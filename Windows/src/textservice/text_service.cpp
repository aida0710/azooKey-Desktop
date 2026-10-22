#include "text_service.h"

#include <shellscalingapi.h>

#include <algorithm>
#include <cmath>
#include <new>

#include "display_attributes.h"
#include "edit_session.h"
#include "guids.h"
#include "module.h"

namespace azookey::tsf {
namespace {

using keys::KeyAction;

// Core pages candidates nine at a time (physical number keys 1-9).
constexpr int kCandidatePageSize = 9;
// ToUnicodeEx flag (Windows 10 1607+): read the character without consuming a
// pending dead key in the application's keyboard state.
constexpr UINT kToUnicodeKeepKeyboardState = 0x4;

bool IsKeyDown(int virtualKey) { return (GetKeyState(virtualKey) & 0x8000) != 0; }

// Control and Alt chords are shortcuts: Core may act on them, and otherwise
// they belong to the application (Alt opens its menus), never typed as text.
bool IsChord(const keys::Modifiers& modifiers) { return modifiers.control || modifiers.alt; }

std::wstring JoinCommits(const protocol::Snapshot& snapshot) {
    std::wstring text;
    for (const auto& commit : snapshot.commits) text += commit;
    return text;
}

}  // namespace

TextService::TextService() { AddModuleReference(); }

TextService::~TextService() { ReleaseModuleReference(); }

STDMETHODIMP TextService::QueryInterface(REFIID riid, void** object) {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (riid == IID_IUnknown || riid == IID_ITfTextInputProcessor || riid == IID_ITfTextInputProcessorEx) {
        *object = static_cast<ITfTextInputProcessorEx*>(this);
    } else if (riid == IID_ITfThreadMgrEventSink) {
        *object = static_cast<ITfThreadMgrEventSink*>(this);
    } else if (riid == IID_ITfKeyEventSink) {
        *object = static_cast<ITfKeyEventSink*>(this);
    } else if (riid == IID_ITfCompositionSink) {
        *object = static_cast<ITfCompositionSink*>(this);
    } else if (riid == IID_ITfDisplayAttributeProvider) {
        *object = static_cast<ITfDisplayAttributeProvider*>(this);
    } else if (riid == IID_ITfCompartmentEventSink) {
        *object = static_cast<ITfCompartmentEventSink*>(this);
    }
    if (!*object) return E_NOINTERFACE;
    AddRef();
    return S_OK;
}

STDMETHODIMP_(ULONG) TextService::AddRef() { return InterlockedIncrement(&references_); }

STDMETHODIMP_(ULONG) TextService::Release() {
    LONG remaining = InterlockedDecrement(&references_);
    if (remaining == 0) delete this;
    return remaining;
}

STDMETHODIMP TextService::Activate(ITfThreadMgr* threadManager, TfClientId clientId) {
    return ActivateEx(threadManager, clientId, 0);
}

STDMETHODIMP TextService::ActivateEx(ITfThreadMgr* threadManager, TfClientId clientId, DWORD) {
    threadManager_ = threadManager;
    threadManager_->AddRef();
    clientId_ = clientId;
    RegisterClauseAttributes();

    ITfSource* source = nullptr;
    if (SUCCEEDED(threadManager_->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&source)))) {
        source->AdviseSink(IID_ITfThreadMgrEventSink, static_cast<ITfThreadMgrEventSink*>(this), &threadManagerSinkCookie_);
        source->Release();
    }
    ITfKeystrokeMgr* keystrokes = nullptr;
    if (SUCCEEDED(threadManager_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&keystrokes)))) {
        keyEventSinkAdvised_ = SUCCEEDED(keystrokes->AdviseKeyEventSink(clientId_, static_cast<ITfKeyEventSink*>(this), TRUE));
        keystrokes->Release();
    }
    openCloseSinkCookie_ = AdviseCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE);
    conversionSinkCookie_ = AdviseCompartment(GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION);

    converter_ = std::make_unique<ConverterClient>();
    CandidatePanel::Actions actions;
    actions.selectCandidate = [this](int candidateIndex) {
        if (converter_) ApplyPointerChoice(converter_->Select(candidateIndex, snapshot_.generation, false));
    };
    actions.confirmCandidate = [this](int candidateIndex) {
        if (converter_) ApplyPointerChoice(converter_->Select(candidateIndex, snapshot_.generation, true));
    };
    actions.selectNode = [this](int nodeId) {
        if (converter_) ApplyPointerChoice(converter_->SelectNode(nodeId, snapshot_.generation, false));
    };
    candidatePanel_ = std::make_unique<CandidatePanel>(std::move(actions));
    notice_ = std::make_unique<NoticeWindow>();
    coreShortcuts_ = converter_->ImeShortcuts();
    CreateCandidateElement();
    AddInputModeButton();
    // Choosing azooKey Tree means the user wants Japanese input now.
    SetInputOpen(true);
    return S_OK;
}

