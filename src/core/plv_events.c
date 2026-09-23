/**
 * @file plv_events.c
 * One LV_EVENT_ALL callback per object feeds a fixed ring. MATLAB code must
 * never run inside an LVGL callback, so the callback only stores numbers: it
 * allocates nothing and raises nothing.
 */
#include "plv_internal.h"
#include <stdlib.h>

int plv_events_init(uint32_t capacity)
{
    g_plv.events = (plv_event_t *)calloc(capacity, sizeof(plv_event_t));
    if(!g_plv.events) return 1;
    g_plv.queue_capacity = capacity;
    g_plv.head = 0;
    g_plv.tail = 0;
    return 0;
}

void plv_events_deinit(void)
{
    free(g_plv.events);
    g_plv.events         = NULL;
    g_plv.queue_capacity = 0;
    g_plv.head = g_plv.tail = 0;
}

void plv_events_reset(void)
{
    g_plv.head = g_plv.tail = 0;
}

uint32_t plv_events_available(void)
{
    return g_plv.head - g_plv.tail;
}

uint32_t plv_events_drain(plv_event_t * dst, uint32_t max_records)
{
    uint32_t n = plv_events_available();
    uint32_t i;
    if(n > max_records) n = max_records;
    for(i = 0; i < n; i++)
        dst[i] = g_plv.events[(g_plv.tail + i) & (g_plv.queue_capacity - 1u)];
    g_plv.tail += n;
    if(g_plv.tail == g_plv.head) g_plv.head = g_plv.tail = 0;
    return n;
}

static void plv_events_push(const plv_event_t * rec)
{
    uint32_t used = g_plv.head - g_plv.tail;
    if(used >= g_plv.queue_capacity) {
        /* Drop the oldest record. A script that stops polling must not stall
         * the GUI, and the ring must never grow on the per-frame path. */
        g_plv.tail++;
        g_plv.stats.events_dropped++;
        used = g_plv.head - g_plv.tail;
    }
    g_plv.events[g_plv.head & (g_plv.queue_capacity - 1u)] = *rec;
    g_plv.head++;
    used = g_plv.head - g_plv.tail;
    if(used > g_plv.stats.queue_high_water) g_plv.stats.queue_high_water = used;
}

/* Widget value that a script would otherwise have to fetch with a second
 * call right after every VALUE_CHANGED. */
static int32_t plv_value_of(lv_obj_t * obj)
{
#if LV_USE_SLIDER
    if(lv_obj_check_type(obj, &lv_slider_class))   return lv_slider_get_value(obj);
#endif
#if LV_USE_ARC
    if(lv_obj_check_type(obj, &lv_arc_class))      return lv_arc_get_value(obj);
#endif
#if LV_USE_SPINBOX
    if(lv_obj_check_type(obj, &lv_spinbox_class))  return lv_spinbox_get_value(obj);
#endif
#if LV_USE_BAR
    if(lv_obj_check_type(obj, &lv_bar_class))      return lv_bar_get_value(obj);
#endif
#if LV_USE_DROPDOWN
    if(lv_obj_check_type(obj, &lv_dropdown_class)) return (int32_t)lv_dropdown_get_selected(obj);
#endif
#if LV_USE_ROLLER
    if(lv_obj_check_type(obj, &lv_roller_class))   return (int32_t)lv_roller_get_selected(obj);
#endif
#if LV_USE_CHECKBOX
    if(lv_obj_check_type(obj, &lv_checkbox_class))
        return lv_obj_has_state(obj, LV_STATE_CHECKED) ? 1 : 0;
#endif
#if LV_USE_SWITCH
    if(lv_obj_check_type(obj, &lv_switch_class))
        return lv_obj_has_state(obj, LV_STATE_CHECKED) ? 1 : 0;
#endif
#if LV_USE_CHART
    /* A chart reports VALUE_CHANGED when a point is pressed. */
    if(lv_obj_check_type(obj, &lv_chart_class))    return (int32_t)lv_chart_get_pressed_point(obj);
#endif
    return 0;
}

void plv_on_event(lv_event_t * e)
{
    lv_event_code_t code = lv_event_get_code(e);
    lv_obj_t * target = (lv_obj_t *)lv_event_get_target(e);
    plv_event_t rec;
    double handle;

    if(code == LV_EVENT_DELETE) {
        plv_handle_release_obj(target);
#if LV_USE_CHART
        /* A chart frees its series and cursors with itself, so their handles
         * go stale here too. Only charts own resources, and the type check
         * keeps a Shutdown of thousands of objects from scanning the
         * resource table once per object. */
        if(lv_obj_check_type(target, &lv_chart_class)) plv_res_release_owned_by(target);
#endif
        return;
    }

    if(!g_plv.events) return;
    if((uint32_t)code >= PLV_EVENT_MASK_BITS) return;

    handle = plv_handle_of(target);
    if(handle == 0.0) return;
    if(!plv_handle_event_subscribed(handle, (uint32_t)code)) return;

    rec.target = (uint32_t)handle;
    rec.code   = (uint32_t)code;
    rec.current_target = (uint32_t)plv_handle_of((lv_obj_t *)lv_event_get_current_target(e));
    rec.time   = g_plv.t_now;

    if(code == LV_EVENT_VALUE_CHANGED)   rec.param = plv_value_of(target);
    else if(code == LV_EVENT_KEY)        rec.param = (int32_t)lv_event_get_key(e);
    else                                 rec.param = 0;

    plv_events_push(&rec);
}

void plv_events_attach(lv_obj_t * obj)
{
    lv_obj_add_event_cb(obj, plv_on_event, LV_EVENT_ALL, NULL);
}
