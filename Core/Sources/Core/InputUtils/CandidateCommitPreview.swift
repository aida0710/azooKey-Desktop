/// A preview points to one existing candidate, including any unseen continuation.
public struct CandidateCommitPreview: Encodable, Equatable, Sendable {
    public let candidateIndex: Int
    public let text: String
    public let annotation: String?
    public let scope: CandidateCommitScope?
    public let followingText: String
    public let previousFollowingText: String?
}

extension CandidateTree {
    public func preview(at nodeID: Int, preserving candidateIndex: Int?) -> CandidateCommitPreview? {
        guard let index = preferredCandidate(at: nodeID, preserving: candidateIndex),
              let entry = entry(candidateIndex: index) else {
            return nil
        }
        let following = followingText(candidateIndex: index, afterDepth: nodes[nodeID].depth)
        let previous = candidateIndex.map { followingText(candidateIndex: $0, afterDepth: nodes[nodeID].depth) }
        return CandidateCommitPreview(
            candidateIndex: index, text: entry.text, annotation: entry.annotation, scope: entry.scope,
            followingText: following, previousFollowingText: previous == following ? nil : previous
        )
    }

    private func followingText(candidateIndex: Int, afterDepth depth: Int) -> String {
        (paths[candidateIndex] ?? []).dropFirst(depth + 1).map { nodes[$0].token.text }.joined()
    }
}
