#include "settings_form.h"

#include <commctrl.h>

#include <cerrno>
#include <cwchar>

#include "../shared/text_encoding.h"
#include "../ui/child_controls.h"
#include "settings_protocol.h"
#include "../ui/control_accessibility.h"
#include "shortcut.h"

namespace azookey::settings {
namespace {

using json::Value;

// Gaps between rows, in 96-DPI pixels: a label sits close to its control,
// an explanation close to what it explains, and settings apart from each other.
constexpr int kSettingGap = 14;
constexpr int kLabelGap = 4;
constexpr int kExplanationGap = 2;

constexpr DWORD kTextStyle = SS_LEFT | SS_NOPREFIX;
// BS_NOTIFY makes buttons report focus, so the page can scroll them into view.
constexpr DWORD kButtonStyle = WS_TABSTOP | BS_PUSHBUTTON | BS_NOTIFY;

bool SameJson(const Value& left, const Value& right) { return json::Serialize(left) == json::Serialize(right); }

// A whole number, or nullopt for text that is not one (Core then reports the value as invalid).
std::optional<long long> ParseInteger(const std::wstring& text) {
    if (text.empty()) return std::nullopt;
    wchar_t* end = nullptr;
    errno = 0;
    long long number = std::wcstoll(text.c_str(), &end, 10);
    if (errno != 0 || end != text.c_str() + text.size()) return std::nullopt;
    return number;
}

}  // namespace

SettingsForm::SettingsForm(const Schema& schema, messages::Language language, HWND pageParent, HWND commandTarget,
                           ui::CommandMap& commands, Actions actions)
    : schema_(schema), language_(language), commandTarget_(commandTarget), commands_(commands), actions_(std::move(actions)) {
    for (const auto& page : schema_.pages) {
        pages_.push_back(std::make_unique<PageView>(pageParent, commandTarget_));
        BuildPage(page, *pages_.back());
    }
}

std::wstring SettingsForm::Text(std::string_view key) const { return messages::Text(key, language_); }

void SettingsForm::BuildPage(const Page& page, PageView& view) {
    HWND heading = view.AddControl(WC_STATICW, Text(page.titleKey), kTextStyle, commands_.Reserve());
    headings_.push_back(heading);
    view.AddRow({{heading}, RowSizing::Heading, 0});
    for (const auto& element : page.elements) {
        WidgetKind kind = WidgetKindFor(element, schema_);
        switch (element.kind) {
        case ElementKind::Setting: AddSetting(*schema_.FindItem(element.settingKey), kind, view); break;
        case ElementKind::Note: AddText(Text(element.textKey), view, kSettingGap); break;
        case ElementKind::Action: AddAction(element.action, view); break;
        case ElementKind::Secret: AddSecret(element.secret, view); break;
        case ElementKind::Support:
            if (actions_.buildSupport) actions_.buildSupport(view);
            break;
        }
    }
}

HWND SettingsForm::AddText(const std::wstring& text, PageView& view, int gapBefore) {
    HWND control = view.AddControl(WC_STATICW, text, kTextStyle, commands_.Reserve());
    view.AddRow({{control}, RowSizing::WrappedText, gapBefore});
    return control;
}

void SettingsForm::AddLabel(const std::wstring& text, const std::string& accessKey, PageView& view) {
    // Without SS_NOPREFIX the label's access key moves focus to the next control.
    HWND label = view.AddControl(WC_STATICW, ui::LabelWithAccessKey(text, accessKey), SS_LEFT, commands_.Reserve());
    view.AddRow({{label}, RowSizing::WrappedText, kSettingGap});
}

void SettingsForm::AddSetting(const SettingItem& item, WidgetKind kind, PageView& view) {
    SettingControl setting;
    setting.item = &item;
    setting.kind = kind;
    std::wstring label = Text(item.labelKey);
    std::wstring description = item.descriptionKey.empty() ? L"" : Text(item.descriptionKey);
    int gapAfterLabel = kLabelGap;
    switch (kind) {
    case WidgetKind::CheckBox:
        setting.control = view.AddControl(WC_BUTTONW, ui::LabelWithAccessKey(label, item.accessKey),
                                          WS_TABSTOP | BS_AUTOCHECKBOX | BS_MULTILINE | BS_NOTIFY, commands_.Reserve());
        view.AddRow({{setting.control}, RowSizing::CheckBox, kSettingGap});
        break;
    case WidgetKind::DropDownList: {
        AddLabel(label, item.accessKey, view);
        setting.control = view.AddControl(WC_COMBOBOXW, L"", WS_TABSTOP | WS_VSCROLL | CBS_DROPDOWNLIST, commands_.Reserve());
        for (const auto& choice : item.choices) {
            SendMessageW(setting.control, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(Text(choice.labelKey).c_str()));
        }
        view.AddRow({{setting.control}, RowSizing::DropDown, gapAfterLabel});
        break;
    }
    case WidgetKind::NumberEdit: {
        AddLabel(label, item.accessKey, view);
        setting.control = view.AddControl(WC_EDITW, L"", WS_TABSTOP | ES_AUTOHSCROLL | ES_NUMBER, commands_.Reserve(),
                                          WS_EX_CLIENTEDGE);
        // The page places the arrows beside the edit; UDS_SETBUDDYINT keeps the edit's text as the value.
        HWND arrows = view.AddControl(UPDOWN_CLASSW, L"", UDS_SETBUDDYINT | UDS_ARROWKEYS | UDS_NOTHOUSANDS,
                                      commands_.Reserve());
        SendMessageW(arrows, UDM_SETBUDDY, reinterpret_cast<WPARAM>(setting.control), 0);
        SendMessageW(arrows, UDM_SETRANGE32, static_cast<WPARAM>(item.minimum.value_or(0)),
                     static_cast<LPARAM>(item.maximum.value_or(INT32_MAX)));
        view.AddRow({{setting.control, arrows}, RowSizing::NarrowField, gapAfterLabel});
        break;
    }
    case WidgetKind::SingleLineEdit:
        AddLabel(label, item.accessKey, view);
        setting.control = view.AddControl(WC_EDITW, L"", WS_TABSTOP | ES_AUTOHSCROLL, commands_.Reserve(), WS_EX_CLIENTEDGE);
        view.AddRow({{setting.control}, RowSizing::Field, gapAfterLabel});
        break;
    case WidgetKind::MultiLineEdit:
        AddLabel(label, item.accessKey, view);
        setting.control = view.AddControl(WC_EDITW, L"",
                                          WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_WANTRETURN | ES_AUTOVSCROLL,
                                          commands_.Reserve(), WS_EX_CLIENTEDGE);
        view.AddRow({{setting.control}, RowSizing::MultiLineField, gapAfterLabel});
        break;
    case WidgetKind::ShortcutField: {
        AddLabel(label, item.accessKey, view);
        setting.control = view.AddControl(WC_EDITW, L"", WS_TABSTOP | ES_AUTOHSCROLL | ES_READONLY, commands_.Reserve(),
                                          WS_EX_CLIENTEDGE);
        setting.shortcut = std::make_unique<ShortcutField>(setting.control);
        view.AddRow({{setting.control}, RowSizing::Field, gapAfterLabel});
        std::wstring instructions = Text("settings.shortcut_instructions");
        description = description.empty() ? instructions : description + L"\n" + instructions;
        break;
    }
    case WidgetKind::DictionaryButton:
        setting.control = view.AddControl(WC_BUTTONW, L"", kButtonStyle, commands_.Register([this](unsigned notification) {
            if (notification == BN_CLICKED && actions_.editDictionary) actions_.editDictionary();
        }));
        dictionaryButton_ = setting.control;
        view.AddRow({{setting.control}, RowSizing::Buttons, kSettingGap});
        break;
    default:
        return;
    }
    // Check boxes and buttons are named by their own text.
    if (kind != WidgetKind::CheckBox && kind != WidgetKind::DictionaryButton) ui::SetAccessibleName(setting.control, label);
    std::wstring accessibleDescription = description;
    if (!description.empty()) AddText(description, view, kExplanationGap);
    if (!item.available) {
        EnableWindow(setting.control, FALSE);
        std::wstring reason = Text(item.unavailableReasonKey);
        setting.unavailableReason = AddText(reason, view, kExplanationGap);
        accessibleDescription += accessibleDescription.empty() ? reason : L"\n" + reason;
    }
    if (!accessibleDescription.empty()) ui::SetAccessibleDescription(setting.control, accessibleDescription);
    settings_.push_back(std::move(setting));
}

void SettingsForm::AddAction(const Action& action, PageView& view) {
    HWND button = view.AddControl(WC_BUTTONW, ui::EscapeAccessKeyMarkers(Text(action.labelKey)), kButtonStyle,
                                  commands_.Register([this, action](unsigned notification) {
                                      if (notification == BN_CLICKED && actions_.runAction) actions_.runAction(action);
                                  }));
    view.AddRow({{button}, RowSizing::Buttons, kSettingGap});
    actionButtons_.emplace_back(action.id, button);
    if (!action.available) {
        EnableWindow(button, FALSE);
        std::wstring reason = Text(action.unavailableReasonKey);
        AddText(reason, view, kExplanationGap);
        ui::SetAccessibleDescription(button, reason);
    }
}

void SettingsForm::AddSecret(const Secret& secret, PageView& view) {
    std::wstring label = Text(secret.labelKey);
    AddLabel(label, secret.accessKey, view);
    secretEdit_ = view.AddControl(WC_EDITW, L"", WS_TABSTOP | ES_AUTOHSCROLL | ES_PASSWORD, commands_.Reserve(),
                                  WS_EX_CLIENTEDGE);
    std::wstring placeholder = Text(secret.placeholderKey);
    SendMessageW(secretEdit_, EM_SETCUEBANNER, TRUE, reinterpret_cast<LPARAM>(placeholder.c_str()));
    view.AddRow({{secretEdit_}, RowSizing::Field, kLabelGap});
    ui::SetAccessibleName(secretEdit_, label);
    std::wstring description = Text(secret.descriptionKey);
    AddText(description, view, kExplanationGap);
    ui::SetAccessibleDescription(secretEdit_, placeholder + L"\n" + description);
}

void SettingsForm::Show(const json::Value& values) {
    for (auto& setting : settings_) {
        const Value& value = values[setting.item->key];
        switch (setting.kind) {
        case WidgetKind::CheckBox:
            SendMessageW(setting.control, BM_SETCHECK, value.AsBoolean() ? BST_CHECKED : BST_UNCHECKED, 0);
            break;
        case WidgetKind::DropDownList: {
            int selected = -1;
            for (size_t index = 0; index < setting.item->choices.size(); ++index) {
                if (SameJson(setting.item->choices[index].value, value)) selected = static_cast<int>(index);
            }
            SendMessageW(setting.control, CB_SETCURSEL, static_cast<WPARAM>(selected), 0);
            break;
        }
        case WidgetKind::NumberEdit:
            SetWindowTextW(setting.control, std::to_wstring(value.AsInteger()).c_str());
            break;
        case WidgetKind::SingleLineEdit:
        case WidgetKind::MultiLineEdit:
            SetWindowTextW(setting.control, ui::ToEditLineBreaks(text::Utf8ToUtf16(value.AsString())).c_str());
            break;
        case WidgetKind::ShortcutField:
            setting.shortcut->SetValue(ShortcutFromJson(value));
            break;
        case WidgetKind::DictionaryButton:
            SetDictionaryCount(value["items"].AsArray().size());
            break;
        default:
            break;
        }
    }
}

json::Value SettingsForm::Collect(const json::Value& values) const {
    Value collected = values;
    for (const auto& setting : settings_) {
        const std::string& key = setting.item->key;
        switch (setting.kind) {
        case WidgetKind::CheckBox:
            collected = WithValue(collected, key,
                                  Value::MakeBoolean(SendMessageW(setting.control, BM_GETCHECK, 0, 0) == BST_CHECKED));
            break;
        case WidgetKind::DropDownList: {
            LRESULT selected = SendMessageW(setting.control, CB_GETCURSEL, 0, 0);
            if (selected >= 0 && static_cast<size_t>(selected) < setting.item->choices.size()) {
                collected = WithValue(collected, key, setting.item->choices[static_cast<size_t>(selected)].value);
            }
            break;
        }
        case WidgetKind::NumberEdit: {
            std::wstring text = ui::WindowText(setting.control);
            auto number = ParseInteger(text);
            collected = WithValue(collected, key,
                                  number ? Value::MakeNumber(static_cast<double>(*number))
                                         : Value::MakeString(text::Utf16ToUtf8(text)));
            break;
        }
        case WidgetKind::SingleLineEdit:
        case WidgetKind::MultiLineEdit:
            collected = WithValue(collected, key,
                                  Value::MakeString(text::Utf16ToUtf8(ui::FromEditLineBreaks(ui::WindowText(setting.control)))));
            break;
        case WidgetKind::ShortcutField:
            if (setting.shortcut->value()) collected = WithValue(collected, key, ShortcutToJson(*setting.shortcut->value()));
            break;
        default:
            break;
        }
    }
    return collected;
}

void SettingsForm::SetDictionaryCount(size_t count) {
    if (!dictionaryButton_) return;
    for (const auto& setting : settings_) {
        if (setting.control != dictionaryButton_) continue;
        std::wstring label = messages::Text(setting.item->labelKey, language_, {{L"count", std::to_wstring(count)}});
        SetWindowTextW(dictionaryButton_, ui::EscapeAccessKeyMarkers(label).c_str());
    }
}

std::wstring SettingsForm::ApiKeyText() const { return secretEdit_ ? ui::WindowText(secretEdit_) : L""; }

void SettingsForm::ClearApiKey() {
    if (secretEdit_) SetWindowTextW(secretEdit_, L"");
}

void SettingsForm::Layout(const ui::UiMetrics& metrics) {
    for (auto& page : pages_) page->Layout(metrics);
}

void SettingsForm::ApplyHeadingFont(HFONT font) {
    for (HWND heading : headings_) SendMessageW(heading, WM_SETFONT, reinterpret_cast<WPARAM>(font), FALSE);
}

HWND SettingsForm::ControlFor(std::string_view settingKey) const {
    for (const auto& setting : settings_) {
        if (setting.item->key == settingKey) return setting.control;
    }
    return nullptr;
}

HWND SettingsForm::UnavailableReasonFor(std::string_view settingKey) const {
    for (const auto& setting : settings_) {
        if (setting.item->key == settingKey) return setting.unavailableReason;
    }
    return nullptr;
}

HWND SettingsForm::ActionButton(std::string_view actionId) const {
    for (const auto& [id, button] : actionButtons_) {
        if (id == actionId) return button;
    }
    return nullptr;
}

}  // namespace azookey::settings
