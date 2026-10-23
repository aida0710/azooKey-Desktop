import Core
import Foundation
import Testing

/// 日本に行く read as にほん or にっぽん, with the first word focused.
private let announcementSnapshot = """
{
  "inputState": "selecting", "reading": "にほんにいく", "selection": 0, "focusedNode": 10,
  "selectedPath": [10, 12],
  "nodes": [
    {"id": 10, "text": "日本", "reading": "ニホン", "parent": null, "relativeScore": 100},
    {"id": 11, "text": "日本", "reading": "ニッポン", "parent": null, "relativeScore": 40},
    {"id": 12, "text": "に行く", "reading": "ニイク", "parent": 10},
    {"id": 13, "text": "に行く", "reading": "ニイク", "parent": 11}
  ],
  "columns": [[10, 11], [12, 13]],
  "candidates": [
    {"index": 0, "text": "日本に行く", "commitScope": {"consumedReading": "にほんにいく", "remainingReading": ""}},
    {"index": 1, "text": "日本に行く", "commitScope": {"consumedReading": "にっぽんにいく", "remainingReading": ""}}
  ]
}
"""

/// Expected text from the same catalog Core uses, so tests pass in any locale.
private func text(_ key: String, _ values: String...) -> String {
    String(format: Localization.text("candidate." + key), arguments: values)
}

private func announcement(_ parts: String...) -> String {
    parts.joined(separator: text("announceSeparator"))
}

private func input(_ changes: [String: Any] = [:]) throws -> CandidateDisplayInput {
    var object = try #require(try JSONSerialization.jsonObject(with: Data(announcementSnapshot.utf8)) as? [String: Any])
    object.merge(changes) { _, new in new }
    return try JSONDecoder().decode(CandidateDisplayInput.self, from: JSONSerialization.data(withJSONObject: object))
}

@Test func movingToAnotherReadingOrWordAnnouncesTheRealCommit() throws {
    #expect(CandidateDisplay(try input()).announcement == announcement(
        text("position", "1", "2"), "日本", text("announceReading", "ニホン"), text("wordPosition", "1", "2"),
        text("announceCommit", "日本に行く")))
    #expect(CandidateDisplay(try input(["selection": 1, "focusedNode": 11, "selectedPath": [11, 13]])).announcement
        == announcement(text("position", "2", "2"), "日本", text("announceReading", "ニッポン"),
                        text("wordPosition", "1", "2"), text("announceCommit", "日本に行く")))
    #expect(CandidateDisplay(try input(["focusedNode": 12])).announcement
        == announcement(text("position", "1", "2"), "に行く", text("announceReading", "ニイク"),
                        text("wordPosition", "2", "2"), text("announceCommit", "日本に行く")))
}

@Test func partialCommitAnnouncesTheRemainingReadingWithoutInventingText() throws {
    let candidates: [[String: Any]] = [
        ["index": 0, "text": "日本", "commitScope": ["consumedReading": "にほん", "remainingReading": "にいく"]],
        ["index": 1, "text": "日本に行く"]
    ]
    #expect(CandidateDisplay(try input(["candidates": candidates])).announcement
        == announcement(text("position", "1", "2"), "日本", text("announceReading", "ニホン"),
                        text("wordPosition", "1", "2"), text("announceRemaining", "にいく")))
}

@Test func typingInvalidSelectionAndMissingFocusAreSilent() throws {
    for changes: [String: Any] in [["inputState": "composing"], ["inputState": "none"], ["selection": 8],
                                   ["focusedNode": 99], ["inputState": "unknown"]] {
        #expect(CandidateDisplay(try input(changes)).announcement == nil, "\(changes)")
    }
}

@Test func liveInputShowsEveryBranchAndTheListExpandsOnlyTheFocusedWord() throws {
    let live = CandidateDisplay(try input(["inputState": "composing"]))
    #expect(live.mode == .tree)
    #expect(live.columns == [[10, 11], [12, 13]])
    let list = CandidateDisplay(try input())
    #expect(list.mode == .list)
    #expect(list.columns == [[10, 11], [12]])
    #expect(CandidateDisplay(try input(["focusedNode": 12])).columns == [[10], [12]])
    #expect(CandidateDisplay(try input(["columns": [[Int]](), "inputState": "composing"])).mode == .hidden)
    #expect(CandidateDisplay(try input(["nodes": [Any](), "inputState": "selecting"])).mode == .hidden)
}

