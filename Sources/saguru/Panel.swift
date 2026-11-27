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
    private var handle: NSPanel!
    private var drawer: NSPanel!
    private var drawerHost: NSHostingView<DrawerView>!
    private var backdrop: NSPanel!
    private var shownTool: Tool?
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
        var platform: Platform = .ios
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NetworkWindow.installEditMenu()
        // The Simulator's chrome is dark in both system appearances; popovers, menus and dialogs follow it.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        (rail, railHost) = makePanel(RailView(model: model))
        (toast, toastHost) = makePanel(ToastView(text: ""))
        toast.ignoresMouseEvents = true
        (overlay, _) = makePanel(OverlayView(model: model))
        // The design overlay is only ever drawn over the Simulator: it never takes its clicks.
        overlay.ignoresMouseEvents = true
        (handle, _) = makePanel(SplitHandle(model: model))
        // The docked panel takes the keyboard (its forms have text fields), so it is a window that can be key.
        let host = NSHostingView(rootView: DrawerView(model: model))
        let drawer = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        drawer.isOpaque = false
        drawer.backgroundColor = .clear
        drawer.hasShadow = true
        drawer.hidesOnDeactivate = false
        drawer.isMovable = false
        drawer.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        drawer.contentView = host
        self.drawer = drawer
        drawerHost = host
        (backdrop, _) = makePanel(BackdropView())
        backdrop.ignoresMouseEvents = true
        // Developer builds lose the Accessibility permission whenever the signature changes, so it is
        // asked for at every launch that does not have it. macOS applies it after a relaunch.

        model.restoreInterruptedAppearances()
        model.refreshDevices()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Polls fast while the Simulator window is moving and slowly otherwise.
    private func step() {
        tick += 1
        let moving = Date().timeIntervalSince(lastChange) < 1.5
        let every = sim == nil ? 20 : (moving || model.measuring || model.split != nil ? 1 : 6)
        if tick % every == 0 || model.openTool != shownTool { follow() }
        if tick % 240 == 0 { model.refreshDevices() }
        if tick % 60 == 0 { model.checkAgent() }
        updateToast()
    }

    private func follow() {
        guard let found = Self.simulatorWindow(ignoring: [rail.windowNumber, toast.windowNumber, overlay.windowNumber, handle.windowNumber, drawer.windowNumber, backdrop.windowNumber]) else {
            if sim != nil, !NSApp.isActive {
                // Keep the rail while one of our own popovers or dialogs is in use.
                sim = nil
                [rail, toast, overlay, handle, drawer, backdrop].forEach { $0?.orderOut(nil) }
                shownTool = nil
            }
            return
        }
        let (window, above) = found
        model.simulatorWindow = window.topLeft
        if model.platform != window.platform {
            model.platform = window.platform
            // A tool from the other platform makes no sense here: fall back to the one that always fits.
            if model.openTool != nil { model.openTool = window.platform == .android ? .android : .context }
        }
        if window.platform == .ios {
            if sim == nil { model.refreshDevices() }
            if window != sim, window.number != sim?.number {
                // With several simulators open, the panel acts on the one it is attached to. macOS only tells
                // which simulator a window shows to apps with Accessibility (or Screen Recording) permission.
                if !window.title.isEmpty {
                    model.select(windowTitle: window.title)
                } else if let title = SimulatorAX.window(at: window.topLeft)?.title {
                    model.select(windowTitle: title)
                }
                model.knowsWindowDevice = !window.title.isEmpty || SimulatorAX.trusted
            }
        } else if window != sim, window.number != sim?.number {
            // A new Android window: look again for the phone or emulator behind it.
            model.android.reload()
        }
        if window != sim {
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
        // While the Simulator (or Saguru) is the front app, our windows simply float: nothing is
        // reordered around the user's clicks. Behind another app they drop to the normal level and are
        // tucked just above the Simulator window, so that app covers both together.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let shouldFloat = front == "com.apple.iphonesimulator" || NSApp.isActive
        if shouldFloat != floating {
            floating = shouldFloat
            [rail, toast, overlay, handle, drawer].forEach { $0?.level = shouldFloat ? .floating : .normal }
        }
        // Unfolded, the panel carries the tools and the button steps aside.
        if model.openTool != nil {
            if rail.isVisible { rail.orderOut(nil) }
        } else {
            if !rail.isVisible { rail.orderFrontRegardless() }
            if !floating, !above.contains(rail.windowNumber) { rail.order(.above, relativeTo: window.number) }
        }
        followDrawer(window, screen: screen, above: above)
        followOverlay(window, isAbove: floating || above.contains(overlay.windowNumber))
    }

    /// The docked panel sits beyond the rail, as tall as the Simulator window, and the tray goes behind all three.
    private var shownExpanded = false
    /// Where the Simulator's window was (top-left coordinates) before the panel was expanded.
    private var restoreTo: CGPoint?

    private func followDrawer(_ window: SimWindow, screen: NSScreen?, above: Set<Int>) {
        let gap: CGFloat = 6
        let railOnRight = rail.frame.minX >= window.frame.midX
        var united = window.frame
        let visible = screen?.visibleFrame ?? window.frame
        // Only an open panel can be expanded: folded, the Simulator goes back where it was.
        let expanded = model.expanded && model.openTool != nil
        if expanded != shownExpanded {
            let screenTop = NSScreen.screens.first?.frame.maxY ?? visible.maxY
            if expanded {
                restoreTo = window.topLeft.origin
                SimulatorAX.move(windowAt: window.topLeft, to: CGPoint(x: visible.minX + 18, y: screenTop - visible.maxY + 14))
            } else if let restoreTo {
                SimulatorAX.move(windowAt: window.topLeft, to: restoreTo)
                self.restoreTo = nil
            }
        }
        if model.openTool != nil {
            let room = railOnRight ? visible.maxX - window.frame.maxX - gap - 10 : window.frame.minX - gap - 10 - visible.minX
            let width = min(drawerHost.fittingSize.width, max(room, 320))
            let height = max(window.frame.height, 360)
            let x = railOnRight ? window.frame.maxX + gap : window.frame.minX - gap - width
            // Expanded, Saguru takes the whole screen with the Simulator set into it: the Simulator goes to
            // the left edge and the tools fill everything beside it. Its old place is kept to put it back.
            var target = NSRect(x: x, y: window.frame.maxY - height, width: width, height: height)
            if expanded {
                // Beside the Simulator wherever it is (it may not have been allowed to move), on its roomier side.
                let onRight = visible.maxX - window.frame.maxX >= window.frame.minX - visible.minX
                let from = onRight ? window.frame.maxX + gap : visible.minX + 14
                let to = onRight ? visible.maxX - 14 : window.frame.minX - gap
                target = NSRect(x: from, y: visible.minY + 14, width: max(to - from, 320), height: visible.height - 28)
            }
            if drawer.frame != target {
                // The change of size is shown as one; following the Simulator's window as it is dragged is not.
                drawer.setFrame(target, display: true, animate: expanded != shownExpanded && drawer.isVisible)
            }
            if model.openTool != shownTool {
                // Typing in a form needs Saguru to be the active app and the panel its key window.
                NSApp.activate(ignoringOtherApps: true)
                drawer.makeKeyAndOrderFront(nil)
            } else if !drawer.isVisible {
                drawer.orderFrontRegardless()
            }
            if !floating, !above.contains(drawer.windowNumber) { drawer.order(.above, relativeTo: window.number) }
            // The tray behind both: around the two of them, or the whole screen when expanded.
            united = expanded ? visible.insetBy(dx: 12, dy: 12) : united.union(target)
        } else {
            if drawer.isVisible { drawer.orderOut(nil) }
            united = united.union(rail.frame)
        }
        shownExpanded = expanded
        let changed = model.openTool != shownTool
        shownTool = model.openTool

        let tray = united.insetBy(dx: -8, dy: -8)
        if backdrop.frame != tray { backdrop.setFrame(tray, display: true) }
        // Always just under the Simulator's window, whichever app is in front.
        if !backdrop.isVisible || changed || tick % 12 == 0 { backdrop.order(.below, relativeTo: window.number) }
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
            if handle.isVisible { handle.orderOut(nil) }
            return
        }
        let frame = NSRect(x: window.frame.minX + offset.minX, y: window.frame.maxY - offset.minY - offset.height,
                           width: offset.width, height: offset.height)
        if overlay.frame != frame { overlay.setFrame(frame, display: true) }
        if !overlay.isVisible { overlay.orderFrontRegardless() }
        if !isAbove { overlay.order(.above, relativeTo: window.number) }

        if model.splitPicture != nil {
            model.splitWidth = frame.width
            let size = handle.frame.size
            let spot = NSPoint(x: frame.minX + frame.width * model.splitPosition - size.width / 2,
                               y: frame.minY + frame.height * 0.22 - size.height / 2)
            if handle.frame.origin != spot { handle.setFrameOrigin(spot) }
            if !handle.isVisible { handle.orderFrontRegardless() }
            if !floating { handle.order(.above, relativeTo: overlay.windowNumber) }
        } else if handle.isVisible {
            handle.orderOut(nil)
        }

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
        guard rail.isVisible || drawer.isVisible, !text.isEmpty else {
            if toast.isVisible { toast.orderOut(nil) }
            toastText = ""
            return
        }
        if text != toastText {
            toastText = text
            toastHost.rootView = ToastView(text: text)
        }
        let size = toastHost.fittingSize
        let mouse = NSEvent.mouseLocation
        let frame: NSRect
        if drawer.isVisible {
            // Under the row of tools, below the cursor.
            let x = min(max(mouse.x - size.width / 2, drawer.frame.minX + 8), drawer.frame.maxX - size.width - 8)
            frame = NSRect(x: x, y: drawer.frame.maxY - 46 - size.height, width: size.width, height: size.height)
        } else {
            // Beside the button, on the side away from the Simulator.
            let onRight = rail.frame.minX >= (sim?.frame.midX ?? 0)
            let x = onRight ? rail.frame.maxX + 6 : rail.frame.minX - 6 - size.width
            frame = NSRect(x: x, y: rail.frame.midY - size.height / 2, width: size.width, height: size.height)
        }
        if toast.frame != frame { toast.setFrame(frame, display: true) }
        if !toast.isVisible { toast.orderFrontRegardless() }
    }

    /// The window a given app's owner name belongs to, if Saguru can hang off it: the iOS Simulator, an
    /// Android emulator, or a mirror of an Android phone.
    private static func platform(forOwner owner: String) -> Platform? {
        if owner == "Simulator" { return .ios }
        // Android Studio's emulator (qemu-backed), and the mirrors we know: Mirroru and scrcpy.
        if owner.contains("qemu") || owner == "Emulator" || owner == "Mirroru" || owner == "scrcpy" { return .android }
        return nil
    }

    /// Frontmost on-screen device window the panel can hang off. Needs no special permission.
    /// `above` lists which of our own windows are stacked in front of it.
    private static func simulatorWindow(ignoring own: [Int]) -> (SimWindow, above: Set<Int>)? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var above = Set<Int>()
        for window in list where (window[kCGWindowLayer as String] as? Int) == 0 {
            let number = window[kCGWindowNumber as String] as? Int ?? 0
            let owner = window[kCGWindowOwnerName as String] as? String ?? ""
            let title = window[kCGWindowName as String] as? String ?? ""
            // An Android emulator's title says "Android Emulator"; a plain window of the same process is not it.
            let emulatorTitle = owner == "Emulator" || owner.contains("qemu")
            if let found = platform(forOwner: owner), !(emulatorTitle && !title.isEmpty && !title.contains("Emulator")),
               let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
               let w = bounds["Width"], let h = bounds["Height"], let x = bounds["X"], let y = bounds["Y"], h > 200,
               NSScreen.screens.contains(where: { $0.frame.intersects(CGRect(x: x, y: primaryHeight - y - h, width: w, height: h)) }) {
                let sim = SimWindow(number: number, title: title, topLeft: CGRect(x: x, y: y, width: w, height: h),
                                    frame: CGRect(x: x, y: primaryHeight - y - h, width: w, height: h), platform: found)
                return (sim, above)
            }
            if own.contains(number) { above.insert(number) }
        }
        return nil
    }
}
