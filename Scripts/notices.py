#!/usr/bin/env python3
"""Writes the app's acknowledgements: every part of the built app that isn't
Darkslide's own code, its licence and its licence text, into
Contents/Resources/Acknowledgements.txt, and the About panel's Credits.html.

Each library the engine bundles (Scripts/bundle-libs.py) must be listed in
LIBRARIES, so a new dependency can't ship without its notice: the build fails
naming it. Licence texts come from the Homebrew formula's own files, from
darktable's source, or from Licences/ for the few that ship none.

Usage: notices.py <app>
"""
import glob
import hashlib
import os
import plistlib
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DT_SRC = os.path.join(ROOT, "vendor", "darktable-5.6.2")
app = os.path.abspath(sys.argv[1])
resources = os.path.join(app, "Contents", "Resources")
libdir = os.path.join(resources, "engine", "lib", "darktable")

# bundled library name prefix -> (component, Homebrew formula, licence, home page, extra licence files)
LIBRARIES = {
    "libbrotli": ("Brotli", "brotli", "MIT", "https://github.com/google/brotli", []),
    "libexiv2": ("Exiv2", "exiv2", "GPL-2.0-or-later", "https://exiv2.org", []),
    "libgio": ("GLib", "glib", "LGPL-2.1-or-later", "https://gitlab.gnome.org/GNOME/glib", ["Licences/LGPL-2.1.txt"]),
    "libglib": ("GLib", "glib", None, None, []),
    "libgmodule": ("GLib", "glib", None, None, []),
    "libgobject": ("GLib", "glib", None, None, []),
    "libgthread": ("GLib", "glib", None, None, []),
    "libImath": ("Imath", "imath", "BSD-3-Clause", "https://github.com/AcademySoftwareFoundation/Imath", []),
    "libinih": ("inih", "inih", "BSD-3-Clause", "https://github.com/benhoyt/inih", []),
    "libINIReader": ("inih", "inih", None, None, []),
    # libintl is LGPL; the formula's COPYING is the GPL of gettext's tools
    "libintl": ("gettext (libintl)", "gettext", "LGPL-2.1-or-later", "https://www.gnu.org/software/gettext/", ["Licences/LGPL-2.1.txt"]),
    "libjpeg": ("libjpeg-turbo", "jpeg-turbo", "IJG, BSD-3-Clause and Zlib", "https://libjpeg-turbo.org", []),
    "libjson-glib": ("JSON-GLib", "json-glib", "LGPL-2.1-or-later", "https://gitlab.gnome.org/GNOME/json-glib", ["Licences/LGPL-2.1.txt"]),
    "liblcms2": ("Little CMS", "little-cms2", "MIT", "https://www.littlecms.com", []),
    "liblensfun": ("Lensfun", "lensfun", "LGPL-3.0 (library); CC BY-SA 3.0 (lens database)", "https://lensfun.github.io",
                   ["Licences/LGPL-3.0.txt", "Licences/Lensfun-database.txt"]),
    "liblzma": ("XZ Utils (liblzma)", "xz", "0BSD", "https://tukaani.org/xz/", []),
    "libomp": ("LLVM OpenMP runtime", "libomp", "Apache-2.0 WITH LLVM-exception", "https://openmp.llvm.org", []),
    "libpcre2": ("PCRE2", "pcre2", "BSD-3-Clause WITH PCRE2-exception", "https://www.pcre.org", []),
    "libpng": ("libpng", "libpng", "libpng-2.0", "http://www.libpng.org/pub/png/libpng.html", []),
    "libpotrace": ("Potrace", "potrace", "GPL-2.0-or-later", "https://potrace.sourceforge.net", []),
    "libpugixml": ("pugixml", "pugixml", "MIT", "https://pugixml.org", []),
    "libtiff": ("LibTIFF", "libtiff", "libtiff", "https://libtiff.gitlab.io/libtiff/", []),
    "libzstd": ("Zstandard", "zstd", "BSD-3-Clause", "https://facebook.github.io/zstd/", []),
    # darktable's own library, and Darkslide's stand-ins for its interface libraries
    "libdarktable": None,
    "libMetalCL": None,
}


def files_in(prefix):
    out = []
    for pattern in ("LICEN[CS]E*", "COPYING*", "COPYRIGHT*", "NOTICE*"):
        out += sorted(glob.glob(os.path.join(prefix, pattern)))
    # xz's COPYING lists which licence covers what; liblzma is 0BSD
    return [f for f in out if not os.path.basename(f).startswith("COPYING.") or f.endswith("0BSD")]


def formula_prefix(formula):
    opt = subprocess.run(["brew", "--prefix", formula], capture_output=True, text=True, check=True).stdout.strip()
    return os.path.realpath(opt)


# what the engine bundles, each library under its component
unlisted = []
components = {}      # component -> (version, licence, url, files)
for path in sorted(glob.glob(os.path.join(libdir, "*.dylib"))):
    name = os.path.basename(path)
    if name.endswith("-stub.dylib"):
        continue
    key = max((k for k in LIBRARIES if name.startswith(k)), key=len, default=None)
    if key is None:
        unlisted.append(name)
        continue
    entry = LIBRARIES[key]
    if entry is None:
        continue
    component, formula, licence, url, extra = entry
    if component in components:
        continue
    if licence is None:
        # a further library of a component listed under another name
        first = next(v for v in LIBRARIES.values() if v and v[0] == component and v[2])
        _, formula, licence, url, extra = first
    prefix = formula_prefix(formula)
    own = [] if formula == "gettext" else files_in(prefix)
    components[component] = (os.path.basename(prefix).split("_")[0], licence, url, own + [os.path.join(ROOT, e) for e in extra])
