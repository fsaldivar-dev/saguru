// Draws a placeholder Saguru icon (1024x1024 PNG): a simulator phone with the rail beside it.
// Usage: swift scripts/make-icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [
        CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a,
    ])!
}

func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ colors: [CGColor], in rect: CGRect) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: CGPoint(x: rect.minX, y: rect.maxY), end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
}

// Tile (macOS grid: 824 px tile on a 1024 px canvas)
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.saveGState()
ctx.addPath(rounded(tile, 186))
ctx.clip()
gradient([color(0x25C6FF), color(0x1677F2), color(0x0B3FB8)], in: tile)
ctx.restoreGState()

// Phone
let phone = CGRect(x: 262, y: 232, width: 300, height: 560)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.35))
ctx.addPath(rounded(phone, 62))
ctx.setFillColor(color(0x15171C))
ctx.fillPath()
ctx.restoreGState()
let screen = phone.insetBy(dx: 16, dy: 16)
ctx.saveGState()
ctx.addPath(rounded(screen, 48))
ctx.clip()
gradient([color(0x8FF3FF), color(0x57B5FF), color(0x6C6BFF)], in: screen)
ctx.restoreGState()
ctx.addPath(rounded(CGRect(x: phone.midX - 46, y: screen.maxY - 48, width: 92, height: 26), 13))
ctx.setFillColor(color(0x15171C))
ctx.fillPath()

// Rail
let rail = CGRect(x: 606, y: 392, width: 104, height: 400)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 24, color: color(0x000000, 0.3))
ctx.addPath(rounded(rail, 52))
ctx.setFillColor(color(0x15171C, 0.92))
ctx.fillPath()
ctx.restoreGState()
for (index, hex) in [0xFFFFFF, 0xFFFFFF, 0x35C8FF, 0xFFFFFF].enumerated() {
    ctx.setFillColor(color(UInt32(hex), hex == 0xFFFFFF ? 0.9 : 1))
    ctx.fillEllipse(in: CGRect(x: rail.midX - 24, y: rail.maxY - 86 - CGFloat(index) * 90, width: 48, height: 48))
}

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
print("icon -> \(out)")
