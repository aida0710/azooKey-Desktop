// Drives the AI instruction window against a stand-in host that answers
// Core's ai-transform-* operations as docs/ai-bridge-protocol.md describes,
// and checks what the window sends and shows: the instruction from the
// history, the preview round trip through "transform" without an API key,
// invalidation on edits and on the surrounding-text choice, history errors,
// a missing key, copying, applying (confirm without close) and closing.
//
//   azookey-ai-transform-window-test.exe [--screenshots <directory>]
#include <windows.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <objbase.h>

#include <atomic>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "../src/ai_transform/ai_transform_protocol.h"
#include "../src/ai_transform/ai_transform_window.h"
#include "../src/shared/host_channel.h"
#include "../src/shared/json.h"
#include "../src/shared/message_catalog_data.h"
#include "../src/shared/text_encoding.h"
#include "../src/ui/bridge_worker.h"
#include "../src/ui/child_controls.h"
#include "../src/ui/top_level_window.h"
#include "screen_capture.h"

namespace {

using azookey::ai_transform::AITransformWindow;
using azookey::json::Value;
using azookey::messages::Language;

constexpr Language kLanguage = Language::Japanese;
constexpr int kTransformation = 7;
// Bounds for a broken run; the stand-in host answers at once.
constexpr DWORD kStepLimitMilliseconds = 10000;
constexpr char kMissingKeyPrompt[] = "鍵なし";
constexpr char kBadShortcut[] = "bad";

int failures = 0;

void Check(bool condition, const std::string& description, const std::string& actual = "") {
    if (!condition) ++failures;
    std::printf("%s: %s\n", condition ? "ok" : "FAIL", description.c_str());
    if (!condition && !actual.empty()) std::printf("  actual: %s\n", actual.c_str());
    std::fflush(stdout);
}

std::string Utf8(const std::wstring& text) { return azookey::text::Utf16ToUtf8(text); }
std::wstring Message(const char* key) { return azookey::messages::Text(key, kLanguage); }

// Answers like the host and Core would, and records every request line.
class StandInHost {
public:
    explicit StandInHost(std::wstring pipe) : pipe_(std::move(pipe)), thread_([this] { Listen(); }) {}
    ~StandInHost() {
        stopping_ = true;
        // Connect once so the listener wakes up and sees it should stop.
        HANDLE wake = CreateFileW(pipe_.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING, 0, nullptr);
        if (wake != INVALID_HANDLE_VALUE) CloseHandle(wake);
        thread_.join();
    }

    std::vector<Value> requests() {
        std::lock_guard<std::mutex> lock(mutex_);
        return requests_;
    }
    void Forget() {
        std::lock_guard<std::mutex> lock(mutex_);
        requests_.clear();
    }

private:
    void Listen() {
        while (!stopping_) {
            HANDLE pipe = CreateNamedPipeW(pipe_.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
                                           PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, PIPE_UNLIMITED_INSTANCES, 65536,
                                           65536, 0, nullptr);
            if (pipe == INVALID_HANDLE_VALUE) break;
            OVERLAPPED overlapped{};
            overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
            BOOL connected = ConnectNamedPipe(pipe, &overlapped);
            DWORD transferred = 0;
            if (!connected && GetLastError() == ERROR_IO_PENDING) GetOverlappedResult(pipe, &overlapped, &transferred, TRUE);
            CloseHandle(overlapped.hEvent);
            if (stopping_) {
                CloseHandle(pipe);
                break;
            }
            clients_.emplace_back([this, pipe] { Serve(pipe); });
        }
        for (auto& client : clients_) client.join();
    }

    void Serve(HANDLE pipe) {
        azookey::channel::LineReader reader;
        while (auto line = reader.ReadLine(pipe, kStepLimitMilliseconds * 6)) {
            auto request = azookey::json::Parse(*line);
            if (!request) break;
            std::string reply;
            {
                std::lock_guard<std::mutex> lock(mutex_);
                requests_.push_back(*request);
                reply = Answer(*request);
            }
            if (!azookey::channel::WriteAll(pipe, reply + "\n", kStepLimitMilliseconds)) break;
        }
        CloseHandle(pipe);
    }

