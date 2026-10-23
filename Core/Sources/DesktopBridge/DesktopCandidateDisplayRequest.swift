/// The `candidateDisplay` object of a bridge request: what the candidate
/// window shows now. The fields are listed in docs/candidate-display.md.
struct DesktopCandidateDisplayRequest: Decodable {
    /// `key`: the window shows the tree, whether `expandTree` or the user's
    /// button opened it.
    var treeShown: Bool?
}
