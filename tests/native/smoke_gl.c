/**
 * @file smoke_gl.c
 * Native smoke test for the OpenGL and NanoVG path.
 *
 * Psychtoolbox is the normal host for that path, so without it nothing else
 * exercises NanoVG. This program creates a legacy compatibility context of the
 * kind Psychtoolbox gives the MEX (WGL behind a hidden window on Windows, GLX
 * behind a mapped window on X11, a drawable-less CGL context on macOS) and
 * drives the core layer directly: load GL, init, create widgets, run Update
 * cycles with synthetic input, read the texture back through a framebuffer
 * object, and shut down. A second scene covers the phase 2 draw paths: a
 * shared style, a chart, an image drawn straight from an OpenGL texture, and
 * a label in a TTF font.
 *
 * It links plv_core only, never MATLAB.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#include <windows.h>
#endif

#include "glad/gl.h"
#include "plv_core.h"
#include "plv_gl_loader.h"

static int failures;

static void check(const char * what, int ok)
{
    printf("%-48s %s\n", what, ok ? "ok" : "FAIL");
    if(!ok) failures++;
}

static void print_line(const char * text)
{
    fputs(text, stdout);
}

#if defined(_WIN32)

static HWND  s_wnd;
static HDC   s_dc;
static HGLRC s_rc;

static int make_context(void)
{
    WNDCLASSA wc;
    PIXELFORMATDESCRIPTOR pfd;
    int format;

    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc   = DefWindowProcA;
    wc.hInstance     = GetModuleHandleA(NULL);
    wc.lpszClassName = "plv_smoke";
    wc.style         = CS_OWNDC;
    if(!RegisterClassA(&wc)) return 0;

    /* Hidden: the test reads pixels from a framebuffer object, never from the
     * window, so nothing has to be visible. */
    s_wnd = CreateWindowA("plv_smoke", "plv_smoke", WS_OVERLAPPEDWINDOW,
                          0, 0, 640, 480, NULL, NULL, wc.hInstance, NULL);
    if(!s_wnd) return 0;
    s_dc = GetDC(s_wnd);
    if(!s_dc) return 0;

    memset(&pfd, 0, sizeof(pfd));
    pfd.nSize      = sizeof(pfd);
    pfd.nVersion   = 1;
    pfd.dwFlags    = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    format = ChoosePixelFormat(s_dc, &pfd);
    if(!format || !SetPixelFormat(s_dc, format, &pfd)) return 0;

    /* wglCreateContext, not wglCreateContextAttribsARB: Psychtoolbox does the
     * same on Windows, so the driver hands back its highest compatibility
     * profile and the test runs on the context the MEX will really see. */
    s_rc = wglCreateContext(s_dc);
    if(!s_rc) return 0;
    return wglMakeCurrent(s_dc, s_rc) ? 1 : 0;
}

static void drop_context(void)
{
    wglMakeCurrent(NULL, NULL);
    if(s_rc) wglDeleteContext(s_rc);
    if(s_wnd && s_dc) ReleaseDC(s_wnd, s_dc);
    if(s_wnd) DestroyWindow(s_wnd);
}

#elif defined(__APPLE__)

#include <OpenGL/OpenGL.h>
#include <OpenGL/CGLRenderers.h>   /* kCGLRendererGenericFloatID */

static CGLContextObj s_cgl;

/* No drawable and no window: everything this test looks at goes through a
 * framebuffer object, and a CGL context with no drawable still renders into
 * one. That is also the only headless OpenGL a macOS runner offers. */
