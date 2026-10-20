import Foundation

/// One horizontal body keeps definitions beside candidates, even in a narrow viewport.
struct WordDefinitionsSideLayout {
    struct LeftHeights {
        var navigation: CGFloat
        var tree: CGFloat
        var details: CGFloat
        var actions: CGFloat
        var minimumNavigation: CGFloat = 0

        var total: CGFloat { navigation + tree + details + actions }
    }

    struct Frames {
        var navigation: CGRect
        var tree: CGRect
        var details: CGRect
        var actions: CGRect
        var definitions: CGRect
    }

    // These widths keep candidate controls and 18/24-point dictionary text readable.
    private static let minimumLeftWidth: CGFloat = 360
    private static let preferredLeftWidth: CGFloat = 480
    private static let minimumDefinitionWidth: CGFloat = 280
    private static let preferredDefinitionWidth: CGFloat = 360
    private static let columnGap: CGFloat = 10

    let leftWidth: CGFloat
    let definitionWidth: CGFloat
    let contentWidth: CGFloat
    let viewportWidth: CGFloat

    init(availableWidth: CGFloat, preferredLeftWidth: CGFloat, showsDefinitions: Bool) {
        let availableWidth = max(1, availableWidth)
        guard showsDefinitions else {
            leftWidth = min(availableWidth, max(1, preferredLeftWidth))
            definitionWidth = 0
            contentWidth = leftWidth
            viewportWidth = leftWidth
            return
        }
        let minimumWidth = Self.minimumLeftWidth + Self.columnGap + Self.minimumDefinitionWidth
        let preferredWidth = Self.preferredLeftWidth + Self.columnGap + Self.preferredDefinitionWidth
        contentWidth = max(minimumWidth, min(availableWidth, preferredWidth))
        viewportWidth = min(availableWidth, contentWidth)
        let extraWidth = contentWidth - minimumWidth
        leftWidth = Self.minimumLeftWidth + min(extraWidth, Self.preferredLeftWidth - Self.minimumLeftWidth)
        definitionWidth = contentWidth - leftWidth - Self.columnGap
    }

    func frames(height: CGFloat, left: LeftHeights, definitionHeight: CGFloat) -> Frames {
        let height = max(0, height)
        let actionHeight = min(left.actions, height)
        let available = max(0, height - actionHeight)
        let sharedScale = min(1, available / max(1, left.navigation + left.tree + left.details))
        let navigationHeight = min(available, max(left.minimumNavigation, left.navigation * sharedScale))
        let optionalScale = min(1, max(0, available - navigationHeight) / max(1, left.tree + left.details))
        var top = height
        func next(_ rowHeight: CGFloat) -> CGRect {
            top = max(actionHeight, top - rowHeight)
            return CGRect(x: 0, y: top, width: leftWidth, height: rowHeight)
        }
        let navigation = next(navigationHeight)
        let tree = next(left.tree * optionalScale)
        let details = next(left.details * optionalScale)
        let definitions = CGRect(x: leftWidth + (definitionWidth == 0 ? 0 : Self.columnGap),
                                 y: max(0, height - definitionHeight), width: definitionWidth,
                                 height: min(height, max(0, definitionHeight)))
        return Frames(navigation: navigation, tree: tree, details: details,
                      actions: CGRect(x: 0, y: 0, width: leftWidth, height: actionHeight), definitions: definitions)
    }

    static func retainsHover(at point: CGPoint, source: CGRect, definitions: CGRect, viewport: CGRect) -> Bool {
        guard viewport.contains(point), definitions.intersects(viewport) else {
            return false
        }
        if source.contains(point) || definitions.contains(point) {
            return true
        }
        // The gap is an actual route into this definition, not an elapsed-time grace period.
        let corridor = CGRect(x: source.maxX, y: min(source.minY, definitions.minY),
                              width: max(0, definitions.minX - source.maxX),
                              height: max(source.maxY, definitions.maxY) - min(source.minY, definitions.minY))
        return corridor.contains(point)
    }
}
