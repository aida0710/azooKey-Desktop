// Opens the AI instruction window (azookey-ai-transform.exe) for a
// selected-text transformation the text service started. Store apps cannot
// start processes, so the host does it for every application.
//
// The selection and its surroundings never go on the window's command line,
// which process-creation auditing records. The host keeps the request under a
// random one-time token; the window claims it through the pipe.
#pragma once

#include <windows.h>

#include <map>
#include <mutex>
#include <string>

#include "../shared/json.h"

namespace azookey::host {

class AITransformHandoff {
public:
    struct Options {
        std::wstring windowExecutable;
        std::wstring pipeName;  // the window talks to the host that started it
    };

    explicit AITransformHandoff(Options options) : options_(std::move(options)) {}

    // host-open-ai-transform → {"opened":true|false}
    std::string Open(const json::Value& request);
    // host-take-ai-transform → the held request (context, transformation,
    // initialPrompt, field, open), once; {"error":"unknown_token"} otherwise.
    std::string Take(const json::Value& request);

private:
    struct Held {
        json::Value request;
        ULONGLONG claimBefore = 0;
    };

    void ForgetExpired(ULONGLONG now);
    bool StartWindow(const std::string& token);

    Options options_;
    std::mutex mutex_;
    std::map<std::string, Held> held_;
};

}  // namespace azookey::host
