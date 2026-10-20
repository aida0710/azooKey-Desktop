import Core
import Foundation
import SwiftUI

struct PromptInputView: View {
    @State private var promptText: String = ""
    @State private var preview = AITransformationPreview()
    @State private var showPreview: Bool = false
    @State private var previewError: String?
    @State private var promptHistory: [PromptHistoryItem] = []
    @State private var hoveredHistoryIndex: Int?
    @State private var isNavigatingHistory: Bool = false
    @State private var includeContext: Bool = Config.IncludeContextInAITransform().value
    @State private var editingShortcutFor: PromptHistoryItem?
    @FocusState private var isTextFieldFocused: Bool

    let initialPrompt: String?
    let requestConfiguration: AIRequestConfiguration
    let targetText: String
    private var previewText: String { preview.applicableText ?? "" }
    private var isLoading: Bool { preview.isLoading }
    private var modelDisplayName: String {
        switch requestConfiguration.backend {
        case .foundationModels:
            return "Foundation Models"
        case .openAI:
            return requestConfiguration.modelName
        }
    }

    let onSubmit: (String?) -> Void
    let onPreview: (String, Bool, @escaping (Result<String, TransformationPreviewError>) -> Void) -> Void
    let onApply: (String) -> Void
    let onCancel: () -> Void
    let onPreviewModeChanged: (Bool) -> Void

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

