local lpcre = require("lpcre")

local format = string.format
local flags  = lpcre.flags

local function PRINT(s)
    print(s.." ("..debug.getinfo(2).currentline..")")
end
local function nlist(...)
    local rslt = {}
    rslt.n = select("#", ...)
    for i = 1, rslt.n do
        rslt[i] = select(i, ...)
    end
    return rslt
end
local function assertNlistEqual(a, b, what)
    assert(a.n == b.n, format("%s: count %d <> %d", what, a.n, b.n))
    for i = 1, a.n do
        assert(a[i] == b[i], format("%s: [%d] %s <> %s", what, i, tostring(a[i]), tostring(b[i])))
    end
end
local function assertResults(expected, ...)
    assertNlistEqual(nlist(...), expected, "results")
end
local function res(f, ...)
    local r = nlist(pcall(f, ...))
    if not r[1] then
        return { n = 1, (r[2]:gsub("^.-: ", "")) }
    end
    return r
end
local function assertError(pattern, f, ...)
    local ok, err = pcall(f, ...)
    assert(not ok, "error expected")
    assert(tostring(err):find(pattern, 1, true), format("unexpected error message: %s", tostring(err)))
end

local ok, carray = pcall(require, "carray")
if not ok then
    print("carray module not available: test skipped")
    return
end

local function newC(s, t)
    return carray.new(t or "char"):append(s)
end

