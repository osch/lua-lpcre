#define PCRE2_CODE_UNIT_WIDTH 8
#include <pcre2.h>

#define CARRAY_CAPI_IMPLEMENT_GET_CAPI 1

#include "util.h"
#include "lpcre.h"
#include "carray_capi.h"

/* ============================================================================================ */

const char* const LPCRE_CLASS_NAME = "lpcre.regex";

/* ============================================================================================ */

/*
 * Compile flags are carried as one unsigned 64 bit value: the lower 32 bits
 * are PCRE2 compile options, the bits above are lpcre's own flags, which
 * PCRE2 must never see: before every call into PCRE2 the options are
 * masked with LPCRE_PCRE2_MASK (a 32 bit mask), see pcre2Options().
 *
 * lpcre's flags are 2^32, 2^33 and 2^34. All flag values and their sums stay
 * far below 2^53 and are therefore exact as Lua numbers also in Lua 5.1 and
 * LuaJIT (doubles), where flags are combined with "+".
 */
typedef unsigned long long lpcre_flags;

#define LPCRE_PCRE2_MASK     ((lpcre_flags)0xFFFFFFFFu)
#define LPCRE_UNSET_FALSE    (((lpcre_flags)1) << 32)
#define LPCRE_JIT            (((lpcre_flags)1) << 33)
#define LPCRE_NOCACHE        (((lpcre_flags)1) << 34)
#define LPCRE_EXT_MASK       (LPCRE_UNSET_FALSE | LPCRE_JIT | LPCRE_NOCACHE)

/* the PCRE2 compile options of lpcre compile flags, lpcre's own bits removed */
static uint32_t pcre2Options(lpcre_flags flags)
{
    return (uint32_t)(flags & LPCRE_PCRE2_MASK);
}

/* number of capture groups for which the ovector copy lives on the C stack */
#define LPCRE_LOCAL_GROUPS   15

#define LPCRE_DEFAULT_CACHE  256

/* ============================================================================================ */

typedef struct LpcreRegex LpcreRegex;

struct LpcreRegex
{
    pcre2_code*       code;
    pcre2_match_data* md;          /* reused for every match with this regex */
    lpcre_flags       flags;
    uint32_t          ncapt;       /* number of capture groups */
    int               isUtf;
    int               isJit;
    int               unsetFalse;

    /* LRU list of the pattern cache (both NULL if not cached or at an end) */
    LpcreRegex*       prev;
    LpcreRegex*       next;
};

typedef struct LpcreCache
{
    LpcreRegex* head;   /* most recently used */
    LpcreRegex* tail;   /* least recently used */
    size_t      count;
    size_t      max;
} LpcreCache;

/*
 * Remembers the Carray C API of the last carray subject. Its
 * toReadableCarray() accepts any Lua value and returns NULL for everything
 * that is not one of its carrays, so it is tried first and the C API need
 * not be looked up in the metatable for each call.
 */
typedef struct SubjectCache
{
    const carray_capi* capi;
} SubjectCache;

/* upvalue indices of the module functions and regex methods */
#define SUBJ_CACHE   lua_upvalueindex(1)   /* SubjectCache userdata (all)     */
#define CACHE_STATE  lua_upvalueindex(2)   /* LpcreCache userdata             */
#define CACHE_PLAIN  lua_upvalueindex(3)   /* pattern -> regex (flags 0)      */
#define CACHE_MAP    lua_upvalueindex(4)   /* flags -> { pattern -> regex }   */
#define CACHE_REV    lua_upvalueindex(5)   /* lightuserdata -> pattern string */

/* ============================================================================================ */

/*
 * A subject is either a Lua string or a carray with 1 byte elements. For a
 * carray the match runs directly on its buffer: pointer and length are
 * obtained through the Carray C API, nothing is copied.
 */
typedef struct Subject
{
    const char*        ptr;
    size_t             len;
    int                idx;    /* absolute stack index of the subject */
    const carray_capi* capi;   /* NULL for strings */
    const carray*      ca;
} Subject;

static void setSubjectBuffer(lua_State* L, Subject* s, const carray_info* info)
{
    s->len = info->elementCount;
    s->ptr = (s->len > 0) ? (const char*)s->capi->getReadableElementPtr(s->ca, 0, s->len) : "";
    if (!s->ptr) {
        luaL_error(L, "cannot access carray subject");
    }
}

/* re-reads pointer and length of a carray subject (after Lua code was run) */
static void refreshSubject(lua_State* L, Subject* s)
{
    if (s->capi) {
        carray_info info;
        s->ca = s->capi->toReadableCarray(L, s->idx, &info);
        if (!s->ca) {
            luaL_error(L, "carray subject became invalid");
        }
        setSubjectBuffer(L, s, &info);
    }
}

/* must be called from a function with the SUBJ_CACHE upvalue */
static void checkSubject(lua_State* L, int idx, Subject* s)
{
    int t = lua_type(L, idx);
    s->idx  = idx;
    s->capi = NULL;
    s->ca   = NULL;
    if (t == LUA_TSTRING || t == LUA_TNUMBER) {
        s->ptr = lua_tolstring(L, idx, &s->len);
        return;
    }
    if (t == LUA_TUSERDATA) {
        SubjectCache*      sc   = (SubjectCache*)lua_touserdata(L, SUBJ_CACHE);
        const carray_capi* capi = sc->capi;
        carray_info        info;
        s->ca = capi ? capi->toReadableCarray(L, idx, &info) : NULL;
        if (!s->ca) {
            capi = carray_get_capi(L, idx, NULL);
            if (capi) {
                s->ca = capi->toReadableCarray(L, idx, &info);
                if (s->ca) {
                    sc->capi = capi;
                }
            }
        }
        if (s->ca) {
            if (info.elementSize != 1) {
                luaL_argerror(L, idx, "carray elements must be 1 byte in size");
            }
            s->capi = capi;
            setSubjectBuffer(L, s, &info);
            return;
        }
    }
    luaL_argerror(L, idx, lua_pushfstring(L, "string or carray expected, got %s",
                                             luaL_typename(L, idx)));
}

/* ============================================================================================ */

static lpcre_flags checkFlags(lua_State* L, int arg)
{
    int t = lua_type(L, arg);
    if (t == LUA_TNONE || t == LUA_TNIL) {
        return 0;
    }
    if (t == LUA_TSTRING) {
        size_t      len;
        const char* s = lua_tolstring(L, arg, &len);
        lpcre_flags f = 0;
        size_t      i;
        for (i = 0; i < len; ++i) {
            switch (s[i]) {
                case 'i': f |= PCRE2_CASELESS;  break;
                case 'm': f |= PCRE2_MULTILINE; break;
                case 's': f |= PCRE2_DOTALL;    break;
                case 'x': f |= PCRE2_EXTENDED;  break;
                case 'u': f |= PCRE2_UTF;       break;
                case 'U': f |= PCRE2_UNGREEDY;  break;
                case 'n': f |= LPCRE_NOCACHE;   break;
                default:
                    luaL_argerror(L, arg, lua_pushfstring(L, "invalid flag character '%c'", s[i]));
            }
        }
        return f;
    }
    if (t == LUA_TNUMBER) {
        lpcre_flags f;
#if LUA_VERSION_NUM >= 503
        if (lua_isinteger(L, arg)) {
            lua_Integer i = lua_tointeger(L, arg);
            if (i < 0) {
                luaL_argerror(L, arg, "invalid flags");
            }
            f = (lpcre_flags)i;
        } else
#endif
        {
            lua_Number n = lua_tonumber(L, arg);
            if (!(n >= 0 && n < 18446744073709551616.0) || n != (lua_Number)(lpcre_flags)n) {
                luaL_argerror(L, arg, "invalid flags");
            }
            f = (lpcre_flags)n;
        }
        if (f & ~(LPCRE_PCRE2_MASK | LPCRE_EXT_MASK)) {
            luaL_argerror(L, arg, "invalid flags");
        }
        return f;
    }
    luaL_argerror(L, arg, lua_pushfstring(L, "number or string expected, got %s",
                                             luaL_typename(L, arg)));
    return 0;
}

