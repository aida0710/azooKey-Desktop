// Sends requests to the converter host on a thread of its own, one at a time
// and in order, so the windows keep painting while Core compiles a dictionary.
// Replies come back on the window thread.
#pragma once

#include <windows.h>

#include <condition_variable>
#include <deque>
#include <functional>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include "../shared/host_channel.h"
#include "../shared/json.h"

namespace azookey::settings {

class BridgeWorker {
public:
    // nullopt when the host did not answer or the reply was not JSON.
    using Completion = std::function<void(const std::optional<json::Value>& reply)>;

    struct Options {
        channel::HostConnection::Options connection;
        HWND window = nullptr;  // receives `message` when replies are ready
        UINT message = 0;
    };

    // How the settings screens connect to the host. The host waits up to 15 s
    // for the converter (BridgeProcess) and then answers "converter_unavailable";
    // the screens wait a little longer so they receive that answer.
    static channel::HostConnection::Options ConnectionOptions(std::wstring pipeName, std::wstring hostExecutable);

    explicit BridgeWorker(Options options);
    ~BridgeWorker();  // waits for the request in progress
    BridgeWorker(const BridgeWorker&) = delete;
    BridgeWorker& operator=(const BridgeWorker&) = delete;

    // Window thread only.
    void Send(std::string line, Completion completion);
    // Runs the completions of finished requests. Call when `message` arrives.
    void DeliverReplies();
    // A request is queued, running, or waiting for its completion to run.
    bool busy() const { return outstanding_ > 0; }

private:
    struct Job {
        std::string line;
        Completion completion;
    };
    struct Finished {
        Completion completion;
        std::optional<json::Value> reply;
    };

    void Run();

    Options options_;
    channel::HostConnection connection_;
    std::mutex mutex_;
    std::condition_variable jobArrived_;
    std::deque<Job> jobs_;
    std::deque<Finished> finished_;
    bool stopping_ = false;
    int outstanding_ = 0;  // window thread only
    std::thread thread_;
};

}  // namespace azookey::settings
