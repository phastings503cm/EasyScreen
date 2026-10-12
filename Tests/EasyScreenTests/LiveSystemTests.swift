import AppKit
import Carbon.HIToolbox
import XCTest
@testable import EasyScreen

/// Exercises the real system APIs (ScreenCaptureKit, Carbon hotkeys). Opt-in
/// because it needs Screen Recording permission for the test host:
///
///     EASYSCREEN_LIVE_TESTS=1 swift test --filter LiveSystemTests
///
/// Captured pixels are only measured in memory, never written anywhere.
@MainActor
final class LiveSystemTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["EASYSCREEN_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set EASYSCREEN_LIVE_TESTS=1 to run live capture / hotkey tests")
        }
    }

    func testSnapshotsEveryDisplayAtNativeResolution() async throws {
        try XCTSkipUnless(Permissions.hasScreenRecording, "Test host lacks Screen Recording permission")
        let snapshots = try await ScreenCapturer.snapshotAllDisplays()
        XCTAssertEqual(snapshots.count, NSScreen.screens.count)
        for snapshot in snapshots {
            let frame = snapshot.screen.frame
            let scale = snapshot.screen.backingScaleFactor
            XCTAssertEqual(snapshot.image.width, Int(frame.width * scale))
            XCTAssertEqual(snapshot.image.height, Int(frame.height * scale))
            XCTAssertEqual(snapshot.scale, scale, accuracy: 0.001)

            // Same crop math the overlay uses for a 200×100 pt selection.
            let rect = CGRect(x: 10, y: 20, width: 200, height: 100)
            let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                   width: rect.width * scale, height: rect.height * scale).integral
            let crop = try XCTUnwrap(snapshot.image.cropping(to: pixelRect))
            XCTAssertEqual(crop.width, Int(200 * scale))
            XCTAssertEqual(crop.height, Int(100 * scale))
        }
        XCTAssertFalse(OnScreenWindow.current().contains { $0.frame.width < 40 })
    }

    func testRegistersGlobalHotkey() {
        // An obscure combo that won't collide with the user's own shortcuts.
        let combo = KeyCombo(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | optionKey | controlKey))
        let manager = HotkeyManager.shared
        manager.apply(bindings: [.captureFullScreen: combo])
        XCTAssertTrue(manager.failedActions.isEmpty)
        manager.suspend()
        manager.resume()
        XCTAssertTrue(manager.failedActions.isEmpty)
        manager.apply(bindings: [:])
    }
}
