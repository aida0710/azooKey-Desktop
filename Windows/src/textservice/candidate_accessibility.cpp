#include "candidate_accessibility.h"

#include "module.h"

namespace azookey::tsf {
namespace {

VARIANT StringVariant(const std::wstring& text) {
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_BSTR;
    value.bstrVal = SysAllocString(text.c_str());
    return value;
}

VARIANT IntegerVariant(LONG number) {
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_I4;
    value.lVal = number;
    return value;
}

VARIANT BooleanVariant(bool flag) {
    VARIANT value;
    VariantInit(&value);
    value.vt = VT_BOOL;
    value.boolVal = flag ? VARIANT_TRUE : VARIANT_FALSE;
    return value;
}

}  // namespace

// The panel itself: a list with one selected item.
class CandidateAccessibility::ListProvider final : public IRawElementProviderSimple,
                                                    public IRawElementProviderFragment,
                                                    public IRawElementProviderFragmentRoot,
                                                    public ISelectionProvider {
public:
    explicit ListProvider(CandidateAccessibility* owner) : owner_(owner) { AddModuleReference(); }

    void Detach() { owner_ = nullptr; }

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        if (!object) return E_INVALIDARG;
        *object = nullptr;
        if (riid == IID_IUnknown || riid == IID_IRawElementProviderSimple) *object = static_cast<IRawElementProviderSimple*>(this);
        else if (riid == IID_IRawElementProviderFragment) *object = static_cast<IRawElementProviderFragment*>(this);
        else if (riid == IID_IRawElementProviderFragmentRoot) *object = static_cast<IRawElementProviderFragmentRoot*>(this);
        else if (riid == IID_ISelectionProvider) *object = static_cast<ISelectionProvider*>(this);
        if (!*object) return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&references_); }
    STDMETHODIMP_(ULONG) Release() override {
        LONG remaining = InterlockedDecrement(&references_);
        if (remaining == 0) delete this;
        return remaining;
    }

    // IRawElementProviderSimple
    STDMETHODIMP get_ProviderOptions(ProviderOptions* options) override {
        *options = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading;
        return S_OK;
    }
    STDMETHODIMP GetPatternProvider(PATTERNID pattern, IUnknown** provider) override {
        *provider = nullptr;
        if (pattern == UIA_SelectionPatternId) {
            *provider = static_cast<ISelectionProvider*>(this);
            AddRef();
        }
        return S_OK;
    }
    STDMETHODIMP GetPropertyValue(PROPERTYID property, VARIANT* value) override {
        VariantInit(value);
        if (!owner_) return UIA_E_ELEMENTNOTAVAILABLE;
        if (property == UIA_ControlTypePropertyId) *value = IntegerVariant(UIA_ListControlTypeId);
        else if (property == UIA_NamePropertyId) *value = StringVariant(L"azooKey Tree の変換候補");
        else if (property == UIA_IsKeyboardFocusablePropertyId) *value = BooleanVariant(false);
        return S_OK;
    }
    STDMETHODIMP get_HostRawElementProvider(IRawElementProviderSimple** provider) override {
        if (!owner_) return UIA_E_ELEMENTNOTAVAILABLE;
        return UiaHostProviderFromHwnd(owner_->window_, provider);
    }

    // IRawElementProviderFragment
    STDMETHODIMP Navigate(NavigateDirection direction, IRawElementProviderFragment** element) override;
    STDMETHODIMP GetRuntimeId(SAFEARRAY** runtimeId) override {
        *runtimeId = nullptr;  // the host window supplies the root's id
        return S_OK;
    }
    STDMETHODIMP get_BoundingRectangle(UiaRect* rectangle) override {
        *rectangle = {};
        RECT window{};
        if (owner_ && GetWindowRect(owner_->window_, &window)) {
            *rectangle = {static_cast<double>(window.left), static_cast<double>(window.top),
                          static_cast<double>(window.right - window.left), static_cast<double>(window.bottom - window.top)};
        }
        return S_OK;
    }
    STDMETHODIMP GetEmbeddedFragmentRoots(SAFEARRAY** roots) override {
        *roots = nullptr;
        return S_OK;
    }
    STDMETHODIMP SetFocus() override { return S_OK; }  // the panel never takes focus
    STDMETHODIMP get_FragmentRoot(IRawElementProviderFragmentRoot** root) override {
        *root = this;
        AddRef();
        return S_OK;
    }

    // IRawElementProviderFragmentRoot
    STDMETHODIMP ElementProviderFromPoint(double x, double y, IRawElementProviderFragment** element) override;
    STDMETHODIMP GetFocus(IRawElementProviderFragment** element) override {
        *element = nullptr;
        return S_OK;
    }

    // ISelectionProvider
    STDMETHODIMP GetSelection(SAFEARRAY** selection) override;
    STDMETHODIMP get_CanSelectMultiple(BOOL* multiple) override {
        *multiple = FALSE;
        return S_OK;
    }
    STDMETHODIMP get_IsSelectionRequired(BOOL* required) override {
        *required = TRUE;
        return S_OK;
    }