STDMETHODIMP TextService::Deactivate() {
    if (IsComposing()) FinishComposition(true, kAnytimeWrite);
    if (candidateElement_) {
        candidateElement_->End();
        candidateElement_->Release();
        candidateElement_ = nullptr;
    }
    RemoveInputModeButton();
    candidatePanel_.reset();
    notice_.reset();
    converter_.reset();
    UnadviseCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, openCloseSinkCookie_);
    UnadviseCompartment(GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION, conversionSinkCookie_);
    openCloseSinkCookie_ = conversionSinkCookie_ = TF_INVALID_COOKIE;
    if (threadManager_) {
        ITfKeystrokeMgr* keystrokes = nullptr;
        if (keyEventSinkAdvised_ &&
            SUCCEEDED(threadManager_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void**>(&keystrokes)))) {
            keystrokes->UnadviseKeyEventSink(clientId_);
            keystrokes->Release();
        }
        keyEventSinkAdvised_ = false;
        ITfSource* source = nullptr;
        if (threadManagerSinkCookie_ != TF_INVALID_COOKIE &&
            SUCCEEDED(threadManager_->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&source)))) {
            source->UnadviseSink(threadManagerSinkCookie_);
            source->Release();
        }
        threadManagerSinkCookie_ = TF_INVALID_COOKIE;
        threadManager_->Release();
        threadManager_ = nullptr;
    }
    if (composition_) {
        composition_->Release();
        composition_ = nullptr;
    }
    clientId_ = TF_CLIENTID_NULL;
    return S_OK;
}

void TextService::RegisterClauseAttributes() {
    ITfCategoryMgr* categories = nullptr;
    if (FAILED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfCategoryMgr,
                                reinterpret_cast<void**>(&categories)))) {
        return;
    }
    categories->RegisterGUID(ClauseStyleGuid(ClauseStyle::Input), &clauseAtoms_.input);
    categories->RegisterGUID(ClauseStyleGuid(ClauseStyle::TargetClause), &clauseAtoms_.targetClause);
    categories->RegisterGUID(ClauseStyleGuid(ClauseStyle::ConvertedClause), &clauseAtoms_.convertedClause);
    categories->Release();
}

STDMETHODIMP TextService::OnSetFocus(ITfDocumentMgr*, ITfDocumentMgr*) {
    // Moving to another field must not carry the composition along with it.
    if (IsComposing()) FinishComposition(true, kAnytimeWrite);
    HideNotice();
    privacyCheckedContext_ = nullptr;
    // Settings may have changed while another window had focus.
    presentationSettings_.reset();
    if (converter_) coreShortcuts_ = converter_->ImeShortcuts();
    lastPlacementSide_.clear();
    return S_OK;
}

bool TextService::IsComposing() const { return HasComposition() || reconversionReading_.has_value(); }

bool TextService::HasComposition() const { return composition_ != nullptr || !snapshot_.preedit.empty(); }

