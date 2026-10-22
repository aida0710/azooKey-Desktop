// Drives the settings windows with window messages against a private host and
// the real converter, then checks the settings file Core wrote. It covers the
// page construction, saving, a file changed elsewhere, recovery of a damaged
// file, the user dictionary (add, edit, delete, validation, import, export),
// the API key staying out of the file, and the settings Windows cannot use.
//
//   azookey-settings-ui-test.exe <host exe> <bridge exe> [--screenshots <directory>]
//
// With --screenshots the windows are shown and every page is saved as a PNG.
#include <windows.h>
#include <commctrl.h>
#include <dwmapi.h>
#include <objbase.h>
#include <oleacc.h>

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <functional>
#include <map>
#include <memory>
#include <sstream>
#include <string>

#include "../src/settings/child_controls.h"
#include "../src/settings/dictionary_protocol.h"
#include "../src/settings/import_preview_window.h"
#include "../src/settings/settings_dialogs.h"
#include "../src/settings/settings_window.h"
#include "../src/settings/top_level_window.h"
#include "../src/settings/window_classes.h"
#include "../src/shared/api_key_credential.h"
#include "../src/shared/host_channel.h"
#include "../src/shared/json.h"
#include "../src/shared/message_catalog_data.h"
#include "../src/shared/text_encoding.h"
#include "screen_capture.h"

namespace {

using namespace azookey::settings;
using azookey::json::Value;
using azookey::messages::Language;

constexpr Language kLanguage = Language::Japanese;
// Bounds for a broken run; a passing step finishes in milliseconds to seconds.
constexpr DWORD kFirstLoadLimitMilliseconds = 60000;
constexpr DWORD kStepLimitMilliseconds = 30000;
// The dictionary imported to measure a save of a realistic size.
constexpr int kImportedEntries = 300;

int failures = 0;

void Check(bool condition, const std::string& description) {
    if (!condition) ++failures;
    std::printf("%s: %s\n", condition ? "ok" : "FAIL", description.c_str());
    std::fflush(stdout);
}

// Like Check, and shows what the window or the file actually held when it fails.
void CheckShowing(bool condition, const std::string& description, const std::string& actual) {
    Check(condition, description);
    if (!condition) std::printf("  actual: %s\n", actual.c_str());
}

std::string Utf8(const std::wstring& text) { return azookey::text::Utf16ToUtf8(text); }

// The dialogs answer as the test decides and record what they were asked.
class ScriptedDialogs final : public SettingsDialogs {
public:
    bool ConfirmResetLearning(HWND) override { return ++resetLearningAsked > 0; }
    bool ConfirmRecovery(HWND) override { return ++recoveryAsked > 0; }
    bool ConfirmReloadChangedFile(HWND) override {
        ++reloadAsked;
        return reloadAnswer;
    }
    std::optional<ImportSelection> ChooseImportFile(HWND) override { return importSelection; }
    std::optional<std::wstring> ChooseExportFile(HWND) override { return exportPath; }
    bool ConfirmImport(HWND, const ImportPreview& preview) override {
        lastPreviewAdditions = preview.additions;
        return true;
    }

    int resetLearningAsked = 0;
    int recoveryAsked = 0;
    int reloadAsked = 0;
    bool reloadAnswer = true;
    std::optional<ImportSelection> importSelection;
    std::optional<std::wstring> exportPath;
    int lastPreviewAdditions = -1;
};

struct Environment {
    std::wstring root;
    std::wstring settingsFile;
    std::wstring dataDirectory;
    std::wstring pipe;
    std::wstring credential;
    std::wstring screenshots;  // empty: windows stay hidden where they can
};

bool PumpUntil(const std::function<bool()>& done, DWORD limitMilliseconds) {
    ULONGLONG deadline = GetTickCount64() + limitMilliseconds;
    while (!done()) {
        if (GetTickCount64() > deadline) return false;
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (TranslateDialogKeys(&message)) continue;
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
    }
    return true;
}

void PumpFor(DWORD milliseconds) {
    PumpUntil([] { return false; }, milliseconds);
}

std::string ReadBytes(const std::wstring& path) {
    std::ifstream file(path, std::ios::binary);
    std::ostringstream contents;
    contents << file.rdbuf();
    return contents.str();
}

void WriteBytes(const std::wstring& path, const std::string& bytes) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << bytes;
}

