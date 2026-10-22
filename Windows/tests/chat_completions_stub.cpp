#include "chat_completions_stub.h"

#include <ws2tcpip.h>

#include <cctype>
#include <cstdlib>

#include "../src/shared/json.h"

namespace azookey::tests {
namespace {

std::string HeaderValue(const std::string& headers, const std::string& name) {
    std::string lower = headers;
    for (char& character : lower) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    std::string wanted = "\r\n" + name + ":";
    size_t start = lower.find(wanted);
    if (start == std::string::npos) return {};
    start += wanted.size();
    size_t end = headers.find("\r\n", start);
    std::string value = headers.substr(start, end - start);
    size_t first = value.find_first_not_of(' ');
    return first == std::string::npos ? std::string() : value.substr(first);
}

// The content Core parses: {"predictions": [...]} for suggestions, {"result": "..."} for a transformation.
std::string ContentFor(const std::string& body) {
    if (body.find("\"predictions\"") != std::string::npos) {
        return json::Serialize(json::Value::MakeObject({{"predictions", json::Value::MakeArray({
                                                             json::Value::MakeString("候補A"), json::Value::MakeString("候補B")})}}));
    }
    return json::Serialize(json::Value::MakeObject({{"result", json::Value::MakeString("変換結果")}}));
}

}  // namespace

ChatCompletionsStub::ChatCompletionsStub() {
    WSADATA data{};
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) return;
    listener_ = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;  // any free port
    int length = sizeof(address);
    if (listener_ == INVALID_SOCKET || bind(listener_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
        listen(listener_, SOMAXCONN) != 0 || getsockname(listener_, reinterpret_cast<sockaddr*>(&address), &length) != 0) {
        if (listener_ != INVALID_SOCKET) closesocket(listener_);
        listener_ = INVALID_SOCKET;
        return;
    }
    port_ = ntohs(address.sin_port);
    thread_ = std::thread([this] { Serve(); });
}

ChatCompletionsStub::~ChatCompletionsStub() {
    stopping_ = true;
    if (listener_ != INVALID_SOCKET) closesocket(listener_);  // ends accept()
    if (thread_.joinable()) thread_.join();
    WSACleanup();
}

std::string ChatCompletionsStub::endpoint() const {
    return "http://127.0.0.1:" + std::to_string(port_) + "/v1/chat/completions";
}

std::vector<ChatCompletionsStub::Received> ChatCompletionsStub::received() {
    std::lock_guard<std::mutex> lock(mutex_);
    return received_;
}

void ChatCompletionsStub::Serve() {
    while (!stopping_) {
        SOCKET client = accept(listener_, nullptr, nullptr);
        if (client == INVALID_SOCKET) return;
        // Each connection gets its own thread, so a slow answer does not hold up the next request.
        std::thread([this, client] { Answer(client); }).detach();
    }
}

void ChatCompletionsStub::Answer(SOCKET client) {
    std::string request;
    char buffer[4096];
    size_t headerEnd = std::string::npos;
    while (headerEnd == std::string::npos) {
        int read = recv(client, buffer, sizeof(buffer), 0);
        if (read <= 0) {
            closesocket(client);
            return;
        }
        request.append(buffer, static_cast<size_t>(read));
        headerEnd = request.find("\r\n\r\n");
    }
    std::string headers = request.substr(0, headerEnd + 2);
    size_t contentLength = static_cast<size_t>(std::strtoul(HeaderValue(headers, "content-length").c_str(), nullptr, 10));
    std::string body = request.substr(headerEnd + 4);
    while (body.size() < contentLength) {
        int read = recv(client, buffer, sizeof(buffer), 0);
        if (read <= 0) break;
        body.append(buffer, static_cast<size_t>(read));
    }
    {
        std::lock_guard<std::mutex> lock(mutex_);
        received_.push_back({HeaderValue(headers, "authorization"), body});
    }
    if (body.find(kSlowMarker) != std::string::npos) Sleep(kSlowDelayMilliseconds);
    std::string answer = json::Serialize(json::Value::MakeObject({
        {"object", json::Value::MakeString("chat.completion")},
        {"choices", json::Value::MakeArray({json::Value::MakeObject({
                        {"index", json::Value::MakeNumber(0)},
                        {"finish_reason", json::Value::MakeString("stop")},
                        {"message", json::Value::MakeObject({{"role", json::Value::MakeString("assistant")},
                                                             {"content", json::Value::MakeString(ContentFor(body))}})},
                    })})},
    }));
    std::string response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
                           std::to_string(answer.size()) + "\r\nConnection: close\r\n\r\n" + answer;
    send(client, response.data(), static_cast<int>(response.size()), 0);
    shutdown(client, SD_SEND);
    closesocket(client);
}

}  // namespace azookey::tests
