/*
 * Test helper module "lpcre_multistate": creates independent Lua states in
 * the same process and runs code in them, also in parallel OS threads.
 * Used by tests/test03.lua to check that lpcre keeps no global state.
 *
 *   ms.new()                          -> state object, package.path/cpath copied
 *   state:run(code)                   -> results of the chunk (nil/boolean/number/string)
 *   state:close()
 *   ms.parallel(stA, codeA, stB, codeB) -> first result of each chunk (as string),
 *                                        both chunks run at the same time in two threads
 */
#include <string.h>
#include <stdlib.h>

#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#ifdef _WIN32
#  include <windows.h>
#  define MS_EXPORT __declspec(dllexport)
#else
#  include <pthread.h>
#  define MS_EXPORT __attribute__ ((visibility ("default")))
#endif

static const char* const MS_CLASS_NAME = "lpcre_multistate.state";

typedef struct State
{
    lua_State* L;
} State;

static State* checkState(lua_State* L, int idx)
{
    State* st = (State*)luaL_checkudata(L, idx, MS_CLASS_NAME);
    if (!st->L) {
        luaL_argerror(L, idx, "state is closed");
    }
    return st;
}

static void copyPath(lua_State* from, lua_State* to, const char* name)
{
    lua_getglobal(from, "package");
    lua_getfield(from, -1, name);
    lua_getglobal(to, "package");
    lua_pushstring(to, lua_tostring(from, -1));
    lua_setfield(to, -2, name);
    lua_pop(to, 1);
    lua_pop(from, 2);
}

static int Ms_new(lua_State* L)
{
    State* st = (State*)lua_newuserdata(L, sizeof(State));
    st->L = NULL;
    luaL_getmetatable(L, MS_CLASS_NAME);
    lua_setmetatable(L, -2);
    st->L = luaL_newstate();
    if (!st->L) {
        return luaL_error(L, "cannot create Lua state");
    }
    luaL_openlibs(st->L);
    copyPath(L, st->L, "path");
    copyPath(L, st->L, "cpath");
    return 1;
}

/* runs code in st, leaves results or error message on st's stack, returns status */
static int runChunk(lua_State* SL, const char* code, size_t len)
{
    lua_settop(SL, 0);
    if (luaL_loadbuffer(SL, code, len, "=child") != 0) {
        return 1;
    }
    return lua_pcall(SL, 0, LUA_MULTRET, 0);
}

/* copies scalar values from st's stack to L */
static int transfer(lua_State* L, lua_State* SL)
{
    int i, n = lua_gettop(SL);
    luaL_checkstack(L, n, "too many results");
    for (i = 1; i <= n; ++i) {
        switch (lua_type(SL, i)) {
            case LUA_TBOOLEAN: lua_pushboolean(L, lua_toboolean(SL, i)); break;
            case LUA_TNUMBER:  lua_pushnumber(L, lua_tonumber(SL, i));   break;
            case LUA_TSTRING: {
                size_t len;
                const char* s = lua_tolstring(SL, i, &len);
                lua_pushlstring(L, s, len);
                break;
            }
            case LUA_TNIL:     lua_pushnil(L); break;
            default:           lua_pushstring(L, luaL_typename(SL, i)); break;
        }
    }
    lua_settop(SL, 0);
    return n;
}

static int State_run(lua_State* L)
{
    State*      st = checkState(L, 1);
    size_t      len;
    const char* code = luaL_checklstring(L, 2, &len);
    if (runChunk(st->L, code, len) != 0) {
        lua_pushstring(L, lua_tostring(st->L, -1));
        lua_settop(st->L, 0);
        return lua_error(L);
    }
    return transfer(L, st->L);
}

static int State_close(lua_State* L)
{
    State* st = (State*)luaL_checkudata(L, 1, MS_CLASS_NAME);
    if (st->L) {
        lua_close(st->L);
        st->L = NULL;
    }
    return 0;
}

/* -------------------------------------------------------------------------------------------- */

typedef struct Job
{
    lua_State*  L;
    const char* code;
    size_t      len;
    int         status;
} Job;

#ifdef _WIN32
static DWORD WINAPI jobMain(LPVOID arg)
#else
static void* jobMain(void* arg)
#endif
{
    Job* job = (Job*)arg;
    job->status = runChunk(job->L, job->code, job->len);
    return 0;
}

static int Ms_parallel(lua_State* L)
{
    Job jobs[2];
    int i;
    for (i = 0; i < 2; ++i) {
        jobs[i].L      = checkState(L, 1 + 2 * i)->L;
        jobs[i].code   = luaL_checklstring(L, 2 + 2 * i, &jobs[i].len);
        jobs[i].status = -1;
    }
    if (jobs[0].L == jobs[1].L) {
        return luaL_error(L, "two different states expected");
    }
    {
#ifdef _WIN32
        HANDLE t[2];
        for (i = 0; i < 2; ++i) {
            t[i] = CreateThread(NULL, 0, jobMain, &jobs[i], 0, NULL);
            if (!t[i]) return luaL_error(L, "cannot create thread");
        }
        WaitForMultipleObjects(2, t, TRUE, INFINITE);
        CloseHandle(t[0]);
        CloseHandle(t[1]);
#else
        pthread_t t[2];
        for (i = 0; i < 2; ++i) {
            if (pthread_create(&t[i], NULL, jobMain, &jobs[i]) != 0) {
                return luaL_error(L, "cannot create thread");
            }
        }
        pthread_join(t[0], NULL);
        pthread_join(t[1], NULL);
#endif
    }
    for (i = 0; i < 2; ++i) {
        if (jobs[i].status != 0) {
            lua_pushfstring(L, "state %d: %s", i + 1, lua_tostring(jobs[i].L, -1));
            lua_settop(jobs[i].L, 0);
            return lua_error(L);
        }
    }
    for (i = 0; i < 2; ++i) {
        lua_settop(jobs[i].L, 1);
        transfer(L, jobs[i].L);
    }
    return 2;
}

/* -------------------------------------------------------------------------------------------- */

MS_EXPORT int luaopen_lpcre_multistate(lua_State* L)
{
    if (luaL_newmetatable(L, MS_CLASS_NAME)) {
        lua_pushcfunction(L, State_close);
        lua_setfield(L, -2, "__gc");
        lua_newtable(L);
        lua_pushcfunction(L, State_run);
        lua_setfield(L, -2, "run");
        lua_pushcfunction(L, State_close);
        lua_setfield(L, -2, "close");
        lua_setfield(L, -2, "__index");
    }
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushcfunction(L, Ms_new);
    lua_setfield(L, -2, "new");
    lua_pushcfunction(L, Ms_parallel);
    lua_setfield(L, -2, "parallel");
    return 1;
}
