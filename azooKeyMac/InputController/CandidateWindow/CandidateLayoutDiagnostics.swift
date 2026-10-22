import AppKit
import os

enum CandidateLayoutDiagnostics {
    private static let logger = Logger(subsystem: "org.azookey.Tree", category: "candidate-layout")

    static func record(reason: String, cursor: CGPoint, popup: CGRect, workArea: CGRect) {
        guard ProcessInfo.processInfo.environment["AZOOKEY_LAYOUT_DIAGNOSTICS"] == "1" else {
            return
        }
        // This opt-in trace deliberately accepts geometry only, never client text.
        let rectangles = "cursor=\(cursor) popup=\(popup) workArea=\(workArea)"
        logger.notice("reason=\(reason, privacy: .public) \(rectangles, privacy: .public)")
    }
}
