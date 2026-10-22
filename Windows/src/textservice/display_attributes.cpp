#include "display_attributes.h"

#include <algorithm>
#include <new>

#include "guids.h"
#include "module.h"

namespace azookey::tsf {
namespace {

constexpr ClauseStyle kStyles[] = {ClauseStyle::Input, ClauseStyle::TargetClause, ClauseStyle::ConvertedClause};

// Colors are left to the application (TF_CT_NONE) so the composition follows
// its theme, including high contrast; only the underline differs.
TF_DISPLAYATTRIBUTE AttributeFor(ClauseStyle style) {
    TF_DISPLAYATTRIBUTE attribute{};
    attribute.crText.type = TF_CT_NONE;
    attribute.crBk.type = TF_CT_NONE;
    attribute.crLine.type = TF_CT_NONE;
    attribute.fBoldLine = FALSE;
    switch (style) {
    case ClauseStyle::Input:
        attribute.lsStyle = TF_LS_DOT;
        attribute.bAttr = TF_ATTR_INPUT;
        break;
    case ClauseStyle::TargetClause:
        attribute.lsStyle = TF_LS_SOLID;
        attribute.fBoldLine = TRUE;
        attribute.bAttr = TF_ATTR_TARGET_CONVERTED;
        break;
    case ClauseStyle::ConvertedClause:
        attribute.lsStyle = TF_LS_SOLID;
        attribute.bAttr = TF_ATTR_CONVERTED;
        break;
    }
    return attribute;
}

const wchar_t* DescriptionFor(ClauseStyle style) {
    switch (style) {
    case ClauseStyle::Input: return L"azooKey Tree 入力中";
    case ClauseStyle::TargetClause: return L"azooKey Tree 変換中の文節";
    case ClauseStyle::ConvertedClause: return L"azooKey Tree 変換済みの文節";
    }
    return L"";
}

}  // namespace

const GUID& ClauseStyleGuid(ClauseStyle style) {
    switch (style) {
    case ClauseStyle::TargetClause: return kTargetClauseAttributeGuid;
    case ClauseStyle::ConvertedClause: return kConvertedClauseAttributeGuid;
    case ClauseStyle::Input: break;
    }
    return kInputAttributeGuid;
}

DisplayAttributeInfo* CreateDisplayAttributeInfo(const GUID& guid) {
    for (ClauseStyle style : kStyles) {
        if (IsEqualGUID(guid, ClauseStyleGuid(style))) return new (std::nothrow) DisplayAttributeInfo(style);
    }
    return nullptr;
}

DisplayAttributeInfo::DisplayAttributeInfo(ClauseStyle style) : style_(style) { AddModuleReference(); }
DisplayAttributeInfo::~DisplayAttributeInfo() { ReleaseModuleReference(); }

STDMETHODIMP DisplayAttributeInfo::QueryInterface(REFIID riid, void** object) {
    if (!object) return E_INVALIDARG;
    if (riid == IID_IUnknown || riid == IID_ITfDisplayAttributeInfo) {
        *object = static_cast<ITfDisplayAttributeInfo*>(this);
        AddRef();
        return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) DisplayAttributeInfo::AddRef() { return InterlockedIncrement(&references_); }

STDMETHODIMP_(ULONG) DisplayAttributeInfo::Release() {
    LONG remaining = InterlockedDecrement(&references_);
    if (remaining == 0) delete this;
    return remaining;
}

STDMETHODIMP DisplayAttributeInfo::GetGUID(GUID* guid) {
    if (!guid) return E_INVALIDARG;
    *guid = ClauseStyleGuid(style_);
    return S_OK;
}

STDMETHODIMP DisplayAttributeInfo::GetDescription(BSTR* description) {
    if (!description) return E_INVALIDARG;
    *description = SysAllocString(DescriptionFor(style_));
    return *description ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP DisplayAttributeInfo::GetAttributeInfo(TF_DISPLAYATTRIBUTE* attribute) {
    if (!attribute) return E_INVALIDARG;
    *attribute = AttributeFor(style_);
    return S_OK;
}

STDMETHODIMP DisplayAttributeInfo::SetAttributeInfo(const TF_DISPLAYATTRIBUTE*) { return E_NOTIMPL; }
STDMETHODIMP DisplayAttributeInfo::Reset() { return S_OK; }

EnumDisplayAttributeInfo::EnumDisplayAttributeInfo() { AddModuleReference(); }
EnumDisplayAttributeInfo::~EnumDisplayAttributeInfo() { ReleaseModuleReference(); }

STDMETHODIMP EnumDisplayAttributeInfo::QueryInterface(REFIID riid, void** object) {
    if (!object) return E_INVALIDARG;
    if (riid == IID_IUnknown || riid == IID_IEnumTfDisplayAttributeInfo) {
        *object = static_cast<IEnumTfDisplayAttributeInfo*>(this);
        AddRef();
        return S_OK;
    }
    *object = nullptr;
    return E_NOINTERFACE;
}

STDMETHODIMP_(ULONG) EnumDisplayAttributeInfo::AddRef() { return InterlockedIncrement(&references_); }

STDMETHODIMP_(ULONG) EnumDisplayAttributeInfo::Release() {
    LONG remaining = InterlockedDecrement(&references_);
    if (remaining == 0) delete this;
    return remaining;
}

STDMETHODIMP EnumDisplayAttributeInfo::Clone(IEnumTfDisplayAttributeInfo** clone) {
    if (!clone) return E_INVALIDARG;
    auto* copy = new (std::nothrow) EnumDisplayAttributeInfo();
    if (!copy) return E_OUTOFMEMORY;
    copy->position_ = position_;
    *clone = copy;
    return S_OK;
}

STDMETHODIMP EnumDisplayAttributeInfo::Next(ULONG count, ITfDisplayAttributeInfo** info, ULONG* fetched) {
    if (!info) return E_INVALIDARG;
    ULONG produced = 0;
    while (produced < count && position_ < ARRAYSIZE(kStyles)) {
        auto* item = new (std::nothrow) DisplayAttributeInfo(kStyles[position_]);
        if (!item) break;
        info[produced++] = item;
        ++position_;
    }
    if (fetched) *fetched = produced;
    return produced == count ? S_OK : S_FALSE;
}

STDMETHODIMP EnumDisplayAttributeInfo::Reset() {
    position_ = 0;
    return S_OK;
}

STDMETHODIMP EnumDisplayAttributeInfo::Skip(ULONG count) {
    position_ = std::min<ULONG>(position_ + count, ARRAYSIZE(kStyles));
    return position_ < ARRAYSIZE(kStyles) ? S_OK : S_FALSE;
}

}  // namespace azookey::tsf
