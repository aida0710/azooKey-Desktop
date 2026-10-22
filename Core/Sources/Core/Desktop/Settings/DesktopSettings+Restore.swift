import Foundation

/// Values a recovery writes back, chosen by the item flags in the schema.
extension DesktopSettings {
    /// Input and display preferences return to their defaults. Dictionaries,
    /// the custom table, learning, personalization, the profile and AI settings stay.
    public func resettingInputPreferences() -> DesktopSettings {
        var settings = self
        settings.copy(DesktopSettingsItems.all.filter(\.resetsToInputDefault).map(\.key), from: .defaults)
        return settings
    }

    /// Keeps `current`'s value for every setting an older copy must not bring back.
    func keepingRecoveryValues(of current: DesktopSettings) -> DesktopSettings {
        var settings = self
        settings.copy(DesktopSettingsItems.all.filter(\.keptOnRecovery).map(\.key), from: current)
        return settings
    }

    private mutating func copy(_ keys: [String], from source: DesktopSettings) {
        for key in keys {
            // A value read from DesktopSettings always has its setting's JSON type.
            try? setValue(source.value(forKey: key), forKey: key)
        }
    }
}
