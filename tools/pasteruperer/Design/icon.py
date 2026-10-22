#!/usr/bin/env python3
"""Draws Pasteruperer's app icon concepts as SVG.

Futuristic graffiti and paste-ups: concrete walls, torn wheatpasted posters, halftone, spray paint,
drips and neon. Run `python3 icon.py <out dir>` to write concept-a/b/c.html, then render each to a
1024px PNG with headless Chrome (see render.sh).
"""
import math
import random
import sys
from pathlib import Path

SIZE = 1024
# macOS icon grid: the body is an 824pt rounded square inset 100pt.
BODY = (100, 100, 824, 824)
RADIUS = 185

NEON_CYAN = "#22f3ff"
NEON_PINK = "#ff2d8a"
ACID = "#d7ff3a"
PAPER = "#f2ead7"
INK = "#15131a"


def fmt(points):
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in points)


def torn(x, y, w, h, seed, amp=7, step=11):
    """A rectangle with ripped, fibrous edges."""
    rng = random.Random(seed)
    points = []

    def edge(x0, y0, x1, y1, nx, ny):
        length = math.hypot(x1 - x0, y1 - y0)
        count = max(2, int(length / step))
        for i in range(count):
            t = i / count
            jitter = rng.uniform(-amp, amp)
            if rng.random() < 0.07:
                jitter += rng.uniform(amp, amp * 3.5)  # an occasional bite out of the edge
            points.append((x0 + (x1 - x0) * t + nx * jitter, y0 + (y1 - y0) * t + ny * jitter))

    edge(x, y, x + w, y, 0, 1)
    edge(x + w, y, x + w, y + h, -1, 0)
    edge(x + w, y + h, x, y + h, 0, -1)
    edge(x, y + h, x, y, 1, 0)
    return "M" + " L".join(f"{a:.1f},{b:.1f}" for a, b in points) + "Z"


def chaikin(points, iterations=4):
    for _ in range(iterations):
        smoothed = [points[0]]
        for (x0, y0), (x1, y1) in zip(points, points[1:]):
            smoothed += [(0.75 * x0 + 0.25 * x1, 0.75 * y0 + 0.25 * y1), (0.25 * x0 + 0.75 * x1, 0.25 * y0 + 0.75 * y1)]
        smoothed.append(points[-1])
        points = smoothed
    return points


def path(points):
    return "M" + " L".join(f"{x:.1f},{y:.1f}" for x, y in points)


def overspray(points, seed, color, count=420, sigma=24, max_r=3.2):
    """Fine dots scattered around a sprayed line."""
    rng = random.Random(seed)
    dots = []
    for _ in range(count):
        x, y = rng.choice(points)
        distance = abs(rng.gauss(0, sigma)) + 10
        angle = rng.uniform(0, math.tau)
        r = rng.uniform(0.6, max_r) * max(0.25, 1 - distance / (sigma * 4))
        dots.append(f'<circle cx="{x + math.cos(angle) * distance:.1f}" cy="{y + math.sin(angle) * distance:.1f}" r="{r:.2f}" fill="{color}" opacity="{rng.uniform(0.35, 0.9):.2f}"/>')
    return "\n".join(dots)


def drips(starts, seed, color, width=(13, 22), length=(40, 150)):
    rng = random.Random(seed)
    out = []
    for x, y in starts:
        w = rng.uniform(*width)
        l = rng.uniform(*length)
        out.append(
            f'<path d="M{x - w / 2:.1f},{y:.1f} C{x - w / 2:.1f},{y + l * 0.6:.1f} {x - w * 0.35:.1f},{y + l:.1f} {x:.1f},{y + l:.1f} '
            f'C{x + w * 0.35:.1f},{y + l:.1f} {x + w / 2:.1f},{y + l * 0.6:.1f} {x + w / 2:.1f},{y:.1f}Z" fill="{color}"/>'
            f'<circle cx="{x:.1f}" cy="{y + l - w * 0.15:.1f}" r="{w * 0.62:.1f}" fill="{color}"/>'
        )
    return "\n".join(out)


