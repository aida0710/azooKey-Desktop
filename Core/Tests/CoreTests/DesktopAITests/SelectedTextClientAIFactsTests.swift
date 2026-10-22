import Core
import Foundation
import Testing

/// macOS reads its facts through the client it later writes to. The facts
/// must describe the selection exactly and let Core refuse any other place.
@MainActor
struct SelectedTextClientAIFactsTests {
    private final class Client: SelectedTextClient {
        var identity: ObjectIdentifier { ObjectIdentifier(self) }
        var isActive = true
        var documentLength: Int { text.utf16.count }
        var selectedRange = NSRange(location: 3, length: 3)
        var text = "前の文日本語後の文"
        var actualRange: NSRange?

        func readText(in range: NSRange) -> (text: String, actualRange: NSRange)? {
            guard range.location >= 0, range.length >= 0, range.location + range.length <= documentLength else {
                return nil
            }
            return ((text as NSString).substring(with: range), actualRange ?? range)
        }

        func replaceText(in range: NSRange, with text: String) {}

        var aiIdentity: [String] { [String(describing: identity)] }
        func field() -> AITextField { aiTextField(identity: aiIdentity, isSensitive: false) }
        func witness() -> AISelectionWitness? { aiSelectionWitness(identity: aiIdentity, window: ["window"]) }
    }

    private static func confirmedTransformation(from client: Client) throws -> AISelectedTextTransformation {
        var transformation = try #require(AISelectedTextTransformation(
            id: 1, field: client.field(), configuration: AISelectedTextTransformationTests.configuration
        ))
        let targetAvailable = transformation.attachWitness(client.witness(), current: client.field())
        let started = try transformation.beginPreview(prompt: "敬語に直す", includeContext: true, field: client.field())
        transformation.completePreview(revision: started.revision, text: "変換した本文", inputContextChanged: false)
        let confirmed = transformation.confirm()
        #expect(targetAvailable && confirmed)
        return transformation
    }

    @Test func theFactsDescribeTheSelectionAndTheTextAroundIt() throws {
        let client = Client()
        let surrounding = try #require(client.field().surrounding)
        #expect(surrounding.text == "前の文日本語後の文")
        #expect(surrounding.anchorUTF16 == 3 && surrounding.cursorUTF16 == 6)
        let witness = try #require(client.witness())
        #expect(witness.start == 3 && witness.end == 6)
        #expect(witness.before == "前の文" && witness.selected == "日本語" && witness.after == "後の文")
        let transformation = try Self.confirmedTransformation(from: client)
        #expect(transformation.content.target == "日本語" && transformation.content.before == "前の文")
    }

    @Test func theSurroundingTextIsLimitedOnEachSide() throws {
        let client = Client()
        let side = String(repeating: "あ", count: AITextSelection.contextScalarLimit + 5)
        client.text = side + "選択" + side
        client.selectedRange = NSRange(location: side.utf16.count, length: 2)
        let witness = try #require(client.witness())
        #expect(witness.before.utf16.count == AITextSelection.contextScalarLimit)
        #expect(witness.after.utf16.count == AITextSelection.contextScalarLimit)
    }

    @Test func aSelectionThatCannotBeReadExactlyGivesNoFacts() {
        let client = Client()
        client.actualRange = NSRange(location: 2, length: 3)
        #expect(client.field().surrounding == nil && client.witness() == nil)
        client.actualRange = nil
        client.selectedRange = NSRange(location: 3, length: 0)
        #expect(client.field().surrounding == nil && client.witness() == nil)
    }

    @Test func theResultReturnsOnlyToTheSameClientAndSelection() throws {
        let client = Client()
        var unchanged = try Self.confirmedTransformation(from: client)
        let returned = unchanged.checkReturn(to: client.field())
        let replacement = unchanged.takeReplacement(for: client.field(), witness: client.witness())
        #expect(returned && replacement == "変換した本文")

        var moved = try Self.confirmedTransformation(from: client)
        client.selectedRange = NSRange(location: 0, length: 3)
        let movedReturned = moved.checkReturn(to: client.field())
        client.selectedRange = NSRange(location: 3, length: 3)
        let movedReplacement = moved.takeReplacement(for: client.field(), witness: client.witness())
        #expect(!movedReturned && movedReplacement == nil, "a contradicting report ends the target")

        var elsewhere = try Self.confirmedTransformation(from: client)
        let other = Client()
        let otherReturned = elsewhere.checkReturn(to: other.field())
        let otherReplacement = elsewhere.takeReplacement(for: other.field(), witness: other.witness())
        #expect(!otherReturned && otherReplacement == nil, "another client with the same text is never the target")
    }
}
