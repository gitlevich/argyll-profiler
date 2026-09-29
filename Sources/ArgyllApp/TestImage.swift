import AppKit
import CoreGraphics

/// A built-in reference image for comparing profiles: saturated primaries, memory
/// colours, a grey ramp. Drawn in sRGB so AppKit colour-manages it through whichever
/// display profile is active, exactly like a photo would be.
enum TestImage {
    static func make(width: Int = 1200, height: Int = 800) -> NSImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.46, 0.46, 0.46, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        func row(_ colors: [(CGFloat, CGFloat, CGFloat)], y: CGFloat, height rh: CGFloat) {
            let pad = w * 0.03
            let gap = w * 0.01
            let n = CGFloat(colors.count)
            let cw = (w - 2 * pad - gap * (n - 1)) / n
            for (i, c) in colors.enumerated() {
                ctx.setFillColor(CGColor(colorSpace: cs, components: [c.0, c.1, c.2, 1])!)
                ctx.fill(CGRect(x: pad + CGFloat(i) * (cw + gap), y: y, width: cw, height: rh))
            }
        }

        // Rows from the top (CG origin is bottom-left).
        let rh = h * 0.19
        row([(1, 0, 0), (0, 1, 0), (0, 0, 1), (0, 1, 1), (1, 0, 1), (1, 1, 0)], y: h - h * 0.05 - rh, height: rh)
        // Memory colours: light skin, dark skin, sky, foliage, sand, red apple, denim, warm grey.
        row([(0.90, 0.72, 0.62), (0.45, 0.30, 0.22), (0.50, 0.70, 0.90), (0.32, 0.50, 0.24),
             (0.87, 0.78, 0.58), (0.70, 0.12, 0.10), (0.24, 0.32, 0.55), (0.62, 0.58, 0.54)],
            y: h - h * 0.29 - rh, height: rh)
        // Grey ramp, 11 steps.
        row((0...10).map { let v = CGFloat($0) / 10; return (v, v, v) }, y: h - h * 0.53 - rh, height: rh)
        // Near-neutrals, where a white point error shows first.
        row([(0.95, 0.95, 0.95), (0.96, 0.95, 0.94), (0.94, 0.95, 0.96), (0.80, 0.80, 0.80), (0.81, 0.80, 0.79), (0.79, 0.80, 0.81)],
            y: h * 0.05, height: rh * 0.8)

        let image = ctx.makeImage()!
        return NSImage(cgImage: image, size: NSSize(width: width / 2, height: height / 2))
    }
}
