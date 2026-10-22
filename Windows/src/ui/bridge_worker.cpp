#include "bridge_worker.h"

#include <utility>

namespace azookey::ui {
namespace {

constexpr DWORD kRequestTimeoutMilliseconds = 20000;
// A host started by the screen creates its pipe at once; this bounds a host that fails to start.
constexpr DWORD kConnectTimeoutMilliseconds = 5000;

}  // namespace

channel::HostConnection::Options BridgeWorker::ConnectionOptions(std::wstring pipeName, std::wstring hostExecutable) {
    channel::HostConnection::Options options;
    options.pipeName = std::move(pipeName);
    options.hostExecutable = std::move(hostExecutable);
    options.connectTimeoutMilliseconds = kConnectTimeoutMilliseconds;
    options.requestTimeoutMilliseconds = kRequestTimeoutMilliseconds;
    return options;
}

BridgeWorker::BridgeWorker(Options options)
    : options_(std::move(options)), connection_(options_.connection), thread_([this] { Run(); }) {}

BridgeWorker::~BridgeWorker() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
        jobs_.clear();
    }
    jobArrived_.notify_all();
    thread_.join();
}

void BridgeWorker::Send(std::string line, Completion completion) {
    ++outstanding_;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        jobs_.push_back({std::move(line), std::move(completion)});
    }
    jobArrived_.notify_one();
}

void BridgeWorker::DeliverReplies() {
    for (;;) {
        Finished finished;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            if (finished_.empty()) return;
            finished = std::move(finished_.front());
            finished_.pop_front();
        }
        --outstanding_;
        // A completion may send the next request, which keeps the worker busy.
        finished.completion(finished.reply);
    }
}

void BridgeWorker::Run() {
    for (;;) {
        Job job;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            jobArrived_.wait(lock, [this] { return stopping_ || !jobs_.empty(); });
            if (stopping_) return;
            job = std::move(jobs_.front());
            jobs_.pop_front();
        }
        auto line = connection_.Request(job.line);
        std::optional<json::Value> reply = line ? json::Parse(*line) : std::nullopt;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            finished_.push_back({std::move(job.completion), std::move(reply)});
        }
        PostMessageW(options_.window, options_.message, 0, 0);
    }
}

}  // namespace azookey::ui
