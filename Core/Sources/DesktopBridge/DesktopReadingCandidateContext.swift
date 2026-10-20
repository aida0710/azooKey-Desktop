/// Values that must still describe the input field when a candidate is adopted or selected.
struct DesktopReadingCandidateContext: Equatable, Sendable {
    let context: String
    let readingProcessGeneration: String
    let focusEpoch: Int
    let compositionRevision: Int
    var settingsRevision: Int
    let leftContext: String
    let rightContext: String
    let privateInput: Bool

    func authority(requestID: String) -> CandidateRequestAuthority {
        .init(context: context, readingProcessGeneration: readingProcessGeneration,
              focusEpoch: focusEpoch, compositionRevision: compositionRevision,
              settingsRevision: settingsRevision, requestID: requestID)
    }
}
