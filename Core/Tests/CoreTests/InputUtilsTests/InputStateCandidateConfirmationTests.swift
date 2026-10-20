import Core
import Foundation
import KanaKanjiConverterModuleWithDefaultDictionary
import Testing

@MainActor
@Suite("Candidate confirmation follows the Enter action")
struct InputStateCandidateConfirmationTests {
    private func action(
        _ userAction: UserAction, in state: InputState, liveConversion: Bool = false
    ) -> (ClientAction, ClientActionCallback) {
        state.event(
            eventCore: .init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 0),
            userAction: userAction, inputLanguage: .japanese,
            liveConversionEnabled: liveConversion, enableDebugWindow: false, enableSuggestion: true
        )
    }

    private func withComposition(_ operation: (SegmentsManager) throws -> Void) rethrows {
        let oldLiveConversion = Config.LiveConversion().value
        let oldTreeCandidates = Config.TreeCandidates().value
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            Config.LiveConversion().value = oldLiveConversion
            Config.TreeCandidates().value = oldTreeCandidates
            try? FileManager.default.removeItem(at: directory)
        }
        Config.LiveConversion().value = false
        Config.TreeCandidates().value = false
        let manager = SegmentsManager(
            kanaKanjiConverter: .withDefaultDictionary(), applicationDirectoryURL: directory,
            containerURL: nil, context: .init(useZenzai: false)
        )
        manager.learningEnabled = false
        manager.insertAtCursorPosition("nihongo", inputStyle: .roman2kana)
        try operation(manager)
    }

    @Test func unselectedCandidateDoesNotAdvertiseEnterWhenEnterCommitsTheReading() throws {
        try withComposition { manager in
            guard case .composing(let candidates, _) = manager.getCurrentCandidateWindow(inputState: .composing) else {
                Issue.record("読みを編集中でも変換候補のプレビューが表示される必要があります")
                return
            }
            let displayed = try #require(candidates.first)
            #expect(displayed.text != "にほんご")
            #expect(!InputState.composing.enterConfirmsCandidate)
            guard case (.commitMarkedText, .transition(.none)) = action(.enter, in: .composing) else {
                Issue.record("未選択の Enter は marked text を確定します")
                return
            }
            #expect(manager.commitMarkedText(inputState: .composing) == "にほんご")
        }
    }

    @Test func spacePreviewAllowsEnterToCommitTheDisplayedConversion() {
        withComposition { manager in
            let (spaceAction, callback) = action(.space(prefersFullWidthWhenInput: false), in: .composing)
            guard case .enterFirstCandidatePreviewMode = spaceAction,
                  case .transition(let state) = callback else {
                Issue.record("ライブ変換 OFF の Space は最初の候補をプレビューします")
                return
            }
            manager.insertCompositionSeparator(inputStyle: .roman2kana, skipUpdate: false)
            manager.requestSetCandidateWindowState(visible: false)
            let preview = manager.getCurrentMarkedText(inputState: state).map(\.content).joined()
            #expect(preview != "にほんご")
            #expect(state.enterConfirmsCandidate)
            guard case (.commitMarkedText, .transition(.none)) = action(.enter, in: state) else {
                Issue.record("プレビュー後の Enter は表示済みの変換を確定します")
                return
            }
            #expect(manager.commitMarkedText(inputState: state) == preview)
        }
    }

    @Test(arguments: [false, true])
    func selectingWithDownAllowsEnterToSubmitTheSelectedCandidate(liveConversion: Bool) {
        let (selectionAction, callback) = action(.navigation(.down), in: .composing, liveConversion: liveConversion)
        guard case .enterCandidateSelectionMode = selectionAction,
              case .transition(let state) = callback else {
            Issue.record("Down は候補選択を開始します")
            return
        }
        #expect(state.enterConfirmsCandidate)
        guard case (.submitSelectedCandidate, .basedOnSubmitCandidate(.none, .previewing)) =
                action(.enter, in: state, liveConversion: liveConversion) else {
            Issue.record("選択中の Enter は選択候補だけを確定し、残りがあればプレビューへ戻します")
            return
        }
    }

    @Test func cancellingTheSelectionRestoresTheEnterMeaningForEachConversionMode() {
        for liveConversion in [false, true] {
            let (_, callback) = action(.escape, in: .selecting, liveConversion: liveConversion)
            guard case .transition(let state) = callback else {
                Issue.record("Escape は候補選択から戻ります")
                return
            }
            #expect(state.enterConfirmsCandidate == !liveConversion)
            guard case .commitMarkedText = action(.enter, in: state, liveConversion: liveConversion).0 else {
                Issue.record("候補選択を取り消した後は現在の marked text を確定します")
                return
            }
        }
    }

    @Test func movingTheCaretRemovesTheCandidateConfirmationHint() {
        for state in [InputState.previewing, .selecting, .replaceSuggestion] {
            let (movement, callback) = action(.moveCompositionCursor(.backward), in: state)
            guard case .moveCompositionCursor(.backward) = movement,
                  case .transition(let nextState) = callback else {
                Issue.record("カーソル編集では読みの編集中へ戻ります")
                continue
            }
            #expect(!nextState.enterConfirmsCandidate)
        }
    }

    @Test func requestingNewSuggestionsRemovesTheHintUntilCandidatesAreReady() {
        #expect(InputState.replaceSuggestion.enterConfirmsCandidate)
        guard case .submitReplaceSuggestionCandidate = action(.enter, in: .replaceSuggestion).0 else {
            Issue.record("AI 候補選択中の Enter は選択済み AI 候補を確定します")
            return
        }
        let (request, callback) = action(.suggest, in: .replaceSuggestion)
        guard case .requestReplaceSuggestion = request,
              case .transition(let waitingState) = callback else {
            Issue.record("再要求中は通常の編集中へ戻ります")
            return
        }
        #expect(!waitingState.enterConfirmsCandidate)
        guard case .commitMarkedText = action(.enter, in: waitingState).0 else {
            Issue.record("AI 待機中の Enter は元の入力を確定します")
            return
        }
    }

    @Test func emptyDeadKeyAndUnicodeInputDoNotAdvertiseCandidateConfirmation() {
        #expect(!InputState.none.enterConfirmsCandidate)
        #expect(!InputState.attachDiacritic("´").enterConfirmsCandidate)
        #expect(!InputState.unicodeInput("3042").enterConfirmsCandidate)
        guard case .fallthrough = action(.enter, in: .none).0,
              case .insertWithoutMarkedText("´\n") = action(.enter, in: .attachDiacritic("´")).0,
              case .submitUnicodeInput("3042") = action(.enter, in: .unicodeInput("3042")).0 else {
            Issue.record("候補選択以外の Enter を候補確定として表示してはいけません")
            return
        }
    }
}
