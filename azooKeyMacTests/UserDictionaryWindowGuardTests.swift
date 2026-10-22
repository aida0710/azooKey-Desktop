import AppKit
import Core
import XCTest

@testable import azooKeyMac

@MainActor
final class UserDictionaryWindowGuardTests: XCTestCase {
    func testNativeCloseIsRefusedUntilSavingFinishes() async {
        var resumeSave: CheckedContinuation<UserDictionaryEditorOutcome, Never>?
        var signalStarted: AsyncStream<Void>.Continuation?
        let started = AsyncStream<Void> { signalStarted = $0 }
        let model = UserDictionaryEditorModel(entries: []) { _ in
            await withCheckedContinuation {
                resumeSave = $0
                signalStarted?.yield(())
            }
        }
        model.beginAdding()
        model.draftWord = "登録する語"
        model.draftReading = "とうろくするご"
        let coordinator = makeCoordinator(model: model)
        let window = makeWindow(coordinator: coordinator)
        defer {
            coordinator.detach()
            window.close()
        }
        let pending = Task { await model.save() }
        var events = started.makeAsyncIterator()
        await events.next()

        window.performClose(nil)

        XCTAssertTrue(window.isVisible)
        XCTAssertTrue(model.isSaving)
        XCTAssertNotNil(model.draft)
        resumeSave?.resume(returning: .saved)
        await pending.value

        window.performClose(nil)

        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.entries.first?.word, "登録する語")
    }

    func testNativeCloseDiscardsAnUnsavedEditAndKeepsTheSavedEntry() {
        let entry = Config.UserDictionaryEntry(word: "保存済み", reading: "ほぞんずみ")
        let model = UserDictionaryEditorModel(entries: [entry]) { _ in
            XCTFail("Closing an editor must not save its draft")
            return .saved
        }
        model.beginEditing(entry.id)
        model.draftWord = "未保存の変更"
        let coordinator = makeCoordinator(model: model)
        let window = makeWindow(coordinator: coordinator)
        defer { coordinator.detach() }

        window.performClose(nil)

        XCTAssertFalse(window.isVisible)
        XCTAssertNil(model.draft)
        XCTAssertEqual(model.entries.first?.id, entry.id)
        XCTAssertEqual(model.entries.first?.word, "保存済み")
    }

    func testNativeCloseWaitsForTheImportPreviewToBeDismissed() async throws {
        let model = UserDictionaryEditorModel(entries: []) { _ in .saved }
        let document = try UserDictionaryExchange.parse(UserDictionaryExchange.export([]), format: .json)
        let preview = try UserDictionaryImportPreview.make(document: document, existing: [])
        await model.prepareImport { _ in preview }
        let coordinator = makeCoordinator(model: model)
        let window = makeWindow(coordinator: coordinator)
        defer { coordinator.detach() }

        window.performClose(nil)

        XCTAssertTrue(window.isVisible)
        XCTAssertNotNil(model.importPreview)
        model.cancelImport()
        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertTrue(model.entries.isEmpty)
    }

    func testPreviousDelegateCanRefuseCloseAndReceivesCloseAfterDraftCancellation() {
        let model = UserDictionaryEditorModel(entries: []) { _ in .saved }
        model.beginAdding()
        let delegate = CloseDelegate()
        delegate.allowClose = false
        delegate.onClose = { XCTAssertNil(model.draft) }
        let coordinator = makeCoordinator(model: model)
        let window = makeWindow(coordinator: coordinator, delegate: delegate)
        defer { coordinator.detach() }

        window.performClose(nil)

        XCTAssertTrue(window.isVisible)
        XCTAssertNotNil(model.draft)
        XCTAssertEqual(delegate.closeRequests, 1)
        XCTAssertEqual(delegate.closes, 0)
        delegate.allowClose = true

        window.performClose(nil)

        XCTAssertFalse(window.isVisible)
        XCTAssertNil(model.draft)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertEqual(delegate.closeRequests, 2)
        XCTAssertEqual(delegate.closes, 1)
    }

    func testDismantlingRestoresThePreviousDelegateAndPreservesAnotherOwnersReplacement() throws {
        let original = CloseDelegate()
        let replacement = CloseDelegate()
        let coordinator = UserDictionaryWindowGuard(canClose: { true }, onClose: {}).makeCoordinator()
        let window = makeWindow(coordinator: coordinator, delegate: original)
        defer { window.close() }
        let view = try XCTUnwrap(window.contentView as? UserDictionaryWindowGuard.WindowView)
        XCTAssertTrue(window.delegate === coordinator)

        UserDictionaryWindowGuard.dismantleNSView(view, coordinator: coordinator)

        XCTAssertTrue(window.delegate === original)
        coordinator.attach(to: window)
        window.delegate = replacement

        coordinator.detach()

        XCTAssertTrue(window.delegate === replacement)
    }

    private func makeCoordinator(
        model: UserDictionaryEditorModel
    ) -> UserDictionaryWindowGuard.Coordinator {
        UserDictionaryWindowGuard(
            canClose: { model.canClose },
            onClose: { model.cancelChanges() }
        ).makeCoordinator()
    }

    private func makeWindow(
        coordinator: UserDictionaryWindowGuard.Coordinator,
        delegate: (any NSWindowDelegate)? = nil
    ) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.delegate = delegate
        window.contentView = UserDictionaryWindowGuard.WindowView(coordinator: coordinator)
        window.orderFront(nil)
        return window
    }

    @MainActor
    private final class CloseDelegate: NSObject, NSWindowDelegate {
        var allowClose = true
        var closeRequests = 0
        var closes = 0
        var onClose: () -> Void = {}

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            closeRequests += 1
            return allowClose
        }

        func windowWillClose(_ notification: Notification) {
            closes += 1
            onClose()
        }
    }
}