    // Guarded by mutex_.
    std::string Answer(const Value& request) {
        const std::string& operation = request["operation"].AsString();
        const Value& ai = request["ai"];
        auto reply = [](std::map<std::string, Value> members) {
            members["transformation"] = Value::MakeNumber(kTransformation);
            return azookey::json::Serialize(Value::MakeObject(std::move(members)));
        };
        if (operation == "ai-transform-preview") {
            if (ai["prompt"].AsString().empty()) return reply({{"previewRefusal", Value::MakeString("emptyPrompt")}});
            if (ai["shortcutText"].AsString() == kBadShortcut) return reply({{"historyError", Value::MakeString("format")}});
            ++revision_;
            resultAccepted_ = false;
            return reply({{"revision", Value::MakeNumber(revision_)},
                          {"request", Value::MakeObject({{"target", Value::MakeString("原文")},
                                                         {"prompt", ai["prompt"]},
                                                         {"includeContext", ai["includeContext"]},
                                                         {"aiModel", Value::MakeString("stub-model")},
                                                         {"aiEndpoint", Value::MakeString("http://127.0.0.1:1/")}})}});
        }
        if (operation == "transform") {
            if (request["prompt"].AsString() == kMissingKeyPrompt) return "{\"error\":\"missing_api_key\"}";
            return azookey::json::Serialize(Value::MakeObject(
                {{"suggestions", Value::MakeArray({Value::MakeString("変換: " + request["prompt"].AsString())})}}));
        }
        if (operation == "ai-transform-result") {
            bool current = ai["revision"].AsInteger() == revision_ && ai["text"].kind() == Value::Kind::String;
            resultAccepted_ = current;
            return reply({{"accepted", Value::MakeBoolean(ai["revision"].AsInteger() == revision_)},
                          {"text", ai["text"]},
                          {"targetAvailable", Value::MakeBoolean(true)}});
        }
        if (operation == "ai-transform-invalidate") {
            ++revision_;  // a reply to the older preview is no longer current
            resultAccepted_ = false;
            return reply({});
        }
        if (operation == "ai-transform-confirm") return reply({{"confirmed", Value::MakeBoolean(resultAccepted_)}});
        if (operation == "settings-update") {
            return "{\"settings\":{\"includeContext\":" + azookey::json::Serialize(request["settings"]["includeContext"]) +
                   "},\"settingsResult\":{}}";
        }
        return reply({});
    }

