# Releasing PsychLVGL

This is the checklist for publishing a release. A release is a `v*` git tag.
CI builds the packages, runs every test, and publishes a GitHub Release with
one zip per engine and platform. You never build release binaries by hand.

## Before you start

- `git status` is clean on `main`, and the last CI run on `main` is green:
  `gh run list --limit 1`.
- You know the new version. Before 1.0: a new subcommand or helper bumps the
  minor number, a fix bumps the patch number. A change that breaks a script
  that worked before bumps the minor number and gets a line in the release
  notes that says so.

## 1. Set the version

The version lives in one place:

| File | Line |
|---|---|
| `src/psychlvgl.c` | `#define PSYCHLVGL_VERSION "0.1.0"` |

`PsychLVGL('Version')` returns it in the `psychlvgl` field, next to the LVGL
version and the NanoVG backend. The generator does not stamp the version, so
`build gen` is not needed for a version change.

## 2. Verify locally

Run both engines. The software variant carries the headless suite; the GPU
variant must at least compile.

```
"C:\Program Files\MATLAB\R2023a\bin\matlab.exe" -batch "build test; build compile-only"
"C:\Program Files\GNU Octave\Octave-10.1.0\mingw64\bin\octave-cli.exe" --eval "build test; build compile-only"
```

Expect `==== N passed, 0 failed ====` from both, with the same N.

With Psychtoolbox installed, run the GL suite and the demo in MATLAB. They
need the GPU build on the path, in a fresh session, because the software and
GPU variants share the name `PsychLVGL`:

```
"C:\Program Files\MATLAB\R2023a\bin\matlab.exe" -batch "build test-gl"
```

```matlab
PsychLVGLDemo(5)
```

```matlab
PsychLVGLXMLDemo(5)
```

Expect `0 failed` and `DEMO_OK` with a printed Gabor standard deviation above
0.02, and the XML demo to run for five seconds with no warning. When the look
of the panel changed, run `tools/CaptureReadmeScreenshot.m` in a fresh session
with the GPU build and check that `docs/images/psychlvgl-xml-demo.png` stays
below about 400 KB. If the version bump came with new subcommands, confirm that
`m/PsychLVGL.m` was regenerated (`build gen`) so the help lists them.

## 3. Update the documents

- `SPEC.md`: the status line at the top names the phase that is implemented.
  Anything that changed against the specification gets a numbered deviation
  in section 14.
- `README.md`: new subcommands or helpers appear where their group is
  described. The install steps and the first example must still work
  with the zip layout below.
- `DEV.md`: new build options, tests or CI jobs.
- `PsychLVGLSetup.m`: after a change to `m/PsychLVGLSetup.m`, copy it over
  the root file. `tests/test_setup.m` fails when the two differ.
- `lv_conf.h`: any option you changed gets its reason in a comment; the
  software and GPU variants both read it.
- `third_party/PINS.md`: only if the LVGL submodule or the pugixml clone
  moved. A new pugixml needs `PUGIXML_COMMIT` in `.github/workflows/ci.yml`
  changed to the same commit.
- A new LVGL version can change the XML format the editor writes. Load the
  example files again (`tests/xml/lvgl_examples`, copied from the LVGL tree)
  and compare them with the new tree's `examples/**/*.xml`.
- A new LVGL version also means rerunning `build gen`, reviewing
  `gen/dropped.txt` for functions that no longer exist, and re-checking the four LVGL behaviors
  recorded as deviations D1 to D5, because they concern the experimental
  OpenGL driver. Both patches in `patches/lvgl` must still apply, and the
  private LVGL structs that D46 names must still have the fields
  `src/core/plv_assets.c` reads.

## 4. Push and wait for green

```
git add -A
git commit -m "Release v0.2.0"
git push
gh run watch
```

The release job only runs on a tag, so this push runs the matrix without
publishing. Wait for it to pass before tagging. A tag on a red commit
produces no release, because the release job needs every other job.

## 5. Tag

```
git tag -a v0.2.0 -m "PsychLVGL v0.2.0"
git push origin v0.2.0
gh run watch
```

