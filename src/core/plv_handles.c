/**
 * @file plv_handles.c
 * Slot table with a generation counter.
 *
 * A raw pointer in a double would be smaller but gives no use-after-delete
 * detection. Twenty-four bytes per object buys a hard error instead of a crash
 * when a script keeps a handle to a deleted widget.
 */
#include "plv_internal.h"
#include <stdio.h>
#include <stdlib.h>

void plv_mask_set(uint32_t * mask, uint32_t bit, int on)
{
    if(bit >= PLV_EVENT_MASK_BITS) return;
    if(on) mask[bit >> 5] |= (1u << (bit & 31u));
    else   mask[bit >> 5] &= ~(1u << (bit & 31u));
}

int plv_mask_get(const uint32_t * mask, uint32_t bit)
{
    if(bit >= PLV_EVENT_MASK_BITS) return 0;
    return (mask[bit >> 5] & (1u << (bit & 31u))) != 0u;
}

int plv_handles_init(uint32_t max_objects)
{
    uint32_t i;

    g_plv.slots = (plv_slot_t *)calloc(max_objects + 1u, sizeof(plv_slot_t));
    if(!g_plv.slots) return 1;
    g_plv.slot_count = max_objects;

    /* Index 0 stays reserved so the null handle can never resolve. */
    for(i = 1; i <= max_objects; i++) {
        g_plv.slots[i].obj       = NULL;
        g_plv.slots[i].gen       = 1;
        g_plv.slots[i].next_free = (i < max_objects) ? (i + 1u) : 0u;
    }
    g_plv.free_head = 1;
    return 0;
}

void plv_handles_deinit(void)
{
    free(g_plv.slots);
    g_plv.slots      = NULL;
    g_plv.slot_count = 0;
    g_plv.free_head  = 0;
}

static uint32_t plv_handle_index(double handle)
{
    double idx;
    if(!(handle > 0.0)) return 0;
    idx = handle - (double)((uint32_t)(handle / PLV_HANDLE_SHIFT)) * PLV_HANDLE_SHIFT;
    if(idx < 1.0 || idx > (double)g_plv.slot_count) return 0;
    return (uint32_t)idx;
}

static uint32_t plv_handle_gen(double handle)
{
    return (uint32_t)(handle / PLV_HANDLE_SHIFT);
}

double plv_handle_register(lv_obj_t * obj, uint16_t extra_flags)
{
    uint32_t idx;
    plv_slot_t * s;
    double handle;

    if(!obj) return 0.0;

    /* An object already known to the table keeps its handle. */
    handle = plv_handle_of(obj);
    if(handle != 0.0) return handle;

    if(g_plv.free_head == 0) {
        plv_defer("psychlvgl:Range", "handle table is full, raise MaxObjects at Init");
        return 0.0;
    }

    idx = g_plv.free_head;
    s   = &g_plv.slots[idx];
    g_plv.free_head = s->next_free;

    s->obj       = obj;
    s->next_free = 0;
    s->flags     = (uint16_t)(PLV_SLOT_LIVE | extra_flags);
    memset(s->event_mask, 0, sizeof(s->event_mask));
    {   /* Section 5.4: the default subscription set. */
        static const uint32_t defaults[] = {
            LV_EVENT_CLICKED, LV_EVENT_VALUE_CHANGED, LV_EVENT_PRESSED,
            LV_EVENT_RELEASED, LV_EVENT_FOCUSED, LV_EVENT_DEFOCUSED,
            LV_EVENT_READY, LV_EVENT_CANCEL
        };
        uint32_t k;
        for(k = 0; k < sizeof(defaults) / sizeof(defaults[0]); k++)
            plv_mask_set(s->event_mask, defaults[k], 1);
    }

    handle = (double)s->gen * PLV_HANDLE_SHIFT + (double)idx;
    lv_obj_set_user_data(obj, (void *)(lv_uintptr_t)(uint64_t)handle);
    plv_events_attach(obj);
    return handle;
}

double plv_handle_of(const lv_obj_t * obj)
{
    double handle;
    uint32_t idx;

    if(!obj || !g_plv.slots) return 0.0;
    handle = (double)(uint64_t)(lv_uintptr_t)lv_obj_get_user_data((lv_obj_t *)obj);
    idx = plv_handle_index(handle);
    if(idx == 0) return 0.0;
    if(g_plv.slots[idx].obj != obj) return 0.0;
    if(g_plv.slots[idx].gen != plv_handle_gen(handle)) return 0.0;
    return handle;
}

int plv_handle_is_valid(double handle)
{
    uint32_t idx = plv_handle_index(handle);
    if(idx == 0) return 0;
    if(!(g_plv.slots[idx].flags & PLV_SLOT_LIVE)) return 0;
    if(g_plv.slots[idx].gen != plv_handle_gen(handle)) return 0;
    return g_plv.slots[idx].obj != NULL;
}

lv_obj_t * plv_handle_resolve(double handle, plv_err_t * err)
{
    uint32_t idx = plv_handle_index(handle);
    if(idx == 0 || !plv_handle_is_valid(handle)) {
        plv_fail(err, "psychlvgl:InvalidHandle",
                 "handle %.0f is null, out of range, freed, or from an earlier generation",
                 handle);
        return NULL;
    }
    return g_plv.slots[idx].obj;
}

uint32_t plv_handle_live_count(void)
{
    uint32_t i, n = 0;
    for(i = 1; i <= g_plv.slot_count; i++)
        if(g_plv.slots[i].obj) n++;
    return n;
}

int plv_handle_event_subscribed(double handle, uint32_t code)
{
    uint32_t idx = plv_handle_index(handle);
    if(idx == 0) return 0;
    return plv_mask_get(g_plv.slots[idx].event_mask, code);
}

int plv_handle_set_event_bit(double handle, uint32_t code, int on, plv_err_t * err)
{
    uint32_t idx = plv_handle_index(handle);
    if(idx == 0 || !plv_handle_is_valid(handle))
        return plv_fail(err, "psychlvgl:InvalidHandle", "handle %.0f is not valid", handle);
    if(code >= PLV_EVENT_MASK_BITS)
        return plv_fail(err, "psychlvgl:Enum",
                        "event code %u is above the %d codes the mask holds",
                        code, PLV_EVENT_MASK_BITS);
    plv_mask_set(g_plv.slots[idx].event_mask, code, on);
    return 0;
}

/* Called from the LV_EVENT_DELETE branch of plv_on_event. Bumping the
 * generation is what turns every outstanding handle into an error, including
 * handles to children deleted with their parent. */
void plv_handle_release_obj(lv_obj_t * obj)
{
    double handle;
    uint32_t idx;

    if(!g_plv.slots) return;
    handle = (double)(uint64_t)(lv_uintptr_t)lv_obj_get_user_data(obj);
    idx = plv_handle_index(handle);
    if(idx == 0) return;
    if(g_plv.slots[idx].obj != obj) return;

    g_plv.slots[idx].obj        = NULL;
    g_plv.slots[idx].flags      = 0;
    memset(g_plv.slots[idx].event_mask, 0, sizeof(g_plv.slots[idx].event_mask));
    g_plv.slots[idx].gen        = (uint16_t)(g_plv.slots[idx].gen + 1u);
    if(g_plv.slots[idx].gen == 0) g_plv.slots[idx].gen = 1;
    g_plv.slots[idx].next_free  = g_plv.free_head;
    g_plv.free_head             = idx;
}
