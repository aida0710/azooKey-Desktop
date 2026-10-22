import Core
@testable import DesktopBridge
import Foundation
import Testing

@Suite("Linux辞書設定JSONの保存と復元")
struct DesktopDictionarySettingsFileTests {
    @Test("保存後の復元で元のJSONの内容・inode・更新日時をすべて保持する")
    func restorationPreservesOriginalContentInodeAndModificationDate() throws {
        let fixture = try DesktopDictionaryFileFixture()
        let originalContent = try Data(contentsOf: fixture.settingsURL)
        let originalIdentity = try fixture.identity()
        let stagedContent = try Data(contentsOf: fixture.stagedURL)
        let file = try fixture.makeFile()
        try file.capture()
        let backup = try #require(try fixture.backups().first)
        #expect(try fixture.identity(at: backup) == originalIdentity)

        try file.install()

        #expect(try Data(contentsOf: fixture.settingsURL) == stagedContent)
        #expect(try fixture.identity().inode != originalIdentity.inode)
        #expect(!FileManager.default.fileExists(atPath: fixture.stagedURL.path))

        try file.restore()

        #expect(try Data(contentsOf: fixture.settingsURL) == originalContent)
        #expect(try fixture.identity() == originalIdentity)
        #expect(try fixture.backups().isEmpty)
    }

    @Test("正常保存では辞書以外の設定とヒントを保持し不要なバックアップだけ削除する")
    func successfulInstallPreservesTheEntireStagedDocument() throws {
        let fixture = try DesktopDictionaryFileFixture()
        let expected = try Data(contentsOf: fixture.stagedURL)
        let file = try fixture.makeFile()
        try file.capture()
        try file.install()
        try file.discardBackup()

        let saved = try Data(contentsOf: fixture.settingsURL)
        #expect(saved == expected)
        let dictionary = try #require(try DesktopDictionarySettingsFile.dictionary(in: saved))
        #expect(DesktopDictionarySettingsFile.sameEntries(dictionary.items, fixture.newEntries))
        let document = try #require(try JSONSerialization.jsonObject(with: saved) as? [String: Any])
        #expect(document["tree"] as? Bool == false)
        #expect((document["appearance"] as? [String: Double])?["fontScale"] == 1.25)
        #expect((document["customSetting"] as? [String: String])?["preserved"] == "固定データ\n改行")
        #expect(try fixture.backups().isEmpty)
    }

    @Test("初回保存を戻すと新しいJSONを除去し存在しなかった旧ファイルを作らない")
    func firstSaveRollbackRemovesTheNewSettingsFile() throws {
        let fixture = try DesktopDictionaryFileFixture(hasPreviousSettings: false)
        let file = try fixture.makeFile()
        try file.capture()
        try file.install()
        #expect(FileManager.default.fileExists(atPath: fixture.settingsURL.path))

        try file.restore()

        #expect(!FileManager.default.fileExists(atPath: fixture.settingsURL.path))
        #expect(try fixture.backups().isEmpty)
    }

    @Test("コンパイル失敗に相当する未設置の破棄では元のJSONを変更しない")
    func failureBeforeInstallDiscardsOnlyTheUnusedBackup() throws {
        let fixture = try DesktopDictionaryFileFixture()
        let originalContent = try Data(contentsOf: fixture.settingsURL)
        let originalIdentity = try fixture.identity()
        let file = try fixture.makeFile()
        try file.capture()
        #expect(try fixture.backups().count == 1)

        try file.discardUnusedBackup()

        #expect(try fixture.backups().isEmpty)
        #expect(try Data(contentsOf: fixture.settingsURL) == originalContent)
        #expect(try fixture.identity() == originalIdentity)
        #expect(FileManager.default.fileExists(atPath: fixture.stagedURL.path))
    }

    @Test("置換直前の内容変更・同内容symlinkへの交換・ディレクトリへの交換を拒否する",
          arguments: ["content", "symlink", "directory"])
    func changedStageCannotReplaceTheOriginalSettings(change: String) throws {
        let fixture = try DesktopDictionaryFileFixture()
        let originalContent = try Data(contentsOf: fixture.settingsURL)
        let originalIdentity = try fixture.identity()
        let stagedContent = try Data(contentsOf: fixture.stagedURL)
        let file = try fixture.makeFile()
        try file.capture()
        try FileManager.default.removeItem(at: fixture.stagedURL)
        switch change {
        case "content":
            try (stagedContent + Data("\n".utf8)).write(to: fixture.stagedURL)
        case "symlink":
            let target = fixture.rootURL.appendingPathComponent("matching-content.json")
            try stagedContent.write(to: target)
            try FileManager.default.createSymbolicLink(at: fixture.stagedURL, withDestinationURL: target)
        default:
            try FileManager.default.createDirectory(at: fixture.stagedURL, withIntermediateDirectories: false)
        }

        #expect(throws: DesktopDictionarySettingsFile.Failure.self) {
            try file.install()
        }
        try file.restore()

