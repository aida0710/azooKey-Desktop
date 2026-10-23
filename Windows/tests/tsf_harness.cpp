// Drives a text input processor without a physical keyboard.
// It hosts a TSF-enabled RichEdit, activates the requested profile and feeds
// keys through ITfKeystrokeMgr, the same entry point the system uses, then
// prints the document text as UTF-8. Keys the processor does not eat are
// delivered to the edit control as ordinary messages.
//
//   tsf-harness --clsid {..} --profile {..} --keys "nihongo{SPACE}{SHOT:menu}{ENTER}"
//               [--expect 日本語] [--screenshots <directory>] [--ui-less]
//
// With --expect the exit code is 0 only when the document equals that text.
// {SHOT:name} saves the screen as <directory>\name.png at that point, so the
// candidate windows can be reviewed from machines without a desktop session.
// {FIRSTFRAME:name} checks the candidate panel as the screen showed it right
// after the previous key, before any window message ran: it must already look
// as it does once settled (name.png and name-settled.png). Any difference fails.
// --ui-less makes the harness behave like a full-screen game: it refuses the
// IME's own candidate window and reads the list through ITfCandidateListUIElement.
#include <windows.h>
#include <dwmapi.h>
#include <msctf.h>
#include <richedit.h>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <optional>
#include <string>
#include <vector>

#include "screen_capture.h"

