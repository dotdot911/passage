// Generates the Passage app icon artwork as SVG and renders every PNG from it.
// Run from the repo root: swift Design/AppIcon/render.swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Design/AppIcon")
let fm = FileManager.default
let S = 1024.0

// MARK: - Palette

enum Appearance: String, CaseIterable { case light = "default", dark, tinted }

struct Palette {
    let bgTop: String, bgBottom: String
    let line: String, lineOpacity: Double
    let accent: String

    static func of(_ a: Appearance) -> Palette {
        switch a {
        case .light: return Palette(bgTop: "#3A3F4B", bgBottom: "#15171C", line: "#FFFFFF", lineOpacity: 0.92, accent: "#FFB23F")
        case .dark: return Palette(bgTop: "#1E2026", bgBottom: "#0B0C0F", line: "#C9CED8", lineOpacity: 0.85, accent: "#F7A733")
        case .tinted: return Palette(bgTop: "#000000", bgBottom: "#000000", line: "#FFFFFF", lineOpacity: 0.55, accent: "#FFFFFF")
        }
    }
}

// Layers are rendered separately for the Icon Composer document and together for the flat PNGs.
enum Part { case background, stream, accent }

// MARK: - Concepts

protocol Concept { var name: String { get }; func body(_ p: Palette, _ parts: Set<Part>) -> String }

func capsule(x: Double, y: Double, w: Double, h: Double, fill: String, opacity: Double = 1) -> String {
    "<rect x=\"\(x)\" y=\"\(y)\" width=\"\(w)\" height=\"\(h)\" rx=\"\(min(w, h) / 2)\" fill=\"\(fill)\" fill-opacity=\"\(opacity)\"/>"
}

func roundedRect(x: Double, y: Double, w: Double, h: Double, r: Double) -> String {
    "M\(x + r) \(y) H\(x + w - r) A\(r) \(r) 0 0 1 \(x + w) \(y + r) V\(y + h - r) A\(r) \(r) 0 0 1 \(x + w - r) \(y + h) H\(x + r) A\(r) \(r) 0 0 1 \(x) \(y + h - r) V\(y + r) A\(r) \(r) 0 0 1 \(x + r) \(y) Z"
}

/// A: request lines flowing past a lens; the part inside the lens is lit up as inspected.
struct Lens: Concept {
    let name = "a-lens"
    let lines: [(x: Double, w: Double, y: Double)] = [(176, 560, 374), (248, 600, 480), (176, 520, 586), (296, 452, 692)]
    let h = 62.0, cx = 512.0, cy = 534.0, r = 206.0, ring = 58.0
    func body(_ p: Palette, _ parts: Set<Part>) -> String {
        var s = "<defs><clipPath id=\"in\"><circle cx=\"\(cx)\" cy=\"\(cy)\" r=\"\(r - ring / 2)\"/></clipPath><mask id=\"out\"><rect width=\"\(S)\" height=\"\(S)\" fill=\"#fff\"/><circle cx=\"\(cx)\" cy=\"\(cy)\" r=\"\(r + ring / 2 + 26)\" fill=\"#000\"/></mask></defs>"
        if parts.contains(.stream) {
            s += "<g mask=\"url(#out)\">" + lines.map { capsule(x: $0.x, y: $0.y - h / 2, w: $0.w, h: h, fill: p.line, opacity: p.lineOpacity) }.joined() + "</g>"
        }
        if parts.contains(.accent) {
            s += "<g clip-path=\"url(#in)\">" + lines.map { capsule(x: $0.x, y: $0.y - h / 2, w: $0.w, h: h, fill: p.accent) }.joined() + "</g>"
            s += "<circle cx=\"\(cx)\" cy=\"\(cy)\" r=\"\(r)\" fill=\"none\" stroke=\"\(p.accent)\" stroke-width=\"\(ring)\"/>"
        }
        return s
    }
}

