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
    private var localClickMonitor: Any?

    /// Collapse callback invoked when a click lands outside the panel frame.
    var onCollapse: (() -> Void)?

    init(rootView: some View) {
        // .nonactivatingPanel: clicking the island never steals app focus.
        super.init(
            contentRect: DynamicIslandMath.restingFrame(
                screen: NSScreen.main?.frame ?? .zero,
                notchHeight: DynamicIslandPanel.notchHeight,
                notchWidth: DynamicIslandPanel.notchWidth
            ),
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
        // Let the hosting view fill the window frame (which we size explicitly
        // on expand/collapse) rather than letting it drive the window size.
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
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

    /// Width of the physical cutout between the two auxiliary menu-bar areas.
    static var notchWidth: CGFloat {
        guard let screen = menuBarScreen,
              let leftArea = screen.auxiliaryTopLeftArea,
              let rightArea = screen.auxiliaryTopRightArea else {
            return DynamicIslandMath.fallbackNotchWidth
        }

        let measuredWidth = rightArea.minX - leftArea.maxX
        guard measuredWidth.isFinite, measuredWidth > 0 else {
            return DynamicIslandMath.fallbackNotchWidth
        }
        return measuredWidth
    }

    /// The screen that hosts the menu bar (first in `NSScreen.screens`).
    static var menuBarScreen: NSScreen? {
        NSScreen.screens.first
    }

    // MARK: - Show / hide

    func show(expanded: Bool = false) {
        positionAtNotch(expanded: expanded)
        orderFront(nil)
        startClickMonitor()
    }

    func hide() {
        orderOut(nil)
        stopClickMonitor()
    }

    /// Re-anchor to the notch at the size matching the current expand state.
    func positionAtNotch(expanded: Bool = false) {
        guard let screen = DynamicIslandPanel.menuBarScreen else { return }
        setFrame(targetFrame(expanded: expanded, screen: screen.frame), display: true)
    }

    private func targetFrame(expanded: Bool, screen: CGRect) -> CGRect {
        expanded
            ? DynamicIslandMath.expandedFrame(
                screen: screen,
                notchHeight: DynamicIslandPanel.notchHeight,
                notchWidth: DynamicIslandPanel.notchWidth
            )
            : DynamicIslandMath.restingFrame(
                screen: screen,
                notchHeight: DynamicIslandPanel.notchHeight,
                notchWidth: DynamicIslandPanel.notchWidth
            )
    }

    /// Animate the window frame to the resting or expanded size, anchored to
    /// the notch. Mirrors the SwiftUI content's spring so the pill appears to
    /// grow downward.
    func setExpanded(_ expanded: Bool) {
        guard let screen = DynamicIslandPanel.menuBarScreen else { return }
        let target = targetFrame(expanded: expanded, screen: screen.frame)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            self.animator().setFrame(target, display: true)
        }
    }

    // MARK: - Fullscreen detection

    /// True when a normal-layer window owned by the frontmost application
    /// covers the menu-bar screen. Filtering by owner avoids mistaking an
    /// auto-hidden menu bar or a background app for fullscreen content.
    static func frontmostAppIsFullscreen() -> Bool {
        guard let screen = menuBarScreen,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let windowInfo = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return false
        }

        let displayBounds = CGDisplayBounds(CGDirectDisplayID(screenNumber.uint32Value))

        for info in windowInfo {
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  ownerPID == frontmostPID,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha > 0,
                  let bounds = info[kCGWindowBounds as String],
                  let windowFrame = CGRect(dictionaryRepresentation: bounds as! CFDictionary) else {
                continue
            }

            if DynamicIslandMath.isFullscreen(window: windowFrame, screen: displayBounds) {
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
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self {
                self.onCollapse?()
            }
            return event
        }
    }

    private func stopClickMonitor() {
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
    }

    deinit {
        stopClickMonitor()
    }
}
