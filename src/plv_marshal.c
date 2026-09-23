/**
 * @file plv_marshal.c
 * Argument readers and result builders for the generated handlers.
 */
#include "plv_marshal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ----------------------------------------------------------------- errors */

void plv_raise(const plv_err_t * err)
{
    mexErrMsgIdAndTxt(err->id, "%s", err->msg);
}

void plv_check_deferred(void)
{
    plv_err_t err;
    if(plv_take_deferred_error(&err)) plv_raise(&err);
}

void plv_need_args(int nrhs, int min_args, int max_args, const char * name)
{
    int given = nrhs - 1;
    if(given < min_args || given > max_args) {
        if(min_args == max_args)
            mexErrMsgIdAndTxt("psychlvgl:Usage",
                              "%s takes %d argument(s), got %d", name, min_args, given);
        mexErrMsgIdAndTxt("psychlvgl:Usage",
                          "%s takes %d to %d arguments, got %d",
                          name, min_args, max_args, given);
    }
    plv_need_init(name);
}

void plv_need_init(const char * name)
{
    if(!plv_is_initialized())
        mexErrMsgIdAndTxt("psychlvgl:NotInitialized",
                          "%s needs PsychLVGL('Init', w, h) first", name);
}

/* ------------------------------------------------------------------ scalars */

static double plv_scalar(const mxArray * a, int pos)
{
    if(!a || mxIsComplex(a) || mxGetNumberOfElements(a) != 1)
        mexErrMsgIdAndTxt("psychlvgl:Usage",
                          "argument %d must be a real scalar", pos);
    if(mxIsLogical(a)) return *(const mxLogical *)mxGetData(a) ? 1.0 : 0.0;
    if(mxIsChar(a) || mxIsCell(a) || mxIsStruct(a))
        mexErrMsgIdAndTxt("psychlvgl:Type",
                          "argument %d must be numeric or logical", pos);
    return mxGetScalar(a);
}

double plv_arg_double(const mxArray * a, int pos)
{
    return plv_scalar(a, pos);
}

double plv_arg_int(const mxArray * a, int pos, double lo, double hi)
{
    double v = plv_scalar(a, pos);
    if(v != v || v < lo || v > hi)
        mexErrMsgIdAndTxt("psychlvgl:Range",
                          "argument %d is %g, outside the %g to %g range of its C type",
                          pos, v, lo, hi);
    return v;
}

int plv_arg_bool(const mxArray * a, int pos)
{
    return plv_scalar(a, pos) != 0.0;
}

lv_obj_t * plv_arg_obj(const mxArray * a, int pos)
{
    plv_err_t err;
    lv_obj_t * obj;
    double h;

    if(!a || mxIsComplex(a) || !mxIsDouble(a) || mxGetNumberOfElements(a) != 1)
        mexErrMsgIdAndTxt("psychlvgl:Type",
                          "argument %d must be a handle, that is a double scalar", pos);
    h = mxGetScalar(a);
    obj = plv_handle_resolve(h, &err);
    if(!obj) plv_raise(&err);
    return obj;
}

/* ------------------------------------------------------------------ strings */

const char * plv_arg_str(const mxArray * a, int pos, plv_strbuf_t * buf)
{
    size_t need;

    buf->p = buf->stack;
    buf->stack[0] = 0;

    if(!a || !mxIsChar(a))
        mexErrMsgIdAndTxt("psychlvgl:Type",
                          "argument %d must be a char row vector; string is not accepted",
                          pos);
    if(mxGetNumberOfDimensions(a) > 2 || (mxGetM(a) > 1))
        mexErrMsgIdAndTxt("psychlvgl:Type", "argument %d must be a char row vector", pos);

    {
        /* MATLAB char is UTF-16 and needs the UTF-8 converter. Octave has no
         * mxArrayToUTF8String and its char data is UTF-8 bytes already. */
#if defined(PSYCHLVGL_OCTAVE)
        char * utf8 = mxArrayToString(a);
#else
        char * utf8 = mxArrayToUTF8String(a);
#endif
        if(!utf8)
            mexErrMsgIdAndTxt("psychlvgl:Type",
                              "argument %d could not be converted to UTF-8", pos);
        need = strlen(utf8) + 1;
        if(need <= PLV_STRBUF_STACK) {
            memcpy(buf->stack, utf8, need);
            buf->p = buf->stack;
        }
        else {
            buf->p = (char *)malloc(need);
            if(!buf->p) {
                mxFree(utf8);
                mexErrMsgIdAndTxt("psychlvgl:Usage", "out of memory for argument %d", pos);
            }
            memcpy(buf->p, utf8, need);
        }
        mxFree(utf8);
    }
    return buf->p;
}