def halftone(cx, cy, radius, color, spacing=17, angle=15, power=0.8):
    """A disc of dots that shrink towards its edge."""
    dots = []
    a = math.radians(angle)
    steps = int(radius / spacing) + 2
    for i in range(-steps, steps + 1):
        for j in range(-steps, steps + 1):
            x = i * spacing * math.cos(a) - j * spacing * math.sin(a)
            y = i * spacing * math.sin(a) + j * spacing * math.cos(a)
            d = math.hypot(x, y)
            if d > radius:
                continue
            r = spacing * 0.56 * (1 - d / radius) ** power
            if r > 0.6:
                dots.append(f'<circle cx="{cx + x:.1f}" cy="{cy + y:.1f}" r="{r:.2f}"/>')
    return f'<g fill="{color}">' + "".join(dots) + "</g>"


def text_lines(x, y, widths, gap=24, height=10, color=INK, opacity=0.8):
    return "".join(
        f'<rect x="{x}" y="{y + i * gap}" width="{w}" height="{height}" rx="2" fill="{color}" opacity="{opacity}"/>'
        for i, w in enumerate(widths)
    )


def sparkle(cx, cy, size, color):
    s = size
    return (f'<path d="M{cx},{cy - s} C{cx + s * 0.12},{cy - s * 0.12} {cx + s * 0.12},{cy - s * 0.12} {cx + s},{cy} '
            f'C{cx + s * 0.12},{cy + s * 0.12} {cx + s * 0.12},{cy + s * 0.12} {cx},{cy + s} '
            f'C{cx - s * 0.12},{cy + s * 0.12} {cx - s * 0.12},{cy + s * 0.12} {cx - s},{cy} '
            f'C{cx - s * 0.12},{cy - s * 0.12} {cx - s * 0.12},{cy - s * 0.12} {cx},{cy - s}Z" fill="{color}" filter="url(#glow-soft)"/>')


DEFS = f"""
<clipPath id="body"><rect x="{BODY[0]}" y="{BODY[1]}" width="{BODY[2]}" height="{BODY[3]}" rx="{RADIUS}"/></clipPath>
<filter id="grain" x="0" y="0" width="100%" height="100%">
  <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="4" stitchTiles="stitch"/>
  <feColorMatrix type="saturate" values="0"/>
</filter>
<filter id="stains" x="0" y="0" width="100%" height="100%">
  <feTurbulence type="fractalNoise" baseFrequency="0.006 0.012" numOctaves="4" seed="11"/>
  <feColorMatrix type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -2.2 1.5"/>
</filter>
<filter id="wrinkle" x="0" y="0" width="100%" height="100%">
  <feTurbulence type="fractalNoise" baseFrequency="0.011 0.026" numOctaves="4" seed="9" result="t"/>
  <feDiffuseLighting in="t" surfaceScale="5" lighting-color="#ffffff"><feDistantLight azimuth="235" elevation="52"/></feDiffuseLighting>
</filter>
<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">
  <feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.5"/>
</filter>
<filter id="shadow-tight" x="-20%" y="-20%" width="140%" height="140%">
  <feDropShadow dx="2" dy="5" stdDeviation="4" flood-color="#000" flood-opacity="0.45"/>
</filter>
<filter id="glow" x="-40%" y="-40%" width="180%" height="180%">
  <feGaussianBlur stdDeviation="14" result="wide"/>
  <feGaussianBlur in="SourceGraphic" stdDeviation="4" result="near"/>
  <feMerge><feMergeNode in="wide"/><feMergeNode in="wide"/><feMergeNode in="near"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<filter id="glow-soft" x="-60%" y="-60%" width="220%" height="220%">
  <feGaussianBlur stdDeviation="6" result="b"/>
  <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
</filter>
<filter id="spray" x="-10%" y="-10%" width="120%" height="120%">
  <feTurbulence type="fractalNoise" baseFrequency="0.7" numOctaves="1" seed="2" result="n"/>
  <feDisplacementMap in="SourceGraphic" in2="n" scale="7"/>
</filter>
<linearGradient id="sheen" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#fff" stop-opacity="0.32"/>
  <stop offset="0.45" stop-color="#fff" stop-opacity="0.04"/>
  <stop offset="1" stop-color="#000" stop-opacity="0.25"/>
</linearGradient>
<pattern id="dots" width="13" height="13" patternUnits="userSpaceOnUse" patternTransform="rotate(22)">
  <circle cx="6.5" cy="6.5" r="3.4" fill="{INK}"/>
</pattern>
"""


