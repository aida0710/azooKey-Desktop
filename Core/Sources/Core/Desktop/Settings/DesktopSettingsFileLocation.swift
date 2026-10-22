import Foundation

/// Where each platform keeps the settings file.
public enum DesktopSettingsFileLocation {
    public static func settingsFileURL(
        platform: DesktopPlatform = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        switch platform {
        case .windows:
            let applicationData = nonEmpty(environment["APPDATA"]).map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? homeDirectory.appendingPathComponent("AppData/Roaming", isDirectory: true)
            return applicationData.appendingPathComponent("azooKey Tree/settings.json")
        case .linux, .macOS:
            // The macOS app keeps its preferences in the app group instead;
            // the desktop bridge uses the XDG location on every Unix.
            let configuration = nonEmpty(environment["XDG_CONFIG_HOME"]).map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? homeDirectory.appendingPathComponent(".config", isDirectory: true)
            return configuration.appendingPathComponent("azookey-tree/settings.json")
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        value?.isEmpty == false ? value : nil
    }
}
