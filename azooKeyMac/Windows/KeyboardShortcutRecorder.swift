import AppKit
import Core
import SwiftUI

/// キーボードショートカットを記録するためのビュー
struct KeyboardShortcutRecorder: NSViewRepresentable {
    @Binding var shortcut: Core.KeyboardShortcut
    var accessibilityName: String = Localization.text("ai.shortcut")

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.shortcut = shortcut
        view.setAccessibilityLabel(accessibilityName)
        view.onShortcutChanged = { newShortcut in
            shortcut = newShortcut
        }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.setAccessibilityLabel(accessibilityName)
        if nsView.shortcut != shortcut {
            nsView.shortcut = shortcut
        }
    }
}

/// NSViewベースのショートカットレコーダー
class ShortcutRecorderView: NSView {
    var shortcut: Core.KeyboardShortcut = .defaultTransformShortcut {
        didSet {
            needsDisplay = true
            publishValue()
        }
    }
    var onShortcutChanged: ((Core.KeyboardShortcut) -> Void)?

    private var isRecording = false {
        didSet {
            needsDisplay = true
            publishValue()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    private func setupView() {
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Localization.text("ai.shortcut"))
        setAccessibilityValue(shortcut.displayString)
        setAccessibilityHelp(Localization.text("shortcut.help"))
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else {
            return false
        }
        isRecording = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        return super.resignFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self) ?? false
    }

    private func publishValue() {
        let state = isRecording ? "、" + Localization.text("shortcut.recording") : ""
        setAccessibilityValue(shortcut.displayString + state)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        // Tab remains navigation, including Shift+Tab, while recording.
        if event.keyCode == 48 {
            if event.modifierFlags.contains(.shift) {
                window?.selectPreviousKeyView(self)
            } else {
                window?.selectNextKeyView(self)
            }
            return
        }

        // keyCode 53: Escape - 記録をキャンセル
        if event.keyCode == 53 {
            window?.makeFirstResponder(nil)
            return
        }

        // keyCode 51: Delete (Backspace), keyCode 117: Forward Delete - デフォルトにリセット
        if event.keyCode == 51 || event.keyCode == 117 {
            shortcut = .defaultTransformShortcut
            onShortcutChanged?(shortcut)
            window?.makeFirstResponder(nil)
            return
        }

        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            return
        }

        let key = characters.lowercased()
        let modifiers = KeyEventCore.ModifierFlag(from: event.modifierFlags)

        guard modifiers.contains(.control) ||
                modifiers.contains(.option) ||
                modifiers.contains(.shift) ||
                modifiers.contains(.command) else {
            return
        }

        let newShortcut = Core.KeyboardShortcut(key: key, modifiers: modifiers)
        shortcut = newShortcut
        onShortcutChanged?(newShortcut)
        window?.makeFirstResponder(nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let backgroundColor: NSColor = isRecording ? .controlAccentColor.withAlphaComponent(0.1) : .controlBackgroundColor
        backgroundColor.setFill()
        bounds.fill()

        let text: String
        let textColor: NSColor

        if isRecording {
            text = Localization.text("shortcut.recording")
            textColor = .secondaryLabelColor
        } else {
            text = shortcut.displayString
            textColor = .labelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: textColor
        ]

        let attributedString = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributedString.size()
        let textRect = NSRect(
            x: (bounds.width - textSize.width) / 2,
            y: (bounds.height - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )

        attributedString.draw(in: textRect)

        if isRecording {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            bounds.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 120, height: 28)
    }
}