std::optional<Value> ReadSettingsFile(const Environment& environment) {
    return azookey::json::Parse(ReadBytes(environment.settingsFile));
}

std::wstring Message(const char* key) { return azookey::messages::Text(key, kLanguage); }

bool HasStyle(HWND window, LONG style) { return (GetWindowLongW(window, GWL_STYLE) & style) == style; }

bool IsClass(HWND window, const wchar_t* className) {
    wchar_t name[64] = {};
    GetClassNameW(window, name, static_cast<int>(std::size(name)));
    return _wcsicmp(name, className) == 0;
}

std::wstring AccessibleName(HWND control) {
    IAccessible* accessible = nullptr;
    if (FAILED(AccessibleObjectFromWindow(control, static_cast<DWORD>(OBJID_CLIENT), IID_PPV_ARGS(&accessible)))) return L"";
    VARIANT self{};
    self.vt = VT_I4;
    self.lVal = CHILDID_SELF;
    BSTR name = nullptr;
    std::wstring result;
    if (SUCCEEDED(accessible->get_accName(self, &name)) && name) result = name;
    SysFreeString(name);
    accessible->Release();
    return result;
}

void Click(HWND button) { SendMessageW(button, BM_CLICK, 0, 0); }

// Replaces an edit's text the way typing does, so the edit reports EN_CHANGE
// (a multi-line edit does not report text set with WM_SETTEXT).
void SetText(HWND edit, const std::wstring& text) {
    SendMessageW(edit, EM_SETSEL, 0, -1);
    SendMessageW(edit, EM_REPLACESEL, FALSE, reinterpret_cast<LPARAM>(text.c_str()));
}

void SelectChoice(HWND comboBox, int index) {
    SendMessageW(comboBox, CB_SETCURSEL, static_cast<WPARAM>(index), 0);
    SendMessageW(GetParent(comboBox), WM_COMMAND, MAKEWPARAM(GetDlgCtrlID(comboBox), CBN_SELCHANGE),
                 reinterpret_cast<LPARAM>(comboBox));
}

// Ctrl+Alt+<key> as the shortcut field sees it: the modifier state comes from
// the thread's keyboard state.
void PressShortcut(HWND field, UINT virtualKey) {
    BYTE state[256] = {};
    GetKeyboardState(state);
    BYTE saved[256];
    std::copy(std::begin(state), std::end(state), std::begin(saved));
    state[VK_CONTROL] = state[VK_LCONTROL] = 0x80;
    state[VK_MENU] = state[VK_LMENU] = 0x80;
    SetKeyboardState(state);
    SendMessageW(field, WM_KEYDOWN, virtualKey, 0);
    SetKeyboardState(saved);
}

// The window's visible frame on screen, without the drop shadow.
RECT FrameOf(HWND window) {
    RECT bounds{};
    if (FAILED(DwmGetWindowAttribute(window, DWMWA_EXTENDED_FRAME_BOUNDS, &bounds, sizeof(bounds)))) {
        GetWindowRect(window, &bounds);
    }
    return bounds;
}

void Capture(const Environment& environment, HWND window, const std::wstring& name) {
    if (environment.screenshots.empty()) return;
    SetForegroundWindow(window);
    RedrawWindow(window, nullptr, nullptr, RDW_INVALIDATE | RDW_UPDATENOW | RDW_ALLCHILDREN);
    PumpFor(400);
    std::wstring path = environment.screenshots + L"\\" + name + L".png";
    bool saved = azookey::tests::SaveScreenRegionPng(path, FrameOf(window));
    Check(saved, "screenshot " + Utf8(name) + " saved");
}

