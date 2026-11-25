// Draws Saguru's icon and, optionally, the banner of the README.
//   swift scripts/make-icon.swift assets/icon_1024.png [assets/banner.png [tagline [features]]]
// The icon is a phone with the » that unfolds Saguru's panel beside it: an 824 px tile centred on a
// transparent 1024 px canvas, the proportions macOS expects of an app icon.
import AppKit

func bitmap(_ width: Int, _ height: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    draw(context.cgContext)
    context.flushGraphics()
    return rep
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ context: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: nil)!
    context.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// The mark, inside a square of `side` whose bottom-left corner is `origin`.
func mark(_ context: CGContext, origin: CGPoint, side: CGFloat) {
    let unit = side / 824
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * unit, y: origin.y + y * unit) }
    let tile = CGPath(roundedRect: CGRect(x: origin.x, y: origin.y, width: side, height: side), cornerWidth: 186 * unit, cornerHeight: 186 * unit, transform: nil)

    // Tile: deep indigo, a little lighter at the top.
    context.saveGState()
    context.addPath(tile)
    context.clip()
    gradient(context, [color(0x232744), color(0x0D0E1A)], from: point(0, 824), to: point(0, 0))
    // A soft glow behind the chevrons.
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x3D8BFF, 0.34), color(0x3D8BFF, 0)] as CFArray, locations: nil)!
    context.drawRadialGradient(glow, startCenter: point(590, 412), startRadius: 0, endCenter: point(590, 412), endRadius: 330 * unit, options: [])
    context.restoreGState()

    // The phone.
    let phone = CGRect(x: origin.x + 150 * unit, y: origin.y + 152 * unit, width: 290 * unit, height: 520 * unit)
    context.setStrokeColor(color(0xFFFFFF, 0.94))
    context.setLineWidth(34 * unit)
    context.addPath(CGPath(roundedRect: phone, cornerWidth: 70 * unit, cornerHeight: 70 * unit, transform: nil))
    context.strokePath()
    context.setFillColor(color(0xFFFFFF, 0.94))
    context.addPath(CGPath(roundedRect: CGRect(x: phone.midX - 46 * unit, y: phone.maxY - 62 * unit, width: 92 * unit, height: 22 * unit),
                           cornerWidth: 11 * unit, cornerHeight: 11 * unit, transform: nil))
    context.fillPath()

    // The » that unfolds the panel.
    context.saveGState()
    let chevrons = CGMutablePath()
    for x in [500.0, 606.0] as [CGFloat] {
        chevrons.move(to: point(x, 552))
        chevrons.addLine(to: point(x + 96, 412))
        chevrons.addLine(to: point(x, 272))
    }
    context.addPath(chevrons)
    context.setLineWidth(50 * unit)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    gradient(context, [color(0x6FD6FF), color(0x2F7BFF)], from: point(480, 560), to: point(720, 260))
    context.restoreGState()

    // A hairline on the tile's edge.
    context.addPath(tile)
    context.setStrokeColor(color(0xFFFFFF, 0.10))
    context.setLineWidth(3 * unit)
    context.strokePath()
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else { print("uso: make-icon.swift icono.png [banner.png]"); exit(1) }

let icon = bitmap(1024, 1024) { context in mark(context, origin: CGPoint(x: 100, y: 100), side: 824) }
try icon.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[1]))

if arguments.count >= 3 {
    let banner = bitmap(1600, 480) { context in
        gradient(context, [color(0x171A30), color(0x0A0B14)], from: CGPoint(x: 0, y: 480), to: CGPoint(x: 1600, y: 0))
        let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0x3D8BFF, 0.22), color(0x3D8BFF, 0)] as CFArray, locations: nil)!
        context.drawRadialGradient(glow, startCenter: CGPoint(x: 330, y: 240), startRadius: 0, endCenter: CGPoint(x: 330, y: 240), endRadius: 520, options: [])
        mark(context, origin: CGPoint(x: 150, y: 80), side: 320)
        let title = NSFont.systemFont(ofSize: 132, weight: .bold)
        let rounded = title.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 132) } ?? title
        ("Saguru" as NSString).draw(at: CGPoint(x: 540, y: 216), withAttributes: [.font: rounded, .foregroundColor: NSColor.white, .kern: -2])
        ((arguments.count > 3 ? arguments[3] : "Superpoderes para el Simulador de iOS") as NSString).draw(at: CGPoint(x: 546, y: 150), withAttributes: [
            .font: NSFont.systemFont(ofSize: 44, weight: .medium), .foregroundColor: NSColor(white: 1, alpha: 0.72)])
        ((arguments.count > 4 ? arguments[4] : "Red · Cámara · Push · Permisos · Datos · Diseño") as NSString).draw(at: CGPoint(x: 548, y: 92), withAttributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .regular), .foregroundColor: NSColor(red: 0.44, green: 0.84, blue: 1, alpha: 0.95)])
    }
    try banner.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[2]))
}
