import Core
import Foundation
import XCTest

@testable import azooKeyMac

@MainActor
final class UserDictionaryExchangeModelTests: XCTestCase {
    func testSearchFindsWordsReadingsAndHintsAndEditsOnlyTheSelectedIdentifier() async throws {
        let first = Config.UserDictionaryEntry(word: "先頭", reading: "せんとう", hint: "分類A")
        let target = Config.UserDictionaryEntry(word: "日本語", reading: "にほんご", hint: "Unique marker")
        let model = UserDictionaryEditorModel(entries: [first, target]) { _ in .saved }
        for query in ["日本", "にほん", "UNIQUE MARKER"] {
            model.searchText = query
            XCTAssertEqual(model.visibleEntries.map(\.id), [target.id])
        }
        model.sortOrder = [KeyPathComparator(\Config.UserDictionaryEntry.word, order: .reverse)]
        model.beginEditing(try XCTUnwrap(model.visibleEntries.first).id)
        model.draftWord = "変更した語"
        await model.save()
        XCTAssertEqual(model.entries.first?.word, first.word)
        XCTAssertEqual(model.entries.last?.word, "変更した語")
        XCTAssertEqual(model.entries.last?.id, target.id)
        model.searchText = "変更した語"
        model.remove(try XCTUnwrap(model.visibleEntries.first).id)
        XCTAssertEqual(model.entries.map(\.id), [first.id])
    }

    func testSortingChangesTheDisplayOrderWithoutReorderingTheDraft() {
        let entries = [
            Config.UserDictionaryEntry(word: "C", reading: "あ", hint: "b"),
            Config.UserDictionaryEntry(word: "A", reading: "う", hint: "c"),
            Config.UserDictionaryEntry(word: "B", reading: "い", hint: "a")
        ]
        let model = UserDictionaryEditorModel(entries: entries) { _ in .saved }
        model.sortOrder = [KeyPathComparator(\Config.UserDictionaryEntry.word)]
        XCTAssertEqual(model.visibleEntries.map(\.word), ["A", "B", "C"])
        model.sortOrder = [KeyPathComparator(\Config.UserDictionaryEntry.reading, order: .reverse)]
        XCTAssertEqual(model.visibleEntries.map(\.reading), ["う", "い", "あ"])
        model.sortOrder = [KeyPathComparator(\Config.UserDictionaryEntry.nonNullHint)]
        XCTAssertEqual(model.visibleEntries.map(\.nonNullHint), ["a", "b", "c"])
        XCTAssertEqual(model.entries.map(\.id), entries.map(\.id))
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testCancelingImportKeepsEarlierUnsavedChangesAndDoesNotSave() async throws {
        let original = Config.UserDictionaryEntry(word: "元の語", reading: "もとのご")
        let removed = Config.UserDictionaryEntry(word: "削除予定", reading: "さくじょよてい")
        var saves = 0
        let model = UserDictionaryEditorModel(entries: [original, removed]) { _ in
            saves += 1
            return .saved
        }
        model.remove(removed.id)
        await model.prepareImport { _ in nil }
        XCTAssertEqual(model.entries.map(\.id), [original.id])
        XCTAssertTrue(model.hasUnsavedChanges)
        let preview = try makePreview(existing: model.entries)
        await model.prepareImport { _ in preview }
        model.cancelImport()
        XCTAssertNil(model.importPreview)
        XCTAssertEqual(model.entries.map(\.id), [original.id])
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(saves, 0)
    }

    func testApplyingPreviewAddsOnlyNewEntriesToTheDraftUntilSave() async throws {
        let original = Config.UserDictionaryEntry(word: "元の語", reading: "もとのご")
        var saved: [Config.UserDictionaryEntry] = []
        let model = UserDictionaryEditorModel(entries: [original]) {
            saved = $0
            return .saved
        }
        let preview = try makePreview(existing: model.entries)
        await model.prepareImport { _ in preview }
        XCTAssertEqual(model.entries.count, 1)
        model.applyImport()
        XCTAssertEqual(model.entries.map(\.word), ["元の語", "日本語"])
        XCTAssertEqual(model.entries[0].id, original.id)
        XCTAssertTrue(saved.isEmpty)
        XCTAssertTrue(model.hasUnsavedChanges)
        await model.save()
        XCTAssertEqual(saved.map(\.id), model.entries.map(\.id))
        XCTAssertFalse(model.hasUnsavedChanges)
    }

    func testStalePreviewIsRejectedWithoutReplacingCurrentEntries() async throws {
        let original = Config.UserDictionaryEntry(word: "元の語", reading: "もとのご")
        let preview = try makePreview(existing: [original])
        var changed = original
        changed.word = "変更済み"
        let model = UserDictionaryEditorModel(entries: [changed]) { _ in .saved }
        await model.prepareImport { _ in preview }
        model.applyImport()
        XCTAssertEqual(model.entries.map(\.word), ["変更済み"])
        XCTAssertEqual(model.failureMessageKey, "importStalePreview")
        XCTAssertNil(model.importPreview)
    }

    func testThousandImportedEntriesCanBeAddedAndEditedByIdentifier() async throws {
        var saves = 0
        let model = UserDictionaryEditorModel(entries: []) { _ in
            saves += 1
            return .saved
        }
        let preview = try makePreview(existing: [], imported: thousandEntries())
        await model.prepareImport { _ in preview }
        XCTAssertEqual(model.importPreview?.counts.additions, 1_000)
        XCTAssertTrue(model.canApplyImport)
        model.applyImport()
        XCTAssertEqual(model.entries.count, 1_000)
        XCTAssertTrue(model.canAdd)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertEqual(saves, 0)
        let identifiers = model.entries.map(\.id)
        model.searchText = "単語0500"
        let target = try XCTUnwrap(model.visibleEntries.first)
        model.beginEditing(target.id)
        model.draftHint = "取込後の編集"
        await model.save()
        XCTAssertEqual(model.entries[500].nonNullHint, "取込後の編集")
        XCTAssertEqual(model.entries.map(\.id), identifiers)
        XCTAssertEqual(saves, 1)
    }

    func testImportInProgressBlocksAnotherFileOperationSaveEditingAndClose() async {
        let entry = Config.UserDictionaryEntry(word: "日本語", reading: "にほんご")
        let model = UserDictionaryEditorModel(entries: [entry]) { _ in
            XCTFail("Importing must not persist the dictionary")
            return .saved
        }
        var resumeImport: CheckedContinuation<UserDictionaryImportPreview.Preview?, Never>?
        var signalStarted: AsyncStream<Void>.Continuation?
        let started = AsyncStream<Void> { signalStarted = $0 }
        let pending = Task {
            await model.prepareImport { _ in
                await withCheckedContinuation {
                    resumeImport = $0
                    signalStarted?.yield(())
                }
            }
        }
        var events = started.makeAsyncIterator()
        await events.next()
        XCTAssertFalse(model.canClose)
        model.remove(entry.id)
        model.beginEditing(entry.id)
        await model.save()
        await model.prepareImport { _ in
            XCTFail("A second import must not open another panel")
            return nil
        }
        await model.export { _ in
            XCTFail("Export must wait for import to finish")
            return false
        }
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.entries.map(\.id), [entry.id])
        resumeImport?.resume(returning: nil)
        await pending.value
        XCTAssertTrue(model.canClose)
    }

