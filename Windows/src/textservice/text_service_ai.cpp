// AI suggestions. Core decides what is reviewed and whether it may be sent
// (docs/ai-bridge-protocol.md); the text service shows the review, reports the
// user's choice, and has the host make the call on its own AI bridge so that a
// slow reply never holds up typing.
#include "text_service.h"

#include "edit_session.h"
#include "shared/ui_language.h"

namespace azookey::tsf {
namespace {

std::wstring Message(const char* key) { return messages::Text(key, messages::CurrentUiLanguage()); }

// The host's answer when no API key is stored (see host_main.cpp).
constexpr char kMissingApiKey[] = "missing_api_key";

}  // namespace

void TextService::ShowAIReview(const protocol::AIReview& review, const std::optional<RECT>& caret) {
    if (caret) noticeCaret_ = caret;
    if (!aiReviewWindow_ || !noticeCaret_) return;
    HideNotice();
    aiReview_ = review;
    aiReviewIncludeContext_ = review.includeContext;
    aiReviewWindow_->Show(review, aiReviewIncludeContext_, *noticeCaret_, SideAwayFromCandidates());
}

void TextService::CloseAIReview() {
    aiReview_.reset();
    if (aiReviewWindow_) aiReviewWindow_->Hide();
}

bool TextService::HandleAIReviewKey(const keys::CoreKeyEvent& event) {
    const keys::KeyBinding* binding = keys::FindBinding(event, aiReview_->bindings);
    if (!binding) return false;
    if (binding->command == "send") SendAIReview();
    else if (binding->command == "toggleContext") ToggleAIReviewContext();
    else if (binding->command == "cancel") CloseAIReview();
    else return false;
    return true;
}

void TextService::ToggleAIReviewContext() {
    if (!aiReview_ || !converter_) return;
    aiReviewIncludeContext_ = !aiReviewIncludeContext_;
    if (noticeCaret_) aiReviewWindow_->Show(*aiReview_, aiReviewIncludeContext_, *noticeCaret_, SideAwayFromCandidates());
    // The choice is also the setting for the next review. This request still
    // uses what the window shows even when saving fails.
    if (!converter_->SaveIncludeContext(aiReviewIncludeContext_)) ShowNotice(Message("ai.scope.include-error"));
}

void TextService::SendAIReview() {
    if (!aiReview_ || !converter_) return;
    int review = aiReview_->id;
    bool includeContext = aiReviewIncludeContext_;
    CloseAIReview();
    // Core sends only the reviewed content of an unchanged composition.
    auto request = converter_->AIReviewSend(review, includeContext);
    if (!request) return;
    ShowNotice(Message("ai.suggestion.loading"));
    Retained keepService(static_cast<ITfTextInputProcessorEx*>(this));
    backgroundRequests_->Start(protocol::AISuggestionsLine(*request),
                               [this, request = *request, keepService](std::optional<std::string> reply) {
                                   FinishAISuggestions(request, std::move(reply));
                               });
}

void TextService::FinishAISuggestions(const protocol::AISuggestionRequest& request, std::optional<std::string> reply) {
    if (!converter_) return;  // deactivated while the AI was answering
    auto snapshot = reply ? protocol::ParseSnapshot(*reply) : std::nullopt;
    if (snapshot && snapshot->error == kMissingApiKey) {
        ShowNotice(Message("ai.error.missing-key"));
        return;
    }
    auto texts = reply ? protocol::ParseAISuggestions(*reply) : std::nullopt;
    if (!texts) {
        ShowNotice(Message("ai.suggestion.failed"));
        return;
    }
    if (texts->empty()) {
        ShowNotice(Message("ai.suggestion.empty"));
        return;
    }
    HideNotice();
    // Core lists them only if the composition is still the one reviewed.
    auto offered = converter_->Suggestions(*texts, request.generation, request.reading);
    ITfContext* context = CompositionContext();
    if (offered && context) ApplySnapshot(context, *offered, kAnytimeWrite);
    if (context) context->Release();
}

}  // namespace azookey::tsf
