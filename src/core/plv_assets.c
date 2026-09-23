/**
 * @file plv_assets.c
 * Styles, images and fonts: the resources a widget points to but does not own.
 *
 * LVGL stores a bare pointer to each of them in the objects that use it and
 * never checks it again, so freeing one that is still in use is a crash that
 * shows up later, at draw time. Every Delete here first looks for users and
 * refuses with psychlvgl:InUse while there are any. The look is a scan of the
 * registered objects, not a reference count: LVGL adds, replaces and drops
 * styles on its own (lv_obj_add_style replaces an entry with the same
 * selector, lv_obj_remove_style takes wildcards, a deleted object drops all
 * of them), and a count kept beside that would drift. Deletes are rare, so
 * the scan costs nothing on the per-frame path.
 */
#include "plv_internal.h"

#include "src/core/lv_obj_private.h"
#include "src/core/lv_obj_style_private.h"
#include "src/misc/cache/instance/lv_image_cache.h"

#include <stdio.h>
#include <stdlib.h>

#if defined(_WIN32)
#include <windows.h>
#endif

typedef struct {
    lv_image_dsc_t dsc;      /* first, so the resource pointer is the image source */
    uint32_t       texture;  /* what dsc.data points to for a texture image */
} plv_image_res_t;

typedef struct {
    lv_font_t * font;
    uint8_t *   data;        /* the TTF file; tiny_ttf reads it for the font's lifetime */
} plv_font_res_t;

/* ------------------------------------------------------------------ shared */

void plv_assets_free(plv_res_kind_t kind, void * ptr)
{
    if(!ptr) return;
    switch(kind) {
        case PLV_RES_STYLE:
            lv_style_reset((lv_style_t *)ptr);
            free(ptr);
            break;
        case PLV_RES_IMAGE:
            /* Draw units may cache a texture per source pointer; the pointer
             * is about to be reused by the allocator. */
            lv_image_cache_drop(ptr);
            free(ptr);
            break;
        case PLV_RES_FONT: {
                plv_font_res_t * f = (plv_font_res_t *)ptr;
#if LV_USE_TINY_TTF
                lv_tiny_ttf_destroy(f->font);
#endif
                free(f->data);
                free(f);
                break;
            }
        default:
            break;
    }
}

/* ------------------------------------------------------------------ styles */

double plv_style_create(plv_err_t * err)
{
    double h;
    lv_style_t * s = (lv_style_t *)calloc(1, sizeof(lv_style_t));
    if(!s) {
        plv_fail(err, "psychlvgl:Range", "out of memory for a style");
        return 0.0;
    }
    lv_style_init(s);
    h = plv_res_register(PLV_RES_STYLE, s, NULL, err);
    if(h == 0.0) free(s);
    return h;
}

uint32_t plv_style_use_count(const lv_style_t * style)
{
    uint32_t i, k, n = 0;
    if(!g_plv.slots) return 0;
    for(i = 1; i <= g_plv.slot_count; i++) {
        const lv_obj_t * obj = g_plv.slots[i].obj;
        if(!obj) continue;
        for(k = 0; k < obj->style_cnt; k++)
            if(obj->styles[k].style == style) n++;
    }
    return n;
}

int plv_style_delete(double handle, plv_err_t * err)
{
    uint32_t users;
    lv_style_t * s = (lv_style_t *)plv_res_resolve(handle, PLV_RES_STYLE, err);
    if(!s) return 1;
    users = plv_style_use_count(s);
    if(users)
        return plv_fail(err, "psychlvgl:InUse",
                        "style %.0f is still added to %u object(s); call ObjRemoveStyle or "
                        "delete those objects first", handle, (unsigned)users);
    plv_res_release(handle);
    plv_assets_free(PLV_RES_STYLE, s);
    return 0;
}

/* ------------------------------------------------------------------ images */

static plv_image_res_t * plv_image_alloc(int32_t w, int32_t h, size_t pixel_bytes, plv_err_t * err)
{
    plv_image_res_t * img;

    if(w < 1 || h < 1 || w > PLV_IMAGE_MAX_SIDE || h > PLV_IMAGE_MAX_SIDE) {
        plv_fail(err, "psychlvgl:Range", "image size %dx%d is outside 1 to %d",
                 (int)w, (int)h, PLV_IMAGE_MAX_SIDE);
        return NULL;
    }
    img = (plv_image_res_t *)calloc(1, sizeof(plv_image_res_t) + pixel_bytes);
    if(!img) {
        plv_fail(err, "psychlvgl:Range", "out of memory for a %dx%d image", (int)w, (int)h);
        return NULL;
    }
    img->dsc.header.magic  = LV_IMAGE_HEADER_MAGIC;
    img->dsc.header.cf     = LV_COLOR_FORMAT_ARGB8888;
    img->dsc.header.w      = (uint32_t)w;
    img->dsc.header.h      = (uint32_t)h;
    img->dsc.header.stride = (uint32_t)w * 4u;
    return img;
}

