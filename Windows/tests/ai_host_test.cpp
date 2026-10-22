// Starts azookey-windows-host.exe on a private pipe with a stub AI API on
// 127.0.0.1 and checks the host's AI path: requests without a stored key are
// refused, the key comes from Credential Manager and replaces any key the
// application sent, "ai" and "transform" go through the second converter, a
// slow AI request does not hold up typing, and the instruction window gets
// the held transformation once through its token, never on its command line.
//
//   azookey-ai-host-test.exe <host exe> <bridge exe> <probe exe>
#include <windows.h>

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <future>
#include <sstream>
#include <string>

#include "../src/shared/api_key_credential.h"
#include "../src/shared/bridge_protocol.h"
#include "../src/shared/host_channel.h"
#include "../src/shared/json.h"
#include "../src/shared/key_translation.h"
#include "../src/shared/text_encoding.h"
#include "chat_completions_stub.h"

namespace {

using azookey::channel::HostConnection;
using azookey::json::Value;
using azookey::tests::ChatCompletionsStub;

// Bounds for a broken run; a passing step finishes well within them.
constexpr DWORD kAIRequestTimeoutMilliseconds = 95000;
constexpr DWORD kProbeLimitMilliseconds = 15000;
// Typing must answer this fast while an AI request waits for the API.
constexpr double kTypingWhileWaitingLimitMilliseconds = 1500;
constexpr char kApiKey[] = "sk-host-test";

int failures = 0;

void Check(bool condition, const std::string& description, const std::string& actual = "") {
    if (!condition) ++failures;
    std::printf("%s: %s\n", condition ? "ok" : "FAIL", description.c_str());
    if (!condition && !actual.empty()) std::printf("  actual: %s\n", actual.c_str());
    std::fflush(stdout);
}

std::optional<Value> Ask(HostConnection& connection, const std::string& line) {
    auto reply = connection.Request(line);
    return reply ? azookey::json::Parse(*reply) : std::nullopt;
}

std::string Show(const std::optional<Value>& reply) { return reply ? azookey::json::Serialize(*reply) : "(no reply)"; }

std::string AIRequest(const std::string& operation, const std::string& endpoint, const std::string& prompt) {
    std::map<std::string, Value> members{
        {"operation", Value::MakeString(operation)},
        {"target", Value::MakeString("原文")},
        {"leftContext", Value::MakeString("")},
        {"rightContext", Value::MakeString("")},
        {"includeContext", Value::MakeBoolean(false)},
        {"aiModel", Value::MakeString("stub-model")},
        {"aiEndpoint", Value::MakeString(endpoint)},
        // An application must not be able to choose the key the host sends.
        {"apiKey", Value::MakeString("sk-from-the-application")},
        {"context", Value::MakeString("ai-host-test")},
    };
    if (!prompt.empty()) members["prompt"] = Value::MakeString(prompt);
    return azookey::json::Serialize(Value::MakeObject(std::move(members)));
}

std::vector<std::string> Suggestions(const std::optional<Value>& reply) {
    std::vector<std::string> texts;
    if (reply) {
        for (const auto& item : (*reply)["suggestions"].AsArray()) texts.push_back(item.AsString());
    }
    return texts;
}

std::string ReadAll(const std::wstring& path) {
    std::ifstream file(path, std::ios::binary);
    std::ostringstream contents;
    contents << file.rdbuf();
    return contents.str();
}

void TestWithoutAKeyNothingIsSent(HostConnection& connection, ChatCompletionsStub& stub) {
    auto reply = Ask(connection, AIRequest("ai", stub.endpoint(), ""));
    Check(reply && (*reply)["error"].AsString() == "missing_api_key", "without a stored key the host answers missing_api_key",
          Show(reply));
    Check(stub.received().empty(), "without a stored key nothing reaches the AI API");
}

void TestTheStoredKeyReplacesTheApplicationsKey(HostConnection& connection, ChatCompletionsStub& stub) {
    auto reply = Ask(connection, AIRequest("ai", stub.endpoint(), ""));
    auto texts = Suggestions(reply);
    Check(texts.size() == 2 && texts[0] == "候補A" && texts[1] == "候補B", "ai returns the API's suggestions", Show(reply));
    auto received = stub.received();
    Check(!received.empty() && received.back().authorization == std::string("Bearer ") + kApiKey,
          "the host sends the key from Credential Manager", received.empty() ? "" : received.back().authorization);
    Check(!received.empty() && received.back().body.find("sk-from-the-application") == std::string::npos &&
              received.back().authorization.find("sk-from-the-application") == std::string::npos,
          "the key the application sent is not used");
}

void TestTransformReturnsTheResult(HostConnection& connection, ChatCompletionsStub& stub) {
    auto reply = Ask(connection, AIRequest("transform", stub.endpoint(), "敬語に直す"));
    auto texts = Suggestions(reply);
    Check(texts.size() == 1 && texts[0] == "変換結果", "transform returns the API's result", Show(reply));
}

void TestTypingContinuesWhileTheAIWaits(const HostConnection::Options& options, ChatCompletionsStub& stub) {
    auto slow = std::async(std::launch::async, [&] {
        HostConnection ai(options);
        return Ask(ai, AIRequest("transform", stub.endpoint(), ChatCompletionsStub::kSlowMarker));
    });
    // Give the slow request time to reach the stub before typing.
    Sleep(500);
    HostConnection typing(options);
    azookey::protocol::RequestContext context{"typing-while-ai-waits", {}};
    auto started = std::chrono::steady_clock::now();
    auto reply = Ask(typing, azookey::protocol::KeyRequest(context, azookey::keys::Translate('K', {}, L"k"), {}));
    double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    std::printf("a key took %.0f ms while an AI request waited for the API\n", elapsed);
    Check(reply.has_value() && elapsed < kTypingWhileWaitingLimitMilliseconds, "typing is answered while an AI request waits");
    auto slowReply = slow.get();
    Check(Suggestions(slowReply).size() == 1, "the slow AI request still completes", Show(slowReply));
}

void TestTheInstructionWindowClaimsItsTransformationOnce(HostConnection& connection, const std::wstring& probeOutput) {
    Value field = Value::MakeObject({
        {"identity", Value::MakeArray({Value::MakeString("document-1")})},
        {"surrounding", Value::MakeObject({{"text", Value::MakeString("前 原文 後")},
                                           {"cursorUTF16", Value::MakeNumber(4)},
                                           {"anchorUTF16", Value::MakeNumber(2)}})},
        {"hasSurroundingUpdate", Value::MakeBoolean(true)},
        {"isSensitive", Value::MakeBoolean(false)},
    });
    Value open = Value::MakeObject({
        {"transformation", Value::MakeNumber(7)},
        {"target", Value::MakeString("原文")},
        {"includeContext", Value::MakeBoolean(false)},
        {"needsWitness", Value::MakeBoolean(true)},
        {"contextCharacters", Value::MakeNumber(100)},
        {"history", Value::MakeArray({})},
    });
    std::string request = azookey::json::Serialize(Value::MakeObject({
        {"operation", Value::MakeString("host-open-ai-transform")},
        {"context", Value::MakeString("text-service-context")},
        {"transformation", Value::MakeNumber(7)},
        {"initialPrompt", Value::MakeString("敬語に直す")},
        {"field", field},
        {"open", open},
    }));
    auto reply = Ask(connection, request);
    Check(reply && (*reply)["opened"].AsBoolean(), "the host opens the instruction window", Show(reply));
    ULONGLONG deadline = GetTickCount64() + kProbeLimitMilliseconds;
    while (!std::filesystem::exists(probeOutput) && GetTickCount64() < deadline) Sleep(50);
    std::istringstream lines(ReadAll(probeOutput));
    std::string commandLine, first, second;
    std::getline(lines, commandLine);
    std::getline(lines, first);
    std::getline(lines, second);
    Check(commandLine.find("--token ") != std::string::npos && commandLine.find("原文") == std::string::npos &&
              commandLine.find("前 原文") == std::string::npos,
          "the window's command line has a token and no text", commandLine);
    auto held = azookey::json::Parse(first);
    Check(held && (*held)["context"].AsString() == "text-service-context" && (*held)["transformation"].AsInteger() == 7 &&
              (*held)["initialPrompt"].AsString() == "敬語に直す" && (*held)["open"]["target"].AsString() == "原文" &&
              (*held)["field"]["surrounding"]["text"].AsString() == "前 原文 後",
          "the window claims the text service's request with its token", first);
    auto again = azookey::json::Parse(second);
    Check(again && (*again)["error"].AsString() == "unknown_token", "a token is good for one claim only", second);
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc < 4) {
        std::fprintf(stderr, "usage: azookey-ai-host-test <host exe> <bridge exe> <probe exe>\n");
        return 64;
    }
    SetConsoleOutputCP(CP_UTF8);
    std::wstring id = std::to_wstring(GetCurrentProcessId());
    wchar_t temporary[MAX_PATH];
    GetTempPathW(MAX_PATH, temporary);
    std::wstring root = std::wstring(temporary) + L"azookey-ai-host-" + id;
    std::filesystem::create_directories(root + L"\\Roaming");
    std::filesystem::create_directories(root + L"\\Local");
    std::wstring probeOutput = root + L"\\probe.txt";
    std::wstring credential = L"azooKey Tree/ai-host-test-" + id;
    azookey::credentials::DeleteApiKey(credential);
    // The host and its converters inherit these.
    SetEnvironmentVariableW(L"APPDATA", (root + L"\\Roaming").c_str());
    SetEnvironmentVariableW(L"AZOOKEY_PROBE_OUTPUT", probeOutput.c_str());

