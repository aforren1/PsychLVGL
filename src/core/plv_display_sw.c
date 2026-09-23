/**
 * @file plv_display_sw.c
 * Display back end for the test variant. No GL at all: LVGL renders with the
 * software draw unit into a buffer this file owns, which makes the whole
 * binding testable on a machine with no GPU and no Psychtoolbox.
 *
 * Only this file and plv_display.c differ between the two variants.
 */
#include "plv_internal.h"
#include <stdlib.h>

static uint8_t * s_buf;
static size_t    s_buf_size;

int plv_display_check_context(plv_err_t * err)
{
    LV_UNUSED(err);
    return 0;   /* no context to check */
}

int plv_display_is_persistent(void)
{
    return 0;   /* the software draw unit is registered by every lv_init */
}

int plv_display_resize(int32_t w, int32_t h, plv_err_t * err)
{
    LV_UNUSED(w);
    LV_UNUSED(h);
    return plv_fail(err, "psychlvgl:Usage",
                    "the software variant rebuilds the display instead of resizing it");
}

int plv_display_create(int32_t w, int32_t h, plv_err_t * err)
{
    uint32_t stride = lv_draw_buf_width_to_stride((uint32_t)w, LV_COLOR_FORMAT_ARGB8888);

    s_buf_size = (size_t)stride * (size_t)h;
    s_buf = (uint8_t *)calloc(1, s_buf_size);
    if(!s_buf)
        return plv_fail(err, "psychlvgl:GLInit", "out of memory for the software buffer");

    g_plv.disp = lv_display_create(w, h);
    if(!g_plv.disp) {
        free(s_buf);
        s_buf = NULL;
        return plv_fail(err, "psychlvgl:GLInit", "lv_display_create failed");
    }
    lv_display_set_color_format(g_plv.disp, LV_COLOR_FORMAT_ARGB8888);
    lv_display_set_buffers(g_plv.disp, s_buf, NULL, (uint32_t)s_buf_size,
                           LV_DISPLAY_RENDER_MODE_DIRECT);
    g_plv.texture_id = 0;
    return 0;
}

void plv_display_destroy(void)
{
    /* lv_deinit deletes the display; only the buffer is ours. */
    free(s_buf);
    s_buf = NULL;
    s_buf_size = 0;
    g_plv.disp = NULL;
}

int plv_display_frame_begin(plv_err_t * err)
{
    LV_UNUSED(err);
    return 0;
}

int plv_display_frame_end(plv_err_t * err)
{
    LV_UNUSED(err);
    return 0;
}

void plv_display_flush_cb(lv_display_t * disp, const lv_area_t * area, uint8_t * px_map)
{
    LV_UNUSED(area);
    LV_UNUSED(px_map);
    g_plv.dirty = 1;
    g_plv.stats.flush_count++;
    lv_display_flush_ready(disp);
}

/* No GPU, so nothing to time; gpuNs stays 0. */
void plv_display_gpu_begin(void) { }
void plv_display_gpu_end(void)   { }

const char * plv_gl_version_string(void)  { return "none"; }
const char * plv_gl_renderer_string(void) { return "software"; }

/* CRC32 of the rendered buffer. Tests pin a fixed scene at fixed ticks
 * against a stored value, which catches rendering regressions that a
 * property read-back would miss. */
uint32_t plv_frame_checksum(void)
{
    static uint32_t table[256];
    static int table_ready;
    uint32_t crc = 0xFFFFFFFFu;
    size_t i;

    if(!s_buf) return 0;
    if(!table_ready) {
        uint32_t n, k, c;
        for(n = 0; n < 256; n++) {
            c = n;
            for(k = 0; k < 8; k++) c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
            table[n] = c;
        }
        table_ready = 1;
    }
    for(i = 0; i < s_buf_size; i++)
        crc = table[(crc ^ s_buf[i]) & 0xFFu] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}