namespace {

constexpr wchar_t kCandidatePanelClass[] = L"azooKeyTreeCandidatePanel";
// Long enough for the text service's windows to repaint after a key.
constexpr DWORD kScreenshotSettleMilliseconds = 300;
// The edit control is tall enough, and its text far enough from its left edge,
// that the candidate list and its shadow lie over its plain background, so
// nothing else changes under the panel between two captures.
constexpr SIZE kFrameSize{900, 600};
constexpr int kTextLeftMargin = 40;

struct Options {
    CLSID clsid{};
    GUID profile{};
    std::wstring keys;
    std::optional<std::wstring> expected;
    std::wstring screenshotDirectory = L".";
    bool uiLess = false;
    LANGID language = 0x0411;
    DWORD settleMilliseconds = 30;
};

struct KeyStroke {
    UINT virtualKey;
    bool shift;
    bool control;
    std::wstring screenshot;  // non-empty: capture the screen instead of a key
    bool checksFirstFrame = false;  // with `screenshot`: {FIRSTFRAME:name} rather than {SHOT:name}
};

void Fail(const char* step, HRESULT result) {
    std::fprintf(stdout, "FAIL %s hr=0x%08lx\n", step, static_cast<unsigned long>(result));
    std::fflush(stdout);
    ExitProcess(2);
}

bool ParseGuid(const wchar_t* text, GUID* out) {
    return SUCCEEDED(CLSIDFromString(text, out));
}

// Named keys use braces so that ordinary letters stay readable in test cases.
bool ParseKeys(const std::wstring& text, std::vector<KeyStroke>* out) {
    struct Named { const wchar_t* name; UINT key; };
    static const Named names[] = {
        {L"SPACE", VK_SPACE}, {L"ENTER", VK_RETURN}, {L"ESC", VK_ESCAPE}, {L"BS", VK_BACK},
        {L"TAB", VK_TAB}, {L"LEFT", VK_LEFT}, {L"RIGHT", VK_RIGHT}, {L"UP", VK_UP}, {L"DOWN", VK_DOWN},
        {L"F6", VK_F6}, {L"F7", VK_F7}, {L"F8", VK_F8}, {L"F9", VK_F9}, {L"F10", VK_F10},
        {L"DEL", VK_DELETE}, {L"HOME", VK_HOME}, {L"END", VK_END}, {L"CONVERT", VK_CONVERT},
        {L"NONCONVERT", VK_NONCONVERT}, {L"KANJI", VK_KANJI}, {L"MINUS", VK_OEM_MINUS},
        {L"COMMA", VK_OEM_COMMA}, {L"PERIOD", VK_OEM_PERIOD},
    };
    for (size_t i = 0; i < text.size();) {
        if (text[i] == L'{') {
            size_t end = text.find(L'}', i);
            if (end == std::wstring::npos) return false;
            std::wstring name = text.substr(i + 1, end - i - 1);
            if (name.rfind(L"SHOT:", 0) == 0) {
                out->push_back({0, false, false, name.substr(5)});
                i = end + 1;
                continue;
            }
            if (name.rfind(L"FIRSTFRAME:", 0) == 0) {
                out->push_back({0, false, false, name.substr(11), true});
                i = end + 1;
                continue;
            }
            KeyStroke stroke{0, false, false, {}};
            for (;;) {
                if (name.rfind(L"SHIFT+", 0) == 0) { stroke.shift = true; name = name.substr(6); continue; }
                if (name.rfind(L"CTRL+", 0) == 0) { stroke.control = true; name = name.substr(5); continue; }
                break;
            }
            for (const auto& entry : names) {
                if (name == entry.name) stroke.virtualKey = entry.key;
            }
            if (stroke.virtualKey == 0 && name.size() == 1) stroke.virtualKey = towupper(name[0]);
            if (stroke.virtualKey == 0) return false;
            out->push_back(stroke);
            i = end + 1;
            continue;
        }
        wchar_t c = text[i++];
        if (c >= L'a' && c <= L'z') out->push_back({static_cast<UINT>(towupper(c)), false, false, {}});
        else if (c >= L'A' && c <= L'Z') out->push_back({static_cast<UINT>(c), true, false, {}});
        else if (c >= L'0' && c <= L'9') out->push_back({static_cast<UINT>(c), false, false, {}});
        else if (c == L'-') out->push_back({VK_OEM_MINUS, false, false, {}});
        else if (c == L',') out->push_back({VK_OEM_COMMA, false, false, {}});
        else if (c == L'.') out->push_back({VK_OEM_PERIOD, false, false, {}});
        else if (c == L' ') out->push_back({VK_SPACE, false, false, {}});
        else return false;
    }
    return true;
}

void PumpMessages(DWORD milliseconds) {
    ULONGLONG deadline = GetTickCount64() + milliseconds;
    do {
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        Sleep(1);
    } while (GetTickCount64() < deadline);
}

struct CandidatePanelSearch {
    DWORD process;
    HWND panel;
};

BOOL CALLBACK MatchCandidatePanel(HWND window, LPARAM parameter) {
    auto* search = reinterpret_cast<CandidatePanelSearch*>(parameter);
    DWORD process = 0;
    GetWindowThreadProcessId(window, &process);
    wchar_t className[64] = {};
    if (process != search->process || !GetClassNameW(window, className, ARRAYSIZE(className)) ||
        wcscmp(className, kCandidatePanelClass) != 0) {
        return TRUE;
    }
    search->panel = window;
    return FALSE;
}

// The panel of the text service loaded into this process; other applications may have their own.
HWND FindCandidatePanel() {
    CandidatePanelSearch search{GetCurrentProcessId(), nullptr};
    EnumWindows(MatchCandidatePanel, reinterpret_cast<LPARAM>(&search));
    return search.panel;
}

size_t CountDifferentPixels(const azookey::tests::ScreenImage& first, const azookey::tests::ScreenImage& second) {
    if (first.width != second.width || first.height != second.height) return first.pixels.size() / 4;
    size_t different = 0;
    for (size_t i = 0; i < first.pixels.size(); i += 4) {
        if (memcmp(&first.pixels[i], &second.pixels[i], 4) != 0) ++different;
    }
    return different;
}

void SetModifierState(bool shift, bool control) {
    BYTE state[256];
    GetKeyboardState(state);
    state[VK_SHIFT] = state[VK_LSHIFT] = shift ? 0x80 : 0;
    state[VK_CONTROL] = state[VK_LCONTROL] = control ? 0x80 : 0;
    SetKeyboardState(state);
}

// Records what an application drawing its own candidates would see.
class UiElementObserver final : public ITfUIElementSink {
public:
    explicit UiElementObserver(ITfUIElementMgr* manager) : manager_(manager) {}

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        if (riid == IID_IUnknown || riid == IID_ITfUIElementSink) {
            *object = static_cast<ITfUIElementSink*>(this);
            AddRef();
            return S_OK;
        }
        *object = nullptr;
        return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return ++references_; }
    STDMETHODIMP_(ULONG) Release() override { return --references_; }  // lives on the stack

    STDMETHODIMP BeginUIElement(DWORD id, BOOL* show) override {
        *show = FALSE;  // we draw the candidates ourselves
        ++begun_;
        Read(id);
        return S_OK;
    }
    STDMETHODIMP UpdateUIElement(DWORD id) override {
        Read(id);
        return S_OK;
    }
    STDMETHODIMP EndUIElement(DWORD) override { return S_OK; }

