// One line per converter request: when it arrived, how long it waited for the
// converter and how long the converter took. A test reads it to see which
// request kept a key past the text service's wait. Off unless --trace is given.
#pragma once

#include <chrono>
#include <mutex>
#include <string>
#include <string_view>

namespace azookey::host {

class RequestTrace {
public:
    using Clock = std::chrono::steady_clock;

    struct Timing {
        Clock::time_point arrived;   // the host read the request
        Clock::time_point started;   // the converter was free
        Clock::time_point finished;  // the converter answered
    };

    // An empty path records nothing.
    explicit RequestTrace(std::wstring path);

    void Record(std::string_view operation, const Timing& timing);

private:
    std::wstring path_;
    Clock::time_point origin_;
    std::mutex mutex_;
};

}  // namespace azookey::host