static uint32_t checkExecFlags(lua_State* L, int arg)
{
    lua_Integer ef = luaL_optinteger(L, arg, 0);
    if (ef < 0 || (lua_Integer)(uint32_t)ef != ef) {
        luaL_argerror(L, arg, "invalid flags");
    }
    /* partial matching: pcre2_match() would report PCRE2_ERROR_PARTIAL instead
       of a match, which lpcre has no result for */
    if (ef & (PCRE2_PARTIAL_HARD | PCRE2_PARTIAL_SOFT)) {
        luaL_argerror(L, arg, "partial matching is not supported");
    }
    return (uint32_t)ef;
}

/* ============================================================================================ */

/*
 * Converts a Lua init (1-based, negative counts from the end, like
 * string.find) into a 0-based offset. Returns 0 if init lies beyond the
 * end of the subject + 1, in which case nothing can match.
 */
static int checkInit(lua_State* L, int arg, size_t len, size_t* offset)
{
    lua_Integer init = luaL_optinteger(L, arg, 1);
    if (init > 0) {
        if ((size_t)(init - 1) > len) {
            return 0;
        }
        *offset = (size_t)(init - 1);
    }
    else if (init == 0) {
        *offset = 0;
    }
    else if (init < -(lua_Integer)len) {
        *offset = 0;
    }
    else {
        *offset = len - (size_t)(-init);
    }
    return 1;
}

/* ============================================================================================ */

static void pushPcreMessage(lua_State* L, int errcode)
{
    PCRE2_UCHAR buf[256];
    if (pcre2_get_error_message(errcode, buf, sizeof(buf)) < 0) {
        lua_pushfstring(L, "PCRE2 error %d", errcode);
    } else {
        lua_pushstring(L, (const char*)buf);
    }
}

static int raiseMatchError(lua_State* L, int rc)
{
    pushPcreMessage(L, rc);
    return luaL_error(L, "match failed: %s", lua_tostring(L, -1));
}

/* ============================================================================================ */

static LpcreRegex* toRegex(lua_State* L, int idx)
{
    LpcreRegex* re = (LpcreRegex*)luaL_testudata(L, idx, LPCRE_CLASS_NAME);
    if (re && !re->code) {
        luaL_argerror(L, idx, "invalid regex object");
    }
    return re;
}

static LpcreRegex* checkRegex(lua_State* L, int idx)
{
    LpcreRegex* re = (LpcreRegex*)luaL_checkudata(L, idx, LPCRE_CLASS_NAME);
    if (!re->code) {
        luaL_argerror(L, idx, "invalid regex object");
    }
    return re;
}

/*
 * Compiles a pattern and pushes the new regex object. Compile errors are
 * reported as argument error for argument patArg.
 */
static LpcreRegex* compileRegex(lua_State* L, const char* pat, size_t patLen, lpcre_flags flags, int patArg)
{
    int         errcode;
    PCRE2_SIZE  erroff;
    uint32_t    options;
    LpcreRegex* re = (LpcreRegex*)lua_newuserdata(L, sizeof(LpcreRegex));    /* -> re */
    memset(re, 0, sizeof(LpcreRegex));
    luaL_getmetatable(L, LPCRE_CLASS_NAME);                                  /* -> re, meta */
    lua_setmetatable(L, -2);                                                 /* -> re */

    /* only PCRE2 bits: lpcre's own flags (above 2^32) are no PCRE2 options */
    re->code = pcre2_compile((PCRE2_SPTR)pat, patLen, pcre2Options(flags),
                             &errcode, &erroff, NULL);
    if (!re->code) {
        pushPcreMessage(L, errcode);
        /* erroff: offset in the pattern where PCRE2 detected the error */
        luaL_argerror(L, patArg, lua_pushfstring(L, "%s at offset %d", lua_tostring(L, -1),
                                                    (int)erroff));
    }
    re->flags      = flags;
    re->unsetFalse = (flags & LPCRE_UNSET_FALSE) != 0;
    if (flags & LPCRE_JIT) {
        /* JIT is optional: if it is not available the interpreter is used */
        re->isJit = (pcre2_jit_compile(re->code, PCRE2_JIT_COMPLETE) == 0);
    }
    pcre2_pattern_info(re->code, PCRE2_INFO_CAPTURECOUNT, &re->ncapt);
    pcre2_pattern_info(re->code, PCRE2_INFO_ALLOPTIONS, &options);
    re->isUtf = (options & PCRE2_UTF) != 0;

    re->md = pcre2_match_data_create_from_pattern(re->code, NULL);
    if (!re->md) {
        luaL_error(L, "not enough memory");
    }
    return re;
}

/* ============================================================================================ */
/* pattern cache (LRU)                                                                          */
/* ============================================================================================ */

static void cacheUnlink(LpcreCache* c, LpcreRegex* re)
{
    if (re->prev) re->prev->next = re->next; else c->head = re->next;
    if (re->next) re->next->prev = re->prev; else c->tail = re->prev;
    re->prev = re->next = NULL;
}

static void cachePushFront(LpcreCache* c, LpcreRegex* re)
{
    re->prev = NULL;
    re->next = c->head;
    if (c->head) c->head->prev = re; else c->tail = re;
    c->head = re;
}

/*
 * Pushes the flags of a cached regex as key of CACHE_MAP. The flags are
 * lpcre's own bits above 2^32 plus PCRE2 options, at most 2^35 (well within
 * the exact range of a lua_Number as well).
 */
static void pushFlagsKey(lua_State* L, lpcre_flags flags)
{
#if LUA_VERSION_NUM >= 503
    lua_pushinteger(L, (lua_Integer)flags);
#else
    lua_pushnumber(L, (lua_Number)flags);
#endif
}

/*
 * Removes the cache entry of re from its map: CACHE_PLAIN for flags 0,
 * otherwise the sub table of its flags in CACHE_MAP, which is dropped
 * when it becomes empty. The pattern string is taken from CACHE_REV.
 */
static void cacheRemoveEntry(lua_State* L, LpcreRegex* re)
{
    lua_pushlightuserdata(L, re);               /* -> p */
    lua_rawget(L, CACHE_REV);                   /* -> pat */
    if (lua_isnil(L, -1)) {                     /* not reachable: list and maps are kept in sync */
        lua_pop(L, 1);                          /* -> */
    } else if (re->flags == 0) {
        lua_pushnil(L);                         /* -> pat, nil */
        lua_rawset(L, CACHE_PLAIN);             /* -> */
    } else {
        pushFlagsKey(L, re->flags);             /* -> pat, fk */
        lua_rawget(L, CACHE_MAP);               /* -> pat, sub? */
        if (lua_istable(L, -1)) {
            lua_insert(L, -2);                  /* -> sub, pat */
            lua_pushnil(L);                     /* -> sub, pat, nil */
            lua_rawset(L, -3);                  /* -> sub */
            lua_pushnil(L);                     /* -> sub, nil */
            if (lua_next(L, -2)) {              /* -> sub, k, v */
                lua_pop(L, 3);                  /* -> */
            } else {                            /* -> sub */
                lua_pop(L, 1);                  /* -> */
                pushFlagsKey(L, re->flags);     /* -> fk */
                lua_pushnil(L);                 /* -> fk, nil */
                lua_rawset(L, CACHE_MAP);       /* -> */
            }
        } else {                                /* not reachable */
            lua_pop(L, 2);                      /* -> */
        }
    }
    lua_pushlightuserdata(L, re);               /* -> p */
    lua_pushnil(L);                             /* -> p, nil */
    lua_rawset(L, CACHE_REV);                   /* -> */
}

