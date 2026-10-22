#include "request_trace.h"

#include <fstream>

namespace azookey::host {
namespace {

long long MillisecondsBetween(RequestTrace::Clock::time_point from, RequestTrace::Clock::time_point to) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(to - from).count();
}

}  // namespace

RequestTrace::RequestTrace(std::wstring path) : path_(std::move(path)), origin_(Clock::now()) {}

void RequestTrace::Record(std::string_view operation, const Timing& timing) {
    if (path_.empty()) return;
    std::lock_guard<std::mutex> lock(mutex_);
    std::ofstream file(path_, std::ios::app);
    file << MillisecondsBetween(origin_, timing.arrived) << "ms " << operation
         << " waited=" << MillisecondsBetween(timing.arrived, timing.started)
         << "ms converted=" << MillisecondsBetween(timing.started, timing.finished) << "ms\n";
}

}  // namespace azookey::host
