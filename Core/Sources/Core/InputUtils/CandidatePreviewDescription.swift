import Foundation

extension CandidateCommitPreview {
    /// Shared by native and bridge renderers, so annotation always belongs to the
    /// exact candidate selected by the same node action.
    public var detailDescription: String {
        var lines = [String(format: Localization.text("candidate.preview.commit"), text)]
        if let scope {
            lines.append(String(format: Localization.text("candidate.preview.scope"), scope.consumedReading))
            if !scope.remainingReading.isEmpty {
                lines.append(String(format: Localization.text("candidate.preview.remaining"), scope.remainingReading))
            }
        }
        if let previousFollowingText {
            let empty = Localization.text("candidate.preview.empty")
            lines.append(String(format: Localization.text("candidate.preview.changedFollowing"),
                                previousFollowingText.isEmpty ? empty : previousFollowingText,
                                followingText.isEmpty ? empty : followingText))
        } else if !followingText.isEmpty {
            lines.append(String(format: Localization.text("candidate.preview.following"), followingText))
        }
        if let annotation, !annotation.isEmpty {
            lines.append(annotation)
        }
        return lines.joined(separator: "\n")
    }
}