/* evicts least recently used entries until at most c->max are left */
static void cacheTrim(lua_State* L, LpcreCache* c)
{
    while (c->count > c->max && c->tail) {
        LpcreRegex* re = c->tail;
        cacheUnlink(c, re);
        c->count--;
        cacheRemoveEntry(L, re);
    }
}

/*
 * Pushes the compiled regex for pattern + flags, taken from the cache or
 * compiled and put into the cache. With the flag NOCACHE or cache size 0
 * the pattern is compiled without using the cache. Must be called from a
 * module function (the cache lives in its upvalues); patArg is the pattern
 * string on the stack.
 *
 * The lookup allocates nothing: the pattern string itself is the key, in
 * CACHE_PLAIN for flags 0 (the common case, a single table lookup) and in
 * the sub table of the flags in CACHE_MAP otherwise. All entries of both
 * maps share one LRU list.
 */
static LpcreRegex* cachedRegex(lua_State* L, const char* pat, size_t patLen, lpcre_flags flags, int patArg)
{
    LpcreCache* c = (LpcreCache*)lua_touserdata(L, CACHE_STATE);
    LpcreRegex* re;
    int         map;
    if (c->max == 0 || (flags & LPCRE_NOCACHE)) {
        return compileRegex(L, pat, patLen, flags, patArg);                 /* -> re */
    }
    patArg = lua_absindex(L, patArg);
    if (flags == 0) {
        lua_pushvalue(L, patArg);                                            /* -> pat */
        lua_rawget(L, CACHE_PLAIN);                                          /* -> re? */
        map = 0;
    } else {
        pushFlagsKey(L, flags);                                              /* -> fk */
        lua_rawget(L, CACHE_MAP);                                            /* -> sub? */
        map = lua_gettop(L);
        if (lua_istable(L, map)) {
            lua_pushvalue(L, patArg);                                        /* -> sub, pat */
            lua_rawget(L, map);                                              /* -> sub, re? */
        } else {
            lua_pushnil(L);                                                  /* -> nil, nil */
        }
    }
    re = (LpcreRegex*)lua_touserdata(L, -1);
    if (re) {
        if (c->head != re) {
            cacheUnlink(c, re);
            cachePushFront(c, re);
        }
        if (map) {
            lua_remove(L, map);                                              /* -> re */
        }
        return re;
    }
    lua_pop(L, 1);                                                           /* -> [sub] */
    re = compileRegex(L, pat, patLen, flags, patArg);                        /* -> [sub], re */
    if (map && !lua_istable(L, map)) {
        /* the sub table is created only after a successful compilation, so
           an empty one is never left behind */
        lua_newtable(L);                                                     /* -> nil, re, sub */
        lua_replace(L, map);                                                 /* -> sub, re */
        pushFlagsKey(L, flags);                                              /* -> sub, re, fk */
        lua_pushvalue(L, map);                                               /* -> sub, re, fk, sub */
        lua_rawset(L, CACHE_MAP);                                            /* -> sub, re */
    }
    /* reverse entry first: if inserting into the map fails (out of memory),
       no map entry is left without a list entry */
    lua_pushlightuserdata(L, re);                                            /* -> [sub], re, p */
    lua_pushvalue(L, patArg);                                                /* -> [sub], re, p, pat */
    lua_rawset(L, CACHE_REV);                                                /* -> [sub], re */
    lua_pushvalue(L, patArg);                                                /* -> [sub], re, pat */
    lua_pushvalue(L, -2);                                                    /* -> [sub], re, pat, re */
    if (map) {
        lua_rawset(L, map);                                                  /* -> sub, re */
        lua_remove(L, map);                                                  /* -> re */
    } else {
        lua_rawset(L, CACHE_PLAIN);                                          /* -> re */
    }
    cachePushFront(c, re);
    c->count++;
    cacheTrim(L, c);
    return re;
}

/*
 * The pattern argument of a module function is a string (compiled via the
 * cache with the flags at cfArg) or a regex object (cfArg must be nil). The
 * regex object replaces the pattern string on the stack, so it stays
 * alive during the call.
 */
static LpcreRegex* checkPatternArg(lua_State* L, int patArg, int cfArg)
{
    LpcreRegex* re = toRegex(L, patArg);
    if (re) {
        /* a regex object carries its compile flags, other ones would be ignored */
        if (!lua_isnoneornil(L, cfArg)) {
            luaL_argerror(L, cfArg, "cf not allowed with a regex object");
        }
        return re;
    }
    if (lua_type(L, patArg) == LUA_TSTRING) {
        size_t      len;
        const char* pat   = lua_tolstring(L, patArg, &len);
        lpcre_flags flags = checkFlags(L, cfArg);
        if (flags & LPCRE_NOCACHE) {
            /* a pattern string here is always cached; for an uncached pattern
               the caller compiles it with lpcre.new(pattern, "n") */
            luaL_argerror(L, cfArg, "flag NOCACHE is only valid for lpcre.new()");
        }
        re = cachedRegex(L, pat, len, flags, patArg);                        /* -> re */
        lua_replace(L, patArg);
        return re;
    }
    luaL_argerror(L, patArg, lua_pushfstring(L, "string or lpcre.regex expected, got %s",
                                                luaL_typename(L, patArg)));
    return NULL;
}

/* ============================================================================================ */
/* matching                                                                                     */
/* ============================================================================================ */

/*
 * Copy of the ovector of the last match. Offsets are copied out of the
 * match data before any Lua API call, because Lua code (callbacks,
 * finalizers) may reuse the same regex object and its match data.
 */
typedef struct Ovec
{
    PCRE2_SIZE* v;
    PCRE2_SIZE  local[2 * (LPCRE_LOCAL_GROUPS + 1)];
} Ovec;

/* may push a userdata for many groups: call before luaL_buffinit() */
static void initOvec(lua_State* L, LpcreRegex* re, Ovec* ov)
{
    if (re->ncapt <= LPCRE_LOCAL_GROUPS) {
        ov->v = ov->local;
    } else {
        ov->v = (PCRE2_SIZE*)lua_newuserdata(L, 2 * (re->ncapt + 1) * sizeof(PCRE2_SIZE));
    }
}

/*
 * Runs one match at offset start. Returns 1 on match (offsets in ov),
 * 0 on no match, raises an error otherwise.
 */
/*
 * Runs one match at offset start without copying the ovector: the offsets
 * stay in re->md, valid only until the next Lua API call that can run Lua
 * code. Returns 1 on match, 0 on no match, raises an error otherwise.
 */
static int execRaw(lua_State* L, LpcreRegex* re, const Subject* s, size_t start, uint32_t ef)
{
    /* ef holds only PCRE2 match options: checkExecFlags() rejects values beyond
       32 bits, so no lpcre flag can get here; masked again to make that explicit */
    int rc = pcre2_match(re->code, (PCRE2_SPTR)s->ptr, s->len, start,
                         (uint32_t)(ef & 0xFFFFFFFFu), re->md, NULL);
    if (rc == PCRE2_ERROR_NOMATCH) {
        return 0;
    }
    if (rc < 0) {
        raiseMatchError(L, rc);
    }
    return 1;
}

static int execAt(lua_State* L, LpcreRegex* re, const Subject* s, size_t start, uint32_t ef, Ovec* ov)
{
    if (!execRaw(L, re, s, start, ef)) {
        return 0;
    }
    memcpy(ov->v, pcre2_get_ovector_pointer(re->md), 2 * (re->ncapt + 1) * sizeof(PCRE2_SIZE));
    return 1;
}

