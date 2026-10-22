import Foundation

/// Core's side of one selected-text AI transformation: what is sent, which
/// preview is current, and whether a confirmed result may replace the
/// original selection. The platform reports facts about the field, performs
/// the request and the witness reads, and shows the results.
public struct AISelectedTextTransformation: Sendable {
    public enum PreviewRefusal: String, Error, Codable, Sendable {
        /// The instruction is blank.
        case emptyPrompt
        /// The current preview is still being generated.
        case loading
    }

    public let id: Int
    public let content: AIReviewContent
    /// A fresh selection from a named field; only this can become a target.
    private let capturedSelection: AITextSelection?
    private let isAIEnabled: Bool
    public private(set) var target: AITransformationTarget?
    private var preview = AITransformationPreview()
    private var currentRequest: (revision: Int, request: AITransformationPreview.Request)?
    private var lastRevision = 0
    /// The result the user chose to apply; it is handed out at most once.
    private var confirmedReplacement: String?

    /// nil when nothing is selected or the field is sensitive.
    public init?(id: Int, field: AITextField, configuration: AIDesktopConfiguration) {
        guard !field.isSensitive, let surrounding = field.surrounding,
              let selection = AITextSelection(identity: nil, surrounding: surrounding) else {
            return nil
        }
        self.id = id
        self.content = AIReviewContent(
            target: selection.selected, before: selection.before, after: selection.after,
            modelName: configuration.modelName, endpoint: configuration.endpoint,
            includesContextByDefault: configuration.includesContext
        )
        self.capturedSelection = field.currentSelection
        self.isAIEnabled = configuration.isEnabled
    }

    /// Whether reading a witness can produce a target at all.
    public var needsWitness: Bool { capturedSelection != nil }
    public var isTargetAvailable: Bool { target != nil }
    public var isLoading: Bool { preview.isLoading }
    public var applicableText: String? { preview.applicableText }

    /// Records the original target when the witness confirms the selection
    /// that was captured and the field still reports it.
    @discardableResult
    public mutating func attachWitness(_ witness: AISelectionWitness?, current: AITextField) -> Bool {
        target = capturedSelection.flatMap { AITransformationTarget(captured: $0, current: current, witness: witness) }
        return isTargetAvailable
    }

    /// Why `prompt` cannot start a preview now. Checked before the prompt is
    /// saved to the history, so a refused submission leaves no trace.
    public func refusal(forPrompt prompt: String) -> PreviewRefusal? {
        if Self.instruction(prompt).isEmpty {
            return .emptyPrompt
        }
        return preview.isLoading ? .loading : nil
    }

    /// Starts a new preview and invalidates the previous one. nil arguments
    /// mean the request may not be sent; the preview has already failed.
    public mutating func beginPreview(prompt: String, includeContext: Bool, field: AITextField) throws(PreviewRefusal)
        -> (revision: Int, arguments: AIRequestArguments?) {
        if let refusal = refusal(forPrompt: prompt) {
            throw refusal
        }
        let instruction = Self.instruction(prompt)
        lastRevision += 1
        let request = preview.begin()
        currentRequest = (lastRevision, request)
        guard isAIEnabled, !field.isSensitive else {
            preview.complete(nil, for: request)
            currentRequest = nil
            return (lastRevision, nil)
        }
        return (lastRevision, content.arguments(includeContext: includeContext, prompt: instruction))
    }

    /// Accepts only the current preview's result. A result that arrives after
    /// the input focus changed stays copyable but may no longer be applied.
    @discardableResult
    public mutating func completePreview(revision: Int, text: String?, inputContextChanged: Bool) -> Bool {
        guard let current = currentRequest, current.revision == revision,
              preview.complete(text, for: current.request) else {
            return false
        }
        currentRequest = nil
        if inputContextChanged {
            discardTarget()
        }
        return true
    }

    /// The instruction or the included context changed.
    public mutating func invalidatePreview() {
        preview.invalidate()
        currentRequest = nil
    }

    /// The user chose to apply the current result to the original selection.
    @discardableResult
    public mutating func confirm() -> Bool {
        guard confirmedReplacement == nil else {
            return true
        }
        guard target != nil, let text = preview.applicableText else {
            return false
        }
        confirmedReplacement = text
        return true
    }

    /// Whether the focused field may still be the original target, before a
    /// witness read is spent on it. A contradicting report ends the target.
    public mutating func checkReturn(to field: AITextField) -> Bool {
        guard confirmedReplacement != nil, let target else {
            return false
        }
        guard target.isOriginal(field) else {
            discardTarget()
            return false
        }
        return true
    }

    /// The confirmed result, once, when the field and a fresh witness both
    /// still describe the original selection.
    public mutating func takeReplacement(for field: AITextField, witness: AISelectionWitness?) -> String? {
        guard let replacement = confirmedReplacement, let target else {
            return nil
        }
        confirmedReplacement = nil
        guard target.matches(field, witness: witness) else {
            discardTarget()
            return nil
        }
        return replacement
    }

    /// The original target can no longer be trusted; the preview stays copyable.
    public mutating func discardTarget() {
        target = nil
        confirmedReplacement = nil
    }

    /// The stored and sent instruction, without surrounding blanks.
    public static func instruction(_ prompt: String) -> String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
