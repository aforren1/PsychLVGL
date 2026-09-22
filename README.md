# psychlvgl

`psychlvgl` is a MEX binding of LVGL 9.6 for MATLAB and GNU Octave. It draws
retained mode GUI panels inside a Psychtoolbox (PTB) onscreen window. LVGL
renders on the GPU with its NanoVG draw unit into an OpenGL texture. PTB draws
that texture like any other PTB texture, so no pixels cross the CPU.

`SPEC.md` is the design reference. Read it for the marshaling rules, the handle
model and the event model. This file tells you how to build, test and run.

## Requirements

| Item | Version |
|---|---|
| MATLAB | R2023a verified, R2019b or later expected |
| GNU Octave | 10.1 verified on Windows, 6.4 verified on Linux (WSL, Ubuntu 22.04) |
| CMake | 3.16 or later |
| C compiler | MSVC 2022 for MATLAB on Windows, the MinGW gcc that Octave ships, gcc or clang elsewhere |
| Psychtoolbox | 3.0.19 or later, only for the GPU build and the demo |
| Python and uv | only to regenerate the bindings |

## Get the sources

LVGL is a submodule, so clone with it:

```sh
git clone --recurse-submodules <repo-url> PsychLVGL
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

`third_party/PINS.md` records the exact commit either way.

## Build

From the `psychlvgl` folder:

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
| GPU, the default | `dist/<arch>` | LVGL OpenGL texture driver plus the NanoVG draw unit | a current OpenGL 3.2 context, normally from `Screen('BeginOpenGL')` |
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
and argument errors, the tick, every generated subcommand, and a CRC32 of the
rendered software buffer. The GL suite opens one 640x480 Psychtoolbox window
and checks the texture id, the rendered colors, the panel orientation, a click,
and a resize.

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
framebuffer object, and prints the Update times.

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

```matlab
PsychLVGLSetup();
InitializeMatlabOpenGL(1);
[win, winRect] = PsychImaging('OpenWindow', screenid, 0);

panelW = 400; panelH = 600;
dst = [20 20 20+panelW 20+panelH];
panel = PsychLVGLFrame('Open', win, dst, panelW, panelH);
kq = PsychLVGLInput('Start', win);

scr = PsychLVGL('ScreenActive');
sl = PsychLVGL('SliderCreate', scr);
PsychLVGL('ObjSetSize', sl, 300, 20);
PsychLVGL('ObjAlign', sl, 'LV_ALIGN_CENTER', 0, 0);
PsychLVGL('AddToGroup', sl);

while running
    [E, panel] = PsychLVGLFrame('Update', panel, kq);
    S = PsychLVGLEvents('decode', E);
    % ... read S(k).target, S(k).name, S(k).param ...
    Screen('Flip', win);
end

PsychLVGLInput('Stop', kq);
PsychLVGLFrame('Close', panel);
```

`PsychLVGLDemo` is a working example: a Gabor patch whose contrast follows a
slider, with a dropdown, a text area and a status label.

`PsychLVGLPerf` sweeps panel sizes and widget counts and prints the Update
times together with the cost of the two Psychtoolbox context switches.

## Continuous integration

`.github/workflows/ci.yml` builds and tests the project on every push and
pull request, and publishes a release on a `v*` tag. Checkout is
`submodules: recursive`, and a "Fetch LVGL" step clones the pinned commit when
the submodule is not there.

Jobs:

| Job | What it does |
|---|---|
| `matlab-build` | MATLAB R2022b on Ubuntu and Windows: software variant, `run_tests sw`, then the GPU variant compile only. Uploads `dist-sw/<arch>` and `dist/<arch>`. |
| `matlab-test-forward` | The newest MATLAB runs the binaries the floor release built, with no rebuild. |
| `octave-build` | `gnuoctave/octave` Docker images, one per binary compatible era (6.4 and 10.1). Same two builds and the same test run. |
| `octave-test-forward` | Newer Octave versions run each era's binary. |
| `octave-windows` | MSYS2 with `MEX_CMAKE_GENERATOR=Ninja`. |
| `smoke-gl-linux` | Builds and runs `smoke_gl` under Xvfb and Mesa llvmpipe. This is the only automated coverage of the NanoVG path, because no runner has a GPU. |
| `release` | On a `v*` tag, zips each artifact and publishes a GitHub Release. |

Artifacts are named `psychlvgl-<engine>-<platform>[-<era>]` and each one holds
only its own `dist/<arch>` and `dist-sw/<arch>`, plus `m/`, `lv_conf.h`,
`README.md` and `SPEC.md`.

## Regenerating the bindings

`src/psychlvgl_gen.c`, `src/psychlvgl_enums.c`, `m/PsychLVGL.m`,
`m/PsychLVGLOp.m` and `tests/test_gen_marshal.m` are generated from the LVGL
headers and committed, so a normal build needs no Python.

```sh
uv run --project gen gen/generate.py
```

`gen/allowlist.toml` chooses the functions. `gen/dropped.txt` lists the
allowlisted functions whose signatures the phase 1 marshaling rules cannot
express.

## Known limits

- One LVGL display per process, bound to one Psychtoolbox window. LVGL 9.6
  can build its NanoVG renderer only once per process, so the MEX keeps the
  display alive across `Shutdown` and reuses it. A second OpenGL context in
  one engine session, for example after `sca` and a new `OpenWindow`, is not
  supported.
- `Shutdown` clears the widget tree and loads a new screen. It does not free
  LVGL itself.
- Style properties that need a pointer argument, images, charts, `lv_style_t`
  handles and TTF fonts are phase 2. See `gen/dropped.txt`.