def wall(base="#24222b", stain_opacity=0.35, grain_opacity=0.32, bricks=False):
    out = [f'<rect x="0" y="0" width="{SIZE}" height="{SIZE}" fill="{base}"/>']
    if bricks:
        rows = []
        for row, y in enumerate(range(80, SIZE, 62)):
            rows.append(f'<line x1="0" y1="{y}" x2="{SIZE}" y2="{y}"/>')
            offset = 0 if row % 2 else 70
            for x in range(offset, SIZE, 140):
                rows.append(f'<line x1="{x}" y1="{y}" x2="{x}" y2="{y + 62}"/>')
        out.append(f'<g stroke="#000" stroke-width="5" opacity="0.28">{"".join(rows)}</g>')
    out.append(f'<rect width="{SIZE}" height="{SIZE}" filter="url(#stains)" opacity="{stain_opacity}"/>')
    out.append(f'<rect width="{SIZE}" height="{SIZE}" filter="url(#grain)" opacity="{grain_opacity}" style="mix-blend-mode:overlay"/>')
    return "\n".join(out)


def paste_up(shape_id, d, fill, core="#fffaf0", content="", transform="", wrinkle=0.45, shadow="shadow"):
    """A wheatpasted sheet: white paper core showing at the rip, ink, wrinkles and a glossy paste sheen."""
    return f"""
<g transform="{transform}" filter="url(#{shadow})">
  <clipPath id="{shape_id}"><path d="{d}"/></clipPath>
  <path d="{d}" fill="{core}" transform="translate(-3,-3) scale(1.006)"/>
  <path d="{d}" fill="{fill}"/>
  <g clip-path="url(#{shape_id})">
    {content}
    <rect width="{SIZE}" height="{SIZE}" filter="url(#wrinkle)" opacity="{wrinkle}" style="mix-blend-mode:multiply"/>
    <rect width="{SIZE}" height="{SIZE}" filter="url(#grain)" opacity="0.18" style="mix-blend-mode:multiply"/>
    <rect width="{SIZE}" height="{SIZE}" fill="url(#sheen)" style="mix-blend-mode:soft-light"/>
  </g>
</g>"""


def stencil_p(fill=INK, gap=PAPER):
    """A chunky stencil P (bridges cut where the bowl meets the stem)."""
    return f"""
<path fill-rule="evenodd" fill="{fill}" d="M330,300 H530 A152,152 0 0 1 530,604 H426 V770 H330 Z M426,382 H522 A70,70 0 0 1 522,522 H426 Z"/>
<rect x="426" y="296" width="18" height="90" fill="{gap}"/>
<rect x="426" y="518" width="18" height="90" fill="{gap}"/>"""


def frame(content):
    """Clips art to the icon body and adds a rim light."""
    x, y, w, h = BODY
    return f"""
<g filter="url(#body-shadow)">
  <g clip-path="url(#body)">{content}</g>
</g>
<rect x="{x + 1.5}" y="{y + 1.5}" width="{w - 3}" height="{h - 3}" rx="{RADIUS - 1}" fill="none" stroke="#fff" stroke-opacity="0.18" stroke-width="3"/>
"""


def document(content):
    return f"""<!doctype html><html><head><style>html,body{{margin:0;background:transparent}}svg{{display:block}}</style></head><body>
<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}">
<defs>{DEFS}
<filter id="body-shadow" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="12" stdDeviation="14" flood-color="#000" flood-opacity="0.35"/></filter>
</defs>
{frame(content)}
</svg></body></html>"""


# MARK: Concept A — a single wheatpasted poster with a neon "post it" arrow sprayed across it.

