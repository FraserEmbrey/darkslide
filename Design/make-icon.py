#!/usr/bin/env python3
"""Generates Darkslide's app icon: darktable's six-colour aperture redrawn as a
real iris, each blade lying on the next, around a hexagonal opening. Writes
Icon Composer layers (AppIcon.icon, compiled by Scripts/build-app.sh) and a
flat preview (preview.svg)."""
import json, math, os, sys

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
C = 512.0             # canvas centre (1024 x 1024)
R = 356.0             # aperture radius
r = 84.0              # opening: hexagon centre to vertex
TWIST = -95.0       # rotation of the whole iris, degrees: red at the top left, as in darktable's logo
# darktable's colours, clockwise from the top left
COLOURS = ["#d0302c", "#ee7b2c", "#f6d73a", "#4fae3d", "#3b74d9", "#9b2fb0"]

def pt(a, d):
    t = math.radians(a)
    return (C + d * math.cos(t), C + d * math.sin(t))

def sub(p, q): return (p[0] - q[0], p[1] - q[1])
def add(p, q): return (p[0] + q[0], p[1] + q[1])
def mul(p, k): return (p[0] * k, p[1] * k)

def ray_circle(p, d):
    """where the ray from p along d leaves the circle"""
    px, py = p[0] - C, p[1] - C
    b = px * d[0] + py * d[1]
    c = px * px + py * py - R * R
    a = d[0] ** 2 + d[1] ** 2
    t = (-b + math.sqrt(b * b - a * c)) / a
    return add(p, mul(d, t))

def intersect(p, d, q, e):
    """intersection of the lines p + t d and q + s e"""
    den = d[0] * e[1] - d[1] * e[0]
    t = ((q[0] - p[0]) * e[1] - (q[1] - p[1]) * e[0]) / den
    return add(p, mul(d, t))

def angle(p): return math.degrees(math.atan2(p[1] - C, p[0] - C))

def arc(a_from, a_to, steps=48):
    """points along the circle from one angle to another, the short way"""
    d = (a_to - a_from + 540) % 360 - 180
    return [pt(a_from + d * i / steps, R) for i in range(1, steps)]

# hexagon vertices; side k runs H[k] -> H[k+1], and its extension past
# H[k+1] is the edge between blades k and k+1
H = [pt(TWIST - 90 + 60 * k, r) for k in range(6)]
D = [sub(H[(k + 1) % 6], H[k]) for k in range(6)]
Q = [ray_circle(H[(k + 1) % 6], D[k]) for k in range(6)]

def base_blade(k):
    """blade k with no overlap: between the extensions of sides k-1 and k"""
    return [H[k], Q[k]] + arc(angle(Q[k]), angle(Q[(k - 1) % 6])) + [Q[(k - 1) % 6]]

def centroid(points):
    return (sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points))

def normal_into(j, k):
    """unit normal of line j (side j and its extension), pointing into blade k"""
    nx, ny = D[j][1], -D[j][0]
    n = math.hypot(nx, ny)
    nx, ny = nx / n, ny / n
    c = centroid(base_blade(k))
    if (c[0] - H[(j + 1) % 6][0]) * nx + (c[1] - H[(j + 1) % 6][1]) * ny < 0: nx, ny = -nx, -ny
    return (nx, ny)

def path(points):
    return "M" + " L".join(f"{x:.2f},{y:.2f}" for x, y in points) + " Z"

def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            + body + "</svg>\n")

SHADOW = 48.0         # width of the shadow the blade above casts
LIGHT = 5.0           # width of the lit edge along each blade's leading side

def strip(p0, p1, normal, width, inner_dir):
    """band along the segment p0-p1 on the normal's side, ending at the rim
    and, at p0, on the blade's other edge (through p0 along inner_dir), so it
    stays inside the blade"""
    edge = sub(p1, p0)
    far = add(p0, mul(normal, width))
    c = ray_circle(far, edge)
    d = intersect(far, edge, p0, inner_dir)
    return [p0, p1] + arc(angle(p1), angle(c), 12) + [c, d]

def blade_svg(k):
    """Blade k, opaque, with the overlap painted in: a soft shadow along the
    edge where blade k-1 lies on it, and a lit rim along its own leading
    edge, which lies on blade k+1. All six joins read the same way round, as
    on a real iris, which stacking alone can't do (it would need six levels
    in a loop)."""
    j = (k - 1) % 6
    shape = base_blade(k)
    # trailing edge: the extension of side k-1, from H[k] to the rim
    sh_n = normal_into(j, k)
    shadow = strip(H[k], Q[j], sh_n, SHADOW, D[k])
    # leading edge: side k extended, from H[k] to the rim; lit on blade k's side
    li_n = normal_into(k, k)
    light = strip(H[k], Q[k], li_n, LIGHT, D[j])
    gx1, gy1 = H[k]
    gx2, gy2 = add(H[k], mul(sh_n, SHADOW))
    return svg(
        "<defs>"
        f'<linearGradient id="s{k}" gradientUnits="userSpaceOnUse" x1="{gx1:.2f}" y1="{gy1:.2f}" x2="{gx2:.2f}" y2="{gy2:.2f}">'
        '<stop offset="0" stop-color="#000" stop-opacity="0.42"/>'
        '<stop offset="0.35" stop-color="#000" stop-opacity="0.16"/>'
        '<stop offset="1" stop-color="#000" stop-opacity="0"/>'
        "</linearGradient></defs>"
        f'<path d="{path(shape)}" fill="{COLOURS[k]}"/>'
        f'<path d="{path(shadow)}" fill="url(#s{k})"/>'
        f'<path d="{path(light)}" fill="#fff" fill-opacity="0.38"/>')

