import Core
import XCTest

@testable import azooKeyMac

@MainActor
final class UserDictionaryEditorModelTests: XCTestCase {
    func testCancelAfterAddingDoesNotCreateAnEmptyEntry() {
        let model = makeModel()
        model.beginAdding()
        model.cancelChanges()
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertEqual(model.entries[0].word, "日本語")
    }

    func testCancelEditingPreservesTheOriginalEntryAndIdentifier() {
        let model = makeModel()
        let identifier = model.entries[0].id
        model.beginEditing(identifier)
        model.draftWord = "変更中"
        model.cancelEditing()
        XCTAssertEqual(model.entries[0].id, identifier)
        XCTAssertEqual(model.entries[0].word, "日本語")
    }

    func testCancelChangesRestoresDeletedEntries() {
        let model = makeModel()
        let identifier = model.entries[0].id
        model.remove(identifier)
        XCTAssertTrue(model.entries.isEmpty)
        model.cancelChanges()
        XCTAssertEqual(model.entries[0].id, identifier)
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testFailedSaveKeepsTheDraftAndCanBeRetried() async {
        var attempts = 0
        let model = UserDictionaryEditorModel(entries: []) { _ in
            attempts += 1
            return attempts == 1 ? .saveFailed(messageKey: "persistenceFailed") : .saved
        }
        model.beginAdding()
        model.draftWord = "日本語"
        model.draftReading = "にほんご"
        let identifier = model.draft?.id
        await model.save()
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(model.draft?.id, identifier)
        XCTAssertEqual(model.failureMessageKey, "persistenceFailed")
        await model.save()
        XCTAssertEqual(model.entries[0].id, identifier)
        XCTAssertNil(model.draft)
        XCTAssertTrue(model.didSave)
    }

    func testInvalidReadingKeepsItsRowAndReasonVisible() async {
        let entry = Config.UserDictionaryEntry(word: "日本語", reading: "漢字")
        let issue = UserDictionaryValidation.Issue(rowID: entry.id, field: .reading, reason: .unsupportedCharacter)
        let model = UserDictionaryEditorModel(entries: [entry]) { _ in .validationFailed([issue]) }
        model.beginEditing(entry.id)
        await model.save()
        XCTAssertEqual(model.issues, [issue])
        XCTAssertEqual(model.draft?.reading, "漢字")
        XCTAssertFalse(model.didSave)
    }

    func testSavedEntryRemainsWhenLaterChangesAreCanceled() async {
        let model = makeModel()
        let identifier = model.entries[0].id
        model.beginEditing(identifier)
        model.draftWord = "保存した語"
        await model.save()
        model.remove(identifier)
        model.cancelChanges()
        XCTAssertEqual(model.entries[0].word, "保存した語")
        XCTAssertEqual(model.entries[0].id, identifier)
    }

    func testSavingTwiceWhileTheFirstSaveIsPendingWritesOnce() async {
        var resumeSave: CheckedContinuation<UserDictionaryEditorOutcome, Never>?
        var signalStarted: AsyncStream<Void>.Continuation?
        let started = AsyncStream<Void> { signalStarted = $0 }
        var writes = 0
        let model = UserDictionaryEditorModel(entries: []) { _ in
            writes += 1
            return await withCheckedContinuation {
                resumeSave = $0
                signalStarted?.yield(())
            }
        }
        model.beginAdding()
        model.draftWord = "日本語"
        model.draftReading = "にほんご"
        let pending = Task { await model.save() }
        var events = started.makeAsyncIterator()
        await events.next()
        XCTAssertTrue(model.isSaving)
        await model.save()
        XCTAssertEqual(writes, 1)
        resumeSave?.resume(returning: .saved)
        await pending.value
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.entries.count, 1)
    }

    func testExternalChangesDoNotOverwriteAnOpenDraft() {
        let model = makeModel()
        model.beginEditing(model.entries[0].id)
        model.draftWord = "変更中"
        model.refreshIfUnchanged([])
        XCTAssertEqual(model.draft?.word, "変更中")
        XCTAssertEqual(model.entries.count, 1)
        model.cancelChanges()
        model.refreshIfUnchanged([])
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testIncompleteRecoveryKeepsTheWarningAndPreventsAnotherSave() async {
        var writes = 0
        let model = UserDictionaryEditorModel(entries: []) { _ in
            writes += 1
            return .saveFailed(messageKey: "rollbackFailed")
        }
        model.beginAdding()
        await model.save()
        model.cancelChanges()
        await model.save()
        XCTAssertEqual(writes, 1)
        XCTAssertTrue(model.needsRecovery)
        XCTAssertEqual(model.failureMessageKey, "rollbackFailed")
    }

    private func makeModel() -> UserDictionaryEditorModel {
        UserDictionaryEditorModel(entries: [.init(word: "日本語", reading: "にほんご")]) { _ in .saved }
    }
}