/// B: a request arrow and a response arrow passing through the proxy node in the middle.
struct Relay: Concept {
    let name = "b-relay"
    func arrow(y: Double, right: Bool, fill: String, opacity: Double) -> String {
        let t = 76.0, head = 150.0, x0 = 190.0, x1 = 834.0
        let d: String
        if right {
            d = "M\(x0 + t / 2) \(y - t / 2) H\(x1 - head + 20) V\(y - 92) L\(x1) \(y) L\(x1 - head + 20) \(y + 92) V\(y + t / 2) H\(x0 + t / 2) A\(t / 2) \(t / 2) 0 0 1 \(x0 + t / 2) \(y - t / 2) Z"
        } else {
            d = "M\(x1 - t / 2) \(y - t / 2) H\(x0 + head - 20) V\(y - 92) L\(x0) \(y) L\(x0 + head - 20) \(y + 92) V\(y + t / 2) H\(x1 - t / 2) A\(t / 2) \(t / 2) 0 0 0 \(x1 - t / 2) \(y - t / 2) Z"
        }
        return "<path d=\"\(d)\" fill=\"\(fill)\" fill-opacity=\"\(opacity)\" stroke=\"\(fill)\" stroke-opacity=\"\(opacity)\" stroke-width=\"10\" stroke-linejoin=\"round\"/>"
    }
    func body(_ p: Palette, _ parts: Set<Part>) -> String {
        let node = (x: 440.0, y: 236.0, w: 144.0, h: 552.0)
        var s = "<defs><mask id=\"gap\"><rect width=\"\(S)\" height=\"\(S)\" fill=\"#fff\"/><rect x=\"\(node.x - 34)\" y=\"\(node.y - 34)\" width=\"\(node.w + 68)\" height=\"\(node.h + 68)\" rx=\"\(node.w / 2 + 34)\" fill=\"#000\"/></mask></defs>"
        if parts.contains(.stream) {
            s += "<g mask=\"url(#gap)\">" + arrow(y: 404, right: true, fill: p.line, opacity: p.lineOpacity) + arrow(y: 620, right: false, fill: p.line, opacity: p.lineOpacity) + "</g>"
        }
        if parts.contains(.accent) {
            s += capsule(x: node.x, y: node.y, w: node.w, h: node.h, fill: p.accent)
        }
        return s
    }
}

/// C: a packet waveform whose middle bars are lit up inside an inspection window.
struct Wave: Concept {
    let name = "c-wave"
    let heights: [Double] = [150, 260, 380, 300, 470, 330, 400, 250, 150]
    let w = 54.0, gap = 30.0
    func body(_ p: Palette, _ parts: Set<Part>) -> String {
        let total = Double(heights.count) * w + Double(heights.count - 1) * gap
        let x0 = (S - total) / 2
        var stream = "", accent = ""
        for (i, h) in heights.enumerated() {
            let x = x0 + Double(i) * (w + gap)
            if (3...5).contains(i) { accent += capsule(x: x, y: 512 - h / 2, w: w, h: h, fill: p.accent) }
            else { stream += capsule(x: x, y: 512 - h / 2, w: w, h: h, fill: p.line, opacity: p.lineOpacity) }
        }
        let fx = x0 + 3 * (w + gap) - 44, fw = 3 * w + 2 * gap + 88
        let frame = "<rect x=\"\(fx)\" y=\"\(512 - 300)\" width=\"\(fw)\" height=\"600\" rx=\"64\" fill=\"none\" stroke=\"\(p.accent)\" stroke-width=\"30\"/>"
        var s = ""
        if parts.contains(.stream) { s += stream }
        if parts.contains(.accent) { s += accent + frame }
        return s
    }
}

/// The shipped icon: concept C with fewer, heavier bars and clear space around a thicker inspection window.
struct PacketWindow: Concept {
    let name = "packet-window"
    let w = 60.0
    let outside: [(x: Double, h: Double)] = [(192, 170), (278, 300), (746, 280), (832, 160)]
    let inside: [(x: Double, h: Double)] = [(426, 260), (512, 460), (598, 340)]
    let frame = (x: 352.0, y: 212.0, w: 320.0, h: 600.0, r: 84.0, stroke: 40.0)
    func bars(_ list: [(x: Double, h: Double)], fill: String, opacity: Double) -> String {
        list.map { capsule(x: $0.x - w / 2, y: 512 - $0.h / 2, w: w, h: $0.h, fill: fill, opacity: opacity) }.joined()
    }
    func body(_ p: Palette, _ parts: Set<Part>) -> String {
        var s = ""
        if parts.contains(.stream) { s += bars(outside, fill: p.line, opacity: p.lineOpacity) }
        if parts.contains(.accent) {
            s += bars(inside, fill: p.accent, opacity: 1)
            // A filled ring rather than a stroke, because Icon Composer recolours a layer by replacing its fills.
            let h = frame.stroke / 2
            let outer = roundedRect(x: frame.x - h, y: frame.y - h, w: frame.w + 2 * h, h: frame.h + 2 * h, r: frame.r + h)
            let inner = roundedRect(x: frame.x + h, y: frame.y + h, w: frame.w - 2 * h, h: frame.h - 2 * h, r: frame.r - h)
            s += "<path fill-rule=\"evenodd\" d=\"\(outer) \(inner)\" fill=\"\(p.accent)\"/>"
        }
        return s
    }
}

