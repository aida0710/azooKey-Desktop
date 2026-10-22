import Core
import Foundation

/// The `ai-transform-*` operations. The platform opens a transformation for
/// the current selection, reports facts and witness reads, performs the AI
/// request Core describes, and asks Core before applying anything.
extension DesktopAIController {
    func transformationResponse(to operation: String, ai: DesktopAIRequest, context: String) throws -> DesktopAITransformationResponse {
        if operation == "ai-transform-open" {
            guard let field = ai.field else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            return open(field: field, context: context)
        }
        guard let identifier = ai.transformation else {
            throw BridgeMain.ProtocolError.invalidRequest
        }
        guard var transformation = transformations[context], transformation.id == identifier else {
            return DesktopAITransformationResponse(transformation: identifier, stale: true)
        }
        defer {
            if operation == "ai-transform-close" {
                transformations[context] = nil
            } else {
                transformations[context] = transformation
            }
        }
        var response = DesktopAITransformationResponse(transformation: identifier)
        switch operation {
        case "ai-transform-target":
            guard let field = ai.field else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            response.targetAvailable = transformation.attachWitness(ai.witness, current: field)
        case "ai-transform-preview":
            guard let prompt = ai.prompt, let includeContext = ai.includeContext, let field = ai.field else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            beginPreview(&transformation, prompt: prompt, includeContext: includeContext, field: field,
                         pinned: ai.pinned ?? false, shortcutText: ai.shortcutText ?? "", response: &response)
        case "ai-transform-result":
            guard let revision = ai.revision else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            response.accepted = transformation.completePreview(
                revision: revision, text: ai.text, inputContextChanged: ai.inputContextChanged ?? false
            )
            response.text = transformation.applicableText
            response.targetAvailable = transformation.isTargetAvailable
        case "ai-transform-invalidate":
            transformation.invalidatePreview()
        case "ai-transform-confirm":
            response.confirmed = transformation.confirm()
        case "ai-transform-check":
            guard let field = ai.field else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            response.matches = transformation.checkReturn(to: field)
        case "ai-transform-take":
            guard let field = ai.field else {
                throw BridgeMain.ProtocolError.invalidRequest
            }
            response.replacement = transformation.takeReplacement(for: field, witness: ai.witness)
        case "ai-transform-reject":
            transformation.discardTarget()
            response.targetAvailable = false
        case "ai-transform-close":
            break
        default:
            throw BridgeMain.ProtocolError.invalidRequest
        }
        return response
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
    private func beginPreview(_ transformation: inout AISelectedTextTransformation, prompt: String, includeContext: Bool,
                              field: AITextField, pinned: Bool, shortcutText: String,
                              response: inout DesktopAITransformationResponse) {
        if let refusal = transformation.refusal(forPrompt: prompt) {
            response.previewRefusal = refusal
            return
        }
        do {
            let shortcut = try DesktopShortcutText.parse(shortcutText)
            try promptHistory.save(AISelectedTextTransformation.instruction(prompt), pinned: pinned, shortcut: shortcut)
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
        guard let started = try? transformation.beginPreview(prompt: prompt, includeContext: includeContext, field: field) else {
            return
        }
        response.revision = started.revision
        response.request = started.arguments
    }
}
