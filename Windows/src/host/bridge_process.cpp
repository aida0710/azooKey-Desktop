#include "bridge_process.h"

#include <algorithm>
#include <chrono>
#include <vector>

namespace azookey::host {
namespace {

constexpr DWORD kReadChunkBytes = 64 * 1024;
// Lets the bridge flush learning data after stdin closes before it is killed.
constexpr DWORD kGracefulExitMilliseconds = 3000;

struct EnvironmentVariable {
    std::wstring name;
    std::wstring value;
};

bool IsVariable(const wchar_t* entry, const std::wstring& name) {
    return _wcsnicmp(entry, name.c_str(), name.size()) == 0 && entry[name.size()] == L'=';
}

// Inherits the user's environment with the bridge's own variables replaced.
std::wstring BuildEnvironmentBlock(const std::vector<EnvironmentVariable>& variables) {
    std::wstring block;
    wchar_t* current = GetEnvironmentStringsW();
    for (const wchar_t* entry = current; entry && *entry; entry += wcslen(entry) + 1) {
        bool replaced = std::any_of(variables.begin(), variables.end(),
                                    [entry](const EnvironmentVariable& variable) { return IsVariable(entry, variable.name); });
        if (replaced) continue;
        block.append(entry);
        block.push_back(L'\0');
    }
    if (current) FreeEnvironmentStringsW(current);
    for (const auto& variable : variables) {
        block.append(variable.name + L"=" + variable.value);
        block.push_back(L'\0');
    }
    block.push_back(L'\0');
    return block;
}

}  // namespace

BridgeProcess::BridgeProcess(Options options) : options_(std::move(options)) {}

BridgeProcess::~BridgeProcess() { Stop(); }

void BridgeProcess::Stop() {
    if (input_) {
        CloseHandle(input_);
        input_ = nullptr;
    }
    if (process_) {
        if (WaitForSingleObject(process_, kGracefulExitMilliseconds) != WAIT_OBJECT_0) TerminateProcess(process_, 1);
        CloseHandle(process_);
        process_ = nullptr;
    }
    if (reader_.joinable()) reader_.join();
    if (job_) {
        CloseHandle(job_);
        job_ = nullptr;
    }
    std::lock_guard<std::mutex> lock(mutex_);
    replies_.clear();
    outputClosed_ = true;
}

bool BridgeProcess::EnsureRunning() {
    if (process_ && WaitForSingleObject(process_, 0) == WAIT_TIMEOUT) return true;
    if (process_) {
        Stop();
        ++restarts_;
    }
    SECURITY_ATTRIBUTES inheritable{sizeof(inheritable), nullptr, TRUE};
    HANDLE childInput = nullptr, parentInput = nullptr, parentOutput = nullptr, childOutput = nullptr;
    if (!CreatePipe(&childInput, &parentInput, &inheritable, 0)) return false;
    if (!CreatePipe(&parentOutput, &childOutput, &inheritable, 0)) {
        CloseHandle(childInput);
        CloseHandle(parentInput);
        return false;
    }
    SetHandleInformation(parentInput, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(parentOutput, HANDLE_FLAG_INHERIT, 0);
    HANDLE nullDevice = CreateFileW(L"NUL", GENERIC_WRITE, FILE_SHARE_WRITE, &inheritable, OPEN_EXISTING, 0, nullptr);

    STARTUPINFOEXW startup{};
    startup.StartupInfo.cb = sizeof(startup);
    startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = childInput;
    startup.StartupInfo.hStdOutput = childOutput;
    startup.StartupInfo.hStdError = nullDevice;
    // Only the three standard handles reach the bridge, not every inheritable
    // handle the host happens to hold (client pipes).
    SIZE_T attributeSize = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attributeSize);
    std::vector<BYTE> attributes(attributeSize);
    startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributes.data());
    InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributeSize);
    HANDLE inherited[] = {childInput, childOutput, nullDevice};
    UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited,
                              sizeof(inherited), nullptr, nullptr);

    std::wstring environment = BuildEnvironmentBlock({{L"AZOOKEY_DATA_DIR", options_.dataDirectory},
                                                      {L"AZOOKEY_RESOURCES", options_.resourcesDirectory}});
    std::wstring commandLine = L"\"" + options_.executable + L"\"";
    PROCESS_INFORMATION info{};
    BOOL created = CreateProcessW(options_.executable.c_str(), commandLine.data(), nullptr, nullptr, TRUE,
                                  CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT |
                                      CREATE_SUSPENDED,
                                  environment.data(), nullptr, &startup.StartupInfo, &info);
    DeleteProcThreadAttributeList(startup.lpAttributeList);
    CloseHandle(childInput);
    CloseHandle(childOutput);
    if (nullDevice != INVALID_HANDLE_VALUE) CloseHandle(nullDevice);
    if (!created) {
        CloseHandle(parentInput);
        CloseHandle(parentOutput);
        return false;
    }
    // The bridge must not outlive the host, even when the host is killed.
    job_ = CreateJobObjectW(nullptr, nullptr);
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(job_, JobObjectExtendedLimitInformation, &limits, sizeof(limits));
    AssignProcessToJobObject(job_, info.hProcess);
    ResumeThread(info.hThread);
    CloseHandle(info.hThread);
    process_ = info.hProcess;
    input_ = parentInput;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        replies_.clear();
        outputClosed_ = false;
    }
    reader_ = std::thread([this, parentOutput] { ReadReplies(parentOutput); });
    return true;
}

void BridgeProcess::ReadReplies(HANDLE output) {
    std::string pending;
    std::vector<char> chunk(kReadChunkBytes);
    for (;;) {
        DWORD read = 0;
        if (!ReadFile(output, chunk.data(), static_cast<DWORD>(chunk.size()), &read, nullptr) || read == 0) break;
        pending.append(chunk.data(), read);
        size_t newline;
        while ((newline = pending.find('\n')) != std::string::npos) {
            std::lock_guard<std::mutex> lock(mutex_);
            replies_.push_back(pending.substr(0, newline));
            pending.erase(0, newline + 1);
            replyArrived_.notify_all();
        }
    }
    CloseHandle(output);
    std::lock_guard<std::mutex> lock(mutex_);
    outputClosed_ = true;
    replyArrived_.notify_all();
}

std::optional<std::string> BridgeProcess::Request(const std::string& line) {
    if (!EnsureRunning()) return std::nullopt;
    std::string bytes = line + "\n";
    DWORD written = 0;
    if (!WriteFile(input_, bytes.data(), static_cast<DWORD>(bytes.size()), &written, nullptr) || written != bytes.size()) {
        Stop();
        ++restarts_;
        return std::nullopt;
    }
    std::unique_lock<std::mutex> lock(mutex_);
    bool ready = replyArrived_.wait_for(lock, std::chrono::milliseconds(options_.replyTimeoutMilliseconds),
                                        [this] { return !replies_.empty() || outputClosed_; });
    if (ready && !replies_.empty()) {
        std::string reply = std::move(replies_.front());
        replies_.pop_front();
        return reply;
    }
    lock.unlock();
    // A hung or crashed bridge is replaced; its pending reply is discarded so
    // replies never shift onto the following request.
    Stop();
    ++restarts_;
    return std::nullopt;
}

}  // namespace azookey::host