    ChatCompletionsStub stub;
    if (!stub.started()) {
        std::printf("FAIL: the stub AI API did not start\n");
        return 1;
    }
    std::wstring pipe = L"\\\\.\\pipe\\azooKeyTree-ai-host-" + id;
    std::wstring commandLine = L"\"" + std::wstring(argv[1]) + L"\" --pipe " + pipe + L" --bridge \"" + argv[2] +
                               L"\" --data \"" + root + L"\\Local\" --api-key-credential \"" + credential +
                               L"\" --ai-transform-window \"" + argv[3] + L"\"";
    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION host{};
    if (!CreateProcessW(argv[1], commandLine.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup,
                        &host)) {
        std::printf("FAIL: could not start the host (%lu)\n", GetLastError());
        return 1;
    }
    HostConnection::Options options;
    options.pipeName = pipe;
    options.requestTimeoutMilliseconds = kAIRequestTimeoutMilliseconds;
    {
        HostConnection connection(options);
        TestWithoutAKeyNothingIsSent(connection, stub);
        // Credential Manager refuses to store from a non-interactive logon (an SSH session).
        Check(azookey::credentials::StoreApiKey(credential, azookey::text::Utf8ToUtf16(kApiKey)),
              "the test's API key is stored in Credential Manager");
        TestTheStoredKeyReplacesTheApplicationsKey(connection, stub);
        TestTransformReturnsTheResult(connection, stub);
        TestTypingContinuesWhileTheAIWaits(options, stub);
        TestTheInstructionWindowClaimsItsTransformationOnce(connection, probeOutput);
    }
    azookey::credentials::DeleteApiKey(credential);
    TerminateProcess(host.hProcess, 0);
    WaitForSingleObject(host.hProcess, 5000);
    CloseHandle(host.hThread);
    CloseHandle(host.hProcess);
    std::error_code ignored;
    std::filesystem::remove_all(root, ignored);
    std::printf("%s\n", failures == 0 ? "PASS" : "FAIL");
    return failures == 0 ? 0 : 1;
}