BARREL = 44.0         # width of the ring that slopes from the tile down to the blades

def barrel_svg():
    """The lens barrel: a ring from the tile's surface down to the iris, light
    at its outer edge and darker as it goes in, so the aperture sits deep."""
    outer, inner = R + BARREL, R - 6
    stop = inner / outer
    return svg(
        '<defs><radialGradient id="b" cx="512" cy="512" r="%.1f" gradientUnits="userSpaceOnUse">' % outer
        + f'<stop offset="{stop:.3f}" stop-color="#5d5e66"/>'
        + f'<stop offset="{stop + (1 - stop) * 0.35:.3f}" stop-color="#a9aab2"/>'
        + '<stop offset="1" stop-color="#eeeef1"/></radialGradient></defs>'
        # a ring as one path: outer circle, then the inner one the other way round
        + f'<path fill-rule="evenodd" fill="url(#b)" d="M{C + outer},{C} A{outer},{outer} 0 1,0 {C - outer},{C} '
        + f'A{outer},{outer} 0 1,0 {C + outer},{C} Z M{C + inner},{C} A{inner},{inner} 0 1,1 {C - inner},{C} '
        + f'A{inner},{inner} 0 1,1 {C + inner},{C} Z"/>')

def rim_shade_svg():
    """the blades darken towards the rim, deep inside the barrel"""
    return svg(
        f'<defs><radialGradient id="v" cx="512" cy="512" r="{R:.1f}" gradientUnits="userSpaceOnUse">'
        '<stop offset="0.55" stop-color="#000" stop-opacity="0"/>'
        '<stop offset="0.86" stop-color="#000" stop-opacity="0.16"/>'
        '<stop offset="1" stop-color="#000" stop-opacity="0.45"/></radialGradient></defs>'
        f'<circle cx="{C}" cy="{C}" r="{R}" fill="url(#v)"/>')

layers = [("opening", svg(f'<circle cx="{C}" cy="{C}" r="{R - 2}" fill="#16161a"/>'))]
layers += [(f"blade-{k}", blade_svg(k)) for k in range(6)]
layers += [("rim-shade", rim_shade_svg()), ("barrel", barrel_svg())]

icon = os.path.join(OUT, "AppIcon.icon")
assets = os.path.join(icon, "Assets")
os.makedirs(assets, exist_ok=True)
for f in os.listdir(assets): os.remove(os.path.join(assets, f))
for name, content in layers:
    with open(os.path.join(assets, f"{name}.svg"), "w") as f: f.write(content)

spec = {
    "fill": {"automatic-gradient": "extended-srgb:0.96000,0.96000,0.97000,1.00000"},
    "groups": [
        {   # the barrel, above the blades so it casts its shadow into the aperture
            "layers": [{"image-name": "barrel.svg", "name": "barrel", "glass": True}],
            "shadow": {"kind": "neutral", "opacity": 0.6},
            "translucency": {"enabled": False, "value": 0},
            "specular": True,
        },
        {   # the blades: one glass piece, top layer first
            "layers": [{"image-name": "rim-shade.svg", "name": "rim-shade", "glass": False}]
                      + [{"image-name": f"blade-{k}.svg", "name": f"blade-{k}", "glass": True} for k in range(6)],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": True, "value": 0.15},
            "specular": True,
        },
        {   # the dark opening behind
            "layers": [{"image-name": "opening.svg", "name": "opening", "glass": False}],
            "shadow": {"kind": "none", "opacity": 0},
            "translucency": {"enabled": False, "value": 0},
        },
    ],
    "supported-platforms": {"squares": "shared"},
}
with open(os.path.join(icon, "icon.json"), "w") as f: json.dump(spec, f, indent=2)

# a flat preview of the artwork, on the squircle
inner = "".join(c[c.index(">") + 1:c.rindex("</svg>")] for _, c in layers)
with open(os.path.join(OUT, "preview.svg"), "w") as f:
    f.write(svg('<rect x="100" y="100" width="824" height="824" rx="185" fill="#f2f2f4"/>' + inner))
print("wrote", icon)
