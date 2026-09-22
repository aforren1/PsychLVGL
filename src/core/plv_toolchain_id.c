/**
 * @file plv_toolchain_id.c
 * A marker string compiled into the static library. build.m reads it and
 * refuses to link an MSVC library into a MinGW MEX, or the other way round,
 * because the mismatch only shows up as unresolved C runtime symbols.
 */

const char * plv_toolchain_id(void)
{
#if defined(_MSC_VER)
    return "msvc";
#elif defined(__MINGW32__) || defined(__MINGW64__)
    return "mingw";
#elif defined(__clang__)
    return "clang";
#elif defined(__GNUC__)
    return "gcc";
#else
    return "unknown";
#endif
}