@Test func nodeNumbersComeFromThePreviewCandidateOnTheCurrentPage() throws {
    let nodes: [[String: Any]] = [
        ["id": 0, "text": "日本", "reading": "ニホン", "preview": ["candidateIndex": 9, "text": "日本に行く"]],
        ["id": 1, "text": "二本", "reading": "ニホン", "preview": ["candidateIndex": 12, "text": "二本"]],
        ["id": 2, "text": "に行く", "reading": "ニイク", "preview": ["candidateIndex": 3, "text": "日本に行く"]]
    ]
    let page: [String: Any] = ["start": 9, "position": 1, "totalCount": 20, "items": [Any]()]
    let changes: [String: Any] = ["nodes": nodes, "columns": [[0, 1], [2]], "selectedPath": [0, 2],
                                  "focusedNode": 0, "selection": 9, "candidatePage": page]
    let live = CandidateDisplay(try input(changes.merging(["inputState": "composing"]) { _, new in new }))
    #expect(live.nodes.map(\.number) == [1, 4, nil])
    #expect(live.showsNumbers)
    #expect(live.nodes[0].accessibleDescription.hasSuffix(text("numberBadge", "1")))
    let unnumbered = CandidateDisplay(try input(changes.merging(["showCandidateIndex": false]) { _, new in new }))
    #expect(unnumbered.nodes.allSatisfy { $0.number == nil } && !unnumbered.showsNumbers)
    let numbered = CandidateDisplay(try input(changes.merging(["showCandidateIndex": true]) { _, new in new }))
    #expect(numbered.nodes.map(\.number) == [1, 4, nil])
}

@Test func nodeTextExplainsTheTargetDetailsAndScore() throws {
    let display = CandidateDisplay(try input(["showRelativeScores": true]))
    let focused = try #require(display.nodes.first(where: { $0.id == 10 }))
    #expect(focused.selected && focused.focused)
    #expect(focused.accessibleName == text("withReading", "日本", "ニホン"))
    let lines = focused.accessibleDescription.components(separatedBy: "\n")
    #expect(lines.first == text("focusedSelect"))
    #expect(lines.contains(String(format: Localization.text("candidate.score.value"), 100)))
    let detail = focused.detailText.components(separatedBy: "\n")
    #expect(Array(detail.prefix(2)) == ["日本", "ニホン"])
    #expect(detail.last == text("detailKeys"))
    let hidden = CandidateDisplay(try input())
    let unscored = try #require(hidden.nodes.first(where: { $0.id == 10 }))
    #expect(!unscored.detailText.contains(String(format: Localization.text("candidate.score.value"), 100)))
    #expect(hidden.detailNode == 10)
}

@Test func listExplainsTheCommitConfirmActionAndPage() throws {
    let page: [String: Any] = [
        "start": 0, "position": 1, "totalCount": 12, "nextIndex": 9,
        "items": [["index": 0, "text": "日本に行く", "reading": "にほんにいく", "detailDescription": "確定予定: 日本に行く"],
                  ["index": 1, "text": "日本に行く", "reading": "にっぽんにいく", "detailDescription": "確定予定: 日本に行く"]]
    ]
    let display = CandidateDisplay(try input(["candidatePage": page, "showCandidateIndex": true]))
    let list = try #require(display.list)
    #expect(list.title == text("composition") && list.commitText == "日本に行く")
    #expect(list.readingText == text("announceReading", "にほんにいく") && list.remainingText == nil)
    #expect(list.positionText == text("position", "1", "12"))
    #expect(list.keyboardConfirmsCandidate && list.confirmLabel == text("submit") + " ↵")
    #expect(list.confirmAccessibleName == text("submit") + " 日本に行く")
    #expect(list.confirmAccessibleDescription == text("confirm"))
    #expect(list.confirmIndex == 0 && list.previousIndex == nil && list.nextIndex == 9)
    #expect(list.items.map(\.number) == [1, 2] && list.items.map(\.selected) == [true, false])
    #expect(list.items[1].accessibleName == text("withReading", "日本に行く", "にっぽんにいく"))
    #expect(list.items[1].accessibleDescription == text("select") + "\n確定予定: 日本に行く")

    let proposal = try #require(CandidateDisplay(try input(["inputState": "composing", "candidatePage": page])).list)
    #expect(proposal.title == text("proposal") && proposal.confirmLabel == text("submitCandidate"))
    #expect(!proposal.keyboardConfirmsCandidate && proposal.items.allSatisfy { $0.number == nil })
    #expect(try CandidateDisplay(input(["selection": NSNull(), "candidates": [Any]()])).list == nil)
}

@Test func focusMoveWithinTheSameCandidateAsksToShowTheTree() throws {
    let moved = ["previous": ["selection": 0, "focusedNode": 12]]
    #expect(CandidateDisplay(try input(moved)).expandTree)
    #expect(!CandidateDisplay(try input(["previous": ["selection": 1, "focusedNode": 11]])).expandTree)
    #expect(!CandidateDisplay(try input(["previous": ["selection": 0, "focusedNode": 10]])).expandTree)
    #expect(!CandidateDisplay(try input()).expandTree)
}

@Test func scoreRolesUseThePaletteNames() throws {
    #expect(CandidateScorePresentation(relativeScore: nil).role == .scoreUnknown)
    #expect(CandidateScorePresentation(relativeScore: 74).role == .scoreLow)
    #expect(CandidateScorePresentation(relativeScore: 75).role == .scoreHigh)
    #expect(CandidateScorePresentation(relativeScore: 101).role == .scoreUnknown)
    let encoded = try JSONEncoder().encode(CandidateScorePresentation(relativeScore: 40))
    let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    #expect(object["role"] as? String == "scoreLow")
}
