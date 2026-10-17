/*
 * Test helper module "lpcre_testcarray": creates carray objects that cannot
 * be made from Lua, through the Carray C API (the "carray" module must be
 * installed). Used by tests/test02.lua for the gsub error cases.
 *
 *   tc.readonly(str)  -> read-only carray with the bytes of str
 *   tc.ref(str)       -> writable carray referencing foreign memory (a copy of
 *                        str): it cannot be resized
 */
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#if LUA_VERSION_NUM < 502
#  define lua_rawlen lua_objlen   /* used by carray_capi.h */
#endif

#define CARRAY_CAPI_IMPLEMENT_REQUIRE_CAPI 1
#include "../src/carray_capi.h"

#ifdef _WIN32
#  define TC_EXPORT __declspec(dllexport)
#else
#  define TC_EXPORT __attribute__ ((visibility ("default")))
#endif

static int Tc_readonly(lua_State* L)
{
    size_t             len;
    const char*        str  = luaL_checklstring(L, 1, &len);
    const carray_capi* capi = carray_require_capi(L);
    void*              data = NULL;
    carray*            ca   = capi->newCarray(L, CARRAY_UCHAR, CARRAY_READONLY, len, &data);
    if (!ca) {
        return luaL_error(L, "cannot create carray");
    }
    if (len > 0) {
        memcpy(data, str, len);
    }
    return 1;
}

static void releaseRef(void* dataRef, size_t elementCount)
{
    (void)elementCount;
    free(dataRef);
}

static int Tc_ref(lua_State* L)
{
    size_t             len;
    const char*        str  = luaL_checklstring(L, 1, &len);
    const carray_capi* capi = carray_require_capi(L);
    char*              data = (char*)malloc(len > 0 ? len : 1);
    carray*            ca;
    if (!data) {
        return luaL_error(L, "not enough memory");
    }
    memcpy(data, str, len);
    ca = capi->newCarrayRef(L, CARRAY_UCHAR, CARRAY_DEFAULT, data, len, releaseRef);
    if (!ca) {
        free(data);
        return luaL_error(L, "cannot create carray");
    }
    return 1;
}

TC_EXPORT int luaopen_lpcre_testcarray(lua_State* L)
{
    lua_newtable(L);
    lua_pushcfunction(L, Tc_readonly);
    lua_setfield(L, -2, "readonly");
    lua_pushcfunction(L, Tc_ref);
    lua_setfield(L, -2, "ref");
    return 1;
}
