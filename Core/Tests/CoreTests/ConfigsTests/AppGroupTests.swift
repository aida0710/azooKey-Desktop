import Foundation
import Testing

@testable import Core

#if os(macOS)
@Suite("AppGroup")
struct AppGroupTests {
    @Test("standalone配布は共有コンテナAPIを使わず自身のsandboxへ保存する")
    func standaloneStorageDoesNotRequestSharedAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = SandboxFileManager(home: root)
        let support = AppGroup.applicationSupportDirectoryURL(fileManager: manager, shared: false)
        #expect(support.path == root.appendingPathComponent("Library/Application Support/azooKey").path)
        try manager.createDirectory(at: support, withIntermediateDirectories: true)
        let fixture = support.appendingPathComponent("storage-test")
        try Data("test".utf8).write(to: fixture, options: .atomic)
        #expect(try String(contentsOf: fixture, encoding: .utf8) == "test")
        #expect(manager.sharedAccessCount == 0)
        #expect(AppGroup.preferences(shared: false) === UserDefaults.standard)
    }

    @Test("entitlementのないHelper向け共有コンテナURLを解決する")
    func resolveContainerURLFromHomeDirectory() {
        let homeDirectoryURL = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        #expect(
            AppGroup.containerURL(homeDirectoryURL: homeDirectoryURL).path
                == "/Users/example/Library/Group Containers/group.dev.ensan.inputmethod.azooKeyMac"
        )
    }
}

private final class SandboxFileManager: FileManager, @unchecked Sendable {
    let home: URL
    var sharedAccessCount = 0
    init(home: URL) {
        self.home = home
        super.init()
    }
    override var homeDirectoryForCurrentUser: URL { home }
    override func containerURL(forSecurityApplicationGroupIdentifier identifier: String) -> URL? {
        sharedAccessCount += 1
        return nil
    }
}
#endif
