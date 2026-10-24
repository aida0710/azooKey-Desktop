import Foundation

/// A display projection of selectable candidates, including exact-reading word edits.
/// Every node retains the indices of the complete candidates that pass through it.
public struct CandidateTree: Sendable, Equatable {
    public struct Token: Sendable, Hashable {
        public var text: String
        public var reading: String

        public init(text: String, reading: String = "") {
            self.text = text
            self.reading = reading
        }

        // Canonically equivalent strings can have different scalar/UTF-16
        // lengths. A shared display node must preserve the actual candidate.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.text.utf8.elementsEqual(rhs.text.utf8) && lhs.reading.utf8.elementsEqual(rhs.reading.utf8)
        }

        public func hash(into hasher: inout Hasher) {
            hasher.combine(Array(text.utf8))
            hasher.combine(Array(reading.utf8))
        }
    }

    public struct Entry: Sendable, Equatable {
        public var text: String
        public var tokens: [Token]
        public var candidateIndex: Int
        public var score: Double?
        public var comparisonGroup: Int?
        public var annotation: String?
        public var scope: CandidateCommitScope?

        public init(text: String, tokens: [Token], candidateIndex: Int, score: Double? = nil,
                    comparisonGroup: Int? = nil, annotation: String? = nil, scope: CandidateCommitScope? = nil) {
            self.text = text
            self.tokens = tokens
            self.candidateIndex = candidateIndex
            self.score = score?.isFinite == true ? score : nil
            self.comparisonGroup = comparisonGroup
            self.annotation = annotation
            self.scope = scope
        }

        fileprivate var displayTokens: [Token] {
            let nonempty = self.tokens.filter { !$0.text.isEmpty }
            // Templates and other special candidates can have text that differs
            // from their dictionary entries. Always show what will be committed.
            if !nonempty.isEmpty, nonempty.map(\.text).joined().utf8.elementsEqual(self.text.utf8) {
                return nonempty
            }
            return [.init(text: self.text)]
        }
    }

    public struct Node: Sendable, Equatable {
        public let id: Int
        public let token: Token
        public let parentID: Int?
        public let depth: Int
        public fileprivate(set) var children: [Int] = []
        public fileprivate(set) var candidateIndices: [Int] = []
        public fileprivate(set) var terminalCandidateIndices: [Int] = []
    }

    public private(set) var nodes: [Node] = []
    public private(set) var roots: [Int] = []
    public private(set) var paths: [Int: [Int]] = [:]
    private var entries: [Entry] = []
    private var entryPositions: [Int: Int] = [:]

    private struct ReadingBoundaryKey: Hashable {
        let reading: [Unicode.Scalar]
        let consumedInputCount: Int
    }

    public func entry(candidateIndex: Int) -> Entry? {
        entryPositions[candidateIndex].map { entries[$0] }
    }

    public init(entries: [Entry]) {
        // Kana-only fallback sentences can reuse real dictionary reading
        // boundaries. Never guess a segmentation for learned kanji phrases.
        var readingSegments: [ReadingBoundaryKey: [Token]] = [:]
        for entry in entries {
            let tokens = entry.displayTokens
            if tokens.count > 1, tokens.allSatisfy({ !$0.reading.isEmpty }),
               let consumedInputCount = entry.comparisonGroup {
                let key = ReadingBoundaryKey(reading: Array(Self.katakana(tokens.map(\.reading).joined()).unicodeScalars),
                                             consumedInputCount: consumedInputCount)
                if readingSegments[key] == nil { readingSegments[key] = tokens }
            }
        }
        for entry in entries where entry.candidateIndex >= 0 && self.paths[entry.candidateIndex] == nil {
            self.entryPositions[entry.candidateIndex] = self.entries.count
            self.entries.append(entry)
            var parentID: Int?
            var path: [Int] = []
            var tokens = entry.displayTokens
            let reading = Self.katakana(tokens.map(\.reading).joined())
            if tokens.count == 1, !reading.isEmpty, Self.katakana(entry.text).utf8.elementsEqual(reading.utf8),
               let consumedInputCount = entry.comparisonGroup,
               let segments = readingSegments[ReadingBoundaryKey(reading: Array(reading.unicodeScalars),
                                                                 consumedInputCount: consumedInputCount)] {
                tokens = Self.kanaTokens(text: entry.text, segments: segments) ?? tokens
            }
            for token in tokens {
                let siblings = parentID.map { self.nodes[$0].children } ?? self.roots
                let id: Int
                if let existing = siblings.first(where: { self.nodes[$0].token == token }) {
                    id = existing
                } else {
                    id = self.nodes.count
                    self.nodes.append(.init(id: id, token: token, parentID: parentID, depth: path.count))
                    if let parentID {
                        self.nodes[parentID].children.append(id)
                    } else {
                        self.roots.append(id)
                    }
                }
                self.nodes[id].candidateIndices.append(entry.candidateIndex)
                path.append(id)
                parentID = id
            }
            if let last = path.last {
                self.nodes[last].terminalCandidateIndices.append(entry.candidateIndex)
            }
            self.paths[entry.candidateIndex] = path
        }
    }

    /// Reuses actual converter reading boundaries for a kana-only sentence.
    static func kanaTokens(text: String, segments: [Token]) -> [Token]? {
        let reading = katakana(segments.map(\.reading).joined())
        let scalars = Array(text.unicodeScalars)
        guard katakana(text).utf8.elementsEqual(reading.utf8), scalars.count == reading.unicodeScalars.count else {
            return nil
        }
        var offset = 0
        return segments.map { segment in
            let length = segment.reading.unicodeScalars.count
            defer { offset += length }
            return Token(text: String(String.UnicodeScalarView(scalars[offset..<(offset + length)])), reading: segment.reading)
        }
    }

    private static func katakana(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map {
            (0x3041...0x3096).contains($0.value) ? UnicodeScalar($0.value + 0x60)! : $0
        }))
    }

    /// Softmax of returned converter evaluations, conditional on the parent.
    /// This is a relative score (0...100), NOT a calibrated probability.
    /// Only equal complete readings compete. Hidden siblings count; duplicate
    /// surfaces, first-clause results, and unavailable evaluations do not inflate it.
    public func relativeScores(candidateIndex: Int?) -> [Int: Int] {
        guard let selected = entries.first(where: { $0.candidateIndex == candidateIndex }) else {
            return [:]
        }
        let reading = Self.katakana(selected.displayTokens.map(\.reading).joined())
        guard !reading.isEmpty else {
            return [:]
        }
        var unique: [String: Entry] = [:]
        for entry in entries where entry.score != nil
            && entry.comparisonGroup == selected.comparisonGroup
            && Self.katakana(entry.displayTokens.map(\.reading).joined()) == reading {
            if let prior = unique[entry.text], prior.score! >= entry.score! { continue }
            unique[entry.text] = entry
        }
        guard let maximum = unique.values.compactMap(\.score).max() else {
            return [:]
        }
        var masses: [Int: Double] = [:]
        var total = 0.0
        for entry in unique.values {
            let weight = exp(entry.score! - maximum)
            total += weight
            for id in paths[entry.candidateIndex] ?? [] { masses[id, default: 0] += weight }
        }
        var result: [Int: Int] = [:]
        for (id, mass) in masses {
            let denominator = nodes[id].parentID.map { masses[$0] ?? 0 } ?? total
            if denominator > 0 { result[id] = min(100, max(0, Int((100 * mass / denominator).rounded()))) }
        }
        return result
    }

    public func preferredCandidate(at nodeID: Int, preserving candidateIndex: Int?) -> Int? {
        guard self.nodes.indices.contains(nodeID) else {
            return nil
        }
        let candidates = self.nodes[nodeID].candidateIndices
        if let candidateIndex, candidates.contains(candidateIndex) {
            return candidateIndex
        }
        if let candidateIndex, let selectedPath = paths[candidateIndex],
           let editedCandidateIndex = candidates.first(where: { index in
               guard let path = paths[index], path.count == selectedPath.count,
                     entry(candidateIndex: index)?.comparisonGroup == entry(candidateIndex: candidateIndex)?.comparisonGroup else {
                   return false
               }
               return zip(path, selectedPath).allSatisfy { alternative, selected in
                   let token = nodes[alternative].token
                   let original = nodes[selected].token
                   return alternative == nodeID ? token.reading.utf8.elementsEqual(original.reading.utf8) : token == original
               }
           }) {
            return editedCandidateIndex
        }
        return candidates.first
    }

    // Two siblings leave room for local edits without a tall per-key popup.
    public static let maximumSiblingsPerWord = 2
    // Carry the best continuation of the two earlier branches, without recursively
    // expanding their siblings. Each column therefore has at most five nodes.
    public static let maximumContinuationsPerColumn = 2

    /// The selected path stays first in every column. Continuations are clipped
    /// at its last column; selecting a branch exposes that candidate's full path.
    public func compactColumns(candidateIndex: Int?) -> [[Int]] {
        let index = candidateIndex.flatMap { paths[$0] != nil ? $0 : nil } ?? roots.first.flatMap {
            nodes[$0].candidateIndices.first
        }
        guard let index, let path = paths[index] else {
            return []
        }
        var columns: [[Int]] = []
        for id in path {
            let siblings = nodes[id].parentID.map { nodes[$0].children } ?? roots
            let alternatives = siblings.filter { $0 != id }
            let matchingReading = alternatives.filter { nodes[$0].token.reading.utf8.elementsEqual(nodes[id].token.reading.utf8) }
            let otherReadings = alternatives.filter { !nodes[$0].token.reading.utf8.elementsEqual(nodes[id].token.reading.utf8) }
            var column = [id] + (matchingReading + otherReadings).prefix(Self.maximumSiblingsPerWord)
            let previousColumn = columns.last ?? []
            let previousParent = previousColumn.first.flatMap { nodes[$0].parentID }
            let previousAlternatives = Array(previousColumn.dropFirst())
            let continuing = previousAlternatives.filter { nodes[$0].parentID != previousParent }
            let branching = previousAlternatives.filter { nodes[$0].parentID == previousParent }
            var continuationCount = 0
            for parent in continuing + branching {
                guard continuationCount < Self.maximumContinuationsPerColumn else { break }
                guard let candidate = preferredCandidate(at: parent, preserving: index),
                      let continuation = paths[candidate]?.dropFirst(nodes[parent].depth + 1).first else { continue }
                column.append(continuation)
                continuationCount += 1
            }
            columns.append(column)
        }
        return columns
    }
}

