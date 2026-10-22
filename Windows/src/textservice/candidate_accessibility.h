// UI Automation for the candidate panel: the panel is a list whose items carry
// the candidate text, report which one is selected, and can be selected or
// confirmed by assistive technology. Selection changes are announced.
#pragma once

#include <windows.h>
// WIN32_LEAN_AND_MEAN leaves out the COM declarations UI Automation needs.
#include <ole2.h>
#include <uiautomation.h>

#include <functional>
#include <string>
#include <vector>

namespace azookey::tsf {

struct AccessibleCandidate {
    int candidateIndex = 0;
    std::wstring name;   // what a screen reader says for the item
    RECT bounds{};       // physical screen pixels
    bool selected = false;
};

class CandidateAccessibility {
public:
    struct Actions {
        std::function<void(int candidateIndex)> select;
        std::function<void(int candidateIndex)> confirm;
    };

    CandidateAccessibility(HWND window, Actions actions);
    ~CandidateAccessibility();
    CandidateAccessibility(const CandidateAccessibility&) = delete;
    CandidateAccessibility& operator=(const CandidateAccessibility&) = delete;

    // Replaces the items; announces `announcement` when the selection changed.
    void Update(std::vector<AccessibleCandidate> items, const std::wstring& announcement);
    void Clear();
    // WM_GETOBJECT handling for the panel window.
    LRESULT HandleGetObject(WPARAM wParam, LPARAM lParam);

    class ListProvider;
    class ItemProvider;

private:
    friend class ListProvider;
    friend class ItemProvider;

    HWND window_;
    Actions actions_;
    ListProvider* list_ = nullptr;
    std::vector<ItemProvider*> items_;
    std::vector<AccessibleCandidate> data_;
    int selectedIndex_ = -1;
};

}  // namespace azookey::tsf
