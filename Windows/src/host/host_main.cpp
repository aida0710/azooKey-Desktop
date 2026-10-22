// azookey-windows-host.exe: one per signed-in user. Text services in every
// application connect over a named pipe; the host forwards their requests to a
// single converter so the dictionary and learning data load once.
//
// Options (for tests): --pipe <name> --bridge <exe> --data <directory> --resources <directory>
//                      --api-key-credential <target> --ai-transform-window <exe>
#include <windows.h>
#include <sddl.h>
#include <shellapi.h>
#include <shlobj.h>

#include <atomic>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <thread>

#include "../shared/api_key_credential.h"
#include "../shared/data_directory.h"
#include "../shared/host_channel.h"
#include "../shared/json.h"
#include "ai_service.h"
#include "ai_transform_handoff.h"
#include "bridge_process.h"
#include "request_route.h"
#include "settings_reload.h"

namespace {

using azookey::host::AIService;
using azookey::host::AITransformHandoff;
using azookey::host::BridgeProcess;
using azookey::host::RequestRoute;
using azookey::host::SettingsReload;

constexpr DWORD kPipeBufferBytes = 64 * 1024;
// Idle clients keep their connection; this only bounds a single reply write.
constexpr DWORD kClientWriteTimeoutMilliseconds = 5000;
// The text service waits for replies itself; the host never gives up on a
// client between requests.
constexpr DWORD kClientReadTimeoutMilliseconds = INFINITE;
// Sent when the converter could not answer, so the client recovers its
// composition instead of waiting.
constexpr char kUnavailableReply[] = "{\"consumed\":false,\"error\":\"converter_unavailable\"}";

struct Options {
    std::wstring pipeName = azookey::channel::HostPipeName();
    std::wstring bridge;
    std::wstring dataDirectory;
    std::wstring resourcesDirectory;
    std::wstring apiKeyCredential = azookey::credentials::kApiKeyTarget;
    std::wstring aiTransformWindow;
};

std::wstring ModuleDirectory() {
    wchar_t path[MAX_PATH];
    DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring directory(path, length);
    return directory.substr(0, directory.find_last_of(L'\\'));
}

Options ParseOptions() {
    Options options;
    options.bridge = ModuleDirectory() + L"\\bridge\\azookey-desktop-bridge.exe";
    options.dataDirectory = azookey::storage::DefaultDataDirectory();
    options.resourcesDirectory = ModuleDirectory() + L"\\models";
    options.aiTransformWindow = ModuleDirectory() + L"\\azookey-ai-transform.exe";
    int count = 0;
    wchar_t** arguments = CommandLineToArgvW(GetCommandLineW(), &count);
    for (int i = 1; arguments && i + 1 < count; i += 2) {
        std::wstring name = arguments[i];
        if (name == L"--pipe") options.pipeName = arguments[i + 1];
        else if (name == L"--bridge") options.bridge = arguments[i + 1];
        else if (name == L"--data") options.dataDirectory = arguments[i + 1];
        else if (name == L"--resources") options.resourcesDirectory = arguments[i + 1];
        else if (name == L"--api-key-credential") options.apiKeyCredential = arguments[i + 1];
        else if (name == L"--ai-transform-window") options.aiTransformWindow = arguments[i + 1];
    }
    LocalFree(arguments);
    return options;
}

// Only the signed-in user and the system may open the pipe, plus AppContainer
// (Store) applications of that user, which run the text service at low integrity.
bool CreatePipeSecurity(SECURITY_ATTRIBUTES* attributes, PSECURITY_DESCRIPTOR* descriptor) {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return false;
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    auto buffer = std::make_unique<BYTE[]>(size);
    wchar_t* userSid = nullptr;
    bool ok = GetTokenInformation(token, TokenUser, buffer.get(), size, &size) &&
              ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.get())->User.Sid, &userSid);
    CloseHandle(token);
    if (!ok) return false;
    std::wstring sddl = L"D:P(A;;GA;;;SY)(A;;GA;;;" + std::wstring(userSid) + L")(A;;GRGW;;;AC)S:(ML;;NW;;;LW)";
    LocalFree(userSid);
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, descriptor, nullptr)) {
        return false;
    }
    attributes->nLength = sizeof(*attributes);
    attributes->lpSecurityDescriptor = *descriptor;
    attributes->bInheritHandle = FALSE;
    return true;
}

