// Writes what the converter returned into the application's document: commits
// confirmed text, keeps the preedit in a TSF composition with clause
// underlines and the caret, and reads the field around the caret. Every
// function runs inside an edit session (`cookie`).
#pragma once

#include <msctf.h>

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

struct InputField {
    bool privateInput = false;  // password and PIN fields
    std::wstring leftContext;   // text before the caret
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

private:
    void ReplaceComposition(TfEditCookie cookie, ITfContext* context, const std::wstring& text, ITfComposition** composition);
    void ApplyClauseAttributes(TfEditCookie cookie, ITfContext* context, ITfRange* range, const protocol::Snapshot& snapshot);
    static void ClearClauseAttributes(TfEditCookie cookie, ITfContext* context, ITfRange* range);
    static void PlaceCaret(TfEditCookie cookie, ITfContext* context, ITfRange* range, LONG offset);
    static std::optional<RECT> ScreenRectangle(TfEditCookie cookie, ITfContext* context, ITfRange* range);
    static std::vector<RECT> WordRectangles(TfEditCookie cookie, ITfContext* context, ITfRange* range,
                                            const protocol::Snapshot& snapshot);

    ITfCompositionSink* sink_;
    ClauseAttributeAtoms atoms_;
};

}  // namespace azookey::tsf