let concepts: [Concept] = [Lens(), Relay(), Wave()]
let chosen = PacketWindow()

func svg(_ c: Concept, _ a: Appearance, _ parts: Set<Part>) -> String {
    let p = Palette.of(a)
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">"
    if parts.contains(.background) {
        s += "<defs><linearGradient id=\"bg\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"\(p.bgTop)\"/><stop offset=\"1\" stop-color=\"\(p.bgBottom)\"/></linearGradient></defs>"
        s += "<rect width=\"1024\" height=\"1024\" fill=\"url(#bg)\"/>"
    }
    return s + c.body(p, parts) + "</svg>\n"
}

// MARK: - Rendering

func bitmap(_ px: Int) -> NSBitmapImageRep {
    NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
}

func draw(into rep: NSBitmapImageRep, _ block: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    block()
    NSGraphicsContext.restoreGraphicsState()
}

func write(_ rep: NSBitmapImageRep, _ url: URL) {
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

/// NSImage only recognises SVG when it loads from a file with the .svg extension.
func image(_ svgText: String) -> NSImage {
    let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".svg")
    try! svgText.write(to: tmp, atomically: true, encoding: .utf8)
    defer { try? fm.removeItem(at: tmp) }
    return NSImage(contentsOf: tmp)!
}

/// Renders a full-bleed 1024 px PNG; the App Store icon must be opaque, so the opaque variants drop alpha.
func renderFull(_ svgText: String, to url: URL, opaque: Bool) {
    let src = bitmap(1024)
    draw(into: src) { image(svgText).draw(in: NSRect(x: 0, y: 0, width: S, height: S)) }
    guard opaque else { return write(src, url) }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(src.cgImage!, in: CGRect(x: 0, y: 0, width: S, height: S))
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
}

/// Draws an icon as the Home Screen shows it: scaled down and clipped to the rounded-rect mask.
func drawMasked(_ img: NSImage, in r: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: r, xRadius: r.width * 0.2237, yRadius: r.width * 0.2237).addClip()
    img.draw(in: r)
    NSGraphicsContext.restoreGraphicsState()
}

func label(_ text: String, at p: NSPoint, color: NSColor, size: Double = 22) {
    (text as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
}

/// A grid: one row per (title, image) with the icon at 180/120/80/58 px (60 pt @3x, 60/40/29 pt @2x), on light and dark wallpapers.
func contactSheet(_ rows: [(String, NSImage)], to url: URL) {
    let sizes: [Double] = [180, 120, 80, 58]
    let rowH = 230.0, labelW = 300.0, panelW = 600.0
    let W = labelW + panelW * 2, H = rowH * Double(rows.count) + 60
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W), pixelsHigh: Int(H), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    draw(into: rep) {
        NSColor(white: 0.96, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: W, height: H).fill()
        NSColor(calibratedRed: 0.62, green: 0.74, blue: 0.86, alpha: 1).setFill(); NSRect(x: labelW, y: 0, width: panelW, height: H).fill()
        NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 1).setFill(); NSRect(x: labelW + panelW, y: 0, width: panelW, height: H).fill()
        label("180 / 120 / 80 / 58 px", at: NSPoint(x: labelW + 20, y: H - 44), color: .black)
        label("on dark wallpaper", at: NSPoint(x: labelW + panelW + 20, y: H - 44), color: .white)
        for (i, row) in rows.enumerated() {
            let top = H - 60 - rowH * Double(i)
            label(row.0, at: NSPoint(x: 20, y: top - rowH / 2 - 12), color: .black, size: 24)
            for panel in 0..<2 {
                var x = labelW + panelW * Double(panel) + 24
                for s in sizes {
                    drawMasked(row.1, in: NSRect(x: x, y: top - 25 - s - (180 - s) / 2, width: s, height: s))
                    x += s + 36
                }
            }
        }
    }
    write(rep, url)
}