bool TextService::IsFieldPrivate(ITfContext* context) {
    if (context != privacyCheckedContext_) {
        privateField_ = ReadInputField(context).document.privateInput;
        // A field can also switch the IME off for itself (for example a PIN box).
        ITfCompartmentMgr* compartments = nullptr;
        if (SUCCEEDED(context->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void**>(&compartments)))) {
            ITfCompartment* disabled = nullptr;
            if (SUCCEEDED(compartments->GetCompartment(GUID_COMPARTMENT_KEYBOARD_DISABLED, &disabled))) {
                VARIANT value;
                VariantInit(&value);
                if (SUCCEEDED(disabled->GetValue(&value)) && value.vt == VT_I4 && value.lVal != 0) privateField_ = true;
                disabled->Release();
            }
            compartments->Release();
        }
        privacyCheckedContext_ = context;
    }
    return privateField_;
}

InputField TextService::ReadInputField(ITfContext* context) {
    InputField field;
    RunEditSession(context, clientId_, TF_ES_SYNC | TF_ES_READ,
                   [&](TfEditCookie cookie) { field = CompositionWriter::ReadInputField(cookie, context); });
    return field;
}

TextService::KeyInput TextService::ReadKey(ITfContext* context, WPARAM virtualKey, LPARAM lParam) {
    KeyInput input;
    if (!converter_ || !context) return input;
    input.modifiers = {IsKeyDown(VK_SHIFT), IsKeyDown(VK_CONTROL), IsKeyDown(VK_MENU)};
    BYTE keyboard[256] = {};
    GetKeyboardState(keyboard);
    // The text the layout produces with Shift only; Ctrl/Alt are modifiers for Core.
    keyboard[VK_CONTROL] = keyboard[VK_LCONTROL] = keyboard[VK_RCONTROL] = 0;
    keyboard[VK_MENU] = keyboard[VK_LMENU] = keyboard[VK_RMENU] = 0;
    wchar_t buffer[8] = {};
    UINT scanCode = (static_cast<UINT>(lParam) >> 16) & 0xFF;
    int produced = ToUnicodeEx(static_cast<UINT>(virtualKey), scanCode, keyboard, buffer, ARRAYSIZE(buffer),
                               kToUnicodeKeepKeyboardState, GetKeyboardLayout(0));
    if (produced > 0) input.typedText.assign(buffer, produced);
    keys::KeyState state;
    state.inputOpen = IsInputOpen();
    state.composing = IsComposing();
    state.privateInput = !state.composing && state.inputOpen && IsFieldPrivate(context);
    state.coreShortcuts = coreShortcuts_ ? &*coreShortcuts_ : nullptr;
    // Reading the field is a round trip into the application; only chords need it.
    if (IsChord(input.modifiers) && state.inputOpen && !state.composing && !state.privateInput) {
        state.hasSelection = ReadInputField(context).hasSelection;
    }
    input.action = keys::Classify(static_cast<uint32_t>(virtualKey), input.modifiers, input.typedText, state);
    return input;
}

STDMETHODIMP TextService::OnTestKeyDown(ITfContext* context, WPARAM wParam, LPARAM lParam, BOOL* eaten) {
    if (!eaten) return E_INVALIDARG;
    *eaten = ReadKey(context, wParam, lParam).action != KeyAction::PassThrough;
    return S_OK;
}

STDMETHODIMP TextService::OnKeyDown(ITfContext* context, WPARAM wParam, LPARAM lParam, BOOL* eaten) {
    if (!eaten) return E_INVALIDARG;
    KeyInput input = ReadKey(context, wParam, lParam);
    *eaten = input.action != KeyAction::PassThrough;
    if (*eaten) HandleKey(context, wParam, input, eaten);
    return S_OK;
}

