import Cocoa
import Core
import InputMethodKit
import KanaKanjiConverterModuleWithDefaultDictionary

@objc(azooKeyMacInputController)
class azooKeyMacInputController: IMKInputController, NSMenuItemValidation { // swiftlint:disable:this type_name
    var segmentsManager: SegmentsManager
    var inputState: InputState = .none
    private var inputLanguage: InputLanguage = .japanese
    var liveConversionEnabled: Bool {
        Config.LiveConversion().value
    }

    var appMenu: NSMenu
    var liveConversionToggleMenuItem: NSMenuItem
    var transformSelectedTextMenuItem: NSMenuItem

    private var candidatesWindow: NSWindow
    private var candidatesViewController: CandidatesViewController

    private var predictionWindow: NSWindow
    private var predictionViewController: PredictionCandidatesViewController
    private var lastPredictionCandidates: [String] = []
    private var lastPredictionUpdateTime: TimeInterval = 0
    private var predictionHideWorkItem: DispatchWorkItem?

    var replaceSuggestionWindow: NSWindow
    var replaceSuggestionsViewController: ReplaceSuggestionsViewController
    @MainActor lazy var aiSuggestionSession = AISuggestionSession()
    let aiSuggestionStatusPanel = InputStatusPanel()
    @MainActor lazy var reconversionClient = MacReconversionSession()
    let reconversionStatusPanel = InputStatusPanel()

    var promptInputWindow: PromptInputWindow
    var isPromptWindowVisible: Bool = false

    // ダブルタップ検出用
    private var lastKey: (time: TimeInterval, code: UInt16) = (0, 0)
    private static let doubleTapInterval: TimeInterval = 0.5
    private static let candidateWindowInitialSize = CGSize(width: 400, height: 1000)

    // ピン留めプロンプトのキャッシュ（パフォーマンス向上のため）
    private var pinnedPromptsCache: [PromptHistoryItem] = []

    private static func makeCandidateWindow(contentViewController: NSViewController) -> NSWindow {
        let window: NSWindow
        if contentViewController is CandidatesViewController || contentViewController is ReplaceSuggestionsViewController {
            let panel = CandidateTreePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            panel.contentViewController = contentViewController
            panel.hidesOnDeactivate = false
            window = panel
        } else {
            window = NSWindow(contentViewController: contentViewController)
            window.styleMask = [.borderless]
        }
        window.level = .popUpMenu

        // Chromium 系アプリの deadlock 回避のため、初期化時に client への
        // 問い合わせを行わない（Chromium issue 503787240）。
        // ウィンドウは直後に orderOut されるため origin はユーザーから不可視であり、
        // 最初の候補表示時に refreshCandidateWindow() で正しい位置に再配置される。
        var frame = NSRect.zero
        frame.size = candidateWindowInitialSize
        window.setFrame(frame, display: true)
        window.setIsVisible(false)
        window.orderOut(nil)
        return window
    }

    func appendDebugMessage(_ message: String) {
        self.segmentsManager.appendDebugMessage(message)
    }

    // MARK: - ダブルタップ検出
    private func checkAndUpdateDoubleTap(keyCode: UInt16) -> Bool {
        let now = Date().timeIntervalSince1970
        let isDouble = (self.lastKey.code == keyCode) && (now - self.lastKey.time < Self.doubleTapInterval)
        self.lastKey = (time: now, code: keyCode)
        return isDouble
    }

    /// ピン留めプロンプトのキャッシュを更新
    func reloadPinnedPromptsCache() {
        guard let data = Config.data(forKey: Config.PromptHistory.key),
              let history = try? JSONDecoder().decode([PromptHistoryItem].self, from: data) else {
            self.pinnedPromptsCache = []
            return
        }
        self.pinnedPromptsCache = history.filter { $0.isPinned }
    }

    // MARK: - カスタムプロンプトショートカット検出
    private func checkCustomPromptShortcut(event: NSEvent) -> String? {
        guard let characters = event.charactersIgnoringModifiers,
              !characters.isEmpty else {
            return nil
        }

        let key = characters.lowercased()
        let eventModifiers = KeyEventCore.ModifierFlag(from: event.modifierFlags)

        // 修飾キーがない場合は早期リターン（通常の入力）
        if eventModifiers.isEmpty {
            return nil
        }

        // キャッシュからショートカット付きのピン留めプロンプトを検索
        if let matched = self.pinnedPromptsCache.first(where: { item in
            guard let itemShortcut = item.shortcut else {
                return false
            }
            return itemShortcut.key == key && itemShortcut.modifiers == eventModifiers
        }) {
            return matched.prompt
        }

        return nil
    }

