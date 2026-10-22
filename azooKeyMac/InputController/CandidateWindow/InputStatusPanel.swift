import Cocoa
import Core

/// Status stays outside the document and never takes keyboard focus.
final class InputStatusPanel: NSPanel {
    private let label = NSTextField(labelWithString: "")
    // Keep the status legible while leaving space between it and the caret.
    private static let horizontalInset: CGFloat = 12
    private static let verticalInset: CGFloat = 8

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .popUpMenu
        hasShadow = true
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.setAccessibilityRole(.staticText)
        contentView?.addSubview(label)
    }

    func show(key: String, cursorLocation: CGPoint) {
        show(message: Localization.text(key), cursorLocation: cursorLocation)
    }

    func show(message: String, cursorLocation: CGPoint) {
        label.stringValue = message
        label.setAccessibilityLabel(label.stringValue)
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: Self.horizontalInset, y: Self.verticalInset))
        let size = NSSize(
            width: label.frame.width + Self.horizontalInset * 2,
            height: label.frame.height + Self.verticalInset * 2
        )
        guard let screen = ScreenLookup.screen(containing: cursorLocation, fallbackWindow: self) else {
            return
        }
        let frame = WindowPositioning.frameNearCursor(
            currentFrame: .init(self.frame), screenRect: .init(screen.visibleFrame),
            cursorLocation: .init(cursorLocation), desiredSize: .init(size)
        ).cgRect
        setFrame(frame, display: true)
        orderFront(nil)
    }
}
