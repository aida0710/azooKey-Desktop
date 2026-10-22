#include "shortcut.h"

#include <cwctype>

#include "../shared/text_encoding.h"

namespace azookey::settings {

std::optional<Shortcut> ShortcutFromJson(const json::Value& value) {
    if (value.kind() != json::Value::Kind::Object || value["key"].AsString().empty()) return std::nullopt;
    return Shortcut{text::Utf8ToUtf16(value["key"].AsString()), static_cast<int>(value["modifiers"].AsInteger())};
}

json::Value ShortcutToJson(const Shortcut& shortcut) {
    return json::Value::MakeObject({
        {"key", json::Value::MakeString(text::Utf16ToUtf8(shortcut.key))},
        {"modifiers", json::Value::MakeNumber(shortcut.modifiers)},
    });
}

std::wstring ShortcutText(const Shortcut& shortcut) {
    std::wstring result;
    if (shortcut.modifiers & Shortcut::kControl) result += L"Ctrl+";
    if (shortcut.modifiers & Shortcut::kAlt) result += L"Alt+";
    if (shortcut.modifiers & Shortcut::kShift) result += L"Shift+";
    if (shortcut.modifiers & Shortcut::kWindows) result += L"Win+";
    for (wchar_t character : shortcut.key) result.push_back(static_cast<wchar_t>(std::towupper(character)));
    return result;
}

std::optional<Shortcut> ShortcutForKeyPress(wchar_t character, int modifiers) {
    if (character == 0 || modifiers == 0 || std::iswspace(character) || std::iswcntrl(character)) return std::nullopt;
    return Shortcut{std::wstring(1, static_cast<wchar_t>(std::towlower(character))), modifiers};
}

}  // namespace azookey::settings