void TextService::HandleKey(ITfContext* context, WPARAM virtualKey, const KeyInput& input, BOOL* eaten) {
    switch (input.action) {
    case KeyAction::PassThrough:
        return;
    case KeyAction::TurnInputOn:
        SetInputOpen(true);
        return;
    case KeyAction::TurnInputOff:
        if (IsComposing()) FinishComposition(true, kSyncWrite);
        SetInputOpen(false);
        return;
    case KeyAction::ToggleInput:
        if (IsInputOpen() && IsComposing()) FinishComposition(true, kSyncWrite);
        SetInputOpen(!IsInputOpen());
        return;
    case KeyAction::PreviousPage:
        ShowPage(context, -kCandidatePageSize);
        return;
    case KeyAction::NextPage:
        ShowPage(context, kCandidatePageSize);
        return;
    case KeyAction::SendToConverter:
        break;
    }
    auto event = keys::Translate(static_cast<uint32_t>(virtualKey), input.modifiers, input.typedText);
    if (reconversionReading_) {
        HandleReadingKey(context, event);
        return;
    }
    HideNotice();
    bool wasComposing = IsComposing();
    InputField field;
    if (!wasComposing) {
        // The whole composition describes the document as it is now (DocumentContext).
        field = ReadInputField(context);
        converter_->SetDocument(field.document);
    }
    protocol::KeyFacts facts;
    facts.hasSelection = !wasComposing && field.hasSelection;
    auto snapshot = converter_->Key(event, facts);
    if (!snapshot) {
        // Keep what the user already sees, and do not lose the key just typed.
        FinishComposition(false, kSyncWrite);
        if (event.characters && !IsChord(input.modifiers)) InsertText(context, input.typedText, kSyncWrite);
        return;
    }
    if (!wasComposing && HandleReconversionReply(context, *snapshot, field)) return;
    if (!snapshot->consumed && !wasComposing && snapshot->preedit.empty() && snapshot->commits.empty()) {
        // Core declined the key; behave as if the IME had not taken it.
        if (event.characters && !IsChord(input.modifiers)) InsertText(context, input.typedText, kSyncWrite);
        else *eaten = FALSE;
        return;
    }
    ApplySnapshot(context, *snapshot, kSyncWrite);
}

void TextService::ApplySnapshot(ITfContext* context, const protocol::Snapshot& snapshot, DWORD sessionFlags) {
    protocol::Snapshot stored = snapshot;
    stored.commits.clear();
    snapshot_ = stored;
    Retained keepService(static_cast<ITfTextInputProcessorEx*>(this));
    Retained keepContext(context);
    RunEditSession(context, clientId_, sessionFlags, [this, context, snapshot, keepService, keepContext](TfEditCookie cookie) {
        CompositionWriter writer(this, clauseAtoms_);
        auto geometry = writer.Apply(cookie, context, snapshot, &composition_);
        ShowCandidates(snapshot, geometry);
        // For example a candidate that covers only part of a reconverted selection.
        if (geometry) ShowReconversionNotice(snapshot, geometry->composition);
    });
}

void TextService::InsertText(ITfContext* context, const std::wstring& text, DWORD sessionFlags) {
    if (text.empty()) return;
    Retained keepContext(context);
    RunEditSession(context, clientId_, sessionFlags, [this, context, text, keepContext](TfEditCookie cookie) {
        CompositionWriter(this, clauseAtoms_).Insert(cookie, context, text);
    });
}

void TextService::FinishComposition(bool confirm, DWORD sessionFlags) {
    std::wstring text = snapshot_.preedit;
    if (converter_) {
        auto reset = converter_->Reset(confirm);
        if (confirm && reset) text = JoinCommits(*reset);
    }
    snapshot_ = {};
    HideCandidates();
    EndReconversionReading();
    if (!composition_) return;
    // The session may run after a new composition has started elsewhere, so it
    // finishes exactly this composition object.
    ITfComposition* finishing = composition_;
    composition_ = nullptr;
    ITfRange* range = nullptr;
    ITfContext* context = nullptr;
    if (SUCCEEDED(finishing->GetRange(&range))) {
        range->GetContext(&context);
        range->Release();
    }
    if (!context) {
        finishing->Release();
        return;
    }
    Retained keepService(static_cast<ITfTextInputProcessorEx*>(this));
    Retained keepContext(context);
    RunEditSession(context, clientId_, sessionFlags, [this, context, text, finishing, keepService, keepContext](TfEditCookie cookie) {
        ITfComposition* target = finishing;
        CompositionWriter(this, clauseAtoms_).Finish(cookie, context, text, &target);
        if (target) target->Release();
    });
    context->Release();
}

