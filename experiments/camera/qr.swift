import AppKit
import CoreImage
let size = NSSize(width: 1080, height: 1440)
let filter = CIFilter(name: "CIQRCodeGenerator")!
filter.setValue("https://saguru.dev/mesa/42".data(using: .utf8), forKey: "inputMessage")
let qr = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 14, y: 14))
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1080, pixelsHigh: 1440, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGradient(colors: [NSColor(red: 0.85, green: 0.7, blue: 0.5, alpha: 1), NSColor(red: 0.45, green: 0.3, blue: 0.2, alpha: 1)])!.draw(in: NSRect(origin: .zero, size: size), angle: 60)
let side = qr.extent.width + 80
let card = NSRect(x: (1080 - side) / 2, y: (1440 - side) / 2, width: side, height: side)
NSColor.white.setFill(); NSBezierPath(roundedRect: card, xRadius: 24, yRadius: 24).fill()
NSCIImageRep(ciImage: qr).draw(in: card.insetBy(dx: 40, dy: 40))
("Mesa 42" as NSString).draw(at: NSPoint(x: 400, y: 1200), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 80), .foregroundColor: NSColor.white])
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
