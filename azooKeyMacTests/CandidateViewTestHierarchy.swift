import AppKit

/// The candidate body may gain clip views without changing which controls a test exercises.
@MainActor
func candidateViewDescendants(in view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { candidateViewDescendants(in: $0) }
}