if unlisted:
    sys.exit("no acknowledgement for " + ", ".join(unlisted) + ": add it to LIBRARIES in Scripts/notices.py")

sections = []
sections.append(("Darkslide", None, "GPL-3.0-or-later", "https://github.com/FraserEmbrey/darkroom-native",
                 [os.path.join(ROOT, "LICENSE")],
                 "Copyright (C) 2026 Fraser Embrey and contributors.\n\n"
                 "This program is free software: you can redistribute it and/or modify it under the terms of the "
                 "GNU General Public License as published by the Free Software Foundation, either version 3 of the "
                 "License, or (at your option) any later version. It comes with NO WARRANTY. The source code of "
                 "this version, with the changes made to darktable, is at the address above."))
sections.append(("darktable", "5.6.2", "GPL-3.0-or-later", "https://www.darktable.org",
                 [os.path.join(DT_SRC, "LICENSE")],
                 "The engine is darktable, built from its 5.6.2 release with the patches in Engine/patches. "
                 "Its GPU kernels run on Metal translated from darktable's OpenCL code. Its authors are listed at "
                 "https://github.com/darktable-org/darktable/blob/release-5.6.2/AUTHORS."))
sections.append(("rawspeed (in darktable)", None, "LGPL-2.1-or-later", "https://github.com/darktable-org/rawspeed",
                 [os.path.join(DT_SRC, "src/external/rawspeed/LICENSE")], None))
sections.append(("LibRaw (in darktable)", None, "LGPL-2.1 or CDDL-1.0", "https://www.libraw.org",
                 [os.path.join(DT_SRC, "src/external/LibRaw", f) for f in ("COPYRIGHT", "LICENSE.LGPL")], None))
sections.append(("whereami (in darktable)", None, "MIT or WTFPL-2.0", "https://github.com/gpakosz/whereami",
                 [os.path.join(DT_SRC, "src/external/whereami/LICENSE.MIT")], None))
for component, (version, licence, url, files) in sorted(components.items(), key=lambda c: c[0].lower()):
    sections.append((component, version, licence, url, files, None))
# the models: downloaded on first use, or built in when Models/ has them
sections.append(("Raw denoise model (RawNIND)", None, "GPL-3.0", "https://github.com/trougnouf/rawnind_jddc", [],
                 "darktable's rawdenoise-nind model (https://github.com/darktable-org/darktable-ai), converted to "
                 "Core ML. From Brummer and De Vleeschouwer, \"Learning Joint Denoising, Demosaicing, and "
                 "Compression from the Raw Natural Image Noise Dataset\" (2025). Licence text: as for Darkslide, above."))
sections.append(("Rescue Focus models (Restormer)", None, "MIT", "https://github.com/swz30/Restormer",
                 [os.path.join(ROOT, "Licences/Restormer.txt")],
                 "Restormer's defocus and motion deblurring models (Zamir et al., CVPR 2022), converted to Core ML."))

# each licence text once: later parts with the same text refer back to the first
seen = {}
out = ["Darkslide: acknowledgements and licences", "=" * 40, "",
       "Darkslide is free software under the GNU General Public License, version 3 or later. It is built on",
       "darktable and the libraries below, each under its own licence, given here in full.", ""]
for name, version, licence, url, files, note in sections:
    title = f"{name} {version}" if version else name
    out += ["", "-" * 72, title, "-" * 72, f"Licence: {licence}", f"Home: {url}", ""]
    if note:
        out += [note, ""]
    for f in files:
        text = open(f, encoding="utf-8", errors="replace").read().strip()
        digest = hashlib.sha256(" ".join(text.split()).encode()).hexdigest()
        if digest in seen:
            out += [f"({os.path.basename(f)}: the same text as under {seen[digest]}, above.)", ""]
        else:
            seen[digest] = title
            out += [text, ""]
open(os.path.join(resources, "Acknowledgements.txt"), "w").write("\n".join(out) + "\n")

# the About panel's credits
info = plistlib.load(open(os.path.join(app, "Contents", "Info.plist"), "rb"))
source = info.get("DarkslideSourceURL", "")
style = "font: 11px -apple-system; text-align: center; color: #888"
credits = f"""<html><body style="{style}">
<p>A Mac app for editing raw photos with darktable's engine.</p>
<p>Free software under the <a href="https://www.gnu.org/licenses/gpl-3.0.html">GNU GPL, version 3 or later</a>.
It comes with no warranty.</p>
<p><a href="{source}">Source code</a></p>
<p>Built on darktable 5.6.2 and {len(components)} other libraries, with models from RawNIND and Restormer.
Help &rsaquo; Acknowledgements lists them with their licences.</p>
</body></html>
"""
open(os.path.join(resources, "Credits.html"), "w").write(credits)
print(f"acknowledged darktable, {len(components)} libraries and 2 models")
