// Starts azookey-windows-host.exe on a private pipe and converts through it the
// way the text service does. Needs the built bridge; no desktop session.
//
//   azookey-host-integration-test.exe <host exe> <bridge exe> [--expect-zenzai]
//
// The host gives the bridge the models folder next to itself. --expect-zenzai
// requires Zenzai to load that model; without it the Zenzai check is reported
// as not run, never as passed.
#include <windows.h>

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <string>
#include <vector>

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

double Median(std::vector<double> values) {
    std::sort(values.begin(), values.end());
    return values.empty() ? 0 : values[values.size() / 2];
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    bool expectZenzai = argc == 4 && std::wstring(argv[3]) == L"--expect-zenzai";
    if (argc != 3 && !expectZenzai) {
        std::fprintf(stderr, "usage: azookey-host-integration-test <host exe> <bridge exe> [--expect-zenzai]\n");
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
    std::vector<double> keyMilliseconds;
    for (wchar_t c : std::wstring(L"nihongo")) {
        auto event = azookey::keys::Translate(towupper(c), {}, std::wstring(1, c));
        auto started = std::chrono::steady_clock::now();
        auto reply = connection.Request(azookey::protocol::KeyRequest(context, event));
        keyMilliseconds.push_back(
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count());
        last = reply ? azookey::protocol::ParseSnapshot(*reply) : std::nullopt;
        if (!last) break;
    }
    Check(last && last->preedit == L"日本語", "typing nihongo composes 日本語");
    // The first key also starts the bridge and loads the dictionary (and the
    // first conversion Zenzai's model), so it is reported on its own. The loop
    // always times at least that key.
    std::vector<double> laterKeys(keyMilliseconds.begin() + 1, keyMilliseconds.end());
    std::printf("first key: %.1f ms; later keys: median %.1f ms, slowest %.1f ms\n", keyMilliseconds.front(),
                Median(laterKeys), laterKeys.empty() ? 0 : *std::max_element(laterKeys.begin(), laterKeys.end()));

    auto space = connection.Request(azookey::protocol::KeyRequest(context, azookey::keys::Translate(0x20, {}, L" ")));
    auto converting = space ? azookey::protocol::ParseSnapshot(*space) : std::nullopt;
    Check(converting && converting->selection.has_value() && !converting->candidates.empty(), "Space opens candidates");
    bool zenzaiLoaded = converting && converting->zenzaiLoaded;
    if (expectZenzai) {
        Check(zenzaiLoaded, "Zenzai converts with the model next to the host");
    } else {
        std::printf("NOT RUN: Zenzai (zenzaiLoaded=%s; pass --expect-zenzai with a package that has "
                    "models\\ggml-model-Q5_K_M.gguf)\n",
                    zenzaiLoaded ? "true" : "false");
    }

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
    std::printf("%s%s\n", failures == 0 ? "PASS" : "FAIL", expectZenzai ? "" : " (Zenzai not run)");
    return failures == 0 ? 0 : 1;
}
