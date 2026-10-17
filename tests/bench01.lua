-- Benchmark: string vs. carray subjects for a 1 MB subject with 1000 matches.
-- Optional comparison with lrexlib (rex_pcre2) if it is installed.

local lpcre = require("lpcre")

local format = string.format

local okC, carray = pcall(require, "carray")
local okR, rex    = pcall(require, "rex_pcre2")

local REPS = tonumber(arg and arg[1]) or 20

local unit = string.rep("x", 1040).."k=12345;"
local s    = string.rep(unit, 1000)..string.rep("x", 1024 * 1024 - 1000 * #unit)
assert(#s == 1024 * 1024)

local pat = "k=(\\d+);"
local re  = lpcre.new(pat)
assert(re:count(s) == 1000)

-- The variants of a group are run interleaved, REPS times each, and the best
-- time of each variant is printed (interleaving keeps CPU frequency and cache
-- effects from favouring one variant).
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
    for _, v in ipairs(group) do
        print(format("  %-46s %9.3f ms", v.name, v.best * 1000))
    end
end

print(format("lpcre %s, PCRE2 %s, Lua: %s, subject: %d bytes, %d matches, best of %d runs",
             lpcre._VERSION, lpcre.version(), _VERSION, #s, re:count(s), REPS))

local c = okC and carray.new("char"):append(s)

local function findLoop(find, subj)
    local pos, n = 1, 0
    while true do
        local _, e = find(subj, pos)
        if not e then break end
        n, pos = n + 1, e + 1
    end
    assert(n == 1000)
end

runGroup("gmatch loop:", function()
    bench("lpcre string", function()
        local n = 0
        for _ in re:gmatch(s) do n = n + 1 end
        assert(n == 1000)
    end)
    if okC then
        bench("lpcre carray", function()
            local n = 0
            for _ in re:gmatch(c) do n = n + 1 end
            assert(n == 1000)
        end)
    end
    if okR then
        local rre = rex.new(pat)
        bench("rex_pcre2 string", function()
            local n = 0
            for _ in rex.gmatch(s, rre) do n = n + 1 end
            assert(n == 1000)
        end)
        if okC then
            bench("rex_pcre2 carray:tostring() once", function()
                local n = 0
                for _ in rex.gmatch(c:tostring(), rre) do n = n + 1 end
                assert(n == 1000)
            end)
        end
    end
end)

runGroup("find loop with init (one call per match):", function()
    bench("lpcre string", function() findLoop(function(x, i) return re:find(x, i) end, s) end)
    if okC then
        bench("lpcre carray", function() findLoop(function(x, i) return re:find(x, i) end, c) end)
    end
    if okR then
        local rre = rex.new(pat)
        bench("rex_pcre2 string", function() findLoop(function(x, i) return rex.find(x, rre, i) end, s) end)
        if okC then
            bench("rex_pcre2 carray:tostring() per call", function()
                findLoop(function(x, i) return rex.find(x:tostring(), rre, i) end, c)
            end)
        end
    end
end)

runGroup("gsub (1000 replacements):", function()
    bench("lpcre string", function()
        local _, n = re:gsub(s, "K=%1;")
        assert(n == 1000)
    end)
    if okC then
        bench("lpcre carray in place", function()
            local _, n = re:gsub(c, "k=%1;")
            assert(n == 1000)
        end)
    end
    if okR then
        local rre = rex.new(pat)
        bench("rex_pcre2 string", function()
            local _, n = rex.gsub(s, rre, "K=%1;")
            assert(n == 1000)
        end)
    end
end)

runGroup("count:", function()
    bench("lpcre string", function() assert(re:count(s) == 1000) end)
    if okC then
        bench("lpcre carray", function() assert(re:count(c) == 1000) end)
    end
    if okR then
        local rre = rex.new(pat)
        bench("rex_pcre2 string", function() assert(rex.count(s, rre) == 1000) end)
    end
end)
