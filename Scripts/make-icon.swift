// Draws the Argyll Profiler app icon (dark slab, spectral ring, white patch) and writes
// AppIcon.icns next to this script. Run: swift Scripts/make-icon.swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func render(size s: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(s), height: Int(s), bitsPerComponent: 8, bytesPerRow: 0,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let u = s / 1024.0                                   // design units
    let c = CGPoint(x: s / 2, y: s / 2)

    // Slab: rounded square with a subtle vertical gradient.
    let slab = CGPath(roundedRect: CGRect(x: 64 * u, y: 64 * u, width: 896 * u, height: 896 * u),
                      cornerWidth: 200 * u, cornerHeight: 200 * u, transform: nil)
    ctx.saveGState()
    ctx.addPath(slab); ctx.clip()
    let g = CGGradient(colorsSpace: cs,
                       colors: [CGColor(red: 0.10, green: 0.12, blue: 0.16, alpha: 1),
                                CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)] as CFArray,
                       locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])
    // faint top highlight
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.06))
    ctx.fill(CGRect(x: 0, y: s / 2, width: s, height: s / 2))
    ctx.restoreGState()

    // Glow behind the patch.
    let glow = CGGradient(colorsSpace: cs,
                          colors: [CGColor(red: 1, green: 1, blue: 1, alpha: 0.35),
                                   CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                          locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: 240 * u, options: [])

    // Spectral ring: red at the top, sweeping clockwise through to violet.
    let rOut = 330 * u, rIn = 250 * u
    let steps = 720
    for i in 0..<steps {
        let t = CGFloat(i) / CGFloat(steps)
        let a0 = CGFloat.pi / 2 - t * 2 * .pi
        let a1 = a0 - (2 * .pi / CGFloat(steps)) * 1.15
        let (r, gg, b) = hsv(h: 0.78 * t, s: 0.85, v: 1)
        ctx.setFillColor(CGColor(red: r, green: gg, blue: b, alpha: 1))
        let p = CGMutablePath()
        p.addArc(center: c, radius: rOut, startAngle: a0, endAngle: a1, clockwise: true)
        p.addArc(center: c, radius: rIn, startAngle: a1, endAngle: a0, clockwise: false)
        p.closeSubpath()
        ctx.addPath(p); ctx.fillPath()
    }

    // White patch with a thin grey rim.
    ctx.setFillColor(CGColor(red: 0.98, green: 0.98, blue: 0.99, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - 150 * u, y: c.y - 150 * u, width: 300 * u, height: 300 * u))
    ctx.setStrokeColor(CGColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1))
    ctx.setLineWidth(6 * u)
    ctx.strokeEllipse(in: CGRect(x: c.x - 147 * u, y: c.y - 147 * u, width: 294 * u, height: 294 * u))

    return ctx.makeImage()!
}

func hsv(h: CGFloat, s: CGFloat, v: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    let i = Int(h * 6) % 6
    let f = h * 6 - CGFloat(Int(h * 6))
    let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
    switch i {
    case 0: return (v, t, p)
    case 1: return (q, v, p)
    case 2: return (p, v, t)
    case 3: return (p, q, v)
    case 4: return (t, p, v)
    default: return (v, p, q)
    }
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                   ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                   ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    writePNG(render(size: CGFloat(px)), to: iconset.appendingPathComponent("\(name).png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! task.run(); task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
