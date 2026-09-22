/**
 * @file psychlvgl.c
 * mexFunction, dispatch, and the hand written subcommands.
 *
 * The MEX holds the whole binding; the LVGL-facing half lives in src/core and
 * knows nothing about MATLAB, so a native test can drive the same code.
 */
#include "plv_marshal.h"
#include "plv_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef PSYCHLVGL_VERSION
#define PSYCHLVGL_VERSION "0.1.0"
#endif

/* ------------------------------------------------------------------ helpers */

static void plv_print(const char * text)
{
    mexPrintf("%s", text);
}

static double plv_opt_num(const mxArray * opts, const char * field, double dflt)
{
    const mxArray * f = mxGetField(opts, 0, field);
    if(!f) return dflt;
    if(mxGetNumberOfElements(f) != 1)
        mexErrMsgIdAndTxt("psychlvgl:Usage", "option %s must be a scalar", field);
    return mxGetScalar(f);
}

static void plv_opt_str(const mxArray * opts, const char * field, char * dst, size_t n)
{
    const mxArray * f = mxGetField(opts, 0, field);
    dst[0] = 0;
    if(!f) return;
    if(!mxIsChar(f))
        mexErrMsgIdAndTxt("psychlvgl:Usage", "option %s must be a char row vector", field);
    mxGetString(f, dst, (mwSize)n);
}

/* ------------------------------------------------------------- lifecycle ops */

static void plv_at_exit(void)
{
    /* MATLAB is unloading the MEX. LVGL state would otherwise outlive it. */
    plv_shutdown();
}

static void op_Init(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    plv_init_opts_t o;
    plv_err_t err;
    unsigned int tex = 0;
    char buf[64];

    if(nrhs < 3 || nrhs > 4)
        mexErrMsgIdAndTxt("psychlvgl:Usage",
                          "Usage: glTex = PsychLVGL('Init', w, h [, opts])");

    plv_opts_default(&o);
    o.w = (int32_t)plv_arg_int(prhs[1], 1, 1, 16384);
    o.h = (int32_t)plv_arg_int(prhs[2], 2, 1, 16384);

    if(nrhs == 4) {
        if(!mxIsStruct(prhs[3]))
            mexErrMsgIdAndTxt("psychlvgl:Usage", "opts must be a struct");
        o.queue_capacity = (uint32_t)plv_opt_num(prhs[3], "QueueCapacity",
                                                 (double)o.queue_capacity);
        o.max_objects    = (uint32_t)plv_opt_num(prhs[3], "MaxObjects",
                                                 (double)o.max_objects);
        o.log_level      = (int)plv_opt_num(prhs[3], "LogLevel", (double)o.log_level);

        plv_opt_str(prhs[3], "FontDefault", buf, sizeof(buf));
        if(buf[0]) {
            o.font_default = plv_font_lookup(buf);
            if(!o.font_default)
                mexErrMsgIdAndTxt("psychlvgl:Font", "unknown font '%s'", buf);
        }
        plv_opt_str(prhs[3], "WheelMode", buf, sizeof(buf));
        if(buf[0]) {
            if(strcmp(buf, "encoder") == 0)   o.wheel_mode = PLV_WHEEL_ENCODER;
            else if(strcmp(buf, "keys") == 0) o.wheel_mode = PLV_WHEEL_KEYS;
            else mexErrMsgIdAndTxt("psychlvgl:Usage",
                                   "WheelMode must be 'encoder' or 'keys'");
        }
        plv_opt_str(prhs[3], "Theme", buf, sizeof(buf));
        if(buf[0]) {
            if(strcmp(buf, "default") == 0)    o.theme = PLV_THEME_DEFAULT;
            else if(strcmp(buf, "dark") == 0)  o.theme = PLV_THEME_DARK;
            else if(strcmp(buf, "light") == 0) o.theme = PLV_THEME_LIGHT;
            else mexErrMsgIdAndTxt("psychlvgl:Usage",
                                   "Theme must be 'default', 'dark' or 'light'");
        }
    }

    if(plv_is_initialized()) {
        /* R5: a new size means a new texture, so tear down and start over.
         * The same size twice is a script bug worth reporting. */
        if(plv_panel_width() == o.w && plv_panel_height() == o.h)
            mexErrMsgIdAndTxt("psychlvgl:AlreadyInitialized",
                              "PsychLVGL is already initialized at %dx%d",
                              (int)o.w, (int)o.h);
        plv_shutdown();
        mexUnlock();
    }

    plv_set_print_fn(plv_print);
    if(plv_init(&o, &tex, &err)) plv_raise(&err);

    mexLock();
    mexAtExit(plv_at_exit);

    (void)nlhs;
    plhs[0] = mxCreateDoubleScalar((double)tex);
}

