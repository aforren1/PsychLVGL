# PsychLVGL

`PsychLVGL` is a MEX binding of LVGL 9.6 for MATLAB and GNU Octave. It draws
retained mode GUI panels inside a Psychtoolbox (PTB) onscreen window. LVGL
renders on the GPU with its NanoVG draw unit into an OpenGL texture. PTB draws
that texture like any other PTB texture, so no pixels cross the CPU.

![A dark LVGL control panel on the left of a Psychtoolbox window, with a contrast slider, a frequency dropdown, a drift switch, a value tile, an arc, a color wheel image, a line chart of the contrast history, three buttons, a progress bar and a trial table; a drifting Gabor patch fills the right side](docs/images/psychlvgl-xml-demo.png)

The panel of `PsychLVGLXMLDemo`, loaded from the XML file
`tests/xml/demo/gabor_panel.xml` and drawn into a Psychtoolbox window next to
the Gabor patch it controls. `tools/CaptureReadmeScreenshot.m` makes this
image again.

`SPEC.md` is the design reference. Read it for the marshaling rules, the handle
model and the event model. This file tells you how to build, test and run.

Status: phases 1 to 3 of SPEC section 13 are implemented. Phase 2 adds
charts, shared styles, images drawn straight from Psychtoolbox textures, TTF
fonts, and GPU timing. Phase 3 loads user interfaces that the LVGL editor
saves as XML, at run time and with no compiler; see "Load an XML user
interface" below.

## Requirements

| Item | Version |
|---|---|
| MATLAB | R2023a verified, R2019b or later expected. On Apple silicon, R2023b or later, because that is the first native build |
| GNU Octave | 10.1 verified on Windows, 6.4 verified on Linux (WSL, Ubuntu 22.04). On macOS, the Homebrew build (`brew install octave`) |
| Operating system | Windows 10 or later, Linux, macOS 12 or later on Apple silicon (`maca64`). Intel Macs are not built or tested |
| CMake | 3.16 or later |
| C and C++ compiler | MSVC 2022 for MATLAB on Windows, the MinGW gcc and g++ that Octave ships, Xcode command line tools on macOS, gcc and g++ or clang elsewhere. C++ builds only pugixml, inside the static library |
| Psychtoolbox | 3.0.19 or later, only for the GPU build and the demo |
| Linux packages | `libgl1-mesa-dev` (or `libgl-dev`) for the GPU build, which links `libGL`; add `libx11-dev`, `xvfb`, and `libgl1-mesa-dri` for the native smoke test |
| macOS frameworks | `OpenGL.framework`, which the Xcode command line tools install. Nothing else |
| Python and uv | only to regenerate the bindings |

## Get the sources

LVGL is a submodule, so clone with it:

```sh
git clone --recurse-submodules https://github.com/aforren1/PsychLVGL.git
cd PsychLVGL
```

If you already cloned without `--recurse-submodules`:

```sh
git submodule update --init --recursive
```

If the submodule cannot be fetched, the same commit can be cloned by hand:

```sh
git clone --branch v9.6.0 https://github.com/lvgl/lvgl.git third_party/lvgl
```

pugixml, the XML parser, is a plain clone for now, not a submodule. Clone it
next to LVGL:

```sh
git clone --branch v1.16 https://github.com/zeux/pugixml.git third_party/pugixml
```

`third_party/PINS.md` records the exact commits either way.

## Build

From the repository root:

```matlab
build              % the GPU build, into dist/<arch>
build test-sw      % the software test build, into dist-sw/<arch>
build test         % build test-sw, then run the no-GL tests
build test-gl      % build the GPU variant, then run the GL tests
build gen          % regenerate the bindings, needs uv and a C compiler
build clean        % remove the build and install directories
```

`build` compiles LVGL with CMake against the project `lv_conf.h`, then calls
`mex` on the binding sources and links the static libraries. The static library
and the MEX must come from one toolchain; `build.m` compares a marker string
compiled into the library with the compiler `mex` uses and stops if they differ.

`MEX_CMAKE_GENERATOR` overrides the CMake generator. On Windows the
"MinGW Makefiles" generator refuses to run while `sh.exe` is on PATH, so use
`Ninja` inside a Git Bash or MSYS2 shell.

Octave names its MEX `PsychLVGL.mex` on every operating system, so the output
carries the architecture: `dist/win64`, `dist/glnxa64`, `dist/maci64`,
`dist/maca64`. Put the right one on the path with:

