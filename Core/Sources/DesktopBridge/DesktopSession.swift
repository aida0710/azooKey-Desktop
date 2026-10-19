import Foundation
import Core
import KanaKanjiConverterModuleWithDefaultDictionary

struct DesktopSnapshot: Encodable {
    struct Token: Encodable { let text: String; let reading: String }
    struct CandidateItem: Encodable {
        let index: Int
        let text: String
        let tokens: [Token]
        let annotation: String?
    }
    struct Node: Encodable {
        let id: Int
        let text: String
        let reading: String
        let parent: Int?
        let children: [Int]
        let terminals: [Int]
        let depth: Int
    }
    var consumed = true
    var preedit = ""
    var cursor = 0
    var commits: [String] = []
    var candidates: [CandidateItem] = []
    var selection: Int?
    var nodes: [Node] = []
    var selectedPath: [Int] = []
    var focusedNode: Int?
    var generation = 0
    var request: String?
    var error: String?
}

/// Platform-neutral adapter around upstream's input state and conversion session.
/// The Linux frontend translates physical key codes and handles only OS effects.
@MainActor
final class DesktopSession: SegmentManagerDelegate {
    private let converter: KanaKanjiConverter
    private let segments: SegmentsManager
    private var state: InputState = .none
    private var language: InputLanguage = .japanese
    private var tree = CandidateTree(entries: [])
    private var treeSelection = CandidateTreeSelection(tree: CandidateTree(entries: []), candidateIndex: nil)
    private var generation = 0
    private var pageStart = 0
    var leftContext = ""
    var rightContext = ""

