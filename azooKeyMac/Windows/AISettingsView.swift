import Cocoa
import Core
import SwiftUI

struct AISettingsView: View {
    @ConfigState private var openAiApiKey = Config.OpenAiApiKey()
    @ConfigState private var openAiModelName = Config.OpenAiModelName()
    @ConfigState private var openAiApiEndpoint = Config.OpenAiApiEndpoint()
    @ConfigState private var aiBackend = Config.AIBackendPreference()
    @ConfigState private var includeContextInAITransform = Config.IncludeContextInAITransform()
    @ConfigState private var transformShortcut = Config.TransformShortcut()
    @ConfigState private var aiPromptLanguage = Config.AIPromptLanguage()
    @State private var openAiApiKeyPopover = false
    @State private var connectionTestInProgress = false
    @State private var connectionTestResult: String?
    @State private var foundationModelsAvailability: FoundationModelsAvailability?
    @State private var availabilityCheckDone = false

    private func getErrorMessage(for error: OpenAIError) -> String {
        switch error {
        case .invalidURL:
            return "エラー: 無効なURL形式です"
        case .noServerResponse:
            return "エラー: サーバーから応答がありません"
        case .invalidResponseStatus(let code, let body):
            return getHTTPErrorMessage(code: code, body: body)
        case .parseError(let message):
            return "エラー: レスポンス解析失敗 - \(message)"
        case .invalidResponseStructure:
            return "エラー: 予期しないレスポンス形式"
        }
    }

    private func getHTTPErrorMessage(code: Int, body: String) -> String {
        switch code {
        case 401:
            return "エラー: APIキーが無効です"
        case 403:
            return "エラー: アクセスが拒否されました"
        case 404:
            return "エラー: エンドポイントが見つかりません"
        case 429:
            return "エラー: レート制限に達しました"
        case 500...599:
            return "エラー: サーバーエラー (コード: \(code))"
        default:
            return "エラー: HTTPステータス \(code)\n詳細: \(body.prefix(100))..."
        }
    }

    func testConnection() async {
        connectionTestInProgress = true
        connectionTestResult = nil

        do {
            let testRequest = OpenAIRequest(
                prompt: "テスト",
                target: "",
                modelName: openAiModelName.value.isEmpty ? Config.OpenAiModelName.default : openAiModelName.value
            )
            _ = try await OpenAIClient.sendRequest(
                testRequest,
                apiKey: openAiApiKey.value,
                apiEndpoint: openAiApiEndpoint.value
            )

            connectionTestResult = "接続成功"
        } catch let error as OpenAIError {
            connectionTestResult = getErrorMessage(for: error)
        } catch {
            connectionTestResult = "エラー: \(error.localizedDescription)"
        }

        connectionTestInProgress = false
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
        Form {
            Section {
                VStack(alignment: .leading) {
                    Picker(Localization.text("ai.title"), selection: $aiBackend) {
                        Text("オフ").tag(Config.AIBackendPreference.Value.off)

                        if let availability = foundationModelsAvailability, availability.isAvailable {
                            Text("Foundation Models").tag(Config.AIBackendPreference.Value.foundationModels)
                        }

                        Text(Localization.text("ai.backend.external")).tag(Config.AIBackendPreference.Value.openAI)
                    }
                    .onAppear {
                        if !availabilityCheckDone {
                            foundationModelsAvailability = FoundationModelsClientCompat.checkAvailability()
                            availabilityCheckDone = true

                            let hasSetAIBackend = UserDefaults.standard.bool(forKey: "hasSetAIBackendManually")
                            if !hasSetAIBackend,
                               aiBackend.value == .off,
                               let availability = foundationModelsAvailability,
                               availability.isAvailable {
                                aiBackend.value = .foundationModels
                                UserDefaults.standard.set(true, forKey: "hasSetAIBackendManually")
                            }

                            if aiBackend.value == .foundationModels,
                               let availability = foundationModelsAvailability,
                               !availability.isAvailable {
                                aiBackend.value = .off
                            }
                        }
                    }
                    .onChange(of: aiBackend.value) { _ in
                        UserDefaults.standard.set(true, forKey: "hasSetAIBackendManually")
                    }
                }

                Text(Localization.text("ai.scope.processing"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if aiBackend.value != .off {
                    Toggle(Localization.text("ai.scope.include-context"), isOn: $includeContextInAITransform)
                    if let configuration = AIRequestConfiguration.current() {
                        Text("\(Localization.text("ai.scope.destination")): \(configuration.destinationLabel)")
                            .font(.caption)
                            .textSelection(.enabled)
                    }
                }

                if aiBackend.value == .openAI {
                    HStack {
                        SecureField(Localization.text("ai.api-key"), text: $openAiApiKey, prompt: Text("例:sk-xxxxxxxxxxx"))
                        helpButton(
                            helpContent: LocalizedStringKey(Localization.text("ai.scope.api-key")),
                            isPresented: $openAiApiKeyPopover
                        )
                    }
                    TextField(Localization.text("ai.model"), text: $openAiModelName, prompt: Text("例: gpt-4o-mini"))
                    TextField(Localization.text("ai.endpoint"), text: $openAiApiEndpoint, prompt: Text("例: https://api.openai.com/v1/chat/completions"))
                        .help("例: https://api.openai.com/v1/chat/completions\nGemini: https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")

                    HStack {
                        Button("接続テスト") {
                            Task {
                                await testConnection()
                            }
                        }
                        .disabled(connectionTestInProgress || openAiApiKey.value.isEmpty)

                        if connectionTestInProgress {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                    }

                    if let result = connectionTestResult {
                        AccessibleStatusMessage(text: result)
                            .foregroundColor(result.contains("成功") ? .green : .red)
                            .font(.caption)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Label(Localization.text("ai.title"), systemImage: "sparkles")
            }
            Section {
                LabeledContent(Localization.text("ai.shortcut")) {
                    KeyboardShortcutRecorder(shortcut: $transformShortcut, accessibilityName: Localization.text("ai.shortcut"))
                }
                Picker(Localization.text("ai.prompt-language"), selection: $aiPromptLanguage) {
                    Text(Localization.text("ai.prompt-language.en")).tag(Config.AIPromptLanguage.Value.english)
                    Text(Localization.text("ai.prompt-language.ja")).tag(Config.AIPromptLanguage.Value.japanese)
                }
                Text(Localization.text("ai.prompt-language.explanation"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
