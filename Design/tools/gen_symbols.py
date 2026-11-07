"""Turn Lucide icons into custom SF Symbol templates (.symbolset) for an asset catalog.

Each AppSymbol case gets all nine weights in three sizes, with a heavier stroke per weight, so toolbars,
Bold Text and imageScale all find a glyph.

usage (deps: skia-pathops, svgelements, fonttools; icons from `npm pack lucide-static`):
  gen_symbols.py <lucide-static/icons> App/Fonts/Geist-SemiBold.ttf App/Assets.xcassets/Icons
"""
import json, os, shutil, sys
import pathops
import svgelements as se
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont

ICONS, FONT, OUT = sys.argv[1:4]
WIDTH = [1.5]         # current stroke, in Lucide's 24-unit grid
WEIGHTS = [("Ultralight", 0.9), ("Thin", 1.1), ("Light", 1.3), ("Regular", 1.5), ("Medium", 1.7),
           ("Semibold", 1.9), ("Bold", 2.1), ("Heavy", 2.4), ("Black", 2.7)]
SIZES = [("S", 696.0, 0.783), ("M", 1126.0, 1.0), ("L", 1556.0, 1.29)]
CAP = 70.459          # cap height of every size's guides
S = 1.5 * CAP / 20    # 20 Lucide units of drawing span 1.5 cap heights

# case name -> (lucide icon, filled element indices or None, extra)
MAP = {
    "add": ("plus",), "altRoute": ("split",), "arrowDownward": ("arrow-down",), "arrowUpward": ("arrow-up",),
    "block": ("ban",), "cancel": ("circle-x",), "cancelFill": ("circle-x", [0]),
    "chat": ("message-square-text",), "check": ("check",), "checkCircle": ("circle-check",),
    "checkCircleFill": ("circle-check", [0]), "chevronRight": ("chevron-right",), "circle": ("circle",),
    "circleFill": ("circle", [0]), "contentCopy": ("copy",),
    "dangerous": ("octagon-x",), "dangerousFill": ("octagon-x", [0]), "dataObject": ("braces",),
    "databaseOff": ("database-x",), "delete": ("trash-2",), "document": ("file-text",), "dns": ("globe",),
    "editSquare": ("square-pen",), "error": ("octagon-alert",), "errorFill": ("octagon-alert", [2]),
    "eventBusy": ("calendar-x",), "hardDrive": ("hard-drive",), "info": ("info",), "filterAlt": ("list-filter", None, "circle"),
    "filterAltFill": ("list-filter", None, "circleFill"), "filterList": ("list-filter",),
    "forum": ("messages-square",), "gppBad": ("badge-x",), "gppBadFill": ("badge-x", [0]),
    "inbox": ("inbox",), "inkHighlighter": ("highlighter",), "iosShare": ("share",),
    "keyboardArrowDown": ("chevron-down",), "keyboardArrowUp": ("chevron-up",),
    "listAlt": ("list",), "listAltFill": ("list",), "lock": ("lock",), "lockFill": ("lock", [0]),
    "lockOpen": ("lock-open",), "memory": ("memory-stick",), "menuBook": ("book-open",),
    "moreHoriz": ("ellipsis",), "moreHorizCircle": ("circle-ellipsis",), "noEncryption": ("shield-alert",),
    "panelBottom": ("panel-bottom",), "panelRight": ("panel-right",), "pause": ("pause",), "pauseCircle": ("circle-pause",), "pauseCircleFill": ("circle-pause", [0]),
    "playArrow": ("play",), "playArrowFill": ("play", [0]), "playCircle": ("circle-play",),
    "refresh": ("rotate-cw",), "schedule": ("clock",), "search": ("search",), "send": ("send",), "sendFill": ("send", [0]),
    "sensors": ("radio",), "sensorsOff": ("wifi-off",), "settings": ("settings",),
    "settingsFill": ("settings", [0]), "speed": ("snail",), "star": ("star",), "sunMoon": ("sun-moon",), "starFill": ("star", [0]),
    "terminal": ("square-terminal",), "traffic": ("arrow-down-up",), "rules": ("list-checks",), "tune": ("sliders-horizontal",), "verified": ("badge-check",),
    "verifiedFill": ("badge-check", [0]), "verifiedUser": ("shield-check",), "warning": ("triangle-alert",),
    "warningFill": ("triangle-alert", [0]),
    "counter1": ("circle", None, "digit1"), "counter2": ("circle", None, "digit2"),
    "counter3": ("circle", None, "digit3"), "counter4": ("circle", None, "digit4"),
}


def shapes(name):
    svg = se.SVG.parse(os.path.join(ICONS, name + ".svg"))
    out = []
    for el in svg.elements():
        if isinstance(el, se.Shape) and not isinstance(el, se.SVG):
            p = se.Path(el)
            p.approximate_arcs_with_cubics()
            out.append(p)
    return out


def to_pathops(p, matrix=None):
    path = pathops.Path()
    pen = path.getPen()
    open_ = False
    for seg in p.segments():
        pts = lambda *ps: [(q.x, q.y) if matrix is None else matrix(q.x, q.y) for q in ps]
        if isinstance(seg, se.Move):
            if open_:
                pen.endPath()
            pen.moveTo(*pts(seg.end)); open_ = True
        elif isinstance(seg, se.Close):
            pen.closePath(); open_ = False
        elif isinstance(seg, se.Line):
            pen.lineTo(*pts(seg.end))
        elif isinstance(seg, se.CubicBezier):
            pen.curveTo(*pts(seg.control1, seg.control2, seg.end))
        elif isinstance(seg, se.QuadraticBezier):
            pen.qCurveTo(*pts(seg.control, seg.end))
    if open_:
        pen.endPath()
    return path