            AIRequestScopeView(configuration: requestConfiguration, targetText: targetText)
                .padding(.horizontal, 12)
            if let previewError {
                AccessibleStatusMessage(text: previewError)
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
                        selectHistory(getVisibleHistory()[index])
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
                            ForEach(Array(getVisibleHistory().enumerated()), id: \.offset) { index, item in
                                HStack(spacing: 4) {
                                    // Pin button
                                    Button {
                                        togglePin(for: item)
                                    } label: {
                                        Image(systemName: item.isPinned ? "pin.fill" : "pin")
                                            .font(.system(size: 9))
                                            .foregroundColor(item.isPinned ? .accentColor : .secondary.opacity(0.4))
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help(Localization.text(item.isPinned ? "ai.unpin" : "ai.pin"))
                                    .accessibilityLabel(Localization.text(item.isPinned ? "ai.unpin" : "ai.pin"))
                                    .accessibilityValue(item.prompt)

                                    // Shortcut button (only for pinned items)
                                    if item.isPinned {
                                        Button {
                                            editingShortcutFor = item
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
                    .disabled(preview.applicableText == nil)
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
                    .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
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
            let trimmedInitialPrompt = initialPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            promptText = trimmedInitialPrompt ?? ""
            preview.invalidate()
            previewError = nil
            showPreview = false
            hoveredHistoryIndex = nil
            isNavigatingHistory = false

            // Load prompt history
            loadPromptHistory()

            // Notify initial preview mode state
            onPreviewModeChanged(false)

            isTextFieldFocused = true
        }
        .onDisappear { preview.invalidate() }
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
        .sheet(item: $editingShortcutFor) { item in
            ShortcutEditorSheet(
                item: item,
                allItems: promptHistory,
                onSave: { updatedItem in
                    updateShortcut(for: updatedItem)
                    editingShortcutFor = nil
                },
                onCancel: {
                    editingShortcutFor = nil
                }
            )
        }
    }

    private func requestPreview() {
        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !isLoading else {
            return
        }

        // Save prompt to history
        savePromptToHistory(trimmedPrompt)

        // Reset hover when requesting preview
        hoveredHistoryIndex = nil

        performPreview(trimmedPrompt)
    }

    private func reloadPreview() {
        let trimmedPrompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty, !isLoading else {
            return
        }

        // Don't save to history again since this is a reload
        hoveredHistoryIndex = nil

        performPreview(trimmedPrompt)
    }

    private func performPreview(_ prompt: String) {
        previewError = nil
        let request = preview.begin()
        onPreview(prompt, includeContext) { outcome in
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.3)) {
                    switch outcome {
                    case .success(let text):
                        guard self.preview.complete(text, for: request) else {
                            return
                        }
                        self.showPreview = self.preview.applicableText != nil
                    case .failure(let error):
                        guard self.preview.complete(nil, for: request) else {
                            return
                        }
                        self.previewError = error.message
                        self.showPreview = false
                    }
                    self.onPreviewModeChanged(self.showPreview)
                }
            }
        }
    }

    private func applyPreview() {
        guard let text = preview.applicableText else {
            return
        }
        onApply(text)
        onSubmit(promptText)
    }

    private func invalidatePreview() {
        preview.invalidate()
        previewError = nil
        showPreview = false
        onPreviewModeChanged(false)
    }

    private func loadPromptHistory() {
        // Try to load as Data first (new format)
        if let data = Config.data(forKey: Config.PromptHistory.key) {
            if let history = try? JSONDecoder().decode([PromptHistoryItem].self, from: data) {
                promptHistory = history
                return
            } else if let oldHistory = try? JSONDecoder().decode([String].self, from: data) {
                // Convert old format to new format
                promptHistory = oldHistory.map { PromptHistoryItem(prompt: $0, isPinned: false) }
                savePinnedHistory() // Save in new format
                return
            }
        }

        // Fallback to string format (legacy)
        let historyString = Config.string(forKey: Config.PromptHistory.key) ?? ""
        if !historyString.isEmpty,
           let data = historyString.data(using: .utf8) {
            if let history = try? JSONDecoder().decode([PromptHistoryItem].self, from: data) {
                promptHistory = history
                savePinnedHistory() // Migrate to new format
            } else if let oldHistory = try? JSONDecoder().decode([String].self, from: data) {
                // Convert old format to new format
                promptHistory = oldHistory.map { PromptHistoryItem(prompt: $0, isPinned: false) }
                savePinnedHistory() // Save in new format
            }
        }

        // Add default pinned prompts if history is empty
        if promptHistory.isEmpty {
            promptHistory = [
                PromptHistoryItem(prompt: Localization.text("ai.example.elaborate"), isPinned: true),
                PromptHistoryItem(prompt: Localization.text("ai.example.rewrite"), isPinned: true),
                PromptHistoryItem(prompt: Localization.text("ai.example.formal"), isPinned: true),
                PromptHistoryItem(prompt: Localization.text("ai.example.english"), isPinned: true)
            ]
            savePinnedHistory()
        }
    }

    private func selectHistory(_ item: PromptHistoryItem) {
        invalidatePreview()
        promptText = item.prompt
        hoveredHistoryIndex = nil
        isTextFieldFocused = true
    }

    private func getVisibleHistory() -> [PromptHistoryItem] {
        // Sort pinned items by lastUsed date (most recent first)
        let pinnedItems = promptHistory.filter { $0.isPinned }.sorted { $0.lastUsed > $1.lastUsed }
        let recentItems = promptHistory.filter { !$0.isPinned }.prefix(max(0, 10 - pinnedItems.count))
        return Array(pinnedItems + recentItems)
    }

    private func togglePin(for item: PromptHistoryItem) {
        if let index = promptHistory.firstIndex(where: { $0.id == item.id }) {
            promptHistory[index].isPinned.toggle()
            savePinnedHistory()
        }
    }

    private func updateShortcut(for item: PromptHistoryItem) {
        if let index = promptHistory.firstIndex(where: { $0.id == item.id }) {
            // Clear conflicting keyboard shortcuts from other items
            if let newShortcut = item.shortcut {
                for i in promptHistory.indices where i != index {
                    if promptHistory[i].shortcut == newShortcut {
                        promptHistory[i].shortcut = nil
                    }
                }
            }

            // Update the item
            promptHistory[index].shortcut = item.shortcut
            savePinnedHistory()
        }
    }

    private func savePromptToHistory(_ prompt: String) {
        // Check if prompt already exists and preserve its pinned status
        if let existingIndex = promptHistory.firstIndex(where: { $0.prompt == prompt }) {
            // Update lastUsed time and move to appropriate position
            let existingItem = promptHistory[existingIndex]
            promptHistory.remove(at: existingIndex)

            // Create updated item with new lastUsed time but preserve pinned status and shortcut
            var updatedItem = PromptHistoryItem(prompt: prompt, isPinned: existingItem.isPinned, shortcut: existingItem.shortcut)
            updatedItem.id = existingItem.id

            if existingItem.isPinned {
                // For pinned items, just update in place (sorting will handle position)
                promptHistory.append(updatedItem)
            } else {
                // For non-pinned items, add to front
                promptHistory.insert(updatedItem, at: 0)
            }
        } else {
            // Add new item to front (non-pinned)
            let newItem = PromptHistoryItem(prompt: prompt, isPinned: false)
            promptHistory.insert(newItem, at: 0)
        }

        // Keep only last 10 non-pinned prompts
        let pinnedItems = promptHistory.filter { $0.isPinned }
        let recentItems = promptHistory.filter { !$0.isPinned }.prefix(10)
        promptHistory = Array(pinnedItems + recentItems)

        // Save to UserDefaults
        savePinnedHistory()
    }

    private func savePinnedHistory() {
        if let data = try? JSONEncoder().encode(promptHistory) {
            Config.set(data, forKey: Config.PromptHistory.key)
        }
    }

    private enum NavigationDirection {
        case up, down
    }

    private func navigateHistory(direction: NavigationDirection) {
        let visibleHistory = getVisibleHistory()
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
    PromptInputView(
        initialPrompt: nil,
        requestConfiguration: AIRequestConfiguration(
            backend: .openAI, modelName: "preview", apiKey: "", apiEndpoint: "https://example.invalid"
        ),
        targetText: "確認する本文",
        onSubmit: { _ in
        },
        onPreview: { prompt, _, callback in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                callback(.success("Transformed: \(prompt)"))
            }
        },
        onApply: { _ in
        },
        onCancel: {
        },
        onPreviewModeChanged: { _ in
        }
    )
    .frame(width: 380)
}
