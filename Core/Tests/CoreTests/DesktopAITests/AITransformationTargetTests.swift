import Core
import Testing

/// Ported from the Ubuntu target tests: a replacement belongs to one input
/// field, one selection and unchanged text.
struct AITransformationTargetTests {
    static let identity = ["/input/1", "gnome-shell"]

    static func field(text: String = "前 原文 後", cursor: Int = 4, anchor: Int = 2, identity: [String]? = identity,
                      hasSurroundingUpdate: Bool = true, isSensitive: Bool = false) -> AITextField {
        AITextField(identity: identity, surrounding: .init(text: text, cursorUTF16: cursor, anchorUTF16: anchor),
                    hasSurroundingUpdate: hasSurroundingUpdate, isSensitive: isSensitive)
    }

    static func witness(object: [String] = ["fixture-bus", ":1.4", "/field/1"], window: [String] = [":1.4", "/window/1"],
                        start: Int = 2, end: Int = 4, before: String = "前 ", selected: String = "原文",
                        after: String = " 後") -> AISelectionWitness {
        AISelectionWitness(object: object, window: window, start: start, end: end, before: before, selected: selected, after: after)
    }

    static func target() throws -> AITransformationTarget {
        let captured = try #require(field().currentSelection)
        return try #require(AITransformationTarget(captured: captured, current: field(), witness: witness()))
    }

    @Test func theOriginalFieldAndSelectionMatch() throws {
        #expect(try Self.target().matches(Self.field(), witness: Self.witness()))
    }

    @Test(arguments: [
        AITransformationTargetTests.witness(object: ["fixture-bus", ":1.4", "/field/2"]),
        AITransformationTargetTests.witness(object: ["fixture-bus", ":1.5", "/field/1"]),
        AITransformationTargetTests.witness(object: ["restarted-bus", ":1.4", "/field/1"]),
        AITransformationTargetTests.witness(window: [":1.4", "/window/2"])
    ])
    func identicalTextInAnotherFieldOrWindowNeverMatches(other: AISelectionWitness) throws {
        #expect(try !Self.target().matches(Self.field(), witness: other))
        #expect(try !Self.target().matches(Self.field(), witness: nil))
    }

    @Test(arguments: [
        AITransformationTargetTests.witness(start: 10, end: 12), AITransformationTargetTests.witness(selected: "別文"),
        AITransformationTargetTests.witness(before: "別 "), AITransformationTargetTests.witness(after: " 別")
    ])
    func aMovedSelectionOrChangedTextInTheSameObjectNeverMatches(changed: AISelectionWitness) throws {
        #expect(try !Self.target().matches(Self.field(), witness: changed))
    }

    @Test func anotherInputContextOrSelectionDirectionNeverMatches() throws {
        let target = try Self.target()
        #expect(!target.matches(Self.field(identity: ["/input/2", "gnome-shell"]), witness: Self.witness()))
        #expect(!target.matches(Self.field(cursor: 2, anchor: 4), witness: Self.witness()))
        #expect(!target.matches(Self.field(identity: nil), witness: Self.witness()))
        #expect(!target.matches(Self.field(isSensitive: true), witness: Self.witness()))
    }

    @Test func aReturnWithoutANewReportNeedsOnlyTheOriginalIdentityAndAFreshWitness() throws {
        let target = try Self.target()
        let returned = AITextField(identity: Self.identity, surrounding: nil, hasSurroundingUpdate: false, isSensitive: false)
        #expect(target.isOriginal(returned))
        #expect(target.matches(returned, witness: Self.witness()))
        #expect(!target.matches(returned, witness: Self.witness(selected: "別文")))
        // A report that arrived before focus returned describes nothing current.
        let stale = Self.field(text: "前 別文 後", hasSurroundingUpdate: false)
        #expect(target.isOriginal(stale))
        let newerEmptySelection = Self.field(cursor: 4, anchor: 4)
        #expect(!target.isOriginal(newerEmptySelection))
        #expect(!target.isOriginal(AITextField(identity: ["/input/other", "gnome-shell"], surrounding: nil,
                                               hasSurroundingUpdate: false, isSensitive: false)))
    }

    @Test func aTargetNeedsAWitnessOfTheCapturedSelectionThatTheFieldStillReports() throws {
        let captured = try #require(Self.field().currentSelection)
        #expect(AITransformationTarget(captured: captured, current: Self.field(), witness: nil) == nil)
        #expect(AITransformationTarget(captured: captured, current: Self.field(), witness: Self.witness(selected: "別文")) == nil)
        #expect(AITransformationTarget(captured: captured, current: Self.field(text: "前 原文 別"), witness: Self.witness()) == nil)
        #expect(AITransformationTarget(captured: captured, current: Self.field(isSensitive: true), witness: Self.witness()) == nil)
    }

    @Test func anInputContextParagraphDoesNotInventAbsoluteWitnessOffsets() throws {
        let paragraph = try #require(Self.field().currentSelection)
        let document = Self.witness(start: 102, end: 104, before: "別の段落\n前 ", after: " 後\n次の段落")
        #expect(document.describes(paragraph))
    }

    @Test func nonBMPAndCombiningCharactersKeepExactTextAndPositions() throws {
        // 前😀か\u{3099}後: the emoji is two UTF-16 units, the voiced mark is separate.
        let selection = try #require(Self.field(text: "前😀か\u{3099}後", cursor: 5, anchor: 1).currentSelection)
        #expect(selection.selected.unicodeScalars.elementsEqual("😀か\u{3099}".unicodeScalars))
        let witness = Self.witness(start: 1, end: 4, before: "前", selected: "😀か\u{3099}", after: "後")
        #expect(witness.describes(selection))
        // Canonically equivalent but different scalars are different text.
        #expect(!Self.witness(start: 1, end: 4, before: "前", selected: "😀が", after: "後").describes(selection))
    }
}

struct AITextSelectionTests {
    @Test(arguments: [(-1, 2), (20, 2), (2, 2)])
    func captureRequiresValidNonEmptyOffsets(cursor: Int, anchor: Int) {
        let surrounding = AITextField.Surrounding(text: "前 原文 後", cursorUTF16: cursor, anchorUTF16: anchor)
        #expect(AITextSelection(identity: ["context"], surrounding: surrounding) == nil)
    }

    @Test func anOffsetInsideASurrogatePairIsNotASelection() {
        let surrounding = AITextField.Surrounding(text: "😀文", cursorUTF16: 1, anchorUTF16: 3)
        #expect(AITextSelection(identity: ["context"], surrounding: surrounding) == nil)
    }

    @Test func aFieldWithoutANameOrAFreshReportHasNoCurrentSelection() {
        let surrounding = AITextField.Surrounding(text: "前 原文 後", cursorUTF16: 4, anchorUTF16: 2)
        #expect(AITextField(identity: nil, surrounding: surrounding, hasSurroundingUpdate: true, isSensitive: false).currentSelection == nil)
        #expect(AITextField(identity: ["c"], surrounding: surrounding, hasSurroundingUpdate: false, isSensitive: false).currentSelection == nil)
    }

    @Test func contextIsLimitedToOneHundredScalarsOnEachSide() throws {
        let text = String(repeating: "前", count: 500) + "原文" + String(repeating: "後", count: 500)
        let selection = try #require(AITextSelection(
            identity: nil, surrounding: .init(text: text, cursorUTF16: 502, anchorUTF16: 500)
        ))
        #expect(selection.selected == "原文")
        #expect(selection.before.unicodeScalars.count == 100)
        #expect(selection.after.unicodeScalars.count == 100)
    }
}
