#include "host_channel.h"

#include <sddl.h>

#include <memory>
#include <vector>

namespace azookey::channel {
namespace {

// Snapshots carry at most a few hundred candidates; anything larger is a
// broken stream, not a reply.
constexpr size_t kMaximumLineBytes = 8 * 1024 * 1024;
constexpr DWORD kReadChunkBytes = 64 * 1024;
// How often the client re-checks for the pipe while a freshly started host
// is still creating it.
constexpr DWORD kConnectRetryMilliseconds = 50;

struct EventHandle {
    HANDLE handle = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    ~EventHandle() { if (handle) CloseHandle(handle); }
};

// Waits for an overlapped operation; cancels it on timeout so the buffer is
// not written after we return.
bool FinishOverlapped(HANDLE handle, OVERLAPPED* overlapped, DWORD timeoutMilliseconds, DWORD* transferred) {
    DWORD wait = WaitForSingleObject(overlapped->hEvent, timeoutMilliseconds);
    if (wait != WAIT_OBJECT_0) {
        CancelIoEx(handle, overlapped);
        GetOverlappedResult(handle, overlapped, transferred, TRUE);
        return false;
    }
    return GetOverlappedResult(handle, overlapped, transferred, FALSE) != FALSE;
}

}  // namespace

std::wstring HostPipeName() {
    std::wstring name = L"\\\\.\\pipe\\azooKeyTree-";
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return name + L"unknown";
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    std::vector<BYTE> buffer(size);
    wchar_t* sidText = nullptr;
    if (size > 0 && GetTokenInformation(token, TokenUser, buffer.data(), size, &size) &&
        ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(buffer.data())->User.Sid, &sidText)) {
        name += sidText;
        LocalFree(sidText);
    } else {
        name += L"unknown";
    }
    CloseHandle(token);
    return name;
}

std::optional<std::string> LineReader::ReadLine(HANDLE handle, DWORD timeoutMilliseconds) {
    ULONGLONG deadline = GetTickCount64() + timeoutMilliseconds;
    EventHandle event;
    std::vector<char> chunk(kReadChunkBytes);
    for (;;) {
        size_t newline = pending_.find('\n');
        if (newline != std::string::npos) {
            std::string line = pending_.substr(0, newline);
            pending_.erase(0, newline + 1);
            return line;
        }
        if (pending_.size() > kMaximumLineBytes) return std::nullopt;
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) return std::nullopt;
        OVERLAPPED overlapped{};
        overlapped.hEvent = event.handle;
        ResetEvent(event.handle);
        DWORD read = 0;
        if (!ReadFile(handle, chunk.data(), static_cast<DWORD>(chunk.size()), &read, &overlapped)) {
            DWORD error = GetLastError();
            if (error != ERROR_IO_PENDING && error != ERROR_MORE_DATA) return std::nullopt;
            if (error == ERROR_IO_PENDING &&
                !FinishOverlapped(handle, &overlapped, static_cast<DWORD>(deadline - now), &read)) {
                if (GetLastError() != ERROR_MORE_DATA) return std::nullopt;
            }
        }
        if (read == 0) return std::nullopt;
        pending_.append(chunk.data(), read);
    }
}

bool WriteAll(HANDLE handle, const std::string& bytes, DWORD timeoutMilliseconds) {
    EventHandle event;
    size_t offset = 0;
    ULONGLONG deadline = GetTickCount64() + timeoutMilliseconds;
    while (offset < bytes.size()) {
        ULONGLONG now = GetTickCount64();
        if (now >= deadline) return false;
        OVERLAPPED overlapped{};
        overlapped.hEvent = event.handle;
        ResetEvent(event.handle);
        DWORD written = 0;
        DWORD length = static_cast<DWORD>(bytes.size() - offset);
        if (!WriteFile(handle, bytes.data() + offset, length, &written, &overlapped)) {
            if (GetLastError() != ERROR_IO_PENDING) return false;
            if (!FinishOverlapped(handle, &overlapped, static_cast<DWORD>(deadline - now), &written)) return false;
        }
        if (written == 0) return false;
        offset += written;
    }
    return true;
}

HostConnection::HostConnection(Options options) : options_(std::move(options)) {}

HostConnection::~HostConnection() { Disconnect(); }

void HostConnection::Disconnect() {
    if (pipe_ != INVALID_HANDLE_VALUE) {
        CloseHandle(pipe_);
        pipe_ = INVALID_HANDLE_VALUE;
    }
    reader_.Clear();
}

bool HostConnection::StartHost() {
    if (options_.hostExecutable.empty()) return false;
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    PROCESS_INFORMATION process{};
    std::wstring commandLine = L"\"" + options_.hostExecutable + L"\"";
    // AppContainer processes cannot create processes; they rely on the host
    // started at sign-in or by another application.
    if (!CreateProcessW(options_.hostExecutable.c_str(), commandLine.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW | DETACHED_PROCESS, nullptr, nullptr, &startup, &process)) {
        return false;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return true;
}

bool HostConnection::Connect() {
    ULONGLONG deadline = GetTickCount64() + options_.connectTimeoutMilliseconds;
    bool startedHost = false;
    for (;;) {
        pipe_ = CreateFileW(options_.pipeName.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                            FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
        if (pipe_ != INVALID_HANDLE_VALUE) return true;
        DWORD error = GetLastError();
        if (GetTickCount64() >= deadline) return false;
        if (error == ERROR_PIPE_BUSY) {
            WaitNamedPipeW(options_.pipeName.c_str(), kConnectRetryMilliseconds);
            continue;
        }
        // Without a host executable (tests, AppContainer callers) the pipe may
        // still appear: someone else is starting the host.
        if (error == ERROR_FILE_NOT_FOUND && !startedHost && !options_.hostExecutable.empty()) {
            startedHost = true;
            if (!StartHost()) return false;
        }
        Sleep(kConnectRetryMilliseconds);
    }
}

std::optional<std::string> HostConnection::Request(const std::string& line) {
    if (pipe_ == INVALID_HANDLE_VALUE && !Connect()) return std::nullopt;
    if (!WriteAll(pipe_, line + "\n", options_.requestTimeoutMilliseconds)) {
        Disconnect();
        return std::nullopt;
    }
    auto reply = reader_.ReadLine(pipe_, options_.requestTimeoutMilliseconds);
    if (!reply) Disconnect();
    return reply;
}

}  // namespace azookey::channel
