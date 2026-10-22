#include "composition_writer.h"

#include <inputscope.h>

#include "shared/text_encoding.h"

namespace azookey::tsf {
namespace {

// Matches the context the bridge keeps (DesktopSession).
constexpr LONG kLeftContextUnits = 100;

// GUID_PROP_INPUTSCOPE from msctf.h; the SDK declares it but ships no library
// that defines it.
constexpr GUID kInputScopeProperty = {0x1713dd5a, 0x68e7, 0x4a5b, {0x9a, 0xf6, 0x59, 0x2a, 0x59, 0x5c, 0x77, 0x8d}};

template <typename T>
struct Releaser {
    T* pointer = nullptr;
    ~Releaser() { if (pointer) pointer->Release(); }
    T** operator&() { return &pointer; }
    T* operator->() const { return pointer; }
    explicit operator bool() const { return pointer != nullptr; }
};

ITfRange* SubRange(TfEditCookie cookie, ITfRange* range, LONG start, LONG end) {
    ITfRange* sub = nullptr;
    if (FAILED(range->Clone(&sub))) return nullptr;
    LONG moved = 0;
    sub->Collapse(cookie, TF_ANCHOR_START);
    sub->ShiftEnd(cookie, end, &moved, nullptr);
    sub->ShiftStart(cookie, start, &moved, nullptr);
    return sub;
}

bool IsPrivateScope(InputScope scope) {
    switch (scope) {
    case IS_PASSWORD:
    case IS_NUMERIC_PASSWORD:
    case IS_NUMERIC_PIN:
    case IS_ALPHANUMERIC_PIN:
    case IS_ALPHANUMERIC_PIN_SET:
        return true;
    default:
        return false;
    }
}

}  // namespace

std::optional<RECT> CompositionWriter::Apply(TfEditCookie cookie, ITfContext* context, const protocol::Snapshot& snapshot,
                                             ITfComposition** composition) {
    std::wstring committed;
    for (const auto& text : snapshot.commits) committed += text;
    if (!committed.empty()) {
        if (*composition) ReplaceComposition(cookie, context, committed, composition);
        else Insert(cookie, context, committed);
    }
    if (snapshot.preedit.empty()) {
        if (*composition) ReplaceComposition(cookie, context, L"", composition);
        return std::nullopt;
    }
    if (!*composition) {
        Releaser<ITfInsertAtSelection> insert;
        Releaser<ITfContextComposition> contextComposition;
        Releaser<ITfRange> start;
        if (FAILED(context->QueryInterface(IID_ITfInsertAtSelection, reinterpret_cast<void**>(&insert))) ||
            FAILED(context->QueryInterface(IID_ITfContextComposition, reinterpret_cast<void**>(&contextComposition))) ||
            FAILED(insert->InsertTextAtSelection(cookie, TF_IAS_QUERYONLY, nullptr, 0, &start)) ||
            FAILED(contextComposition->StartComposition(cookie, start.pointer, sink_, composition)) || !*composition) {
            return std::nullopt;
        }
    }
    Releaser<ITfRange> range;
    if (FAILED((*composition)->GetRange(&range))) return std::nullopt;
    range->SetText(cookie, 0, snapshot.preedit.c_str(), static_cast<LONG>(snapshot.preedit.size()));
    ApplyClauseAttributes(cookie, context, range.pointer, snapshot);
    LONG caret = static_cast<LONG>(text::ScalarOffsetToUtf16(snapshot.preedit, snapshot.cursorScalars));
    PlaceCaret(cookie, context, range.pointer, caret);
    return ScreenRectangle(cookie, context, range.pointer);
}

void CompositionWriter::Finish(TfEditCookie cookie, ITfContext* context, const std::wstring& text, ITfComposition** composition) {
    if (*composition) ReplaceComposition(cookie, context, text, composition);
}

void CompositionWriter::Insert(TfEditCookie cookie, ITfContext* context, const std::wstring& text) {
    Releaser<ITfInsertAtSelection> insert;
    Releaser<ITfRange> range;
    if (FAILED(context->QueryInterface(IID_ITfInsertAtSelection, reinterpret_cast<void**>(&insert))) ||
        FAILED(insert->InsertTextAtSelection(cookie, 0, text.c_str(), static_cast<LONG>(text.size()), &range))) {
        return;
    }
    PlaceCaret(cookie, context, range.pointer, static_cast<LONG>(text.size()));
}

void CompositionWriter::ReplaceComposition(TfEditCookie cookie, ITfContext* context, const std::wstring& text,
                                           ITfComposition** composition) {
    Releaser<ITfRange> range;
    if (SUCCEEDED((*composition)->GetRange(&range))) {
        // Confirmed text must not keep the composition's underline.
        ClearClauseAttributes(cookie, context, range.pointer);
        range->SetText(cookie, 0, text.c_str(), static_cast<LONG>(text.size()));
        PlaceCaret(cookie, context, range.pointer, static_cast<LONG>(text.size()));
    }
    (*composition)->EndComposition(cookie);
    (*composition)->Release();
    *composition = nullptr;
}

void CompositionWriter::ApplyClauseAttributes(TfEditCookie cookie, ITfContext* context, ITfRange* range,
                                              const protocol::Snapshot& snapshot) {
    Releaser<ITfProperty> property;
    if (FAILED(context->GetProperty(GUID_PROP_ATTRIBUTE, &property))) return;
    property->Clear(cookie, range);
    auto set = [&](ITfRange* target, TfGuidAtom atom) {
        VARIANT value;
        VariantInit(&value);
        value.vt = VT_I4;
        value.lVal = static_cast<LONG>(atom);
        property->SetValue(cookie, target, &value);
    };
    if (snapshot.segments.empty()) {
        set(range, atoms_.input);
        return;
    }
    LONG start = 0;
    for (const auto& segment : snapshot.segments) {
        LONG end = start + static_cast<LONG>(segment.text.size());
        Releaser<ITfRange> clause;
        clause.pointer = SubRange(cookie, range, start, end);
        if (clause) {
            // Core marks the clause being converted as focused and the other
            // converted clauses as unfocused; plain typing has no focus state.
            TfGuidAtom atom = segment.focused ? atoms_.targetClause
                              : snapshot.selection ? atoms_.convertedClause
                                                   : atoms_.input;
            set(clause.pointer, atom);
        }
        start = end;
    }
}

void CompositionWriter::ClearClauseAttributes(TfEditCookie cookie, ITfContext* context, ITfRange* range) {
    Releaser<ITfProperty> property;
    if (SUCCEEDED(context->GetProperty(GUID_PROP_ATTRIBUTE, &property))) property->Clear(cookie, range);
}

void CompositionWriter::PlaceCaret(TfEditCookie cookie, ITfContext* context, ITfRange* range, LONG offset) {
    Releaser<ITfRange> caret;
    caret.pointer = SubRange(cookie, range, offset, offset);
    if (!caret) return;
    TF_SELECTION selection{};
    selection.range = caret.pointer;
    selection.style.ase = TF_AE_NONE;
    selection.style.fInterimChar = FALSE;
    context->SetSelection(cookie, 1, &selection);
}

std::optional<RECT> CompositionWriter::ScreenRectangle(TfEditCookie cookie, ITfContext* context, ITfRange* range) {
    Releaser<ITfContextView> view;
    if (FAILED(context->GetActiveView(&view))) return std::nullopt;
    RECT rectangle{};
    BOOL clipped = FALSE;
    if (FAILED(view->GetTextExt(cookie, range, &rectangle, &clipped))) return std::nullopt;
    // DPI-unaware applications report logical coordinates; the list is
    // positioned in physical pixels.
    HWND window = nullptr;
    if (SUCCEEDED(view->GetWnd(&window)) && window) {
        POINT topLeft{rectangle.left, rectangle.top};
        POINT bottomRight{rectangle.right, rectangle.bottom};
        LogicalToPhysicalPointForPerMonitorDPI(window, &topLeft);
        LogicalToPhysicalPointForPerMonitorDPI(window, &bottomRight);
        rectangle = {topLeft.x, topLeft.y, bottomRight.x, bottomRight.y};
    }
    return rectangle;
}

InputField CompositionWriter::ReadInputField(TfEditCookie cookie, ITfContext* context) {
    InputField field;
    TF_SELECTION selection{};
    ULONG fetched = 0;
    if (FAILED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) || fetched == 0) return field;
    Releaser<ITfRange> caret;
    caret.pointer = selection.range;

