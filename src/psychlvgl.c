/**
 * @file psychlvgl.c
 * mexFunction, dispatch, and the hand written subcommands.
 *
 * The MEX holds the whole binding; the LVGL-facing half lives in src/core and
 * knows nothing about MATLAB, so a native test can drive the same code.
 */
#include "plv_marshal.h"
#include "plv_internal.h"
#include "plv_xml.h"

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
static void op_StyleCreate(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_StyleDelete(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_StyleSetProp(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ObjAddStyle(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ObjRemoveStyle(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ObjRemoveStyleAll(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ImageFromTexture(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ImageFromArray(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ImageDelete(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_FontLoad(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_FontDelete(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ChartSetValues(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ChartGetValues(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);
static void op_ParseXML(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);

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
    { "FrameChecksum",   op_FrameChecksum },
    { "StyleCreate",     op_StyleCreate },
    { "StyleDelete",     op_StyleDelete },
    { "StyleSetProp",    op_StyleSetProp },
    { "ObjAddStyle",     op_ObjAddStyle },
    { "ObjRemoveStyle",  op_ObjRemoveStyle },
    { "ObjRemoveStyleAll", op_ObjRemoveStyleAll },
    { "ImageFromTexture", op_ImageFromTexture },
    { "ImageFromArray",  op_ImageFromArray },
    { "ImageDelete",     op_ImageDelete },
    { "FontLoad",        op_FontLoad },
    { "FontDelete",      op_FontDelete },
    { "ChartSetValues",  op_ChartSetValues },
    { "ChartGetValues",  op_ChartGetValues },
    { "ParseXML",        op_ParseXML }
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
    /* One call for both tables: the two handle ranges cannot overlap. */
    plhs[0] = mxCreateLogicalScalar((plv_handle_is_valid(h) || plv_res_kind(h) != PLV_RES_NONE)
                                    ? 1 : 0);
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

/* ------------------------------------------------------------------ styles */

static void op_StyleCreate(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    plv_err_t err;
    double h;
    (void)nlhs; (void)prhs;
    plv_need_args(nrhs, 0, 0, "StyleCreate");
    h = plv_style_create(&err);
    if(h == 0.0) plv_raise(&err);
    plhs[0] = mxCreateDoubleScalar(h);
}

static void op_StyleDelete(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    plv_err_t err;
    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 1, 1, "StyleDelete");
    if(plv_style_delete(plv_arg_res_handle(prhs[1], 1), &err)) plv_raise(&err);
}

static void op_StyleSetProp(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    char name[64];
    lv_style_t * s;
    plv_style_setter_t fn;

    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 3, 3, "StyleSetProp");
    s = plv_arg_style(prhs[1], 1);
    if(!mxIsChar(prhs[2]) || mxGetString(prhs[2], name, sizeof(name)) != 0)
        mexErrMsgIdAndTxt("psychlvgl:Type",
                          "argument 2 must be a style property name such as 'bg_color'");
    fn = plv_style_prop_lookup(name);
    if(!fn)
        mexErrMsgIdAndTxt("psychlvgl:Enum",
                          "unknown style property '%s'; the names are those of the "
                          "ObjSetStyle<Prop> subcommands, for example 'bg_color'", name);
    fn(s, prhs[3], 3);
    /* Objects cache what their styles resolve to, so a style already in use
     * has to announce the change. */
    lv_obj_report_style_change(s);
    plv_check_deferred();
}

static lv_style_selector_t plv_selector_arg(int nrhs, const mxArray * prhs[], int pos,
                                            lv_style_selector_t dflt)
{
    if(nrhs <= pos) return dflt;
    return (lv_style_selector_t)plv_arg_enum(prhs[pos], pos);
}

static void op_ObjAddStyle(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    lv_obj_t * obj;
    lv_style_t * s;
    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 2, 3, "ObjAddStyle");
    obj = plv_arg_obj(prhs[1], 1);
    s = plv_arg_style(prhs[2], 2);
    lv_obj_add_style(obj, s, plv_selector_arg(nrhs, prhs, 3, LV_PART_MAIN));
    plv_check_deferred();
}

static void op_ObjRemoveStyle(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    lv_obj_t * obj;
    const lv_style_t * s = NULL;
    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 2, 3, "ObjRemoveStyle");
    obj = plv_arg_obj(prhs[1], 1);
    /* Style 0 means every style that matches the selector, as in LVGL. */
    if(!(mxIsDouble(prhs[2]) && mxGetNumberOfElements(prhs[2]) == 1 && mxGetScalar(prhs[2]) == 0.0))
        s = plv_arg_style(prhs[2], 2);
    /* Without a selector every entry of the style goes, whatever part and
     * state it was added for, which is what a script usually means. */
    lv_obj_remove_style(obj, s, plv_selector_arg(nrhs, prhs, 3,
                                                 (lv_style_selector_t)LV_PART_ANY | LV_STATE_ANY));
    plv_check_deferred();
}

static void op_ObjRemoveStyleAll(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 1, 1, "ObjRemoveStyleAll");
    lv_obj_remove_style_all(plv_arg_obj(prhs[1], 1));
    plv_check_deferred();
}

/* ------------------------------------------------------------------ images */

static void op_ImageFromTexture(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    plv_err_t err;
    double h;
    uint32_t tex;
    int32_t w, hh;
    int transposed = 0;
    (void)nlhs;
    plv_need_args(nrhs, 3, 4, "ImageFromTexture");
    tex = (uint32_t)plv_arg_int(prhs[1], 1, 1, 4294967295.0);
    w   = (int32_t)plv_arg_int(prhs[2], 2, 1, PLV_IMAGE_MAX_SIDE);
    hh  = (int32_t)plv_arg_int(prhs[3], 3, 1, PLV_IMAGE_MAX_SIDE);
    if(nrhs > 4) transposed = plv_arg_bool(prhs[4], 4);
    h = plv_image_from_texture(tex, w, hh, transposed, &err);
    if(h == 0.0) plv_raise(&err);
    plhs[0] = mxCreateDoubleScalar(h);
}

static void op_ImageFromArray(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    plv_err_t err;
    const mxArray * a;
    const mwSize * dims;
    mwSize nd;
    size_t rows, cols, planes, r, c, plane;
    const uint8_t * src;
    uint8_t * dst = NULL;
    double h;

    (void)nlhs;
    plv_need_args(nrhs, 1, 1, "ImageFromArray");
    a = prhs[1];
    if(!mxIsUint8(a) || mxIsComplex(a))
        mexErrMsgIdAndTxt("psychlvgl:Type",
                          "argument 1 must be a uint8 image, HxW, HxWx3 or HxWx4");
    nd   = mxGetNumberOfDimensions(a);
    dims = mxGetDimensions(a);
    rows = dims[0];
    cols = dims[1];
    planes = (nd >= 3) ? dims[2] : 1;
    if(nd > 3 || !(planes == 1 || planes == 3 || planes == 4))
        mexErrMsgIdAndTxt("psychlvgl:Type",
                          "argument 1 must be a uint8 image, HxW, HxWx3 or HxWx4");

    if(rows > PLV_IMAGE_MAX_SIDE || cols > PLV_IMAGE_MAX_SIDE || rows == 0 || cols == 0)
        mexErrMsgIdAndTxt("psychlvgl:Range", "image size %ux%u is outside 1 to %d",
                          (unsigned)cols, (unsigned)rows, PLV_IMAGE_MAX_SIDE);
    /* Width is the column count. */
    h = plv_image_create_argb((int32_t)cols, (int32_t)rows, &dst, &err);
    if(h == 0.0) plv_raise(&err);

    /* MATLAB stores columns, LVGL rows of B, G, R, A. */
    src = (const uint8_t *)mxGetData(a);
    plane = rows * cols;
    for(c = 0; c < cols; c++) {
        for(r = 0; r < rows; r++) {
            size_t si = r + c * rows;
            uint8_t * px = dst + (r * cols + c) * 4u;
            if(planes == 1) {
                px[0] = px[1] = px[2] = src[si];
                px[3] = 255;
            }
            else {
                px[2] = src[si];
                px[1] = src[si + plane];
                px[0] = src[si + 2 * plane];
                px[3] = (planes == 4) ? src[si + 3 * plane] : 255;
            }
        }
    }
    plhs[0] = mxCreateDoubleScalar(h);
}

static void op_ImageDelete(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    plv_err_t err;
    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 1, 1, "ImageDelete");
    if(plv_image_delete(plv_arg_res_handle(prhs[1], 1), &err)) plv_raise(&err);
}

/* ------------------------------------------------------------------- fonts */

static void op_FontLoad(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    plv_err_t err;
    plv_strbuf_t buf;
    const char * path;
    int32_t px;
    double h;

    (void)nlhs;
    plv_need_args(nrhs, 2, 2, "FontLoad");
    px   = (int32_t)plv_arg_int(prhs[2], 2, 1, PLV_FONT_MAX_PX);
    path = plv_arg_str(prhs[1], 1, &buf);
    h = plv_font_load(path, px, &err);
    plv_strbuf_free(&buf);
    if(h == 0.0) plv_raise(&err);
    plhs[0] = mxCreateDoubleScalar(h);
}

static void op_FontDelete(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    plv_err_t err;
    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 1, 1, "FontDelete");
    if(plv_font_delete(plv_arg_res_handle(prhs[1], 1), &err)) plv_raise(&err);
}

/* ------------------------------------------------------------------ charts */

static void op_ChartSetValues(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    plv_i32vec_t vb;
    lv_obj_t * chart;
    lv_chart_series_t * ser;
    const int32_t * v;
    int32_t * y;
    uint32_t n, i;

    (void)nlhs; (void)plhs;
    plv_need_args(nrhs, 3, 3, "ChartSetValues");
    chart = plv_arg_obj(prhs[1], 1);
    ser   = plv_arg_series(prhs, 2, 1);
    /* NaN is a gap in the plot, which LVGL spells LV_CHART_POINT_NONE. */
    v = plv_arg_i32vec(prhs[3], 3, &vb, 1, LV_CHART_POINT_NONE);
    n = lv_chart_get_point_count(chart);
    if(vb.n > n) {
        plv_i32vec_free(&vb);
        mexErrMsgIdAndTxt("psychlvgl:Range",
                          "argument 3 has %u values but the chart has %u points; "
                          "call ChartSetPointCount first", (unsigned)vb.n, (unsigned)n);
    }
    /* Copied into the array the chart owns, never aliased: LVGL keeps using
     * the array after this call returns, and MATLAB may free or move the
     * argument at any time. */
    y = lv_chart_get_series_y_array(chart, ser);
    for(i = 0; i < (uint32_t)vb.n; i++) y[i] = v[i];
    for(; i < n; i++) y[i] = LV_CHART_POINT_NONE;
    plv_i32vec_free(&vb);
    lv_chart_set_x_start_point(chart, ser, 0);
    lv_chart_refresh(chart);
    plv_check_deferred();
}

static void op_ChartGetValues(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    lv_obj_t * chart;
    lv_chart_series_t * ser;
    const int32_t * y;
    uint32_t n, i, start = 0;
    mxArray * out;
    double * p;

    (void)nlhs;
    plv_need_args(nrhs, 2, 2, "ChartGetValues");
    chart = plv_arg_obj(prhs[1], 1);
    ser   = plv_arg_series(prhs, 2, 1);
    n = lv_chart_get_point_count(chart);
    y = lv_chart_get_series_y_array(chart, ser);
    /* In shift mode the plot starts at the series' start point; in circular
     * mode it is the array as stored. The result is the order on screen. */
    if(lv_chart_get_update_mode(chart) == LV_CHART_UPDATE_MODE_SHIFT)
        start = lv_chart_get_x_start_point(chart, ser);
    out = mxCreateDoubleMatrix(1, (mwSize)n, mxREAL);
    p = mxGetPr(out);
    for(i = 0; i < n; i++) {
        int32_t v = y[(start + i) % n];
        p[i] = (v == LV_CHART_POINT_NONE) ? mxGetNaN() : (double)v;
    }
    plhs[0] = out;
}

/* ---------------------------------------------------------------- ParseXML */

/* Deeper documents are refused: the tree is built by recursion on the C
 * stack, and no user interface nests anywhere near this far. */
#define PLV_XML_MAX_DEPTH 256
/* MATLAB's namelengthmax. */
#define PLV_XML_NAME_MAX 63

static const char * s_xml_fields[] = { "tag", "attributes", "attr_names", "text", "children" };

/* A document whose tree was being built when an mx allocation raised. The
 * next ParseXML frees it; the error path cannot, because it never returns. */
static plv_xml_doc_t * s_xml_pending;

/* Keywords of both engines. mxCreateStructMatrix accepts them, but a field
 * with such a name cannot be written as s.name in M code. */
static const char * s_xml_keywords[] = {
    "__FILE__", "__LINE__", "break", "case", "catch", "classdef", "continue", "do",
    "else", "elseif", "end", "end_try_catch", "end_unwind_protect", "endclassdef",
    "endenumeration", "endevents", "endfor", "endfunction", "endif", "endmethods",
    "endparfor", "endproperties", "endspmd", "endswitch", "endwhile", "enumeration",
    "events", "for", "function", "global", "if", "methods", "otherwise", "parfor",
    "persistent", "properties", "return", "spmd", "switch", "try", "until",
    "unwind_protect", "unwind_protect_cleanup", "while"
};

static int plv_xml_is_keyword(const char * s)
{
    size_t i;
    for(i = 0; i < sizeof(s_xml_keywords) / sizeof(s_xml_keywords[0]); i++)
        if(strcmp(s, s_xml_keywords[i]) == 0) return 1;
    return 0;
}

/* A valid struct field name for an XML attribute name. Returns 1 when the
 * name had to change. The rule is makeValidName's: invalid characters become
 * underscores, and a name that does not start with a letter, or is a
 * keyword, gets an x in front. */
static int plv_xml_field_name(const char * src, char dst[PLV_XML_NAME_MAX + 1])
{
    size_t i, o = 0;
    int changed = 0;
    int lead = !((src[0] >= 'A' && src[0] <= 'Z') || (src[0] >= 'a' && src[0] <= 'z'));

    if(lead) { dst[o++] = 'x'; changed = 1; }
    for(i = 0; src[i] && o < PLV_XML_NAME_MAX; i++) {
        char c = src[i];
        int ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_';
        dst[o++] = ok ? c : '_';
        if(!ok) changed = 1;
    }
    if(src[i]) changed = 1;   /* truncated */
    dst[o] = 0;
    if(!lead && plv_xml_is_keyword(dst)) {
        memmove(dst + 1, dst, (o < PLV_XML_NAME_MAX) ? o + 1 : o);
        dst[0] = 'x';
        dst[PLV_XML_NAME_MAX] = 0;
        changed = 1;
    }
    return changed;
}

static mxArray * plv_xml_nodes(plv_xml_node_t first, size_t count, int depth);

static mxArray * plv_xml_attributes(plv_xml_node_t node, mxArray ** names_out)
{
    char    stack_names[16][PLV_XML_NAME_MAX + 1];
    const char * stack_ptrs[16];
    char (*names)[PLV_XML_NAME_MAX + 1] = stack_names;
    const char ** ptrs = stack_ptrs;
    size_t n = plv_xml_attr_count(node), i, j;
    plv_xml_attr_t a;
    int renamed = 0;
    mxArray * s;

    if(n > 16) {
        /* mxMalloc memory is released by the engine if a later call raises. */
        names = (char (*)[PLV_XML_NAME_MAX + 1])mxMalloc(n * sizeof(*names));
        ptrs  = (const char **)mxMalloc(n * sizeof(*ptrs));
    }
    for(a = plv_xml_attr_first(node), i = 0; a; a = plv_xml_attr_next(a), i++) {
        renamed |= plv_xml_field_name(plv_xml_attr_name(a), names[i]);
        /* Two attributes can sanitize to one name, and a field name must be
         * unique, so a later one gets a numeric suffix. */
        for(j = 0; j < i; j++) {
            if(strcmp(names[i], names[j]) == 0) {
                char base[PLV_XML_NAME_MAX + 1];
                int k = 2;
                memcpy(base, names[i], sizeof(base));
                do {
                    char suffix[16];
                    size_t sl = (size_t)sprintf(suffix, "_%d", k++);
                    size_t bl = strlen(base);
                    if(bl + sl > PLV_XML_NAME_MAX) bl = PLV_XML_NAME_MAX - sl;
                    memcpy(names[i], base, bl);
                    memcpy(names[i] + bl, suffix, sl + 1);
                    for(j = 0; j < i; j++) if(strcmp(names[i], names[j]) == 0) break;
                } while(j < i);
                renamed = 1;
                break;
            }
        }
        ptrs[i] = names[i];
    }

    s = mxCreateStructMatrix(1, 1, (int)n, ptrs);
    for(a = plv_xml_attr_first(node), i = 0; a; a = plv_xml_attr_next(a), i++)
        mxSetFieldByNumber(s, 0, (int)i, plv_ret_str(plv_xml_attr_value(a)));

    if(renamed) {
        *names_out = mxCreateCellMatrix(1, (mwSize)n);
        for(a = plv_xml_attr_first(node), i = 0; a; a = plv_xml_attr_next(a), i++)
            mxSetCell(*names_out, (mwIndex)i, plv_ret_str(plv_xml_attr_name(a)));
    }
    else *names_out = mxCreateCellMatrix(0, 0);

    if(names != stack_names) {
        mxFree(names);
        mxFree((void *)ptrs);
    }
    return s;
}

static mxArray * plv_xml_text_of(plv_xml_node_t node)
{
    const char * single;
    char stack[1024];
    char * buf;
    size_t n = plv_xml_text(node, &single, NULL, 0);
    mxArray * out;

    if(single) return plv_ret_utf8n(single, n);
    buf = (n < sizeof(stack)) ? stack : (char *)mxMalloc(n + 1);
    plv_xml_text(node, &single, buf, n + 1);
    out = plv_ret_utf8n(buf, n);
    if(buf != stack) mxFree(buf);
    return out;
}

/* The struct array for first and its element siblings, allocated once at its
 * final size. NULL means the document nests too deep. */
static mxArray * plv_xml_nodes(plv_xml_node_t first, size_t count, int depth)
{
    mxArray * arr;
    plv_xml_node_t node;
    size_t i;

    if(depth > PLV_XML_MAX_DEPTH) return NULL;
    arr = mxCreateStructMatrix(count ? 1 : 0, count ? (mwSize)count : 0, 5, s_xml_fields);
    for(node = first, i = 0; node && i < count; node = plv_xml_next(node), i++) {
        mxArray * names;
        mxArray * attrs = plv_xml_attributes(node, &names);
        plv_xml_node_t child = plv_xml_first(node);
        mxArray * kids = plv_xml_nodes(child, plv_xml_count(child), depth + 1);
        if(!kids) return NULL;
        mxSetFieldByNumber(arr, (mwIndex)i, 0, plv_ret_str(plv_xml_name(node)));
        mxSetFieldByNumber(arr, (mwIndex)i, 1, attrs);
        mxSetFieldByNumber(arr, (mwIndex)i, 2, names);
        mxSetFieldByNumber(arr, (mwIndex)i, 3, plv_xml_text_of(node));
        mxSetFieldByNumber(arr, (mwIndex)i, 4, kids);
    }
    return arr;
}

static void op_ParseXML(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[])
{
    char msg[PLV_ERR_MSG_MAX];
    char * text;
    plv_xml_doc_t * doc;
    plv_xml_node_t root;
    mxArray * tree;

    (void)nlhs;
    if(s_xml_pending) {
        plv_xml_free(s_xml_pending);
        s_xml_pending = NULL;
    }
    if(nrhs != 2)
        mexErrMsgIdAndTxt("psychlvgl:Usage", "Usage: tree = PsychLVGL('ParseXML', pathOrText)");
    if(!mxIsChar(prhs[1]) || mxGetNumberOfDimensions(prhs[1]) > 2 || mxGetM(prhs[1]) > 1)
        mexErrMsgIdAndTxt("psychlvgl:Type",
                          "argument 1 must be a char row vector, a file name or XML text");
#if defined(PSYCHLVGL_OCTAVE)
    text = mxArrayToString(prhs[1]);
#else
    text = mxArrayToUTF8String(prhs[1]);
#endif
    if(!text)
        mexErrMsgIdAndTxt("psychlvgl:Type", "argument 1 could not be converted to UTF-8");

    /* No file name contains '<' on Windows, and every XML document does, so
     * the test never has to touch the file system for text. */
    if(!strchr(text, '<')) {
        int status;
        doc = plv_xml_parse_file(text, &status, msg, sizeof(msg));
        if(!doc && status == PLV_XML_NOT_FOUND) {
            char shown[256];
            snprintf(shown, sizeof(shown), "%s", text);
            mxFree(text);
            mexErrMsgIdAndTxt("psychlvgl:XML",
                              "'%s' is neither a readable file nor XML text", shown);
        }
    }
    else doc = plv_xml_parse_text(text, strlen(text), msg, sizeof(msg));
    mxFree(text);
    if(!doc) mexErrMsgIdAndTxt("psychlvgl:XML", "%s", msg);

    s_xml_pending = doc;
    root = plv_xml_root_first(doc);
    tree = plv_xml_nodes(root, plv_xml_count(root), 0);
    s_xml_pending = NULL;
    plv_xml_free(doc);
    if(!tree)
        mexErrMsgIdAndTxt("psychlvgl:XML", "the document nests deeper than %d elements",
                          PLV_XML_MAX_DEPTH);
    plhs[0] = tree;
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