def stroked(p, width=None):
    width = width or WIDTH[0]
    q = pathops.Path(p)
    q.stroke(width, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4)
    q.convertConicsToQuads(0.01)
    return q


def closed(p):
    q = pathops.Path()
    pen = q.getPen()
    for verb, pts in p:
        if verb == pathops.PathVerb.MOVE:
            pen.moveTo(*pts)
        elif verb == pathops.PathVerb.LINE:
            pen.lineTo(*pts)
        elif verb == pathops.PathVerb.CUBIC:
            pen.curveTo(*pts)
        elif verb == pathops.PathVerb.QUAD:
            pen.qCurveTo(*pts)
        elif verb == pathops.PathVerb.CLOSE:
            pen.closePath()
    pen.closePath()
    return pathops.simplify(q, fix_winding=True)


def union(paths):
    out = pathops.Path()
    for p in paths:
        out = pathops.op(out, p, pathops.PathOp.UNION, fix_winding=True)
    return out


def minus(a, paths):
    for p in paths:
        a = pathops.op(a, p, pathops.PathOp.DIFFERENCE, fix_winding=True)
    return a


def digit(n, box):
    """Outline of digit n from the font, centered in a Lucide-grid box (cx, cy, height)."""
    font = TTFont(FONT)
    gs = font.getGlyphSet()
    gname = font.getBestCmap()[ord(str(n))]
    cap = font["OS/2"].sCapHeight
    adv = gs[gname].width
    cx, cy, h = box
    k = h / cap
    path = pathops.Path()
    gs[gname].draw(TransformPen(path.getPen(), (k, 0, 0, -k, cx - adv * k / 2, cy + h / 2)))
    return pathops.simplify(path, fix_winding=True)


def build(icon, fill=None, extra=None):
    els = shapes(icon)
    paths = [to_pathops(p) for p in els]
    if extra in ("circle", "circleFill"):
        # list-filter lines shrunk into a 10-radius circle, like line.3.horizontal.decrease.circle
        m = lambda x, y: (12 + (x - 12) * 0.5, 12 + (y - 12) * 0.5)
        inner = [stroked(to_pathops(p, m)) for p in els]
        ring = to_pathops(shapes("circle")[0])
        if extra == "circle":
            return union([stroked(ring)] + inner)
        return minus(union([closed(ring), stroked(ring)]), inner)
    if extra and extra.startswith("digit"):
        return union([stroked(paths[0]), digit(int(extra[5:]), (12, 12, 9))])
    if not fill:
        return union([stroked(p) for p in paths])
    body = union([closed(paths[i]) for i in fill] + [stroked(paths[i]) for i in fill])
    rest = [stroked(p) for i, p in enumerate(paths) if i not in fill]
    return minus(body, rest) if rest else body


def svg_d(path, k):
    # Lucide (x, y) -> template coordinates relative to a variant's origin (left margin, baseline), scaled by k.
    pen = SVGPathPen(None, ntos=lambda v: f"{v:.3f}".rstrip("0").rstrip("."))
    t = TransformPen(pen, (S * k, 0, 0, S * k, -1 * S * k, -CAP / 2 - 12 * S * k))
    path.draw(t)
    return pen.getCommands()


HEAD = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
 <g id="Notes">
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 2952.79 1902.05)">Template v.3.0</text>
  <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 263 1902)">{name}</text>
 </g>
 <g id="Guides" style="stroke:#27AAE1;stroke-width:0.5;fill:none;">
  <line id="Baseline-S" x1="263" x2="3036" y1="696" y2="696"/>
  <line id="Capline-S" x1="263" x2="3036" y1="625.541" y2="625.541"/>
  <line id="Baseline-M" x1="263" x2="3036" y1="1126" y2="1126"/>
  <line id="Capline-M" x1="263" x2="3036" y1="1055.54" y2="1055.54"/>
  <line id="Baseline-L" x1="263" x2="3036" y1="1556" y2="1556"/>
  <line id="Capline-L" x1="263" x2="3036" y1="1485.54" y2="1485.54"/>
{margins} </g>
 <g id="Symbols">
{symbols} </g>
</svg>
"""


def template(case, spec):
    icon, fill, extra = (list(spec) + [None, None])[:3]
    margins, symbols = [], []
    for wi, (weight, width) in enumerate(WEIGHTS):
        WIDTH[0] = width
        shape = build(icon, fill, extra)
        x = 300 + wi * 296
        for size, base, k in SIZES:
            vid = f"{weight}-{size}"
            r = x + 22 * S * k
            margins.append(f'  <line id="left-margin-{vid}" x1="{x}" x2="{x}" y1="{base - 95}" y2="{base + 24}"/>\n')
            margins.append(f'  <line id="right-margin-{vid}" x1="{r:.3f}" x2="{r:.3f}" y1="{base - 95}" y2="{base + 24}"/>\n')
            symbols.append(f'  <g id="{vid}" transform="matrix(1 0 0 1 {x} {base})">\n   <path d="{svg_d(shape, k)}"/>\n  </g>\n')
    return HEAD.format(name=case, margins="".join(margins), symbols="".join(symbols))


if os.path.isdir(OUT):
    shutil.rmtree(OUT)
os.makedirs(OUT)
json.dump({"info": {"author": "xcode", "version": 1}}, open(os.path.join(OUT, "Contents.json"), "w"), indent=2)
for case, spec in MAP.items():
    folder = os.path.join(OUT, case + ".symbolset")
    os.makedirs(folder)
    open(os.path.join(folder, case + ".svg"), "w").write(
        template(case, spec))
    json.dump({"info": {"author": "xcode", "version": 1},
               "symbols": [{"filename": case + ".svg", "idiom": "universal"}]},
              open(os.path.join(folder, "Contents.json"), "w"), indent=2)
print(len(MAP), "symbols")