/* the offset of the next character after pos (a whole UTF-8 sequence in UTF mode) */
static size_t nextCharPos(const LpcreRegex* re, const Subject* s, size_t pos)
{
    ++pos;
    if (re->isUtf) {
        while (pos < s->len && (((unsigned char)s->ptr[pos]) & 0xC0) == 0x80) {
            ++pos;
        }
    }
    return pos;
}

/*
 * State of an iteration over all matches (gmatch, gsub, count, split).
 * Same rule as Lua 5.4's string.gmatch/gsub: an empty match directly at
 * the end of the previous match is skipped.
 */
typedef struct IterState
{
    size_t   pos;        /* next search offset                         */
    size_t   lastEnd;    /* end offset of the previous match           */
    int      hasLast;    /* lastEnd is valid                           */
    int      utfChecked; /* subject was already UTF checked by PCRE2   */
    uint32_t ef;         /* execution flags                            */
} IterState;

static int findNext(lua_State* L, LpcreRegex* re, const Subject* s, IterState* it, Ovec* ov)
{
    for (;;) {
        uint32_t ef = it->ef;
        if (it->pos > s->len) {
            return 0;
        }
        if (it->utfChecked) {
            ef |= PCRE2_NO_UTF_CHECK;
        }
        if (!execAt(L, re, s, it->pos, ef, ov)) {
            return 0;
        }
        it->utfChecked = 1;
        if (it->hasLast && ov->v[1] == it->lastEnd && ov->v[0] == ov->v[1]) {
            if (it->pos >= s->len) {
                return 0;
            }
            it->pos = nextCharPos(re, s, it->pos);
            continue;
        }
        it->pos     = ov->v[1];
        it->lastEnd = ov->v[1];
        it->hasLast = 1;
        return 1;
    }
}

/* ============================================================================================ */

static void pushUnset(lua_State* L, const LpcreRegex* re)
{
    if (re->unsetFalse) {
        lua_pushboolean(L, 0);
    } else {
        lua_pushnil(L);
    }
}

static void pushGroup(lua_State* L, const LpcreRegex* re, const Subject* s, const Ovec* ov, uint32_t i)
{
    PCRE2_SIZE b = ov->v[2 * i];
    PCRE2_SIZE e = ov->v[2 * i + 1];
    if (b == PCRE2_UNSET) {
        pushUnset(L, re);
    } else {
        lua_pushlstring(L, s->ptr + b, (e > b) ? (e - b) : 0);
    }
}

/* pushes the captures, or the whole match if there are none; returns the count */
static int pushCaptures(lua_State* L, const LpcreRegex* re, const Subject* s, const Ovec* ov, int wholeIfNone)
{
    uint32_t i;
    if (re->ncapt == 0) {
        if (wholeIfNone) {
            pushGroup(L, re, s, ov, 0);
            return 1;
        }
        return 0;
    }
    luaL_checkstack(L, (int)re->ncapt + LUA_MINSTACK, "too many captures");
    for (i = 1; i <= re->ncapt; ++i) {
        pushGroup(L, re, s, ov, i);
    }
    return (int)re->ncapt;
}

/*
 * pushes a table with all captures by number and by name. Groups that did not
 * take part in the match are always false here (as in lrexlib), independent of
 * UNSET_FALSE: a nil would leave a hole, making #t and ipairs unreliable.
 */
static void pushCaptureTable(lua_State* L, const LpcreRegex* re, const Subject* s, const Ovec* ov)
{
    uint32_t i, namecount = 0, entrysize = 0;
    PCRE2_SPTR nametable = NULL;
    lua_createtable(L, (int)re->ncapt, 0);                                   /* -> t */
    for (i = 1; i <= re->ncapt; ++i) {
        if (ov->v[2 * i] != PCRE2_UNSET) {
            pushGroup(L, re, s, ov, i);                                      /* -> t, v */
        } else {
            lua_pushboolean(L, 0);                                           /* -> t, false */
        }
        lua_rawseti(L, -2, (int)i);                                          /* -> t */
    }
    pcre2_pattern_info(re->code, PCRE2_INFO_NAMECOUNT, &namecount);
    if (namecount > 0) {
        pcre2_pattern_info(re->code, PCRE2_INFO_NAMEENTRYSIZE, &entrysize);
        pcre2_pattern_info(re->code, PCRE2_INFO_NAMETABLE, &nametable);
        for (i = 0; i < namecount; ++i) {
            PCRE2_SPTR entry = nametable + i * entrysize;
            uint32_t   n     = ((uint32_t)entry[0] << 8) | entry[1];
            const char* name = (const char*)(entry + 2);
            if (ov->v[2 * n] != PCRE2_UNSET) {
                pushGroup(L, re, s, ov, n);                                  /* -> t, v */
                lua_setfield(L, -2, name);                                   /* -> t */
            }
            else {
                lua_getfield(L, -1, name);                                   /* -> t, old */
                if (lua_isnil(L, -1)) {     /* duplicate names: keep a set one */
                    lua_pushboolean(L, 0);                                   /* -> t, nil, false */
                    lua_setfield(L, -3, name);                               /* -> t, nil */
                }
                lua_pop(L, 1);                                               /* -> t */
            }
        }
    }
}

/* ============================================================================================ */

/* common part of find/match/exec; returns 0 (nil pushed) if no match */
static int matchOnce(lua_State* L, LpcreRegex* re, int subjArg, int initArg, int efArg,
                     Subject* s, Ovec* ov)
{
    size_t   start;
    uint32_t ef;
    checkSubject(L, subjArg, s);
    ef = checkExecFlags(L, efArg);
    initOvec(L, re, ov);
    if (!checkInit(L, initArg, s->len, &start) || !execAt(L, re, s, start, ef, ov)) {
        lua_pushnil(L);
        return 0;
    }
    return 1;
}

static int doFind(lua_State* L, LpcreRegex* re, int subjArg, int initArg, int efArg)
{
    Subject s;
    Ovec    ov;
    if (!matchOnce(L, re, subjArg, initArg, efArg, &s, &ov)) {
        return 1;
    }
    lua_pushinteger(L, (lua_Integer)ov.v[0] + 1);
    lua_pushinteger(L, (lua_Integer)ov.v[1]);
    return 2 + pushCaptures(L, re, &s, &ov, 0);
}

static int doMatch(lua_State* L, LpcreRegex* re, int subjArg, int initArg, int efArg)
{
    Subject s;
    Ovec    ov;
    if (!matchOnce(L, re, subjArg, initArg, efArg, &s, &ov)) {
        return 1;
    }
    return pushCaptures(L, re, &s, &ov, 1);
}

static int doExec(lua_State* L, LpcreRegex* re, int subjArg, int initArg, int efArg)
{
    Subject s;
    Ovec    ov;
    if (!matchOnce(L, re, subjArg, initArg, efArg, &s, &ov)) {
        return 1;
    }
    lua_pushinteger(L, (lua_Integer)ov.v[0] + 1);
    lua_pushinteger(L, (lua_Integer)ov.v[1]);
    pushCaptureTable(L, re, &s, &ov);
    return 3;
}

/*
 * test: only whether there is a match. No ovector copy, no Ovec userdata
 * for many groups, nothing pushed but the boolean.
 */
static int doTest(lua_State* L, LpcreRegex* re, int subjArg, int initArg, int efArg)
{
    Subject  s;
    size_t   start;
    uint32_t ef;
    checkSubject(L, subjArg, &s);
    ef = checkExecFlags(L, efArg);
    lua_pushboolean(L, checkInit(L, initArg, s.len, &start) && execRaw(L, re, &s, start, ef));
    return 1;
}

/*
 * matchpos: the captures followed by the end position of the match, or true
 * followed by the end position if the pattern has no capture groups.
 */
