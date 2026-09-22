/**
 * @file plv_assert.h
 * LV_ASSERT_HANDLER for psychlvgl.
 *
 * lv_conf.h names this header through LV_ASSERT_CUSTOM_INCLUDE, so it is
 * pulled in before any LVGL type exists. It must stay free of includes.
 *
 * A failed LVGL assert must not longjmp out of an LVGL stack frame, because
 * LVGL would leak whatever it holds. The hook only records the site and
 * returns; the dispatch layer raises the MATLAB error afterwards.
 */
#ifndef PLV_ASSERT_H
#define PLV_ASSERT_H

#ifdef __cplusplus
extern "C" {
#endif

void plv_assert_hook(const char * file, int line);

#define LV_ASSERT_HANDLER plv_assert_hook(__FILE__, __LINE__);

#ifdef __cplusplus
}
#endif

#endif /* PLV_ASSERT_H */
