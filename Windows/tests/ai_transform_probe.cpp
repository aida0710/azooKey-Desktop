// Stands in for azookey-ai-transform.exe in azookey-ai-host-test: it records
// the command line the host gave it, claims the held transformation with its
// token, and tries the same token again. The lines go to %AZOOKEY_PROBE_OUTPUT%.
#include <windows.h>
#include <shellapi.h>

#include <fstream>
#include <string>

#include "../src/shared/host_channel.h"
#include "../src/shared/text_encoding.h"

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    wchar_t output[MAX_PATH] = {};
    if (!GetEnvironmentVariableW(L"AZOOKEY_PROBE_OUTPUT", output, MAX_PATH)) return 64;
    int count = 0;
    wchar_t** arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    std::wstring token;
    std::wstring pipe;
    for (int index = 1; arguments && index + 1 < count; ++index) {
        if (std::wstring(arguments[index]) == L"--token") token = arguments[index + 1];
        if (std::wstring(arguments[index]) == L"--pipe") pipe = arguments[index + 1];
    }
    LocalFree(arguments);
    azookey::channel::HostConnection::Options options;
    options.pipeName = pipe;
    azookey::channel::HostConnection host(options);
    std::string take = "{\"operation\":\"host-take-ai-transform\",\"token\":\"" + azookey::text::Utf16ToUtf8(token) + "\"}";
    std::string first = host.Request(take).value_or("(no reply)");
    std::string second = host.Request(take).value_or("(no reply)");
    // Written to a temporary name and renamed, so the test never reads half a file.
    std::wstring partial = std::wstring(output) + L".partial";
    {
        std::ofstream file(partial, std::ios::binary | std::ios::trunc);
        file << azookey::text::Utf16ToUtf8(GetCommandLineW()) << "\n" << first << "\n" << second << "\n";
    }
    MoveFileExW(partial.c_str(), output, MOVEFILE_REPLACE_EXISTING);
    return 0;
}
