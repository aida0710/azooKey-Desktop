import Foundation

/// A concise selection announcement. Screen readers speak it while input and
/// accessibility focus stay in the document.
enum CandidateAnnouncement {
    /// - Returns: nil while typing, or when the selection or focused word is
    ///   unknown, so live candidates are never announced on every key.
    static func text(_ input: CandidateDisplayInput) -> String? {
        guard CandidateDisplay.keyboardConfirmsCandidate(input),
              let candidate = input.candidates.first(where: { $0.index == input.selection }),
              let node = input.nodes.first(where: { $0.id == input.focusedNode }) else {
            return nil
        }
        let scope = candidate.commitScope
        let reading = [node.reading, scope?.consumedReading ?? "", input.reading].first { !$0.isEmpty } ?? ""
        var parts = [
            String(format: Localization.text("candidate.position"), String(candidate.index + 1), String(input.candidates.count)),
            node.text
        ]
        if !reading.isEmpty {
            parts.append(String(format: Localization.text("candidate.announceReading"), reading))
        }
        if let word = input.selectedPath.firstIndex(of: node.id), input.selectedPath.count > 1 {
            parts.append(String(format: Localization.text("candidate.wordPosition"),
                                String(word + 1), String(input.selectedPath.count)))
        }
        if candidate.text != node.text {
            parts.append(String(format: Localization.text("candidate.announceCommit"), candidate.text))
        }
        if let remaining = scope?.remainingReading, !remaining.isEmpty {
            parts.append(String(format: Localization.text("candidate.announceRemaining"), remaining))
        }
        return parts.joined(separator: Localization.text("candidate.announceSeparator"))
    }
}
