# lua-lpcre 
[![Licence](http://img.shields.io/badge/Licence-MIT-brightgreen.svg)](LICENSE)
[![build status](https://github.com/osch/lua-lpcre/workflows/test/badge.svg)](https://github.com/osch/lua-lpcre/actions/workflows/test.yml)
[![Install](https://img.shields.io/badge/Install-LuaRocks-brightgreen.svg)](https://luarocks.org/modules/osch/lpcre)

<!-- ---------------------------------------------------------------------------------------- -->

This [Lua] module provides [PCRE2] regular expressions with an API in the style of Lua's 
string library (`find`, `match`, `gmatch`, `gsub`). Subjects may be Lua strings or 
[carray] objects: a carray is matched directly on its buffer, without copying, and `gsub` 
modifies it in place. Compiled patterns are cached per Lua state.

   * [Documentation](./doc/README.md#lua-lpcre-documentation)

[Lua]:          https://www.lua.org
[PCRE2]:        https://www.pcre.org
[carray]:       https://github.com/osch/lua-carray

<!-- ---------------------------------------------------------------------------------------- -->

## First Example

 ```lua
local lpcre = require("lpcre")

-- like string.find: start, end and captures
local s, e, key, value = lpcre.find("width = 1024", "(\\w+)\\s*=\\s*(\\d+)")
assert(s == 1 and e == 12 and key == "width" and value == "1024")

-- like string.match: captures or the whole match, nil for groups not taking part
local a, b = lpcre.match("2026-10", "(\\d{4})-(\\d\\d)(?:-(\\d\\d))?")
assert(a == "2026" and b == "10")

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

-- regex objects are cached like pattern strings in find etc.:
-- same pattern and flags, same object; "n" (NOCACHE) compiles a new one
local re = lpcre.new("(\\d+)")
assert(re == lpcre.new("(\\d+)"))
assert(lpcre.new("(\\d+)", "n") ~= lpcre.new("(\\d+)", "n"))
assert(re:match("abc 42") == "42")

-- carray subjects are matched without copying, gsub works in place
local carray = require("carray")
local buf = carray.new("char"):append("a1 b22 c333")
assert(re:match(buf) == "1")
local r, n = re:gsub(buf, "<%1>")
assert(r == buf and n == 3)
assert(buf:tostring() == "a<1> b<22> c<333>")
```

<!-- ---------------------------------------------------------------------------------------- -->

## Installation

```
luarocks install lpcre
```

lpcre needs the 8-bit library of PCRE2 (*libpcre2-8*) and works with Lua 5.1 up to 5.5 and
LuaJIT; [carray] is optional. For building from source and PCRE2 in non-standard 
locations see [Building](./doc/README.md#building).

<!-- ---------------------------------------------------------------------------------------- -->