    init(dataDirectory: URL, resourcesDirectory: URL?, useZenzai: Bool) throws {
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("memory"), withIntermediateDirectories: true)
        converter = .withDefaultDictionary()
        segments = SegmentsManager(kanaKanjiConverter: converter, applicationDirectoryURL: dataDirectory,
                                   containerURL: dataDirectory, context: .init(useZenzai: useZenzai, resourcesDirectoryURL: resourcesDirectory))
        segments.delegate = self
        _ = CustomInputTableStore.registerIfExists()
        segments.activate()
    }

    nonisolated func getLeftSideContext(maxCount: Int) -> String? {
        MainActor.assumeIsolated { String(leftContext.suffix(maxCount)) }
    }
    nonisolated func getRightSideContext(maxCount: Int) -> String? {
        MainActor.assumeIsolated { String(rightContext.prefix(maxCount)) }
    }

    private var inputStyle: InputStyle {
        if language == .english { return .direct }
        switch Config.InputStyle().value {
        case .default: return .mapped(id: .defaultRomanToKana)
        case .defaultAZIK: return .mapped(id: .defaultAZIK)
        case .defaultKanaUS: return .mapped(id: .defaultKanaUS)
        case .defaultKanaJIS: return .mapped(id: .defaultKanaJIS)
        case .custom:
            return CustomInputTableStore.registerIfExists() ? .mapped(id: .tableName(CustomInputTableStore.tableName)) : .mapped(id: .defaultRomanToKana)
        }
    }

    func reset(commit: Bool) -> DesktopSnapshot {
        let text = commit && !segments.isEmpty ? segments.commitMarkedText(inputState: state) : ""
        segments.stopComposition()
        state = .none
        pageStart = 0
        return snapshot(commits: text.isEmpty ? [] : [text])
    }

    func close() { segments.deactivate() }

    func select(candidateIndex: Int, submit: Bool, expectedGeneration: Int? = nil) -> DesktopSnapshot {
        guard expectedGeneration == nil || expectedGeneration == generation,
              currentCandidates.indices.contains(candidateIndex) else { return snapshot() }
        segments.requestSelectingRow(candidateIndex)
        state = .selecting
        var commits: [String] = []
        if submit {
            commitSelected(into: &commits)
            state = segments.isEmpty ? .none : .previewing
        }
        return snapshot(commits: commits)
    }

    func selectNode(_ nodeID: Int, submit: Bool, expectedGeneration: Int) -> DesktopSnapshot {
        guard expectedGeneration == generation,
              let index = treeSelection.select(nodeID: nodeID, in: tree) else { return snapshot() }
        return select(candidateIndex: index, submit: submit, expectedGeneration: expectedGeneration)
    }

    private var currentCandidates: [Candidate] {
        switch segments.getCurrentCandidateWindow(inputState: state) {
        case .selecting(let candidates, _), .composing(let candidates, _): return candidates
        case .hidden: return []
        }
    }

    private func commitSelected(into commits: inout [String]) {
        guard let candidate = segments.selectedCandidate else { return }
        commit(candidate, into: &commits)
    }

    private func commit(_ candidate: Candidate, into commits: inout [String]) {
        commits.append(candidate.text)
        segments.prefixCandidateCommited(candidate, leftSideContext: leftContext)
        leftContext += candidate.text
    }

    func key(_ event: KeyEventCore) -> DesktopSnapshot {
        let action = UserAction.getUserAction(eventCore: event, inputLanguage: language)
        if state == .selecting, event.modifierFlags.isEmpty, Config.TreeCandidates().value,
           case .navigation(let direction) = action {
            let move: CandidateTreeSelection.Direction
            switch direction {
            case .left: move = .left
            case .right: move = .right
            case .up: move = .up
            case .down: move = .down
            }
            if let index = treeSelection.move(move, in: tree) { segments.requestSelectingRow(index) }
            return snapshot()
        }
        let (clientAction, callback) = state.event(eventCore: event, userAction: action, inputLanguage: language,
                                                  liveConversionEnabled: Config.LiveConversion().value,
                                                  enableDebugWindow: Config.DebugWindow().value,
                                                  enableSuggestion: Config.AIBackendPreference().value != .off)
        var result = DesktopSnapshot()
        switch clientAction {
        case .consume: break
        case .fallthrough: result.consumed = false
        case .showCandidateWindow: segments.requestSetCandidateWindowState(visible: true)
        case .hideCandidateWindow: segments.requestSetCandidateWindowState(visible: false)
        case .enterFirstCandidatePreviewMode:
            segments.insertCompositionSeparator(inputStyle: inputStyle, skipUpdate: false)
            segments.requestSetCandidateWindowState(visible: false)
        case .enterCandidateSelectionMode:
            segments.insertCompositionSeparator(inputStyle: inputStyle, skipUpdate: true)
            segments.update(requestRichCandidates: true)
        case .appendToMarkedText(let text): segments.insertAtCursorPosition(text, inputStyle: inputStyle)
        case .appendPieceToMarkedText(let pieces): segments.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .insertWithoutMarkedText(let text): result.commits.append(text)
        case .editSegment(let count): segments.editSegment(count: count)
        case .commitMarkedText: result.commits.append(segments.commitMarkedText(inputState: state))
        case .commitMarkedTextAndAppendToMarkedText(let text):
            result.commits.append(segments.commitMarkedText(inputState: state))
            segments.insertAtCursorPosition(text, inputStyle: inputStyle)
        case .commitMarkedTextAndAppendPieceToMarkedText(let pieces):
            result.commits.append(segments.commitMarkedText(inputState: state))
            segments.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .submitSelectedCandidate: commitSelected(into: &result.commits)
        case .removeLastMarkedText:
            segments.deleteBackwardFromCursorPosition()
            segments.requestResettingSelection()
        case .selectPrevCandidate: segments.requestSelectingPrevCandidate()
        case .selectNextCandidate: segments.requestSelectingNextCandidate()
        case .selectNumberCandidate(let number):
            let index = pageStart + number - 1
            if currentCandidates.indices.contains(index) {
                segments.requestSelectingRow(index)
                commitSelected(into: &result.commits)
                segments.requestResettingSelection()
            }
        case .submitHiraganaCandidate:
            commit(segments.getModifiedRubyCandidate(inputState: state) { $0.toHiragana() }, into: &result.commits)
        case .submitKatakanaCandidate:
            commit(segments.getModifiedRubyCandidate(inputState: state) { $0.toKatakana() }, into: &result.commits)
        case .submitHankakuKatakanaCandidate:
            commit(segments.getModifiedRubyCandidate(inputState: state) { $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, into: &result.commits)
        case .submitFullWidthRomanCandidate:
            commit(segments.getModifiedRomanCandidate { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 }, into: &result.commits)
        case .submitHalfWidthRomanCandidate:
            commit(segments.getModifiedRomanCandidate { $0.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, into: &result.commits)
        case .enableDebugWindow: segments.requestDebugWindowMode(enabled: true)
        case .disableDebugWindow: segments.requestDebugWindowMode(enabled: false)
        case .stopComposition: segments.stopComposition()
        case .forgetMemory: segments.forgetMemory()
        case .selectInputLanguage(let newLanguage): language = newLanguage
        case .commitMarkedTextAndSelectInputLanguage(let newLanguage):
            result.commits.append(segments.commitMarkedText(inputState: state))
            language = newLanguage
        case .acceptPredictionCandidate: segments.acceptPredictionCandidate()
        case .submitUnicodeInput(let codePoint):
            if let value = UInt32(codePoint, radix: 16), let scalar = Unicode.Scalar(value) { result.commits.append(String(scalar)) }
        case .submitSelectedCandidateAndEnterUnicodeInputMode:
            commitSelected(into: &result.commits)
            if !segments.isEmpty { result.commits.append(segments.convertTarget); segments.stopComposition() }
        case .enterUnicodeInputMode, .appendToUnicodeInput, .removeLastUnicodeInput, .cancelUnicodeInput: break
        case .requestPredictiveSuggestion: result.request = "predict"
        case .requestReplaceSuggestion: result.request = "replace"
        case .showPromptInputWindow, .transformSelectedText: result.request = "prompt"
        case .selectNextReplaceSuggestionCandidate, .selectPrevReplaceSuggestionCandidate, .submitReplaceSuggestionCandidate, .hideReplaceSuggestionWindow:
            result.request = "suggestion"
        }
        if result.consumed {
            switch callback {
            case .fallthrough: break
            case .transition(let next): state = next
            case .basedOnBackspace(let empty, let nonempty), .basedOnSubmitCandidate(let empty, let nonempty):
                state = segments.isEmpty ? empty : nonempty
            }
        }
        var response = snapshot(commits: result.commits)
        response.consumed = result.consumed
        response.request = result.request
        return response
    }

    func snapshot(commits: [String] = []) -> DesktopSnapshot {
        var result = DesktopSnapshot()
        result.commits = commits.filter { !$0.isEmpty }
        if case .unicodeInput(let code) = state {
            result.preedit = "U+" + code
            result.cursor = result.preedit.unicodeScalars.count
        } else {
            let marked = segments.getCurrentMarkedText(inputState: state)
            result.preedit = marked.map(\.content).joined()
            let utf16Position = min(marked.selectionRange.location, result.preedit.utf16.count)
            // IBus uses Unicode code points; upstream selection offsets are UTF-16.
            let prefix = String(decoding: Array(result.preedit.utf16.prefix(utf16Position)), as: UTF16.self)
            result.cursor = prefix.unicodeScalars.count
        }
        let candidates = currentCandidates
        switch segments.getCurrentCandidateWindow(inputState: state) {
        case .selecting(_, let selected), .composing(_, let selected): result.selection = selected
        case .hidden: break
        }
        result.candidates = segments.makeCandidatePresentations(candidates).enumerated().map { index, presentation in
            .init(index: index, text: presentation.candidate.text,
                  tokens: presentation.candidate.data.map { .init(text: $0.word, reading: $0.ruby) },
                  annotation: presentation.displayContext.annotationText)
        }
        let nextTree = CandidateTree(entries: result.candidates.map {
            .init(text: $0.text, tokens: $0.tokens.map { .init(text: $0.text, reading: $0.reading) }, candidateIndex: $0.index)
        })
        if nextTree != tree { generation += 1; tree = nextTree }
        treeSelection.synchronize(tree: tree, candidateIndex: result.selection)
        result.generation = generation
        result.nodes = tree.nodes.map { .init(id: $0.id, text: $0.token.text, reading: $0.token.reading,
                                             parent: $0.parentID, children: $0.children, terminals: $0.terminalCandidateIndices, depth: $0.depth) }
        result.selectedPath = result.selection.flatMap { tree.paths[$0] } ?? []
        result.focusedNode = treeSelection.focusedNodeID
        if let index = result.selection {
            if index < pageStart { pageStart = index }
            if index > pageStart + 8 { pageStart = index - 8 }
        } else { pageStart = 0 }
        return result
    }
}
