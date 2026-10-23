import AppKit

@MainActor
final class TreeButton: NSButton {
    var clicked: ((Bool) -> Void)?
    var hovered: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    var reading = ""
    var highlightedPath = false
    var focusedNode = false
    var documentAligned = false
    static func preferredHeight(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        let verticalPadding: CGFloat = 4 // Keep Japanese glyphs inside a compact single line.
        return ceil(font.ascender - font.descender) + verticalPadding
    }
    var candidateTextFrame: NSRect {
        let inset: CGFloat = documentAligned ? 2 : 4
        let textFont = font ?? NSFont.systemFont(ofSize: 14)
        let height = textFont.ascender - textFont.descender + 2
        return NSRect(x: inset, y: (bounds.height - height) / 2, width: bounds.width - inset * 2, height: height)
    }
    override var acceptsFirstResponder: Bool { false }
    override func isAccessibilitySelected() -> Bool { highlightedPath }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        font = .systemFont(ofSize: 12)
        target = self
        action = #selector(activate)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func activate() { clicked?(false) }
    override func mouseDown(with event: NSEvent) { clicked?(event.clickCount > 1) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered?(true) }
    override func mouseExited(with event: NSEvent) { hovered?(false) }
    override func draw(_ dirtyRect: NSRect) {
        let palette = CandidateTheme.palette(for: effectiveAppearance)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        (highlightedPath ? palette.selection : palette.surface).setFill()
        shape.fill()
        if highlightedPath {
            palette.text.setStroke()
            shape.lineWidth = 2
            shape.stroke()
        }
        if focusedNode {
            (highlightedPath ? palette.selectionText : palette.text).setStroke()
            let underline = NSBezierPath()
            underline.lineWidth = 2
            underline.move(to: NSPoint(x: 6, y: bounds.height - 4))
            underline.line(to: NSPoint(x: bounds.width - 6, y: bounds.height - 4))
            underline.stroke()
        }
        let style = NSMutableParagraphStyle()
        style.alignment = documentAligned ? .left : .center
        style.lineBreakMode = .byTruncatingTail
        let textFont = font ?? NSFont.systemFont(ofSize: 18)
        (title as NSString).draw(in: candidateTextFrame,
                                withAttributes: [.font: textFont, .foregroundColor: highlightedPath ? palette.selectionText : palette.text,
                                                 .paragraphStyle: style])
    }
}
