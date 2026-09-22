/**
 * @file plv_display.c
 * Every lv_opengles_* call, the flush callback, and the Update render step.
 * LVGL documents the OpenGL driver API as experimental, so keeping the calls
 * in one file means an API change touches one place.
 *
 * Why this file owns an FBO
 * -------------------------
 * With LV_USE_DRAW_NANOVG the texture driver does not route the root layer to
 * the display texture: lv_opengles_texture_attach_to_display skips the
 * assignment, the root layer keeps user_data == NULL, and the NanoVG draw unit
 * then calls nvgluBindFramebuffer(NULL), which binds whatever framebuffer was
 * current the first time that function ran. Left alone, LVGL would draw into
 * the caller's framebuffer, not into a texture, and Init could not return a
 * texture id.
 *
 * So this file creates the texture, wraps it in its own framebuffer object
 * with a stencil attachment (NanoVG needs stencil for concave fills), and
 * binds that framebuffer before every lv_timer_handler. NanoVG then caches
 * our framebuffer as its "default" and every frame lands in the texture.
 *
 * The framebuffer object is created once per process and never deleted, which
 * keeps NanoVG's cached name valid across a Shutdown and a second Init. A new
 * GL context invalidates the name; plv_display_create notices that and tries
 * to reclaim the same name, which a compatibility profile allows.
 */
#include "plv_internal.h"
#include "plv_gl_loader.h"

#if defined(_WIN32)
#include <windows.h>
#endif

#include "glad/gl.h"
#include "lvgl/drivers/opengles/lv_opengles_driver.h"
#include "lvgl/drivers/opengles/lv_opengles_texture.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static GLuint s_fbo;          /* kept for the process lifetime, see above */
static GLuint s_wanted_fbo;   /* the name NanoVG cached as its default target */
static GLuint s_stencil_rbo;
static GLint  s_rbo_w, s_rbo_h;
static void * s_ctx;          /* the context those names belong to */
static lv_display_t * s_disp; /* outlives Shutdown, see plv_display_destroy */
static unsigned int s_tex;
static int32_t s_disp_w, s_disp_h;
/* NanoVG renders on the GPU and never fills this, but LVGL still sizes a draw
 * buffer from the resolution and parts of it copy through that buffer. LVGL's
 * own texture driver passes a one word placeholder, which overflows as soon as
 * the resolution changes, so psychlvgl gives it a real allocation. */
static uint8_t * s_draw_buf;
static size_t    s_draw_buf_size;
static char   s_gl_version[128];
static char   s_gl_renderer[128];

static int plv_set_draw_buf(lv_display_t * disp, int32_t w, int32_t h, plv_err_t * err)
{
    lv_color_format_t cf = lv_display_get_color_format(disp);
    size_t need = (size_t)lv_draw_buf_width_to_stride((uint32_t)w, cf) * (size_t)h;

    if(need > s_draw_buf_size) {
        uint8_t * p = (uint8_t *)realloc(s_draw_buf, need);
        if(!p) return plv_fail(err, "psychlvgl:GLInit", "out of memory for the draw buffer");
        s_draw_buf = p;
        s_draw_buf_size = need;
    }
    memset(s_draw_buf, 0, need);
    lv_display_set_buffers(disp, s_draw_buf, NULL, (uint32_t)need,
                           LV_DISPLAY_RENDER_MODE_DIRECT);
    return 0;
}


int plv_display_is_persistent(void)
{
    return 1;
}

int plv_display_check_context(plv_err_t * err)
{
    if(plv_gl_has_context()) return 0;
    return plv_fail(err, "psychlvgl:NoGLContext",
                    "no OpenGL context is current; wrap the call in "
                    "Screen('BeginOpenGL', win) and Screen('EndOpenGL', win)");
}

static const char * plv_gl_error_name(GLenum e)
{
    switch(e) {
        case GL_INVALID_ENUM:      return "GL_INVALID_ENUM";
        case GL_INVALID_VALUE:     return "GL_INVALID_VALUE";
        case GL_INVALID_OPERATION: return "GL_INVALID_OPERATION";
        case GL_OUT_OF_MEMORY:     return "GL_OUT_OF_MEMORY";
        case GL_INVALID_FRAMEBUFFER_OPERATION: return "GL_INVALID_FRAMEBUFFER_OPERATION";
        case GL_STACK_OVERFLOW:    return "GL_STACK_OVERFLOW";
        case GL_STACK_UNDERFLOW:   return "GL_STACK_UNDERFLOW";
        default:                   return "GL_UNKNOWN_ERROR";
    }
}

