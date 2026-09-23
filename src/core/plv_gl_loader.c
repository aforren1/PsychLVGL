/**
 * @file plv_gl_loader.c
 * Loads the OpenGL entry points into LVGL's vendored glad.
 *
 * LVGL calls gladLoadGL only from its GLFW and EGL drivers. The texture
 * driver alone leaves the entry points null, so the embedding application has
 * to load them. Psychtoolbox owns the context, so all this file does is hand
 * glad a per-platform address lookup.
 */
#include "plv_gl_loader.h"

#if defined(_WIN32)
#include <windows.h>
#endif

#include "glad/gl.h"

#if defined(_WIN32)

static HMODULE s_opengl32;

static GLADapiproc plv_get_proc(const char * name)
{
    PROC p = wglGetProcAddress(name);
    /* wglGetProcAddress only knows the extensions and the modern core; the
     * GL 1.1 entry points live in opengl32.dll itself. */
    if(p == NULL || p == (PROC)1 || p == (PROC)2 || p == (PROC)3 || p == (PROC) - 1) {
        if(!s_opengl32) s_opengl32 = LoadLibraryA("opengl32.dll");
        if(s_opengl32) p = GetProcAddress(s_opengl32, name);
    }
    return (GLADapiproc)p;
}

int plv_gl_has_context(void)
{
    return wglGetCurrentContext() != NULL;
}

void * plv_gl_context(void)
{
    return (void *)wglGetCurrentContext();
}

#elif defined(__APPLE__)

#include <dlfcn.h>
#include <OpenGL/OpenGL.h>

static void * s_framework;

static GLADapiproc plv_get_proc(const char * name)
{
    if(!s_framework)
        s_framework = dlopen("/System/Library/Frameworks/OpenGL.framework/OpenGL", RTLD_LAZY);
    if(!s_framework) return NULL;
    return (GLADapiproc)dlsym(s_framework, name);
}

int plv_gl_has_context(void)
{
    return CGLGetCurrentContext() != NULL;
}

void * plv_gl_context(void)
{
    return (void *)CGLGetCurrentContext();
}

#else

/* Declared here rather than through GL/glx.h so that building the MEX needs
 * no GLX development headers, only libGL itself, which exports both symbols.
 * The MATLAB CI runner, for one, has libGL but not the headers. */
extern GLADapiproc glXGetProcAddressARB(const unsigned char * name);
extern void * glXGetCurrentContext(void);

static GLADapiproc plv_get_proc(const char * name)
{
    return glXGetProcAddressARB((const unsigned char *)name);
}

int plv_gl_has_context(void)
{
    return glXGetCurrentContext() != NULL;
}

void * plv_gl_context(void)
{
    return (void *)glXGetCurrentContext();
}

#endif

int plv_gl_load(void)
{
    if(gladLoadGL(plv_get_proc) == 0) return 0;

    /* glad's ALIAS output fills glGenVertexArrays and glDeleteVertexArrays from
     * the APPLE extension on a context without the core names, but not
     * glBindVertexArray: the registry does not list glBindVertexArrayAPPLE as
     * an alias, because the APPLE spec words the binding of object 0 as a
     * return to the default array rather than to no array. For the driver and
     * NanoVG, which bind a generated object and then 0, the two behave the
     * same, so on the GL 2.1 context Psychtoolbox creates on macOS this is
     * what makes the GL2 build start (SPEC deviation D38). */
    if(glad_glBindVertexArray == NULL && glad_glBindVertexArrayAPPLE != NULL)
        glad_glBindVertexArray = (PFNGLBINDVERTEXARRAYPROC)glad_glBindVertexArrayAPPLE;
    if(glad_glIsVertexArray == NULL && glad_glIsVertexArrayAPPLE != NULL)
        glad_glIsVertexArray = (PFNGLISVERTEXARRAYPROC)glad_glIsVertexArrayAPPLE;
    return 1;
}
