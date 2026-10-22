#include "window_classes.h"

#include "dictionary_window.h"
#include "import_preview_window.h"
#include "page_view.h"
#include "settings_window.h"

namespace azookey::settings {

void RegisterWindowClasses(HINSTANCE instance, HICON icon) {
    PageView::RegisterWindowClass(instance);
    TopLevelWindow::RegisterWindowClass(instance, SettingsWindow::kClassName, icon);
    TopLevelWindow::RegisterWindowClass(instance, DictionaryWindow::kClassName, icon);
    TopLevelWindow::RegisterWindowClass(instance, ImportPreviewWindow::kClassName, icon);
}

}  // namespace azookey::settings
