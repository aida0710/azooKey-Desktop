// What every window of the settings app shares: the monitor's DPI and fonts,
// the system's dialog colors, and moving between controls with the keyboard
// (Tab, access keys, Enter on a focused button, Escape to cancel).
#pragma once

#include <windows.h>

#include <memory>
#include <string>

#include "ui_metrics.h"

namespace azookey::ui {

class TopLevelWindow {
public:
    virtual ~TopLevelWindow();
    TopLevelWindow(const TopLevelWindow&) = delete;
    TopLevelWindow& operator=(const TopLevelWindow&) = delete;

    HWND window() const { return window_; }
    const UiMetrics& metrics() const { return *metrics_; }

    // Registers a window class whose windows are TopLevelWindow objects.
    static void RegisterWindowClass(HINSTANCE instance, const wchar_t* className, HICON icon);

protected:
    TopLevelWindow() = default;

    // Creates the window hidden, sized for the DPI of the monitor it lands on.
    // `owner` stays below this window and is not its parent.
    bool Create(const wchar_t* className, const std::wstring& title, HWND owner, SIZE clientSizeAt96Dpi);
    // Places the controls in the current client area with metrics().
    virtual void Layout() = 0;
    // Called after the DPI or the system font changed and every control got metrics().font().
    virtual void OnFontsChanged() {}
    // Escape, or the close box.
    virtual void OnCancel() { DestroyWindow(window_); }
    // Messages the subclass handles itself. Returns true after setting `result`;
    // false lets the base handle the message.
    virtual bool HandleMessage(UINT message, WPARAM wParam, LPARAM lParam, LRESULT* result);

private:
    static LRESULT CALLBACK Procedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
    LRESULT Handle(UINT message, WPARAM wParam, LPARAM lParam);
    void ReplaceMetrics(UINT dpi);

    HWND window_ = nullptr;
    std::unique_ptr<UiMetrics> metrics_;
    // The control that had focus when the window was deactivated; it gets focus back.
    HWND lastFocus_ = nullptr;
};

// Gives the keyboard navigation of TopLevelWindow to `message`; true when it was used.
// Every message loop of the app calls this before TranslateMessage.
bool TranslateDialogKeys(MSG* message);

// Runs a message loop with `owner` disabled until `finished` becomes true.
void RunModalLoop(HWND owner, const bool& finished);

}  // namespace azookey::ui
