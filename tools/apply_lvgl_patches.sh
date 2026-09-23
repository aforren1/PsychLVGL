#!/usr/bin/env bash
#
# Apply the vendored LVGL patches in patches/lvgl to third_party/lvgl.
#
# CMake does the same at configure time, so a normal build never needs this
# script. It exists for a shell that wants the patched tree before configuring,
# for example the CI host step that runs before the Octave Docker containers,
# and for reading: the patch is the only local change to LVGL, and this is how
# it gets there. Idempotent: a patch that is already present is skipped.
#
#   bash tools/apply_lvgl_patches.sh [repo_root]

set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
lvgl="$root/third_party/lvgl"

if [ ! -f "$lvgl/lvgl.h" ]; then
    echo "third_party/lvgl is empty; fetch the submodule first" >&2
    exit 1
fi

for p in "$root"/patches/lvgl/*.patch; do
    if git -C "$lvgl" apply --check --reverse "$p" >/dev/null 2>&1; then
        echo "already applied: $(basename "$p")"
        continue
    fi
    git -C "$lvgl" apply "$p"
    echo "applied: $(basename "$p")"
done
