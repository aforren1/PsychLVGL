/**
 * @file plv_profiler.h
 * Zone macros. They expand to Tracy calls with PSYCHLVGL_TRACY, else nothing.
 */
#ifndef PLV_PROFILER_H
#define PLV_PROFILER_H

#if defined(PSYCHLVGL_TRACY) && PSYCHLVGL_TRACY
#include "tracy/TracyC.h"
#define PLV_ZONE_BEGIN(name) TracyCZoneN(plv_zone_##name, #name, 1)
#define PLV_ZONE_END(name)   TracyCZoneEnd(plv_zone_##name)
#define PLV_FRAME_MARK()     TracyCFrameMark
#else
#define PLV_ZONE_BEGIN(name) ((void)0)
#define PLV_ZONE_END(name)   ((void)0)
#define PLV_FRAME_MARK()     ((void)0)
#endif

#endif /* PLV_PROFILER_H */
