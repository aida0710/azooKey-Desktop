#include "converter_client.h"

#include <objbase.h>

#include "module.h"
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


std::string NewContextIdentifier() {
    GUID guid{};
    CoCreateGuid(&guid);
    wchar_t text[64];
    StringFromGUID2(guid, text, ARRAYSIZE(text));
    return text::Utf16ToUtf8(text);
}

}  // namespace

channel::HostConnection::Options TextServiceHostOptions() {
    channel::HostConnection::Options options;
    options.hostExecutable = ModuleDirectory() + kHostRelativePath;
    return options;
}

ConverterClient::ConverterClient() : connection_(TextServiceHostOptions()) { context_.context = NewContextIdentifier(); }

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

std::optional<protocol::AISuggestionRequest> ConverterClient::AIReviewSend(int review, bool includeContext) {
    auto reply = connection_.Request(protocol::AIReviewSendRequest(context_, review, includeContext));
    return reply ? protocol::ParseAIReviewSend(*reply) : std::nullopt;
}

bool ConverterClient::SaveIncludeContext(bool includeContext) {
    auto reply = connection_.Request(protocol::IncludeContextUpdateRequest(includeContext));
    return reply && protocol::IsSettingsUpdateSaved(*reply);
}

std::optional<protocol::Snapshot> ConverterClient::Suggestions(const std::vector<std::wstring>& texts, int generation,
                                                               const std::wstring& reading) {
    return Send(protocol::SuggestionsRequest(context_, texts, generation, reading));
}

std::optional<protocol::AITransformOpened> ConverterClient::OpenAITransformation(const protocol::AITextField& field) {
    auto reply = connection_.Request(protocol::AITransformOpenRequest(context_, field));
    return reply ? protocol::ParseAITransformOpen(*reply) : std::nullopt;
}

std::optional<protocol::AITransformReply> ConverterClient::AITransformation(const std::string& operation, int transformation,
                                                                            const protocol::AITransformFacts& facts) {
    auto reply = connection_.Request(protocol::AITransformRequest(context_, operation, transformation, facts));
    return reply ? protocol::ParseAITransformReply(*reply) : std::nullopt;
}

bool ConverterClient::OpenAITransformationWindow(const protocol::AITransformOpened& opened, const std::wstring& initialPrompt,
                                                 const protocol::AITextField& field) {
    // The application has the foreground; only the host may take it, and it
    // hands that on to the window it starts. Any process (ASFW_ANY) would be
    // more than the window needs.
    if (auto host = connection_.HostProcessId()) AllowSetForegroundWindow(*host);
    auto reply = connection_.Request(protocol::HostOpenAITransformRequest(context_, opened, initialPrompt, field));
    return reply && protocol::ParseHostOpened(*reply);
}

std::optional<protocol::PresentationSettings> ConverterClient::PresentationSettings() {
    auto reply = connection_.Request(protocol::SettingsRequest(context_.context));
    return reply ? protocol::ParsePresentationSettings(*reply) : std::nullopt;
}

}  // namespace azookey::tsf
