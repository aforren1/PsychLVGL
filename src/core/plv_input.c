/**
 * @file plv_input.c
 * Three indevs in LV_INDEV_MODE_EVENT: pointer, encoder, keypad.
 *
 * Event mode means LVGL reads the devices only when Update calls
 * lv_indev_read, so input and rendering stay on the script frame clock.
 */
#include "plv_internal.h"

static void plv_pointer_read(lv_indev_t * indev, lv_indev_data_t * data)
{
    LV_UNUSED(indev);
    data->point.x = g_plv.pointer.x;
    data->point.y = g_plv.pointer.y;
    data->state   = g_plv.pointer.pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}

static void plv_encoder_read(lv_indev_t * indev, lv_indev_data_t * data)
{
    LV_UNUSED(indev);
    data->enc_diff = g_plv.enc_diff;
    data->state    = LV_INDEV_STATE_RELEASED;
    g_plv.enc_diff = 0;
}

static void plv_keypad_read(lv_indev_t * indev, lv_indev_data_t * data)
{
    LV_UNUSED(indev);
    if(g_plv.key_head == g_plv.key_tail) {
        data->key   = 0;
        data->state = LV_INDEV_STATE_RELEASED;
        return;
    }
    {
        plv_key_t k = g_plv.keyring[g_plv.key_tail % PLV_KEYRING_SIZE];
        g_plv.key_tail++;
        data->key   = k.key;
        data->state = k.pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
        data->continue_reading = (g_plv.key_head != g_plv.key_tail);
    }
}

int plv_input_init(plv_err_t * err)
{
    g_plv.group = lv_group_create();
    if(!g_plv.group)
        return plv_fail(err, "psychlvgl:GLInit", "could not create the default focus group");
    lv_group_set_default(g_plv.group);

    g_plv.indev_pointer = lv_indev_create();
    g_plv.indev_encoder = lv_indev_create();
    g_plv.indev_keypad  = lv_indev_create();
    if(!g_plv.indev_pointer || !g_plv.indev_encoder || !g_plv.indev_keypad)
        return plv_fail(err, "psychlvgl:GLInit", "could not create the input devices");

    lv_indev_set_type(g_plv.indev_pointer, LV_INDEV_TYPE_POINTER);
    lv_indev_set_read_cb(g_plv.indev_pointer, plv_pointer_read);
    lv_indev_set_mode(g_plv.indev_pointer, LV_INDEV_MODE_EVENT);
    lv_indev_set_display(g_plv.indev_pointer, g_plv.disp);

    lv_indev_set_type(g_plv.indev_encoder, LV_INDEV_TYPE_ENCODER);
    lv_indev_set_read_cb(g_plv.indev_encoder, plv_encoder_read);
    lv_indev_set_mode(g_plv.indev_encoder, LV_INDEV_MODE_EVENT);
    lv_indev_set_display(g_plv.indev_encoder, g_plv.disp);
    lv_indev_set_group(g_plv.indev_encoder, g_plv.group);

    lv_indev_set_type(g_plv.indev_keypad, LV_INDEV_TYPE_KEYPAD);
    lv_indev_set_read_cb(g_plv.indev_keypad, plv_keypad_read);
    lv_indev_set_mode(g_plv.indev_keypad, LV_INDEV_MODE_EVENT);
    lv_indev_set_display(g_plv.indev_keypad, g_plv.disp);
    lv_indev_set_group(g_plv.indev_keypad, g_plv.group);

    return 0;
}

void plv_input_deinit(void)
{
    /* The persistent back end keeps LVGL alive across Shutdown, so the indevs
     * and the group have to go by hand. lv_deinit does it in the other build,
     * which is why this runs before lv_deinit there. */
    if(g_plv.indev_pointer) lv_indev_delete(g_plv.indev_pointer);
    if(g_plv.indev_encoder) lv_indev_delete(g_plv.indev_encoder);
    if(g_plv.indev_keypad)  lv_indev_delete(g_plv.indev_keypad);
    if(g_plv.group) {
        lv_group_set_default(NULL);
        lv_group_delete(g_plv.group);
    }
    g_plv.indev_pointer = NULL;
    g_plv.indev_encoder = NULL;
    g_plv.indev_keypad  = NULL;
    g_plv.group         = NULL;
}

void plv_input_set_pointer(const plv_pointer_t * p)
{
    int32_t x = p->x;
    int32_t y = p->y;
    int inside = (x >= 0 && y >= 0 && x < g_plv.w && y < g_plv.h);

    /* Clamp to the panel and report released when the point left it, so a
     * drag that leaves the panel ends cleanly instead of sticking. */
    if(x < 0) x = 0;
    if(y < 0) y = 0;
    if(x > g_plv.w - 1) x = g_plv.w - 1;
    if(y > g_plv.h - 1) y = g_plv.h - 1;

    g_plv.pointer.x = x;
    g_plv.pointer.y = y;
    g_plv.pointer.pressed = (p->pressed && inside) ? 1 : 0;
}

void plv_input_push_key(uint32_t key, uint8_t pressed)
{
    if(g_plv.key_head - g_plv.key_tail >= PLV_KEYRING_SIZE) {
        g_plv.key_tail++;   /* drop the oldest; never grow on the frame path */
    }
    g_plv.keyring[g_plv.key_head % PLV_KEYRING_SIZE].key     = key;
    g_plv.keyring[g_plv.key_head % PLV_KEYRING_SIZE].pressed = pressed;
    g_plv.key_head++;
}

void plv_input_set_wheel(double wheel)
{
    int32_t clicks = (int32_t)(wheel < 0 ? wheel - 0.5 : wheel + 0.5);
    if(clicks == 0) return;

    if(g_plv.wheel_mode == PLV_WHEEL_KEYS) {
        int32_t i;
        int32_t n = clicks < 0 ? -clicks : clicks;
        uint32_t key = (clicks > 0) ? LV_KEY_UP : LV_KEY_DOWN;
        for(i = 0; i < n; i++) {
            plv_input_push_key(key, 1);
            plv_input_push_key(key, 0);
        }
    }
    else {
        /* Wheel up is a negative encoder step, which is what LVGL treats as
         * "previous" for lists and "increase" for value widgets. */
        int32_t d = (int32_t)g_plv.enc_diff - clicks;
        if(d > 32767) d = 32767;
        if(d < -32768) d = -32768;
        g_plv.enc_diff = (int16_t)d;
    }
}

void plv_input_pump(void)
{
    uint32_t guard;

    lv_indev_read(g_plv.indev_pointer);
    lv_indev_read(g_plv.indev_encoder);

    /* In event mode continue_reading is ignored, so drain the ring here. */
    for(guard = 0; guard < PLV_KEYRING_SIZE && g_plv.key_head != g_plv.key_tail; guard++)
        lv_indev_read(g_plv.indev_keypad);
}
