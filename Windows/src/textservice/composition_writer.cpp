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

std::wstring LastUnits(const std::wstring& text, LONG units) {
    return text.size() > static_cast<size_t>(units) ? text.substr(text.size() - units) : text;
}

// What ReadInputField read around the selection.
struct SelectionText {
    std::wstring before;
    std::wstring selected;
    std::wstring after;
    bool caretAtStart = false;  // the caret is at the selection's start (selected leftwards)
};

protocol::AISurrounding SurroundingOf(const SelectionText& text) {
    int start = static_cast<int>(text.before.size());
    int end = start + static_cast<int>(text.selected.size());
    return {text.before + text.selected + text.after, text.caretAtStart ? start : end, text.caretAtStart ? end : start};
}

// Core compares the positions between requests, so they count from the document start.
protocol::ReconversionContext ReconversionContextOf(const SelectionText& text, const Extent& extent, bool canReplace,
                                                    bool isSensitive) {
    protocol::ReconversionContext reconversion;
    reconversion.before = text::LastScalars(text.before, protocol::kReconversionContextLimit);
    reconversion.selected = text.selected;
    reconversion.after = text::FirstScalars(text.after, protocol::kReconversionContextLimit);
    int start = static_cast<int>(extent.start);
    int end = start + static_cast<int>(extent.length);
    reconversion.cursorUTF16 = text.caretAtStart ? start : end;
    reconversion.anchorUTF16 = text.caretAtStart ? end : start;
    reconversion.canReplace = canReplace;
    reconversion.isSensitive = isSensitive;
    return reconversion;
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

// Password and PIN fields, by the input scope the application gives the caret.
bool IsPrivateField(TfEditCookie cookie, ITfContext* context, ITfRange* caret) {
    bool privateInput = false;
    Releaser<ITfReadOnlyProperty> scopeProperty;
    if (FAILED(context->GetAppProperty(kInputScopeProperty, &scopeProperty))) return false;
    VARIANT value;
    VariantInit(&value);
    if (SUCCEEDED(scopeProperty->GetValue(cookie, caret, &value)) && value.vt == VT_UNKNOWN && value.punkVal) {
        Releaser<ITfInputScope> inputScope;
        if (SUCCEEDED(value.punkVal->QueryInterface(IID_ITfInputScope, reinterpret_cast<void**>(&inputScope)))) {
            InputScope* scopes = nullptr;
            UINT count = 0;
            if (SUCCEEDED(inputScope->GetInputScopes(&scopes, &count))) {
                for (UINT i = 0; i < count; ++i) privateInput = privateInput || IsPrivateScope(scopes[i]);
                CoTaskMemFree(scopes);
            }
        }
    }
    VariantClear(&value);
    return privateInput;
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
    TF_SELECTION selection{};
    ULONG fetched = 0;
    if (FAILED(context->GetSelection(cookie, TF_DEFAULT_SELECTION, 1, &selection, &fetched)) || fetched == 0) return field;
    Releaser<ITfRange> caret;
    caret.pointer = selection.range;

    field.document.privateInput = IsPrivateField(cookie, context, caret.pointer);
    SelectionText text;
    text.before = ReadBeside(cookie, caret.pointer, TF_ANCHOR_START, -kSurroundingReadUnits);
    text.selected = ReadRange(cookie, caret.pointer, kSurroundingReadUnits + 1);
    text.after = ReadBeside(cookie, caret.pointer, TF_ANCHOR_END, kSurroundingReadUnits);
    text.caretAtStart = selection.style.ase == TF_AE_START;
    field.document.leftContext = LastUnits(text.before, kLeftContextUnits);
    field.caret = ScreenRectangle(cookie, context, caret.pointer);
    field.hasSelection = !text.selected.empty();
    // A selection longer than the read is described by nothing below.
    if (static_cast<LONG>(text.selected.size()) > kSurroundingReadUnits) return field;
    field.surrounding = SurroundingOf(text);

    auto extent = DocumentExtent(caret.pointer);
    if (!extent || static_cast<LONG>(text.selected.size()) != extent->length) return field;
    field.selectionExtent = std::make_pair(static_cast<int>(extent->start), static_cast<int>(extent->start + extent->length));
    if (text::ScalarCount(text.selected) > protocol::kReconversionContextLimit) return field;
    TF_STATUS status{};
    bool readOnly = SUCCEEDED(context->GetStatus(&status)) && (status.dwDynamicFlags & TF_SD_READONLY);
    field.document.reconversion = ReconversionContextOf(text, *extent, !readOnly, field.document.privateInput);
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