    int begun() const { return begun_; }
    UINT count() const { return count_; }
    const std::wstring& first() const { return first_; }

private:
    void Read(DWORD id) {
        ITfUIElement* element = nullptr;
        if (FAILED(manager_->GetUIElement(id, &element))) return;
        ITfCandidateListUIElement* list = nullptr;
        if (SUCCEEDED(element->QueryInterface(IID_ITfCandidateListUIElement, reinterpret_cast<void**>(&list)))) {
            list->GetCount(&count_);
            BSTR text = nullptr;
            if (count_ > 0 && SUCCEEDED(list->GetString(0, &text))) {
                first_ = text;
                SysFreeString(text);
            }
            list->Release();
        }
        element->Release();
    }

    ITfUIElementMgr* manager_;
    ULONG references_ = 1;
    int begun_ = 0;
    UINT count_ = 0;
    std::wstring first_;
};

std::string ToUtf8(const std::wstring& text) {
    if (text.empty()) return {};
    int size = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string out(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), size, nullptr, nullptr);
    return out;
}

// Runs for {FIRSTFRAME:name}: right after the previous key, before any window message.
bool CheckFirstFrame(const std::wstring& directory, const std::wstring& name) {
    // Waits for the next composition, so the capture shows what the key left on the screen.
    DwmFlush();
    HWND panel = FindCandidatePanel();
    RECT bounds{};
    if (!panel || !IsWindowVisible(panel) || !GetWindowRect(panel, &bounds)) {
        std::printf("FAIL first frame %s: no candidate panel is shown\n", ToUtf8(name).c_str());
        return false;
    }
    azookey::tests::ScreenImage first = azookey::tests::CaptureScreenRegion(bounds);
    PumpMessages(kScreenshotSettleMilliseconds);
    DwmFlush();
    RECT settledBounds{};
    GetWindowRect(panel, &settledBounds);
    azookey::tests::ScreenImage settled = azookey::tests::CaptureScreenRegion(bounds);
    azookey::tests::SavePng(directory + L"\\" + name + L".png", first);
    azookey::tests::SavePng(directory + L"\\" + name + L"-settled.png", settled);
    size_t different = CountDifferentPixels(first, settled);
    if (!EqualRect(&bounds, &settledBounds) || different > 0) {
        std::printf("FAIL first frame %s: the panel changed after its first frame (moved: %s, %zu of %zu pixels differ)\n",
                    ToUtf8(name).c_str(), EqualRect(&bounds, &settledBounds) ? "no" : "yes", different, first.pixels.size() / 4);
        return false;
    }
    std::printf("FIRSTFRAME %s: the first frame already shows the settled panel (%ldx%ld)\n", ToUtf8(name).c_str(),
                bounds.right - bounds.left, bounds.bottom - bounds.top);
    return true;
}

std::wstring EditText(HWND edit) {
    int length = GetWindowTextLengthW(edit);
    std::wstring text(length + 1, L'\0');
    GetWindowTextW(edit, text.data(), length + 1);
    text.resize(length);
    return text;
}