static CGLContextObj plv_make_cgl(int software)
{
    CGLPixelFormatAttribute attrs[12];
    CGLPixelFormatObj pix = NULL;
    CGLContextObj ctx = NULL;
    GLint npix = 0;
    int n = 0;

    /* No kCGLPFAOpenGLProfile attribute at all. Asking for a profile on macOS
     * gives a 3.2 core context, which has no fixed function pipeline and no
     * GLSL 1.20; Psychtoolbox asks for neither, so it gets the legacy 2.1
     * compatibility context this build targets with LV_NANOVG_BACKEND_GL2. */
    attrs[n++] = kCGLPFAColorSize;
    attrs[n++] = (CGLPixelFormatAttribute)24;
    attrs[n++] = kCGLPFAAlphaSize;
    attrs[n++] = (CGLPixelFormatAttribute)8;
    attrs[n++] = kCGLPFADepthSize;
    attrs[n++] = (CGLPixelFormatAttribute)24;
    if(software) {
        /* The Apple software renderer. A GitHub macOS runner is a virtual
         * machine, so the accelerated renderer may not be reachable. */
        attrs[n++] = kCGLPFARendererID;
        attrs[n++] = (CGLPixelFormatAttribute)kCGLRendererGenericFloatID;
    }
    else {
        attrs[n++] = kCGLPFAAccelerated;
    }
    attrs[n++] = (CGLPixelFormatAttribute)0;

    if(CGLChoosePixelFormat(attrs, &pix, &npix) != kCGLNoError || pix == NULL) return NULL;
    if(CGLCreateContext(pix, NULL, &ctx) != kCGLNoError) ctx = NULL;
    CGLDestroyPixelFormat(pix);
    return ctx;
}

static int make_context(void)
{
    s_cgl = plv_make_cgl(0);
    if(!s_cgl) {
        printf("no accelerated CGL pixel format; falling back to the software renderer\n");
        s_cgl = plv_make_cgl(1);
    }
    if(!s_cgl) {
        printf("CGLCreateContext failed for both renderers\n");
        return 0;
    }
    return CGLSetCurrentContext(s_cgl) == kCGLNoError ? 1 : 0;
}

static void drop_context(void)
{
    CGLSetCurrentContext(NULL);
    if(s_cgl) {
        CGLDestroyContext(s_cgl);
        s_cgl = NULL;
    }
}

#else

#include <X11/Xlib.h>
#include <GL/glx.h>

static Display  * s_dpy;
static Window     s_win;
static GLXContext s_ctx;

static int make_context(void)
{
    /* GLX 1.2 visual selection and a legacy context: that is what
     * Psychtoolbox gives the MEX, and it is also all that Mesa's llvmpipe
     * needs under Xvfb, where this runs in CI. */
    static int rich[] = {
        GLX_RGBA, GLX_DOUBLEBUFFER,
        GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, GLX_ALPHA_SIZE, 8,
        GLX_DEPTH_SIZE, 24, GLX_STENCIL_SIZE, 8,
        None
    };
    /* The panel has its own framebuffer object with its own stencil buffer, so
     * the window visual only has to be RGB. */
    static int plain[] = { GLX_RGBA, GLX_RED_SIZE, 8, GLX_GREEN_SIZE, 8,
                           GLX_BLUE_SIZE, 8, None };
    XVisualInfo * vi;
    XSetWindowAttributes swa;

    s_dpy = XOpenDisplay(NULL);
    if(!s_dpy) {
        printf("no X display; set DISPLAY or run under xvfb-run\n");
        return 0;
    }
    vi = glXChooseVisual(s_dpy, DefaultScreen(s_dpy), rich);
    if(!vi) vi = glXChooseVisual(s_dpy, DefaultScreen(s_dpy), plain);
    if(!vi) {
        printf("no usable GLX visual\n");
        return 0;
    }

    memset(&swa, 0, sizeof(swa));
    swa.colormap = XCreateColormap(s_dpy, RootWindow(s_dpy, vi->screen),
                                   vi->visual, AllocNone);
    swa.event_mask = StructureNotifyMask;
    s_win = XCreateWindow(s_dpy, RootWindow(s_dpy, vi->screen), 0, 0, 640, 480, 0,
                          vi->depth, InputOutput, vi->visual,
                          CWColormap | CWEventMask, &swa);
    if(!s_win) return 0;

    /* Mapped, not shown: under Xvfb there is no visible screen, and an
     * unmapped drawable is not guaranteed to be a valid GLX target. */
    XMapWindow(s_dpy, s_win);
    XSync(s_dpy, False);

    s_ctx = glXCreateContext(s_dpy, vi, NULL, True);
    if(!s_ctx) {
        printf("glXCreateContext failed\n");
        return 0;
    }
    return glXMakeCurrent(s_dpy, s_win, s_ctx) ? 1 : 0;
}