def concept_a():
    poster = torn(205, 185, 600, 660, seed=21, amp=8)
    poster_content = f"""
{halftone(560, 420, 215, NEON_PINK, spacing=19, power=0.7)}
{stencil_p()}
{text_lines(470, 650, [250, 210, 236, 150], gap=28, height=12)}
<rect x="470" y="770" width="96" height="14" fill="{NEON_PINK}"/>"""

    scraps = (
        paste_up("scrap-y", torn(520, 90, 380, 260, seed=3, amp=9), "#f4c430", transform="rotate(9 700 220)",
                 content=f'<rect x="540" y="150" width="400" height="200" fill="url(#dots)" opacity="0.35"/>')
        + paste_up("scrap-c", torn(80, 600, 300, 340, seed=5, amp=9), "#7fe3f0", transform="rotate(-12 230 770)",
                   content=text_lines(110, 650, [210, 180, 220, 160, 200, 120], gap=34, height=14, opacity=0.55))
    )

    arrow = chaikin([(205, 840), (300, 760), (420, 720), (520, 650), (600, 540), (690, 400), (760, 300)])
    head = f'<path d="M700,268 L792,250 L770,342" fill="none" stroke="{NEON_CYAN}" stroke-width="34" stroke-linecap="round" stroke-linejoin="round"/>'
    spray = f"""
<g filter="url(#spray)">
  {overspray(arrow, seed=8, color=NEON_CYAN, count=520)}
  <g filter="url(#glow)">
    <path d="{path(arrow)}" fill="none" stroke="{NEON_CYAN}" stroke-width="34" stroke-linecap="round" stroke-linejoin="round"/>
    {head}
    {drips([(318, 770), (452, 708), (560, 610)], seed=4, color=NEON_CYAN, length=(50, 120))}
  </g>
  <path d="{path(arrow)}" fill="none" stroke="#e9feff" stroke-width="9" stroke-linecap="round" opacity="0.85"/>
</g>"""

    return document(f"""
{wall(base="#26232c", bricks=True)}
{scraps}
{paste_up("poster", poster, PAPER, content=poster_content, transform="rotate(-5 505 515)")}
{spray}
{sparkle(800, 640, 34, "#ffffff")}
{sparkle(255, 255, 22, ACID)}
""")


# MARK: Concept B — a chrome fountain-pen nib that sprays neon paint.