static double plv_image_register(plv_image_res_t * img, plv_err_t * err)
{
    double h = plv_res_register(PLV_RES_IMAGE, img, NULL, err);
    if(h == 0.0) free(img);
    return h;
}

double plv_image_create_argb(int32_t w, int32_t h, uint8_t ** out_pixels, plv_err_t * err)
{
    size_t bytes = (size_t)w * (size_t)h * 4u;
    plv_image_res_t * img = plv_image_alloc(w, h, bytes, err);
    if(!img) return 0.0;
    img->dsc.data      = (const uint8_t *)(img + 1);
    img->dsc.data_size = (uint32_t)bytes;
    if(out_pixels) *out_pixels = (uint8_t *)(img + 1);
    return plv_image_register(img, err);
}

double plv_image_from_texture(uint32_t texture, int32_t w, int32_t h, plv_err_t * err)
{
    plv_image_res_t * img;

    if(texture == 0) {
        plv_fail(err, "psychlvgl:Range", "texture name 0 is not a texture");
        return 0.0;
    }
#if LV_USE_DRAW_NANOVG
    img = plv_image_alloc(w, h, 0, err);
    if(!img) return 0.0;
    /* The vendored patch 0002 teaches the NanoVG draw unit to draw this
     * descriptor straight from the texture, so no pixel crosses the CPU. */
    img->texture          = texture;
    img->dsc.header.flags = LV_IMAGE_FLAGS_GL_TEXTURE;
    img->dsc.data         = (const uint8_t *)&img->texture;
    img->dsc.data_size    = (uint32_t)sizeof(img->texture);
#else
    /* The software variant has no OpenGL. A transparent image of the same
     * size keeps layout, handles and deletion identical to the GPU build. */
    {
        size_t bytes = (size_t)w * (size_t)h * 4u;
        img = plv_image_alloc(w, h, bytes, err);
        if(!img) return 0.0;
        img->texture       = texture;
        img->dsc.data      = (const uint8_t *)(img + 1);
        img->dsc.data_size = (uint32_t)bytes;
    }
#endif
    return plv_image_register(img, err);
}

uint32_t plv_image_use_count(const void * src)
{
    uint32_t i, n = 0;
    if(!g_plv.slots) return 0;
    for(i = 1; i <= g_plv.slot_count; i++) {
        lv_obj_t * obj = g_plv.slots[i].obj;
        if(!obj) continue;
        if(lv_obj_check_type(obj, &lv_image_class) && lv_image_get_src(obj) == src) n++;
    }
    return n;
}

int plv_image_delete(double handle, plv_err_t * err)
{
    uint32_t users;
    plv_image_res_t * img = (plv_image_res_t *)plv_res_resolve(handle, PLV_RES_IMAGE, err);
    if(!img) return 1;
    users = plv_image_use_count(img);
    if(users)
        return plv_fail(err, "psychlvgl:InUse",
                        "image %.0f is still the source of %u image object(s); call "
                        "ImageSetSrc with 0 or delete those objects first",
                        handle, (unsigned)users);
    plv_res_release(handle);
    plv_assets_free(PLV_RES_IMAGE, img);
    return 0;
}

/* ------------------------------------------------------------------- fonts */

static FILE * plv_fopen_utf8(const char * path)
{
#if defined(_WIN32)
    /* fopen takes the ANSI code page on Windows, so a path with any
     * character outside it would not open. */
    wchar_t wide[1024];
    if(MultiByteToWideChar(CP_UTF8, 0, path, -1, wide, (int)(sizeof(wide) / sizeof(wide[0]))) == 0)
        return NULL;
    return _wfopen(wide, L"rb");
#else
    return fopen(path, "rb");
#endif
}

/* The four tags a TrueType or OpenType file (or a collection) starts with.
 * tiny_ttf trusts the table offsets it reads, so a file that is not a font
 * at all is refused before it gets there. */
static int plv_is_font_file(const uint8_t * d, size_t n)
{
    if(n < 12) return 0;
    if(d[0] == 0x00 && d[1] == 0x01 && d[2] == 0x00 && d[3] == 0x00) return 1;
    if(memcmp(d, "true", 4) == 0 || memcmp(d, "OTTO", 4) == 0 || memcmp(d, "ttcf", 4) == 0) return 1;
    return 0;
}

