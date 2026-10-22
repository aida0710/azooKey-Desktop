#include "converter_client.h"

#include <objbase.h>

#include "module.h"
#include "shared/text_encoding.h"

namespace azookey::tsf {
namespace {

channel::HostConnection::Options ConnectionOptions() {
    channel::HostConnection::Options options;
    options.hostExecutable = ModuleDirectory() + L"\\azookey-windows-host.exe";
    return options;
}

std::string NewContextIdentifier() {
    GUID guid{};
    CoCreateGuid(&guid);
    wchar_t text[64];
    StringFromGUID2(guid, text, ARRAYSIZE(text));
    return text::Utf16ToUtf8(text);
}

}  // namespace

ConverterClient::ConverterClient() : connection_(ConnectionOptions()) { context_.context = NewContextIdentifier(); }

ConverterClient::~ConverterClient() {
    if (connection_.connected()) connection_.Request(protocol::CloseRequest(context_.context));
}

std::optional<protocol::Snapshot> ConverterClient::Send(const std::string& request) {
    auto reply = connection_.Request(request);
    if (!reply) return std::nullopt;
    auto snapshot = protocol::ParseSnapshot(*reply);
    if (!snapshot || snapshot->error == "converter_unavailable") return std::nullopt;
    return snapshot;
}

std::optional<protocol::Snapshot> ConverterClient::Key(const keys::CoreKeyEvent& event, const std::wstring& leftContext,
                                                       bool privateInput) {
    context_.leftContext = leftContext;
    context_.privateInput = privateInput;
    return Send(protocol::KeyRequest(context_, event));
}

std::optional<protocol::Snapshot> ConverterClient::Select(int candidateIndex, int generation, bool submit) {
    return Send(protocol::SelectRequest(context_, candidateIndex, generation, submit));
}

std::optional<protocol::Snapshot> ConverterClient::Reset(bool submit) {
    return Send(protocol::ResetRequest(context_, submit));
}

}  // namespace azookey::tsf
