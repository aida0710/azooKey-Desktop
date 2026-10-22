import Foundation

/// Reads and writes the settings file's document. A document may name only
/// some settings; the others keep the values Core already trusts.
public enum DesktopSettingsDocument {
    public static func settings(from data: Data, over knownGood: DesktopSettings) throws -> DesktopSettings {
        let document: DesktopSettingsJSON
        do {
            document = try DesktopSettingsJSONText.parse(data)
        } catch let failure as DesktopSettingsJSONText.Failure {
            throw DesktopSettingsProblem(failure)
        }
        return try settings(from: document, over: knownGood)
    }

    public static func settings(from document: DesktopSettingsJSON, over knownGood: DesktopSettings) throws -> DesktopSettings {
        var settings = knownGood
        try settings.merge(document)
        try settings.validate()
        return settings
    }

    public static func data(for settings: DesktopSettings) -> Data {
        DesktopSettingsJSONText.serialize(settings.json)
    }
}
