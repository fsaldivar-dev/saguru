import AppKit
import ApplicationServices
import SwiftUI

/// Reads the Simulator's window through the Accessibility API. Only the design tools need it:
/// it is the one way to learn exactly where the device screen sits inside the window.
enum SimulatorAX {
    static var trusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    private static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// Title and device-screen rectangle (top-left screen coordinates) of the Simulator window at `windowFrame`.
    static func window(at windowFrame: CGRect) -> (title: String, screen: CGRect?)? {
        guard trusted, let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.iphonesimulator").first
        else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        for window in (attribute(root, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
            guard let frame = frame(window), abs(frame.minX - windowFrame.minX) < 3, abs(frame.minY - windowFrame.minY) < 3,
                  abs(frame.width - windowFrame.width) < 3 else { continue }
            let children = (attribute(window, kAXChildrenAttribute) as? [AXUIElement]) ?? []
            let content = children.first { (attribute($0, kAXSubroleAttribute) as? String) == "iOSContentGroup" }
            return ((attribute(window, kAXTitleAttribute) as? String) ?? "", content.flatMap(Self.frame))
        }
        return nil
    }
}

/// Drawn exactly over the device screen: the design image, the grid and the rulers.
struct OverlayView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let pointsWide = landscape ? max(model.screenPoints.width, model.screenPoints.height)
                                       : min(model.screenPoints.width, model.screenPoints.height)
            let scale = geo.size.width / max(pointsWide, 1)
            ZStack(alignment: .topLeading) {
                if let picture = model.splitPicture {
                    // The picture covers the left of the divider; the live app shows on the right.
                    let x = geo.size.width * model.splitPosition
                    Image(nsImage: picture)
                        .resizable()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .mask(alignment: .leading) { Rectangle().frame(width: x) }
                    if let freeze = model.freezeImage {
                        // The live side, held still while the other side is being retaken.
                        Image(nsImage: freeze)
                            .resizable()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .mask(alignment: .trailing) { Rectangle().frame(width: geo.size.width - x) }
                    }
                    Rectangle().fill(.white)
                        .frame(width: 2, height: geo.size.height)
                        .shadow(color: .black.opacity(0.5), radius: 3)
                        .offset(x: x - 1)
                }
                if model.gridOn {
                    Canvas { context, size in
                        let step = model.gridSpacing * scale
                        guard step >= 2 else { return }
                        var path = Path()
                        var x = step
                        while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += step }
                        var y = step
                        while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += step }
                        context.stroke(path, with: .color(.red.opacity(0.45)), lineWidth: 0.5)
                    }
                }
                if model.measuring {
                    rulers(size: geo.size, scale: scale)
                }
                ForEach(model.axMarks) { mark in
                    let rect = CGRect(x: mark.rect.minX * geo.size.width, y: mark.rect.minY * geo.size.height,
                                      width: mark.rect.width * geo.size.width, height: mark.rect.height * geo.size.height)
                    let color = mark.warning ? Color(nsColor: .systemOrange) : Color(nsColor: .systemBlue)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(mark.strong ? 0.22 : 0))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(mark.strong ? 1 : 0.7), lineWidth: mark.strong ? 2.5 : 1))
                        .frame(width: max(rect.width, 2), height: max(rect.height, 2))
                        .offset(x: rect.minX, y: rect.minY)
                    if let number = mark.number {
                        Text("\(number)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(color, in: Capsule())
                            .fixedSize()
                            .offset(x: rect.minX + 2, y: rect.minY + 2)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius(geo.size), style: .continuous))
            .allowsHitTesting(false)
        }
    }

    /// Approximates the display's rounded corners, which the device profile does not publish:
    /// edge-to-edge phones are tall and very round, iPads slightly round, home-button phones square.
    private func cornerRadius(_ size: CGSize) -> CGFloat {
        let short = min(size.width, size.height), long = max(size.width, size.height)
        let ratio = long / max(short, 1)
        return ratio > 2 ? short * 0.15 : (ratio < 1.6 ? short * 0.025 : 0)
    }

    @ViewBuilder
    private func rulers(size: CGSize, scale: CGFloat) -> some View {
        ForEach(Array(model.guides.enumerated()), id: \.offset) { _, guide in
            crosshair(at: guide, size: size, scale: scale, color: .orange.opacity(0.9))
        }
        if let cursor = model.cursor {
            crosshair(at: cursor, size: size, scale: scale, color: Color(nsColor: .systemBlue))
            let last = model.guides.last
            let label = last.map { "\(Int(cursor.x)), \(Int(cursor.y))   Δ \(Int(abs(cursor.x - $0.x))) × \(Int(abs(cursor.y - $0.y)))" }
                ?? "\(Int(cursor.x)), \(Int(cursor.y))"
            Text(label)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 5))
                .foregroundStyle(.white)
                .fixedSize()
                .position(x: min(max(cursor.x * scale + 70, 76), size.width - 76),
                          y: min(max(cursor.y * scale - 18, 12), size.height - 12))
        }
    }

    private func crosshair(at point: CGPoint, size: CGSize, scale: CGFloat, color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: point.x * scale, y: 0))
            path.addLine(to: CGPoint(x: point.x * scale, y: size.height))
            path.move(to: CGPoint(x: 0, y: point.y * scale))
            path.addLine(to: CGPoint(x: size.width, y: point.y * scale))
        }
        .stroke(color, lineWidth: 1)
    }
}

/// The round handle on the split's divider. It lives in its own small window, the only part of the
/// split that takes the mouse; everywhere else clicks still reach the app.
struct SplitHandle: View {
    @ObservedObject var model: PanelModel
    @State private var start: (mouse: CGFloat, position: Double)?

    var body: some View {
        Image(systemName: "arrow.left.and.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 36, height: 36)
            .background(Color(red: 0.2, green: 0.2, blue: 0.22), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2))
            .shadow(color: .black.opacity(0.45), radius: 4, y: 1)
            .padding(6)
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    // The window follows the divider, so the drag is measured on the screen, not in the view.
                    let mouse = NSEvent.mouseLocation.x
                    let begin = start ?? (mouse, model.splitPosition)
                    start = begin
                    let moved = Double((mouse - begin.mouse) / max(model.splitWidth, 1))
                    model.splitPosition = min(max(begin.position + moved, 0), 1)
                }
                .onEnded { _ in start = nil })
            .help("Arrastra para comparar")
            .accessibilityLabel("Divisor de la comparación")
    }
}
