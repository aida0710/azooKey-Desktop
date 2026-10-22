import Core
import Foundation
import SwiftUI

struct PromptInputView: View {
    /// Sends the arguments Core prepared and reports the reply or why it failed.
    typealias PreviewSender = (AIRequestArguments, @escaping (Result<String, TransformationPreviewError>) -> Void) -> Void

    @State private var promptText: String = ""
    /// Core decides what is sent, which preview is current and what may be applied.
    @State private var transformation: AISelectedTextTransformation
    @State private var showPreview: Bool = false
    @State private var previewError: String?
    @State private var historyError: String?
    @State private var promptHistory: [AIPromptHistory.Item] = []
    @State private var hoveredHistoryIndex: Int?
    @State private var isNavigatingHistory: Bool = false
    @State private var includeContext: Bool
    @State private var editingShortcut: ShortcutEditorTarget?
    @FocusState private var isTextFieldFocused: Bool

    let request: PromptInputRequest
    private let history = MacPromptHistory.open()
    private var requestConfiguration: AIRequestConfiguration { request.configuration }
    private var previewText: String { transformation.applicableText ?? "" }
    private var isLoading: Bool { transformation.isLoading }
    private var modelDisplayName: String {
        switch requestConfiguration.backend {
        case .foundationModels:
            return "Foundation Models"
        case .openAI:
            return requestConfiguration.modelName
        }
    }

    let onPreview: PreviewSender
    let onApply: (_ confirmed: AISelectedTextTransformation, _ prompt: String) -> Void
    let onCancel: () -> Void
    let onPreviewModeChanged: (Bool) -> Void

    init(request: PromptInputRequest, onPreview: @escaping PreviewSender,
         onApply: @escaping (_ confirmed: AISelectedTextTransformation, _ prompt: String) -> Void,
         onCancel: @escaping () -> Void, onPreviewModeChanged: @escaping (Bool) -> Void) {
        self.request = request
        self._transformation = State(initialValue: request.transformation)
        self._includeContext = State(initialValue: request.transformation.content.includesContextByDefault)
        self.onPreview = onPreview
        self.onApply = onApply
        self.onCancel = onCancel
        self.onPreviewModeChanged = onPreviewModeChanged
    }