```matlab
PsychLVGLSetup          % the GPU build
PsychLVGLSetup('sw')    % the software test build
```

## Two build variants

| Variant | Output | Renders with | Needs |
|---|---|---|---|
| GPU, the default | `dist/<arch>` | LVGL OpenGL texture driver plus the NanoVG draw unit | a current OpenGL 3.2 context, normally from `Screen('BeginOpenGL')`. On macOS the context is GL 2.1 and the build uses the NanoVG GL2 shaders; see "Known limits" |
| software, for tests | `dist-sw/<arch>` | the LVGL software draw unit into a buffer the MEX owns | nothing |

Both are called `PsychLVGL`, so only one can be on the path at a time.

## Tests

```matlab
build test-sw
run_tests sw        % the no-GL suite, MATLAB and Octave, no GPU, no PTB

build
run_tests gl        % the GL suite, needs Psychtoolbox and a GPU
```

Run the two suites in separate engine sessions, because each needs its own
MEX on the path.

The no-GL suite covers the handle table, the event ring, the keypad, dispatch
and argument errors, the tick, every generated subcommand, a CRC32 of the
rendered software buffer, charts and their series handles, styles, fonts,
images, the helper M-files, `ParseXML`, and the XML interpreter on the
fixtures in `tests/xml`, including eight example files copied from the LVGL
tree. The helpers are tested
against a Psychtoolbox stub in `tests/stub`, which records the calls and
answers them, so the suite checks that every `Screen('BeginOpenGL')` has its
`Screen('EndOpenGL')` even when the wrapped call fails. `run_tests` puts that
directory on the path once and takes it off once; no test changes the load
path, and nothing here calls `rehash`, because a path change while the MEX is
loaded can drive Octave 10 into unbounded recursion (SPEC deviation D35). The GL suite opens one 640x480 Psychtoolbox window
and checks the texture id, the rendered colors, the panel orientation, a click,
a resize, a chart, a style, a texture image, a TTF label, and an XML screen.

The GL tests, the demo and the perf script all open their window through
`tests/gl/ptb_test_window.m`. That is the one place that sets
`Screen('Preference', 'SkipSyncTests', 2)` and
`Screen('Preference', 'VisualDebugLevel', 0)`, so repeated runs skip the
display sync calibration and the startup splash. Never use those settings for
a real experiment session. The helper also caches the window, because LVGL
allows only one OpenGL context per process.

### Native smoke test

`smoke_gl` drives the OpenGL and NanoVG path with no engine at all. It creates
a hidden window and a legacy context, runs the core layer through several
Update cycles with synthetic input, reads the panel texture back through a
framebuffer object, and prints the Update times. A second scene draws a shared
style, a line chart, an image straight from an OpenGL texture and a TTF label,
and checks each one in the read-back pixels. Before any of that it parses a
small XML document through the C interface of the parser, so the C++ part of
the core library runs on every platform that runs the smoke test.

```sh
# Windows
cmake -S . -B build-smoke -DPSYCHLVGL_SMOKE_GL=ON
cmake --build build-smoke --config Release --target smoke_gl
./build-smoke/Release/smoke_gl

# Linux, in its own build tree so a shared checkout keeps both
cmake -S . -B build-smoke-linux -DCMAKE_BUILD_TYPE=Release -DPSYCHLVGL_SMOKE_GL=ON
cmake --build build-smoke-linux --target smoke_gl --parallel
LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a ./build-smoke-linux/smoke_gl
```

The Linux form needs `xvfb`, `libgl1-mesa-dri`, `libgl1-mesa-dev` and
`libx11-dev`, and it runs on Mesa's llvmpipe software renderer. That is what
the CI job does.

## Use it in an experiment

Four calls carry the OpenGL bookkeeping, so the script never writes a
`Screen('BeginOpenGL')` and `Screen('EndOpenGL')` pair:

| Call | What it does |
|---|---|
| `ui = PsychLVGLOpen(win, w, h [, dst] [, opts])` | Creates the panel, wraps its OpenGL texture as a Psychtoolbox texture, starts the keyboard queue. |
| `[ui, E] = PsychLVGLFrame(ui)` | One frame: input, update, draw the panel, return the events. |
| `[...] = PsychLVGLGL(ui, subcommand, ...)` | Any single subcommand that needs the OpenGL context. |
| `PsychLVGLClose(ui)` | Shuts the panel down and frees the texture. Safe twice. |

