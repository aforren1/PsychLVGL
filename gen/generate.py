"""Generates the psychlvgl binding sources from the LVGL public headers.

Run it with ``uv run gen/generate.py`` from the project root, or with
``build('gen')`` from MATLAB or Octave. The outputs are committed, so a user
needs neither Python nor a preprocessor to build the MEX.

Pipeline
--------
1. Build a fake libc include tree with LVGL's own ``create_fake_lib_c``.
2. Preprocess ``include/lvgl/lvgl.h`` against the project ``lv_conf.h``.
3. Parse the result with pycparser.
4. Keep the functions named in ``allowlist.toml`` plus every
   ``lv_obj_set_style_*`` setter, and drop whatever the SPEC 7.3 marshaling
   rules cannot express.
5. Emit the C handlers, the StyleSetProp property table (one entry per
   ``lv_style_set_<prop>`` that matches a kept ``lv_obj_set_style_<prop>``),
   the enum table, the help text, the opcode struct, and the generated
   marshaling test.

SPEC 7.1 calls for ``scripts/gen_json/gen_json.py`` here. See the deviations
section of SPEC.md for why this file preprocesses the headers itself.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import tomllib
except ImportError:      # Python 3.10
    import tomli as tomllib

import pycparser
from pycparser import c_ast

HERE = os.path.abspath(os.path.dirname(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
LVGL = os.path.join(ROOT, "third_party", "lvgl")

sys.path.insert(0, os.path.join(LVGL, "scripts", "gen_json"))

# --------------------------------------------------------------------------
# type model
# --------------------------------------------------------------------------

# Integer spellings that map straight to a range checked double.
INT_TYPES = {
    "int": (-2147483648, 2147483647),
    "signed int": (-2147483648, 2147483647),
    "unsigned int": (0, 4294967295),
    "long": (-2147483648, 2147483647),
    "unsigned long": (0, 4294967295),
    "short": (-32768, 32767),
    "unsigned short": (0, 65535),
    "char": (-128, 127),
    "signed char": (-128, 127),
    "unsigned char": (0, 255),
    "int8_t": (-128, 127),
    "uint8_t": (0, 255),
    "int16_t": (-32768, 32767),
    "uint16_t": (0, 65535),
    "int32_t": (-2147483648, 2147483647),
    "uint32_t": (0, 4294967295),
    "size_t": (0, 4294967295),
    "lv_coord_t": (-2147483648, 2147483647),
}

FLOAT_TYPES = {"float", "double", "lv_value_precise_t"}

# Types the phase 1 rules refuse outright. Anything else unknown is refused too.
REFUSED_HINTS = (
    "lv_style_t", "lv_anim_t", "lv_draw_", "lv_image_dsc_t", "lv_indev_t",
    "lv_display_t", "lv_event_cb_t", "va_list", "void *",
)


class Arg(object):
    def __init__(self, name, kind, ctype, base=None):
        self.name = name
        self.kind = kind        # obj, int, float, bool, str, color, opa,
                                # enum, selector, font, series, cursor,
                                # imgsrc, i32vec, out_u32, out_i32
        self.ctype = ctype
        self.base = base        # underlying integer spelling for enum/int


class Func(object):
    def __init__(self, cname, ret_kind, ret_ctype, args):
        self.cname = cname
        self.ret_kind = ret_kind
        self.ret_ctype = ret_ctype
        self.args = args
        self.opname = camel(cname)

    @property
    def in_args(self):
        return [a for a in self.args if not a.kind.startswith("out_")]

    @property
    def out_args(self):
        return [a for a in self.args if a.kind.startswith("out_")]


def camel(cname):
    """lv_obj_set_style_bg_color -> ObjSetStyleBgColor"""
    parts = cname[3:].split("_") if cname.startswith("lv_") else cname.split("_")
    return "".join(p[:1].upper() + p[1:] for p in parts if p)


# --------------------------------------------------------------------------
# preprocess and parse
# --------------------------------------------------------------------------

def find_compiler():
    for env in ("CC", "PSYCHLVGL_CPP"):
        if os.environ.get(env):
            return os.environ[env]
    candidates = ["gcc", "clang", "cc"]
    if sys.platform.startswith("win"):
        candidates.insert(0, r"C:\Program Files\GNU Octave\Octave-10.1.0\mingw64\bin\gcc.exe")
    for c in candidates:
        path = c if os.path.isabs(c) else shutil.which(c)
        if path and os.path.exists(path):
            return path
    raise SystemExit("no C preprocessor found; set CC to one")


def preprocess(tmp):
    import create_fake_lib_c

    fake = create_fake_lib_c.run(tmp)
    header = os.path.join(LVGL, "include", "lvgl", "lvgl.h")
    out = os.path.join(tmp, "lvgl.pp")
    conf = os.path.join(ROOT, "lv_conf.h").replace("\\", "/")

    cmd = [
        find_compiler(), "-std=c11", "-E", "-P",
        "-DPYCPARSER",
        '-DLV_CONF_PATH="%s"' % conf,
        "-DLV_LVGL_H_INCLUDE_SIMPLE",
        "-I" + fake,
        "-I" + os.path.join(LVGL, "include"),
        "-I" + os.path.join(LVGL, "include", "lvgl"),
        "-I" + ROOT,
        "-I" + os.path.join(ROOT, "src", "core"),
        header,
        "-o", out,
    ]
    # cc1.exe loads its runtime from the compiler's own bin directory, which
    # is not on PATH when the driver is called by absolute path.
    env = dict(os.environ)
    env["PATH"] = os.path.dirname(cmd[0]) + os.pathsep + env.get("PATH", "")

    res = subprocess.run(cmd, capture_output=True, text=True, env=env)
    if res.returncode != 0:
        sys.stderr.write(" ".join(cmd) + "\n")
        sys.stderr.write(res.stderr[:8000])
        raise SystemExit("preprocessing failed")
    with open(out, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def strip_attributes(text):
    """pycparser does not know GCC attributes or inline assembly."""
    text = re.sub(r"__attribute__\s*\(\(.*?\)\)", "", text, flags=re.S)
    text = re.sub(r"__asm__\s*\(.*?\)", "", text, flags=re.S)
    text = re.sub(r"\b__inline\b|\b__forceinline\b|\b__restrict\b", "", text)
    text = re.sub(r"\b__extension__\b", "", text)
    return text


# --------------------------------------------------------------------------
# AST walk
# --------------------------------------------------------------------------

class Collector(c_ast.NodeVisitor):
    def __init__(self):
        self.funcs = {}        # cname -> c_ast.Decl
        self.typedefs = {}     # name -> node
        self.enum_names = []
        self.seen_enum = set()

    def visit_Decl(self, node):
        if isinstance(node.type, c_ast.FuncDecl) and node.name:
            self.funcs.setdefault(node.name, node)
        self.generic_visit(node)

    def visit_Typedef(self, node):
        self.typedefs[node.name] = node
        self.generic_visit(node)

    def visit_Enum(self, node):
        if node.values:
            for e in node.values.enumerators:
                if e.name not in self.seen_enum:
                    self.seen_enum.add(e.name)
                    self.enum_names.append(e.name)
        self.generic_visit(node)


def spell(node):
    """Returns (base_spelling, pointer_depth, is_const)."""
    depth = 0
    const = False
    while True:
        if isinstance(node, c_ast.PtrDecl):
            depth += 1
            const = const or ("const" in (node.quals or []))
            node = node.type
        elif isinstance(node, c_ast.ArrayDecl):
            depth += 1
            node = node.type
        elif isinstance(node, c_ast.TypeDecl):
            const = const or ("const" in (node.quals or []))
            node = node.type
        elif isinstance(node, c_ast.IdentifierType):
            return " ".join(node.names), depth, const
        elif isinstance(node, c_ast.Struct):
            return "struct " + (node.name or "?"), depth, const
        elif isinstance(node, c_ast.Union):
            return "union " + (node.name or "?"), depth, const
        elif isinstance(node, c_ast.Enum):
            return "enum " + (node.name or "?"), depth, const
        elif isinstance(node, c_ast.FuncDecl):
            return "<function>", depth + 1, const
        else:
            return "<unknown>", depth, const


def resolve_typedef(collector, name, seen=None):
    """Follows a typedef chain. Returns (kind, base_spelling).

    kind is 'enum' for anything that ends in an enum tag, else the final
    identifier spelling.
    """
    seen = seen or set()
    while name in collector.typedefs and name not in seen:
        seen.add(name)
        base, depth, _ = spell(collector.typedefs[name].type)
        if depth:
            return "pointer", base
        if base.startswith("enum "):
            return "enum", "int32_t"
        name = base
    return "scalar", name


# --------------------------------------------------------------------------
# classification
# --------------------------------------------------------------------------

# Typedefs that resolve to a plain integer but name a set of constants, so a
# script should be able to pass a name instead of a number.
ENUMISH_SUFFIXES = ("_flag_t", "_state_t", "_part_t", "_dir_t", "_mode_t",
                    "_align_t", "_flow_t", "_selector_t")

SCALAR_TYPEDEFS = {"lv_coord_t", "lv_value_precise_t", "lv_uintptr_t",
                   "lv_intptr_t", "lv_opa_t"}


def classify_arg(collector, name, node, cname):
    base, depth, is_const = spell(node)

    if depth == 1 and base == "lv_obj_t":
        return Arg(name, "obj", "lv_obj_t *")
    if depth == 1 and base == "char":
        if is_const:
            return Arg(name, "str", "const char *")
        # A writable char buffer is an output; build_funcs pairs it with the
        # size argument that always follows it in LVGL.
        return Arg(name, "out_str", "char *")
    if depth == 1 and base == "lv_font_t":
        return Arg(name, "font", "const lv_font_t *")
    # Series and cursors live in the resource table, keyed by their chart.
    if depth == 1 and base == "lv_chart_series_t":
        return Arg(name, "series", "lv_chart_series_t *")
    if depth == 1 and base == "lv_chart_cursor_t":
        return Arg(name, "cursor", "lv_chart_cursor_t *")
    # The image source of lv_image_set_src: an ImageFromTexture or
    # ImageFromArray handle. Other void pointers stay refused.
    if depth == 1 and base == "void" and is_const and name == "src":
        return Arg(name, "imgsrc", "const void *")
    # An input int32 array; build_funcs pairs it with the count after it.
    if depth == 1 and base == "int32_t" and is_const:
        return Arg(name, "i32vec", "const int32_t *", "int32_t")
    if depth == 1 and base in ("uint32_t", "int32_t", "uint16_t", "int16_t"):
        # An array parameter is never an output scalar: a writable one such as
        # lv_chart_set_series_ext_y_array keeps the caller's memory, which a
        # MATLAB argument cannot outlive.
        if isinstance(node, c_ast.ArrayDecl):
            return None
        # An output pointer to a scalar, as in lv_table_get_selected_cell.
        if not is_const:
            return Arg(name, "out_" + base, base + " *", base)
        return None
    if depth:
        return None

    if base == "void":
        return None
    if base == "bool" or base == "_Bool":
        return Arg(name, "bool", "bool")
    if base == "lv_color_t":
        return Arg(name, "color", "lv_color_t")
    if base == "lv_opa_t":
        return Arg(name, "opa", "lv_opa_t")
    if base == "lv_style_selector_t":
        return Arg(name, "selector", "lv_style_selector_t")
    if base in FLOAT_TYPES:
        return Arg(name, "float", base)
    if base in INT_TYPES:
        return Arg(name, "int", base, base)

    kind, resolved = resolve_typedef(collector, base)
    if kind == "enum":
        return Arg(name, "enum", base, "int32_t")
    if kind == "scalar":
        if resolved in ("bool", "_Bool"):
            return Arg(name, "bool", base)
        if resolved in FLOAT_TYPES:
            return Arg(name, "float", base)
        if resolved in INT_TYPES:
            if base in SCALAR_TYPEDEFS:
                return Arg(name, "int", base, resolved)
            if base.startswith("lv_") and base.endswith(ENUMISH_SUFFIXES):
                return Arg(name, "enum", base, resolved)
            return Arg(name, "int", base, resolved)
    return None


def classify_ret(collector, node):
    base, depth, is_const = spell(node)
    if depth == 1 and base == "lv_obj_t":
        return "obj", "lv_obj_t *"
    if depth == 1 and base == "char":
        return "str", "const char *"
    if depth == 1 and base == "lv_chart_series_t":
        return "series", "lv_chart_series_t *"
    if depth == 1 and base == "lv_chart_cursor_t":
        return "cursor", "lv_chart_cursor_t *"
    if depth:
        return None, None
    if base == "void":
        return "void", "void"
    if base in ("bool", "_Bool"):
        return "bool", "bool"
    if base == "lv_color_t":
        return "color", "lv_color_t"
    if base in FLOAT_TYPES:
        return "float", base
    if base in INT_TYPES:
        return "int", base
    kind, resolved = resolve_typedef(collector, base)
    if kind == "enum":
        return "int", base
    if kind == "scalar" and resolved in ("bool", "_Bool"):
        return "bool", base
    if kind == "scalar" and resolved in INT_TYPES:
        return "int", base
    if kind == "scalar" and resolved in FLOAT_TYPES:
        return "float", base
    return None, None


def build_funcs(collector, wanted, rules, dropped):
    out = []
    for cname in sorted(wanted):
        decl = collector.funcs.get(cname)
        if decl is None:
            dropped.append((cname, "not declared in the configured headers"))
            continue
        fd = decl.type
        ret_kind, ret_ctype = classify_ret(collector, fd.type)
        if ret_kind is None:
            base, depth, _ = spell(fd.type)
            dropped.append((cname, "return type %s%s" % (base, " *" * depth)))
            continue
        args = []
        bad = None
        params = fd.args.params if fd.args else []
        i = 0
        while i < len(params):
            p = params[i]
            if isinstance(p, c_ast.EllipsisParam):
                bad = "variadic"
                break
            base, depth, _ = spell(p.type)
            if base == "void" and depth == 0:
                i += 1
                continue
            a = classify_arg(collector, p.name or "a%d" % len(args), p.type, cname)
            if a is None:
                bad = "argument %s of type %s%s" % (p.name, base, " *" * depth)
                break
            if a.kind == "out_str":
                nxt = params[i + 1] if i + 1 < len(params) else None
                nb, nd, _ = spell(nxt.type) if nxt is not None else ("", 1, False)
                if nd != 0 or nb not in INT_TYPES:
                    bad = "output buffer %s without a size argument" % p.name
                    break
                i += 1          # the size argument is supplied by the handler
            if a.kind == "i32vec":
                nxt = params[i + 1] if i + 1 < len(params) else None
                nb, nd, _ = spell(nxt.type) if nxt is not None else ("", 1, False)
                nname = (nxt.name or "") if nxt is not None else ""
                if nd != 0 or nb not in ("size_t", "uint32_t") or not re.search(
                        r"(cnt|count|len|num|size)$", nname):
                    bad = "argument %s of type int32_t * without a count argument" % p.name
                    break
                i += 1          # the count comes from the MATLAB vector length
            args.append(a)
            i += 1
        if bad:
            dropped.append((cname, bad))
            continue
        out.append(Func(cname, ret_kind, ret_ctype, args))
    return out


def collect_wanted(allow, collector):
    wanted = set()
    for _, section in allow.get("widgets", {}).items():
        wanted.update(section.get("functions", []))
    rules = allow.get("rules", {})
    if rules.get("style_setters"):
        for name in collector.funcs:
            if name.startswith("lv_obj_set_style_"):
                wanted.add(name)
    for suffix in rules.get("exclude_suffix", []):
        wanted = {w for w in wanted if not w.endswith(suffix)}
    return wanted, rules


# --------------------------------------------------------------------------
# emitters
# --------------------------------------------------------------------------

BANNER = ("/* Generated by gen/generate.py. Do not edit.\n"
          " * Regenerate with `build gen` after changing gen/allowlist.toml. */\n")

READERS = {
    "obj":      'plv_arg_obj(prhs[%d], %d)',
    "int":      'plv_arg_int(prhs[%d], %d, %s, %s)',
    "float":    'plv_arg_double(prhs[%d], %d)',
    "bool":     'plv_arg_bool(prhs[%d], %d)',
    "str":      'plv_arg_str(prhs[%d], %d, &sbuf%d)',
    "color":    'plv_arg_color(prhs[%d], %d)',
    "opa":      'plv_arg_opa(prhs[%d], %d)',
    "enum":     'plv_arg_enum(prhs[%d], %d)',
    "selector": 'plv_arg_selector(prhs, nrhs, %d)',
    "font":     'plv_arg_font(prhs[%d], %d)',
}

# Casting to a struct type is not legal C, and the scalar readers already
# return the right width, so only the integer-like kinds get a cast.
CAST_KINDS = {"int", "enum", "selector"}

# Functions after which the handle of their series or cursor argument is
# stale. LVGL frees the struct inside the call.
RELEASES = {"lv_chart_remove_series", "lv_chart_remove_cursor"}

RES_KIND = {"series": "PLV_RES_SERIES", "cursor": "PLV_RES_CURSOR"}


def emit_handler(f):
    lines = []
    lines.append("static void plv_op_%s(int nlhs, mxArray * plhs[], int nrhs, "
                 "const mxArray * prhs[])" % f.opname)
    lines.append("{")

    n_required = len(f.in_args)
    trailing_selector = (f.in_args and f.in_args[-1].kind == "selector")
    if trailing_selector:
        guard = ["    /* The style selector is optional and defaults to LV_PART_MAIN. */",
                 "    plv_need_args(nrhs, %d, %d, \"%s\");" %
                 (n_required - 1, n_required, f.opname)]
    else:
        guard = ["    plv_need_args(nrhs, %d, %d, \"%s\");" %
                 (n_required, n_required, f.opname)]

    # The chart of a series or cursor argument is the first object argument.
    chart_pos = 0
    pos = 1
    for a in f.in_args:
        if a.kind == "obj":
            chart_pos = pos
            break
        pos += 1

    # locals
    sbuf = 0
    vbuf = 0
    decls = []
    calls = []
    pre = []
    release_pos = None
    argpos = 1
    for a in f.args:
        if a.kind == "out_str":
            decls.append("    char %s[256] = { 0 };" % a.name)
            calls.append(a.name)
            calls.append("(uint32_t)sizeof(%s)" % a.name)
            continue
        if a.kind.startswith("out_"):
            decls.append("    %s %s = 0;" % (a.base, a.name))
            calls.append("&" + a.name)
            continue
        if a.kind == "str":
            decls.append("    plv_strbuf_t sbuf%d;" % sbuf)
            calls.append(READERS["str"] % (argpos, argpos, sbuf))
            sbuf += 1
        elif a.kind == "i32vec":
            # Read before the call: the count argument comes from the same
            # read, and C leaves the order of argument evaluation open.
            decls.append("    plv_i32vec_t vbuf%d;" % vbuf)
            decls.append("    const int32_t * vec%d;" % vbuf)
            pre.append("    vec%d = plv_arg_i32vec(prhs[%d], %d, &vbuf%d, 0, 0);"
                       % (vbuf, argpos, argpos, vbuf))
            calls.append("vec%d" % vbuf)
            calls.append("vbuf%d.n" % vbuf)
            vbuf += 1
        elif a.kind in ("series", "cursor"):
            calls.append("plv_arg_%s(prhs, %d, %d)" % (a.kind, argpos, chart_pos))
            if f.cname in RELEASES:
                release_pos = argpos
        elif a.kind == "imgsrc":
            calls.append("plv_arg_image_src(prhs[%d], %d)" % (argpos, argpos))
        elif a.kind == "int":
            lo, hi = INT_TYPES.get(a.base, (-2147483648, 2147483647))
            calls.append("(%s)" % a.ctype + (READERS["int"] % (argpos, argpos, _c(lo), _c(hi))))
        elif a.kind == "selector":
            calls.append("(lv_style_selector_t)" + (READERS["selector"] % argpos))
        elif a.kind == "enum":
            calls.append("(%s)%s" % (a.ctype, READERS["enum"] % (argpos, argpos)))
        else:
            calls.append(READERS[a.kind] % (argpos, argpos))
        argpos += 1

    if f.ret_kind == "obj":
        decls.append("    lv_obj_t * ret;")
    elif f.ret_kind in ("series", "cursor"):
        decls.append("    %s ret;" % f.ret_ctype)
    elif f.ret_kind == "str":
        decls.append("    const char * ret;")
    elif f.ret_kind != "void":
        decls.append("    %s ret;" % f.ret_ctype)
    # C89 declaration order keeps every compiler happy, MSVC included.
    lines.extend(decls)
    if decls:
        lines.append("")
    lines.extend(guard)
    if not f.out_args:
        lines.append("    (void)nlhs;")
    lines.extend(pre)

    call = "%s(%s)" % (f.cname, ", ".join(calls))
    if f.ret_kind == "void":
        lines.append("    %s;" % call)
    else:
        lines.append("    ret = %s;" % call)
    for i in range(sbuf):
        lines.append("    plv_strbuf_free(&sbuf%d);" % i)
    for i in range(vbuf):
        lines.append("    plv_i32vec_free(&vbuf%d);" % i)
    if release_pos is not None:
        lines.append("    plv_res_release_arg(prhs[%d]);" % release_pos)
    lines.append("    plv_check_deferred();")

    # outputs
    out_index = 0
    if f.ret_kind == "obj":
        lines.append("    plhs[0] = plv_ret_obj(ret);")
        out_index = 1
    elif f.ret_kind in ("series", "cursor"):
        lines.append("    plhs[0] = plv_ret_res(ret, %s, plv_arg_obj(prhs[%d], %d));"
                     % (RES_KIND[f.ret_kind], chart_pos, chart_pos))
        out_index = 1
    elif f.ret_kind == "str":
        lines.append("    plhs[0] = plv_ret_str(ret);")
        out_index = 1
    elif f.ret_kind == "bool":
        lines.append("    plhs[0] = mxCreateLogicalScalar(ret ? 1 : 0);")
        out_index = 1
    elif f.ret_kind == "color":
        lines.append("    plhs[0] = plv_ret_color(ret);")
        out_index = 1
    elif f.ret_kind in ("int", "float"):
        lines.append("    plhs[0] = mxCreateDoubleScalar((double)ret);")
        out_index = 1
    for a in f.out_args:
        if a.kind == "out_str":
            lines.append("    if(nlhs > %d) plhs[%d] = mxCreateString(%s);"
                         % (out_index, out_index, a.name))
        else:
            lines.append("    if(nlhs > %d) plhs[%d] = mxCreateDoubleScalar((double)%s);"
                         % (out_index, out_index, a.name))
        out_index += 1
    if out_index == 0:
        lines.append("    (void)plhs;")
    lines.append("}")
    return "\n".join(lines)


def _c(v):
    if v == -2147483648:
        return "(-2147483647 - 1)"
    return str(v)


STYLE_READERS = {
    "int":   "(%s)plv_arg_int(v, pos, %s, %s)",
    "enum":  "(%s)plv_arg_enum(v, pos)",
    "float": "plv_arg_double(v, pos)",
    "bool":  "plv_arg_bool(v, pos)",
    "color": "plv_arg_color(v, pos)",
    "opa":   "(lv_opa_t)plv_arg_opa(v, pos)",
    "font":  "plv_arg_font(v, pos)",
}


def style_props(collector, funcs, dropped):
    """(prop, key, value Arg) for every kept lv_obj_set_style_<prop> whose
    lv_style_set_<prop> takes the same value type. The table key drops the
    underscores, so 'bg_color' and 'BgColor' both find it."""
    out = []
    for f in sorted(funcs, key=lambda x: x.cname):
        if not f.cname.startswith("lv_obj_set_style_"):
            continue
        ins = f.in_args
        if len(ins) != 3 or ins[0].kind != "obj" or ins[2].kind != "selector":
            continue
        prop = f.cname[len("lv_obj_set_style_"):]
        sname = "lv_style_set_" + prop
        decl = collector.funcs.get(sname)
        if decl is None:
            dropped.append(("StyleSetProp " + prop, "no %s in the configured headers" % sname))
            continue
        params = decl.type.args.params if decl.type.args else []
        if len(params) != 2:
            dropped.append(("StyleSetProp " + prop, "%s does not take one value" % sname))
            continue
        a = classify_arg(collector, params[1].name or "value", params[1].type, sname)
        if a is None or a.kind != ins[1].kind or a.kind not in STYLE_READERS:
            dropped.append(("StyleSetProp " + prop, "value type differs from the obj setter"))
            continue
        out.append((prop, prop.replace("_", "").lower(), a))
    keys = [k for _, k, _ in out]
    assert len(keys) == len(set(keys)), "style property keys collide"
    return out


def emit_style_setter(prop, a):
    if a.kind == "int":
        lo, hi = INT_TYPES.get(a.base, (-2147483648, 2147483647))
        expr = STYLE_READERS["int"] % (a.ctype, _c(lo), _c(hi))
    elif a.kind == "enum":
        expr = STYLE_READERS["enum"] % a.ctype
    else:
        expr = STYLE_READERS[a.kind]
    return ("static void plv_sp_%s(lv_style_t * s, const mxArray * v, int pos)\n"
            "{\n    lv_style_set_%s(s, %s);\n}\n") % (prop, prop, expr)


def emit_gen_c(funcs, props, path):
    funcs = sorted(funcs, key=lambda f: f.opname)
    out = [BANNER, '#include "plv_marshal.h"', ""]
    for f in funcs:
        out.append(emit_handler(f))
        out.append("")
    out.append("const plv_op_entry_t plv_gen_ops[] = {")
    for f in funcs:
        out.append('    { "%s", plv_op_%s },' % (f.opname, f.opname))
    out.append("};")
    out.append("")
    out.append("const int plv_gen_op_count = %d;" % len(funcs))
    out.append("")
    out.append("/* StyleSetProp: one setter per style property, sorted by key. */")
    out.append("")
    for prop, _, a in sorted(props):
        out.append(emit_style_setter(prop, a))
    out.append("const plv_style_prop_entry_t plv_style_props[] = {")
    for prop, key, _ in sorted(props, key=lambda t: t[1]):
        out.append('    { "%s", plv_sp_%s },' % (key, prop))
    out.append("};")
    out.append("")
    out.append("const int plv_style_prop_count = %d;" % len(props))
    out.append("")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(out))


def emit_enums_c(names, path):
    """The C compiler evaluates the constants, so no expression evaluator is
    needed here and the table can never drift from the headers."""
    names = sorted(set(names))
    out = [BANNER, '#include "plv_marshal.h"', "",
           "const plv_enum_entry_t plv_enum_table[] = {"]
    for n in names:
        out.append('    { "%s", (double)(%s) },' % (n, n))
    out.append("};")
    out.append("")
    out.append("const int plv_enum_count = %d;" % len(names))
    out.append("")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(out))


def sig_text(f):
    ins = ", ".join(a.name for a in f.in_args)
    outs = []
    if f.ret_kind != "void":
        outs.append("ret")
    outs.extend(a.name for a in f.out_args)
    lhs = ""
    if len(outs) == 1:
        lhs = "%s = " % outs[0]
    elif outs:
        lhs = "[%s] = " % ", ".join(outs)
    return "%sPsychLVGL('%s'%s)" % (lhs, f.opname, (", " + ins) if ins else "")


HAND_WRITTEN = [
    ("Init", "glTex = PsychLVGL('Init', w, h [, opts])"),
    ("Shutdown", "PsychLVGL('Shutdown')"),
    ("Update", "dirty = PsychLVGL('Update', tNow, mouse, wheel, keys)"),
    ("Poll", "E = PsychLVGL('Poll')"),
    ("Version", "v = PsychLVGL('Version')"),
    ("Opcode", "op = PsychLVGL('Opcode', name)"),
    ("Stats", "s = PsychLVGL('Stats' [, 'reset'])"),
    ("StatsAddFrame", "PsychLVGL('StatsAddFrame', dt)"),
    ("Enum", "v = PsychLVGL('Enum', 'LV_EVENT_CLICKED')"),
    ("FontList", "names = PsychLVGL('FontList')"),
    ("Log", "PsychLVGL('Log', level)"),
    ("ScreenActive", "h = PsychLVGL('ScreenActive')"),
    ("ScreenCreate", "h = PsychLVGL('ScreenCreate')"),
    ("ScreenLoad", "PsychLVGL('ScreenLoad', h)"),
    ("ObjDelete", "PsychLVGL('ObjDelete', h)"),
    ("IsValid", "tf = PsychLVGL('IsValid', h)"),
    ("AddEvent", "PsychLVGL('AddEvent', h, 'LONG_PRESSED')"),
    ("RemoveEvent", "PsychLVGL('RemoveEvent', h, 'LONG_PRESSED')"),
    ("AddToGroup", "PsychLVGL('AddToGroup', h)"),
    ("RemoveFromGroup", "PsychLVGL('RemoveFromGroup', h)"),
    ("FocusObj", "PsychLVGL('FocusObj', h)"),
    ("EventName", "name = PsychLVGL('EventName', code)"),
    ("FrameChecksum", "crc = PsychLVGL('FrameChecksum')"),
    ("StyleCreate", "style = PsychLVGL('StyleCreate')"),
    ("StyleDelete", "PsychLVGL('StyleDelete', style)"),
    ("StyleSetProp", "PsychLVGL('StyleSetProp', style, 'bg_color', value)"),
    ("ObjAddStyle", "PsychLVGL('ObjAddStyle', h, style [, selector])"),
    ("ObjRemoveStyle", "PsychLVGL('ObjRemoveStyle', h, style [, selector])"),
    ("ObjRemoveStyleAll", "PsychLVGL('ObjRemoveStyleAll', h)"),
    ("ImageFromTexture", "img = PsychLVGL('ImageFromTexture', glTex, w, h [, transposed])"),
    ("ImageFromArray", "img = PsychLVGL('ImageFromArray', uint8Image)"),
    ("ImageDelete", "PsychLVGL('ImageDelete', img)"),
    ("FontLoad", "font = PsychLVGL('FontLoad', ttfPath, px)"),
    ("FontDelete", "PsychLVGL('FontDelete', font)"),
    ("ChartSetValues", "PsychLVGL('ChartSetValues', chart, series, values)"),
    ("ChartGetValues", "values = PsychLVGL('ChartGetValues', chart, series)"),
    ("ParseXML", "tree = PsychLVGL('ParseXML', pathOrText)"),
]


def emit_help_m(funcs, path):
    funcs = sorted(funcs, key=lambda f: f.opname)
    lines = [
        "function varargout = PsychLVGL(varargin) %#ok<STOUT,INUSD>",
        "% PSYCHLVGL  LVGL 9 retained mode GUI panels for Psychtoolbox.",
        "%",
        "%   This file holds the help text. The compiled MEX in dist/<arch> shadows it.",
        "%   If you see this error, the MEX is not built or not on the path.",
        "%",
        "%   Lifecycle and hand written subcommands:",
    ]
    for name, sig in HAND_WRITTEN:
        lines.append("%%     %s" % sig)
    lines.append("%")
    lines.append("%   Generated subcommands (one per allowlisted LVGL function):")
    for f in funcs:
        lines.append("%%     %s" % sig_text(f))
    lines.append("%")
    lines.append("%   StyleSetProp takes the property names of the ObjSetStyle<Prop>")
    lines.append("%   subcommands, for example 'bg_color' or 'text_font', and the same value.")
    lines.append("%   Font arguments take a built-in name from FontList or a FontLoad handle.")
    lines.append("%")
    lines.append("%   See SPEC.md for the marshaling rules and DEV.md for the build.")
    lines.append("")
    lines.append("error('psychlvgl:NotBuilt', ...")
    lines.append("      'The PsychLVGL MEX is not on the path. Run PsychLVGLSetup; in a source checkout, run build first.');")
    lines.append("end")
    lines.append("")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))


def emit_opcodes_m(funcs, path):
    """Opcodes are the index into the dispatch table, hand written entries
    first, so a script can skip the name lookup on the per-frame path."""
    names = [n for n, _ in HAND_WRITTEN] + sorted(f.opname for f in funcs)
    lines = [
        "function op = PsychLVGLOp()",
        "% PSYCHLVGLOP  Numeric opcodes for the PsychLVGL subcommands.",
        "%   Generated by gen/generate.py. PsychLVGL('Opcode', name) returns the",
        "%   same numbers at run time.",
        "",
        "    persistent cached",
        "    if isempty(cached)",
        "        cached = struct( ...",
    ]
    for i, n in enumerate(names):
        tail = ", ..." if i < len(names) - 1 else ");"
        lines.append("            '%s', %d%s" % (n, i + 1, tail))
    lines.append("    end")
    lines.append("    op = cached;")
    lines.append("end")
    lines.append("")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))


SAMPLE = {
    "obj":      "target",
    "int":      "1",
    "float":    "1",
    "bool":     "true",
    "str":      "'x'",
    "color":    "[10 20 30]",
    "opa":      "255",
    "enum":     "0",
    "selector": "0",
    "font":     "'montserrat_16'",
    "i32vec":   "[1 2 3]",
    "imgsrc":   "0",
    "series":   "t_chart_ser",
    "cursor":   "t_chart_cur",
}

# What creates a fresh series or cursor for a call that frees its argument.
FRESH = {
    "series": "PsychLVGL('ChartAddSeries', t_chart, [255 0 0], 0)",
    "cursor": "PsychLVGL('ChartAddCursor', t_chart, [0 0 255], 0)",
}


def emit_test_m(funcs, path):
    funcs = sorted(funcs, key=lambda f: f.opname)

    # Calling lv_label_set_text on a plain object trips LV_ASSERT_OBJ, so each
    # family gets a target of its own widget class.
    widgets = {f.cname.split("_")[1] for f in funcs}
    creatable = {w for w in widgets
                 if any(f.cname == "lv_%s_create" % w for f in funcs)}

    lines = [
        "function test_gen_marshal()",
        "% TEST_GEN_MARSHAL  Calls every generated subcommand once.",
        "%   Generated by gen/generate.py. The point is coverage of the marshaling",
        "%   layer, not of LVGL behavior: each call uses valid arguments and the",
        "%   output count is checked.",
        "",
        "    PsychLVGL('Init', 240, 240);",
        "    c = onCleanup(@() PsychLVGL('Shutdown'));",
        "    scr = PsychLVGL('ScreenActive');",
    ]
    for w in sorted(creatable):
        lines.append("    t_%s = PsychLVGL('%sCreate', scr);" % (w, camel("lv_" + w)))
    for w in sorted(widgets - creatable):
        lines.append("    t_%s = PsychLVGL('ObjCreate', scr);" % w)
    names = {f.opname for f in funcs}
    if "ChartAddSeries" in names:
        lines.append("    t_chart_ser = %s;" % FRESH["series"])
    if "ChartAddCursor" in names:
        lines.append("    t_chart_cur = %s;" % FRESH["cursor"])
    lines.append("")

    for f in funcs:
        if any(a.kind == "font" for a in f.in_args):
            continue
        target = "t_" + f.cname.split("_")[1]
        args = []
        first = True
        for a in f.in_args:
            if a.kind == "obj" and first:
                args.append(target)
            elif a.kind == "obj":
                args.append("scr")
            elif a.kind in FRESH and f.cname in RELEASES:
                args.append(FRESH[a.kind])
            else:
                args.append(SAMPLE.get(a.kind, "0"))
            first = False
        nout = (1 if f.ret_kind != "void" else 0) + len(f.out_args)
        call = "PsychLVGL('%s'%s)" % (f.opname, (", " + ", ".join(args)) if args else "")
        lines.append("    gen_call('%s', @() %s, %d);" % (f.opname, call, nout))

    lines.append("end")
    lines.append("")
    lines.append("function gen_call(name, fn, nout)")
    lines.append("    global TST_PASS TST_FAIL %#ok<GVMIS>")
    lines.append("    try")
    lines.append("        if nout == 0")
    lines.append("            fn();")
    lines.append("        else")
    lines.append("            out = cell(1, nout);")
    lines.append("            [out{1:nout}] = fn(); %#ok<NASGU>")
    lines.append("        end")
    lines.append("        TST_PASS = TST_PASS + 1;")
    lines.append("    catch err")
    lines.append("        TST_FAIL = TST_FAIL + 1;")
    lines.append("        fprintf(2, '  FAIL  gen %s: %s\\n', name, err.message);")
    lines.append("    end")
    lines.append("end")
    lines.append("")
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))


# --------------------------------------------------------------------------

EXTRA_ENUM_NAMES = [
    "LV_SIZE_CONTENT", "LV_RADIUS_CIRCLE", "LV_COORD_MAX", "LV_COORD_MIN",
    "LV_OPA_TRANSP", "LV_OPA_COVER",
]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dump", action="store_true", help="print the signatures and stop")
    args = ap.parse_args()

    with open(os.path.join(HERE, "allowlist.toml"), "rb") as fh:
        allow = tomllib.load(fh)

    tmp = tempfile.mkdtemp(suffix=".psychlvgl_gen")
    try:
        text = strip_attributes(preprocess(tmp))
        ast = pycparser.CParser().parse(text, "lvgl.h")
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    collector = Collector()
    collector.visit(ast)

    wanted, rules = collect_wanted(allow, collector)
    dropped = []
    funcs = build_funcs(collector, wanted, rules, dropped)

    if args.dump:
        for f in sorted(funcs, key=lambda x: x.cname):
            print("%-40s %s" % (f.cname, sig_text(f)))
        print("")
        for name, why in sorted(dropped):
            print("DROPPED %-40s %s" % (name, why))
        print("\n%d kept, %d dropped, %d enum constants"
              % (len(funcs), len(dropped), len(collector.enum_names)))
        return

    props = style_props(collector, funcs, dropped)
    emit_gen_c(funcs, props, os.path.join(ROOT, "src", "psychlvgl_gen.c"))
    emit_enums_c(collector.enum_names + EXTRA_ENUM_NAMES,
                 os.path.join(ROOT, "src", "psychlvgl_enums.c"))
    emit_help_m(funcs, os.path.join(ROOT, "m", "PsychLVGL.m"))
    emit_opcodes_m(funcs, os.path.join(ROOT, "m", "PsychLVGLOp.m"))
    emit_test_m(funcs, os.path.join(ROOT, "tests", "test_gen_marshal.m"))

    with open(os.path.join(HERE, "dropped.txt"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write("# Allowlisted LVGL functions the SPEC 7.3 rules cannot marshal.\n")
        for name, why in sorted(dropped):
            fh.write("%-44s %s\n" % (name, why))

    print("generated %d subcommands, %d style properties, %d enum constants, "
          "%d functions dropped"
          % (len(funcs), len(props), len(set(collector.enum_names)), len(dropped)))


if __name__ == "__main__":
    main()
