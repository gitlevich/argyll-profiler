import Foundation
import CoreGraphics
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let greys: [CGFloat] = [1.0, 0.95, 0.9, 0.8, 0.5, 0.2]
for path in CommandLine.arguments.dropFirst() {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let cs = CGColorSpace(iccData: data as CFData) else { continue }
    var line = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent + ": "
    for g in greys {
        let src = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        src.setFillColor(CGColor(colorSpace: srgb, components: [g, g, g, 1])!)
        src.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let dst = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        dst.draw(src.makeImage()!, in: CGRect(x: 0, y: 0, width: 4, height: 4))
        let p = dst.data!.assumingMemoryBound(to: UInt8.self)
        line += String(format: "%3d/%3d/%3d  ", Int(p[0]), Int(p[1]), Int(p[2]))
    }
    print(line)
}
