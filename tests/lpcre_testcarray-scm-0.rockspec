-- Test helper for tests/test02.lua, not part of the lpcre package.
-- Install from the repository root: luarocks make tests/lpcre_testcarray-scm-0.rockspec
package = "lpcre_testcarray"
version = "scm-0"
source = {
  url = "https://github.com/osch/lua-lpcre/archive/master.zip",
  dir = "lua-lpcre-master",
}
description = {
  summary = "Test helper for lpcre: read-only and non-resizable carray objects",
  homepage = "https://github.com/osch/lua-lpcre",
  license = "MIT",
}
dependencies = {
  "lua >= 5.1",
  "carray",
}
build = {
  type = "builtin",
  modules = {
    lpcre_testcarray = {
      sources = { "tests/testcarray.c" },
    },
  },
}
