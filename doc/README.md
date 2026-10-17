# lua-lpcre Documentation
<!-- ---------------------------------------------------------------------------------------- -->
##   Contents
<!-- ---------------------------------------------------------------------------------------- -->

   * [Overview](#overview)
   * [Subjects](#subjects)
   * [Positions](#positions)
   * [Module Functions](#module-functions)
        * [lpcre.new()](#lpcre_new)
        * [lpcre.find()](#lpcre_find)
        * [lpcre.match()](#lpcre_match)
        * [lpcre.test()](#lpcre_test)
        * [lpcre.matchpos()](#lpcre_matchpos)
        * [lpcre.findmatch()](#lpcre_findmatch)
        * [lpcre.gmatch()](#lpcre_gmatch)
        * [lpcre.gsub()](#lpcre_gsub)
        * [lpcre.count()](#lpcre_count)
        * [lpcre.split()](#lpcre_split)
        * [lpcre.cache()](#lpcre_cache)
        * [lpcre.flags](#lpcre_flags)
        * [lpcre.version()](#lpcre_version)
        * [lpcre.config()](#lpcre_config)
   * [Regex Methods](#regex-methods)
        * [regex:find()](#regex_find)
        * [regex:match()](#regex_match)
        * [regex:exec()](#regex_exec)
        * [regex:test()](#regex_test)
        * [regex:matchpos()](#regex_matchpos)
        * [regex:findmatch()](#regex_findmatch)
        * [regex:gmatch()](#regex_gmatch)
        * [regex:gsub()](#regex_gsub)
        * [regex:count()](#regex_count)
        * [regex:split()](#regex_split)
        * [regex:ncapt()](#regex_ncapt)
        * [regex:jit()](#regex_jit)
   * [Flags](#flags)
        * [Compile flags](#compile_flags)
        * [Execution flags](#execution_flags)
   * [Replacements](#replacements)
   * [Empty Matches](#empty-matches)
   * [Errors](#errors)
   * [Pattern Cache](#pattern-cache)
   * [Thread safety / multiple Lua states](#thread-safety--multiple-lua-states)
   * [Building](#building)
   * [Migration from lrexlib-pcre2](#migration-from-lrexlib-pcre2)

<!-- ---------------------------------------------------------------------------------------- -->
##   Overview
<!-- ---------------------------------------------------------------------------------------- -->

The [Lua] module *lpcre* provides [PCRE2] regular expressions with an API in the style of 
Lua's string library: [lpcre.find()](#lpcre_find), [lpcre.match()](#lpcre_match), 
[lpcre.gmatch()](#lpcre_gmatch) and [lpcre.gsub()](#lpcre_gsub) take the same arguments
and return the same kind of results as *string.find*, *string.match*, *string.gmatch* and 
*string.gsub*, but the pattern is a PCRE2 regular expression.

In addition:

  * The subject may be a Lua string or a [carray] object. A carray is matched directly
    on its buffer, without copying, and [lpcre.gsub()](#lpcre_gsub) modifies a carray 
    subject in place, see [Subjects](#subjects).
  * Compiled patterns are kept in a [cache](#pattern-cache): a pattern is compiled only
    once, whether it is given as string to the module functions or to 
    [lpcre.new()](#lpcre_new).
  * The regex objects of [lpcre.new()](#lpcre_new) have the module functions as 
    [methods](#regex-methods), without the arguments *pattern* and *cf*: 
    *re:gsub(s, repl)* is *lpcre.gsub(s, re, repl)*. The subject is always the first
    argument.

The module name to require is *"lpcre"*:

```lua
local lpcre = require("lpcre")
```

This module needs the 8-bit library of PCRE2 (*libpcre2-8*). It works with Lua 5.1 up to
5.5 and LuaJIT. The [carray] module is optional: lpcre neither links against it nor 
requires it, carray objects are recognized through the [Carray C API].

[Lua]:          https://www.lua.org
[PCRE2]:        https://www.pcre.org
[carray]:       https://github.com/osch/lua-carray
[Carray C API]: https://github.com/lua-capis/lua-carray-capi

<!-- ---------------------------------------------------------------------------------------- -->
##   Subjects
<!-- ---------------------------------------------------------------------------------------- -->

The subject is the data a pattern is matched against. It may be

  * a Lua string (a number is converted to a string, as in the string library), or
  * a carray object with elements of 1 byte size (element types *"char"*, *"uchar"*, 
    *"schar"*, *"int8"*, *"uint8"*). Other element types raise an error.

Subjects may contain arbitrary binary data including NUL bytes. Captures and all other 
results are returned as Lua strings, also for a carray subject.

For a carray, pointer and length of its buffer are obtained through the Carray C API on
each call, so the match always sees the current content. The iterators of 
[lpcre.gmatch()](#lpcre_gmatch) and [lpcre.split()](#lpcre_split) do this on each 
iteration and therefore see changes of the carray between iterations.

[lpcre.gsub()](#lpcre_gsub) with a carray subject always works in place: the carray is
modified and returned, no new string is created. To replace only the first match, give 
the maximum count 1: *lpcre.gsub(subject, pattern, repl, 1)*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Positions
<!-- ---------------------------------------------------------------------------------------- -->

All positions are 1-based byte positions, as in Lua's string library: the end position of
a match is inclusive, an empty match at position *p* is reported as start *p* and end *p-1*.

The optional argument *init* gives the position where the search starts (default 1). A
negative *init* counts from the end of the subject (*-1* is the last byte). An *init* of 0
or less than *-len* is treated as 1. If *init* is greater than *len + 1*, nothing can 
match: *find*, *match*, *matchpos*, *findmatch* and *exec* return *nil*, *test* returns
*false*, *gmatch* ends at once, *count* returns 0 and *split* returns one empty string.

The whole subject is always passed to PCRE2, so lookbehind assertions can see the bytes 
before *init*, but *^* only matches at the beginning of the subject (or, with the flag 
*MULTILINE*, after a newline).

<!-- ---------------------------------------------------------------------------------------- -->
##   Module Functions
<!-- ---------------------------------------------------------------------------------------- -->

The argument *pattern* of the module functions is a pattern string or a regex object 
created by [lpcre.new()](#lpcre_new):

  * A pattern string is compiled with the compile flags *cf* through the 
    [pattern cache](#pattern-cache). The flag *NOCACHE* is not allowed here.
  * A regex object already carries its compile flags: *cf* must be *nil* or absent,
    otherwise an error is raised. To give execution flags together with a regex object,
    pass *nil* for *cf*, or use the [method](#regex-methods) of the regex object, which
    has no *cf* argument: *lpcre.gsub(s, re, repl, n, nil, ef)* is *re:gsub(s, repl, n, ef)*.

*cf* (compile flags) and *ef* (execution flags) are optional, see [Flags](#flags).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_new">**`lpcre.new(pattern[, cf])
  `**</span>
  
  Compiles a pattern and returns a regex object, see [Regex Methods](#regex-methods).
  
  * *pattern* - string, a PCRE2 regular expression. May contain NUL bytes. Unlike 
                subjects, numbers are not converted.
  * *cf*      - optional compile flags, number or string, see [Compile flags](#compile_flags).
  
  The regex object is taken from the [pattern cache](#pattern-cache), or the pattern is 
  compiled and put into the cache: two calls with the same pattern and flags give the same
  object, as long as it was not evicted from the cache.

  With the flag *NOCACHE* (*"n"*) the pattern is always compiled and a new regex object 
  is returned, the cache is not used.
  
  Raises an error if the pattern cannot be compiled.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_find">**`lpcre.find(subject, pattern[, init[, cf[, ef]]])
  `**</span>
  
  Looks for the first match of *pattern* in *subject*, like *string.find*. Returns
  start and end position of the match followed by all captures, or *nil* if there is
  no match. Captures of groups that did not take part in the match are *nil* (*false*
  with the flag [UNSET_FALSE](#compile_flags)).

  * *subject* - string or carray, see [Subjects](#subjects).
  * *pattern* - pattern string or regex object, see above.
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *cf*      - optional [compile flags](#compile_flags) for a pattern string; must be
                *nil* or absent for a regex object.
  * *ef*      - optional [execution flags](#execution_flags).

  ```lua
  lpcre.find("hello world", "o (w)")   --> 5, 7, "w"
  lpcre.find("hello", "(x)?l")         --> 3, 3, nil
  ```

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_match">**`lpcre.match(subject, pattern[, init[, cf[, ef]]])
  `**</span>
  
  Looks for the first match of *pattern* in *subject*, like *string.match*. Returns the 
  captures, or the whole match if the pattern has no capture groups, or *nil* if there
  is no match.

  * *subject* - string or carray, see [Subjects](#subjects).
  * *pattern* - pattern string or regex object, see above.
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *cf*      - optional [compile flags](#compile_flags) for a pattern string; must be
                *nil* or absent for a regex object.
  * *ef*      - optional [execution flags](#execution_flags).

  ```lua
  lpcre.match("key=value", "(\\w+)=(\\w+)")   --> "key", "value"
  lpcre.match("hello", "l+")                 --> "ll"
  ```

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_test">**`lpcre.test(subject, pattern[, init[, cf[, ef]]])
  `**</span>
  
  Returns *true* if *pattern* matches *subject*, otherwise *false*. Nothing else is 
  returned, also for patterns with capture groups: no captures are extracted and no
  position is converted, so this is the fastest way to ask whether there is a match.

  * *subject* - string or carray, see [Subjects](#subjects).
  * *pattern* - pattern string or regex object, see above.
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *cf*      - optional [compile flags](#compile_flags) for a pattern string; must be
                *nil* or absent for a regex object.
  * *ef*      - optional [execution flags](#execution_flags).

  ```lua
  lpcre.test("hello world", "o w")        --> true
  lpcre.test("hello", "(x)(y)")           --> false
  if lpcre.test(line, "^#") then ... end
  ```

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_matchpos">**`lpcre.matchpos(subject, pattern[, init[, cf[, ef]]])
  `**</span>
  
  Looks for the first match and returns the captures followed by the end position of the 
  match, or *nil* if there is no match. The end position is the same as the second result
  of [lpcre.find()](#lpcre_find) (inclusive; for an empty match at position *p* it is 
  *p-1*), so *e + 1* is the *init* for searching on behind the match. Captures of groups 
  that did not take part in the match are *nil* (*false* with the flag 
  [UNSET_FALSE](#compile_flags)).

  If the pattern has no capture groups, *true* takes the place of the captures (not the 
  whole match as with [lpcre.match()](#lpcre_match)), so the result is always 
  *true, e*. Use [lpcre.findmatch()](#lpcre_findmatch) to get the matched text.

  * *subject* - string or carray, see [Subjects](#subjects).
  * *pattern* - pattern string or regex object, see above.
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *cf*      - optional [compile flags](#compile_flags) for a pattern string; must be
                *nil* or absent for a regex object.
  * *ef*      - optional [execution flags](#execution_flags).

  ```lua
  lpcre.matchpos("key=value; x", "(\\w+)=(\\w+)")   --> "key", "value", 9
  lpcre.matchpos("hello", "l+")                     --> true, 4
  lpcre.matchpos("hello", "(x)?(l)")                --> nil, "l", 3

  local init = 1
  while true do
      local num, e = lpcre.matchpos(s, "(\\d+)", init)
      if not num then break end
      print(num)
      init = e + 1
  end
  ```

  Unlike *string.match* with a position capture *()*, *matchpos* needs no change of the
  pattern and returns the end of the match itself (not the position after it). For a 
  pattern whose first group may not take part in a match, test the end position, not 
  the first capture.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_findmatch">**`lpcre.findmatch(subject, pattern[, init[, cf[, ef]]])
  `**</span>
  
  Like [lpcre.find()](#lpcre_find), but with the whole match after the positions: returns 
  start and end position, the matched text and then all captures, or *nil* if there is no 
  match. Captures of groups that did not take part in the match are *nil* (*false* with 
  the flag [UNSET_FALSE](#compile_flags)).

  * *subject* - string or carray, see [Subjects](#subjects).
  * *pattern* - pattern string or regex object, see above.
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *cf*      - optional [compile flags](#compile_flags) for a pattern string; must be
                *nil* or absent for a regex object.
  * *ef*      - optional [execution flags](#execution_flags).

  ```lua
  lpcre.findmatch("key=value; x", "(\\w+)=(\\w+)")  --> 1, 9, "key=value", "key", "value"
  lpcre.findmatch("hello", "l+")                    --> 3, 4, "ll"
  ```

  For a carray subject this avoids a separate *carray:tostring(s, e)* call.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_gmatch">**`lpcre.gmatch(subject, pattern[, init[, cf[, ef]]])
  `**</span>
  
  Returns an iterator function, like *string.gmatch*. Each call returns the captures of the 
  next match (or the whole match if the pattern has no capture groups). See 
  [Empty Matches](#empty-matches) for how empty matches are handled.

  * *subject* - string or carray, see [Subjects](#subjects).
  * *pattern* - pattern string or regex object, see above.
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *cf*      - optional [compile flags](#compile_flags) for a pattern string; must be
                *nil* or absent for a regex object.
  * *ef*      - optional [execution flags](#execution_flags).

  ```lua
  for k, v in lpcre.gmatch("a=1, b=2", "(\\w+)=(\\w+)") do
      print(k, v)   --> "a" "1"   "b" "2"
  end
  ```
  
  A capture of a group that did not take part in the match is *nil*; as first capture 
  this ends a generic *for* loop. Use the flag [UNSET_FALSE](#compile_flags) for such 
  patterns.

  For a carray subject the captures are returned as Lua strings, and the iterator sees 
  changes of the carray between iterations.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_gsub">**`lpcre.gsub(subject, pattern, repl[, n[, cf[, ef]]])
  `**</span>
  
  Replaces all (or the first *n*) matches of *pattern* in *subject*, like *string.gsub*.
  
  * *subject* - string or carray, see [Subjects](#subjects).
  * *pattern* - pattern string or regex object, see above.
  * *repl*    - string, table or function, see [Replacements](#replacements).
  * *n*       - optional integer, maximum number of matches to replace. If *n* is 0 or 
                negative, nothing is replaced.
  * *cf*      - optional [compile flags](#compile_flags) for a pattern string; must be
                *nil* or absent for a regex object.
  * *ef*      - optional [execution flags](#execution_flags).

  For a string subject, returns the new string and the number of matches.
  
  For a carray subject, the result is written back into the carray and the carray itself
  is returned together with the number of matches. The carray must be writable and, if 
  its length changes, resizable. It is only modified if there was at least one match. A 
  replacement function or table must not change the length of the carray (an error is 
  raised if it does).

  ```lua
  lpcre.gsub("hello world", "o", "0")        --> "hell0 w0rld", 2
  local buf = carray.new("char"):append("a1b2")
  lpcre.gsub(buf, "\\d", "<%0>")             --> buf, 2
  buf:tostring()                             --> "a<1>b<2>"
  ```

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_count">**`lpcre.count(subject, pattern[, init[, cf[, ef]]])
  `**</span>
  
  Returns the number of matches of *pattern* in *subject*, counted as 
  [lpcre.gmatch()](#lpcre_gmatch) would iterate them.

  * *subject* - string or carray, see [Subjects](#subjects).
  * *pattern* - pattern string or regex object, see above.
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *cf*      - optional [compile flags](#compile_flags) for a pattern string; must be
                *nil* or absent for a regex object.
  * *ef*      - optional [execution flags](#execution_flags).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_split">**`lpcre.split(subject, sep[, init[, cf[, ef]]])
  `**</span>
  
  Returns an iterator function that splits *subject* at the matches of the pattern 
  *sep*. Each call returns the substring before the next separator followed by the 
  captures of the separator (or the whole separator if it has no capture groups). The last 
  call returns only the rest of the subject after the last separator. See 
  [Empty Matches](#empty-matches) for how empty separators are handled.

  * *subject* - string or carray, see [Subjects](#subjects).
  * *sep*     - pattern string or regex object for the separator, see above.
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *cf*      - optional [compile flags](#compile_flags) for a pattern string; must be
                *nil* or absent for a regex object.
  * *ef*      - optional [execution flags](#execution_flags).

  ```lua
  for part, sep in lpcre.split("a,b;c", "[,;]") do
      print(part, sep)   --> "a" ","   "b" ";"   "c" nil
  end
  ```

  For a carray subject the pieces are returned as Lua strings, and the iterator sees 
  changes of the carray between iterations: each piece is taken from the current content
  of the carray.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_cache">**`lpcre.cache([n])
  `**</span>
  
  Queries or sets the size of the [pattern cache](#pattern-cache).
  
  * *n* - optional integer, new maximum number of cached patterns (default 256). 0 
          disables the cache. If the cache holds more patterns, the least recently used 
          ones are removed.

  Returns the previous maximum size and the number of patterns currently in the cache.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_flags">**`lpcre.flags`**</span>
  
  Table with the numeric values of all [flags](#flags), e.g. *lpcre.flags.CASELESS*. 
  For compatibility with lrexlib the table can also be called: *lpcre.flags()* 
  returns the table itself.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_version">**`lpcre.version()`**</span>
  
  Returns the version string of the PCRE2 library, e.g. *"10.47 2025-10-21"*.
  The version of the lpcre module itself is *lpcre._VERSION*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="lpcre_config">**`lpcre.config()`**</span>
  
  Returns a table with information about the PCRE2 library: 
  
  * *VERSION*         - string, same as [lpcre.version()](#lpcre_version)
  * *UNICODE_VERSION* - string, e.g. *"16.0.0"*
  * *UNICODE*         - boolean, Unicode support available
  * *JIT*             - boolean, JIT compiler available
  * *JITTARGET*       - string, e.g. *"x86 64bit (little endian + unaligned)"*, only 
                        present if the JIT compiler is available
  * *NEWLINE*         - integer, PCRE2's code for the default newline convention 
                        (e.g. 2 for LF)
  * *LINKSIZE*        - integer, internal link size of compiled patterns

<!-- ---------------------------------------------------------------------------------------- -->
##   Regex Methods
<!-- ---------------------------------------------------------------------------------------- -->

Regex objects are created by [lpcre.new()](#lpcre_new). They are immutable and may be 
used for any number of subjects, also recursively from within a replacement function or 
a *gmatch* loop. Their type name is *"lpcre.regex"* (shown by *tostring()* and in error 
messages).

Each method does the same as the [module function](#module-functions) of the same name 
with the regex object as *pattern*, and returns the same results:

```lua
re:find(subject, init, ef)       -- is  lpcre.find(subject, re, init, nil, ef)
re:gsub(subject, repl, n, ef)    -- is  lpcre.gsub(subject, re, repl, n, nil, ef)
```

The arguments *pattern* and *cf* are left out, since the object already carries its 
pattern and compile flags. The subject stays the first argument, the execution flags 
*ef* are the last. The descriptions below give the arguments of each method and refer to
the module function for the results.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_find">**`regex:find(subject[, init[, ef]])
  `**</span>
  
  Looks for the first match in *subject* and returns start and end position of the match
  followed by all captures, or *nil* if there is no match, see [lpcre.find()](#lpcre_find).

  * *subject* - string or carray, see [Subjects](#subjects).
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *ef*      - optional [execution flags](#execution_flags).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_match">**`regex:match(subject[, init[, ef]])
  `**</span>
  
  Looks for the first match in *subject* and returns the captures, or the whole match if
  the pattern has no capture groups, or *nil* if there is no match, see 
  [lpcre.match()](#lpcre_match).

  * *subject* - string or carray, see [Subjects](#subjects).
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *ef*      - optional [execution flags](#execution_flags).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_exec">**`regex:exec(subject[, init[, ef]])
  `**</span>
  
  Looks for the first match and returns start and end position of the match and a table
  with all captures: by group number and, for named groups, also by name. Groups that 
  did not take part in the match are *false* in the table, independent of the flag 
  [UNSET_FALSE](#compile_flags), so that *#t* and *ipairs* cover all groups (as in 
  lrexlib). Returns *nil* if there is no match. This method has no module function 
  counterpart.

  * *subject* - string or carray, see [Subjects](#subjects).
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *ef*      - optional [execution flags](#execution_flags).

  ```lua
  local re = lpcre.new("(?<key>\\w+)=(?<value>\\w+)")
  local s, e, t = re:exec("x: a=1")   --> 4, 6, { "a", "1", key = "a", value = "1" }
  lpcre.new("(a)?(b)"):exec("b")      --> 1, 1, { false, "b" }
  ```

  *regex:tfind()* is an alias of *regex:exec()*.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_test">**`regex:test(subject[, init[, ef]])
  `**</span>
  
  Returns *true* if the pattern matches *subject*, otherwise *false*; nothing else is
  returned, see [lpcre.test()](#lpcre_test).

  * *subject* - string or carray, see [Subjects](#subjects).
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *ef*      - optional [execution flags](#execution_flags).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_matchpos">**`regex:matchpos(subject[, init[, ef]])
  `**</span>
  
  Looks for the first match and returns the captures (or *true* if the pattern has no 
  capture groups) followed by the end position of the match, or *nil* if there is no 
  match, see [lpcre.matchpos()](#lpcre_matchpos).

  * *subject* - string or carray, see [Subjects](#subjects).
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *ef*      - optional [execution flags](#execution_flags).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_findmatch">**`regex:findmatch(subject[, init[, ef]])
  `**</span>
  
  Looks for the first match and returns start and end position, the matched text and
  then all captures, or *nil* if there is no match, see 
  [lpcre.findmatch()](#lpcre_findmatch).

  * *subject* - string or carray, see [Subjects](#subjects).
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *ef*      - optional [execution flags](#execution_flags).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_gmatch">**`regex:gmatch(subject[, init[, ef]])
  `**</span>
  
  Returns an iterator function over all matches in *subject*, see 
  [lpcre.gmatch()](#lpcre_gmatch).

  * *subject* - string or carray, see [Subjects](#subjects).
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *ef*      - optional [execution flags](#execution_flags).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_gsub">**`regex:gsub(subject, repl[, n[, ef]])
  `**</span>
  
  Replaces all (or the first *n*) matches in *subject* and returns the new string (or 
  the carray subject, modified in place) and the number of matches, see 
  [lpcre.gsub()](#lpcre_gsub). Note that *repl* takes the place of *init*: like 
  *string.gsub*, *gsub* has no start position.

  * *subject* - string or carray, see [Subjects](#subjects).
  * *repl*    - string, table or function, see [Replacements](#replacements).
  * *n*       - optional integer, maximum number of matches to replace. If *n* is 0 or 
                negative, nothing is replaced.
  * *ef*      - optional [execution flags](#execution_flags).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_count">**`regex:count(subject[, init[, ef]])
  `**</span>
  
  Returns the number of matches in *subject*, see [lpcre.count()](#lpcre_count).

  * *subject* - string or carray, see [Subjects](#subjects).
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *ef*      - optional [execution flags](#execution_flags).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_split">**`regex:split(subject[, init[, ef]])
  `**</span>
  
  Returns an iterator function that splits *subject* at the matches of the pattern, 
  which is the separator here, see [lpcre.split()](#lpcre_split).

  * *subject* - string or carray, see [Subjects](#subjects).
  * *init*    - optional start position (default 1), see [Positions](#positions).
  * *ef*      - optional [execution flags](#execution_flags).

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_ncapt">**`regex:ncapt()`**</span>
  
  Returns the number of capture groups of the pattern.

<!-- ---------------------------------------------------------------------------------------- -->

* <span id="regex_jit">**`regex:jit()`**</span>
  
  Returns *true* if the pattern was compiled with the flag [JIT](#compile_flags) and JIT 
  compilation succeeded, i.e. the JIT compiler is available.

<!-- ---------------------------------------------------------------------------------------- -->
##   Flags
<!-- ---------------------------------------------------------------------------------------- -->

Flags are given as compile flags (argument *cf*) or as execution flags (argument *ef*). 
Their numeric values are in [lpcre.flags](#lpcre_flags). Several flags are combined with 
*+* (or with *|* in Lua 5.3 and newer), e.g. *lpcre.flags.CASELESS + lpcre.flags.UTF*.

* <span id="compile_flags">**Compile flags (argument *cf*)**</span>

  A number, or a string of the flag letters given below, e.g. *"is"*. Other letters raise
  an error. Inline options in the pattern work as usual, e.g. *"(?i)abc"*.

  * **PCRE2 options**: each value equals the PCRE2 constant of the same name, e.g. 
    *lpcre.flags.CASELESS == PCRE2_CASELESS*, so values from *pcre2.h* can be used directly.

    * **`CASELESS`** (`"i"`) - case-insensitive matching
    * **`MULTILINE`** (`"m"`) - `^` and `$` also match at newlines
    * **`DOTALL`** (`"s"`) - `.` also matches a newline
    * **`EXTENDED`** (`"x"`) - whitespace and `#` comments in the pattern are ignored
    * **`UTF`** (`"u"`) - pattern and subject are UTF-8
    * **`UNGREEDY`** (`"U"`) - quantifiers are lazy by default
    * **`ALLOW_EMPTY_CLASS`** - `[]` is an empty class
    * **`ALT_BSUX`** - JavaScript-like `\U`, `\u`, `\x`
    * **`ALT_CIRCUMFLEX`** - `^` in multiline mode also matches after a final newline
    * **`ALT_VERBNAMES`** - backslash processing in verb names
    * **`ANCHORED`** - match only at the start position
    * **`AUTO_CALLOUT`** - automatic callouts
    * **`DOLLAR_ENDONLY`** - `$` matches only at the very end
    * **`DUPNAMES`** - duplicate group names allowed
    * **`ENDANCHORED`** - the match must end at the end of the subject; PCRE2 10.30 and newer
    * **`EXTENDED_MORE`** - like *EXTENDED*, also ignores spaces in classes; PCRE2 10.30 and newer
    * **`FIRSTLINE`** - the match must start before or at the first newline
    * **`LITERAL`** - the pattern is a literal string; PCRE2 10.30 and newer
    * **`MATCH_INVALID_UTF`** - invalid UTF-8 in the subject is allowed (never matched); PCRE2 10.34 and newer
    * **`MATCH_UNSET_BACKREF`** - unset back references match an empty string
    * **`NEVER_BACKSLASH_C`** - `\C` is not allowed
    * **`NEVER_UCP`** - `(*UCP)` is not allowed
    * **`NEVER_UTF`** - `(*UTF)` is not allowed
    * **`NO_AUTO_CAPTURE`** - `(...)` does not capture, only named groups do
    * **`NO_AUTO_POSSESS`** - no automatic possessification
    * **`NO_DOTSTAR_ANCHOR`** - no automatic anchoring for `.*`
    * **`NO_START_OPTIMIZE`** - no start-of-match optimizations
    * **`NO_UTF_CHECK`** - the pattern is not checked for valid UTF-8
    * **`UCP`** - Unicode properties for `\d`, `\w` etc.

  * **lpcre options**: these values belong to lpcre, not to PCRE2. They lie above 2^32 
    (2^32, 2^33, 2^34) and are filtered out before every call into PCRE2.

    * **`UNSET_FALSE`** - captures of groups not taking part in the match are *false* instead of *nil*
      in multiple results (*find*, *match*, *matchpos*, *findmatch*, *gmatch*, *split*, *gsub* 
      callback arguments); the table of [regex:exec()](#regex_exec) always has *false*
    * **`JIT`** - use the PCRE2 JIT compiler if available, see [regex:jit()](#regex_jit)
    * **`NOCACHE`** (`"n"`) - compile a new regex object without the [pattern cache](#pattern-cache); [lpcre.new()](#lpcre_new) only

* <span id="execution_flags">**Execution flags (argument *ef*)**</span>

  A number; letters are not accepted.

  * **PCRE2 options**: each value equals the PCRE2 constant of the same name, e.g. 
    *lpcre.flags.NOTBOL == PCRE2_NOTBOL*.

    * **`NOTBOL`** - the subject start is not the beginning of a line
    * **`NOTEOL`** - the subject end is not the end of a line
    * **`NOTEMPTY`** - an empty string is not a valid match
    * **`NOTEMPTY_ATSTART`** - an empty string at the start position is not a valid match
    * **`ANCHORED`** - match only at the start position
    * **`ENDANCHORED`** - the match must end at the end of the subject; PCRE2 10.30 and newer
    * **`NO_JIT`** - do not use the JIT compiled code; PCRE2 10.22 and newer
    * **`NO_UTF_CHECK`** - the subject is not checked for valid UTF-8

  Partial matching (*PCRE2_PARTIAL_SOFT*, *PCRE2_PARTIAL_HARD*) is not supported: these
  values are rejected with an error (*partial matching is not supported*).

  * **lpcre options**: none. The lpcre options lie above 2^32 and are compile flags only; 
    as execution flags they are rejected with an error (*invalid flags*).

All flag values and their sums are below 2^53 and therefore exact also in Lua 5.1 and 
LuaJIT, where numbers are doubles.

With the flag *UTF* the subject must be valid UTF-8 and *init* must point to the start of
a character, otherwise an error is raised (unless *MATCH_INVALID_UTF* is set). A string 
subject is checked once per call, not once per match in *gmatch*, *gsub*, *count* and 
*split*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Replacements
<!-- ---------------------------------------------------------------------------------------- -->

The argument *repl* of [lpcre.gsub()](#lpcre_gsub) works as in *string.gsub*:

  * **string**: the replacement text. *%1* ... *%9* insert the corresponding capture, *%0*
    the whole match, *%%* a single *%*. If the pattern has no capture groups, *%1* is the 
    whole match. A capture of a group that did not take part in the match inserts an empty
    string. Any other use of *%* raises an error. A number is used as string.
  * **table**: the table is indexed with the first capture (or the whole match if the 
    pattern has no capture groups).
  * **function**: the function is called with all captures (or the whole match if the 
    pattern has no capture groups) as arguments.

If the table value or the function result is a string or a number, it is used as 
replacement; if it is *false* or *nil*, the match is kept unchanged; anything else 
raises an error.

<!-- ---------------------------------------------------------------------------------------- -->
##   Empty Matches
<!-- ---------------------------------------------------------------------------------------- -->

[lpcre.gmatch()](#lpcre_gmatch), [lpcre.gsub()](#lpcre_gsub), [lpcre.count()](#lpcre_count)
and [lpcre.split()](#lpcre_split) follow the rule of Lua 5.4's *string.gmatch* and 
*string.gsub*: an empty match directly at the end of the previous match is skipped and 
the search continues one character later (one UTF-8 character with the flag *UTF*).

```lua
lpcre.gsub("abc", "x*", "-")   --> "-a-b-c-", 4
lpcre.gsub("abc", "b*", "-")   --> "-a-c-", 3
```

<!-- ---------------------------------------------------------------------------------------- -->
##   Errors
<!-- ---------------------------------------------------------------------------------------- -->

All errors are raised with *error()*; no function returns an error code. The messages
below are those of Lua 5.4; the function name in argument errors depends on the Lua 
version.

  * **Invalid pattern**: an argument error for the pattern with the PCRE2 message and the
    offset in the pattern where PCRE2 detected the error, e.g. *lpcre.new("(abc")* raises
    *bad argument #1 to 'lpcre.new' (missing closing parenthesis at offset 4)*.
  * **Invalid arguments**: argument errors as in the Lua standard library, e.g. 
    *string or carray expected, got table*, *string or lpcre.regex expected, got number*, 
    *string expected, got number* (pattern of *lpcre.new()*), 
    *string/function/table expected, got boolean* (for *repl*), *carray elements must be 
    1 byte in size*, *cache size must not be negative*.
  * **Invalid flags**: *invalid flag character 'q'*, *invalid flags* (negative, not an
    integer, unknown bits, or an lpcre option as execution flag), *partial matching is
    not supported*, *number or string 
    expected, got table*, *flag NOCACHE is only valid for lpcre.new()*, *cf not allowed 
    with a regex object*.
  * **Invalid replacement**: *invalid capture index %2 in replacement string*, 
    *invalid use of '%' in replacement string*, *invalid replacement value (a table)*.
  * **carray subject of gsub**: *carray is not writable*,
    *carray subject was resized during gsub*, *cannot resize carray* (the length changes
    and the carray is not resizable, e.g. one referencing foreign memory, or out of memory).
  * **Match errors**: *match failed: <PCRE2 message>*, e.g. 
    *match failed: UTF-8 error: illegal byte (0xfe or 0xff)*.

<!-- ---------------------------------------------------------------------------------------- -->
##   Pattern Cache
<!-- ---------------------------------------------------------------------------------------- -->

Compiled patterns are kept in a cache, keyed by pattern string and compile flags (all of 
them, including *JIT* and *UNSET_FALSE*). By default everything is cached: 
[lpcre.new()](#lpcre_new) and pattern strings given to the module functions 
[lpcre.find()](#lpcre_find), [lpcre.match()](#lpcre_match), [lpcre.gmatch()](#lpcre_gmatch),
[lpcre.gsub()](#lpcre_gsub), [lpcre.count()](#lpcre_count) and [lpcre.split()](#lpcre_split)
look up the pattern in the cache, or compile it and put it into the cache.

```lua
for line in io.lines(file) do
    local k, v = lpcre.match(line, "^(\\w+)\\s*=\\s*(.*)$")   -- compiled once
end
```

The cache holds at most [lpcre.cache()](#lpcre_cache) patterns (default 256); when it is 
full, the least recently used pattern is removed. Regex objects removed from the cache stay
valid as long as they are referenced. *lpcre.cache(0)* disables the cache: then every 
pattern is compiled anew, also by *lpcre.new()*.

The only way to compile a single pattern without the cache is *lpcre.new(pattern, "n")*
(flag *NOCACHE*). The module functions reject *NOCACHE* together with a pattern string; 
pass the regex object of *lpcre.new(pattern, "n")* to them instead. The regex object 
belongs to the caller and is garbage collected when it is no longer referenced. Use 
*NOCACHE* for patterns built at runtime from data, so that they do not evict the 
frequently used patterns from the cache:

```lua
local re = lpcre.new("^" .. escaped .. "$", "n")    -- not cached, owned by re
for _, s in ipairs(list) do
    if lpcre.find(s, re) then print(s) end
end
```

The cache belongs to the Lua state, see 
[Thread safety / multiple Lua states](#thread-safety--multiple-lua-states).

<!-- ---------------------------------------------------------------------------------------- -->
##   Thread safety / multiple Lua states
<!-- ---------------------------------------------------------------------------------------- -->

lpcre has no global mutable data: the pattern cache and all other state are kept per Lua
state (in upvalues of the module functions). PCRE2 itself works without global state; 
everything is passed explicitly through compiled patterns, match data blocks and the 
default contexts. lpcre can therefore be loaded into several independent Lua states of 
the same process, and these states can be used concurrently from different OS threads 
(each state by one thread at a time, as usual for Lua). Closing one state does not affect
the others. *tests/test03.lua* checks this with two Lua states running in parallel threads.

<!-- ---------------------------------------------------------------------------------------- -->
##   Building
<!-- ---------------------------------------------------------------------------------------- -->

With [LuaRocks](https://luarocks.org) from the repository root:

```
luarocks make rockspecs/lpcre-scm-0.rockspec
luarocks --lua-version 5.4 --local make rockspecs/lpcre-scm-0.rockspec
```

PCRE2 is found as external dependency *PCRE2* (header *pcre2.h*, library *pcre2-8*). If it
is not installed in a standard location, give its prefix or its directories:

```
luarocks make rockspecs/lpcre-scm-0.rockspec PCRE2_DIR=/opt/homebrew/opt/pcre2
luarocks make rockspecs/lpcre-scm-0.rockspec PCRE2_INCDIR=... PCRE2_LIBDIR=...
```

On Windows with MSVC, PCRE2 can be installed with vcpkg (*vcpkg install pcre2:x64-windows*,
then *PCRE2_DIR=<vcpkg>/installed/x64-windows*; *pcre2-8.dll* must be on the *PATH*). With 
MinGW/MSYS2 install *mingw-w64-x86_64-pcre2*. When linking PCRE2 statically, add the define 
*PCRE2_STATIC*.

Without LuaRocks, the Makefile in *src* builds *src/build/lua$(LUA_VERSION)/lpcre.so*
(settings can be overridden in *src/sandbox.mk*; *COPTS* and *LOPTS* are added to the 
flags of PCRE2 from *pkg-config*, they do not replace them); *src/activate.sh* sets the Lua paths for
using the module from the source tree:

```
cd src
make LUA_VERSION=5.4 COPTS=-I/usr/include/lua5.4
. activate.sh
```

The tests are run from the *tests* directory:

  * *lua test01.lua* - string subjects
  * *lua test02.lua* - carray subjects (skipped if carray is not installed); the
    error cases for read-only and non-resizable carrays need the test helper module
    *lpcre_testcarray* (*luarocks make tests/lpcre_testcarray-scm-0.rockspec* from the
    repository root, or *make testcarray* in *src*), skipped if it is not installed
  * *lua test03.lua* - several Lua states in parallel threads; needs the test helper 
    module *lpcre_multistate* (*luarocks make tests/lpcre_multistate-scm-0.rockspec* from
    the repository root, or *make multistate* in *src*), skipped if it is not installed
  * *lua bench01.lua* - benchmark: string vs. carray subjects on a 1 MB subject
  * *lua bench02.lua [calls [reps]]* - benchmark: per-call cost of *test*, *matchpos* and 
    *findmatch* against the same results built from *find* in Lua (1 million calls per
    variant by default)

<!-- ---------------------------------------------------------------------------------------- -->
##   Migration from lrexlib-pcre2
<!-- ---------------------------------------------------------------------------------------- -->

lpcre follows the conventions of Lua's string library; where lrexlib-pcre2 (*rex_pcre2*) 
differs from them, lpcre follows Lua. For most code the migration consists of replacing
*require("rex_pcre2")* by *require("lpcre")* and checking the points below.

  * **Groups not taking part in a match** give *nil* captures instead of *false* in 
    multiple results (*find*, *match*, *gmatch*, *gsub* callback arguments etc.). Code 
    that tests captures with *== false* or relies on *false* in *gmatch* loops can use the
    compile flag *lpcre.flags.UNSET_FALSE* to get lrexlib's behaviour. The capture table 
    of *regex:exec()*/*regex:tfind()* has *false* for such groups like lrexlib, with or 
    without the flag.

  * **gsub** returns two values (new string, number of matches) like *string.gsub*. 
    lrexlib returns a third value, the number of replacements actually made.

  * **Replacement strings**: lrexlib inserts *x* for *%x* if *x* is not a digit and drops a
    trailing *%*; lpcre raises an error like *string.gsub*. Write *%%* for a literal *%*.

  * **gmatch, count, split** take *init* as third argument, before the flags:
    *rex.gmatch(s, p, cf, ef)* becomes *lpcre.gmatch(s, p, nil, cf, ef)*. The arguments of
    *find*, *match* and *gsub* are unchanged.

  * **regex:exec()** returns a table of captures (including named groups) like lrexlib's
    *tfind*, not a table of offsets. *regex:tfind()* is an alias.

  * **Pattern cache**: lpcre caches compiled patterns by default, for *lpcre.new()* and for
    pattern strings in the module functions; lrexlib compiles on every call. Therefore
    *lpcre.new()* returns the same regex object for the same pattern and flags. 
    *lpcre.new(pattern, "n")* (flag *NOCACHE*) compiles a new object as *rex.new()* does;
    the module functions accept *"n"* only through such an object, not with a pattern 
    string, and take no *cf* at all together with a regex object. *lpcre.cache(0)* disables the cache.

  * **Flags**: *rex.flags()* becomes *lpcre.flags* (calling *lpcre.flags()* still works).
    Flag strings: lrexlib ignores unknown letters, lpcre raises an error; *"u"* (*UTF*) 
    and *"n"* (*NOCACHE*) are new. lpcre's flags table contains compile and execution 
    options but no *ERROR_xxx*, *INFO_xxx* or *CONFIG_xxx* entries.

  * **Error messages** differ: compile errors are argument errors 
    (*bad argument #1 to 'lpcre.new' (missing closing parenthesis at offset 4)* instead of 
    *missing closing parenthesis (pattern offset: 5)*; lpcre reports PCRE2's 0-based 
    offset, lrexlib adds 1), match errors read *match failed: <PCRE2 message>* instead of 
    *error PCRE2_ERROR_xxx*.

  * **Subjects**: lrexlib accepts strings and userdata/tables with a buffer interface; 
    lpcre accepts strings and carrays. With a carray subject, lpcre's *gsub* modifies the
    carray in place.

  * **Additional methods**: regex objects have *gmatch*, *gsub*, *count* and *split* 
    methods; in lrexlib these exist only as module functions.

  * **Additional functions**: [lpcre.test()](#lpcre_test) (only *true*/*false*),
    [lpcre.matchpos()](#lpcre_matchpos) (captures, then the end position) and 
    [lpcre.findmatch()](#lpcre_findmatch) (positions, whole match, captures), also as 
    regex methods. lrexlib code of the form *if rex.find(s, p) then* can use 
    *lpcre.test(s, p)*; code that calls *rex.find* only to get the captures and the end 
    of the match can use *lpcre.matchpos* without rearranging the results in Lua.

  * **Not provided**: *dfa_exec*, *fullinfo*, locale tables (lrexlib's *larg*), a function
    as maximum count *n* of *gsub*; *lpcre.config()* returns fewer entries than 
    *rex.config()*.

  * **JIT**: lpcre compiles with JIT on request (*lpcre.flags.JIT*), see 
    [regex:jit()](#regex_jit).

  * **Positions, init, empty matches and the semantics of table and function replacements**
    are the same in both modules.

<!-- ---------------------------------------------------------------------------------------- -->