/// Selection is separate from the tree so UI refreshes never emit user actions.
public struct CandidateTreeSelection: Sendable {
    public enum Direction: Sendable {
        case left, right, up, down
    }

    public private(set) var selectedCandidateIndex: Int?
    public private(set) var focusedNodeID: Int?
    private var focusedDepth: Int = 0

    public init(tree: CandidateTree, candidateIndex: Int?) {
        self.synchronize(tree: tree, candidateIndex: candidateIndex)
    }

    public mutating func synchronize(tree: CandidateTree, candidateIndex: Int?) {
        guard let candidateIndex, let path = tree.paths[candidateIndex], !path.isEmpty else {
            self.selectedCandidateIndex = nil
            self.focusedNodeID = nil
            self.focusedDepth = 0
            return
        }
        self.selectedCandidateIndex = candidateIndex
        self.focusedDepth = min(self.focusedDepth, path.count - 1)
        self.focusedNodeID = path[self.focusedDepth]
    }

    @discardableResult
    public mutating func select(nodeID: Int, in tree: CandidateTree) -> Int? {
        guard let candidate = tree.preferredCandidate(at: nodeID, preserving: self.selectedCandidateIndex) else {
            return nil
        }
        self.selectedCandidateIndex = candidate
        self.focusedNodeID = nodeID
        self.focusedDepth = tree.nodes[nodeID].depth
        return candidate
    }

    @discardableResult
    public mutating func move(_ direction: Direction, in tree: CandidateTree) -> Int? {
        guard let focusedNodeID, tree.nodes.indices.contains(focusedNodeID) else {
            return nil
        }
        let node = tree.nodes[focusedNodeID]
        let target: Int?
        switch direction {
        case .left:
            target = node.parentID
        case .right:
            let selectedPath = self.selectedCandidateIndex.flatMap { tree.paths[$0] } ?? []
            target = selectedPath.dropFirst(node.depth + 1).first ?? node.children.first
        case .up, .down:
            let siblings = node.parentID.map { tree.nodes[$0].children } ?? tree.roots
            guard siblings.count > 1, let position = siblings.firstIndex(of: focusedNodeID) else {
                return nil
            }
            let offset = direction == .up ? siblings.count - 1 : 1
            target = siblings[(position + offset) % siblings.count]
        }
        guard let target else {
            return nil
        }
        return self.select(nodeID: target, in: tree)
    }
}
