# Builds the LVGL static library with the project lv_conf.h, plus the
# LVGL-facing core layer of psychlvgl. The MEX itself is compiled by build.m
# with the engine's own `mex` driver, so nothing here knows about MATLAB.
cmake_minimum_required(VERSION 3.16)
project(psychlvgl C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(PSYCHLVGL_TEST_SW  "Software render variant used by the no-GL tests" OFF)
option(PSYCHLVGL_TRACY    "Compile the Tracy client into the core library"  OFF)
option(PSYCHLVGL_SMOKE_GL "Build the native GL smoke test executable"       OFF)
option(PSYCHLVGL_STATS    "Compile the Stats counters"                      ON)

# GL3 matches the compatibility context Psychtoolbox creates on Windows and
# Linux. macOS compatibility profiles stop at GL 2.1, so they need GL2.
if(APPLE)
    set(_plv_backend_default LV_NANOVG_BACKEND_GL2)
else()
    set(_plv_backend_default LV_NANOVG_BACKEND_GL3)
endif()
set(LV_NANOVG_BACKEND "${_plv_backend_default}" CACHE STRING "NanoVG shader flavor")

# --- LVGL ------------------------------------------------------------------
# LVGL reads LV_BUILD_CONF_PATH, not LV_CONF_PATH. Demos, examples and ThorVG
# are off because none of them is reachable from this binding.
# LVGL declares these with option() and set(CACHE), both of which drop a plain
# variable of the same name, so every one of them has to be forced into the
# cache before the subdirectory is added.
set(CMAKE_POLICY_DEFAULT_CMP0077 NEW)
set(LV_BUILD_CONF_PATH    ${CMAKE_CURRENT_SOURCE_DIR}/lv_conf.h CACHE PATH "" FORCE)
set(LV_BUILD_INSTALL      OFF  CACHE BOOL "" FORCE)
set(CONFIG_LV_BUILD_DEMOS OFF  CACHE BOOL "" FORCE)
set(CONFIG_LV_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(CONFIG_LV_USE_THORVG  OFF  CACHE BOOL "" FORCE)
set(CONFIG_LV_USE_THORVG_INTERNAL OFF CACHE BOOL "" FORCE)
set(LV_FETCH_DEPENDENCIES OFF  CACHE BOOL "" FORCE)
set(LV_USE_FIND_PACKAGE   OFF  CACHE BOOL "" FORCE)
set(LV_USE_PKG_CONFIG     OFF  CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS     OFF  CACHE BOOL "" FORCE)
add_subdirectory(third_party/lvgl lvgl)

# lv_conf.h names plv_assert.h through LV_ASSERT_CUSTOM_INCLUDE, so every LVGL
# translation unit has to be able to find it. src/compat carries the GL/glew.h
# shim that the NanoVG draw unit asks for; see that file for why.
target_include_directories(lvgl PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src/core
    ${CMAKE_CURRENT_SOURCE_DIR}/src/compat
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lvgl/src/drivers/opengles/glad/include)

if(PSYCHLVGL_TEST_SW)
    target_compile_definitions(lvgl PUBLIC PSYCHLVGL_TEST_SW=1)
else()
    target_compile_definitions(lvgl PUBLIC LV_NANOVG_BACKEND=${LV_NANOVG_BACKEND})
endif()
if(PSYCHLVGL_TRACY)
    target_compile_definitions(lvgl PUBLIC PSYCHLVGL_TRACY=1)
endif()

# --- core layer ------------------------------------------------------------
set(PLV_CORE_SOURCES
    src/core/plv_core.c
    src/core/plv_handles.c
    src/core/plv_events.c
    src/core/plv_input.c
    src/core/plv_stats.c
    src/core/plv_toolchain_id.c)

if(PSYCHLVGL_TEST_SW)
    list(APPEND PLV_CORE_SOURCES src/core/plv_display_sw.c)
else()
    list(APPEND PLV_CORE_SOURCES src/core/plv_display.c src/core/plv_gl_loader.c)
endif()

add_library(plv_core STATIC ${PLV_CORE_SOURCES})
target_include_directories(plv_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/core
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lvgl
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lvgl/include
    ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lvgl/src/drivers/opengles/glad/include)
target_link_libraries(plv_core PUBLIC lvgl)

if(PSYCHLVGL_TEST_SW)
    target_compile_definitions(plv_core PUBLIC PSYCHLVGL_TEST_SW=1)
endif()
if(NOT PSYCHLVGL_STATS)
    target_compile_definitions(plv_core PUBLIC PSYCHLVGL_STATS=0)
endif()
if(PSYCHLVGL_TRACY)
    # Tracy is C++. Compiling its client into this library keeps the MEX plain C.
    if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/third_party/tracy/public/TracyClient.cpp)
        enable_language(CXX)
        target_sources(plv_core PRIVATE third_party/tracy/public/TracyClient.cpp)
        target_include_directories(plv_core PUBLIC third_party/tracy/public)
        target_compile_definitions(plv_core PUBLIC TRACY_ENABLE=1 PSYCHLVGL_TRACY=1)
    else()
        message(FATAL_ERROR "PSYCHLVGL_TRACY=ON but third_party/tracy is missing")
    endif()
endif()

if(NOT PSYCHLVGL_TEST_SW)
    if(WIN32)
        target_link_libraries(plv_core PUBLIC opengl32)
    elseif(APPLE)
        target_link_libraries(plv_core PUBLIC "-framework OpenGL")
    else()
        target_link_libraries(plv_core PUBLIC GL dl)
    endif()
endif()

# --- install ---------------------------------------------------------------
# build.m links the MEX against these two archives.
install(TARGETS plv_core ARCHIVE DESTINATION lib)
install(TARGETS lvgl ARCHIVE DESTINATION lib)

# build.m compares this against the compiler its own `mex` uses. An MSVC
# archive in a MinGW MEX only fails at link time with unresolved runtime
# symbols, which is a slow way to learn the two do not match.
file(WRITE ${CMAKE_BINARY_DIR}/plv_toolchain_id.txt "${CMAKE_C_COMPILER_ID}")

# --- native GL smoke test --------------------------------------------------
# Psychtoolbox is the normal host for the GL path. This executable is the only
# way to exercise NanoVG when PTB is absent.
if(PSYCHLVGL_SMOKE_GL AND NOT PSYCHLVGL_TEST_SW)
    add_executable(smoke_gl tests/native/smoke_gl.c)
    target_link_libraries(smoke_gl PRIVATE plv_core)
    if(WIN32)
        target_link_libraries(smoke_gl PRIVATE opengl32 gdi32 user32)
    elseif(NOT APPLE)
        # The X11 branch of the smoke test creates its own GLX context.
        target_link_libraries(smoke_gl PRIVATE X11)
    endif()
endif()