double plv_font_load(const char * path_utf8, int32_t px, plv_err_t * err)
{
#if LV_USE_TINY_TTF
    FILE * fp;
    long size;
    plv_font_res_t * f;
    double h;

    if(px < 1 || px > PLV_FONT_MAX_PX) {
        plv_fail(err, "psychlvgl:Range", "font size %d px is outside 1 to %d",
                 (int)px, PLV_FONT_MAX_PX);
        return 0.0;
    }
    fp = plv_fopen_utf8(path_utf8);
    if(!fp) {
        plv_fail(err, "psychlvgl:Font", "cannot open font file '%s'", path_utf8);
        return 0.0;
    }
    if(fseek(fp, 0, SEEK_END) != 0 || (size = ftell(fp)) <= 0 || size > (64L << 20)
       || fseek(fp, 0, SEEK_SET) != 0) {
        fclose(fp);
        plv_fail(err, "psychlvgl:Font", "font file '%s' is empty, unreadable, or above 64 MB",
                 path_utf8);
        return 0.0;
    }
    f = (plv_font_res_t *)calloc(1, sizeof(*f));
    if(f) f->data = (uint8_t *)malloc((size_t)size);
    if(!f || !f->data) {
        fclose(fp);
        if(f) free(f);
        plv_fail(err, "psychlvgl:Range", "out of memory for font file '%s'", path_utf8);
        return 0.0;
    }
    if(fread(f->data, 1, (size_t)size, fp) != (size_t)size) {
        fclose(fp);
        free(f->data);
        free(f);
        plv_fail(err, "psychlvgl:Font", "could not read font file '%s'", path_utf8);
        return 0.0;
    }
    fclose(fp);

    if(!plv_is_font_file(f->data, (size_t)size)) {
        free(f->data);
        free(f);
        plv_fail(err, "psychlvgl:Font", "'%s' is not a TrueType or OpenType font", path_utf8);
        return 0.0;
    }

    f->font = lv_tiny_ttf_create_data_ex(f->data, (size_t)size, px, LV_FONT_KERNING_NORMAL,
                                         LV_TINY_TTF_CACHE_GLYPH_CNT);
    if(!f->font) {
        free(f->data);
        free(f);
        plv_fail(err, "psychlvgl:Font", "tiny_ttf could not parse '%s'", path_utf8);
        return 0.0;
    }
    h = plv_res_register(PLV_RES_FONT, f, NULL, err);
    if(h == 0.0) plv_assets_free(PLV_RES_FONT, f);
    return h;
#else
    LV_UNUSED(path_utf8);
    LV_UNUSED(px);
    plv_fail(err, "psychlvgl:Font", "this build has no TTF support (LV_USE_TINY_TTF is 0)");
    return 0.0;
#endif
}

static int plv_style_names_font(const lv_style_t * style, const lv_font_t * font)
{
    lv_style_value_t v;
    if(lv_style_get_prop(style, LV_STYLE_TEXT_FONT, &v) != LV_STYLE_RES_FOUND) return 0;
    return v.ptr == (const void *)font;
}

uint32_t plv_font_use_count(const lv_font_t * font)
{
    uint32_t i, k, n = 0;

    /* A style that names the font counts even when no object uses it yet:
     * adding it later would hand LVGL a freed font. */
    if(g_plv.res) {
        for(i = 1; i <= g_plv.res_count; i++)
            if(g_plv.res[i].ptr && g_plv.res[i].kind == PLV_RES_STYLE
               && plv_style_names_font((const lv_style_t *)g_plv.res[i].ptr, font)) n++;
    }
    /* Local styles are where ObjSetStyleTextFont puts the pointer. */
    if(g_plv.slots) {
        for(i = 1; i <= g_plv.slot_count; i++) {
            const lv_obj_t * obj = g_plv.slots[i].obj;
            if(!obj) continue;
            for(k = 0; k < obj->style_cnt; k++)
                if(obj->styles[k].is_local && plv_style_names_font(obj->styles[k].style, font)) n++;
        }
    }
    return n;
}

int plv_font_delete(double handle, plv_err_t * err)
{
    uint32_t users;
    plv_font_res_t * f = (plv_font_res_t *)plv_res_resolve(handle, PLV_RES_FONT, err);
    if(!f) return 1;
    users = plv_font_use_count(f->font);
    if(users)
        return plv_fail(err, "psychlvgl:InUse",
                        "font %.0f is still named by %u style(s); set another font there "
                        "or delete those styles and objects first", handle, (unsigned)users);
    plv_res_release(handle);
    plv_assets_free(PLV_RES_FONT, f);
    return 0;
}

const lv_font_t * plv_font_resolve(double handle, plv_err_t * err)
{
    plv_font_res_t * f = (plv_font_res_t *)plv_res_resolve(handle, PLV_RES_FONT, err);
    return f ? f->font : NULL;
}
