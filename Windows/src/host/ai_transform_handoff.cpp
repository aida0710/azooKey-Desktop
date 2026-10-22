#include "ai_transform_handoff.h"

#include <bcrypt.h>

#include <map>
#include <utility>

#include "../shared/text_encoding.h"

namespace azookey::host {
namespace {

// The window claims its request right after it starts; an unclaimed one is dropped.
constexpr ULONGLONG kClaimLimitMilliseconds = 60000;
constexpr size_t kTokenBytes = 16;
constexpr char kOpenedReply[] = "{\"opened\":true}";
constexpr char kNotOpenedReply[] = "{\"opened\":false}";
constexpr char kUnknownTokenReply[] = "{\"error\":\"unknown_token\"}";

// 128 random bits as hex: not guessable by another process of the same user.
std::string NewToken() {
    unsigned char bytes[kTokenBytes] = {};
    if (!BCRYPT_SUCCESS(BCryptGenRandom(nullptr, bytes, static_cast<ULONG>(sizeof(bytes)), BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
        return {};
    }
    static const char digits[] = "0123456789abcdef";
    std::string token;
    for (unsigned char byte : bytes) {
        token.push_back(digits[byte >> 4]);
        token.push_back(digits[byte & 0x0F]);
    }
    return token;
}

}  // namespace

void AITransformHandoff::ForgetExpired(ULONGLONG now) {
    std::erase_if(held_, [now](const auto& entry) { return entry.second.claimBefore <= now; });
}

bool AITransformHandoff::StartWindow(const std::string& token) {
    std::wstring commandLine = L"\"" + options_.windowExecutable + L"\" --token " + text::Utf8ToUtf16(token) + L" --pipe " +
                               options_.pipeName;
    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION process{};
    if (!CreateProcessW(options_.windowExecutable.c_str(), commandLine.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr,
                        &startup, &process)) {
        return false;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return true;
}

std::string AITransformHandoff::Open(const json::Value& request) {
    if (request["context"].AsString().empty() || request["transformation"].kind() != json::Value::Kind::Number) {
        return kNotOpenedReply;
    }
    std::string token = NewToken();
    if (token.empty()) return kNotOpenedReply;
    std::map<std::string, json::Value> held = request.AsObject();
    held.erase("operation");
    ULONGLONG now = GetTickCount64();
    {
        std::lock_guard<std::mutex> lock(mutex_);
        ForgetExpired(now);
        held_[token] = {json::Value::MakeObject(std::move(held)), now + kClaimLimitMilliseconds};
    }
    if (StartWindow(token)) return kOpenedReply;
    std::lock_guard<std::mutex> lock(mutex_);
    held_.erase(token);
    return kNotOpenedReply;
}

std::string AITransformHandoff::Take(const json::Value& request) {
    std::lock_guard<std::mutex> lock(mutex_);
    ForgetExpired(GetTickCount64());
    auto found = held_.find(request["token"].AsString());
    if (found == held_.end()) return kUnknownTokenReply;
    std::string reply = json::Serialize(found->second.request);
    held_.erase(found);
    return reply;
}

}  // namespace azookey::host
