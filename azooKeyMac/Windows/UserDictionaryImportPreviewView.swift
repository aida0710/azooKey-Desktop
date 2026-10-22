import Core
import SwiftUI

@MainActor
struct UserDictionaryImportPreviewView: View {
    // Keep source, content, outcome and reason visible together before confirming an import.
    private static let minimumWidth: CGFloat = 850
    private static let minimumHeight: CGFloat = 420
    private static let sourceColumnWidth: CGFloat = 90
    private static let outcomeColumnWidth: CGFloat = 90
    private static let minimumReasonWidth: CGFloat = 200
    private static let preferredReasonWidth: CGFloat = 260
    // Long comments must not push the confirmation controls out of the sheet.
    private static let maximumDetailsHeight: CGFloat = 120
    let preview: UserDictionaryImportPreview.Preview
    let canApply: Bool
    let cancel: () -> Void
    let apply: () -> Void
    @State private var selectedSourceIndex: Int?

    private var selectedRow: UserDictionaryImportPreview.Row? {
        preview.rows.first { $0.source.sourceIndex == selectedSourceIndex }
    }

    private struct PreviewRow: Identifiable {
        let row: UserDictionaryImportPreview.Row
        var id: Int { row.source.sourceIndex }
        var location: String {
            if let line = row.source.sourceLine {
                return String(format: UserDictionaryMessages.text("importLineFormat"), line)
            }
            return String(format: UserDictionaryMessages.text("importItemFormat"), row.source.sourceIndex)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(UserDictionaryMessages.text("importPreview")).font(.title2).bold()
            Text(String(
                format: UserDictionaryMessages.text("importCountsFormat"),
                preview.counts.additions, preview.counts.duplicates, preview.counts.conflicts, preview.counts.excluded
            ))
            if preview.notices.contains(.properNounRegistration) {
                Text(UserDictionaryMessages.text("importProperNounNotice")).foregroundStyle(.secondary)
            }
            Text(UserDictionaryMessages.text("importDraftHelp")).foregroundStyle(.secondary)
            Table(preview.rows.map { PreviewRow(row: $0) }, selection: $selectedSourceIndex) {
                TableColumn(UserDictionaryMessages.text("importSource")) { row in
                    Text(row.location)
                }
                .width(Self.sourceColumnWidth)
                TableColumn(UserDictionaryMessages.text("word")) { row in
                    Text(row.row.source.item?.word ?? "")
                }
                TableColumn(UserDictionaryMessages.text("reading")) { row in
                    Text(row.row.source.item?.reading ?? "")
                }
                TableColumn(UserDictionaryMessages.text("hint")) { row in
                    Text(row.row.source.item?.nonNullHint ?? "")
                }
                TableColumn(UserDictionaryMessages.text("importOutcome")) { row in
                    Text(UserDictionaryMessages.text("importOutcome." + row.row.outcome.rawValue))
                }
                .width(Self.outcomeColumnWidth)
                TableColumn(UserDictionaryMessages.text("importReason")) { row in
                    Text(UserDictionaryExchangeFeedback.importReason(row.row))
                        .help(UserDictionaryExchangeFeedback.importReason(row.row))
                }
                .width(min: Self.minimumReasonWidth, ideal: Self.preferredReasonWidth)
            }
            if let row = selectedRow {
                ScrollView {
                    Text(selectedDetails(row))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: Self.maximumDetailsHeight)
                .accessibilityLabel(Text(UserDictionaryMessages.text("importSelectedDetail")))
            }
            HStack {
                Spacer()
                Button(UserDictionaryMessages.text("cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(UserDictionaryMessages.text("importApply"), action: apply)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canApply)
            }
        }
        .padding()
        .frame(minWidth: Self.minimumWidth, minHeight: Self.minimumHeight)
        .onAppear { selectedSourceIndex = preview.rows.first?.source.sourceIndex }
    }

    private func selectedDetails(_ row: UserDictionaryImportPreview.Row) -> String {
        var fields = [
            UserDictionaryMessages.text("word") + ": " + (row.source.item?.word ?? ""),
            UserDictionaryMessages.text("reading") + ": " + (row.source.item?.reading ?? ""),
            UserDictionaryMessages.text("hint") + ": " + (row.source.item?.nonNullHint ?? "")
        ]
        if let partOfSpeech = row.source.partOfSpeech {
            fields.append(UserDictionaryMessages.text("importPartOfSpeech") + ": " + partOfSpeech)
        }
        let reason = UserDictionaryExchangeFeedback.importReason(row)
        if !reason.isEmpty {
            fields.append(UserDictionaryMessages.text("importReason") + ": " + reason)
        }
        return fields.joined(separator: "\n")
    }
}