def concept_b():
    floor_lines = []
    horizon = 690
    for i in range(-9, 10):
        floor_lines.append(f'<line x1="{512 + i * 26}" y1="{horizon}" x2="{512 + i * 150}" y2="{SIZE}"/>')
    y, gap = horizon, 10
    while y < SIZE:
        floor_lines.append(f'<line x1="0" y1="{y:.1f}" x2="{SIZE}" y2="{y:.1f}"/>')
        y += gap
        gap *= 1.35
    grid = f'<g stroke="{NEON_PINK}" stroke-width="3" opacity="0.55" filter="url(#glow-soft)">{"".join(floor_lines)}</g>'

    sky = f"""
<linearGradient id="dusk" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#0d0a1f"/><stop offset="0.62" stop-color="#3a0f4d"/><stop offset="0.68" stop-color="#ff2d8a" stop-opacity="0.55"/><stop offset="0.7" stop-color="#140a22"/>
</linearGradient>
<linearGradient id="chrome" x1="0" y1="0" x2="1" y2="0.2">
  <stop offset="0" stop-color="#6b6f80"/><stop offset="0.18" stop-color="#f4f6ff"/><stop offset="0.34" stop-color="#9aa0b5"/>
  <stop offset="0.5" stop-color="#ffffff"/><stop offset="0.62" stop-color="#7b8094"/><stop offset="0.8" stop-color="#e7eaf5"/><stop offset="1" stop-color="#4c5062"/>
</linearGradient>
<linearGradient id="holo" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="{NEON_CYAN}"/><stop offset="0.5" stop-color="#b16cff"/><stop offset="1" stop-color="{NEON_PINK}"/>
</linearGradient>"""

    nib = "M512,850 C468,712 396,610 378,474 C370,410 390,326 420,282 L604,282 C634,326 654,410 646,474 C628,610 556,712 512,850 Z"
    nib_group = f"""
<g transform="rotate(-28 512 560)" filter="url(#shadow)">
  <path d="{nib}" fill="url(#chrome)"/>
  <path d="{nib}" fill="url(#holo)" opacity="0.42" style="mix-blend-mode:color"/>
  <path d="M420,282 L604,282 L600,318 L424,318 Z" fill="#2b2d38" opacity="0.55"/>
  <path d="M446,470 C470,420 554,420 578,470" fill="none" stroke="#2b2d38" stroke-width="7" opacity="0.6"/>
  <circle cx="512" cy="540" r="24" fill="#120e1c"/>
  <line x1="512" y1="562" x2="512" y2="846" stroke="#120e1c" stroke-width="7"/>
  <path d="{nib}" fill="none" stroke="#fff" stroke-opacity="0.6" stroke-width="3"/>
</g>"""

    # Paint bursts from the nib's tip (512,850 rotated -28° about 512,560).
    angle = math.radians(-28)
    tip_x = 512 - 290 * math.sin(angle)
    tip_y = 560 + 290 * math.cos(angle)
    rng = random.Random(14)
    splat = []
    for _ in range(26):
        angle = rng.uniform(-0.3, math.pi + 0.3)
        distance = rng.uniform(50, 170)
        splat.append(f'<circle cx="{tip_x + math.cos(angle) * distance:.1f}" cy="{tip_y + 30 + math.sin(angle) * distance * 0.5:.1f}" r="{rng.uniform(3, 12):.1f}"/>')
    splat_path = (f"M{tip_x - 70:.0f},{tip_y + 30:.0f} C{tip_x - 80:.0f},{tip_y - 10:.0f} {tip_x - 30:.0f},{tip_y - 20:.0f} {tip_x:.0f},{tip_y + 5:.0f} "
                  f"C{tip_x + 40:.0f},{tip_y - 25:.0f} {tip_x + 95:.0f},{tip_y:.0f} {tip_x + 75:.0f},{tip_y + 40:.0f} "
                  f"C{tip_x + 100:.0f},{tip_y + 70:.0f} {tip_x + 40:.0f},{tip_y + 90:.0f} {tip_x + 10:.0f},{tip_y + 70:.0f} "
                  f"C{tip_x - 30:.0f},{tip_y + 95:.0f} {tip_x - 100:.0f},{tip_y + 80:.0f} {tip_x - 70:.0f},{tip_y + 30:.0f} Z")
    paint = f"""
<g filter="url(#glow)">
  <g fill="{NEON_PINK}" filter="url(#spray)">
    <path d="{splat_path}"/>
    {"".join(splat)}
  </g>
  {drips([(tip_x - 40, tip_y + 60), (tip_x + 5, tip_y + 70), (tip_x + 50, tip_y + 55)], seed=6, color=NEON_PINK, length=(50, 110))}
</g>"""

    poster = paste_up("b-poster", torn(560, 160, 300, 400, seed=31, amp=8), "#7ff6ff", transform="rotate(8 710 360)",
                      content=f'{halftone(710, 330, 150, INK, spacing=15)}{text_lines(600, 470, [200, 160, 180], gap=24, height=11)}')

    return document(f"""
<defs>{sky}</defs>
<rect width="{SIZE}" height="{SIZE}" fill="url(#dusk)"/>
<rect width="{SIZE}" height="{SIZE}" filter="url(#stains)" opacity="0.25"/>
{grid}
<circle cx="512" cy="690" r="210" fill="{NEON_PINK}" opacity="0.18" filter="url(#glow)"/>
{poster}
{nib_group}
{paint}
{overspray([(tip_x - 40, tip_y + 30), (tip_x, tip_y + 20), (tip_x + 40, tip_y + 30)], seed=3, color=NEON_PINK, count=200, sigma=45)}
<rect width="{SIZE}" height="{SIZE}" filter="url(#grain)" opacity="0.22" style="mix-blend-mode:overlay"/>
{sparkle(760, 210, 30, "#fff")}
{sparkle(820, 700, 18, NEON_CYAN)}
""")


# MARK: Concept C — a wall of layered paste-ups with a neon wildstyle P tagged over the top.