static void plv_gl_drain(void)
{
    int guard;
    for(guard = 0; guard < 64; guard++)
        if(glGetError() == GL_NO_ERROR) return;
}

static int plv_gl_version_at_least(int major, int minor)
{
    int gl_major = 0, gl_minor = 0;
    if(sscanf(s_gl_version, "%d.%d", &gl_major, &gl_minor) != 2) return 0;
    if(gl_major > major) return 1;
    return gl_major == major && gl_minor >= minor;
}

static unsigned int plv_create_texture(int32_t w, int32_t h)
{
    GLuint tex = 0;
    glGenTextures(1, &tex);
    if(tex == 0) return 0;
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, (GLsizei)w, (GLsizei)h, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glBindTexture(GL_TEXTURE_2D, 0);
    return tex;
}

static int plv_attach_fbo(unsigned int tex, int32_t w, int32_t h, plv_err_t * err)
{
    GLint saved = 0;
    GLenum status;

    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved);

    if(s_fbo == 0 && s_wanted_fbo != 0 && !glIsFramebuffer(s_wanted_fbo)) {
        /* A second GL context in the same process starts with an empty name
         * space, but NanoVG still holds the framebuffer name it cached in the
         * first one. A compatibility profile creates the object on first bind,
         * which is how the same name can be reclaimed here. The glIsFramebuffer
         * guard keeps this from stealing a name the context owner already uses. */
        glBindFramebuffer(GL_FRAMEBUFFER, s_wanted_fbo);
        if(glGetError() == GL_NO_ERROR && glIsFramebuffer(s_wanted_fbo))
            s_fbo = s_wanted_fbo;
    }
    if(s_fbo == 0) glGenFramebuffers(1, &s_fbo);
    if(s_wanted_fbo == 0) s_wanted_fbo = s_fbo;
    if(s_fbo != s_wanted_fbo && g_plv.print_fn) {
        g_plv.print_fn("psychlvgl: a second OpenGL context could not reuse the "
                       "framebuffer name NanoVG cached, so the panel may stay "
                       "blank. Restart the engine between windows.\n");
    }
    if(s_stencil_rbo == 0) glGenRenderbuffers(1, &s_stencil_rbo);
    if(s_fbo == 0 || s_stencil_rbo == 0) {
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);
        return plv_fail(err, "psychlvgl:GLInit", "could not create a framebuffer object");
    }

    glBindFramebuffer(GL_FRAMEBUFFER, s_fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);

    if(s_rbo_w != w || s_rbo_h != h) {
        glBindRenderbuffer(GL_RENDERBUFFER, s_stencil_rbo);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_STENCIL_INDEX8, (GLsizei)w, (GLsizei)h);
        s_rbo_w = w;
        s_rbo_h = h;
    }
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_STENCIL_ATTACHMENT, GL_RENDERBUFFER,
                              s_stencil_rbo);

    status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if(status != GL_FRAMEBUFFER_COMPLETE) {
        /* Some drivers refuse a stencil-only renderbuffer and want a packed
         * depth-stencil instead. */
        glBindRenderbuffer(GL_RENDERBUFFER, s_stencil_rbo);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH24_STENCIL8, (GLsizei)w, (GLsizei)h);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_STENCIL_ATTACHMENT,
                                  GL_RENDERBUFFER, s_stencil_rbo);
        status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    }
    glBindRenderbuffer(GL_RENDERBUFFER, 0);

    if(status != GL_FRAMEBUFFER_COMPLETE) {
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);
        return plv_fail(err, "psychlvgl:GLInit",
                        "framebuffer is incomplete (status 0x%04X); the context needs a "
                        "stencil capable render target", (unsigned)status);
    }

    /* Start from a transparent panel so the first frame has no garbage. */
    glViewport(0, 0, (GLsizei)w, (GLsizei)h);
    glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
    glClearStencil(0);
    glClear(GL_COLOR_BUFFER_BIT | GL_STENCIL_BUFFER_BIT);

    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);
    return 0;
}

