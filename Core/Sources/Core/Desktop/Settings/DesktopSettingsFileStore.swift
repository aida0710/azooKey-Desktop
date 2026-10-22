import Foundation

/// The settings file as one version: values to use and, when the file
/// cannot be used, why. Values are then the last ones Core trusted.
public struct DesktopSettingsLoad: Sendable {
    public let values: DesktopSettings
    public let stamp: DesktopSettingsFileStamp
    public let problem: DesktopSettingsProblem?
}

public struct DesktopSettingsSave: Sendable {
    public let values: DesktopSettings
    public let stamp: DesktopSettingsFileStamp
    /// Where an explicit recovery kept the original file, byte for byte.
    public let recoveredFileURL: URL?
    /// False when the settings were saved but the last good copy was not.
    public let lastGoodSaved: Bool
}

/// Reads the settings file without ever changing it, and writes it only
/// through a private staged copy that replaces the file in one step.
@MainActor
public final class DesktopSettingsFileStore {
    public typealias Publish = @MainActor (_ stagedFileURL: URL) async throws -> Void

    private enum CachedRead {
        case values(DesktopSettings)
        case problem(DesktopSettingsProblem)
    }

    public let fileURL: URL
    public let lastGoodURL: URL
    private let directoryURL: URL
    private let lockFileURL: URL
    private let operations: DesktopSettingsFileOperations
    private var cache: (stamp: DesktopSettingsFileStamp, read: CachedRead)?

    public convenience init(fileURL: URL = DesktopSettingsFileLocation.settingsFileURL()) {
        self.init(fileURL: fileURL, operations: .system)
    }

    init(fileURL: URL, operations: DesktopSettingsFileOperations) {
        self.fileURL = fileURL
        self.directoryURL = fileURL.deletingLastPathComponent()
        self.lastGoodURL = directoryURL.appendingPathComponent("settings.last-good.json")
        self.lockFileURL = directoryURL.appendingPathComponent(".settings.lock")
        self.operations = operations
    }

    /// A missing file means `knownGood`. A damaged file is reported once per
    /// version and is never rewritten here; the user repairs or recovers it.
    public func load(knownGood: DesktopSettings) -> DesktopSettingsLoad {
        let stamp = DesktopSettingsFileStamp.read(fileURL)
        guard stamp != .absent else {
            return .init(values: knownGood, stamp: stamp, problem: nil)
        }
        if cache?.stamp != stamp {
            do {
                cache = (stamp, .values(try readFile(over: knownGood)))
            } catch {
                cache = (stamp, .problem(Self.problem(for: error, fallback: .readFailed)))
            }
        }
        switch cache?.read {
        case .values(let values):
            return .init(values: values, stamp: stamp, problem: nil)
        case .problem(let problem):
            // A later successful apply may have changed knownGood while the
            // same damaged file remains. Never pin an older fallback.
            return .init(values: knownGood, stamp: stamp, problem: problem)
        case nil:
            return .init(values: knownGood, stamp: stamp, problem: nil)
        }
    }

    /// The converter refused this version; report it until the file changes.
    public func reject(_ loaded: DesktopSettingsLoad) {
        cache = (loaded.stamp, .problem(.init(.engineRejected)))
    }

    /// Keeps a copy of values Core accepted. Failure never blocks input.
    @discardableResult
    public func remember(_ values: DesktopSettings) -> Bool {
        do {
            try values.validate()
            try createDirectory()
            try write(DesktopSettingsDocument.data(for: values), to: lastGoodURL)
            return true
        } catch {
            return false
        }
    }

    /// The last good copy, except that newer dictionaries and learning, AI
    /// and profile choices stay as they are now.
    public func recoveryValues(knownGood: DesktopSettings) -> DesktopSettings {
        guard let data = try? Data(contentsOf: lastGoodURL),
              let saved = try? DesktopSettingsDocument.settings(from: data, over: knownGood) else {
            return knownGood
        }
        return saved.keepingRecoveryValues(of: knownGood)
    }

    /// Saves `values`. `expectedStamp` is the version the caller opened, or
    /// nil to skip that check. A damaged file is replaced only when `recover`
    /// is true, and then the original is kept beside it under a new name.
    /// `publish` installs the staged file and restores any state it changed if it fails.
    /// Throws a `DesktopSettingsProblem`, or the error `publish` threw.
    public func save(
        _ values: DesktopSettings, expectedStamp: DesktopSettingsFileStamp?, recover: Bool = false,
        publish: Publish
    ) async throws -> DesktopSettingsSave {
        let lock = try acquireWriterLock()
        defer {
            withExtendedLifetime(lock) {}
        }
        try values.validate()
        let currentStamp = try currentStamp(matching: expectedStamp)
        if !recover {
            _ = try readBeforeSave(knownGood: values, stamp: currentStamp)
        }
        return try await publishLocked(values, currentStamp: currentStamp, recover: recover, publish: publish)
    }

