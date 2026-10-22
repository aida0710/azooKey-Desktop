// The second converter process the host keeps for "ai" and "transform", so a
// request that waits for the AI API never holds up typing in the converter that
// serves the input sessions. It starts with the first AI request, runs without
// Zenzai's model, and stops after it has been idle for a while.
//
// The API key comes from Credential Manager here, never from the application
// that sent the request: a key in the request is replaced.
#pragma once

#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>

#include "../shared/json.h"
#include "bridge_process.h"

namespace azookey::host {

class AIService {
public:
    struct Options {
        std::wstring bridge;
        // A folder of its own, so the two converters never write the same learning files.
        std::wstring dataDirectory;
        std::wstring apiKeyCredential;
    };

    explicit AIService(Options options);
    ~AIService();
    AIService(const AIService&) = delete;
    AIService& operator=(const AIService&) = delete;

    // The reply line for one AI request; callers may come from several client threads.
    std::string Handle(const json::Value& request);

private:
    void StopWhenIdle();

    Options options_;
    std::mutex mutex_;  // one request at a time, and guards the members below
    BridgeProcess bridge_;
    bool running_ = false;
    ULONGLONG lastUsed_ = 0;
    bool stopping_ = false;
    std::condition_variable wake_;
    std::thread idleWatch_;
};

}  // namespace azookey::host
