local lpcre = require("lpcre")

local format = string.format
local flags  = lpcre.flags

local function PRINT(s)
    print(s.." ("..debug.getinfo(2).currentline..")")
end
local function msgh(err)
    return debug.traceback(err, 2)
end
local function nlist(...)
    local rslt = {}
    rslt.n = select("#", ...)
    for i = 1, rslt.n do
        rslt[i] = select(i, ...)
    end
    return rslt
end
local function pcall(f, ...)
    -- PUC Lua 5.1 passes no arguments through xpcall, so they are bound here
    local args = nlist(...)
    return xpcall(function() return f(unpack(args, 1, args.n)) end, msgh)
end
local function assertNlistIs(nl, ...)
    local n = select("#", ...)
    assert(nl.n == n, format("count %d <> %d", nl.n, n))
    for i = 1, n do
        local v = select(i, ...)
        assert(nl[i] == v, format("[%d]: %s <> %s", i, tostring(nl[i]), tostring(v)))
    end
end
local function assertResults(expected, ...)
    assertNlistIs(nlist(...), unpack(expected, 1, expected.n or #expected))
end
local function assertError(pattern, f, ...)
    local ok, err = _G.pcall(f, ...)
    assert(not ok, "error expected")
    assert(tostring(err):find(pattern, 1, true), format("unexpected error message: %s", tostring(err)))
end
unpack = unpack or table.unpack

PRINT("==================================================================================")
do
    PRINT(format("lpcre %s, PCRE2 %s, JIT: %s", lpcre._VERSION, lpcre.version(),
                 tostring(lpcre.config().JIT)))
    assert(type(lpcre.version()) == "string")
    assert(lpcre.flags() == lpcre.flags) -- callable for lrexlib compatibility
    assert(getmetatable(lpcre) == "lpcre")
end
PRINT("==================================================================================")
do
    -- find: positions and init like string.find for patterns valid in both syntaxes
    local subjects = { "", "a", "hello", "hello world", "aaa bbb aaa" }
    local patterns = { "l+", "o", "a", "^h", "d$", "", "x*", "[ab]+" }
    for _, s in ipairs(subjects) do
        for _, p in ipairs(patterns) do
            for init = -15, 15 do
              if init > #s + 1 then
                -- (Lua 5.1/LuaJIT clamp init here, Lua 5.2+ fail as lpcre does)
                assertResults({ n = 1, nil }, lpcre.find(s, p, init))
                assertResults({ n = 1, nil }, lpcre.match(s, p, init))
              else
                local e = nlist(string.find(s, p, init))
                local r = nlist(lpcre.find(s, p, init))
                assert(e.n == r.n and e[1] == r[1] and e[2] == r[2],
                       format("find(%q, %q, %d): %s,%s <> %s,%s", s, p, init,
                              tostring(e[1]), tostring(e[2]), tostring(r[1]), tostring(r[2])))
                local em = string.match(s, p, init)
                local rm = lpcre.match(s, p, init)
                assert(em == rm, format("match(%q, %q, %d)", s, p, init))
              end
            end
        end
    end
end
PRINT("==================================================================================")
do
    -- captures, unset groups are nil
    assertResults({ n = 3, 3, 3, nil },        lpcre.find("hello", "(x)?l"))
    assertResults({ n = 4, 1, 5, "hel", "lo" }, lpcre.find("hello", "(h.l)(lo)"))
    assertResults({ n = 2, "l", nil },         lpcre.match("hello", "l(l)(x)?"))
    assertResults({ n = 1, "ll" },             lpcre.match("hello", "ll"))
    assertResults({ n = 1, nil },              lpcre.match("hello", "z"))
    assertResults({ n = 1, nil },              lpcre.find("hello", "z"))
    -- UNSET_FALSE gives false for unset groups (as lrexlib)
    assertResults({ n = 2, "l", false },       lpcre.match("hello", "l(l)(x)?", 1, flags.UNSET_FALSE))
    -- exec: start, end and capture table with named groups
    local s, e, t = lpcre.new("(?<first>l)(x)?(?<third>o)?"):exec("hello")
    assert(s == 3 and e == 3)
    assert(t[1] == "l" and t[2] == false and t[3] == false)
    assert(t.first == "l" and t.third == false)
    local _, _, t2 = lpcre.new("(?<first>l)(x)?", flags.UNSET_FALSE):exec("hello")
    assert(t2[1] == "l" and t2[2] == false)
    -- exec/tfind: unset groups are always false in the table, so #t and ipairs see all
    -- groups; the multiple results of the other functions keep nil
    do
        local ok, carray = pcall(require, "carray")
        local subjects = { "xb" }
        if ok then
            subjects[2] = carray.new("char"):append("xb")
        else
            print("carray module not available: carray subject skipped")
        end
        local re = lpcre.new("(a)?(b)(c)?")
        for _, subj in ipairs(subjects) do
            for _, m in ipairs({ "exec", "tfind" }) do
                local s3, e3, t3 = re[m](re, subj)
                assert(s3 == 2 and e3 == 2)
                assert(#t3 == 3)
                assert(t3[1] == false and t3[2] == "b" and t3[3] == false)
                local seen = {}
                for k, v in ipairs(t3) do seen[k] = v end
                assert(#seen == 3 and seen[1] == false and seen[2] == "b" and seen[3] == false)
            end
            assertResults({ n = 5, 2, 2, nil, "b", nil }, re:find(subj))
            assertResults({ n = 3, nil, "b", nil },       re:match(subj))
            assertResults({ n = 4, nil, "b", nil, 2 },    re:matchpos(subj))
            assertResults({ n = 6, 2, 2, "b", nil, "b", nil }, re:findmatch(subj))
            local cnt = 0
            for a, b in lpcre.gmatch(subj, "(b)(c)?") do
                cnt = cnt + 1
                assert(a == "b" and b == nil)
            end
            assert(cnt == 1)
            local args
            lpcre.gsub(subj, re, function(...) args = nlist(...) end)
            assertNlistIs(args, nil, "b", nil)
            -- with UNSET_FALSE the table is unchanged, the multiple results are false
            local reF = lpcre.new("(a)?(b)(c)?", flags.UNSET_FALSE)
            local _, _, tF = reF:exec(subj)
            assert(#tF == 3 and tF[1] == false and tF[2] == "b" and tF[3] == false)
            assertResults({ n = 3, false, "b", false }, reF:match(subj))
        end
    end
    assert(lpcre.new("a"):exec("b") == nil)
    assert(lpcre.new("(a)(b)(c)?"):ncapt() == 3)
end
PRINT("==================================================================================")
do
    -- flags as numbers and as letter strings
    assert(lpcre.find("ABC", "b", 1, "i") == 2)
    assert(lpcre.find("ABC", "b", 1, flags.CASELESS) == 2)
    assert(lpcre.find("ABC", "b") == nil)
    assert(lpcre.find("a\nb", "^b", 1, "m") == 3)
    assert(lpcre.find("a\nb", "^b", 1) == nil)
    assert(lpcre.find("a\nb", "a.b", 1, "s") == 1)
    assert(lpcre.find("a\nb", "a.b") == nil)
    assert(lpcre.find("ab", "a b # comment", 1, "x") == 1)
    assert(lpcre.match("aaa", "a+", 1, "U") == "a")
    assert(lpcre.match("aaa", "a+", 1, flags.UNGREEDY) == "a")
    assert(lpcre.match("xaB", "ab", 1, "ix") == "aB")
    assert(lpcre.match("xaB", "ab", 1, flags.CASELESS + flags.EXTENDED) == "aB")
    -- execution flags
    assert(lpcre.find("abc", "^b", 2) == nil)
    assert(lpcre.find("abc", "b", 1, nil, flags.ANCHORED) == nil)
    assert(lpcre.find("abc", "b", 2, nil, flags.ANCHORED) == 2)
    assert(lpcre.find("abc", "^a", 1, nil, flags.NOTBOL) == nil)
    assert(lpcre.find("abc", "x*", 1, nil, flags.NOTEMPTY) == nil)
    -- lpcre's own flags (above 2^32) never reach PCRE2: all of them at once
    local own = flags.UNSET_FALSE + flags.JIT + flags.NOCACHE
    assert(own == 2^32 + 2^33 + 2^34)
    local ra = lpcre.new("(a)(x)?", own + flags.CASELESS)
    assertResults({ n = 2, "A", false }, ra:match("zA"))
    assertResults({ n = 4, 2, 2, "A", false }, ra:find("zA"))
    assertResults({ n = 4, 2, 2, "A", false },
                  lpcre.find("zA", "(a)(x)?", 1, flags.UNSET_FALSE + flags.JIT + flags.CASELESS))
    assertResults({ n = 2, "A", false },
                  lpcre.match("zA", "(a)(x)?", 1, flags.UNSET_FALSE + flags.JIT + flags.CASELESS))
    assertError("invalid flags", lpcre.find, "a", "a", 1, nil, flags.JIT)   -- no match option
    -- flag values are exact numbers (also as doubles in Lua 5.1/LuaJIT)
    local sum = 0
    for name, v in pairs(flags) do
        assert(type(v) == "number" and v >= 0 and v < 2^53 and v == math.floor(v), name)
        sum = sum + v
    end
    assert(sum < 2^53 and sum == math.floor(sum))
    -- JIT is optional: results are the same whether JIT is available or not
    local rj = lpcre.new("(\\d+)-(\\d+)", flags.JIT)
    assert(rj:jit() == (lpcre.config().JIT == true))
    assertResults({ n = 2, "12", "345" }, rj:match("ab 12-345 cd"))
end
PRINT("==================================================================================")
do
    -- gmatch
    local r = {}
    for k, v in lpcre.gmatch("a=1, b=22, c=333", "(\\w+)=(\\w+)") do
        r[#r + 1] = k..":"..v
    end
    assert(table.concat(r, " ") == "a:1 b:22 c:333")
    r = {}
    for w in lpcre.gmatch("one two  three", "\\w+") do
        r[#r + 1] = w
    end
    assert(table.concat(r, ",") == "one,two,three")
    -- init
    r = {}
    for w in lpcre.gmatch("one two three", "\\w+", 5) do
        r[#r + 1] = w
    end
    assert(table.concat(r, ",") == "two,three")
    r = {}
    for w in lpcre.gmatch("one two three", "\\w+", -5) do
        r[#r + 1] = w
    end
    assert(table.concat(r, ",") == "three")
    for _ in lpcre.gmatch("abc", "\\w", 10) do
        error("unexpected")
    end
    -- empty matches as Lua 5.4's string.gmatch
    local function all(s, p)
        local t = {}
        for m in lpcre.gmatch(s, p) do t[#t + 1] = "<"..m..">" end
        return table.concat(t)
    end
    assert(all("abc", "x*") == "<><><><>")
    assert(all("abc", "b*") == "<><b><>")
    assert(all("", "x*")    == "<>")
    assert(all("aaa", "a*?") == "<><><><>")
    -- regex method
    local re = lpcre.new("\\d")
    local n = 0
    for d in re:gmatch("1a2b3") do n = n + tonumber(d) end
    assert(n == 6)
    -- iterator survives the regex being used elsewhere in the loop
    local out = {}
    for a in re:gmatch("1 2 3") do
        out[#out + 1] = a..(re:match("x9") or "")
    end
    assert(table.concat(out, ",") == "19,29,39")
end
PRINT("==================================================================================")
do
    -- gsub with string replacement
    assertResults({ n = 2, "hell[o] w[o]rld", 2 }, lpcre.gsub("hello world", "(o)|(z)", "[%1%2]"))
    assertResults({ n = 2, "he<l><l>o", 2 },       lpcre.gsub("hello", "l", "<%0>"))
    assertResults({ n = 2, "he<l><l>o", 2 },       lpcre.gsub("hello", "l", "<%1>"))
    assertResults({ n = 2, "he%%o", 2 },           lpcre.gsub("hello", "l", "%%"))
    assertResults({ n = 2, "world hello", 1 },     lpcre.gsub("hello world", "(\\w+) (\\w+)", "%2 %1"))
    assertResults({ n = 2, "-a-b-c-", 4 },         lpcre.gsub("abc", "x*", "-"))
    assertResults({ n = 2, "-a-c-", 3 },           lpcre.gsub("abc", "b*", "-"))
    assertResults({ n = 2, "hexlo", 1 },           lpcre.gsub("hello", "l", "x", 1))
    assertResults({ n = 2, "hello", 0 },           lpcre.gsub("hello", "l", "x", 0))
    assertResults({ n = 2, "hello", 0 },           lpcre.gsub("hello", "l", "x", -1))
    assertResults({ n = 2, "he11o", 2 },           lpcre.gsub("hello", "l", 1))
    assertResults({ n = 2, "HELLO", 1 },           lpcre.gsub("hello", "hello", "HELLO", nil, "i"))
    assertResults({ n = 2, "XbX", 2 },             lpcre.gsub("aba", "A", "X", nil, "i"))
    -- same results as string.gsub where the pattern syntax agrees
    for _, c in ipairs { {"hello world", "o", "0"}, {"abc", "", "-"}, {"hello", "l+", "L"},
                         {"x = 1, y = 2", "(%w+) = (%w+)", "%2 = %1"} } do
        local p = c[2]:gsub("%%w", "\\w")
        local e1, e2 = string.gsub(c[1], c[2], c[3])
        local r1, r2 = lpcre.gsub(c[1], p, c[3])
        assert(e1 == r1 and e2 == r2, format("gsub(%q, %q): %q <> %q", c[1], c[2], e1, r1))
    end
    -- table replacement
    assertResults({ n = 2, "heLLo", 2 },           lpcre.gsub("hello", "(l)", { l = "L" }))
    assertResults({ n = 2, "hello", 2 },           lpcre.gsub("hello", "l", {}))
    assertResults({ n = 2, "$x-1$", 2 },           lpcre.gsub("$a-$b$", "\\$(\\w)", { a = "$x", b = 1 }))
    assertResults({ n = 2, "h1llo", 1 },           lpcre.gsub("hello", "e", { e = 1 }))
    -- function replacement
    assertResults({ n = 2, "he55o", 2 },           lpcre.gsub("hello", "l", function() return 5 end))
    assertResults({ n = 2, "hello", 2 },           lpcre.gsub("hello", "l", function() return false end))
    assertResults({ n = 2, "hello", 2 },           lpcre.gsub("hello", "l", function() end))
    assertResults({ n = 2, "1+2=3", 1 },           lpcre.gsub("1+2=?", "(\\d)\\+(\\d)=\\?", function(a, b)
                                                        -- tonumber() avoids Lua 5.3's implicit string-to-number
                                                        -- coercion in "+", which yields a float there (3.0)
                                                        return a.."+"..b.."="..(tonumber(a) + tonumber(b))
                                                   end))
    local args = nil
    lpcre.gsub("ab", "(a)(x)?(b)", function(...) args = nlist(...) end)
    assertNlistIs(args, "a", nil, "b")
    lpcre.gsub("ab", "(a)(x)?(b)", function(...) args = nlist(...) end, nil, flags.UNSET_FALSE)
    assertNlistIs(args, "a", false, "b")
    -- regex method
    local re = lpcre.new("(\\d+)")
    assertResults({ n = 2, "a<1>b<22>", 2 }, re:gsub("a1b22", "<%1>"))
    assertResults({ n = 2, "a<1>b22", 1 },   re:gsub("a1b22", "<%1>", 1))
    -- recursive use of the same regex inside a replacement function
    assertResults({ n = 2, "[2] [4]", 2 }, re:gsub("1 3", function(d)
        -- tonumber() avoids Lua 5.3's implicit string-to-number
        -- coercion in "+", which yields a float there (2.0)
        return "["..re:gsub(d, function(x) return tonumber(x) + 1 end).."]"
    end))
end
PRINT("==================================================================================")
do
    -- count and split
    assert(lpcre.count("abcabc", "b") == 2)
    assert(lpcre.count("abc", "x*") == 4)
    assert(lpcre.count("abc", "b*") == 3)
    assert(lpcre.count("abcabc", "b", 3) == 1)
    assert(lpcre.new("\\d"):count("a1b2c3") == 3)
    local function split(...)
        local t = {}
        for a, b in lpcre.split(...) do t[#t + 1] = a.."|"..tostring(b) end
        return table.concat(t, " ")
    end
    assert(split("a,b;c", "[,;]")     == "a|, b|; c|nil")
    assert(split("a,b;c", "([,;])")   == "a|, b|; c|nil")
    assert(split(",a,", ",")          == "|, a|, |nil")
    assert(split("", "x")             == "|nil")
    assert(split("a,,b", ",*")        == "| a|,, b| |nil")
    assert(split("a1b2", "\\d", 3)    == "b|2 |nil")
end
PRINT("==================================================================================")
do
    -- binary data with NUL bytes
    local s = "a\0b\0\0c"
    assertResults({ n = 2, "a-b--c", 3 },    lpcre.gsub(s, "\0", "-"))
    assertResults({ n = 2, "a-b-c", 2 },     lpcre.gsub(s, "\\x00+", "-"))
    assertResults({ n = 3, 2, 4, "\0b\0" },  lpcre.find(s, "(\\0b\\0)"))
    assert(lpcre.match(s, "b\0+c") == "b\0\0c")       -- NUL inside the pattern
    assert(lpcre.match("\255\254\0\1", "[\\x00-\\x01]+") == "\0\1")
    assert(lpcre.count(string.rep("\0", 100), "\0") == 100)
end
PRINT("==================================================================================")
do
    -- UTF-8
    local s = "äöü"
    assert(#s == 6)
    assert(lpcre.match(s, "^.", 1, "u") == "ä")
    assert(lpcre.match(s, "^.") == "\195")
    assert(lpcre.match(s, "^.", 1, flags.UTF) == "ä")
    assertResults({ n = 2, "-ä-ö-ü-", 4 }, lpcre.gsub(s, "", "-", nil, "u"))
    assertResults({ n = 2, 3, 4 },         lpcre.find(s, "ö", 1, "u"))
    assert(lpcre.count(s, ".", 1, "u") == 3)
    local t = {}
    for c in lpcre.gmatch(s, "x*", 1, "u") do t[#t + 1] = "<"..c..">" end
    assert(#t == 4)
    assert(lpcre.match("Grüße", "\\w+", 1, flags.UTF + flags.UCP) == "Grüße")
    -- invalid UTF-8 and offsets inside a character are errors
    assertError("UTF-8 error",     lpcre.find, "\255", "a", 1, "u")
    assertError("match failed",    lpcre.find, s, "ö", 2, "u")
end
PRINT("==================================================================================")
do
    -- default: everything is cached, new() as well as pattern strings
    local oldSize = lpcre.cache()
    assert(oldSize == 256)
    lpcre.cache(0)
    lpcre.cache(oldSize)
    assert(select(2, lpcre.cache()) == 0)
    local c1 = lpcre.new("abc")
    assert(select(2, lpcre.cache()) == 1)
    assert(lpcre.new("abc") == c1)
    assert(select(2, lpcre.cache()) == 1)
    assert(lpcre.new("abc", "i") ~= c1)                          -- other flags
    assert(lpcre.new("abc", "i") == lpcre.new("abc", flags.CASELESS))
    assert(select(2, lpcre.cache()) == 2)
    assert(lpcre.find("xabc", "abc") == 2)                       -- same entry as new("abc")
    assert(select(2, lpcre.cache()) == 2)
    assert(lpcre.match("xa\0b", "a\0b") == "a\0b")             -- NUL in the key
    assert(lpcre.match("xa\0c", "a\0c") == "a\0c")
    assert(lpcre.new("a\0b") ~= lpcre.new("a\0c"))
    assert(select(2, lpcre.cache()) == 4)
    for _, f in ipairs { "find", "match", "gmatch", "gsub", "count", "split" } do
        lpcre[f]("x", "via_"..f, f == "gsub" and "" or nil)
    end
    assert(select(2, lpcre.cache()) == 10)
    -- NOCACHE ("n") for new(): compiled anew, not cached, owned by the caller
    local n1, n2 = lpcre.new("abc", "n"), lpcre.new("abc", "n")
    assert(n1 ~= n2 and n1 ~= c1)
    assert(lpcre.new("uncached", "n") ~= lpcre.new("uncached", flags.NOCACHE))
    assert(select(2, lpcre.cache()) == 10)
    assert(n1:find("xabc") == 2 and lpcre.find("xabc", n1) == 2)
    assert(select(2, lpcre.cache()) == 10)
    -- ... and rejected for pattern strings of the module functions
    assertError("flag NOCACHE is only valid for lpcre.new()", lpcre.find, "x", "x", 1, "n")
    assertError("flag NOCACHE is only valid for lpcre.new()", lpcre.gsub, "x", "x", "", nil, flags.NOCACHE)
    -- bounded size, least recently used patterns are evicted
    lpcre.cache(0)
    lpcre.cache(3)
    local p1 = lpcre.new("p1")
    local p2 = lpcre.new("p2")
    local p3 = lpcre.new("p3")
    assert(select(2, lpcre.cache()) == 3)
    lpcre.find("x", "p1")               -- p1 is now most recently used
    local p4 = lpcre.new("p4")          -- evicts p2
    assert(select(2, lpcre.cache()) == 3)
    assert(lpcre.new("p1") == p1)
    assert(lpcre.new("p3") == p3)
    assert(lpcre.new("p4") == p4)
    assert(lpcre.new("p2") ~= p2)       -- was evicted, compiled anew (evicts p1)
    assert(lpcre.new("p1") ~= p1)
    assert(p2:match("xp2") == "p2")     -- evicted objects remain usable
    assert(lpcre.cache(2) == 3)
    assert(select(2, lpcre.cache()) == 2)
    -- cache(0) disables and empties the cache
    lpcre.cache(0)
    local size, count = lpcre.cache()
    assert(size == 0 and count == 0)
    assert(lpcre.new("abc") ~= lpcre.new("abc"))
    assert(lpcre.find("xabc", "abc") == 2)
    assert(lpcre.match("xabc", "b") == "b")
    assert(select(2, lpcre.gsub("xabc", "c", "C")) == 1)
    assert(lpcre.count("xabc", "\\w") == 4)
    assert(select(2, lpcre.cache()) == 0)
    assert(lpcre.cache(oldSize) == 0)
    -- patterns with and without flags live in separate maps that share one LRU list
    lpcre.cache(0)
    lpcre.cache(4)
    local a0, ai, ax = lpcre.new("a"), lpcre.new("a", "i"), lpcre.new("a", "x")
    assert(a0 ~= ai and a0 ~= ax and ai ~= ax)                   -- same pattern, other flags
    assert(lpcre.new("a", 0) == a0 and lpcre.new("a", "") == a0) -- flags 0 = no flags
    assert(lpcre.new("a", flags.CASELESS) == ai)
    assert(lpcre.find("xA", "a", 1, "i") == 2 and lpcre.find("xA", "a") == nil)
    assert(select(2, lpcre.cache()) == 3)
    local nul0, nuli = lpcre.new("n\0b"), lpcre.new("n\0b", "i")
    assert(nul0 ~= nuli)
    assert(lpcre.new("n\0b") == nul0 and lpcre.new("n\0b", "i") == nuli)
    assert(lpcre.new("n\0c") ~= nul0 and lpcre.new("n\0c", "i") ~= nuli)
    assert(lpcre.match("xN\0B", "n\0b", 1, "i") == "N\0B")
    -- eviction spans both maps: the four n\0 entries have pushed out all "a" entries
    assert(select(2, lpcre.cache()) == 4)
    assert(lpcre.new("a") ~= a0 and lpcre.new("a", "i") ~= ai and lpcre.new("a", "x") ~= ax)
    lpcre.cache(0)
    lpcre.cache(3)
    a0, ai = lpcre.new("a"), lpcre.new("a", "i")
    local b0 = lpcre.new("b")                    -- LRU order: b, a(i), a
    lpcre.find("x", "a")                         -- a(i) is now least recently used
    local bi = lpcre.new("b", "i")               -- evicts a(i) from the flags map
    assert(lpcre.new("a") == a0 and lpcre.new("b") == b0 and lpcre.new("b", "i") == bi)
    local ai2 = lpcre.new("a", "i")              -- compiled anew, evicts the plain "a"
    assert(ai2 ~= ai and ai2:find("A") == 1)
    assert(lpcre.new("b") == b0 and lpcre.new("b", "i") == bi and lpcre.new("a", "i") == ai2)
    assert(lpcre.new("a") ~= a0)                 -- evicts b
    assert(select(2, lpcre.cache()) == 3)
    -- a compile error with flags leaves the cache unchanged
    assertError("missing closing parenthesis", lpcre.new, "(", "i")
    assertError("missing closing parenthesis", lpcre.find, "x", "(", 1, "u")
    assert(select(2, lpcre.cache()) == 3)
    -- cache(0) empties both maps: afterwards nothing of the old entries is found
    lpcre.cache(0)
    assert(select(2, lpcre.cache()) == 0)
    lpcre.cache(3)
    assert(lpcre.new("b") ~= b0 and lpcre.new("b", "i") ~= bi and lpcre.new("a", "i") ~= ai2)
    assert(select(2, lpcre.cache()) == 3)
    collectgarbage()
    assert(lpcre.find("xB", "b", 1, "i") == 2 and lpcre.find("xb", "b") == 2)
    assert(select(2, lpcre.cache()) == 3)
    -- shrinking evicts from both maps; the remaining entries stay intact
    local keep = lpcre.new("b", "i")             -- most recently used
    assert(lpcre.cache(1) == 3 and select(2, lpcre.cache()) == 1)
    assert(lpcre.new("b", "i") == keep)
    lpcre.cache(oldSize)
    -- many patterns: the cache stays bounded
    for i = 1, 1000 do
        assert(lpcre.find("n"..i, "n"..i.."$") == 1)
    end
    assert(select(2, lpcre.cache()) == oldSize)
    collectgarbage()
    -- regex objects are accepted wherever a pattern is expected, cf must be nil then
    local re = lpcre.new("b")
    assert(lpcre.find("abc", re) == 2)
    assert(lpcre.find("abc", re, 1, nil) == 2)
    local ok, err = pcall(lpcre.find, "aBc", re, 1, "i")
    assert(not ok and err:match("cf not allowed with a regex object"))
    ok, err = pcall(lpcre.gsub, "abc", re, "x", nil, 0)
    assert(not ok and err:match("cf not allowed with a regex object"))
    -- the pattern of lpcre.new() must be a string, as in the module functions
    ok, err = pcall(lpcre.new, 1)
    assert(not ok and err:match("string expected, got number"))
end
PRINT("==================================================================================")
do
    -- errors
    -- (the function name in the message depends on the Lua version)
    assertError("bad argument #1 to ",                        lpcre.new, "a(b")
    assertError("(missing closing parenthesis at offset 3)",  lpcre.new, "a(b")
    assertError("bad argument #2 to ",                        lpcre.find, "x", "a(b")
    assertError("(missing closing parenthesis at offset 3)",  lpcre.find, "x", "a(b")
    -- the exact offset in this message varies between PCRE2 versions (e.g. 10.42 vs 10.47)
    assertError("quantifier does not follow a repeatable item", lpcre.new, "*")
    assertError("invalid flag character 'z'",                 lpcre.new, "a", "z")
    assertError("invalid flags",                              lpcre.new, "a", -1)
    assertError("invalid flags",                              lpcre.new, "a", 2^40)
    assertError("number or string expected, got table",       lpcre.new, "a", {})
    assertError("string or carray expected, got table",       lpcre.find, {}, "a")
    assertError("string or carray expected, got nil",         lpcre.find, nil, "a")
    assertError("string or lpcre.regex expected, got nil",    lpcre.find, "a", nil)
    assertError("invalid capture index %2 in replacement string", lpcre.gsub, "hello", "(l)", "%2")
    assertError("invalid capture index %2 in replacement string", lpcre.gsub, "hello", "(?:l)(?:l)", "%2")
    assertError("invalid use of '%' in replacement string",   lpcre.gsub, "hello", "l", "%x")
    assertError("invalid use of '%' in replacement string",   lpcre.gsub, "hello", "l", "a%")
    assertError("invalid replacement value (a table)",        lpcre.gsub, "hello", "l", function() return {} end)
    assertError("invalid replacement value (a boolean)",      lpcre.gsub, "hello", "l", { l = true })
    assertError("string/function/table expected, got boolean", lpcre.gsub, "hello", "l", true)
    assertError("lpcre.regex expected, got table",            lpcre.new("a").find, {}, "a")
    -- no error if nothing matches
    assertResults({ n = 2, "abc", 0 }, lpcre.gsub("abc", "x", "%9"))
    -- numbers are accepted as subjects
    assert(lpcre.find(12345, "3") == 3)
    assert(tostring(lpcre.new("a")):match("^lpcre%.regex: "))
end
PRINT("==================================================================================")
do
    -- gsub results of length 0 and empty subjects (string subject; carray in test02)
    local content = string.rep("0123456789abcdef", 64)   -- 1 KB
    local s, n = lpcre.gsub(content, ".*", "")
    assert(s == "" and n == 1)
    s, n = lpcre.gsub(content, ".", "")
    assert(s == "" and n == 1024)
    s, n = lpcre.gsub(content, "\\w", function() return "" end)
    assert(s == "" and n == 1024)
    s, n = lpcre.gsub("", ".*", "")
    assert(s == "" and n == 1)
    s, n = lpcre.gsub("", "x", "y")
    assert(s == "" and n == 0)
    -- growing again from an empty subject by an empty match
    s, n = lpcre.gsub("", "^", "hello")
    assert(s == "hello" and n == 1)
    s, n = lpcre.gsub("", "", "longer replacement")
    assert(s == "longer replacement" and n == 1)
    assert(lpcre.find("", "") == 1 and lpcre.find("", "a") == nil and lpcre.count("", "x*") == 1)
end
PRINT("==================================================================================")
do
    -- partial matching flags are rejected (PCRE2_PARTIAL_SOFT = 0x10, PCRE2_PARTIAL_HARD = 0x20)
    assertError("partial matching is not supported", lpcre.find, "abc", "abcd", 1, nil, 0x10)
    assertError("partial matching is not supported", lpcre.find, "abc", "abcd", 1, nil, 0x20)
    assertError("partial matching is not supported", lpcre.new("abcd").gsub, lpcre.new("abcd"), "abc", "", nil, 0x30)
    assert(lpcre.find("abc", "abcd", 1, nil, 0) == nil)
    -- config strings
    local cfg = lpcre.config()
    assert(cfg.VERSION == lpcre.version() and type(cfg.UNICODE_VERSION) == "string")
    assert(type(cfg.NEWLINE) == "number" and type(cfg.LINKSIZE) == "number")
    if cfg.JIT then assert(type(cfg.JITTARGET) == "string") end
end
PRINT("==================================================================================")
do
    -- test, matchpos and findmatch agree with find for patterns, subjects and init
    -- (Lua 5.1/LuaJIT clamp an init beyond the end in string.find, so find of lpcre
    -- is the reference here, it is checked against string.find above)
    local function capsThenEnd(st, en, ...)
        if not st then return nil end
        local n = select("#", ...)
        if n == 0 then return true, en end
        local r = { ... }
        r[n + 1] = en
        return unpack(r, 1, n + 1)
    end
    local subjects = { "", "a", "abc", "a\0b\0", "hello world", "x = 1, y = 22" }
    local patterns = { "", "a", "(a)", "(x)?(b)", "x*", "(b)|(c)", "\\0", "^", "(\\w+) = (\\d+)",
                       "(?<k>\\w)(?<v>\\d)?" }
    for _, s in ipairs(subjects) do
        for _, p in ipairs(patterns) do
            for init = -8, #s + 3 do
                local what = format("%q %q %d", s, p, init)
                local f = nlist(lpcre.find(s, p, init))
                assertResults({ n = 1, f[1] ~= nil }, lpcre.test(s, p, init))
                assertResults(nlist(capsThenEnd(lpcre.find(s, p, init))), lpcre.matchpos(s, p, init))
                local fm = nlist(lpcre.findmatch(s, p, init))
                if f[1] then
                    assert(fm.n == f.n + 1 and fm[1] == f[1] and fm[2] == f[2], what)
                    assert(fm[3] == s:sub(f[1], f[2]), what)
                    for i = 3, f.n do assert(fm[i + 1] == f[i], what) end
                else
                    assertResults({ n = 1, nil }, lpcre.findmatch(s, p, init))
                end
                local re = lpcre.new(p)
                assertResults(nlist(lpcre.test(s, p, init)), re:test(s, init))
                assertResults(nlist(lpcre.matchpos(s, p, init)), re:matchpos(s, init))
                assertResults(fm, re:findmatch(s, init))
            end
        end
    end
end
PRINT("==================================================================================")
do
    -- test: only a boolean, also for patterns with groups
    assertResults({ n = 1, true },  lpcre.test("hello", "l+"))
    assertResults({ n = 1, true },  lpcre.test("hello", "(x)?(l)(l)"))
    assertResults({ n = 1, false }, lpcre.test("hello", "(x)(y)"))
    assertResults({ n = 1, false }, lpcre.test("hello", "h", 2))
    assertResults({ n = 1, true },  lpcre.test("hello", "o", -1))
    assertResults({ n = 1, false }, lpcre.test("hello", "", 7))      -- init beyond len + 1
    assertResults({ n = 1, true },  lpcre.test("hello", "$", 6))     -- init == len + 1
    assertResults({ n = 1, true },  lpcre.test(12345, "3"))          -- number subject
    -- NUL bytes in subject and pattern
    assert(lpcre.test("a\0b", "\0b") == true and lpcre.test("a\0b", "a\0b") == true)
    assert(lpcre.test("a\0b", "^b") == false)
    -- compile flags
    assert(lpcre.test("HELLO", "hel") == false and lpcre.test("HELLO", "hel", 1, "i") == true)
    assert(lpcre.test("a\nb", "^b") == false and lpcre.test("a\nb", "^b", 1, flags.MULTILINE) == true)
    assert(lpcre.test("a\nb", "a.b", 1, "s") == true)
    assert(lpcre.new("hel", "i"):test("HELLO") == true)
    -- execution flags
    assert(lpcre.test("abc", "^a", 1, nil, flags.NOTBOL) == false)
    assert(lpcre.test("abc", "b", 1, nil, flags.ANCHORED) == false)
    assert(lpcre.test("abc", "b", 2, nil, flags.ANCHORED) == true)
    assert(lpcre.test("abc", "x*", 1, nil, flags.NOTEMPTY) == false)
    -- many groups (more than kept on the C stack)
    local many = string.rep("(a)", 20)
    assert(lpcre.test(string.rep("a", 20), many) == true and lpcre.test(string.rep("a", 19), many) == false)
    -- UTF: invalid subject is an error, as for find
    assertError("match failed: UTF-8 error", lpcre.test, "a\255", "a", 1, "u")
    assert(lpcre.test("a\255", "a", 1, flags.UTF + flags.MATCH_INVALID_UTF) == true)
end
PRINT("==================================================================================")
do
    -- matchpos: captures, then the end position
    assertResults({ n = 3, "key", "value", 9 }, lpcre.matchpos("key=value; x", "(\\w+)=(\\w+)"))
    assertResults({ n = 2, "ll", 4 },    lpcre.matchpos("hello", "(l+)"))
    assertResults({ n = 2, true, 4 },    lpcre.matchpos("hello", "l+"))       -- no groups: true
    assertResults({ n = 2, true, 0 },    lpcre.matchpos("hello", ""))         -- empty match at 1
    assertResults({ n = 2, true, 2 },    lpcre.matchpos("hello", "", 3))      -- empty match at 3
    assertResults({ n = 3, nil, "l", 3 }, lpcre.matchpos("hello", "(x)?(l)")) -- unset group: nil
    assertResults({ n = 3, "b", nil, 2 }, lpcre.matchpos("abc", "(b)|(c)"))
    assertResults({ n = 1, nil },        lpcre.matchpos("hello", "(x)"))
    assertResults({ n = 1, nil },        lpcre.matchpos("hello", "x"))
    assertResults({ n = 1, nil },        lpcre.matchpos("hello", "", 7))
    assertResults({ n = 2, "o", 5 },     lpcre.matchpos("hello", "(o)", -1))
    -- the end position continues a /g-style loop: next init is e + 1
    local caps, init = {}, 1
    while true do
        local d, e = lpcre.matchpos("a1b22c333", "(\\d+)", init)
        if not d then break end
        caps[#caps + 1] = d
        init = e + 1
    end
    assert(table.concat(caps, ",") == "1,22,333")
    -- NUL bytes
    assertResults({ n = 2, "\0b", 3 }, lpcre.matchpos("a\0b", "(\0.)"))
    -- flags
    assertResults({ n = 2, "HEL", 3 },  lpcre.matchpos("HELLO", "(hel)", 1, "i"))
    assertResults({ n = 1, nil },       lpcre.matchpos("abc", "(^a)", 1, nil, flags.NOTBOL))
    assertResults({ n = 3, false, "l", 3 }, lpcre.matchpos("hello", "(x)?(l)", 1, flags.UNSET_FALSE))
    assertResults({ n = 3, false, "l", 3 }, lpcre.new("(x)?(l)", flags.UNSET_FALSE):matchpos("hello"))
    -- many groups (more than kept on the C stack)
    local r = nlist(lpcre.matchpos("x" .. string.rep("a", 20), string.rep("(a)", 20)))
    assert(r.n == 21 and r[1] == "a" and r[20] == "a" and r[21] == 21)
end
PRINT("==================================================================================")
do
    -- findmatch: start, end, whole match, captures
    assertResults({ n = 5, 1, 9, "key=value", "key", "value" }, lpcre.findmatch("key=value; x", "(\\w+)=(\\w+)"))
    assertResults({ n = 3, 3, 4, "ll" },       lpcre.findmatch("hello", "l+"))
    assertResults({ n = 3, 1, 0, "" },         lpcre.findmatch("hello", ""))
    assertResults({ n = 5, 3, 3, "l", nil, "l" }, lpcre.findmatch("hello", "(x)?(l)"))
    assertResults({ n = 5, 3, 3, "l", false, "l" }, lpcre.findmatch("hello", "(x)?(l)", 1, flags.UNSET_FALSE))
    assertResults({ n = 1, nil },              lpcre.findmatch("hello", "x"))
    assertResults({ n = 1, nil },              lpcre.findmatch("hello", "", 7))
    assertResults({ n = 3, 5, 5, "o" },        lpcre.findmatch("hello", "o", -1))
    assertResults({ n = 4, 2, 3, "\0b", "b" }, lpcre.findmatch("a\0b", "\0(b)"))
    assertResults({ n = 3, 1, 3, "HEL" },      lpcre.findmatch("HELLO", "hel", 1, "i"))
    assertResults({ n = 1, nil },              lpcre.findmatch("abc", "^a", 1, nil, flags.NOTBOL))
    assertResults({ n = 4, 2, 4, "234", "4" }, lpcre.new("\\d+(\\d)"):findmatch("x234", 2))
    local r = nlist(lpcre.findmatch(string.rep("a", 20), string.rep("(a)", 20)))
    assert(r.n == 23 and r[3] == string.rep("a", 20) and r[4] == "a" and r[23] == "a")
end
PRINT("==================================================================================")
do
    -- argument errors of test, matchpos and findmatch, the same as for find
    for _, f in ipairs { lpcre.test, lpcre.matchpos, lpcre.findmatch } do
        assertError("string or carray expected, got table", f, {}, "a")
        assertError("string or carray expected, got nil", f, nil, "a")
        assertError("string or lpcre.regex expected, got number", f, "a", 1)
        assertError("missing closing parenthesis at offset 4", f, "a", "(abc")
        assertError("invalid flag character 'q'", f, "a", "a", 1, "q")
        assertError("invalid flags", f, "a", "a", 1, -1)
        assertError("flag NOCACHE is only valid for lpcre.new()", f, "a", "a", 1, "n")
        assertError("cf not allowed with a regex object", f, "a", lpcre.new("a"), 1, "i")
        assertError("invalid flags", f, "a", "a", 1, nil, flags.UNSET_FALSE)
        assertError("partial matching is not supported", f, "a", "a", 1, nil, 0x10)
        assertError("bad argument #3", f, "a", "a", "x")
        assertError("match failed: UTF-8 error", f, "a\255", "a", 1, "u")
    end
    local re = lpcre.new("a")
    for _, m in ipairs { "test", "matchpos", "findmatch" } do
        assertError("string or carray expected, got boolean", re[m], re, true)
        assertError("lpcre.regex expected", re[m], "a", "a")
        assertError("partial matching is not supported", re[m], re, "a", 1, 0x20)
    end
end
PRINT("==================================================================================")
print("OK.")