    Releaser<ITfReadOnlyProperty> scopeProperty;
    if (SUCCEEDED(context->GetAppProperty(kInputScopeProperty, &scopeProperty))) {
        VARIANT value;
        VariantInit(&value);
        if (SUCCEEDED(scopeProperty->GetValue(cookie, caret.pointer, &value)) && value.vt == VT_UNKNOWN && value.punkVal) {
            Releaser<ITfInputScope> inputScope;
            if (SUCCEEDED(value.punkVal->QueryInterface(IID_ITfInputScope, reinterpret_cast<void**>(&inputScope)))) {
                InputScope* scopes = nullptr;
                UINT count = 0;
                if (SUCCEEDED(inputScope->GetInputScopes(&scopes, &count))) {
                    for (UINT i = 0; i < count; ++i) field.privateInput = field.privateInput || IsPrivateScope(scopes[i]);
                    CoTaskMemFree(scopes);
                }
            }
        }
        VariantClear(&value);
    }

    Releaser<ITfRange> before;
    if (SUCCEEDED(caret->Clone(&before))) {
        LONG moved = 0;
        before->Collapse(cookie, TF_ANCHOR_START);
        TF_HALTCOND halt{};
        halt.dwFlags = TF_HF_OBJECT;
        before->ShiftStart(cookie, -kLeftContextUnits, &moved, &halt);
        wchar_t buffer[kLeftContextUnits + 1];
        ULONG length = 0;
        if (SUCCEEDED(before->GetText(cookie, 0, buffer, kLeftContextUnits, &length))) {
            field.leftContext.assign(buffer, length);
        }
    }
    return field;
}

}  // namespace azookey::tsf
