// azookey-settings.exe: the settings window of azooKey Tree for Windows.
//
//   azookey-settings.exe [--page <id>]
//
// --page opens a page of Core's definition (input, conversion, dictionary, ai,
// support). A second start brings the open window to the front instead.
#include <windows.h>
#include <commctrl.h>
#include <objbase.h>
#include <shellapi.h>

#include <string>

#include "../shared/api_key_credential.h"
#include "../shared/data_directory.h"
#include "../shared/text_encoding.h"
#include "../shared/ui_language.h"
#include "settings_window.h"
#include "system_dialogs.h"
#include "top_level_window.h"
#include "window_classes.h"

namespace {

using namespace azookey::settings;

constexpr wchar_t kSingleInstanceMutex[] = L"Local\\azooKeyTreeSettings";
// Set once the first start's window exists, so a second start can hand over its page.
constexpr wchar_t kWindowReadyEvent[] = L"Local\\azooKeyTreeSettingsWindowReady";
// A first start that has not made its window by then has failed to start.
constexpr DWORD kHandOverLimitMilliseconds = 15000;
constexpr int kApplicationIcon = 1;  // azookey-settings.rc

std::wstring ModuleDirectory() {
    wchar_t path[MAX_PATH];
    DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring directory(path, length);
    return directory.substr(0, directory.find_last_of(L'\\'));
}

std::string RequestedPage() {
    int count = 0;
    wchar_t** arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    std::string page;
    for (int index = 1; arguments && index + 1 < count; ++index) {
        if (std::wstring(arguments[index]) == L"--page") page = azookey::text::Utf16ToUtf8(arguments[index + 1]);
    }
    LocalFree(arguments);
    return page;
}

// Gives the page to the window that is already open and brings it forward.
void ShowInOpenWindow(const std::string& page) {
    // The first start may still be creating its window.
    HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, kWindowReadyEvent);
    if (ready) {
        WaitForSingleObject(ready, kHandOverLimitMilliseconds);
        CloseHandle(ready);
    }
    HWND existing = FindWindowW(SettingsWindow::kClassName, nullptr);
    if (!existing) return;
    DWORD process = 0;
    GetWindowThreadProcessId(existing, &process);
    // This process was just started by the user, so it may hand the foreground on.
    AllowSetForegroundWindow(process);
    COPYDATASTRUCT data{SettingsWindow::kShowPageData, static_cast<DWORD>(page.size()), const_cast<char*>(page.data())};
    SendMessageW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data));
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    std::string page = RequestedPage();
    HANDLE instanceMutex = CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        ShowInOpenWindow(page);
        if (instanceMutex) CloseHandle(instanceMutex);
        return 0;
    }
    // The file dialogs and the accessibility annotations need a single-threaded apartment.
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    INITCOMMONCONTROLSEX controls{sizeof(controls),
                                  ICC_STANDARD_CLASSES | ICC_LISTVIEW_CLASSES | ICC_UPDOWN_CLASS | ICC_LINK_CLASS};
    InitCommonControlsEx(&controls);
    HICON icon = static_cast<HICON>(LoadImageW(instance, MAKEINTRESOURCEW(kApplicationIcon), IMAGE_ICON, 0, 0,
                                               LR_DEFAULTSIZE | LR_SHARED));
    RegisterWindowClasses(instance, icon);

    auto language = azookey::messages::CurrentUiLanguage();
    SystemDialogs dialogs(language);
    SettingsWindow::Options options;
    options.language = language;
    options.connection = BridgeWorker::ConnectionOptions(azookey::channel::HostPipeName(),
                                                         ModuleDirectory() + L"\\azookey-windows-host.exe");
    options.dialogs = &dialogs;
    options.apiKeyCredential = azookey::credentials::kApiKeyTarget;
    options.dataDirectory = azookey::storage::DefaultDataDirectory();
    options.buildInfoPath = ModuleDirectory() + L"\\build-info.txt";
    options.initialPage = page;
    int exitCode = 0;
    {
        SettingsWindow window(options);
        if (!window.window()) return 1;
        window.Present();
        HANDLE ready = CreateEventW(nullptr, TRUE, FALSE, kWindowReadyEvent);
        if (ready) SetEvent(ready);
        MSG message;
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
            if (TranslateDialogKeys(&message)) continue;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        exitCode = static_cast<int>(message.wParam);
        // The window is closed. Let the next start open its own window at once,
        // even while this process still waits for a request it sent.
        if (ready) {
            ResetEvent(ready);
            CloseHandle(ready);
        }
        if (instanceMutex) {
            ReleaseMutex(instanceMutex);
            CloseHandle(instanceMutex);
        }
    }
    CoUninitialize();
    return exitCode;
}
