import Core
@testable import DesktopBridge
import Foundation
import Testing

/// The AI operations as a platform sends them: JSON facts in, decisions out.
@MainActor
@Suite struct DesktopAIControllerTests {
    static let endpoint = "https://user:secret@reviewed.example.invalid:8443/v1?key=private"

    func withController(aiEnabled: Bool = true,
                        _ test: (DesktopAIController, DesktopSession, AIPromptHistory) throws -> Void) throws {
        let saved = (Config.AIBackendPreference().value, Config.OpenAiModelName().value, Config.OpenAiApiEndpoint().value,
                     Config.IncludeContextInAITransform().value, Config.TransformShortcut().value, Config.LiveConversion().value,
                     Config.AIPromptLanguage().value)
        defer {
            Config.AIBackendPreference().value = saved.0
            Config.OpenAiModelName().value = saved.1
            Config.OpenAiApiEndpoint().value = saved.2
            Config.IncludeContextInAITransform().value = saved.3
            Config.TransformShortcut().value = saved.4
            Config.LiveConversion().value = saved.5
            Config.AIPromptLanguage().value = saved.6
        }
        Config.AIBackendPreference().value = aiEnabled ? .openAI : .off
        Config.OpenAiModelName().value = "reviewed-model"
        Config.OpenAiApiEndpoint().value = Self.endpoint
        Config.IncludeContextInAITransform().value = false
        Config.TransformShortcut().value = .defaultTransformShortcut
        Config.LiveConversion().value = false
        Config.AIPromptLanguage().value = .english
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ai-controller-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = AIPromptHistory(fileURL: directory.appendingPathComponent("config/prompts.json"))
        let session = try DesktopSession(dataDirectory: directory.appendingPathComponent("data"), resourcesDirectory: nil, useZenzai: false)
        defer { session.close() }
        try test(DesktopAIController(promptHistory: history), session, history)
    }

    func request(_ object: [String: Any]) throws -> BridgeRequest {
        try JSONDecoder().decode(BridgeRequest.self, from: JSONSerialization.data(withJSONObject: object))
    }

