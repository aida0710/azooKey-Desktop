// Checks the text service's background request mailbox on its own, outside of
// TSF. Run: azookey-background-requests-test.exe (exit code 0 means every
// check passed).
#include <windows.h>

#include <cstdio>

#include "../src/textservice/background_requests.h"
#include "../src/textservice/module.h"

namespace {

int failures = 0;

void Check(bool condition, const char* description) {
    if (!condition) ++failures;
    std::printf("%s: %s\n", condition ? "ok" : "FAIL", description);
}

// TSF tears the text service down inside DestroyWindow of the application's
// main window, after its WM_DESTROY has already called PostQuitMessage.
void TestClosingKeepsTheApplicationsQuitMessage() {
    constexpr int kExitCode = 7;
    {
        azookey::channel::HostConnection::Options options;
        options.hostExecutable.clear();
        azookey::tsf::BackgroundRequests requests(options);
        PostQuitMessage(kExitCode);
    }
    MSG message{};
    bool quit = PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE) && message.message == WM_QUIT;
    Check(quit, "closing the text service leaves WM_QUIT for the application");
    Check(quit && message.wParam == kExitCode, "the quit message keeps the application's exit code");
}

}  // namespace

int main() {
    azookey::tsf::SetModuleInstance(GetModuleHandleW(nullptr));
    TestClosingKeepsTheApplicationsQuitMessage();
    std::printf("%d failures\n", failures);
    return failures == 0 ? 0 : 1;
}
