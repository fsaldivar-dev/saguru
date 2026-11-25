import AppKit
import SwiftUI

private func makePanel<Content: View>(_ view: Content) -> (NSPanel, NSHostingView<Content>) {
    let hosting = NSHostingView(rootView: view)
    // Borderless panels never become key, so clicking the rail leaves keyboard focus in the Simulator.
    let panel = NSPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isMovable = false
    // A window stays on the desktop (Space) where it was first shown. The Simulator may be on any of them,
    // or be moved, so these panels exist on all desktops and are simply hidden where it is not in view.
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = hosting
    return (panel, hosting)
}

/// Keeps the rail (and the toast and design overlay) glued to the frontmost Simulator window.
final class PanelController: NSObject, NSApplicationDelegate {
    private let model = PanelModel()
    private var rail: NSPanel!
    private var railHost: NSHostingView<RailView>!
    private var toast: NSPanel!
    private var toastHost: NSHostingView<ToastView>!
    private var overlay: NSPanel!
    private var toastText = ""
    private var timer: Timer?
    private var tick = 0
    private var lastChange = Date.distantPast
    private var sim: SimWindow?
    private var screenOffset: CGRect?
    private var floating = false
    private var optionWasDown = false

    private struct SimWindow: Equatable {
        let number: Int
        /// Device name as the window server reports it ("iPhone 17"); empty if macOS withholds it.
        var title = ""
        /// Top-left origin (what the window server and Accessibility use).
        let topLeft: CGRect
        /// Bottom-left origin (what AppKit uses).
        let frame: CGRect
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The Simulator's chrome is dark in both system appearances; popovers, menus and dialogs follow it.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        (rail, railHost) = makePanel(RailView(model: model))
        (toast, toastHost) = makePanel(ToastView(text: ""))
        toast.ignoresMouseEvents = true
        (overlay, _) = makePanel(OverlayView(model: model))
        // The design overlay is only ever drawn over the Simulator: it never takes its clicks.
        overlay.ignoresMouseEvents = true

        model.refreshDevices()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Polls fast while the Simulator window is moving and slowly otherwise.
    private func step() {
        tick += 1
        let moving = Date().timeIntervalSince(lastChange) < 1.5
        let every = sim == nil ? 20 : (moving || model.measuring ? 1 : 6)
        if tick % every == 0 { follow() }
        if tick % 240 == 0 { model.refreshDevices() }
        updateToast()
    }

    private func follow() {
        guard let found = Self.simulatorWindow(ignoring: [rail.windowNumber, toast.windowNumber, overlay.windowNumber]) else {
            if sim != nil, !NSApp.isActive {
                // Keep the rail while one of our own popovers or dialogs is in use.
                sim = nil
                [rail, toast, overlay].forEach { $0?.orderOut(nil) }
            }
            return
        }
        let (window, above) = found
        if sim == nil { model.refreshDevices() }
        if window != sim {
            // With several simulators open, the panel acts on the one it is attached to. macOS only tells
            // which simulator a window shows to apps with Accessibility (or Screen Recording) permission.
            if window.number != sim?.number {
                if !window.title.isEmpty {
                    model.select(windowTitle: window.title)
                } else if let title = SimulatorAX.window(at: window.topLeft)?.title {
                    model.select(windowTitle: title)
                }
                model.knowsWindowDevice = !window.title.isEmpty || SimulatorAX.trusted
            }
            if window.topLeft.size != sim?.topLeft.size { screenOffset = nil }
            sim = window
            lastChange = Date()
        }

        // Rail: right of the window, or left when it would fall off the screen.
        let size = railHost.fittingSize
        let gap: CGFloat = 6
        let screen = NSScreen.screens.first { $0.frame.intersects(window.frame) } ?? NSScreen.main
        var x = window.frame.maxX + gap
        if let visible = screen?.visibleFrame, x + size.width > visible.maxX, window.frame.minX - gap - size.width >= visible.minX {
            x = window.frame.minX - gap - size.width
        }
        let target = NSRect(x: x, y: window.frame.maxY - size.height, width: size.width, height: size.height)
        if rail.frame != target { rail.setFrame(target, display: true) }

        // Sit directly above the Simulator in the window stack, so other apps cover both together.
        // While the Simulator (or Simuru) is the front app, our windows simply float: nothing is
        // reordered around the user's clicks. Behind another app they drop to the normal level and are
        // tucked just above the Simulator window, so that app covers both together.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let shouldFloat = front == "com.apple.iphonesimulator" || NSApp.isActive
        if shouldFloat != floating {
            floating = shouldFloat
            [rail, toast, overlay].forEach { $0?.level = shouldFloat ? .floating : .normal }
        }
        if !rail.isVisible { rail.orderFrontRegardless() }
        if !floating, !above.contains(rail.windowNumber) { rail.order(.above, relativeTo: window.number) }
        followOverlay(window, isAbove: floating || above.contains(overlay.windowNumber))
    }