void TextService::ShowPage(ITfContext* context, int delta) {
    if (!snapshot_.showCandidateIndex || !snapshot_.selection || snapshot_.candidates.empty()) return;
    int target = std::clamp(*snapshot_.selection + delta, 0, static_cast<int>(snapshot_.candidates.size()) - 1);
    auto snapshot = converter_->Select(target, snapshot_.generation, false);
    if (snapshot) ApplySnapshot(context, *snapshot, kSyncWrite);
}

void TextService::CreateCandidateElement() {
    CandidateListElement::Actions actions;
    actions.showPanel = [this](bool shown) {
        // A shown panel reappears with the next candidate update.
        if (!shown && candidatePanel_) candidatePanel_->Hide();
    };
    actions.selectCandidate = [this](int candidateIndex) {
        if (converter_) ApplyPointerChoice(converter_->Select(candidateIndex, snapshot_.generation, false));
    };
    actions.confirmSelection = [this]() {
        if (converter_ && snapshot_.selection) ApplyPointerChoice(converter_->Select(*snapshot_.selection, snapshot_.generation, true));
    };
    actions.cancel = [this]() {
        // Leaving the list is what Escape does in the converter.
        if (converter_) ApplyPointerChoice(converter_->Key(keys::Translate(VK_ESCAPE, {}, L""), {}));
    };
    candidateElement_ = new (std::nothrow) CandidateListElement(threadManager_, std::move(actions));
}

namespace {

// Windows' "Text size" accessibility setting (100-225 %), which Core applies
// to candidate text like GTK's text scaling factor.
float SystemTextScale() {
    DWORD percent = 100;
    DWORD size = sizeof(percent);
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Accessibility", L"TextScaleFactor", RRF_RT_REG_DWORD, nullptr,
                 &percent, &size);
    return percent / 100.0f;
}

}  // namespace

bool TextService::TreeCandidatesEnabled() {
    if (!presentationSettings_ && converter_) presentationSettings_ = converter_->PresentationSettings();
    return !presentationSettings_ || presentationSettings_->treeCandidates;
}

void TextService::AddInputModeButton() {
    InputModeButton::Actions actions;
    actions.toggleInput = [this]() {
        bool open = IsInputOpen();
        // A click is not a key event, so the document may take the commit later.
        if (open && IsComposing()) FinishComposition(true, kAnytimeWrite);
        SetInputOpen(!open);
    };
    actions.undoCommit = [this]() { StartReconversion(true); };
    actions.reconvertSelection = [this]() { StartReconversion(false); };
    actions.openSettings = [this]() { OpenSettings(L""); };
    actions.openDictionary = [this]() { OpenSettings(L"--page dictionary"); };
    inputModeButton_ = new (std::nothrow) InputModeButton(std::move(actions));
    if (!inputModeButton_) return;
    inputModeButton_->SetJapanese(IsInputOpen());
    ITfLangBarItemMgr* items = nullptr;
    if (SUCCEEDED(threadManager_->QueryInterface(IID_ITfLangBarItemMgr, reinterpret_cast<void**>(&items)))) {
        items->AddItem(inputModeButton_);
        items->Release();
    }
}

void TextService::RemoveInputModeButton() {
    if (!inputModeButton_) return;
    ITfLangBarItemMgr* items = nullptr;
    if (threadManager_ && SUCCEEDED(threadManager_->QueryInterface(IID_ITfLangBarItemMgr, reinterpret_cast<void**>(&items)))) {
        items->RemoveItem(inputModeButton_);
        items->Release();
    }
    inputModeButton_->Release();
    inputModeButton_ = nullptr;
}

void TextService::OpenSettings(const std::wstring& arguments) {
    // The x86 build lives in x86\ under the installation folder.
#if defined(_M_IX86)
    std::wstring executable = ModuleDirectory() + L"\\..\\azookey-settings.exe";
#else
    std::wstring executable = ModuleDirectory() + L"\\azookey-settings.exe";
#endif
    std::wstring commandLine = L"\"" + executable + L"\"" + (arguments.empty() ? L"" : L" " + arguments);
    STARTUPINFOW startup{sizeof(startup)};
    PROCESS_INFORMATION process{};
    // Store applications cannot start processes; the menu then does nothing.
    if (CreateProcessW(executable.c_str(), commandLine.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &process)) {
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    }
}