    var body: some View {
        VStack(spacing: 4) {
            // Header with Apple Intelligence-like design
            HStack {
                // Gradient AI icon with glow effect
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 16, height: 16)
                        .blur(radius: 2)
                        .opacity(0.7)

                    Image(systemName: "sparkles")
                        .foregroundColor(.white)
                        .font(.system(size: 8, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(Localization.text("ai.title"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.primary, .secondary],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )

                    Text(modelDisplayName)
                        .font(.system(size: 8, weight: .regular))
                        .foregroundColor(.secondary.opacity(0.7))
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .foregroundColor(.secondary.opacity(0.8))
                        .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(PlainButtonStyle())
                .accessibilityLabel(Localization.text("settings.cancel"))
                .keyboardShortcut(.escape)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            AIRequestScopeView(configuration: requestConfiguration, targetText: transformation.content.target)
                .padding(.horizontal, 12)
            if let message = historyError ?? previewError {
                AccessibleStatusMessage(text: message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            // Input field with custom key handling
            CustomTextField(
                text: $promptText,
                placeholder: Localization.text("ai.instruction-placeholder"),
                accessibilityName: Localization.text("ai.instruction"),
                isFocused: $isTextFieldFocused,
                onSubmit: {
                    guard !isLoading else {
                        return
                    }
                    if let index = hoveredHistoryIndex {
                        selectHistory(promptHistory[index])
                    } else if showPreview {
                        // Apply when Enter is pressed in preview mode
                        applyPreview()
                    } else {
                        // Preview when Enter is pressed in input mode
                        requestPreview()
                    }
                },
                onDownArrow: {
                    // Handle down arrow to start history navigation
                    navigateHistory(direction: .down)
                },
                onUpArrow: {
                    // Handle up arrow for history navigation
                    navigateHistory(direction: .up)
                },
                onCancel: {
                    onCancel()
                }
            )
            .onChange(of: isTextFieldFocused) { isFocused in
                // Notify parent window about focus changes
                NotificationCenter.default.post(name: .textFieldFocusChanged, object: isFocused)
            }
            .onChange(of: promptText) { _ in
                invalidatePreview()
                // Only clear history selection if not navigating through history
                if !isNavigatingHistory {
                    hoveredHistoryIndex = nil
                }
                // Reset navigation flag after text change
                isNavigatingHistory = false
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.regularMaterial)
            }

            // Recent prompts (visible when not in preview mode and available)
            if !promptHistory.isEmpty && !showPreview {
                VStack(alignment: .leading, spacing: 1) {
                    HStack {
                        Text(Localization.text("ai.history"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.6))
                        Spacer()
                    }

                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 1) {
                            ForEach(Array(promptHistory.enumerated()), id: \.offset) { index, item in
                                HStack(spacing: 4) {
                                    // Pin button
                                    Button {
                                        togglePin(for: item)
                                    } label: {
                                        Image(systemName: item.pinned ? "pin.fill" : "pin")
                                            .font(.system(size: 9))
                                            .foregroundColor(item.pinned ? .accentColor : .secondary.opacity(0.4))
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help(Localization.text(item.pinned ? "ai.unpin" : "ai.pin"))
                                    .accessibilityLabel(Localization.text(item.pinned ? "ai.unpin" : "ai.pin"))
                                    .accessibilityValue(item.prompt)

                                    // Shortcut button (only for pinned items)
                                    if item.pinned {
                                        Button {
                                            editingShortcut = ShortcutEditorTarget(item: item)
                                        } label: {
                                            if let shortcut = item.shortcut {
                                                Text(shortcut.displayString)
                                                    .font(.system(size: 8, weight: .medium))
                                                    .foregroundColor(.accentColor)
                                            } else {
                                                Image(systemName: "command")
                                                    .font(.system(size: 9))
                                                    .foregroundColor(.secondary.opacity(0.4))
                                            }
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .help(Localization.text(item.shortcut == nil ? "ai.shortcut.set" : "ai.shortcut.edit"))
                                        .accessibilityLabel(Localization.text("ai.shortcut.prompt"))
                                        .accessibilityValue(item.shortcut?.displayString ?? Localization.text("support.none"))
                                    }

                                    Button {
                                        selectHistory(item)
                                    } label: {
                                        Text(item.prompt)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .lineLimit(1)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(item.prompt)
                                    .accessibilityHint(Localization.text("ai.history.choose"))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(hoveredHistoryIndex == index ? Color.accentColor.opacity(0.2) : Color.clear)
                                }
                                .onHover { isHovered in
                                    hoveredHistoryIndex = isHovered ? index : nil
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 180)
                }
                .padding(.horizontal, 12)
                .padding(.top, 2)
            }

            // Preview section with enhanced design
            if showPreview {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Localization.text("ai.preview"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.secondary)
                        Spacer()

                        // Reload button
                        Button {
                            reloadPreview()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.secondary.opacity(0.8))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .disabled(isLoading)
                        .help(Localization.text("ai.preview.reload"))
                        .accessibilityLabel(Localization.text("ai.preview.reload"))
                        .keyboardShortcut("r", modifiers: .command)
                    }

                    ScrollView {
                        if isLoading {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text(Localization.text("ai.scope.generating"))
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.thinMaterial)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                                    )
                            }
                        } else {
                            Text(previewText)
                                .font(.system(size: 12))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .background {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(.thinMaterial)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
                                        )
                                }
                        }
                    }
                    .frame(minHeight: 40, maxHeight: 70)
                }
                .padding(.horizontal, 12)
            }

            // Action buttons with modern styling
            HStack(spacing: 10) {
                if showPreview {
                    Button(Localization.text("ai.preview.edit")) {
                        invalidatePreview()
                        DispatchQueue.main.async {
                            isTextFieldFocused = true
                        }
                    }
                    .buttonStyle(ModernSecondaryButtonStyle())

                    Spacer()

                    Button(Localization.text("ai.preview.apply")) {
                        applyPreview()
                    }
                    .buttonStyle(ModernPrimaryButtonStyle())
                    .disabled(transformation.applicableText == nil)
                } else {
                    // Include context checkbox
                    Toggle(isOn: $includeContext) {
                        Text(Localization.text("ai.scope.include-context"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                    .toggleStyle(CheckboxToggleStyle())
                    .disabled(isLoading)
                    .onChange(of: includeContext) { newValue in
                        Config.IncludeContextInAITransform().value = newValue
                        invalidatePreview()
                    }

                    Spacer()

                    Button(Localization.text(isLoading ? "ai.scope.generating" : "ai.scope.preview")) {
                        requestPreview()
                    }
                    .buttonStyle(ModernPrimaryButtonStyle())
                    .disabled(transformation.refusal(forPrompt: promptText) != nil)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
            // Reset all state variables when the view appears
            promptText = request.initialPrompt.map(AISelectedTextTransformation.instruction) ?? ""
            transformation.invalidatePreview()
            previewError = nil
            historyError = nil
            showPreview = false
            hoveredHistoryIndex = nil
            isNavigatingHistory = false

            // Load prompt history
            loadPromptHistory()

            // Notify initial preview mode state
            onPreviewModeChanged(false)

            isTextFieldFocused = true
        }
        .onDisappear { transformation.invalidatePreview() }
        .onReceive(NotificationCenter.default.publisher(for: .navigateHistoryUp)) { _ in
            navigateHistory(direction: .up)
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateHistoryDown)) { _ in
            navigateHistory(direction: .down)
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestTextFieldFocus)) { _ in
            // Force focus to text field and clear any history selection
            hoveredHistoryIndex = nil
            isTextFieldFocused = true
        }
        .sheet(item: $editingShortcut) { target in
            ShortcutEditorSheet(
                item: target.item,
                onSave: { shortcut in
                    let refusal = changeHistory {
                        try history.save(target.item.prompt, pinned: target.item.pinned, shortcut: shortcut)
                    }
                    if refusal == nil {
                        editingShortcut = nil
                    }
                    return refusal
                },
                onCancel: {
                    editingShortcut = nil
                }
            )
        }
    }

    private func requestPreview() {
        guard transformation.refusal(forPrompt: promptText) == nil else {
            return
        }
        // The instruction is kept before anything is sent; a history that
        // cannot be saved stops the request, as on the other desktops.
        historyError = changeHistory { try history.recordUse(AISelectedTextTransformation.instruction(promptText)) }
        guard historyError == nil else {
            return
        }

        // Reset hover when requesting preview
        hoveredHistoryIndex = nil

        performPreview()
    }

    private func reloadPreview() {
        guard transformation.refusal(forPrompt: promptText) == nil else {
            return
        }

        // Don't save to history again since this is a reload
        hoveredHistoryIndex = nil

        performPreview()
    }

    private func performPreview() {
        previewError = nil
        guard let started = try? transformation.beginPreview(
            prompt: promptText, includeContext: includeContext, field: request.openedField
        ) else {
            return
        }
        guard let arguments = started.arguments else {
            // Core ended this preview without sending anything.
            previewError = TransformationPreviewError.requestFailed.message
            return
        }
        onPreview(arguments) { outcome in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.3)) {
                    let text = try? outcome.get()
                    // The prompt window holds the focus, so the original field's
                    // input context is judged again when the result is applied.
                    guard self.transformation.completePreview(
                        revision: started.revision, text: text, inputContextChanged: false
                    ) else {
                        return
                    }
                    if case .failure(let error) = outcome {
                        self.previewError = error.message
                    }
                    self.showPreview = self.transformation.applicableText != nil
                    self.onPreviewModeChanged(self.showPreview)
                }
            }
        }
    }

    /// The result reaches the document only if Core still finds the original
    /// selection when focus returns; otherwise it is offered for copying.
    private func applyPreview() {
        guard transformation.applicableText != nil else {
            return
        }
        transformation.confirm()
        onApply(transformation, promptText)
    }

    private func invalidatePreview() {
        transformation.invalidatePreview()
        previewError = nil
        showPreview = false
        onPreviewModeChanged(false)
    }

    private func loadPromptHistory() {
        promptHistory = history.load()
    }

    private func selectHistory(_ item: AIPromptHistory.Item) {
        invalidatePreview()
        promptText = item.prompt
        hoveredHistoryIndex = nil
        isTextFieldFocused = true
    }

    private func togglePin(for item: AIPromptHistory.Item) {
        historyError = changeHistory { try history.save(item.prompt, pinned: !item.pinned, shortcut: item.shortcut) }
    }

    /// Applies one change to the history file and shows the history again.
    /// Returns the message that explains a refused change, or nil.
    private func changeHistory(_ change: () throws -> Void) -> String? {
        defer { loadPromptHistory() }
        do {
            try change()
            return nil
        } catch {
            return Self.historyErrorMessage(error)
        }
    }

    private static func historyErrorMessage(_ error: any Error) -> String {
        let failure = error as? AIPromptHistory.Failure
        return Localization.text(failure == .duplicateShortcut ? "ai.shortcut.error.duplicate" : "ai.history.error.save")
    }

    private enum NavigationDirection {
        case up, down
    }

    private func navigateHistory(direction: NavigationDirection) {
        let visibleHistory = promptHistory
        guard !visibleHistory.isEmpty else {
            hoveredHistoryIndex = nil
            return
        }

        let maxIndex = visibleHistory.count - 1

        switch direction {
        case .up:
            if hoveredHistoryIndex == nil {
                hoveredHistoryIndex = maxIndex
            } else if hoveredHistoryIndex! > 0 {
                hoveredHistoryIndex! -= 1
            } else {
                // When at the first history item and pressing up, return to text field
                hoveredHistoryIndex = nil
                isTextFieldFocused = true
                return // Don't update promptText, keep current text
            }
        case .down:
            if hoveredHistoryIndex == nil {
                // When down is pressed from text field, start history navigation
                hoveredHistoryIndex = 0
                isTextFieldFocused = true
            } else if hoveredHistoryIndex! < maxIndex {
                hoveredHistoryIndex! += 1
            } else {
                // At the end of history, cycle back to start
                hoveredHistoryIndex = 0
            }
        }

        // Validate index bounds and update text field with hovered history item
        if let index = hoveredHistoryIndex, index < visibleHistory.count {
            isNavigatingHistory = true
            promptText = visibleHistory[index].prompt
        } else {
            // Reset invalid index
            hoveredHistoryIndex = nil
        }
    }
}

#Preview {
    let field = AITextField(
        identity: ["preview"], surrounding: .init(text: "確認する本文", cursorUTF16: 6, anchorUTF16: 0),
        hasSurroundingUpdate: true, isSensitive: false
    )
    let configuration = AIRequestConfiguration(
        backend: .openAI, modelName: "preview", apiKey: "", apiEndpoint: "https://example.invalid"
    )
    PromptInputView(
        request: PromptInputRequest(
            initialPrompt: nil, configuration: configuration,
            transformation: AISelectedTextTransformation(id: 0, field: field, configuration: configuration.desktopConfiguration())!,
            openedField: field
        ),
        onPreview: { arguments, callback in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                callback(.success("Transformed: \(arguments.prompt ?? "")"))
            }
        },
        onApply: { _, _ in
        },
        onCancel: {
        },
        onPreviewModeChanged: { _ in
        }
    )
    .frame(width: 380)
}
