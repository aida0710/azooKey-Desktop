import Core
import Foundation

/// The `ai-transform-*` operations. The platform opens a transformation for
/// the current selection, reports facts and witness reads, performs the AI
/// request Core describes, and asks Core before applying anything.
extension DesktopAIController {
    func transformationResponse(to operation: String, ai: DesktopAIRequest, context: String) throws -> DesktopAITransformationResponse {
        if operation == "ai-transform-open" {
            return open(field: try Self.required(ai.field), context: context)
        }
        let identifier = try Self.required(ai.transformation)
        guard var transformation = transformations[context], transformation.id == identifier else {
            return DesktopAITransformationResponse(transformation: identifier, stale: true)
        }
        var response = DesktopAITransformationResponse(transformation: identifier)
        try apply(operation, ai: ai, to: &transformation, response: &response)
        transformations[context] = operation == "ai-transform-close" ? nil : transformation
        return response
    }

    private func apply(_ operation: String, ai: DesktopAIRequest, to transformation: inout AISelectedTextTransformation,
                       response: inout DesktopAITransformationResponse) throws {
        switch operation {
        case "ai-transform-target":
            response.targetAvailable = transformation.attachWitness(ai.witness, current: try Self.required(ai.field))
        case "ai-transform-preview":
            try beginPreview(&transformation, ai: ai, response: &response)
        case "ai-transform-result":
            response.accepted = transformation.completePreview(
                revision: try Self.required(ai.revision), text: ai.text, inputContextChanged: ai.inputContextChanged ?? false
            )
            response.text = transformation.applicableText
            response.targetAvailable = transformation.isTargetAvailable
        case "ai-transform-invalidate":
            transformation.invalidatePreview()
        case "ai-transform-confirm":
            response.confirmed = transformation.confirm()
        case "ai-transform-check":
            response.matches = transformation.checkReturn(to: try Self.required(ai.field))
        case "ai-transform-take":
            response.replacement = transformation.takeReplacement(for: try Self.required(ai.field), witness: ai.witness)
        case "ai-transform-reject":
            transformation.discardTarget()
            response.targetAvailable = false
        case "ai-transform-close":
            break
        default:
            throw BridgeMain.ProtocolError.invalidRequest
        }
    }

    private func open(field: AITextField, context: String) -> DesktopAITransformationResponse {
        transformations[context] = nil
        guard let transformation = AISelectedTextTransformation(
            id: nextIdentifier(), field: field, configuration: .current()
        ) else {
            return DesktopAITransformationResponse()
        }
        transformations[context] = transformation
        return DesktopAITransformationResponse(
            transformation: transformation.id, target: transformation.content.target,
            destination: transformation.content.destination,
            includeContext: transformation.content.includesContextByDefault,
            needsWitness: transformation.needsWitness, contextCharacters: AITextSelection.contextScalarLimit,
            history: promptHistory.load().map {
                .init(prompt: $0.prompt, pinned: $0.pinned, shortcutText: DesktopShortcutText.text(for: $0.shortcut))
            }
        )
    }

    /// The instruction is kept in the history before the request starts, as
    /// it was typed even if the request later fails.
    private func beginPreview(_ transformation: inout AISelectedTextTransformation, ai: DesktopAIRequest,
                              response: inout DesktopAITransformationResponse) throws {
        let prompt = try Self.required(ai.prompt)
        let includeContext = try Self.required(ai.includeContext)
        let field = try Self.required(ai.field)
        if let refusal = transformation.refusal(forPrompt: prompt) {
            response.previewRefusal = refusal
            return
        }
        do {
            let shortcut = try DesktopShortcutText.parse(ai.shortcutText ?? "")
            try promptHistory.save(AISelectedTextTransformation.instruction(prompt), pinned: ai.pinned ?? false, shortcut: shortcut)
        } catch let failure as DesktopShortcutText.Failure {
            response.historyError = failure.rawValue
            return
        } catch let failure as AIPromptHistory.Failure {
            response.historyError = failure.rawValue
            return
        } catch {
            response.historyError = AIPromptHistory.Failure.saveFailed.rawValue
            return
        }
        let started = try transformation.beginPreview(prompt: prompt, includeContext: includeContext, field: field)
        response.revision = started.revision
        response.request = started.arguments
    }

    private static func required<Value>(_ value: Value?) throws -> Value {
        guard let value else {
            throw BridgeMain.ProtocolError.invalidRequest
        }
        return value
    }
}
