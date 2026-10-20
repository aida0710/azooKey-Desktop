import AppKit

/// Candidate controls accept pointer and assistive actions without taking the document's keyboard focus.
@MainActor
class CandidatePresentationButton: NSButton {
    var activate: (() -> Void)?
    var preview: ((Bool) -> Void)?
    var selected = false {
        didSet { needsDisplay = true }
    }
    var primary = false
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func isAccessibilitySelected() -> Bool { selected }

    init() {
        super.init(frame: .zero)
        target = self
        action = #selector(invoke)
        isBordered = false
        font = .systemFont(ofSize: 14, weight: .medium)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseDown(with event: NSEvent) {
        if isEnabled { performClick(nil) }
    }

    @objc private func invoke() {
        if isEnabled { activate?() }
    }

    override func mouseEntered(with event: NSEvent) { preview?(true) }
    override func mouseExited(with event: NSEvent) { preview?(false) }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil))
        super.updateTrackingAreas()
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = CandidateTheme.palette(for: effectiveAppearance)
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        (primary || selected ? palette.selection : palette.surface).setFill()
        shape.fill()
        palette.border.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: isEnabled ? (primary || selected ? palette.selectionText : palette.text) : palette.secondaryText
        ]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: max(8, (bounds.width - size.width) / 2),
                                            y: (bounds.height - size.height) / 2), withAttributes: attributes)
    }
}
