import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary

struct DesktopSnapshot: Encodable {
    struct Token: Encodable { let text: String; let reading: String }
    struct CandidateItem: Encodable {
        let index: Int
        let text: String
        let tokens: [Token]
        let annotation: String?
        let score: Double?
        let comparisonGroup: Int?
    }
    struct Node: Encodable {
        let id: Int
        let text: String
        let reading: String
        let parent: Int?
        let children: [Int]
        let terminals: [Int]
        let depth: Int
        let relativeScore: Int?
    }
    var consumed = true
    var preedit = ""
    var cursor = 0
    var commits: [String] = []
    var candidates: [CandidateItem] = []
    var selection: Int?
    var nodes: [Node] = []
    var columns: [[Int]] = []
    var selectedPath: [Int] = []
    var focusedNode: Int?
    var generation = 0
    var request: String?
    var error: String?
    var settings: DesktopSettings?
    var suggestions: [String]?
    var dictionaryIssues: [UserDictionaryValidation.Issue]?
    var dictionarySaved: Bool?
    var dictionarySaveError: String?
    var dictionaryImportPreview: UserDictionaryImportPreview.Preview?
    var dictionaryImportItems: [Config.UserDictionaryEntry]?
    var dictionaryExportJSON: String?
    var dictionaryExchangeError: String?
    var reading = ""
    var readingCursor = 0
    var inputState = "none"
    var prediction: String?
    var pageStart = 0
    var showCandidateIndex = false
    var zenzaiLoaded = false
    var personalizationConfigured = false
    var language = "japanese"
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
    private var suggestions: [Candidate] = []
    private var suggestionIndex = 0
    private let modelURL: URL?
    var leftContext = ""
    var rightContext = ""
    var privateInput = false {
        didSet { segments.learningEnabled = !privateInput }
    }

    init(dataDirectory: URL, resourcesDirectory: URL?, useZenzai: Bool, converter: KanaKanjiConverter? = nil) throws {
        modelURL = useZenzai ? resourcesDirectory?.appendingPathComponent("ggml-model-Q5_K_M.gguf") : nil
        try FileManager.default.createDirectory(at: dataDirectory.appendingPathComponent("memory"), withIntermediateDirectories: true)
        self.converter = converter ?? .withDefaultDictionary()
        segments = SegmentsManager(kanaKanjiConverter: self.converter, applicationDirectoryURL: dataDirectory.appendingPathComponent("memory"),
                                   containerURL: dataDirectory, context: .init(useZenzai: useZenzai, resourcesDirectoryURL: resourcesDirectory))
        segments.delegate = self
        _ = CustomInputTableStore.registerIfExists()
        segments.activate()
        if !CompiledUserDictionaryStore.hasExportedDictionary(memoryDirectoryURL: segments.azooKeyMemoryDir) {
            try CompiledUserDictionaryStore.exportCurrentDictionaries(memoryDirectoryURL: segments.azooKeyMemoryDir)
        }
    }

    nonisolated func getLeftSideContext(maxCount: Int) -> String? {
        MainActor.assumeIsolated { String(leftContext.suffix(maxCount)) }
    }
    nonisolated func getRightSideContext(maxCount: Int) -> String? {
        MainActor.assumeIsolated { String(rightContext.prefix(maxCount)) }
    }

    private var inputStyle: InputStyle {
        if language == .english {
            return .direct
        }
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
        generation += 1
        let text = commit && !segments.isEmpty ? segments.commitMarkedText(inputState: state) : ""
        segments.stopComposition()
        state = .none
        pageStart = 0
        suggestions = []
        converter.commitUpdateLearningData()
        return snapshot(commits: text.isEmpty ? [] : [text])
    }

    func close() { segments.deactivate() }

    func reloadSettings(rebuildDictionary: Bool = true) throws {
        if rebuildDictionary {
            try CompiledUserDictionaryStore.exportCurrentDictionaries(memoryDirectoryURL: segments.azooKeyMemoryDir)
        }
        segments.reloadUserDictionary()
        segments.reloadPersonalization()
    }

    func resetLearning() throws {
        // The upstream LearningConfig has no public initializer. A separate,
        // non-learning conversion session initializes its storage URL through
        // the public API without touching any application's composition.
        let maintenance = converter.createSession()
        defer { converter.removeSession(maintenance) }
        try converter.withSession(maintenance) {
            var probe = ComposingText()
            probe.insertAtCursorPosition("あ", inputStyle: .direct)
            _ = converter.requestCandidates(probe, options: .init(
                requireJapanesePrediction: .disabled, requireEnglishPrediction: .disabled,
                keyboardLanguage: .ja_JP,
                learningType: .nothing, memoryDirectoryURL: segments.azooKeyMemoryDir,
                sharedContainerURL: CompiledUserDictionaryStore.directoryURL(memoryDirectoryURL: segments.azooKeyMemoryDir),
                textReplacer: .empty, specialCandidateProviders: [], zenzaiMode: .off, metadata: nil))
            converter.resetMemory()
        }
        guard !FileManager.default.fileExists(atPath: segments.azooKeyMemoryDir.appendingPathComponent("memory.louds").path) else {
            throw BridgeMain.ProtocolError.invalidRequest
        }
    }

