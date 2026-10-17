-- lpcre in several independent Lua states of the same process, also used
-- from parallel OS threads: lpcre keeps all its state (pattern cache, carray
-- C API cache) per Lua state and has no global mutable data.
-- Needs the test helper module lpcre_multistate (tests/multistate.c).

local lpcre = require("lpcre")

local format = string.format

local function PRINT(s)
    print(s.." ("..debug.getinfo(2).currentline..")")
end

local ok, ms = pcall(require, "lpcre_multistate")
if not ok then
    print("test helper lpcre_multistate not available: test skipped")
    return
end
local hasCarray = pcall(require, "carray")

PRINT("==================================================================================")
local A = ms.new()
local B = ms.new()
do
    local init = [[
        lpcre = require("lpcre")
        hasCarray, carray = pcall(require, "carray")
        return lpcre._VERSION
    ]]
    assert(A:run(init) == lpcre._VERSION)
    assert(B:run(init) == lpcre._VERSION)

    -- pattern cache: patterns compiled in A are not visible in B
    assert(A:run([[ for i = 1, 10 do lpcre.find("x", "pattern"..i) end
                    return select(2, lpcre.cache()) ]]) == 10)
    assert(B:run([[ return select(2, lpcre.cache()) ]]) == 0)
    assert(B:run([[ lpcre.cache(5) return lpcre.cache() ]]) == 5)
    assert(A:run([[ return lpcre.cache() ]]) == 256)
    assert(A:run([[ return select(2, lpcre.cache()) ]]) == 10)
end
PRINT("==================================================================================")
do
    -- interleaved use: an iterator in A stays valid while B matches
    A:run([[ it = lpcre.gmatch("a1b2c3", "\\d") ]])
    B:run([[ it = lpcre.gmatch("x7y8z9", "\\d") ]])
    local seq = {}
    for _ = 1, 3 do
        seq[#seq + 1] = A:run("return it()")
        seq[#seq + 1] = B:run("return it()")
    end
    assert(table.concat(seq) == "172839")
    assert(A:run("return it()") == nil and B:run("return it()") == nil)

    if hasCarray then
        local code = [[
            local c = carray.new("char"):append(...)
            local r, n = lpcre.gsub(c, "(\\d+)", "<%1>")
            assert(r == c)
            return c:tostring(), n
        ]]
        local a, n = A:run("return (function(...) "..code.." end)('a1 b22')")
        local b, m = B:run("return (function(...) "..code.." end)('x333')")
        assert(a == "a<1> b<22>" and n == 2)
        assert(b == "x<333>" and m == 1)
    end
end
PRINT("==================================================================================")
do
    -- parallel threads: both states match, gsub and churn their pattern
    -- caches at the same time
    local work = [[
        local tag = %q
        local s = string.rep(string.rep("x", 1000) .. "k=12345;", 1000)
        local sum = 0
        for round = 1, 20 do
            sum = sum + lpcre.count(s, "k=(\\d+);")
            for i = 1, 50 do        -- more patterns than the cache holds in B
                assert(lpcre.find(tag..i, "^"..tag..i.."$") == 1)
            end
            if hasCarray then
                local c = carray.new("char"):append(s)
                local _, n = lpcre.gsub(c, "k=(\\d+);", "%%1")
                assert(n == 1000 and c:len() == #s - 3000)
                sum = sum + lpcre.count(c, "12345")
            else
                sum = sum + 1000
            end
        end
        return tag .. ":" .. sum .. ":" .. select(2, lpcre.cache())
    ]]
    local t0 = os.clock()
    local ra, rb = ms.parallel(A, format(work, "A"), B, format(work, "B"))
    PRINT(format("parallel: %s / %s (%.2f s cpu)", ra, rb, os.clock() - t0))
    -- A's cache: 10 patterns from above, "\d" and (with carray) "(\d+)" from the
    -- interleaved test, "k=(\d+);", (with carray) "12345" and the 50 tag patterns
    local expectedA = 10 + 1 + 1 + 50 + (hasCarray and 2 or 0)
    assert(ra == "A:40000:" .. expectedA, ra)
    assert(rb == "B:40000:5")
end
PRINT("==================================================================================")
do
    -- closing A does not affect B
    A:close()
    assert(not pcall(A.run, A, "return 1"))
    collectgarbage()
    assert(B:run([[ return lpcre.match("key=value", "(\\w+)=(\\w+)") ]]) == "key")
    assert(B:run([[ return select(2, lpcre.gsub("abc", "b", "B")) ]]) == 1)
    assert(B:run([[ lpcre.cache(256) return lpcre.new("q") == lpcre.new("q")
                    and lpcre.new("q", "n") ~= lpcre.new("q", "n") ]]) == true)
    if hasCarray then
        assert(B:run([[ local c = carray.new("char"):append("abc")
                        lpcre.gsub(c, "b", "BBB", 1)
                        return c:tostring() ]]) == "aBBBc")
    end
    B:close()
    -- and the main state still works
    assert(lpcre.find("hello", "l+") == 3)
end
PRINT("==================================================================================")
print("OK.")
