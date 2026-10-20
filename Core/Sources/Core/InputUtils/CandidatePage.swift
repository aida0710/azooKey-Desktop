/// A bounded page of real converter candidates. Indices always belong to Core.
public struct CandidatePage: Sendable, Codable, Equatable {
    public struct Item: Sendable, Codable, Equatable {
        public let index: Int
        public let text: String
        public let reading: String
        public let annotation: String?
        public let detailDescription: String

        fileprivate init(entry: CandidateTree.Entry) {
            index = entry.candidateIndex
            text = entry.text
            reading = entry.scope?.consumedReading ?? entry.tokens.map(\.reading).joined()
            annotation = entry.annotation
            detailDescription = CandidateCommitPreview(candidateIndex: entry.candidateIndex,
                text: entry.text, annotation: entry.annotation, scope: entry.scope,
                followingText: "", previousFollowingText: nil).detailDescription
        }
    }

    // The existing candidate number keys select one of nine entries.
    public static let size = 9
    public let totalCount: Int
    public let position: Int?
    public let start: Int
    public let items: [Item]
    public let previousIndex: Int?
    public let nextIndex: Int?

    public init(entries: [CandidateTree.Entry], selectionIndex: Int?, pageStart: Int? = nil) {
        totalCount = entries.count
        let selectedOffset = entries.firstIndex { $0.candidateIndex == selectionIndex }
        position = selectedOffset.map { $0 + 1 }
        let offset = selectedOffset ?? 0
        if let pageStart, pageStart >= 0, pageStart <= offset, offset < pageStart + Self.size {
            start = pageStart
        } else {
            start = offset / Self.size * Self.size
        }
        let end = min(entries.count, start + Self.size)
        items = entries[start..<end].map { Item(entry: $0) }
        previousIndex = start > 0 ? entries[max(0, start - Self.size)].candidateIndex : nil
        nextIndex = end < entries.count ? entries[end].candidateIndex : nil
    }
}
