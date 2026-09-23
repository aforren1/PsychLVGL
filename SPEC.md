# PsychLVGL specification

Status: implemented through phase 3. Specification version 0.1, 2026-09-22; section 14 records every deviation. Sections 5 and 7 also list the phase 2 and phase 3 subcommands and marshaling rules.

`PsychLVGL` is a MEX binding of LVGL 9 for MATLAB and GNU Octave. It draws
retained-mode GUI panels inside a Psychtoolbox (PTB) onscreen window. LVGL
renders on the GPU with its NanoVG draw unit into an OpenGL texture, inside
PTB's userspace OpenGL context. PTB draws that texture like any other PTB
texture.

This document is the design reference for the implementation. Section 3 and
section 4 explain the design. The other sections are reference material.

## 1. Purpose and scope

### 1.1 Purpose

A PTB experiment script builds a widget tree once with `PsychLVGL(...)` calls,
then calls `PsychLVGL('Update', ...)` every frame. LVGL handles layout, focus,
animation, and redraw. The script reads user actions from an event queue.

Typical uses: operator control panels with persistent layout, forms, status
displays, and touch-style interfaces.

### 1.2 In scope

- One LVGL display per MATLAB or Octave process, rendered into one GL texture,
  bound to one PTB onscreen window.
- GPU rendering only: LVGL OpenGL texture driver plus the NanoVG draw unit.
- Procedural widget creation with opaque handles and a polled event queue.
- Generated bindings for about 120 core functions, selected by an allowlist,
  plus all `lv_obj_set_style_*` setters.
- Mouse, wheel, keyboard, and text input from PTB functions.
- User interfaces that the LVGL editor (LVGL Pro) saves as XML, parsed in C
  and interpreted in MATLAB at run time, with no compiler (phase 3).
- MATLAB R2023a and Octave 10.1 on Windows, verified. Linux verified in CI.
  macOS on Apple silicon (`maca64`) is a build target with CI jobs of its own:
  MATLAB R2023b, Homebrew Octave, and the native smoke test on a CGL context.
  Those three jobs are not blocking yet. Intel Macs (`maci64`) are not built.

### 1.3 Out of scope

- Software rendering at run time. A software build variant exists for tests
  only.
- LVGL's own XML engine. LVGL removed the open-source loader in 9.5.0; phase 3
  interprets the editor's XML in MATLAB instead (section 13).
- Callbacks from LVGL into MATLAB code. Events are queued and polled.
- More than one display or PTB window.
- Any code shared with other bindings. This project is self-contained.

## 2. Dependencies and pinned versions

| Dependency | Version | Location | Reason |
|---|---|---|---|
| LVGL | v9.6.0 | `third_party/lvgl` (git submodule) | Core, OpenGL texture driver (`src/drivers/opengles`), NanoVG draw unit (`src/draw/nanovg`), vendored NanoVG (`src/libs/nanovg`), vendored glad loader (`src/drivers/opengles/glad`), `scripts/gen_json`. |
| Tracy | 0.11.x | `third_party/tracy` (git submodule, optional) | Profiler client, compiled only with `PSYCHLVGL_TRACY=ON`. |
| Psychtoolbox | 3.0.19 or later | user install | `Screen('BeginOpenGL')`, `Screen('SetOpenGLTexture')`, `KbEventGet` with `CookedKey`, `GetMouseWheel`. |
| MATLAB | R2023a verified, R2019b or later expected | user install | C MEX with MSVC 2022. |
| Octave | 10.1 verified, 8.x expected | user install | `mkoctfile --mex` with the bundled MinGW gcc. |
| CMake | 3.16 or later | build machine | Builds the LVGL static library with the project `lv_conf.h`. |
| Python and uv | Python 3.10 or later, pycparser 2.22 or later, pymsvc on Windows, doxygen | developer machine only | Runs `gen_json.py` and `gen/generate.py`. Generated files are committed. |
| LVGL editor (LVGL Pro) | current | user's choice, phase 3 only | Saves user interfaces as XML, which `PsychLVGLLoadXML` interprets. Community license is free for personal and open-source use. |
| pugixml | latest release, pinned in `third_party/PINS.md` | phase 3, compiled into the core static library | XML parser for `ParseXML`. MIT. Octave has no built-in XML reader, so parsing happens in C. |

LVGL notes that the OpenGL driver API is experimental. All driver calls live in
one file, `src/plv_display.c`, so an API change touches one place.

## 3. Architecture overview

```
MATLAB / Octave script
  |  h = PsychLVGL('SliderCreate', parent)   PsychLVGL('Update', t, mouse, wheel, keys)   E = PsychLVGL('Poll')
  v
+------------------------------------------------------------------+
| PsychLVGL MEX (C99)                                              |
|  dispatch:  sorted name table + opcode fast path                 |
|  handles:   slot table, generation counter, LV_EVENT_DELETE hook |
|  events:    fixed ring buffer filled by one LV_EVENT_ALL callback|
|  input:     PTB polls -> pointer, encoder, keypad indevs         |
|  display:   lv_opengles_texture_create + NanoVG draw unit        |
|  gl loader: gladLoadGL(psychlvgl_get_proc)                       |
+------------------------------------------------------------------+
  |  OpenGL calls, only between Screen('BeginOpenGL') and Screen('EndOpenGL')
  v
GL texture (owned by LVGL)  --Screen('SetOpenGLTexture')-->  PTB texture  --Screen('DrawTexture')-->  Screen('Flip')
```

Design choices and why:

- LVGL renders into a GL texture that lives in PTB's context. PTB wraps that
  texture once with `Screen('SetOpenGLTexture')`. No pixels cross the CPU. The
  script places the panel anywhere with `Screen('DrawTexture')`.
- The NanoVG draw unit is the only renderer. LVGL documents it as the
  recommended GPU renderer. It renders fills, gradients, borders, shadows,
  text, images, lines, arcs, and layers on the GPU. The alternative
  `LV_USE_DRAW_OPENGLES` still rasterizes on the CPU and only caches textures.
- Widgets are opaque handles and events are polled. LVGL is callback driven,
  but MATLAB code must not run inside LVGL callbacks. A ring buffer converts
  callbacks into a per-frame matrix.
- Input is gathered in MATLAB with PTB functions and passed to the MEX once per
  frame. PTB already solves per-platform keyboard and mouse access.
- The MEX is plain C. LVGL is C99 and the MATLAB MEX C API works in both
  engines. Tracy, when enabled, is compiled into the static library so the MEX
  stays C.

## 4. PTB integration contract

### 4.1 Verified PTB behavior

These facts come from the PTB source tree, `PsychSourceGL/Source/`.

- `Screen('BeginOpenGL', win)` (`Common/Screen/SCREENglMatrixFunctionWrappers.c`)
  switches to a separate userspace GL context. That context shares textures,
  buffers, FBOs, and shaders with PTB's context but not render state. PTB binds
  its current FBO in the userspace context and sets viewport, scissor, and
  projection on the first call.
- `BeginOpenGL` fails unless the script called `InitializeMatlabOpenGL` first.
- `Screen('EndOpenGL', win)` calls `glGetError` and aborts the script if an
  error is pending. It also resets the FBO binding to PTB's.
- `Screen('SetOpenGLTexture', win, texOrZero, glTexId, target, glWidth,
  glHeight)` (`Common/Screen/SCREENSetOpenGLTexture.c`) wraps an external GL
  texture as a PTB texture. Pass an existing PTB texture handle to update it.
- PTB windows use a legacy compatibility GL context. On Windows PTB does not
  call `wglCreateContextAttribsARB` (`Windows/Screen/PsychWindowGlue.c`), so the
  driver returns the highest compatibility version it supports. On macOS PTB
  uses a GL 2.1 context.

### 4.2 Verified LVGL behavior

These facts come from the LVGL v9.6.0 tree.

- `lv_opengles_texture_create(w, h)` (`include/lvgl/drivers/opengles/lv_opengles_texture.h`)
  creates a display that renders into a GL texture. The context must be
  current. `lv_opengles_texture_get_texture_id(disp)` returns the texture id.
- With `LV_USE_DRAW_NANOVG`, the display gets a static dummy buffer and NanoVG
  draw buffer handlers (`src/drivers/opengles/lv_opengles_texture.c`). No CPU
  frame buffer exists. NanoVG renders into the texture through its own FBO with
  a stencil renderbuffer (`src/libs/nanovg/nanovg_gl_utils.h`).
- `lv_opengles_init()` creates the driver's shaders and buffers and calls
  `lv_draw_nanovg_init()`. It needs a current context. `LV_USE_OPENGLES`
  requires `LV_USE_MATRIX`.
- Upstream `lv_opengles_init()` is not GL 2.1 clean, whatever `LV_NANOVG_BACKEND`
  says. `lv_opengles_shader_manager_init` (`opengl_shader/lv_opengl_shader_manager.c`)
  offers only `#version 300 es`, `#version 330` and `#version 100`, and the
  driver uses `GL_R8` for `LV_COLOR_FORMAT_L8` textures. A macOS compatibility
  context has GLSL 1.20 and no 3.0 internal formats. `LV_NANOVG_BACKEND_GL2`
  only changes the NanoVG draw unit, which is a separate shader set. The
  vendored patch in `patches/lvgl` closes both gaps (D38). Vertex array and
  framebuffer objects need no patch: LVGL's glad is generated with `ALIAS`, so
  `glGenVertexArrays` and `glDeleteVertexArrays` fall back to their `APPLE`
  forms and the framebuffer functions to their `EXT` forms when the core names
  are absent, and Apple's legacy profile exports both extensions. The one
  exception is `glBindVertexArray`, which the registry does not list as an
  alias of `glBindVertexArrayAPPLE`; `plv_gl_load` fills it after `gladLoadGL`.
- `LV_NANOVG_BACKEND` is read only by `src/draw/nanovg/lv_draw_nanovg_private.h`,
  which no public header includes. The value therefore has to match between
  CMake and `lv_conf.h`, but a mismatch cannot change a struct layout.
- `gladLoadGL(loader)` is called only by LVGL's GLFW and EGL drivers. With the
  texture driver alone, the embedding application must load the GL entry
  points. The MEX does this in `src/plv_gl_loader.c`.
- The driver does not support runtime resolution change.
- `LV_NANOVG_BACKEND` selects the shader flavor at compile time. GL3 matches
  PTB contexts on Windows and Linux. GL2 matches macOS.

### 4.3 Required call order

Four helper M-files carry the call order, so a script never writes a
`Screen('BeginOpenGL')` and `Screen('EndOpenGL')` pair itself:

```matlab
% Setup, once
PsychLVGLSetup();                                       % the MEX for this platform
InitializeMatlabOpenGL(1);                              % required by Screen('BeginOpenGL')
[win, winRect] = PsychImaging('OpenWindow', screenid, 0);

panelW = 400; panelH = 600;
dst = [20 20 20 + panelW, 20 + panelH];
ui  = PsychLVGLOpen(win, panelW, panelH, dst);          % Init, wrap, keyboard queue

% Build the UI, once (no GL calls)
scr = PsychLVGL('ScreenActive');
sl  = PsychLVGL('SliderCreate', scr);
PsychLVGL('ObjSetSize', sl, 300, 20);
PsychLVGL('ObjAlign', sl, 'CENTER', 0, 0);

% Every frame
while running
    [ui, E] = PsychLVGLFrame(ui);                       % input, Update, DrawTexture, Poll
    Screen('Flip', win);                                % the script still owns the flip
end

% Teardown, once
PsychLVGLClose(ui);
sca;
```

`PsychLVGLGL(ui, 'Update', tNow, mouse, wheel, keys)` wraps any single
subcommand marked GL in section 5, for a frame loop that needs its own input.

The same sequence without the helpers, which is what they do:

```matlab
% Setup, once
InitializeMatlabOpenGL(1);                              % required by Screen('BeginOpenGL')
[win, winRect] = PsychImaging('OpenWindow', screenid, 0);
panelW = 400; panelH = 600;
Screen('BeginOpenGL', win);
glTex = PsychLVGL('Init', panelW, panelH);              % LVGL renders into this GL texture
Screen('EndOpenGL', win);
tex = Screen('SetOpenGLTexture', win, [], glTex, GL_TEXTURE_2D, panelW, panelH, 32);
dst = [20 20 20 + panelW, 20 + panelH];
kq  = PsychLVGLInput('Start', win);

% Build the UI, once (no GL calls, may run outside BeginOpenGL)
scr = PsychLVGL('ScreenActive');
sl  = PsychLVGL('SliderCreate', scr);
PsychLVGL('ObjSetSize', sl, 300, 20);
PsychLVGL('ObjAlign', sl, 'CENTER', 0, 0);

% Every frame
[mouse, wheel, keys] = PsychLVGLInput('Poll', kq, win, dst, panelW, panelH);
Screen('BeginOpenGL', win);
dirty = PsychLVGL('Update', GetSecs, mouse, wheel, keys);   % ticks, input, lv_timer_handler, NanoVG renders into glTex
Screen('EndOpenGL', win);
Screen('DrawTexture', win, tex, [], dst);
Screen('Flip', win);
E = PsychLVGL('Poll');                                   % Nx5 double, see section 5.4

% Teardown, once
Screen('BeginOpenGL', win);
PsychLVGL('Shutdown');
Screen('EndOpenGL', win);
Screen('Close', tex);
PsychLVGLInput('Stop', kq);
sca;
```

### 4.4 Rules

| Rule | Statement | Reason |
|---|---|---|
| R1 | Call `Init`, `Update`, `Shutdown`, and every subcommand marked GL in section 5 between `Screen('BeginOpenGL')` and `Screen('EndOpenGL')`. Widget creation and property calls do not need a current context. | NanoVG issues GL calls from `lv_timer_handler`. Widget calls only change LVGL data and mark areas invalid. The MEX checks for a current context on GL subcommands and raises `psychlvgl:NoGLContext`. |
| R2 | Call `PsychLVGL` only from the MATLAB main thread. | MEX functions run on the main thread. GL contexts are thread bound. |
| R3 | `Update` leaves `glGetError` at `GL_NO_ERROR`. | `Screen('EndOpenGL')` aborts the script on a pending error. `Update` drains errors first and raises `psychlvgl:GLError` with the enum name. |
| R4 | `Update` restores the FBO binding it found. | NanoVG binds its own FBOs. PTB resets the binding at `EndOpenGL` too, but restoring it keeps the contract explicit. |
| R5 | The panel size is fixed after `Init`. `Init` with a different size runs `Shutdown` and `Init` and returns a new texture id. | The driver has no runtime resize. The script re-wraps the new id with `Screen('SetOpenGLTexture')`. |
| R6 | The MEX never calls `Screen`. | The MEX has no PTB dependency. |
| R7 | Mouse coordinates passed to `Update` are panel pixels. | The script chooses where the panel appears. `PsychLVGLInput('Poll')` subtracts the destination rectangle origin and scales when the destination size differs from the panel size. |
| R8 | The script owns the PTB texture handle. | PTB deletes it on `Screen('Close')`. The MEX only knows the GL texture id. |

## 5. MATLAB API reference

All functions accept a subcommand name as the first argument, or a numeric
opcode (section 9.1). `PsychLVGL` with no arguments prints the list.
`PsychLVGL('Name?')` prints the help for one subcommand.

Subcommand names for generated functions come from the LVGL name with the
`lv_` prefix removed and CamelCase applied: `lv_slider_set_value` becomes
`SliderSetValue`, `lv_obj_set_style_bg_color` becomes `ObjSetStyleBgColor`.

### 5.1 Lifecycle subcommands

