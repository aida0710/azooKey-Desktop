// Labels with a keyboard access key: "Label (&S)", as Windows shows one for a
// language without letters to underline. Ampersands in the label stay literal.
#pragma once

#include <string>

namespace azookey::ui {

std::wstring LabelWithAccessKey(const std::wstring& label, const std::string& accessKey);
// A label shown by a control that treats "&" as an access key marker, without one.
std::wstring EscapeAccessKeyMarkers(const std::wstring& label);

}  // namespace azookey::ui
