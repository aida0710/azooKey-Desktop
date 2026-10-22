#include "composition_writer.h"

#include <inputscope.h>

#include <algorithm>

#include "shared/text_encoding.h"

namespace azookey::tsf {
namespace {

// Matches the context the bridge keeps (DesktopSession).
constexpr LONG kLeftContextUnits = 100;
// Enough UTF-16 units for Core's 256-scalar reconversion window even when every
// character is a surrogate pair.
constexpr LONG kSurroundingReadUnits = 512;

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

struct Extent {
    LONG start = 0;   // UTF-16 units from the start of the document
    LONG length = 0;
};

// Character positions let Core compare the field between requests. Documents
// without them (anchor-based text stores) get no reconversion.
std::optional<Extent> DocumentExtent(ITfRange* range) {
    Releaser<ITfRangeACP> characters;
    if (FAILED(range->QueryInterface(IID_ITfRangeACP, reinterpret_cast<void**>(&characters)))) return std::nullopt;
    Extent extent;
    if (FAILED(characters->GetExtent(&extent.start, &extent.length))) return std::nullopt;
    return extent;
}

std::wstring ReadRange(TfEditCookie cookie, ITfRange* range, LONG maximumUnits) {
    std::wstring text(static_cast<size_t>(maximumUnits), L'\0');
    ULONG length = 0;
    if (FAILED(range->GetText(cookie, 0, text.data(), static_cast<ULONG>(maximumUnits), &length))) return {};
    text.resize(length);
    return text;
}

// Text before (negative `units`) or after the given end of `range`, stopping at
// embedded objects.
std::wstring ReadBeside(TfEditCookie cookie, ITfRange* range, TfAnchor end, LONG units) {
    ITfRange* beside = nullptr;
    if (FAILED(range->Clone(&beside))) return {};
    LONG moved = 0;
    TF_HALTCOND halt{};
    halt.dwFlags = TF_HF_OBJECT;
    beside->Collapse(cookie, end);
    if (units < 0) beside->ShiftStart(cookie, units, &moved, &halt);
    else beside->ShiftEnd(cookie, units, &moved, &halt);
    std::wstring text = ReadRange(cookie, beside, units < 0 ? -units : units);
    beside->Release();
    return text;
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

std::optional<CompositionGeometry> CompositionWriter::Apply(TfEditCookie cookie, ITfContext* context,
                                                            const protocol::Snapshot& snapshot, ITfComposition** composition) {
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
    auto rectangle = ScreenRectangle(cookie, context, range.pointer);
    if (!rectangle) return std::nullopt;
    return CompositionGeometry{*rectangle, WordRectangles(cookie, context, range.pointer, snapshot)};
}

std::vector<RECT> CompositionWriter::WordRectangles(TfEditCookie cookie, ITfContext* context, ITfRange* range,
                                                    const protocol::Snapshot& snapshot) {
    std::vector<std::wstring> words;
    std::wstring joined;
    for (const auto& column : snapshot.columns) {
        const protocol::TreeNode* node = column.empty() ? nullptr : snapshot.FindNode(column.front());
        if (!node) return {};
        words.push_back(node->text);
        joined += node->text;
    }
    // Live conversion shows the chosen words as the preedit; any other preedit
    // (romaji in progress, a converted clause) has no word-for-word match.
    if (words.empty() || joined != snapshot.preedit) return {};
    std::vector<RECT> rectangles;
    LONG start = 0;
    for (const auto& word : words) {
        LONG end = start + static_cast<LONG>(word.size());
        Releaser<ITfRange> wordRange;
        wordRange.pointer = SubRange(cookie, range, start, end);
        auto rectangle = wordRange ? ScreenRectangle(cookie, context, wordRange.pointer) : std::nullopt;
        if (!rectangle) return {};
        rectangles.push_back(*rectangle);
        start = end;
    }
    return rectangles;
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
            TfGuidAtom atom = segment.focus == protocol::SegmentFocus::Focused     ? atoms_.targetClause
                              : segment.focus == protocol::SegmentFocus::Unfocused ? atoms_.convertedClause
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
    protocol::DocumentContext& document = field.document;
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
                    for (UINT i = 0; i < count; ++i) document.privateInput = document.privateInput || IsPrivateScope(scopes[i]);
                    CoTaskMemFree(scopes);
                }
            }
        }
        VariantClear(&value);
    }

    std::wstring before = ReadBeside(cookie, caret.pointer, TF_ANCHOR_START, -kSurroundingReadUnits);
    document.leftContext = before.size() > static_cast<size_t>(kLeftContextUnits) ? before.substr(before.size() - kLeftContextUnits) : before;
    field.caret = ScreenRectangle(cookie, context, caret.pointer);

    auto extent = DocumentExtent(caret.pointer);
    std::wstring selected = ReadRange(cookie, caret.pointer, kSurroundingReadUnits + 1);
    if (!extent || static_cast<LONG>(selected.size()) != extent->length ||
        text::ScalarCount(selected) > protocol::kReconversionContextLimit) {
        return field;  // no character positions, or a selection Core does not reconvert
    }
    TF_STATUS status{};
    bool readOnly = SUCCEEDED(context->GetStatus(&status)) && (status.dwDynamicFlags & TF_SD_READONLY);
    protocol::ReconversionContext reconversion;
    reconversion.before = text::LastScalars(before, protocol::kReconversionContextLimit);
    reconversion.selected = selected;
    reconversion.after = text::FirstScalars(ReadBeside(cookie, caret.pointer, TF_ANCHOR_END, kSurroundingReadUnits),
                                            protocol::kReconversionContextLimit);
    int start = static_cast<int>(extent->start);
    int end = start + static_cast<int>(extent->length);
    bool caretAtStart = selection.style.ase == TF_AE_START;
    reconversion.cursorUTF16 = caretAtStart ? start : end;
    reconversion.anchorUTF16 = caretAtStart ? end : start;
    reconversion.canReplace = !readOnly;
    reconversion.isSensitive = document.privateInput;
    document.reconversion = reconversion;
    return field;
}

