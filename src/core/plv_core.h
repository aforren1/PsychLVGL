/**
 * @file plv_core.h
 * The LVGL-facing half of psychlvgl. Nothing here knows about MATLAB, so a
 * native test executable can link it and drive the real GL path without an
 * engine present.
 *
 * Errors travel back in a plv_err_t instead of longjmp: an error must never
 * unwind an LVGL stack frame, and callbacks must never touch the engine.
 */
#ifndef PLV_CORE_H
#define PLV_CORE_H

#include <stdint.h>
#include "lvgl.h"

#ifdef __cplusplus
extern "C" {
#endif

#define PLV_VERSION            "0.1.0"
#define PLV_ERR_ID_MAX         64
#define PLV_ERR_MSG_MAX        512
#define PLV_KEYRING_SIZE       64
#define PLV_MAX_OPCODES        1024
#define PLV_DEFAULT_MAX_OBJECTS 4096
#define PLV_DEFAULT_QUEUE_CAP  1024
#define PLV_MAX_OBJECTS_LIMIT  65535
#define PLV_MAX_RESOURCES      4096
#define PLV_IMAGE_MAX_SIDE     16383
#define PLV_FONT_MAX_PX        1000

/* Handle layout: gen * 65536 + idx, idx in 1..65535, 0 is the null handle. */
#define PLV_HANDLE_SHIFT 65536.0

/* Kinds of the resource handle table. A resource handle is
 * ((kind * 65536 + gen) * 65536 + idx), so it is never below 2^32 and can
 * never equal an object handle. */
typedef enum {
    PLV_RES_NONE   = 0,
    PLV_RES_SERIES = 1,
    PLV_RES_CURSOR = 2,
    PLV_RES_STYLE  = 3,
    PLV_RES_IMAGE  = 4,
    PLV_RES_FONT   = 5,
    PLV_RES_KIND_COUNT
} plv_res_kind_t;

typedef struct {
    char id[PLV_ERR_ID_MAX];
    char msg[PLV_ERR_MSG_MAX];
} plv_err_t;

typedef enum {
    PLV_WHEEL_ENCODER = 0,
    PLV_WHEEL_KEYS    = 1
} plv_wheel_mode_t;

typedef enum {
    PLV_THEME_DEFAULT = 0,
    PLV_THEME_DARK    = 1,
    PLV_THEME_LIGHT   = 2
} plv_theme_t;

typedef struct {
    int32_t          w;
    int32_t          h;
    uint32_t         queue_capacity;
    uint32_t         max_objects;
    plv_wheel_mode_t wheel_mode;
    plv_theme_t      theme;
    int              log_level;
    const lv_font_t *font_default;
} plv_init_opts_t;

typedef struct {
    int32_t x;
    int32_t y;
    int     pressed;
} plv_pointer_t;

typedef struct {
    uint32_t key;
    uint8_t  pressed;
} plv_key_t;

typedef struct {
    uint32_t target;
    uint32_t code;
    uint32_t current_target;
    int32_t  param;
    double   time;
} plv_event_t;

typedef struct {
    uint64_t calls;
    uint64_t total_ns;
    uint64_t max_ns;
} plv_opstat_t;

typedef struct {
    uint64_t update_last_ns;
    uint64_t update_max_ns;
    uint64_t update_sum_ns;
    uint64_t update_count;
    uint64_t gpu_last_ns;
    uint64_t gpu_max_ns;
    uint64_t flush_count;
    uint64_t events_dropped;
    uint64_t queue_high_water;
    uint64_t tick_anomaly;
    uint64_t frame_last_ns;
    uint64_t frame_max_ns;
    uint64_t frame_sum_ns;
    uint64_t frame_count;
    plv_opstat_t op[PLV_MAX_OPCODES];
} plv_stats_t;

/* ---- lifecycle ---- */
void plv_opts_default(plv_init_opts_t * opts);
int  plv_is_initialized(void);
int  plv_init(const plv_init_opts_t * opts, unsigned int * out_texture_id, plv_err_t * err);
void plv_shutdown(void);
int  plv_update(double t_now, const plv_pointer_t * pointer, double wheel,
                const plv_key_t * keys, uint32_t n_keys, int * out_dirty, plv_err_t * err);
int32_t      plv_panel_width(void);
int32_t      plv_panel_height(void);
unsigned int plv_texture_id(void);
const char * plv_gl_version_string(void);
const char * plv_gl_renderer_string(void);
const char * plv_nanovg_backend_name(void);
const char * plv_build_string(void);
const char * plv_toolchain_id(void);

/* ---- deferred errors and logging ---- */
int  plv_take_deferred_error(plv_err_t * err);
void plv_set_log_level(int level);
int  plv_get_log_level(void);
/* The core never prints by itself; the MEX layer installs mexPrintf here. */
void plv_set_print_fn(void (*fn)(const char * text));

/* ---- handles ---- */
double     plv_handle_register(lv_obj_t * obj, uint16_t extra_flags);
double     plv_handle_of(const lv_obj_t * obj);
lv_obj_t * plv_handle_resolve(double handle, plv_err_t * err);
int        plv_handle_is_valid(double handle);
uint32_t   plv_handle_live_count(void);
int        plv_handle_event_subscribed(double handle, uint32_t code);
int        plv_handle_set_event_bit(double handle, uint32_t code, int on, plv_err_t * err);

/* ---- resource handles: series, cursors, styles, images, fonts ---- */
/* owner is the chart for series and cursors, NULL otherwise. Deleting the
 * owner releases every handle it owns. */
double         plv_res_register(plv_res_kind_t kind, void * ptr, void * owner, plv_err_t * err);
void *         plv_res_resolve(double handle, plv_res_kind_t kind, plv_err_t * err);
void *         plv_res_owner(double handle);
plv_res_kind_t plv_res_kind(double handle);   /* PLV_RES_NONE when not live */
void           plv_res_release(double handle);
const char *   plv_res_kind_name(plv_res_kind_t kind);

double            plv_style_create(plv_err_t * err);
int               plv_style_delete(double handle, plv_err_t * err);
uint32_t          plv_style_use_count(const lv_style_t * style);

/* w and h are the image as shown. transposed: the texture holds it with rows
 * and columns swapped, as Psychtoolbox stores a texture made from a matrix. */
double            plv_image_from_texture(uint32_t texture, int32_t w, int32_t h, int transposed,
                                         plv_err_t * err);
/* The caller fills *out_pixels, w * h ARGB8888 pixels in LVGL byte order
 * (B, G, R, A), before anything draws the image. */
double            plv_image_create_argb(int32_t w, int32_t h, uint8_t ** out_pixels, plv_err_t * err);
int               plv_image_delete(double handle, plv_err_t * err);
uint32_t          plv_image_use_count(const void * src);

double            plv_font_load(const char * path_utf8, int32_t px, plv_err_t * err);
int               plv_font_delete(double handle, plv_err_t * err);
uint32_t          plv_font_use_count(const lv_font_t * font);
const lv_font_t * plv_font_resolve(double handle, plv_err_t * err);

/* ---- events ---- */
uint32_t plv_events_available(void);
uint32_t plv_events_drain(plv_event_t * dst, uint32_t max_records);
void     plv_events_reset(void);

/* ---- group ---- */
lv_group_t * plv_group(void);

/* ---- stats ---- */
plv_stats_t * plv_stats(void);
void          plv_stats_reset(void);
void          plv_stats_add_frame(double dt_seconds);
void          plv_stats_add_op(uint32_t opcode, uint64_t ns);
uint64_t      plv_now_ns(void);

/* ---- test hooks ---- */
uint32_t plv_frame_checksum(void);
#ifndef PSYCHLVGL_TEST_SW
/** Framebuffer object that NanoVG renders the panel through. */
unsigned int plv_display_fbo(void);
#endif

#ifdef __cplusplus
}
#endif

#endif /* PLV_CORE_H */