| Subcommand | GL | Signature | Notes |
|---|---|---|---|
| Init | yes | `glTex = PsychLVGL('Init', w, h [, opts])` | Loads GL entry points, `lv_init`, tick callback, `lv_opengles_init`, `lv_opengles_texture_create(w, h)`, own flush callback, indevs, default group, `mexLock`, `mexAtExit`. Returns the GL texture id. `opts` fields: `FontDefault` (name, default `'montserrat_16'`), `LogLevel` (0 to 5, default 2 = warnings), `QueueCapacity` (default 1024, power of two), `MaxObjects` (default 4096), `WheelMode` (`'encoder'` default or `'keys'`), `Theme` (`'default'`, `'dark'`, `'light'`). Errors: `psychlvgl:AlreadyInitialized`, `psychlvgl:GLInit`, `psychlvgl:NoGLContext`. |
| Shutdown | yes | `PsychLVGL('Shutdown')` | `lv_deinit` (destroys display, NanoVG context, FBO cache), `lv_opengles_deinit`, zero tables and rings, `mexUnlock`. If no context is current, GL objects are abandoned with a warning. |
| Update | yes | `dirty = PsychLVGL('Update', tNow, mouse, wheel, keys)` | `tNow` in seconds. `mouse` is `[x y pressed]` in panel pixels. `wheel` is a scalar, clicks since last call. `keys` is Nx2 `[lvKey pressed]`, N may be 0. Order inside: tick, copy keys into the keypad ring, set pointer and encoder state, `lv_indev_read` on the three indevs, `lv_timer_handler`, restore FBO binding, GL error drain. Returns 1 when the flush callback ran. |
| Poll | no | `E = PsychLVGL('Poll')` | Drains the event ring into an Nx5 double matrix. Section 5.4. |
| Version | no | `v = PsychLVGL('Version')` | Struct: `lvgl`, `psychlvgl`, `nanovgBackend`, `glVersion`, `glRenderer`, `build`. |
| Opcode | no | `op = PsychLVGL('Opcode', 'SliderSetValue')` | Numeric opcode. |
| Stats | no | `s = PsychLVGL('Stats' [, 'reset'])` | Section 9.2. |
| Enum | no | `v = PsychLVGL('Enum', 'LV_EVENT_CLICKED')` | Value from the generated enum table. Also accepts `'LV_PART_MAIN|LV_STATE_PRESSED'`. |
| FontList | no | `names = PsychLVGL('FontList')` | Cellstr of built-in font names. |
| Log | no | `PsychLVGL('Log', level)` | Changes the log filter at run time. |

### 5.2 Handle and event subcommands (hand-written)

| Subcommand | Signature | Notes |
|---|---|---|
| ScreenActive | `h = PsychLVGL('ScreenActive')` | Handle of `lv_screen_active()`. Registers a slot on first use. |
| ScreenCreate | `h = PsychLVGL('ScreenCreate')` | `lv_obj_create(NULL)`. |
| ScreenLoad | `PsychLVGL('ScreenLoad', h)` | `lv_screen_load`. |
| ObjDelete | `PsychLVGL('ObjDelete', h)` | Deletes the object and its children. All affected slots are freed through the delete hook. |
| IsValid | `tf = PsychLVGL('IsValid', h)` | Slot and generation check without error. Takes object handles and the resource handles of section 7.4 (series, cursor, style, image, font). |
| AddEvent / RemoveEvent | `PsychLVGL('AddEvent', h, 'LONG_PRESSED')` | Edits the per-object event mask. Names without the `LV_EVENT_` prefix. |
| AddToGroup / RemoveFromGroup | `PsychLVGL('AddToGroup', h)` | Default focus group for keypad and encoder input. |
| FocusObj | `PsychLVGL('FocusObj', h)` | `lv_group_focus_obj`. |
| EventName | `name = PsychLVGL('EventName', code)` | Reverse lookup for `Poll` output. |
| StyleCreate | `style = PsychLVGL('StyleCreate')` | New `lv_style_t` with no properties. Phase 2. |
| StyleSetProp | `PsychLVGL('StyleSetProp', style, prop, value)` | `prop` is the property of any `ObjSetStyle<Prop>` subcommand, as `'bg_color'`, `'BgColor'` or `'LV_STYLE_BG_COLOR'`. `value` follows the same rule as in that subcommand. Objects that use the style redraw. |
| StyleDelete | `PsychLVGL('StyleDelete', style)` | Raises `psychlvgl:InUse` while any object still has the style. |
| ObjAddStyle | `PsychLVGL('ObjAddStyle', h, style [, selector])` | `lv_obj_add_style`. Selector default `LV_PART_MAIN`. |
| ObjRemoveStyle | `PsychLVGL('ObjRemoveStyle', h, style [, selector])` | `lv_obj_remove_style`. Style 0 means every style. Selector default `LV_PART_ANY \| LV_STATE_ANY`, so every entry of the style goes. |
| ObjRemoveStyleAll | `PsychLVGL('ObjRemoveStyleAll', h)` | `lv_obj_remove_style_all`, theme and local styles included. |
| ImageFromTexture | `img = PsychLVGL('ImageFromTexture', glTex, w, h [, transposed])` | Image handle that draws an existing `GL_TEXTURE_2D` texture with no copy. `w` and `h` are the size as shown. Without `transposed` the texture is stored bottom row first; with `transposed` true it holds the image with rows and columns swapped, `h` texels wide, as Psychtoolbox stores a texture made from a matrix. The texture stays the caller's. `m/PsychLVGLImageFromTexture.m` makes one from a Psychtoolbox texture. |
| ImageFromArray | `img = PsychLVGL('ImageFromArray', uint8Image)` | Image handle from a uint8 HxW, HxWx3 or HxWx4 array. The MEX keeps an ARGB8888 copy. |
| ImageDelete | `PsychLVGL('ImageDelete', img)` | Raises `psychlvgl:InUse` while an image object shows it. |
| FontLoad | `font = PsychLVGL('FontLoad', ttfPath, px)` | TTF or OTF font through `tiny_ttf`, 1 to 1000 px. The handle works wherever a font name does. |
| FontDelete | `PsychLVGL('FontDelete', font)` | Raises `psychlvgl:InUse` while a style or an object names the font. |
| ChartSetValues | `PsychLVGL('ChartSetValues', chart, series, values)` | Copies a numeric vector into the series' own array, point 1 first. NaN and the points past the end become gaps. |
| ChartGetValues | `values = PsychLVGL('ChartGetValues', chart, series)` | 1xN double in screen order; gaps are NaN. |
| ParseXML | `tree = PsychLVGL('ParseXML', pathOrText)` | Phase 3. Parses an XML file, or XML text when the argument contains `<`, with pugixml. Returns the top-level elements as a 1xN struct array with fields `tag`, `attributes`, `attr_names`, `text` and `children`; section 7.6. Needs no `Init`. Errors: `psychlvgl:XML` with pugixml's description, the byte offset, the line and the column. |

### 5.3 Generated subcommands

The generator (section 7) emits one subcommand per allowlisted LVGL function.
Initial allowlist, about 120 functions plus all style setters:

| Widget | Functions (LVGL names) |
|---|---|
| obj | `lv_obj_create`, `lv_obj_set_pos`, `lv_obj_set_x`, `lv_obj_set_y`, `lv_obj_set_size`, `lv_obj_set_width`, `lv_obj_set_height`, `lv_obj_align`, `lv_obj_align_to`, `lv_obj_center`, `lv_obj_set_parent`, `lv_obj_add_flag`, `lv_obj_remove_flag`, `lv_obj_has_flag`, `lv_obj_add_state`, `lv_obj_remove_state`, `lv_obj_has_state`, `lv_obj_get_x`, `lv_obj_get_y`, `lv_obj_get_width`, `lv_obj_get_height`, `lv_obj_get_child_count`, `lv_obj_get_child`, `lv_obj_get_parent`, `lv_obj_invalidate`, `lv_obj_scroll_to_view`, `lv_obj_set_flex_flow`, `lv_obj_set_flex_align`, `lv_obj_set_layout` |
| label | `lv_label_create`, `lv_label_set_text`, `lv_label_set_long_mode`, `lv_label_get_text` |
| button | `lv_button_create` |
| slider | `lv_slider_create`, `lv_slider_set_value`, `lv_slider_set_range`, `lv_slider_set_mode`, `lv_slider_get_value`, `lv_slider_get_min_value`, `lv_slider_get_max_value`, `lv_slider_set_left_value` |
| switch | `lv_switch_create` |
| checkbox | `lv_checkbox_create`, `lv_checkbox_set_text`, `lv_checkbox_get_text` |
| bar | `lv_bar_create`, `lv_bar_set_value`, `lv_bar_set_range`, `lv_bar_set_start_value`, `lv_bar_get_value`, `lv_bar_set_mode` |
| arc | `lv_arc_create`, `lv_arc_set_value`, `lv_arc_set_range`, `lv_arc_set_bg_angles`, `lv_arc_set_angles`, `lv_arc_set_rotation`, `lv_arc_set_mode`, `lv_arc_get_value` |
| dropdown | `lv_dropdown_create`, `lv_dropdown_set_options`, `lv_dropdown_add_option`, `lv_dropdown_clear_options`, `lv_dropdown_set_selected`, `lv_dropdown_get_selected`, `lv_dropdown_get_selected_str`, `lv_dropdown_set_text`, `lv_dropdown_set_dir`, `lv_dropdown_open`, `lv_dropdown_close` |
| roller | `lv_roller_create`, `lv_roller_set_options`, `lv_roller_set_selected`, `lv_roller_get_selected`, `lv_roller_get_selected_str`, `lv_roller_set_visible_row_count` |
| textarea | `lv_textarea_create`, `lv_textarea_set_text`, `lv_textarea_add_text`, `lv_textarea_add_char`, `lv_textarea_delete_char`, `lv_textarea_get_text`, `lv_textarea_set_placeholder_text`, `lv_textarea_set_one_line`, `lv_textarea_set_password_mode`, `lv_textarea_set_max_length`, `lv_textarea_set_accepted_chars`, `lv_textarea_set_cursor_pos`, `lv_textarea_get_cursor_pos` |
| spinbox | `lv_spinbox_create`, `lv_spinbox_set_value`, `lv_spinbox_set_range`, `lv_spinbox_set_digit_format`, `lv_spinbox_set_step`, `lv_spinbox_increment`, `lv_spinbox_decrement`, `lv_spinbox_get_value` |
| table | `lv_table_create`, `lv_table_set_cell_value`, `lv_table_set_row_count`, `lv_table_set_column_count`, `lv_table_set_column_width`, `lv_table_get_selected_cell`, `lv_table_get_cell_value` |
| styles | every `lv_obj_set_style_<prop>` from `lv_obj_style_gen.h`, selector optional with default `LV_PART_MAIN` |
| chart (phase 2) | `lv_chart_create`, `lv_chart_set_type`, `lv_chart_get_type`, `lv_chart_set_point_count`, `lv_chart_get_point_count`, `lv_chart_set_axis_range`, `lv_chart_set_axis_min_value`, `lv_chart_set_axis_max_value`, `lv_chart_set_update_mode`, `lv_chart_get_update_mode`, `lv_chart_set_div_line_count`, `lv_chart_refresh`, `lv_chart_add_series`, `lv_chart_remove_series`, `lv_chart_hide_series`, `lv_chart_set_series_color`, `lv_chart_get_series_color`, `lv_chart_set_x_start_point`, `lv_chart_get_x_start_point`, `lv_chart_set_all_values`, `lv_chart_set_next_value`, `lv_chart_set_series_values`, `lv_chart_set_series_value_by_id`, `lv_chart_get_pressed_point`, `lv_chart_add_cursor`, `lv_chart_remove_cursor`, `lv_chart_set_cursor_pos_x`, `lv_chart_set_cursor_pos_y`, `lv_chart_set_cursor_point` |
| phase 3, for the XML attributes | `lv_obj_set_scrollbar_mode`, `lv_obj_set_scroll_snap_x`, `lv_obj_set_scroll_snap_y`, `lv_obj_set_scroll_dir`, `lv_obj_set_ext_click_area`, `lv_obj_set_flex_grow`, `lv_obj_set_name`, `lv_obj_find_by_name`, the 26 per-flag setters `lv_obj_set_hidden` to `lv_obj_set_flex_in_new_track`, `lv_label_set_recolor`, `lv_label_set_text_selection_start`, `lv_label_set_text_selection_end`, `lv_switch_set_orientation`, `lv_bar_set_orientation`, `lv_arc_set_start_angle`, `lv_arc_set_end_angle`, `lv_arc_set_bg_start_angle`, `lv_arc_set_bg_end_angle`, `lv_arc_set_change_rate`, `lv_textarea_set_password_show_time`, `lv_spinbox_set_rollover`, `lv_spinbox_set_digit_count`, `lv_spinbox_set_dec_point_pos`, `lv_table_set_cell_ctrl`, `lv_chart_set_hor_div_line_count`, `lv_chart_set_ver_div_line_count`, `lv_image_set_pivot_x`, `lv_image_set_pivot_y` (D52) |
| image (phase 2) | `lv_image_create`, `lv_image_set_src`, `lv_image_set_offset_x`, `lv_image_set_offset_y`, `lv_image_set_rotation`, `lv_image_set_pivot`, `lv_image_set_scale`, `lv_image_set_scale_x`, `lv_image_set_scale_y`, `lv_image_set_antialias`, `lv_image_set_inner_align`, `lv_image_get_src_width`, `lv_image_get_src_height`, `lv_image_get_rotation`, `lv_image_get_scale` |

`lv_obj_create` and every `lv_<widget>_create` return a new handle. Getters
that return `const char*` return char. Getters with output pointers
(`lv_table_get_selected_cell`) return extra outputs.

### 5.4 Poll output

`E = PsychLVGL('Poll')` returns an Nx5 double matrix, one row per event, oldest
first:

| Column | Content |
|---|---|
| 1 | `target` handle (the object the callback was registered on) |
| 2 | event code (`LV_EVENT_*`) |
| 3 | `current_target` handle, or 0 for LVGL-internal objects |
| 4 | `param`: widget value for VALUE_CHANGED (slider, arc, bar, spinbox value; dropdown and roller selected index; checkbox and switch checked state; chart pressed point index, 2147483647 when none), key code for KEY, 0 otherwise |
| 5 | `tNow` of the `Update` call that produced the event |

`PsychLVGLEvents('decode', E)` returns a struct array with `target`, `name`,
`code`, `currentTarget`, `param`, `time`. `PsychLVGLEvents('filter', E, h,
'CLICKED')` returns the matching rows.

Default subscriptions per object: CLICKED, VALUE_CHANGED, PRESSED, RELEASED,
FOCUSED, DEFOCUSED, READY, CANCEL. `AddEvent` and `RemoveEvent` change the
mask. The ring holds `QueueCapacity` records. On overflow the oldest record is
dropped and `stats.eventsDropped` increments.

### 5.5 Helper M-files

The first four carry the OpenGL call order, so a script never writes a
`Screen('BeginOpenGL')` and `Screen('EndOpenGL')` pair itself. The naming
follows `Screen('OpenWindow')` and `Screen('Close')`, and
`PsychPortAudio('Open')` and `('Close')`.