        #expect(try Data(contentsOf: fixture.settingsURL) == originalContent)
        #expect(try fixture.identity() == originalIdentity)
        #expect(try fixture.backups().isEmpty)
    }

    @Test("ステージファイルの場所・名前・種別が不正なら元の設定を変更しない",
          arguments: ["directory", "name", "symlink", "folder"])
    func invalidStagingLocationOrTypeIsRejected(kind: String) throws {
        let fixture = try DesktopDictionaryFileFixture()
        let originalContent = try Data(contentsOf: fixture.settingsURL)
        let originalIdentity = try fixture.identity()
        let stage: URL
        switch kind {
        case "directory":
            let other = fixture.rootURL.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            stage = other.appendingPathComponent(".settings-other.json")
            try Data(contentsOf: fixture.stagedURL).write(to: stage)
        case "name":
            stage = fixture.rootURL.appendingPathComponent("unrelated.json")
            try Data(contentsOf: fixture.stagedURL).write(to: stage)
        case "symlink":
            stage = fixture.rootURL.appendingPathComponent(".settings-link.json")
            try FileManager.default.createSymbolicLink(at: stage, withDestinationURL: fixture.stagedURL)
        default:
            stage = fixture.rootURL.appendingPathComponent(".settings-folder")
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        }

        #expect(throws: DesktopDictionarySettingsFile.Failure.self) {
            _ = try DesktopDictionarySettingsFile(
                stagedURL: stage, settingsURL: fixture.settingsURL, entries: fixture.newEntries
            )
        }

        #expect(try Data(contentsOf: fixture.settingsURL) == originalContent)
        #expect(try fixture.identity() == originalIdentity)
        #expect(try fixture.backups().isEmpty)
    }

    @Test("ステージの辞書と要求のID・単語・読み・ヒントの不一致を拒否する",
          arguments: ["id", "word", "reading", "hint", "count"])
    func mismatchedDictionaryCannotBeSaved(field: String) throws {
        let fixture = try DesktopDictionaryFileFixture()
        var entries = fixture.newEntries
        switch field {
        case "id": entries[0].id = UUID()
        case "word": entries[0].word = "異なる単語"
        case "reading": entries[0].reading = "べつのよみ"
        case "hint": entries[0].nonNullHint = "異なるヒント"
        default: entries = []
        }

        #expect(throws: DesktopDictionarySettingsFile.Failure.self) {
            _ = try DesktopDictionarySettingsFile(
                stagedURL: fixture.stagedURL, settingsURL: fixture.settingsURL, entries: entries
            )
        }

        #expect(try fixture.backups().isEmpty)
        #expect(try Data(contentsOf: fixture.settingsURL) == fixture.content(entries: fixture.oldEntries))
    }

    @Test("既存JSONがsymlinkならリンク先の有無にかかわらず保存を拒否する", arguments: [false, true])
    func symbolicSettingsFileIsRejectedWithoutTouchingItsTarget(dangling: Bool) throws {
        let fixture = try DesktopDictionaryFileFixture()
        let target = fixture.rootURL.appendingPathComponent("link-target.json")
        let originalContent = try Data(contentsOf: fixture.settingsURL)
        if !dangling {
            try originalContent.write(to: target)
        }
        try FileManager.default.removeItem(at: fixture.settingsURL)
        try FileManager.default.createSymbolicLink(at: fixture.settingsURL, withDestinationURL: target)
        let file = try fixture.makeFile()

        #expect(throws: DesktopDictionarySettingsFile.Failure.self) {
            try file.capture()
        }

        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: fixture.settingsURL.path) == target.path)
        #expect(try fixture.backups().isEmpty)
        if !dangling {
            #expect(try Data(contentsOf: target) == originalContent)
        }
    }

    @Test("復元に失敗しても元JSONのバックアップを削除せず次の復元に使える")
    func failedRestoreRetainsTheOriginalInodeForRecovery() throws {
        let fixture = try DesktopDictionaryFileFixture()
        let originalContent = try Data(contentsOf: fixture.settingsURL)
        let originalIdentity = try fixture.identity()
        let file = try fixture.makeFile()
        try file.capture()
        try file.install()
        let installedURL = fixture.rootURL.appendingPathComponent("installed.json")
        try FileManager.default.moveItem(at: fixture.settingsURL, to: installedURL)
        try FileManager.default.createDirectory(at: fixture.settingsURL, withIntermediateDirectories: false)

        #expect(throws: POSIXError.self) {
            try file.restore()
        }
        try file.discardUnusedBackup()

        let backup = try #require(try fixture.backups().first)
        #expect(try Data(contentsOf: backup) == originalContent)
        #expect(try fixture.identity(at: backup) == originalIdentity)
        try FileManager.default.removeItem(at: fixture.settingsURL)
        try file.restore()
        #expect(try Data(contentsOf: fixture.settingsURL) == originalContent)
        #expect(try fixture.identity() == originalIdentity)
    }

    @Test("元のJSONが壊れていても失敗後にその内容を正確に戻せる")
    func malformedPreviousSettingsAreRestoredWithoutDecoding() throws {
        let fixture = try DesktopDictionaryFileFixture()
        let malformed = Data("{broken legacy settings\n".utf8)
        try malformed.write(to: fixture.settingsURL)
        let originalIdentity = try fixture.identity()
        let file = try fixture.makeFile()
        try file.capture()
        try file.install()
        try file.restore()

        #expect(try Data(contentsOf: fixture.settingsURL) == malformed)
        #expect(try fixture.identity() == originalIdentity)
    }
}
