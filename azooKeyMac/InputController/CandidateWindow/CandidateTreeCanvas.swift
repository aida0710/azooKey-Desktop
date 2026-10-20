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
    var candidateNumber: String?
    // Keep the label and its lower-left number inside one pointer target.
    private let titleTopInset: CGFloat = 3
    private let numberInset: CGFloat = 4
    private let numberBottomInset: CGFloat = 3
    private let numberTextInset: CGFloat = 3
    private static let minimumHeight: CGFloat = 44
    private static let minimumNumberFontSize: CGFloat = 11
    private static let numberFontReduction: CGFloat = 8
    private static let textAndNumberInsets: CGFloat = 11
    private static let unnumberedInsets: CGFloat = 14
    private var numberFont: NSFont {
        Self.numberFont(fontSize: font?.pointSize ?? 18)
    }
    private static func numberFont(fontSize: CGFloat) -> NSFont {
        .monospacedSystemFont(ofSize: max(minimumNumberFontSize, fontSize - numberFontReduction), weight: .medium)
    }
    static func preferredHeight(fontSize: CGFloat, hasNumber: Bool) -> CGFloat {
        let titleFont = NSFont.systemFont(ofSize: fontSize)
        let numberFont = numberFont(fontSize: fontSize)
        let numberedHeight = titleFont.ascender - titleFont.descender + numberFont.ascender - numberFont.descender + textAndNumberInsets
        return max(minimumHeight, ceil(hasNumber ? numberedHeight : fontSize + unnumberedInsets))
    }
    var candidateTextFrame: NSRect {
        let inset: CGFloat = documentAligned ? 2 : 4
        let textFont = font ?? NSFont.systemFont(ofSize: 18)
        let height = textFont.ascender - textFont.descender + 2
        let y = candidateNumber == nil ? (bounds.height - height) / 2 : bounds.height - height - titleTopInset
        return NSRect(x: inset, y: y, width: bounds.width - inset * 2, height: height)
    }
    var numberBadgeFrame: NSRect? {
        guard let candidateNumber else {
            return nil
        }
        let size = (candidateNumber as NSString).size(withAttributes: [.font: numberFont])
        return NSRect(x: numberInset, y: numberBottomInset, width: size.width + numberTextInset * 2, height: size.height)
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
        if let candidateNumber, let badge = numberBadgeFrame {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: numberFont,
                .foregroundColor: highlightedPath ? palette.selectionText : palette.text
            ]
            (candidateNumber as NSString).draw(at: NSPoint(x: badge.minX + numberTextInset, y: badge.minY), withAttributes: attributes)
        }
    }
}
