import Foundation
import Testing

@testable import Core

@Suite("設定の定義とページ構成")
struct DesktopSettingsSchemaTests {
    private static let inputDefaultKeys: Set<String> = [
        "tree", "live", "halfSpace", "backslash", "optionDirect", "inputStyle", "candidateTextSize",
        "punctuation", "inferenceLimit", "predictiveTyping", "typoCorrection", "debug", "showRelativeScores"
    ]
    private static let recoveryKeptKeys: Set<String> = [
        "userDictionary", "customTable", "learning", "personalization", "profile",
        "aiEnabled", "aiModel", "aiEndpoint", "includeContext", "transformShortcut"
    ]

    @Test("設定ファイルのすべての項目に定義があり既定値は既定の設定と一致する")
    func everySettingHasADefinitionWithItsDefault() {
        let schema = DesktopSettingsSchema(platform: .linux)
        #expect(schema.items.map(\.key) == DesktopSettings.keys)
        for item in schema.items {
            #expect(item.defaultValue == DesktopSettings.defaults.value(forKey: item.key))
            for choice in item.choices {
                var settings = DesktopSettings.defaults
                #expect(throws: Never.self) { try settings.setValue(choice.value, forKey: item.key) }
            }
        }
        #expect(Set(schema.items.filter(\.resetsToInputDefault).map(\.key)) == Self.inputDefaultKeys)
        #expect(Set(schema.items.filter(\.keptOnRecovery).map(\.key)) == Self.recoveryKeptKeys)
    }

    @Test("各項目はちょうど一つのページに現れLinuxの画面と同じ順に並ぶ")
    func everySettingAppearsOnceInPageOrder() {
        let schema = DesktopSettingsSchema(platform: .linux)
        let placed = schema.pages.flatMap { page in
            page.elements.compactMap { element -> String? in
                if case .setting(let key) = element {
                    return key
                }
                return nil
            }
        }
        #expect(placed.sorted() == DesktopSettings.keys.sorted())
        #expect(schema.pages.map(\.id) == ["input", "conversion", "dictionary", "ai", "support"])
        #expect(Array(placed.prefix(6)) == ["halfSpace", "backslash", "optionDirect", "inputStyle", "punctuation", "customTable"])
    }

    @Test("Windowsではmarisa形式を使う項目とボタンを理由付きで使えないと示す")
    func windowsMarksMarisaFeaturesUnavailableWithAReason() throws {
        let windows = DesktopSettingsSchema(platform: .windows)
        for key in ["typoCorrection", "personalization"] {
            let item = try #require(windows.item(key))
            #expect(!item.isAvailable)
            #expect(item.unavailableReasonKey == "settings.unavailable.marisa_windows")
        }
        let actions = windows.pages.flatMap(\.elements).compactMap { element -> DesktopSettingsAction? in
            if case .action(let action) = element {
                return action
            }
            return nil
        }
        #expect(actions.filter { !$0.isAvailable }.map(\.id).sorted() == ["downloadTypoWeights", "importPersonalization"])
        let linux = DesktopSettingsSchema(platform: .linux)
        #expect(linux.items.allSatisfy { $0.isAvailable })
    }

    @Test("定義はキー名で文言を引ける形でJSONに書き出す")
    func schemaEncodesMessageKeysAndControls() throws {
        let data = try JSONEncoder().encode(DesktopSettingsSchema(platform: .windows))
        let document = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(document["platform"] as? String == "windows")
        let items = try #require(document["items"] as? [[String: Any]])
        let inference = try #require(items.first { $0["key"] as? String == "inferenceLimit" })
        #expect(inference["control"] as? String == "integer")
        #expect(inference["minimum"] as? Int == 1)
        #expect(inference["maximum"] as? Int == 100)
        #expect(inference["default"] as? Int == 5)
        let typo = try #require(items.first { $0["key"] as? String == "typoCorrection" })
        #expect(typo["available"] as? Bool == false)
        let pages = try #require(document["pages"] as? [[String: Any]])
        let ai = try #require(pages.first { $0["id"] as? String == "ai" })
        let kinds = try #require(ai["elements"] as? [[String: Any]]).compactMap { $0["kind"] as? String }
        #expect(kinds == ["setting", "setting", "note", "setting", "setting", "setting", "secret"])
    }

    @Test("設定ファイルはLinuxとmacOSではXDGの場所、Windowsでは利用者のAppDataに置く")
    func settingsFileLocationFollowsEachPlatform() {
        let home = URL(fileURLWithPath: "/home/user", isDirectory: true)
        #expect(DesktopSettingsFileLocation.settingsFileURL(platform: .linux, environment: [:], homeDirectory: home).path
            == "/home/user/.config/azookey-tree/settings.json")
        #expect(DesktopSettingsFileLocation.settingsFileURL(
            platform: .linux, environment: ["XDG_CONFIG_HOME": "/tmp/config"], homeDirectory: home
        ).path == "/tmp/config/azookey-tree/settings.json")
        #expect(DesktopSettingsFileLocation.settingsFileURL(
            platform: .linux, environment: ["XDG_CONFIG_HOME": ""], homeDirectory: home
        ).path == "/home/user/.config/azookey-tree/settings.json")
        #expect(DesktopSettingsFileLocation.settingsFileURL(
            platform: .windows, environment: ["APPDATA": "/appdata"], homeDirectory: home
        ).path == "/appdata/azooKey Tree/settings.json")
        #expect(DesktopSettingsFileLocation.settingsFileURL(platform: .windows, environment: [:], homeDirectory: home).path
            == "/home/user/AppData/Roaming/azooKey Tree/settings.json")
    }
}
