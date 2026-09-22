/**
 * @file GL/glew.h
 * Shim, not GLEW.
 *
 * LVGL's NanoVG draw unit includes <GL/glew.h> when it is not built for EGL
 * (src/draw/nanovg/lv_draw_nanovg.c), although the rest of the OpenGL driver
 * resolves its entry points through the glad loader LVGL vendors. psychlvgl
 * loads glad itself in plv_gl_loader.c, so this header points that one include
 * at glad and avoids a second GL loader in the build.
 */
#ifndef PLV_COMPAT_GL_GLEW_H
#define PLV_COMPAT_GL_GLEW_H

#include "glad/gl.h"

#endif /* PLV_COMPAT_GL_GLEW_H */
