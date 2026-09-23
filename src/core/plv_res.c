/**
 * @file plv_res.c
 * Handle table for everything that is not a widget: chart series and
 * cursors, styles, images and fonts.
 *
 * It is a second table rather than more slots in the object table because
 * these things have no LV_EVENT_DELETE of their own. A series or a cursor
 * dies with its chart, so its slot records the chart as its owner and the
 * chart's delete hook releases it. Styles, images and fonts die only when the
 * script deletes them or at Shutdown.
 *
 * The kind sits above bit 32 of the handle. A style handle can therefore
 * never pass for a widget handle, and a font argument can tell a handle from
 * a font name by its class and value alone.
 */
#include "plv_internal.h"
#include <stdlib.h>

#define PLV_RES_SHIFT 65536.0

static const char * const s_kind_names[PLV_RES_KIND_COUNT] = {
    "none", "series", "cursor", "style", "image", "font"
};

const char * plv_res_kind_name(plv_res_kind_t kind)
{
    if((unsigned)kind >= PLV_RES_KIND_COUNT) return "unknown";
    return s_kind_names[kind];
}

int plv_res_init(uint32_t capacity)
{
    uint32_t i;

    g_plv.res = (plv_res_t *)calloc(capacity + 1u, sizeof(plv_res_t));
    if(!g_plv.res) return 1;
    g_plv.res_count = capacity;
    for(i = 1; i <= capacity; i++) {
        g_plv.res[i].gen       = 1;
        g_plv.res[i].next_free = (i < capacity) ? (i + 1u) : 0u;
    }
    g_plv.res_free_head  = 1;
    g_plv.res_owned_live = 0;
    return 0;
}

void plv_res_deinit(void)
{
    uint32_t i;

    if(!g_plv.res) return;
    /* Styles before fonts: a style may name a font, and lv_style_reset must
     * run while that pointer is still the font it was. */
    for(i = 1; i <= g_plv.res_count; i++)
        if(g_plv.res[i].ptr && g_plv.res[i].kind == PLV_RES_STYLE)
            plv_assets_free(PLV_RES_STYLE, g_plv.res[i].ptr);
    for(i = 1; i <= g_plv.res_count; i++) {
        plv_res_t * r = &g_plv.res[i];
        if(r->ptr && (r->kind == PLV_RES_IMAGE || r->kind == PLV_RES_FONT))
            plv_assets_free((plv_res_kind_t)r->kind, r->ptr);
    }
    free(g_plv.res);
    g_plv.res            = NULL;
    g_plv.res_count      = 0;
    g_plv.res_free_head  = 0;
    g_plv.res_owned_live = 0;
}

static uint32_t plv_res_index(double handle)
{
    double hi, idx;
    if(!(handle >= 4294967296.0)) return 0;
    hi  = (double)(uint64_t)(handle / PLV_RES_SHIFT);
    idx = handle - hi * PLV_RES_SHIFT;
    if(idx < 1.0 || idx > (double)g_plv.res_count) return 0;
    return (uint32_t)idx;
}

static uint32_t plv_res_hi(double handle)
{
    return (uint32_t)(uint64_t)(handle / PLV_RES_SHIFT);
}

static int plv_res_live(double handle, uint32_t * out_idx)
{
    uint32_t idx, hi;
    const plv_res_t * r;

    if(!g_plv.res) return 0;
    idx = plv_res_index(handle);
    if(idx == 0) return 0;
    r  = &g_plv.res[idx];
    hi = plv_res_hi(handle);
    if(r->ptr == NULL) return 0;
    if((hi >> 16) != r->kind || (hi & 0xFFFFu) != r->gen) return 0;
    if(out_idx) *out_idx = idx;
    return 1;
}

double plv_res_register(plv_res_kind_t kind, void * ptr, void * owner, plv_err_t * err)
{
    uint32_t idx;
    plv_res_t * r;

    if(!ptr) return 0.0;
    if(!g_plv.res || g_plv.res_free_head == 0) {
        plv_fail(err, "psychlvgl:Range",
                 "the resource table is full (%d series, cursors, styles, images and "
                 "fonts); delete some first", PLV_MAX_RESOURCES);
        return 0.0;
    }
    idx = g_plv.res_free_head;
    r   = &g_plv.res[idx];
    g_plv.res_free_head = r->next_free;

    r->ptr       = ptr;
    r->owner     = owner;
    r->kind      = (uint8_t)kind;
    r->next_free = 0;
    if(owner) g_plv.res_owned_live++;

    return ((double)((uint32_t)kind * 65536u + r->gen)) * PLV_RES_SHIFT + (double)idx;
}

void * plv_res_resolve(double handle, plv_res_kind_t kind, plv_err_t * err)
{
    uint32_t idx;
    plv_res_kind_t actual;

    if(plv_res_live(handle, &idx) && g_plv.res[idx].kind == (uint8_t)kind)
        return g_plv.res[idx].ptr;

    actual = plv_res_kind(handle);
    if(actual != PLV_RES_NONE)
        plv_fail(err, "psychlvgl:InvalidHandle", "handle %.0f is a %s handle, not a %s handle",
                 handle, plv_res_kind_name(actual), plv_res_kind_name(kind));
    else
        plv_fail(err, "psychlvgl:InvalidHandle",
                 "handle %.0f is not a live %s handle; it is null, freed, or from an "
                 "earlier generation", handle, plv_res_kind_name(kind));
    return NULL;
}

void * plv_res_owner(double handle)
{
    uint32_t idx;
    if(!plv_res_live(handle, &idx)) return NULL;
    return g_plv.res[idx].owner;
}

plv_res_kind_t plv_res_kind(double handle)
{
    uint32_t idx;
    if(!plv_res_live(handle, &idx)) return PLV_RES_NONE;
    return (plv_res_kind_t)g_plv.res[idx].kind;
}

static void plv_res_free_slot(uint32_t idx)
{
    plv_res_t * r = &g_plv.res[idx];
    if(r->owner && g_plv.res_owned_live) g_plv.res_owned_live--;
    r->ptr   = NULL;
    r->owner = NULL;
    r->kind  = PLV_RES_NONE;
    r->gen   = (uint16_t)(r->gen + 1u);
    if(r->gen == 0) r->gen = 1;
    r->next_free = g_plv.res_free_head;
    g_plv.res_free_head = idx;
}

void plv_res_release(double handle)
{
    uint32_t idx;
    if(plv_res_live(handle, &idx)) plv_res_free_slot(idx);
}

/* Runs from the LV_EVENT_DELETE hook of every registered chart; the scan is
 * skipped unless some chart still owns a series or a cursor. */
void plv_res_release_owned_by(const void * owner)
{
    uint32_t i;
    if(!g_plv.res || g_plv.res_owned_live == 0 || owner == NULL) return;
    for(i = 1; i <= g_plv.res_count; i++)
        if(g_plv.res[i].ptr && g_plv.res[i].owner == owner) plv_res_free_slot(i);
}