```matlab
PsychLVGLSetup();
InitializeMatlabOpenGL(1);                 % before the window, not after
[win, winRect] = PsychImaging('OpenWindow', screenid, 0);

panelW = 400; panelH = 600;
dst = [20 20 20+panelW 20+panelH];
ui = PsychLVGLOpen(win, panelW, panelH, dst);

scr = PsychLVGL('ScreenActive');
sl = PsychLVGL('SliderCreate', scr);
PsychLVGL('ObjSetSize', sl, 300, 20);
PsychLVGL('ObjAlign', sl, 'LV_ALIGN_CENTER', 0, 0);
PsychLVGL('AddToGroup', sl);

while running
    [ui, E] = PsychLVGLFrame(ui);
    S = PsychLVGLEvents('decode', E);
    % ... read S(k).target, S(k).name, S(k).param ...
    Screen('DrawTexture', win, stimulus);
    Screen('Flip', win);
end

PsychLVGLClose(ui);
```

Widget calls need no OpenGL context, so they go straight to `PsychLVGL`. Only
`Init`, `Update` and `Shutdown` touch OpenGL, and the helpers wrap those three.
`PsychLVGLGL` is there for a frame loop that gathers its own input:

```matlab
dirty = PsychLVGLGL(ui, 'Update', GetSecs(), [x y pressed], wheel, keys);
Screen('DrawTexture', win, ui.tex, [], ui.dst);
```

### The low-level form

The helpers are M-files with no state of their own, so the raw sequence works
just as well. SPEC section 4.3 shows both. In short:

```matlab
Screen('BeginOpenGL', win);
glTex = PsychLVGL('Init', panelW, panelH);
Screen('EndOpenGL', win);
tex = Screen('SetOpenGLTexture', win, [], glTex, GL.TEXTURE_2D, panelW, panelH, 32);
...
Screen('BeginOpenGL', win);
PsychLVGL('Update', GetSecs(), mouse, wheel, keys);
Screen('EndOpenGL', win);
Screen('DrawTexture', win, tex, [], dst);
E = PsychLVGL('Poll');
...
Screen('BeginOpenGL', win);
PsychLVGL('Shutdown');
Screen('EndOpenGL', win);
Screen('Close', tex);
```

Every subcommand marked GL in SPEC section 5 has to run between `BeginOpenGL`
and `EndOpenGL`, and the MEX raises `psychlvgl:NoGLContext` when it does not.

### Charts, styles, images and fonts

None of these subcommands needs an OpenGL context. Each returns a handle, like
a widget does, and `PsychLVGL('IsValid', h)` works for all of them.

| Subcommand | What it does |
|---|---|
| `ch = PsychLVGL('ChartCreate', parent)` | A chart. `ChartSetType`, `ChartSetPointCount`, `ChartSetAxisRange` and the rest of the generated `Chart*` subcommands configure it. |
| `ser = PsychLVGL('ChartAddSeries', ch, [r g b], axis)` | A series handle. It dies with its chart. |
| `PsychLVGL('ChartSetNextValue', ch, ser, v)` | Appends one value. The cheap per-frame call, about 0.2 us. |
| `PsychLVGL('ChartSetValues', ch, ser, values)` | Copies a whole vector into the series. NaN is a gap. |
| `values = PsychLVGL('ChartGetValues', ch, ser)` | The values in screen order. |
| `st = PsychLVGL('StyleCreate')` | A shared `lv_style_t`. |
| `PsychLVGL('StyleSetProp', st, 'bg_color', [r g b])` | Any property of the `ObjSetStyle<Prop>` subcommands, with the same value. |
| `PsychLVGL('ObjAddStyle', h, st [, selector])` | Adds the style to an object. `ObjRemoveStyle` and `ObjRemoveStyleAll` take it off. |
| `img = PsychLVGLImageFromTexture(win, tex)` | An image that draws a Psychtoolbox texture, with no pixel copy. |
| `img = PsychLVGL('ImageFromArray', uint8Image)` | An image from a uint8 HxW, HxWx3 or HxWx4 array. |
| `PsychLVGL('ImageSetSrc', imageObj, img)` | Shows the image in an image object from `ImageCreate`. 0 clears it. |
| `f = PsychLVGL('FontLoad', ttfPath, px)` | A TTF or OTF font. The handle works wherever a font name does. |
| `StyleDelete`, `ImageDelete`, `FontDelete` | Free the resource. Each raises `psychlvgl:InUse` while an object or a style still uses it. |

