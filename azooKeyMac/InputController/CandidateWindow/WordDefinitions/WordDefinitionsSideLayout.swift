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
        var candidateCard: CGRect
        var navigation: CGRect
        var tree: CGRect
        var details: CGRect
        var actions: CGRect
        var definitions: CGRect
    }

    // A normal IME list stays small; larger candidate text expands both cards naturally.
    private static let candidateWidth: CGFloat = 260
    private static let definitionWidth: CGFloat = 280
    private static let standardFontSize: CGFloat = 18
    private static let columnGap: CGFloat = 10

    let leftWidth: CGFloat
    let definitionWidth: CGFloat
    let contentWidth: CGFloat
    let viewportWidth: CGFloat

    init(availableWidth: CGFloat, preferredLeftWidth: CGFloat, showsDefinitions: Bool,
         compactMenu: Bool = false, fontSize: CGFloat = 18) {
        let availableWidth = max(1, availableWidth)
        if compactMenu {
            let scale = max(1, fontSize / Self.standardFontSize)
            leftWidth = Self.candidateWidth * scale
            definitionWidth = showsDefinitions ? Self.definitionWidth * scale : 0
            contentWidth = leftWidth + (showsDefinitions ? Self.columnGap + definitionWidth : 0)
            viewportWidth = min(availableWidth, contentWidth)
            return
        }
        guard showsDefinitions else {
            leftWidth = min(availableWidth, max(1, preferredLeftWidth))
            definitionWidth = 0
            contentWidth = leftWidth
            viewportWidth = leftWidth
            return
        }
        leftWidth = max(1, preferredLeftWidth)
        contentWidth = leftWidth + Self.columnGap + Self.definitionWidth
        viewportWidth = min(availableWidth, contentWidth)
        definitionWidth = contentWidth - leftWidth - Self.columnGap
    }

    func frames(height: CGFloat, left: LeftHeights, definitionHeight: CGFloat) -> Frames {
        let height = max(0, height)
        let candidateHeight = min(height, left.total)
        let candidateBottom = height - candidateHeight
        let actionHeight = min(left.actions, candidateHeight)
        let available = max(0, candidateHeight - actionHeight)
        let sharedScale = min(1, available / max(1, left.navigation + left.tree + left.details))
        let navigationHeight = min(available, max(left.minimumNavigation, left.navigation * sharedScale))
        let optionalScale = min(1, max(0, available - navigationHeight) / max(1, left.tree + left.details))
        var top = height
        func next(_ rowHeight: CGFloat) -> CGRect {
            top = max(candidateBottom + actionHeight, top - rowHeight)
            return CGRect(x: 0, y: top, width: leftWidth, height: rowHeight)
        }
        let navigation = next(navigationHeight)
        let tree = next(left.tree * optionalScale)
        let details = next(left.details * optionalScale)
        let definitions = CGRect(x: leftWidth + (definitionWidth == 0 ? 0 : Self.columnGap),
                                 y: max(0, height - definitionHeight), width: definitionWidth,
                                 height: min(height, max(0, definitionHeight)))
        return Frames(candidateCard: CGRect(x: 0, y: candidateBottom, width: leftWidth, height: candidateHeight),
                      navigation: navigation, tree: tree, details: details,
                      actions: CGRect(x: 0, y: candidateBottom, width: leftWidth, height: actionHeight), definitions: definitions)
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