PRINT("==================================================================================")
do
    -- string and carray subjects give identical results
    local subjects = {
        "", "a", "hello world", "a\0b\0\0c", "aaa bbb aaa", "x = 1, y = 22, z = 333",
        "äöü Grüße", "line1\nline2\r\nline3",
    }
    local patterns = {
        { "l+" }, { "o" }, { "" }, { "x*" }, { "(\\w+) = (\\d+)" }, { "(a)|(b)" },
        { "\\0+" }, { "^line\\d$", "m" }, { "." , "u" }, { "(?<w>\\w)(\\w)?" }, { "A+", "i" },
        { "\\w+", flags.UTF + flags.UCP }, { "(x)?" },
    }
    local n = 0
    for _, s in ipairs(subjects) do
        for _, pf in ipairs(patterns) do
            local p, cf = pf[1], pf[2]
            local c = newC(s)
            do
                local what = format("%q %q", s, p)
                for init = -3, #s + 2 do
                    -- (with UTF an init inside a character is an error for both)
                    assertNlistEqual(res(lpcre.find, s, p, init, cf), res(lpcre.find, c, p, init, cf), "find "..what)
                    assertNlistEqual(res(lpcre.match, s, p, init, cf), res(lpcre.match, c, p, init, cf), "match "..what)
                    assertNlistEqual(res(lpcre.count, s, p, init, cf), res(lpcre.count, c, p, init, cf), "count "..what)
                    assertNlistEqual(res(lpcre.test, s, p, init, cf), res(lpcre.test, c, p, init, cf), "test "..what)
                    assertNlistEqual(res(lpcre.matchpos, s, p, init, cf), res(lpcre.matchpos, c, p, init, cf), "matchpos "..what)
                    assertNlistEqual(res(lpcre.findmatch, s, p, init, cf), res(lpcre.findmatch, c, p, init, cf), "findmatch "..what)
                end
                local s1, e1, t1 = lpcre.new(p, cf):exec(s)
                local s2, e2, t2 = lpcre.new(p, cf):exec(c)
                assert(s1 == s2 and e1 == e2, "exec "..what)
                if t1 then
                    for k, v in pairs(t1) do assert(t2[k] == v, "exec "..what) end
                    for k, v in pairs(t2) do assert(t1[k] == v, "exec "..what) end
                end
                local g1, g2 = {}, {}
                for a, b in lpcre.gmatch(s, p, 1, cf) do g1[#g1 + 1] = tostring(a).."|"..tostring(b) end
                for a, b in lpcre.gmatch(c, p, 1, cf) do g2[#g2 + 1] = tostring(a).."|"..tostring(b) end
                assert(table.concat(g1, ",") == table.concat(g2, ","), "gmatch "..what)
                g1, g2 = {}, {}
                for a, b in lpcre.split(s, p, 1, cf) do g1[#g1 + 1] = tostring(a).."|"..tostring(b) end
                for a, b in lpcre.split(c, p, 1, cf) do g2[#g2 + 1] = tostring(a).."|"..tostring(b) end
                assert(table.concat(g1, ",") == table.concat(g2, ","), "split "..what)
                for _, repl in ipairs { "<%0>", function(x) return x and x:upper() end, { a = "A", o = 0 } } do
                    local r1, n1 = lpcre.gsub(s, p, repl, nil, cf)
                    local c2 = newC(s)
                    local r2, n2 = lpcre.gsub(c2, p, repl, nil, cf)
                    assert(r2 == c2 and n1 == n2 and r1 == c2:tostring(), "gsub "..what)
                    local r3, n3 = lpcre.gsub(s, p, repl, 1, cf)
                    local c3 = newC(s)
                    local _, n4 = lpcre.gsub(c3, p, repl, 1, cf)
                    assert(n3 == n4 and r3 == c3:tostring(), "gsub n "..what)
                end
                n = n + 1
            end
        end
    end
    PRINT(format("%d subject/pattern combinations compared", n))
end
PRINT("==================================================================================")
do
    -- element types
    assert(lpcre.find(newC("abc", "uchar"), "b") == 2)
    assert(lpcre.find(newC("abc", "schar"), "b") == 2)
    assert(lpcre.find(newC("abc", "uint8"), "b") == 2)
    assertError("carray elements must be 1 byte in size", lpcre.find, carray.new("int", 3), "a")
    assertError("carray elements must be 1 byte in size", lpcre.find, carray.new("double", 3), "a")
    -- empty carray
    local e = carray.new("char")
    assert(lpcre.find(e, "") == 1)
    assert(lpcre.find(e, "a") == nil)
    assert(lpcre.count(e, "x*") == 1)
    local r, n = lpcre.gsub(e, "^", "start")
    assert(r == e and n == 1 and e:tostring() == "start")
    -- captures from a carray are strings
    local a, b = lpcre.match(newC("key=value"), "(\\w+)=(\\w+)")
    assert(type(a) == "string" and a == "key" and b == "value")
    -- test, matchpos, findmatch on a carray: results as for a string
    local c = newC("a\0b=12\0")
    assert(lpcre.test(c, "\\0b") == true and lpcre.test(c, "x") == false)
    assert(lpcre.test(c, "a", 2) == false and lpcre.new("\\d+"):test(c, -3) == true)
    assertResults({ n = 3, "b", "12", 6 }, lpcre.matchpos(c, "(\\w)=(\\d+)"))
    assertResults({ n = 2, true, 3 }, lpcre.new("\\0b"):matchpos(c))
    assertResults({ n = 4, 3, 6, "b=12", "12" }, lpcre.findmatch(c, "\\w=(\\d+)"))
    local m = select(3, lpcre.findmatch(c, "\\d+\\0"))
    assert(type(m) == "string" and m == "12\0")
    e = carray.new("char")
    assert(lpcre.test(e, "") == true and lpcre.test(e, "a") == false)
    assertResults({ n = 2, true, 0 }, lpcre.matchpos(e, ""))
    assertResults({ n = 3, 1, 0, "" }, lpcre.findmatch(e, ""))
    assertError("carray elements must be 1 byte in size", lpcre.test, carray.new("int", 3), "a")
    assertError("carray elements must be 1 byte in size", lpcre.matchpos, carray.new("int", 3), "a")
    assertError("carray elements must be 1 byte in size", lpcre.findmatch, carray.new("int", 3), "a")
end
PRINT("==================================================================================")
do
    -- in-place gsub
    local c = newC("hello world")
    local r, n = lpcre.gsub(c, "o", "0")
    assert(r == c and n == 2 and c:tostring() == "hell0 w0rld")
    -- grow
    r, n = c:len(), nil
    _, n = lpcre.gsub(c, "l", "LLL")
    assert(n == 3 and c:tostring() == "heLLLLLL0 w0rLLLd")
    -- shrink
    _, n = lpcre.gsub(c, "L+", "")
    assert(n == 2 and c:tostring() == "he0 w0rd")
    -- no match: unchanged
    _, n = lpcre.gsub(c, "zzz", "")
    assert(n == 0 and c:tostring() == "he0 w0rd")
    -- remove everything
    _, n = lpcre.gsub(c, ".", "")
    assert(n == 8 and c:len() == 0)
    -- function and table replacements, regex method
    c = newC("a1 b22 c333")
    local re = lpcre.new("(\\d+)")
    _, n = re:gsub(c, function(d) return "#"..#d end)
    assert(n == 3 and c:tostring() == "a#1 b#2 c#3")
    _, n = lpcre.gsub(c, "(\\w)#", { a = "A", c = "C" })
    assert(n == 3 and c:tostring() == "A1 b#2 C3")
    -- max count
    _, n = lpcre.gsub(c, "\\d", "x", 2)
    assert(n == 2 and c:tostring() == "Ax b#x C3")
    -- a replacement function that resizes the carray is an error
    c = newC("aaa")
    assertError("carray subject was resized during gsub", lpcre.gsub, c, "a", function()
        c:append("x")
        return "b"
    end)
    -- a replacement function may read the carray
    c = newC("abc")
    _, n = lpcre.gsub(c, "\\w", function(x) return x..c:len() end)
    assert(n == 3 and c:tostring() == "a3b3c3")
end
PRINT("==================================================================================")
do
    -- gmatch on a carray sees changes between iterations
    local c = newC("a1a2a3")
    local seen = {}
    for d in lpcre.gmatch(c, "\\d") do
        seen[#seen + 1] = d
        if d == "1" then
            c:set(4, "9")     -- replaces the "2" before it is reached
        end
    end
    assert(table.concat(seen) == "193")
    -- shrinking during iteration ends it
    c = newC("a1a2a3")
    seen = {}
    for d in lpcre.gmatch(c, "\\d") do
        seen[#seen + 1] = d
        c:setlen(1)
    end
    assert(table.concat(seen) == "1")
end
PRINT("==================================================================================")
do
    -- large subject (1 MB): carray is matched in place, without copying
    local unit  = string.rep("x", 1013).."k=12345;"
    local s     = string.rep(unit, math.floor(1024 * 1024 / #unit))
    local c     = newC(s)
    assert(c:len() == #s and #s > 1000000)
    local re    = lpcre.new("k=(\\d+);")
    local nMatches = re:count(s)
    assert(nMatches == re:count(c) and nMatches > 1000)

    -- a match at the end of the subject costs the same, independent of its size:
    -- no copy of the 1 MB buffer per call
    local t0 = os.clock()
    for _ = 1, 20000 do
        assert(re:find(c, -8) == #s - 7)
    end
    local tC = os.clock() - t0
    PRINT(format("20000 x find at end of 1 MB carray: %.3f s", tC))
    assert(tC < 1.0, "carray subject seems to be copied")

    -- full scan: carray must not be slower than string
    local function timeIt(subj)
        local best = math.huge
        for _ = 1, 5 do
            local t = os.clock()
            local n = 0
            for _ in re:gmatch(subj) do n = n + 1 end
            assert(n == nMatches)
            best = math.min(best, os.clock() - t)
        end
        return best
    end
    local tStr = timeIt(s)
    local tCa  = timeIt(c)
    PRINT(format("gmatch over 1 MB with %d matches: string %.4f s, carray %.4f s", nMatches, tStr, tCa))
    assert(tCa <= tStr * 1.5 + 0.002, "carray match slower than string match")
end
PRINT("==================================================================================")
do
    -- gsub that empties a non-empty carray: the Carray C API's resizeCarray()
    -- returns NULL for a new length of 0, success must be detected otherwise
    local content = string.rep("0123456789abcdef", 64)   -- 1 KB
    local c = newC(content)
    assert(c:len() == 1024)
    local r, n = lpcre.gsub(c, ".*", "")
    assert(r == c and n == 1 and c:len() == 0, "carray not emptied by gsub")
    -- the empty carray still works as subject
    assert(lpcre.find(c, "") == 1)
    assert(lpcre.find(c, "a") == nil)
    assert(lpcre.count(c, "x*") == 1)
    assert(lpcre.count(c, "a") == 0)
    r, n = lpcre.gsub(c, "a", "b")
    assert(r == c and n == 0 and c:len() == 0)
    -- grows again by an empty match on the empty subject
    r, n = lpcre.gsub(c, "^", "hello")
    assert(r == c and n == 1 and c:tostring() == "hello")
    r, n = lpcre.gsub(c, "", "-")
    assert(r == c and n == 6 and c:tostring() == "-h-e-l-l-o-")
    -- byte by byte
    c = newC(content)
    r, n = lpcre.gsub(c, ".", "")
    assert(r == c and n == 1024 and c:len() == 0)
    r, n = lpcre.gsub(c, "", "longer replacement")
    assert(r == c and n == 1 and c:tostring() == "longer replacement")
    -- replacement function that removes everything
    c = newC("abc")
    r, n = lpcre.gsub(c, "\\w", function() return "" end)
    assert(r == c and n == 3 and c:len() == 0)
    -- empty carray as input, result empty
    c = carray.new("char")
    r, n = lpcre.gsub(c, ".*", "")
    assert(r == c and n == 1 and c:len() == 0)
    r, n = lpcre.gsub(c, "x", "y")
    assert(r == c and n == 0 and c:len() == 0)
    -- a replacement function that makes a UTF-8 carray invalid: the content
    -- is checked again before the next match (no NO_UTF_CHECK on changed data)
    c = newC("a\195\164b")   -- "aäb"
    assertError("match failed: UTF-8 error", lpcre.gsub, c, "a|b", function()
        c:set(2, "\255")
        return "x"
    end, nil, "u")
end
PRINT("==================================================================================")
do
    -- read-only and non-resizable carrays (made through the Carray C API by the
    -- test helper module tests/testcarray.c)
    local okTc, tc = pcall(require, "lpcre_testcarray")
    if not okTc then
        print("lpcre_testcarray module not available: test skipped")
    else
        local content = string.rep("x", 1024)
        local ro = tc.readonly(content)
        assert(lpcre.find(ro, "x") == 1 and lpcre.count(ro, "x") == 1024)
        assertError("carray is not writable", lpcre.gsub, ro, ".*", "")
        assertError("carray is not writable", lpcre.gsub, ro, "x", "y")
        assert(ro:len() == 1024 and ro:tostring() == content)

        local ref = tc.ref(content)
        assert(ref:len() == 1024)
        -- same length: written in place into the referenced memory
        local r, n = lpcre.gsub(ref, "x", "y", 10)
        local expected = string.rep("y", 10)..string.rep("x", 1014)
        assert(r == ref and n == 10 and ref:tostring() == expected)
        -- length changes: a clean error, the carray keeps its content
        assertError("cannot resize carray", lpcre.gsub, ref, ".*", "")
        assert(ref:len() == 1024)
        assertError("cannot resize carray", lpcre.gsub, ref, "x", "")
        assert(ref:len() == 1024)
        assertError("cannot resize carray", lpcre.gsub, ref, "x", "xx", 1)
        assert(ref:len() == 1024 and ref:tostring() == expected)
        -- empty non-resizable carray cannot grow
        local e = tc.ref("")
        assertError("cannot resize carray", lpcre.gsub, e, "^", "abc")
        assert(e:len() == 0)
        r, n = lpcre.gsub(e, "x", "y")
        assert(r == e and n == 0)
    end
end
PRINT("==================================================================================")
print("OK.")
