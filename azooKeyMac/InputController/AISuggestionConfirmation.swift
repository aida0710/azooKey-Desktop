import Core
import Foundation

/// A suggestion review on macOS: Core's review of the composition, the input
/// client it was opened for, and the backend that will receive it.
struct AISuggestionConfirmation {
    // macOS keeps one review per input controller and closes it on any other
    // key, so it needs neither review identifiers nor composition generations;
    // the reading, the client and its selection are compared instead.
    private static let reviewIdentifier = 0
    static let compositionGeneration = 0

    let review: AISuggestionReview
    let clientIdentity: ObjectIdentifier
    let selectedRange: NSRange
    /// The backend and the API key. The model and endpoint are the review's.
    let configuration: AIRequestConfiguration
    var includeContext: Bool

    init(reading: String, surrounding: (before: String, after: String), clientIdentity: ObjectIdentifier,
         selectedRange: NSRange, configuration: AIRequestConfiguration) {
        self.review = AISuggestionReview(
            id: Self.reviewIdentifier, reading: reading, generation: Self.compositionGeneration,
            before: surrounding.before, after: surrounding.after, configuration: configuration.desktopConfiguration()
        )
        self.clientIdentity = clientIdentity
        self.selectedRange = selectedRange
        self.configuration = configuration
        self.includeContext = review.content.includesContextByDefault
    }

    func isCurrent(reading: String) -> Bool {
        review.isCurrent(generation: Self.compositionGeneration, reading: reading)
    }

    /// Exactly the reviewed text, destination and model; the surrounding text
    /// only when it is included.
    func suggestionRequest() -> AISuggestionRequest {
        review.content.arguments(includeContext: includeContext)
            .suggestionRequest(backend: configuration.backend, apiKey: configuration.apiKey)
    }
}
