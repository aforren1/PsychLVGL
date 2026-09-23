# Builds the LVGL static library with the project lv_conf.h, plus the
# LVGL-facing core layer of psychlvgl. The MEX itself is compiled by build.m
# with the engine's own `mex` driver, so nothing here knows about MATLAB.
cmake_minimum_required(VERSION 3.16)

# MATLAB's mex links with -mmacosx-version-min=11.0. Static libraries built
# for the host's newer macOS make the linker print a warning per object file,
# several hundred for LVGL, so they target the same minimum. It has to be set
# before project(), which reads it.
if(APPLE AND NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0" CACHE STRING "Minimum macOS version, as mex uses")
endif()

project(psychlvgl C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

option(PSYCHLVGL_TEST_SW  "Software render variant used by the no-GL tests" OFF)
option(PSYCHLVGL_TRACY    "Compile the Tracy client into the core library"  OFF)
option(PSYCHLVGL_SMOKE_GL "Build the native GL smoke test executable"       OFF)
option(PSYCHLVGL_STATS    "Compile the Stats counters"                      ON)
set(PSYCHLVGL_TRACY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/tracy" CACHE PATH
    "Tracy checkout used when PSYCHLVGL_TRACY is ON")

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

# --- vendored LVGL patches --------------------------------------------------
# Each patch in patches/lvgl is applied to the submodule checkout at configure
# time. A marker string in a file the patch adds to tells whether it is already
# there, so this is idempotent and needs no tool when nothing is to do.
# tools/apply_lvgl_patches.sh does the same from a shell.
#   0001  GLSL 1.20 shader path and a luminance texture fallback, so the GL2
#         build runs on the legacy 2.1 contexts Psychtoolbox creates on macOS
#         (SPEC deviation D38).
#   0002  lets an image descriptor name an OpenGL texture that the NanoVG draw
#         unit draws without a copy, which is how ImageFromTexture shows a
#         Psychtoolbox texture (SPEC deviation D41).
set(_plv_lvgl_dir ${CMAKE_CURRENT_SOURCE_DIR}/third_party/lvgl)
function(plv_apply_lvgl_patch patch marker_file marker)
    set(_patch ${CMAKE_CURRENT_SOURCE_DIR}/patches/lvgl/${patch})
    file(STRINGS ${_plv_lvgl_dir}/${marker_file} _found REGEX "${marker}")
    if(_found)
        message(STATUS "third_party/lvgl already carries ${patch}")
        return()
    endif()
    find_program(_plv_git git)
    find_program(_plv_patch_prog patch)
    if(_plv_git)
        execute_process(COMMAND ${_plv_git} -C ${_plv_lvgl_dir} apply ${_patch}
                        RESULT_VARIABLE _rc OUTPUT_QUIET ERROR_VARIABLE _err)
    elseif(_plv_patch_prog)
        execute_process(COMMAND ${_plv_patch_prog} -p1 -N -d ${_plv_lvgl_dir} -i ${_patch}
                        RESULT_VARIABLE _rc OUTPUT_QUIET ERROR_VARIABLE _err)
    else()
        message(FATAL_ERROR "Neither git nor patch is available to apply ${_patch}. "
                            "Run tools/apply_lvgl_patches.sh on a machine that has one, "
                            "or apply the patch by hand inside third_party/lvgl.")
    endif()
    if(NOT _rc EQUAL 0)
        message(FATAL_ERROR "Applying ${_patch} to third_party/lvgl failed: ${_err}")
    endif()
    message(STATUS "Applied ${patch} to third_party/lvgl")
endfunction()
plv_apply_lvgl_patch(0001-opengles-driver-gl21-glsl120.patch
    src/drivers/opengles/opengl_shader/lv_opengl_shader_internal.h "LV_OPENGL_GLSL_VERSION_120")
plv_apply_lvgl_patch(0002-nanovg-image-from-gl-texture.patch
    include/lvgl/draw/lv_image_dsc.h "LV_IMAGE_FLAGS_GL_TEXTURE")

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
if(APPLE)
    # OpenGL and CGL are deprecated on macOS since 10.14. The project still
    # uses them because that is the context Psychtoolbox creates, so the two
    # macros turn off several thousand deprecation warnings that would
    # otherwise hide real ones.
    target_compile_definitions(lvgl PUBLIC GL_SILENCE_DEPRECATION=1 CGL_SILENCE_DEPRECATION=1)
endif()
if(PSYCHLVGL_TRACY)
    target_compile_definitions(lvgl PUBLIC PSYCHLVGL_TRACY=1)
endif()

# --- core layer ------------------------------------------------------------
set(PLV_CORE_SOURCES
    src/core/plv_core.c
    src/core/plv_handles.c
    src/core/plv_res.c
    src/core/plv_assets.c
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
if(APPLE)
    target_compile_definitions(plv_core PUBLIC GL_SILENCE_DEPRECATION=1 CGL_SILENCE_DEPRECATION=1)
endif()
if(PSYCHLVGL_TRACY)
    # Tracy is C++. Compiling its client into this library keeps the MEX plain
    # C. plv_tracy.cpp is the one piece of the GPU zone that needs C++.
    if(EXISTS ${PSYCHLVGL_TRACY_DIR}/public/TracyClient.cpp)
        enable_language(CXX)
        target_sources(plv_core PRIVATE ${PSYCHLVGL_TRACY_DIR}/public/TracyClient.cpp
                                        src/core/plv_tracy.cpp)
        target_include_directories(plv_core PUBLIC ${PSYCHLVGL_TRACY_DIR}/public)
        target_compile_definitions(plv_core PUBLIC TRACY_ENABLE=1 PSYCHLVGL_TRACY=1)
    else()
        message(FATAL_ERROR
            "PSYCHLVGL_TRACY=ON but Tracy is missing: ${PSYCHLVGL_TRACY_DIR}/public/TracyClient.cpp "
            "does not exist. Clone it with
"
            "  git clone --branch v0.11.1 https://github.com/wolfpld/tracy.git third_party/tracy
"
            "or pass -DPSYCHLVGL_TRACY_DIR=<a Tracy checkout>, or configure with "
            "-DPSYCHLVGL_TRACY=OFF. See third_party/PINS.md.")
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
    # The phase 2 scene loads a TTF file from the LVGL submodule.
    target_compile_definitions(smoke_gl PRIVATE PLV_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}")
    if(WIN32)
        target_link_libraries(smoke_gl PRIVATE opengl32 gdi32 user32)
    elseif(APPLE)
        # CGL lives in OpenGL.framework, which plv_core already links, so the
        # macOS branch of the smoke test needs no library of its own. The line
        # is here so that a reader does not look for a missing one.
    else()
        # The X11 branch of the smoke test creates its own GLX context.
        target_link_libraries(smoke_gl PRIVATE X11)
    endif()
endif()
