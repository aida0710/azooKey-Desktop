#include "ai_service.h"

#include <chrono>
#include <map>
#include <utility>

#include "../shared/api_key_credential.h"
#include "../shared/text_encoding.h"

namespace azookey::host {
namespace {

// An AI API answers in seconds and may take tens of seconds for a long text;
// the conversion bridge's few-second limit would cut such a request off.
constexpr DWORD kReplyTimeoutMilliseconds = 90000;
// The AI converter keeps its own copy of the dictionary in memory; without AI
// requests for this long it is stopped and started again on the next one.
constexpr ULONGLONG kIdleStopMilliseconds = 10 * 60 * 1000;
constexpr char kMissingApiKeyReply[] = "{\"error\":\"missing_api_key\"}";
constexpr char kUnavailableReply[] = "{\"consumed\":false,\"error\":\"converter_unavailable\"}";

}  // namespace

AIService::AIService(Options options)
    : options_(std::move(options)),
      bridge_({options_.bridge, options_.dataDirectory, L"", kReplyTimeoutMilliseconds}),
      idleWatch_([this] { StopWhenIdle(); }) {}

AIService::~AIService() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = true;
    }
    wake_.notify_all();
    idleWatch_.join();
}

std::string AIService::Handle(const json::Value& request) {
    auto key = credentials::ReadApiKey(options_.apiKeyCredential);
    if (!key || key->empty()) return kMissingApiKeyReply;
    std::map<std::string, json::Value> members = request.AsObject();
    members["apiKey"] = json::Value::MakeString(text::Utf16ToUtf8(*key));
    // The AI converter only calls the API; one session serves every request, so
    // it never keeps a session per text field that nobody would close.
    members.erase("context");
    std::string line = json::Serialize(json::Value::MakeObject(std::move(members)));
    std::lock_guard<std::mutex> lock(mutex_);
    running_ = true;
    lastUsed_ = GetTickCount64();
    std::string reply = bridge_.Request(line).value_or(kUnavailableReply);
    lastUsed_ = GetTickCount64();
    wake_.notify_all();
    return reply;
}

void AIService::StopWhenIdle() {
    std::unique_lock<std::mutex> lock(mutex_);
    while (!stopping_) {
        if (!running_) {
            wake_.wait(lock, [this] { return stopping_ || running_; });
            continue;
        }
        ULONGLONG idleUntil = lastUsed_ + kIdleStopMilliseconds;
        ULONGLONG now = GetTickCount64();
        if (now >= idleUntil) {
            bridge_.Stop();
            running_ = false;
            continue;
        }
        wake_.wait_for(lock, std::chrono::milliseconds(idleUntil - now));
    }
}

}  // namespace azookey::host
