/**
 * @file plv_internal.h
 * Shared state of the core layer. One process holds one of these.
 */
#ifndef PLV_INTERNAL_H
#define PLV_INTERNAL_H

#include "plv_core.h"
#include <string.h>

#define PLV_SLOT_LIVE       0x0001u
#define PLV_SLOT_IS_SCREEN  0x0002u
#define PLV_SLOT_FROM_PLUGIN 0x0004u

/* One bit per LV_EVENT_* code. LVGL 9.6 defines about 90 codes, so a single
 * uint32 as in SPEC 7.4 cannot hold VALUE_CHANGED, READY, CANCEL or DELETE. */
#define PLV_EVENT_MASK_BITS  128
#define PLV_EVENT_MASK_WORDS (PLV_EVENT_MASK_BITS / 32)

typedef struct {
    lv_obj_t * obj;        /* NULL when free */
    uint32_t   next_free;  /* free list link, valid only when obj == NULL */
    uint16_t   gen;
    uint16_t   flags;
    uint32_t   event_mask[PLV_EVENT_MASK_WORDS];
} plv_slot_t;

typedef struct {
    int          initialized;
    lv_display_t * disp;
    unsigned int texture_id;
    int32_t      w, h;

    lv_indev_t * indev_pointer;
    lv_indev_t * indev_encoder;
    lv_indev_t * indev_keypad;
    lv_group_t * group;

    plv_pointer_t pointer;
    int16_t       enc_diff;
    plv_key_t     keyring[PLV_KEYRING_SIZE];
    uint32_t      key_head, key_tail;
    plv_wheel_mode_t wheel_mode;

    plv_slot_t * slots;
    uint32_t     slot_count;
    uint32_t     free_head;

    struct plv_res_s * res;          /* resource table, index 0 unused */
    uint32_t     res_count;
    uint32_t     res_free_head;
    uint32_t     res_owned_live;     /* live series and cursors */

    plv_event_t * events;
    uint32_t      queue_capacity;
    uint32_t      head, tail;

    double   t0;
    double   t_now;
    uint32_t last_tick;

    int      dirty;
    int      saved_fbo;

    plv_stats_t stats;

    int  deferred_error;
    char deferred_id[PLV_ERR_ID_MAX];
    char deferred_msg[PLV_ERR_MSG_MAX];

    int  log_level;
    void (*print_fn)(const char * text);
} plv_state_t;

extern plv_state_t g_plv;

/* Fills err and returns 1, so callers can `return plv_fail(err, ...)`. */
int  plv_fail(plv_err_t * err, const char * id, const char * fmt, ...);
void plv_defer(const char * id, const char * msg);

void plv_mask_set(uint32_t * mask, uint32_t bit, int on);
int  plv_mask_get(const uint32_t * mask, uint32_t bit);

/* ---- handle table ---- */
int  plv_handles_init(uint32_t max_objects);
void plv_handles_deinit(void);
void plv_handle_release_obj(lv_obj_t * obj);

/* ---- resource table ---- */
typedef struct plv_res_s {
    void *   ptr;        /* NULL when free */
    void *   owner;      /* the chart of a series or cursor */
    uint32_t next_free;
    uint16_t gen;
    uint8_t  kind;
    uint8_t  pad;
} plv_res_t;

int  plv_res_init(uint32_t capacity);
/* Frees every style, image and font. The widget tree has to be gone first,
 * because objects hold pointers to all three. */
void plv_res_deinit(void);
void plv_res_release_owned_by(const void * owner);
/* Frees what a resource points to; plv_res_deinit and the Delete calls use it. */
void plv_assets_free(plv_res_kind_t kind, void * ptr);

/* ---- GPU timing and the Tracy GPU zone around lv_timer_handler ---- */
void plv_display_gpu_begin(void);
void plv_display_gpu_end(void);

/* ---- event ring ---- */
int  plv_events_init(uint32_t capacity);
void plv_events_deinit(void);
void plv_on_event(lv_event_t * e);
void plv_events_attach(lv_obj_t * obj);

/* ---- input ---- */
int  plv_input_init(plv_err_t * err);
void plv_input_deinit(void);
void plv_input_set_pointer(const plv_pointer_t * p);
void plv_input_push_key(uint32_t key, uint8_t pressed);
void plv_input_set_wheel(double wheel);
void plv_input_pump(void);

/* ---- display back end ---- */
/* Two implementations: plv_display.c (OpenGL + NanoVG) and plv_display_sw.c
 * (software, test builds). Only one is compiled into a given library. */
int  plv_display_check_context(plv_err_t * err);
int  plv_display_create(int32_t w, int32_t h, plv_err_t * err);
void plv_display_destroy(void);
/* 1 when the display and the draw unit have to outlive Shutdown. LVGL 9.6
 * guards lv_draw_nanovg_init with a static flag that lv_deinit never clears,
 * so a second lv_init would leave the GL build with no draw unit at all. */
int  plv_display_is_persistent(void);
/* Reuses the surviving display at a new size. Only the persistent back end
 * implements it. */
int  plv_display_resize(int32_t w, int32_t h, plv_err_t * err);
int  plv_display_frame_begin(plv_err_t * err);
int  plv_display_frame_end(plv_err_t * err);
void plv_display_flush_cb(lv_display_t * disp, const lv_area_t * area, uint8_t * px_map);

#endif /* PLV_INTERNAL_H */
