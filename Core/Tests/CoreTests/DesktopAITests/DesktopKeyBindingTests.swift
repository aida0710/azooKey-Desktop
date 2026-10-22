import Core
import Testing

/// Platforms route keys by Core's bindings; Core gives the keys their meaning.
struct DesktopKeyBindingTests {
    static func event(_ characters: String?, _ modifiers: KeyEventCore.ModifierFlag = [], keyCode: UInt16 = 0) -> KeyEventCore {
        KeyEventCore(modifierFlags: modifiers, characters: characters, charactersIgnoringModifiers: characters, keyCode: keyCode)
    }

    @Test func everyIMEShortcutHasTheMeaningCoreGivesIt() {
        for binding in IMEShortcuts.bindings {
            let action = UserAction.getUserAction(
                eventCore: Self.event(binding.key, binding.modifiers), inputLanguage: .japanese
            )
            switch (binding.command, action) {
            case (.suggestion, .suggest), (.unicode, .startUnicodeInput):
                break
            default:
                Issue.record("\(binding) is routed to Core but means \(action)")
            }
        }
    }

    @Test func idleShortcutsMatchOnlyTheirExactChord() {
        #expect(DesktopKeyBinding.command(for: Self.event("s", [.control]), in: IMEShortcuts.bindings) == .suggestion)
        #expect(DesktopKeyBinding.command(for: Self.event("U", [.control, .shift]), in: IMEShortcuts.bindings) == .unicode)
        for other in [Self.event("s", [.control, .option]), Self.event("s"), Self.event("c", [.control])] {
            #expect(DesktopKeyBinding.command(for: other, in: IMEShortcuts.bindings) == nil)
        }
    }

    @Test func theReviewLeavesReturnAndOrdinaryInputToTheInputEngine() {
        let bindings = AISuggestionReview.keyBindings
        #expect(DesktopKeyBinding.command(for: Self.event("s", [.control]), in: bindings) == .send)
        #expect(DesktopKeyBinding.command(for: Self.event("S", [.control, .shift]), in: bindings) == .toggleContext)
        #expect(DesktopKeyBinding.command(for: Self.event(nil, keyCode: 53), in: bindings) == .cancel)
        for other in [Self.event(nil, keyCode: 36), Self.event("a"), Self.event("s", [.option]), Self.event(nil, [.shift], keyCode: 53)] {
            #expect(DesktopKeyBinding.command(for: other, in: bindings) == nil)
        }
    }

    @Test func pinnedShortcutsComeBeforeTheTransformShortcutAndDoubleTaps() {
        let formal = KeyboardShortcut(key: "s", modifiers: [.control])
        let shortcuts = AIPromptShortcuts(
            pinned: [(KeyboardShortcut(key: "e", modifiers: [.control, .option]), "敬語"), (formal, "丁寧に")],
            transformShortcut: .defaultTransformShortcut
        )
        #expect(shortcuts.initialPrompt(for: Self.event("e", [.control, .option]), doubleTap: false) == "敬語")
        #expect(shortcuts.initialPrompt(for: Self.event("s", [.control]), doubleTap: false) == "丁寧に")
        #expect(AIPromptShortcuts(pinned: [], transformShortcut: .defaultTransformShortcut)
            .initialPrompt(for: Self.event("s", [.control]), doubleTap: false) == "")
        #expect(shortcuts.initialPrompt(for: Self.event(nil, keyCode: 102), doubleTap: true) == "english")
        #expect(shortcuts.initialPrompt(for: Self.event(nil, keyCode: 104), doubleTap: true) == "japanese")
        #expect(shortcuts.initialPrompt(for: Self.event(nil, keyCode: 102), doubleTap: false) == nil)
        #expect(shortcuts.initialPrompt(for: Self.event("e", [.control]), doubleTap: false) == nil)
        #expect(shortcuts.bindings.allSatisfy { $0.command == .prompt })
        #expect(shortcuts.bindings.count == 3)
    }
}

struct AISuggestionReviewTests {
    static let configuration = AIDesktopConfiguration(
        isEnabled: true, modelName: "fixture-model", endpoint: "https://user:password@api.example.invalid:8443/secret?key=private",
        includesContext: false, transformShortcut: .defaultTransformShortcut
    )

    @Test func surroundingTextIsAbsentFromTheRequestUnlessIncluded() {
        let review = AISuggestionReview(id: 1, reading: "送信する本文", generation: 8, before: "PRIVATE_BEFORE",
                                        after: "PRIVATE_AFTER", configuration: Self.configuration)
        let excluded = review.content.arguments(includeContext: false)
        #expect(excluded.target == "送信する本文" && excluded.leftContext.isEmpty && excluded.rightContext.isEmpty)
        #expect(!excluded.includeContext && excluded.prompt == nil)
        let included = review.content.arguments(includeContext: true)
        #expect(included.leftContext == "PRIVATE_BEFORE" && included.rightContext == "PRIVATE_AFTER")
        #expect(included.aiEndpoint == Self.configuration.endpoint && included.aiModel == "fixture-model")
        #expect(!review.content.includesContextByDefault)
    }

    @Test func anEmptyCompositionAsksForAContinuation() {
        let review = AISuggestionReview(id: 1, reading: "", generation: 1, before: "", after: "", configuration: Self.configuration)
        #expect(review.content.target == AISuggestionReview.continuationTarget)
    }

    @Test func aConfirmationCountsOnlyForTheReviewedComposition() {
        let review = AISuggestionReview(id: 1, reading: "よみ", generation: 8, before: "", after: "", configuration: Self.configuration)
        #expect(review.isCurrent(generation: 8, reading: "よみ"))
        #expect(!review.isCurrent(generation: 9, reading: "よみ"))
        #expect(!review.isCurrent(generation: 8, reading: "べつ"))
    }

    @Test func theReviewedContextIsLimitedToOneHundredScalars() {
        let review = AISuggestionReview(id: 1, reading: "よみ", generation: 1, before: String(repeating: "前", count: 150),
                                        after: String(repeating: "後", count: 150), configuration: Self.configuration)
        #expect(review.content.before.unicodeScalars.count == 100)
        #expect(review.content.after.unicodeScalars.count == 100)
    }
}

@Suite("AI destination")
struct AIDestinationTests {
    @Test func theDestinationShowsNoCredentialsPathOrQuery() {
        #expect(AIRequestConfiguration.safeEndpointHost("https://user:password@api.example.invalid:8443/secret?key=private")
            == "api.example.invalid:8443")
        #expect(AIRequestConfiguration.safeEndpointHost("http://[::1]:8080/private") == "[::1]:8080")
        #expect(AIRequestConfiguration.safeEndpointHost("https://API.Example.Invalid/v1") == "api.example.invalid")
    }

    @Test(arguments: ["file:///secret", "https://user:password@", "https://host:invalid/private", "not a URL"])
    func anEndpointWithoutAShowableHostHasNoDestination(endpoint: String) {
        #expect(AIRequestConfiguration.safeEndpointHost(endpoint) == nil)
    }
}
