// Gives each control of a window a unique id and runs the control's handler
// when WM_COMMAND or WM_NOTIFY names that id.
#pragma once

#include <functional>
#include <unordered_map>

namespace azookey::settings {

class CommandMap {
public:
    // `notification` is the WM_COMMAND notification code (BN_CLICKED, CBN_SELCHANGE, ...)
    // or the WM_NOTIFY code (NM_CLICK, ...).
    using Handler = std::function<void(unsigned notification)>;

    int Register(Handler handler);
    // An id for a control whose notifications nobody handles.
    int Reserve() { return nextId_++; }
    // Returns false when no handler has `id`.
    bool Dispatch(int id, unsigned notification) const;

private:
    // Below this, ids belong to the dialog manager (IDOK, IDCANCEL, ...).
    static constexpr int kFirstId = 1000;

    int nextId_ = kFirstId;
    std::unordered_map<int, Handler> handlers_;
};

}  // namespace azookey::settings