void TextService::ShowCandidates(const protocol::Snapshot& snapshot, const std::optional<CompositionGeometry>& geometry) {
    const display::CandidateDisplay& shown = snapshot.display;
    bool listMode = shown.mode == display::DisplayMode::List;
    bool treeMode = shown.mode == display::DisplayMode::Tree && TreeCandidatesEnabled();
    if (!geometry || !converter_ || !candidatePanel_ || (!listMode && !treeMode)) {
        HideCandidates();
        return;
    }
    // Applications that draw candidates themselves get the list through the UI element.
    if (listMode) {
        bool drawOwnPanel = candidateElement_ ? candidateElement_->Update(snapshot) : true;
        if (!drawOwnPanel) {
            candidatePanel_->Hide();
            return;
        }
    } else if (candidateElement_) {
        candidateElement_->End();
    }

    // Core works in DIPs; convert with the DPI of the monitor showing the composition.
    POINT anchor{geometry->composition.left, geometry->composition.bottom};
    HMONITOR monitor = MonitorFromPoint(anchor, MONITOR_DEFAULTTONEAREST);
    UINT dpiX = 96, dpiY = 96;
    GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY);
    float toDips = 96.0f / dpiX;
    auto frameInDips = [&](const RECT& rect) {
        return display::Frame{rect.left * toDips, rect.top * toDips, (rect.right - rect.left) * toDips, (rect.bottom - rect.top) * toDips};
    };
    MONITORINFO monitorInfo{sizeof(monitorInfo)};
    GetMonitorInfoW(monitor, &monitorInfo);

    display::LayoutRequest request;
    request.mode = listMode ? display::DisplayMode::List : display::DisplayMode::Tree;
    request.largeText = snapshot.largeText;
    request.textScale = SystemTextScale();
    request.measuredFontSize = shown.baseFontSize;
    request.lineHeight = candidatePanel_->LineHeight(shown.baseFontSize);
    for (const auto& column : shown.columns) {
        display::LayoutColumn layoutColumn;
        for (int id : column) {
            const protocol::TreeNode* node = snapshot.FindNode(id);
            layoutColumn.nodes.push_back({id, node ? node->parent : std::nullopt});
        }
        const protocol::TreeNode* first = column.empty() ? nullptr : snapshot.FindNode(column.front());
        layoutColumn.textWidth = first ? candidatePanel_->MeasureText(first->text, shown.baseFontSize) : 0;
        request.columns.push_back(std::move(layoutColumn));
    }
    if (!geometry->words.empty() && geometry->words.size() == shown.columns.size()) {
        std::vector<float> widths;
        for (const RECT& word : geometry->words) widths.push_back((word.right - word.left) * toDips);
        request.documentWordWidths = std::move(widths);
        request.columnAnchorX = geometry->words.front().left * toDips;
    }
    request.showScores = snapshot.showRelativeScores;
    request.showNumbers = shown.showsNumbers;
    request.cursor = frameInDips(geometry->composition);
    request.workArea = frameInDips(monitorInfo.rcWork);
    request.preferredSide = lastPlacementSide_;

    // First the widths, then the placement for the height measured at that width
    // (docs/candidate-display.md, 呼び出しの手順).
    auto sized = converter_->Layout(request);
    if (!sized) {
        HideCandidates();
        return;
    }
    PanelContent content;
    content.display = shown;
    content.nodes = snapshot.nodes;
    content.showList = listMode;
    content.showScores = snapshot.showRelativeScores;
    bool drawsTree = treeMode || (listMode && shown.expandTree);
    auto measure = [&](const display::LayoutResult& layout) {
        content.tree = drawsTree ? layout.tree : std::nullopt;
        content.fontSize = layout.tree ? layout.tree->metrics.fontSize : shown.baseFontSize;
        request.popupHeight = static_cast<int>(std::ceil(candidatePanel_->ContentHeight(content, layout.popupWidth)));
    };
    measure(*sized);
    auto placed = converter_->Layout(request);
    // Core gives up aligning the columns when it places the popup beside the
    // text, which changes the width; measure again at the new width.
    if (placed && placed->popupWidth != sized->popupWidth) {
        measure(*placed);
        placed = converter_->Layout(request);
    }
    if (!placed || placed->placementStatus != "placed" || !placed->placement) {
        candidatePanel_->Hide();
        return;
    }
    content.tree = drawsTree ? placed->tree : std::nullopt;
    lastPlacementSide_ = placed->side;
    const display::Frame& frame = *placed->placement;
    float toPixels = dpiX / 96.0f;
    RECT pixels{static_cast<LONG>(frame.x * toPixels), static_cast<LONG>(frame.y * toPixels),
                static_cast<LONG>((frame.x + frame.width) * toPixels), static_cast<LONG>((frame.y + frame.height) * toPixels)};
    candidatePanel_->Show(content, pixels, dpiX);
}

