// UI Automation for a popup that only shows text and never takes focus: the
// window is a text element named by what it shows, and new text is spoken as a
// notification, since screen readers otherwise follow the focus only.
#pragma once

#include <windows.h>

#include <string>

namespace azookey::tsf {

class TextAnnouncer {
public:
    // `activity` names the kind of notification (UiaRaiseNotificationEvent).
    TextAnnouncer(HWND window, std::wstring activity);
    ~TextAnnouncer();
    TextAnnouncer(const TextAnnouncer&) = delete;
    TextAnnouncer& operator=(const TextAnnouncer&) = delete;

    // Names the element and speaks `text` when it differs from the last one.
    void Announce(const std::wstring& text);
    void Forget() { spoken_.clear(); }
    // WM_GETOBJECT; 0 when the request is not for this element.
    LRESULT HandleGetObject(WPARAM wParam, LPARAM lParam);

    class Provider;

private:
    HWND window_;
    std::wstring activity_;
    std::wstring spoken_;
    Provider* provider_;
};

}  // namespace azookey::tsf
