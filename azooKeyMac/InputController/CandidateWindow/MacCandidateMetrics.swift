import AppKit
import Core

enum MacCandidateMetrics {
    // Desktop candidates need less space than the shared touch-sized presentation.
    static func fontSize(_ size: Config.CandidateTextSize.Value) -> CGFloat {
        size == .large ? 20 : 14
    }

    static let minimumListWidth: CGFloat = 120
    static let maximumListWidth: CGFloat = 360
    static let visibleRows = 7
    static let cardGap: CGFloat = 8
    static let definitionWidth: CGFloat = 240
    static let cornerRadius: CGFloat = 6
}
