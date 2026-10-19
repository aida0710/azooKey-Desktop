import Foundation

public enum AppGroup {
    public static let azooKeyMacIdentifier = "group.dev.ensan.inputmethod.azooKeyMac"

    #if os(macOS)
    /// Ad-hoc packages use their own sandbox; shared groups require an authorized signing team.
    public static var usesSharedContainer: Bool {
        Bundle.main.object(forInfoDictionaryKey: "AzooKeyStandaloneStorage") as? Bool != true
    }

    public static func preferences(shared: Bool = usesSharedContainer) -> UserDefaults {
        shared ? UserDefaults(suiteName: azooKeyMacIdentifier) ?? .standard : .standard
    }

    public static func containerURL(fileManager: FileManager = .default, shared: Bool = usesSharedContainer) -> URL? {
        guard shared else {
            return fileManager.homeDirectoryForCurrentUser
        }
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: Self.azooKeyMacIdentifier)
            ?? Self.containerURL(homeDirectoryURL: fileManager.homeDirectoryForCurrentUser)
    }

    /// 既存バージョンと同じ共有コンテナを、App Group APIが利用できない環境でも参照する。
    public static func containerURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent(Self.azooKeyMacIdentifier, isDirectory: true)
    }

    public static func applicationSupportDirectoryURL(fileManager: FileManager = .default, shared: Bool = usesSharedContainer) -> URL {
        if let containerURL = Self.containerURL(fileManager: fileManager, shared: shared) {
            return containerURL
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
                .appendingPathComponent("azooKey", isDirectory: true)
        }

        if #available(macOS 13, *) {
            return URL.applicationSupportDirectory
                .appending(path: "azooKey", directoryHint: .isDirectory)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("azooKey", isDirectory: true)
    }

    public static func memoryDirectoryURL(fileManager: FileManager = .default) -> URL {
        Self.applicationSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("memory", isDirectory: true)
    }
    #endif
}