| File | Purpose |
|---|---|
| `m/PsychLVGLOpen.m` | `ui = PsychLVGLOpen(win, w, h [, dst] [, opts])`. Checks that 3D graphics are on, wraps `Init` in a BeginOpenGL pair, wraps the GL texture with `Screen('SetOpenGLTexture')`, starts the keyboard queue, returns the struct the script keeps. |
| `m/PsychLVGLFrame.m` | `[ui, E] = PsychLVGLFrame(ui)`. Input, BeginOpenGL, `Update`, EndOpenGL, `DrawTexture`, `Poll`. The script still owns `Screen('Flip')`. |
| `m/PsychLVGLGL.m` | `[...] = PsychLVGLGL(ui, subcommand, ...)`. Wraps any one subcommand marked GL. Calls straight through when `Screen('GetOpenGLDrawMode')` reports the userspace context is already current. |
| `m/PsychLVGLClose.m` | `PsychLVGLClose(ui)`. Wraps `Shutdown`, closes the PTB texture, stops the keyboard queue. Safe twice, and safe after the window is closed. |
| `m/PsychLVGLSetup.m` | Puts `dist/<arch>` and `m/` on the path for this engine and platform. `'save'` also runs `savepath`. `'remove'` shuts the MEX down if it is locked, clears it, and only then takes `dist/<arch>`, `dist-sw/<arch>` and `m/` of this package off the path; it stops without a path change when the MEX stays locked, and does nothing when the package is not on the path. An identical copy sits at the package root, so a fresh unzip can call it with nothing on the path (D63). |
| `m/PsychLVGL.m` | Help text only. The MEX shadows it once built. Generated. |
| `m/PsychLVGLInput.m` | `Start`, `Poll`, `Stop`. Wraps `KbQueueCreate`, `KbQueueStart`, `KbEventGet`, `GetMouse`, `GetMouseWheel`. Converts mouse to panel pixels and key events to LVGL key codes. |
| `m/PsychLVGLKeyMap.m` | PTB key event to LVGL key code, section 6.3. |
| `m/PsychLVGLEvents.m` | `decode` and `filter`. |
| `m/PsychLVGLOp.m` | Generated struct of opcodes. |
| `m/PsychLVGLDemo.m` | Demo: Gabor patch controlled by a slider, a dropdown, a text area. Phase 2 adds a contrast history chart and a style shared by two widgets. |
| `m/PsychLVGLLoadXML.m` | `[root, named] = PsychLVGLLoadXML(file [, parent] [, opts])`. Phase 3. Builds the user interface of an LVGL editor `<screen>` or `<component>` file with ordinary PsychLVGL calls. `named` holds the handles by `name` attribute and the subject table in `named.subjects`. `opts`: `AssetDir`, `Consts`, `Warn`, `Globals`, `ComponentDirs`. |
| `m/PsychLVGLXMLToM.m` | `PsychLVGLXMLToM(file, outFile [, opts])`. Phase 3. Writes the same calls as a function `[root, named] = name(parent, assetDir)`. |
| `m/PsychLVGLSubjects.m` | Phase 3. The subject table of an XML interface: `create`, `add`, `bind`, `trigger`, `apply`, `update` (once per frame with the events), `set`, `get`. |
| `m/PsychLVGLImageFromFile.m` | `img = PsychLVGLImageFromFile(path)`. Phase 3. `imread` plus `ImageFromArray`, with transparency kept. |
| `m/PsychLVGLXMLDemo.m` | Phase 3 demo: the Gabor of `PsychLVGLDemo`, with its panel loaded from `examples/xml/gabor_panel/gabor_panel.xml` and driven by subjects. `PsychLVGLXMLDemo([], file)` saves a screenshot. |
| `m/private/plv_xml_*.m` | Phase 3. The interpreter (`plv_xml_run`), its two emitters (`plv_xml_emit_exec`, `plv_xml_emit_write`), and option and literal helpers. |
| `m/private/psychlvgl_demo_window*.m`, `psychlvgl_gabor_*.m` | The demo copies of `tests/gl/ptb_test_window`, `ptb_test_window_close`, `gabor_std` and `gabor_michelson` (D63). |
| `m/PsychLVGLImageFromTexture.m` | `img = PsychLVGLImageFromTexture(win, tex)`. Phase 2. Reads the OpenGL name, target and orientation of a Psychtoolbox texture with `Screen('GetOpenGLTexture')` and calls `ImageFromTexture`, with `transposed` set for a texture made from a matrix. Refuses rectangle textures with `psychlvgl:Texture`. |

Every one of the four uses `onCleanup` or `try` around `Screen('EndOpenGL')`,
so an error inside the wrapped region still leaves Psychtoolbox in 2D mode.

### 5.6 Error identifiers

| Identifier | Meaning |
|---|---|
| `psychlvgl:Usage` | Wrong number or class of arguments. |
| `psychlvgl:UnknownCommand` | Subcommand name or opcode not found. |
| `psychlvgl:NotInitialized` | Subcommand needs `Init` first. |
| `psychlvgl:AlreadyInitialized` | `Init` called twice with the same size. |
| `psychlvgl:NoGLContext` | GL subcommand called with no current GL context. |
| `psychlvgl:GLInit` | GL loader, `lv_opengles_init`, or texture creation failed. Message contains the GL version and the LVGL log. |
| `psychlvgl:GLError` | `glGetError` returned an error after `Update`. |
| `psychlvgl:InvalidHandle` | Handle is 0, out of range, freed, or from a previous generation. |
| `psychlvgl:LVGLAssert` | `LV_ASSERT_HANDLER` fired during the last call. |
| `psychlvgl:Type` | Argument class not accepted. |
| `psychlvgl:Range` | Numeric argument out of range for the C type. |
| `psychlvgl:Enum` | Unknown enum or event name. |
| `psychlvgl:Font` | Unknown font name, or a font file that cannot be read or parsed. |
| `psychlvgl:InUse` | `StyleDelete`, `ImageDelete` or `FontDelete` on a resource that an object or a style still uses. Phase 2. |
| `psychlvgl:Texture` | `PsychLVGLImageFromTexture` got a texture LVGL cannot draw, one that is not `GL_TEXTURE_2D`. Phase 2. |
| `psychlvgl:XML` | `ParseXML` could not read or parse its input, or `PsychLVGLLoadXML` got a file whose root element is not `<screen>`, `<component>` or `<globals>`. Phase 3. |

`PsychLVGLLoadXML` and `PsychLVGLXMLToM` also report four kinds of problem
through the `Warn` option, by default as MATLAB warnings with these
identifiers, once per distinct message and load: `psychlvgl:XMLUnknown` (an
element or attribute that is not part of the format), `psychlvgl:XMLUnsupported`
(part of the format that PsychLVGL does not map), `psychlvgl:XMLReference` (a
constant, style, font, image, subject or prop that does not resolve) and
`psychlvgl:XMLValue` (a value that does not parse). The rest of the file still
loads.

## 6. Input handling

### 6.1 Mouse

`PsychLVGLInput('Poll')` calls `GetMouse(win)`, subtracts the panel origin
`dst(1:2)`, scales by `panelW / (dst(3) - dst(1))` and the same for y when the
destination size differs from the panel size, and returns `[x y pressed]` with
`pressed = buttons(1)`. `Update` clamps the point to the panel and writes it to
the pointer indev with `LV_INDEV_STATE_PRESSED` or `RELEASED`. Points outside
the panel are clamped to the edge and reported released, so a drag that leaves
the panel ends cleanly.

### 6.2 Wheel

`GetMouseWheel()` returns clicks since the last call. With `WheelMode =
'encoder'` (default), `Update` writes `enc_diff = -wheel` to the encoder indev
with state RELEASED. The encoder changes the focused widget's value or scrolls.
With `WheelMode = 'keys'`, each click becomes an `LV_KEY_UP` or `LV_KEY_DOWN`
press and release pair on the keypad indev.

### 6.3 Keyboard and text

`PsychLVGLKeyMap` converts each `KbEventGet` event to one row `[lvKey
pressed]`:

1. If `CookedKey > 0`, `lvKey = CookedKey`. LVGL treats printable code points
   as text for text areas.
2. Otherwise map `KbName(Keycode)` through a fixed table: `UpArrow` 17,
   `DownArrow` 18, `RightArrow` 19, `LeftArrow` 20, `ESCAPE` 27, `DELETE` 127,
   `BackSpace` 8, `Return` 10, `tab` 9, `Home` 2, `End` 3. Shift held with
   `tab` gives 11 (`LV_KEY_PREV`).
3. Drop unmapped keys.

`Update` copies the rows into a 64-entry ring in the MEX. The keypad indev read
callback pops one record per call and sets `continue_reading` while records
remain. All three indevs run in `LV_INDEV_MODE_EVENT`, so LVGL reads them only
when `Update` calls `lv_indev_read`.

`Init` creates one default `lv_group_t` and assigns it to the keypad and
encoder indevs. Objects join it with `AddToGroup`. Text areas need to be in the
group to receive keys.

`CookedKey` values are UTF-16 units on Windows and UTF-32 on Linux and macOS.
The key path is numeric and never creates a MATLAB `char`, so Octave's limited
Unicode support does not affect it. Text setters convert MATLAB char to UTF-8
(section 7.3).

### 6.4 Tick

LVGL's tick comes from `tNow` passed to `Update`: `lv_tick_set_cb` returns
`(uint32_t)((tNow - t0) * 1000)`. The GUI shares one clock with PTB's
timestamps, animations line up with `Flip` times, and tests can inject
synthetic times for reproducible output. A non-monotonic `tNow` advances the
tick by 1 ms and increments `stats.tickAnomaly`.

`lv_conf.h` sets `LV_DEF_REFR_PERIOD 1`, so any invalidated area renders on the
next `Update`. The script's `Flip` cadence limits the frame rate.

## 7. Marshaling rules and the generator

### 7.1 Generator

`gen/generate.py` runs with `uv run gen/generate.py`. Steps:

1. Run `third_party/lvgl/scripts/gen_json/gen_json.py --lvgl-config lv_conf.h`
   and read the JSON from stdout.
2. Filter `functions` by `gen/allowlist.toml`. Apply the style-setter rule:
   every function named `lv_obj_set_style_*` with signature `(lv_obj_t*,
   <value>, lv_style_selector_t)` is included.
3. Emit `src/psychlvgl_gen.c` (one static handler per function plus the sorted
   name table and opcode enum), `src/psychlvgl_enums.c` (enum name table from
   `enums`), `m/PsychLVGL.m`, `m/PsychLVGLOp.m`, and `tests/test_gen_marshal.m`.

Generated files are committed. Users build without Python or doxygen.

### 7.2 Allowlist format

```toml
[widgets.slider]
functions = ["lv_slider_create", "lv_slider_set_value", "lv_slider_set_range"]

[rules]
style_setters = true          # include all lv_obj_set_style_*
exclude_suffix = ["_static"]  # lv_label_set_text_static keeps the caller's buffer
```

### 7.3 Type rules

| C type (from `args[].type`) | MATLAB input | MATLAB output |
|---|---|---|
| `lv_obj_t*` | handle double, validated against the slot table | new handle, registered on return when the pointer is unknown |
| `int32_t`, `uint32_t`, `int16_t`, `uint16_t`, `uint8_t`, `lv_coord_t`, `lv_value_precise_t` | double scalar, range checked | double scalar |
| `bool` | double or logical scalar | logical scalar |
| `const char*` | char row vector. MATLAB UTF-16 is converted to UTF-8 into a 4 KB stack buffer, heap above that. Octave char is UTF-8 bytes already. `string` is rejected. | char from UTF-8 |
| `lv_color_t` | `[r g b]` in 0 to 255, or a double scalar `0xRRGGBB` | 1x3 double |
| `lv_opa_t` | double 0 to 255, or a name such as `'LV_OPA_50'` | double |
| enums and flag typedefs (`lv_align_t`, `lv_obj_flag_t`, `lv_state_t`, `lv_part_t`, `lv_dir_t`, `lv_slider_mode_t`, ...) | double, or a name with or without the `LV_` prefix, or several names joined with `\|` | double |
| `lv_style_selector_t` | double or joined names, optional with default `LV_PART_MAIN` | none |
| `const lv_font_t*` | font name from `FontList`, or a `FontLoad` handle (phase 2) | none |
| `uint32_t key` in `lv_textarea_add_char` | double code point | none |
| output pointers to scalars, `lv_area_t*`, `lv_point_t*`, `uint32_t* row, uint32_t* col` | not passed | extra outputs |
| `const int32_t values[]` followed by a `size_t` or `uint32_t` count (phase 2) | real numeric vector, row or column, any numeric or logical class; one argument, the count comes from its length. Each element is range checked and truncated toward zero like an `int32_t` scalar; NaN raises `psychlvgl:Range`. An int32 vector is passed through without a copy; other classes are converted into a 1024 element stack buffer, or an `mxMalloc` buffer above that. LVGL copies the values, so the MEX never aliases MATLAB memory. | none |
| `lv_chart_series_t*`, `lv_chart_cursor_t*` (phase 2) | resource handle of section 7.4 that belongs to the chart argument; a handle of another chart raises `psychlvgl:InvalidHandle` | new resource handle, owned by the chart |
| `const void* src` of `lv_image_set_src` (phase 2) | `ImageFromTexture` or `ImageFromArray` handle, or 0 for no image | none |
| `lv_style_t*` (phase 2) | style handle, through the hand-written style subcommands of section 5.2 only | none |
| function pointers, other `void*`, variadic, arrays of structs, writable arrays such as `lv_chart_set_series_ext_y_array`, `lv_anim_t*`, `lv_draw_*`, `lv_image_dsc_t*`, `lv_indev_t*`, `lv_display_t*` | not supported. The generator refuses the entry. | |

Return convention: `[ret, out1, out2, ...]`. `void` functions return nothing
unless they have output pointers.

### 7.4 Handles

A handle is a double with value `gen * 65536 + idx`. `idx` is a slot index from
1 to 65535, `gen` a generation counter. 0 is the null handle.

Slot table, fixed size `MaxObjects`, 16 bytes per record:

```c
typedef struct {
    lv_obj_t *obj;        /* NULL when free; next free index stored in low bits when free */
    uint16_t  gen;
    uint16_t  flags;      /* LIVE, IS_SCREEN, FROM_PLUGIN */
    uint32_t  event_mask; /* bit per LV_EVENT_* code below 32; uint64 if needed */
} plv_slot_t;
```

Every object created through the MEX gets `lv_obj_set_user_data(obj, handle)`
and one `lv_obj_add_event_cb(obj, plv_on_event, LV_EVENT_ALL, NULL)`. The
callback frees the slot on `LV_EVENT_DELETE` and increments `gen`. A stale
handle then fails the generation check and raises `psychlvgl:InvalidHandle`.
This covers deletion by LVGL itself, for example when a parent is deleted or a
screen is unloaded with auto-delete.

Reverse lookup from `lv_obj_t*` to handle reads `lv_obj_get_user_data`. Objects
LVGL creates internally, such as a dropdown list, have no user data and report
handle 0 in `Poll`.

Phase 2 adds a second table for everything that is not a widget: chart series
and cursors, styles, images and fonts. It has 4096 entries of 24 bytes. A
resource handle is `(kind * 65536 + gen) * 65536 + idx` with `kind` 1 to 5, so
it is at least 2^32, never equals an object handle, and names its kind. A
series or cursor records its chart as owner; the chart's `LV_EVENT_DELETE` hook
frees every entry it owns, so a stale series handle raises
`psychlvgl:InvalidHandle` like a stale object handle. Styles, images and fonts
live until their Delete subcommand or `Shutdown`.

### 7.5 Event queue

```c
typedef struct {
    uint32_t target;
    uint32_t code;
    uint32_t current_target;
    int32_t  param;
    double   time;
} plv_event_t;                /* 24 bytes */
```

Ring of `QueueCapacity` records with `uint32_t head, tail`. `plv_on_event`
pushes when the code bit is set in the target slot's mask. The push never
allocates. On overflow the oldest record is dropped. `Poll` copies the live
records into one `mxCreateDoubleMatrix(n, 5)` and resets the ring.