std::unique_ptr<SettingsWindow> OpenSettings(const Environment& environment, ScriptedDialogs& dialogs,
                                             const std::string& page = "") {
    SettingsWindow::Options options;
    options.language = kLanguage;
    options.connection = BridgeWorker::ConnectionOptions(environment.pipe, L"");
    options.dialogs = &dialogs;
    options.apiKeyCredential = environment.credential;
    options.dataDirectory = environment.dataDirectory;
    options.buildInfoPath = environment.root + L"\\build-info.txt";
    options.initialPage = page;
    options.quitWhenClosed = false;
    auto window = std::make_unique<SettingsWindow>(options);
    if (!environment.screenshots.empty()) window->Present();
    bool loaded = PumpUntil([&] { return window->loaded() && !window->busy(); }, kFirstLoadLimitMilliseconds);
    Check(loaded && window->form(), "the settings window loads Core's definition and the file");
    return window;
}

bool WaitIdle(SettingsWindow& window) {
    return PumpUntil([&] { return !window.busy(); }, kStepLimitMilliseconds);
}

std::wstring StatusOf(SettingsWindow& window) { return WindowText(window.statusText()); }

void TestPagesFollowTheDefinition(SettingsWindow& window) {
    SettingsForm& form = *window.form();
    Check(form.pageCount() == 5 && SendMessageW(window.pageList(), LB_GETCOUNT, 0, 0) == 5,
          "every page of the definition is listed");
    Check(window.currentPage() == "support", "a first start without a settings file opens the support page");
    Check(IsClass(form.ControlFor("live"), WC_BUTTONW) && HasStyle(form.ControlFor("live"), BS_AUTOCHECKBOX),
          "a toggle is a check box");
    Check(IsClass(form.ControlFor("punctuation"), WC_COMBOBOXW) && HasStyle(form.ControlFor("punctuation"), CBS_DROPDOWNLIST),
          "a choice is a drop-down list");
    Check(IsClass(form.ControlFor("inferenceLimit"), WC_EDITW) && HasStyle(form.ControlFor("inferenceLimit"), ES_NUMBER),
          "an integer is a number edit");
    Check(HasStyle(form.ControlFor("customTable"), ES_MULTILINE), "the custom table is a multi-line edit");
    Check(HasStyle(form.ControlFor("transformShortcut"), ES_READONLY), "the shortcut is a recording field");
    Check(IsClass(form.ControlFor("userDictionary"), WC_BUTTONW), "the dictionary is a button");
    Check(form.SecretEdit() && HasStyle(form.SecretEdit(), ES_PASSWORD), "the API key is a password edit");
    Check(AccessibleName(form.ControlFor("punctuation")) == Message("settings.punctuation"),
          "a drop-down list is named by its label for screen readers");
    Check(AccessibleName(form.SecretEdit()) == Message("ai.api-key"), "the API key field is named by its label");
}

void TestSettingsWindowsCannotUseAreDisabled(SettingsWindow& window) {
    SettingsForm& form = *window.form();
    const std::wstring reason = Message("settings.unavailable.marisa_windows");
    Check(!IsWindowEnabled(form.ControlFor("typoCorrection")), "typo correction is disabled on Windows");
    Check(!IsWindowEnabled(form.ControlFor("personalization")), "the personalization model is disabled on Windows");
    Check(form.UnavailableReasonFor("typoCorrection") && WindowText(form.UnavailableReasonFor("typoCorrection")) == reason,
          "the reason is shown beside the disabled setting");
    Check(form.ActionButton("downloadTypoWeights") && !IsWindowEnabled(form.ActionButton("downloadTypoWeights")),
          "downloading typo weights is disabled");
    Check(form.ActionButton("importPersonalization") && !IsWindowEnabled(form.ActionButton("importPersonalization")),
          "importing a personalization model is disabled");
    Check(form.ActionButton("resetLearning") && IsWindowEnabled(form.ActionButton("resetLearning")),
          "resetting learning stays available");
}

