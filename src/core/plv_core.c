/**
 * @file plv_core.c
 * Lifecycle, tick, logging, deferred errors, stats. Engine independent.
 */
#include "plv_internal.h"
#include "plv_assert.h"
#include "plv_profiler.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(_WIN32)
#include <windows.h>
#else
#include <time.h>
#endif

plv_state_t g_plv;

/* lv_init has run in this process. LVGL 9.6 cannot rebuild the NanoVG draw
 * unit after lv_deinit, so the GL build starts LVGL once and keeps it. */
static int s_lvgl_started;

static void plv_shutdown_common(void);

/* ------------------------------------------------------------------ errors */

int plv_fail(plv_err_t * err, const char * id, const char * fmt, ...)
{
    if(err) {
        va_list ap;
        snprintf(err->id, sizeof(err->id), "%s", id);
        va_start(ap, fmt);
        vsnprintf(err->msg, sizeof(err->msg), fmt, ap);
        va_end(ap);
    }
    return 1;
}

void plv_defer(const char * id, const char * msg)
{
    /* First failure wins: later ones are usually consequences of the first. */
    if(g_plv.deferred_error) return;
    g_plv.deferred_error = 1;
    snprintf(g_plv.deferred_id, sizeof(g_plv.deferred_id), "%s", id);
    snprintf(g_plv.deferred_msg, sizeof(g_plv.deferred_msg), "%s", msg);
}

void plv_assert_hook(const char * file, int line)
{
    char buf[PLV_ERR_MSG_MAX];
    snprintf(buf, sizeof(buf), "LVGL assertion failed at %s:%d", file, line);
    plv_defer("psychlvgl:LVGLAssert", buf);
}

int plv_take_deferred_error(plv_err_t * err)
{
    if(!g_plv.deferred_error) return 0;
    g_plv.deferred_error = 0;
    if(err) {
        snprintf(err->id, sizeof(err->id), "%s", g_plv.deferred_id);
        snprintf(err->msg, sizeof(err->msg), "%s", g_plv.deferred_msg);
    }
    return 1;
}

/* ----------------------------------------------------------------- logging */

static void plv_log_cb(lv_log_level_t level, const char * buf)
{
    if((int)level < g_plv.log_level) return;
    if(g_plv.print_fn) g_plv.print_fn(buf);
}

void plv_set_print_fn(void (*fn)(const char * text))
{
    g_plv.print_fn = fn;
}

void plv_set_log_level(int level)
{
    g_plv.log_level = level;
}

int plv_get_log_level(void)
{
    return g_plv.log_level;
}

/* -------------------------------------------------------------------- tick */

/* Where this session starts on LVGL's millisecond clock. LVGL timers keep the
 * tick of their last run across a Shutdown in the persistent build, so a tick
 * that restarted at zero would leave every timer waiting for a time that never
 * comes and nothing would ever redraw again. */
static uint32_t s_tick_offset;

/* LVGL shares the script clock, so animations line up with Flip times and
 * tests can inject synthetic times. */
static uint32_t plv_tick(void)
{
    double ms = (g_plv.t_now - g_plv.t0) * 1000.0;
    if(ms < 0.0) ms = 0.0;
    return s_tick_offset + (uint32_t)ms;
}

/* ------------------------------------------------------------------- stats */

uint64_t plv_now_ns(void)
{
#if defined(_WIN32)
    static LARGE_INTEGER freq;
    LARGE_INTEGER now;
    if(freq.QuadPart == 0) QueryPerformanceFrequency(&freq);
    QueryPerformanceCounter(&now);
    return (uint64_t)((double)now.QuadPart * 1e9 / (double)freq.QuadPart);
#elif defined(__APPLE__)
    /* clock_gettime(CLOCK_MONOTONIC) is rounded to microseconds on macOS,
     * which is coarser than an Update on an idle panel. The _np variant with
     * CLOCK_MONOTONIC_RAW keeps mach_absolute_time resolution, about 42 ns on
     * Apple silicon. */
    return (uint64_t)clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
#endif
}

plv_stats_t * plv_stats(void)
{
    return &g_plv.stats;
}

void plv_stats_reset(void)
{
    memset(&g_plv.stats, 0, sizeof(g_plv.stats));
}

/* ----------------------------------------------------------------- strings */

const char * plv_nanovg_backend_name(void)
{
#if defined(PSYCHLVGL_TEST_SW)
    return "none (software test variant)";
#elif LV_NANOVG_BACKEND == LV_NANOVG_BACKEND_GL2
    return "GL2";
#elif LV_NANOVG_BACKEND == LV_NANOVG_BACKEND_GL3
    return "GL3";
#elif LV_NANOVG_BACKEND == LV_NANOVG_BACKEND_GLES2
    return "GLES2";
#elif LV_NANOVG_BACKEND == LV_NANOVG_BACKEND_GLES3
    return "GLES3";
#else
    return "unknown";
#endif
}

