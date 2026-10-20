import Core

/// Internal preparation for prefetching; neither the worker settings nor the default entry enable it.
enum DesktopCandidateRequestMode {
    case manual
    case afterEditing

    func requestsCandidates(after action: ClientAction) -> Bool {
        guard self == .afterEditing else {
            return false
        }
        switch action {
        case .appendToMarkedText, .appendPieceToMarkedText,
             .commitMarkedTextAndAppendToMarkedText, .commitMarkedTextAndAppendPieceToMarkedText,
             .removeLastMarkedText, .removeNextMarkedText, .moveCompositionCursor:
            return true
        default:
            return false
        }
    }
}
