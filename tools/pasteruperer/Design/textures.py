#!/usr/bin/env python3
"""Seamless 512px textures for the app UI, drawn with the same SVG noise as the icon."""
import sys
from pathlib import Path

TILE = 512

def doc(body):
    return f"""<!doctype html><html><head><style>html,body{{margin:0;background:transparent}}svg{{display:block}}</style></head><body>
<svg xmlns="http://www.w3.org/2000/svg" width="{TILE}" height="{TILE}">{body}</svg></body></html>"""

CONCRETE = doc(f"""
<filter id="g" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" seed="4" stitchTiles="stitch"/><feColorMatrix type="saturate" values="0"/></filter>
<filter id="s" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="0.0078 0.0156" numOctaves="4" seed="11" stitchTiles="stitch"/>
<feColorMatrix type="matrix" values="0 0 0 0 0  0 0 0 0 0  0 0 0 0 0  0 0 0 -2.2 1.5"/></filter>
<rect width="{TILE}" height="{TILE}" fill="#1d1b22"/>
<rect width="{TILE}" height="{TILE}" filter="url(#s)" opacity="0.32"/>
<rect width="{TILE}" height="{TILE}" filter="url(#g)" opacity="0.28" style="mix-blend-mode:overlay"/>""")

PAPER = doc(f"""
<filter id="g" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="7" stitchTiles="stitch"/><feColorMatrix type="saturate" values="0"/></filter>
<filter id="w" x="0" y="0" width="100%" height="100%"><feTurbulence type="fractalNoise" baseFrequency="0.0117 0.0273" numOctaves="4" seed="9" stitchTiles="stitch" result="t"/>
<feDiffuseLighting in="t" surfaceScale="4" lighting-color="#fff"><feDistantLight azimuth="235" elevation="58"/></feDiffuseLighting></filter>
<rect width="{TILE}" height="{TILE}" fill="#efe8d6"/>
<rect width="{TILE}" height="{TILE}" filter="url(#w)" opacity="0.28" style="mix-blend-mode:multiply"/>
<rect width="{TILE}" height="{TILE}" filter="url(#g)" opacity="0.14" style="mix-blend-mode:multiply"/>""")

if __name__ == "__main__":
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    (out / "concrete.html").write_text(CONCRETE)
    (out / "paper.html").write_text(PAPER)
