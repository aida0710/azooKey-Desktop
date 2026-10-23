import AppKit
import Core

enum MacCandidateMetrics {
    // Desktop candidates need less space than the shared touch-sized presentation.
    static func fontSize(_ size: Config.CandidateTextSize.Value) -> CGFloat {
        size == .large ? 16 : 12
    }

    static let minimumListWidth: CGFloat = 96
    static let maximumListWidth: CGFloat = 280
    static let visibleRows = 7
    // Limit the live tree to a small area while keeping longer paths scrollable.
    static let maximumTreeWidth: CGFloat = 480
    static let maximumTreeHeight: CGFloat = 110
    static let minimumTreeHeight: CGFloat = 20
    static let cardGap: CGFloat = 6
    static let definitionWidth: CGFloat = 200
    static let cornerRadius: CGFloat = 6
}
