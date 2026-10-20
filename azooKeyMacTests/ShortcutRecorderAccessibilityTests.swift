import AppKit
import Core
import XCTest

@testable import azooKeyMac

@MainActor
final class ShortcutRecorderAccessibilityTests: XCTestCase {
    private var window: NSWindow!
    private var previous: NSTextField!
    private var recorder: ShortcutRecorderView!
    private var next: NSTextField!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
                          styleMask: .titled, backing: .buffered, defer: false)
        previous = NSTextField(string: "")
        recorder = ShortcutRecorderView()
        next = NSTextField(string: "")
        window.contentView = NSStackView(views: [previous, recorder, next])
        previous.nextKeyView = recorder
        recorder.nextKeyView = next
        next.nextKeyView = previous
        window.makeFirstResponder(recorder)
    }

    override func tearDown() {
        window.orderOut(nil)
        window.contentView = nil
        window = nil
        super.tearDown()
    }

    private func key(_ code: UInt16, text: String, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: text,
                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: code)!
    }

    func testTabAndShiftTabMoveFocusWithoutRecordingAShortcut() {
        let original = recorder.shortcut
        var changes: [Core.KeyboardShortcut] = []
        recorder.onShortcutChanged = { changes.append($0) }
        recorder.keyDown(with: key(48, text: "\t"))
        XCTAssertTrue(window.firstResponder === next || window.firstResponder === next.currentEditor())
        window.makeFirstResponder(recorder)
        recorder.keyDown(with: key(48, text: "\t", modifiers: .shift))
        XCTAssertTrue(window.firstResponder === previous || window.firstResponder === previous.currentEditor())
        XCTAssertEqual(recorder.shortcut, original)
        XCTAssertTrue(changes.isEmpty)
    }

    func testRecordingPublishesTheNameRoleCurrentValueAndHelp() {
        recorder.setAccessibilityLabel("AI変換のショートカット")
        XCTAssertEqual(recorder.accessibilityRole(), .button)
        XCTAssertEqual(recorder.accessibilityLabel(), "AI変換のショートカット")
        XCTAssertFalse(recorder.accessibilityHelp()?.isEmpty ?? true)
        recorder.keyDown(with: key(0, text: "a", modifiers: [.control, .option]))
        XCTAssertEqual(recorder.shortcut, Core.KeyboardShortcut(key: "a", modifiers: [.control, .option]))
        XCTAssertEqual(recorder.accessibilityValue() as? String, recorder.shortcut.displayString)
        XCTAssertTrue(recorder.accessibilityPerformPress())
        XCTAssertTrue((recorder.accessibilityValue() as? String)?.contains(Localization.text("shortcut.recording")) ?? false)
        recorder.keyDown(with: key(53, text: "\u{1b}"))
        XCTAssertEqual(recorder.accessibilityValue() as? String, recorder.shortcut.displayString)
    }
}