func pngImage(_ url: URL) -> NSImage { NSImage(contentsOf: url)! }

// MARK: - Outputs

let out = root.appendingPathComponent("out")
let all: Set<Part> = [.background, .stream, .accent]

// 1. Concept previews and one comparison sheet.
var conceptRows: [(String, NSImage)] = []
for c in concepts {
    for a in Appearance.allCases {
        let text = svg(c, a, all)
        let dir = root.appendingPathComponent("src/concepts")
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try! text.write(to: dir.appendingPathComponent("\(c.name)-\(a.rawValue).svg"), atomically: true, encoding: .utf8)
        let png = out.appendingPathComponent("concepts/\(c.name)-\(a.rawValue).png")
        renderFull(text, to: png, opaque: true)
        conceptRows.append(("\(c.name) \(a.rawValue)", pngImage(png)))
    }
}
contactSheet(conceptRows, to: out.appendingPathComponent("concepts/contact-sheet.png"))

// 2. The chosen design: final flat PNGs, the asset catalog copies, and its contact sheet.
let catalog = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
var finalRows: [(String, NSImage)] = []
for a in Appearance.allCases {
    let text = svg(chosen, a, all)
    try! text.write(to: root.appendingPathComponent("src/appicon-\(a.rawValue).svg"), atomically: true, encoding: .utf8)
    let png = out.appendingPathComponent("final/appicon-\(a.rawValue).png")
    renderFull(text, to: png, opaque: true)
    if fm.fileExists(atPath: catalog.path) {
        let dst = catalog.appendingPathComponent("AppIcon-\(a.rawValue).png")
        try? fm.removeItem(at: dst)
        try! fm.copyItem(at: png, to: dst)
    }
    finalRows.append((a.rawValue, pngImage(png)))
}

// 3. Foreground layers for the Icon Composer document (background comes from icon.json).
let iconAssets = root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App/AppIcon.icon/Assets")
if fm.fileExists(atPath: iconAssets.path) {
    let p = Palette.of(.light)
    let flat = Palette(bgTop: p.bgTop, bgBottom: p.bgBottom, line: p.line, lineOpacity: 1, accent: p.accent)
    for (name, part) in [("stream", Part.stream), ("window", Part.accent)] {
        let text = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\">" + chosen.body(flat, [part]) + "</svg>\n"
        try! text.write(to: iconAssets.appendingPathComponent("\(name).svg"), atomically: true, encoding: .utf8)
    }
}

// 4. Liquid Glass renders of the .icon through Icon Composer's ictool (set ICTOOL to override its path).
let ictool = ProcessInfo.processInfo.environment["ICTOOL"]
    ?? "/Applications/Xcode26.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
let glass = [("glass-default", "Default"), ("glass-dark", "Dark"), ("glass-tinted-dark", "TintedDark"), ("glass-clear-dark", "ClearDark")]
for (name, rendition) in glass where fm.fileExists(atPath: ictool) && fm.fileExists(atPath: iconAssets.path) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ictool)
    p.arguments = [iconAssets.deletingLastPathComponent().path, "--export-image", "--output-file", out.appendingPathComponent("final/\(name).png").path,
                   "--platform", "iOS", "--rendition", rendition, "--width", "1024", "--height", "1024", "--scale", "1"]
        + (rendition == "TintedDark" ? ["--tint-color", "0.6", "--tint-strength", "0.75"] : [])
    p.standardOutput = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
}
for (name, _) in glass {
    let url = out.appendingPathComponent("final/\(name).png")
    if fm.fileExists(atPath: url.path) { finalRows.append((name, pngImage(url))) }
}
contactSheet(finalRows, to: out.appendingPathComponent("final/contact-sheet.png"))
print("done")