void TextService::HideCandidates() {
    if (candidateElement_) candidateElement_->End();
    if (candidatePanel_) candidatePanel_->Hide();
}

ITfContext* TextService::FocusedContext() const {
    if (!threadManager_) return nullptr;
    ITfDocumentMgr* documents = nullptr;
    ITfContext* context = nullptr;
    if (SUCCEEDED(threadManager_->GetFocus(&documents)) && documents) {
        documents->GetTop(&context);
        documents->Release();
    }
    return context;
}

ITfContext* TextService::CompositionContext() const {
    if (!composition_) return nullptr;
    ITfRange* range = nullptr;
    ITfContext* context = nullptr;
    if (SUCCEEDED(composition_->GetRange(&range))) {
        range->GetContext(&context);
        range->Release();
    }
    return context;
}

void TextService::ApplyPointerChoice(std::optional<protocol::Snapshot> snapshot) {
    ITfContext* context = CompositionContext();
    if (!context) return;
    if (snapshot) ApplySnapshot(context, *snapshot, kAnytimeWrite);
    else FinishComposition(false, kAnytimeWrite);
    context->Release();
}

STDMETHODIMP TextService::OnTestKeyUp(ITfContext*, WPARAM, LPARAM, BOOL* eaten) {
    if (eaten) *eaten = FALSE;
    return S_OK;
}

STDMETHODIMP TextService::OnKeyUp(ITfContext*, WPARAM, LPARAM, BOOL* eaten) {
    if (eaten) *eaten = FALSE;
    return S_OK;
}

STDMETHODIMP TextService::OnPreservedKey(ITfContext*, REFGUID, BOOL* eaten) {
    if (eaten) *eaten = FALSE;
    return S_OK;
}

STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie, ITfComposition* composition) {
    // The application ended the composition (for example by a click); the text
    // it shows stays as typed, so the converter drops its copy.
    if (composition == composition_ && composition_) {
        composition_->Release();
        composition_ = nullptr;
    }
    if (converter_) converter_->Reset(false);
    snapshot_ = {};
    HideCandidates();
    return S_OK;
}

STDMETHODIMP TextService::EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo** enumerator) {
    if (!enumerator) return E_INVALIDARG;
    *enumerator = new (std::nothrow) azookey::tsf::EnumDisplayAttributeInfo();
    return *enumerator ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP TextService::GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo** info) {
    if (!info) return E_INVALIDARG;
    *info = CreateDisplayAttributeInfo(guid);
    return *info ? S_OK : E_INVALIDARG;
}

bool TextService::IsInputOpen() {
    if (!threadManager_) return false;
    ITfCompartmentMgr* compartments = nullptr;
    bool open = false;
    if (SUCCEEDED(threadManager_->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void**>(&compartments)))) {
        ITfCompartment* compartment = nullptr;
        if (SUCCEEDED(compartments->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, &compartment))) {
            VARIANT value;
            VariantInit(&value);
            open = SUCCEEDED(compartment->GetValue(&value)) && value.vt == VT_I4 && value.lVal != 0;
            compartment->Release();
        }
        compartments->Release();
    }
    return open;
}