    std::wstring pipe_;
    std::atomic<bool> stopping_{false};
    std::mutex mutex_;
    std::vector<Value> requests_;
    int revision_ = 0;
    bool resultAccepted_ = false;
    std::vector<std::thread> clients_;
    std::thread thread_;
};

azookey::ai_transform::HeldTransformation HeldForTest() {
    Value held = Value::MakeObject({
        {"context", Value::MakeString("text-service-context")},
        {"transformation", Value::MakeNumber(kTransformation)},
        {"initialPrompt", Value::MakeString("")},
        {"field", Value::MakeObject({{"identity", Value::MakeArray({Value::MakeString("document-1")})},
                                     {"isSensitive", Value::MakeBoolean(false)}})},
        {"open", Value::MakeObject({
                     {"target", Value::MakeString("原文")},
                     {"destination", Value::MakeString("api.example.com:443")},
                     {"includeContext", Value::MakeBoolean(false)},
                     {"needsWitness", Value::MakeBoolean(true)},
                     {"history", Value::MakeArray({
                                     Value::MakeObject({{"prompt", Value::MakeString("敬語に直す")},
                                                        {"pinned", Value::MakeBoolean(true)},
                                                        {"shortcutText", Value::MakeString("Ctrl+Alt+e")}}),
                                     Value::MakeObject({{"prompt", Value::MakeString("英語へ翻訳する")},
                                                        {"pinned", Value::MakeBoolean(false)},
                                                        {"shortcutText", Value::MakeString("")}}),
                                 })},
                 })},
    });
    return *azookey::ai_transform::ParseHeldTransformation(held);
}

bool PumpUntil(const std::function<bool()>& done) {
    ULONGLONG deadline = GetTickCount64() + kStepLimitMilliseconds;
    while (!done()) {
        if (GetTickCount64() > deadline) return false;
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (azookey::ui::TranslateDialogKeys(&message)) continue;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
    }
    return true;
}

bool WaitIdle(AITransformWindow& window) {
    return PumpUntil([&] { return !window.busy(); });
}

std::vector<Value> RequestsNamed(StandInHost& host, const std::string& operation) {
    std::vector<Value> found;
    for (const auto& request : host.requests()) {
        if (request["operation"].AsString() == operation) found.push_back(request);
    }
    return found;
}

// Replaces an edit's text the way typing does, so the window gets EN_CHANGE.
void Type(HWND edit, const std::wstring& text) {
    SendMessageW(edit, EM_SETSEL, 0, -1);
    SendMessageW(edit, EM_REPLACESEL, FALSE, reinterpret_cast<LPARAM>(text.c_str()));
}

void Click(HWND button) { SendMessageW(button, BM_CLICK, 0, 0); }

std::unique_ptr<AITransformWindow> OpenWindow(const std::wstring& pipe, bool shown) {
    AITransformWindow::Options options;
    options.language = kLanguage;
    options.held = HeldForTest();
    options.conversion = azookey::ui::BridgeWorker::ConnectionOptions(pipe, L"");
    options.ai = options.conversion;
    options.quitWhenClosed = false;
    auto window = std::make_unique<AITransformWindow>(std::move(options));
    if (shown) window->Present();
    return window;
}

void Capture(const std::wstring& directory, HWND window, const std::wstring& name) {
    if (directory.empty()) return;
    SetWindowPos(window, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    PumpUntil([start = GetTickCount64()] { return GetTickCount64() - start > 400; });
    RECT bounds{};
    if (FAILED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &bounds, sizeof(bounds)))) GetWindowRect(window, &bounds);
    Check(azookey::tests::SaveScreenRegionPng(directory + L"\\" + name + L".png", bounds), "screenshot " + Utf8(name) + " saved");
    SetWindowPos(window, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void TestTheWindowShowsWhatCoreWillSend(AITransformWindow& window) {
    Check(azookey::ui::WindowText(window.targetText()) == L"原文", "the target is shown");
    Check(SendMessageW(window.historyList(), CB_GETCOUNT, 0, 0) == 3, "the history lists every instruction after the prompt to choose");
    wchar_t first[256] = {};
    SendMessageW(window.historyList(), CB_GETLBTEXT, 1, reinterpret_cast<LPARAM>(first));
    Check(std::wstring(first).find(L"★") != std::wstring::npos && std::wstring(first).find(L"Ctrl+Alt+e") != std::wstring::npos,
          "a pinned instruction shows its mark and its shortcut", Utf8(first));
    Check(!IsWindowEnabled(window.applyButton()) && !IsWindowEnabled(window.copyButton()), "nothing can be applied or copied yet");
}

void TestThePreviewGoesThroughTransformWithoutAKey(AITransformWindow& window, StandInHost& host) {
    SendMessageW(window.historyList(), CB_SETCURSEL, 1, 0);
    SendMessageW(window.window(), WM_COMMAND, MAKEWPARAM(GetDlgCtrlID(window.historyList()), CBN_SELCHANGE),
                 reinterpret_cast<LPARAM>(window.historyList()));
    Check(azookey::ui::WindowText(window.instructionEdit()) == L"敬語に直す" &&
              SendMessageW(window.pinCheckBox(), BM_GETCHECK, 0, 0) == BST_CHECKED &&
              azookey::ui::WindowText(window.shortcutEdit()) == L"Ctrl+Alt+e",
          "choosing from the history fills the instruction, the pin and the shortcut");
    host.Forget();
    Click(window.previewButton());
    WaitIdle(window);
    auto previews = RequestsNamed(host, "ai-transform-preview");
    Check(previews.size() == 1 && previews[0]["context"].AsString() == "text-service-context" &&
              previews[0]["ai"]["transformation"].AsInteger() == kTransformation &&
              previews[0]["ai"]["prompt"].AsString() == "敬語に直す" && previews[0]["ai"]["pinned"].AsBoolean() &&
              previews[0]["ai"]["shortcutText"].AsString() == "Ctrl+Alt+e" && !previews[0]["ai"]["includeContext"].AsBoolean(true) &&
              previews[0]["ai"]["field"]["identity"].AsArray().size() == 1,
          "the preview request carries the instruction and the text service's field",
          previews.empty() ? "" : azookey::json::Serialize(previews[0]));
    auto transforms = RequestsNamed(host, "transform");
    Check(transforms.size() == 1 && !transforms[0].Has("apiKey") && transforms[0]["prompt"].AsString() == "敬語に直す",
          "the AI request goes to the host as transform, without an API key");
    auto results = RequestsNamed(host, "ai-transform-result");
    Check(results.size() == 1 && results[0]["ai"]["text"].AsString() == "変換: 敬語に直す", "the AI's answer goes back to Core");
    Check(azookey::ui::WindowText(window.resultEdit()) == L"変換: 敬語に直す", "the accepted result is shown");
    Check(IsWindowEnabled(window.applyButton()) && IsWindowEnabled(window.copyButton()), "the result can be applied and copied");
    Check(azookey::ui::WindowText(window.statusText()) == Message("ai.preview.ready"), "the status says the preview is ready");
}

void TestEditsInvalidateThePreview(AITransformWindow& window, StandInHost& host) {
    host.Forget();
    Type(window.instructionEdit(), L"丁寧に書き直す");
    WaitIdle(window);
    Check(RequestsNamed(host, "ai-transform-invalidate").size() >= 1, "editing the instruction invalidates the preview");
    Check(azookey::ui::WindowText(window.resultEdit()).empty() && !IsWindowEnabled(window.applyButton()),
          "the old result is gone and cannot be applied");
    Check(azookey::ui::WindowText(window.statusText()) == Message("ai.scope.changed"), "the status says the instruction changed");
    host.Forget();
    Click(window.includeContextCheckBox());
    WaitIdle(window);
    auto updates = RequestsNamed(host, "settings-update");
    Check(RequestsNamed(host, "ai-transform-invalidate").size() == 1 && updates.size() == 1 &&
              updates[0]["settings"]["includeContext"].AsBoolean(),
          "including the surrounding text invalidates and saves the choice");
}

void TestCoreRefusalsAreShown(AITransformWindow& window) {
    SetWindowTextW(window.shortcutEdit(), azookey::text::Utf8ToUtf16(kBadShortcut).c_str());
    Click(window.previewButton());
    WaitIdle(window);
    Check(azookey::ui::WindowText(window.statusText()) == Message("ai.shortcut.error.format"),
          "a shortcut Core cannot read is explained");
    SetWindowTextW(window.shortcutEdit(), L"");
    Type(window.instructionEdit(), azookey::text::Utf8ToUtf16(kMissingKeyPrompt));
    Click(window.previewButton());
    WaitIdle(window);
    Check(azookey::ui::WindowText(window.statusText()) == Message("ai.error.missing-key"), "a missing API key is explained");
    Check(!IsWindowEnabled(window.applyButton()), "a failed preview cannot be applied");
}

void TestCopyAndApply(AITransformWindow& window, StandInHost& host) {
    Type(window.instructionEdit(), L"要約する");
    Click(window.previewButton());
    WaitIdle(window);
    Click(window.copyButton());
    std::wstring copied;
    if (OpenClipboard(window.window())) {
        if (HANDLE data = GetClipboardData(CF_UNICODETEXT)) {
            copied = static_cast<const wchar_t*>(GlobalLock(data));
            GlobalUnlock(data);
        }
        CloseClipboard();
    }
    Check(copied == L"変換: 要約する", "Copy puts the result on the clipboard", Utf8(copied));
    host.Forget();
    Click(window.applyButton());
    PumpUntil([&] { return window.closed(); });
    Check(window.closed() && RequestsNamed(host, "ai-transform-confirm").size() == 1, "Apply confirms with Core and closes the window");
    Check(RequestsNamed(host, "ai-transform-close").empty(), "Apply leaves the transformation for the text service to take");
}

void TestClosingTellsCore(const std::wstring& pipe, StandInHost& host) {
    auto window = OpenWindow(pipe, false);
    host.Forget();
    Click(window->closeButton());
    PumpUntil([&] { return window->closed(); });
    Check(window->closed() && RequestsNamed(host, "ai-transform-close").size() == 1, "closing the window closes the transformation");
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    SetConsoleOutputCP(CP_UTF8);
    std::wstring screenshots;
    for (int index = 1; index + 1 < argc; ++index) {
        if (std::wstring(argv[index]) == L"--screenshots") screenshots = argv[index + 1];
    }
    if (!screenshots.empty()) std::filesystem::create_directories(screenshots);
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&controls);
    azookey::ui::TopLevelWindow::RegisterWindowClass(GetModuleHandleW(nullptr), AITransformWindow::kClassName, nullptr);
    std::wstring pipe = L"\\\\.\\pipe\\azooKeyTree-ai-window-test-" + std::to_wstring(GetCurrentProcessId());
    {
        StandInHost host(pipe);
        auto window = OpenWindow(pipe, !screenshots.empty());
        TestTheWindowShowsWhatCoreWillSend(*window);
        TestThePreviewGoesThroughTransformWithoutAKey(*window, host);
        Capture(screenshots, window->window(), L"ai-transform-preview");
        TestEditsInvalidateThePreview(*window, host);
        TestCoreRefusalsAreShown(*window);
        TestCopyAndApply(*window, host);
        TestClosingTellsCore(pipe, host);
    }
    CoUninitialize();
    std::printf("%s\n", failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}
