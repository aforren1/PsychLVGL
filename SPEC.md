# PsychLVGL specification

Status: implemented through phase 1. Specification version 0.1, 2026-09-22; section 14 records every deviation.

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
- A later phase that loads user interfaces exported as C code by the LVGL Pro
  editor.
- MATLAB R2023a and Octave 10.1 on Windows, verified. Linux expected to work.
  macOS best effort.

### 1.3 Out of scope

- Software rendering at run time. A software build variant exists for tests
  only.
- Runtime XML parsing. LVGL removed the open-source XML loader in 9.5.0.
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
| LVGL Pro editor or CLI | current | developer machine, phase 3 only | Exports XML user interfaces as C. Community license is free for personal and open-source use. |

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
| IsValid | `tf = PsychLVGL('IsValid', h)` | Slot and generation check without error. |
| AddEvent / RemoveEvent | `PsychLVGL('AddEvent', h, 'LONG_PRESSED')` | Edits the per-object event mask. Names without the `LV_EVENT_` prefix. |
| AddToGroup / RemoveFromGroup | `PsychLVGL('AddToGroup', h)` | Default focus group for keypad and encoder input. |
| FocusObj | `PsychLVGL('FocusObj', h)` | `lv_group_focus_obj`. |
| EventName | `name = PsychLVGL('EventName', code)` | Reverse lookup for `Poll` output. |

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
| 4 | `param`: widget value for VALUE_CHANGED (slider, arc, bar, spinbox value; dropdown and roller selected index; checkbox and switch checked state), key code for KEY, 0 otherwise |
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
| `m/PsychLVGLSetup.m` | Puts `dist/<arch>` and `m/` on the path for this engine and platform. |
| `m/PsychLVGL.m` | Help text only. The MEX shadows it once built. Generated. |
| `m/PsychLVGLInput.m` | `Start`, `Poll`, `Stop`. Wraps `KbQueueCreate`, `KbQueueStart`, `KbEventGet`, `GetMouse`, `GetMouseWheel`. Converts mouse to panel pixels and key events to LVGL key codes. |
| `m/PsychLVGLKeyMap.m` | PTB key event to LVGL key code, section 6.3. |
| `m/PsychLVGLEvents.m` | `decode` and `filter`. |
| `m/PsychLVGLOp.m` | Generated struct of opcodes. |
| `m/PsychLVGLDemo.m` | Demo: Gabor patch controlled by a slider, a dropdown, a text area. |

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
| `psychlvgl:Font` | Unknown font name. |

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
| `const lv_font_t*` | font name from `FontList` | none |
| `uint32_t key` in `lv_textarea_add_char` | double code point | none |
| output pointers to scalars, `lv_area_t*`, `lv_point_t*`, `uint32_t* row, uint32_t* col` | not passed | extra outputs |
| function pointers, `void*`, variadic, arrays of structs, `lv_style_t*`, `lv_anim_t*`, `lv_draw_*`, `lv_image_dsc_t*`, `lv_indev_t*`, `lv_display_t*` | not supported in phase 1. The generator refuses the entry. | |

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
  README.md
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
  plugin/                 phase 3, LVGL Pro C export goes here
  third_party/
    lvgl/                 submodule v9.6.0
    tracy/                submodule, optional
```

### 10.2 lv_conf.h

Key settings:

| Option | Value | Reason |
|---|---|---|
| `LV_USE_OPENGLES` | 1 | texture driver |
| `LV_USE_DRAW_NANOVG`, `LV_USE_NANOVG`, `LV_USE_MATRIX` | 1 | GPU draw unit and its requirements |
| `LV_NANOVG_BACKEND` | `LV_NANOVG_BACKEND_GL3`, or GL2 on macOS | `lv_conf.h` wraps the line in `#ifndef LV_NANOVG_BACKEND`; CMake passes `-DLV_NANOVG_BACKEND=...` per platform |
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
   `build.m plugin <dir>` compiles an LVGL Pro C export into the MEX (section 13).

### 10.4 CI

Same shape as `mex-msgpack`: build on the oldest supported release, test the
binary on the newest. CI runs the no-GL tests on the software variant and
compiles the GL variant without running it. GL tests run on developer machines.

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

### 11.3 Interactive

`PsychLVGLDemo.m`: a Gabor patch whose contrast follows a slider, a dropdown
that selects the spatial frequency, a text area for a subject id, and a status
label. `perf/PsychLVGLPerf.m` prints the table described in section 9.4.

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
- Runtime XML loading. Rejected: LVGL 9.5.0 removed the open-source XML engine.
  Pinning 9.4.0 would freeze the binding on an old release. See section 13.
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
| macOS support? | Best effort with the GL2 backend. Not CI-blocking. |

## 13. Phasing

| Phase | Content |
|---|---|
| 1 | Lifecycle, GL loader, NanoVG display, indevs, handles, events, generator, allowlist of section 5.3, `Stats`, software test variant, GL tests, demo. |
| 2 | Chart (int32 array marshaling, series handles), `lv_style_t` handles (`StyleCreate`, `StyleSetProp`, `ObjAddStyle`), images from PTB textures by wrapping a PTB texture's GL id with `lv_opengles_texture_create_from_texture_id` or an `lv_image_dsc_t` handle, TTF fonts through `LV_USE_TINY_TTF`, Tracy GPU zones. |
| 3 | LVGL Pro C export as a UI plugin. The editor or CLI exports `<name>_gen.c` and `<name>_gen.h` with `lv_obj_t* <name>_create(lv_obj_t* parent)` functions (screens take no parent), `lv_obj_set_name_static` on named objects, and global `lv_subject_t` variables. The export includes `lvgl_private.h`, so it must compile against the same LVGL tree and `lv_conf.h`. `build.m plugin <dir>` compiles the export plus a hand-written `plugin_table.c` with `{name, create_fn}` and `{name, lv_subject_t*}` arrays into the MEX. New subcommands: `CreateComponent(name, parentH)` calls the create function, walks the new subtree with `lv_obj_get_child`, registers slots with the `FROM_PLUGIN` flag and the event callback, and returns the root handle; `FindByName(rootH, name)` wraps `lv_obj_find_by_name`; `SubjectList`, `SubjectGet(name)`, `SubjectSet(name, value)` for int, string, and color subjects; subject observers push a synthetic `SUBJECT_CHANGED` record into the event ring with the subject index as target. A UI change needs a rebuild. |

## 14. Deviations from version 0.1

Phase 1 is implemented. Everything below differs from sections 1 to 13 above.
Section 13 stays the plan of record; only this section is added.

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
