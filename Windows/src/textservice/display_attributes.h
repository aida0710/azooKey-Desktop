// How the composition is drawn: TSF asks the IME for these styles and the
// application renders them (dotted underline while typing, thick underline on
// the clause being converted).
#pragma once

#include <msctf.h>

namespace azookey::tsf {

enum class ClauseStyle { Input, TargetClause, ConvertedClause };

class DisplayAttributeInfo final : public ITfDisplayAttributeInfo {
public:
    explicit DisplayAttributeInfo(ClauseStyle style);

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    STDMETHODIMP GetGUID(GUID* guid) override;
    STDMETHODIMP GetDescription(BSTR* description) override;
    STDMETHODIMP GetAttributeInfo(TF_DISPLAYATTRIBUTE* attribute) override;
    STDMETHODIMP SetAttributeInfo(const TF_DISPLAYATTRIBUTE* attribute) override;
    STDMETHODIMP Reset() override;

private:
    ~DisplayAttributeInfo();
    LONG references_ = 1;
    ClauseStyle style_;
};

class EnumDisplayAttributeInfo final : public IEnumTfDisplayAttributeInfo {
public:
    EnumDisplayAttributeInfo();

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override;
    STDMETHODIMP_(ULONG) AddRef() override;
    STDMETHODIMP_(ULONG) Release() override;

    STDMETHODIMP Clone(IEnumTfDisplayAttributeInfo** clone) override;
    STDMETHODIMP Next(ULONG count, ITfDisplayAttributeInfo** info, ULONG* fetched) override;
    STDMETHODIMP Reset() override;
    STDMETHODIMP Skip(ULONG count) override;

private:
    ~EnumDisplayAttributeInfo();
    LONG references_ = 1;
    ULONG position_ = 0;
};

const GUID& ClauseStyleGuid(ClauseStyle style);
// Returns nullptr when the GUID is not one of this IME's styles.
DisplayAttributeInfo* CreateDisplayAttributeInfo(const GUID& guid);

}  // namespace azookey::tsf
