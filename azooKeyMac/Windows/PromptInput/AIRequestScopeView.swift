import Core
import SwiftUI

struct AIRequestScopeView: View {
    let configuration: AIRequestConfiguration
    let targetText: String
    // Keep the target scrollable while leaving the send controls visible.
    private static let previewHeight: CGFloat = 72
    private static let previewInset: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(Localization.text("ai.scope.destination")): \(configuration.destinationLabel)")
                .font(.callout)
                .textSelection(.enabled)
            Text(Localization.text("ai.scope.target"))
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                Text(targetText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: Self.previewHeight)
            .padding(Self.previewInset)
            .background(.thinMaterial)
            Text(Localization.text("ai.scope.history"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
    }
}