static int doMatchPos(lua_State* L, LpcreRegex* re, int subjArg, int initArg, int efArg)
{
    Subject s;
    Ovec    ov;
    int     n;
    if (!matchOnce(L, re, subjArg, initArg, efArg, &s, &ov)) {
        return 1;
    }
    if (re->ncapt == 0) {
        lua_pushboolean(L, 1);
        n = 1;
    } else {
        /* leaves at least LUA_MINSTACK free slots for the end position */
        n = pushCaptures(L, re, &s, &ov, 0);
    }
    lua_pushinteger(L, (lua_Integer)ov.v[1]);
    return n + 1;
}

/* findmatch: start and end position, the whole match, then the captures */
static int doFindMatch(lua_State* L, LpcreRegex* re, int subjArg, int initArg, int efArg)
{
    Subject s;
    Ovec    ov;
    if (!matchOnce(L, re, subjArg, initArg, efArg, &s, &ov)) {
        return 1;
    }
    lua_pushinteger(L, (lua_Integer)ov.v[0] + 1);
    lua_pushinteger(L, (lua_Integer)ov.v[1]);
    pushGroup(L, re, &s, &ov, 0);
    return 3 + pushCaptures(L, re, &s, &ov, 0);
}

/* ============================================================================================ */

static int doCount(lua_State* L, LpcreRegex* re, int subjArg, int initArg, int efArg)
{
    Subject     s;
    Ovec        ov;
    IterState   it;
    lua_Integer n = 0;
    checkSubject(L, subjArg, &s);
    memset(&it, 0, sizeof(it));
    it.ef = checkExecFlags(L, efArg);
    initOvec(L, re, &ov);
    if (checkInit(L, initArg, s.len, &it.pos)) {
        while (findNext(L, re, &s, &it, &ov)) {
            ++n;
        }
    }
    lua_pushinteger(L, n);
    return 1;
}

/* ============================================================================================ */

/* iterator state for gmatch and split, kept as upvalue 3 */
typedef struct GmatchState
{
    const carray_capi* capi;   /* for a carray subject, NULL for strings */
    IterState it;
    size_t    pieceStart;   /* split: start of the next piece */
    int       done;
} GmatchState;

/* the subject of an iterator: upvalue 2, pushed to stack index 1 */
static void getIterSubject(lua_State* L, GmatchState* gs, Subject* s)
{
    lua_settop(L, 0);
    lua_pushvalue(L, lua_upvalueindex(2));                                   /* -> subject */
    s->idx  = 1;
    s->capi = gs->capi;
    s->ca   = NULL;
    if (s->capi) {
        refreshSubject(L, s);
        gs->it.utfChecked = 0;    /* a carray may have changed since the last call */
    } else {
        s->ptr = lua_tolstring(L, 1, &s->len);
    }
}

/* upvalues: 1 regex, 2 subject, 3 GmatchState */
static int gmatchIter(lua_State* L)
{
    LpcreRegex*  re = (LpcreRegex*)lua_touserdata(L, lua_upvalueindex(1));
    GmatchState* gs = (GmatchState*)lua_touserdata(L, lua_upvalueindex(3));
    Subject      s;
    Ovec         ov;
    if (gs->done) {
        return 0;
    }
    getIterSubject(L, gs, &s);
    initOvec(L, re, &ov);
    if (!findNext(L, re, &s, &gs->it, &ov)) {
        gs->done = 1;
        return 0;
    }
    return pushCaptures(L, re, &s, &ov, 1);
}

/* upvalues: 1 regex, 2 subject, 3 GmatchState */
static int splitIter(lua_State* L)
{
    LpcreRegex*  re = (LpcreRegex*)lua_touserdata(L, lua_upvalueindex(1));
    GmatchState* gs = (GmatchState*)lua_touserdata(L, lua_upvalueindex(3));
    Subject      s;
    Ovec         ov;
    if (gs->done) {
        return 0;
    }
    getIterSubject(L, gs, &s);
    initOvec(L, re, &ov);
    if (gs->pieceStart > s.len) {
        gs->pieceStart = s.len;
    }
    if (!findNext(L, re, &s, &gs->it, &ov)) {
        gs->done = 1;
        lua_pushlstring(L, s.ptr + gs->pieceStart, s.len - gs->pieceStart);
        return 1;
    }
    lua_pushlstring(L, s.ptr + gs->pieceStart, ov.v[0] - gs->pieceStart);
    gs->pieceStart = ov.v[1];
    return 1 + pushCaptures(L, re, &s, &ov, 1);
}

/* the regex object must be at regexIdx */
static int doGmatch(lua_State* L, int regexIdx, int subjArg, int initArg, int efArg, lua_CFunction iter)
{
    Subject      s;
    GmatchState* gs;
    checkSubject(L, subjArg, &s);
    gs = (GmatchState*)lua_newuserdata(L, sizeof(GmatchState));              /* -> gs */
    memset(gs, 0, sizeof(GmatchState));
    gs->capi  = s.capi;
    gs->it.ef = checkExecFlags(L, efArg);
    if (!checkInit(L, initArg, s.len, &gs->it.pos)) {
        gs->it.pos = s.len + 1;
        gs->done   = (iter == gmatchIter);
    }
    gs->pieceStart = gs->it.pos;
    lua_pushvalue(L, regexIdx);                                              /* -> gs, re */
    lua_pushvalue(L, subjArg);                                               /* -> gs, re, subj */
    lua_pushvalue(L, -3);                                                    /* -> gs, re, subj, gs */
    lua_pushcclosure(L, iter, 3);                                            /* -> gs, iter */
    return 1;
}

/* ============================================================================================ */
/* gsub                                                                                         */
/* ============================================================================================ */

/* content of a luaL_Buffer (the compat-5.3 buffer for Lua 5.1/LuaJIT) */
#if LUA_VERSION_NUM == 501
#  define BUFF_ADDR(B)  ((B)->ptr)
#  define BUFF_LEN(B)   ((B)->nelems)
#else
#  define BUFF_ADDR(B)  ((B)->b)
#  define BUFF_LEN(B)   ((B)->n)
#endif

static void addGroup(luaL_Buffer* b, const Subject* s, const Ovec* ov, uint32_t i)
{
    PCRE2_SIZE bg = ov->v[2 * i];
    PCRE2_SIZE e  = ov->v[2 * i + 1];
    if (bg != PCRE2_UNSET && e > bg) {
        luaL_addlstring(b, s->ptr + bg, e - bg);
    }
}

/* replacement string with %0..%9 and %% like string.gsub */
static void addReplString(lua_State* L, luaL_Buffer* b, const LpcreRegex* re, const Subject* s,
                          const Ovec* ov, const char* r, size_t rlen)
{
    size_t i = 0;
    while (i < rlen) {
        const char* p = (const char*)memchr(r + i, '%', rlen - i);
        if (!p) {
            luaL_addlstring(b, r + i, rlen - i);
            return;
        }
        luaL_addlstring(b, r + i, (size_t)(p - (r + i)));
        i = (size_t)(p - r) + 1;
        if (i >= rlen) {
            luaL_error(L, "invalid use of '%%' in replacement string");
        }
        if (r[i] == '%') {
            luaL_addchar(b, '%');
        }
        else if (r[i] >= '0' && r[i] <= '9') {
            uint32_t n = (uint32_t)(r[i] - '0');
            if (n == 0 || (n == 1 && re->ncapt == 0)) {
                addGroup(b, s, ov, 0);
            } else if (n <= re->ncapt) {
                addGroup(b, s, ov, n);
            } else {
                luaL_error(L, "invalid capture index %%%d in replacement string", (int)n);
            }
        }
        else {
            luaL_error(L, "invalid use of '%%' in replacement string");
        }
        ++i;
    }
}

/*
 * re:gsub(subject, repl [, n [, ef]]) / lpcre.gsub(subject, pattern, repl [, n [, cf [, ef]]])
 *
 * String subject: returns the new string and the number of matches.
 * Carray subject: the result is written back into the carray, returns the
 * carray and the number of matches.
 */