def concept_c():
    sheets = [
        ("c1", torn(60, 70, 430, 520, seed=41), "#ece6d6", "rotate(-7 270 330)",
         f'{text_lines(110, 140, [320, 280, 300, 240, 310, 260, 300, 220, 290, 250, 280, 200, 300], gap=30, height=12, opacity=0.45)}'),
        ("c2", torn(470, 60, 470, 380, seed=42), "#f4c430", "rotate(6 700 250)",
         f'{halftone(720, 250, 200, "#c2185b", spacing=20)}'),
        ("c3", torn(520, 470, 420, 470, seed=43), "#7ff6ff", "rotate(-4 730 700)",
         f'<rect x="500" y="440" width="480" height="520" fill="url(#dots)" opacity="0.3"/>'),
        ("c4", torn(60, 560, 470, 400, seed=44), NEON_PINK, "rotate(5 290 760)",
         f'{text_lines(110, 640, [300, 260, 320, 200], gap=40, height=18, color="#fff", opacity=0.75)}'),
    ]
    wall_art = "".join(paste_up(i, d, fill, content=c, transform=t, shadow="shadow-tight") for i, d, fill, t, c in sheets)

    p = ("M330,250 C360,236 470,226 560,240 C690,260 726,388 652,470 C606,520 540,532 470,530 "
         "L458,640 C456,690 470,720 520,700 L600,640 L590,760 C520,820 380,830 352,740 C340,700 350,640 356,600 Z "
         "M468,330 L462,450 C520,456 576,430 572,384 C568,342 520,326 468,330 Z")
    extrude = "".join(f'<path d="{p}" fill="#2a0b3d" fill-rule="evenodd" transform="translate({i * 3},{i * 3})"/>' for i in range(1, 11))
    tag = f"""
<linearGradient id="tag-fill" x1="0" y1="0" x2="0.4" y2="1">
  <stop offset="0" stop-color="{ACID}"/><stop offset="0.45" stop-color="{NEON_CYAN}"/><stop offset="1" stop-color="#7a5cff"/>
</linearGradient>
<g transform="skewX(-8) translate(60,0)">
  <g filter="url(#glow)"><path d="{p}" fill="none" stroke="{NEON_PINK}" stroke-width="34" stroke-linejoin="round"/></g>
  {extrude}
  <path d="{p}" fill="url(#tag-fill)" fill-rule="evenodd" stroke="{INK}" stroke-width="16" stroke-linejoin="round" paint-order="stroke"/>
  <path d="M372,292 C420,272 500,268 556,280" fill="none" stroke="#fff" stroke-width="14" stroke-linecap="round" opacity="0.85"/>
  <path d="M388,330 L380,600" fill="none" stroke="#fff" stroke-width="10" stroke-linecap="round" opacity="0.6"/>
  {drips([(410, 800), (470, 812), (540, 790)], seed=12, color="#7a5cff", width=(18, 26), length=(50, 120))}
</g>"""
    arrow = f"""
<g filter="url(#glow)">
  <path d="M640,700 C720,640 760,560 790,470" fill="none" stroke="{NEON_PINK}" stroke-width="26" stroke-linecap="round"/>
  <path d="M745,488 L795,450 L820,512" fill="none" stroke="{NEON_PINK}" stroke-width="26" stroke-linecap="round" stroke-linejoin="round"/>
</g>"""

    return document(f"""
{wall(base="#1f1d24")}
{wall_art}
<rect width="{SIZE}" height="{SIZE}" fill="#0b0912" opacity="0.28"/>
<defs>{tag.split("<g transform")[0]}</defs>
{"<g transform" + tag.split("<g transform", 1)[1]}
{arrow}
{overspray(chaikin([(330, 250), (560, 240), (650, 470), (470, 530), (360, 740)]), seed=19, color=NEON_PINK, count=380, sigma=30)}
{sparkle(800, 250, 36, "#fff")}
{sparkle(250, 200, 20, NEON_CYAN)}
""")


if __name__ == "__main__":
    out = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    out.mkdir(parents=True, exist_ok=True)
    for name, make in [("concept-a", concept_a), ("concept-b", concept_b), ("concept-c", concept_c)]:
        (out / f"{name}.html").write_text(make())
        print(out / f"{name}.html")
