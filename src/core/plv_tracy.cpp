// The one part of the Tracy integration that has to be C++, compiled only
// with PSYCHLVGL_TRACY=ON.
//
// Tracy's C API emits GPU zones but has no call that hands out a GPU context
// id. The C++ integrations take theirs from a shared counter, so this one does
// too; a private number could collide with another GPU context in the process.

#include "client/TracyProfiler.hpp"

extern "C" unsigned char plv_tracy_gpu_context(void)
{
    return tracy::GetGpuCtxCounter().fetch_add(1, std::memory_order_relaxed);
}
