// Starts azookey-windows-host.exe on a private pipe with its own settings
// folder, changes settings.json the way the settings window or a user would,
// and checks that the next conversion follows the file: with live conversion
// off the text being typed stays in kana.
//
//   azookey-settings-reload-test.exe <host exe> <bridge exe>
#include <windows.h>

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>

#include "../src/shared/bridge_protocol.h"
#include "../src/shared/host_channel.h"
#include "../src/shared/json.h"
#include "../src/shared/key_translation.h"
#include "../src/shared/text_encoding.h"

namespace {

using azookey::channel::HostConnection;
using azookey::protocol::RequestContext;

int failures = 0;

void Check(bool condition, const char* description) {
    if (!condition) ++failures;
    std::printf("%s: %s\n", condition ? "ok" : "FAIL", description);
}

std::wstring CreateDirectoryUnder(const std::wstring& parent, const std::wstring& name) {
    std::wstring directory = parent + L"\\" + name;
    CreateDirectoryW(directory.c_str(), nullptr);
    return directory;
}

void WriteText(const std::wstring& path, const std::string& text) {
    std::ofstream file(path, std::ios::binary | std::ios::trunc);
    file << text;
}

// Types `romaji` as new text and returns the preedit after the last key.
std::wstring Type(HostConnection& connection, const RequestContext& context, const std::wstring& romaji) {
    std::optional<azookey::protocol::Snapshot> last;
    for (wchar_t character : romaji) {
        auto event = azookey::keys::Translate(towupper(character), {}, std::wstring(1, character));
        auto reply = connection.Request(azookey::protocol::KeyRequest(context, event));
        last = reply ? azookey::protocol::ParseSnapshot(*reply) : std::nullopt;
        if (!last) return L"(no reply)";
    }
    return last ? last->preedit : L"";
}

void Cancel(HostConnection& connection, const RequestContext& context) {
    connection.Request(azookey::protocol::ResetRequest(context, false));
}

bool LiveConversionSetting(HostConnection& connection) {
    auto reply = connection.Request(azookey::protocol::SettingsRequest("reload-test"));
    auto parsed = reply ? azookey::json::Parse(*reply) : std::nullopt;
    return parsed && (*parsed)["settings"]["live"].AsBoolean(true);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: azookey-settings-reload-test <host exe> <bridge exe>\n");
        return 64;
    }
    SetConsoleOutputCP(CP_UTF8);
    wchar_t temporary[MAX_PATH];
    GetTempPathW(MAX_PATH, temporary);
    std::wstring root = CreateDirectoryUnder(temporary, L"azookey-settings-reload-" + std::to_wstring(GetCurrentProcessId()));
    std::wstring roaming = CreateDirectoryUnder(root, L"Roaming");
    std::wstring data = CreateDirectoryUnder(root, L"Local");
    std::wstring settingsFile = CreateDirectoryUnder(roaming, L"azooKey Tree") + L"\\settings.json";
    // Core puts the settings file under %APPDATA%; the host and the converter inherit this.
    SetEnvironmentVariableW(L"APPDATA", roaming.c_str());

    std::wstring pipe = L"\\\\.\\pipe\\azooKeyTree-reload-test-" + std::to_wstring(GetCurrentProcessId());
    std::wstring commandLine = L"\"" + std::wstring(argv[1]) + L"\" --pipe " + pipe + L" --bridge \"" + argv[2] +
                               L"\" --data \"" + data + L"\"";
    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION host{};
    if (!CreateProcessW(argv[1], commandLine.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup,
                        &host)) {
        std::printf("FAIL: could not start the host (%lu)\n", GetLastError());
        return 1;
    }

    HostConnection::Options options;
    options.pipeName = pipe;
    // The first request starts the converter, which loads the dictionary.
    options.requestTimeoutMilliseconds = 20000;
    HostConnection connection(options);
    RequestContext context{"reload-test", {}};

    // The converter keeps its preferences outside the settings folder, so the
    // first file sets live conversion explicitly instead of relying on a default.
    WriteText(settingsFile, "{\"live\": true}\n");
    Check(Type(connection, context, L"nihongo") == L"日本語", "with live conversion on in settings.json the preedit shows 日本語");
    Cancel(connection, context);

    WriteText(settingsFile, "{\"live\": false}\n");
    Check(Type(connection, context, L"nihongo") == L"にほんご", "after settings.json turns live conversion off the preedit stays kana");
    Check(!LiveConversionSetting(connection), "the converter reports live conversion as off");
    Cancel(connection, context);

    WriteText(settingsFile, "{\"live\": true, \"punctuation\": 1}\n");
    Check(Type(connection, context, L"nihongo") == L"日本語", "turning it back on in the file converts while typing again");
    Check(LiveConversionSetting(connection), "the converter reports live conversion as on");
    Cancel(connection, context);

    connection.Disconnect();
    TerminateProcess(host.hProcess, 0);
    WaitForSingleObject(host.hProcess, 5000);
    CloseHandle(host.hThread);
    CloseHandle(host.hProcess);
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
    std::printf("%s\n", failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}