class Host {
public:
    explicit Host(const Options& options)
        : options_(options),
          bridge_({options.bridge, options.dataDirectory, options.resourcesDirectory}),
          aiService_({options.bridge, options.dataDirectory + L"\\ai", options.apiKeyCredential}),
          aiTransformHandoff_({options.aiTransformWindow, options.pipeName}) {}

    int Run() {
        SECURITY_ATTRIBUTES security{};
        PSECURITY_DESCRIPTOR descriptor = nullptr;
        if (!CreatePipeSecurity(&security, &descriptor)) return 2;
        bool first = true;
        for (;;) {
            DWORD openMode = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | (first ? FILE_FLAG_FIRST_PIPE_INSTANCE : 0);
            HANDLE pipe = CreateNamedPipeW(options_.pipeName.c_str(), openMode,
                                           PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                           PIPE_UNLIMITED_INSTANCES, kPipeBufferBytes, kPipeBufferBytes, 0, &security);
            if (pipe == INVALID_HANDLE_VALUE) {
                // Another host already serves this user: exit quietly.
                LocalFree(descriptor);
                return first ? 0 : 3;
            }
            first = false;
            if (!WaitForClient(pipe)) {
                CloseHandle(pipe);
                continue;
            }
            std::thread([this, pipe] { ServeClient(pipe); }).detach();
        }
    }

private:
    static bool WaitForClient(HANDLE pipe) {
        OVERLAPPED overlapped{};
        overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        BOOL connected = ConnectNamedPipe(pipe, &overlapped);
        DWORD error = GetLastError();
        bool ok = connected || error == ERROR_PIPE_CONNECTED;
        if (!ok && error == ERROR_IO_PENDING) {
            DWORD ignored = 0;
            ok = GetOverlappedResult(pipe, &overlapped, &ignored, TRUE) != FALSE;
        }
        CloseHandle(overlapped.hEvent);
        return ok;
    }

    void ServeClient(HANDLE pipe) {
        azookey::channel::LineReader reader;
        std::set<std::string> contexts;
        for (;;) {
            auto line = reader.ReadLine(pipe, kClientReadTimeoutMilliseconds);
            if (!line) break;
            // A line that is not JSON goes to the converter, which answers invalid_request.
            auto request = azookey::json::Parse(*line);
            std::string reply;
            switch (request ? azookey::host::RouteFor(*request) : RequestRoute::Conversion) {
            case RequestRoute::Conversion:
                if (request && azookey::host::OwnsContext(*request)) contexts.insert((*request)["context"].AsString());
                reply = Convert(*line);
                break;
            case RequestRoute::AIService:
                reply = aiService_.Handle(*request);
                break;
            case RequestRoute::OpenAITransformWindow:
                reply = aiTransformHandoff_.Open(*request);
                break;
            case RequestRoute::TakeAITransform:
                reply = aiTransformHandoff_.Take(*request);
                break;
            }
            if (!azookey::channel::WriteAll(pipe, reply + "\n", kClientWriteTimeoutMilliseconds)) break;
        }
        // An application that exits without deactivating the text service
        // must not leave its compositions in the converter.
        std::lock_guard<std::mutex> lock(bridgeMutex_);
        for (const auto& context : contexts) {
            bridge_.Request("{\"operation\":\"close\",\"context\":" + azookey::json::Quote(context) + "}");
        }
        DisconnectNamedPipe(pipe);
        CloseHandle(pipe);
    }

    std::string Convert(const std::string& line) {
        std::lock_guard<std::mutex> lock(bridgeMutex_);
        settingsReload_.BeforeRequest([this](const std::string& request) { return bridge_.Request(request); },
                                      bridge_.restarts());
        return bridge_.Request(line).value_or(kUnavailableReply);
    }

    Options options_;
    std::mutex bridgeMutex_;
    BridgeProcess bridge_;
    SettingsReload settingsReload_;  // guarded by bridgeMutex_
    AIService aiService_;
    AITransformHandoff aiTransformHandoff_;
};

}  // namespace

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    Options options = ParseOptions();
    if (!options.dataDirectory.empty()) SHCreateDirectoryExW(nullptr, options.dataDirectory.c_str(), nullptr);
    Host host(options);
    return host.Run();
}