    private func followOverlay(_ window: SimWindow, isAbove: Bool) {
        if SimulatorAX.trusted, model.needsOverlay || tick % 60 == 0 {
            if screenOffset == nil || tick % 30 == 0, let info = SimulatorAX.window(at: window.topLeft) {
                if tick % 60 == 0 || screenOffset == nil { model.select(windowTitle: info.title) }
                screenOffset = info.screen.map { $0.offsetBy(dx: -window.topLeft.minX, dy: -window.topLeft.minY) }
            }
        }
        guard model.needsOverlay, let offset = screenOffset else {
            if overlay.isVisible { overlay.orderOut(nil) }
            return
        }
        let frame = NSRect(x: window.frame.minX + offset.minX, y: window.frame.maxY - offset.minY - offset.height,
                           width: offset.width, height: offset.height)
        if overlay.frame != frame { overlay.setFrame(frame, display: true) }
        if !overlay.isVisible { overlay.orderFrontRegardless() }
        if !isAbove { overlay.order(.above, relativeTo: window.number) }

        if model.measuring {
            let mouse = NSEvent.mouseLocation
            let landscape = frame.width > frame.height
            let points = model.screenPoints
            let wide = landscape ? max(points.width, points.height) : min(points.width, points.height)
            let scale = frame.width / max(wide, 1)
            let cursor: CGPoint? = frame.contains(mouse)
                ? CGPoint(x: ((mouse.x - frame.minX) / scale).rounded(), y: ((frame.maxY - mouse.y) / scale).rounded()) : nil
            if cursor != model.cursor { model.cursor = cursor }
            // Option pins a guide at the cursor; clicks are left alone so the app stays usable.
            let optionDown = NSEvent.modifierFlags.contains(.option)
            if optionDown, !optionWasDown, let cursor { model.guides.append(cursor) }
            optionWasDown = optionDown
        }
    }

    /// The capsule beside the rail: the outcome of the last action, or the name of the hovered button.
    private func updateToast() {
        let text = model.status.isEmpty ? model.hint : model.status
        guard rail.isVisible, !text.isEmpty else {
            if toast.isVisible { toast.orderOut(nil) }
            toastText = ""
            return
        }
        if text != toastText {
            toastText = text
            toastHost.rootView = ToastView(text: text)
        }
        // Beside the rail, on the side away from the Simulator, level with the cursor.
        let size = toastHost.fittingSize
        let onRight = rail.frame.minX >= (sim?.frame.midX ?? 0)
        let x = onRight ? rail.frame.maxX + 6 : rail.frame.minX - 6 - size.width
        let y = min(max(NSEvent.mouseLocation.y, rail.frame.minY + 14), rail.frame.maxY - 14) - size.height / 2
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if toast.frame != frame { toast.setFrame(frame, display: true) }
        if !toast.isVisible { toast.orderFrontRegardless() }
    }

    /// Frontmost on-screen Simulator device window. Needs no special permission.
    /// `above` lists which of our own windows are stacked in front of it.
    private static func simulatorWindow(ignoring own: [Int]) -> (SimWindow, above: Set<Int>)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var above = Set<Int>()
        for window in list where (window[kCGWindowLayer as String] as? Int) == 0 {
            let number = window[kCGWindowNumber as String] as? Int ?? 0
            if (window[kCGWindowOwnerName as String] as? String) == "Simulator",
               let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
               let w = bounds["Width"], let h = bounds["Height"], let x = bounds["X"], let y = bounds["Y"], h > 200,
               NSScreen.screens.contains(where: { $0.frame.intersects(CGRect(x: x, y: primaryHeight - y - h, width: w, height: h)) }) {
                let sim = SimWindow(number: number, title: window[kCGWindowName as String] as? String ?? "", topLeft: CGRect(x: x, y: y, width: w, height: h),
                                    frame: CGRect(x: x, y: primaryHeight - y - h, width: w, height: h))
                return (sim, above)
            }
            if own.contains(number) { above.insert(number) }
        }
        return nil
    }
}