static int doGsub(lua_State* L, LpcreRegex* re, int subjArg, int replArg, int nArg, int efArg)
{
    Subject      s;
    Ovec         ov;
    IterState    it;
    lua_Integer  maxN;
    lua_Integer  nmatch = 0;
    size_t       copyFrom = 0;
    int          rt;
    size_t       rlen = 0;
    const char*  rstr = NULL;
    carray*      wca  = NULL;
    luaL_Buffer  b;

    checkSubject(L, subjArg, &s);
    rt = lua_type(L, replArg);
    if (rt == LUA_TSTRING || rt == LUA_TNUMBER) {
        rstr = lua_tolstring(L, replArg, &rlen);
    }
    else if (rt != LUA_TTABLE && rt != LUA_TFUNCTION) {
        luaL_argerror(L, replArg, lua_pushfstring(L, "string/function/table expected, got %s",
                                                     luaL_typename(L, replArg)));
    }
    maxN = luaL_optinteger(L, nArg, (lua_Integer)(s.len + 1));
    memset(&it, 0, sizeof(it));
    it.ef = checkExecFlags(L, efArg);
    if (s.capi) {
        wca = s.capi->toWritableCarray(L, subjArg, NULL);
        if (!wca) {
            luaL_argerror(L, subjArg, "carray is not writable");
        }
    }
    initOvec(L, re, &ov);

    luaL_buffinit(L, &b);
    while (nmatch < maxN && findNext(L, re, &s, &it, &ov)) {
        size_t from = ov.v[0];
        size_t to   = ov.v[1];
        ++nmatch;
        luaL_addlstring(&b, s.ptr + copyFrom, from - copyFrom);
        if (rstr) {
            addReplString(L, &b, re, &s, &ov, rstr, rlen);
        }
        else {
            if (rt == LUA_TFUNCTION) {
                int nargs;
                lua_pushvalue(L, replArg);                                   /* -> f */
                nargs = pushCaptures(L, re, &s, &ov, 1);                     /* -> f, caps... */
                lua_call(L, nargs, 1);                                       /* -> v */
            } else {
                lua_pushvalue(L, replArg);                                   /* -> t */
                pushGroup(L, re, &s, &ov, re->ncapt > 0 ? 1 : 0);            /* -> t, key */
                lua_gettable(L, -2);                                         /* -> t, v */
                lua_remove(L, -2);                                           /* -> v */
            }
            if (s.capi) {
                size_t oldLen = s.len;
                refreshSubject(L, &s);
                if (s.len != oldLen) {
                    luaL_error(L, "carray subject was resized during gsub");
                }
                /* the callback may have changed the content: PCRE2 must check
                   the UTF-8 again, NO_UTF_CHECK on invalid UTF-8 is undefined */
                it.utfChecked = 0;
            }
            if (!lua_toboolean(L, -1)) {
                lua_pop(L, 1);                                               /* -> */
                luaL_addlstring(&b, s.ptr + from, to - from);
            }
            else if (lua_type(L, -1) == LUA_TSTRING || lua_type(L, -1) == LUA_TNUMBER) {
                luaL_addvalue(&b);                                           /* -> */
            }
            else {
                luaL_error(L, "invalid replacement value (a %s)", luaL_typename(L, -1));
            }
        }
        copyFrom = to;
    }
    luaL_addlstring(&b, s.ptr + copyFrom, s.len - copyFrom);

    if (wca) {
        /* the result is copied from the buffer into the carray, no Lua string is created */
        if (nmatch > 0) {
            size_t      newLen  = BUFF_LEN(&b);
            const char* newData = BUFF_ADDR(&b);
            void*       dst;
            if (newLen == s.len) {
                /* same length: written in place, this also works for a carray that
                   is writable but not resizable (one referencing foreign memory) */
                dst = (newLen > 0) ? s.capi->getWritableElementPtr(wca, 0, newLen) : NULL;
                if (newLen > 0 && !dst) {
                    luaL_error(L, "cannot access carray subject");
                }
            }
            else {
                /*
                 * reservePercent 0: exact capacity when growing, capacity kept when
                 * shrinking. A reserve would only pay off for a carray that grows
                 * again and again; each gsub copies the whole subject anyway, so a
                 * realloc costs no more than the copy, and the carray's own append
                 * functions add their reserve when they grow it later.
                 *
                 * With reservePercent >= 0 the buffer is never freed, so a successful
                 * resize returns a valid pointer, also for newLen == 0: the length
                 * changes here, so s.len > 0 and the capacity is > 0. NULL is only
                 * returned on failure: a carray that is not resizable (one referencing
                 * foreign memory) or out of memory. See resizeCarray() in
                 * lua-carray/src/carray_capi_impl.c; only newElementCount == 0 with
                 * reservePercent < 0 frees the buffer and returns NULL on success.
                 * The Carray C API cannot tell the two failures apart (carray_info
                 * has no reference flag), hence one message for both.
                 */
                dst = s.capi->resizeCarray(wca, newLen, 0);
                if (!dst) {
                    luaL_error(L, "cannot resize carray");
                }
            }
            if (newLen > 0) {
                memcpy(dst, newData, newLen);
            }
        }
        lua_pushvalue(L, subjArg);                                           /* -> carray */
    } else {
        luaL_pushresult(&b);                                                 /* -> result */
    }
    lua_pushinteger(L, nmatch);
    return 2;
}

/* ============================================================================================ */
/* module functions                                                                             */
/* ============================================================================================ */

/* lpcre.new(pattern [, cf]) -> regex object from the cache, freshly compiled with NOCACHE */
static int Lpcre_new(lua_State* L)
{
    size_t      len;
    const char* pat;
    lpcre_flags flags;
    lua_settop(L, 2);
    luaL_checktype(L, 1, LUA_TSTRING);      /* no number conversion, as in the module functions */
    pat   = lua_tolstring(L, 1, &len);
    flags = checkFlags(L, 2);
    cachedRegex(L, pat, len, flags, 1);
    return 1;
}

/* lpcre.find(subject, pattern [, init [, cf [, ef]]]) */
static int Lpcre_find(lua_State* L)
{
    lua_settop(L, 5);
    LpcreRegex* re = checkPatternArg(L, 2, 4);
    return doFind(L, re, 1, 3, 5);
}

/* lpcre.match(subject, pattern [, init [, cf [, ef]]]) */
static int Lpcre_match(lua_State* L)
{
    lua_settop(L, 5);
    LpcreRegex* re = checkPatternArg(L, 2, 4);
    return doMatch(L, re, 1, 3, 5);
}

/* lpcre.test(subject, pattern [, init [, cf [, ef]]]) */
static int Lpcre_test(lua_State* L)
{
    lua_settop(L, 5);
    LpcreRegex* re = checkPatternArg(L, 2, 4);
    return doTest(L, re, 1, 3, 5);
}

/* lpcre.matchpos(subject, pattern [, init [, cf [, ef]]]) */
static int Lpcre_matchpos(lua_State* L)
{
    lua_settop(L, 5);
    LpcreRegex* re = checkPatternArg(L, 2, 4);
    return doMatchPos(L, re, 1, 3, 5);
}

/* lpcre.findmatch(subject, pattern [, init [, cf [, ef]]]) */
static int Lpcre_findmatch(lua_State* L)
{
    lua_settop(L, 5);
    LpcreRegex* re = checkPatternArg(L, 2, 4);
    return doFindMatch(L, re, 1, 3, 5);
}

/* lpcre.gmatch(subject, pattern [, init [, cf [, ef]]]) */
static int Lpcre_gmatch(lua_State* L)
{
    lua_settop(L, 5);
    checkPatternArg(L, 2, 4);
    return doGmatch(L, 2, 1, 3, 5, gmatchIter);
}

