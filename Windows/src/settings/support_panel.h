// The support page: how to set up and recover, links to the guide and the
// issue tracker, where the settings and the learning data are kept, and Core's
// diagnostic report to copy into an issue (Linux: support_page.py).
#pragma once

#include <windows.h>

#include <functional>
#include <string>

#include "../shared/message_catalog_data.h"
#include "bridge_worker.h"
#include "command_map.h"
#include "page_view.h"

namespace azookey::settings {

class SupportPanel {
public:
    struct Context {
        messages::Language language = messages::Language::English;
        BridgeWorker* worker = nullptr;
        std::function<bool()> treeEnabled;  // the setting as the window shows it now
        std::wstring dataDirectory;
        std::wstring buildInfoPath;  // the package's build-info.txt
    };

    SupportPanel(PageView& page, CommandMap& commands, Context context);

    void SetSettingsFilePath(const std::wstring& path);
    // Asks Core for a fresh report.
    void Refresh();

    HWND reportEdit() const { return report_; }
    HWND copyButton() const { return copy_; }
    HWND notice() const { return notice_; }

private:
    HWND AddPath(PageView& page, CommandMap& commands, const std::string& labelKey, const std::wstring& path);
    // Shows a fresh report, then runs `then` with it.
    void RequestReport(std::function<void(const std::wstring& report)> then);
    void Copy();

    Context context_;
    PageView& page_;
    HWND settingsFile_ = nullptr;
    HWND report_ = nullptr;
    HWND copy_ = nullptr;
    HWND notice_ = nullptr;
};

}  // namespace azookey::settings
