import Core
import SwiftUI

/// The pinned instruction whose shortcut is being edited.
struct ShortcutEditorTarget: Identifiable {
    let item: AIPromptHistory.Item
    var id: String { item.prompt }
}

struct ShortcutEditorSheet: View {
    @State private var shortcut: Core.KeyboardShortcut
    @State private var hasShortcut: Bool
    @State private var refusal: String?
    let item: AIPromptHistory.Item
    /// Saves the shortcut (nil removes it). Returns why Core refused it, or nil once saved.
    let onSave: (Core.KeyboardShortcut?) -> String?
    let onCancel: () -> Void

    // The transform shortcut stays free for opening the prompt without an instruction.
    private var isSystemShortcut: Bool {
        hasShortcut && shortcut == Config.TransformShortcut().value
    }

    init(item: AIPromptHistory.Item, onSave: @escaping (Core.KeyboardShortcut?) -> String?, onCancel: @escaping () -> Void) {
        self.item = item
        self._shortcut = State(initialValue: item.shortcut ?? Core.KeyboardShortcut(key: "a", modifiers: .control))
        self._hasShortcut = State(initialValue: item.shortcut != nil)
        self.onSave = onSave
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(Localization.text("ai.shortcut.prompt") + "：" + item.prompt)
                .font(.headline)

            VStack(spacing: 12) {
                // Keyboard shortcut
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Toggle(Localization.text("shortcut.enabled"), isOn: $hasShortcut)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if hasShortcut {
                        KeyboardShortcutRecorder(shortcut: $shortcut, accessibilityName: Localization.text("ai.shortcut.prompt"))
                            .frame(height: 40)

                        if isSystemShortcut {
                            AccessibleStatusMessage(text: Localization.text("shortcut.reserved"))
                                .font(.callout)
                                .foregroundColor(.red)
                        }
                    }
                    if let refusal {
                        AccessibleStatusMessage(text: refusal)
                            .font(.callout)
                            .foregroundColor(.red)
                    }
                }
            }
            .onChange(of: shortcut) { _ in refusal = nil }
            .onChange(of: hasShortcut) { _ in refusal = nil }

            HStack {
                Button(Localization.text("settings.cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Spacer()

                if hasShortcut {
                    Button(Localization.text("shortcut.remove")) {
                        refusal = onSave(nil)
                    }
                }

                Button(Localization.text("settings.save")) {
                    refusal = onSave(hasShortcut ? shortcut : nil)
                }
                .disabled(isSystemShortcut)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