    /// Changes the current file's values. A missing file starts from `knownGood`.
    public func modify(
        knownGood: DesktopSettings, expectedStamp: DesktopSettingsFileStamp?,
        change: (inout DesktopSettings) throws -> Void, publish: Publish
    ) async throws -> DesktopSettingsSave {
        let lock = try acquireWriterLock()
        defer {
            withExtendedLifetime(lock) {}
        }
        let currentStamp = try currentStamp(matching: expectedStamp)
        var values = try readBeforeSave(knownGood: knownGood, stamp: currentStamp)
        try change(&values)
        try values.validate()
        return try await publishLocked(values, currentStamp: currentStamp, recover: false, publish: publish)
    }

    /// The plain publication: move the staged file into place.
    public func install(_ stagedFileURL: URL) throws {
        do {
            try operations.replaceFile(stagedFileURL, fileURL)
        } catch {
            throw DesktopSettingsProblem(.writeFailed)
        }
    }

    private func publishLocked(
        _ values: DesktopSettings, currentStamp: DesktopSettingsFileStamp, recover: Bool, publish: Publish
    ) async throws -> DesktopSettingsSave {
        var recoveredFileURL: URL?
        if recover && currentStamp != .absent {
            let preserved = recoveredFileURLCandidate()
            do {
                try operations.replaceFile(fileURL, preserved)
            } catch {
                throw DesktopSettingsProblem(.writeFailed)
            }
            recoveredFileURL = preserved
        }
        do {
            let staged: URL
            do {
                staged = try operations.writeStagedFile(DesktopSettingsDocument.data(for: values), directoryURL)
            } catch {
                throw DesktopSettingsProblem(.writeFailed)
            }
            defer {
                // After a successful publication the staged file is already gone.
                try? FileManager.default.removeItem(at: staged)
            }
            try await publish(staged)
        } catch {
            if let recoveredFileURL, !FileManager.default.fileExists(atPath: fileURL.path) {
                try? operations.replaceFile(recoveredFileURL, fileURL)
            }
            throw error
        }
        let lastGoodSaved = remember(values)
        cache = nil
        return .init(values: values, stamp: .read(fileURL), recoveredFileURL: recoveredFileURL, lastGoodSaved: lastGoodSaved)
    }

    private func currentStamp(matching expectedStamp: DesktopSettingsFileStamp?) throws -> DesktopSettingsFileStamp {
        let currentStamp = DesktopSettingsFileStamp.read(fileURL)
        if let expectedStamp, currentStamp != expectedStamp {
            throw DesktopSettingsProblem(.changed)
        }
        return currentStamp
    }

    private func readBeforeSave(knownGood: DesktopSettings, stamp: DesktopSettingsFileStamp) throws -> DesktopSettings {
        guard stamp != .absent else {
            return knownGood
        }
        do {
            return try readFile(over: knownGood)
        } catch {
            throw DesktopSettingsProblem(.recoveryRequired)
        }
    }

    private func readFile(over knownGood: DesktopSettings) throws -> DesktopSettings {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw DesktopSettingsProblem(.readFailed)
        }
        return try DesktopSettingsDocument.settings(from: data, over: knownGood)
    }

    private func acquireWriterLock() throws -> DesktopSettingsWriterLock {
        do {
            try createDirectory()
            return try DesktopSettingsWriterLock(lockFileURL: lockFileURL)
        } catch {
            throw Self.problem(for: error, fallback: .writeFailed)
        }
    }

    private func write(_ content: Data, to destination: URL) throws {
        let staged = try operations.writeStagedFile(content, directoryURL)
        do {
            try operations.replaceFile(staged, destination)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    private func createDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
    }

    private func recoveredFileURLCandidate() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8).lowercased()
        return directoryURL.appendingPathComponent("settings.recovered-\(formatter.string(from: Date()))-\(suffix).json")
    }

    private static func problem(for error: any Error, fallback: DesktopSettingsProblem.Code) -> DesktopSettingsProblem {
        error as? DesktopSettingsProblem ?? .init(fallback)
    }
}
