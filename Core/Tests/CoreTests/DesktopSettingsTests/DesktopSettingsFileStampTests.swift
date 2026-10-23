import Foundation
#if os(Linux)
import Glibc
#endif
import Testing

@testable import Core

#if !os(Windows)
@Suite("設定ファイルの版の検出")
struct DesktopSettingsFileStampTests {
    let fixture: DesktopSettingsFixture

    init() throws {
        fixture = try DesktopSettingsFixture()
    }

    @Test("存在しないファイルだけを absent とし同じファイルの印は変わらない")
    func missingFileIsAbsentAndUnchangedFileKeepsItsStamp() throws {
        #expect(DesktopSettingsFileStamp.read(fixture.fileURL) == .absent)
        try fixture.write("{}")
        let stamp = DesktopSettingsFileStamp.read(fixture.fileURL)
        #expect(stamp.token.hasPrefix("file:"))
        #expect(DesktopSettingsFileStamp.read(fixture.fileURL) == stamp)
    }

    @MainActor
    @Test("サイズと更新日時を保って置き換えても古い画面からの保存を拒否する")
    func replacementWithSameSizeAndModificationDateRejectsStaleSave() async throws {
        try fixture.write(DesktopSettingsFixture.known)
        // Whole seconds keep date rounding from making the replacement appear newer.
        let modified = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: fixture.fileURL.path)
        let store = DesktopSettingsFileStore(fileURL: fixture.fileURL)
        let opened = store.load(knownGood: .defaults)
        let replacement = fixture.directoryURL.appendingPathComponent("replacement.json")
        try fixture.contents().write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: replacement.path)
        let replacementAttributes = try FileManager.default.attributesOfItem(atPath: replacement.path)
        #expect(replacementAttributes[.modificationDate] as? Date == modified)
        #expect(try replacementAttributes[.size] as? Int == fixture.contents().count)
        try PlatformFileOperations.replaceFile(replacement, to: fixture.fileURL)
        #expect(DesktopSettingsFileStamp.read(fixture.fileURL) != opened.stamp)
        #expect(await asyncSettingsProblem {
            _ = try await store.save(opened.values, expectedStamp: opened.stamp) { try store.install($0) }
        } == .init(.changed))
    }

    @Test("相対リンクをたどりリンク先が置き換わると印も変わる")
    func relativeLinkTracksItsTargetReplacement() throws {
        try fixture.write("{}")
        let link = fixture.directoryURL.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "settings.json")
        let opened = DesktopSettingsFileStamp.read(link)
        #expect(opened == DesktopSettingsFileStamp.read(fixture.fileURL))
        let replacement = fixture.directoryURL.appendingPathComponent("replacement.json")
        try Data("[]".utf8).write(to: replacement)
        try PlatformFileOperations.replaceFile(replacement, to: fixture.fileURL)
        #expect(DesktopSettingsFileStamp.read(link) != opened)
        #expect(DesktopSettingsFileStamp.read(link) == DesktopSettingsFileStamp.read(fixture.fileURL))
    }

    @Test("リンク先が消えても absent にならず復元されるとファイルの印に戻る")
    func brokenLinkKeepsALinkStampUntilItsTargetReturns() throws {
        let link = fixture.directoryURL.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.fileURL)
        #expect(DesktopSettingsFileStamp.read(link).token.hasPrefix("link:"))
        try fixture.write("{}")
        #expect(DesktopSettingsFileStamp.read(link) == DesktopSettingsFileStamp.read(fixture.fileURL))
        try FileManager.default.removeItem(at: fixture.fileURL)
        #expect(DesktopSettingsFileStamp.read(link).token.hasPrefix("link:"))
    }

    @Test("循環するリンクは absent ではなく unreadable になる")
    func symbolicLinkLoopIsUnreadable() throws {
        try FileManager.default.createSymbolicLink(at: fixture.fileURL, withDestinationURL: fixture.fileURL)
        #expect(DesktopSettingsFileStamp.read(fixture.fileURL).token.hasPrefix("unreadable"))
    }

    @Test("ファイルを親ディレクトリに指定したパスは unreadable になる")
    func nonDirectoryParentIsUnreadable() throws {
        try fixture.write("{}")
        let child = fixture.fileURL.appendingPathComponent("child.json")
        #expect(DesktopSettingsFileStamp.read(child).token.hasPrefix("unreadable"))
    }

    @Test("権限だけが変わっても印が変わる")
    func permissionChangeUpdatesStamp() throws {
        try fixture.write("{}")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.fileURL.path)
        let opened = DesktopSettingsFileStamp.read(fixture.fileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.fileURL.path)
        #expect(DesktopSettingsFileStamp.read(fixture.fileURL) != opened)
    }

    #if os(Linux)
    @Test("親ディレクトリへのアクセスが拒否されたら unreadable になる", .enabled(if: geteuid() != 0))
    func inaccessibleParentIsUnreadable() throws {
        try fixture.write("{}")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directoryURL.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: fixture.directoryURL.path)
        #expect(DesktopSettingsFileStamp.read(fixture.fileURL).token.hasPrefix("unreadable"))
    }
    #endif
}
#endif
