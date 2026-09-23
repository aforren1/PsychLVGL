# PsychLVGL for developers

This file tells you how to build PsychLVGL from the sources, run the tests,
and change the bindings. To use a release, read [README.md](README.md). For
the design, read [SPEC.md](SPEC.md). To publish a release, follow
[RELEASING.md](RELEASING.md).

## Build requirements

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
build compile-only % build the GPU variant only; what CI does, with no GPU
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
`dist/maca64`. Outside Windows the build and install directories carry it too
(`build-octave-glnxa64-sw`), so one checkout can hold a Windows build and a
WSL build at the same time. Put the right one on the path with:

```matlab
PsychLVGLSetup          % the GPU build
PsychLVGLSetup('sw')    % the software test build
```

### The two copies of PsychLVGLSetup

`PsychLVGLSetup.m` is in the repository root and in `m/`, and the two files
are identical. The root copy lets a user who just unzipped a release call it
with nothing on the path. The `m/` copy is the one scripts find once `m/` is
on the path. The file finds the package root from its own location, so either
copy puts the same folders on the path. A wrapper in the root that called the
`m/` copy by name would call itself whenever the root is the current folder,
because the current folder comes before the path. Edit `m/PsychLVGLSetup.m`
and copy it over the root file; `tests/test_setup.m` fails when they differ.

The same test covers `PsychLVGLSetup('remove')`. It is the one test that
changes the load path, so it runs last in the no-GL group: `remove` must
shut the MEX down and clear it before its first `rmpath` (SPEC D35). The
test never passes `save`, so it does not write your saved path.

### Two build variants

| Variant | Output | Renders with | Needs |
|---|---|---|---|
| GPU, the default | `dist/<arch>` | LVGL OpenGL texture driver plus the NanoVG draw unit | a current OpenGL 3.2 context, normally from `Screen('BeginOpenGL')`. On macOS the context is GL 2.1 and the build uses the NanoVG GL2 shaders; see "Known limits" in README.md |
| software, for tests | `dist-sw/<arch>` | the LVGL software draw unit into a buffer the MEX owns | nothing |

Both are called `PsychLVGL`, so only one can be on the path at a time.

### Tracy

`build.m` always configures CMake with `-DPSYCHLVGL_TRACY=OFF`. The CMake
option `PSYCHLVGL_TRACY` compiles the Tracy client into the core library, so
the MEX stays C; SPEC section 9.3 describes the zones. Tracy is not a
submodule yet. Clone it into `third_party/tracy`, or pass
`-DPSYCHLVGL_TRACY_DIR` with a checkout elsewhere:

```sh
git clone --branch v0.11.1 https://github.com/wolfpld/tracy.git third_party/tracy
```

`third_party/PINS.md` names the version that was checked. Export a capture
with `tracy-csvexport`.

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
tree. It also checks that the two copies of `PsychLVGLSetup.m` are identical.
The helpers are tested
against a Psychtoolbox stub in `tests/stub`, which records the calls and
answers them, so the suite checks that every `Screen('BeginOpenGL')` has its
`Screen('EndOpenGL')` even when the wrapped call fails. `run_tests` puts that
directory on the path once and takes it off once; no test changes the load
path, and nothing here calls `rehash`, because a path change while the MEX is
loaded can drive Octave 10 into unbounded recursion (SPEC deviation D35). The GL suite opens one 640x480 Psychtoolbox window
and checks the texture id, the rendered colors, the panel orientation, a click,
a resize, a chart, a style, a texture image, a TTF label, and an XML screen.

The GL tests and the perf script open their window through
`tests/gl/ptb_test_window.m`. The two demos use
`m/private/psychlvgl_demo_window.m`, a copy under a name that cannot shadow
it, so they run from a release package and never change the path. These are
the only places that set
`Screen('Preference', 'SkipSyncTests', 2)` and
`Screen('Preference', 'VisualDebugLevel', 0)`, so repeated runs skip the
display sync calibration and the startup splash. Never use those settings for
a real experiment session. Both helpers also cache the window, because LVGL
allows only one OpenGL context per process. The demos close their panel and
keep the window, so they can run again in one session.
`m/private/psychlvgl_gabor_std.m` and `psychlvgl_gabor_michelson.m` are the
demo copies of `tests/gl/gabor_std.m` and `gabor_michelson.m`. Change both
copies together.

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