### 7.6 XML node tree (phase 3)

`ParseXML` returns one struct array per level of the document, each made once
at its final size: the element children are counted first, then
`mxCreateStructMatrix(1, n, 5, fields)` is filled. The walk recurses on the C
stack and refuses documents deeper than 256 elements.

| Field | Content |
|---|---|
| `tag` | Element name, char. |
| `attributes` | 1x1 struct, one char field per attribute, in document order. |
| `attr_names` | `{}` when every attribute name is a valid field name; otherwise a 1xN cellstr of the original names, in the order of `fieldnames(attributes)`. |
| `text` | The text and CDATA children, each trimmed, joined by one space. `''` when there are none. |
| `children` | The element children, 1xN, or 0x0 with the same five fields. |

Field names follow `matlab.lang.makeValidName` in both engines: a character
that is not a letter, digit or underscore becomes `_`, a name that does not
start with a letter or that is a MATLAB or Octave keyword gets an `x` in
front, a name is cut to 63 characters, and a name that is then equal to an
earlier one gets `_2`, `_3` and so on. `bind_text-fmt` becomes
`bind_text_fmt`, `end` becomes `xend`. Comments, declarations and processing
instructions are not returned. Character data follows section 7.3: UTF-8
bytes on Octave, UTF-16 on MATLAB, decoded in C with no call to
`mxCreateString`. A file's encoding comes from its byte order mark or its
declaration; text passed as an argument is UTF-8 after the usual conversion.

## 8. State, lifecycle, and error handling

### 8.1 State

One static `plv_state_t` in `psychlvgl.c`:

| Member | Content |
|---|---|
| `disp`, `texture_id`, `w`, `h` | display and texture |
| `indev_pointer`, `indev_encoder`, `indev_keypad`, `group` | input |
| `pointer`, `enc_diff`, `keyring[64]` | current input state |
| `slots[]`, `free_head` | handle table |
| `events[]`, `head`, `tail` | event ring |
| `t0`, `last_tick` | tick |
| `dirty`, `saved_fbo` | render bookkeeping |
| `stats` | fixed arrays, section 9 |
| `deferred_error` | flag, id, message buffer of 512 bytes |
| `log_level` | filter |

### 8.2 Init sequence

1. Check for a current GL context. Raise `psychlvgl:NoGLContext` if none.
2. `gladLoadGL(plv_get_proc)`. The loader tries `wglGetProcAddress` then
   `GetProcAddress` on `opengl32.dll` on Windows, `glXGetProcAddressARB` on
   Linux, and `dlsym` on the OpenGL framework on macOS. Raise `psychlvgl:GLInit`
   on failure.
3. Read `GL_VERSION` and `GL_RENDERER`. Require 3.2 or later for the GL3 build,
   2.1 or later for the GL2 build.
4. `lv_init()`, `lv_tick_set_cb(plv_tick)`, `lv_log_register_print_cb(plv_log)`.
5. `lv_opengles_init()`. On failure raise `psychlvgl:GLInit` with the LVGL log,
   which contains the GLSL version negotiation.
6. `disp = lv_opengles_texture_create(w, h)`, `lv_display_set_default(disp)`,
   `lv_display_set_flush_cb(disp, plv_flush)`. The flush callback sets `dirty`,
   calls `lv_display_flush_ready`, and returns. NanoVG has already rendered
   into the texture.
7. Create indevs, set `LV_INDEV_MODE_EVENT`, create the group, apply the theme.
8. Save `texture_id = lv_opengles_texture_get_texture_id(disp)`.
9. `mexLock()`, `mexAtExit(plv_at_exit)`.

### 8.3 Update sequence

1. Check for a current GL context.
2. `glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved_fbo)`.
3. `lv_opengles_reinit_state()` to restore the driver's GL state after PTB or
   other code changed it between frames.
4. Tick, keys, pointer, encoder, `lv_indev_read` x3.
5. `lv_timer_handler()` with timing around it.
6. `glBindFramebuffer(GL_FRAMEBUFFER, saved_fbo)`.
7. Drain `glGetError`. Raise `psychlvgl:GLError` on the first error.
8. Return `dirty` and clear it.

### 8.4 Asserts and errors

`LV_ASSERT_HANDLER` is defined to `plv_assert_hook(__FILE__, __LINE__);` which
records into `deferred_error` and returns. LVGL continues on its own return
path. Every dispatched call ends with `plv_check_deferred_error()`, which raises
`psychlvgl:LVGLAssert` from the dispatch layer. No `longjmp` crosses an LVGL
frame. Event callbacks never allocate and never call `mexErrMsgIdAndTxt`.

`LV_USE_LOG 1` with `LV_LOG_PRINTF 0`. `plv_log` prints through `mexPrintf`
when the level passes `log_level`.

### 8.5 Shutdown

`Shutdown` and `plv_at_exit` share one path: `lv_deinit()` (destroys the
display, the NanoVG context, the FBO cache, timers, and indevs),
`lv_opengles_deinit()`, zero the state, `mexUnlock()`. When no GL context is
current, skip the two GL calls and log a warning; PTB frees the objects with
the context.

## 9. Performance and profiling

### 9.1 Dispatch

Same design as the other subcommand MEX files in this workspace: names read
with `mxGetString` into a 64-byte stack buffer, binary search in a generated
sorted table, and a numeric opcode fast path with constants from
`PsychLVGLOp.m`. Budget: under 0.5 us for dispatch plus marshaling of a scalar
setter.

LVGL calls in a retained tree are rare after setup. The per-frame cost is
`Update`, which is dominated by `lv_timer_handler` when something changed and by
the two PTB context switches otherwise.

### 9.2 Built-in Stats

Always compiled unless `PSYCHLVGL_STATS=0`. Fixed arrays, no allocation:

| Field | Content |
|---|---|
| per subcommand `calls`, `totalNs`, `maxNs` | dispatch timing by opcode |
| `updateNs` last, max, sum, count | CPU time of `lv_timer_handler`, which includes NanoVG command submission |
| `gpuNs` last, max | GPU time of `lv_timer_handler` from a `GL_TIMESTAMP` query pair, read two frames later, 0 when `GL_ARB_timer_query` is absent |
| `flushCount` | frames where the flush callback ran |
| `eventsDropped`, `queueHighWater` | event ring |
| `tickAnomaly` | non-monotonic `tNow` count |
| `frameNs` | optional, from `PsychLVGLFrame` through `PsychLVGL('StatsAddFrame', dt)` |

### 9.3 Tracy

CMake option `PSYCHLVGL_TRACY` (default OFF) compiles `TracyClient.cpp` into
the static library so the MEX stays C. `PLV_ZONE(name)` expands to
`TracyCZoneN` when ON and to nothing when OFF. With Tracy ON, `lv_conf.h` sets
`LV_USE_PROFILER 1` and maps `LV_PROFILER_BEGIN` and `LV_PROFILER_END` to the
same macros, so LVGL's refresh and NanoVG draw phases appear as nested zones.
`TracyCGpuZone` wraps `lv_timer_handler`. Export with `tracy-csvexport`.

### 9.4 What to measure first

1. `Update` CPU time for the demo panel when idle and when a slider moves.
2. GPU time for the same two cases.
3. `Screen('BeginOpenGL')` plus `Screen('EndOpenGL')` per frame without LVGL
   calls.
4. `perf/PsychLVGLPerf.m` sweeps panel sizes (200x200 to 1920x1080) and widget
   counts (10 to 500) and prints one table.

## 10. Build

### 10.1 Layout

```
PsychLVGL/
  CMakeLists.txt          builds lvgl static lib with the project lv_conf.h, optional Tracy
  lv_conf.h               project LVGL configuration
  build.m                 MATLAB/Octave build driver
  PsychLVGLSetup.m        identical copy of m/PsychLVGLSetup.m, for a fresh unzip (D63)
  README.md               install and use, for users
  DEV.md                  build, tests, CI, generator, patches, for developers
  RELEASING.md            release checklist
  SPEC.md
  src/
    psychlvgl.c           mexFunction, dispatch, state, lifecycle
    plv_display.c         all lv_opengles_* calls, flush callback, Update render step
    plv_input.c           indevs, key ring, group
    plv_handles.c         slot table
    plv_events.c          event ring and LV_EVENT_ALL callback
    plv_gl_loader.c       gladLoadGL proc loader per platform
    plv_marshal.h         mxArray <-> C helpers used by generated code
    plv_internal.h        state struct, error helpers
    plv_profiler.h        PLV_ZONE macros
    psychlvgl_gen.c       generated, committed
    psychlvgl_enums.c     generated, committed
  gen/
    pyproject.toml generate.py allowlist.toml templates/
  m/
    PsychLVGL.m PsychLVGLInput.m PsychLVGLKeyMap.m PsychLVGLFrame.m PsychLVGLEvents.m PsychLVGLOp.m PsychLVGLDemo.m
  tests/
    run_tests.m test_handles.m test_events.m test_keypad.m test_dispatch.m test_gen_marshal.m test_tick.m
    gl/test_gl_init.m gl/test_gl_render.m gl/test_gl_click.m gl/test_gl_resize.m
  perf/
    PsychLVGLPerf.m
  tests/xml/              phase 3, XML fixtures, LVGL examples
  examples/xml/gabor_panel/  the PsychLVGLXMLDemo panel, shipped in the release zips (D63)
  docs/images/            README screenshot
  tools/                  apply_lvgl_patches.sh, CaptureReadmeScreenshot.m
  third_party/
    lvgl/                 submodule v9.6.0
    pugixml/              v1.16, phase 3, a plain clone until it becomes a submodule
    tracy/                submodule, optional
```

### 10.2 lv_conf.h

Key settings:

| Option | Value | Reason |
|---|---|---|
| `LV_USE_OPENGLES` | 1 | texture driver |
| `LV_USE_DRAW_NANOVG`, `LV_USE_NANOVG`, `LV_USE_MATRIX` | 1 | GPU draw unit and its requirements |
| `LV_NANOVG_BACKEND` | `LV_NANOVG_BACKEND_GL3`, or GL2 on macOS | `lv_conf.h` wraps the line in `#ifndef LV_NANOVG_BACKEND` and repeats the same `__APPLE__` choice as its default, so a unit compiled without the CMake define agrees; CMake passes `-DLV_NANOVG_BACKEND=...` per platform |
| `LV_USE_DRAW_SW` | 0, 1 in the test variant | no software renderer at run time |
| `LV_USE_GLFW`, `LV_USE_EGL`, `LV_USE_SDL` | 0 | PTB owns the context |
| `LV_COLOR_DEPTH` | 32 | |
| `LV_DEF_REFR_PERIOD` | 1 | render on the next `Update` |
| `LV_USE_OBJ_NAME` | 1 | phase 3 name lookup |
| `LV_USE_OBSERVER` | 1 | phase 3 subjects |
| `LV_USE_LOG`, `LV_LOG_PRINTF` | 1, 0 | route to `mexPrintf` |
| `LV_ASSERT_HANDLER` | `plv_assert_hook(__FILE__, __LINE__);` | section 8.4 |
| `LV_FONT_MONTSERRAT_12` to `_48` | 12, 14, 16, 20, 24, 28, 32, 48 on | `FontList` |
| `LV_FONT_DEFAULT` | `&lv_font_montserrat_16` | |
| `LV_USE_PROFILER` | 1 only with Tracy | section 9.3 |
| `LV_USE_STDLIB_MALLOC` | `LV_STDLIB_CLIB` | use the C runtime allocator, no fixed pool |

### 10.3 Flow

`build.m` follows the user's `mex-msgpack` pattern.

1. Detect the engine with `exist('OCTAVE_VERSION', 'builtin')`. Choose
   `build-matlab/` or `build-octave/`.
2. CMake configure the LVGL static library: `set(LV_CONF_PATH
   ${CMAKE_SOURCE_DIR}/lv_conf.h)` before `add_subdirectory(third_party/lvgl)`.
   Force the C compiler to the engine's compiler: `mex.getCompilerConfigurations('C')`
   for MATLAB, `mkoctfile -p CC` for Octave. Generator `-G "Visual Studio 17
   2022"` or `-G "MinGW Makefiles"`, overridable with `MEX_CMAKE_GENERATOR`.
   Options `-DPSYCHLVGL_TRACY=OFF`, `-DPSYCHLVGL_TEST_SW=OFF`.
3. `cmake --build` and install into `inst-<engine>/`. A small
   `plv_toolchain_id.c` compiled into the library exports a string with the
   compiler name. `build.m` checks it against the MEX compiler before linking.
4. `mex` with `-R2017b`, includes `third_party/lvgl/include`,
   `third_party/lvgl/src/drivers/opengles/glad/include` (for the `gladLoadGL`
   prototype), `src/`, define `LV_CONF_PATH`, the static library, and
   `opengl32.lib` or `-lGL` or `-framework OpenGL`. Output
   `dist/PsychLVGL.<mexext>`.
5. `build.m gen` runs the generator. `build.m test` runs `run_tests.m`.
   `build.m test-sw` builds the software variant used by the no-GL tests.

### 10.4 CI

Same shape as `mex-msgpack`: build on the oldest supported release, test the
binary on the newest. CI runs the no-GL tests on the software variant and
compiles the GL variant without running it. GL tests run on developer machines.

Platforms: Linux and Windows for both engines, plus macOS on Apple silicon.
The macOS units are the `macos-latest` entry of `matlab-build` (MATLAB R2023b,
the first native Apple silicon release), the matching `matlab-test-forward`
entry, `octave-macos` (Homebrew Octave), and `smoke-gl-macos`. They started as
`continue-on-error: true`, because no one on the team has a Mac, and the flag
came off on 2026-09-23 after the first run where every one of them was green
(D37, D38). The release job lists them in `needs`, so all of them must pass.

## 11. Testing

### 11.1 Without a GPU

The `test-sw` build variant sets `LV_USE_DRAW_SW 1`, `LV_USE_OPENGLES 0`, and
`LV_USE_DRAW_NANOVG 0`, and replaces `plv_display.c` with
`plv_display_sw.c`, which uses `lv_display_create` and a MEX-owned buffer. Every
other source file is identical. `run_tests.m` runs under both engines:

- `test_handles.m`: create, delete parent, child handle invalid, stale handle
  error id, slot reuse increments generation, `MaxObjects` exhaustion error.
- `test_events.m`: button at a known rectangle, `Update` with press then
  release, `Poll` returns PRESSED, RELEASED, CLICKED with the right handle;
  `AddEvent` and `RemoveEvent`; overflow drops oldest and counts.
- `test_keypad.m`: textarea in the group, inject key rows, `TextareaGetText`
  matches.
- `test_dispatch.m`: unknown name, opcode path, argument errors, `Init` twice.
- `test_gen_marshal.m`: generated; every allowlisted function called once with
  valid arguments, output count and class checked.
- `test_tick.m`: synthetic times, animation progress, non-monotonic time
  counted.
- `FrameChecksum` (test builds only): CRC32 of the software buffer against a
  stored value for a fixed scene and fixed ticks.
- `test_xml_parse.m` (phase 3): the node tree, renamed attributes, text and
  CDATA, entities, empty elements, a file, non-ASCII text, and the error id
  and message of a parse error.
- `test_xml_load.m` (phase 3): `tests/xml/main.xml` through
  `PsychLVGLLoadXML`: names and handles, sizes, a percentage width, styles with
  selectors, chained constants, component props and defaults, a component that
  extends a component, fonts and images; `PsychLVGLXMLToM` on the same file
  and the generated function run, with the same names and sizes;
  `tests/xml/unknown.xml` with one warning per distinct problem; the `Consts`,
  `AssetDir` and `Globals` options; the demo panel; and eight example files
  copied from the LVGL tree.