```matlab
scr = PsychLVGL('ScreenActive');

ch  = PsychLVGL('ChartCreate', scr);
PsychLVGL('ObjSetSize', ch, 300, 120);
PsychLVGL('ChartSetPointCount', ch, 60);
ser = PsychLVGL('ChartAddSeries', ch, [255 200 0], 'LV_CHART_AXIS_PRIMARY_Y');

card = PsychLVGL('StyleCreate');
PsychLVGL('StyleSetProp', card, 'border_width', 2);
PsychLVGL('ObjAddStyle', ch, card);

f = PsychLVGL('FontLoad', 'C:\Windows\Fonts\arial.ttf', 24);
lbl = PsychLVGL('LabelCreate', scr);
PsychLVGL('ObjSetStyleTextFont', lbl, f);

tex = Screen('MakeTexture', win, imread('face.png'), [], 1);
img = PsychLVGLImageFromTexture(win, tex);
PsychLVGL('ImageSetSrc', PsychLVGL('ImageCreate', scr), img);

% every frame
PsychLVGL('ChartSetNextValue', ch, ser, round(100 * contrast));
```

A texture image needs a `GL_TEXTURE_2D` texture, which is what `specialFlags`
1 gives. Either storage order works: the default, which holds the matrix
transposed, and `textureOrientation` 1 or 2, which holds it upright. The
image shows the matrix as `Screen('DrawTexture')` does, columns wide and rows
high. Texture images do not tile. The texture stays yours: keep it open while the image is shown, and after you change its
contents call `PsychLVGL('ObjInvalidate', imageObj)`. `PsychLVGLClose` frees
every chart series, style, image and font of the session, but not the
Psychtoolbox textures.

`PsychLVGLDemo` is a working example: a Gabor patch whose contrast follows a
slider, with a dropdown, a text area and a status label. `PsychLVGLDemo(3)`
runs it for three seconds, which is what a smoke run does.

`PsychLVGLXMLDemo` is the same experiment with its panel loaded from XML; it
is the screenshot at the top of this file. Both demos need the source tree,
because their window helper and the XML live under `tests/`.

`PsychLVGLPerf` sweeps panel sizes and widget counts and prints the Update
times together with the cost of the two Psychtoolbox context switches.

## Load an XML user interface

The LVGL editor (LVGL Pro, online or desktop) saves every screen and every
component of a project as an XML file. `PsychLVGLLoadXML` reads such a file at
run time and makes the same widgets with ordinary `PsychLVGL` calls. Nothing
is compiled, so a layout can change between two sessions of an experiment.

1. Design the panel in the editor, or write the XML by hand. Keep the
   project folder together: the screen files, the component files, and
   `globals.xml` with the constants, styles, subjects, fonts and images.
2. Open the panel, then load the screen into it:

   ```matlab
   ui = PsychLVGLOpen(win, 440, 680, [20 20 460 700]);
   [root, named] = PsychLVGLLoadXML('ui/main.xml');
   ```

   A `<screen>` fills the active screen, or the object you give as the
   second argument. A `<component>` file becomes one child of it.
3. Use the widgets by the `name` attribute they have in the XML:

   ```matlab
   PsychLVGL('LabelSetText', named.status, 'ready');
   PsychLVGL('AddToGroup', named.contrast_slider);
   ```

4. If the XML binds widgets to subjects (`bind_value`, `bind_text`,
   `bind_checked`, the `bind_flag_if_*` elements, `subject_*_event`), pass the
   events to `PsychLVGLSubjects` every frame and read the values from it:

   ```matlab
   while running
       [ui, E] = PsychLVGLFrame(ui);
       named.subjects = PsychLVGLSubjects('update', named.subjects, E);
       contrast = PsychLVGLSubjects('get', named.subjects, 'contrast') / 100;
       ...
       Screen('Flip', win);
   end
   ```

   A value set from the script reaches every bound widget:
   `named.subjects = PsychLVGLSubjects('set', named.subjects, 'contrast', 50)`.

Every element or attribute that PsychLVGL cannot map gives one warning that
names it and the file. Nothing is dropped without one. Pass
`struct('Warn', @(id, msg) ...)` as the third argument to collect the
warnings instead.

To see or keep the calls that a file makes, write them as a MATLAB function:

```matlab
PsychLVGLXMLToM('ui/main.xml', 'build_main_panel.m');
[root, named] = build_main_panel();       % the same result as PsychLVGLLoadXML
```