    func downloadTypoWeights() async throws {
        try await DebugTypoCorrectionWeights.downloadWeights(modelDirectoryURL: segments.downloadedInputN5LMDir)
    }

    func applySuggestions(_ texts: [String], reading: String, expectedGeneration: Int) -> DesktopSnapshot {
        guard expectedGeneration == generation, segments.convertTarget == reading else {
            return snapshot()
        }
        suggestions = texts.filter { !$0.isEmpty }.prefix(30).map {
            Candidate(text: $0, value: 0, composingCount: .surfaceCount(reading.count), lastMid: 0, data: [])
        }
        suggestionIndex = 0
        if !suggestions.isEmpty {
            segments.setReplaceSuggestions(suggestions)
            segments.requestSelectingSuggestionRow(0)
            state = .replaceSuggestion
        } else if state == .replaceSuggestion {
            segments.resetSuggestionSelection()
            state = segments.isEmpty ? .none : .composing
        }
        return snapshot()
    }

    func select(candidateIndex: Int, submit: Bool, expectedGeneration: Int? = nil) -> DesktopSnapshot {
        guard expectedGeneration == nil || expectedGeneration == generation,
              currentCandidates.indices.contains(candidateIndex) else {
            return snapshot()
        }
        generation += 1
        if state == .replaceSuggestion {
            suggestionIndex = candidateIndex
            segments.requestSelectingSuggestionRow(candidateIndex)
        } else {
            segments.requestSelectingRow(candidateIndex)
            state = .selecting
        }
        var commits: [String] = []
        if submit {
            commitSelected(into: &commits)
            state = segments.isEmpty ? .none : .previewing
            converter.commitUpdateLearningData()
        }
        return snapshot(commits: commits)
    }

    func selectNode(_ nodeID: Int, submit: Bool, expectedGeneration: Int) -> DesktopSnapshot {
        guard expectedGeneration == generation,
              let index = treeSelection.select(nodeID: nodeID, in: tree) else {
            return snapshot()
        }
        return select(candidateIndex: index, submit: submit, expectedGeneration: expectedGeneration)
    }

    private var currentCandidates: [Candidate] {
        if state == .replaceSuggestion {
            return suggestions
        }
        switch segments.getCurrentCandidateWindow(inputState: state) {
        case .selecting(let candidates, _), .composing(let candidates, _): return candidates
        case .hidden: return []
        }
    }

    private func commitSelected(into commits: inout [String]) {
        if state == .replaceSuggestion {
            guard suggestions.indices.contains(suggestionIndex) else {
                return
            }
            commit(suggestions[suggestionIndex], into: &commits)
            suggestions = []
            segments.resetSuggestionSelection()
            return
        }
        guard let candidate = segments.selectedCandidate else {
            return
        }
        commit(candidate, into: &commits)
    }

    private func commit(_ candidate: Candidate, into commits: inout [String]) {
        commits.append(candidate.text)
        segments.prefixCandidateCommited(candidate, leftSideContext: leftContext)
        leftContext += candidate.text
    }

