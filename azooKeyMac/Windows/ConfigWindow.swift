import Cocoa
import Core
import SwiftUI

struct ConfigWindow: View {
    @ConfigState private var liveConversion = Config.LiveConversion()
    @ConfigState private var treeCandidates = Config.TreeCandidates()
    @ConfigState private var candidateTextSize = Config.CandidateTextSize()
    @ConfigState private var showRelativeScores = Config.ShowRelativeScores()
    @ConfigState private var inputStyle = Config.InputStyle()
    @ConfigState private var typeBackSlash = Config.TypeBackSlash()
    @ConfigState private var punctuationStyle = Config.PunctuationStyle()
    @ConfigState private var typeHalfSpace = Config.TypeHalfSpace()
    @ConfigState private var optionDirectFullWidthInput = Config.OptionDirectFullWidthInput()
    @ConfigState private var zenzaiProfile = Config.ZenzaiProfile()
    @ConfigState private var zenzaiPersonalizationLevel = Config.ZenzaiPersonalizationLevel()
    @ConfigState private var inferenceLimit = Config.ZenzaiInferenceLimit()
    @ConfigState private var debugWindow = Config.DebugWindow()
    @ConfigState private var debugPredictiveTyping = Config.DebugPredictiveTyping()
    @ConfigState private var debugTypoCorrection = Config.DebugTypoCorrection()
    @ConfigState private var userDictionary = Config.UserDictionary()
    @ConfigState private var systemUserDictionary = Config.SystemUserDictionary()
    @ConfigState private var keyboardLayout = Config.KeyboardLayout()

    @State private var selectedTab: Tab = Config.SetupGuideSeen().value ? .input : .support
    @State private var zenzaiProfileHelpPopover = false
    @State private var zenzaiInferenceLimitHelpPopover = false
    @State private var showingRomajiTableEditor = false
    @State private var systemUserDictionaryUpdateMessage: SystemUserDictionaryUpdateMessage?
    @State private var showingImportedDictionaryResetConfirmation = false
    @State private var debugTypoCorrectionState: DebugTypoCorrectionState = .notDownloaded
    @State private var debugTypoCorrectionDownloadInProgress = false
    @State private var debugTypoCorrectionErrorMessage: String?

    private enum Tab: String, CaseIterable, Hashable {
        case input, conversion, dictionary, ai, support

        var title: String { Localization.text("settings.page." + rawValue) }
    }

    private enum SystemUserDictionaryUpdateMessage {
        case error(any Error)
        case successfulUpdate
    }

    private var azooKeyApplicationSupportDirectoryURL: URL {
        AppGroup.applicationSupportDirectoryURL()
    }