The tag push runs the matrix again. When every job passes, the `release`
job downloads the packages, zips each one, and runs
`gh release create v0.2.0 *.zip --title "PsychLVGL v0.2.0" --generate-notes`.
The notes list the commits and pull requests since the previous tag.

## 6. Check the release

```
gh release view v0.2.0
gh release download v0.2.0 --pattern "psychlvgl-matlab-windows.zip" --dir %TEMP%\rel
```

Unzip into an empty folder and follow the install steps of `README.md`
literally, in a fresh MATLAB:

```matlab
cd <the folder>
PsychLVGLSetup
PsychLVGL('Version')
```

The `psychlvgl` field must show the new version, and `build` must be `gl`.
Then run the first example of `README.md` and, in a new session,
`PsychLVGLXMLDemo(3)` from the unzipped folder. Do the same for one Octave
zip when you changed anything Octave specific.

## What a release contains

| Zip | Built on | Runs on |
|---|---|---|
| `psychlvgl-matlab-linux.zip` | MATLAB R2022b, Ubuntu 22.04 | MATLAB R2022b and later on Linux |
| `psychlvgl-matlab-windows.zip` | MATLAB R2022b, Windows Server 2022 | MATLAB R2022b and later on Windows |
| `psychlvgl-octave-linux-6.4.zip` | Octave 6.4.0 | Octave 6.x through 9.x on Linux |
| `psychlvgl-octave-linux-10.zip` | Octave 10.1.0 | Octave 10.x and later on Linux |
| `psychlvgl-octave-windows.zip` | Octave 10.1.0 official zip | Octave 10.x on Windows |
| `psychlvgl-matlab-macos.zip` | MATLAB R2023b, `macos-latest` | MATLAB R2023b and later on Apple silicon Macs |
| `psychlvgl-octave-macos.zip` | Homebrew Octave, `macos-latest` | That Octave series on Apple silicon Macs |

Each zip holds `PsychLVGLSetup.m` at its root, `dist/<arch>/` (the GPU
build), `dist-sw/<arch>/` (the software test build), `m/` (with the XML
interpreter and the demo helpers in `m/private`), `examples/` (the panel of
`PsychLVGLXMLDemo`, with its font and the font licence),
`docs/images/psychlvgl-xml-demo.png` (so the README renders from the unzipped
folder), `lv_conf.h`, `README.md`, `SPEC.md`, and `LICENSE`, and is a complete install
for that engine and platform. The zip has no top folder, so a user unzips it
into a folder of their own; `README.md`, "Install", says so. The file list is
the `path:` list of each upload step in `.github/workflows/ci.yml`; keep the
four lists the same. Only the GPU build is meant for experiments. Both demos
run from the zip. The XML fixtures under `tests/` are not in the zips;
`PsychLVGLLoadXML` itself needs nothing from `tests/`.

The two macOS zips are built on `macos-latest`, which is Apple silicon, so
they carry `maca64` only. Intel Macs are not covered: no runner builds
`maci64`, and nothing on that architecture has been tested. The macOS jobs
block the release like every other job. The GPU path on macOS depends on the
vendored LVGL patch 0001 (`DEV.md`, "Vendored LVGL patches"); CI runs it on
Apple's software renderer, and no accelerated Mac has run it yet, so say so
when you announce a macOS build.

## If the release job fails

1. Read the failing job: `gh run view --log-failed`.
2. Fix on `main`, push, and wait for green.
3. Remove the tag and any partial release, then tag again:

```
gh release delete v0.2.0 --yes
git tag -d v0.2.0
git push --delete origin v0.2.0
git tag -a v0.2.0 -m "PsychLVGL v0.2.0"
git push origin v0.2.0
```

Do not reuse a version number for different binaries once a release with
that tag has been downloaded by anyone. Bump the patch number instead.

## Known limits of the process

- The version string is set by hand and is not derived from the tag. If they
  disagree, the tag wins for users, so check step 1.
- Release notes are generated from commit and pull request titles. Write
  titles that read well in a list.
- The release job has never run for real yet. The first tag is the first end
  to end test.
- The Octave 6.4 Docker job is slow when reproduced locally over a Windows
  bind mount (its CMake 3.16 dependency scanner). Copy the tree into the
  container first; see `DEV.md`, "Check Linux from Windows".
