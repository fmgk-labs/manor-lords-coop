"""Lane 74: parse or run Lua with a Lua runtime DLL found on this PC (no Lua interpreter is installed here).
  py -I luarun.py <lua5x.dll> parse <file.lua> [...]        compile only (luaL_loadbuffer), never called
  py -I luarun.py <lua5x.dll> run <script.lua> [args]       run a desk test (made-up game objects, no game)
A Lua 5.1 / LuaJIT DLL knows no 5.3 / 5.4 syntax ("//", "&", "<<", goto ...): the mod's files that are parsed here
use none. The 5.4 library forms they use (math.tointeger, table.unpack) are stood in for by the test script.
Exit code: 0 = every file parses / the script returned nothing or true; 1 otherwise."""
import ctypes, sys

if len(sys.argv) < 4 or sys.argv[2] not in ("parse", "run"):
    print(__doc__); sys.exit(2)
dll = ctypes.CDLL(sys.argv[1])
V = ctypes.c_void_p
dll.luaL_newstate.restype = V
dll.luaL_openlibs.argtypes = [V]
dll.luaL_loadbuffer.argtypes = [V, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
dll.lua_pcall.argtypes = [V, ctypes.c_int, ctypes.c_int, ctypes.c_int]
dll.lua_tolstring.argtypes = [V, ctypes.c_int, V]
dll.lua_tolstring.restype = ctypes.c_char_p
dll.lua_toboolean.argtypes = [V, ctypes.c_int]
dll.lua_type.argtypes = [V, ctypes.c_int]
dll.lua_settop.argtypes = [V, ctypes.c_int]
dll.lua_createtable.argtypes = [V, ctypes.c_int, ctypes.c_int]
dll.lua_pushstring.argtypes = [V, ctypes.c_char_p]
dll.lua_rawseti.argtypes = [V, ctypes.c_int, ctypes.c_int]
dll.lua_setfield.argtypes = [V, ctypes.c_int, ctypes.c_char_p]
LUA_GLOBALSINDEX = -10002          # Lua 5.1 / LuaJIT


def base(p):
    return p.replace("\\", "/").split("/")[-1]


L = dll.luaL_newstate()
if sys.argv[2] == "parse":
    bad = 0
    for p in sys.argv[3:]:
        src = open(p, "rb").read()
        if dll.luaL_loadbuffer(L, src, len(src), ("@" + base(p)).encode()) == 0:
            print("%s: parses" % base(p))
        else:
            bad = 1
            print("%s: %s" % (base(p), dll.lua_tolstring(L, -1, None).decode("utf-8", "replace")))
        dll.lua_settop(L, 0)
    sys.exit(bad)

dll.luaL_openlibs(L)
dll.lua_createtable(L, 0, 0)
dll.lua_pushstring(L, sys.argv[3].encode()); dll.lua_rawseti(L, -2, 0)
for i, a in enumerate(sys.argv[4:], 1):
    dll.lua_pushstring(L, a.encode()); dll.lua_rawseti(L, -2, i)
dll.lua_setfield(L, LUA_GLOBALSINDEX, b"arg")
src = open(sys.argv[3], "rb").read()
sys.stdout.flush()
if dll.luaL_loadbuffer(L, src, len(src), ("@" + base(sys.argv[3])).encode()) != 0:
    print("LOAD ERROR: " + dll.lua_tolstring(L, -1, None).decode("utf-8", "replace")); sys.exit(1)
if dll.lua_pcall(L, 0, 1, 0) != 0:
    print("RUN ERROR: " + dll.lua_tolstring(L, -1, None).decode("utf-8", "replace")); sys.exit(1)
ok = dll.lua_type(L, -1) == 0 or dll.lua_toboolean(L, -1)
sys.exit(0 if ok else 1)