const char * plv_build_string(void)
{
#if defined(PSYCHLVGL_TEST_SW)
    return "test-sw";
#else
    return "gl";
#endif
}

int32_t      plv_panel_width(void)    { return g_plv.w; }
int32_t      plv_panel_height(void)   { return g_plv.h; }
unsigned int plv_texture_id(void)     { return g_plv.texture_id; }
lv_group_t * plv_group(void)          { return g_plv.group; }
int          plv_is_initialized(void) { return g_plv.initialized; }

/* ----------------------------------------------------------------- options */

void plv_opts_default(plv_init_opts_t * opts)
{
    memset(opts, 0, sizeof(*opts));
    opts->w              = 400;
    opts->h              = 600;
    opts->queue_capacity = PLV_DEFAULT_QUEUE_CAP;
    opts->max_objects    = PLV_DEFAULT_MAX_OBJECTS;
    opts->wheel_mode     = PLV_WHEEL_ENCODER;
    opts->theme          = PLV_THEME_DEFAULT;
    opts->log_level      = LV_LOG_LEVEL_WARN;
    opts->font_default   = NULL;
}

static void plv_apply_theme(plv_theme_t theme, const lv_font_t * font)
{
    lv_theme_t * th;
    const lv_font_t * f = font ? font : LV_FONT_DEFAULT;
    bool dark = (theme == PLV_THEME_DARK);

    th = lv_theme_default_init(g_plv.disp, lv_palette_main(LV_PALETTE_BLUE),
                               lv_palette_main(LV_PALETTE_RED), dark, f);
    if(th) lv_display_set_theme(g_plv.disp, th);
}

/* --------------------------------------------------------------- lifecycle */

int plv_init(const plv_init_opts_t * opts, unsigned int * out_texture_id, plv_err_t * err)
{
    plv_init_opts_t o;
    void (*saved_print)(const char *) = g_plv.print_fn;

    if(opts) o = *opts;
    else plv_opts_default(&o);

    if(o.w <= 0 || o.h <= 0)
        return plv_fail(err, "psychlvgl:Usage", "panel size must be positive, got %dx%d",
                        (int)o.w, (int)o.h);
    if(o.max_objects < 16 || o.max_objects > PLV_MAX_OBJECTS_LIMIT)
        return plv_fail(err, "psychlvgl:Range", "MaxObjects must be 16 to %d",
                        PLV_MAX_OBJECTS_LIMIT);
    if(o.queue_capacity < 16 || (o.queue_capacity & (o.queue_capacity - 1u)) != 0u)
        return plv_fail(err, "psychlvgl:Range",
                        "QueueCapacity must be a power of two, at least 16");

    if(g_plv.initialized)
        return plv_fail(err, "psychlvgl:AlreadyInitialized", "PsychLVGL is already initialized");

    if(plv_display_check_context(err)) return 1;

    memset(&g_plv, 0, sizeof(g_plv));
    g_plv.print_fn   = saved_print;
    g_plv.log_level  = o.log_level;
    g_plv.wheel_mode = o.wheel_mode;
    g_plv.w          = o.w;
    g_plv.h          = o.h;

    if(plv_handles_init(o.max_objects))
        return plv_fail(err, "psychlvgl:GLInit", "out of memory for the handle table");
    if(plv_events_init(o.queue_capacity)) {
        plv_handles_deinit();
        return plv_fail(err, "psychlvgl:GLInit", "out of memory for the event ring");
    }
    if(plv_res_init(PLV_MAX_RESOURCES)) {
        plv_events_deinit();
        plv_handles_deinit();
        return plv_fail(err, "psychlvgl:GLInit", "out of memory for the resource table");
    }

    if(!s_lvgl_started) {
        lv_init();
        lv_tick_set_cb(plv_tick);
        lv_log_register_print_cb(plv_log_cb);
    }

    if(s_lvgl_started && plv_display_is_persistent()) {
        if(plv_display_resize(o.w, o.h, err)) {
            plv_res_deinit();
            plv_events_deinit();
            plv_handles_deinit();
            return 1;
        }
        /* The widget tree from the previous session goes, the display stays.
         * A fresh screen rather than lv_obj_clean, because a loaded screen also
         * drops the style properties the last session set on the screen. */
        {
            lv_obj_t * old_scr = lv_screen_active();
            lv_obj_t * new_scr = lv_obj_create(NULL);
            lv_screen_load(new_scr);
            if(old_scr && old_scr != new_scr) lv_obj_delete(old_scr);
            lv_obj_invalidate(new_scr);
        }
    }
    else if(plv_display_create(o.w, o.h, err)) {
        if(!s_lvgl_started) lv_deinit();
        plv_res_deinit();
        plv_events_deinit();
        plv_handles_deinit();
        return 1;
    }
    s_lvgl_started = 1;

    lv_display_set_default(g_plv.disp);
    lv_display_set_flush_cb(g_plv.disp, plv_display_flush_cb);
    plv_apply_theme(o.theme, o.font_default);

    if(plv_input_init(err)) {
        plv_shutdown_common();
        plv_events_deinit();
        plv_handles_deinit();
        return 1;
    }

    g_plv.initialized = 1;
    if(out_texture_id) *out_texture_id = g_plv.texture_id;
    return 0;
}