bool ParseOptions(int argc, wchar_t** argv, Options* options) {
    for (int i = 1; i < argc; ++i) {
        std::wstring name = argv[i];
        if (name == L"--ui-less") {
            options->uiLess = true;
            continue;
        }
        if (i + 1 >= argc) return false;
        const wchar_t* value = argv[++i];
        if (name == L"--clsid" && ParseGuid(value, &options->clsid)) continue;
        if (name == L"--profile" && ParseGuid(value, &options->profile)) continue;
        if (name == L"--keys") { options->keys = value; continue; }
        if (name == L"--expect") { options->expected = value; continue; }
        if (name == L"--screenshots") { options->screenshotDirectory = value; continue; }
        if (name == L"--settle") { options->settleMilliseconds = static_cast<DWORD>(_wtoi(value)); continue; }
        return false;
    }
    return !options->keys.empty();
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    Options options;
    std::vector<KeyStroke> strokes;
    if (!ParseOptions(argc, argv, &options) || !ParseKeys(options.keys, &strokes)) {
        std::fprintf(stderr, "usage: tsf-harness --clsid {...} --profile {...} --keys \"nihongo{SPACE}{ENTER}\"\n");
        return 64;
    }
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) Fail("CoInitializeEx", hr);

    ITfThreadMgr* threadManager = nullptr;
    hr = CoCreateInstance(CLSID_TF_ThreadMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfThreadMgr, reinterpret_cast<void**>(&threadManager));
    if (FAILED(hr)) Fail("CoCreateInstance(ThreadMgr)", hr);
    TfClientId clientId = TF_CLIENTID_NULL;
    hr = threadManager->Activate(&clientId);
    if (FAILED(hr)) Fail("ITfThreadMgr::Activate", hr);
    std::printf("thread manager active client=%lu\n", static_cast<unsigned long>(clientId));

    LoadLibraryW(L"Msftedit.dll");
    HWND frame = CreateWindowExW(0, L"STATIC", L"tsf-harness", WS_OVERLAPPEDWINDOW, 80, 80, kFrameSize.cx, kFrameSize.cy, nullptr,
                                 nullptr, nullptr, nullptr);
    RECT client{};
    if (frame) GetClientRect(frame, &client);
    HWND edit = CreateWindowExW(0, MSFTEDIT_CLASS, L"", WS_CHILD | WS_VISIBLE | ES_MULTILINE, 0, 0, client.right, client.bottom, frame,
                                nullptr, nullptr, nullptr);
    if (!frame || !edit) Fail("CreateWindow", HRESULT_FROM_WIN32(GetLastError()));
    SendMessageW(edit, EM_SETMARGINS, EC_LEFTMARGIN, MAKELPARAM(kTextLeftMargin, 0));
    // RichEdit talks to TSF only when asked to; without this it uses IMM32.
    SendMessageW(edit, EM_SETEDITSTYLE, SES_USECTF | SES_CTFALLOWEMBED | SES_CTFALLOWSMARTTAG | SES_CTFALLOWPROOFING,
                 SES_USECTF | SES_CTFALLOWEMBED | SES_CTFALLOWSMARTTAG | SES_CTFALLOWPROOFING);
    ShowWindow(frame, SW_SHOWNORMAL);
    SetForegroundWindow(frame);
    SetFocus(edit);
    PumpMessages(100);
    std::printf("focus=%s foreground=%s\n", GetFocus() == edit ? "edit" : "other", GetForegroundWindow() == frame ? "frame" : "other");

    ITfInputProcessorProfileMgr* profiles = nullptr;
    hr = CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER, IID_ITfInputProcessorProfileMgr,
                          reinterpret_cast<void**>(&profiles));
    if (FAILED(hr)) Fail("CoCreateInstance(ProfileMgr)", hr);
    hr = profiles->ActivateProfile(TF_PROFILETYPE_INPUTPROCESSOR, options.language, options.clsid, options.profile, nullptr,
                                   TF_IPPMF_FORPROCESS | TF_IPPMF_DONTCARECURRENTINPUTLANGUAGE);
    if (FAILED(hr)) Fail("ActivateProfile", hr);
    PumpMessages(200);

    ITfCompartmentMgr* compartments = nullptr;
    hr = threadManager->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void**>(&compartments));
    if (FAILED(hr)) Fail("QueryInterface(CompartmentMgr)", hr);
    ITfCompartment* openClose = nullptr;
    hr = compartments->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, &openClose);
    if (FAILED(hr)) Fail("GetCompartment(OPENCLOSE)", hr);
    VARIANT open;
    VariantInit(&open);
    open.vt = VT_I4;
    open.lVal = 1;
    hr = openClose->SetValue(clientId, &open);
    if (FAILED(hr)) Fail("SetValue(OPENCLOSE)", hr);
    PumpMessages(100);

    ITfUIElementMgr* elements = nullptr;
    threadManager->QueryInterface(IID_ITfUIElementMgr, reinterpret_cast<void**>(&elements));
    UiElementObserver observer(elements);
    DWORD observerCookie = TF_INVALID_COOKIE;
    if (options.uiLess) {
        ITfSource* source = nullptr;
        if (SUCCEEDED(threadManager->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&source)))) {
            source->AdviseSink(IID_ITfUIElementSink, static_cast<ITfUIElementSink*>(&observer), &observerCookie);
            source->Release();
        }
    }

    ITfKeystrokeMgr* keystrokes = nullptr;
    hr = threadManager->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&keystrokes));
    if (FAILED(hr)) Fail("QueryInterface(KeystrokeMgr)", hr);
    int eatenCount = 0;
    bool firstFramesPassed = true;
    for (size_t index = 0; index < strokes.size(); ++index) {
        const KeyStroke& stroke = strokes[index];
        if (stroke.checksFirstFrame) {
            if (!CheckFirstFrame(options.screenshotDirectory, stroke.screenshot)) firstFramesPassed = false;
            continue;
        }
        if (!stroke.screenshot.empty()) {
            PumpMessages(kScreenshotSettleMilliseconds);
            std::wstring path = options.screenshotDirectory + L"\\" + stroke.screenshot + L".png";
            std::printf("screenshot %s: %s\n", ToUtf8(stroke.screenshot).c_str(), azookey::tests::SaveScreenPng(path) ? "saved" : "failed");
            continue;
        }
        SetModifierState(stroke.shift, stroke.control);
        UINT scan = MapVirtualKeyW(stroke.virtualKey, MAPVK_VK_TO_VSC);
        LPARAM down = 1 | (static_cast<LPARAM>(scan) << 16);
        LPARAM up = down | (1LL << 30) | (1LL << 31);
        BOOL eaten = FALSE;
        hr = keystrokes->TestKeyDown(stroke.virtualKey, down, &eaten);
        if (SUCCEEDED(hr) && eaten) {
            hr = keystrokes->KeyDown(stroke.virtualKey, down, &eaten);
        } else {
            eaten = FALSE;
        }
        if (eaten) {
            ++eatenCount;
        } else {
            SendMessageW(edit, WM_KEYDOWN, stroke.virtualKey, down);
            BYTE state[256];
            GetKeyboardState(state);
            wchar_t chars[4] = {};
            int produced = ToUnicode(stroke.virtualKey, scan, state, chars, 4, 0);
            for (int i = 0; i < produced; ++i) SendMessageW(edit, WM_CHAR, chars[i], down);
        }
        BOOL upEaten = FALSE;
        if (SUCCEEDED(keystrokes->TestKeyUp(stroke.virtualKey, up, &upEaten)) && upEaten) {
            keystrokes->KeyUp(stroke.virtualKey, up, &upEaten);
        } else {
            SendMessageW(edit, WM_KEYUP, stroke.virtualKey, up);
        }
        SetModifierState(false, false);
        // A first-frame check must see the screen before any window message runs.
        bool nextChecksFirstFrame = index + 1 < strokes.size() && strokes[index + 1].checksFirstFrame;
        if (!nextChecksFirstFrame) PumpMessages(options.settleMilliseconds);
    }
    PumpMessages(300);
    std::wstring text = EditText(edit);
    std::printf("eaten=%d/%zu\n", eatenCount, strokes.size());
    bool uiLessPassed = true;
    if (options.uiLess) {
        HWND panel = FindCandidatePanel();
        bool panelVisible = panel && IsWindowVisible(panel);
        std::printf("UIELEMENT begun=%d count=%u first=%s panelVisible=%s\n", observer.begun(), observer.count(),
                    ToUtf8(observer.first()).c_str(), panelVisible ? "yes" : "no");
        uiLessPassed = observer.begun() > 0 && observer.count() > 0 && !panelVisible;
        ITfSource* source = nullptr;
        if (observerCookie != TF_INVALID_COOKIE &&
            SUCCEEDED(threadManager->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&source)))) {
            source->UnadviseSink(observerCookie);
            source->Release();
        }
    }
    if (elements) elements->Release();
    std::printf("TEXT=%s\n", ToUtf8(text).c_str());
    std::fflush(stdout);
    keystrokes->Release();
    openClose->Release();
    compartments->Release();
    profiles->Release();
    DestroyWindow(frame);
    threadManager->Deactivate();
    threadManager->Release();
    CoUninitialize();
    if (!uiLessPassed) {
        std::printf("FAIL ui-less: the candidates were not offered as a UI element, or our panel was shown\n");
        return 1;
    }
    bool matched = true;
    if (options.expected) {
        matched = text == *options.expected;
        std::printf("%s expected=%s\n", matched ? "PASS" : "FAIL", ToUtf8(*options.expected).c_str());
    }
    return matched && firstFramesPassed ? 0 : 1;
}
