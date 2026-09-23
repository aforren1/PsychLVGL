/**
 * @file plv_marshal.h
 * mxArray to C helpers used by the generated handlers.
 *
 * Everything here runs on the dispatch stack, never inside an LVGL callback,
 * so raising a MATLAB error from these functions is safe.
 */
#ifndef PLV_MARSHAL_H
#define PLV_MARSHAL_H

#include "mex.h"
#include "plv_core.h"

typedef void (*plv_op_fn_t)(int nlhs, mxArray * plhs[], int nrhs, const mxArray * prhs[]);

typedef struct {
    const char * name;
    plv_op_fn_t  fn;
} plv_op_entry_t;

typedef struct {
    const char * name;
    double       value;
} plv_enum_entry_t;

/* StyleSetProp dispatch: one entry per lv_style_set_<prop>, generated from
 * the same headers as the ObjSetStyle<Prop> subcommands. name is the
 * property with underscores removed and in lower case, the table is sorted
 * by it. */
typedef void (*plv_style_setter_t)(lv_style_t * style, const mxArray * value, int pos);
typedef struct {
    const char *       name;
    plv_style_setter_t fn;
} plv_style_prop_entry_t;

extern const plv_op_entry_t plv_gen_ops[];
extern const int            plv_gen_op_count;
extern const plv_enum_entry_t plv_enum_table[];
extern const int            plv_enum_count;
extern const plv_style_prop_entry_t plv_style_props[];
extern const int            plv_style_prop_count;

/* A short string stays on the stack; only a long one reaches the heap. */
#define PLV_STRBUF_STACK 4096
typedef struct {
    char * p;
    char   stack[PLV_STRBUF_STACK];
} plv_strbuf_t;

void         plv_need_args(int nrhs, int min_args, int max_args, const char * name);
void         plv_need_init(const char * name);
lv_obj_t *   plv_arg_obj(const mxArray * a, int pos);
double       plv_arg_int(const mxArray * a, int pos, double lo, double hi);
double       plv_arg_double(const mxArray * a, int pos);
int          plv_arg_bool(const mxArray * a, int pos);
const char * plv_arg_str(const mxArray * a, int pos, plv_strbuf_t * buf);
void         plv_strbuf_free(plv_strbuf_t * buf);

/* An int32 vector argument. Up to PLV_I32VEC_STACK elements stay on the
 * stack; an int32 array is passed through without a copy, since every LVGL
 * function that takes one copies the values itself. */
#define PLV_I32VEC_STACK 1024
typedef struct {
    const int32_t * p;
    size_t          n;
    int32_t *       heap;    /* mxMalloc, so an error raised later frees it */
    int32_t         stack[PLV_I32VEC_STACK];
} plv_i32vec_t;

/* nan_ok: a NaN element becomes nan_value instead of raising. */
const int32_t * plv_arg_i32vec(const mxArray * a, int pos, plv_i32vec_t * buf,
                               int nan_ok, int32_t nan_value);
void         plv_i32vec_free(plv_i32vec_t * buf);
lv_color_t   plv_arg_color(const mxArray * a, int pos);
double       plv_arg_opa(const mxArray * a, int pos);
double       plv_arg_enum(const mxArray * a, int pos);
double       plv_arg_selector(const mxArray * prhs[], int nrhs, int pos);
const lv_font_t * plv_arg_font(const mxArray * a, int pos);
lv_style_t * plv_arg_style(const mxArray * a, int pos);
/* The chart is the object argument at chart_pos. A series or cursor handle
 * from another chart is refused: LVGL would unlink it from the wrong list. */
lv_chart_series_t * plv_arg_series(const mxArray * prhs[], int pos, int chart_pos);
lv_chart_cursor_t * plv_arg_cursor(const mxArray * prhs[], int pos, int chart_pos);
/* An image handle, or 0 for no source. */
const void * plv_arg_image_src(const mxArray * a, int pos);
double       plv_arg_res_handle(const mxArray * a, int pos);
void         plv_res_release_arg(const mxArray * a);

mxArray *    plv_ret_obj(lv_obj_t * obj);
mxArray *    plv_ret_res(void * ptr, plv_res_kind_t kind, void * owner);
mxArray *    plv_ret_str(const char * s);
mxArray *    plv_ret_color(lv_color_t c);

void         plv_check_deferred(void);
void         plv_raise(const plv_err_t * err);
int          plv_enum_lookup(const char * name, double * out);
const lv_font_t * plv_font_lookup(const char * name);
const char * plv_font_name(int index);   /* NULL past the end */
plv_style_setter_t plv_style_prop_lookup(const char * name);

#endif /* PLV_MARSHAL_H */