void TestSavingWritesTheFileAndKeepsTheKeyOut(SettingsWindow& window, const Environment& environment) {
    SettingsForm& form = *window.form();
    SendMessageW(form.ControlFor("live"), BM_SETCHECK, BST_UNCHECKED, 0);
    SelectChoice(form.ControlFor("punctuation"), 1);
    SetText(form.ControlFor("inferenceLimit"), L"7");
    SetText(form.ControlFor("profile"), L"技術文書を書くことが多い");
    PressShortcut(form.ControlFor("transformShortcut"), 'E');
    Check(WindowText(form.ControlFor("transformShortcut")) == L"Ctrl+Alt+E", "the shortcut field shows the pressed keys");
    const std::wstring apiKey = L"sk-settings-test-" + std::to_wstring(GetCurrentProcessId());
    SetText(form.SecretEdit(), apiKey);
    Click(window.saveButton());
    WaitIdle(window);
    CheckShowing(StatusOf(window) == Message("settings.saved"), "Save reports that the settings were saved", Utf8(StatusOf(window)));
    auto file = ReadSettingsFile(environment);
    Check(file.has_value(), "settings.json is valid JSON");
    if (!file) return;
    Check(!(*file)["live"].AsBoolean(true), "live conversion is off in the file");
    Check((*file)["punctuation"].AsInteger() == 2, "the second punctuation choice is saved as its integer");
    Check((*file)["inferenceLimit"].AsInteger() == 7, "the number is saved");
    Check((*file)["profile"].AsString() == "技術文書を書くことが多い", "the profile text is saved");
    Check((*file)["transformShortcut"]["key"].AsString() == "e" && (*file)["transformShortcut"]["modifiers"].AsInteger() == 6,
          "the shortcut is saved as Core's key and modifiers");
    Check(ReadBytes(environment.settingsFile).find(Utf8(apiKey)) == std::string::npos, "the API key is not in settings.json");
    auto stored = azookey::credentials::ReadApiKey(environment.credential);
    Check(stored && *stored == apiKey, "the API key is in Credential Manager");
    Check(WindowText(form.SecretEdit()).empty(), "the API key field is cleared after saving");
}

void TestCoreRefusalsAreShownWithTheLabel(SettingsWindow& window, const Environment& environment) {
    SettingsForm& form = *window.form();
    std::string before = ReadBytes(environment.settingsFile);
    SetText(form.ControlFor("inferenceLimit"), L"500");
    Click(window.saveButton());
    WaitIdle(window);
    std::wstring status = StatusOf(window);
    Check(status.find(Message("settings.inferenceLimit")) != std::wstring::npos,
          "an out-of-range number is reported with the setting's label");
    Check(ReadBytes(environment.settingsFile) == before, "a refused save leaves the file as it was");
    SetText(form.ControlFor("inferenceLimit"), L"7");
}

void TestAFileChangedElsewhereIsReloaded(SettingsWindow& window, const Environment& environment, ScriptedDialogs& dialogs) {
    SettingsForm& form = *window.form();
    auto file = ReadSettingsFile(environment);
    if (!file) return;
    WriteBytes(environment.settingsFile, azookey::json::Serialize(WithValue(*file, "live", Value::MakeBoolean(true))));
    SelectChoice(form.ControlFor("punctuation"), 0);
    Click(window.saveButton());
    bool reloaded = PumpUntil([&] { return !window.busy() && StatusOf(window) == Message("settings.reloaded"); },
                              kStepLimitMilliseconds);
    Check(dialogs.reloadAsked == 1 && reloaded, "saving over a changed file asks to reload and reloads");
    Check(SendMessageW(form.ControlFor("live"), BM_GETCHECK, 0, 0) == BST_CHECKED, "the reloaded value from the file is shown");
    Check(SendMessageW(form.ControlFor("punctuation"), CB_GETCURSEL, 0, 0) == 1, "the unsaved edit was replaced by the file");
    auto after = ReadSettingsFile(environment);
    Check(after && (*after)["punctuation"].AsInteger() == 2, "the file written elsewhere was not overwritten");
}

void TestLearningCanBeReset(SettingsWindow& window, ScriptedDialogs& dialogs) {
    Click(window.form()->ActionButton("resetLearning"));
    WaitIdle(window);
    Check(dialogs.resetLearningAsked == 1, "resetting learning asks first");
    Check(StatusOf(window) == Message("learning.reset.completed"), "resetting learning reports completion");
}

