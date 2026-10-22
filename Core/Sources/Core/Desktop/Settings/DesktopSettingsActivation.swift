import Foundation

/// Keeps the running converter's settings consistent with the settings
/// file. One instance lives in each process that applies settings.
@MainActor
public final class DesktopSettingsActivation {
    /// Gives the converter new settings, or throws and leaves it unchanged.
    public typealias Apply = @MainActor (DesktopSettings) async throws -> Void

    private let running: @MainActor () -> DesktopSettings
    private var appliedStamp: DesktopSettingsFileStamp?
    /// Settings the converter must get back before anything else is saved: a
    /// file write failed after the converter took new values, and putting the
    /// old ones back failed as well.
    private var restoreTarget: DesktopSettings?

    /// `running` reads the settings the converter uses now.
    public init(running: @escaping @MainActor () -> DesktopSettings) {
        self.running = running
    }

    public var current: DesktopSettings {
        running()
    }

    /// Applies the settings file if it changed since this process last applied
    /// it. Values in the result are what the converter runs with afterwards.
    public func reload(from store: DesktopSettingsFileStore, apply: Apply) async -> DesktopSettingsLoad {
        let loaded = store.load(knownGood: running())
        guard loaded.problem == nil, loaded.stamp != .absent, loaded.stamp != appliedStamp else {
            return .init(values: running(), stamp: loaded.stamp, problem: loaded.problem)
        }
        do {
            try await apply(loaded.values)
        } catch {
            store.reject(loaded)
            return .init(values: running(), stamp: loaded.stamp, problem: .init(.engineRejected))
        }
        appliedStamp = loaded.stamp
        store.remember(loaded.values)
        return .init(values: running(), stamp: loaded.stamp, problem: nil)
    }

    /// Publishes a staged save: the converter takes `values`, then the staged
    /// file replaces the settings file. If the file cannot be replaced the
    /// converter gets its previous settings back.
    public func publish(
        _ values: DesktopSettings, stagedFileURL: URL, into store: DesktopSettingsFileStore, apply: Apply
    ) async throws {
        if let restoreTarget {
            do {
                try await apply(restoreTarget)
            } catch {
                throw DesktopSettingsProblem(.backendRecoveryFailed)
            }
            self.restoreTarget = nil
        }
        let previous = running()
        do {
            try await apply(values)
        } catch {
            throw DesktopSettingsProblem(.engineRejected)
        }
        do {
            try store.install(stagedFileURL)
        } catch {
            do {
                try await apply(previous)
            } catch {
                restoreTarget = previous
                throw DesktopSettingsProblem(.backendRecoveryFailed)
            }
            throw error
        }
    }

    /// A save this process published is already applied; reloading it does nothing.
    public func recordSaved(_ saved: DesktopSettingsSave) {
        appliedStamp = saved.stamp
    }
}