static void drop_context(void)
{
    if(s_dpy) {
        glXMakeCurrent(s_dpy, None, NULL);
        if(s_ctx) glXDestroyContext(s_dpy, s_ctx);
        if(s_win) XDestroyWindow(s_dpy, s_win);
        XCloseDisplay(s_dpy);
    }
}

#endif

/* Reads the panel texture through the same framebuffer object the renderer
 * uses, which is the only way to prove pixels reached the texture. */
static int count_non_background(unsigned int tex, int w, int h, int * out_distinct)
{
    unsigned char * px = (unsigned char *)malloc((size_t)w * h * 4);
    GLuint fbo = 0;
    GLint saved = 0;
    int i, n = 0;
    unsigned int first = 0;
    int distinct = 0;

    if(!px) return -1;

    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved);
    glGenFramebuffers(1, &fbo);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
    if(glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);
        glDeleteFramebuffers(1, &fbo);
        free(px);
        return -1;
    }
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);
    glDeleteFramebuffers(1, &fbo);

    for(i = 0; i < w * h; i++) {
        unsigned int c = ((unsigned int)px[i * 4] << 16) |
                         ((unsigned int)px[i * 4 + 1] << 8) |
                         (unsigned int)px[i * 4 + 2];
        if(px[i * 4 + 3] != 0) n++;
        if(i == 0) first = c;
        else if(c != first && distinct == 0) distinct = 1;
    }
    if(out_distinct) *out_distinct = distinct;
    free(px);
    return n;
}

/* The whole render framebuffer, read once, so several probes can share it. */
static unsigned char * read_panel(int w, int h)
{
    unsigned char * px = (unsigned char *)malloc((size_t)w * h * 4);
    GLint saved = 0;
    if(!px) return NULL;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)plv_display_fbo());
    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, px);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);
    return px;
}

/* Panel coordinates have y down; which framebuffer row holds panel row 0 is
 * measured, not assumed, and passed in as flip. */
static const unsigned char * panel_px(const unsigned char * px, int w, int h, int flip,
                                      int x, int y)
{
    int row = flip ? (h - 1 - y) : y;
    return px + ((size_t)row * w + x) * 4;
}

static int near_rgb(const unsigned char * p, int r, int g, int b, int tol)
{
    return abs(p[0] - r) <= tol && abs(p[1] - g) <= tol && abs(p[2] - b) <= tol;
}

/* A 32x32 RGBA texture stored bottom row first, as OpenGL and a Psychtoolbox
 * texture in normal orientation store it: the bottom half red, the top half
 * blue. ImageFromTexture promises that the blue half shows at the top. */
static GLuint make_test_texture(void)
{
    unsigned char data[32 * 32 * 4];
    GLuint tex = 0;
    int r, c;
    for(r = 0; r < 32; r++) {
        for(c = 0; c < 32; c++) {
            unsigned char * p = data + (r * 32 + c) * 4;
            int top = r >= 16;
            p[0] = top ? 0 : 255;
            p[1] = 0;
            p[2] = top ? 255 : 0;
            p[3] = 255;
        }
    }
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 32, 32, 0, GL_RGBA, GL_UNSIGNED_BYTE, data);
    glBindTexture(GL_TEXTURE_2D, 0);
    return tex;
}

/* Phase 2 scene: a style, a chart, a texture image and a TTF label on one
 * screen, rendered through the same NanoVG path as everything else. */
