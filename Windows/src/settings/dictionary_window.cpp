#include "dictionary_window.h"

#include <commctrl.h>

#include <algorithm>

#include "child_controls.h"
#include "control_accessibility.h"
#include "dictionary_text.h"
#include "file_replace.h"
#include "list_view.h"
#include "problem_text.h"

namespace azookey::settings {
namespace {

// The list stays usable beside a complete form for the selected entry.
constexpr SIZE kClientSize = {760, 600};
constexpr int kMargin = 16;
constexpr int kGap = 8;
constexpr int kHintHeight = 56;
constexpr int kMinimumListHeight = 96;
constexpr DWORD kTextStyle = SS_LEFT | SS_NOPREFIX;
constexpr DWORD kButtonStyle = WS_TABSTOP | BS_PUSHBUTTON;
// word, reading, hint, issues
const std::vector<int> kColumnWeights = {3, 3, 3, 4};

}  // namespace

DictionaryWindow::DictionaryWindow(Options options) : options_(std::move(options)), draft_(options_.entries) {
    if (!Create(kClassName, DictionaryText("title", options_.language), options_.owner, kClientSize)) return;
    Build();
}

std::wstring DictionaryWindow::Text(std::string_view key,
                                    std::initializer_list<std::pair<std::wstring_view, std::wstring_view>> values) const {
    return DictionaryText(key, options_.language, values);
}

HWND DictionaryWindow::AddButton(const std::string& key, std::function<void()> action) {
    return CreateChildControl(window(), WC_BUTTONW, Text(key), kButtonStyle,
                              commands_.Register([action = std::move(action)](unsigned notification) {
                                  if (notification == BN_CLICKED) action();
                              }));
}

HWND DictionaryWindow::AddFormField(const std::string& labelKey, DictionaryField field, DWORD style) {
    // The label's access key would need a letter per language; the list and Tab reach the fields.
    HWND label = CreateChildControl(window(), WC_STATICW, Text(labelKey), kTextStyle, commands_.Reserve());
    formLabels_.push_back(label);
    HWND edit = CreateChildControl(window(), WC_EDITW, L"", WS_TABSTOP | style,
                                   commands_.Register([this, field](unsigned notification) {
                                       if (notification != EN_CHANGE) return;
                                       Edit(field, field == DictionaryField::Word      ? word_
                                                   : field == DictionaryField::Reading ? reading_
                                                                                       : hint_);
                                   }),
                                   WS_EX_CLIENTEDGE);
    SetAccessibleName(edit, Text(labelKey));
    return edit;
}

void DictionaryWindow::Build() {
    HWND window = this->window();
    instructions_ = CreateChildControl(window, WC_STATICW, Text("instructions"), kTextStyle, commands_.Reserve());
    search_ = CreateChildControl(window, WC_EDITW, L"", WS_TABSTOP | ES_AUTOHSCROLL, commands_.Register([this](unsigned n) {
        if (n != EN_CHANGE || settingText_) return;
        query_ = WindowText(search_);
        RefreshRows(selectedId_);
    }), WS_EX_CLIENTEDGE);
    std::wstring searchLabel = Text("search");
    SendMessageW(search_, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(searchLabel.c_str()));
    SetAccessibleName(search_, searchLabel);
    sortReset_ = AddButton("sort_original", [this] {
        order_ = DictionaryOrder::Registration;
        RefreshRows(selectedId_);
    });
    filterCount_ = CreateChildControl(window, WC_STATICW, L"", kTextStyle, commands_.Reserve());
    list_ = CreateReportList(window, commands_.Reserve(),
                             {Text("word"), Text("reading"), Text("hint"), Text("issues")});
    SetAccessibleName(list_, Text("title"));
    add_ = AddButton("add", [this] { AddEntry(); });
    remove_ = AddButton("remove", [this] { RemoveEntry(); });
    import_ = AddButton("import.title", [this] { Import(); });
    export_ = AddButton("export.title", [this] { Export(); });
    word_ = AddFormField("word", DictionaryField::Word, ES_AUTOHSCROLL);
    reading_ = AddFormField("reading", DictionaryField::Reading, ES_AUTOHSCROLL);
    hint_ = AddFormField("hint", DictionaryField::Hint, WS_VSCROLL | ES_MULTILINE | ES_WANTRETURN | ES_AUTOVSCROLL);
    issues_ = CreateChildControl(window, WC_STATICW, L"", kTextStyle, commands_.Reserve());
    status_ = CreateChildControl(window, WC_STATICW, L"", kTextStyle, commands_.Reserve());
    MakeLiveRegion(status_);
    cancel_ = CreateChildControl(window, WC_BUTTONW, Text("cancel"), kButtonStyle, IDCANCEL);
    save_ = AddButton("save", [this] { Save(); });
    ApplyFont(window, metrics().font());
    RefreshRows(std::nullopt);
}

void DictionaryWindow::Present() {
    if (!window()) return;
    if (options_.owner) EnableWindow(options_.owner, FALSE);
    ShowWindow(window(), SW_SHOW);
    SetForegroundWindow(window());
    SetFocus(list_);
}

void DictionaryWindow::OnFontsChanged() {
    // The list view keeps its own font for rows; give it the new one.
    SendMessageW(list_, WM_SETFONT, reinterpret_cast<WPARAM>(metrics().font()), TRUE);
}

void DictionaryWindow::Layout() {
    if (!save_) return;
    const UiMetrics& metrics = this->metrics();
    RECT client{};
    GetClientRect(window(), &client);
    const int margin = metrics.Scale(kMargin);
    const int gap = metrics.Scale(kGap);
    const int width = std::max(1, static_cast<int>(client.right) - 2 * margin);
    auto wrapped = [&](HWND text) { return metrics.WrappedTextHeight(WindowText(text), width, metrics.font()); };

    // From the top: instructions, search, the filter count.
    int y = margin;
    int height = wrapped(instructions_);
    MoveControl(instructions_, margin, y, width, height);
    y += height + gap;
    SIZE sortSize = metrics.ButtonSize(WindowText(sortReset_));
    MoveControl(search_, margin, y, std::max(1, width - static_cast<int>(sortSize.cx) - gap), metrics.FieldHeight());
    MoveControl(sortReset_, margin + width - sortSize.cx, y, sortSize.cx, sortSize.cy);
    y += std::max(metrics.FieldHeight(), static_cast<int>(sortSize.cy)) + gap;
    height = wrapped(filterCount_);
    MoveControl(filterCount_, margin, y, width, height);
    const int listTop = y + height + gap;

    // From the bottom: the footer buttons, status, issues, the form and the entry buttons.
    SIZE saveSize = metrics.ButtonSize(WindowText(save_));
    SIZE cancelSize = metrics.ButtonSize(WindowText(cancel_));
    int bottom = client.bottom - margin;
    MoveControl(save_, margin + width - saveSize.cx, bottom - saveSize.cy, saveSize.cx, saveSize.cy);
    MoveControl(cancel_, margin + width - saveSize.cx - gap - cancelSize.cx, bottom - cancelSize.cy, cancelSize.cx,
                cancelSize.cy);
    bottom -= saveSize.cy + gap;
    for (HWND text : {status_, issues_}) {
        height = wrapped(text);
        MoveControl(text, margin, bottom - height, width, height);
        if (height > 0) bottom -= height + gap;
    }
    int labelWidth = 0;
    for (HWND label : formLabels_) labelWidth = std::max(labelWidth, metrics.TextWidth(WindowText(label), metrics.font()));
    const int fieldLeft = margin + labelWidth + gap;
    const int fieldWidth = std::max(1, margin + width - fieldLeft);
    const HWND fields[] = {word_, reading_, hint_};
    for (int index = 2; index >= 0; --index) {
        int fieldHeight = index == 2 ? metrics.Scale(kHintHeight) : metrics.FieldHeight();
        bottom -= fieldHeight;
        MoveControl(fields[index], fieldLeft, bottom, fieldWidth, fieldHeight);
        MoveControl(formLabels_[static_cast<size_t>(index)], margin, bottom + metrics.Scale(3), labelWidth, metrics.LineHeight());
        bottom -= gap;
    }
    int buttonsHeight = 0;
    int x = margin;
    for (HWND button : {add_, remove_, import_, export_}) {
        SIZE size = metrics.ButtonSize(WindowText(button));
        MoveControl(button, x, bottom - size.cy, size.cx, size.cy);
        x += size.cx + gap;
        buttonsHeight = std::max(buttonsHeight, static_cast<int>(size.cy));
    }
    bottom -= buttonsHeight + gap;
    MoveControl(list_, margin, listTop, width, std::max(metrics.Scale(kMinimumListHeight), bottom - listTop));
    ResizeColumns(list_, kColumnWeights);
    // A selection made while the list was smaller may have scrolled it; keep the selected row in view.
    int selectedRow = ListView_GetNextItem(list_, -1, LVNI_SELECTED);
    if (selectedRow >= 0) ListView_EnsureVisible(list_, selectedRow, FALSE);
}

std::wstring DictionaryWindow::IssuesText(const std::wstring& id, const wchar_t* separator) const {
    std::wstring text;
    for (const auto& issue : draft_.IssuesFor(id)) {
        if (!text.empty()) text += separator;
        text += ValidationReasonText(issue, options_.language);
    }
    return text;
}

void DictionaryWindow::RefreshRows(const std::optional<std::wstring>& selectId) {
    updatingRows_ = true;
    SendMessageW(list_, WM_SETREDRAW, FALSE, 0);
    ListView_DeleteAllItems(list_);
    const auto& entries = draft_.entries();
    std::optional<LPARAM> wanted;
    for (size_t index : draft_.VisibleIndices(query_, order_)) {
        const DictionaryEntry& entry = entries[index];
        AppendRow(list_, {entry.word, entry.reading, entry.hint, IssuesText(entry.id, L" / ")}, static_cast<LPARAM>(index));
        if (selectId && SameEntryId(entry.id, *selectId)) wanted = static_cast<LPARAM>(index);
    }
    // When the wanted entry is hidden by the search, the first visible one is selected instead.
    if (!wanted && ListView_GetItemCount(list_) > 0) {
        LVITEMW first{};
        first.mask = LVIF_PARAM;
        ListView_GetItem(list_, &first);
        wanted = first.lParam;
    }
    if (wanted) SelectRowWithData(list_, *wanted);
    SendMessageW(list_, WM_SETREDRAW, TRUE, 0);
    InvalidateRect(list_, nullptr, TRUE);
    updatingRows_ = false;
    SelectionChanged();
}

void DictionaryWindow::SelectionChanged() {
    if (updatingRows_) return;
    LPARAM data = SelectedRowData(list_);
    const auto& entries = draft_.entries();
    std::wstring id = data >= 0 && static_cast<size_t>(data) < entries.size() ? entries[static_cast<size_t>(data)].id : L"";
    if (id != selectedId_) {
        selectedId_ = id;
        const DictionaryEntry* entry = draft_.Find(id);
        settingText_ = true;
        SetWindowTextW(word_, entry ? entry->word.c_str() : L"");
        SetWindowTextW(reading_, entry ? entry->reading.c_str() : L"");
        SetWindowTextW(hint_, entry ? ToEditLineBreaks(entry->hint).c_str() : L"");
        settingText_ = false;
    }
    RefreshFeedback();
}

void DictionaryWindow::RefreshFeedback() {
    if (closed_) return;
    const bool editable = draft_.CanEdit();
    const bool selected = !selectedId_.empty() && draft_.Find(selectedId_);
    // Disabling the focused control drops keyboard focus; it comes back when the work is done.
    HWND focus = GetFocus();
    if (!editable && focus && IsChild(window(), focus)) focusBeforeWork_ = focus;
    EnableWindow(list_, editable);
    EnableWindow(search_, editable);
    EnableWindow(sortReset_, editable);
    EnableWindow(add_, editable);
    EnableWindow(remove_, editable && selected);
    EnableWindow(import_, editable && !draft_.needsRecovery());
    EnableWindow(export_, editable);
    for (HWND field : {word_, reading_, hint_}) EnableWindow(field, editable && selected);
    EnableWindow(save_, editable && !draft_.needsRecovery());
    EnableWindow(cancel_, editable);
    if (editable && focusBeforeWork_) {
        HWND restore = IsWindowEnabled(focusBeforeWork_) ? focusBeforeWork_ : list_;
        focusBeforeWork_ = nullptr;
        if (!GetFocus() || GetFocus() == window()) SetFocus(restore);
    }

    std::wstring count = Text("filtered_count", {{L"visible", std::to_wstring(ListView_GetItemCount(list_))},
                                                 {L"total", std::to_wstring(draft_.entries().size())}});
    if (selected && SelectedRowData(list_) < 0) count += L"\n" + Text("editing_hidden");
    SetWindowTextW(filterCount_, count.c_str());

    std::wstring issues;
    const auto& entries = draft_.entries();
    for (const auto& issue : draft_.IssuesFor(selectedId_)) {
        size_t row = 0;
        while (row < entries.size() && !SameEntryId(entries[row].id, issue.entryId)) ++row;
        if (!issues.empty()) issues += L"\n";
        issues += Text("row_issue", {{L"row", std::to_wstring(row + 1)},
                                     {L"field", Text(issue.field)},
                                     {L"reason", ValidationReasonText(issue, options_.language)}});
    }
    SetWindowTextW(issues_, issues.c_str());

    std::wstring status;
    for (const auto& line : draft_.Status()) {
        if (!status.empty()) status += L"\n";
        status += line.key.empty() ? line.text
                                   : messages::FillPlaceholders(
                                         messages::Template(line.key, options_.language, messages::Table::UserDictionary),
                                         line.arguments);
    }
    if (status != WindowText(status_)) AnnounceText(status_, status);
    Layout();
}

void DictionaryWindow::Edit(DictionaryField field, HWND edit) {
    if (settingText_ || selectedId_.empty() || !draft_.CanEdit()) return;
    std::wstring value = WindowText(edit);
    draft_.Update(selectedId_, field, field == DictionaryField::Hint ? FromEditLineBreaks(value) : value);
    UpdateSelectedRow();
    RefreshFeedback();
}

// Rewrites the selected row in place: refiltering while typing would move it away.
void DictionaryWindow::UpdateSelectedRow() {
    const DictionaryEntry* entry = draft_.Find(selectedId_);
    LPARAM data = SelectedRowData(list_);
    int row = ListView_GetNextItem(list_, -1, LVNI_SELECTED);
    if (!entry || data < 0 || row < 0) return;
    std::wstring texts[] = {entry->word, entry->reading, entry->hint, IssuesText(entry->id, L" / ")};
    for (int column = 0; column < 4; ++column) ListView_SetItemText(list_, row, column, texts[column].data());
}

void DictionaryWindow::ClearSearch() {
    query_.clear();
    settingText_ = true;
    SetWindowTextW(search_, L"");
    settingText_ = false;
}

void DictionaryWindow::AddEntry() {
    if (!draft_.CanEdit()) return;
    std::wstring id = draft_.Add();
    // The new, empty entry would not match a search.
    ClearSearch();
    RefreshRows(id);
    SetFocus(word_);
}

void DictionaryWindow::RemoveEntry() {
    if (!draft_.CanEdit() || selectedId_.empty()) return;
    draft_.Remove(selectedId_);
    selectedId_.clear();
    RefreshRows(std::nullopt);
}

void DictionaryWindow::Save() {
    auto sent = draft_.BeginSave();
    if (!sent) return;
    RefreshFeedback();
    options_.worker->Send(ValidateRequest(*sent), [this, sent = *sent](const std::optional<json::Value>& reply) {
        ValidateReply validated = ParseValidateReply(reply);
        if (!validated.answered || !validated.issues.empty()) {
            DictionarySaveReply failed;
            failed.failureStage = validated.answered ? "" : "validation";
            failed.issues = std::move(validated.issues);
            FinishSave(sent, failed);
            return;
        }
        options_.worker->Send(DictionarySaveRequest(sent, options_.stamp),
                              [this, sent](const std::optional<json::Value>& saveReply) {
                                  FinishSave(sent, ParseDictionarySaveReply(saveReply));
                              });
    });
}

void DictionaryWindow::FinishSave(const std::vector<DictionaryEntry>& sent, const DictionarySaveReply& reply) {
    draft_.FinishSave(sent, reply.issues, reply.saved ? "" : reply.failureStage);
    if (reply.saved) {
        if (options_.onSaved) options_.onSaved(reply.settings);
        Close();
        return;
    }
    // Core described why the settings file refused the save (it changed, it is damaged, ...).
    if (reply.settings.error) draft_.SetSaveProblem(ProblemText(*reply.settings.error, options_.language, nullptr));
    std::optional<std::wstring> firstIssue;
    if (!reply.issues.empty()) {
        firstIssue = reply.issues.front().entryId;
        ClearSearch();
    }
    RefreshRows(firstIssue ? firstIssue : std::optional<std::wstring>(selectedId_));
}

void DictionaryWindow::Import() {
    if (!draft_.CanEdit() || draft_.needsRecovery()) return;
    auto selection = options_.dialogs->ChooseImportFile(window());
    if (!selection) return;
    auto sent = draft_.BeginFileOperation(FileOperation::Import);
    if (!sent) return;
    RefreshFeedback();
    options_.worker->Send(ImportPreviewRequest(selection->path, selection->format, selection->encoding, *sent),
                          [this, sent = *sent](const std::optional<json::Value>& reply) {
                              FinishImport(sent, ParseImportReply(reply, sent));
                          });
}

void DictionaryWindow::FinishImport(const std::vector<DictionaryEntry>& sent, const ImportReply& reply) {
    if (!reply.preview) {
        draft_.FailFileOperation(reply.failure);
        RefreshFeedback();
        return;
    }
    draft_.ReceiveImportPreview(sent, *reply.preview);
    std::optional<std::wstring> firstAdded;
    if (draft_.importPreview()) {
        RefreshFeedback();
        if (options_.dialogs->ConfirmImport(window(), *draft_.importPreview())) {
            firstAdded = draft_.ApplyImport();
        } else {
            draft_.CancelImport();
        }
    }
    if (firstAdded) ClearSearch();
    RefreshRows(firstAdded ? firstAdded : std::optional<std::wstring>(selectedId_));
}

void DictionaryWindow::Export() {
    if (!draft_.CanEdit()) return;
    auto path = options_.dialogs->ChooseExportFile(window());
    if (!path) return;
    auto sent = draft_.BeginFileOperation(FileOperation::Export);
    if (!sent) return;
    RefreshFeedback();
    options_.worker->Send(ExportRequest(*sent), [this, path = *path](const std::optional<json::Value>& reply) {
        ExportReply exported = ParseExportReply(reply);
        if (exported.failure.empty() && WriteFileReplacing(path, exported.document)) {
            draft_.FinishExport();
        } else {
            draft_.FailFileOperation(exported.failure.empty() ? "exportFailed" : exported.failure);
        }
        RefreshFeedback();
    });
}

void DictionaryWindow::OnCancel() {
    // A running save or file operation finishes first; its result belongs in this window.
    if (!draft_.CanEdit()) return;
    Close();
}

void DictionaryWindow::Close() {
    if (closed_) return;
    closed_ = true;
    if (options_.owner) {
        EnableWindow(options_.owner, TRUE);
        SetActiveWindow(options_.owner);
    }
    DestroyWindow(window());
    if (options_.onClosed) options_.onClosed();
}

bool DictionaryWindow::HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT* result) {
    switch (message) {
    case WM_COMMAND:
        if (LOWORD(wParam) != IDCANCEL && LOWORD(wParam) != IDOK &&
            commands_.Dispatch(LOWORD(wParam), HIWORD(wParam))) {
            *result = 0;
            return true;
        }
        return false;
    case WM_NOTIFY: {
        const auto* header = reinterpret_cast<const NMHDR*>(lParam);
        if (header->hwndFrom != list_) return false;
        if (header->code == LVN_ITEMCHANGED) {
            const auto* change = reinterpret_cast<const NMLISTVIEW*>(lParam);
            if ((change->uChanged & LVIF_STATE) && ((change->uNewState ^ change->uOldState) & LVIS_SELECTED)) {
                SelectionChanged();
            }
        } else if (header->code == LVN_COLUMNCLICK) {
            const DictionaryOrder orders[] = {DictionaryOrder::Word, DictionaryOrder::Reading, DictionaryOrder::Hint};
            int column = reinterpret_cast<const NMLISTVIEW*>(lParam)->iSubItem;
            if (column >= 0 && column < 3) {
                order_ = orders[column];
                RefreshRows(selectedId_);
            }
        }
        *result = 0;
        return true;
    }
    default:
        return false;
    }
}

}  // namespace azookey::settings
