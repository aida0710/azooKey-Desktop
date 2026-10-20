import Foundation

enum DesktopSettingsValidation {
    // Match the settings UI's existing conversion limits in every protocol.
    static let inferenceLimits = 1...100
    static let profileCharacters = 4096

    static func conversion(inferenceLimit: Int, profile: String) throws {
        guard inferenceLimits.contains(inferenceLimit), profile.count <= profileCharacters else {
            throw BridgeMain.ProtocolError.invalidRequest
        }
    }
}