    // Keep the upstream ClientAction mapping exhaustive, as in InputState.event.
    // swiftlint:disable:next cyclomatic_complexity
    func key(_ event: KeyEventCore, doubleTap: Bool = false) -> DesktopSnapshot {
        generation += 1
        if doubleTap, event.keyCode == 102, !segments.isEmpty {
            var commits: [String] = []
            commit(segments.getModifiedRomanCandidate(inputState: state) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, into: &commits)
            language = .english
            state = segments.isEmpty ? .none : .composing
            converter.commitUpdateLearningData()
            return snapshot(commits: commits)
        }
        if Config.OptionDirectFullWidthInput().value,
           let text = OptionDirectInputResolver.resolve(characters: event.characters, modifierFlags: event.modifierFlags,
                                                       inputLanguage: language, inputState: state, typeBackSlash: Config.TypeBackSlash().value) {
            return snapshot(commits: [text])
        }
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
        case .hideCandidateWindow: segments.cancelCandidateSelection()
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
        case .moveCompositionCursor(let movement): segments.moveCompositionCursor(movement)
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
        case .removeNextMarkedText:
            segments.deleteForwardFromCursorPosition()
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
            commit(segments.getModifiedRomanCandidate(inputState: state) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: true) ?? $0 }, into: &result.commits)
        case .submitHalfWidthRomanCandidate:
            commit(segments.getModifiedRomanCandidate(inputState: state) { $0.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? $0 }, into: &result.commits)
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
        case .selectNextReplaceSuggestionCandidate:
            if !suggestions.isEmpty { suggestionIndex = (suggestionIndex + 1) % suggestions.count; segments.requestSelectingSuggestionRow(suggestionIndex) }
        case .selectPrevReplaceSuggestionCandidate:
            if !suggestions.isEmpty { suggestionIndex = (suggestionIndex + suggestions.count - 1) % suggestions.count; segments.requestSelectingSuggestionRow(suggestionIndex) }
        case .submitReplaceSuggestionCandidate: commitSelected(into: &result.commits)
        case .hideReplaceSuggestionWindow:
            suggestions = []
            segments.resetSuggestionSelection()
        }
        if result.consumed {
            switch callback {
            case .fallthrough: break
            case .transition(let next): state = next
            case .basedOnBackspace(let empty, let nonempty), .basedOnSubmitCandidate(let empty, let nonempty):
                state = segments.isEmpty ? empty : nonempty
            }
        }
        if result.request == "replace" || result.request == "predict" {
            suggestions = []
            segments.resetSuggestionSelection()
            // Keep the ordinary composition usable while the asynchronous AI
            // request is pending or unavailable. Only results enter selection.
            state = segments.isEmpty ? .none : .composing
        } else if state != .replaceSuggestion {
            suggestions = []
            segments.resetSuggestionSelection()
        }
        if !result.commits.isEmpty { converter.commitUpdateLearningData() }
        var response = snapshot(commits: result.commits)
        response.consumed = result.consumed
        response.request = result.request
        return response
    }

    func snapshot(commits: [String] = []) -> DesktopSnapshot {
        var result = DesktopSnapshot()
        result.commits = commits.filter { !$0.isEmpty }
        result.language = language == .japanese ? "japanese" : "english"
        result.zenzaiLoaded = modelURL.map { converter.zenzStatus == "load \($0.absoluteString)" } ?? false
        result.personalizationConfigured = segments.hasPersonalizationConfiguration
        result.reading = segments.convertTarget
        result.readingCursor = unicodeScalarOffset(in: result.reading, utf16Offset: segments.readingCursorUTF16Offset)
        result.inputState = state.bridgeName
        if state == .composing {
            result.prediction = SegmentsManager.preferredPredictionCandidates(
                typoCorrectionCandidates: segments.requestTypoCorrectionPredictionCandidates(),
                predictionCandidates: segments.requestPredictionCandidates()
            ).first?.displayText
        }
        if case .unicodeInput(let code) = state {
            result.preedit = "U+" + code
            result.cursor = result.preedit.unicodeScalars.count
        } else {
            let marked = segments.getCurrentMarkedText(inputState: state)
            result.preedit = marked.map(\.content).joined()
            result.cursor = unicodeScalarOffset(in: result.preedit, utf16Offset: marked.selectionRange.location)
        }
        let candidates = currentCandidates
        switch segments.getCurrentCandidateWindow(inputState: state) {
        case .selecting(_, let selected), .composing(_, let selected): result.selection = selected
        case .hidden: break
        }
        if state == .replaceSuggestion, !suggestions.isEmpty { result.selection = suggestionIndex }
        result.candidates = segments.makeCandidatePresentations(candidates).enumerated().map { index, presentation in
            .init(index: index, text: presentation.candidate.text,
                  tokens: presentation.candidate.data.map { .init(text: $0.word, reading: $0.ruby) },
                  annotation: presentation.displayContext.annotationText,
                  score: presentation.candidate.value.isFinite ? Double(presentation.candidate.value) : nil,
                  comparisonGroup: presentation.consumedInputCount)
        }
        let nextTree = CandidateTree(entries: result.candidates.map {
            .init(text: $0.text, tokens: $0.tokens.map { .init(text: $0.text, reading: $0.reading) },
                  candidateIndex: $0.index, score: $0.score, comparisonGroup: $0.comparisonGroup)
        })
        if nextTree != tree { generation += 1; tree = nextTree }
        treeSelection.synchronize(tree: tree, candidateIndex: result.selection)
        result.generation = generation
        let relativeScores = tree.relativeScores(candidateIndex: result.selection)
        result.nodes = tree.nodes.map { .init(id: $0.id, text: $0.token.text, reading: $0.token.reading,
                                             parent: $0.parentID, children: $0.children, terminals: $0.terminalCandidateIndices,
                                             depth: $0.depth, relativeScore: relativeScores[$0.id]) }
        result.columns = tree.compactColumns(candidateIndex: result.selection)
        result.selectedPath = result.columns.compactMap(\.first)
        result.focusedNode = treeSelection.focusedNodeID
        if let index = result.selection {
            pageStart = (index / 9) * 9
        } else { pageStart = 0 }
        result.pageStart = pageStart
        result.showCandidateIndex = state == .selecting || state == .replaceSuggestion
        return result
    }
}

private extension InputState {
    var bridgeName: String {
        switch self {
        case .none: "none"
        case .composing: "composing"
        case .previewing: "previewing"
        case .selecting: "selecting"
        case .replaceSuggestion: "replaceSuggestion"
        case .unicodeInput: "unicodeInput"
        case .attachDiacritic: "attachDiacritic"
        }
    }
}
