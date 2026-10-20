import Cocoa
import Core
import SwiftUI

struct SupportSettingsView: View {
    // Give setup instructions and diagnostics enough room in the separate help window.
    static let preferredWindowSize = CGSize(width: 600, height: 620)
    @State private var diagnostics = SupportDiagnostics.current()
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Text(Localization.text("support.setup.mac"))
                Text(Localization.text("support.recovery"))
                Link(Localization.text("support.guide"), destination: SupportLinks.guide)
                Link(Localization.text("support.releases"), destination: SupportLinks.releases)
                Link(Localization.text("support.issues"), destination: SupportLinks.issues)
                Link(Localization.text("support.upstream"), destination: SupportLinks.upstream)
            } header: {
                Text(Localization.text("support.guide"))
            }
            HomebrewUpdateView()
            Section {
                Text(diagnostics).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text(Localization.text("support.privacy")).font(.caption)
                HStack {
                    Button(Localization.text("support.refresh")) {
                        diagnostics = SupportDiagnostics.current()
                        copied = false
                    }
                    Button(Localization.text("support.copy")) {
                        diagnostics = SupportDiagnostics.current()
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics, forType: .string)
                        copied = true
                    }
                }
                if copied {
                    Text(Localization.text("support.copied"))
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { Config.SetupGuideSeen().value = true }
    }
}