static void phase2_scene(int W, int H, double * t)
{
    plv_err_t err;
    lv_obj_t * scr = lv_screen_active();
    lv_obj_t * box, * chart, * img, * lbl;
    lv_chart_series_t * ser;
    lv_style_t * style;
    double hstyle, hser, himg, hfont = 0.0;
    GLuint tex;
    int i, dirty = 0, flip = -1;
    unsigned char * px;
    char font_path[1024];

    lv_obj_clean(scr);
    lv_obj_set_style_bg_color(scr, lv_color_make(20, 40, 160), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, 255, LV_PART_MAIN);

    /* A shared style through the resource table. */
    hstyle = plv_style_create(&err);
    style = (lv_style_t *)plv_res_resolve(hstyle, PLV_RES_STYLE, &err);
    check("a style handle resolves", style != NULL);
    if(!style) return;
    lv_style_set_bg_color(style, lv_color_make(0, 200, 0));
    lv_style_set_bg_opa(style, 255);
    lv_style_set_radius(style, 0);
    lv_style_set_border_width(style, 0);
    box = lv_obj_create(scr);
    plv_handle_register(box, 0);
    lv_obj_remove_style_all(box);
    lv_obj_add_style(box, style, LV_PART_MAIN);
    lv_obj_set_pos(box, 0, 0);
    lv_obj_set_size(box, 100, 60);
    check("StyleDelete is refused while the style is added",
          plv_style_delete(hstyle, &err) != 0 && strcmp(err.id, "psychlvgl:InUse") == 0);

    /* A line chart; its series lives in the resource table. */
    chart = lv_chart_create(scr);
    plv_handle_register(chart, 0);
    lv_obj_set_pos(chart, 0, 70);
    lv_obj_set_size(chart, 200, 120);
    lv_chart_set_type(chart, LV_CHART_TYPE_LINE);
    lv_chart_set_point_count(chart, 10);
    lv_chart_set_axis_range(chart, LV_CHART_AXIS_PRIMARY_Y, 0, 100);
    ser = lv_chart_add_series(chart, lv_color_make(255, 0, 0), LV_CHART_AXIS_PRIMARY_Y);
    hser = plv_res_register(PLV_RES_SERIES, ser, chart, &err);
    for(i = 0; i < 10; i++) lv_chart_set_next_value(chart, ser, i * 10);

    /* An image drawn straight from an OpenGL texture (vendored patch 0002). */
    tex = make_test_texture();
    himg = plv_image_from_texture((uint32_t)tex, 32, 32, &err);
    check("ImageFromTexture returned a handle", himg != 0.0);
    img = lv_image_create(scr);
    plv_handle_register(img, 0);
    lv_image_set_src(img, plv_res_resolve(himg, PLV_RES_IMAGE, &err));
    lv_obj_set_pos(img, 220, 20);

    /* A label in a TTF font through tiny_ttf. */
    snprintf(font_path, sizeof(font_path), "%s/third_party/lvgl/examples/libs/tiny_ttf/Ubuntu-Medium.ttf",
             PLV_SOURCE_DIR);
    hfont = plv_font_load(font_path, 32, &err);
    check("FontLoad read the TTF file", hfont != 0.0);
    if(hfont == 0.0) printf("  FontLoad: %s %s\n", err.id, err.msg);
    lbl = lv_label_create(scr);
    plv_handle_register(lbl, 0);
    lv_label_set_text(lbl, "TTF");
    lv_obj_set_style_text_color(lbl, lv_color_make(255, 255, 255), LV_PART_MAIN);
    if(hfont != 0.0) lv_obj_set_style_text_font(lbl, plv_font_resolve(hfont, &err), LV_PART_MAIN);
    lv_obj_set_pos(lbl, 220, 120);

    for(i = 0; i < 4; i++) {
        *t += 0.016;
        if(plv_update(*t, NULL, 0.0, NULL, 0, &dirty, &err)) {
            printf("plv_update (phase 2) failed: %s %s\n", err.id, err.msg);
            failures++;
            return;
        }
    }
    check("glGetError is clean after the phase 2 scene", glGetError() == GL_NO_ERROR);

    px = read_panel(W, H);
    if(!px) return;

    /* The styled box fills the top left of the panel; find the row order. */
    if(near_rgb(panel_px(px, W, H, 0, 20, 20), 0, 200, 0, 12))      flip = 0;
    else if(near_rgb(panel_px(px, W, H, 1, 20, 20), 0, 200, 0, 12)) flip = 1;
    check("the styled box shows its style colour", flip >= 0);
    if(flip < 0) flip = 1;
    printf("  panel row 0 is framebuffer row %s\n", flip ? "H-1" : "0");

    {
        const unsigned char * top = panel_px(px, W, H, flip, 236, 26);
        const unsigned char * bot = panel_px(px, W, H, flip, 236, 46);
        printf("  texture image top %u %u %u, bottom %u %u %u\n",
               top[0], top[1], top[2], bot[0], bot[1], bot[2]);
        check("the texture image is drawn, top half blue", near_rgb(top, 0, 0, 255, 24));
        check("the texture image is upright, bottom half red", near_rgb(bot, 255, 0, 0, 24));
    }

    {   /* A chart with a grid and a line is not one flat colour. */
        int x, y, n = 0;
        const unsigned char * ref = panel_px(px, W, H, flip, 5, 75);
        for(y = 72; y < 188; y += 2)
            for(x = 2; x < 198; x += 2)
                if(!near_rgb(panel_px(px, W, H, flip, x, y), ref[0], ref[1], ref[2], 8)) n++;
        printf("  chart pixels that differ from its background: %d\n", n);
        check("the chart renders a non-flat plot", n > 200);
    }

    {   /* White TTF glyphs on the blue screen. */
        int x, y, n = 0;
        for(y = 120; y < 160 && y < H; y++)
            for(x = 220; x < 300 && x < W; x++)
                if(near_rgb(panel_px(px, W, H, flip, x, y), 255, 255, 255, 60)) n++;
        printf("  TTF label white pixels: %d\n", n);
        check("the TTF label renders glyphs", n > 50);
    }
    free(px);

    /* The GL_TIMESTAMP pair is read a few frames late, so run a few more. */
    for(i = 0; i < 6; i++) {
        *t += 0.016;
        lv_chart_set_next_value(chart, ser, (i * 37) % 100);
        plv_update(*t, NULL, 0.0, NULL, 0, &dirty, &err);
    }
    printf("  GPU time of lv_timer_handler: last %.3f ms, max %.3f ms (0: no GL_TIMESTAMP here)\n",
           (double)plv_stats()->gpu_last_ns / 1e6, (double)plv_stats()->gpu_max_ns / 1e6);
    /* Reported, not checked: a software renderer may stamp both ends of a
     * frame at the same time, and a CI job must not fail on that. The GL
     * suite checks gpuNs on real hardware. */
    if((GLAD_GL_VERSION_3_3 || GLAD_GL_ARB_timer_query) && plv_stats()->gpu_max_ns == 0)
        printf("  note: GL_TIMESTAMP is available but measured 0 ns\n");

    /* Deleting the chart releases its series handle through the delete hook. */
    lv_obj_delete(chart);
    check("the series handle died with its chart", plv_res_kind(hser) == PLV_RES_NONE);

    /* The texture stays the caller's: releasing the image must not delete it. */
    lv_image_set_src(img, NULL);
    check("ImageDelete succeeds once no object shows the image", plv_image_delete(himg, &err) == 0);
    *t += 0.016;
    plv_update(*t, NULL, 0.0, NULL, 0, &dirty, &err);
    check("the texture survives the image handle", glIsTexture(tex) == GL_TRUE);
    glDeleteTextures(1, &tex);
    check("glGetError is clean after the phase 2 teardown", glGetError() == GL_NO_ERROR);
}

