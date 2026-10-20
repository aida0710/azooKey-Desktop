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
                Button(UserDictionaryMessages.text("import")) {
                    Task {
                        await model.prepareImport {
                            try await UserDictionaryFilePanels.previewImport(existing: $0, window: dictionaryWindow)
                        }
                    }
                }
                .disabled(!model.canEditEntries)
                Button(UserDictionaryMessages.text("export")) {
                    Task {
                        await model.export {
                            try await UserDictionaryFilePanels.export($0, window: dictionaryWindow)
                        }
                    }
                }
                .disabled(!model.canEditEntries)
                Button {
                    model.beginAdding()
                } label: {
                    Label(UserDictionaryMessages.text("add"), systemImage: "plus")
                }
                .disabled(!model.canAdd)
            }
            HStack {
                TextField(UserDictionaryMessages.text("search"), text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                Text(String(format: UserDictionaryMessages.text("visibleCountFormat"), model.visibleEntries.count))
                    .foregroundStyle(.secondary)
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
                if let operation = model.fileOperation {
                    ProgressView().controlSize(.small)
                    Text(UserDictionaryMessages.text(operation == .importing ? "importing" : "exporting"))
                }
                Spacer()
                Button(UserDictionaryMessages.text("cancel")) {
                    model.cancelChanges()
                    dictionaryWindow?.close()
                }
                .disabled(!model.canClose)
                Button(UserDictionaryMessages.text("save")) {
                    Task { await model.save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canClose || model.needsRecovery || (!model.hasUnsavedChanges && model.draft == nil))
            }
        }
        .padding()
        .frame(minWidth: Self.minimumWindowWidth, minHeight: Self.minimumWindowHeight)
        .background(UserDictionaryWindowGuard(
            canClose: { model.canClose }, onClose: { model.cancelChanges() }
        ))
        .sheet(isPresented: Binding(
            get: { model.importPreview != nil },
            set: { if !$0 { model.cancelImport() } }
        )) {
            if let preview = model.importPreview {
                UserDictionaryImportPreviewView(
                    preview: preview, canApply: model.canApplyImport,
                    cancel: model.cancelImport, apply: model.applyImport
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            if isDictionaryWindow(notification.object) {
                model.refreshIfUnchanged(Config.UserDictionary().value.items)
            }
        }
    }

    private var entriesTable: some View {
        Table(model.visibleEntries, sortOrder: $model.sortOrder) {
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
        .disabled(!model.canEditEntries)
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
        .disabled(model.isBusy || model.needsRecovery)
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
        if model.didExport {
            Text(UserDictionaryMessages.text("exported")).foregroundStyle(.secondary)
        }
    }

    private func issueMessage(_ issue: UserDictionaryValidation.Issue) -> String {
        let field = UserDictionaryMessages.text(issue.field.rawValue)
        let reason = UserDictionaryExchangeFeedback.validationReason(issue)
        let item = model.draft?.id == issue.rowID ? model.draft : model.entries.first { $0.id == issue.rowID }
        if let item {
            return String(
                format: UserDictionaryMessages.text("entryIssueFormat"), item.word, item.reading, field, reason
            )
        }
        let word = Config.SystemUserDictionary().value.items.first { $0.id == issue.rowID }?.word ?? ""
        return String(format: UserDictionaryMessages.text("systemIssueFormat"), word, field, reason)
    }

    private var dictionaryWindow: NSWindow? {
        (NSApplication.shared.delegate as? AppDelegate)?.userDictionaryEditorWindow
    }

    private func isDictionaryWindow(_ object: Any?) -> Bool {
        guard let window = object as? NSWindow, let dictionaryWindow else {
            return false
        }
        return window === dictionaryWindow
    }
}
