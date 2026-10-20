@testable import Core
@testable import DesktopBridge
import Foundation
import Testing

@MainActor
enum DesktopWorkerDefaultsFixture {
    static func withSavedTable<Value>(_ contents: Data?, perform: () throws -> Value) throws -> Value {
        let file = CustomInputTableStore.fileURL
        let original = CustomInputTableStore.exists() ? try Data(contentsOf: file) : nil
        defer {
            do {
                if let original { try original.write(to: file, options: .atomic) } else { try CustomInputTableStore.clear() }
            } catch {
                Issue.record(error)
            }
        }
        try replaceSavedTable(contents)
        return try perform()
    }

    static func replaceSavedTable(_ contents: Data?) throws {
        if let contents {
            let file = try CustomInputTableStore.save(exported: "")
            try contents.write(to: file, options: .atomic)
        } else {
            try CustomInputTableStore.clear()
        }
    }

    static func fillingSettingsLimit(_ settings: DesktopWorkerSettings) throws -> DesktopWorkerSettings {
        var expanded = settings
        expanded.transformShortcut.key = "x"
        let byteCount = try JSONEncoder().encode(expanded).count
        expanded.transformShortcut.key = String(repeating: "x", count: DesktopWorkerProtocolLimits.settingsBytes - byteCount + 1)
        #expect(try JSONEncoder().encode(expanded).count == DesktopWorkerProtocolLimits.settingsBytes)
        return expanded
    }
}