static void op_Shutdown(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)plhs; (void)prhs;
    if(nrhs != 1) mexErrMsgIdAndTxt("psychlvgl:Usage", "Usage: PsychLVGL('Shutdown')");
    if(!plv_is_initialized()) return;
    plv_shutdown();
    mexUnlock();
}

static void op_Update(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    plv_err_t err;
    plv_pointer_t ptr;
    plv_key_t keys[PLV_KEYRING_SIZE];
    uint32_t n_keys = 0;
    double wheel = 0.0;
    double t_now;
    int dirty = 0;

    if(nrhs < 2 || nrhs > 5)
        mexErrMsgIdAndTxt("psychlvgl:Usage",
                          "Usage: dirty = PsychLVGL('Update', tNow, mouse, wheel, keys)");
    plv_need_init("Update");

    t_now = plv_arg_double(prhs[1], 1);

    memset(&ptr, 0, sizeof(ptr));
    if(nrhs >= 3 && !mxIsEmpty(prhs[2])) {
        const double * m;
        if(!mxIsDouble(prhs[2]) || mxGetNumberOfElements(prhs[2]) != 3)
            mexErrMsgIdAndTxt("psychlvgl:Usage", "mouse must be [x y pressed]");
        m = mxGetPr(prhs[2]);
        ptr.x = (int32_t)m[0];
        ptr.y = (int32_t)m[1];
        ptr.pressed = m[2] != 0.0;
    }
    else {
        /* No mouse this frame: keep the last position, report released. */
        ptr.x = 0;
        ptr.y = 0;
        ptr.pressed = 0;
    }

    if(nrhs >= 4 && !mxIsEmpty(prhs[3])) wheel = plv_arg_double(prhs[3], 3);

    if(nrhs >= 5 && !mxIsEmpty(prhs[4])) {
        const double * k;
        mwSize rows, cols, i;
        if(!mxIsDouble(prhs[4]) || mxGetNumberOfDimensions(prhs[4]) != 2)
            mexErrMsgIdAndTxt("psychlvgl:Usage", "keys must be an Nx2 double matrix");
        rows = mxGetM(prhs[4]);
        cols = mxGetN(prhs[4]);
        if(cols != 2)
            mexErrMsgIdAndTxt("psychlvgl:Usage", "keys must be an Nx2 double matrix");
        if(rows > PLV_KEYRING_SIZE) rows = PLV_KEYRING_SIZE;
        k = mxGetPr(prhs[4]);
        for(i = 0; i < rows; i++) {
            keys[i].key     = (uint32_t)k[i];
            keys[i].pressed = (uint8_t)(k[i + mxGetM(prhs[4])] != 0.0);
        }
        n_keys = (uint32_t)rows;
    }

    if(plv_update(t_now, &ptr, wheel, keys, n_keys, &dirty, &err)) plv_raise(&err);

    (void)nlhs;
    plhs[0] = mxCreateDoubleScalar(dirty ? 1.0 : 0.0);
}

static void op_Poll(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    plv_event_t rec[256];
    mxArray * out;
    double * p;
    uint32_t total, got, row;

    (void)nlhs; (void)prhs;
    if(nrhs != 1) mexErrMsgIdAndTxt("psychlvgl:Usage", "Usage: E = PsychLVGL('Poll')");
    plv_need_init("Poll");

    total = plv_events_available();
    out = mxCreateDoubleMatrix((mwSize)total, 5, mxREAL);
    p = mxGetPr(out);
    row = 0;
    while(row < total) {
        uint32_t i;
        got = plv_events_drain(rec, 256);
        if(got == 0) break;
        for(i = 0; i < got; i++, row++) {
            p[row]             = (double)rec[i].target;
            p[row + total]     = (double)rec[i].code;
            p[row + 2 * total] = (double)rec[i].current_target;
            p[row + 3 * total] = (double)rec[i].param;
            p[row + 4 * total] = rec[i].time;
        }
    }
    plhs[0] = out;
}

