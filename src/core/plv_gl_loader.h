/**
 * @file plv_gl_loader.h
 * Platform hooks for the GL entry points. Compiled only in the GL variant.
 */
#ifndef PLV_GL_LOADER_H
#define PLV_GL_LOADER_H

#ifdef __cplusplus
extern "C" {
#endif

/** @return 1 when a GL context is current on this thread. */
int plv_gl_has_context(void);

/** @return 1 on success. Safe to call more than once. */
int plv_gl_load(void);

/** @return an opaque handle for the current context, NULL when there is none.
 *  Object names belong to a context, so the display layer compares this
 *  against the context that owned the framebuffer it built. */
void * plv_gl_context(void);

#ifdef __cplusplus
}
#endif

#endif /* PLV_GL_LOADER_H */
