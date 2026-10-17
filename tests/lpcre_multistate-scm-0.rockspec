-- Test helper for tests/test03.lua, not part of the lpcre package.
-- Install from the repository root: luarocks make tests/lpcre_multistate-scm-0.rockspec
package = "lpcre_multistate"
version = "scm-0"
source = {
  url = "https://github.com/osch/lua-lpcre/archive/master.zip",
  dir = "lua-lpcre-master",
}
description = {
  summary = "Test helper for lpcre: independent Lua states and parallel threads",
  homepage = "https://github.com/osch/lua-lpcre",
  license = "MIT",
}
dependencies = {
  "lua >= 5.1",
}
build = {
  type = "builtin",
  modules = {
    lpcre_multistate = {
      sources = { "tests/multistate.c" },
    },
  },
  platforms = {
    unix = {
      modules = {
        lpcre_multistate = {
          libraries = { "pthread" },
        },
      },
    },
  },
}
