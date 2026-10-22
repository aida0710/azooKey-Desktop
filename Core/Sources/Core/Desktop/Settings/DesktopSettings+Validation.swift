import Foundation

/// Rules a whole settings value must satisfy before it is saved or applied.
extension DesktopSettings {
    public static let inferenceLimitRange = 1...100
    /// Counted in Characters, so a combining sequence counts once.
    public static let maximumProfileLength = 4096
    /// Shift, Control, Option and Command; other bits have no meaning.
    static let shortcutModifierMask = 15
    static let endpointSchemes: Set<String> = ["http", "https"]

    public func validate() throws {
        guard Self.inferenceLimitRange.contains(inferenceLimit) else {
            throw DesktopSettingsProblem.invalidValue("inferenceLimit")
        }
        guard profile.count <= Self.maximumProfileLength else {
            throw DesktopSettingsProblem.invalidValue("profile")
        }
        guard Self.isEndpoint(aiEndpoint) else {
            throw DesktopSettingsProblem.invalidValue("aiEndpoint")
        }
        guard !transformShortcut.key.isEmpty else {
            throw DesktopSettingsProblem.invalidValue("transformShortcut.key")
        }
        let modifiers = transformShortcut.modifiers.rawValue
        guard modifiers >= 0, modifiers & ~Self.shortcutModifierMask == 0 else {
            throw DesktopSettingsProblem.invalidValue("transformShortcut.modifiers")
        }
        try validateDictionary()
        guard inputStyle != .custom || !customTable.isEmpty else {
            throw DesktopSettingsProblem.invalidValue("customTable")
        }
    }

    private func validateDictionary() throws {
        var identifiers: Set<UUID> = []
        for (index, entry) in userDictionary.items.enumerated() {
            let path = "userDictionary.items[\(index)]."
            guard !entry.reading.isEmpty else {
                throw DesktopSettingsProblem.invalidValue(path + "reading")
            }
            guard !entry.word.isEmpty else {
                throw DesktopSettingsProblem.invalidValue(path + "word")
            }
            guard identifiers.insert(entry.id).inserted else {
                throw DesktopSettingsProblem.invalidValue(path + "id")
            }
        }
    }

    private static func isEndpoint(_ text: String) -> Bool {
        guard let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host else {
            return false
        }
        return endpointSchemes.contains(scheme) && !host.isEmpty
    }
}