    func encoded(_ response: any Encodable) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
    }

    /// What BridgeMain sets on the session from every request before the operation runs.
    func applyRequestFacts(_ request: BridgeRequest, to session: DesktopSession) {
        session.privateInput = request.privateInput ?? false
        session.leftContext = String((request.leftContext ?? "").suffix(100))
        session.rightContext = String((request.rightContext ?? "").prefix(100))
        session.reconversionContext = request.reconversionContext
    }

    func keyEvent(_ characters: String, _ modifiers: KeyEventCore.ModifierFlag = [], keyCode: UInt16 = 0) -> [String: Any] {
        ["modifierFlags": modifiers.rawValue, "characters": characters, "charactersIgnoringModifiers": characters, "keyCode": keyCode]
    }

    func key(_ controller: DesktopAIController, _ session: DesktopSession, _ event: [String: Any], extra: [String: Any] = [:],
             context: String = "field") throws -> DesktopSnapshot {
        let request = try request(["operation": "key", "event": event].merging(extra) { $1 })
        applyRequestFacts(request, to: session)
        return controller.key(try #require(request.event), request: request, session: session, context: context)
    }

    func send(_ controller: DesktopAIController, _ session: DesktopSession, review: Int, includeContext: Bool,
              privateInput: Bool = false, context: String = "field") throws -> [String: Any] {
        let request = try request(["operation": "ai-review-send", "privateInput": privateInput,
                                   "ai": ["review": review, "includeContext": includeContext]])
        applyRequestFacts(request, to: session)
        return try encoded(try #require(try controller.sessionResponse(to: request, session: session, context: context)))
    }

    func transform(_ controller: DesktopAIController, _ operation: String, _ ai: [String: Any], context: String = "field") throws -> [String: Any] {
        let request = try request(["operation": "ai-transform-\(operation)", "ai": ai])
        return try encoded(try #require(try controller.response(to: request, context: context)))
    }

    static func field(_ text: String = "前 原文 後", cursor: Int = 4, anchor: Int = 2, sensitive: Bool = false) -> [String: Any] {
        ["identity": ["/input/1", "gtk3-im:fixture"], "surrounding": ["text": text, "cursorUTF16": cursor, "anchorUTF16": anchor],
         "hasSurroundingUpdate": true, "isSensitive": sensitive]
    }

    static let witness: [String: Any] = ["object": ["bus", ":1.4", "/field/1"], "window": [":1.4", "/window/1"],
                                         "start": 2, "end": 4, "before": "前 ", "selected": "原文", "after": " 後"]

    func typeNihongo(_ controller: DesktopAIController, _ session: DesktopSession) throws {
        for character in "nihongo" {
            _ = try key(controller, session, keyEvent(String(character)))
        }
    }

    // MARK: Suggestion review

    @Test func aSuggestionRequestOpensAReviewAndSendingUsesTheReviewedContent() throws {
        try withController { controller, session, _ in
            try typeNihongo(controller, session)
            let pending = try key(controller, session, keyEvent("s", .control),
                                  extra: ["leftContext": "PRIVATE_BEFORE", "rightContext": "PRIVATE_AFTER"])
            let review = try #require(pending.ai?.review)
            #expect(pending.request == "replace" && !pending.preedit.isEmpty)
            #expect(review.target == pending.reading)
            #expect(review.destination == "reviewed.example.invalid:8443" && !review.includeContext)
            #expect(review.bindings == AISuggestionReview.keyBindings)
            // A changed stored destination must not redirect the reviewed request.
            Config.OpenAiApiEndpoint().value = "http://127.0.0.1:1/unused"
            let sent = try send(controller, session, review: review.id, includeContext: false)
            let arguments = try #require(sent["request"] as? [String: Any])
            #expect(arguments["aiEndpoint"] as? String == Self.endpoint && arguments["aiModel"] as? String == "reviewed-model")
            #expect((arguments["leftContext"] as? String)?.isEmpty == true && (arguments["rightContext"] as? String)?.isEmpty == true)
            #expect(sent["generation"] as? Int == pending.generation && sent["reading"] as? String == pending.reading)
            #expect(try send(controller, session, review: review.id, includeContext: false)["request"] == nil, "sent once")
        }
    }

    @Test func sendingDoesNotDependOnTheSurroundingTextOfTheSendRequest() throws {
        try withController { controller, session, _ in
            for character in "nihongo" {
                _ = try key(controller, session, keyEvent(String(character)), extra: ["leftContext": "前の文"])
            }
            let review = try #require(try key(controller, session, keyEvent("s", .control), extra: ["leftContext": "前の文"]).ai?.review)
            // The send request carries no surrounding text, so the session's context is now empty.
            #expect(try send(controller, session, review: review.id, includeContext: false)["request"] != nil)
        }
    }

    @Test func includingContextSendsTheReviewedSurroundingText() throws {
        try withController { controller, session, _ in
            let pending = try key(controller, session, keyEvent("s", .control),
                                  extra: ["leftContext": "PRIVATE_BEFORE", "rightContext": "PRIVATE_AFTER"])
            let review = try #require(pending.ai?.review)
            #expect(pending.request == "predict" && review.target == AISuggestionReview.continuationTarget)
            let arguments = try #require(try send(controller, session, review: review.id, includeContext: true)["request"] as? [String: Any])
            #expect(arguments["leftContext"] as? String == "PRIVATE_BEFORE" && arguments["includeContext"] as? Bool == true)
        }
    }

    @Test func aChangedCompositionResetOrPrivateFieldNeverSends() throws {
        try withController { controller, session, _ in
            try typeNihongo(controller, session)
            let changed = try #require(try key(controller, session, keyEvent("s", .control)).ai?.review)
            _ = session.key(KeyEventCore(modifierFlags: [], characters: "a", charactersIgnoringModifiers: "a", keyCode: 0))
            #expect(try send(controller, session, review: changed.id, includeContext: false)["request"] == nil)

            let reset = try #require(try key(controller, session, keyEvent("s", .control)).ai?.review)
            _ = session.reset(commit: false)
            #expect(try send(controller, session, review: reset.id, includeContext: false)["request"] == nil)

            try typeNihongo(controller, session)
            let protected = try #require(try key(controller, session, keyEvent("s", .control)).ai?.review)
            #expect(try send(controller, session, review: protected.id, includeContext: false, privateInput: true)["request"] == nil)
        }
    }

    @Test func aNewerKeyReplacesTheReviewAndAnOldIdentifierCannotSendIt() throws {
        try withController { controller, session, _ in
            try typeNihongo(controller, session)
            let first = try #require(try key(controller, session, keyEvent("s", .control)).ai?.review)
            let second = try #require(try key(controller, session, keyEvent("s", .control)).ai?.review)
            #expect(first.id != second.id)
            #expect(try send(controller, session, review: first.id, includeContext: false)["request"] == nil)
            #expect(try send(controller, session, review: second.id, includeContext: false)["request"] != nil)
        }
    }

    @Test func privateInputOrDisabledAIOffersNoReview() throws {
        try withController { controller, session, _ in
            let pending = try key(controller, session, keyEvent("s", .control), extra: ["privateInput": true])
            #expect(pending.request == "predict" && pending.ai == nil)
        }
        try withController(aiEnabled: false) { controller, session, _ in
            let ignored = try key(controller, session, keyEvent("s", .control))
            #expect(!ignored.consumed && ignored.ai == nil)
        }
    }

    // MARK: Prompt shortcuts

    @Test func promptShortcutsOpenThePromptOnlyForASelectionWithoutEditingTheComposition() throws {
        try withController { controller, session, history in
            try history.save("敬語に直す", pinned: true, shortcut: KeyboardShortcut(key: "e", modifiers: [.control, .option]))
            let before = session.snapshot()
            let pinned = try key(controller, session, keyEvent("e", [.control, .option]), extra: ["ai": ["hasSelection": true]])
            #expect(pinned.ai?.prompt?.initialPrompt == "敬語に直す" && pinned.consumed)
            #expect(pinned.generation == before.generation)
            let transform = try key(controller, session, keyEvent("s", .control), extra: ["ai": ["hasSelection": true]])
            #expect(transform.ai?.prompt?.initialPrompt.isEmpty == true)
            let doubleTap = try key(controller, session, ["modifierFlags": 0, "keyCode": 104], extra: ["doubleTap": true, "ai": ["hasSelection": true]])
            #expect(doubleTap.ai?.prompt?.initialPrompt == "japanese")
            let withoutSelection = try key(controller, session, keyEvent("e", [.control, .option]))
            #expect(withoutSelection.ai?.prompt == nil)
            let privateField = try key(controller, session, keyEvent("e", [.control, .option]),
                                       extra: ["privateInput": true, "ai": ["hasSelection": true]])
            #expect(privateField.ai?.prompt == nil)
        }
    }

    @Test func routedShortcutsIncludePromptChordsOnlyWhileAIIsEnabled() throws {
        try withController { controller, _, history in
            try history.save("敬語に直す", pinned: true, shortcut: KeyboardShortcut(key: "e", modifiers: [.control, .option]))
            let enabled = try encoded(try #require(try controller.response(to: request(["operation": "ime-shortcuts"]), context: "field")))
            let commands = try #require(enabled["shortcuts"] as? [[String: Any]]).compactMap { $0["command"] as? String }
            #expect(commands == ["suggestion", "unicode", "prompt", "prompt"])
        }
        try withController(aiEnabled: false) { controller, _, _ in
            let disabled = try encoded(try #require(try controller.response(to: request(["operation": "ime-shortcuts"]), context: "field")))
            #expect((disabled["shortcuts"] as? [[String: Any]])?.count == IMEShortcuts.bindings.count)
        }
    }

    @Test func theShortcutNotationIsCheckedAndShownByCore() throws {
        try withController { controller, _, _ in
            let parsed = try encoded(try #require(try controller.response(to: request(["operation": "ai-shortcut", "ai": ["shortcutText": "ctrl+alt+E"]]), context: "c")))
            #expect(parsed["shortcutText"] as? String == "Ctrl+Alt+e")
            #expect((parsed["shortcut"] as? [String: Any])?["modifiers"] as? Int == 6)
            let invalid = try encoded(try #require(try controller.response(to: request(["operation": "ai-shortcut", "ai": ["shortcutText": "e"]]), context: "c")))
            #expect(invalid["shortcutError"] as? String == "modifierRequired")
            let shown = try encoded(try #require(try controller.response(
                to: request(["operation": "ai-shortcut", "ai": ["shortcut": ["key": "g", "modifiers": 6]]]), context: "c"
            )))
            #expect(shown["shortcutText"] as? String == "Ctrl+Alt+g")
        }
    }

    // MARK: Selected-text transformation

    func openVerified(_ controller: DesktopAIController) throws -> Int {
        let opened = try transform(controller, "open", ["field": Self.field()])
        let identifier = try #require(opened["transformation"] as? Int)
        #expect(opened["needsWitness"] as? Bool == true && opened["contextCharacters"] as? Int == 100)
        let target = try transform(controller, "target", ["transformation": identifier, "field": Self.field(), "witness": Self.witness])
        #expect(target["targetAvailable"] as? Bool == true)
        return identifier
    }

    func preview(_ controller: DesktopAIController, _ identifier: Int, prompt: String = "敬語に直す") throws -> [String: Any] {
        try transform(controller, "preview", ["transformation": identifier, "prompt": prompt, "includeContext": false,
                                             "pinned": false, "shortcutText": "", "field": Self.field()])
    }

    @Test func openingShowsTheTargetDestinationAndHistoryWithoutSending() throws {
        try withController { controller, _, _ in
            let opened = try transform(controller, "open", ["field": Self.field()])
            #expect(opened["target"] as? String == "原文")
            #expect(opened["destination"] as? String == "reviewed.example.invalid:8443")
            #expect(opened["includeContext"] as? Bool == false)
            #expect(Self.historyPrompts(opened) == AIPromptHistory.defaultPrompts(in: .english))
            #expect(try transform(controller, "open", ["field": Self.field(sensitive: true)])["transformation"] == nil)
            #expect(try transform(controller, "open", ["field": Self.field(cursor: 4, anchor: 4)])["transformation"] == nil)
        }
    }

    @Test func theOfferedDefaultsFollowTheLanguageSetting() throws {
        try withController { controller, _, _ in
            Config.AIPromptLanguage().value = .japanese
            let opened = try transform(controller, "open", ["field": Self.field()])
            #expect(Self.historyPrompts(opened) == AIPromptHistory.defaultPrompts(in: .japanese))
        }
    }

    static func historyPrompts(_ opened: [String: Any]) -> [String]? {
        (opened["history"] as? [[String: Any]])?.compactMap { $0["prompt"] as? String }
    }

    @Test func aVerifiedResultIsAppliedOnceToTheOriginalSelection() throws {
        try withController { controller, _, history in
            let identifier = try openVerified(controller)
            let started = try preview(controller, identifier)
            let revision = try #require(started["revision"] as? Int)
            let arguments = try #require(started["request"] as? [String: Any])
            #expect(arguments["prompt"] as? String == "敬語に直す" && arguments["target"] as? String == "原文")
            #expect(history.load().contains { $0.prompt == "敬語に直す" && !$0.pinned }, "only the instruction is kept")
            let result = try transform(controller, "result", ["transformation": identifier, "revision": revision, "text": "変更済み"])
            #expect(result["accepted"] as? Bool == true && result["text"] as? String == "変更済み")
            #expect(try transform(controller, "confirm", ["transformation": identifier])["confirmed"] as? Bool == true)
            #expect(try transform(controller, "check", ["transformation": identifier, "field": Self.field()])["matches"] as? Bool == true)
            let take = ["transformation": identifier, "field": Self.field(), "witness": Self.witness] as [String: Any]
            #expect(try transform(controller, "take", take)["replacement"] as? String == "変更済み")
            #expect(try transform(controller, "take", take)["replacement"] == nil)
        }
    }

    @Test func repliesInReverseOrderKeepTheCurrentPreviewAndItsTarget() throws {
        try withController { controller, _, _ in
            let identifier = try openVerified(controller)
            let first = try #require(try preview(controller, identifier)["revision"] as? Int)
            #expect(try preview(controller, identifier)["previewRefusal"] as? String == "loading")
            _ = try transform(controller, "invalidate", ["transformation": identifier])
            let second = try #require(try preview(controller, identifier, prompt: "新しい指示")["revision"] as? Int)
            let current = try transform(controller, "result", ["transformation": identifier, "revision": second, "text": "新しい本文"])
            #expect(current["accepted"] as? Bool == true)
            let late = try transform(controller, "result", ["transformation": identifier, "revision": first, "text": "逆順に届いた本文",
                                                             "inputContextChanged": true])
            #expect(late["accepted"] as? Bool == false && late["text"] as? String == "新しい本文")
            #expect(late["targetAvailable"] as? Bool == true)
        }
    }

    @Test func failedEmptyOrFocusChangedResultsCannotBeApplied() throws {
        try withController { controller, _, _ in
            let identifier = try openVerified(controller)
            for text: Any in [NSNull(), ""] {
                let revision = try #require(try preview(controller, identifier)["revision"] as? Int)
                let failed = try transform(controller, "result", ["transformation": identifier, "revision": revision, "text": text])
                #expect(failed["accepted"] as? Bool == true && failed["text"] == nil)
                #expect(try transform(controller, "confirm", ["transformation": identifier])["confirmed"] as? Bool == false)
            }
            let revision = try #require(try preview(controller, identifier)["revision"] as? Int)
            let moved = try transform(controller, "result", ["transformation": identifier, "revision": revision, "text": "新しい本文",
                                                              "inputContextChanged": true])
            #expect(moved["text"] as? String == "新しい本文" && moved["targetAvailable"] as? Bool == false)
            #expect(try transform(controller, "confirm", ["transformation": identifier])["confirmed"] as? Bool == false)
        }
    }

    @Test func aChangedFieldOrWitnessRejectsTheResultButKeepsItForCopy() throws {
        try withController { controller, _, _ in
            for (field, witness) in [(Self.field("前 別文 後"), Self.witness),
                                     (Self.field(), Self.witness.merging(["object": ["bus", ":1.4", "/field/2"]]) { $1 })] {
                let identifier = try openVerified(controller)
                let revision = try #require(try preview(controller, identifier)["revision"] as? Int)
                _ = try transform(controller, "result", ["transformation": identifier, "revision": revision, "text": "新しい本文"])
                _ = try transform(controller, "confirm", ["transformation": identifier])
                _ = try transform(controller, "check", ["transformation": identifier, "field": field])
                let take = try transform(controller, "take", ["transformation": identifier, "field": Self.field(), "witness": witness])
                #expect(take["replacement"] == nil)
                let after = try transform(controller, "result", ["transformation": identifier, "revision": revision, "text": "再送"])
                #expect(after["text"] as? String == "新しい本文" && after["targetAvailable"] as? Bool == false)
            }
        }
    }

    @Test func historyProblemsAreReportedBeforeAnyRequest() throws {
        try withController { controller, _, history in
            try history.save("敬語に直す", pinned: true, shortcut: KeyboardShortcut(key: "e", modifiers: [.control, .option]))
            let identifier = try openVerified(controller)
            for (shortcutText, error) in [("e", "modifierRequired"), ("Ctrl+ee", "format"), ("Ctrl+Alt+e", "duplicateShortcut")] {
                let refused = try transform(controller, "preview", ["transformation": identifier, "prompt": "英訳", "includeContext": false,
                                                                    "pinned": true, "shortcutText": shortcutText, "field": Self.field()])
                #expect(refused["historyError"] as? String == error && refused["request"] == nil)
            }
            #expect(try preview(controller, identifier, prompt: "  ")["previewRefusal"] as? String == "emptyPrompt")
        }
    }

    @Test func aSensitiveFieldEndsThePreviewWithoutARequest() throws {
        try withController { controller, _, _ in
            let identifier = try openVerified(controller)
            let refused = try transform(controller, "preview", ["transformation": identifier, "prompt": "送信禁止", "includeContext": true,
                                                                "pinned": false, "shortcutText": "", "field": Self.field(sensitive: true)])
            #expect(refused["revision"] != nil && refused["request"] == nil)
        }
    }

    @Test func operationsForAClosedOrReplacedTransformationAreStale() throws {
        try withController { controller, _, _ in
            let first = try openVerified(controller)
            let second = try openVerified(controller)
            #expect(try transform(controller, "confirm", ["transformation": first])["stale"] as? Bool == true)
            _ = try transform(controller, "close", ["transformation": second])
            #expect(try transform(controller, "confirm", ["transformation": second])["stale"] as? Bool == true)
            let other = try transform(controller, "open", ["field": Self.field()], context: "other-field")
            #expect(other["transformation"] != nil)
            controller.close(context: "other-field")
            #expect(try transform(controller, "confirm", ["transformation": try #require(other["transformation"] as? Int)],
                                  context: "other-field")["stale"] as? Bool == true)
        }
    }
}
