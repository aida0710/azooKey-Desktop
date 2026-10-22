// azookey-ai-transform.exe: the AI instruction window for selected text.
//
//   azookey-ai-transform.exe --token <hex> --pipe <host pipe>
//
// Only the host starts it, after the text service asked for it. The selection
// and its surroundings are not on this command line; the window claims them
// from the host with the one-time token.
#include <windows.h>
#include <commctrl.h>
#include <objbase.h>
#include <shellapi.h>

#include <string>

#include "../shared/host_channel.h"
#include "../shared/text_encoding.h"
#include "../shared/ui_language.h"
#include "../ui/bridge_worker.h"
#include "../ui/top_level_window.h"
#include "ai_transform_protocol.h"
#include "ai_transform_window.h"

namespace {

using azookey::ai_transform::AITransformWindow;

// One instruction window at a time; a newer one replaces the open one, because
// Core keeps one transformation per text field and the newer one replaced it.
constexpr wchar_t kSingleInstanceMutex[] = L"Local\\azooKeyTreeAITransform";
// The open window sends Core its close request first; this bounds that wait.
constexpr DWORD kReplaceLimitMilliseconds = 10000;
// The host gives the AI converter 90 s for a request; wait a little longer for its answer.
constexpr DWORD kAIRequestTimeoutMilliseconds = 95000;
constexpr int kApplicationIcon = 1;  // azookey-ai-transform.rc

struct Arguments {
    std::string token;
    std::wstring pipe;
};

Arguments ParseArguments() {
    Arguments parsed;
    int count = 0;
    wchar_t** arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    for (int index = 1; arguments && index + 1 < count; ++index) {
        std::wstring name = arguments[index];
        if (name == L"--token") parsed.token = azookey::text::Utf16ToUtf8(arguments[index + 1]);
        if (name == L"--pipe") parsed.pipe = arguments[index + 1];
    }
    LocalFree(arguments);
    return parsed;
}

// Owns the single-instance mutex, closing the instruction window that is open
// first. False when that window did not close.
bool BecomeTheOnlyWindow(HANDLE mutex) {
    DWORD state = WaitForSingleObject(mutex, 0);
    if (state == WAIT_TIMEOUT) {
        if (HWND open = FindWindowW(AITransformWindow::kClassName, nullptr)) PostMessageW(open, WM_CLOSE, 0, 0);
        state = WaitForSingleObject(mutex, kReplaceLimitMilliseconds);
    }
    return state == WAIT_OBJECT_0 || state == WAIT_ABANDONED;
}

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    Arguments arguments = ParseArguments();
    if (arguments.token.empty() || arguments.pipe.empty()) return 64;
    HANDLE mutex = CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
    if (!mutex || !BecomeTheOnlyWindow(mutex)) return 1;

    // The host only hands out what it holds for this token, and only once.
    auto connection = azookey::ui::BridgeWorker::ConnectionOptions(arguments.pipe, L"");
    std::optional<azookey::ai_transform::HeldTransformation> held;
    {
        azookey::channel::HostConnection host(connection);
        auto line = host.Request(azookey::ai_transform::TakeRequest(arguments.token));
        auto reply = line ? azookey::json::Parse(*line) : std::nullopt;
        if (reply) held = azookey::ai_transform::ParseHeldTransformation(*reply);
    }
    if (!held) {
        ReleaseMutex(mutex);
        CloseHandle(mutex);
        return 2;
    }

    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&controls);
    HICON icon = static_cast<HICON>(LoadImageW(instance, MAKEINTRESOURCEW(kApplicationIcon), IMAGE_ICON, 0, 0,
                                               LR_DEFAULTSIZE | LR_SHARED));
    azookey::ui::TopLevelWindow::RegisterWindowClass(instance, AITransformWindow::kClassName, icon);

    AITransformWindow::Options options;
    options.language = azookey::messages::CurrentUiLanguage();
    options.held = std::move(*held);
    options.conversion = connection;
    options.ai = connection;
    options.ai.requestTimeoutMilliseconds = kAIRequestTimeoutMilliseconds;
    int exitCode = 0;
    {
        AITransformWindow window(std::move(options));
        if (!window.window()) return 1;
        window.Present();
        MSG message;
        while (GetMessageW(&message, nullptr, 0, 0) > 0) {
            if (azookey::ui::TranslateDialogKeys(&message)) continue;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        exitCode = static_cast<int>(message.wParam);
        ReleaseMutex(mutex);
        CloseHandle(mutex);
    }
    CoUninitialize();
    return exitCode;
}