void TestSupportReportIsCopied(SettingsWindow& window) {
    SupportPanel* support = window.support();
    if (!support) {
        Check(false, "the support page has its panel");
        return;
    }
    std::wstring report = WindowText(support->reportEdit());
    CheckShowing(report.find(L"azooKey Tree") != std::wstring::npos && report.find(L"TSF") != std::wstring::npos,
                 "the support page shows Core's Windows report", Utf8(report + L" / " + WindowText(support->notice())));
    Click(support->copyButton());
    WaitIdle(window);
    std::wstring copied;
    if (OpenClipboard(window.window())) {
        if (HANDLE data = GetClipboardData(CF_UNICODETEXT)) {
            copied = static_cast<const wchar_t*>(GlobalLock(data));
            GlobalUnlock(data);
        }
        CloseClipboard();
    }
    Check(copied.find(L"Windows ") != std::wstring::npos && WindowText(support->notice()) == Message("support.copied"),
          "the report is copied to the clipboard");
}

DictionaryWindow* OpenDictionary(SettingsWindow& window) {
    Click(window.form()->DictionaryButton());
    PumpUntil([&] { return window.dictionaryWindow() != nullptr && !window.busy(); }, kStepLimitMilliseconds);
    return window.dictionaryWindow();
}

bool SaveDictionary(SettingsWindow& window, DictionaryWindow& dictionary) {
    Click(dictionary.saveButton());
    return PumpUntil([&] { return !window.busy(); }, kStepLimitMilliseconds);
}

std::vector<Value> DictionaryItems(const Environment& environment) {
    auto file = ReadSettingsFile(environment);
    return file ? (*file)["userDictionary"]["items"].AsArray() : std::vector<Value>{};
}

void TestDictionaryAddEditDeleteAndValidation(SettingsWindow& window, const Environment& environment) {
    DictionaryWindow* dictionary = OpenDictionary(window);
    Check(dictionary != nullptr, "the dictionary button opens the editor");
    if (!dictionary) return;
    Capture(environment, dictionary->window(), L"dictionary-empty");
    Click(dictionary->addButton());
    SetText(dictionary->wordEdit(), L"東京タワー");
    SetText(dictionary->readingEdit(), L"とうきょうたわー");
    SetText(dictionary->hintEdit(), L"観光地");
    Check(dictionary->draft().HasChanges(), "the form edits the draft");
    Check(SaveDictionary(window, *dictionary) && window.dictionaryWindow() == nullptr, "a valid draft is saved and the editor closes");
    auto items = DictionaryItems(environment);
    CheckShowing(items.size() == 1 && items[0]["word"].AsString() == "東京タワー" &&
                     items[0]["reading"].AsString() == "とうきょうたわー" && items[0]["hint"].AsString() == "観光地",
                 "the added entry is in settings.json", ReadBytes(environment.settingsFile));
    Check(StatusOf(window) == Message("settings.dictionary_saved"), "the settings window reports the saved dictionary");
    Check(WindowText(window.form()->DictionaryButton()).find(L"1") != std::wstring::npos, "the dictionary button counts the entry");

    dictionary = OpenDictionary(window);
    if (!dictionary) return;
    SetText(dictionary->readingEdit(), L"とうきょうたわぁ");
    SaveDictionary(window, *dictionary);
    items = DictionaryItems(environment);
    Check(items.size() == 1 && items[0]["reading"].AsString() == "とうきょうたわぁ", "editing the selected entry is saved");

    dictionary = OpenDictionary(window);
    if (!dictionary) return;
    Click(dictionary->addButton());
    SetText(dictionary->wordEdit(), L"制御");
    SetText(dictionary->readingEdit(), std::wstring(L"せいぎょ") + L'\x0007');
    Click(dictionary->saveButton());
    PumpUntil([&] { return !window.busy(); }, kStepLimitMilliseconds);
    Check(window.dictionaryWindow() != nullptr && !dictionary->draft().issues().empty(),
          "Core's validation keeps the editor open with the issue");
    Check(!WindowText(dictionary->issueText()).empty(), "the issue of the selected entry is explained");
    Check(DictionaryItems(environment).size() == 1, "an invalid draft is not saved");
    Capture(environment, dictionary->window(), L"dictionary-validation");
    Click(dictionary->removeButton());
    SaveDictionary(window, *dictionary);
    Check(window.dictionaryWindow() == nullptr && DictionaryItems(environment).size() == 1,
          "removing the invalid entry lets the draft save");

    dictionary = OpenDictionary(window);
    if (!dictionary) return;
    Click(dictionary->removeButton());
    SaveDictionary(window, *dictionary);
    Check(DictionaryItems(environment).empty(), "deleting the entry is saved");
}