    func testExportUsesAllDraftEntriesAndCancelDoesNotMarkThemSaved() async {
        let entries = [
            Config.UserDictionaryEntry(word: "一", reading: "いち"),
            Config.UserDictionaryEntry(word: "二", reading: "に"),
            Config.UserDictionaryEntry(word: "三", reading: "さん")
        ]
        let model = UserDictionaryEditorModel(entries: entries) { _ in .saved }
        model.remove(entries[2].id)
        model.searchText = "一"
        await model.export {
            XCTAssertEqual($0.map(\.id), Array(entries.prefix(2)).map(\.id))
            return false
        }
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertFalse(model.didExport)
        XCTAssertFalse(model.didSave)
        await model.export { _ in true }
        XCTAssertTrue(model.didExport)
        XCTAssertTrue(model.hasUnsavedChanges)
        XCTAssertFalse(model.didSave)
    }

    func testThousandEntriesRemainSearchableAndEditableByIdentifier() async throws {
        let entries = thousandEntries()
        let model = UserDictionaryEditorModel(entries: entries) { _ in .saved }
        model.sortOrder = [KeyPathComparator(\Config.UserDictionaryEntry.word, order: .reverse)]
        model.searchText = "単語0500"
        let target = try XCTUnwrap(model.visibleEntries.first)
        XCTAssertEqual(target.id, entries[500].id)
        model.beginEditing(target.id)
        model.draftHint = "変更したヒント"
        await model.save()
        XCTAssertEqual(model.entries.count, 1_000)
        XCTAssertEqual(model.entries[500].nonNullHint, "変更したヒント")
        XCTAssertEqual(model.entries.map(\.id), entries.map(\.id))
    }

    func testThousandEntrySearchAndEditPerformance() {
        let model = UserDictionaryEditorModel(entries: thousandEntries()) { _ in .saved }
        measure {
            model.searchText = "分類5"
            XCTAssertEqual(model.visibleEntries.count, 100)
            let identifier = model.visibleEntries[50].id
            model.beginEditing(identifier)
            model.draftWord = "編集した語"
            model.cancelEditing()
            XCTAssertNil(model.draft)
        }
    }

    private func thousandEntries() -> [Config.UserDictionaryEntry] {
        let kana = Array("あいうえおかきくけこ")
        return (0..<1_000).map { index in
            let number = String(format: "%04d", index)
            let suffix = String(number.compactMap { $0.wholeNumberValue }.map { kana[$0] })
            return .init(word: "単語" + number, reading: "ことば" + suffix, hint: "分類\(index % 10)")
        }
    }

    private func makePreview(
        existing: [Config.UserDictionaryEntry],
        imported: [Config.UserDictionaryEntry] = [.init(word: "日本語", reading: "にほんご", hint: "備考")]
    ) throws -> UserDictionaryImportPreview.Preview {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let characters = directory.appendingPathComponent("charID.chid")
        try "アイウエオカキクケコトバニホンゴ".write(to: characters, atomically: true, encoding: .utf8)
        let content = try UserDictionaryExchange.export(imported)
        let document = try UserDictionaryExchange.parse(content, format: .json)
        return try UserDictionaryImportPreview.make(document: document, existing: existing, charIDFileURL: characters)
    }
}
