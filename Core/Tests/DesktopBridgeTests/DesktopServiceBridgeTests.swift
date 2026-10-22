#if os(Linux)
import Core
import Foundation
import Testing

@Suite(.serialized)
struct DesktopServiceBridgeTests {
    @Test func supportReportUsesTheRequestedLanguageAndOnlyRecognizedValues() throws {
        let fixture = try DesktopDictionaryBridgeFixture()
        let environment: [String: Any] = [
            "treeEnabled": true, "rendererRegistered": true, "sessionType": "x11",
            "osReleaseID": "ubuntu", "osReleaseVersionID": "PRIVATE VERSION", "machine": "x86_64",
            "buildInfo": "version=0.2.0\napiKey=PRIVATE_KEY\n"
        ]
        let responses = try fixture.run([
            ["operation": "support-diagnostics", "supportEnvironment": environment, "language": "ja"],
            ["operation": "support-diagnostics", "supportEnvironment": environment, "language": "en"],
            ["operation": "support-diagnostics", "language": "ja"]
        ])
        let japanese = try #require(responses[0]["supportDiagnostics"] as? String)
        #expect(japanese.contains("配布版: 0.2.0"))
        #expect(japanese.contains("候補の表示方式: GNOME 拡張のツリー"))
        #expect(!japanese.contains("PRIVATE"))
        let english = try #require(responses[1]["supportDiagnostics"] as? String)
        #expect(english.contains("\(Localization.text("support.version", language: .english)): 0.2.0"))
        #expect(responses[2]["error"] as? String == "invalid_request")
    }

    @Test func personalizationImportPlacesTheModelOrNamesTheInvalidFile() throws {
        let fixture = try DesktopDictionaryBridgeFixture()
        let source = fixture.rootURL.appendingPathComponent("tuner-output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in PersonalizationModelImport.fileNames {
            try Data("We love Marisa.\0\(name)".utf8).write(to: source.appendingPathComponent(name))
        }
        let valid = try fixture.run([["operation": "import-personalization", "importPath": source.path]])
        #expect(valid[0]["personalizationImported"] as? Bool == true)
        let current = fixture.dataURL.appendingPathComponent("personalization/current/lm_c_abc.marisa")
        #expect(FileManager.default.fileExists(atPath: current.path))

        try Data("plain text, not a MARISA trie file".utf8).write(to: source.appendingPathComponent("lm_u_abx.marisa"))
        let invalid = try fixture.run([["operation": "import-personalization", "importPath": source.path]])
        #expect(invalid[0]["personalizationImported"] as? Bool == false)
        let failure = try #require(invalid[0]["personalizationFailure"] as? [String: Any])
        #expect(failure["reason"] as? String == "notMarisa")
        #expect(failure["file"] as? String == "lm_u_abx.marisa")
    }
}
#endif
