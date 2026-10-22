#include "input_mode_button.h"

#include <olectl.h>

#include <new>

#include "guids.h"
#include "module.h"
#include "resource.h"
#include "shared/ui_language.h"

namespace azookey::tsf {
namespace {

// Any value works as long as it is ours; TSF only hands it back to AdviseSink callers.
constexpr DWORD kSinkCookie = 1;

// GUID_LBI_INPUTMODE (Windows 8 SDK documentation); the SDK headers do not declare it.
constexpr GUID kInputModeItemGuid = {0x2c77a81e, 0x41cc, 0x4178, {0xa3, 0xa7, 0x5f, 0x8a, 0x98, 0x75, 0x68, 0xe6}};

std::wstring Message(const char* key) { return messages::Text(key, messages::CurrentUiLanguage()); }

}  // namespace

InputModeButton::InputModeButton(Actions actions) : actions_(std::move(actions)) { AddModuleReference(); }

InputModeButton::~InputModeButton() {
    if (sink_) sink_->Release();
    ReleaseModuleReference();
}

void InputModeButton::SetJapanese(bool japanese) {
    if (japanese == japanese_) return;
    japanese_ = japanese;
    if (sink_) sink_->OnUpdate(TF_LBI_ICON | TF_LBI_TEXT | TF_LBI_TOOLTIP);
}

STDMETHODIMP InputModeButton::QueryInterface(REFIID riid, void** object) {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (riid == IID_IUnknown || riid == IID_ITfLangBarItem || riid == IID_ITfLangBarItemButton) {
        *object = static_cast<ITfLangBarItemButton*>(this);
    } else if (riid == IID_ITfSource) {
        *object = static_cast<ITfSource*>(this);
    }
    if (!*object) return E_NOINTERFACE;
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) InputModeButton::AddRef() { return InterlockedIncrement(&references_); }

STDMETHODIMP_(ULONG) InputModeButton::Release() {
    LONG remaining = InterlockedDecrement(&references_);
    if (remaining == 0) delete this;
    return remaining;
}

STDMETHODIMP InputModeButton::GetInfo(TF_LANGBARITEMINFO* info) {
    if (!info) return E_INVALIDARG;
    info->clsidService = kTextServiceClsid;
    // Windows 8 and later show this item as the taskbar's input mode indicator.
    info->guidItem = kInputModeItemGuid;
    info->dwStyle = TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_SHOWNINTRAY;
    info->ulSort = 0;
    lstrcpynW(info->szDescription, Message("input.menu.toggleMode").c_str(), ARRAYSIZE(info->szDescription));
    return S_OK;
}

STDMETHODIMP InputModeButton::GetStatus(DWORD* status) {
    if (!status) return E_INVALIDARG;
    *status = 0;
    return S_OK;
}

STDMETHODIMP InputModeButton::GetTooltipString(BSTR* tooltip) {
    if (!tooltip) return E_INVALIDARG;
    *tooltip = SysAllocString(Message("input.menu.toggleMode").c_str());
    return *tooltip ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP InputModeButton::OnClick(TfLBIClick click, POINT point, const RECT*) {
    if (click == TF_LBI_CLK_LEFT) {
        Run(kToggle);
        return S_OK;
    }
    // The taskbar indicator does not ask for InitMenu, so the right-click menu is ours.
    HMENU menu = CreatePopupMenu();
    if (!menu) return E_OUTOFMEMORY;
    AppendMenuW(menu, MF_STRING, kToggle, Message("input.menu.toggleMode").c_str());
    AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(menu, MF_STRING, kSettings, Message("input.menu.settings").c_str());
    AppendMenuW(menu, MF_STRING, kDictionary, Message("input.menu.dictionary").c_str());
    UINT chosen = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, point.x, point.y, GetFocus(), nullptr);
    DestroyMenu(menu);
    if (chosen != 0) Run(chosen);
    return S_OK;
}

STDMETHODIMP InputModeButton::InitMenu(ITfMenu* menu) {
    if (!menu) return E_INVALIDARG;
    // The classic language bar builds the same menu through ITfMenu.
    auto add = [&](UINT id, const std::wstring& text) {
        menu->AddMenuItem(id, 0, nullptr, nullptr, text.c_str(), static_cast<ULONG>(text.size()), nullptr);
    };
    add(kToggle, Message("input.menu.toggleMode"));
    menu->AddMenuItem(0, TF_LBMENUF_SEPARATOR, nullptr, nullptr, nullptr, 0, nullptr);
    add(kSettings, Message("input.menu.settings"));
    add(kDictionary, Message("input.menu.dictionary"));
    return S_OK;
}

STDMETHODIMP InputModeButton::OnMenuSelect(UINT id) {
    Run(id);
    return S_OK;
}

void InputModeButton::Run(UINT id) {
    switch (id) {
    case kToggle:
        if (actions_.toggleInput) actions_.toggleInput();
        break;
    case kSettings:
        if (actions_.openSettings) actions_.openSettings();
        break;
    case kDictionary:
        if (actions_.openDictionary) actions_.openDictionary();
        break;
    default:
        break;
    }
}

STDMETHODIMP InputModeButton::GetIcon(HICON* icon) {
    if (!icon) return E_INVALIDARG;
    int size = GetSystemMetrics(SM_CXSMICON);
    *icon = static_cast<HICON>(LoadImageW(ModuleInstance(), MAKEINTRESOURCEW(japanese_ ? IDI_TEXT_SERVICE : IDI_INPUT_OFF), IMAGE_ICON,
                                          size, size, LR_DEFAULTCOLOR));
    return *icon ? S_OK : E_FAIL;
}

STDMETHODIMP InputModeButton::GetText(BSTR* text) {
    if (!text) return E_INVALIDARG;
    *text = SysAllocString(Message(japanese_ ? "input.mode.japanese" : "input.mode.alphanumeric").c_str());
    return *text ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP InputModeButton::AdviseSink(REFIID riid, IUnknown* sink, DWORD* cookie) {
    if (!sink || !cookie) return E_INVALIDARG;
    if (riid != IID_ITfLangBarItemSink) return CONNECT_E_CANNOTCONNECT;
    if (sink_) return CONNECT_E_ADVISELIMIT;
    if (FAILED(sink->QueryInterface(IID_ITfLangBarItemSink, reinterpret_cast<void**>(&sink_)))) {
        sink_ = nullptr;
        return E_NOINTERFACE;
    }
    *cookie = kSinkCookie;
    return S_OK;
}

STDMETHODIMP InputModeButton::UnadviseSink(DWORD cookie) {
    if (cookie != kSinkCookie || !sink_) return CONNECT_E_NOCONNECTION;
    sink_->Release();
    sink_ = nullptr;
    return S_OK;
}

}  // namespace azookey::tsf