### Check Linux from Windows

Some faults show only on Linux, where glibc is stricter about freed memory
(SPEC deviation D48). Run the no-GL suite under WSL with the Ubuntu Octave
(6.4 on Ubuntu 22.04) on the same checkout. It needs `cmake`,
`build-essential` and `libgl1-mesa-dev` in WSL:

```sh
wsl -d Ubuntu -- bash -lc 'cd /mnt/c/path/to/PsychLVGL && octave-cli --eval "build test"'
```

The build lands in `build-octave-glnxa64-sw` and `dist-sw/glnxa64`, next to
the Windows build.

To reproduce one of the `octave-build` CI jobs exactly, use its Docker image.
Copy the tree into the container first: over a Windows bind mount, the
CMake 3.16 dependency scanner of the 6.4 image is very slow.

```sh
docker run --rm -v "$PWD:/src:ro" gnuoctave/octave:6.4.0 bash -c '
  cp -r /src /work && cd /work
  apt-get update && apt-get install -y --no-install-recommends cmake build-essential libgl1-mesa-dev
  octave --no-gui --eval "build test"'
```

## Measure performance

`perf/PsychLVGLPerf` sweeps panel sizes and widget counts and prints the
Update times together with the cost of the two Psychtoolbox context switches.
It needs Psychtoolbox and the GPU build. SPEC section 9.4 lists the numbers to
look at first. For a timeline of one frame, build with Tracy (see
[Tracy](#tracy)).

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
only its own `dist/<arch>` and `dist-sw/<arch>`, plus `PsychLVGLSetup.m` at
the root, `m/` (with the XML interpreter in `m/private`), `lv_conf.h`,
`README.md` and `SPEC.md`, the demo panel in `examples/`, and the README
screenshot `docs/images/psychlvgl-xml-demo.png`. The XML fixtures under
`tests/xml` are not packaged. The release job zips each artifact as it is,
so these paths are the layout a user gets after the unzip. A file that the
install steps in README.md name must be in every `path:` list.

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

## The XML interpreter

`PsychLVGLLoadXML` and `PsychLVGLXMLToM` share one interpreter,
`m/private/plv_xml_run.m`. It reads the tree that `PsychLVGL('ParseXML')`
returns and calls an emitter for every change: `plv_xml_emit_exec` calls
`PsychLVGL` at once, and `plv_xml_emit_write` appends M code. The private
folder must stay next to the M-files in `m/`, because only those files can
call it. SPEC deviations D55 to D59 have the rules.

## Layout

```
PsychLVGL/
  PsychLVGLSetup.m      the same file as m/PsychLVGLSetup.m, for a fresh unzip
  build.m               MATLAB and Octave build driver
  CMakeLists.txt        LVGL and the core library, the smoke test, optional Tracy
  lv_conf.h             the LVGL configuration of both variants
  src/                  the MEX and the core library; *_gen.c and *_enums.c are generated
  m/                    the help text, the helper M-files, the demos
  m/private/            the XML interpreter and the demo window and Gabor helpers
  examples/xml/         the demo panel, shipped: gabor_panel.xml, globals.xml, stat_tile.xml, fonts/
  gen/                  the binding generator
  tests/                run_tests.m, the no-GL suite, tests/gl, tests/stub, tests/native, tests/xml
  perf/                 PsychLVGLPerf.m
  tools/                apply_lvgl_patches.sh, CaptureReadmeScreenshot.m
  patches/lvgl/         the vendored LVGL patches
  docs/images/          the README screenshot, shipped
  third_party/          lvgl (submodule), pugixml, PINS.md
```

SPEC section 10.1 has the file by file list.

## Releasing

A release is a `v*` tag; CI builds and publishes the packages. The
step-by-step checklist, including where the version string lives and how to
recover from a failed release job, is in [RELEASING.md](RELEASING.md).
