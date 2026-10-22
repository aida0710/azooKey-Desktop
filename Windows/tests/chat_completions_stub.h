// A tiny HTTP server on 127.0.0.1 that answers the OpenAI-compatible chat
// completions requests Core sends, so AI requests are tested without leaving
// the machine. Suggestion requests (whose schema names "predictions") get two
// predictions; transformation requests get a "result" built from the prompt.
// A request whose body contains kSlowMarker is answered after kSlowDelay.
#pragma once

#include <winsock2.h>
#include <windows.h>

#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace azookey::tests {

class ChatCompletionsStub {
public:
    static constexpr char kSlowMarker[] = "slow-request";
    static constexpr DWORD kSlowDelayMilliseconds = 3000;

    struct Received {
        std::string authorization;
        std::string body;
    };

    ChatCompletionsStub();
    ~ChatCompletionsStub();
    ChatCompletionsStub(const ChatCompletionsStub&) = delete;
    ChatCompletionsStub& operator=(const ChatCompletionsStub&) = delete;

    bool started() const { return listener_ != INVALID_SOCKET; }
    // http://127.0.0.1:<port>/v1/chat/completions
    std::string endpoint() const;
    std::vector<Received> received();

private:
    void Serve();
    void Answer(SOCKET client);

    SOCKET listener_ = INVALID_SOCKET;
    unsigned short port_ = 0;
    std::atomic<bool> stopping_{false};
    std::mutex mutex_;
    std::vector<Received> received_;
    std::thread thread_;
};

}  // namespace azookey::tests
