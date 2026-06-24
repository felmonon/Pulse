import SwiftUI
import AppKit

// MARK: - Dynamic Island Panel
/// A borderless, always-on-top `NSPanel` that anchors in the MacBook notch and
/// hosts the SwiftUI `DynamicIslandView`. The panel owns:
///   - window level / collection behavior (above everything, all spaces),
///   - notch detection + frame positioning,
///   - show / hide,
///   - the click-outside-to-collapse monitor.
///
/// It does NOT know about stats — it receives a root view from its owner.
final class DynamicIslandPanel: NSPanel {
    private var globalClickMonitor: Any?

    /// Collapse callback invoked when a click lands outside the panel frame.
    var onCollapse: (() -> Void)?

    init(rootView: some View) {
        // .nonactivatingPanel: clicking the island never steals app focus.
        super.init(
            contentRect: DynamicIslandMath.restingFrame(screen: NSScreen.main?.frame ?? .zero, notchHeight: DynamicIslandPanel.notchHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .statusBar
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.isMovable = false
        self.ignoresMouseEvents = false
        self.hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        self.contentView = hosting
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Notch geometry

    /// True when the menu-bar screen has a physical notch.
    static var notchIsPresent: Bool {
        guard let screen = menuBarScreen else { return false }
        return DynamicIslandMath.notchPresent(
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeftArea: screen.auxiliaryTopLeftArea
        )
    }

    /// The notch height on the menu-bar screen, or a sensible default.
    static var notchHeight: CGFloat {
        menuBarScreen?.safeAreaInsets.top ?? 32
    }

    /// The screen that hosts the menu bar (first in `NSScreen.screens`).
    static var menuBarScreen: NSScreen? {
        NSScreen.screens.first
    }

    // MARK: - Show / hide

    func show() {
        positionAtNotch()
        orderFront(nil)
        startClickMonitor()
    }

    func hide() {
        orderOut(nil)
        stopClickMonitor()
    }

    /// Re-anchor to the notch — call on screen-layout changes.
    func positionAtNotch() {
        guard let screen = DynamicIslandPanel.menuBarScreen else { return }
        let frame = DynamicIslandMath.restingFrame(screen: screen.frame, notchHeight: DynamicIslandPanel.notchHeight)
        setFrame(frame, display: true)
    }

    // MARK: - Fullscreen detection

    /// True when a normal-layer window fully covers the menu-bar screen —
    /// i.e. a fullscreen app is frontmost on that display.
    static func frontmostAppCoversMenuBarScreen() -> Bool {
        guard let screen = menuBarScreen else { return false }
        guard let windowInfo = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        for info in windowInfo {
            // kCGWindowLayer == 0 means a normal app window (not menu/overlay).
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            // Skip fully transparent windows.
            guard let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let w = boundsDict["Width"] as? CGFloat,
                  let h = boundsDict["Height"] as? CGFloat else { continue }

            let windowRect = CGRect(x: x, y: y, width: w, height: h)
            if DynamicIslandMath.isFullscreen(window: windowRect, screen: screen.frame) {
                return true
            }
        }
        return false
    }

    // MARK: - Click-outside-to-collapse

    private func startClickMonitor() {
        guard globalClickMonitor == nil else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            guard let self else { return }
            self.onCollapse?()
        }
    }

    private func stopClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
    }

    deinit {
        stopClickMonitor()
    }
}