// A reading made of kana only: Core accepts kana in readings, not digits.
std::string KanaNumber(int number) {
    static const char* const digits[] = {"あ", "い", "う", "え", "お", "か", "き", "く", "け", "こ"};
    std::string text;
    do {
        text.insert(0, digits[number % 10]);
        number /= 10;
    } while (number > 0);
    return text;
}

void TestDictionaryImportAndExport(SettingsWindow& window, const Environment& environment, ScriptedDialogs& dialogs) {
    std::vector<Value> entries;
    for (int index = 0; index < kImportedEntries; ++index) {
        entries.push_back(Value::MakeObject({
            {"word", Value::MakeString("試験語" + std::to_string(index))},
            {"reading", Value::MakeString("しけんご" + KanaNumber(index))},
        }));
    }
    std::wstring importPath = environment.root + L"\\import.json";
    WriteBytes(importPath, azookey::json::Serialize(Value::MakeObject({
                               {"format", Value::MakeString("azookey-user-dictionary")},
                               {"version", Value::MakeNumber(1)},
                               {"items", Value::MakeArray(entries)},
                           })));
    dialogs.importSelection = ImportSelection{importPath, "json", "automatic"};
    DictionaryWindow* dictionary = OpenDictionary(window);
    if (!dictionary) return;
    Click(dictionary->importButton());
    PumpUntil([&] { return !window.busy(); }, kStepLimitMilliseconds);
    Check(dialogs.lastPreviewAdditions == kImportedEntries, "the import preview counts every addition");
    Check(dictionary->draft().entries().size() == static_cast<size_t>(kImportedEntries), "accepting the preview fills the draft");
    auto started = std::chrono::steady_clock::now();
    SaveDictionary(window, *dictionary);
    double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    std::printf("saving %d dictionary entries took %.0f ms (the host gives the converter 15000 ms)\n", kImportedEntries, elapsed);
    Check(DictionaryItems(environment).size() == static_cast<size_t>(kImportedEntries), "the imported entries are saved");

    dictionary = OpenDictionary(window);
    if (!dictionary) return;
    Capture(environment, dictionary->window(), L"dictionary");
    std::wstring exportPath = environment.root + L"\\export.json";
    dialogs.exportPath = exportPath;
    Click(dictionary->exportButton());
    PumpUntil([&] { return !window.busy(); }, kStepLimitMilliseconds);
    auto exported = azookey::json::Parse(ReadBytes(exportPath));
    Check(exported && (*exported)["format"].AsString() == "azookey-user-dictionary" &&
              (*exported)["items"].AsArray().size() == static_cast<size_t>(kImportedEntries),
          "export writes every draft entry as azooKey JSON");
    Click(dictionary->cancelButton());
    PumpUntil([&] { return window.dictionaryWindow() == nullptr; }, kStepLimitMilliseconds);
    Check(window.dictionaryWindow() == nullptr, "Cancel closes the editor");
}