ITfRange* CompositionWriter::FindReplacedText(TfEditCookie cookie, ITfContext* context, const ReconversionEdit& edit) {
    const protocol::ReconversionContext& source = edit.source;
    const protocol::ReconversionReplacement& replacement = edit.replacement;
    TF_SELECTION selection{};
    ULONG fetched = 0;
    if (FAILED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) || fetched == 0) return nullptr;
    Releaser<ITfRange> current;
    current.pointer = selection.range;
    LONG selectionStart = std::min(source.cursorUTF16, source.anchorUTF16);
    auto extent = DocumentExtent(current.pointer);
    if (!extent || extent->start != selectionStart || replacement.count <= 0) return nullptr;

    // Core counts `offset` in scalars from the caret, inside the window it was sent.
    std::wstring window = source.before + source.selected + source.after;
    size_t caretInWindow = source.before.size() + (source.cursorUTF16 > source.anchorUTF16 ? source.selected.size() : 0);
    LONG firstScalar = static_cast<LONG>(text::ScalarCount(window.substr(0, caretInWindow))) + replacement.offset;
    if (firstScalar < 0) return nullptr;
    size_t first = text::ScalarOffsetToUtf16(window, static_cast<size_t>(firstScalar));
    size_t last = text::ScalarOffsetToUtf16(window, static_cast<size_t>(firstScalar + replacement.count));
    if (window.compare(first, last - first, replacement.text) != 0) return nullptr;

    // Move from the selection start (which is `before.size()` into the window).
    ITfRange* target = nullptr;
    if (FAILED(current->Clone(&target))) return nullptr;
    LONG shift = static_cast<LONG>(first) - static_cast<LONG>(source.before.size());
    LONG length = static_cast<LONG>(last - first);
    LONG moved = 0;
    target->Collapse(cookie, TF_ANCHOR_START);
    bool placed = SUCCEEDED(target->ShiftStart(cookie, shift, &moved, nullptr)) && moved == shift;
    target->Collapse(cookie, TF_ANCHOR_START);
    placed = placed && SUCCEEDED(target->ShiftEnd(cookie, length, &moved, nullptr)) && moved == length;
    if (!placed || ReadRange(cookie, target, length + 1) != replacement.text) {
        target->Release();
        return nullptr;
    }
    return target;
}

ReconversionOutcome CompositionWriter::Reconvert(TfEditCookie cookie, ITfContext* context, const ReconversionEdit& edit,
                                                 ITfComposition** composition) {
    ReconversionOutcome outcome;
    Releaser<ITfRange> target;
    target.pointer = FindReplacedText(cookie, context, edit);
    if (!target) return outcome;
    const std::wstring& text = edit.replacement.text;
    if (FAILED(target->SetText(cookie, 0, L"", 0))) return outcome;
    PlaceCaret(cookie, context, target.pointer, 0);

    outcome.reply = edit.confirm(ReadInputField(cookie, context).document);
    bool accepted = outcome.reply && outcome.reply->reconversionError.empty() && !outcome.reply->preedit.empty();
    if (!accepted) {
        target->SetText(cookie, 0, text.c_str(), static_cast<LONG>(text.size()));
        PlaceCaret(cookie, context, target.pointer, static_cast<LONG>(text.size()));
        outcome.result = ReconversionResult::Declined;
        return outcome;
    }
    outcome.result = ReconversionResult::Restored;
    outcome.geometry = Apply(cookie, context, *outcome.reply, composition);
    return outcome;
}

}  // namespace azookey::tsf
