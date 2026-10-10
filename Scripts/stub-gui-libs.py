#!/usr/bin/env python3
"""Replaces darktable's interface libraries in an engine copy with stand-ins.

darktable is built with GTK and the libraries under it, which its build
requires and its code refers to throughout (every module has interface code),
but Develop never runs darktable's interface. This generates, for each of
those libraries, a small dynamic library exporting every function the engine
refers to from it, each doing nothing and returning zero, and points the
engine's binaries at them. The real GTK stack is then never loaded.

A stand-in that is called logs its name once, so a hidden use shows up.

Usage: stub-gui-libs.py <engine dir>   (the bundle's Resources/engine)
"""
import os
import re
import subprocess
import sys
import tempfile

# the libraries replaced, by the start of their file name: the interface
# stack, Cairo (drawing; the app draws frames and watermarks itself) and
# potrace (tracing AI masks into paths, with darktable's AI off)
GUI = ["libgtk-3", "libgdk-3", "libgdk_pixbuf-2", "libpango-1", "libpangocairo-1", "libpangoft2-1",
       "librsvg-2", "libatk-1", "libharfbuzz", "libcairo-gobject", "libepoxy", "libfribidi",
       "libcairo", "libpotrace"]

engine = os.path.abspath(sys.argv[1])
libdir = os.path.join(engine, "lib", "darktable")


def machos():
    yield os.path.join(engine, "bin", "darkroom-helper")
    for root, _, files in os.walk(libdir):
        for f in files:
            if f.endswith((".so", ".dylib")) and "stub" not in f:
                yield os.path.join(root, f)


def deps(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout.splitlines()[1:]
    return [l.strip().split(" (")[0] for l in out]


def gui_name(dep):
    base = os.path.basename(dep)
    for g in GUI:
        if base.startswith(g + ".") or base.startswith(g + "-") or base == g + ".dylib" or base.startswith(g):
            return g
    return None


# symbols each binary binds to each interface library
needed = {g: set() for g in GUI}
users = []
for m in machos():
    gui_deps = [(d, gui_name(d)) for d in deps(m) if gui_name(d)]
    if not gui_deps:
        continue
    users.append((m, gui_deps))
    out = subprocess.run(["nm", "-m", m], capture_output=True, text=True).stdout
    for line in out.splitlines():
        mm = re.search(r"\(undefined\).* external (\S+) \(from ([^)]+)\)", line)
        if not mm:
            continue
        sym, lib = mm.group(1), mm.group(2)
        for g in GUI:
            if lib == g or lib.startswith(g):
                needed[g].add(sym)

# the generated sources go to a temporary folder, outside the bundle
work = tempfile.mkdtemp(prefix="develop-gui-stubs-")
built = {}
for g, syms in needed.items():
    if not any(g == name for _, deps_ in users for _, name in deps_):
        continue
    name = f"{g}-stub.dylib"
    c = os.path.join(work, g + ".c")
    with open(c, "w") as f:
        f.write('#include <stdio.h>\n'
                '/* stand-ins for %s: darktable refers to these, Develop never runs them */\n'
                'static void hit(const char *n) { fprintf(stderr, "[gui stub] %%s called\\n", n); }\n' % g)
        for s in sorted(syms):
            cname = s[1:] if s.startswith("_") else s
            f.write(f'long {cname}(void) {{ static int once; if(!once++) hit("{cname}"); return 0; }}\n')
    out = os.path.join(libdir, name)
    subprocess.run(["clang", "-dynamiclib", "-O1", "-w", "-o", out, c,
                    "-install_name", f"@rpath/{name}"], check=True)
    built[g] = name
    print(f"{name}: {len(syms)} functions")

for m, gui_deps in users:
    for dep, g in gui_deps:
        subprocess.run(["install_name_tool", "-change", dep, f"@rpath/{built[g]}", m],
                       check=True, capture_output=True)

left = set()
for m in machos():
    for d in deps(m):
        if gui_name(d) and "stub" not in d:
            left.add(d)
if left:
    sys.exit("still linked: " + ", ".join(sorted(left)))
print(f"relinked {len(users)} binaries")
