import AppKit
import Core

@MainActor
final class TreeCanvas: NSView {
    struct Edge { var nodeID: Int; var from: NSPoint; var to: NSPoint }
    var edges: [Edge] = []
    var selectedPath: Set<Int> = []
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
            CandidateScoreBadge.draw(presentation: presentation, frame: frame, palette: palette)
        }
    }
}
