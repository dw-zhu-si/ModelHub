import AppKit
import XCTest
@testable import ModelHub

@MainActor
final class WindowLifecycleTests: XCTestCase {
    func testMissingWindowWaitsForSwiftUIWindowCreation() {
        XCTAssertEqual(
            ModelHubWindowController.presentationPlan(
                hasExistingWindow: false,
                remainingAttempts: 1,
                canCreateFallbackWindow: true
            ),
            .waitForMainWindow
        )
    }

    func testMissingWindowUsesFallbackAfterBoundedWait() {
        XCTAssertEqual(
            ModelHubWindowController.presentationPlan(
                hasExistingWindow: false,
                remainingAttempts: 0,
                canCreateFallbackWindow: true
            ),
            .createFallbackWindow
        )
    }

    func testExistingWindowIsFocusedWithoutCreatingDuplicate() {
        XCTAssertEqual(
            ModelHubWindowController.presentationPlan(
                hasExistingWindow: true,
                remainingAttempts: 0,
                canCreateFallbackWindow: true
            ),
            .showExisting
        )
    }

    func testMainWindowCloseHidesInsteadOfDestroyingWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.orderFront(nil)
        let delegate = ModelHubMainWindowDelegateProxy(forwarding: nil)

        XCTAssertFalse(delegate.windowShouldClose(window))
        XCTAssertFalse(window.isVisible)
    }
}
