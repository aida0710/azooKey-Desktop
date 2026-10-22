import Cocoa
import Core
import SwiftUI

struct LearningSettingsSection: View {
    @ConfigState private var learning = Config.Learning()
    @State private var showingResetConfirmation = false
    @State private var resetMessage: String?
    @State private var resetFailed = false

    var body: some View {
        Section {
            Picker(Localization.text("learning.title"), selection: $learning) {
                ForEach(Config.Learning.Value.allCases, id: \.self) { mode in
                    Text(Localization.text(mode.labelKey)).tag(mode)
                }
            }
            Text(Localization.text("learning.retention"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let resetMessage {
                AccessibleStatusMessage(text: resetMessage)
                    .foregroundColor(resetFailed ? .red : .primary)
            }
            Button(Localization.text("learning.reset.action")) {
                showingResetConfirmation = true
            }
            .confirmationDialog(
                Localization.text("learning.reset.title"),
                isPresented: $showingResetConfirmation, titleVisibility: .visible
            ) {
                Button(Localization.text("learning.reset.confirm"), role: .destructive) {
                    resetHistory()
                }
                Button(Localization.text("settings.cancel"), role: .cancel) {}
            } message: {
                Text(Localization.text("learning.reset.explanation"))
            }
        } header: {
            Label(Localization.text("learning.title"), systemImage: "memorychip")
        }
    }

    @MainActor
    private func resetHistory() {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else {
            resetMessage = Localization.text("learning.reset.failed")
            resetFailed = true
            return
        }
        appDelegate.kanaKanjiConverter.resetMemory()
        resetMessage = Localization.text("learning.reset.completed")
        resetFailed = false
    }
}
