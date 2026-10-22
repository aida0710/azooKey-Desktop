// Transforming the selected text with an instruction. Core keeps the target and
// decides whether a result may replace it (docs/ai-bridge-protocol.md). The
// instruction window runs in its own process, started by the host, so the text
// service only opens the transformation, tells the host, and applies the result
// when focus comes back to the same field.
#include "text_service.h"

#include <algorithm>
#include <cstdio>

#include "edit_session.h"

namespace azookey::tsf {
namespace {

std::string PointerText(const void* pointer) {
    char text[2 + sizeof(void*) * 2 + 1];
    std::snprintf(text, sizeof(text), "%p", pointer);
    return text;
}

HWND ContextWindow(ITfContext* context) {
    ITfContextView* view = nullptr;
    HWND window = nullptr;
    if (SUCCEEDED(context->GetActiveView(&view)) && view) {
        view->GetWnd(&window);
        view->Release();
    }
    return window;
}

}  // namespace

protocol::AITextField TextService::AIFieldFacts(ITfContext* context, const InputField& field) const {
    protocol::AITextField facts;
    ITfDocumentMgr* document = nullptr;
    // A TSF document manager and its context name the field within this process.
    if (SUCCEEDED(context->GetDocumentMgr(&document)) && document) {
        facts.identity = {"tsf", PointerText(document), PointerText(context)};
        document->Release();
    }
    facts.surrounding = field.surrounding;
    facts.isSensitive = field.document.privateInput;
    return facts;
}

protocol::AISelectionWitness TextService::AIWitness(ITfContext* context, const InputField& field) const {
    protocol::AISelectionWitness witness;
    witness.object = {"tsf-context", PointerText(context)};
    witness.window = {PointerText(ContextWindow(context))};
    if (!field.surrounding) return witness;
    const protocol::AISurrounding& surrounding = *field.surrounding;
    int start = std::min(surrounding.cursorUTF16, surrounding.anchorUTF16);
    int end = std::max(surrounding.cursorUTF16, surrounding.anchorUTF16);
    witness.before = surrounding.text.substr(0, start);
    witness.selected = surrounding.text.substr(start, end - start);
    witness.after = surrounding.text.substr(end);
    // Document positions where the field has them; otherwise the read's own.
    witness.start = field.selectionExtent ? field.selectionExtent->first : start;
    witness.end = field.selectionExtent ? field.selectionExtent->second : end;
    return witness;
}

void TextService::StartAITransformation(ITfContext* context, const std::wstring& initialPrompt) {
    ForgetAITransformation(true);
    if (!converter_) return;
    protocol::AITextField field = AIFieldFacts(context, ReadInputField(context));
    auto opened = converter_->OpenAITransformation(field);
    if (!opened) return;
    if (opened->needsWitness) {
        // A second read right away tells Core which selection the result is for.
        InputField again = ReadInputField(context);
        converter_->AITransformation("ai-transform-target", opened->transformation,
                                     {AIFieldFacts(context, again), AIWitness(context, again)});
    }
    if (!converter_->OpenAITransformationWindow(*opened, initialPrompt, field)) {
        converter_->AITransformation("ai-transform-close", opened->transformation, {});
        return;
    }
    PendingAITransformation pending;
    pending.id = opened->transformation;
    context->GetDocumentMgr(&pending.document);
    aiTransformation_ = pending;
}

void TextService::ReturnToAITransformation(ITfContext* context) {
    Retained keepService(static_cast<ITfTextInputProcessorEx*>(this));
    Retained keepContext(context);
    // Focus changes are not key events, so the document is ours whenever the application allows.
    RunEditSession(context, clientId_, kAnytimeWrite, [this, context, keepService, keepContext](TfEditCookie cookie) {
        if (!aiTransformation_ || !converter_) return;
        int id = aiTransformation_->id;
        InputField field = CompositionWriter::ReadInputField(cookie, context);
        auto checked = converter_->AITransformation("ai-transform-check", id, {AIFieldFacts(context, field), std::nullopt});
        if (!checked || checked->stale) {
            ForgetAITransformation(false);
            return;
        }
        // Not confirmed yet (the window is still open), or not the same selection.
        if (!checked->matches) return;
        InputField witness = CompositionWriter::ReadInputField(cookie, context);
        auto taken = converter_->AITransformation("ai-transform-take", id, {AIFieldFacts(context, witness), AIWitness(context, witness)});
        converter_->AITransformation("ai-transform-close", id, {});
        ForgetAITransformation(false);
        // Inserting at the selection replaces it.
        if (taken && taken->replacement) CompositionWriter(this, clauseAtoms_).Insert(cookie, context, *taken->replacement);
    });
}

void TextService::ForgetAITransformation(bool reject) {
    if (!aiTransformation_) return;
    PendingAITransformation pending = *aiTransformation_;
    aiTransformation_.reset();
    if (reject && converter_) converter_->AITransformation("ai-transform-reject", pending.id, {});
    if (pending.document) pending.document->Release();
}

}  // namespace azookey::tsf
