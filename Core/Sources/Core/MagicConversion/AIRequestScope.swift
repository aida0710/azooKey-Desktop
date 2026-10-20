import Foundation

/// The only document text allowed into an AI request.
public struct AIRequestScope: Sendable {
    // A small, consistent context window is shown in both desktop interfaces.
    public static let contextCharacterLimit = 100
    public let target: String
    public let before: String
    public let after: String
    public let includeContext: Bool

    public init(target: String, before: String = "", after: String = "", includeContext: Bool) {
        self.target = target
        self.includeContext = includeContext
        self.before = includeContext ? String(before.suffix(Self.contextCharacterLimit)) : ""
        self.after = includeContext ? String(after.prefix(Self.contextCharacterLimit)) : ""
    }

    public var suggestionContext: String {
        [
            before.isEmpty ? nil : "Text before: ...\(before)",
            after.isEmpty ? nil : "Text after: \(after)..."
        ].compactMap(\.self).joined(separator: "\n")
    }

    public func transformationPrompt(instructions: String) -> String {
        var prompt = """
        Transform the given text according to the user's instructions.
        Return only the transformed text without any additional explanation or formatting.
        """
        if !suggestionContext.isEmpty {
            prompt += "\n\nContext information:\n\(suggestionContext)"
        }
        prompt += "\n\nText to transform: \(target)"
        prompt += "\n\nUser instructions: \(instructions)"
        return prompt
    }
}
