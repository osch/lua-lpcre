.PHONY: default lpcre multistate testcarray
default: lpcre

BUILD_DATE  := $(shell date "+%Y-%m-%dT%H:%M:%S")

LNX_GCC_RUN := gcc -shared -fPIC -O2 -g -Werror=return-type
WIN_GCC_RUN := gcc -shared -fPIC -O2
MAC_GCC_RUN := MACOSX_DEPLOYMENT_TARGET=10.8 gcc -O2 -bundle -undefined dynamic_lookup -all_load

PCRE2_CFLAGS := $(shell pkg-config --cflags libpcre2-8 2>/dev/null)
PCRE2_LIBS   := $(or $(shell pkg-config --libs libpcre2-8 2>/dev/null),-lpcre2-8)

# PCRE2_CFLAGS/PCRE2_LIBS are always added to COPTS/LOPTS in the lpcre rule,
# so COPTS/LOPTS given on the command line or in sandbox.mk extend them
LNX_COPTS   :=
WIN_COPTS   := -I/mingw64/include/lua5.1
MAC_COPTS   := -I/usr/local/opt/lua/include/lua5.3

LNX_LOPTS   :=
WIN_LOPTS   :=
MAC_LOPTS   :=

LNX_SO_EXT  := so
WIN_SO_EXT  := dll
MAC_SO_EXT  := so

GCC_RUN     :=
SO_EXT      :=
COPTS       :=
LOPTS       :=

# platforms: LNX, WIN, MAC
# (may be set in sandbox.mk)

PLATFORM    := LNX
LUA_VERSION := 5.5

-include sandbox.mk

GCC_RUN       := $(or $(GCC_RUN),       $($(PLATFORM)_GCC_RUN))
SO_EXT        := $(or $(SO_EXT),        $($(PLATFORM)_SO_EXT))
COPTS         := $(or $(COPTS),         $($(PLATFORM)_COPTS))
LOPTS         := $(or $(LOPTS),         $($(PLATFORM)_LOPTS))

lpcre:
	@mkdir -p build/lua$(LUA_VERSION)/
	$(GCC_RUN) $(COPTS) $(PCRE2_CFLAGS) \
	    -D LPCRE_VERSION=Makefile"-$(BUILD_DATE)" \
	    main.c lpcre.c \
	    lpcre_compat.c  \
	    $(LOPTS) $(PCRE2_LIBS) \
	    -o build/lua$(LUA_VERSION)/lpcre.$(SO_EXT)

# Test helper module for tests/test02.lua (read-only and non-resizable carrays)
testcarray:
	@mkdir -p build/lua$(LUA_VERSION)/
	$(GCC_RUN) $(COPTS) \
	    ../tests/testcarray.c \
	    -o build/lua$(LUA_VERSION)/lpcre_testcarray.$(SO_EXT)

# Test helper module for tests/test03.lua (several Lua states, parallel threads)
multistate:
	@mkdir -p build/lua$(LUA_VERSION)/
	$(GCC_RUN) $(COPTS) \
	    ../tests/multistate.c \
	    $(if $(filter WIN,$(PLATFORM)),,-lpthread) \
	    -o build/lua$(LUA_VERSION)/lpcre_multistate.$(SO_EXT)
