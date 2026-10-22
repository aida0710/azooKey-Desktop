#include "converter_client.h"

#include <objbase.h>

#include "module.h"
#include "shared/ai_protocol.h"
#include "shared/text_encoding.h"

namespace azookey::tsf {
namespace {

// 32-bit applications load the x86 build from the x86 subfolder; both builds
// share the one 64-bit host and converter in the installation folder.
#if defined(_M_IX86)
constexpr wchar_t kHostRelativePath[] = L"\\..\\azookey-windows-host.exe";
#else
constexpr wchar_t kHostRelativePath[] = L"\\azookey-windows-host.exe";
#endif

channel::HostConnection::Options ConnectionOptions() {
    channel::HostConnection::Options options;
    options.hostExecutable = ModuleDirectory() + kHostRelativePath;
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
    std::wstring committed;
    for (const auto& text : snapshot->commits) committed += text;
    if (!committed.empty()) context_.document = protocol::AdvancedPastCommit(context_.document, committed);
    return snapshot;
}

std::optional<protocol::Snapshot> ConverterClient::Key(const keys::CoreKeyEvent& event, const protocol::KeyFacts& facts) {
    return Send(protocol::KeyRequest(context_, event, facts));
}

std::optional<protocol::Snapshot> ConverterClient::ReconversionReading(const keys::CoreKeyEvent& event) {
    return Send(protocol::ReconversionReadingRequest(context_, event));
}

std::optional<protocol::Snapshot> ConverterClient::UndoCommit() { return Send(protocol::UndoCommitRequest(context_)); }

std::optional<protocol::Snapshot> ConverterClient::Reconvert() { return Send(protocol::ReconvertRequest(context_)); }

std::optional<protocol::Snapshot> ConverterClient::ConfirmReconversion(const std::string& token) {
    return Send(protocol::ConfirmReconversionRequest(context_, token));
}

std::optional<protocol::Snapshot> ConverterClient::Select(int candidateIndex, int generation, bool submit) {
    return Send(protocol::SelectRequest(context_, candidateIndex, generation, submit));
}

std::optional<protocol::Snapshot> ConverterClient::SelectNode(int nodeId, int generation, bool submit) {
    return Send(protocol::NodeRequest(context_, nodeId, generation, submit));
}

std::optional<protocol::Snapshot> ConverterClient::Reset(bool submit) {
    return Send(protocol::ResetRequest(context_, submit));
}

std::optional<display::LayoutResult> ConverterClient::Layout(const display::LayoutRequest& request) {
    auto reply = connection_.Request(display::LayoutRequestLine(request));
    return reply ? display::ParseLayoutResult(*reply) : std::nullopt;
}

std::optional<std::vector<keys::KeyBinding>> ConverterClient::ImeShortcuts() {
    auto reply = connection_.Request(protocol::ImeShortcutsRequest());
    return reply ? protocol::ParseImeShortcuts(*reply) : std::nullopt;
}

std::optional<protocol::PresentationSettings> ConverterClient::PresentationSettings() {
    auto reply = connection_.Request(protocol::SettingsRequest(context_.context));
    return reply ? protocol::ParsePresentationSettings(*reply) : std::nullopt;
}

}  // namespace azookey::tsf
