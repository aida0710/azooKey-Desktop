// Which Win32 control the screen builds for each element of a page. Kept apart
// from the window code so the choice can be tested without creating windows.
#pragma once

#include "settings_schema.h"

namespace azookey::settings {

enum class WidgetKind {
    CheckBox,          // toggle
    DropDownList,      // choice
    NumberEdit,        // integer: an edit with up-down arrows
    SingleLineEdit,    // text
    MultiLineEdit,     // multilineText
    ShortcutField,     // shortcut: records the key combination the user presses
    DictionaryButton,  // dictionary: opens the dictionary editor
    NoteText,          // note
    ActionButton,      // action
    PasswordEdit,      // secret
    SupportPanel,      // support
};

// `element` must come from `schema`, which ParseSchema already checked.
WidgetKind WidgetKindFor(const PageElement& element, const Schema& schema);

}  // namespace azookey::settings
