// The input mode indicator on the taskbar (GUID_LBI_INPUTMODE): あ while
// Japanese input is on, A while it is off. A left click switches; a right
// click opens the menu (switch, undo the last commit, reconvert the selection,
// settings, user dictionary).
#pragma once

#include <msctf.h>

#include <functional>

namespace azookey::tsf {

class InputModeButton final : public ITfLangBarItemButton, public ITfSource {
public:
    struct Actions {
        std::function<void()> toggleInput;
        std::function<void()> undoCommit;
        std::function<void()> reconvertSelection;
        std::function<void()> openSettings;
        std::function<void()> openDictionary;
    };

    explicit InputModeButton(Actions actions);

    // Redraws the indicator after the input mode changed.
    void SetJapanese(bool japanese);

    // IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, void** object) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    // ITfLangBarItem
    STDMETHODIMP GetInfo(TF_LANGBARITEMINFO* info) override;
    STDMETHODIMP GetStatus(DWORD* status) override;
    STDMETHODIMP Show(BOOL) override { return E_NOTIMPL; }
    STDMETHODIMP GetTooltipString(BSTR* tooltip) override;

    // ITfLangBarItemButton
    STDMETHODIMP OnClick(TfLBIClick click, POINT point, const RECT* area) override;
    STDMETHODIMP InitMenu(ITfMenu* menu) override;
    STDMETHODIMP OnMenuSelect(UINT id) override;
    STDMETHODIMP GetIcon(HICON* icon) override;
    STDMETHODIMP GetText(BSTR* text) override;

    // ITfSource
    STDMETHODIMP AdviseSink(REFIID riid, IUnknown* sink, DWORD* cookie) override;
    STDMETHODIMP UnadviseSink(DWORD cookie) override;

private:
    ~InputModeButton();
    void Run(UINT id);

    LONG references_ = 1;
    Actions actions_;
    bool japanese_ = true;
    ITfLangBarItemSink* sink_ = nullptr;
};

}  // namespace azookey::tsf
