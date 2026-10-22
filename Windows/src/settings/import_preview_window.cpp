#include "import_preview_window.h"

#include <commctrl.h>

#include <algorithm>

#include "../ui/child_controls.h"
#include "../ui/control_accessibility.h"
#include "dictionary_text.h"
#include "list_view.h"

namespace azookey::settings {
namespace {

// Wide enough for the six columns; long comments stay readable in the details below the list.
constexpr SIZE kClientSize = {880, 520};
constexpr int kMargin = 16;
constexpr int kGap = 8;
constexpr int kDetailsHeight = 96;
constexpr int kListId = 1001;
constexpr int kDetailsId = 1002;
constexpr int kApplyId = 1003;
// source, word, reading, hint, outcome, reason
const std::vector<int> kColumnWeights = {2, 3, 3, 3, 2, 5};

}  // namespace

ImportPreviewWindow::ImportPreviewWindow(HWND owner, const ImportPreview& preview, messages::Language language)
    : preview_(preview), language_(language), owner_(owner) {
    if (!Create(kClassName, DictionaryText("import.preview", language), owner, kClientSize)) return;
    Build();
}

bool ImportPreviewWindow::Ask(HWND owner, const ImportPreview& preview, messages::Language language) {
    ImportPreviewWindow dialog(owner, preview, language);
    return dialog.RunModal();
}

bool ImportPreviewWindow::RunModal() {
    if (!window()) return false;
    ShowWindow(window(), SW_SHOW);
    SetFocus(list_);
    // The owner is enabled again before this window goes away, so activation returns to it.
    ui::RunModalLoop(owner_, finished_);
    return accepted_;
}

void ImportPreviewWindow::Build() {
    HWND window = this->window();
    std::wstring counts = DictionaryText(
        "import.counts", language_,
        {{L"additions", std::to_wstring(preview_.additions)}, {L"duplicates", std::to_wstring(preview_.duplicates)},
         {L"conflicts", std::to_wstring(preview_.conflicts)}, {L"excluded", std::to_wstring(preview_.excluded)}});
    counts_ = ui::CreateChildControl(window, WC_STATICW, counts, SS_LEFT | SS_NOPREFIX, -1);
    std::wstring notices;
    for (const auto& notice : preview_.notices) {
        if (!notices.empty()) notices += L"\n";
        notices += DictionaryText("import.notice." + notice, language_);
    }
    notices_ = ui::CreateChildControl(window, WC_STATICW, notices, SS_LEFT | SS_NOPREFIX, -1);
    help_ = ui::CreateChildControl(window, WC_STATICW, DictionaryText("import.draft_help", language_), SS_LEFT | SS_NOPREFIX, -1);
    list_ = CreateReportList(window, kListId,
                             {DictionaryText("import.source", language_), DictionaryText("word", language_),
                              DictionaryText("reading", language_), DictionaryText("hint", language_),
                              DictionaryText("import.outcome", language_), DictionaryText("import.reason", language_)});
    ui::SetAccessibleName(list_, DictionaryText("import.preview", language_));
    for (size_t index = 0; index < preview_.rows.size(); ++index) {
        const ImportRow& row = preview_.rows[index];
        std::wstring source =
            row.sourceLine ? DictionaryText("import.source_line", language_, {{L"number", std::to_wstring(*row.sourceLine)}})
                           : DictionaryText("import.source_item", language_, {{L"number", std::to_wstring(row.sourceIndex)}});
        const DictionaryEntry empty;
        const DictionaryEntry& entry = row.entry ? *row.entry : empty;
        // A list cell shows one line; the details below the list keep the line breaks.
        std::wstring reason = Reason(row);
        std::replace(reason.begin(), reason.end(), L'\n', L' ');
        AppendRow(list_,
                  {source, entry.word, entry.reading, entry.hint, DictionaryText("import.outcome." + row.outcome, language_),
                   reason},
                  static_cast<LPARAM>(index));
    }
    details_ = ui::CreateChildControl(window, WC_EDITW, L"",
                                  WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL, kDetailsId,
                                  WS_EX_CLIENTEDGE);
    ui::SetAccessibleName(details_, DictionaryText("import.selected_detail", language_));
    cancel_ = ui::CreateChildControl(window, WC_BUTTONW, DictionaryText("cancel", language_), WS_TABSTOP | BS_PUSHBUTTON, IDCANCEL);
    apply_ = ui::CreateChildControl(window, WC_BUTTONW, DictionaryText("import.apply", language_), WS_TABSTOP | BS_PUSHBUTTON,
                                kApplyId);
    EnableWindow(apply_, preview_.additions > 0);
    ui::ApplyFont(window, metrics().font());
    if (!preview_.rows.empty()) SelectRowWithData(list_, 0);
    Layout();
}

std::wstring ImportPreviewWindow::Reason(const ImportRow& row) const {
    std::wstring reason;
    for (const auto& issue : row.validationIssues) {
        if (!reason.empty()) reason += L"\n";
        reason += DictionaryText(issue.field, language_) + L"：" + ValidationReasonText(issue, language_);
    }
    if (reason.empty() && !row.problem.empty()) reason = DictionaryText("import.problem." + row.problem, language_);
    return reason;
}

void ImportPreviewWindow::ShowDetails() {
    LPARAM selected = SelectedRowData(list_);
    if (selected < 0 || static_cast<size_t>(selected) >= preview_.rows.size()) {
        SetWindowTextW(details_, L"");
        return;
    }
    const ImportRow& row = preview_.rows[static_cast<size_t>(selected)];
    const DictionaryEntry empty;
    const DictionaryEntry& entry = row.entry ? *row.entry : empty;
    std::wstring details = DictionaryText("word", language_) + L"：" + entry.word + L"\r\n" +
                           DictionaryText("reading", language_) + L"：" + entry.reading + L"\r\n" +
                           DictionaryText("hint", language_) + L"：" + entry.hint;
    if (!row.partOfSpeech.empty()) {
        details += L"\r\n" + DictionaryText("import.part_of_speech", language_) + L"：" + row.partOfSpeech;
    }
    std::wstring reason = Reason(row);
    if (!reason.empty()) details += L"\r\n" + DictionaryText("import.reason", language_) + L"：" + ui::ToEditLineBreaks(reason);
    SetWindowTextW(details_, details.c_str());
}

void ImportPreviewWindow::Layout() {
    if (!apply_) return;
    const ui::UiMetrics& metrics = this->metrics();
    RECT client{};
    GetClientRect(window(), &client);
    const int margin = metrics.Scale(kMargin);
    const int gap = metrics.Scale(kGap);
    const int width = std::max(1, static_cast<int>(client.right) - 2 * margin);
    int y = margin;
    for (HWND text : {counts_, notices_, help_}) {
        int height = metrics.WrappedTextHeight(ui::WindowText(text), width, metrics.font());
        ui::MoveControl(text, margin, y, width, height);
        if (height > 0) y += height + gap;
    }
    SIZE applySize = metrics.ButtonSize(ui::WindowText(apply_));
    SIZE cancelSize = metrics.ButtonSize(ui::WindowText(cancel_));
    int buttonTop = client.bottom - margin - applySize.cy;
    ui::MoveControl(apply_, client.right - margin - applySize.cx, buttonTop, applySize.cx, applySize.cy);
    ui::MoveControl(cancel_, client.right - margin - applySize.cx - gap - cancelSize.cx, buttonTop, cancelSize.cx, cancelSize.cy);
    int detailsHeight = metrics.Scale(kDetailsHeight);
    int detailsTop = buttonTop - gap - detailsHeight;
    ui::MoveControl(details_, margin, detailsTop, width, detailsHeight);
    ui::MoveControl(list_, margin, y, width, std::max(metrics.FieldHeight(), detailsTop - gap - y));
    ResizeColumns(list_, kColumnWeights);
}

void ImportPreviewWindow::Finish(bool accepted) {
    accepted_ = accepted;
    finished_ = true;
}

void ImportPreviewWindow::OnCancel() { Finish(false); }

bool ImportPreviewWindow::HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT* result) {
    if (message == WM_COMMAND && LOWORD(wParam) == kApplyId) {
        Finish(preview_.additions > 0);
        *result = 0;
        return true;
    }
    if (message == WM_NOTIFY) {
        const auto* header = reinterpret_cast<const NMHDR*>(lParam);
        if (header->hwndFrom == list_ && header->code == LVN_ITEMCHANGED) {
            const auto* change = reinterpret_cast<const NMLISTVIEW*>(lParam);
            if ((change->uChanged & LVIF_STATE) && ((change->uNewState ^ change->uOldState) & LVIS_SELECTED)) ShowDetails();
        }
    }
    return false;
}

}  // namespace azookey::settings