void plv_strbuf_free(plv_strbuf_t * buf)
{
    if(buf->p && buf->p != buf->stack) free(buf->p);
    buf->p = NULL;
}

/* ------------------------------------------------------------------- color */

lv_color_t plv_arg_color(const mxArray * a, int pos)
{
    size_t n;

    if(!a || mxIsComplex(a) || mxIsChar(a) || mxIsCell(a) || mxIsStruct(a))
        mexErrMsgIdAndTxt("psychlvgl:Type",
                          "argument %d must be [r g b] in 0 to 255 or a 0xRRGGBB scalar", pos);
    n = mxGetNumberOfElements(a);
    if(n == 3) {
        double r = mxGetPr(a)[0], g = mxGetPr(a)[1], b = mxGetPr(a)[2];
        if(r < 0 || r > 255 || g < 0 || g > 255 || b < 0 || b > 255)
            mexErrMsgIdAndTxt("psychlvgl:Range",
                              "argument %d has a colour component outside 0 to 255", pos);
        return lv_color_make((uint8_t)r, (uint8_t)g, (uint8_t)b);
    }
    if(n == 1) {
        double v = mxGetScalar(a);
        if(v < 0 || v > 16777215.0)
            mexErrMsgIdAndTxt("psychlvgl:Range",
                              "argument %d must be 0 to 0xFFFFFF", pos);
        return lv_color_hex((uint32_t)v);
    }
    mexErrMsgIdAndTxt("psychlvgl:Type",
                      "argument %d must be [r g b] or a 0xRRGGBB scalar", pos);
    return lv_color_black();
}

mxArray * plv_ret_color(lv_color_t c)
{
    mxArray * out = mxCreateDoubleMatrix(1, 3, mxREAL);
    double * p = mxGetPr(out);
    p[0] = c.red;
    p[1] = c.green;
    p[2] = c.blue;
    return out;
}

/* -------------------------------------------------------------------- enums */

static int plv_enum_cmp(const void * key, const void * entry)
{
    return strcmp((const char *)key, ((const plv_enum_entry_t *)entry)->name);
}

int plv_enum_lookup(const char * name, double * out)
{
    const plv_enum_entry_t * hit;
    char prefixed[96];

    hit = (const plv_enum_entry_t *)bsearch(name, plv_enum_table, (size_t)plv_enum_count,
                                            sizeof(plv_enum_entry_t), plv_enum_cmp);
    if(!hit && strncmp(name, "LV_", 3) != 0 && strlen(name) < sizeof(prefixed) - 4) {
        /* Scripts may leave the LV_ prefix off. */
        strcpy(prefixed, "LV_");
        strcat(prefixed, name);
        hit = (const plv_enum_entry_t *)bsearch(prefixed, plv_enum_table,
                                                (size_t)plv_enum_count,
                                                sizeof(plv_enum_entry_t), plv_enum_cmp);
    }
    if(!hit) return 0;
    *out = hit->value;
    return 1;
}

