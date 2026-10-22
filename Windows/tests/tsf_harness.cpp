// Drives a text input processor without a physical keyboard.
// It hosts a TSF-enabled RichEdit, activates the requested profile and feeds
// keys through ITfKeystrokeMgr, the same entry point the system uses, then
// prints the document text as UTF-8. Keys the processor does not eat are
// delivered to the edit control as ordinary messages.
//
//   tsf-harness --clsid {..} --profile {..} --keys "nihongo{SPACE}{ENTER}" [--expect 日本語]
//
// With --expect the exit code is 0 only when the document equals that text.
#include <windows.h>
#include <msctf.h>
#include <richedit.h>
#include <cstdio>
#include <optional>
#include <string>
#include <vector>

namespace {

struct Options {
    CLSID clsid{};
    GUID profile{};
    std::wstring keys;
    std::optional<std::wstring> expected;
    LANGID language = 0x0411;
    DWORD settleMilliseconds = 30;
};

struct KeyStroke {
    UINT virtualKey;
    bool shift;
    bool control;
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
            KeyStroke stroke{0, false, false};
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
        if (c >= L'a' && c <= L'z') out->push_back({static_cast<UINT>(towupper(c)), false, false});
        else if (c >= L'A' && c <= L'Z') out->push_back({static_cast<UINT>(c), true, false});
        else if (c >= L'0' && c <= L'9') out->push_back({static_cast<UINT>(c), false, false});
        else if (c == L'-') out->push_back({VK_OEM_MINUS, false, false});
        else if (c == L',') out->push_back({VK_OEM_COMMA, false, false});
        else if (c == L'.') out->push_back({VK_OEM_PERIOD, false, false});
        else if (c == L' ') out->push_back({VK_SPACE, false, false});
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

void SetModifierState(bool shift, bool control) {
    BYTE state[256];
    GetKeyboardState(state);
    state[VK_SHIFT] = state[VK_LSHIFT] = shift ? 0x80 : 0;
    state[VK_CONTROL] = state[VK_LCONTROL] = control ? 0x80 : 0;
    SetKeyboardState(state);
}

std::string ToUtf8(const std::wstring& text) {
    if (text.empty()) return {};
    int size = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
    std::string out(size, '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), out.data(), size, nullptr, nullptr);
    return out;
}

std::wstring EditText(HWND edit) {
    int length = GetWindowTextLengthW(edit);
    std::wstring text(length + 1, L'\0');
    GetWindowTextW(edit, text.data(), length + 1);
    text.resize(length);
    return text;
}

bool ParseOptions(int argc, wchar_t** argv, Options* options) {
    for (int i = 1; i + 1 < argc; i += 2) {
        std::wstring name = argv[i];
        if (name == L"--clsid" && ParseGuid(argv[i + 1], &options->clsid)) continue;
        if (name == L"--profile" && ParseGuid(argv[i + 1], &options->profile)) continue;
        if (name == L"--keys") { options->keys = argv[i + 1]; continue; }
        if (name == L"--expect") { options->expected = argv[i + 1]; continue; }
        if (name == L"--settle") { options->settleMilliseconds = static_cast<DWORD>(_wtoi(argv[i + 1])); continue; }
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
    HWND frame = CreateWindowExW(0, L"STATIC", L"tsf-harness", WS_OVERLAPPEDWINDOW, 0, 0, 640, 200, nullptr, nullptr, nullptr, nullptr);
    HWND edit = CreateWindowExW(0, MSFTEDIT_CLASS, L"", WS_CHILD | WS_VISIBLE | ES_MULTILINE, 0, 0, 620, 160, frame, nullptr, nullptr, nullptr);
    if (!frame || !edit) Fail("CreateWindow", HRESULT_FROM_WIN32(GetLastError()));
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

    ITfKeystrokeMgr* keystrokes = nullptr;
    hr = threadManager->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&keystrokes));
    if (FAILED(hr)) Fail("QueryInterface(KeystrokeMgr)", hr);
    int eatenCount = 0;
    for (const auto& stroke : strokes) {
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
        PumpMessages(options.settleMilliseconds);
    }
    PumpMessages(300);
    std::wstring text = EditText(edit);
    std::printf("eaten=%d/%zu\n", eatenCount, strokes.size());
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
    if (options.expected) {
        bool matched = text == *options.expected;
        std::printf("%s expected=%s\n", matched ? "PASS" : "FAIL", ToUtf8(*options.expected).c_str());
        return matched ? 0 : 1;
    }
    return 0;
}
