import Core
import Testing

/// Results arrive late, empty, failed or in reverse order; only the current
/// preview may become applicable, and only the original selection receives it.
struct AISelectedTextTransformationTests {
    typealias Fixture = AITransformationTargetTests

    static let configuration = AIDesktopConfiguration(
        isEnabled: true, modelName: "fixture-model", endpoint: "https://user:secret@api.example.invalid:8443/v1?key=private",
        includesContext: false, transformShortcut: .defaultTransformShortcut
    )

    static func transformation(field: AITextField = Fixture.field(),
                               configuration: AIDesktopConfiguration = configuration) throws -> AISelectedTextTransformation {
        var transformation = try #require(AISelectedTextTransformation(id: 1, field: field, configuration: configuration))
        transformation.attachWitness(Fixture.witness(), current: field)
        return transformation
    }

    static func preview(_ transformation: inout AISelectedTextTransformation, prompt: String = "敬語に直す") throws -> Int {
        try transformation.beginPreview(prompt: prompt, includeContext: false, field: Fixture.field()).revision
    }

    /// A transformation whose current preview completed with `text`.
    static func completed(_ text: String = "新しい本文", inputContextChanged: Bool = false) throws -> AISelectedTextTransformation {
        var transformation = try Self.transformation()
        let revision = try Self.preview(&transformation)
        transformation.completePreview(revision: revision, text: text, inputContextChanged: inputContextChanged)
        return transformation
    }

    @Test func onlyASelectionInAFieldThatIsNotSensitiveCanBeTransformed() {
        #expect(AISelectedTextTransformation(id: 1, field: Fixture.field(isSensitive: true), configuration: Self.configuration) == nil)
        #expect(AISelectedTextTransformation(id: 1, field: Fixture.field(cursor: 4, anchor: 4), configuration: Self.configuration) == nil)
        let unnamed = AISelectedTextTransformation(id: 1, field: Fixture.field(identity: nil), configuration: Self.configuration)
        #expect(unnamed?.needsWitness == false, "a field without identity still offers a copyable preview")
    }

    @Test func theRequestCarriesSurroundingTextOnlyWhenIncluded() throws {
        var transformation = try Self.transformation(field: Fixture.field(text: "PRIVATE_BEFORE原文PRIVATE_AFTER", cursor: 16, anchor: 14))
        let withoutContext = try transformation.beginPreview(prompt: " 敬語に直す ", includeContext: false, field: Fixture.field())
        let excluded = try #require(withoutContext.arguments)
        #expect(excluded.target == "原文" && excluded.leftContext.isEmpty && excluded.rightContext.isEmpty)
        #expect(excluded.prompt == "敬語に直す")
        #expect(excluded.aiEndpoint == Self.configuration.endpoint && excluded.aiModel == "fixture-model")
        transformation.invalidatePreview()
        let withContext = try transformation.beginPreview(prompt: "敬語に直す", includeContext: true, field: Fixture.field())
        let included = try #require(withContext.arguments)
        #expect(included.leftContext == "PRIVATE_BEFORE" && included.rightContext == "PRIVATE_AFTER")
        #expect(transformation.content.destination == "api.example.invalid:8443")
    }

    @Test func aRepeatedSubmitWaitsForTheCurrentRequestAndBlankInstructionsAreRefused() throws {
        var transformation = try Self.transformation()
        #expect(transformation.refusal(forPrompt: "  ") == .emptyPrompt)
        let revision = try Self.preview(&transformation)
        #expect(transformation.refusal(forPrompt: "敬語に直す") == .loading)
        do {
            _ = try Self.preview(&transformation)
            Issue.record("a second submit started another request")
        } catch {
            #expect(error as? AISelectedTextTransformation.PreviewRefusal == .loading)
        }
        let accepted = transformation.completePreview(revision: revision, text: "本文", inputContextChanged: false)
        #expect(accepted && transformation.applicableText == "本文")
    }

    @Test(arguments: [nil, ""] as [String?])
    func regenerationClearsThePreviousTextEvenWhenItFails(response: String?) throws {
        var transformation = try Self.completed("前の本文")
        let revision = try Self.preview(&transformation)
        #expect(transformation.applicableText == nil && transformation.isLoading)
        transformation.completePreview(revision: revision, text: response, inputContextChanged: false)
        #expect(!transformation.isLoading && transformation.applicableText == nil)
    }