void TextService::SetInputOpen(bool open) {
    if (!threadManager_) return;
    ITfCompartmentMgr* compartments = nullptr;
    if (FAILED(threadManager_->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void**>(&compartments)))) return;
    updatingCompartments_ = true;
    auto set = [&](const GUID& guid, LONG number) {
        ITfCompartment* compartment = nullptr;
        if (SUCCEEDED(compartments->GetCompartment(guid, &compartment))) {
            VARIANT value;
            VariantInit(&value);
            value.vt = VT_I4;
            value.lVal = number;
            compartment->SetValue(clientId_, &value);
            compartment->Release();
        }
    };
    set(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, open ? 1 : 0);
    if (inputModeButton_) inputModeButton_->SetJapanese(open);
    // Drives the taskbar indicator: あ for Japanese input, A otherwise.
    set(GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION,
        open ? (TF_CONVERSIONMODE_NATIVE | TF_CONVERSIONMODE_FULLSHAPE | TF_CONVERSIONMODE_ROMAN)
             : TF_CONVERSIONMODE_ALPHANUMERIC);
    updatingCompartments_ = false;
    compartments->Release();
}

STDMETHODIMP TextService::OnChange(REFGUID compartment) {
    if (updatingCompartments_) return S_OK;
    if (IsEqualGUID(compartment, GUID_COMPARTMENT_KEYBOARD_OPENCLOSE)) {
        // Turned off from outside (taskbar, another IME key): confirm first.
        bool open = IsInputOpen();
        if (!open && IsComposing()) FinishComposition(true, kAnytimeWrite);
        SetInputOpen(open);
    } else if (IsEqualGUID(compartment, GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION) && threadManager_) {
        ITfCompartmentMgr* compartments = nullptr;
        if (SUCCEEDED(threadManager_->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void**>(&compartments)))) {
            ITfCompartment* conversion = nullptr;
            if (SUCCEEDED(compartments->GetCompartment(GUID_COMPARTMENT_KEYBOARD_INPUTMODE_CONVERSION, &conversion))) {
                VARIANT value;
                VariantInit(&value);
                // Only hiragana input exists; choosing an alphanumeric mode means "off".
                if (SUCCEEDED(conversion->GetValue(&value)) && value.vt == VT_I4) {
                    bool wantsJapanese = (value.lVal & TF_CONVERSIONMODE_NATIVE) != 0;
                    if (wantsJapanese != IsInputOpen()) {
                        if (!wantsJapanese && IsComposing()) FinishComposition(true, kAnytimeWrite);
                        SetInputOpen(wantsJapanese);
                    }
                }
                conversion->Release();
            }
            compartments->Release();
        }
    }
    return S_OK;
}

DWORD TextService::AdviseCompartment(const GUID& compartment) {
    DWORD cookie = TF_INVALID_COOKIE;
    ITfCompartmentMgr* compartments = nullptr;
    if (FAILED(threadManager_->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void**>(&compartments)))) return cookie;
    ITfCompartment* item = nullptr;
    if (SUCCEEDED(compartments->GetCompartment(compartment, &item))) {
        ITfSource* source = nullptr;
        if (SUCCEEDED(item->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&source)))) {
            source->AdviseSink(IID_ITfCompartmentEventSink, static_cast<ITfCompartmentEventSink*>(this), &cookie);
            source->Release();
        }
        item->Release();
    }
    compartments->Release();
    return cookie;
}

void TextService::UnadviseCompartment(const GUID& compartment, DWORD cookie) {
    if (cookie == TF_INVALID_COOKIE || !threadManager_) return;
    ITfCompartmentMgr* compartments = nullptr;
    if (FAILED(threadManager_->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void**>(&compartments)))) return;
    ITfCompartment* item = nullptr;
    if (SUCCEEDED(compartments->GetCompartment(compartment, &item))) {
        ITfSource* source = nullptr;
        if (SUCCEEDED(item->QueryInterface(IID_ITfSource, reinterpret_cast<void**>(&source)))) {
            source->UnadviseSink(cookie);
            source->Release();
        }
        item->Release();
    }
    compartments->Release();
}

}  // namespace azookey::tsf