void TestADamagedFileIsRecovered(const Environment& environment, ScriptedDialogs& dialogs) {
    const std::string damaged = "{ \"live\": tru";
    WriteBytes(environment.settingsFile, damaged);
    auto window = OpenSettings(environment, dialogs);
    if (!window->form()) return;
    Check(HasStyle(window->recoveryNotice(), WS_VISIBLE) && !WindowText(window->recoveryNotice()).empty(),
          "a damaged file shows the recovery notice");
    Capture(environment, window->window(), L"settings-recovery");
    Click(window->saveButton());
    WaitIdle(*window);
    Check(StatusOf(*window) == Message("settings.recovery_required"), "saving over a damaged file asks for recovery");
    Click(window->recoverButton());
    WaitIdle(*window);
    Check(dialogs.recoveryAsked == 1, "recovery asks first");
    Check(!HasStyle(window->recoveryNotice(), WS_VISIBLE), "the notice disappears after recovery");
    Check(ReadSettingsFile(environment).has_value(), "settings.json is valid again");
    bool kept = false;
    for (const auto& file : std::filesystem::directory_iterator(std::filesystem::path(environment.settingsFile).parent_path())) {
        if (file.path().filename() != L"settings.json" && ReadBytes(file.path().wstring()) == damaged) kept = true;
    }
    Check(kept, "the damaged file is kept under another name");
}

void CaptureEveryPage(SettingsWindow& window, const Environment& environment) {
    if (environment.screenshots.empty()) return;
    for (const char* page : {"input", "conversion", "dictionary", "ai", "support"}) {
        window.SelectPage(page);
        Capture(environment, window.window(), L"settings-" + azookey::text::Utf8ToUtf16(page));
    }
    // Tab moves from the page list into the page.
    SetFocus(window.pageList());
    MSG tab{GetFocus(), WM_KEYDOWN, VK_TAB, 0};
    TranslateDialogKeys(&tab);
    Check(GetFocus() != window.pageList() && IsChild(window.window(), GetFocus()), "Tab moves focus from the page list into the page");
}

void CaptureImportPreview(const Environment& environment, HWND owner) {
    if (environment.screenshots.empty()) return;
    ImportPreview preview;
    preview.additions = 1;
    preview.duplicates = 1;
    preview.excluded = 1;
    preview.notices = {"properNounRegistration"};
    preview.rows = {
        {1, 1, DictionaryEntry{L"", L"大阪城", L"おおさかじょう", L""}, L"固有名詞", "addition", "", {}},
        {2, 2, DictionaryEntry{L"", L"東京", L"とうきょう", L""}, L"地名", "duplicate", "duplicate", {}},
        {3, 3, std::nullopt, L"", "excluded", "invalidColumns", {}},
    };
    ImportPreviewWindow window(owner, preview, kLanguage);
    ShowWindow(window.window(), SW_SHOW);
    Check(IsWindowEnabled(window.applyButton()), "the preview can apply its addition");
    Capture(environment, window.window(), L"dictionary-import-preview");
}

std::optional<Value> Ask(azookey::channel::HostConnection& connection, const std::string& request) {
    auto line = connection.Request(request);
    return line ? azookey::json::Parse(*line) : std::nullopt;
}