private:
    ~ListProvider() { ReleaseModuleReference(); }
    LONG references_ = 1;
    CandidateAccessibility* owner_;
};

// One candidate: selectable, and invokable to confirm it.
class CandidateAccessibility::ItemProvider final : public IRawElementProviderSimple,
                                                    public IRawElementProviderFragment,
                                                    public ISelectionItemProvider,
                                                    public IInvokeProvider {
public:
    ItemProvider(CandidateAccessibility* owner, int position) : owner_(owner), position_(position) { AddModuleReference(); }

    void Detach() { owner_ = nullptr; }
    int position() const { return position_; }

    STDMETHODIMP QueryInterface(REFIID riid, void** object) override {
        if (!object) return E_INVALIDARG;
        *object = nullptr;
        if (riid == IID_IUnknown || riid == IID_IRawElementProviderSimple) *object = static_cast<IRawElementProviderSimple*>(this);
        else if (riid == IID_IRawElementProviderFragment) *object = static_cast<IRawElementProviderFragment*>(this);
        else if (riid == IID_ISelectionItemProvider) *object = static_cast<ISelectionItemProvider*>(this);
        else if (riid == IID_IInvokeProvider) *object = static_cast<IInvokeProvider*>(this);
        if (!*object) return E_NOINTERFACE;
        AddRef();
        return S_OK;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&references_); }
    STDMETHODIMP_(ULONG) Release() override {
        LONG remaining = InterlockedDecrement(&references_);
        if (remaining == 0) delete this;
        return remaining;
    }

    // IRawElementProviderSimple
    STDMETHODIMP get_ProviderOptions(ProviderOptions* options) override {
        *options = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading;
        return S_OK;
    }
    STDMETHODIMP GetPatternProvider(PATTERNID pattern, IUnknown** provider) override {
        *provider = nullptr;
        if (pattern == UIA_SelectionItemPatternId) *provider = static_cast<ISelectionItemProvider*>(this);
        else if (pattern == UIA_InvokePatternId) *provider = static_cast<IInvokeProvider*>(this);
        if (*provider) AddRef();
        return S_OK;
    }
    STDMETHODIMP GetPropertyValue(PROPERTYID property, VARIANT* value) override {
        VariantInit(value);
        const AccessibleCandidate* item = Item();
        if (!item) return UIA_E_ELEMENTNOTAVAILABLE;
        if (property == UIA_ControlTypePropertyId) *value = IntegerVariant(UIA_ListItemControlTypeId);
        else if (property == UIA_NamePropertyId) *value = StringVariant(item->name);
        else if (property == UIA_IsKeyboardFocusablePropertyId) *value = BooleanVariant(false);
        return S_OK;
    }
    STDMETHODIMP get_HostRawElementProvider(IRawElementProviderSimple** provider) override {
        *provider = nullptr;
        return S_OK;
    }

    // IRawElementProviderFragment
    STDMETHODIMP Navigate(NavigateDirection direction, IRawElementProviderFragment** element) override {
        *element = nullptr;
        if (!owner_) return UIA_E_ELEMENTNOTAVAILABLE;
        int target = -1;
        if (direction == NavigateDirection_Parent) {
            *element = owner_->list_;
            owner_->list_->AddRef();
            return S_OK;
        }
        if (direction == NavigateDirection_NextSibling) target = position_ + 1;
        if (direction == NavigateDirection_PreviousSibling) target = position_ - 1;
        if (target >= 0 && target < static_cast<int>(owner_->items_.size())) {
            *element = owner_->items_[target];
            (*element)->AddRef();
        }
        return S_OK;
    }
    STDMETHODIMP GetRuntimeId(SAFEARRAY** runtimeId) override {
        int id[] = {UiaAppendRuntimeId, position_ + 1};
        *runtimeId = SafeArrayCreateVector(VT_I4, 0, 2);
        for (LONG i = 0; i < 2; ++i) SafeArrayPutElement(*runtimeId, &i, &id[i]);
        return S_OK;
    }
    STDMETHODIMP get_BoundingRectangle(UiaRect* rectangle) override {
        const AccessibleCandidate* item = Item();
        *rectangle = {};
        if (!item) return UIA_E_ELEMENTNOTAVAILABLE;
        *rectangle = {static_cast<double>(item->bounds.left), static_cast<double>(item->bounds.top),
                      static_cast<double>(item->bounds.right - item->bounds.left),
                      static_cast<double>(item->bounds.bottom - item->bounds.top)};
        return S_OK;
    }
    STDMETHODIMP GetEmbeddedFragmentRoots(SAFEARRAY** roots) override {
        *roots = nullptr;
        return S_OK;
    }
    STDMETHODIMP SetFocus() override { return S_OK; }
    STDMETHODIMP get_FragmentRoot(IRawElementProviderFragmentRoot** root) override {
        *root = nullptr;
        if (!owner_) return UIA_E_ELEMENTNOTAVAILABLE;
        *root = owner_->list_;
        owner_->list_->AddRef();
        return S_OK;
    }

    // ISelectionItemProvider
    STDMETHODIMP Select() override {
        const AccessibleCandidate* item = Item();
        if (!item) return UIA_E_ELEMENTNOTAVAILABLE;
        if (owner_->actions_.select) owner_->actions_.select(item->candidateIndex);
        return S_OK;
    }
    STDMETHODIMP AddToSelection() override { return Select(); }
    STDMETHODIMP RemoveFromSelection() override { return UIA_E_INVALIDOPERATION; }
    STDMETHODIMP get_IsSelected(BOOL* selected) override {
        const AccessibleCandidate* item = Item();
        if (!item) return UIA_E_ELEMENTNOTAVAILABLE;
        *selected = item->selected ? TRUE : FALSE;
        return S_OK;
    }
    STDMETHODIMP get_SelectionContainer(IRawElementProviderSimple** container) override {
        *container = nullptr;
        if (!owner_) return UIA_E_ELEMENTNOTAVAILABLE;
        *container = owner_->list_;
        owner_->list_->AddRef();
        return S_OK;
    }

    // IInvokeProvider
    STDMETHODIMP Invoke() override {
        const AccessibleCandidate* item = Item();
        if (!item) return UIA_E_ELEMENTNOTAVAILABLE;
        if (owner_->actions_.confirm) owner_->actions_.confirm(item->candidateIndex);
        return S_OK;
    }

