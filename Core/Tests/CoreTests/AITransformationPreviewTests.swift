@testable import Core
import Testing

struct AITransformationPreviewTests {
    @Test func regenerationCannotApplyThePreviousPreviewWhileWaiting() {
        var preview = AITransformationPreview()
        let first = preview.begin()
        preview.complete("前回の本文", for: first)
        #expect(preview.applicableText == "前回の本文")

        let second = preview.begin()
        #expect(preview.isLoading)
        #expect(preview.applicableText == nil)
        preview.complete("新しい本文", for: second)
        #expect(preview.applicableText == "新しい本文")
    }

    @Test func changingInstructionsOrScopeRejectsTheOldCompletion() {
        var preview = AITransformationPreview()
        let request = preview.begin()
        preview.invalidate()
        let accepted = preview.complete("変更前の指示への応答", for: request)
        #expect(!accepted)
        #expect(preview.applicableText == nil)
        #expect(!preview.isLoading)
    }

    @Test func reverseResponsesCannotReplaceTheNewPreview() {
        var preview = AITransformationPreview()
        let first = preview.begin()
        preview.invalidate()
        let second = preview.begin()
        preview.complete("新しい本文", for: second)
        let accepted = preview.complete("古い本文", for: first)
        #expect(!accepted)
        #expect(preview.applicableText == "新しい本文")
    }

    @Test func oldFailureDoesNotEndTheCurrentRequest() {
        var preview = AITransformationPreview()
        let first = preview.begin()
        let second = preview.begin()
        let accepted = preview.complete(nil, for: first)
        #expect(!accepted)
        #expect(preview.isLoading)
        preview.complete("現在の応答", for: second)
        #expect(preview.applicableText == "現在の応答")
    }

    @Test(arguments: [nil, ""] as [String?])
    func emptyOrFailedRegenerationCannotApplyStaleText(response: String?) {
        var preview = AITransformationPreview()
        let first = preview.begin()
        preview.complete("前回の本文", for: first)
        let second = preview.begin()
        preview.complete(response, for: second)
        #expect(!preview.isLoading)
        #expect(preview.applicableText == nil)
    }
}
