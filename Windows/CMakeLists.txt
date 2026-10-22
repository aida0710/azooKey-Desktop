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
    src/shared/key_binding.cpp
    src/shared/bridge_protocol.cpp
    src/shared/ai_protocol.cpp
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
        src/host/request_route.cpp
        src/host/ai_service.cpp
        src/host/ai_transform_handoff.cpp
    )
    target_link_libraries(azookey-windows-host PRIVATE azookey_shared shell32 ole32 bcrypt)

    # The settings app's logic without windows, tested by azookey-settings-tests.
    add_library(azookey_settings_model STATIC
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

    # Win32 window parts shared by the settings app and the AI instruction window:
    # DPI and fonts, dialog colors, keyboard navigation, accessibility, and the
    # thread that talks to the host.
    add_library(azookey_ui STATIC
        src/ui/access_key_label.cpp
        src/ui/bridge_worker.cpp
        src/ui/child_controls.cpp
        src/ui/clipboard.cpp
        src/ui/command_map.cpp
        src/ui/control_accessibility.cpp
        src/ui/top_level_window.cpp
        src/ui/ui_metrics.cpp
    )
    target_link_libraries(azookey_ui PUBLIC azookey_shared user32 gdi32 comctl32 oleacc ole32)

    # The settings windows, shared by the app and its screen test.
    add_library(azookey_settings_screens STATIC
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
        src/settings/window_classes.cpp
    )
    target_link_libraries(azookey_settings_screens PUBLIC azookey_settings_model azookey_ui shell32 uuid)

    # The manifest selects common controls 6 and Per-Monitor V2 DPI awareness.
    add_executable(azookey-settings WIN32
        src/settings/settings_main.cpp
        src/settings/azookey-settings.rc
        src/ui/azookey-ui.manifest
    )
    target_link_libraries(azookey-settings PRIVATE azookey_settings_screens)

    # The AI instruction window; the host starts it for a text service.
    add_library(azookey_ai_transform STATIC
        src/ai_transform/ai_transform_protocol.cpp
        src/ai_transform/ai_transform_window.cpp
    )
    target_link_libraries(azookey_ai_transform PUBLIC azookey_ui)
    add_executable(azookey-ai-transform WIN32
        src/ai_transform/ai_transform_main.cpp
        src/ai_transform/azookey-ai-transform.rc
        src/ui/azookey-ui.manifest
    )
    target_link_libraries(azookey-ai-transform PRIVATE azookey_ai_transform shell32)
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
        src/ui/azookey-ui.manifest
    )
    target_link_libraries(azookey-settings-ui-test PRIVATE azookey_settings_screens dwmapi windowscodecs)

    add_executable(azookey-settings-reload-test tests/settings_reload_test.cpp)
    target_link_libraries(azookey-settings-reload-test PRIVATE azookey_shared)

    # The host's AI path against a stub AI API on 127.0.0.1; the probe stands in for the instruction window.
    add_executable(azookey-ai-host-test tests/ai_host_test.cpp tests/chat_completions_stub.cpp)
    target_link_libraries(azookey-ai-host-test PRIVATE azookey_shared ws2_32)
    add_executable(azookey-ai-transform-probe WIN32 tests/ai_transform_probe.cpp)
    target_link_libraries(azookey-ai-transform-probe PRIVATE azookey_shared shell32)

    # Drives the AI instruction window against a stand-in host.
    add_executable(azookey-ai-transform-window-test
        tests/ai_transform_window_test.cpp
        tests/screen_capture.cpp
        src/ui/azookey-ui.manifest
    )
    target_link_libraries(azookey-ai-transform-window-test PRIVATE azookey_ai_transform dwmapi windowscodecs)
endif()

add_executable(tsf-harness tests/tsf_harness.cpp tests/screen_capture.cpp)
target_link_libraries(tsf-harness PRIVATE ole32 oleaut32 user32 gdi32 uuid windowscodecs)

if(NOT AZOOKEY_X86)
    enable_testing()
    add_test(NAME shared COMMAND azookey-windows-tests)
    add_test(NAME settings COMMAND azookey-settings-tests)
endif()