    @Test func anOldReplyCannotEndOrReplaceTheNewRequest() throws {
        var transformation = try Self.transformation()
        let first = try Self.preview(&transformation)
        transformation.invalidatePreview()
        let second = try Self.preview(&transformation)
        let oldAccepted = transformation.completePreview(revision: first, text: "古い本文", inputContextChanged: true)
        #expect(!oldAccepted && transformation.isLoading && transformation.isTargetAvailable)
        let currentAccepted = transformation.completePreview(revision: second, text: "新しい本文", inputContextChanged: false)
        let oldFailureAccepted = transformation.completePreview(revision: first, text: nil, inputContextChanged: false)
        let repeatAccepted = transformation.completePreview(revision: second, text: "二回目の本文", inputContextChanged: true)
        #expect(currentAccepted && !oldFailureAccepted && !repeatAccepted)
        #expect(transformation.applicableText == "新しい本文" && transformation.isTargetAvailable)
    }

    @Test func aDelayedReplyAfterAnEditIsIgnored() throws {
        var transformation = try Self.transformation()
        let revision = try Self.preview(&transformation)
        transformation.invalidatePreview()
        let accepted = transformation.completePreview(revision: revision, text: "遅れた本文", inputContextChanged: true)
        #expect(!accepted && transformation.applicableText == nil && transformation.isTargetAvailable)
    }

    @Test func aResultAfterAFocusChangeStaysCopyableButCannotBeApplied() throws {
        var transformation = try Self.completed(inputContextChanged: true)
        #expect(transformation.applicableText == "新しい本文" && !transformation.isTargetAvailable)
        let confirmed = transformation.confirm()
        #expect(!confirmed)
    }

    @Test(arguments: [false, true])
    func aSensitiveFieldOrDisabledAIEndsThePreviewWithoutARequest(sensitive: Bool) throws {
        var configuration = Self.configuration
        configuration.isEnabled = sensitive
        var transformation = try Self.transformation(configuration: configuration)
        let first = try Self.preview(&transformation)
        transformation.completePreview(revision: first, text: "前の本文", inputContextChanged: false)
        let started = try transformation.beginPreview(prompt: "送信禁止", includeContext: true, field: Fixture.field(isSensitive: sensitive))
        #expect(started.arguments == nil)
        #expect(!transformation.isLoading && transformation.applicableText == nil)
    }

    @Test func theConfirmedResultReachesTheOriginalSelectionExactlyOnce() throws {
        var transformation = try Self.completed()
        let confirmed = transformation.confirm()
        let returned = transformation.checkReturn(to: Fixture.field())
        let first = transformation.takeReplacement(for: Fixture.field(), witness: Fixture.witness())
        let second = transformation.takeReplacement(for: Fixture.field(), witness: Fixture.witness())
        #expect(confirmed && returned)
        #expect(first == "新しい本文" && second == nil)
    }

    @Test func nothingIsAppliedWithoutAConfirmedResultAndATarget() throws {
        var transformation = try Self.transformation()
        let confirmed = transformation.confirm()
        let returned = transformation.checkReturn(to: Fixture.field())
        let replacement = transformation.takeReplacement(for: Fixture.field(), witness: Fixture.witness())
        #expect(!confirmed && !returned && replacement == nil)

        var unverified = try #require(AISelectedTextTransformation(id: 2, field: Fixture.field(), configuration: Self.configuration))
        unverified.attachWitness(nil, current: Fixture.field())
        let revision = try Self.preview(&unverified)
        unverified.completePreview(revision: revision, text: "新しい本文", inputContextChanged: false)
        let unverifiedConfirmed = unverified.confirm()
        #expect(!unverified.isTargetAvailable && !unverifiedConfirmed)
        #expect(unverified.applicableText == "新しい本文", "the result remains for an explicit copy")
    }

    @Test func aContradictingReportEndsTheTargetBeforeAnyWitnessRead() throws {
        var transformation = try Self.completed()
        transformation.confirm()
        let changed = transformation.checkReturn(to: Fixture.field(text: "前 別文 後"))
        // Returning to the old selection cannot restore the permission.
        let restored = transformation.checkReturn(to: Fixture.field())
        let replacement = transformation.takeReplacement(for: Fixture.field(), witness: Fixture.witness())
        #expect(!changed && !restored && replacement == nil)
        #expect(transformation.applicableText == "新しい本文")
    }

    @Test func aRejectedTakeCannotBeReplayed() throws {
        var transformation = try Self.completed()
        transformation.confirm()
        let otherField = transformation.takeReplacement(for: Fixture.field(), witness: Fixture.witness(object: ["bus", ":1.4", "/field/2"]))
        let replayed = transformation.takeReplacement(for: Fixture.field(), witness: Fixture.witness())
        #expect(otherField == nil && replayed == nil && !transformation.isTargetAvailable)
    }

    @Test func discardingTheTargetKeepsTheResultForCopy() throws {
        var transformation = try Self.completed()
        transformation.confirm()
        transformation.discardTarget()
        let replacement = transformation.takeReplacement(for: Fixture.field(), witness: Fixture.witness())
        #expect(replacement == nil && transformation.applicableText == "新しい本文")
    }
}