int plv_display_create(int32_t w, int32_t h, plv_err_t * err)
{
    unsigned int tex;
    const char * s;
    GLint saved = 0;

    if(!plv_gl_load())
        return plv_fail(err, "psychlvgl:GLInit",
                        "gladLoadGL could not resolve the OpenGL entry points");

    /* Object names belong to a context. A new one, for example after the
     * Psychtoolbox window was closed and reopened, invalidates everything this
     * file kept, so drop the names instead of binding them. */
    if(s_ctx != NULL && s_ctx != plv_gl_context()) {
        s_fbo = 0;
        s_stencil_rbo = 0;
        s_rbo_w = 0;
        s_rbo_h = 0;
    }
    s_ctx = plv_gl_context();

    s = (const char *)glGetString(GL_VERSION);
    snprintf(s_gl_version, sizeof(s_gl_version), "%s", s ? s : "unknown");
    s = (const char *)glGetString(GL_RENDERER);
    snprintf(s_gl_renderer, sizeof(s_gl_renderer), "%s", s ? s : "unknown");

#if LV_NANOVG_BACKEND == LV_NANOVG_BACKEND_GL2
    if(!plv_gl_version_at_least(2, 1))
        return plv_fail(err, "psychlvgl:GLInit",
                        "the GL2 NanoVG backend needs OpenGL 2.1 or later, context reports %s",
                        s_gl_version);
#else
    if(!plv_gl_version_at_least(3, 2))
        return plv_fail(err, "psychlvgl:GLInit",
                        "the GL3 NanoVG backend needs OpenGL 3.2 or later, context reports %s",
                        s_gl_version);
#endif

    plv_gl_drain();

    tex = plv_create_texture(w, h);
    if(tex == 0)
        return plv_fail(err, "psychlvgl:GLInit", "could not create the panel texture");

    if(plv_attach_fbo(tex, w, h, err)) {
        GLuint t = tex;
        glDeleteTextures(1, &t);
        return 1;
    }

    /* NanoVG caches the framebuffer that is current when it first binds its
     * "default" target, so ours has to be bound across LVGL's GL setup. */
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved);
    glBindFramebuffer(GL_FRAMEBUFFER, s_fbo);

    /* The display has to exist before the NanoVG draw unit does. LVGL creates
     * the root layer inside lv_display_create and sends LV_EVENT_CHILD_CREATED
     * to every draw unit that already exists; the NanoVG unit answers that by
     * handing the layer a framebuffer from its own cache. A root layer with a
     * cache framebuffer is never copied anywhere, so the panel texture would
     * stay empty. Created in this order the root layer keeps user_data NULL,
     * which routes it to NanoVG's default target, which is our framebuffer.
     * lv_opengles_texture_create_from_texture_id calls lv_opengles_init itself
     * at the end, so the call below only reports whether that succeeded. */
    g_plv.disp = lv_opengles_texture_create_from_texture_id(w, h, tex);
    if(!g_plv.disp) {
        GLuint t = tex;
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);
        glDeleteTextures(1, &t);
        return plv_fail(err, "psychlvgl:GLInit", "lv_opengles_texture_create failed");
    }

    if(lv_opengles_init() != LV_RESULT_OK) {
        GLuint t = tex;
        lv_display_delete(g_plv.disp);
        g_plv.disp = NULL;
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);
        glDeleteTextures(1, &t);
        return plv_fail(err, "psychlvgl:GLInit",
                        "lv_opengles_init failed on a %s context (%s); the LVGL log above "
                        "holds the GLSL version it asked for",
                        s_gl_version, s_gl_renderer);
    }

    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);

    /* Screen('EndOpenGL') aborts the script on any pending error, including one
     * this setup left behind, so report and clear it here rather than let it
     * surface later as a failure with no cause attached. */
    {
        GLenum e = glGetError();
        if(e != GL_NO_ERROR && g_plv.print_fn) {
            char buf[160];
            snprintf(buf, sizeof(buf),
                     "psychlvgl: OpenGL reported %s during Init; cleared.\n",
                     plv_gl_error_name(e));
            g_plv.print_fn(buf);
        }
        plv_gl_drain();
    }

    if(plv_set_draw_buf(g_plv.disp, w, h, err)) return 1;

    g_plv.texture_id = tex;
    s_disp   = g_plv.disp;
    s_tex    = tex;
    s_disp_w = w;
    s_disp_h = h;
    return 0;
}

