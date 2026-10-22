// Owns the azookey-desktop-bridge child process: starts it on demand, sends one
// request line at a time and restarts it after a crash or a hang.
#pragma once

#include <windows.h>

#include <condition_variable>
#include <deque>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

namespace azookey::host {

class BridgeProcess {
public:
    struct Options {
        std::wstring executable;
        std::wstring dataDirectory;
        // Holds Zenzai's model (AZOOKEY_RESOURCES). Without the model there the
        // bridge converts with the dictionary alone.
        std::wstring resourcesDirectory;
        // A conversion normally answers in milliseconds; the first request also
        // loads the dictionary, and the first conversion Zenzai's model. Past
        // this the bridge is treated as hung.
        DWORD replyTimeoutMilliseconds = 15000;
    };

    explicit BridgeProcess(Options options);
    ~BridgeProcess();
    BridgeProcess(const BridgeProcess&) = delete;
    BridgeProcess& operator=(const BridgeProcess&) = delete;

    // Not thread-safe; the host serializes callers.
    std::optional<std::string> Request(const std::string& line);
    unsigned restarts() const { return restarts_; }

private:
    bool EnsureRunning();
    void Stop();
    void ReadReplies(HANDLE output);

    Options options_;
    HANDLE job_ = nullptr;
    HANDLE process_ = nullptr;
    HANDLE input_ = nullptr;
    std::thread reader_;
    std::mutex mutex_;
    std::condition_variable replyArrived_;
    std::deque<std::string> replies_;
    bool outputClosed_ = true;
    unsigned restarts_ = 0;
};

}  // namespace azookey::host
