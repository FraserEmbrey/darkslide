#!/usr/bin/env python3
"""Copies the engine's Homebrew libraries into the app, so it runs without Homebrew.

Walks every binary in the engine copy (the helper, libdarktable, its modules,
and each library copied) for dependencies in /opt/homebrew, copies each under
the name it's referred to by into lib/darktable, gives it an @rpath install
name and points every reference at that, then removes the helper's
/opt/homebrew search path. Lensfun's lens database goes into share/lensfun,
where darktable looks for it beside its own data.

Usage: bundle-libs.py <engine dir>   (the bundle's Resources/engine)
"""
import os
import shutil
import subprocess
import sys

HOMEBREW = "/opt/homebrew"
engine = os.path.abspath(sys.argv[1])
libdir = os.path.join(engine, "lib", "darktable")


def deps(path):
    out = subprocess.run(["otool", "-L", path], capture_output=True, text=True).stdout.splitlines()[1:]
    return [l.strip().split(" (")[0] for l in out]


def run(*args):
    subprocess.run(args, check=True, capture_output=True)


# the engine's own binaries
binaries = [os.path.join(engine, "bin", "darkroom-helper")]
for root, _, files in os.walk(libdir):
    binaries += [os.path.join(root, f) for f in files if f.endswith((".so", ".dylib"))]

# copy every Homebrew library reached, under the name it's referred to by
copied = {}          # referred path -> bundled name
queue = list(binaries)
while queue:
    b = queue.pop()
    for d in deps(b):
        if not d.startswith(HOMEBREW) or d in copied:
            continue
        name = os.path.basename(d)
        dest = os.path.join(libdir, name)
        if not os.path.exists(dest):
            shutil.copy2(os.path.realpath(d), dest)
            os.chmod(dest, 0o755)
            run("install_name_tool", "-id", f"@rpath/{name}", dest)
            queue.append(dest)
            binaries.append(dest)
        copied[d] = name

# Homebrew libraries also refer to each other by @rpath or @loader_path names
for b in binaries:
    for d in deps(b):
        if d.startswith(HOMEBREW):
            run("install_name_tool", "-change", d, f"@rpath/{copied[d]}", b)
        elif d.startswith("@loader_path/") and b.startswith(libdir) and not os.path.exists(os.path.join(libdir, os.path.basename(d))):
            sys.exit(f"{os.path.basename(b)} refers to {d}, which isn't bundled")

# the helper searched /opt/homebrew/lib too; only the bundle now
helper = binaries[0]
out = subprocess.run(["otool", "-l", helper], capture_output=True, text=True).stdout.split("\n")
for i, line in enumerate(out):
    if "cmd LC_RPATH" in line:
        path = out[i + 2].strip().split(" ")[1]
        if path.startswith(HOMEBREW):
            run("install_name_tool", "-delete_rpath", path, helper)

# changing a library breaks its signature (install_name_tool only re-signs
# what the linker signed), and macOS kills a process that loads a library with
# a broken one: sign every binary here again (ad hoc; the app is signed after)
for b in binaries:
    run("codesign", "--force", "--sign", "-", b)

# Lensfun's database
lensfun = os.path.join(HOMEBREW, "share", "lensfun")
if os.path.isdir(lensfun):
    shutil.copytree(lensfun, os.path.join(engine, "share", "lensfun"), dirs_exist_ok=True)

# nothing may still point into Homebrew
left = [f"{os.path.basename(b)} -> {d}" for b in binaries for d in deps(b) if d.startswith(HOMEBREW)]
if left:
    sys.exit("still linked to Homebrew: " + "; ".join(left[:5]))
print(f"bundled {len(set(copied.values()))} libraries")
