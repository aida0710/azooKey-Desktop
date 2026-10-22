import Foundation

/// The review shown before AI suggestions are requested for a composition.
/// Nothing is sent until the user confirms, and a confirmation counts only
/// while the reviewed composition is unchanged.
public struct AISuggestionReview: Sendable {
    /// Asks AI to continue the text when nothing has been composed yet.
    public static let continuationTarget = "つづき"
    /// Return, typing and other keys are left to ordinary input.
    public static let keyBindings: [DesktopKeyBinding] = [
        DesktopKeyBinding(key: "s", modifiers: [.control], command: .send),
        DesktopKeyBinding(key: "s", modifiers: [.control, .shift], command: .toggleContext),
        DesktopKeyBinding(keyCode: 53, modifiers: [], command: .cancel)
    ]

    public let id: Int
    public let content: AIReviewContent
    public let generation: Int
    public let reading: String

    public init(id: Int, reading: String, generation: Int, before: String, after: String, configuration: AIDesktopConfiguration) {
        self.id = id
        self.generation = generation
        self.reading = reading
        self.content = AIReviewContent(
            target: reading.isEmpty ? Self.continuationTarget : reading, before: before, after: after,
            modelName: configuration.modelName, endpoint: configuration.endpoint,
            includesContextByDefault: configuration.includesContext
        )
    }

    public func isCurrent(generation: Int, reading: String) -> Bool {
        self.generation == generation && self.reading.hasSameScalars(as: reading)
    }
}
