// Undoing the last commit and reconverting a selection. Core decides what can be
// reconverted (ReconversionSession); the text service reads the field, takes the
// text out of the document and puts the restored composition in its place, all
// inside one edit session so the application never sees a half-done state.
#include "text_service.h"

#include "edit_session.h"
#include "shared/ui_language.h"

namespace azookey::tsf {
namespace {

// Core's ReconversionSession.Failure raw values name the messages.
std::wstring ReconversionMessage(const std::string& failure) {
    return messages::Text("reconversion." + failure, messages::CurrentUiLanguage());
}

std::wstring ReadingPrompt(const std::wstring& reading) {
    return messages::Text("reconversion.reading_input", messages::CurrentUiLanguage(), {{L"reading", reading}});
}

}  // namespace

void TextService::StartReconversion(bool undo) {
    ITfContext* context = FocusedContext();
    if (!context || !converter_) {
        if (context) context->Release();
        return;
    }
    Retained keepService(static_cast<ITfTextInputProcessorEx*>(this));
    Retained keepContext(context);
    // A menu click is not a key event, so the whole exchange runs whenever the
    // application grants the document, with the field read in that same session.
    RunEditSession(context, clientId_, kAnytimeWrite, [this, context, undo, keepService, keepContext](TfEditCookie cookie) {
        if (!converter_) return;
        HideNotice();
        InputField field = CompositionWriter::ReadInputField(cookie, context);
        // During a composition Core answers composition_active; the composition
        // keeps the document it started with.
        if (!HasComposition()) converter_->SetDocument(field.document);
        auto reply = undo ? converter_->UndoCommit() : converter_->Reconvert();
        if (!reply) return;
        if (reply->reconversion) ReplaceForReconversion(cookie, context, *reply->reconversion, field);
        else ShowReconversionNotice(*reply, field.caret);
    });
    context->Release();
}

void TextService::HandleReadingKey(ITfContext* context, const keys::CoreKeyEvent& event) {
    // Core checks that the field is still the one the reading is for.
    InputField field = ReadInputField(context);
    converter_->SetDocument(field.document);
    auto reply = converter_->ReconversionReading(event);
    if (!reply) {
        EndReconversionReading();
        return;
    }
    // A reply with no reading and nothing to reconvert means Esc dropped the reading.
    if (!HandleReconversionReply(context, *reply, field)) EndReconversionReading();
}

bool TextService::HandleReconversionReply(ITfContext* context, const protocol::Snapshot& reply, const InputField& source) {
    if (!reply.reconversion) return ShowReconversionNotice(reply, source.caret);
    HRESULT result = RunEditSession(context, clientId_, kSyncWrite, [&](TfEditCookie cookie) {
        ReplaceForReconversion(cookie, context, *reply.reconversion, source);
    });
    if (FAILED(result)) {
        noticeCaret_ = source.caret;
        ShowNotice(ReconversionMessage("replacement_unavailable"));
    }
    return true;
}

void TextService::ReplaceForReconversion(TfEditCookie cookie, ITfContext* context,
                                         const protocol::ReconversionReplacement& replacement, const InputField& source) {
    reconversionReading_.reset();
    noticeCaret_ = source.caret;
    if (!source.document.reconversion) {
        ShowNotice(ReconversionMessage("replacement_unavailable"));
        return;
    }
    ReconversionEdit edit;
    edit.replacement = replacement;
    edit.source = *source.document.reconversion;
    edit.confirm = [this, token = replacement.token](const protocol::DocumentContext& removed) {
        // The restored composition describes the document without the text.
        converter_->SetDocument(removed);
        return converter_->ConfirmReconversion(token);
    };
    ReconversionOutcome outcome = CompositionWriter(this, clauseAtoms_).Reconvert(cookie, context, edit, &composition_);
    switch (outcome.result) {
    case ReconversionResult::Restored:
        HideNotice();
        snapshot_ = *outcome.reply;
        snapshot_.commits.clear();
        ShowCandidates(*outcome.reply, outcome.geometry);
        return;
    case ReconversionResult::Declined: {
        bool explained = outcome.reply && !outcome.reply->reconversionError.empty();
        ShowNotice(ReconversionMessage(explained ? outcome.reply->reconversionError : "replacement_unavailable"));
        return;
    }
    case ReconversionResult::DocumentChanged:
        ShowNotice(ReconversionMessage("changed_context"));
        return;
    }
}

bool TextService::ShowReconversionNotice(const protocol::Snapshot& reply, const std::optional<RECT>& caret) {
    if (caret) noticeCaret_ = caret;
    // reading_required comes with an empty reading: the prompt replaces the reason.
    if (reply.reconversionReading) {
        reconversionReading_ = reply.reconversionReading;
        ShowNotice(ReadingPrompt(*reply.reconversionReading));
        return true;
    }
    reconversionReading_.reset();
    if (reply.reconversionError.empty()) return false;
    ShowNotice(ReconversionMessage(reply.reconversionError));
    return reply.preedit.empty() && reply.commits.empty();
}

void TextService::EndReconversionReading() {
    if (!reconversionReading_) return;
    reconversionReading_.reset();
    HideNotice();
}

void TextService::ShowNotice(const std::wstring& text) {
    if (!notice_ || !noticeCaret_) return;
    // Keep clear of the candidate panel, which Core usually puts below the text.
    bool candidatesBelow = candidatePanel_ && candidatePanel_->visible() && lastPlacementSide_ != "above";
    notice_->Show(text, *noticeCaret_, candidatesBelow ? NoticePlacement::AboveCaret : NoticePlacement::BelowCaret);
}

void TextService::HideNotice() {
    if (notice_) notice_->Hide();
}

}  // namespace azookey::tsf