- `test_xml_subjects.m` (phase 3): `tests/xml/subjects.xml`: initial values,
  events that change subjects, the increment, set and toggle events, flag,
  state and style bindings, real clicks through `Update`, clamping, and a
  deleted widget.
- `test_setup.m`: the root and `m/` copies of `PsychLVGLSetup.m` are
  identical; `remove` with an initialized MEX unlocks it and takes
  `dist/<arch>`, `dist-sw/<arch>` and `m/` off the path; a second `remove`
  leaves the path unchanged; the software build goes back on. It runs last in
  the no-GL group, because it is the one test that changes the path, and it
  does so only after `remove` has unloaded the MEX (D35, D63).

### 11.2 With PTB and a GPU

`tests/gl/` opens a 640x480 PTB window:

- `test_gl_init.m`: `Init` returns a nonzero texture id, `Version` reports the
  NanoVG backend, `Init` without `BeginOpenGL` raises `psychlvgl:NoGLContext`.
- `test_gl_render.m`: a screen with a known background color and one label,
  `Update`, `DrawTexture`, `Flip`, `Screen('GetImage')`, mean color inside the
  panel within a tolerance. NanoVG antialiasing differs across GPUs, so tests
  compare regions, not pixels.
- `test_gl_click.m`: press and release on a button through `Update`, CLICKED in
  `Poll`, visual state change in the read-back image.
- `test_gl_resize.m`: `Init` with a new size returns a new texture id, old
  handles invalid, re-wrapped PTB texture draws.
- `test_gl_xml.m` (phase 3): `tests/xml/main.xml` in the window: the color of
  a style from `globals.xml`, the background of the screen's view, a TTF
  title, and a style with a `pressed` selector, all in the read-back image.

### 11.3 Native smoke test

`tests/native/smoke_gl.c` is the only GL coverage without Psychtoolbox. It
makes the platform's own legacy context, WGL behind a hidden window on Windows,
GLX behind a mapped window on X11, and on macOS a CGL context with no drawable
and no `kCGLPFAOpenGLProfile` attribute, which is GL 2.1. The macOS branch asks
for `kCGLPFAAccelerated` first and falls back to `kCGLPFARendererID` with
`kCGLRendererGenericFloatID`, the Apple software renderer, because a CI runner
is a virtual machine. It then runs the same sequence as the other platforms and
reads the panel texture back through a framebuffer object. Before the GL part
it parses a short XML document through `plv_xml.h`, the C interface of the
parser, so the C++ part of the core library runs wherever the smoke test runs.

### 11.4 Interactive

`PsychLVGLDemo.m`: a Gabor patch whose contrast follows a slider, a dropdown
that selects the spatial frequency, a text area for a subject id, and a status
label. `PsychLVGLXMLDemo.m` (phase 3) shows the same stimulus with its panel
loaded from XML. `perf/PsychLVGLPerf.m` prints the table described in section 9.4.

## 12. Risks, alternatives considered, open questions

### 12.1 Risks

| Risk | Mitigation |
|---|---|
| LVGL marks the OpenGL driver API as experimental | Pin v9.6.0. Isolate driver calls in `plv_display.c`. |
| NanoVG shader compile fails on a PTB context | `GLInit` error includes the LVGL log with the GLSL negotiation. GL2 backend as a build option. |
| `gladLoadGL` lives in LVGL's driver tree, not the public API | Declare the prototype locally and check the symbol at link time. |
| Mixed toolchains (MSVC library, MinGW MEX) | `plv_toolchain_id` check in `build.m`. |
| LVGL global state and `clear mex` | `mexLock` while initialized. `Shutdown` unlocks. |
| Two PTB context switches per frame | Measure. Expected 50 to 200 us. |
| Antialiasing differs across GPUs | Region-based image tests with tolerances. |
| `gen_json.py` needs doxygen and MSVC headers on Windows | Developer step only. Generated files are committed. |
| Octave Unicode handling | Key path is numeric. Text setters convert to UTF-8 in C. |
| `lv_deinit` leaves GL objects when no context is current | Skip GL calls and warn. PTB frees them with the context. |

### 12.2 Alternatives considered

- Software renderer with `Screen('SetOpenGLTextureFromMemPointer')`. The MEX
  would render on the CPU into a buffer and pass its address to PTB as a
  double. Rejected: CPU rasterization, and a full-buffer upload on every dirty
  frame, 8 MB at 1920x1080. The user requires GPU rendering.
- `LV_USE_DRAW_OPENGLES` draw unit. Rejected: it rasterizes widgets on the CPU
  and caches them as textures. LVGL documents it as slower than software
  rendering for content that changes every frame.
- A minimal own GL path: software render, then `glTexSubImage2D` of dirty
  rectangles inside `BeginOpenGL`. Rejected: still CPU rasterization.
- Dear ImGui's `ImDrawList` as a custom `lv_draw_unit_t`. The MEX would translate
  LVGL draw tasks into ImGui primitives and render with the ImGui OpenGL
  backend. Rejected: it would duplicate NanoVG with less coverage. `ImDrawList`
  has no stencil-based concave fills, no radial gradients, no blur for box
  shadows, no offscreen layers, and rectangular clipping only, so shadows,
  layers, and rounded masks would need a software fallback. Text would need a
  glyph atlas built from `lv_font` bitmaps. LVGL's draw unit API is
  semi-private and changes between minor versions. The one benefit, GL state
  save and restore, does not matter because PTB isolates the userspace context.
- LVGL's XML engine at run time. Rejected: LVGL 9.5.0 removed the open-source
  engine, and pinning 9.4.0 would freeze the binding on an old release.
  Vendoring the removed engine (72 files against 9.4 internals) was rejected
  for the same maintenance reason. Phase 3 parses the editor's XML with pugixml
  and interprets it in MATLAB instead (section 13, D50).
- LVGL Pro C export compiled into the MEX as a plugin (the version 0.1 phase 3).
  Rejected 2026-09-23: Psychtoolbox users install a binary MEX and most have
  no compiler, so a layout change that needs a rebuild is unusable for them,
  and the export includes `lvgl_private.h`, which breaks on minor LVGL
  upgrades. See D50.
- Handles as raw pointer bits in a double. Rejected: no use-after-delete
  detection. The slot table costs 16 bytes per object.
- `Poll` returning a struct array. Rejected as the primary form: one
  `mxCreateStructMatrix` plus per-field scalars is slower than one matrix.
  `PsychLVGLEvents('decode')` provides the struct form when readability
  matters.

### 12.3 Open questions

| Question | Default assumed by this specification |
|---|---|
| Panel size defaults to a fixed size given by the script, not the window size? | Yes. A full-window panel is allowed but not the default. |
| Chart widget in phase 1? | No, phase 2. It needs an int32 array rule and series handles. |
| Wheel default: encoder or keys? | Encoder. |
| Slot table fixed at 4096? | Yes, adjustable with `MaxObjects` at `Init`. |
| Tracy as a submodule now? | Yes, optional, not compiled by default. |
| `Poll` matrix only, or also a MATLAB callback dispatcher? | Matrix plus `decode` and `filter`. No dispatcher. |
| macOS support? | Apple silicon only, built and tested by three CI jobs of its own with the GL2 backend. Not CI-blocking until the first green run. The GPU path is expected to fail in `lv_opengles_init`; see section 4.2 and D37. |
| Intel Macs? | No. `maci64` is neither built nor tested. |

## 13. Phasing

| Phase | Content |
|---|---|
| 1 | Lifecycle, GL loader, NanoVG display, indevs, handles, events, generator, allowlist of section 5.3, `Stats`, software test variant, GL tests, demo. |
| 2 | Chart (int32 array marshaling, series handles), `lv_style_t` handles (`StyleCreate`, `StyleSetProp`, `ObjAddStyle`), images from PTB textures by wrapping a PTB texture's GL id with `lv_opengles_texture_create_from_texture_id` or an `lv_image_dsc_t` handle, TTF fonts through `LV_USE_TINY_TTF`, Tracy GPU zones. |
| 3 | XML user interfaces loaded at run time, interpreted in MATLAB. The LVGL editor (LVGL Pro, online or desktop, Community license) saves each screen and component as XML. The MEX gains one parser subcommand, `ParseXML(path or text)`, built on pugixml compiled into the core static library so the MEX stays C, which returns the document as a plain node tree: a struct array with `tag`, `attributes` (struct) and `children`. Everything LVGL-specific lives in M-files. `PsychLVGLLoadXML(file, parent)` walks the tree and issues the existing procedural calls, returns the root handle and a struct of named handles, and resolves fonts and images relative to the XML file with an override hook. `PsychLVGLXMLToM(file, out)` writes the same calls as a script, so a layout can be read and edited without the editor. Phase 3 covers this subset of the LVGL XML format: widgets in the allowlist with their attributes, all `style_*` attributes with selectors through the generated setters, percent sizes and alignment, `<consts>`, `<styles>` through the phase 2 style handles, `<component>` with `<api>` props and `<view>`, TTF fonts and images through the phase 2 handles, and subjects with `bind_*` attributes mapped onto the event ring. An unknown tag or attribute produces one warning naming it, never a silent skip. The format is LVGL's and moves with LVGL releases; the interpreter tracks the docs in `third_party/lvgl/docs` and the editor output, and Pro-only widgets stay unmapped. |

## 14. Deviations from version 0.1

Phases 1 to 3 are implemented. Everything below differs from sections 1 to
13 above. Section 13 stays the plan of record. Sections 5 and 7 list the phase
2 and phase 3 subcommands and rules; everything else about phase 2 is in
section 14.4 and about phase 3 in section 14.5.

### 14.1 LVGL 9.6.0 facts that changed the design

| # | Deviation | Reason |
|---|---|---|
| D1 | Section 4.2 says the NanoVG draw unit renders into the display texture. It does not. `lv_opengles_texture_attach_to_display` skips the assignment when `LV_USE_DRAW_NANOVG` is on, so the root layer keeps `user_data == NULL` and the draw unit calls `nvgluBindFramebuffer(NULL)`, which binds the framebuffer that was current the first time that function ran (`src/libs/nanovg/nanovg_gl_utils.h`, static `defaultFBO`). `src/core/plv_display.c` therefore creates the texture itself, wraps it in its own framebuffer object with a stencil attachment, and binds that framebuffer before every `lv_timer_handler`. | Without it `Init` cannot return a texture id and LVGL draws into the caller's framebuffer. |
| D2 | Section 8.2 orders `lv_opengles_init()` before `lv_opengles_texture_create`. The order is reversed. `lv_draw_layer_init` sends `LV_EVENT_CHILD_CREATED` to every draw unit that already exists when the display's root layer is created, and the NanoVG unit answers by handing that layer a framebuffer from its own cache, which nothing ever copies out. The display has to exist before the draw unit does. `lv_opengles_texture_create_from_texture_id` calls `lv_opengles_init` itself at the end, so the explicit call after it only reports success. | Otherwise the panel texture stays empty. |
| D3 | `Shutdown` does not call `lv_deinit` in the GPU build. `lv_draw_nanovg_init` guards itself with a `static bool initialized` that `lv_deinit` never clears, so a second `lv_init` would leave the build with no draw unit at all. The GPU build starts LVGL once and keeps the display, the texture, the framebuffer object and the draw unit; `Shutdown` clears the widget tree, deletes the indevs and the group, and frees the handle table and the event ring. The software build keeps the `lv_deinit` path, where every `lv_init` registers the software draw unit again. | Upstream limitation. |
| D4 | The LVGL tick continues across `Shutdown` instead of restarting at zero. LVGL timers keep the tick of their last run, so a tick that restarted would leave the refresh timer waiting for a time that never arrives and nothing would ever redraw again. | Found by the native smoke test; see `s_tick_offset` in `plv_core.c`. |
| D5 | Rule R5 holds, but through `lv_display_set_resolution` on the surviving display plus a new texture, not through a new display. The display also gets a real draw buffer sized to the panel, because LVGL's texture driver passes a one word placeholder there and the resolution change overruns it. | Follows from D3. |
| D6 | Only one OpenGL context per process is supported. The framebuffer name NanoVG caches belongs to the context that created it. `plv_display.c` notices a context change, drops its names, and tries to reclaim the same framebuffer name in the new context, which a compatibility profile allows; if that fails it warns that the panel may stay blank. | Upstream `defaultFBO` is a process static with no reset. |
| D7 | `lv_conf.h` sets `LV_COLOR_FORMAT_DEFAULT LV_COLOR_FORMAT_ARGB8888` rather than `LV_COLOR_DEPTH 32`. | LVGL 9.6 replaced the option. |
| D8 | `src/compat/GL/glew.h` is a shim that points at LVGL's vendored glad, because `src/draw/nanovg/lv_draw_nanovg.c` includes `<GL/glew.h>` when it is not built for EGL although the rest of the driver uses glad. | Avoids a second GL loader in the build. |
| D9 | `lv_slider_set_left_value` from section 5.3 does not exist in 9.6. The allowlist uses `lv_slider_set_start_value` and adds `lv_slider_get_left_value`, `lv_slider_set_orientation` and `lv_slider_get_mode`. | Renamed upstream. |
| D10 | CMake reads `LV_BUILD_CONF_PATH`, not `LV_CONF_PATH` as section 10.3 says, and LVGL declares its options with `option()` and `set(CACHE)`, both of which drop a plain variable of the same name, so `CMakeLists.txt` forces every one into the cache. | LVGL 9.6 build system. |

### 14.2 Binding design

| # | Deviation | Reason |
|---|---|---|
| D11 | The per object event mask is 128 bits, not the 32 of section 7.4, and a slot record is 24 bytes rather than 16. LVGL 9.6 defines about 90 event codes, so `VALUE_CHANGED`, `READY`, `CANCEL` and `DELETE` all sit above bit 31. | The specified mask cannot hold the default subscription set. |
| D12 | The LVGL facing code lives in `src/core/` as a plain C library that links without MATLAB, and `src/` holds only the mx marshaling layer. Section 10.1 puts both in `src/`. | Lets `tests/native/smoke_gl.c` drive the real GL path with no engine. |
| D13 | `gen/generate.py` preprocesses `include/lvgl/lvgl.h` itself and parses it with pycparser instead of running `scripts/gen_json/gen_json.py` as section 7.1 says. `gen_json.py` needs pyMSVC, which could not find the installed Visual C here, and it downloads SDL2 on Windows. | The specified tool did not run on this machine. |
| D14 | The generator emits the enum table as `{ "LV_EVENT_CLICKED", (double)(LV_EVENT_CLICKED) }` and lets the C compiler evaluate the constants. | No expression evaluator in the generator, and the table cannot drift from the headers. |
| D15 | 236 subcommands are generated, not the "about 120" of section 5.3, because the style setter rule alone contributes about 120. Eleven allowlisted functions are dropped and `gen/dropped.txt` lists them; all eleven take a pointer to a struct, a `void *`, an `int32_t` array or an `lv_style_t`, which section 7.3 puts outside phase 1. | As specified. |
| D16 | `lv_dropdown_get_selected_str` and `lv_roller_get_selected_str` are supported: a writable `char *` followed by a size argument becomes an extra char output. Section 7.3 does not name that pattern. | Both are in the section 5.3 allowlist. |
| D17 | `PsychLVGL('Name?')` is not implemented. `PsychLVGL` with no arguments prints the subcommand list and `help PsychLVGL` prints the generated signatures. | Not reached in phase 1. |
| D18 | `Stats` reports the per subcommand numbers as `opNames`, `opCalls`, `opTotalNs` and `opMaxNs`, listing only the opcodes that were called. | Section 9.2 does not fix the field names; this keeps `Stats` free of per call allocation. |
| D19 | `stats.gpuNs` is always 0. The `GL_TIMESTAMP` query pair of section 9.2 is not implemented. | Phase 2 work. `updateNs` covers the CPU side. |
| D20 | Tracy is an unwired CMake option. `PSYCHLVGL_TRACY=ON` compiles `TracyClient.cpp` into the core library and `PLV_ZONE_BEGIN` and `PLV_ZONE_END` expand to `TracyCZoneN`, but `third_party/tracy` is not cloned and the option has never been built here. `LV_USE_PROFILER` follows `PSYCHLVGL_TRACY` in `lv_conf.h`, but the LVGL profiler macros are not mapped to Tracy yet. | Optional, and not needed for phase 1. |