/* Accepts "LV_PART_MAIN|LV_STATE_PRESSED" as well as a single name. */
static double plv_enum_from_string(const char * text, int pos)
{
    char buf[256];
    char * tok;
    double total = 0.0;
    size_t n = strlen(text);

    if(n >= sizeof(buf))
        mexErrMsgIdAndTxt("psychlvgl:Enum", "argument %d: enum name is too long", pos);
    memcpy(buf, text, n + 1);

    tok = strtok(buf, "|");
    while(tok) {
        double v;
        while(*tok == ' ') tok++;
        {
            size_t len = strlen(tok);
            while(len && tok[len - 1] == ' ') tok[--len] = 0;
        }
        if(!plv_enum_lookup(tok, &v))
            mexErrMsgIdAndTxt("psychlvgl:Enum", "argument %d: unknown enum name '%s'",
                              pos, tok);
        total += v;
        tok = strtok(NULL, "|");
    }
    return total;
}

double plv_arg_enum(const mxArray * a, int pos)
{
    if(a && mxIsChar(a)) {
        plv_strbuf_t buf;
        double v;
        const char * s = plv_arg_str(a, pos, &buf);
        v = plv_enum_from_string(s, pos);
        plv_strbuf_free(&buf);
        return v;
    }
    return plv_scalar(a, pos);
}

double plv_arg_opa(const mxArray * a, int pos)
{
    double v;
    if(a && mxIsChar(a)) return plv_arg_enum(a, pos);
    v = plv_scalar(a, pos);
    if(v < 0 || v > 255)
        mexErrMsgIdAndTxt("psychlvgl:Range", "argument %d: opacity must be 0 to 255", pos);
    return v;
}

double plv_arg_selector(const mxArray * prhs[], int nrhs, int pos)
{
    if(nrhs <= pos) return (double)LV_PART_MAIN;
    return plv_arg_enum(prhs[pos], pos);
}

/* -------------------------------------------------------------------- fonts */

typedef struct {
    const char * name;
    const lv_font_t * font;
} plv_font_entry_t;

static const plv_font_entry_t plv_fonts[] = {
#if LV_FONT_MONTSERRAT_12
    { "montserrat_12", &lv_font_montserrat_12 },
#endif
#if LV_FONT_MONTSERRAT_14
    { "montserrat_14", &lv_font_montserrat_14 },
#endif
#if LV_FONT_MONTSERRAT_16
    { "montserrat_16", &lv_font_montserrat_16 },
#endif
#if LV_FONT_MONTSERRAT_20
    { "montserrat_20", &lv_font_montserrat_20 },
#endif
#if LV_FONT_MONTSERRAT_24
    { "montserrat_24", &lv_font_montserrat_24 },
#endif
#if LV_FONT_MONTSERRAT_28
    { "montserrat_28", &lv_font_montserrat_28 },
#endif
#if LV_FONT_MONTSERRAT_32
    { "montserrat_32", &lv_font_montserrat_32 },
#endif
#if LV_FONT_MONTSERRAT_48
    { "montserrat_48", &lv_font_montserrat_48 },
#endif
    { NULL, NULL }
};

const lv_font_t * plv_font_lookup(const char * name)
{
    int i;
    for(i = 0; plv_fonts[i].name; i++)
        if(strcmp(plv_fonts[i].name, name) == 0) return plv_fonts[i].font;
    return NULL;
}

const char * plv_font_name(int index)
{
    int i;
    for(i = 0; plv_fonts[i].name; i++)
        if(i == index) return plv_fonts[i].name;
    return NULL;
}

const lv_font_t * plv_arg_font(const mxArray * a, int pos)
{
    plv_strbuf_t buf;
    const lv_font_t * f;
    const char * s;

    /* A number is a FontLoad handle, a char a built-in font name. */
    if(a && !mxIsChar(a)) {
        plv_err_t err;
        f = plv_font_resolve(plv_arg_res_handle(a, pos), &err);
        if(!f) plv_raise(&err);
        return f;
    }
    s = plv_arg_str(a, pos, &buf);
    f = plv_font_lookup(s);
    if(!f) {
        plv_strbuf_free(&buf);
        mexErrMsgIdAndTxt("psychlvgl:Font",
                          "argument %d: unknown font; PsychLVGL('FontList') has the names",
                          pos);
    }
    plv_strbuf_free(&buf);
    return f;
}

