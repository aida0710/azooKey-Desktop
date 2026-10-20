/// Pointer, accessibility and delayed IPC actions must identify the list they displayed.
struct DesktopCandidateSelection: Codable, Sendable {
    let batch: DesktopCandidateBatchReference
    let candidateID: String
}