### 14.3 Build, layout and tests

| # | Deviation | Reason |
|---|---|---|
| D21 | The MEX goes to `dist/<arch>/PsychLVGL.<mexext>` and the test variant to `dist-sw/<arch>/`. Octave names its MEX `PsychLVGL.mex` on every operating system, so a Linux build would otherwise overwrite a Windows one. `m/PsychLVGLSetup.m` puts the right pair on the path and raises `psychlvgl:NotBuilt` with the expected path and the build command when it is missing. Outside Windows the build and install directories carry the architecture too. Octave's `computer('arch')` answers with a GNU triplet, so the architecture name is derived from `ispc`, `ismac` and `computer` there. | Requested after the specification was written. |
| D22 | Both variants are called `PsychLVGL`, so only one can be on the path at a time. `run_tests sw` runs the no-GL suite and `run_tests gl` runs the GL suite, each in its own engine session. Section 11 assumes one `run_tests`. | Two MEX files cannot share one function name. |
| D23 | `FrameChecksum` compares two runs of one fixed scene and checks that a change to the scene changes the checksum, instead of comparing against a stored value as section 11.1 says. | A stored CRC32 would have to be regenerated for every compiler and font rounding difference between MSVC and MinGW. |
| D24 | `test_gl_click` checks `LV_STATE_PRESSED` on the widget rather than a visual state change in the read back image. On this machine `Screen('GetImage')` of a sub-region of a windowed window returned identical pixels for two different frames, whichever buffer was named. `test_gl_render` carries the pixel checks, including a white band that proves the panel is not flipped vertically. | Read back behavior of a windowed Psychtoolbox window under the Windows desktop compositor. |
| D25 | Section 11.2 gains one rule: every script that opens a Psychtoolbox window goes through `tests/gl/ptb_test_window.m`, which sets `Screen('Preference', 'SkipSyncTests', 2)` and `Screen('Preference', 'VisualDebugLevel', 0)` before opening it and caches the window so the whole GL suite runs on one OpenGL context. `PsychLVGLDemo` and `perf/PsychLVGLPerf.m` open their window through the same helper. | Repeated test runs must not run the full display sync calibration, and D6 allows only one context. |
| D26 | `PsychLVGLFrame` draws with no source rectangle. A framebuffer rendered texture already matches the row order Psychtoolbox expects, which `test_gl_render` asserts. | Measured, not assumed. |
| D27 | `tests/native/smoke_gl.c` and the CMake option `PSYCHLVGL_SMOKE_GL` are new. The program creates a hidden window and a legacy context, runs the core layer through several Update cycles with synthetic input, reads the texture back through a framebuffer object, and repeats the whole cycle at three panel sizes. | The only GL coverage that needs no Psychtoolbox. It found D1 to D5. |
| D28 | The project is its own git repository, rooted at this folder, so section 10.4 gains `.github/workflows/ci.yml` here rather than in a parent tree. Every job builds the software variant, runs the no-GL suite and builds the GPU variant compile only; `smoke-gl-linux` runs `smoke_gl` under Xvfb and Mesa llvmpipe, the only automated GL execution. | No hosted runner has a GPU or Psychtoolbox. |
| D29 | `build.m` gains `build compile-only`, which CI uses for the GPU variant, and `build test-gl`. On Windows with Octave it selects the `MSYS Makefiles` generator with the `make.exe` the Octave distribution ships, because `MinGW Makefiles` refuses to run while `sh.exe` is on PATH and Ninja is not installed. `MEX_CMAKE_GENERATOR` still overrides it. | The machine has no Ninja. |
| D30 | The MEX is compiled with `LV_CONF_INCLUDE_SIMPLE` and `-I<project>` instead of `LV_CONF_PATH`, because `mex` does not pass the quotes a path macro needs through to the compiler. The static library still uses `LV_BUILD_CONF_PATH`, and both read the same file. | `mex` argument handling. |
| D31 | `third_party/lvgl` is a submodule pinned at v9.6.0, and `third_party/PINS.md` records the commit. It was a plain clone while phase 1 was written and was registered as a submodule at the same commit on 2026-09-22. The CI workflow keeps a "Fetch LVGL" step that clones that commit when a checkout was made without submodules. | The repository did not exist while phase 1 was written. |
| D32 | Doxygen 1.18.0 was installed with scoop while trying to run `gen_json.py`. The generator that shipped does not need it. | Recorded for reproducibility. |
| D33 | Section 4.3 and section 5.5 gain a four call helper layer: `PsychLVGLOpen`, `PsychLVGLFrame`, `PsychLVGLGL` and `PsychLVGLClose`. Version 0.1 had `PsychLVGLFrame('Open'|'Update'|'Close', ...)`, one function with a string subcommand; that form is gone and its three callers were migrated. `PsychLVGLFrame` is now `[ui, E] = PsychLVGLFrame(ui)`. `PsychLVGLOpen` also reports the missing `InitializeMatlabOpenGL` case as `psychlvgl:No3DGraphics` rather than letting `Screen('BeginOpenGL')` fail with a message that does not name the cause, and it passes a texture depth of 32 to `Screen('SetOpenGLTexture')`, because without it Psychtoolbox reads the format back from a texture that belongs to the userspace context and fails. `tests/test_helpers.m` covers the wrapping with a Psychtoolbox stub in `tests/stub`, so the no-GL suite checks it with no window and no GPU. | A script should never write a `Screen('BeginOpenGL')` pair, and one function per verb reads better than one function with a verb argument. The same shape is used in the sibling projects. |
| D34 | `Shutdown` frees the panel texture in the GPU build, although the display itself survives (D3). A script that wrapped the texture with `Screen('SetOpenGLTexture')` closes the Psychtoolbox texture next, and Psychtoolbox deletes the OpenGL name with it, so keeping the name would leave the next session rendering into a texture that no longer exists. Rule R5 still holds, but the new texture id is allowed to be the integer the driver just freed, so a script re-wraps the id it is given rather than comparing it with the old one. | Found by running the GL suite through the new helpers. |
| D35 | No test changes the load path, and nothing in the project calls `rehash`. `tests/run_tests.m` puts `tests/stub` on the path once, before the first call into the MEX, and takes it off once after the last test, and only where a real Psychtoolbox `Screen` exists. `tests/test_helpers.m` has no `addpath`, `rmpath`, `rehash` or `onCleanup`. `m/PsychLVGLSetup.m` is idempotent, so a caller that runs it every frame does not rewrite the path. | A load path change while the MEX is loaded can make Octave 10 decide the MEX file is out of date. Its `out_of_date_check` then calls `bp_table::remove_all_breakpoints_from_function`, which looks the function up again, which runs `out_of_date_check` again. `gdb` in the `gnuoctave/octave:10.1.0` image shows more than 35000 frames of that cycle ending in SIGSEGV, right after `warning: library .../PsychLVGL.mex not reloaded due to existing references`. Octave 6.4 has no such cycle, and MATLAB is unaffected. The same crash hit all three sibling projects at the same point in their test suites, so the suspect mechanism was removed everywhere rather than worked around. |
| D36 | `m/PsychLVGLDemo.m` calls `PsychDefaultSetup(2)` before it opens the window, and creates the Gabor with `CreateProceduralGabor(win, 300, 300, 0, [0.5 0.5 0.5 0], 1, 0.5)` and a unit `modulateColor`. It also measures the first frame and fails with `psychlvgl:GaborFlat` when the pixel standard deviation of the patch is below 0.02. `tests/gl/test_gl_demo_gabor.m`, with the helpers `gabor_std.m` and `gabor_michelson.m`, pins the same settings in the GL suite. | The demo drew a flat gray square. With the default `disableNorm = 0` the shader multiplies the contrast by `1/(sqrt(2*pi)*sc)`, about 1/100 at `sc = 40`, so a slider contrast of 0.6 reached an amplitude near 0.006; the window was also not in the normalized colour range the 0.5 offset assumes, and the Michelson relation only holds with a unit modulation colour. Measured after the fix: pixel standard deviation 0.0501 and central Michelson contrast 0.570 for a nominal 0.6, against 0.0021 before. |
| D37 | macOS on Apple silicon is a build target. `lv_conf.h` defaults `LV_NANOVG_BACKEND` to `LV_NANOVG_BACKEND_GL2` under `__APPLE__`, CMake passes the same value, `build.m` picks the `Unix Makefiles` generator and links `-framework OpenGL`: under MATLAB as the `mex` argument `LDFLAGS=$LDFLAGS -framework OpenGL`, and under Octave through the `LDFLAGS` environment variable, set to `mkoctfile -p LDFLAGS` plus the framework and restored afterwards. `mkoctfile` answers "unrecognized argument" to `LDFLAGS=...` on the command line and its environment variable replaces its own value rather than adding to it; both were measured with `mkoctfile -v` on Octave 10.1, `tests/native/smoke_gl.c` grew a CGL branch, and `ci.yml` grew three macOS units. The GPU path itself is unverified and is expected to raise `psychlvgl:GLInit`: `lv_opengles_init` binds a core vertex array object and compiles its blit shader as `#version 300 es`, `330` or `100`, none of which a Psychtoolbox GL 2.1 compatibility context accepts. The software variant and the no-GL suite have no such dependency. | Version 0.1 called macOS best effort with no jobs. Nobody on the team has a Mac, so `macos-latest` is the only test bed, and every macOS unit is `continue-on-error: true` until one run is green. Everything here except the CI result was checked by inspection and by compiling the new CGL branch against stub CGL headers. The first CI run (2026-09-22) settled it: the MATLAB R2023b and Homebrew Octave jobs built the maca64 MEX and passed the 355-test suite, so both are blocking now; the smoke test got a context (`GL_VERSION 2.1 APPLE-23.1.1`, `GL_RENDERER Apple Software Renderer`, GLSL 1.20; the runner offers no accelerated CGL pixel format) and then died with a segmentation fault inside `lv_opengles_init`, because glad leaves `glGenVertexArrays` null on a 2.1 context and LVGL calls it unchecked. `plv_display_create` now checks the version and the entry points before any `lv_opengles_*` call and returns `psychlvgl:GLInit` with that explanation, so the smoke test fails cleanly; it stays advisory until the GPU path question for macOS is decided. Round 2 confirmed the clean failure on the runner: `plv_init failed: psychlvgl:GLInit LVGL's OpenGL driver needs OpenGL 3.0 or later; this context is 2.1 APPLE-23.1.1`, exit code 1, no crash. D38 then replaced that failure with a working GPU path, and the `continue-on-error` flags came off all four macOS units on 2026-09-23. |
| D38 | `patches/lvgl/0001-opengles-driver-gl21-glsl120.patch` is applied to the LVGL checkout at configure time (`CMakeLists.txt`, before `add_subdirectory`; `tools/apply_lvgl_patches.sh` does the same from a shell and runs as a host step in CI before the Octave containers), so the GL2 build runs on a legacy OpenGL 2.1 context. The patch adds `LV_OPENGL_GLSL_VERSION_120`, which the manager tries after `300 es`, `330` and `100`; its shaders are the GLSL ES 1.00 sources with the `precision` statement skipped, because desktop 1.20 rejects `precision` and the qualifiers as reserved words but has `attribute`, `varying`, `texture2D` and `gl_FragColor`. It also maps `LV_COLOR_FORMAT_L8` onto `GL_LUMINANCE` below GL 3.0, because `GL_R8` is a 3.0 internal format. `plv_display_create` accepts 2.1 for the GL2 build and keeps the entry point check. The idempotence marker is the enum name in `lv_opengl_shader_internal.h`. `plv_gl_load` aliases `glBindVertexArray` and `glIsVertexArray` to their `APPLE` forms after `gladLoadGL`, because glad's alias table covers Gen and Delete but not Bind. | Section 4.2 recorded the 3.0 floor and D37 the clean `psychlvgl:GLInit` failure it causes on macOS. The user chose to vendor a patch rather than leave the GPU path unsupported there or fall back to software rendering. The patch is 56 lines in four files and is a candidate for an upstream pull request; until then the submodule pointer stays at v9.6.0 and the working tree carries the patch, which `git status` shows as modified submodule content. Verified on Windows on 2026-09-22: a fresh configure applies the patch to the pristine submodule, a second configure sees the marker, MSVC compiles the patched sources, and `smoke_gl` passes on GL 4.6, where the `330` path still wins. The first macOS run (2026-09-23) applied the patch, passed the GLSL floor, and stopped in the entry point check on `glBindVertexArray`, which is how the missing alias was found; the loader fix followed. The second run passed: the runner's `2.1 APPLE-23.1.1` context (Apple Software Renderer, GLSL 1.20) rejected `300 es`, `330` and `100` with "version is not supported" and compiled the `120` shaders, `plv_init` succeeded, `glGetError` stayed clean through `Update`, the slider followed the pointer, events were queued, and the texture held rendered, non-flat pixels. The macOS GPU path is covered by CI from here on, on a software renderer; no accelerated Mac has run it. |

### 14.4 Phase 2

