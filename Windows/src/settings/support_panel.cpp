#include "support_panel.h"

#include <commctrl.h>
#include <shellapi.h>

#include <cstring>
#include <utility>

#include "../shared/text_encoding.h"
#include "child_controls.h"
#include "control_accessibility.h"
#include "support_environment.h"

namespace azookey::settings {
namespace {

// The fork's pages, as on the Linux support page.
constexpr wchar_t kGuideUrl[] = L"https://github.com/aida0710/azooKey-Desktop/blob/main/docs/windows.md";
constexpr wchar_t kReleasesUrl[] = L"https://github.com/aida0710/azooKey-Desktop/releases";
constexpr wchar_t kIssuesUrl[] = L"https://github.com/aida0710/azooKey-Desktop/issues/new";
constexpr wchar_t kUpstreamUrl[] = L"https://github.com/azooKey/azooKey-Desktop";

constexpr int kSectionGap = 14;
constexpr int kLabelGap = 4;
constexpr DWORD kTextStyle = SS_LEFT | SS_NOPREFIX;

bool CopyToClipboard(HWND owner, const std::wstring& text) {
    if (!OpenClipboard(owner)) return false;
    EmptyClipboard();
    size_t bytes = (text.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    bool copied = false;
    if (memory) {
        std::memcpy(GlobalLock(memory), text.c_str(), bytes);
        GlobalUnlock(memory);
        copied = SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
        if (!copied) GlobalFree(memory);
    }
    CloseClipboard();
    return copied;
}

// SysLink markup: the label is plain text inside the anchor.
std::wstring LinkMarkup(const std::wstring& label, const wchar_t* url) {
    std::wstring escaped;
    for (wchar_t character : label) {
        if (character == L'<') escaped += L"&lt;";
        else if (character == L'>') escaped += L"&gt;";
        else if (character == L'&') escaped += L"&amp;";
        else escaped.push_back(character);
    }
    return L"<a href=\"" + std::wstring(url) + L"\">" + escaped + L"</a>";
}

}  // namespace

SupportPanel::SupportPanel(PageView& page, CommandMap& commands, Context context)
    : context_(std::move(context)), page_(page) {
    auto text = [this](const char* key) { return messages::Text(key, context_.language); };
    auto addText = [&](const std::wstring& value, int gap) {
        HWND control = page.AddControl(WC_STATICW, value, kTextStyle, commands.Reserve());
        page.AddRow({{control}, RowSizing::WrappedText, gap});
        return control;
    };
    addText(text("support.setup.windows"), kSectionGap);
    addText(text("support.recovery"), kSectionGap);
    const std::pair<const char*, const wchar_t*> links[] = {
        {"support.guide", kGuideUrl}, {"support.releases", kReleasesUrl},
        {"support.issues", kIssuesUrl}, {"support.upstream", kUpstreamUrl}};
    bool firstLink = true;
    for (const auto& [key, url] : links) {
        int id = commands.Register([url](unsigned notification) {
            if (notification == NM_CLICK || notification == NM_RETURN) {
                ShellExecuteW(nullptr, L"open", url, nullptr, nullptr, SW_SHOWNORMAL);
            }
        });
        HWND link = page.AddControl(WC_LINK, LinkMarkup(text(key), url), WS_TABSTOP, id);
        page.AddRow({{link}, RowSizing::Link, firstLink ? kSectionGap : kLabelGap});
        firstLink = false;
    }
    settingsFile_ = AddPath(page, commands, "support.settings_file", L"");
    AddPath(page, commands, "support.data_directory", context_.dataDirectory);
    HWND reportLabel = page.AddControl(WC_STATICW, text("support.title"), kTextStyle, commands.Reserve());
    page.AddRow({{reportLabel}, RowSizing::WrappedText, kSectionGap});
    report_ = page.AddControl(WC_EDITW, L"", WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
                              commands.Reserve(), WS_EX_CLIENTEDGE);
    SetAccessibleName(report_, text("support.title"));
    page.AddRow({{report_}, RowSizing::MultiLineField, kLabelGap});
    addText(text("support.privacy"), kLabelGap);
    HWND refresh = page.AddControl(WC_BUTTONW, text("support.refresh"), WS_TABSTOP | BS_PUSHBUTTON | BS_NOTIFY,
                                   commands.Register([this](unsigned notification) {
                                       if (notification == BN_CLICKED) Refresh();
                                   }));
    copy_ = page.AddControl(WC_BUTTONW, text("support.copy"), WS_TABSTOP | BS_PUSHBUTTON | BS_NOTIFY,
                            commands.Register([this](unsigned notification) {
                                if (notification == BN_CLICKED) Copy();
                            }));
    page.AddRow({{refresh, copy_}, RowSizing::Buttons, kSectionGap});
    notice_ = page.AddControl(WC_STATICW, L"", kTextStyle, commands.Reserve());
    MakeLiveRegion(notice_);
    page.AddRow({{notice_}, RowSizing::WrappedText, kLabelGap});
}

HWND SupportPanel::AddPath(PageView& page, CommandMap& commands, const std::string& labelKey, const std::wstring& path) {
    std::wstring label = messages::Text(labelKey, context_.language);
    HWND caption = page.AddControl(WC_STATICW, label, kTextStyle, commands.Reserve());
    page.AddRow({{caption}, RowSizing::WrappedText, kSectionGap});
    // A read-only edit lets the path be selected and copied.
    HWND field = page.AddControl(WC_EDITW, path, WS_TABSTOP | ES_AUTOHSCROLL | ES_READONLY, commands.Reserve(),
                                 WS_EX_CLIENTEDGE);
    SetAccessibleName(field, label);
    page.AddRow({{field}, RowSizing::Field, kLabelGap});
    return field;
}

void SupportPanel::SetSettingsFilePath(const std::wstring& path) { SetWindowTextW(settingsFile_, path.c_str()); }

void SupportPanel::Refresh() {
    RequestReport([this](const std::wstring& report) {
        if (!report.empty()) SetWindowTextW(notice_, L"");
        page_.Relayout();
    });
}

void SupportPanel::Copy() {
    RequestReport([this](const std::wstring& report) {
        if (!report.empty()) {
            bool copied = CopyToClipboard(GetParent(report_), report);
            AnnounceText(notice_, copied ? messages::Text("support.copied", context_.language) : L"");
        }
        page_.Relayout();
    });
}

void SupportPanel::RequestReport(std::function<void(const std::wstring& report)> then) {
    bool treeEnabled = context_.treeEnabled ? context_.treeEnabled() : true;
    context_.worker->Send(SupportDiagnosticsRequest(treeEnabled, context_.buildInfoPath, context_.language),
                          [this, then = std::move(then)](const std::optional<json::Value>& reply) {
                              std::wstring report;
                              if (reply) report = text::Utf8ToUtf16((*reply)["supportDiagnostics"].AsString());
                              if (report.empty()) {
                                  AnnounceText(notice_, messages::Text(reply ? "settings.request_failed"
                                                                             : "settings.host_unavailable",
                                                                       context_.language));
                              }
                              SetWindowTextW(report_, ToEditLineBreaks(report).c_str());
                              then(report);
                          });
}

}  // namespace azookey::settings
