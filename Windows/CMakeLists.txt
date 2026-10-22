cmake_minimum_required(VERSION 3.24)
project(azooKeyTreeWindows LANGUAGES CXX RC)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
# The text service DLL is loaded into arbitrary applications, so it must not
# depend on a particular Visual C++ runtime being installed.
set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
add_compile_definitions(UNICODE _UNICODE WIN32_LEAN_AND_MEAN NOMINMAX)
add_compile_options(/utf-8 /W4 /permissive- /EHsc)

add_library(azookey_shared STATIC
    src/shared/json.cpp
    src/shared/text_encoding.cpp
    src/shared/key_translation.cpp
    src/shared/bridge_protocol.cpp
    src/shared/candidate_display.cpp
    src/shared/ui_language.cpp
    src/shared/host_channel.cpp
    src/shared/data_directory.cpp
    src/shared/api_key_credential.cpp
)
target_include_directories(azookey_shared PUBLIC src)
target_link_libraries(azookey_shared PUBLIC advapi32 shell32 ole32)

# 32-bit builds provide only the text service for 32-bit applications; the
# host, the converter and the tests run as 64-bit programs.
set(AZOOKEY_X86 OFF)
if(CMAKE_SIZEOF_VOID_P EQUAL 4)
    set(AZOOKEY_X86 ON)
endif()

if(NOT AZOOKEY_X86)
    add_executable(azookey-windows-host WIN32
        src/host/host_main.cpp
        src/host/bridge_process.cpp
        src/host/settings_reload.cpp
    )
    target_link_libraries(azookey-windows-host PRIVATE azookey_shared shell32 ole32)

    # The settings app's logic without windows, tested by azookey-settings-tests.
    add_library(azookey_settings_model STATIC
        src/settings/access_key_label.cpp
        src/settings/dictionary_draft.cpp
        src/settings/dictionary_protocol.cpp
        src/settings/dictionary_text.cpp
        src/settings/problem_text.cpp
        src/settings/settings_protocol.cpp
        src/settings/settings_schema.cpp
        src/settings/settings_widgets.cpp
        src/settings/shortcut.cpp
        src/settings/support_environment.cpp
    )
    target_link_libraries(azookey_settings_model PUBLIC azookey_shared)

    # The settings windows, shared by the app and its screen test.
    add_library(azookey_settings_screens STATIC
        src/settings/bridge_worker.cpp
        src/settings/child_controls.cpp
        src/settings/command_map.cpp
        src/settings/control_accessibility.cpp
        src/settings/dictionary_window.cpp
        src/settings/file_replace.cpp
        src/settings/import_preview_window.cpp
        src/settings/list_view.cpp
        src/settings/page_view.cpp
        src/settings/settings_form.cpp
        src/settings/settings_window.cpp
        src/settings/shortcut_field.cpp
        src/settings/support_panel.cpp
        src/settings/system_dialogs.cpp
        src/settings/top_level_window.cpp
        src/settings/ui_metrics.cpp
        src/settings/window_classes.cpp
    )
    target_link_libraries(azookey_settings_screens PUBLIC azookey_settings_model user32 gdi32 comctl32 oleacc ole32 shell32 uuid)

    # The manifest selects common controls 6 and Per-Monitor V2 DPI awareness.
    add_executable(azookey-settings WIN32
        src/settings/settings_main.cpp
        src/settings/azookey-settings.rc
        src/settings/azookey-settings.manifest
    )
    target_link_libraries(azookey-settings PRIVATE azookey_settings_screens)
endif()

if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/src/textservice/dll_main.cpp)
    file(GLOB TEXT_SERVICE_SOURCES CONFIGURE_DEPENDS src/textservice/*.cpp)
    add_library(azookey-tsf SHARED
        ${TEXT_SERVICE_SOURCES}
        src/textservice/azookey-tsf.def
        src/textservice/azookey-tsf.rc
    )
    target_link_libraries(azookey-tsf PRIVATE azookey_shared ole32 oleaut32 uuid user32 gdi32 shlwapi shcore imm32 d2d1 dwrite dwmapi uiautomationcore)
endif()

if(NOT AZOOKEY_X86)
    add_executable(azookey-windows-tests tests/shared_tests.cpp)
    target_link_libraries(azookey-windows-tests PRIVATE azookey_shared)

    add_executable(azookey-host-integration-test tests/host_integration_test.cpp)
    target_link_libraries(azookey-host-integration-test PRIVATE azookey_shared)

    add_executable(azookey-settings-tests tests/settings_tests.cpp)
    target_link_libraries(azookey-settings-tests PRIVATE azookey_settings_model)

    # Drives the settings windows; the manifest gives it the same controls and DPI handling as the app.
    add_executable(azookey-settings-ui-test
        tests/settings_ui_test.cpp
        tests/screen_capture.cpp
        src/settings/azookey-settings.manifest
    )
    target_link_libraries(azookey-settings-ui-test PRIVATE azookey_settings_screens dwmapi windowscodecs)

    add_executable(azookey-settings-reload-test tests/settings_reload_test.cpp)
    target_link_libraries(azookey-settings-reload-test PRIVATE azookey_shared)
endif()

add_executable(tsf-harness tests/tsf_harness.cpp tests/screen_capture.cpp)
target_link_libraries(tsf-harness PRIVATE ole32 oleaut32 user32 gdi32 uuid windowscodecs)

if(NOT AZOOKEY_X86)
    enable_testing()
    add_test(NAME shared COMMAND azookey-windows-tests)
    add_test(NAME settings COMMAND azookey-settings-tests)
endif()
