import Foundation

/// What a settings screen needs to build itself on one platform: each
/// setting's control, choices, default and message keys, and the pages that
/// order settings, explanations and buttons.
public struct DesktopSettingsSchema: Encodable, Sendable {
    public let platform: DesktopPlatform
    public let items: [DesktopSettingItem]
    public let pages: [DesktopSettingsPage]

    public init(platform: DesktopPlatform = .current) {
        self.platform = platform
        self.items = DesktopSettingsItems.all.map { $0.resolved(for: platform) }
        self.pages = DesktopSettingsPages.pages(for: platform)
    }

    public func item(_ key: String) -> DesktopSettingItem? {
        items.first { $0.key == key }
    }
}

/// One setting. Labels and explanations are message keys; every platform
/// looks them up in its own catalog.
public struct DesktopSettingItem: Encodable, Sendable {
    public enum Control: String, Encodable, Sendable {
        case toggle
        case choice
        case integer
        case text
        case multilineText
        case shortcut
        /// Edited and saved in a screen of its own; the page shows a button.
        case dictionary
    }

    public struct Choice: Encodable, Sendable {
        public let value: DesktopSettingsJSON
        public let labelKey: String
    }

    public let key: String
    public let control: Control
    public let labelKey: String
    public let descriptionKey: String?
    public let choices: [Choice]
    public let range: ClosedRange<Int>?
    public let maximumCharacters: Int?
    /// A letter for the platform's keyboard access key, where it has one.
    public let accessKey: String?
    /// Restoring "input and display defaults" resets this setting.
    public let resetsToInputDefault: Bool
    /// Restoring from the last good copy keeps the current value, so an older
    /// copy cannot bring back an old dictionary or AI choice.
    public let keptOnRecovery: Bool
    let unavailableReasons: [DesktopPlatform: String]
    public private(set) var unavailableReasonKey: String?

    init(
        key: String, control: Control, labelKey: String, descriptionKey: String? = nil,
        choices: [Choice] = [], range: ClosedRange<Int>? = nil, maximumCharacters: Int? = nil,
        accessKey: String? = nil, resetsToInputDefault: Bool = false, keptOnRecovery: Bool = false,
        unavailableReasons: [DesktopPlatform: String] = [:]
    ) {
        self.key = key
        self.control = control
        self.labelKey = labelKey
        self.descriptionKey = descriptionKey
        self.choices = choices
        self.range = range
        self.maximumCharacters = maximumCharacters
        self.accessKey = accessKey
        self.resetsToInputDefault = resetsToInputDefault
        self.keptOnRecovery = keptOnRecovery
        self.unavailableReasons = unavailableReasons
    }

    public var isAvailable: Bool {
        unavailableReasonKey == nil
    }

    public var defaultValue: DesktopSettingsJSON {
        DesktopSettings.defaults.value(forKey: key)
    }

    func resolved(for platform: DesktopPlatform) -> DesktopSettingItem {
        var item = self
        item.unavailableReasonKey = unavailableReasons[platform]
        return item
    }

    private enum CodingKeys: String, CodingKey {
        case key, control, labelKey, descriptionKey, choices, minimum, maximum, maximumCharacters, accessKey
        case resetsToInputDefault, keptOnRecovery, available, unavailableReasonKey
        case defaultValue = "default"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(control, forKey: .control)
        try container.encode(labelKey, forKey: .labelKey)
        try container.encodeIfPresent(descriptionKey, forKey: .descriptionKey)
        if !choices.isEmpty {
            try container.encode(choices, forKey: .choices)
        }
        try container.encodeIfPresent(range?.lowerBound, forKey: .minimum)
        try container.encodeIfPresent(range?.upperBound, forKey: .maximum)
        try container.encodeIfPresent(maximumCharacters, forKey: .maximumCharacters)
        try container.encodeIfPresent(accessKey, forKey: .accessKey)
        try container.encode(defaultValue, forKey: .defaultValue)
        try container.encode(resetsToInputDefault, forKey: .resetsToInputDefault)
        try container.encode(keptOnRecovery, forKey: .keptOnRecovery)
        try container.encode(isAvailable, forKey: .available)
        try container.encodeIfPresent(unavailableReasonKey, forKey: .unavailableReasonKey)
    }
}

/// A button that starts work outside the settings document.
public struct DesktopSettingsAction: Encodable, Sendable {
    public let id: String
    public let labelKey: String
    public let unavailableReasonKey: String?

    public var isAvailable: Bool {
        unavailableReasonKey == nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, labelKey, available, unavailableReasonKey
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(labelKey, forKey: .labelKey)
        try container.encode(isAvailable, forKey: .available)
        try container.encodeIfPresent(unavailableReasonKey, forKey: .unavailableReasonKey)
    }
}

/// A value kept by the platform's credential store, never in the settings file.
public struct DesktopSettingsSecret: Encodable, Sendable {
    public let id: String
    public let labelKey: String
    public let placeholderKey: String
    public let descriptionKey: String
    public let accessKey: String
}

/// One tab of the settings screen.
public struct DesktopSettingsPage: Encodable, Sendable {
    public enum Element: Encodable, Sendable {
        case setting(key: String)
        case note(textKey: String)
        case action(DesktopSettingsAction)
        case secret(DesktopSettingsSecret)
        /// The platform's diagnostics and support information.
        case support

        private enum CodingKeys: String, CodingKey {
            case kind, key, textKey, action, secret
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .setting(let key):
                try container.encode("setting", forKey: .kind)
                try container.encode(key, forKey: .key)
            case .note(let textKey):
                try container.encode("note", forKey: .kind)
                try container.encode(textKey, forKey: .textKey)
            case .action(let action):
                try container.encode("action", forKey: .kind)
                try container.encode(action, forKey: .action)
            case .secret(let secret):
                try container.encode("secret", forKey: .kind)
                try container.encode(secret, forKey: .secret)
            case .support:
                try container.encode("support", forKey: .kind)
            }
        }
    }

    public let id: String
    public let titleKey: String
    public let elements: [Element]
}