| # | Deviation | Reason |
|---|---|---|
| D39 | Section 13 names `lv_chart_set_range`; LVGL 9.6 calls it `lv_chart_set_axis_range` and adds `lv_chart_set_axis_min_value` and `lv_chart_set_axis_max_value`, which the allowlist binds instead. `lv_chart_set_series_ext_y_array` and `lv_chart_set_series_ext_x_array` are not bound, and the generator now refuses any writable array parameter, because LVGL keeps the caller's array and a MATLAB argument does not outlive the call. The hand-written `ChartSetValues` copies a vector into the array the series owns, point 1 first, sets the x start point to 0 and refreshes; NaN and the points past the end of the vector become `LV_CHART_POINT_NONE` gaps, and more values than points raise `psychlvgl:Range`. `ChartGetValues` returns the points in screen order, which is the stored order rotated by the x start point in shift mode and the stored order in circular mode. The generated `ChartSetSeriesValues` keeps LVGL's meaning, one `lv_chart_set_next_value` per element. `Poll` reports the pressed point index as the VALUE_CHANGED parameter of a chart. Measured on the software variant under MATLAB R2023a: `ChartSetNextValue` 0.22 us per call through the opcode path, `ChartSetValues` with 500 points 1.3 us. | LVGL 9.6 names; the aliasing rule of the phase 2 brief; the SPEC 9.1 budget of 0.5 us holds for the per-frame setter. |
| D40 | Series, cursors, styles, images and fonts share one resource table of 4096 entries, separate from the object table, instead of one table per kind (section 7.4). The size is fixed at compile time (`PLV_MAX_RESOURCES`), not an `Init` option. A resource handle carries its kind above bit 32, so `IsValid` answers for both tables and a font argument tells a handle from a name by its class. A series or cursor handle from another chart is refused before LVGL sees it. `ChartRemoveSeries` and `ChartRemoveCursor` release their handle after the call; the generator does this through a two-entry list, `RELEASES`. The thirteen new hand-written subcommands follow `FrameChecksum` in the dispatch table, so every generated opcode moved; scripts that read `PsychLVGLOp` at run time are not affected. | LVGL frees a series with its chart and a wrong-chart series would be unlinked from the wrong list. One table keeps the delete hook to one scan, which runs only while a chart owns something. |
| D41 | Images from Psychtoolbox textures need a second vendored patch, `patches/lvgl/0002-nanovg-image-from-gl-texture.patch` (110 lines in 5 files). It adds the image flag `LV_IMAGE_FLAGS_GL_TEXTURE`: an `lv_image_dsc_t` with that flag carries a `uint32_t` OpenGL texture name instead of pixels, and the NanoVG image cache wraps the name with `nvglCreateImageFromHandle` and `NVG_IMAGE_NODELETE` on every draw, releasing only the NanoVG record at the end of the frame. A texture stored bottom row first also gets `NVG_IMAGE_FLIPY`. The second flag, `LV_IMAGE_FLAGS_GL_TEXTURE_TRANSPOSED`, marks a texture that holds the image with rows and columns swapped, which is how Psychtoolbox stores a texture made from a MATLAB matrix: texel row c is matrix column c. For it `lv_draw_nanovg_image` swaps the axes of the image paint, `xform` becoming `[0 1 1 0 x y]` and the extent `(h, w)`, so texture u runs down the image and v across it, with no flip. The swap lives in the paint, so rotation, scale, recolor, opacity and clip radius work as for any image. Tiling does not: NanoVG sets the wrap mode only on textures it creates, so a texture image never repeats in either storage order, and the GLES2 tile fallback, which neither desktop backend uses, does not swap. The wrapper also makes the texture complete: when its minification filter asks for mipmaps, as the OpenGL default does and as Psychtoolbox leaves it on a texture made from a matrix, it sets `GL_LINEAR`, binding through NanoVG's own `glnvg__bindTexture` so NanoVG's binding cache stays right. Psychtoolbox sets its own filter on every `Screen('DrawTexture')`, so the change does not show there. Without it the transposed test texture sampled as black on the Intel driver. The descriptor is therefore an ordinary image source for `lv_image_set_src`, with rotation, scale, recolor and clip radius. Without a patch LVGL 9.6 offers no image source backed by a texture: every image goes through an image decoder that yields CPU pixels, which the NanoVG unit uploads with `nvgCreateImage`. The only upstream way to draw an existing texture is the `3dtexture` widget with `LV_USE_3DTEXTURE`. It was rejected: it is a widget, not an image source; `lv_draw_nanovg_3d` ends the NanoVG frame for every texture; and it draws through `lv_opengles_render` with `rb_swap` fixed to true, which swaps red and blue of a Psychtoolbox RGBA texture, measured by reading the source. `lv_opengles_texture_create_from_texture_id`, which section 13 names, creates a display, not an image. The texture must be `GL_TEXTURE_2D`, which Psychtoolbox makes with `specialFlags` 1; its default is a rectangle texture, which `m/PsychLVGLImageFromTexture.m` refuses with the new `psychlvgl:Texture`. Both storage orders are accepted. The helper tells them apart as `Screen('GetOpenGLTexture', win, tex, 0, 0)` answers: the top left pixel maps to v near 1 for an upright texture (`textureOrientation` 1 or 2, bottom row first) and near 0 for the transposed default. Measured on Psychtoolbox 3.0.22 for a 20x30 matrix: (u, v) = (-0.017, 0.975) upright and (-0.025, -0.017) transposed; the `SCREENGetOpenGLTexture.c` and `PsychMapTexCoord` sources agree. The image takes its size from `Screen('Rect', tex)`, the matrix columns by rows, which is the size Psychtoolbox shows and not the texel size of a transposed texture. PsychImGui's `PsychImGuiImage.m` uses the same test; no code is shared. Images are at most 16383 pixels on a side, because the image header stores the row stride in 16 bits. The software variant has no OpenGL, so there `ImageFromTexture` returns a transparent image of the given size with the same handle rules. The generator reads the patched headers, so `src/psychlvgl_enums.c` lists `LV_IMAGE_FLAGS_GL_TEXTURE`. `ImageFromArray` is added as well: a uint8 HxW, HxWx3 or HxWx4 array becomes an ARGB8888 copy the MEX owns. With `LV_CACHE_DEF_SIZE 0` the NanoVG unit uploads such an image again every time it draws it, so a large or often redrawn image belongs in a texture. | The phase 2 brief allows a small second patch when a texture-backed image source needs one. It keeps the lv_image features and the colour order of the texture, and needs no pixel to cross the CPU. Accepting both storage orders means a texture looks the same in `Screen('DrawTexture')` and in the panel whichever way it was made; the user asked for the transposed default to be corrected rather than refused. |
| D42 | Section 13 names one `StyleSetProp`; it takes the property as a string. The generator emits a sorted table of 127 setters, one per `lv_style_set_<prop>` whose value type matches a kept `lv_obj_set_style_<prop>`, so the property set and the value rules are those of the `ObjSetStyle<Prop>` subcommands. The names match without underscores and case, and with or without `LV_STYLE_`. `StyleSetProp` calls `lv_obj_report_style_change`, which LVGL needs when a style in use changes. `StyleDelete` refuses with the new `psychlvgl:InUse` while any registered object still has the style. It does not detach the style from those objects, because that would change the look of the panel as a side effect. The check scans the style lists of the registered objects instead of keeping a count: LVGL replaces an entry with the same selector in `lv_obj_add_style`, takes wildcards in `lv_obj_remove_style`, and drops every entry when an object is deleted, and a count kept beside that would drift. `ObjRemoveStyle` without a selector removes every entry of the style. | A deleted style that an object still lists is a use after free at the next redraw. Refusing is explicit, and a Delete is rare enough that the scan costs nothing per frame. |
| D43 | `FontLoad` reads the whole TTF or OTF file into memory the MEX owns and calls `lv_tiny_ttf_create_data_ex`, so no LVGL file system driver is configured. `lv_conf.h` still sets `LV_TINY_TTF_FILE_SUPPORT 1`: only then does tiny_ttf read the in-memory font through a stream that knows its size; with 0 it follows the table offsets of the file with no bound. `FontLoad` also refuses a file that does not start with a TrueType, OpenType or collection tag, a file above 64 MB, and sizes outside 1 to 1000 px. Every font argument accepts a `FontLoad` handle or a built-in name; the `FontDefault` option of `Init` stays a name, because no font can be loaded before `Init`. `FontDelete` raises `psychlvgl:InUse` while any style handle, or any local style of a registered object, names the font, even a style that no object uses yet. On Windows the path goes through `_wfopen`, so a path outside the ANSI code page opens. | tiny_ttf keeps a pointer to the font bytes for the life of the font. The bounded stream is the difference between an error and a crash on a damaged file. |
| D44 | D19 and the GPU half of D20 no longer hold. `stats.gpuNs` is measured: a `GL_TIMESTAMP` query pair around `lv_timer_handler` goes into a ring of four pairs, and each pair is read once the GPU reports it available, normally two or three frames later, so the read never stalls a frame. A pair still in flight when its slot comes round again is read with a wait, so every opened Tracy zone is closed. The queries need OpenGL 3.3 or `GL_ARB_timer_query`; on the macOS 2.1 context `gpuNs` stays 0. With `PSYCHLVGL_TRACY=ON` the same pairs feed a Tracy GPU zone, "lv_timer_handler (GPU)", through `___tracy_emit_gpu_zone_begin_serial` and friends; section 9.3 names `TracyCGpuZone`, which the Tracy 0.11 C API does not have. Tracy's C API has no call that hands out a GPU context id, so `src/core/plv_tracy.cpp`, compiled only with Tracy, takes one from Tracy's shared counter. The new cache variable `PSYCHLVGL_TRACY_DIR` points CMake at a Tracy checkout outside `third_party/tracy`; without one the configure step fails with the clone command. Verified on Windows with Tracy v0.11.1 and MSVC: `smoke_gl` builds and passes with Tracy on. No Tracy viewer was connected. `build.m` still configures with `PSYCHLVGL_TRACY=OFF`, and the LVGL profiler macros are still not mapped to Tracy, so that half of D20 stands. | The GPU half of section 9.2 and 9.3 was the open phase 2 item. |
| D45 | `Shutdown` now loads a fresh screen and deletes the old active screen and every other registered screen, where it cleaned the active screen before (section 8.5, D3). The software variant does the same before `lv_deinit`. Only then does it free the resource table, styles first, then images and fonts. Handles of all five kinds are invalid after `Shutdown`. The first version of this read a freed screen; D48 has the fix. | Objects hold bare pointers to styles, images and fonts, and LVGL reads them while it deletes an object. An unloaded screen from `ScreenCreate` would otherwise keep such pointers after the resources were freed. |
| D46 | `src/core/plv_assets.c` includes three private LVGL headers: `src/core/lv_obj_private.h` and `src/core/lv_obj_style_private.h` to walk an object's style list, and `src/misc/cache/instance/lv_image_cache.h` for `lv_image_cache_drop`. | LVGL 9.6 has no public call that lists the styles of an object. A new LVGL version must be checked for changes to `struct _lv_obj_t` and `struct _lv_obj_style_t`. |
| D47 | Tests for phase 2. The no-GL suite gains `test_chart`, `test_styles`, `test_fonts` and `test_images`, and `test_helpers` checks `PsychLVGLImageFromTexture` against a stub `GetOpenGLTexture`; 517 checks pass under MATLAB R2023a and Octave 10.1 on Windows and under Octave 6.4 on Linux (WSL, Ubuntu 22.04), up from 355. The GL suite gains `test_gl_chart`, `test_gl_style`, `test_gl_image` and `test_gl_font`; 65 checks pass with Psychtoolbox 3.0.22 on an OpenGL 4.6 context. `tests/native/smoke_gl.c` gains a second scene with a shared style, a line chart (its series check reworked in D49), an upright and a transposed texture image (the transposed one with the default minification filter, as Psychtoolbox leaves it, and checked in all four quadrants so a transpose is not mistaken for a flip) and a TTF label, and it reads which framebuffer row holds panel row 0 before it checks the image orientation. The TTF tests use `examples/libs/tiny_ttf/Ubuntu-Medium.ttf` from the LVGL submodule, so they need no font of the host. | The brief's test list. The smoke test is what CI's `smoke-gl-linux` and `smoke-gl-macos` run, so the new draw paths get automated GL coverage on Mesa and on the Apple software renderer. |
| D48 | The first version of the D45 Shutdown freed a screen and then read it. `plv_clear_widgets` kept the old active screen, deleted every registered parentless object in its slot loop, and then called `lv_obj_is_valid` on the old screen before deleting it. `ScreenActive` registers the active screen, so the loop had already freed it, and LVGL 9.6's `lv_obj_is_valid` reads `obj->parent` through `lv_obj_is_in_widget_tree`. The Windows heap left the memory readable, so the Windows suite passed; glibc and macOS crashed on the first `Shutdown` of `test_dispatch` in every Linux and macOS CI job of the phase 2 commit (run 35842649421), and gdb under WSL put the fault in `lv_obj_is_in_widget_tree`. Shutdown now deletes the old active screen first, once, whether it is registered or not, and the slot loop then finds its slot free; no freed pointer is read. The fresh screen that Shutdown loads is not registered; in the persistent build the next `Init` replaces and deletes it, so it never outlives one Init cycle, and `lv_deinit` frees it in the software build. `tests/test_shutdown.m` runs Init, ScreenActive, ObjCreate on the screen and Shutdown three times, then an unloaded screen with a child, a styled screen, a chart with a series, and a `ScreenLoad` of a created screen. Measured under WSL with Octave 6.4: the old code ends in a segmentation fault in that test, the fixed code passes the whole suite, 517 checks. | A use after free that only a stricter allocator shows. The test has to run on Linux or macOS to catch a regression, which CI does. |
| D49 | Two fixes from the same CI run. `smoke-gl-macos` failed "the chart renders a non-flat plot" with 158 differing pixels against a threshold of 200, where Mesa gave 554: the check sampled every second pixel, so one pixel grid and series lines were counted or missed by parity, and Apple's software renderer rasterizes differently. The chart in the smoke scene now draws its series 6 px wide (`LV_PART_ITEMS` line width), and the check counts the red series pixels over every pixel of the chart area. Nothing else in the scene is red, so a chart without its series gives 0; the threshold is 300. Measured on Windows (Intel GL 4.6): 1324 series pixels, and 0 with the series hidden, which fails the check as it should. `CMakeLists.txt` also sets `CMAKE_OSX_DEPLOYMENT_TARGET` to 11.0 before `project()` when the caller has not set one, because MATLAB's `mex` links with `-mmacosx-version-min=11.0` and static libraries built for the runner's macOS made the linker print one warning per object file of `liblvgl.a` and `libplv_core.a`. PsychImGui does the same. | A check that measures the feature, not the rasterizer; a clean macOS link log. |
| D50 | Phase 3 is redefined (section 13, row 3): the editor's XML is parsed by a pugixml `ParseXML` subcommand and interpreted in MATLAB by `PsychLVGLLoadXML` and `PsychLVGLXMLToM`. The LVGL Pro C export plugin, `build.m plugin`, `CreateComponent`, `SubjectList`, `SubjectGet`, `SubjectSet` and the `FROM_PLUGIN` slot flag are dropped from the plan; `FindByName` stays. Section 1, section 2 and section 12 are updated to match. | The user decided on 2026-09-23 that a UI path needing a C compiler is a bridge too far for Psychtoolbox users, who install binaries. The editor already produces XML, so parsing it and interpreting it in M-code gives the same separation of layout from experiment logic with no toolchain, and the interpreter is patchable by users. Octave has no `xmlread`, which is why the parser is in C. |

### 14.5 Phase 3

