import AppKit
import Core
import SwiftUI

@MainActor
struct UserDictionaryEditorWindow: View {
    // Keep the entry list, form, and save controls visible when many rows are invalid.
    private static let maximumIssueListHeight: CGFloat = 120
    private static let minimumWindowWidth: CGFloat = 600
    private static let minimumWindowHeight: CGFloat = 400
    private static let actionColumnWidth: CGFloat = 80
    @StateObject private var model: UserDictionaryEditorModel

    init(model: UserDictionaryEditorModel? = nil) {
        _model = StateObject(wrappedValue: model ?? UserDictionaryEditorModel(
            entries: Config.UserDictionary().value.items,
            save: UserDictionarySaveService.save
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(UserDictionaryMessages.text("title")).font(.title2).bold()
            Text(UserDictionaryMessages.text("draftHelp")).foregroundStyle(.secondary)
            HStack {
                Text(String(format: UserDictionaryMessages.text("countFormat"), model.entries.count))
                Spacer()
                Button {
                    model.beginAdding()
                } label: {
                    Label(UserDictionaryMessages.text("add"), systemImage: "plus")
                }
                .disabled(!model.canAdd)
            }
            if model.entries.count >= UserDictionaryEditorModel.entryLimit {
                Text(String(format: UserDictionaryMessages.text("limitFormat"), UserDictionaryEditorModel.entryLimit))
                    .font(.caption)
            }
            entriesTable
            if model.draft != nil {
                editorForm
            }
            feedback
            HStack {
                if model.isSaving {
                    ProgressView().controlSize(.small)
                    Text(UserDictionaryMessages.text("saving"))
                }
                Spacer()
                Button(UserDictionaryMessages.text("cancel")) {
                    model.cancelChanges()
                    (NSApplication.shared.delegate as? AppDelegate)?.userDictionaryEditorWindow?.close()
                }
                .disabled(model.isSaving)
                Button(UserDictionaryMessages.text("save")) {
                    Task { await model.save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSaving || model.needsRecovery || (!model.hasUnsavedChanges && model.draft == nil))
            }
        }
        .padding()
        .frame(minWidth: Self.minimumWindowWidth, minHeight: Self.minimumWindowHeight)
        .background(UserDictionaryWindowGuard(
            canClose: { !model.isSaving }, onClose: { model.cancelChanges() }
        ))
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if isDictionaryWindow(notification.object) {
                model.refreshIfUnchanged(Config.UserDictionary().value.items)
            }
        }
    }

    private var entriesTable: some View {
        Table(model.entries) {
            TableColumn("") { item in
                HStack {
                    Button {
                        model.beginEditing(item.id)
                    } label: {
                        Label(UserDictionaryMessages.text("edit"), systemImage: "pencil")
                    }
                    .accessibilityLabel(Text(UserDictionaryMessages.text("edit") + " " + item.word))
                    Button(role: .destructive) {
                        model.remove(item.id)
                    } label: {
                        Label(UserDictionaryMessages.text("delete"), systemImage: "trash")
                    }
                    .accessibilityLabel(Text(UserDictionaryMessages.text("delete") + " " + item.word))
                }
                .labelStyle(.iconOnly)
            }
            .width(Self.actionColumnWidth)
            TableColumn(UserDictionaryMessages.text("word"), value: \.word)
            TableColumn(UserDictionaryMessages.text("reading"), value: \.reading)
            TableColumn(UserDictionaryMessages.text("hint"), value: \.nonNullHint)
        }
        .disabled(model.isSaving || model.needsRecovery || model.draft != nil)
    }

    private var editorForm: some View {
        Form {
            TextField(UserDictionaryMessages.text("word"), text: $model.draftWord)
            TextField(UserDictionaryMessages.text("reading"), text: $model.draftReading)
            TextField(UserDictionaryMessages.text("hint"), text: $model.draftHint)
            Button(UserDictionaryMessages.text("cancelEdit")) {
                model.cancelEditing()
            }
        }
        .disabled(model.isSaving || model.needsRecovery)
    }

    @ViewBuilder
    private var feedback: some View {
        if !model.issues.isEmpty {
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(Array(model.issues.enumerated()), id: \.offset) { _, issue in
                        Text(issueMessage(issue)).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.maximumIssueListHeight)
            .accessibilityLabel(Text(UserDictionaryMessages.text("validationIssues")))
        }
        if let key = model.failureMessageKey {
            Text(UserDictionaryMessages.text(key)).foregroundStyle(.red).textSelection(.enabled)
        }
        if model.didSave {
            Text(UserDictionaryMessages.text("saved")).foregroundStyle(.secondary)
        }
    }

    private func issueMessage(_ issue: UserDictionaryValidation.Issue) -> String {
        let key: String
        switch (issue.field, issue.reason) {
        case (.word, .empty): key = "emptyWord"
        case (.reading, .empty): key = "emptyReading"
        case (.word, .controlCharacter): key = "controlWord"
        case (.reading, .controlCharacter): key = "controlReading"
        default: key = "unsupportedReading"
        }
        let field = UserDictionaryMessages.text(issue.field.rawValue)
        let reason = UserDictionaryMessages.text(key)
        if let index = model.entries.firstIndex(where: { $0.id == issue.rowID }) {
            return String(format: UserDictionaryMessages.text("rowIssueFormat"), index + 1, field, reason)
        }
        if model.draft?.id == issue.rowID {
            return String(format: UserDictionaryMessages.text("rowIssueFormat"), model.entries.count + 1, field, reason)
        }
        let word = Config.SystemUserDictionary().value.items.first { $0.id == issue.rowID }?.word ?? ""
        return String(format: UserDictionaryMessages.text("systemIssueFormat"), word, field, reason)
    }

    private func isDictionaryWindow(_ object: Any?) -> Bool {
        guard let window = object as? NSWindow,
              let dictionaryWindow = (NSApplication.shared.delegate as? AppDelegate)?.userDictionaryEditorWindow else {
            return false
        }
        return window === dictionaryWindow
    }
}
