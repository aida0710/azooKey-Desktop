#include "settings_schema.h"

#include <utility>

namespace azookey::settings {
namespace {

std::optional<Control> ParseControl(const std::string& name) {
    if (name == "toggle") return Control::Toggle;
    if (name == "choice") return Control::Choice;
    if (name == "integer") return Control::Integer;
    if (name == "text") return Control::Text;
    if (name == "multilineText") return Control::MultilineText;
    if (name == "shortcut") return Control::Shortcut;
    if (name == "dictionary") return Control::Dictionary;
    return std::nullopt;
}

std::optional<int64_t> OptionalInteger(const json::Value& value) {
    if (value.kind() != json::Value::Kind::Number) return std::nullopt;
    return value.AsInteger();
}

std::optional<SettingItem> ParseItem(const json::Value& document) {
    SettingItem item;
    item.key = document["key"].AsString();
    auto control = ParseControl(document["control"].AsString());
    if (item.key.empty() || !control) return std::nullopt;
    item.control = *control;
    item.labelKey = document["labelKey"].AsString();
    item.descriptionKey = document["descriptionKey"].AsString();
    item.accessKey = document["accessKey"].AsString();
    for (const auto& choice : document["choices"].AsArray()) {
        item.choices.push_back({choice["value"], choice["labelKey"].AsString()});
    }
    if (item.control == Control::Choice && item.choices.empty()) return std::nullopt;
    item.minimum = OptionalInteger(document["minimum"]);
    item.maximum = OptionalInteger(document["maximum"]);
    item.available = document["available"].AsBoolean(true);
    item.unavailableReasonKey = document["unavailableReasonKey"].AsString();
    return item;
}

Action ParseAction(const json::Value& document) {
    return {document["id"].AsString(), document["labelKey"].AsString(), document["available"].AsBoolean(true),
            document["unavailableReasonKey"].AsString()};
}

Secret ParseSecret(const json::Value& document) {
    return {document["id"].AsString(), document["labelKey"].AsString(), document["placeholderKey"].AsString(),
            document["descriptionKey"].AsString(), document["accessKey"].AsString()};
}

std::optional<PageElement> ParseElement(const json::Value& document, const Schema& schema) {
    const std::string& kind = document["kind"].AsString();
    PageElement element;
    if (kind == "setting") {
        element.kind = ElementKind::Setting;
        element.settingKey = document["key"].AsString();
        if (!schema.FindItem(element.settingKey)) return std::nullopt;
    } else if (kind == "note") {
        element.kind = ElementKind::Note;
        element.textKey = document["textKey"].AsString();
    } else if (kind == "action") {
        element.kind = ElementKind::Action;
        element.action = ParseAction(document["action"]);
        if (element.action.id.empty()) return std::nullopt;
    } else if (kind == "secret") {
        element.kind = ElementKind::Secret;
        element.secret = ParseSecret(document["secret"]);
        if (element.secret.id.empty()) return std::nullopt;
    } else if (kind == "support") {
        element.kind = ElementKind::Support;
    } else {
        return std::nullopt;
    }
    return element;
}

}  // namespace

const SettingItem* Schema::FindItem(std::string_view key) const {
    for (const auto& item : items) {
        if (item.key == key) return &item;
    }
    return nullptr;
}

std::optional<size_t> Schema::PageIndex(std::string_view id) const {
    for (size_t index = 0; index < pages.size(); ++index) {
        if (pages[index].id == id) return index;
    }
    return std::nullopt;
}

std::optional<Schema> ParseSchema(const json::Value& reply) {
    const json::Value& document = reply["settingsResult"]["schema"];
    if (document.kind() != json::Value::Kind::Object) return std::nullopt;
    Schema schema;
    schema.platform = document["platform"].AsString();
    for (const auto& itemDocument : document["items"].AsArray()) {
        auto item = ParseItem(itemDocument);
        if (!item) return std::nullopt;
        schema.items.push_back(std::move(*item));
    }
    for (const auto& pageDocument : document["pages"].AsArray()) {
        Page page{pageDocument["id"].AsString(), pageDocument["titleKey"].AsString(), {}};
        if (page.id.empty()) return std::nullopt;
        for (const auto& elementDocument : pageDocument["elements"].AsArray()) {
            auto element = ParseElement(elementDocument, schema);
            if (!element) return std::nullopt;
            page.elements.push_back(std::move(*element));
        }
        schema.pages.push_back(std::move(page));
    }
    if (schema.pages.empty()) return std::nullopt;
    return schema;
}

}  // namespace azookey::settings