| # | Deviation | Reason |
|---|---|---|
| D51 | pugixml v1.16 (commit `c8033ce9`, MIT) is a plain clone in `third_party/pugixml`, not a submodule yet, and CI clones the same commit in a "Fetch pugixml" step with `PUGIXML_COMMIT`, as it does for LVGL. `CMakeLists.txt` compiles `src/pugixml.cpp` and `src/core/plv_xml.cpp` into `plv_core` with `PUGIXML_NO_XPATH`, `PUGIXML_NO_EXCEPTIONS` and `PUGIXML_NO_STL`, and with `-fno-exceptions -fno-rtti` for GCC and Clang. `project()` now enables C++ for every build, where Tracy enabled it on demand. `plv_xml.h` is a C interface that knows nothing of LVGL, so `ParseXML` needs no `Init`; the document is made with placement new in `malloc` memory, which keeps `operator new` out. With those flags the only C++ runtime symbol left is sized `operator delete`, from the deleting destructors of pugixml's writer classes (measured with `nm` on the MinGW g++ 14.2 object), so `build.m` adds `-lstdc++` to the MEX link for GCC and `-lc++` on macOS; MSVC links its runtime anyway. `build.m` also passes `CMAKE_CXX_COMPILER` from `mkoctfile -p CXX`, its first word only, because Homebrew answers `clang++ -std=gnu++17`. The first configure of a build folder made before this change fails once, and `build.m`'s existing retry wipes the folder and configures again. | Octave has no XML reader (D50). XPath, exceptions and the STL are not needed to walk a tree, and leaving them out keeps the runtime dependency to one symbol. |
| D52 | The allowlist grows by 53 functions, from 280 to 333 generated subcommands: the setters the XML attributes need (scroll bar mode, scroll snap, scroll direction, extended click area, flex grow, label recolor and selection, switch and bar orientation, the four single arc angles and the change rate, password show time, spinbox rollover, digit count and decimal point, table cell control, chart division line counts, image pivot x and y), `lv_obj_set_name` and `lv_obj_find_by_name`, and one setter per object flag, `lv_obj_set_hidden` to `lv_obj_set_flex_in_new_track`. LVGL 9.6 marks `lv_obj_add_flag` and `lv_obj_remove_flag` deprecated and logs a warning on every call, so the interpreter uses the per-flag setters. `ParseXML` follows `ChartGetValues` in the hand-written table, so every generated opcode moved by one again, as in D40. `ObjFindByName` is the `FindByName` that D50 keeps. The interpreter calls `ObjSetName` for every named widget, so `ObjFindByName` finds it. | The widget attributes of the format come first in the brief. Adding a setter costs one generated handler and one generated test. |
| D53 | `ParseXML` details that section 13 leaves open: an argument that contains `<` is XML text, any other is a path, and a path that does not open raises `psychlvgl:XML` "neither a readable file nor XML text"; no file name contains `<` on Windows, so the rule never has to ask the file system about text. The result is the list of top-level elements, which is one element for any well-formed document. Section 7.6 has the fields, the naming rule and the text rule. A parse error reads "Start-end tags mismatch at offset 8 (line 1, column 9)". A document deeper than 256 elements raises `psychlvgl:XML`. A document being converted when an `mx` call raises is freed by the next `ParseXML`, because the error path does not return. | Keeps the one argument of the brief and makes the error useful. |
| D54 | `plv_ret_str`, which every generated `const char *` getter uses, now decodes UTF-8 into UTF-16 on MATLAB instead of calling `mxCreateString`, which reads the bytes in the user's code page. Text that is not ASCII now comes back from `LabelGetText` and the other getters as it went in. Octave is unchanged: its char is UTF-8 bytes. | Section 7.3 says "char from UTF-8"; `ParseXML` needed the conversion, and the getters had the same bug. |
| D55 | `PsychLVGLLoadXML` and `PsychLVGLXMLToM` share one interpreter, `m/private/plv_xml_run.m`, which calls an emitter for every change it makes. The execute emitter calls `PsychLVGL`, `PsychLVGLSubjects` and `PsychLVGLImageFromFile` at once and uses handles as references; the write emitter appends M code and uses variable names. The interpreter itself only reads: `ParseXML`, `Enum` (to check enum names, so a typo warns rather than aborts the load), `FontList` and `PsychLVGLOp`. `PsychLVGLXMLToM` writes a function `[root, named] = name(parent, assetDir)`, not the script that section 13 names; references and components are expanded when it writes, so the function needs no XML. Asset paths under the asset folder are written relative to `assetDir`. Percentages and `content` appear in the written code as the numbers LVGL stores for them, for example 536871012 for 100%. The two front ends report the same warnings and return the same fields in the same order; `named.subjects` comes first in both. | The brief asks for one core so the two cannot drift. A function keeps the generated variables out of the caller's workspace and takes the parent like the loader does. |
| D56 | Where the format sources disagree, the editor's output wins, and both forms are read. The selector after a local style property is written with `-` by the editor, by the Pro documentation and in every one of the 144 XML examples in LVGL 9.6's `examples/` tree (`style_bg_color-pressed`, `style_bg_opa-indicator-pressed`); the removed 9.4 engine split on `:`. A style is applied with a `<style name selector>` child in the editor's files and with a `styles="name name:knob"` attribute in the 9.4 engine. Parameters of a property are separate attributes with a hyphen (`bind_text-fmt`, `options-mode`, `value-anim`, `selected-animated`). Sources used: the LVGL Pro documentation at lvgl.io/docs/pro (components, api, styles, constants, fonts, images, screens, data binding), the example files in `third_party/lvgl/examples`, whose tree says it is written in the editor's format, and the widget schemas and parsers of LVGL v9.4.0 (`xmls/*.xml`, `src/others/xml`) for attribute names and value rules. `docs/src/xml.mdx` in the 9.6 tree only points at the Pro documentation. The editor itself and viewer.lvgl.io were not run. | Recorded as the brief asks. |
| D57 | Resolution rules. `globals.xml` is read from the file's folder or up to three folders above, or from `opts.Globals`. A component is found by its tag in the folder of the loaded file, the folder of `globals.xml`, or `opts.ComponentDirs`, and parsed on first use. `$prop` and `#const` replace a whole attribute value; constants may refer to constants; `opts.Consts` replaces a constant everywhere. A prop without a value or default drops its attribute with no warning, as LVGL does. A component's instance attributes that are not props override its view's attributes; a component can extend a widget or another component. Styles are made on first use, once per load, and shared. A repeated `name` gets `_2`, `_3` in document order. A `<screen>` fills the parent it is given, by default the active screen, so its view attributes apply to that object; a `<component>` file becomes one child. Font and image `src_path` values are relative to the folder of the file that declares them, which for `globals.xml` is the project root the Pro documentation names, or to `opts.AssetDir`. `bin`, `tiny_ttf` and `freetype` fonts all load the TTF or OTF file with `FontLoad` at the declared size; `bpp`, `range`, `symbols` and `as_file` describe the editor's conversion and are not read. `data` and `file` images load with `imread` through `PsychLVGLImageFromFile`, and `color_format` is not read. An image `src` that no `<images>` entry declares is tried as a path. The attributes `help` and the elements `previews`, `preview` and `enumdef` are editor-only and are not read. | The brief leaves these open; each follows LVGL's own engine where it had a rule. |
| D58 | Subjects are a MATLAB struct, `named.subjects`, handled by `PsychLVGLSubjects`, not LVGL observers: LVGL would run the bindings as callbacks, and MATLAB code cannot run inside one. At load time every `bind_*` attribute or element becomes a binding and every `subject_*_event` a trigger, each with `AddEvent` for its event; `apply` then pushes every subject once. Each frame `update` reads the `Poll` rows of bound widgets: a `VALUE_CHANGED` of a `bind_value` widget sets the subject from the event parameter (value, or selected index), one of a `bind_checked` widget from `ObjHasState(LV_STATE_CHECKED)`, and a trigger whose widget and event match sets, toggles or increments its subject. Every subject that changed is pushed to all its bindings except the one it came from: widget setters for values, `LabelSetText` with `sprintf(fmt, v)` for `bind_text`, the per-flag setter or the state for `bind_flag_if_*` and `bind_state_if_*`, `ObjAddStyle` and `ObjRemoveStyle` for `bind_style`, and the `ObjSetStyle<Prop>` setter for `bind_style_prop`. Int and float subjects are clamped to their `min_value` and `max_value`. A binding whose widget was deleted is dropped the first time it is written. An empty event matrix returns at once. | The event ring is the only way values leave LVGL (section 3). A MATLAB-side table can be read and set by the script with no new subcommand. |
| D59 | Not covered, each with one warning when it appears: the widgets that are not in the allowlist (`lv_buttonmatrix`, `lv_scale`, `lv_keyboard`, `lv_tabview`, `lv_spangroup`, `lv_led`, `lv_spinner`, `lv_calendar`, `lv_line`, `lv_qrcode`, `lv_list`, `lv_menu`, `lv_msgbox`, `lv_tileview`, `lv_win`, `lv_canvas`, `lv_animimg`, `lv_imagebutton`, and the Pro-only widgets); `style_grid_column_dsc_array` and `style_grid_row_dsc_array`, which the generator cannot marshal (`gen/dropped.txt`), so grid cell attributes apply but a grid layout has no tracks; `bg_grad`, `bg_image_src`, `arc_image_src`, `bitmap_mask_src`, `transition` and `anim` style properties; `<animations>`, `play_timeline_event`, `screen_load_event`, `screen_create_event` and `event_cb`; `<translations>`, `translation_tag` and `<gradients>`; `<slot>`, `<element>` and `<param>` in a component's `<api>`; the `symbol` of a dropdown and `<lv_dropdown-list>`; `text_selection` of a text area; `bind_src` of an image; subjects other than int, float and string; `<convert>` images and `imagefont` fonts; attributes on the `<screen>` and `<component>` elements, such as `permanent`; and `extends` on a screen's view. | Each needs a type the SPEC 7.3 rules do not marshal, an LVGL feature that runs callbacks, or a widget outside the allowlist. They can be added one at a time. |
| D60 | Tests for phase 3. The no-GL suite gains `test_xml_parse`, `test_xml_load` and `test_xml_subjects`, and `test_gen_marshal` covers the 53 new subcommands: 722 checks pass under MATLAB R2023a and Octave 10.1 on Windows and under Octave 6.4 on Linux (WSL, Ubuntu 22.04), up from 517. The GL suite gains `test_gl_xml`: 72 checks pass with Psychtoolbox 3.0.22 on an OpenGL 4.6 context (Intel Iris Xe), up from 65. `smoke_gl` gains five parser checks. The fixtures are in `tests/xml`, with eight example files copied from LVGL v9.6.0 in `tests/xml/lvgl_examples` and its MIT notice. The tests run the function that `PsychLVGLXMLToM` writes by evaluating its body in `tests/plv_run_generated.m`, because a new file in a folder on the path is not seen by every engine without a `rehash`, which D35 rules out. | The brief's test list. |
| D61 | `PsychLVGLXMLDemo` and the README screenshot. The demo panel is `tests/xml/demo/gabor_panel.xml` with its own `globals.xml` and a component, `stat_tile.xml`; like `PsychLVGLDemo` it needs the source tree, because the release zips do not carry `tests/`. `tools/CaptureReadmeScreenshot.m` runs the demo in a scripted mode in a 1280x720 window and saves `docs/images/psychlvgl-xml-demo.png` from the whole back buffer before the flip (88 KB here). The `plugin/` folder and its `.gitignore` lines, placeholders for the dropped C export (D50), are removed, and section 10.1 lists `tests/xml` where it listed a top-level `xml/`. | The brief asks for fixtures under `tests/xml`; the coordinator asked for the screenshot. |
| D62 | The tests carry their own copy of `Ubuntu-Medium.ttf` in `tests/xml/fonts/`, with a `NOTICE.txt` naming the Ubuntu Font Licence 1.0 and the LVGL file it was copied from. The XML fixtures, `test_fonts`, `test_gl_font` and the native smoke test all point at that copy; nothing under `tests/` refers into `third_party/lvgl` any more. The font is test data and is not part of the release packages. | The forward-test CI jobs check out the repository without submodules and download the built package, so `third_party/lvgl` is empty there. The first phase 3 run (35863170235) failed all seven forward jobs with `psychlvgl:XMLReference` warnings for the missing font while every build job passed, because only the build jobs have the submodule. A test must not depend on a tree that its job does not have. |
| D63 | The documentation is split by reader. `README.md` is for users: what PsychLVGL is, Install from a release zip, keeping and removing the path, a first panel of about 20 lines, the demos, the how-to sections, Known limits, Requirements for a release, and links onward. `DEV.md` takes the build requirements, Get the sources, Build (with the two variants and Tracy), Tests (no-GL, GL, native smoke, a Linux check from Windows), performance measurement, Continuous integration, Regenerating the bindings, the vendored LVGL patches, the XML interpreter and the layout, moved with their text. `PsychLVGLSetup.m` now also sits at the package root, byte for byte the same as `m/PsychLVGLSetup.m`, so a user who unzips a release runs `cd` to the folder and `PsychLVGLSetup`, or `run('<folder>/PsychLVGLSetup.m')`, with nothing on the path. The file finds the package root from its own location: the folder that holds `m/PsychLVGLOpen.m`, or else the parent of its own folder. It gains `'save'`, which runs `savepath` after the path change, and `'remove'`. `remove` calls `PsychLVGL('Shutdown')` when `mislocked('PsychLVGL')` is true (the MEX has no `Shutdown('all')`; `Shutdown` is the one subcommand that unlocks), checks `mislocked` again, prints what to do and returns without a path change if the MEX is still locked, then runs `clear('PsychLVGL')` (`clear('-f', ...)` on Octave, because a plain `clear` there leaves a loaded function resident and the `rmpath` that follows crashed Octave 10.1 on Linux in PsychNanoVG's CI, run 35887011083, while the `-f` form passed in PsychImGui's) and only then `rmpath` on `dist/<arch>`, `dist-sw/<arch>` and `m/`; a package that is not on the path is a no-op. `tests/test_setup.m` checks the two copies and the remove cycle and runs last in the no-GL group, as the one test that changes the path, only after the MEX is unloaded. 735 no-GL checks pass under MATLAB R2023a and Octave 10.1 on Windows, up from 722, and the GL suite still passes its 72. The demos no longer need the source tree and no longer call `addpath`. Their window and Gabor helpers are copies in `m/private` (`psychlvgl_demo_window`, `psychlvgl_demo_window_close`, `psychlvgl_gabor_std`, `psychlvgl_gabor_michelson`), and the tests keep the originals in `tests/gl`. The demo panel moved from `tests/xml/demo` to `examples/xml/gabor_panel`, with its own copy of `Ubuntu-Medium.ttf`, the Ubuntu Font Licence text `UFL.txt` from the LVGL tree, and a `NOTICE.txt`; `globals.xml` names the font as `fonts/Ubuntu-Medium.ttf`, and `test_xml_load` loads the panel from there. This replaces the part of D61 that says the demo needs the source tree. A demo now closes its panel and keeps its window, so both demos run any number of times in one session on one OpenGL context; `sca` closes the window, after which a panel needs a new session (D6). The screenshot mode of `PsychLVGLXMLDemo` still closes the window. `tools/CaptureReadmeScreenshot.m` keeps its `addpath`, as a source tree tool run in a fresh session. Every upload step in `ci.yml` ships `PsychLVGLSetup.m`, `examples` and `docs/images/psychlvgl-xml-demo.png` in addition to the earlier list. `RELEASING.md`, `third_party/PINS.md`, the `build.m` error and the generated help of `m/PsychLVGL.m` point at `DEV.md` where they pointed at the README for build matters, and the help shim error now says to run `PsychLVGLSetup`. | A user could not find how to install: the README opened with build, test and CI material, a release zip left `PsychLVGLSetup` inside `m/`, which is not on the path after an unzip, and there was no way to take the package off the path again. A root wrapper that called the `m/` copy by name would call itself whenever the package root is the current folder, because the current folder comes before the path; a second public setup name would give users two functions for one job. The demos called `addpath` at run time, which is the D35 crash class once the MEX is loaded, and read files that the zips did not carry. |
| D64 | The build waits out the link second under Octave. `build.m` now ends with `age_mex_file`: under Octave it waits until the second of the MEX file's modification time has passed, at most one second, so no later load can fall inside it. MATLAB has no such check and skips the wait. Reproduced from a core dump in the `gnuoctave/octave:10.1.0` container (gdb hides the timing), and verified there by relinking and testing back to back. | Octave 10.1 rechecks a loaded function when its check time is not later than the last prompt or path stamp, in whole seconds, and `addpath` and `rmpath` set that stamp; it reloads the function when the file's modification time, with sub-second precision, is newer than the parse time truncated to whole seconds (`fcn-info.cc`, `out_of_date_check`). Reloading a MEX function recurses without end, because `remove_all_breakpoints_from_function` looks the function up again, and the process dies of stack exhaustion. So a MEX linked, put on the path and first loaded inside one wall-clock second crashes the first call after any path change. The lock was never the cause; it only made the earlier failures repeatable, because the locked MEX stayed loaded across the path change. CI runs 35887011083 (PsychNanoVG) and the one-session container run here showed the same frames as D35's crash. D35's rule about path changes stands as practice, but its explanation is superseded by this row. |
