# Pinned dependencies

`third_party/lvgl` is a git submodule of this repository (see `.gitmodules`),
pinned at the commit below. `git clone --recurse-submodules` fetches it. The
commands further down reproduce the same commit in a checkout without
submodules; the commit is what matters, the tag is only a label.

| Dependency | Tag | Commit | Cloned on |
|---|---|---|---|
| LVGL | v9.6.0 | `80ca777e37a2b176770726a02e07a6fb79ef0b39` | 2026-09-22 |
| Tracy | not cloned | | optional, only with `PSYCHLVGL_TRACY=ON`. v0.11.1 is the version checked; `-DPSYCHLVGL_TRACY_DIR` points CMake at a checkout elsewhere |

```sh
git clone --branch v9.6.0 https://github.com/lvgl/lvgl.git third_party/lvgl
git -C third_party/lvgl checkout 80ca777e37a2b176770726a02e07a6fb79ef0b39
```

Once LVGL is a submodule, `git clone --recurse-submodules` or
`git submodule update --init --recursive` replaces the commands above, and the
commit in the table is the one the submodule points at.

The LVGL checkout carries two local patches, applied in order at configure
time by CMake or by `tools/apply_lvgl_patches.sh`:

| Patch | Files | Purpose |
|---|---|---|
| `patches/lvgl/0001-opengles-driver-gl21-glsl120.patch` | 4 | GLSL 1.20 and OpenGL 2.1 path of the OpenGL driver (SPEC D38) |
| `patches/lvgl/0002-nanovg-image-from-gl-texture.patch` | 4 | image descriptors that name an OpenGL texture, drawn by the NanoVG unit (SPEC D41) |

The submodule pointer stays at the commit above; the patches live in the
working tree only. See README, "Vendored LVGL patches".
