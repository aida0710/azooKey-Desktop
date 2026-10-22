// Writes what the converter returned into the application's document: commits
// confirmed text, keeps the preedit in a TSF composition with clause
// underlines and the caret, and reads the field around the caret. Every
// function runs inside an edit session (`cookie`).
#pragma once

#include <msctf.h>

#include <functional>
#include <optional>
#include <string>
#include <vector>

#include "shared/bridge_protocol.h"

namespace azookey::tsf {

struct ClauseAttributeAtoms {
    TfGuidAtom input = TF_INVALID_GUIDATOM;
    TfGuidAtom targetClause = TF_INVALID_GUIDATOM;
    TfGuidAtom convertedClause = TF_INVALID_GUIDATOM;
};

// Where the composition is on screen, in physical pixels. `words` has one
// rectangle per tree column when the preedit is exactly the chosen words, so
// the tree can line its columns up under them.
struct CompositionGeometry {
    RECT composition{};
    std::vector<RECT> words;
};

// The field around the selection. `document.reconversion` is missing when the
// selection is longer than Core reconverts or the document has no character
// positions (ITfRangeACP).
struct InputField {
    protocol::DocumentContext document;
    std::optional<RECT> caret;  // physical screen pixels
};

// One undo of a commit or reconversion of a selection, as Core asked for it.
struct ReconversionEdit {
    protocol::ReconversionReplacement replacement;
    protocol::ReconversionContext source;  // the field Core chose `replacement` from
    // Asks Core to restore the composition once the text is out of the document;
    // `removed` is the field read after the removal.
    std::function<std::optional<protocol::Snapshot>(const protocol::DocumentContext& removed)> confirm;
};

enum class ReconversionResult {
    DocumentChanged,  // the text was not where Core said; nothing was touched
    Declined,         // Core (or the converter being gone) said no; the text is back
    Restored,         // the text is now the composition
};

struct ReconversionOutcome {
    ReconversionResult result = ReconversionResult::DocumentChanged;
    std::optional<protocol::Snapshot> reply;  // Core's answer to `confirm`, when it gave one
    std::optional<CompositionGeometry> geometry;  // where the restored composition is
};

class CompositionWriter {
public:
    CompositionWriter(ITfCompositionSink* sink, ClauseAttributeAtoms atoms) : sink_(sink), atoms_(atoms) {}

    // Applies `snapshot`; `composition` is the live composition (or nullptr)
    // and is updated when one starts or ends. Returns where the composition is
    // when one remains, for placing the candidate panel.
    std::optional<CompositionGeometry> Apply(TfEditCookie cookie, ITfContext* context, const protocol::Snapshot& snapshot,
                                             ITfComposition** composition);

    // Leaves `text` in the document in place of the composition (used when the
    // converter is unavailable or focus moves away).
    void Finish(TfEditCookie cookie, ITfContext* context, const std::wstring& text, ITfComposition** composition);

    // Inserts text at the caret without a composition.
    void Insert(TfEditCookie cookie, ITfContext* context, const std::wstring& text);

    static InputField ReadInputField(TfEditCookie cookie, ITfContext* context);

    // Takes the replaced text out of the document, asks Core, and writes the
    // restored composition in its place. When Core declines, the text goes back.
    ReconversionOutcome Reconvert(TfEditCookie cookie, ITfContext* context, const ReconversionEdit& edit, ITfComposition** composition);

private:
    void ReplaceComposition(TfEditCookie cookie, ITfContext* context, const std::wstring& text, ITfComposition** composition);
    void ApplyClauseAttributes(TfEditCookie cookie, ITfContext* context, ITfRange* range, const protocol::Snapshot& snapshot);
    static void ClearClauseAttributes(TfEditCookie cookie, ITfContext* context, ITfRange* range);
    static void PlaceCaret(TfEditCookie cookie, ITfContext* context, ITfRange* range, LONG offset);
    static std::optional<RECT> ScreenRectangle(TfEditCookie cookie, ITfContext* context, ITfRange* range);
    static std::vector<RECT> WordRectangles(TfEditCookie cookie, ITfContext* context, ITfRange* range,
                                            const protocol::Snapshot& snapshot);
    // The range holding `edit.replacement` now, or nullptr when the document changed.
    static ITfRange* FindReplacedText(TfEditCookie cookie, ITfContext* context, const ReconversionEdit& edit);

    ITfCompositionSink* sink_;
    ClauseAttributeAtoms atoms_;
};

}  // namespace azookey::tsf
