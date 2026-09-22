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

extern const plv_op_entry_t plv_gen_ops[];
extern const int            plv_gen_op_count;
extern const plv_enum_entry_t plv_enum_table[];
extern const int            plv_enum_count;

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
lv_color_t   plv_arg_color(const mxArray * a, int pos);
double       plv_arg_opa(const mxArray * a, int pos);
double       plv_arg_enum(const mxArray * a, int pos);
double       plv_arg_selector(const mxArray * prhs[], int nrhs, int pos);
const lv_font_t * plv_arg_font(const mxArray * a, int pos);

mxArray *    plv_ret_obj(lv_obj_t * obj);
mxArray *    plv_ret_str(const char * s);
mxArray *    plv_ret_color(lv_color_t c);

void         plv_check_deferred(void);
void         plv_raise(const plv_err_t * err);
int          plv_enum_lookup(const char * name, double * out);
const lv_font_t * plv_font_lookup(const char * name);
const char * plv_font_name(int index);   /* NULL past the end */

#endif /* PLV_MARSHAL_H */
