import AppKit

/// The rounded, bordered background of each candidate block: the list or tree,
/// and the definition card beside it. Like the system input method's panels,
/// each block keeps its own edge against a white document.
@MainActor
enum CandidateBlockBackground {
    static func draw(in frame: NSRect, appearance: NSAppearance) {
        let palette = CandidateTheme.palette(for: appearance)
        // Inset by half the line so the whole border stays inside the block.
        let inset = MacCandidateMetrics.borderWidth / 2
        let path = NSBezierPath(roundedRect: frame.insetBy(dx: inset, dy: inset),
                                xRadius: MacCandidateMetrics.cornerRadius, yRadius: MacCandidateMetrics.cornerRadius)
        palette.background.setFill()
        path.fill()
        path.lineWidth = MacCandidateMetrics.borderWidth
        palette.border.setStroke()
        path.stroke()
    }
}