int main(void)
{
    plv_init_opts_t opts;
    plv_err_t err;
    unsigned int tex = 0;
    plv_pointer_t ptr;
    lv_obj_t * scr;
    lv_obj_t * label;
    lv_obj_t * slider;
    const int W = 320, H = 200;
    double t = 0.0;
    int i, dirty = 0;
    int nonbg, distinct = 0;
    unsigned long long idle_ns = 0, change_ns = 0;

    /* Unbuffered: a crash must not take the log that leads up to it. */
    setvbuf(stdout, NULL, _IONBF, 0);

    if(!make_context()) {
        printf("could not create an OpenGL context; nothing to test\n");
        return 2;
    }

    plv_set_print_fn(print_line);

    check("a GL context is current", plv_gl_has_context());
    check("gladLoadGL resolved the entry points", plv_gl_load());
    printf("GL_VERSION  %s\n", (const char *)glGetString(GL_VERSION));
    printf("GL_RENDERER %s\n", (const char *)glGetString(GL_RENDERER));
    printf("GL_SHADING_LANGUAGE_VERSION %s\n",
           (const char *)glGetString(GL_SHADING_LANGUAGE_VERSION));

    plv_opts_default(&opts);
    opts.w = W;
    opts.h = H;
    opts.log_level = 1;

    memset(&err, 0, sizeof(err));
    if(plv_init(&opts, &tex, &err)) {
        /* plv_display_create checks the context before it calls into
         * lv_opengles_*, so a context LVGL cannot use arrives here as an
         * error with the reason in it, not as a segmentation fault.
         * SPEC deviation D37 has the macOS measurement. */
        printf("plv_init failed: %s %s\n", err.id, err.msg);
        drop_context();
        return 1;
    }
    check("plv_init succeeded", 1);
    check("the panel texture id is nonzero", tex != 0);
    printf("NanoVG backend %s, texture %u, fbo %u\n",
           plv_nanovg_backend_name(), tex, plv_display_fbo());

    scr = lv_screen_active();
    lv_obj_set_style_bg_color(scr, lv_color_make(20, 40, 160), LV_PART_MAIN);
    lv_obj_set_style_bg_opa(scr, 255, LV_PART_MAIN);

    label = lv_label_create(scr);
    lv_label_set_text(label, "psychlvgl smoke");
    lv_obj_align(label, LV_ALIGN_TOP_MID, 0, 10);
    plv_handle_register(label, 0);

    slider = lv_slider_create(scr);
    lv_obj_set_size(slider, 240, 20);
    lv_obj_align(slider, LV_ALIGN_CENTER, 0, 0);
    lv_slider_set_range(slider, 0, 100);
    lv_slider_set_value(slider, 25, LV_ANIM_OFF);
    plv_handle_register(slider, 0);

    memset(&ptr, 0, sizeof(ptr));
    for(i = 0; i < 8; i++) {
        uint64_t t0;
        t += 0.016;
        if(i == 3) {                    /* press on the slider */
            ptr.x = 200; ptr.y = H / 2; ptr.pressed = 1;
        }
        else if(i == 5) {               /* release */
            ptr.pressed = 0;
        }
        t0 = plv_now_ns();
        if(plv_update(t, &ptr, 0.0, NULL, 0, &dirty, &err)) {
            printf("plv_update failed: %s %s\n", err.id, err.msg);
            failures++;
            break;
        }
        if(i == 1) idle_ns = plv_now_ns() - t0;        /* nothing changed */
        if(i == 3) change_ns = plv_now_ns() - t0;      /* the slider moved */
        printf("  frame %d dirty=%d update=%.3f ms\n", i, dirty,
               (double)(plv_now_ns() - t0) / 1e6);
    }

    check("glGetError is clean after Update", glGetError() == GL_NO_ERROR);
    check("the slider followed the pointer", lv_slider_get_value(slider) > 25);
    check("some events were queued", plv_events_available() > 0);

    {   /* The centre of the panel is the slider, so a blue opaque pixel there
         * means NanoVG reached the framebuffer the renderer owns. */
        unsigned char probe[4] = { 0, 0, 0, 0 };
        GLint saved = 0;
        glGetIntegerv(GL_FRAMEBUFFER_BINDING, &saved);
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)plv_display_fbo());
        glPixelStorei(GL_PACK_ALIGNMENT, 1);
        glReadPixels(W / 2, H / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, probe);
        printf("render framebuffer centre pixel %u %u %u %u\n",
               probe[0], probe[1], probe[2], probe[3]);
        check("the slider indicator reached the centre pixel",
              probe[3] == 255 && probe[2] > probe[0]);
        glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)saved);
        glGetError();
    }

    nonbg = count_non_background(tex, W, H, &distinct);
    printf("non transparent pixels %d of %d, more than one colour: %d\n",
           nonbg, W * H, distinct);
    check("the texture holds rendered pixels", nonbg > (W * H) / 2);
    check("the texture is not one flat colour", distinct == 1);

    printf("Update CPU time: idle %.3f ms, changing %.3f ms\n",
           (double)idle_ns / 1e6, (double)change_ns / 1e6);
    printf("lv_timer_handler last %.3f ms, max %.3f ms over %llu frames\n",
           (double)plv_stats()->update_last_ns / 1e6,
           (double)plv_stats()->update_max_ns / 1e6,
           (unsigned long long)plv_stats()->update_count);

    printf("phase 2 scene\n");
    phase2_scene(W, H, &t);

    plv_shutdown();
    check("plv_shutdown left GL clean", glGetError() == GL_NO_ERROR);
    check("the core reports itself uninitialized", !plv_is_initialized());

    /* Rule R5, and the shape the GL tests have: several Init and Shutdown
     * cycles at different sizes on one context, each with its own widgets. */
    {
        static const int sizes[][2] = { { 160, 100 }, { 200, 120 }, { 240, 160 } };
        int k;
        for(k = 0; k < 3; k++) {
            unsigned int tex2 = 0;
            int w2 = sizes[k][0];
            int h2 = sizes[k][1];
            char what[64];

            opts.w = w2;
            opts.h = h2;
            if(plv_init(&opts, &tex2, &err)) {
                printf("Init %dx%d failed: %s %s\n", w2, h2, err.id, err.msg);
                failures++;
                break;
            }
            {
                lv_obj_t * s2 = lv_screen_active();
                lv_obj_t * l2;
                lv_obj_set_style_bg_color(s2, lv_color_make(200, 30, 30), LV_PART_MAIN);
                lv_obj_set_style_bg_opa(s2, 255, LV_PART_MAIN);
                l2 = lv_label_create(s2);
                lv_label_set_text(l2, "cycle");
                lv_obj_align(l2, LV_ALIGN_CENTER, 0, 0);
                plv_handle_register(l2, 0);
            }
            t += 1.0;
            if(plv_update(t, NULL, 0.0, NULL, 0, &dirty, &err)) {
                printf("Update after Init %dx%d failed: %s %s\n", w2, h2, err.id, err.msg);
                failures++;
                plv_shutdown();
                break;
            }
            nonbg = count_non_background(tex2, w2, h2, &distinct);
            printf("  cycle %d: %dx%d texture %u, %d of %d opaque, dirty %d\n",
                   k, w2, h2, tex2, nonbg, w2 * h2, dirty);
            sprintf(what, "Init %dx%d renders into its own texture", w2, h2);
            check(what, nonbg > 100 && distinct == 1);
            plv_shutdown();
        }
    }

    drop_context();

    printf("\n%s (%d failure(s))\n", failures ? "SMOKE TEST FAILED" : "SMOKE TEST PASSED",
           failures);
    return failures ? 1 : 0;
}
