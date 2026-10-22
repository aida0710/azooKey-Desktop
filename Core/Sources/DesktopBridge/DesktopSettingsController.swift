import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

/// The settings file fields of a request.
struct DesktopSettingsFileRequest: Decodable {
    /// The stamp the screen opened; a save refuses a file changed since.
    var expectedStamp: DesktopSettingsFileStamp?
    /// Replace a damaged file, keeping the original under a new name.
    var recover: Bool?
    /// With settings-recover: also return input and display settings to their defaults.
    var useDefaults: Bool?
}

/// What a settings operation reports besides the values in `settings`.
struct DesktopSettingsResult: Encodable {
    struct FileState: Encodable {
        let path: String
        let stamp: DesktopSettingsFileStamp
        let exists: Bool
        let problem: DesktopSettingsProblem?
    }

    struct SaveReport: Encodable {
        let recoveredPath: String?
        let lastGoodSaved: Bool
    }

    var schema: DesktopSettingsSchema?
    var file: FileState?
    var saved: SaveReport?
    var error: DesktopSettingsProblem?
}

/// Serves the settings operations of one bridge process. The settings file
/// is read, validated, saved and recovered in Core; frontends only show it.
@MainActor
final class DesktopSettingsController {
    /// Operations after which the converter may run with other settings.
    static let applyingOperations: Set<String> = ["configure", "settings-reload", "settings-save", "settings-recover"]

    let store: DesktopSettingsFileStore
    let activation = DesktopSettingsActivation { DesktopSettings.current() }
    private let memoryDirectoryURL: URL
    private let converter: KanaKanjiConverter

    init(memoryDirectoryURL: URL, converter: KanaKanjiConverter, fileURL: URL = DesktopSettingsFileLocation.settingsFileURL()) {
        self.store = DesktopSettingsFileStore(fileURL: fileURL)
        self.memoryDirectoryURL = memoryDirectoryURL
        self.converter = converter
    }

    func response(to request: BridgeRequest, reloadSessions: () throws -> Void) async throws -> DesktopSnapshot? {
        var response = DesktopSnapshot()
        switch request.operation {
        case "settings":
            response.settings = activation.current
        case "settings-schema":
            response.settingsResult = .init(schema: DesktopSettingsSchema())
        case "settings-load":
            respond(with: store.load(knownGood: activation.current), to: &response)
        case "settings-reload":
            let loaded = await activation.reload(from: store) {
                try await apply($0, requiredDictionarySource: nil, reloadSessions: reloadSessions)
            }
            respond(with: loaded, to: &response)
        case "settings-save":
            guard let document = request.settings else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            await save(request, recover: request.settingsFile?.recover ?? false, to: &response, reloadSessions: reloadSessions) {
                try DesktopSettingsDocument.settings(from: document, over: activation.current)
            }
        case "settings-recover":
            await save(request, recover: true, to: &response, reloadSessions: reloadSessions) {
                let values = store.recoveryValues(knownGood: activation.current)
                return request.settingsFile?.useDefaults == true ? values.resettingInputPreferences() : values
            }
        case "settings-update":
            guard let changes = request.settings else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            await update(changes, expectedStamp: request.settingsFile?.expectedStamp, to: &response)
        default:
            return nil
        }
        return response
    }

    /// Applies settings sent with the request itself, without the settings file.
    func configure(_ document: DesktopSettingsJSON, reloadSessions: () throws -> Void) async throws {
        try await apply(
            DesktopSettingsDocument.settings(from: document, over: activation.current),
            requiredDictionarySource: store.fileURL, reloadSessions: reloadSessions
        )
    }

    private func save(
        _ request: BridgeRequest, recover: Bool, to response: inout DesktopSnapshot, reloadSessions: () throws -> Void,
        makeValues: () throws -> DesktopSettings
    ) async {
        do {
            let values = try makeValues()
            let expectedStamp = request.settingsFile?.expectedStamp
            let saved = try await store.save(values, expectedStamp: expectedStamp, recover: recover) { staged in
                try await activation.publish(values, stagedFileURL: staged, into: store) {
                    try await apply($0, requiredDictionarySource: nil, reloadSessions: reloadSessions)
                }
            }
            activation.recordSaved(saved)
            respond(with: saved, to: &response)
        } catch {
            response.settingsResult = .init(error: Self.problem(for: error))
        }
    }

    /// Changes some settings in the file without applying them; the next reload does.
    private func update(_ changes: DesktopSettingsJSON, expectedStamp: DesktopSettingsFileStamp?, to response: inout DesktopSnapshot) async {
        do {
            let saved = try await store.modify(
                knownGood: activation.current, expectedStamp: expectedStamp,
                change: { try $0.merge(changes) }, publish: { try store.install($0) }
            )
            respond(with: saved, to: &response)
        } catch {
            response.settingsResult = .init(error: Self.problem(for: error))
        }
    }

    private func apply(
        _ settings: DesktopSettings, requiredDictionarySource: URL?, reloadSessions: () throws -> Void
    ) async throws {
        try await DesktopDictionaryController.applyDictionary(
            settings.userDictionary.items, requiredSourceURL: requiredDictionarySource,
            memoryDirectoryURL: memoryDirectoryURL, converter: converter
        )
        try settings.applyToConfig()
        try reloadSessions()
    }

    private func respond(with loaded: DesktopSettingsLoad, to response: inout DesktopSnapshot) {
        response.settings = loaded.values
        response.settingsResult = .init(file: fileState(stamp: loaded.stamp, problem: loaded.problem))
    }

    func respond(with saved: DesktopSettingsSave, to response: inout DesktopSnapshot) {
        response.settings = saved.values
        response.settingsResult = .init(
            file: fileState(stamp: saved.stamp, problem: nil),
            saved: .init(recoveredPath: saved.recoveredFileURL?.path, lastGoodSaved: saved.lastGoodSaved)
        )
    }

    private func fileState(stamp: DesktopSettingsFileStamp, problem: DesktopSettingsProblem?) -> DesktopSettingsResult.FileState {
        .init(path: store.fileURL.path, stamp: stamp, exists: FileManager.default.fileExists(atPath: store.fileURL.path), problem: problem)
    }

    static func problem(for error: any Error) -> DesktopSettingsProblem {
        error as? DesktopSettingsProblem ?? .init(.writeFailed)
    }
}
