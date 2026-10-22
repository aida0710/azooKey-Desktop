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
    src/shared/host_channel.cpp
)
target_include_directories(azookey_shared PUBLIC src)
target_link_libraries(azookey_shared PUBLIC advapi32)

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
    )
    target_link_libraries(azookey-windows-host PRIVATE azookey_shared shell32 ole32)
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
endif()

add_executable(tsf-harness tests/tsf_harness.cpp)
target_link_libraries(tsf-harness PRIVATE ole32 oleaut32 user32 gdi32 uuid windowscodecs)

if(NOT AZOOKEY_X86)
    enable_testing()
    add_test(NAME shared COMMAND azookey-windows-tests)
endif()