| Call | What it does |
|---|---|
| `[root, named] = PsychLVGLLoadXML(file [, parent] [, opts])` | Builds the interface of a screen or component file. `opts` fields: `AssetDir`, `Consts` (replaces `<consts>` values), `Warn`, `Globals` (a `globals.xml`, or `'none'`), `ComponentDirs`. |
| `PsychLVGLXMLToM(file, outFile [, opts])` | Writes the same calls as a function `[root, named] = name(parent, assetDir)`. |
| `S = PsychLVGLSubjects(verb, S, ...)` | The subject table: `update` once per frame with the events, `get`, `set`, and the `add`, `bind` and `trigger` verbs the loader uses. |
| `img = PsychLVGLImageFromFile(path)` | An image handle from a PNG or JPEG file. The loader uses it for `<images>`. |
| `tree = PsychLVGL('ParseXML', pathOrText)` | The parser itself: a struct tree with `tag`, `attributes`, `attr_names`, `text` and `children`. Needs no `Init`. |

What the loader covers:

| XML | Status |
|---|---|
| `lv_obj`, `lv_label`, `lv_button`, `lv_slider`, `lv_switch`, `lv_checkbox`, `lv_bar`, `lv_arc`, `lv_dropdown`, `lv_roller`, `lv_textarea`, `lv_spinbox`, `lv_table`, `lv_chart`, `lv_image` | Mapped, with their attributes, the table columns and cells, and the chart series, axes and cursors. |
| `x`, `y`, `width`, `height` (pixels, `%`, `content`), `align`, `flex_flow`, `flex_grow`, the scroll attributes, every object flag and state | Mapped. |
| Every `style_*` attribute, with parts and states after `-` or `:` (`style_bg_color-knob-pressed`) | Mapped onto the `ObjSetStyle<Prop>` setters. |
| `<consts>` and `#name`, `<styles>` with `<style name selector>` children or the `styles` attribute, `<component>` with `<api>` props, `$prop` and `<view extends>` | Mapped. Styles become style handles, shared by every widget that uses them. |
| `<fonts>` (`bin`, `tiny_ttf`, `freetype`) and built-in `lv_font_montserrat_*` names; `<images>` (`data`, `file`) | Fonts load with `FontLoad` at the declared size; images load with `imread`. |
| `<subjects>` (`int`, `float`, `string`) and the `bind_*` and `subject_*_event` elements | Kept by `PsychLVGLSubjects`, which moves values through the event ring once per frame. |
| Widgets that are not in the allowlist (button matrix, scale, keyboard, tab view, span, LED, and the others), grid track arrays, gradients, background and arc images, animations and timelines, translations, screen load events, event callbacks | Not mapped. Each gives one warning. SPEC deviation D59 has the list. |

## Continuous integration

`.github/workflows/ci.yml` builds and tests the project on every push and
pull request, and publishes a release on a `v*` tag. Checkout is
`submodules: recursive`, and a "Fetch LVGL" step clones the pinned commit when
the submodule is not there. A "Fetch pugixml" step does the same for pugixml,
with the commit in `PUGIXML_COMMIT`.

Jobs:

| Job | What it does |
|---|---|
| `matlab-build` | MATLAB R2022b on Ubuntu and Windows: software variant, `run_tests sw`, then the GPU variant compile only. Uploads `dist-sw/<arch>` and `dist/<arch>`. |
| `matlab-test-forward` | The newest MATLAB runs the binaries the floor release built, with no rebuild. |
| `octave-build` | `gnuoctave/octave` Docker images, one per binary compatible era (6.4 and 10.1). Same two builds and the same test run. |
| `octave-test-forward` | Newer Octave versions run each era's binary. |
| `octave-windows` | Official GNU Octave Windows zip (10.1.0, cached), using the toolchain and `make` it ships, as on a developer machine. |
| `smoke-gl-linux` | Builds and runs `smoke_gl` under Xvfb and Mesa llvmpipe. This is the only automated coverage of the NanoVG GL3 path, because no runner has a GPU. |
| `octave-macos` | Homebrew Octave on `macos-latest` (Apple silicon): same two builds and the same test run, uploaded as `maca64`. |
| `smoke-gl-macos` | Builds and runs `smoke_gl` against a drawable-less CGL context, which is the GL 2.1 compatibility profile Psychtoolbox uses on macOS. |
| `release` | On a `v*` tag, zips each artifact and publishes a GitHub Release. |

