// Long requests to the host (an AI call takes seconds) run on a background
// thread with their own connection, so typing never waits for them, and their
// replies come back on the UI thread that started them.
#pragma once

#include <windows.h>

#include <functional>
#include <memory>
#include <optional>
#include <string>

#include "shared/host_channel.h"

namespace azookey::tsf {

class BackgroundRequests {
public:
    using ReplyHandler = std::function<void(std::optional<std::string> reply)>;

    // Call on the UI thread; replies are delivered to it.
    explicit BackgroundRequests(channel::HostConnection::Options options);
    // Replies still on their way are dropped.
    ~BackgroundRequests();
    BackgroundRequests(const BackgroundRequests&) = delete;
    BackgroundRequests& operator=(const BackgroundRequests&) = delete;

    // `onReply` gets nullopt when the host did not answer in time.
    void Start(std::string line, ReplyHandler onReply);

    struct Mailbox;

private:
    static LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam);

    channel::HostConnection::Options options_;
    std::shared_ptr<Mailbox> mailbox_;
};

}  // namespace azookey::tsf
