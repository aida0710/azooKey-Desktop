import Foundation

/// The report a support page copies for a public issue. It is an explicit
/// allowlist: each platform passes only recognized environment values, never
/// typed text, dictionary contents, prompt history or API keys.
public struct SupportDiagnostics: Equatable, Sendable {
    public enum Renderer: String, Sendable {
        case macTree = "mac-tree"
        case macList = "mac-list"
        case gtkTree = "gtk-tree"
        case shellTree = "shell-tree"
        case ibusList = "ibus-list"
        case windowsTree = "windows-tree"
        case windowsList = "windows-list"
    }

    /// Why the plain list is shown instead of the tree.
    public enum Fallback: String, Sendable {
        case setting
        case gnomeExtension = "extension"
        case unavailable
    }

    public enum Value: Equatable, Sendable {
        /// A recognized value, or `nil` for one that could not be verified.
        case text(String?)
        /// A message key from Shared/Messages.
        case message(String)
    }

    public struct Field: Equatable, Sendable {
        public let labelKey: String
        public let value: Value

        public init(labelKey: String, value: Value) {
            self.labelKey = labelKey
            self.value = value
        }
    }

    public let fields: [Field]

    public init(fields: [Field]) {
        self.fields = fields
    }

    /// `language` selects the support page's language; `nil` uses the process locale.
    public func report(language: Localization.Language? = nil) -> String {
        func localized(_ key: String) -> String {
            language.map { Localization.text(key, language: $0) } ?? Localization.text(key)
        }
        let lines = fields.map { field in
            let value: String
            switch field.value {
            case .text(let text?):
                value = text
            case .text(nil):
                value = localized("support.unknown")
            case .message(let key):
                value = localized(key)
            }
            return "\(localized(field.labelKey)): \(value)"
        }
        return (["azooKey Tree"] + lines).joined(separator: "\n")
    }

    /// `renderer` is `nil` when the platform cannot tell which renderer is active.
    static func rendererFields(renderer: Renderer?, fallback: Fallback?) -> [Field] {
        [
            Field(labelKey: "support.renderer", value: renderer.map { .message("support.renderer.\($0.rawValue)") } ?? .text(nil)),
            Field(labelKey: "support.fallback", value: .message(fallback.map { "support.fallback.\($0.rawValue)" } ?? "support.none"))
        ]
    }

    public static func macOS(
        version: String?, source: String?, operatingSystem: String, cpu: String?, backend: String?, treeEnabled: Bool
    ) -> Self {
        let fields = [
            Field(labelKey: "support.version", value: .text(version)),
            Field(labelKey: "support.source", value: .text(source)),
            Field(labelKey: "support.os", value: .text(operatingSystem)),
            Field(labelKey: "support.cpu", value: .text(cpu)),
            Field(labelKey: "support.backend", value: .text(backend)),
            Field(labelKey: "support.session", value: .text("AppKit"))
        ]
        return .init(fields: fields + rendererFields(renderer: treeEnabled ? .macTree : .macList,
                                                     fallback: treeEnabled ? nil : .setting))
    }
}
