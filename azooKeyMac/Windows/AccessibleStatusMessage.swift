import AppKit
import SwiftUI

/// Keep a visible status available while announcing changes to VoiceOver.
struct AccessibleStatusMessage: View {
    let text: String

    var body: some View {
        Text(text)
            .onAppear(perform: announce)
            .onChange(of: text) { _ in announce() }
    }

    private func announce() {
        guard !text.isEmpty else {
            return
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue
            ]
        )
    }
}