Four units build or test macOS: the `macos-latest` entries of `matlab-build`
and `matlab-test-forward`, `octave-macos`, and `smoke-gl-macos`. They block
like every other job. The smoke job runs the GPU path on Apple's software
renderer, which is a GL 2.1 context with GLSL 1.20, the same profile
Psychtoolbox gets on a Mac.

Artifacts are named `psychlvgl-<engine>-<platform>[-<era>]` and each one holds
only its own `dist/<arch>` and `dist-sw/<arch>`, plus `m/` (with the XML
interpreter in `m/private`), `lv_conf.h`, `README.md` and `SPEC.md`. The XML
fixtures and the demo panel under `tests/xml` are not packaged.

## Regenerating the bindings

`src/psychlvgl_gen.c` (with the `StyleSetProp` property table),
`src/psychlvgl_enums.c`, `m/PsychLVGL.m`, `m/PsychLVGLOp.m` and
`tests/test_gen_marshal.m` are generated from the LVGL headers and committed,
so a normal build needs no Python.

```sh
uv run --project gen gen/generate.py
```

`gen/allowlist.toml` chooses the functions. `gen/dropped.txt` lists the
allowlisted functions whose signatures the marshaling rules of SPEC section
7.3 cannot express.

Run the generator on the patched LVGL tree. Any CMake configure, or
`tools/apply_lvgl_patches.sh`, applies the patches; patch 0002 adds the enum
constant `LV_IMAGE_FLAGS_GL_TEXTURE`, and a run on a pristine tree drops it
from `src/psychlvgl_enums.c`.

## Known limits

- One LVGL display per process, bound to one Psychtoolbox window. LVGL 9.6
  can build its NanoVG renderer only once per process, so the MEX keeps the
  display alive across `Shutdown` and reuses it. A second OpenGL context in
  one engine session, for example after `sca` and a new `OpenWindow`, is not
  supported.
- `Shutdown` clears the widget tree and loads a new screen. It does not free
  LVGL itself.
- Style properties that need a pointer argument, such as `bg_image_src` or a
  gradient descriptor, are not bound. See `gen/dropped.txt`.
- An image from `ImageFromArray` is uploaded to the GPU again every time LVGL
  draws it, because the image cache is off. Use a texture image for large or
  often redrawn pictures.
- Series, cursors, styles, images and fonts share one table of 4096 handles
  per session.
- The GPU time in `Stats` needs OpenGL 3.3 or `GL_ARB_timer_query`. It stays 0
  on the OpenGL 2.1 context of macOS.
- The XML loader covers the part of the LVGL XML format listed in "Load an
  XML user interface". Grid layouts do not work, because the grid track
  arrays cannot be passed (`gen/dropped.txt`).
- macOS is built and packaged for Apple silicon only. Psychtoolbox gives a
  GL 2.1 compatibility context there, so the build selects
  `LV_NANOVG_BACKEND_GL2` and applies vendored LVGL patch 0001, described below.
  The `smoke-gl-macos` job runs that path on Apple's software renderer. The
  software variant and the whole no-GL suite do not depend on it.

## Vendored LVGL patches

`third_party/lvgl` is the unmodified v9.6.0 submodule plus two patches in
`patches/lvgl`. CMake applies each one at configure time when the checkout
does not carry it yet, and `tools/apply_lvgl_patches.sh` does the same from a
shell.

| Patch | What it does | SPEC |
|---|---|---|
| `0001-opengles-driver-gl21-glsl120.patch` | Adds a GLSL 1.20 shader path and a luminance texture fallback to LVGL's OpenGL driver. The GL2 build needs it on the OpenGL 2.1 contexts Psychtoolbox creates on macOS; upstream LVGL needs OpenGL 3.0. | D38 |
| `0002-nanovg-image-from-gl-texture.patch` | Adds the image flags `LV_IMAGE_FLAGS_GL_TEXTURE` and `LV_IMAGE_FLAGS_GL_TEXTURE_TRANSPOSED`, which let an image descriptor name an OpenGL texture stored upright or transposed. The NanoVG draw unit then samples the texture directly. `ImageFromTexture` needs it. | D41 |

After a build, `git status` shows `third_party/lvgl` as modified. That is the
applied patches, not something to commit. To see the pristine tree again, run
`git -C third_party/lvgl checkout -- .`; the next configure applies the
patches again.

## Releasing

A release is a `v*` tag; CI builds and publishes the packages. The
step-by-step checklist, including where the version string lives and how to
recover from a failed release job, is in [RELEASING.md](RELEASING.md).
