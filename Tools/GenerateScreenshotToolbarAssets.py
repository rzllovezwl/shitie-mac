#!/usr/bin/env python3
"""Generate equal-weight toolbar PDFs from lucide-static's original stroke nodes.

Requires ReportLab. Usage:
  python3 Tools/GenerateScreenshotToolbarAssets.py <lucide-static package> <Assets.xcassets>
"""

import json
import sys
from pathlib import Path

from reportlab.graphics import renderPDF
from reportlab.graphics.shapes import Circle, Drawing, Group, Rect
from reportlab.graphics.svgpath import SvgPath
from reportlab.lib.colors import black


PACKAGE_VERSION = "1.59.0"
CANVAS_SIZE = 24
STROKE_WIDTH = 2
ICON_NAMES = (
    "mouse-pointer-2", "square", "square-filled", "circle", "arrow-up-right",
    "list-ordered", "highlighter", "pencil", "grid-3x3",
    "type", "pen-tool", "image", "scan-search", "languages", "chevron-down", "pin", "undo-2",
    "x", "copy-check",
)


def shape_from_node(tag, attrs):
    if tag == "path":
        return SvgPath(attrs["d"], fillColor=None)
    if tag == "circle":
        return Circle(float(attrs["cx"]), float(attrs["cy"]), float(attrs["r"]))
    if tag == "rect":
        return Rect(
            float(attrs.get("x", 0)), float(attrs.get("y", 0)),
            float(attrs["width"]), float(attrs["height"]),
            rx=float(attrs.get("rx", 0)),
            ry=float(attrs.get("ry", attrs.get("rx", 0))),
        )
    raise ValueError(f"Unsupported Lucide node: {tag}")


def icon_drawing(name, nodes, color=black):
    shapes = [shape_from_node(tag, attrs) for tag, attrs in nodes]
    bounds = [shape.getBounds() for shape in shapes]
    x0, y0 = min(b[0] for b in bounds), min(b[1] for b in bounds)
    x1, y1 = max(b[2] for b in bounds), max(b[3] for b in bounds)
    # Keep the accepted small language chevron and drawing-arrow size. Other
    # marks occupy an 18-unit shape, with a two-unit stroke on this 24-unit page.
    extent = {"arrow-up-right": 14, "chevron-down": 9}.get(name, 18)
    scale = extent / max(x1 - x0, y1 - y0)
    group = Group()
    group.transform = (
        scale, 0, 0, -scale,
        CANVAS_SIZE / 2 - scale * (x0 + x1) / 2,
        CANVAS_SIZE / 2 + scale * (y0 + y1) / 2,
    )
    for shape in shapes:
        shape.fillColor = color if name == "square-filled" else None
        shape.strokeColor = color
        # Scale the centerline geometry, then compensate the stroke so each
        # rendered PDF has the same weight regardless of its original bounds.
        shape.strokeWidth = STROKE_WIDTH / scale
        shape.strokeLineCap = 1
        shape.strokeLineJoin = 1
        group.add(shape)
    drawing = Drawing(CANVAS_SIZE, CANVAS_SIZE)
    drawing.add(group)
    return drawing


def generate(package, catalog):
    version = json.loads((package / "package.json").read_text())["version"]
    if version != PACKAGE_VERSION:
        raise ValueError(f"Expected lucide-static@{PACKAGE_VERSION}, received {version}")
    nodes = json.loads((package / "icon-nodes.json").read_text())
    for name in ICON_NAMES:
        drawing = icon_drawing(name, nodes["square" if name == "square-filled" else name])
        asset = catalog / f"LucideToolbar-{name}.imageset"
        asset.mkdir(parents=True, exist_ok=True)
        (asset / "icon.pdf").write_bytes(renderPDF.drawToString(
            drawing, invariant=1, pageCompression=0,
            title=f"Lucide {name} - uniform toolbar stroke",
        ))
        (asset / "Contents.json").write_text(json.dumps({
            "images": [{"filename": "icon.pdf", "idiom": "universal"}],
            "info": {"author": "xcode", "version": 1},
            "properties": {
                "preserves-vector-representation": True,
                "template-rendering-intent": "template",
            },
        }, indent=2) + "\n")
    print(f"Generated {len(ICON_NAMES)} Lucide toolbar assets with a uniform {STROKE_WIDTH}-unit stroke")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    generate(Path(sys.argv[1]), Path(sys.argv[2]))
