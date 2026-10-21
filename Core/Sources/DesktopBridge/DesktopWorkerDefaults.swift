import Core
import Foundation

/// A reader's immutable startup values, separate from the settings acknowledged by either worker.
@MainActor
struct DesktopWorkerDefaults {
    private static let invalidDefaults = "invalid_worker_defaults"
    private let settings: DesktopWorkerSettings?

    init() {
        do {
            let table = try CustomInputTableStore.load(maximumBytes: DesktopWorkerProtocolLimits.settingsBytes) ?? ""
            let captured = DesktopWorkerSettings(capturingCustomTable: table)
            _ = try DesktopWorkerSettingsRuntime.identity(captured)
            try DesktopWorkerSettingsRuntime.validateValues(captured)
            settings = captured
        } catch {
            settings = nil
        }
    }

    func adding(to response: DesktopReadingWorkerResponse) throws -> DesktopReadingWorkerResponse {
        var reply = response
        reply.defaultSettings = settings
        if settings == nil {
            reply.defaultSettingsError = Self.invalidDefaults
        } else if try JSONEncoder().encode(reply).count > DesktopWorkerProtocolLimits.jsonBytes {
            // Applied settings and envelope metadata also consume space in a hello/settings reply.
            reply.defaultSettings = nil
            reply.defaultSettingsError = Self.invalidDefaults
        }
        return reply
    }
}