/* ---------------------------------------------------------------- resources */

double plv_arg_res_handle(const mxArray * a, int pos)
{
    if(!a || mxIsComplex(a) || !mxIsDouble(a) || mxGetNumberOfElements(a) != 1)
        mexErrMsgIdAndTxt("psychlvgl:Type",
                          "argument %d must be a handle, that is a double scalar", pos);
    return mxGetScalar(a);
}

static void * plv_arg_res(const mxArray * a, int pos, plv_res_kind_t kind)
{
    plv_err_t err;
    void * p = plv_res_resolve(plv_arg_res_handle(a, pos), kind, &err);
    if(!p) plv_raise(&err);
    return p;
}

lv_style_t * plv_arg_style(const mxArray * a, int pos)
{
    return (lv_style_t *)plv_arg_res(a, pos, PLV_RES_STYLE);
}

static void * plv_arg_owned(const mxArray * prhs[], int pos, int chart_pos, plv_res_kind_t kind)
{
    void * p = plv_arg_res(prhs[pos], pos, kind);
    lv_obj_t * chart = plv_arg_obj(prhs[chart_pos], chart_pos);
    if(plv_res_owner(mxGetScalar(prhs[pos])) != (void *)chart)
        mexErrMsgIdAndTxt("psychlvgl:InvalidHandle",
                          "argument %d: this %s belongs to another chart",
                          pos, plv_res_kind_name(kind));
    return p;
}

lv_chart_series_t * plv_arg_series(const mxArray * prhs[], int pos, int chart_pos)
{
    return (lv_chart_series_t *)plv_arg_owned(prhs, pos, chart_pos, PLV_RES_SERIES);
}

lv_chart_cursor_t * plv_arg_cursor(const mxArray * prhs[], int pos, int chart_pos)
{
    return (lv_chart_cursor_t *)plv_arg_owned(prhs, pos, chart_pos, PLV_RES_CURSOR);
}

const void * plv_arg_image_src(const mxArray * a, int pos)
{
    if(a && mxIsDouble(a) && !mxIsComplex(a) && mxGetNumberOfElements(a) == 1
       && mxGetScalar(a) == 0.0)
        return NULL;
    return plv_arg_res(a, pos, PLV_RES_IMAGE);
}

void plv_res_release_arg(const mxArray * a)
{
    plv_res_release(mxGetScalar(a));
}

mxArray * plv_ret_res(void * ptr, plv_res_kind_t kind, void * owner)
{
    plv_err_t err;
    double h;
    if(!ptr) return mxCreateDoubleScalar(0.0);
    h = plv_res_register(kind, ptr, owner, &err);
    if(h == 0.0) plv_raise(&err);
    return mxCreateDoubleScalar(h);
}

/* ------------------------------------------------------------ int32 vectors */

static int32_t plv_i32_elem(double v, int pos, size_t i, int nan_ok, int32_t nan_value)
{
    if(v != v) {
        if(!nan_ok)
            mexErrMsgIdAndTxt("psychlvgl:Range", "argument %d: element %u is NaN",
                              pos, (unsigned)(i + 1));
        return nan_value;
    }
    if(v < -2147483648.0 || v > 2147483647.0)
        mexErrMsgIdAndTxt("psychlvgl:Range",
                          "argument %d: element %u is %g, outside the int32 range",
                          pos, (unsigned)(i + 1), v);
    /* Truncation toward zero, the same rule as a scalar int32_t argument. */
    return (int32_t)v;
}

