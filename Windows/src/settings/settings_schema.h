// The settings screen's definition from Core (operation settings-schema):
// which settings exist, how each one is edited and how the pages order them.
// Labels and explanations are message keys of the shared catalog.
#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "../shared/json.h"

namespace azookey::settings {

// How Core says a setting is edited (DesktopSettingItem.Control).
enum class Control { Toggle, Choice, Integer, Text, MultilineText, Shortcut, Dictionary };

struct Choice {
    // Sent back unchanged: some choices are strings, punctuation choices are integers.
    json::Value value;
    std::string labelKey;
};

struct SettingItem {
    std::string key;
    Control control = Control::Toggle;
    std::string labelKey;
    std::string descriptionKey;  // empty when the setting has no explanation
    std::string accessKey;       // a letter for the label's keyboard access key, or empty
    std::vector<Choice> choices;
    std::optional<int64_t> minimum;
    std::optional<int64_t> maximum;
    bool available = true;
    std::string unavailableReasonKey;
};

// A button that starts work outside the settings document.
struct Action {
    std::string id;
    std::string labelKey;
    bool available = true;
    std::string unavailableReasonKey;
};

// A value kept in the platform's credential store, never in the settings file.
struct Secret {
    std::string id;
    std::string labelKey;
    std::string placeholderKey;
    std::string descriptionKey;
    std::string accessKey;
};

enum class ElementKind { Setting, Note, Action, Secret, Support };

struct PageElement {
    ElementKind kind = ElementKind::Note;
    std::string settingKey;  // kind == Setting
    std::string textKey;     // kind == Note
    Action action;           // kind == Action
    Secret secret;           // kind == Secret
};

struct Page {
    std::string id;
    std::string titleKey;
    std::vector<PageElement> elements;
};

struct Schema {
    std::string platform;
    std::vector<SettingItem> items;
    std::vector<Page> pages;

    const SettingItem* FindItem(std::string_view key) const;
    std::optional<size_t> PageIndex(std::string_view id) const;
};

// Reads settingsResult.schema of a settings-schema reply. Returns nullopt when
// the reply holds no schema, or names a control, an element or a setting this
// screen does not know: Core and this screen ship together, so a mismatch is a
// defect to fix, not something to show partially.
std::optional<Schema> ParseSchema(const json::Value& reply);

}  // namespace azookey::settings