/* Shutdown keeps the display, the texture, the framebuffer object and the
 * NanoVG draw unit: LVGL cannot build a second NanoVG unit in one process, and
 * the root layer only renders into our framebuffer when it was created before
 * any draw unit existed. Both facts make the display a process-wide resource.
 * The caller clears the widget tree instead. */
void plv_display_destroy(void)
{
    if(plv_gl_has_context() && plv_gl_context() == s_ctx) {
        /* The panel texture goes at Shutdown, even though the display stays.
         * A script that wrapped it with Screen('SetOpenGLTexture') closes the
         * Psychtoolbox texture next, and Psychtoolbox deletes the OpenGL name
         * with it, so keeping the name here would leave the next session
         * rendering into a texture that no longer exists. The next Init makes
         * a fresh one. */
        GLint saved = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved);
        if(s_fbo) {
            glBindFramebuffer(GL_FRAMEBUFFER, s_fbo);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, 0, 0);
            glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);
        }
        if(s_tex) {
            GLuint t = (GLuint)s_tex;
            glDeleteTextures(1, &t);
        }
        plv_gl_drain();
    }
    else if(g_plv.print_fn) {
        g_plv.print_fn("psychlvgl: shutdown with no current GL context; "
                       "the texture and shaders are left to the context owner.\n");
    }

    s_tex = 0;
    s_disp_w = 0;
    s_disp_h = 0;
    g_plv.disp = NULL;
    g_plv.texture_id = 0;
}

int plv_display_resize(int32_t w, int32_t h, plv_err_t * err)
{
    unsigned int tex;
    GLuint old;

    if(!s_disp)
        return plv_fail(err, "psychlvgl:NotInitialized", "there is no display to resize");

    if(w == s_disp_w && h == s_disp_h) {
        g_plv.disp = s_disp;
        g_plv.texture_id = s_tex;
        return 0;
    }

    tex = plv_create_texture(w, h);
    if(tex == 0)
        return plv_fail(err, "psychlvgl:GLInit", "could not create the panel texture");
    if(plv_attach_fbo(tex, w, h, err)) {
        GLuint t = tex;
        glDeleteTextures(1, &t);
        return 1;
    }

    old = (GLuint)s_tex;
    if(old) glDeleteTextures(1, &old);
    s_tex = tex;
    s_disp_w = w;
    s_disp_h = h;

    lv_display_set_resolution(s_disp, w, h);
    if(plv_set_draw_buf(s_disp, w, h, err)) return 1;
    g_plv.disp = s_disp;
    g_plv.texture_id = tex;
    plv_gl_drain();
    return 0;
}

int plv_display_frame_begin(plv_err_t * err)
{
    LV_UNUSED(err);

    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &g_plv.saved_fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, s_fbo);
    glViewport(0, 0, (GLsizei)g_plv.w, (GLsizei)g_plv.h);

    /* Psychtoolbox and any other code between frames changes the GL state
     * this driver relies on, so put its own bindings back. */
    lv_opengles_reinit_state();
    return 0;
}

int plv_display_frame_end(plv_err_t * err)
{
    GLenum e;

    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)g_plv.saved_fbo);

    /* Screen('EndOpenGL') aborts the script on a pending error, so drain here
     * and name the error while the cause is still known. */
    e = glGetError();
    if(e != GL_NO_ERROR) {
        plv_gl_drain();
        return plv_fail(err, "psychlvgl:GLError",
                        "OpenGL reported %s during Update", plv_gl_error_name(e));
    }
    return 0;
}

void plv_display_flush_cb(lv_display_t * disp, const lv_area_t * area, uint8_t * px_map)
{
    LV_UNUSED(area);
    LV_UNUSED(px_map);
    /* NanoVG has already rendered into the texture; nothing to copy. */
    g_plv.dirty = 1;
    g_plv.stats.flush_count++;
    lv_display_flush_ready(disp);
}

const char * plv_gl_version_string(void)
{
    return s_gl_version[0] ? s_gl_version : "unknown";
}

const char * plv_gl_renderer_string(void)
{
    return s_gl_renderer[0] ? s_gl_renderer : "unknown";
}

unsigned int plv_display_fbo(void)
{
    return s_fbo;
}

uint32_t plv_frame_checksum(void)
{
    return 0;   /* only the software variant has a buffer to checksum */
}