    private var legacyAzooKeyApplicationSupportDirectoryURL: URL {
        if #available(macOS 13, *) {
            URL.applicationSupportDirectory
                .appending(path: "azooKey", directoryHint: .isDirectory)
        } else {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("azooKey", isDirectory: true)
        }
    }

    private var debugTypoCorrectionModelDirectoryURL: URL {
        DebugTypoCorrectionWeights.modelDirectoryURL(
            azooKeyApplicationSupportDirectoryURL: self.azooKeyApplicationSupportDirectoryURL
        )
    }

    private var legacyDebugTypoCorrectionModelDirectoryURL: URL {
        DebugTypoCorrectionWeights.modelDirectoryURL(
            azooKeyApplicationSupportDirectoryURL: self.legacyAzooKeyApplicationSupportDirectoryURL
        )
    }

    private var debugTypoCorrectionStatusText: String {
        if self.debugTypoCorrectionDownloadInProgress {
            return "ダウンロード中..."
        }
        switch self.debugTypoCorrectionState {
        case .downloaded:
            return "重み: ダウンロード済み"
        case .failed:
            return "重み: ダウンロード失敗"
        case .notDownloaded:
            return "重み: ダウンロード未実施"
        }
    }

    @MainActor
    private func refreshDebugTypoCorrectionState() async {
        let modelDirectoryURL = self.debugTypoCorrectionModelDirectoryURL
        let legacyModelDirectoryURL = self.legacyDebugTypoCorrectionModelDirectoryURL
        let state = await Task.detached(priority: .utility) { () -> DebugTypoCorrectionState in
            Self.migrateLegacyDebugTypoCorrectionWeightsIfNeeded(
                from: legacyModelDirectoryURL,
                to: modelDirectoryURL
            )
            return DebugTypoCorrectionWeights.state(modelDirectoryURL: modelDirectoryURL)
        }.value
        self.debugTypoCorrectionState = state
        if state != .failed {
            self.debugTypoCorrectionErrorMessage = nil
        }
    }

    @MainActor
    private func downloadDebugTypoCorrectionWeights() {
        guard !self.debugTypoCorrectionDownloadInProgress else {
            return
        }
        self.debugTypoCorrectionDownloadInProgress = true
        self.debugTypoCorrectionErrorMessage = nil

        let modelDirectoryURL = self.debugTypoCorrectionModelDirectoryURL
        Task {
            do {
                try await DebugTypoCorrectionWeights.downloadWeights(modelDirectoryURL: modelDirectoryURL)
                let state = await Task.detached(priority: .utility) {
                    DebugTypoCorrectionWeights.state(modelDirectoryURL: modelDirectoryURL)
                }.value
                await MainActor.run {
                    self.debugTypoCorrectionState = state
                    self.debugTypoCorrectionErrorMessage = state == .failed ? "ダウンロード後の整合性チェックに失敗しました" : nil
                    self.debugTypoCorrectionDownloadInProgress = false
                }
            } catch {
                await MainActor.run {
                    self.debugTypoCorrectionState = .failed
                    self.debugTypoCorrectionErrorMessage = error.localizedDescription
                    self.debugTypoCorrectionDownloadInProgress = false
                }
            }
        }
    }

    nonisolated private static func migrateLegacyDebugTypoCorrectionWeightsIfNeeded(from sourceURL: URL, to targetURL: URL) {
        guard sourceURL.standardizedFileURL != targetURL.standardizedFileURL else {
            return
        }
        guard !DebugTypoCorrectionWeights.hasRequiredWeightFiles(modelDirectoryURL: targetURL),
              DebugTypoCorrectionWeights.hasRequiredWeightFiles(modelDirectoryURL: sourceURL) else {
            return
        }
        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: targetURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: targetURL.path) {
                try fileManager.removeItem(at: targetURL)
            }
            try fileManager.copyItem(at: sourceURL, to: targetURL)
        } catch {
            // The status check below will surface a notDownloaded/failed state.
        }
    }

    private func openAzooKeyDataDirectoryInFinder() {
        do {
            try FileManager.default.createDirectory(
                at: self.azooKeyApplicationSupportDirectoryURL,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.activateFileViewerSelecting([self.azooKeyApplicationSupportDirectoryURL])
        } catch {
            // no-op
        }
    }

    private func exportUserDictionary() {
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            appDelegate.exportUserDictionaryAndReloadConverter()
        }
    }

    @ViewBuilder
    private func helpButton(helpContent: LocalizedStringKey, isPresented: Binding<Bool>) -> some View {
        if #available(macOS 14, *) {
            Button("ヘルプ", systemImage: "questionmark") {
                isPresented.wrappedValue = true
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .popover(isPresented: isPresented) {
                Text(helpContent).padding()
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            inputTabView.tabItem { Text(Tab.input.title) }.tag(Tab.input)
            conversionTabView.tabItem { Text(Tab.conversion.title) }.tag(Tab.conversion)
            dictionaryTabView.tabItem { Text(Tab.dictionary.title) }.tag(Tab.dictionary)
            AISettingsView().tabItem { Text(Tab.ai.title) }.tag(Tab.ai)
            SupportSettingsView().tabItem { Text(Tab.support.title) }.tag(Tab.support)
        }
        .frame(width: 600, height: 500)
        .sheet(isPresented: $showingRomajiTableEditor) {
            RomajiTableEditorWindow(base: CustomInputTableStore.loadTable()) { exported in
                do {
                    _ = try CustomInputTableStore.save(exported: exported)
                    CustomInputTableStore.registerIfExists()
                } catch {
                    print("Failed to save custom input table: \(error)")
                }
            }
        }
    }

    // MARK: - 入力
    @ViewBuilder
    private var inputTabView: some View {
        Form {
            Section {
                Toggle("円記号の代わりにバックスラッシュを入力", isOn: $typeBackSlash)
                Toggle("スペースは常に半角を入力", isOn: $typeHalfSpace)
                Toggle("Optionキーで直接全角英数を入力", isOn: $optionDirectFullWidthInput)
                Picker("句読点の種類", selection: $punctuationStyle) {
                    Text("、と。").tag(Config.PunctuationStyle.Value.`kutenAndToten`)
                    Text("、と．").tag(Config.PunctuationStyle.Value.periodAndToten)
                    Text("，と。").tag(Config.PunctuationStyle.Value.kutenAndComma)
                    Text("，と．").tag(Config.PunctuationStyle.Value.periodAndComma)
                }
            } header: {
                Label("入力オプション", systemImage: "character.cursor.ibeam")
            }

            Section {
                Picker("入力方式", selection: $inputStyle) {
                    Text("デフォルト").tag(Config.InputStyle.Value.default)
                    Text("かな入力（JIS）").tag(Config.InputStyle.Value.defaultKanaJIS)
                    Text("かな入力（US）").tag(Config.InputStyle.Value.defaultKanaUS)
                    Text("AZIK").tag(Config.InputStyle.Value.defaultAZIK)
                    Text("カスタム").tag(Config.InputStyle.Value.custom)
                }
                if inputStyle.value == .custom {
                    LabeledContent {
                        Button("編集") {
                            showingRomajiTableEditor = true
                        }
                    } label: {
                        Text("カスタム入力テーブル")
                    }
                }
            } header: {
                Label("入力方式", systemImage: "keyboard")
            }

            Section {
                Picker("キーボード配列", selection: $keyboardLayout) {
                    Text("QWERTY").tag(Config.KeyboardLayout.Value.qwerty)
                    Text("Australian").tag(Config.KeyboardLayout.Value.australian)
                    Text("British").tag(Config.KeyboardLayout.Value.british)
                    Text("Colemak").tag(Config.KeyboardLayout.Value.colemak)
                    Text("Dvorak").tag(Config.KeyboardLayout.Value.dvorak)
                    Text("Dvorak - QWERTY ⌘").tag(Config.KeyboardLayout.Value.dvorakQwertyCommand)
                }
            } header: {
                Label("キーボード配列", systemImage: "keyboard.badge.ellipsis")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var conversionTabView: some View {
        Form {
            Section {
                Toggle("ライブ変換を有効化", isOn: $liveConversion)
                Toggle("変換候補を木構造で表示", isOn: $treeCandidates)
                Picker(Localization.text("candidate.textSize"), selection: $candidateTextSize) {
                    Text(Localization.text("candidate.textSize.standard")).tag(Config.CandidateTextSize.Value.standard)
                    Text(Localization.text("candidate.textSize.large")).tag(Config.CandidateTextSize.Value.large)
                }
                Toggle(Localization.text("candidate.score.show"), isOn: $showRelativeScores)
                Text(CandidateScorePresentation.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("変換設定", systemImage: "brain")
            }
            Section {
                HStack {
                    TextField(
                        "Zenzaiの推論上限",
                        text: Binding(
                            get: {
                                String(self.$inferenceLimit.wrappedValue)
                            },
                            set: {
                                if let value = Int($0), (1 ... 50).contains(value) {
                                    self.$inferenceLimit.wrappedValue = value
                                }
                            }
                        )
                    )
                    Stepper("", value: $inferenceLimit, in: 1 ... 50)
                        .labelsHidden()
                    helpButton(helpContent: "推論上限を小さくすると、入力中のもたつきが改善されることがあります。", isPresented: $zenzaiInferenceLimitHelpPopover)
                }
            } header: {
                Label("Zenzai設定", systemImage: "cpu")
            }

            Section {
                Toggle("デバッグウィンドウを有効化", isOn: $debugWindow)
                Toggle("開発中の予測入力を有効化", isOn: $debugPredictiveTyping)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("開発中の入力訂正を有効化", isOn: $debugTypoCorrection)
                    if self.debugTypoCorrection.value {
                        HStack {
                            Text(self.debugTypoCorrectionStatusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if self.debugTypoCorrectionDownloadInProgress {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Spacer()
                            switch self.debugTypoCorrectionState {
                            case .downloaded:
                                EmptyView()
                            case .failed:
                                Button("再ダウンロード") {
                                    self.downloadDebugTypoCorrectionWeights()
                                }
                                .disabled(self.debugTypoCorrectionDownloadInProgress)
                            case .notDownloaded:
                                Button("ダウンロード") {
                                    self.downloadDebugTypoCorrectionWeights()
                                }
                                .disabled(self.debugTypoCorrectionDownloadInProgress)
                            }
                        }
                        if case .failed = self.debugTypoCorrectionState,
                           let errorMessage = self.debugTypoCorrectionErrorMessage {
                            Text(errorMessage)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .onAppear {
                    guard self.debugTypoCorrection.value else {
                        return
                    }
                    Task { @MainActor in
                        await self.refreshDebugTypoCorrectionState()
                    }
                }
                .onChange(of: self.debugTypoCorrection.value) { enabled in
                    if enabled {
                        Task { @MainActor in
                            await self.refreshDebugTypoCorrectionState()
                        }
                    } else {
                        self.debugTypoCorrectionState = .notDownloaded
                        self.debugTypoCorrectionDownloadInProgress = false
                        self.debugTypoCorrectionErrorMessage = nil
                    }
                }
                LabeledContent("アプリデータ") {
                    HStack {
                        Button("Finderで開く") {
                            self.openAzooKeyDataDirectoryInFinder()
                        }
                    }
                }
            } header: {
                Label("開発者向け設定", systemImage: "hammer")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var dictionaryTabView: some View {
        Form {
            Section {
                LabeledContent {
                    HStack {
                        Text("\(self.userDictionary.value.items.count)件のアイテム")
                        Button("編集") {
                            (NSApplication.shared.delegate as? AppDelegate)!.openUserDictionaryEditorWindow()
                        }
                    }
                } label: {
                    Text("azooKeyユーザ辞書")
                }
                LabeledContent {
                    HStack {
                        switch self.systemUserDictionaryUpdateMessage {
                        case .none:
                            if let updated = self.systemUserDictionary.value.lastUpdate {
                                let date = updated.formatted(date: .omitted, time: .omitted)
                                Text("最終更新: \(date) / \(self.systemUserDictionary.value.items.count)件のアイテム")
                            } else {
                                Text("未設定")
                            }
                        case .error(let error):
                            Text("読み込みエラー: \(error.localizedDescription)")
                        case .successfulUpdate:
                            Text("読み込みに成功しました / \(self.systemUserDictionary.value.items.count)件のアイテム")
                        }
                        Button("読み込む") {
                            do {
                                let systemUserDictionaryEntries = try SystemUserDictionaryHelper.fetchEntries()
                                self.systemUserDictionary.value.items = systemUserDictionaryEntries.map {
                                    .init(word: $0.phrase, reading: $0.shortcut)
                                }
                                self.systemUserDictionary.value.lastUpdate = .now
                                self.systemUserDictionaryUpdateMessage = .successfulUpdate
                                self.exportUserDictionary()
                            } catch {
                                self.systemUserDictionaryUpdateMessage = .error(error)
                            }
                        }
                        Button(Localization.text("dictionary.imported.reset.action")) {
                            showingImportedDictionaryResetConfirmation = true
                        }
                        .confirmationDialog(
                            Localization.text("dictionary.imported.reset.title"),
                            isPresented: $showingImportedDictionaryResetConfirmation, titleVisibility: .visible
                        ) {
                            Button(Localization.text("dictionary.imported.reset.confirm"), role: .destructive) {
                                self.systemUserDictionary.value.lastUpdate = nil
                                self.systemUserDictionary.value.items = []
                                self.systemUserDictionaryUpdateMessage = nil
                                self.exportUserDictionary()
                            }
                            Button(Localization.text("settings.cancel"), role: .cancel) {}
                        } message: {
                            Text(Localization.text("dictionary.imported.reset.explanation"))
                        }
                    }
                } label: {
                    Text("システムのユーザ辞書")
                }
            } header: {
                Label("ユーザ辞書", systemImage: "book.closed")
            }

            LearningSettingsSection()

            Section {
                HStack {
                    TextField(Localization.text("settings.profile"), text: $zenzaiProfile, prompt: Text("例：田中太郎/高校生"))
                    helpButton(
                        helpContent: """
                    Zenzaiはあなたのプロフィールを考慮した変換を行うことができます。
                    名前や仕事、趣味などを入力すると、それに合わせた変換が自動で推薦されます。
                    （実験的な機能のため、精度が不十分な場合があります）
                    """,
                        isPresented: $zenzaiProfileHelpPopover
                    )
                }
                Picker(Localization.text("settings.personalization"), selection: $zenzaiPersonalizationLevel) {
                    Text("オフ").tag(Config.ZenzaiPersonalizationLevel.Value.off)
                    Text("弱く").tag(Config.ZenzaiPersonalizationLevel.Value.soft)
                    Text("普通").tag(Config.ZenzaiPersonalizationLevel.Value.normal)
                    Text("強く").tag(Config.ZenzaiPersonalizationLevel.Value.hard)
                }
                Text(Localization.text("settings.personalization.explanation"))
                    .font(.callout)
            } header: {
                Text(Localization.text("settings.personalization"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

}

#Preview {
    ConfigWindow()
}
