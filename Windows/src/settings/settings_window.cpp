#include "settings_window.h"

#include <commctrl.h>

#include <algorithm>

#include "../shared/api_key_credential.h"
#include "child_controls.h"
#include "control_accessibility.h"
#include "dictionary_protocol.h"
#include "problem_text.h"

namespace azookey::settings {
namespace {

constexpr UINT kRepliesReadyMessage = WM_APP + 1;
constexpr UINT kDictionaryClosedMessage = WM_APP + 2;
// Room for the pages beside a list of page titles.
constexpr SIZE kClientSize = {820, 640};
constexpr int kMargin = 16;
constexpr int kGap = 8;
constexpr int kPageListWidth = 176;
constexpr DWORD kButtonStyle = WS_TABSTOP | BS_PUSHBUTTON;
constexpr char kSupportPage[] = "support";
constexpr char kResetLearningAction[] = "resetLearning";

}  // namespace

SettingsWindow::SettingsWindow(Options options) : options_(std::move(options)) {
    if (!Create(kClassName, Text("settings.window_title"), nullptr, kClientSize)) return;
    Build();
    worker_ = std::make_unique<BridgeWorker>(BridgeWorker::Options{options_.connection, window(), kRepliesReadyMessage});
    LoadDefinition();
}

SettingsWindow::~SettingsWindow() {
    // The editor sends through the worker, and the panels hold the worker too.
    dictionary_.reset();
    support_.reset();
    form_.reset();
    worker_.reset();
}

std::wstring SettingsWindow::Text(std::string_view key) const { return messages::Text(key, options_.language); }

void SettingsWindow::Build() {
    HWND window = this->window();
    noticeTitle_ = CreateChildControl(window, WC_STATICW, Text("settings.recovery_title"), SS_LEFT | SS_NOPREFIX,
                                      commands_.Reserve());
    noticeText_ = CreateChildControl(window, WC_STATICW, L"", SS_LEFT | SS_NOPREFIX, commands_.Reserve());
    recover_ = CreateChildControl(window, WC_BUTTONW, Text("settings.restore_current"), kButtonStyle,
                                  commands_.Register([this](unsigned notification) {
                                      if (notification == BN_CLICKED) Recover(false);
                                  }));
    recoverDefaults_ = CreateChildControl(window, WC_BUTTONW, Text("settings.restore_defaults"), kButtonStyle,
                                          commands_.Register([this](unsigned notification) {
                                              if (notification == BN_CLICKED) Recover(true);
                                          }));
    pageList_ = CreateChildControl(window, WC_LISTBOXW, L"", WS_TABSTOP | WS_VSCROLL | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT,
                                   commands_.Register([this](unsigned notification) {
                                       if (notification != LBN_SELCHANGE) return;
                                       LRESULT selected = SendMessageW(pageList_, LB_GETCURSEL, 0, 0);
                                       if (selected >= 0) ShowPage(static_cast<size_t>(selected));
                                   }),
                                   WS_EX_CLIENTEDGE);
    SetAccessibleName(pageList_, Text("settings.pages"));
    status_ = CreateChildControl(window, WC_STATICW, L"", SS_LEFT | SS_NOPREFIX, commands_.Reserve());
    MakeLiveRegion(status_);
    save_ = CreateChildControl(window, WC_BUTTONW, Text("settings.save"), kButtonStyle,
                               commands_.Register([this](unsigned notification) {
                                   if (notification == BN_CLICKED) Save();
                               }));
    cancel_ = CreateChildControl(window, WC_BUTTONW, Text("settings.cancel"), kButtonStyle, IDCANCEL);
    EnableWindow(save_, FALSE);
    ApplyFont(window, metrics().font());
    OnFontsChanged();
    ShowRecoveryNotice(std::nullopt);
}

void SettingsWindow::Present() {
    if (!window()) return;
    if (IsIconic(window())) ShowWindow(window(), SW_RESTORE);
    ShowWindow(window(), SW_SHOW);
    SetForegroundWindow(window());
    if (DictionaryWindow* open = dictionaryWindow()) {
        open->Present();
        return;
    }
    SetFocus(pageList_);
}

void SettingsWindow::LoadDefinition() {
    SetStatus(Text("settings.loading"));
    worker_->Send(SchemaRequest(), [this](const std::optional<json::Value>& reply) {
        auto schema = reply ? ParseSchema(*reply) : std::nullopt;
        if (!schema) {
            ShowFailure(ParseSettingsReply(reply));
            loaded_ = true;
            return;
        }
        schema_ = std::move(schema);
        worker_->Send(LoadRequest(), [this](const std::optional<json::Value>& loadReply) {
            ApplyLoad(ParseSettingsReply(loadReply), true);
        });
    });
}

void SettingsWindow::ApplyLoad(const SettingsReply& loaded, bool first) {
    if (!loaded.succeeded() || !loaded.file) {
        ShowFailure(loaded);
        loaded_ = true;
        return;
    }
    values_ = *loaded.values;
    stamp_ = loaded.file->stamp;
    settingsFilePath_ = loaded.file->path;
    if (!form_) BuildForm();
    form_->Show(values_);
    if (support_) support_->SetSettingsFilePath(settingsFilePath_);
    ShowRecoveryNotice(loaded.file->problem);
    if (first) {
        std::string page = options_.initialPage;
        // As on Linux, a first start opens the setup guidance.
        if (page.empty() && !loaded.file->exists) page = kSupportPage;
        ShowPage(schema_->PageIndex(page).value_or(0));
        SetStatus(L"");
        EnableWindow(save_, TRUE);
        loaded_ = true;
        if (support_) support_->Refresh();
    }
    Layout();
}

void SettingsWindow::BuildForm() {
    SettingsForm::Actions actions;
    actions.editDictionary = [this] { OpenDictionary(); };
    actions.runAction = [this](const Action& action) { RunAction(action); };
    actions.buildSupport = [this](PageView& page) {
        SupportPanel::Context context;
        context.language = options_.language;
        context.worker = worker_.get();
        context.treeEnabled = [this] { return (form_ ? form_->Collect(values_) : values_)["tree"].AsBoolean(true); };
        context.dataDirectory = options_.dataDirectory;
        context.buildInfoPath = options_.buildInfoPath;
        support_ = std::make_unique<SupportPanel>(page, commands_, std::move(context));
    };
    form_ = std::make_unique<SettingsForm>(*schema_, options_.language, window(), window(), commands_, std::move(actions));
    for (size_t index = 0; index < form_->pageCount(); ++index) {
        SendMessageW(pageList_, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(Text(schema_->pages[index].titleKey).c_str()));
        // Tab goes from the page list into the page, then to Save and Cancel.
        SetWindowPos(form_->page(index).window(), pageList_, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
    ApplyFont(window(), metrics().font());
    OnFontsChanged();
}

void SettingsWindow::ShowPage(size_t index) {
    if (!form_ || index >= form_->pageCount()) return;
    for (size_t page = 0; page < form_->pageCount(); ++page) {
        ShowWindow(form_->page(page).window(), page == index ? SW_SHOW : SW_HIDE);
    }
    SendMessageW(pageList_, LB_SETCURSEL, index, 0);
    shownPage_ = index;
}

void SettingsWindow::SelectPage(std::string_view id) {
    if (!loaded_ || !schema_) {
        options_.initialPage = std::string(id);
        return;
    }
    if (auto index = schema_->PageIndex(id)) ShowPage(*index);
}

std::string SettingsWindow::currentPage() const {
    if (!schema_ || !shownPage_) return {};
    return schema_->pages[*shownPage_].id;
}

void SettingsWindow::ShowRecoveryNotice(const std::optional<Problem>& problem) {
    int show = problem ? SW_SHOW : SW_HIDE;
    for (HWND control : {noticeTitle_, noticeText_, recover_, recoverDefaults_}) ShowWindow(control, show);
    if (problem) {
        std::wstring reason = ProblemText(*problem, options_.language, schema_ ? &*schema_ : nullptr);
        std::wstring detail = messages::Text("settings.recovery_detail", options_.language,
                                             {{L"reason", reason}, {L"path", settingsFilePath_}});
        SetWindowTextW(noticeText_, detail.c_str());
        SetFocus(recover_);
    }
    Layout();
}

void SettingsWindow::SetStatus(const std::wstring& text) {
    AnnounceText(status_, text);
    Layout();
}

void SettingsWindow::ShowFailure(const SettingsReply& reply) {
    if (reply.error) {
        SetStatus(ProblemText(*reply.error, options_.language, schema_ ? &*schema_ : nullptr));
    } else if (reply.failure == "no_reply" || reply.failure == "converter_unavailable") {
        SetStatus(Text("settings.host_unavailable"));
    } else {
        SetStatus(Text("settings.request_failed"));
    }
}

void SettingsWindow::Save() {
    if (!form_ || busy()) return;
    json::Value values = form_->Collect(values_);
    EnableWindow(save_, FALSE);
    SetStatus(L"");
    worker_->Send(SaveRequest(values, stamp_), [this](const std::optional<json::Value>& reply) {
        FinishSave(ParseSettingsReply(reply));
    });
}

void SettingsWindow::FinishSave(const SettingsReply& reply) {
    EnableWindow(save_, TRUE);
    if (reply.error && reply.error->code == "changed") {
        ReloadAfterChange();
        return;
    }
    if (!reply.succeeded() || !reply.file) {
        ShowFailure(reply);
        return;
    }
    values_ = *reply.values;
    stamp_ = reply.file->stamp;
    form_->Show(values_);
    std::wstring status = Text(reply.saved && !reply.saved->lastGoodSaved ? "settings.backup_warning" : "settings.saved");
    // The key goes to Credential Manager only after the settings themselves were saved.
    std::wstring apiKey = form_->ApiKeyText();
    if (!apiKey.empty()) {
        bool stored = credentials::StoreApiKey(options_.apiKeyCredential, apiKey);
        SecureZeroMemory(apiKey.data(), apiKey.size() * sizeof(wchar_t));
        form_->ClearApiKey();
        if (!stored) status = Text("settings.api_key_failed");
    }
    SetStatus(status);
}

void SettingsWindow::ReloadAfterChange() {
    if (!options_.dialogs->ConfirmReloadChangedFile(window())) {
        SetStatus(Text("settings.changed"));
        return;
    }
    worker_->Send(LoadRequest(), [this](const std::optional<json::Value>& reply) {
        SettingsReply loaded = ParseSettingsReply(reply);
        ApplyLoad(loaded, false);
        if (loaded.succeeded()) SetStatus(Text("settings.reloaded"));
    });
}

void SettingsWindow::Recover(bool useDefaults) {
    if (busy() || !options_.dialogs->ConfirmRecovery(window())) return;
    EnableWindow(recover_, FALSE);
    EnableWindow(recoverDefaults_, FALSE);
    worker_->Send(RecoverRequest(stamp_, useDefaults), [this](const std::optional<json::Value>& reply) {
        EnableWindow(recover_, TRUE);
        EnableWindow(recoverDefaults_, TRUE);
        SettingsReply recovered = ParseSettingsReply(reply);
        if (recovered.error && recovered.error->code == "changed") {
            ReloadAfterChange();
            return;
        }
        if (!recovered.succeeded() || !recovered.file) {
            ShowFailure(recovered);
            return;
        }
        values_ = *recovered.values;
        stamp_ = recovered.file->stamp;
        form_->Show(values_);
        ShowRecoveryNotice(std::nullopt);
        SetFocus(pageList_);
        std::wstring backup = recovered.saved ? recovered.saved->recoveredPath : L"";
        SetStatus(recovered.saved && !recovered.saved->lastGoodSaved
                      ? Text("settings.backup_warning")
                      : messages::Text("settings.restored", options_.language, {{L"backup", backup}}));
    });
}

void SettingsWindow::RunAction(const Action& action) {
    // The other actions (downloading typo weights, importing a personalization
    // model) need MARISA files, which the Windows converter cannot read; Core
    // marks them unavailable here, so their buttons stay disabled.
    if (action.id == kResetLearningAction) ResetLearning();
}

void SettingsWindow::ResetLearning() {
    if (busy() || !options_.dialogs->ConfirmResetLearning(window())) return;
    worker_->Send(ResetLearningRequest(), [this](const std::optional<json::Value>& reply) {
        SetStatus(Text(ResetLearningSucceeded(reply) ? "learning.reset.completed" : "learning.reset.failed"));
    });
}

void SettingsWindow::OpenDictionary() {
    if (DictionaryWindow* open = dictionaryWindow()) {
        open->Present();
        return;
    }
    if (busy()) return;
    // The editor saves into the file it opened; read it again so it starts from the newest version.
    worker_->Send(LoadRequest(), [this](const std::optional<json::Value>& reply) {
        SettingsReply opened = ParseSettingsReply(reply);
        if (!opened.succeeded() || !opened.file) {
            ShowFailure(opened);
            return;
        }
        if (opened.file->problem) {
            SetStatus(Text("settings.recovery_required"));
            return;
        }
        if (opened.file->stamp != stamp_) {
            if (!options_.dialogs->ConfirmReloadChangedFile(window())) {
                SetStatus(Text("settings.changed"));
                return;
            }
            ApplyLoad(opened, false);
        }
        DictionaryWindow::Options editor;
        editor.owner = window();
        editor.language = options_.language;
        editor.worker = worker_.get();
        editor.dialogs = options_.dialogs;
        editor.entries = DictionaryEntriesIn(*opened.values);
        editor.stamp = opened.file->stamp;
        editor.onSaved = [this](const SettingsReply& saved) { DictionarySaved(saved); };
        editor.onClosed = [this] { PostMessageW(window(), kDictionaryClosedMessage, 0, 0); };
        dictionary_ = std::make_unique<DictionaryWindow>(std::move(editor));
        dictionary_->Present();
    });
}

void SettingsWindow::DictionarySaved(const SettingsReply& saved) {
    if (!saved.values || !saved.file) return;
    // Only the dictionary changed in the file; unsaved edits on the pages stay as they are.
    values_ = *saved.values;
    stamp_ = saved.file->stamp;
    form_->SetDictionaryCount(DictionaryEntriesIn(values_).size());
    SetStatus(Text(saved.saved && !saved.saved->lastGoodSaved ? "settings.backup_warning" : "settings.dictionary_saved"));
}

void SettingsWindow::OnFontsChanged() {
    SendMessageW(noticeTitle_, WM_SETFONT, reinterpret_cast<WPARAM>(metrics().headingFont()), FALSE);
    if (form_) {
        form_->ApplyHeadingFont(metrics().headingFont());
        // The pages keep a pointer to the metrics, which were just replaced.
        form_->Layout(metrics());
    }
}

void SettingsWindow::Layout() {
    if (!cancel_) return;
    const UiMetrics& metrics = this->metrics();
    RECT client{};
    GetClientRect(window(), &client);
    const int margin = metrics.Scale(kMargin);
    const int gap = metrics.Scale(kGap);
    const int width = std::max(1, static_cast<int>(client.right) - 2 * margin);
    int y = margin;
    // The style, not IsWindowVisible: the layout is also computed while the window is hidden.
    if (GetWindowLongW(noticeTitle_, GWL_STYLE) & WS_VISIBLE) {
        int titleHeight = metrics.WrappedTextHeight(WindowText(noticeTitle_), width, metrics.headingFont());
        MoveControl(noticeTitle_, margin, y, width, titleHeight);
        y += titleHeight + metrics.Scale(4);
        int textHeight = metrics.WrappedTextHeight(WindowText(noticeText_), width, metrics.font());
        MoveControl(noticeText_, margin, y, width, textHeight);
        y += textHeight + gap;
        int x = margin;
        int buttonHeight = 0;
        for (HWND button : {recover_, recoverDefaults_}) {
            SIZE size = metrics.ButtonSize(WindowText(button));
            MoveControl(button, x, y, size.cx, size.cy);
            x += size.cx + gap;
            buttonHeight = std::max(buttonHeight, static_cast<int>(size.cy));
        }
        y += buttonHeight + metrics.Scale(kMargin);
    }
    SIZE saveSize = metrics.ButtonSize(WindowText(save_));
    SIZE cancelSize = metrics.ButtonSize(WindowText(cancel_));
    const int buttonsWidth = saveSize.cx + gap + cancelSize.cx;
    const int statusWidth = std::max(1, width - buttonsWidth - gap);
    const int statusHeight = metrics.WrappedTextHeight(WindowText(status_), statusWidth, metrics.font());
    const int footerHeight = std::max(static_cast<int>(saveSize.cy), statusHeight);
    const int footerTop = client.bottom - margin - footerHeight;
    MoveControl(status_, margin, footerTop, statusWidth, std::max(statusHeight, 1));
    MoveControl(cancel_, margin + width - cancelSize.cx, footerTop, cancelSize.cx, cancelSize.cy);
    MoveControl(save_, margin + width - cancelSize.cx - gap - saveSize.cx, footerTop, saveSize.cx, saveSize.cy);
    const int listWidth = metrics.Scale(kPageListWidth);
    const int pagesHeight = std::max(1, footerTop - gap - y);
    MoveControl(pageList_, margin, y, listWidth, pagesHeight);
    if (form_) {
        const int pagesLeft = margin + listWidth + gap;
        for (size_t page = 0; page < form_->pageCount(); ++page) {
            MoveControl(form_->page(page).window(), pagesLeft, y, std::max(1, margin + width - pagesLeft), pagesHeight);
        }
        form_->Layout(metrics);
    }
}

void SettingsWindow::OnCancel() {
    // The dictionary editor decides itself whether its draft may be discarded.
    if (DictionaryWindow* open = dictionaryWindow()) {
        open->Present();
        return;
    }
    DestroyWindow(window());
}

bool SettingsWindow::HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT* result) {
    *result = 0;
    switch (message) {
    case kRepliesReadyMessage:
        if (worker_) worker_->DeliverReplies();
        return true;
    case kDictionaryClosedMessage:
        dictionary_.reset();
        if (form_ && form_->DictionaryButton()) SetFocus(form_->DictionaryButton());
        return true;
    case WM_COMMAND:
        return LOWORD(wParam) != IDOK && LOWORD(wParam) != IDCANCEL && commands_.Dispatch(LOWORD(wParam), HIWORD(wParam));
    case WM_NOTIFY: {
        const auto* header = reinterpret_cast<const NMHDR*>(lParam);
        return commands_.Dispatch(static_cast<int>(header->idFrom), header->code);
    }
    case WM_COPYDATA: {
        const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lParam);
        if (data->dwData != kShowPageData) return false;
        SelectPage(std::string(static_cast<const char*>(data->lpData), data->cbData));
        Present();
        *result = TRUE;
        return true;
    }
    case WM_DESTROY:
        if (options_.quitWhenClosed) PostQuitMessage(0);
        return false;
    default:
        return false;
    }
}

}  // namespace azookey::settings