// Gives the converter the preferences of a new installation and removes the
// settings file. The converter keeps its preferences outside the settings
// folder, so a run must not depend on what an earlier run left there.
void ResetToNewInstallation(const Environment& environment) {
    azookey::channel::HostConnection connection(BridgeWorker::ConnectionOptions(environment.pipe, L""));
    std::map<std::string, Value> defaults;
    if (auto schema = Ask(connection, SchemaRequest())) {
        for (const auto& item : (*schema)["settingsResult"]["schema"]["items"].AsArray()) {
            defaults[item["key"].AsString()] = item["default"];
        }
    }
    // Only dictionary-save changes the dictionary; settings-save keeps the file's.
    defaults.erase("userDictionary");
    auto loaded = ParseSettingsReply(Ask(connection, LoadRequest()));
    std::string stamp = loaded.file ? loaded.file->stamp : "";
    auto emptied = ParseDictionarySaveReply(Ask(connection, DictionarySaveRequest({}, stamp)));
    if (emptied.settings.file) stamp = emptied.settings.file->stamp;
    auto restored = Ask(connection, SaveRequest(Value::MakeObject(defaults), stamp));
    CheckShowing(emptied.saved && ParseSettingsReply(restored).succeeded(), "the converter starts from the defaults",
                 restored ? azookey::json::Serialize(*restored) : "no reply");
    std::filesystem::path folder = std::filesystem::path(environment.settingsFile).parent_path();
    for (const auto& file : std::filesystem::directory_iterator(folder)) std::filesystem::remove_all(file.path());
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: azookey-settings-ui-test <host exe> <bridge exe> [--screenshots <directory>]\n");
        return 64;
    }
    SetConsoleOutputCP(CP_UTF8);
    Environment environment;
    for (int index = 3; index + 1 < argc; ++index) {
        if (std::wstring(argv[index]) == L"--screenshots") environment.screenshots = argv[index + 1];
    }
    wchar_t temporary[MAX_PATH];
    GetTempPathW(MAX_PATH, temporary);
    std::wstring id = std::to_wstring(GetCurrentProcessId());
    environment.root = std::wstring(temporary) + L"azookey-settings-ui-" + id;
    std::filesystem::create_directories(environment.root + L"\\Roaming\\azooKey Tree");
    std::filesystem::create_directories(environment.root + L"\\Local");
    environment.settingsFile = environment.root + L"\\Roaming\\azooKey Tree\\settings.json";
    environment.dataDirectory = environment.root + L"\\Local";
    environment.pipe = L"\\\\.\\pipe\\azooKeyTree-settings-ui-" + id;
    environment.credential = L"azooKey Tree/settings-ui-test-" + id;
    if (!environment.screenshots.empty()) std::filesystem::create_directories(environment.screenshots);
    // Core keeps settings.json under %APPDATA%; the host and the converter inherit this.
    SetEnvironmentVariableW(L"APPDATA", (environment.root + L"\\Roaming").c_str());
    WriteBytes(environment.root + L"\\build-info.txt", "version=0.0.0\narchitecture=x64\nsource=0123456789abcdef\n");

    std::wstring commandLine = L"\"" + std::wstring(argv[1]) + L"\" --pipe " + environment.pipe + L" --bridge \"" + argv[2] +
                               L"\" --data \"" + environment.dataDirectory + L"\"";
    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION host{};
    if (!CreateProcessW(argv[1], commandLine.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup,
                        &host)) {
        std::printf("FAIL: could not start the host (%lu)\n", GetLastError());
        return 1;
    }
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    INITCOMMONCONTROLSEX controls{sizeof(controls),
                                  ICC_STANDARD_CLASSES | ICC_LISTVIEW_CLASSES | ICC_UPDOWN_CLASS | ICC_LINK_CLASS};
    InitCommonControlsEx(&controls);
    RegisterWindowClasses(GetModuleHandleW(nullptr), nullptr);
    ResetToNewInstallation(environment);
    {
        ScriptedDialogs dialogs;
        auto window = OpenSettings(environment, dialogs);
        if (window->form()) {
            TestPagesFollowTheDefinition(*window);
            TestSettingsWindowsCannotUseAreDisabled(*window);
            CaptureEveryPage(*window, environment);
            TestSavingWritesTheFileAndKeepsTheKeyOut(*window, environment);
            TestCoreRefusalsAreShownWithTheLabel(*window, environment);
            TestAFileChangedElsewhereIsReloaded(*window, environment, dialogs);
            TestLearningCanBeReset(*window, dialogs);
            TestSupportReportIsCopied(*window);
            TestDictionaryAddEditDeleteAndValidation(*window, environment);
            TestDictionaryImportAndExport(*window, environment, dialogs);
            CaptureImportPreview(environment, window->window());
        }
    }
    {
        ScriptedDialogs dialogs;
        TestADamagedFileIsRecovered(environment, dialogs);
    }
    ResetToNewInstallation(environment);
    azookey::credentials::DeleteApiKey(environment.credential);
    TerminateProcess(host.hProcess, 0);
    WaitForSingleObject(host.hProcess, 5000);
    CloseHandle(host.hThread);
    CloseHandle(host.hProcess);
    CoUninitialize();
    std::printf("%s\n", failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}
