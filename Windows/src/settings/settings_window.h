// The settings window: the list of pages on the left, the selected page on
// the right, a notice above them when the settings file is damaged, and the
// status line with Save and Cancel below. It reads Core's definition and the
// settings file through the converter host, then saves with the file's stamp
// so a file changed elsewhere is never overwritten.
#pragma once

#include <windows.h>

#include <memory>
#include <optional>
#include <string>
#include <string_view>

#include "../shared/host_channel.h"
#include "../shared/json.h"
#include "../shared/message_catalog_data.h"
#include "bridge_worker.h"
#include "command_map.h"
#include "dictionary_window.h"
#include "settings_dialogs.h"
#include "settings_form.h"
#include "settings_protocol.h"
#include "settings_schema.h"
#include "support_panel.h"
#include "top_level_window.h"

namespace azookey::settings {

class SettingsWindow final : public TopLevelWindow {
public:
    static constexpr wchar_t kClassName[] = L"azooKeyTreeSettings";
    // WM_COPYDATA from a second start of the app: the page to show (UTF-8 page id).
    static constexpr ULONG_PTR kShowPageData = 0x415A4B50;

    struct Options {
        messages::Language language = messages::Language::English;
        channel::HostConnection::Options connection;
        SettingsDialogs* dialogs = nullptr;
        std::wstring apiKeyCredential;  // the credential's target name
        std::wstring dataDirectory;
        std::wstring buildInfoPath;
        std::string initialPage;  // empty: the first page, or support before the first save
        bool quitWhenClosed = true;
    };

    explicit SettingsWindow(Options options);
    ~SettingsWindow() override;

    void Present();
    void SelectPage(std::string_view id);

    // The definition and the file have been read, or reading them failed.
    bool loaded() const { return loaded_; }
    bool busy() const { return worker_ && worker_->busy(); }
    SettingsForm* form() { return form_.get(); }
    SupportPanel* support() { return support_.get(); }
    // The open dictionary editor; null once its window is closed, even before the object is released.
    DictionaryWindow* dictionaryWindow() { return dictionary_ && dictionary_->window() ? dictionary_.get() : nullptr; }
    HWND pageList() const { return pageList_; }
    HWND saveButton() const { return save_; }
    HWND statusText() const { return status_; }
    HWND recoveryNotice() const { return noticeText_; }
    HWND recoverButton() const { return recover_; }
    HWND recoverWithDefaultsButton() const { return recoverDefaults_; }
    const std::string& stamp() const { return stamp_; }
    // The page shown now, or empty.
    std::string currentPage() const;

protected:
    void Layout() override;
    void OnFontsChanged() override;
    void OnCancel() override;
    bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT* result) override;

private:
    void Build();
    void LoadDefinition();
    void ApplyLoad(const SettingsReply& loaded, bool first);
    void BuildForm();
    void ShowPage(size_t index);
    void ShowRecoveryNotice(const std::optional<Problem>& problem);
    void SetStatus(const std::wstring& text);
    void ShowFailure(const SettingsReply& reply);
    std::wstring Text(std::string_view key) const;

    void Save();
    void FinishSave(const SettingsReply& reply);
    void ReloadAfterChange();
    void Recover(bool useDefaults);
    void RunAction(const Action& action);
    void ResetLearning();
    void OpenDictionary();
    void DictionarySaved(const SettingsReply& saved);

    Options options_;
    CommandMap commands_;
    std::unique_ptr<BridgeWorker> worker_;
    std::optional<Schema> schema_;
    std::unique_ptr<SettingsForm> form_;
    std::unique_ptr<SupportPanel> support_;
    std::unique_ptr<DictionaryWindow> dictionary_;
    json::Value values_;
    std::string stamp_;
    std::wstring settingsFilePath_;
    std::optional<size_t> shownPage_;
    bool loaded_ = false;

    HWND noticeTitle_ = nullptr;
    HWND noticeText_ = nullptr;
    HWND recover_ = nullptr;
    HWND recoverDefaults_ = nullptr;
    HWND pageList_ = nullptr;
    HWND status_ = nullptr;
    HWND save_ = nullptr;
    HWND cancel_ = nullptr;
};

}  // namespace azookey::settings
