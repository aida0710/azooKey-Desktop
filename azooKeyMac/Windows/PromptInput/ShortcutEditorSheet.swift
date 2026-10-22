import Core
import SwiftUI

struct ShortcutEditorSheet: View {
    @State private var item: PromptHistoryItem
    @State private var shortcut: Core.KeyboardShortcut
    @State private var hasShortcut: Bool
    let allItems: [PromptHistoryItem]
    let onSave: (PromptHistoryItem) -> Void
    let onCancel: () -> Void

    // Reserved system shortcuts
    private var reservedShortcuts: [Core.KeyboardShortcut] {
        [
            Config.TransformShortcut().value
        ]
    }

    private var conflictingPrompt: String? {
        guard hasShortcut else {
            return nil
        }
        return allItems.first(where: { otherItem in
            otherItem.id != item.id &&
                otherItem.shortcut == shortcut
        })?.prompt
    }

    private var isSystemShortcut: Bool {
        guard hasShortcut else {
            return false
        }
        return reservedShortcuts.contains(shortcut)
    }

    init(item: PromptHistoryItem, allItems: [PromptHistoryItem], onSave: @escaping (PromptHistoryItem) -> Void, onCancel: @escaping () -> Void) {
        self._item = State(initialValue: item)
        self._shortcut = State(initialValue: item.shortcut ?? Core.KeyboardShortcut(key: "a", modifiers: .control))
        self._hasShortcut = State(initialValue: item.shortcut != nil)
        self.allItems = allItems
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

                        // Conflict warnings
                        if isSystemShortcut {
                            AccessibleStatusMessage(text: Localization.text("shortcut.reserved"))
                                .font(.callout)
                                .foregroundColor(.red)
                        } else if let conflicting = conflictingPrompt {
                            AccessibleStatusMessage(text: Localization.text("shortcut.conflict") + " " + conflicting)
                                .font(.callout)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            HStack {
                Button(Localization.text("settings.cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.escape)

                Spacer()

                if hasShortcut {
                    Button(Localization.text("shortcut.remove")) {
                        var updatedItem = item
                        updatedItem.shortcut = nil
                        onSave(updatedItem)
                    }
                }

                Button(Localization.text("settings.save")) {
                    var updatedItem = item
                    updatedItem.shortcut = hasShortcut ? shortcut : nil
                    onSave(updatedItem)
                }
                .disabled(isSystemShortcut)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}