static void op_Version(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    static const char * fields[] = { "lvgl", "psychlvgl", "nanovgBackend",
                                     "glVersion", "glRenderer", "build" };
    char lvglver[32];
    mxArray * s;

    (void)nlhs; (void)nrhs; (void)prhs;
    s = mxCreateStructMatrix(1, 1, 6, fields);
    sprintf(lvglver, "%d.%d.%d", LVGL_VERSION_MAJOR, LVGL_VERSION_MINOR,
            LVGL_VERSION_PATCH);
    mxSetField(s, 0, "lvgl", mxCreateString(lvglver));
    mxSetField(s, 0, "psychlvgl", mxCreateString(PSYCHLVGL_VERSION));
    mxSetField(s, 0, "nanovgBackend", mxCreateString(plv_nanovg_backend_name()));
    mxSetField(s, 0, "glVersion", mxCreateString(plv_gl_version_string()));
    mxSetField(s, 0, "glRenderer", mxCreateString(plv_gl_renderer_string()));
    mxSetField(s, 0, "build", mxCreateString(plv_build_string()));
    plhs[0] = s;
}

/* -------------------------------------------------------------- dispatch table */

static void op_Opcode(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_Stats(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_StatsAddFrame(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_Enum(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_FontList(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_Log(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ScreenActive(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ScreenCreate(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ScreenLoad(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ObjDelete(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_IsValid(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_AddEvent(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_RemoveEvent(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_AddToGroup(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_RemoveFromGroup(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_FocusObj(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_EventName(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_FrameChecksum(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);

/* The order here fixes the opcodes, and m/PsychLVGLOp.m repeats it. */
static const plv_op_entry_t plv_hand_ops[] = {
    { "Init",            op_Init },
    { "Shutdown",        op_Shutdown },
    { "Update",          op_Update },
    { "Poll",            op_Poll },
    { "Version",         op_Version },
    { "Opcode",          op_Opcode },
    { "Stats",           op_Stats },
    { "StatsAddFrame",   op_StatsAddFrame },
    { "Enum",            op_Enum },
    { "FontList",        op_FontList },
    { "Log",             op_Log },
    { "ScreenActive",    op_ScreenActive },
    { "ScreenCreate",    op_ScreenCreate },
    { "ScreenLoad",      op_ScreenLoad },
    { "ObjDelete",       op_ObjDelete },
    { "IsValid",         op_IsValid },
    { "AddEvent",        op_AddEvent },
    { "RemoveEvent",     op_RemoveEvent },
    { "AddToGroup",      op_AddToGroup },
    { "RemoveFromGroup", op_RemoveFromGroup },
    { "FocusObj",        op_FocusObj },
    { "EventName",       op_EventName },
    { "FrameChecksum",   op_FrameChecksum }
};

#define PLV_HAND_COUNT ((int)(sizeof(plv_hand_ops) / sizeof(plv_hand_ops[0])))

static const plv_op_entry_t * plv_entry(int opcode)
{
    if(opcode < 1) return NULL;
    if(opcode <= PLV_HAND_COUNT) return &plv_hand_ops[opcode - 1];
    if(opcode <= PLV_HAND_COUNT + plv_gen_op_count)
        return &plv_gen_ops[opcode - PLV_HAND_COUNT - 1];
    return NULL;
}

static int  s_sorted[PLV_MAX_OPCODES];
static int  s_sorted_n;

static int plv_sort_cmp(const void * a, const void * b)
{
    return strcmp(plv_entry(*(const int *)a)->name, plv_entry(*(const int *)b)->name);
}

static void plv_build_index(void)
{
    int i, n = PLV_HAND_COUNT + plv_gen_op_count;
    if(s_sorted_n) return;
    if(n > PLV_MAX_OPCODES) n = PLV_MAX_OPCODES;
    for(i = 0; i < n; i++) s_sorted[i] = i + 1;
    qsort(s_sorted, (size_t)n, sizeof(int), plv_sort_cmp);
    s_sorted_n = n;
}

static int plv_find(const char * name)
{
    int lo = 0, hi = s_sorted_n - 1;
    while(lo <= hi) {
        int mid = (lo + hi) / 2;
        int c = strcmp(name, plv_entry(s_sorted[mid])->name);
        if(c == 0) return s_sorted[mid];
        if(c < 0) hi = mid - 1;
        else lo = mid + 1;
    }
    return 0;
}

/* ------------------------------------------------------- hand written bodies */

static void op_Opcode(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    char name[64];
    int op;
    (void)nlhs;
    if(nrhs != 2 || !mxIsChar(prhs[1]))
        mexErrMsgIdAndTxt("psychlvgl:Usage", "Usage: op = PsychLVGL('Opcode', name)");
    mxGetString(prhs[1], name, sizeof(name));
    op = plv_find(name);
    if(op == 0)
        mexErrMsgIdAndTxt("psychlvgl:UnknownCommand", "unknown subcommand '%s'", name);
    plhs[0] = mxCreateDoubleScalar((double)op);
}

static void op_Stats(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    static const char * fields[] = {
        "updateLastNs", "updateMaxNs", "updateSumNs", "updateCount",
        "gpuLastNs", "gpuMaxNs", "flushCount", "eventsDropped",
        "queueHighWater", "tickAnomaly", "frameLastNs", "frameMaxNs",
        "frameSumNs", "frameCount", "liveObjects",
        "opNames", "opCalls", "opTotalNs", "opMaxNs"
    };
    plv_stats_t * st = plv_stats();
    mxArray * s;
    mxArray * names;
    mxArray * calls;
    mxArray * total;
    mxArray * maxns;
    int i, n = 0, k = 0;

    (void)nlhs;
    if(nrhs == 2) {
        char what[16];
        mxGetString(prhs[1], what, sizeof(what));
        if(strcmp(what, "reset") != 0)
            mexErrMsgIdAndTxt("psychlvgl:Usage", "Stats takes no argument or 'reset'");
        plv_stats_reset();
        plhs[0] = mxCreateDoubleMatrix(0, 0, mxREAL);
        return;
    }

    for(i = 0; i < PLV_MAX_OPCODES; i++) if(st->op[i].calls) n++;

    s = mxCreateStructMatrix(1, 1, 19, fields);
    mxSetField(s, 0, "updateLastNs", mxCreateDoubleScalar((double)st->update_last_ns));
    mxSetField(s, 0, "updateMaxNs",  mxCreateDoubleScalar((double)st->update_max_ns));
    mxSetField(s, 0, "updateSumNs",  mxCreateDoubleScalar((double)st->update_sum_ns));
    mxSetField(s, 0, "updateCount",  mxCreateDoubleScalar((double)st->update_count));
    mxSetField(s, 0, "gpuLastNs",    mxCreateDoubleScalar((double)st->gpu_last_ns));
    mxSetField(s, 0, "gpuMaxNs",     mxCreateDoubleScalar((double)st->gpu_max_ns));
    mxSetField(s, 0, "flushCount",   mxCreateDoubleScalar((double)st->flush_count));
    mxSetField(s, 0, "eventsDropped", mxCreateDoubleScalar((double)st->events_dropped));
    mxSetField(s, 0, "queueHighWater", mxCreateDoubleScalar((double)st->queue_high_water));
    mxSetField(s, 0, "tickAnomaly",  mxCreateDoubleScalar((double)st->tick_anomaly));
    mxSetField(s, 0, "frameLastNs",  mxCreateDoubleScalar((double)st->frame_last_ns));
    mxSetField(s, 0, "frameMaxNs",   mxCreateDoubleScalar((double)st->frame_max_ns));
    mxSetField(s, 0, "frameSumNs",   mxCreateDoubleScalar((double)st->frame_sum_ns));
    mxSetField(s, 0, "frameCount",   mxCreateDoubleScalar((double)st->frame_count));
    mxSetField(s, 0, "liveObjects",
               mxCreateDoubleScalar(plv_is_initialized() ?
                                    (double)plv_handle_live_count() : 0.0));

    names = mxCreateCellMatrix((mwSize)n, 1);
    calls = mxCreateDoubleMatrix((mwSize)n, 1, mxREAL);
    total = mxCreateDoubleMatrix((mwSize)n, 1, mxREAL);
    maxns = mxCreateDoubleMatrix((mwSize)n, 1, mxREAL);
    for(i = 0; i < PLV_MAX_OPCODES; i++) {
        const plv_op_entry_t * e;
        if(!st->op[i].calls) continue;
        e = plv_entry(i);
        mxSetCell(names, k, mxCreateString(e ? e->name : "?"));
        mxGetPr(calls)[k] = (double)st->op[i].calls;
        mxGetPr(total)[k] = (double)st->op[i].total_ns;
        mxGetPr(maxns)[k] = (double)st->op[i].max_ns;
        k++;
    }
    mxSetField(s, 0, "opNames", names);
    mxSetField(s, 0, "opCalls", calls);
    mxSetField(s, 0, "opTotalNs", total);
    mxSetField(s, 0, "opMaxNs", maxns);
    plhs[0] = s;
}

static void op_StatsAddFrame(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)plhs;
    if(nrhs != 2)
        mexErrMsgIdAndTxt("psychlvgl:Usage", "Usage: PsychLVGL('StatsAddFrame', dt)");
    plv_stats_add_frame(plv_arg_double(prhs[1], 1));
}

static void op_Enum(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs;
    if(nrhs != 2 || !mxIsChar(prhs[1]))
        mexErrMsgIdAndTxt("psychlvgl:Usage", "Usage: v = PsychLVGL('Enum', name)");
    plhs[0] = mxCreateDoubleScalar(plv_arg_enum(prhs[1], 1));
}

static void op_FontList(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    int n = 0;
    int i;
    mxArray * c;
    (void)nlhs; (void)nrhs; (void)prhs;
    while(plv_font_name(n)) n++;
    c = mxCreateCellMatrix((mwSize)n, 1);
    for(i = 0; i < n; i++) mxSetCell(c, i, mxCreateString(plv_font_name(i)));
    plhs[0] = c;
}

static void op_Log(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)plhs;
    if(nrhs != 2) mexErrMsgIdAndTxt("psychlvgl:Usage", "Usage: PsychLVGL('Log', level)");
    plv_set_log_level((int)plv_arg_int(prhs[1], 1, 0, 5));
}

static void op_ScreenActive(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    lv_obj_t * scr;
    (void)nlhs; (void)prhs; (void)nrhs;
    plv_need_init("ScreenActive");
    scr = lv_screen_active();
    plhs[0] = plv_ret_obj(scr);
}

static void op_ScreenCreate(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    lv_obj_t * scr;
    (void)nlhs; (void)prhs; (void)nrhs;
    plv_need_init("ScreenCreate");
    scr = lv_obj_create(NULL);
    plhs[0] = plv_ret_obj(scr);
}

static void op_ScreenLoad(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 1, 1, "ScreenLoad");
    lv_screen_load(plv_arg_obj(prhs[1], 1));
    plv_check_deferred();
}

static void op_ObjDelete(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 1, 1, "ObjDelete");
    lv_obj_delete(plv_arg_obj(prhs[1], 1));
    plv_check_deferred();
}

static void op_IsValid(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    double h;
    (void)nlhs;
    if(nrhs != 2) mexErrMsgIdAndTxt("psychlvgl:Usage", "Usage: tf = PsychLVGL('IsValid', h)");
    plv_need_init("IsValid");
    h = plv_arg_double(prhs[1], 1);
    plhs[0] = mxCreateLogicalScalar(plv_handle_is_valid(h) ? 1 : 0);
}

static double plv_event_code_from_name(const mxArray * a, int pos)
{
    plv_strbuf_t buf;
    char prefixed[96];
    const char * s = plv_arg_str(a, pos, &buf);
    double v;
    int ok;

    if(strncmp(s, "LV_EVENT_", 9) == 0) ok = plv_enum_lookup(s, &v);
    else {
        strcpy(prefixed, "LV_EVENT_");
        strncat(prefixed, s, sizeof(prefixed) - 10);
        ok = plv_enum_lookup(prefixed, &v);
    }
    plv_strbuf_free(&buf);
    if(!ok) mexErrMsgIdAndTxt("psychlvgl:Enum", "unknown event name");
    return v;
}

static void plv_edit_event(int nrhs, const mxArray * prhs[], int on, const char * name)
{
    plv_err_t err;
    double h;
    double code;

    plv_need_args(nrhs, 2, 2, name);
    h = plv_arg_double(prhs[1], 1);
    if(mxIsChar(prhs[2])) code = plv_event_code_from_name(prhs[2], 2);
    else code = plv_arg_int(prhs[2], 2, 0, 127);
    if(plv_handle_set_event_bit(h, (uint32_t)code, on, &err)) plv_raise(&err);
}

static void op_AddEvent(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)plhs;
    plv_edit_event(nrhs, prhs, 1, "AddEvent");
}

static void op_RemoveEvent(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)plhs;
    plv_edit_event(nrhs, prhs, 0, "RemoveEvent");
}

static void op_AddToGroup(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 1, 1, "AddToGroup");
    lv_group_add_obj(plv_group(), plv_arg_obj(prhs[1], 1));
    plv_check_deferred();
}

static void op_RemoveFromGroup(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 1, 1, "RemoveFromGroup");
    lv_group_remove_obj(plv_arg_obj(prhs[1], 1));
    plv_check_deferred();
}

static void op_FocusObj(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 1, 1, "FocusObj");
    lv_group_focus_obj(plv_arg_obj(prhs[1], 1));
    plv_check_deferred();
}

static void op_EventName(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    double code;
    int i;
    (void)nlhs;
    if(nrhs != 2)
        mexErrMsgIdAndTxt("psychlvgl:Usage", "Usage: name = PsychLVGL('EventName', code)");
    code = plv_arg_int(prhs[1], 1, 0, 65535);
    for(i = 0; i < plv_enum_count; i++) {
        if(strncmp(plv_enum_table[i].name, "LV_EVENT_", 9) != 0) continue;
        if(plv_enum_table[i].value != code) continue;
        plhs[0] = mxCreateString(plv_enum_table[i].name + 9);
        return;
    }
    mexErrMsgIdAndTxt("psychlvgl:Enum", "no event has code %g", code);
}

static void op_FrameChecksum(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)nrhs; (void)prhs;
    plv_need_init("FrameChecksum");
    plhs[0] = mxCreateDoubleScalar((double)plv_frame_checksum());
}

/* --------------------------------------------------------------- mexFunction */

static void plv_print_list(void)
{
    int i;
    mexPrintf("PsychLVGL subcommands (%d):\n", PLV_HAND_COUNT + plv_gen_op_count);
    for(i = 0; i < s_sorted_n; i++) {
        mexPrintf("  %-32s", plv_entry(s_sorted[i])->name);
        if((i % 2) == 1) mexPrintf("\n");
    }
    if((s_sorted_n % 2) != 0) mexPrintf("\n");
    mexPrintf("PsychLVGL('Name?') is not implemented yet; see help PsychLVGL.\n");
}

void mexFunction(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    char name[64];
    int opcode = 0;
    const plv_op_entry_t * e;
    uint64_t t0;

    plv_build_index();
    plv_set_print_fn(plv_print);

    if(nrhs == 0) {
        plv_print_list();
        return;
    }

    if(mxIsChar(prhs[0])) {
        if(mxGetString(prhs[0], name, sizeof(name)) != 0)
            mexErrMsgIdAndTxt("psychlvgl:UnknownCommand", "subcommand name is too long");
        opcode = plv_find(name);
        if(opcode == 0)
            mexErrMsgIdAndTxt("psychlvgl:UnknownCommand", "unknown subcommand '%s'", name);
    }
    else if(mxIsNumeric(prhs[0]) && mxGetNumberOfElements(prhs[0]) == 1) {
        opcode = (int)mxGetScalar(prhs[0]);
    }
    else {
        mexErrMsgIdAndTxt("psychlvgl:Usage",
                          "the first argument must be a subcommand name or an opcode");
    }

    e = plv_entry(opcode);
    if(!e) mexErrMsgIdAndTxt("psychlvgl:UnknownCommand", "opcode %d is out of range", opcode);

    t0 = plv_now_ns();
    e->fn(nlhs, plhs, nrhs, prhs);
    plv_stats_add_op((uint32_t)opcode, plv_now_ns() - t0);
}