private:
    ~ItemProvider() { ReleaseModuleReference(); }
    const AccessibleCandidate* Item() const {
        if (!owner_ || position_ >= static_cast<int>(owner_->data_.size())) return nullptr;
        return &owner_->data_[position_];
    }

    LONG references_ = 1;
    CandidateAccessibility* owner_;
    int position_;
};

STDMETHODIMP CandidateAccessibility::ListProvider::Navigate(NavigateDirection direction, IRawElementProviderFragment** element) {
    *element = nullptr;
    if (!owner_ || owner_->items_.empty()) return S_OK;
    if (direction == NavigateDirection_FirstChild) *element = owner_->items_.front();
    else if (direction == NavigateDirection_LastChild) *element = owner_->items_.back();
    if (*element) (*element)->AddRef();
    return S_OK;
}

STDMETHODIMP CandidateAccessibility::ListProvider::ElementProviderFromPoint(double x, double y,
                                                                            IRawElementProviderFragment** element) {
    *element = nullptr;
    if (!owner_) return S_OK;
    for (size_t i = 0; i < owner_->data_.size(); ++i) {
        const RECT& bounds = owner_->data_[i].bounds;
        if (x >= bounds.left && x < bounds.right && y >= bounds.top && y < bounds.bottom) {
            *element = owner_->items_[i];
            (*element)->AddRef();
            break;
        }
    }
    return S_OK;
}

