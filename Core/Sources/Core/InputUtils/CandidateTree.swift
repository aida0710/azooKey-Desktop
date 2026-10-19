/// A display projection of real converter candidates, not a new conversion lattice.
/// Every node retains the indices of the original candidates that pass through it.
public struct CandidateTree: Sendable, Equatable {
    public struct Token: Sendable, Hashable {
        public var text: String
        public var reading: String

        public init(text: String, reading: String = "") {
            self.text = text
            self.reading = reading
        }
    }

    public struct Entry: Sendable, Equatable {
        public var text: String
        public var tokens: [Token]
        public var candidateIndex: Int

        public init(text: String, tokens: [Token], candidateIndex: Int) {
            self.text = text
            self.tokens = tokens
            self.candidateIndex = candidateIndex
        }

        fileprivate var displayTokens: [Token] {
            let nonempty = self.tokens.filter { !$0.text.isEmpty }
            // Templates and other special candidates can have text that differs
            // from their dictionary entries. Always show what will be committed.
            if !nonempty.isEmpty, nonempty.map(\.text).joined() == self.text {
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

    public init(entries: [Entry]) {
        for entry in entries where entry.candidateIndex >= 0 && self.paths[entry.candidateIndex] == nil {
            var parentID: Int?
            var path: [Int] = []
            for token in entry.displayTokens {
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

    public func preferredCandidate(at nodeID: Int, preserving candidateIndex: Int?) -> Int? {
        guard self.nodes.indices.contains(nodeID) else {
            return nil
        }
        let candidates = self.nodes[nodeID].candidateIndices
        if let candidateIndex, candidates.contains(candidateIndex) {
            return candidateIndex
        }
        return candidates.first
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
