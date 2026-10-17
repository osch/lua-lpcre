-- Benchmark: per-call cost of the single-match functions on short subjects,
-- 1 million calls per variant, string and carray subjects. Compares
-- lpcre.test/matchpos/findmatch with the same results built from
-- lpcre.find/match in Lua (the way a wrapper had to do it before).

local lpcre = require("lpcre")

local format = string.format
local sub    = string.sub
local select = select
local unpack = table.unpack or unpack

local okC, carray = pcall(require, "carray")

local N    = tonumber(arg and arg[1]) or 1000000
local REPS = tonumber(arg and arg[2]) or 5

local find, match, test     = lpcre.find, lpcre.match, lpcre.test
local matchpos, findmatch   = lpcre.matchpos, lpcre.findmatch

-- The variants of a group are run interleaved, REPS times each, and the best
-- time of each variant is printed.
local group
local function bench(name, f)
    group[#group + 1] = { name = name, f = f, best = math.huge }
end
local function runGroup(title, fill)
    group = {}
    fill()
    print(title)
    for _, v in ipairs(group) do v.f() end -- warm up
    for _ = 1, REPS do
        for _, v in ipairs(group) do
            local t0 = os.clock()
            v.f()
            v.best = math.min(v.best, os.clock() - t0)
        end
    end
    local base = group[1].best
    for _, v in ipairs(group) do
        print(format("  %-44s %7.1f ns/call  %6.1f %%", v.name, v.best / N * 1e9,
                     (v.best / base - 1) * 100))
    end
end

print(format("lpcre %s, PCRE2 %s, %s, %d calls per variant, best of %d",
             lpcre._VERSION, lpcre.version(), _VERSION, N, REPS))

-- what a Lua wrapper had to do to get "captures..., end" out of find
local function capsThenEnd(st, en, ...)
    if not st then return nil end
    local ncap = select("#", ...)
    if ncap == 0 then return true, en end
    if ncap == 1 then return (...), en end
    local ret = { ... }
    ret[ncap + 1] = en
    return unpack(ret, 1, ncap + 1)
end
local function boolOf(st) return st ~= nil end

local subjects = { { "string", "Canon EOS 5D Mark II, firmware 1.0.7" } }
if okC then
    subjects[2] = { "carray", carray.new("char"):append(subjects[1][2]) }
end

for _, sj in ipairs(subjects) do
    local kind, s = sj[1], sj[2]

    runGroup(format("(a) boolean, no groups, match [%s]:", kind), function()
        local p = "Mark\\s+II"
        bench("find -> st ~= nil (Lua wrapper)",  function() for _ = 1, N do boolOf(find(s, p)) end end)
        bench("find (results unused)",            function() for _ = 1, N do find(s, p) end end)
        bench("test",                             function() for _ = 1, N do test(s, p) end end)
    end)

    runGroup(format("(a) boolean, 2 groups, no match [%s]:", kind), function()
        local p = "(Nikon)\\s+(\\w+)"
        bench("find -> st ~= nil (Lua wrapper)",  function() for _ = 1, N do boolOf(find(s, p)) end end)
        bench("test",                             function() for _ = 1, N do test(s, p) end end)
    end)

    runGroup(format("(a) boolean, 2 groups, match [%s]:", kind), function()
        local p = "(\\d+)D\\s+(\\w+)"
        bench("find -> st ~= nil (Lua wrapper)",  function() for _ = 1, N do boolOf(find(s, p)) end end)
        bench("test",                             function() for _ = 1, N do test(s, p) end end)
    end)

    runGroup(format("(b) captures + end, 2 groups [%s]:", kind), function()
        local p = "(\\d+)D\\s+(\\w+)"
        assert(select("#", capsThenEnd(find(s, p))) == 3)
        bench("find -> caps..., e (Lua wrapper)", function() for _ = 1, N do capsThenEnd(find(s, p)) end end)
        bench("match (captures only, reference)", function() for _ = 1, N do match(s, p) end end)
        bench("matchpos",                         function() for _ = 1, N do matchpos(s, p) end end)
    end)

    runGroup(format("(b) captures + end, 1 group [%s]:", kind), function()
        local p = "firmware ([\\d.]+)"
        bench("find -> cap, e (Lua wrapper)",     function() for _ = 1, N do capsThenEnd(find(s, p)) end end)
        bench("matchpos",                         function() for _ = 1, N do matchpos(s, p) end end)
    end)

    runGroup(format("(b) true + end, no groups [%s]:", kind), function()
        local p = "EOS"
        bench("find -> true, e (Lua wrapper)",    function() for _ = 1, N do capsThenEnd(find(s, p)) end end)
        bench("matchpos",                         function() for _ = 1, N do matchpos(s, p) end end)
    end)

    runGroup(format("(c) bounds + whole match + captures [%s]:", kind), function()
        local p = "(\\d+)D\\s+(\\w+)"
        local tostr = (kind == "string") and sub or function(c, i, j) return c:tostring(i, j) end
        local function withWhole(st, en, ...)
            if not st then return nil end
            return st, en, tostr(s, st, en), ...
        end
        bench("find + sub (Lua wrapper)",         function() for _ = 1, N do withWhole(find(s, p)) end end)
        bench("findmatch",                        function() for _ = 1, N do findmatch(s, p) end end)
    end)
end