const int32_t * plv_arg_i32vec(const mxArray * a, int pos, plv_i32vec_t * buf,
                               int nan_ok, int32_t nan_value)
{
    size_t n, i;
    int32_t * dst;
    mxClassID c;
    const void * s;

    buf->p    = buf->stack;
    buf->n    = 0;
    buf->heap = NULL;

    if(!a || mxIsComplex(a) || !(mxIsNumeric(a) || mxIsLogical(a))
       || mxGetNumberOfDimensions(a) > 2 || (mxGetM(a) > 1 && mxGetN(a) > 1))
        mexErrMsgIdAndTxt("psychlvgl:Type",
                          "argument %d must be a real numeric vector", pos);
    n = mxGetNumberOfElements(a);
    buf->n = n;
    if(n == 0) return buf->p;

    if(mxIsInt32(a)) {
        buf->p = (const int32_t *)mxGetData(a);
        return buf->p;
    }

    if(n > PLV_I32VEC_STACK) {
        buf->heap = (int32_t *)mxMalloc(n * sizeof(int32_t));
        dst = buf->heap;
    }
    else {
        dst = buf->stack;
    }
    buf->p = dst;

    c = mxGetClassID(a);
    s = mxGetData(a);
    /* double is the class a script passes almost always, so it gets the
     * loop without the per element switch. */
    if(c == mxDOUBLE_CLASS) {
        const double * d = (const double *)s;
        for(i = 0; i < n; i++) dst[i] = plv_i32_elem(d[i], pos, i, nan_ok, nan_value);
        return buf->p;
    }
    for(i = 0; i < n; i++) {
        double v;
        switch(c) {
            case mxSINGLE_CLASS:  v = ((const float *)s)[i]; break;
            case mxLOGICAL_CLASS: v = ((const mxLogical *)s)[i] ? 1.0 : 0.0; break;
            case mxINT8_CLASS:    v = ((const int8_t *)s)[i]; break;
            case mxUINT8_CLASS:   v = ((const uint8_t *)s)[i]; break;
            case mxINT16_CLASS:   v = ((const int16_t *)s)[i]; break;
            case mxUINT16_CLASS:  v = ((const uint16_t *)s)[i]; break;
            case mxUINT32_CLASS:  v = ((const uint32_t *)s)[i]; break;
            case mxINT64_CLASS:   v = (double)((const int64_t *)s)[i]; break;
            case mxUINT64_CLASS:  v = (double)((const uint64_t *)s)[i]; break;
            default:
                mexErrMsgIdAndTxt("psychlvgl:Type", "argument %d must be a real numeric vector", pos);
                return NULL;
        }
        dst[i] = plv_i32_elem(v, pos, i, nan_ok, nan_value);
    }
    return buf->p;
}

void plv_i32vec_free(plv_i32vec_t * buf)
{
    if(buf->heap) mxFree(buf->heap);
    buf->heap = NULL;
}

/* ------------------------------------------------------------ style props */

static int plv_style_prop_cmp(const void * key, const void * entry)
{
    return strcmp((const char *)key, ((const plv_style_prop_entry_t *)entry)->name);
}

/* Accepts 'bg_color', 'BgColor' and 'LV_STYLE_BG_COLOR' alike. */
plv_style_setter_t plv_style_prop_lookup(const char * name)
{
    char key[64];
    size_t i = 0;
    const plv_style_prop_entry_t * hit;

    if(strncmp(name, "LV_STYLE_", 9) == 0 || strncmp(name, "lv_style_", 9) == 0) name += 9;
    for(; *name && i < sizeof(key) - 1; name++) {
        char c = *name;
        if(c == '_') continue;
        if(c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        key[i++] = c;
    }
    key[i] = 0;
    hit = (const plv_style_prop_entry_t *)bsearch(key, plv_style_props, (size_t)plv_style_prop_count,
                                                  sizeof(plv_style_prop_entry_t), plv_style_prop_cmp);
    return hit ? hit->fn : NULL;
}

/* ------------------------------------------------------------------ results */

mxArray * plv_ret_obj(lv_obj_t * obj)
{
    double h = 0.0;
    if(obj) {
        h = plv_handle_of(obj);
        if(h == 0.0) h = plv_handle_register(obj, 0);
        plv_check_deferred();
    }
    return mxCreateDoubleScalar(h);
}

mxArray * plv_ret_str(const char * s)
{
    return mxCreateString(s ? s : "");
}