/* lpcre.gsub(subject, pattern, repl [, n [, cf [, ef]]]) */
static int Lpcre_gsub(lua_State* L)
{
    lua_settop(L, 6);
    LpcreRegex* re = checkPatternArg(L, 2, 5);
    return doGsub(L, re, 1, 3, 4, 6);
}

/* lpcre.count(subject, pattern [, init [, cf [, ef]]]) */
static int Lpcre_count(lua_State* L)
{
    lua_settop(L, 5);
    LpcreRegex* re = checkPatternArg(L, 2, 4);
    return doCount(L, re, 1, 3, 5);
}

/* lpcre.split(subject, sep [, init [, cf [, ef]]]) */
static int Lpcre_split(lua_State* L)
{
    lua_settop(L, 5);
    checkPatternArg(L, 2, 4);
    return doGmatch(L, 2, 1, 3, 5, splitIter);
}

/* lpcre.cache([n]) -> previous size, number of cached patterns */
static int Lpcre_cache(lua_State* L)
{
    LpcreCache* c   = (LpcreCache*)lua_touserdata(L, CACHE_STATE);
    size_t      old = c->max;
    if (!lua_isnoneornil(L, 1)) {
        lua_Integer n = luaL_checkinteger(L, 1);
        luaL_argcheck(L, n >= 0, 1, "cache size must not be negative");
        c->max = (size_t)n;
        cacheTrim(L, c);
    }
    lua_pushinteger(L, (lua_Integer)old);
    lua_pushinteger(L, (lua_Integer)c->count);
    return 2;
}

/*
 * Pushes a string item of pcre2_config(), or nil if it is not available.
 * pcre2_config() copies the string without a length limit, so the needed
 * length (including the terminating zero) is queried first.
 */
static void pushPcreConfigString(lua_State* L, uint32_t what)
{
    char buf[256];
    int  len = pcre2_config(what, NULL);
    if (len > 0 && (size_t)len <= sizeof(buf)) {
        pcre2_config(what, buf);
        lua_pushlstring(L, buf, (size_t)len - 1);
    } else {
        lua_pushnil(L);
    }
}

/* lpcre.version() -> PCRE2 version string */
static int Lpcre_version(lua_State* L)
{
    pushPcreConfigString(L, PCRE2_CONFIG_VERSION);
    return 1;
}

/* lpcre.config() -> table with PCRE2 build configuration */
static int Lpcre_config(lua_State* L)
{
    uint32_t v = 0;
    lua_newtable(L);
    pushPcreConfigString(L, PCRE2_CONFIG_VERSION);
    lua_setfield(L, -2, "VERSION");
    pushPcreConfigString(L, PCRE2_CONFIG_UNICODE_VERSION);
    lua_setfield(L, -2, "UNICODE_VERSION");
    pcre2_config(PCRE2_CONFIG_UNICODE, &v);
    lua_pushboolean(L, v != 0);          lua_setfield(L, -2, "UNICODE");
    v = 0;
    pcre2_config(PCRE2_CONFIG_JIT, &v);
    lua_pushboolean(L, v != 0);          lua_setfield(L, -2, "JIT");
    if (v) {
        pushPcreConfigString(L, PCRE2_CONFIG_JITTARGET);
        lua_setfield(L, -2, "JITTARGET");
    }
    pcre2_config(PCRE2_CONFIG_NEWLINE, &v);
    lua_pushinteger(L, (lua_Integer)v);  lua_setfield(L, -2, "NEWLINE");
    pcre2_config(PCRE2_CONFIG_LINKSIZE, &v);
    lua_pushinteger(L, (lua_Integer)v);  lua_setfield(L, -2, "LINKSIZE");
    return 1;
}

/* ============================================================================================ */
/* regex methods                                                                                */
/* ============================================================================================ */

/* re:find(subject [, init [, ef]]) */
static int Regex_find(lua_State* L)
{
    lua_settop(L, 4);
    return doFind(L, checkRegex(L, 1), 2, 3, 4);
}

/* re:match(subject [, init [, ef]]) */
static int Regex_match(lua_State* L)
{
    lua_settop(L, 4);
    return doMatch(L, checkRegex(L, 1), 2, 3, 4);
}

/* re:exec(subject [, init [, ef]]) */
static int Regex_exec(lua_State* L)
{
    lua_settop(L, 4);
    return doExec(L, checkRegex(L, 1), 2, 3, 4);
}

/* re:test(subject [, init [, ef]]) */
static int Regex_test(lua_State* L)
{
    lua_settop(L, 4);
    return doTest(L, checkRegex(L, 1), 2, 3, 4);
}

/* re:matchpos(subject [, init [, ef]]) */
static int Regex_matchpos(lua_State* L)
{
    lua_settop(L, 4);
    return doMatchPos(L, checkRegex(L, 1), 2, 3, 4);
}

/* re:findmatch(subject [, init [, ef]]) */
static int Regex_findmatch(lua_State* L)
{
    lua_settop(L, 4);
    return doFindMatch(L, checkRegex(L, 1), 2, 3, 4);
}

/* re:gmatch(subject [, init [, ef]]) */
static int Regex_gmatch(lua_State* L)
{
    lua_settop(L, 4);
    checkRegex(L, 1);
    return doGmatch(L, 1, 2, 3, 4, gmatchIter);
}

/* re:gsub(subject, repl [, n [, ef]]) */
static int Regex_gsub(lua_State* L)
{
    lua_settop(L, 5);
    return doGsub(L, checkRegex(L, 1), 2, 3, 4, 5);
}

/* re:count(subject [, init [, ef]]) */
static int Regex_count(lua_State* L)
{
    lua_settop(L, 4);
    return doCount(L, checkRegex(L, 1), 2, 3, 4);
}

/* re:split(subject [, init [, ef]]) */
static int Regex_split(lua_State* L)
{
    lua_settop(L, 4);
    checkRegex(L, 1);
    return doGmatch(L, 1, 2, 3, 4, splitIter);
}

/* re:ncapt() -> number of capture groups */
static int Regex_ncapt(lua_State* L)
{
    lua_pushinteger(L, (lua_Integer)checkRegex(L, 1)->ncapt);
    return 1;
}

/* re:jit() -> true if the regex was JIT compiled */
static int Regex_jit(lua_State* L)
{
    lua_pushboolean(L, checkRegex(L, 1)->isJit);
    return 1;
}

static int Regex_toString(lua_State* L)
{
    LpcreRegex* re = (LpcreRegex*)luaL_checkudata(L, 1, LPCRE_CLASS_NAME);
    lua_pushfstring(L, "%s: %p", LPCRE_CLASS_NAME, re);
    return 1;
}

static int Regex_release(lua_State* L)
{
    LpcreRegex* re = (LpcreRegex*)luaL_checkudata(L, 1, LPCRE_CLASS_NAME);
    if (re->md) {
        pcre2_match_data_free(re->md);
        re->md = NULL;
    }
    if (re->code) {
        pcre2_code_free(re->code);
        re->code = NULL;
    }
    return 0;
}

/* ============================================================================================ */

static const luaL_Reg ModuleFunctions[] =
{
    { "new",       Lpcre_new     },
    { "find",      Lpcre_find    },
    { "match",     Lpcre_match   },
    { "test",      Lpcre_test    },
    { "matchpos",  Lpcre_matchpos  },
    { "findmatch", Lpcre_findmatch },
    { "gmatch",    Lpcre_gmatch  },
    { "gsub",      Lpcre_gsub    },
    { "count",     Lpcre_count   },
    { "split",     Lpcre_split   },
    { "cache",     Lpcre_cache   },
    { NULL,        NULL } /* sentinel */
};

static const luaL_Reg PlainModuleFunctions[] =
{
    { "version",   Lpcre_version },
    { "config",    Lpcre_config  },
    { NULL,        NULL } /* sentinel */
};

