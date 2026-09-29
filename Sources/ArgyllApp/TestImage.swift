import AppKit
import CoreGraphics
import ColorSync

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


/// Colour-manages an image the way Lightroom or Photoshop would: converts it from its
/// own colour space into the given display profile, then hands the OS the converted
/// pixels. On this macOS the OS ignores the assigned display profile for its own drawing,
/// so this is the only way two profiles can be compared on screen.
enum ProfileRenderer {
    static func render(_ image: NSImage, through profileURL: URL?) -> NSImage {
        guard let profileURL,
              let data = try? Data(contentsOf: profileURL),
              let target = CGColorSpace(iccData: data as CFData),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let w = source.width, h = source.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: target, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: w, height: h))      // CoreGraphics converts into the profile
        guard let converted = ctx.makeImage(),
              // Re-tag the converted pixels as sRGB: the OS treats what it receives as sRGB anyway,
              // so tagging them honestly would make it convert them a second time.
              let retagged = converted.copy(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return image }
        return NSImage(cgImage: retagged, size: image.size)
    }
}


/// Numbers behind a profile: what an sRGB grey becomes in the profile's device space
/// (the same conversion Compare and Lightroom perform) and the profile's white point.
enum ProfileInspector {
    static let rampLevels = [100, 95, 90, 80, 50, 20]

    struct RGB: Equatable { let r: Int, g: Int, b: Int
        var spread: Int { max(r, g, b) - min(r, g, b) }
        var text: String { "\(r) / \(g) / \(b)" }
    }

    static func device(forGreyPercent percent: Int, through url: URL) -> RGB? {
        guard let data = try? Data(contentsOf: url), let target = CGColorSpace(iccData: data as CFData),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let v = CGFloat(percent) / 100
        guard let src = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        src.setFillColor(CGColor(colorSpace: srgb, components: [v, v, v, 1])!)
        src.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let image = src.makeImage(),
              let dst = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0, space: target,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        dst.draw(image, in: CGRect(x: 0, y: 0, width: 2, height: 2))
        guard let px = dst.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        return RGB(r: Int(px[0]), g: Int(px[1]), b: Int(px[2]))
    }

    static func greyRamp(through url: URL?) -> [Int: RGB] {
        guard let url else { return [:] }
        var out: [Int: RGB] = [:]
        for level in rampLevels { out[level] = device(forGreyPercent: level, through: url) }
        return out
    }

    /// The profile's media white point (wtpt tag) as xy and correlated colour temperature.
    /// ICC v4 profiles store D50 there and keep the real white elsewhere, which is reported as such.
    static func whitePoint(of url: URL) -> (x: Double, y: Double, cct: Double, isD50: Bool)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        var error: Unmanaged<CFError>?
        guard let p = ColorSyncProfileCreate(data as CFData, &error) else { return nil }
        let profile = p.takeRetainedValue()
        guard let tag = ColorSyncProfileCopyTag(profile, "wtpt" as CFString)?.takeRetainedValue() as Data?, tag.count >= 20 else { return nil }
        func fixed(_ offset: Int) -> Double {
            let raw = tag[offset..<offset+4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Double(Int32(bitPattern: raw)) / 65536.0
        }
        let X = fixed(8), Y = fixed(12), Z = fixed(16)
        let sum = X + Y + Z
        guard sum > 0 else { return nil }
        let x = X / sum, y = Y / sum
        let n = (x - 0.3320) / (0.1858 - y)
        let cct = 449 * pow(n, 3) + 3525 * pow(n, 2) + 6823.3 * n + 5520.33
        let isD50 = abs(x - 0.3457) < 0.002 && abs(y - 0.3585) < 0.002
        return (x, y, cct, isD50)
    }
}