STDMETHODIMP CandidateAccessibility::ListProvider::GetSelection(SAFEARRAY** selection) {
    *selection = nullptr;
    if (!owner_ || owner_->selectedIndex_ < 0) return S_OK;
    *selection = SafeArrayCreateVector(VT_UNKNOWN, 0, 1);
    LONG index = 0;
    IUnknown* item = static_cast<IRawElementProviderSimple*>(owner_->items_[owner_->selectedIndex_]);
    SafeArrayPutElement(*selection, &index, item);
    return S_OK;
}

CandidateAccessibility::CandidateAccessibility(HWND window, Actions actions) : window_(window), actions_(std::move(actions)) {
    list_ = new ListProvider(this);
}

CandidateAccessibility::~CandidateAccessibility() {
    Clear();
    // Release the providers UIA may still hold for this window.
    UiaReturnRawElementProvider(window_, 0, 0, nullptr);
    UiaDisconnectProvider(list_);
    list_->Detach();
    list_->Release();
}

void CandidateAccessibility::Clear() {
    for (ItemProvider* item : items_) {
        UiaDisconnectProvider(static_cast<IRawElementProviderSimple*>(item));
        item->Detach();
        item->Release();
    }
    items_.clear();
    data_.clear();
    selectedIndex_ = -1;
}

void CandidateAccessibility::Update(std::vector<AccessibleCandidate> items, const std::wstring& announcement) {
    bool sameItems = items.size() == data_.size();
    for (size_t i = 0; sameItems && i < items.size(); ++i) sameItems = items[i].candidateIndex == data_[i].candidateIndex;
    int previousSelection = selectedIndex_ >= 0 ? data_[selectedIndex_].candidateIndex : -1;
    if (!sameItems) {
        Clear();
        for (size_t i = 0; i < items.size(); ++i) items_.push_back(new ItemProvider(this, static_cast<int>(i)));
    }
    data_ = std::move(items);
    selectedIndex_ = -1;
    for (size_t i = 0; i < data_.size(); ++i) {
        if (data_[i].selected) selectedIndex_ = static_cast<int>(i);
    }
    if (!UiaClientsAreListening() || selectedIndex_ < 0) return;
    if (data_[selectedIndex_].candidateIndex == previousSelection && sameItems) return;
    UiaRaiseAutomationEvent(items_[selectedIndex_], UIA_SelectionItem_ElementSelectedEventId);
    if (!announcement.empty()) {
        // The candidate panel never has focus, so a notification is how screen
        // readers learn about the new selection.
        BSTR text = SysAllocString(announcement.c_str());
        BSTR activity = SysAllocString(L"azooKeyTree.candidateSelection");
        UiaRaiseNotificationEvent(list_, NotificationKind_ActionCompleted, NotificationProcessing_ImportantMostRecent, text, activity);
        SysFreeString(activity);
        SysFreeString(text);
    }
}

LRESULT CandidateAccessibility::HandleGetObject(WPARAM wParam, LPARAM lParam) {
    if (static_cast<long>(lParam) != static_cast<long>(UiaRootObjectId)) return 0;
    return UiaReturnRawElementProvider(window_, wParam, lParam, list_);
}

}  // namespace azookey::tsf
