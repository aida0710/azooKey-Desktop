#include "access_key_label.h"

namespace azookey::ui {

std::wstring EscapeAccessKeyMarkers(const std::wstring& label) {
    std::wstring escaped;
    escaped.reserve(label.size());
    for (wchar_t character : label) {
        if (character == L'&') escaped.push_back(L'&');
        escaped.push_back(character);
    }
    return escaped;
}

std::wstring LabelWithAccessKey(const std::wstring& label, const std::string& accessKey) {
    std::wstring escaped = EscapeAccessKeyMarkers(label);
    if (accessKey.empty()) return escaped;
    return escaped + L" (&" + std::wstring(accessKey.begin(), accessKey.end()) + L")";
}

}  // namespace azookey::ui
