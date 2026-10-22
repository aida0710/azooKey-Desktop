// The per-user named pipe between the text service (loaded into every
// application) and azookey-windows-host.exe, which owns the single converter.
// Messages are the bridge's newline-delimited JSON lines, forwarded unchanged.
#pragma once

#include <windows.h>

#include <optional>
#include <string>

namespace azookey::channel {

// \\.\pipe\azooKeyTree-<user SID>: other users on the same machine get their own host.
std::wstring HostPipeName();

// Reads one '\n'-terminated line from an overlapped handle. Bytes after the
// newline stay in `pending` for the next call.
class LineReader {
public:
    // Returns nullopt on timeout, disconnect or a line longer than the limit.
    std::optional<std::string> ReadLine(HANDLE handle, DWORD timeoutMilliseconds);
    void Clear() { pending_.clear(); }

private:
    std::string pending_;
};

// Writes all bytes to an overlapped handle within the timeout.
bool WriteAll(HANDLE handle, const std::string& bytes, DWORD timeoutMilliseconds);

// Client side used by the text service and the tests.
class HostConnection {
public:
    struct Options {
        std::wstring pipeName = HostPipeName();
        std::wstring hostExecutable;  // started when the pipe is missing; empty disables
        DWORD connectTimeoutMilliseconds = 3000;
        DWORD requestTimeoutMilliseconds = 2000;
    };

    explicit HostConnection(Options options);
    ~HostConnection();
    HostConnection(const HostConnection&) = delete;
    HostConnection& operator=(const HostConnection&) = delete;

    // Sends one request line (without newline) and waits for the reply line.
    // Any failure drops the connection so a late reply can never be read as
    // the answer to the next request.
    std::optional<std::string> Request(const std::string& line);
    void Disconnect();
    bool connected() const { return pipe_ != INVALID_HANDLE_VALUE; }
    // The host process at the other end; nullopt while not connected.
    std::optional<DWORD> HostProcessId() const;

private:
    bool Connect();
    bool StartHost();

    Options options_;
    HANDLE pipe_ = INVALID_HANDLE_VALUE;
    LineReader reader_;
};

}  // namespace azookey::channel
