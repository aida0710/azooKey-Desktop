import Cocoa
import Core

final class AISuggestionConfirmationPanel: NSPanel {
    var onSend: (() -> Void)?
    var onCancel: (() -> Void)?
    var onContextChanged: ((Bool) -> Void)?
    private let destination = NSTextField(labelWithString: "")
    private let targetText = NSTextView()
    private let contextToggle = NSButton(checkboxWithTitle: Localization.text("ai.scope.include-context"), target: nil, action: nil)
    // A scrollable preview keeps long input from covering the document.
    private static let panelSize = NSSize(width: 460, height: 290)
    private static let contentInset: CGFloat = 12
    private static let previewHeight: CGFloat = 90

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = .popUpMenu
        hasShadow = true

        let preview = NSScrollView()
        preview.hasVerticalScroller = true
        preview.borderType = .bezelBorder
        targetText.isEditable = false
        targetText.isRichText = false
        targetText.isVerticallyResizable = true
        targetText.autoresizingMask = [.width]
        targetText.textContainer?.widthTracksTextView = true
        targetText.font = .systemFont(ofSize: NSFont.systemFontSize)
        targetText.setAccessibilityLabel(Localization.text("ai.scope.target"))
        preview.documentView = targetText

        contextToggle.target = self
        contextToggle.action = #selector(contextChanged)
        let send = NSButton(title: Localization.text("ai.scope.send"), target: self, action: #selector(sendRequest))
        let cancel = NSButton(title: Localization.text("ai.scope.cancel"), target: self, action: #selector(cancelRequest))
        let buttons = NSStackView(views: [send, cancel])
        let keyboard = NSTextField(wrappingLabelWithString: Localization.text("ai.scope.keyboard"))
        keyboard.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [
            NSTextField(labelWithString: Localization.text("ai.scope.confirm")),
            destination,
            NSTextField(labelWithString: Localization.text("ai.scope.target")),
            preview, contextToggle, keyboard, buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.contentInset / 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: NSRect(origin: .zero, size: Self.panelSize))
        content.addSubview(stack)
        contentView = content
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: Self.contentInset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Self.contentInset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.contentInset),
            preview.widthAnchor.constraint(equalTo: stack.widthAnchor),
            preview.heightAnchor.constraint(equalToConstant: Self.previewHeight)
        ])
    }

    func show(configuration: AIRequestConfiguration, reading: String, includeContext: Bool, cursorLocation: CGPoint) {
        destination.stringValue = "\(Localization.text("ai.scope.destination")): \(configuration.destinationLabel)"
        targetText.string = reading
        targetText.setFrameSize(NSSize(width: Self.panelSize.width - Self.contentInset * 2, height: Self.previewHeight))
        setIncludesContext(includeContext)
        guard let screen = ScreenLookup.screen(containing: cursorLocation, fallbackWindow: self) else {
            return
        }
        let frame = WindowPositioning.frameNearCursor(
            currentFrame: .init(self.frame), screenRect: .init(screen.visibleFrame),
            cursorLocation: .init(cursorLocation), desiredSize: .init(Self.panelSize)
        ).cgRect
        setFrame(frame, display: true)
        orderFront(nil)
    }

    func setIncludesContext(_ value: Bool) {
        contextToggle.state = value ? .on : .off
    }

    @objc private func contextChanged() { onContextChanged?(contextToggle.state == .on) }
    @objc private func sendRequest() { onSend?() }
    @objc private func cancelRequest() { onCancel?() }
}
