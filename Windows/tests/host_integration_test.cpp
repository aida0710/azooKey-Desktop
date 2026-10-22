// Starts azookey-windows-host.exe on a private pipe and converts through it the
// way the text service does. Needs the built bridge; no desktop session.
//
//   azookey-host-integration-test.exe <host exe> <bridge exe>
#include <windows.h>

#include <chrono>
#include <cstdio>
#include <string>

#include "../src/shared/bridge_protocol.h"
#include "../src/shared/host_channel.h"
#include "../src/shared/key_translation.h"
#include "../src/shared/text_encoding.h"

namespace {

int failures = 0;

void Check(bool condition, const char* description) {
    if (!condition) {
        ++failures;
        std::printf("FAIL: %s\n", description);
    } else {
        std::printf("ok: %s\n", description);
    }
}

std::wstring TemporaryDirectory(const std::wstring& name) {
    wchar_t base[MAX_PATH];
    GetTempPathW(MAX_PATH, base);
    std::wstring directory = std::wstring(base) + name;
    CreateDirectoryW(directory.c_str(), nullptr);
    return directory;
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 3) {
        std::fprintf(stderr, "usage: azookey-host-integration-test <host exe> <bridge exe>\n");
        return 64;
    }
    std::wstring pipe = L"\\\\.\\pipe\\azooKeyTree-test-" + std::to_wstring(GetCurrentProcessId());
    std::wstring data = TemporaryDirectory(L"azookey-host-test-" + std::to_wstring(GetCurrentProcessId()));
    std::wstring commandLine = L"\"" + std::wstring(argv[1]) + L"\" --pipe " + pipe + L" --bridge \"" + argv[2] +
                               L"\" --data \"" + data + L"\"";
    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION host{};
    if (!CreateProcessW(argv[1], commandLine.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr,
                        &startup, &host)) {
        std::printf("FAIL: could not start the host (%lu)\n", GetLastError());
        return 1;
    }

    azookey::channel::HostConnection::Options options;
    options.pipeName = pipe;
    // The first request loads the dictionary.
    options.requestTimeoutMilliseconds = 15000;
    azookey::channel::HostConnection connection(options);
    azookey::protocol::RequestContext context{"integration", L"", false};

    std::optional<azookey::protocol::Snapshot> last;
    double slowestMilliseconds = 0;
    for (wchar_t c : std::wstring(L"nihongo")) {
        auto event = azookey::keys::Translate(towupper(c), {}, std::wstring(1, c));
        auto started = std::chrono::steady_clock::now();
        auto reply = connection.Request(azookey::protocol::KeyRequest(context, event));
        double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
        if (c != L'n' || last) slowestMilliseconds = std::max(slowestMilliseconds, elapsed);
        last = reply ? azookey::protocol::ParseSnapshot(*reply) : std::nullopt;
        if (!last) break;
    }
    Check(last && last->preedit == L"日本語", "typing nihongo composes 日本語");
    std::printf("slowest key after the first: %.1f ms\n", slowestMilliseconds);

    auto space = connection.Request(azookey::protocol::KeyRequest(context, azookey::keys::Translate(0x20, {}, L" ")));
    auto converting = space ? azookey::protocol::ParseSnapshot(*space) : std::nullopt;
    Check(converting && converting->selection.has_value() && !converting->candidates.empty(), "Space opens candidates");

    // A second client (another application) gets its own composition.
    azookey::channel::HostConnection other(options);
    auto otherReply = other.Request(azookey::protocol::KeyRequest({"other", L"", false},
                                                                  azookey::keys::Translate('K', {}, L"k")));
    auto otherSnapshot = otherReply ? azookey::protocol::ParseSnapshot(*otherReply) : std::nullopt;
    Check(otherSnapshot && otherSnapshot->preedit == L"k", "a second application composes independently");

    auto enter = connection.Request(azookey::protocol::KeyRequest(context, azookey::keys::Translate(0x0D, {}, L"")));
    auto committed = enter ? azookey::protocol::ParseSnapshot(*enter) : std::nullopt;
    Check(committed && committed->commits.size() == 1 && committed->commits[0] == L"日本語" && committed->preedit.empty(),
          "Enter commits 日本語 and clears the preedit");

    connection.Disconnect();
    other.Disconnect();
    TerminateProcess(host.hProcess, 0);
    WaitForSingleObject(host.hProcess, 5000);
    CloseHandle(host.hThread);
    CloseHandle(host.hProcess);
    std::printf("%s\n", failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}
