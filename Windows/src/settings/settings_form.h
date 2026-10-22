// Builds the controls of every settings page from Core's definition and moves
// values between the controls and the settings document. Which control each
// element becomes is decided by WidgetKindFor.
#pragma once

#include <windows.h>

#include <functional>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "../shared/json.h"
#include "../shared/message_catalog_data.h"
#include "../ui/access_key_label.h"
#include "../ui/command_map.h"
#include "page_view.h"
#include "settings_schema.h"
#include "settings_widgets.h"
#include "shortcut_field.h"

namespace azookey::settings {

class SettingsForm {
public:
    // What the buttons on the pages start; the window owns that work.
    struct Actions {
        std::function<void()> editDictionary;
        std::function<void(const Action& action)> runAction;
        // Fills the page that shows the support element.
        std::function<void(PageView& page)> buildSupport;
    };

    // `schema` must outlive the form. Pages are children of `pageParent`;
    // their notifications go to `commandTarget`, which dispatches them with `commands`.
    SettingsForm(const Schema& schema, messages::Language language, HWND pageParent, HWND commandTarget,
                 ui::CommandMap& commands, Actions actions);

    size_t pageCount() const { return pages_.size(); }
    PageView& page(size_t index) { return *pages_[index]; }

    // Shows `values` (a whole settings document) in the controls.
    void Show(const json::Value& values);
    // `values` with every setting replaced by what its control shows. A number
    // that does not parse is sent as text so Core reports it as invalid.
    json::Value Collect(const json::Value& values) const;
    void SetDictionaryCount(size_t count);

    // The API key typed into the secret field; it never goes into the document.
    std::wstring ApiKeyText() const;
    void ClearApiKey();

    void Layout(const ui::UiMetrics& metrics);
    void ApplyHeadingFont(HFONT font);

    // The control that edits `settingKey`, for focus and for the screen tests.
    HWND ControlFor(std::string_view settingKey) const;
    // The text explaining why `settingKey` cannot be used here, or null.
    HWND UnavailableReasonFor(std::string_view settingKey) const;
    HWND ActionButton(std::string_view actionId) const;
    HWND SecretEdit() const { return secretEdit_; }
    HWND DictionaryButton() const { return dictionaryButton_; }

private:
    struct SettingControl {
        const SettingItem* item = nullptr;
        WidgetKind kind = WidgetKind::CheckBox;
        HWND control = nullptr;
        HWND unavailableReason = nullptr;
        std::unique_ptr<ShortcutField> shortcut;
    };

    void BuildPage(const Page& page, PageView& view);
    void AddSetting(const SettingItem& item, WidgetKind kind, PageView& view);
    void AddAction(const Action& action, PageView& view);
    void AddSecret(const Secret& secret, PageView& view);
    // A label for the control created next, so its access key moves focus there.
    void AddLabel(const std::wstring& text, const std::string& accessKey, PageView& view);
    HWND AddText(const std::wstring& text, PageView& view, int gapBefore);
    std::wstring Text(std::string_view key) const;

    const Schema& schema_;
    messages::Language language_;
    HWND commandTarget_;
    ui::CommandMap& commands_;
    Actions actions_;
    std::vector<std::unique_ptr<PageView>> pages_;
    std::vector<HWND> headings_;
    std::vector<SettingControl> settings_;
    std::vector<std::pair<std::string, HWND>> actionButtons_;
    HWND secretEdit_ = nullptr;
    HWND dictionaryButton_ = nullptr;
};

}  // namespace azookey::settings
