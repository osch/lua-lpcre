local lpcre = require("lpcre")

-- like string.find: start, end and captures
local s, e, key, value = lpcre.find("width = 1024", "(\\w+)\\s*=\\s*(\\d+)")
assert(s == 1 and e == 12 and key == "width" and value == "1024")

-- like string.match: captures or the whole match, nil for groups not taking part
local a, b = lpcre.match("2026-10", "(\\d{4})-(\\d\\d)(?:-(\\d\\d))?")
assert(a == "2026" and b == "10")
assert(select("#", lpcre.match("2026-10", "(\\d{4})-(\\d\\d)(?:-(\\d\\d))?")) == 3)

-- like string.gmatch
local words = {}
for w in lpcre.gmatch("one, two; three", "\\w+") do
    words[#words + 1] = w
end
assert(table.concat(words, " ") == "one two three")

-- like string.gsub: replacement string, table or function
assert(lpcre.gsub("hello world", "(\\w+) (\\w+)", "%2 %1") == "world hello")
assert(lpcre.gsub("$a + $b", "\\$(\\w+)", { a = 1, b = 2 }) == "1 + 2")
assert(lpcre.gsub("abc", "\\w", string.upper) == "ABC")

-- test: only true/false; matchpos: captures followed by the end position
assert(lpcre.test("width = 1024", "\\d+") == true)
local num, e = lpcre.matchpos("a1 b22", "(\\d+)", 3)
assert(num == "22" and e == 6)

-- flags as letters or numbers
assert(lpcre.match("Hello", "hello", 1, "i") == "Hello")
assert(lpcre.match("Hello", "hello", 1, lpcre.flags.CASELESS) == "Hello")

-- compiled pattern objects are cached (as pattern strings in find etc.):
-- same pattern and flags, same object; "n" (NOCACHE) compiles a new one
local re = lpcre.new("(\\d+)")
assert(re == lpcre.new("(\\d+)"))
assert(lpcre.new("(\\d+)", "n") ~= lpcre.new("(\\d+)", "n"))
assert(re:match("abc 42") == "42")

-- carray subjects are matched without copying, gsub works in place
local ok, carray = pcall(require, "carray")
if ok then
    local buf = carray.new("char"):append("a1 b22 c333")
    assert(re:match(buf) == "1")
    local r, n = re:gsub(buf, "<%1>")
    assert(r == buf and n == 3)
    assert(buf:tostring() == "a<1> b<22> c<333>")
end

print("OK.")
