import XCTest
@testable import MacMonitorWidget

final class DynamicIslandMathTests: XCTestCase {
    // MARK: - Notch presence

    func testNotchPresentWhenAuxiliaryAreaExistsAndSafeAreaExceedsMenuBar() {
        XCTAssertTrue(DynamicIslandMath.notchPresent(safeAreaTopInset: 32, auxiliaryTopLeftArea: .zero))
    }

    func testNotchAbsentWhenAuxiliaryAreaIsNil() {
        XCTAssertFalse(DynamicIslandMath.notchPresent(safeAreaTopInset: 32, auxiliaryTopLeftArea: nil))
    }

    func testNotchAbsentWhenSafeAreaDoesNotExceedMenuBar() {
        // 24pt or less is a standard menu bar with no notch
        XCTAssertFalse(DynamicIslandMath.notchPresent(safeAreaTopInset: 24, auxiliaryTopLeftArea: .zero))
        XCTAssertFalse(DynamicIslandMath.notchPresent(safeAreaTopInset: 0, auxiliaryTopLeftArea: .zero))
    }

    func testNotchAbsentForNonFiniteInset() {
        XCTAssertFalse(DynamicIslandMath.notchPresent(safeAreaTopInset: .nan, auxiliaryTopLeftArea: .zero))
        XCTAssertFalse(DynamicIslandMath.notchPresent(safeAreaTopInset: .infinity, auxiliaryTopLeftArea: .zero))
    }

    // MARK: - Island frames

    func testRestingFrameHugsNotchWithCompactEars() {
        // Screen 1728pt wide (a 14" MacBook at default scaling), notch 32pt tall.
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let frame = DynamicIslandMath.restingFrame(screen: screen, notchHeight: 32, notchWidth: 200)

        // Exactly notch-height so the island reads as part of the hardware.
        XCTAssertEqual(frame.height, 32, accuracy: 0.01)
        // One ear either side of the cutout.
        XCTAssertEqual(frame.width, 200 + DynamicIslandMath.compactEarWidth * 2, accuracy: 0.01)
        // Horizontally centered: midX == screen midX
        XCTAssertEqual(frame.midX, screen.midX, accuracy: 0.01)
        // Top edge at the top of the screen (y in screen coords; AppKit origin
        // is bottom-left, so "top" is screen.maxY)
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.01)
    }

    func testExpandedFrameGrowsDownwardFromSameTopEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let resting = DynamicIslandMath.restingFrame(screen: screen, notchHeight: 32, notchWidth: 200)
        let expanded = DynamicIslandMath.expandedFrame(screen: screen, notchHeight: 32, notchWidth: 200)

        // Same horizontal center
        XCTAssertEqual(expanded.midX, resting.midX, accuracy: 0.01)
        // Same top edge (grows downward = top edge fixed, bottom edge drops)
        XCTAssertEqual(expanded.maxY, resting.maxY, accuracy: 0.01)
        XCTAssertGreaterThan(expanded.height, resting.height)
        XCTAssertGreaterThan(expanded.width, resting.width)
    }

    func testFramesCenterOnAnOffsetDisplay() {
        let screen = CGRect(x: -1728, y: 120, width: 1728, height: 1117)
        let resting = DynamicIslandMath.restingFrame(screen: screen, notchHeight: 32, notchWidth: 190)
        let expanded = DynamicIslandMath.expandedFrame(screen: screen, notchHeight: 32, notchWidth: 190)

        XCTAssertEqual(resting.midX, screen.midX, accuracy: 0.01)
        XCTAssertEqual(expanded.midX, screen.midX, accuracy: 0.01)
        XCTAssertEqual(resting.maxY, screen.maxY, accuracy: 0.01)
        XCTAssertEqual(expanded.maxY, screen.maxY, accuracy: 0.01)
    }

    func testInvalidNotchWidthUsesFallback() {
        XCTAssertEqual(
            DynamicIslandMath.restingWidth(notchWidth: .nan),
            DynamicIslandMath.restingWidth(notchWidth: DynamicIslandMath.fallbackNotchWidth),
            accuracy: 0.01
        )
    }

    func testExpandedWidthNeverDropsBelowMinimum() {
        XCTAssertEqual(
            DynamicIslandMath.expandedWidth(notchWidth: 10),
            DynamicIslandMath.expandedMinimumWidth,
            accuracy: 0.01
        )
        XCTAssertGreaterThan(
            DynamicIslandMath.expandedWidth(notchWidth: 400),
            DynamicIslandMath.expandedMinimumWidth
        )
    }

    func testRestingFrameSanitizesNonFiniteNotchHeight() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let frame = DynamicIslandMath.restingFrame(screen: screen, notchHeight: .nan, notchWidth: 200)
        XCTAssertEqual(frame.height, 1, accuracy: 0.01)
        XCTAssertEqual(frame.maxY, screen.maxY, accuracy: 0.01)
    }

    // MARK: - Fullscreen detection

    func testFullscreenWhenWindowCoversScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let covering = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertTrue(DynamicIslandMath.isFullscreen(window: covering, screen: screen))
    }

    func testNotFullscreenWhenWindowIsSmallerThanScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let smaller = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertFalse(DynamicIslandMath.isFullscreen(window: smaller, screen: screen))
    }

    func testNotFullscreenWhenWindowCoversWrongScreen() {
        let screen = CGRect(x: 1728, y: 0, width: 1920, height: 1080) // external display
        let coveringMain = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        XCTAssertFalse(DynamicIslandMath.isFullscreen(window: coveringMain, screen: screen))
    }
}
