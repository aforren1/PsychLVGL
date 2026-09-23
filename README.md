# PsychLVGL

`PsychLVGL` is a MEX binding of LVGL 9.6 for MATLAB and GNU Octave. It draws
retained mode GUI panels inside a Psychtoolbox (PTB) onscreen window. LVGL
renders on the GPU with its NanoVG draw unit into an OpenGL texture. PTB draws
that texture like any other PTB texture, so no pixels cross the CPU. Pick it
when an experiment needs a real control panel next to the stimulus: sliders,
dropdowns, text fields, charts and tables that the participant or the
experimenter uses while PTB keeps its own timing. You can build the panel with
function calls, or design it in the LVGL editor and load the XML file at run
time, with no compiler.

![A dark LVGL control panel on the left of a Psychtoolbox window, with a contrast slider, a frequency dropdown, a drift switch, a value tile, an arc, a color wheel image, a line chart of the contrast history, three buttons, a progress bar and a trial table; a drifting Gabor patch fills the right side](docs/images/psychlvgl-xml-demo.png)

The panel of `PsychLVGLXMLDemo`, loaded from the XML file
`examples/xml/gabor_panel/gabor_panel.xml` and drawn into a Psychtoolbox window next to
the Gabor patch it controls.

## Install

You need MATLAB or GNU Octave and Psychtoolbox. You do not need a compiler.
See [Requirements](#requirements) for the versions.

1. Open the Releases page:
   <https://github.com/aforren1/PsychLVGL/releases>.

   The first release is pending. Until it is published, the page has no zip
   files; build from the sources instead, as [DEV.md](DEV.md) describes.

2. Download the zip for your engine and platform. The names follow the
   pattern `psychlvgl-<engine>-<platform>[-<era>].zip`:

   | Zip | For |
   |---|---|
   | `psychlvgl-matlab-windows.zip` | MATLAB R2022b and later on Windows |
   | `psychlvgl-matlab-linux.zip` | MATLAB R2022b and later on Linux |
   | `psychlvgl-matlab-macos.zip` | MATLAB R2023b and later on Apple silicon Macs |
   | `psychlvgl-octave-windows.zip` | Octave 10.x on Windows |
   | `psychlvgl-octave-linux-6.4.zip` | Octave 6.4 through 9.x on Linux |
   | `psychlvgl-octave-linux-10.zip` | Octave 10.x and later on Linux |
   | `psychlvgl-octave-macos.zip` | Homebrew Octave on Apple silicon Macs |

3. Make a new, empty folder, for example `C:\toolboxes\PsychLVGL`, and unzip
   the file into it. The zip has no top folder of its own. After the unzip,
   the folder holds:

   ```
   PsychLVGL/
     PsychLVGLSetup.m     puts PsychLVGL on the path
     dist/<arch>/         the GPU build; this is the one you use
     dist-sw/<arch>/      a software build for the test suite only
     m/                   the helper M-files, the demos and the help text
     examples/            the XML panel of PsychLVGLXMLDemo
     docs/images/         the screenshot in this file
     lv_conf.h  README.md  SPEC.md
   ```

   `<arch>` is `win64`, `glnxa64` or `maca64`. Both builds are called
   `PsychLVGL`, so only one of them can be on the path. `PsychLVGLSetup` puts
   the GPU build in `dist/<arch>` on the path. The software build in
   `dist-sw/<arch>` draws into memory, not onto the screen; the tests use it,
   and an experiment never does.

4. In MATLAB or Octave, go to that folder and run the setup:

   ```matlab
   cd C:\toolboxes\PsychLVGL
   PsychLVGLSetup
   ```

   From another folder, this line does the same:

   ```matlab
   run('C:\toolboxes\PsychLVGL\PsychLVGLSetup.m')
   ```

   `PsychLVGLSetup` adds two folders to the path: `m/` and, in front of it,
   `dist/<arch>`. It changes the path only when that order is not there yet,
   so you can call it at the top of every experiment script.

5. Check the install:

   ```matlab
   PsychLVGL('Version')
   ```

   The result is a struct. `build` must be `gl`, which is the GPU build, and
   `psychlvgl` is the version of the release. In MATLAB it looks like this:

   ```
                lvgl: '9.6.0'
           psychlvgl: '0.1.0'
       nanovgBackend: 'GL3'
           glVersion: 'unknown'
          glRenderer: 'unknown'
               build: 'gl'
   ```

   `glVersion` and `glRenderer` stay `unknown` until a panel is open.

### Keep the path for later sessions

The steps above last for one session. To keep the path, add `save`:

```matlab
cd C:\toolboxes\PsychLVGL
PsychLVGLSetup save
```

`save` runs `savepath` after the path is set. MATLAB writes its `pathdef.m`,
and Octave writes your `~/.octaverc`. If that file cannot be written, you get
a warning with a `run(...)` line. Put that line in your `startup.m` (MATLAB)
or `~/.octaverc` (Octave), or where your lab adds Psychtoolbox to the path.

Under Octave 10, do not call `addpath`, `rmpath` or `rehash` while a panel is
open or after the first `PsychLVGL` call of a session. See
[Known limits](#known-limits).

### Remove it

```matlab
PsychLVGLSetup remove          % this session only
PsychLVGLSetup remove save     % and in the saved path too
```

`remove` takes `dist/<arch>`, `dist-sw/<arch>` and `m/` of this package off
the path. Call `PsychLVGLClose(ui)` first if a panel is open. `remove` unloads
the MEX before it changes the path. If the MEX stays locked, it tells you what
to do and leaves the path as it is. If the package is not on the path,
`remove` does nothing. To delete the package, remove it, then delete its
folder.

`m/` is off the path after `remove`, so a second `PsychLVGLSetup` call must
come from the package folder or use the `run(...)` line.

## A first panel

This script puts a slider panel over a PTB stimulus. The slider sets the size
of a white disc. It runs for ten seconds.

```matlab
PsychLVGLSetup();                                   % the GPU build on the path
PsychDefaultSetup(2);
InitializeMatlabOpenGL(1);                          % before the window, not after
[win, rect] = PsychImaging('OpenWindow', max(Screen('Screens')), 0.5);
ui = PsychLVGLOpen(win, 320, 80, [20 20 340 100]);  % panel size, then where to draw it

sl = PsychLVGL('SliderCreate', PsychLVGL('ScreenActive'));
PsychLVGL('ObjSetSize', sl, 260, 20);
PsychLVGL('ObjAlign', sl, 'LV_ALIGN_CENTER', 0, 0);
PsychLVGL('SliderSetValue', sl, 50, 0);

t0 = GetSecs();
while GetSecs() - t0 < 10
    r = 20 + 4 * double(PsychLVGL('SliderGetValue', sl));
    Screen('FillOval', win, [1 1 1], CenterRect([0 0 r r], rect));
    ui = PsychLVGLFrame(ui);                         % input, update, draw the panel
    Screen('Flip', win);
end
PsychLVGLClose(ui);
sca;
```

Drag the slider with the mouse. The disc follows on the next frame. The panel
is drawn after the stimulus, so it is on top. The next sections explain each
call.

Run the script once per engine session. `sca` closes the window, and a panel
cannot draw into a second window in the same session (see
[Known limits](#known-limits)). Restart MATLAB or Octave to run it again.

## Run the demos

Two demos come with PsychLVGL. Each one opens a window and draws a Gabor patch
that a panel controls.

```matlab
PsychLVGLDemo          % the panel built with PsychLVGL calls; ESCAPE ends it
PsychLVGLXMLDemo       % the same experiment, with its panel loaded from XML
PsychLVGLDemo(3)       % runs for three seconds
```

`PsychLVGLDemo` has a contrast slider, a spatial frequency dropdown, a text
area, a chart of the contrast history and a status label. `PsychLVGLXMLDemo`
is the screenshot at the top of this file.

Both demos run from the release package. `PsychLVGLXMLDemo` loads its panel
from `examples/xml/gabor_panel/`, which is a good start for your own XML
panel.

When a demo ends, its panel closes and its window stays open. Run a demo
again, or the other demo, and it uses the same window. LVGL allows one OpenGL
context per process, so after `sca` closes the window, a panel needs a new
engine session (see [Known limits](#known-limits)).

The demo window skips the Psychtoolbox display sync tests and the startup
splash, so it opens fast on any computer. Never copy those two settings into a
real experiment.

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

`help PsychLVGL` lists every subcommand. SPEC section 5 describes them.

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

## Load an XML user interface

The LVGL editor (LVGL Pro, online or desktop) saves every screen and every
component of a project as an XML file. `PsychLVGLLoadXML` reads such a file at
run time and makes the same widgets with ordinary `PsychLVGL` calls. Nothing
is compiled, so a layout can change between two sessions of an experiment.

### Make the XML in the LVGL editor

The LVGL editor is a separate product of the LVGL project. Its Community
license is free for personal and open source use.

1. Make a project in the editor, or write the XML by hand.
2. Add a screen and put the widgets on it. Use the widgets and attributes in
   [What the loader covers](#what-the-loader-covers); anything else gives a
   warning when you load the file.
3. Give each widget that your script must read or change a `name` attribute.
   The loader returns the widget handles by that name.
4. Save the project. Keep the project folder together: the screen files, the
   component files, and `globals.xml` with the constants, styles, subjects,
   fonts and images.

### Load it

1. Open the panel, then load the screen into it:

   ```matlab
   ui = PsychLVGLOpen(win, 440, 680, [20 20 460 700]);
   [root, named] = PsychLVGLLoadXML('ui/main.xml');
   ```

   A `<screen>` fills the active screen, or the object you give as the
   second argument. A `<component>` file becomes one child of it.
2. Use the widgets by the `name` attribute they have in the XML:

   ```matlab
   PsychLVGL('LabelSetText', named.status, 'ready');
   PsychLVGL('AddToGroup', named.contrast_slider);
   ```

3. If the XML binds widgets to subjects (`bind_value`, `bind_text`,
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

### What the loader covers

| XML | Status |
|---|---|
| `lv_obj`, `lv_label`, `lv_button`, `lv_slider`, `lv_switch`, `lv_checkbox`, `lv_bar`, `lv_arc`, `lv_dropdown`, `lv_roller`, `lv_textarea`, `lv_spinbox`, `lv_table`, `lv_chart`, `lv_image` | Mapped, with their attributes, the table columns and cells, and the chart series, axes and cursors. |
| `x`, `y`, `width`, `height` (pixels, `%`, `content`), `align`, `flex_flow`, `flex_grow`, the scroll attributes, every object flag and state | Mapped. |
| Every `style_*` attribute, with parts and states after `-` or `:` (`style_bg_color-knob-pressed`) | Mapped onto the `ObjSetStyle<Prop>` setters. |
| `<consts>` and `#name`, `<styles>` with `<style name selector>` children or the `styles` attribute, `<component>` with `<api>` props, `$prop` and `<view extends>` | Mapped. Styles become style handles, shared by every widget that uses them. |
| `<fonts>` (`bin`, `tiny_ttf`, `freetype`) and built-in `lv_font_montserrat_*` names; `<images>` (`data`, `file`) | Fonts load with `FontLoad` at the declared size; images load with `imread`. |
| `<subjects>` (`int`, `float`, `string`) and the `bind_*` and `subject_*_event` elements | Kept by `PsychLVGLSubjects`, which moves values through the event ring once per frame. |
| Widgets that are not in the allowlist (button matrix, scale, keyboard, tab view, span, LED, and the others), grid track arrays, gradients, background and arc images, animations and timelines, translations, screen load events, event callbacks | Not mapped. Each gives one warning. SPEC deviation D59 has the list. |

## Known limits

- One LVGL display per process, bound to one Psychtoolbox window. LVGL 9.6
  can build its NanoVG renderer only once per process, so the MEX keeps the
  display alive across `Shutdown` and reuses it. A second OpenGL context in
  one engine session, for example after `sca` and a new `OpenWindow`, is not
  supported.
- `Shutdown` clears the widget tree and loads a new screen. It does not free
  LVGL itself.
- Under Octave 10, a change to the load path while the MEX is loaded can crash
  Octave (SPEC deviation D35). Run `PsychLVGLSetup` before the first
  `PsychLVGL` call, and do not call `addpath`, `rmpath` or `rehash` after it.
  `PsychLVGLSetup` itself is safe to call again, because it changes nothing
  when the path is already right. MATLAB and Octave 6 to 9 are not affected.
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
  `LV_NANOVG_BACKEND_GL2` and applies vendored LVGL patch 0001 (DEV.md,
  "Vendored LVGL patches"). The `smoke-gl-macos` job runs that path on
  Apple's software renderer; no accelerated Mac has run it yet.

## Requirements

- Psychtoolbox 3.0.19 or later. 3.0.22 is the version tested.
- MATLAB R2022b or later on Windows and Linux. R2023b or later on Apple
  silicon Macs, because that is the first native build. R2023a is verified on
  Windows.
- GNU Octave: 10.x on Windows (10.1 verified); 6.4 through 9.x, or 10 and
  later, on Linux, with the zip for that era; the Homebrew build
  (`brew install octave`) on Apple silicon Macs.
- Windows 10 or later, Linux, or macOS 12 or later on Apple silicon
  (`maca64`). Intel Macs are not built or tested.
- OpenGL 3.2 or later on Windows and Linux, which is what a Psychtoolbox
  window gives on a current GPU. On macOS, the OpenGL 2.1 context that
  Psychtoolbox makes.
- No compiler. A release zip holds the built MEX files. You need a compiler
  only to build from the sources ([DEV.md](DEV.md)).

## Where to go next

- [DEV.md](DEV.md): build from the sources, run the tests, continuous
  integration, the binding generator, the vendored LVGL patches.
- [SPEC.md](SPEC.md): the design reference. Read it for the marshaling
  rules, the handle model, the event model and the list of deviations.
- [RELEASING.md](RELEASING.md): how a release is made and what each zip
  holds.

## License

PsychLVGL is MIT licensed; see `LICENSE`.

LVGL and pugixml, which are compiled into the MEX, are MIT licensed; their
license texts are in `third_party/` of the source repository. The Montserrat
fonts inside LVGL are under the SIL Open Font License, and the Ubuntu font in
`examples/` is under the Ubuntu Font Licence 1.0, with its text beside it.
The LVGL editor has its own license.
