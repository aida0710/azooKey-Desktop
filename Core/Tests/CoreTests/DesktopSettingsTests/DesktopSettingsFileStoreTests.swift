import Foundation
import Testing
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

@testable import Core

@MainActor
@Suite("設定ファイルの読み込み・保存・復旧")
struct DesktopSettingsFileStoreTests {
    let fixture: DesktopSettingsFixture
    let store: DesktopSettingsFileStore
    let values = DesktopSettingsFixture.known

    init() throws {
        fixture = try DesktopSettingsFixture()
        store = DesktopSettingsFileStore(fileURL: fixture.fileURL)
    }

    @Test("ファイルが無いときと壊れたまま変わらないときは最新の正常な値を使う")
    func missingAndUnchangedBrokenFileUseLatestKnownSettings() throws {
        #expect(store.load(knownGood: values).values == values)
        var changed = values
        changed.live = true
        #expect(store.load(knownGood: changed).values == changed)
        try fixture.write("{")
        #expect(store.load(knownGood: values).problem != nil)
        #expect(store.load(knownGood: changed).values == changed)
    }

    @Test("壊れた文書は元のファイルを変えず入力用の値も保つ")
    func invalidDocumentsKeepOriginalFileAndInputValues() throws {
        let documents = ["{", #"{"live":false,"live":true}"#, #"{"live":1}"#, #"{"learning":"unknown"}"#,
                         #"{"unexpected":true}"#, #"["not an object"]"#, #"{"profile":"\ud800"}"#]
        for document in documents {
            try fixture.write(document)
            let loaded = store.load(knownGood: values)
            #expect(loaded.values == values)
            #expect(loaded.problem != nil, "\(document)")
            #expect(try fixture.contents() == Data(document.utf8))
            #expect(try fixture.files(withPrefix: "settings.recovered-").isEmpty)
        }
    }

    @Test("読めないファイルと切れたリンクも復旧できる問題として扱う")
    func unreadableFileAndBrokenLinkRemainRecoverable() throws {
        try FileManager.default.createDirectory(at: fixture.fileURL, withIntermediateDirectories: false)
        let unreadable = store.load(knownGood: values)
        #expect(unreadable.problem == .init(.readFailed))
        #expect(unreadable.values == values)
        try FileManager.default.removeItem(at: fixture.fileURL)
        try FileManager.default.createSymbolicLink(
            at: fixture.fileURL, withDestinationURL: fixture.directoryURL.appendingPathComponent("missing.json")
        )
        let brokenLink = store.load(knownGood: values)
        #expect(brokenLink.stamp != .absent)
        #expect(brokenLink.problem != nil)
        #expect(brokenLink.values == values)
    }

    @Test("深く壊れた文書は何度読んでも問題を返し直せばすぐ使える")
    func deeplyInvalidDocumentIsReportedRepeatedlyUntilRepaired() throws {
        let original = #"{"profile":"# + String(repeating: "[", count: 1200) + "0" + String(repeating: "]", count: 1200) + "}"
        try fixture.write(original)
        for _ in 0..<3 {
            let loaded = store.load(knownGood: values)
            #expect(loaded.values == values)
            #expect(loaded.problem != nil)
        }
        #expect(try fixture.contents() == Data(original.utf8))
        var repaired = values
        repaired.live = true
        try fixture.write(repaired)
        let loaded = store.load(knownGood: values)
        #expect(loaded.values.live)
        #expect(loaded.problem == nil)
    }

    @Test("直したファイルは再起動せずに次の読み込みで使い辞書は正常な値を保つ")
    func repairedPartialFileAppliesOnNextLoad() throws {
        try fixture.write("{")
        #expect(store.load(knownGood: values).problem != nil)
        try fixture.write(#"{"live":true}"#)
        let loaded = store.load(knownGood: values)
        #expect(loaded.problem == nil)
        #expect(loaded.values.live)
        #expect(loaded.values.userDictionary.items.map(\.id) == values.userDictionary.items.map(\.id))
    }

    @Test("変換器が拒否した版は文書が変わるまで問題として残る")
    func engineRejectionIsCachedUntilTheDocumentChanges() throws {
        try fixture.write(#"{"customTable":"synthetic invalid TSV"}"#)
        let loaded = store.load(knownGood: values)
        store.reject(loaded)
        #expect(store.load(knownGood: values).problem == .init(.engineRejected))
        #expect(store.load(knownGood: values).values == values)
        try fixture.write(#"{"customTable":""}"#)
        #expect(store.load(knownGood: values).problem == nil)
    }

    @Test("保存と一部更新は壊れたファイルを上書きしない")
    func saveAndModifyRefuseToOverwriteABrokenFile() async throws {
        try fixture.write("{ invalid synthetic document")
        #expect(await asyncSettingsProblem { _ = try await store.save(values, expectedStamp: nil) { try store.install($0) } }
            == .init(.recoveryRequired))
        #expect(await asyncSettingsProblem {
            _ = try await store.modify(
                knownGood: values, expectedStamp: nil, change: { $0.includeContext = true }, publish: { try store.install($0) }
            )
        } == .init(.recoveryRequired))
        #expect(try fixture.contents() == Data("{ invalid synthetic document".utf8))
    }

    @Test("一部更新は古い画面の写しではなく最新の辞書に重ねる")
    func modifyMergesTheLatestDictionary() async throws {
        var latest = values
        latest.userDictionary.items[0].word = "最新"
        try fixture.write(latest)
        let saved = try await store.modify(
            knownGood: values, expectedStamp: nil, change: { $0.includeContext = true }, publish: { try store.install($0) }
        )
        #expect(saved.values.includeContext)
        #expect(try fixture.savedSettings().userDictionary.items.map(\.word) == ["最新"])
    }

    @Test("開いた後に作られたファイルや書き換えられたファイルを競合として検出する")
    func conflictDetectionIncludesAFileCreatedAfterOpening() async throws {
        let absent = store.load(knownGood: values)
        #expect(absent.stamp == .absent)
        try fixture.write(values)
        #expect(await asyncSettingsProblem { _ = try await store.save(values, expectedStamp: absent.stamp) { try store.install($0) } }
            == .init(.changed))
        let opened = store.load(knownGood: values)
        var changed = values
        changed.live = true
        try fixture.write(changed)
        #expect(await asyncSettingsProblem { _ = try await store.save(values, expectedStamp: opened.stamp) { try store.install($0) } }
            == .init(.changed))
        #expect(try fixture.savedSettings().live)
    }

    #if !os(Windows)
    @Test("明示的な復旧は元のファイルをそのまま残し周りのファイルを変えない")
    func explicitRecoveryPreservesTheExactOriginalAndOtherFiles() async throws {
        let original = Data("{ broken synthetic JSON\n".utf8)
        try original.write(to: fixture.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.fileURL.path)
        let protected = ["learning.dat", "lm_3.marisa", "test-keyring"]
        for name in protected {
            try Data(name.utf8).write(to: fixture.directoryURL.appendingPathComponent(name))
        }
        let loaded = store.load(knownGood: values)
        let saved = try await store.save(values, expectedStamp: loaded.stamp, recover: true) { try store.install($0) }
        let recovered = try #require(saved.recoveredFileURL)
        #expect(try Data(contentsOf: recovered) == original)
        #expect(try permissions(of: recovered) == 0o400)
        #expect(try permissions(of: fixture.fileURL) == 0o600)
        #expect(try fixture.savedSettings() == values)
        #expect(try DesktopSettingsDocument.settings(from: Data(contentsOf: fixture.lastGoodURL), over: .defaults) == values)
        for name in protected {
            #expect(try Data(contentsOf: fixture.directoryURL.appendingPathComponent(name)) == Data(name.utf8))
        }
    }
    #endif

    @Test("復旧の書き込みに失敗したら元のファイルを戻し退避したファイルを残さない")
    func failedRecoveryPublicationPutsTheOriginalBack() async throws {
        try fixture.write("{ original")
        await #expect(throws: SyntheticFailure.self) {
            _ = try await store.save(values, expectedStamp: nil, recover: true) { _ in throw SyntheticFailure() }
        }
        #expect(try fixture.contents() == Data("{ original".utf8))
        #expect(try fixture.files(withPrefix: "settings.recovered-").isEmpty)
        #expect(try fixture.files(withPrefix: ".settings-").isEmpty)
    }

    @Test("古い控えは新しい辞書や送信範囲の選択を戻さない")
    func olderBackupDoesNotReplaceNewerDictionaryOrPrivacyChoices() {
        var older = values
        older.live = true
        older.userDictionary.items[0].word = "古い"
        older.includeContext = true
        #expect(store.remember(older))
        let restored = store.recoveryValues(knownGood: values)
        #expect(restored.live)
        #expect(restored.userDictionary.items.map(\.word) == ["試験"])
        #expect(!restored.includeContext)
    }

    #if !os(Windows)
    @Test("別の画面が保存中なら待たずに断り文書を変えない")
    func anotherWriterFailsQuicklyWithoutChangingTheDocument() async throws {
        try fixture.write(values)
        let descriptor = open(fixture.directoryURL.appendingPathComponent(".settings.lock").path, O_CREAT | O_RDWR, 0o600)
        defer {
            close(descriptor)
        }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        var changed = values
        changed.live = true
        #expect(await asyncSettingsProblem { _ = try await store.save(changed, expectedStamp: nil) { try store.install($0) } }
            == .init(.busy))
        #expect(try fixture.savedSettings() == values)
    }
    #endif

    @Test("控えを書けなくても設定の保存は成功させて知らせる")
    func lastGoodFailureReportsAWarningButKeepsTheSave() async throws {
        try FileManager.default.createDirectory(at: fixture.lastGoodURL, withIntermediateDirectories: false)
        let saved = try await store.save(values, expectedStamp: nil) { try store.install($0) }
        #expect(!saved.lastGoodSaved)
        #expect(try fixture.savedSettings() == values)
    }

    #if !os(Windows)
    @Test("公開処理は同じフォルダーの非公開で同期済みの一時ファイルを書き込みロック中に一度だけ受け取る")
    func publishReceivesAPrivateSyncedStagedFileUnderTheLock() async throws {
        try fixture.write(values)
        let opened = store.load(knownGood: values)
        var updated = values
        updated.live = true
        var installedInode: UInt64?
        let saved = try await store.save(updated, expectedStamp: opened.stamp) { staged in
            #expect(staged.deletingLastPathComponent().standardizedFileURL.path == fixture.directoryURL.standardizedFileURL.path)
            #expect(try permissions(of: staged) == 0o600)
            #expect(try DesktopSettingsDocument.settings(from: Data(contentsOf: staged), over: .defaults) == updated)
            let other = DesktopSettingsFileStore(fileURL: fixture.fileURL)
            #expect(await asyncSettingsProblem { _ = try await other.save(values, expectedStamp: nil) { try other.install($0) } }
                == .init(.busy))
            installedInode = try inode(of: staged)
            try store.install(staged)
        }
        #expect(saved.values == updated)
        #expect(try inode(of: fixture.fileURL) == installedInode)
        #expect(try DesktopSettingsDocument.settings(from: Data(contentsOf: fixture.lastGoodURL), over: .defaults) == updated)
        #expect(try fixture.files(withPrefix: ".settings-").isEmpty)
    }
    #endif

    @Test("公開処理の失敗はそのまま返し一時ファイルを消して元のファイルと控えを変えない")
    func publishFailureIsReturnedUnchangedAndStagingIsRemoved() async throws {
        try fixture.write(values)
        let opened = store.load(knownGood: values)
        await #expect(throws: SyntheticFailure.self) {
            _ = try await store.save(values, expectedStamp: opened.stamp) { _ in throw SyntheticFailure() }
        }
        #expect(store.load(knownGood: values).stamp == opened.stamp)
        #expect(!FileManager.default.fileExists(atPath: fixture.lastGoodURL.path))
        #expect(try fixture.files(withPrefix: ".settings-").isEmpty)
    }

    @Test("競合・不正な値・壊れたファイルでは公開処理を呼ばない")
    func publishIsNotCalledForConflictsInvalidValuesOrABrokenFile() async throws {
        var calls = 0
        try fixture.write(values)
        let opened = store.load(knownGood: values)
        var invalid = values
        invalid.inferenceLimit = 0
        #expect(await asyncSettingsProblem { _ = try await store.save(invalid, expectedStamp: opened.stamp) { _ in calls += 1 } }
            == .invalidValue("inferenceLimit"))
        var changed = values
        changed.live = true
        try fixture.write(changed)
        #expect(await asyncSettingsProblem { _ = try await store.save(values, expectedStamp: opened.stamp) { _ in calls += 1 } }
            == .init(.changed))
        try fixture.write("{")
        let broken = store.load(knownGood: values)
        #expect(await asyncSettingsProblem { _ = try await store.save(values, expectedStamp: broken.stamp) { _ in calls += 1 } }
            == .init(.recoveryRequired))
        #expect(calls == 0)
        #expect(try fixture.contents() == Data("{".utf8))
    }

    @Test("一時ファイルを書けなければ公開処理を呼ばず設定を変えない")
    func stagingFailureNeverCallsPublish() async throws {
        try fixture.write(values)
        let failing = DesktopSettingsFileStore(fileURL: fixture.fileURL, operations: .init(
            writeStagedFile: { _, _ in throw SyntheticFailure() }, replaceFile: SystemSettingsFiles.replaceFile(_:to:)
        ))
        var calls = 0
        #expect(await asyncSettingsProblem { _ = try await failing.save(values, expectedStamp: nil) { _ in calls += 1 } }
            == .init(.writeFailed))
        #expect(calls == 0)
        #expect(try fixture.savedSettings() == values)
        #expect(try fixture.files(withPrefix: ".settings-").isEmpty)
    }

    @Test("復旧の公開に失敗したら元のファイルを戻し再試行で退避できる")
    func failedRecoveryPublishRestoresTheOriginalAndCanBeRetried() async throws {
        let original = Data("{ synthetic broken JSON".utf8)
        try original.write(to: fixture.fileURL)
        let opened = store.load(knownGood: values)
        await #expect(throws: SyntheticFailure.self) {
            _ = try await store.save(values, expectedStamp: opened.stamp, recover: true) { _ in throw SyntheticFailure() }
        }
        #expect(try fixture.contents() == original)
        #expect(store.load(knownGood: values).stamp == opened.stamp)
        let saved = try await store.save(values, expectedStamp: opened.stamp, recover: true) { try store.install($0) }
        #expect(try Data(contentsOf: try #require(saved.recoveredFileURL)) == original)
        #expect(try fixture.savedSettings() == values)
    }

    #if !os(Windows)
    private func permissions(of url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    private func inode(of url: URL) throws -> UInt64 {
        var status = stat()
        try #require(stat(url.path, &status) == 0)
        return UInt64(status.st_ino)
    }
    #endif
}
