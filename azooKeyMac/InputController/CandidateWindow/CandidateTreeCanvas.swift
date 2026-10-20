import AppKit
import Core

@MainActor
final class TreeCanvas: NSView {
    struct Edge { var nodeID: Int; var from: NSPoint; var to: NSPoint }
    var edges: [Edge] = []
    var selectedPath: Set<Int> = []
    var scores: [Int: Int] = [:]
    var scorePresentations: [Int: CandidateScorePresentation] = [:]
    var nodeFrames: [Int: NSRect] = [:]
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let palette = CandidateTheme.palette(for: effectiveAppearance)
        palette.background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        for edge in edges {
            let selected = selectedPath.contains(edge.nodeID)
            (selected ? palette.text : palette.border).setStroke()
            let path = NSBezierPath()
            path.lineWidth = selected ? 3 : 1
            if !selected { path.setLineDash([2, 3], count: 2, phase: 0) }
            path.move(to: edge.from)
            let middle = (edge.from.x + edge.to.x) / 2
            path.curve(to: edge.to, controlPoint1: NSPoint(x: middle, y: edge.from.y), controlPoint2: NSPoint(x: middle, y: edge.to.y))
            path.stroke()
        }
        palette.text.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 15, width: 6, height: 6)).fill()
        for (id, frame) in nodeFrames {
            guard let presentation = scorePresentations[id] else { continue }
            CandidateScoreBadge.draw(presentation: presentation, score: scores[id], frame: frame, palette: palette)
        }
    }
}

@MainActor
final class TreeButton: NSButton {
    var clicked: ((Bool) -> Void)?
    var hovered: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?
    var reading = ""
    var highlightedPath = false
    var focusedNode = false
    var documentAligned = false
    var compactBadge = false
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
        let inset: CGFloat = compactBadge ? 1 : (documentAligned ? 2 : 4)
        let textFont = font ?? NSFont.systemFont(ofSize: 18)
        let height = textFont.ascender - textFont.descender + 2
        (title as NSString).draw(in: NSRect(x: inset, y: (bounds.height - height) / 2, width: bounds.width - inset * 2, height: height),
                                withAttributes: [.font: textFont, .foregroundColor: highlightedPath ? palette.selectionText : palette.text,
                                                 .paragraphStyle: style])
    }
}
