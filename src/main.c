#include "util.h"
#include "main.h"
#include "lpcre.h"

#ifndef LPCRE_VERSION
    #error LPCRE_VERSION is not defined
#endif 

#define LPCRE_STRINGIFY(x) #x
#define LPCRE_TOSTRING(x) LPCRE_STRINGIFY(x)
#define LPCRE_VERSION_STRING LPCRE_TOSTRING(LPCRE_VERSION)

/* ============================================================================================ */

static const char* const LPCRE_MODULE_NAME = "lpcre";

/* ============================================================================================ */


DLL_PUBLIC int luaopen_lpcre(lua_State* L)
{
    luaL_checkversion(L); /* does nothing if compiled for Lua 5.1 */

    /* ---------------------------------------- */

    int n = lua_gettop(L);
    
    int module      = ++n; lua_newtable(L);

    lua_pushliteral(L, LPCRE_VERSION_STRING);
    lua_setfield(L, module, "_VERSION");
    
    luaL_checkstack(L, LUA_MINSTACK, NULL);
    
    lpcre_init_module(L, module);

    lua_newtable(L);                                   /* -> module meta */
    lua_pushstring(L, LPCRE_MODULE_NAME);              /* -> module meta, "lpcre" */
    lua_setfield(L, -2, "__metatable");                /* -> module meta */
    lua_setmetatable(L, module);                       /* -> */
    
    lua_settop(L, module);

    return 1;
}

/* ============================================================================================ */
