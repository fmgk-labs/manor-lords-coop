# Lane 67: compile Lua files with a Lua 5.1 library from Python (ctypes), and run Lua desk tests.
#   py -3 -I luacheck.py compile <file.lua> ...     luaL_loadfile only (never runs the file); exit 1 on any error
#   py -3 -I luacheck.py run <script.lua> [args]    runs a desk test script (arg table = args); exit 1 on error
# The library: LUA51_DLL, else MSI Kombustor's lua51.dll (an installed program on the lead's PC). Lua 5.1 parses a
# subset of the 5.4 grammar the game's loader (UE4SS) uses: a 5.4-only form (//, bit operators, goto, <const>) fails
# here, which is what this check is for in files that must not use them.
import ctypes, os, sys
DLL = os.environ.get("LUA51_DLL", r"C:\Program Files\Geeks3D\MSI Kombustor 4 x64\lua51.dll")
L51 = ctypes.CDLL(DLL)
L51.luaL_newstate.restype = ctypes.c_void_p
L51.luaL_loadfile.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
L51.luaL_loadbuffer.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
L51.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
L51.lua_tolstring.restype = ctypes.c_char_p
L51.lua_pcall.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
L51.luaL_openlibs.argtypes = [ctypes.c_void_p]
L51.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
L51.lua_pushstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
L51.lua_setfield.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p]
LUA_GLOBALSINDEX = -10002

def err(L): return (L51.lua_tolstring(L, -1, None) or b"?").decode("utf-8", "replace")

def compile_files(files):
    bad = 0
    for f in files:
        L = L51.luaL_newstate()
        r = L51.luaL_loadfile(L, f.encode("mbcs"))
        print(("OK    " if r == 0 else "ERROR ") + (f if r == 0 else err(L)))
        bad += r != 0
    return bad

def run(script, args):
    L = L51.luaL_newstate(); L51.luaL_openlibs(L)
    here = os.path.dirname(os.path.abspath(script)).replace("\\", "/") + "/"
    L51.lua_pushstring(L, here.encode()); L51.lua_setfield(L, LUA_GLOBALSINDEX, b"HERE")
    for i, a in enumerate(args):
        L51.lua_pushstring(L, a.encode()); L51.lua_setfield(L, LUA_GLOBALSINDEX, ("ARG%d" % (i + 1)).encode())
    if L51.luaL_loadfile(L, script.encode("mbcs")) != 0: print("ERROR " + err(L)); return 1
    if L51.lua_pcall(L, 0, 0, 0) != 0: print("ERROR " + err(L)); return 1
    return 0

if __name__ == "__main__":
    if len(sys.argv) < 3: print(__doc__ if __doc__ else "usage"); sys.exit(2)
    if sys.argv[1] == "compile": sys.exit(1 if compile_files(sys.argv[2:]) else 0)
    if sys.argv[1] == "run": sys.exit(run(sys.argv[2], sys.argv[3:]))
    sys.exit(2)
