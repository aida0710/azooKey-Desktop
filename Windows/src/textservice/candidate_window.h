// The candidate list shown while converting: a small numbered page of up to
// nine candidates under the composition. It never takes focus from the
// application; clicking a row confirms that candidate.
#pragma once

#include <windows.h>

#include <functional>
#include <string>
#include <vector>

#include "shared/bridge_protocol.h"

namespace azookey::tsf {

class CandidateWindow {
public:
    using ChooseHandler = std::function<void(int candidateIndex)>;

    explicit CandidateWindow(ChooseHandler onChoose);
    ~CandidateWindow();
    CandidateWindow(const CandidateWindow&) = delete;
    CandidateWindow& operator=(const CandidateWindow&) = delete;

    // `anchor` is the composition's rectangle in physical screen pixels.
    void Show(const protocol::Snapshot& snapshot, const RECT& anchor);
    void Hide();
    bool visible() const { return window_ && IsWindowVisible(window_); }

    // Must run before the DLL unloads so no window class points into freed code.
    static void UnregisterWindowClass();

private:
    static LRESULT CALLBACK WindowProcedure(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
    bool EnsureWindow();
    void UpdateFonts(UINT dpi);
    SIZE MeasureContent(HDC dc);
    void Paint(HDC dc);
    int RowAt(POINT point) const;

    struct Row {
        int candidateIndex;
        std::wstring number;
        std::wstring text;
    };

    ChooseHandler onChoose_;
    HWND window_ = nullptr;
    HFONT textFont_ = nullptr;
    HFONT detailFont_ = nullptr;
    UINT fontDpi_ = 0;
    std::vector<Row> rows_;
    int selectedRow_ = -1;
    std::wstring footer_;
    std::wstring annotation_;
    int rowHeight_ = 0;
    int padding_ = 0;
    int numberWidth_ = 0;
    int footerHeight_ = 0;
};

}  // namespace azookey::tsf