static const luaL_Reg RegexMethods[] =
{
    { "find",      Regex_find    },
    { "match",     Regex_match   },
    { "exec",      Regex_exec    },
    { "tfind",     Regex_exec    },
    { "test",      Regex_test    },
    { "matchpos",  Regex_matchpos  },
    { "findmatch", Regex_findmatch },
    { "gmatch",    Regex_gmatch  },
    { "gsub",      Regex_gsub    },
    { "count",     Regex_count   },
    { "split",     Regex_split   },
    { "ncapt",     Regex_ncapt   },
    { "jit",       Regex_jit     },
    { NULL,        NULL } /* sentinel */
};

static const luaL_Reg RegexMetaMethods[] =
{
    { "__tostring", Regex_toString },
    { "__gc",       Regex_release  },
    { NULL,         NULL } /* sentinel */
};

/* ============================================================================================ */

typedef struct FlagDef
{
    const char* name;
    lpcre_flags value;
} FlagDef;

static const FlagDef Flags[] =
{
    /* compile options */
    { "ALLOW_EMPTY_CLASS",   PCRE2_ALLOW_EMPTY_CLASS   },
    { "ALT_BSUX",            PCRE2_ALT_BSUX            },
    { "AUTO_CALLOUT",        PCRE2_AUTO_CALLOUT        },
    { "CASELESS",            PCRE2_CASELESS            },
    { "DOLLAR_ENDONLY",      PCRE2_DOLLAR_ENDONLY      },
    { "DOTALL",              PCRE2_DOTALL              },
    { "DUPNAMES",            PCRE2_DUPNAMES            },
    { "EXTENDED",            PCRE2_EXTENDED            },
    { "FIRSTLINE",           PCRE2_FIRSTLINE           },
    { "MATCH_UNSET_BACKREF", PCRE2_MATCH_UNSET_BACKREF },
    { "MULTILINE",           PCRE2_MULTILINE           },
    { "NEVER_UCP",           PCRE2_NEVER_UCP           },
    { "NEVER_UTF",           PCRE2_NEVER_UTF           },
    { "NO_AUTO_CAPTURE",     PCRE2_NO_AUTO_CAPTURE     },
    { "NO_AUTO_POSSESS",     PCRE2_NO_AUTO_POSSESS     },
    { "NO_DOTSTAR_ANCHOR",   PCRE2_NO_DOTSTAR_ANCHOR   },
    { "NO_START_OPTIMIZE",   PCRE2_NO_START_OPTIMIZE   },
    { "UCP",                 PCRE2_UCP                 },
    { "UNGREEDY",            PCRE2_UNGREEDY            },
    { "UTF",                 PCRE2_UTF                 },
    { "NEVER_BACKSLASH_C",   PCRE2_NEVER_BACKSLASH_C   },
    { "ALT_CIRCUMFLEX",      PCRE2_ALT_CIRCUMFLEX      },
    { "ALT_VERBNAMES",       PCRE2_ALT_VERBNAMES       },
#ifdef PCRE2_EXTENDED_MORE
    { "EXTENDED_MORE",       PCRE2_EXTENDED_MORE       },
#endif
#ifdef PCRE2_LITERAL
    { "LITERAL",             PCRE2_LITERAL             },
#endif
#ifdef PCRE2_MATCH_INVALID_UTF
    { "MATCH_INVALID_UTF",   PCRE2_MATCH_INVALID_UTF   },
#endif
    /* compile and execution options */
    { "ANCHORED",            PCRE2_ANCHORED            },
    { "NO_UTF_CHECK",        PCRE2_NO_UTF_CHECK        },
#ifdef PCRE2_ENDANCHORED
    { "ENDANCHORED",         PCRE2_ENDANCHORED         },
#endif
    /* execution options */
    { "NOTBOL",              PCRE2_NOTBOL              },
    { "NOTEOL",              PCRE2_NOTEOL              },
    { "NOTEMPTY",            PCRE2_NOTEMPTY            },
    { "NOTEMPTY_ATSTART",    PCRE2_NOTEMPTY_ATSTART    },
#ifdef PCRE2_NO_JIT
    { "NO_JIT",              PCRE2_NO_JIT              },
#endif
    /* lpcre extension flags (compile flags) */
    { "UNSET_FALSE",         LPCRE_UNSET_FALSE         },
    { "JIT",                 LPCRE_JIT                 },
    { "NOCACHE",             LPCRE_NOCACHE             },
    { NULL,                  0                         }
};

/* flags table, callable for lrexlib compatibility: lpcre.flags() returns lpcre.flags */
static int Flags_call(lua_State* L)
{
    lua_settop(L, 1);
    return 1;
}

static void pushFlagsTable(lua_State* L)
{
    const FlagDef* f;
    lua_newtable(L);                                       /* -> flags */
    for (f = Flags; f->name; ++f) {
#if LUA_VERSION_NUM >= 503
        lua_pushinteger(L, (lua_Integer)f->value);         /* -> flags, value */
#else
        lua_pushnumber(L, (lua_Number)f->value);           /* -> flags, value */
#endif
        lua_setfield(L, -2, f->name);                      /* -> flags */
    }
    lua_newtable(L);                                       /* -> flags, meta */
    lua_pushcfunction(L, Flags_call);                      /* -> flags, meta, f */
    lua_setfield(L, -2, "__call");                         /* -> flags, meta */
    lua_setmetatable(L, -2);                               /* -> flags */
}

/* ============================================================================================ */

static void setupRegexMeta(lua_State* L, int subjCache)
{                                                          /* -> meta */
    lua_pushstring(L, LPCRE_CLASS_NAME);                   /* -> meta, className */
    lua_setfield(L, -2, "__metatable");                    /* -> meta */

    luaL_setfuncs(L, RegexMetaMethods, 0);                 /* -> meta */
    
    lua_newtable(L);                                       /* -> meta, RegexClass */
    lua_pushvalue(L, subjCache);                           /* -> meta, RegexClass, sc */
    luaL_setfuncs(L, RegexMethods, 1);                     /* -> meta, RegexClass */
    lua_setfield (L, -2, "__index");                       /* -> meta */
}

/* ============================================================================================ */

int lpcre_init_module(lua_State* L, int module)
{
    LpcreCache*   c;
    SubjectCache* sc;
    int           subjCache;

    sc = (SubjectCache*)lua_newuserdata(L, sizeof(SubjectCache)); /* -> sc */
    memset(sc, 0, sizeof(SubjectCache));
    subjCache = lua_gettop(L);

    if (luaL_newmetatable(L, LPCRE_CLASS_NAME)) {          /* -> sc, meta */
        setupRegexMeta(L, subjCache);
    }
    lua_pop(L, 1);                                         /* -> sc */

    lua_pushvalue(L, module);                              /* -> sc, module */
        lua_pushvalue(L, subjCache);                       /* -> sc, module, sc */
        c = (LpcreCache*)lua_newuserdata(L, sizeof(LpcreCache)); /* -> sc, module, sc, cache */
        memset(c, 0, sizeof(LpcreCache));
        c->max = LPCRE_DEFAULT_CACHE;
        lua_newtable(L);                                   /* -> sc, module, sc, cache, plain */
        lua_newtable(L);                                   /* -> sc, module, sc, cache, plain, map */
        lua_newtable(L);                                   /* -> sc, module, sc, cache, plain, map, rev */
        luaL_setfuncs(L, ModuleFunctions, 5);              /* -> sc, module */
        luaL_setfuncs(L, PlainModuleFunctions, 0);         /* -> sc, module */
        pushFlagsTable(L);                                 /* -> sc, module, flags */
        lua_setfield(L, -2, "flags");                      /* -> sc, module */
    lua_pop(L, 2);                                         /* -> */

    return 0;
}

/* ============================================================================================ */
