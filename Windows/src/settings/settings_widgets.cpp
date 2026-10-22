#include "settings_widgets.h"

namespace azookey::settings {
namespace {

WidgetKind WidgetKindForControl(Control control) {
    switch (control) {
    case Control::Toggle: return WidgetKind::CheckBox;
    case Control::Choice: return WidgetKind::DropDownList;
    case Control::Integer: return WidgetKind::NumberEdit;
    case Control::Text: return WidgetKind::SingleLineEdit;
    case Control::MultilineText: return WidgetKind::MultiLineEdit;
    case Control::Shortcut: return WidgetKind::ShortcutField;
    case Control::Dictionary: return WidgetKind::DictionaryButton;
    }
    return WidgetKind::SingleLineEdit;
}

}  // namespace

WidgetKind WidgetKindFor(const PageElement& element, const Schema& schema) {
    switch (element.kind) {
    case ElementKind::Setting: return WidgetKindForControl(schema.FindItem(element.settingKey)->control);
    case ElementKind::Note: return WidgetKind::NoteText;
    case ElementKind::Action: return WidgetKind::ActionButton;
    case ElementKind::Secret: return WidgetKind::PasswordEdit;
    case ElementKind::Support: return WidgetKind::SupportPanel;
    }
    return WidgetKind::NoteText;
}

}  // namespace azookey::settings