/* Every widget has to go before the styles, images and fonts do, because
 * objects hold bare pointers to all three and LVGL reads them again while it
 * deletes an object. A fresh screen replaces the active one, and every other
 * screen the script created is deleted too, so no object that could name a
 * freed resource survives. The delete hooks that free the handle slots run
 * inside lv_obj_delete, before the table is freed. */
static void plv_clear_widgets(void)
{
    lv_obj_t * old;
    lv_obj_t * fresh;
    uint32_t i;

    if(!g_plv.disp) return;
    old   = lv_screen_active();
    fresh = lv_obj_create(NULL);
    lv_screen_load(fresh);
    for(i = 1; g_plv.slots && i <= g_plv.slot_count; i++) {
        lv_obj_t * obj = g_plv.slots[i].obj;
        if(obj && obj != fresh && lv_obj_get_parent(obj) == NULL) lv_obj_delete(obj);
    }
    if(old && old != fresh && lv_obj_is_valid(old)) lv_obj_delete(old);
}

/* Tears the session down without deciding the fate of LVGL itself. */
static void plv_shutdown_common(void)
{
    plv_clear_widgets();
    plv_res_deinit();
    if(plv_display_is_persistent()) {
        /* The display, the texture and the NanoVG unit are process resources
         * here, so only the session state goes. */
        plv_input_deinit();
        plv_display_destroy();
    }
    else {
        /* lv_deinit destroys the display, the draw unit, the timers and the
         * indevs in one step. */
        plv_display_destroy();
        plv_input_deinit();
        lv_deinit();
        s_lvgl_started = 0;
    }
}

void plv_shutdown(void)
{
    void (*saved_print)(const char *) = g_plv.print_fn;
    int saved_level = g_plv.log_level;

    if(!g_plv.initialized) return;

    s_tick_offset = g_plv.last_tick + 1u;

    plv_shutdown_common();
    plv_events_deinit();
    plv_handles_deinit();

    memset(&g_plv, 0, sizeof(g_plv));
    g_plv.print_fn  = saved_print;
    g_plv.log_level = saved_level;
}

/* ------------------------------------------------------------------ update */

int plv_update(double t_now, const plv_pointer_t * pointer, double wheel,
               const plv_key_t * keys, uint32_t n_keys, int * out_dirty, plv_err_t * err)
{
    uint32_t i;
    uint64_t t_start;
    uint32_t tick_before;

    if(!g_plv.initialized)
        return plv_fail(err, "psychlvgl:NotInitialized", "call PsychLVGL Init first");

    if(plv_display_check_context(err)) return 1;

    if(g_plv.stats.update_count == 0 && g_plv.t0 == 0.0) g_plv.t0 = t_now;

    tick_before = plv_tick();
    g_plv.t_now = t_now;
    if(plv_tick() < tick_before) {
        /* A clock that steps backwards would freeze every animation, so move
         * the origin instead and count the anomaly. */
        g_plv.t0 = t_now - (double)(tick_before + 1u) / 1000.0;
        g_plv.stats.tick_anomaly++;
    }
    g_plv.last_tick = plv_tick();

    for(i = 0; i < n_keys; i++) plv_input_push_key(keys[i].key, keys[i].pressed);
    if(pointer) plv_input_set_pointer(pointer);
    plv_input_set_wheel(wheel);

    if(plv_display_frame_begin(err)) return 1;

    plv_input_pump();

    PLV_ZONE_BEGIN(timer_handler);
    plv_display_gpu_begin();
    t_start = plv_now_ns();
    lv_timer_handler();
    plv_display_gpu_end();
    {
        uint64_t dt = plv_now_ns() - t_start;
        g_plv.stats.update_last_ns = dt;
        if(dt > g_plv.stats.update_max_ns) g_plv.stats.update_max_ns = dt;
        g_plv.stats.update_sum_ns += dt;
        g_plv.stats.update_count++;
    }
    PLV_ZONE_END(timer_handler);

    if(plv_display_frame_end(err)) return 1;

    if(out_dirty) *out_dirty = g_plv.dirty;
    g_plv.dirty = 0;

    if(plv_take_deferred_error(err)) return 1;
    return 0;
}