    override convenience init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        let applicationDirectoryURL = AppGroup.memoryDirectoryURL()
        let containerURL = AppGroup.containerURL()
        let segmentsManager = SegmentsManager(
            kanaKanjiConverter: (NSApplication.shared.delegate as? AppDelegate)!.kanaKanjiConverter,
            applicationDirectoryURL: applicationDirectoryURL,
            containerURL: containerURL
        )
        self.init(server: server, delegate: delegate, client: inputClient, segmentsManager: segmentsManager)
    }

    init!(server: IMKServer!, delegate: Any!, client inputClient: Any!, segmentsManager: SegmentsManager) {
        self.segmentsManager = segmentsManager
        self.appMenu = NSMenu(title: "azooKey")
        self.liveConversionToggleMenuItem = NSMenuItem()
        self.transformSelectedTextMenuItem = NSMenuItem()

        let candidatesViewController = CandidatesViewController()
        let predictionViewController = PredictionCandidatesViewController()
        let replaceSuggestionsViewController = ReplaceSuggestionsViewController()

        self.candidatesViewController = candidatesViewController
        self.predictionViewController = predictionViewController
        self.replaceSuggestionsViewController = replaceSuggestionsViewController

        self.candidatesWindow = Self.makeCandidateWindow(contentViewController: candidatesViewController)
        self.predictionWindow = Self.makeCandidateWindow(contentViewController: predictionViewController)
        self.replaceSuggestionWindow = Self.makeCandidateWindow(contentViewController: replaceSuggestionsViewController)

        // PromptInputWindowの初期化
        self.promptInputWindow = PromptInputWindow()

        super.init(server: server, delegate: delegate, client: inputClient)

        // デリゲートの設定を super.init の後に移動
        self.candidatesViewController.delegate = self
        self.replaceSuggestionsViewController.delegate = self
        self.segmentsManager.delegate = self
        self.setupMenu()
    }

    @MainActor
    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        self.reconversionClient.clear()
        self.reconversionStatusPanel.orderOut(nil)
        self.cancelReplaceSuggestion()
        // アプリケーションサポートのディレクトリを準備しておく
        self.prepareApplicationSupportDirectory()
        // Register custom input table (if available) for `.tableName` usage
        CustomInputTableStore.registerIfExists()
        self.updateLiveConversionToggleMenuItem(newValue: self.liveConversionEnabled)
        self.updateTransformSelectedTextMenuItemEnabledState()
        // ピン留めプロンプトのキャッシュを更新
        self.reloadPinnedPromptsCache()
        self.segmentsManager.activate()

        if let client = sender as? IMKTextInput {
            client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        }
        // Chromium 系アプリで JS コンパイル中に activate された場合、
        // client.attributes(forCharacterIndex:) の同期呼び出しが deadlock を
        // 引き起こすため呼び出さない（Chromium issue 503787240）。
        // refreshCandidateWindow / refreshPredictionWindow は composing/selecting 状態で
        // client.attributes(...) を呼ぶ経路があるため、activate 中は使わずウィンドウを
        // 明示的に閉じる。
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        self.candidatesWindow.setIsVisible(false)
        self.candidatesWindow.orderOut(nil)
        self.candidatesViewController.hide()
        self.hidePredictionWindow()
    }

    @MainActor
    override func deactivateServer(_ sender: Any!) {
        self.reconversionClient.clear()
        self.reconversionStatusPanel.orderOut(nil)
        self.cancelReplaceSuggestion()
        self.segmentsManager.deactivate(flushLearningData: false)
        (NSApplication.shared.delegate as? AppDelegate)?.scheduleLearningDataCommit()
        self.inputState = .none
        self.candidatesWindow.orderOut(nil)
        self.predictionWindow.orderOut(nil)
        self.replaceSuggestionWindow.orderOut(nil)
        self.candidatesViewController.updateCandidatePresentations([], selectionIndex: nil, cursorLocation: .zero)
        super.deactivateServer(sender)
    }

    @MainActor
    override func commitComposition(_ sender: Any!) {
        defer { self.cancelReplaceSuggestion() }
        self.aiSuggestionSession.cancel()
        self.aiSuggestionStatusPanel.orderOut(nil)
        // Unicode入力モードの場合は状態だけリセットして終了
        // マウスクリック等でOSがMarkedTextを確定した場合、IME側からは消せないため
        if case .unicodeInput = self.inputState {
            self.inputState = .none
            return
        }
        if self.segmentsManager.isEmpty {
            return
        }
        let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
        if let client = sender as? IMKTextInput {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        self.inputState = .none
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
    }

    // MARK: - setValue: 状態同期のみ
    @MainActor
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        defer {
            super.setValue(value, forTag: tag, client: sender)
        }

        if let value = value as? NSString {
            self.client()?.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
            let englishMode = value == "com.apple.inputmethod.Roman"

            if englishMode {
                // 英語モードへの切り替え通知（実際の処理はhandleで行う）
                // メニューバーやshortcut経由の切り替えに対応する。
                // composing中でも英数キーMarkedTextを保ったまま英語入力へ移る。
                if self.inputLanguage == .japanese {
                    if self.aiSuggestionSession.isLoading {
                        self.cancelReplaceSuggestion()
                    }
                    self.inputLanguage = .english
                    self.segmentsManager.stopJapaneseInput()
                    self.refreshCandidateWindow()
                    self.refreshPredictionWindow()
                }
            } else {
                // 日本語モードへの切り替え
                if self.inputLanguage == .english {
                    self.inputLanguage = .japanese
                    let (clientAction, clientActionCallback) = self.inputState.event(
                        eventCore: .init(modifierFlags: [], characters: nil, charactersIgnoringModifiers: nil, keyCode: 0x00),
                        userAction: .かな,
                        inputLanguage: self.inputLanguage,
                        liveConversionEnabled: false,
                        enableDebugWindow: false,
                        enableSuggestion: false
                    )
                    _ = self.handleClientAction(
                        clientAction,
                        clientActionCallback: clientActionCallback,
                        client: self.client()
                    )
                }
            }
        }
    }

    override func menu() -> NSMenu! {
        self.appMenu
    }

    // swiftlint:disable:next cyclomatic_complexity
    @MainActor override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        defer {
            (NSApplication.shared.delegate as? AppDelegate)?.postponeLearningDataCommit()
        }
        guard let event, let client = sender as? IMKTextInput else {
            return false
        }
        guard event.type == .keyDown else {
            return false
        }
        if self.handleReconversionReading(event.keyEventCore, client: client) {
            return true
        }
        if let shortcut = ReconversionShortcut.resolve(event.keyEventCore) {
            self.requestReconversion(undo: shortcut == .undoCommit, client: client)
            return true
        }
        self.reconversionStatusPanel.orderOut(nil)

        // カスタムプロンプトショートカットのチェック
        if let matchedPrompt = checkCustomPromptShortcut(event: event) {
            let aiBackendEnabled = Config.AIBackendPreference().value != .off
            if aiBackendEnabled && !self.isPromptWindowVisible {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: matchedPrompt) {
                        return true
                    }
                }
            }
            // ショートカットがマッチした場合はイベントを消費して他のハンドラに渡さない
            return true
        }

        let eventModifiers = KeyEventCore.ModifierFlag(from: event.modifierFlags)
        let charactersForOptionDirectInput = event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.option))
        if Config.OptionDirectFullWidthInput().value,
           let text = OptionDirectInputResolver.resolve(
            characters: charactersForOptionDirectInput,
            modifierFlags: eventModifiers,
            inputLanguage: inputLanguage,
            inputState: inputState,
            typeBackSlash: Config.TypeBackSlash().value
           ) {
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }

        let userAction = UserAction.getUserAction(eventCore: event.keyEventCore, inputLanguage: inputLanguage)

        // 英数キー（keyCode 102）の処理
        if event.keyCode == 102 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 102)

            if isDoubleTap {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "english") {
                        return true
                    }
                }
                if !self.segmentsManager.isEmpty {
                    _ = self.handleClientAction(.submitHalfWidthRomanCandidate, clientActionCallback: .transition(.none), client: client)
                    self.switchInputLanguage(.english, client: client)
                    return true
                }
            }
        }

        // かなキー（keyCode 104）の処理（ダブルタップで日本語への翻訳）
        if event.keyCode == 104 {
            let isDoubleTap = checkAndUpdateDoubleTap(keyCode: 104)
            if isDoubleTap {
                let selectedRange = client.selectedRange()
                if selectedRange.length > 0 {
                    if self.triggerAiTranslation(initialPrompt: "japanese") {
                        return true
                    }
                }
            }
        }

        // Check if AI backend is enabled
        let aiBackendEnabled = Config.AIBackendPreference().value != .off

        // Handle suggest action with selected text check (prevent recursive calls)
        if case .suggest = userAction {
            // If AI backend is off, ignore the suggest action
            if !aiBackendEnabled {
                self.segmentsManager.appendDebugMessage("Suggest action ignored: AI backend is off")
                return false
            }

            // Prevent recursive window calls
            if self.isPromptWindowVisible {
                self.segmentsManager.appendDebugMessage("Suggest action ignored: prompt window already visible")
                return true
            }

            let selectedRange = client.selectedRange()
            self.segmentsManager.appendDebugMessage("Suggest action detected. Selected range: \(selectedRange)")
            if selectedRange.length > 0 {
                self.segmentsManager.appendDebugMessage("Selected text found, showing prompt input window")
                // There is selected text, show prompt input window
                return self.handleClientAction(.showPromptInputWindow, clientActionCallback: .fallthrough, client: client)
            } else {
                self.segmentsManager.appendDebugMessage("No selected text, using normal suggest behavior")
            }
        }

        if inputState == .selecting, event.keyEventCore.modifierFlags.isEmpty,
           case .navigation(let direction) = userAction {
            let treeDirection: CandidateTreeSelection.Direction
            switch direction {
            case .left: treeDirection = .left
            case .right: treeDirection = .right
            case .up: treeDirection = .up
            case .down: treeDirection = .down
            }
            if candidatesViewController.handleTreeNavigation(treeDirection) {
                return true
            }
        }

        let (clientAction, clientActionCallback) = inputState.event(
            eventCore: event.keyEventCore,
            userAction: userAction,
            inputLanguage: self.inputLanguage,
            liveConversionEnabled: Config.LiveConversion().value,
            enableDebugWindow: Config.DebugWindow().value,
            enableSuggestion: aiBackendEnabled
        )
        return handleClientAction(clientAction, clientActionCallback: clientActionCallback, client: client)
    }

    private var inputStyle: InputStyle {
        switch Config.InputStyle().value {
        case .default:
            .mapped(id: .defaultRomanToKana)
        case .defaultAZIK:
            .mapped(id: .defaultAZIK)
        case .defaultKanaUS:
            .mapped(id: .defaultKanaUS)
        case .defaultKanaJIS:
            .mapped(id: .defaultKanaJIS)
        case .custom:
            if CustomInputTableStore.exists() {
                .mapped(id: .tableName(CustomInputTableStore.tableName))
            } else {
                .mapped(id: .defaultRomanToKana)
            }
        }
    }

    // この種のコードは複雑にしかならないので、lintを無効にする
    // swiftlint:disable:next cyclomatic_complexity
    @MainActor func handleClientAction(_ clientAction: ClientAction, clientActionCallback: ClientActionCallback, client: IMKTextInput) -> Bool {
        self.reconversionClient.beginInput()
        let commitSource: MacReconversionSession.CommitSource?
        switch clientAction {
        case .commitMarkedText, .commitMarkedTextAndAppendToMarkedText, .commitMarkedTextAndAppendPieceToMarkedText,
             .commitMarkedTextAndSelectInputLanguage, .stopComposition:
            commitSource = self.reconversionClient.captureCommit(from: self.segmentsManager, client: client)
        default:
            commitSource = nil
        }
        defer { self.reconversionClient.rememberCommit(commitSource, manager: self.segmentsManager, client: client) }
        switch clientAction {
        case .requestPredictiveSuggestion, .requestReplaceSuggestion, .consume:
            break
        default:
            if self.aiSuggestionSession.isLoading {
                self.cancelReplaceSuggestion()
            }
            self.aiSuggestionStatusPanel.orderOut(nil)
        }
        // return only false
        switch clientAction {
        case .showCandidateWindow:
            self.segmentsManager.requestSetCandidateWindowState(visible: true)
        case .hideCandidateWindow:
            self.segmentsManager.cancelCandidateSelection()
        case .enterFirstCandidatePreviewMode:
            self.segmentsManager.insertCompositionSeparator(inputStyle: self.inputStyle, skipUpdate: false)
            self.segmentsManager.requestSetCandidateWindowState(visible: false)
        case .enterCandidateSelectionMode:
            self.segmentsManager.insertCompositionSeparator(inputStyle: self.inputStyle, skipUpdate: true)
            self.segmentsManager.update(requestRichCandidates: true)
        case .appendToMarkedText(let string):
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(string, inputStyle: inputStyle)
        case .appendPieceToMarkedText(let pieces):
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .insertWithoutMarkedText(let string):
            client.insertText(string, replacementRange: NSRange(location: NSNotFound, length: 0))
        case .editSegment(let count):
            self.segmentsManager.editSegment(count: count)
        case .moveCompositionCursor(let movement):
            self.segmentsManager.moveCompositionCursor(movement)
        case .commitMarkedText:
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        case .commitMarkedTextAndAppendToMarkedText(let string):
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(string, inputStyle: inputStyle)
        case .commitMarkedTextAndAppendPieceToMarkedText(let pieces):
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            // 英語モードの場合は.directでローマ字変換せずそのまま入力
            let inputStyle: InputStyle = self.inputLanguage == .english ? .direct : self.inputStyle
            self.segmentsManager.insertAtCursorPosition(pieces: pieces, inputStyle: inputStyle)
        case .submitSelectedCandidate:
            self.submitSelectedCandidate()
        case .removeLastMarkedText:
            self.segmentsManager.deleteBackwardFromCursorPosition()
            self.segmentsManager.requestResettingSelection()
        case .removeNextMarkedText:
            self.segmentsManager.deleteForwardFromCursorPosition()
            self.segmentsManager.requestResettingSelection()
        case .selectPrevCandidate:
            self.segmentsManager.requestSelectingPrevCandidate()
        case .selectNextCandidate:
            self.segmentsManager.requestSelectingNextCandidate()
        case .selectNumberCandidate(let num):
            self.segmentsManager.requestSelectingRow(self.candidatesViewController.getNumberCandidate(num: num))
            self.submitSelectedCandidate()
            self.segmentsManager.requestResettingSelection()
        case .submitHiraganaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toHiragana()
            })
        case .submitKatakanaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toKatakana()
            })
        case .submitHankakuKatakanaCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRubyCandidate(inputState: self.inputState) {
                $0.toKatakana().applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            })
        case .submitFullWidthRomanCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRomanCandidate(inputState: self.inputState) {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: true)!
            })
        case .submitHalfWidthRomanCandidate:
            self.submitCandidate(self.segmentsManager.getModifiedRomanCandidate(inputState: self.inputState) {
                $0.applyingTransform(.fullwidthToHalfwidth, reverse: false)!
            })
        case .enableDebugWindow:
            self.segmentsManager.requestDebugWindowMode(enabled: true)
        case .disableDebugWindow:
            self.segmentsManager.requestDebugWindowMode(enabled: false)
        case .stopComposition:
            self.reconversionClient.restoreOriginal(client: client)
            self.segmentsManager.stopComposition()
        case .forgetMemory:
            self.segmentsManager.forgetMemory()
        case .selectInputLanguage(let language):
            self.switchInputLanguage(language, client: client)
        case .commitMarkedTextAndSelectInputLanguage(let language):
            let text = self.segmentsManager.commitMarkedText(inputState: self.inputState)
            client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            self.switchInputLanguage(language, client: client)
        // PredictiveSuggestion
        case .requestPredictiveSuggestion:
            // 「つづき」を直接入力し、コンテキストを渡す
            self.segmentsManager.insertAtCursorPosition("つづき", inputStyle: self.inputStyle)
            self.requestReplaceSuggestion()
        case .acceptPredictionCandidate:
            self.acceptPredictionCandidate()
        // ReplaceSuggestion
        case .requestReplaceSuggestion:
            self.requestReplaceSuggestion()
        case .selectNextReplaceSuggestionCandidate:
            self.replaceSuggestionsViewController.selectNextCandidate()
        case .selectPrevReplaceSuggestionCandidate:
            self.replaceSuggestionsViewController.selectPrevCandidate()
        case .submitReplaceSuggestionCandidate:
            self.submitSelectedSuggestionCandidate(client: client)
        case .hideReplaceSuggestionWindow:
            self.cancelReplaceSuggestion()
        // Selected Text Transform
        case .showPromptInputWindow:
            self.segmentsManager.appendDebugMessage("Executing showPromptInputWindow")
            self.showPromptInputWindow()
        case .transformSelectedText(let selectedText, let prompt):
            self.segmentsManager.appendDebugMessage("Executing transformSelectedText with text: '\(selectedText)' and prompt: '\(prompt)'")
            self.transformSelectedText(selectedText: selectedText, prompt: prompt)
        // Unicode Input (Shift+Ctrl+U)
        case .enterUnicodeInputMode:
            // 状態遷移は clientActionCallback で行われるので、ここでは何もしない
            break
        case .appendToUnicodeInput:
            // markedText の更新は refreshMarkedText で行われる
            break
        case .removeLastUnicodeInput:
            // markedText の更新は refreshMarkedText で行われる
            break
        case .submitUnicodeInput(let codePoint):
            if let scalar = UInt32(codePoint, radix: 16), let unicodeScalar = Unicode.Scalar(scalar) {
                let character = String(Character(unicodeScalar))
                client.insertText(character, replacementRange: NSRange(location: NSNotFound, length: 0))
            }
        case .cancelUnicodeInput:
            // 状態遷移は clientActionCallback で行われるので、ここでは何もしない
            break
        case .submitSelectedCandidateAndEnterUnicodeInputMode:
            // 選択中の候補を確定
            self.submitSelectedCandidate()
            // 残りのテキストがあればひらがなのまま確定
            if !self.segmentsManager.isEmpty {
                let text = self.segmentsManager.convertTarget
                client.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
                self.segmentsManager.stopComposition()
            }
        // MARK: 特殊ケース
        case .consume:
            // 何もせず先に進む
            break
        case .fallthrough:
            return false
        }

        switch clientActionCallback {
        case .fallthrough:
            break
        case .transition(let inputState):
            // 遷移した時にreplaceSuggestionWindowをhideする
            if inputState != .replaceSuggestion {
                self.replaceSuggestionWindow.orderOut(nil)
            }
            if inputState == .none {
                self.switchInputLanguage(self.inputLanguage, client: client)
            }
            self.inputState = inputState
        case .basedOnBackspace(let ifIsEmpty, let ifIsNotEmpty), .basedOnSubmitCandidate(let ifIsEmpty, let ifIsNotEmpty):
            self.inputState = self.segmentsManager.isEmpty ? ifIsEmpty : ifIsNotEmpty
        }

        if self.inputState != .replaceSuggestion, !self.aiSuggestionSession.isLoading {
            self.aiSuggestionSession.cancel()
            self.clearReplaceSuggestionCandidates()
        }
        if self.segmentsManager.isEmpty {
            self.reconversionClient.restoreOriginal(client: client)
        }
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
        return true
    }

    @MainActor func switchInputLanguage(_ language: InputLanguage, client: IMKTextInput) {
        if self.aiSuggestionSession.isLoading {
            self.cancelReplaceSuggestion()
        }
        self.inputLanguage = language
        client.overrideKeyboard(withKeyboardNamed: Config.KeyboardLayout().value.layoutIdentifier)
        switch language {
        case .english:
            client.selectMode("dev.ensan.inputmethod.azooKeyMac.Roman")
            self.segmentsManager.stopJapaneseInput()
        case .japanese:
            client.selectMode("dev.ensan.inputmethod.azooKeyMac.Japanese")
        }
    }

    func refreshCandidateWindow() {
        let preedit = self.segmentsManager.getCurrentMarkedText(inputState: self.inputState).map(\.content).joined()
        switch self.segmentsManager.getCurrentCandidateWindow(inputState: self.inputState) {
        case .selecting(let candidates, let selectionIndex):
            var rect: NSRect = .zero
            self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            self.candidatesViewController.showCandidateIndex = true
            let candidatePresentations = self.segmentsManager.makeCandidatePresentations(candidates)
            self.candidatesViewController.alignWithDocument(candidatePresentations, selectionIndex: selectionIndex, preedit: preedit) { offset in
                var wordRect: NSRect = .zero
                self.client().attributes(forCharacterIndex: offset, lineHeightRectangle: &wordRect)
                return wordRect
            }
            self.candidatesViewController.updateCandidatePresentations(
                candidatePresentations,
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .composing(let candidates, let selectionIndex):
            var rect: NSRect = .zero
            self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            self.candidatesViewController.showCandidateIndex = false
            let candidatePresentations = self.segmentsManager.makeCandidatePresentations(candidates)
            self.candidatesViewController.alignWithDocument(candidatePresentations, selectionIndex: selectionIndex, preedit: preedit) { offset in
                var wordRect: NSRect = .zero
                self.client().attributes(forCharacterIndex: offset, lineHeightRectangle: &wordRect)
                return wordRect
            }
            self.candidatesViewController.updateCandidatePresentations(
                candidatePresentations,
                selectionIndex: selectionIndex,
                cursorLocation: rect.origin
            )
            self.candidatesWindow.orderFront(nil)
        case .hidden:
            self.candidatesWindow.setIsVisible(false)
            self.candidatesWindow.orderOut(nil)
            self.candidatesViewController.hide()
        }
    }

    func refreshPredictionWindow() {
        guard self.inputState == .composing else {
            self.hidePredictionWindow()
            return
        }

        let predictions = self.requestPreferredPredictionCandidates()
        if predictions.isEmpty {
            let now = Date().timeIntervalSince1970
            let elapsed = now - self.lastPredictionUpdateTime
            if elapsed < 1.0, !self.lastPredictionCandidates.isEmpty {
                self.showCachedPredictionWindow()
                self.schedulePredictionHide(after: max(0, 1.0 - elapsed))
                return
            }
            self.hidePredictionWindow()
            return
        }

        self.predictionHideWorkItem?.cancel()
        let candidates = predictions.map { prediction in
            Candidate(
                text: prediction.displayText,
                value: 0,
                composingCount: .surfaceCount(prediction.displayText.count),
                lastMid: 0,
                data: []
            )
        }

        self.lastPredictionCandidates = candidates.map(\.text)
        self.lastPredictionUpdateTime = Date().timeIntervalSince1970

        var rect: NSRect = .zero
        self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.predictionViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: nil,
            cursorLocation: rect.origin
        )

        if self.candidatesWindow.isVisible {
            self.positionPredictionWindowRightOfCandidateWindow()
        }
        self.predictionWindow.orderFront(nil)
    }

    private func positionPredictionWindowRightOfCandidateWindow(gap: CGFloat = 8) {
        // アンカーである候補ウィンドウの中心が乗っているスクリーンを基準にする。
        // predictionWindow.screen / candidatesWindow.screen はマルチディスプレイ遷移直後に
        // 古いディスプレイを返すことがあるため、frame の中心点で能動的に判定する。
        let anchorFrame = self.candidatesWindow.frame
        let anchorCenter = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        guard let screen = ScreenLookup.screen(containing: anchorCenter, fallbackWindow: self.candidatesWindow) else {
            return
        }

        var frame = WindowPositioning.frameRightOfAnchor(
            currentFrame: WindowPositioning.Rect(self.predictionWindow.frame),
            anchorFrame: WindowPositioning.Rect(anchorFrame),
            screenRect: WindowPositioning.Rect(screen.visibleFrame),
            gap: Double(gap)
        ).cgRect
        // The compact tree also appears during live conversion. At a screen
        // edge the usual horizontal clamp can put predictions on top of it.
        if Config.TreeCandidates().value, frame.intersects(anchorFrame) {
            let below = anchorFrame.minY - frame.height - gap
            let above = anchorFrame.maxY + gap
            if below >= screen.visibleFrame.minY {
                frame.origin.y = below
            } else if above + frame.height <= screen.visibleFrame.maxY {
                frame.origin.y = above
            } else if anchorFrame.minX - frame.width - gap >= screen.visibleFrame.minX {
                frame.origin.x = anchorFrame.minX - frame.width - gap
            }
        }
        self.predictionWindow.setFrame(frame, display: true)
    }

    private func showCachedPredictionWindow() {
        let candidates = self.lastPredictionCandidates.map { text in
            Candidate(
                text: text,
                value: 0,
                composingCount: .surfaceCount(text.count),
                lastMid: 0,
                data: []
            )
        }
        guard !candidates.isEmpty else {
            return
        }
        var rect: NSRect = .zero
        self.client().attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.predictionViewController.updateCandidatePresentations(
            candidates.map { .init(candidate: $0) },
            selectionIndex: nil,
            cursorLocation: rect.origin
        )
        if self.candidatesWindow.isVisible {
            self.positionPredictionWindowRightOfCandidateWindow()
        }
        self.predictionWindow.orderFront(nil)
    }

    private func schedulePredictionHide(after delay: TimeInterval) {
        self.predictionHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }
            let now = Date().timeIntervalSince1970
            if now - self.lastPredictionUpdateTime >= 1.0 {
                self.hidePredictionWindow()
            }
        }
        self.predictionHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hidePredictionWindow() {
        self.predictionWindow.setIsVisible(false)
        self.predictionWindow.orderOut(nil)
        self.lastPredictionCandidates = []
        self.lastPredictionUpdateTime = 0
        self.predictionHideWorkItem?.cancel()
        self.predictionHideWorkItem = nil
    }

    @MainActor
    private func acceptPredictionCandidate() {
        self.segmentsManager.acceptPredictionCandidate()
    }

    private func requestPreferredPredictionCandidates() -> [SegmentsManager.PredictionCandidate] {
        SegmentsManager.preferredPredictionCandidates(
            typoCorrectionCandidates: self.segmentsManager.requestTypoCorrectionPredictionCandidates(),
            predictionCandidates: self.segmentsManager.requestPredictionCandidates()
        )
    }

    @MainActor func handleSuggestionError(_ error: Error, cursorPosition: CGPoint) {
        let errorMessage = "エラーが発生しました: \(error.localizedDescription)"
        self.segmentsManager.appendDebugMessage(errorMessage)
    }

    func getCursorLocation() -> CGPoint {
        var rect: NSRect = .zero
        self.client()?.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        self.segmentsManager.appendDebugMessage("カーソル位置取得: \(rect.origin)")
        return rect.origin
    }

    func refreshMarkedText() {
        let highlight = self.mark(
            forStyle: kTSMHiliteSelectedConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let underline = self.mark(
            forStyle: kTSMHiliteConvertedText,
            at: NSRange(location: NSNotFound, length: 0)
        ) as? [NSAttributedString.Key: Any]
        let text = NSMutableAttributedString(string: "")
        let currentMarkedText = self.segmentsManager.getCurrentMarkedText(inputState: self.inputState)
        for part in currentMarkedText where !part.content.isEmpty {
            let attributes: [NSAttributedString.Key: Any]? = switch part.focus {
            case .focused: highlight
            case .unfocused: underline
            case .none: [:]
            }
            text.append(
                NSAttributedString(
                    string: part.content,
                    attributes: attributes
                )
            )
        }
        self.client()?.setMarkedText(
            text,
            selectionRange: currentMarkedText.selectionRange,
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
    }

    @MainActor
    func submitCandidate(_ candidate: Candidate) {
        self.cancelReplaceSuggestion()
        if let client = self.client() {
            guard self.reconversionClient.originalText == nil || self.segmentsManager.consumesWholeComposition(candidate) else {
                self.showReconversionFailure(.wholeSelectionRequired)
                return
            }
            let commitSource = self.reconversionClient.captureCommit(from: self.segmentsManager, client: client)
            // インサートを行う前にコンテキストを取得する
            let cleanLeftSideContext = self.segmentsManager.getCleanLeftSideContext(maxCount: 30)
            client.insertText(candidate.text, replacementRange: NSRange(location: NSNotFound, length: 0))
            // アプリケーションサポートのディレクトリを準備しておく
            self.segmentsManager.prefixCandidateCommited(candidate, leftSideContext: cleanLeftSideContext ?? "")
            self.reconversionClient.rememberCommit(commitSource, manager: self.segmentsManager, client: client)
        }
    }

    @MainActor
    func submitSelectedCandidate() {
        if let candidate = self.segmentsManager.selectedCandidate {
            self.submitCandidate(candidate)
            self.segmentsManager.requestResettingSelection()
        }
    }
}

extension azooKeyMacInputController: CandidatesViewControllerDelegate {
    func candidateSubmitted() {
        self.submitSelectedCandidate()
        self.inputState = self.segmentsManager.isEmpty ? .none : .previewing
        self.refreshMarkedText()
        self.refreshCandidateWindow()
        self.refreshPredictionWindow()
    }

    func candidateSubmitted(_ row: Int) {
        self.segmentsManager.requestSelectingRow(row)
        self.candidateSubmitted()
    }

    func candidateSelectionChanged(_ row: Int) {
        self.cancelReplaceSuggestion()
        self.segmentsManager.requestSelectingRow(row)
        self.inputState = .selecting
        self.refreshMarkedText()
        self.refreshCandidateWindow()
    }
}

extension azooKeyMacInputController: SegmentManagerDelegate {
    func getLeftSideContext(maxCount: Int) -> String? {
        let endIndex = self.contextRange().location
        let leftRange = NSRange(location: max(endIndex - maxCount, 0), length: min(endIndex, maxCount))
        var actual = NSRange()
        // 同じ行の文字のみコンテキストに含める
        let leftSideContext = self.client().string(from: leftRange, actualRange: &actual)
        self.segmentsManager.appendDebugMessage("\(#function): leftSideContext=\(leftSideContext ?? "nil")")
        return leftSideContext
    }

    func getRightSideContext(maxCount: Int) -> String? {
        let range = self.contextRange()
        let startIndex = range.location + range.length
        let documentLength = self.client().length()
        guard startIndex < documentLength else {
            return nil
        }
        let rightRange = NSRange(location: startIndex, length: min(documentLength - startIndex, maxCount))
        var actual = NSRange()
        let rightSideContext = self.client().string(from: rightRange, actualRange: &actual)
        self.segmentsManager.appendDebugMessage("\(#function): rightSideContext=\(rightSideContext ?? "nil")")
        return rightSideContext
    }

    private func contextRange() -> NSRange {
        let markedRange = self.client().markedRange()
        if markedRange.location != NSNotFound {
            return markedRange
        }
        let selectedRange = self.client().selectedRange()
        if selectedRange.location != NSNotFound {
            return selectedRange
        }
        return NSRange(location: 0, length: 0)
    }
}

extension azooKeyMacInputController: ReplaceSuggestionsViewControllerDelegate {
    @MainActor func replaceSuggestionSelectionChanged(_ row: Int) {
        self.aiSuggestionSession.select(row)
        self.segmentsManager.requestSelectingSuggestionRow(row)
        self.refreshMarkedText()
    }

    func replaceSuggestionSubmitted() {
        Task { @MainActor in
            guard let client = self.client() else {
                return
            }
            self.submitSelectedSuggestionCandidate(client: client)
        }
    }
}
