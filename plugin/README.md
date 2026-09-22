# plugin

Where an LVGL Pro C export goes. Phase 3, see SPEC.md section 13.

The editor or CLI writes `<name>_gen.c` and `<name>_gen.h` for each screen or
component. Copy that pair into this folder. `.gitignore` excludes
`plugin/*_gen.c` and `plugin/*_gen.h`, because the export belongs to whoever
designed the user interface, not to this repository. Only the hand-written
`plugin_table.c` and this file are tracked.

`build.m plugin <dir>` will copy the export in, compile it together with a
`plugin_table.c` that holds the `{name, create_fn}` and `{name, lv_subject_t*}`
arrays, and link the result into the MEX. The export includes
`lvgl_private.h`, so it has to be compiled against the same LVGL tree and the
same `lv_conf.h` as the rest of the binding, which is why it is built here
rather than loaded at run time. A change to the user interface needs a rebuild.

None of this is implemented yet: `build.m plugin` is not a valid action in
phase 1.
