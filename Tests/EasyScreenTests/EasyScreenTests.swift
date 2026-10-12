import AppKit
import Carbon.HIToolbox
import XCTest
@testable import EasyScreen

final class KeyComboTests: XCTestCase {
    func testDefaultRegionShortcutIsCommandShift1() {
        let combo = KeyCombo.defaultRegion
        XCTAssertEqual(combo.keyCode, UInt32(kVK_ANSI_1))
        XCTAssertEqual(combo.modifierFlags, [.command, .shift])
        XCTAssertEqual(combo.modifierSymbols, "⇧⌘")
        XCTAssertTrue(combo.displayString.hasPrefix("⇧⌘"))
        XCTAssertTrue(combo.isValidGlobalHotkey)
    }

    func testModifierRoundTrip() {
        let flags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let combo = KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifierFlags: flags)
        XCTAssertEqual(combo.modifierFlags, flags)
        XCTAssertEqual(combo.modifierSymbols, "⌃⌥⇧⌘")
    }

    func testShiftOnlyIsNotAValidGlobalHotkey() {
        XCTAssertFalse(KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifierFlags: [.shift]).isValidGlobalHotkey)
        XCTAssertFalse(KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifierFlags: []).isValidGlobalHotkey)
        XCTAssertTrue(KeyCombo(keyCode: UInt16(kVK_F5), modifierFlags: []).isValidGlobalHotkey)
    }

    func testSpecialKeyNames() {
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_F12), modifiers: 0).keyName, "F12")
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_Space), modifiers: 0).keyName, "Space")
        XCTAssertEqual(KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: 0).keyName, "←")
    }
}

final class PreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "EasyScreenTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaults() {
        let prefs = Preferences(defaults: defaults)
        XCTAssertTrue(prefs.openEditor)
        XCTAssertTrue(prefs.copyToClipboard)
        XCTAssertFalse(prefs.saveToFolder)
        XCTAssertEqual(prefs.hotkey(for: .captureRegion), .defaultRegion)
        XCTAssertNil(prefs.hotkey(for: .captureFullScreen))
        XCTAssertFalse(prefs.hasNoActions)
    }

    func testActionTogglesPersist() {
        let prefs = Preferences(defaults: defaults)
        prefs.openEditor = false
        prefs.copyToClipboard = false
        prefs.saveToFolder = true
        let reloaded = Preferences(defaults: defaults)
        XCTAssertFalse(reloaded.openEditor)
        XCTAssertFalse(reloaded.copyToClipboard)
        XCTAssertTrue(reloaded.saveToFolder)
    }

    func testCustomHotkeyPersists() {
        let prefs = Preferences(defaults: defaults)
        let custom = KeyCombo(keyCode: UInt16(kVK_ANSI_S), modifierFlags: [.control, .option])
        prefs.setHotkey(custom, for: .captureRegion)
        XCTAssertEqual(Preferences(defaults: defaults).hotkey(for: .captureRegion), custom)
    }

    func testClearedDefaultHotkeyStaysCleared() {
        let prefs = Preferences(defaults: defaults)
        prefs.setHotkey(nil, for: .captureRegion)
        XCTAssertNil(Preferences(defaults: defaults).hotkey(for: .captureRegion))
    }

    func testAssigningComboMovesItFromOtherAction() {
        let prefs = Preferences(defaults: defaults)
        prefs.setHotkey(.defaultRegion, for: .captureFullScreen)
        XCTAssertEqual(prefs.hotkey(for: .captureFullScreen), .defaultRegion)
        XCTAssertNil(prefs.hotkey(for: .captureRegion))
    }

    func testResetHotkeys() {
        let prefs = Preferences(defaults: defaults)
        prefs.setHotkey(nil, for: .captureRegion)
        prefs.resetHotkeys()
        XCTAssertEqual(prefs.hotkey(for: .captureRegion), .defaultRegion)
    }

    func testColorHexRoundTrip() {
        let color = NSColor(hexString: "#12AB34CC")!
        XCTAssertEqual(color.hexString, "#12AB34CC")
        XCTAssertEqual(NSColor(hexString: "FF0000")?.hexString, "#FF0000FF")
        XCTAssertNil(NSColor(hexString: "nope"))
    }
}

final class ImageOutputTests: XCTestCase {
    func testFilenameFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 12
        components.hour = 9; components.minute = 41; components.second = 7
        let date = Calendar.current.date(from: components)!
        XCTAssertEqual(ImageOutput.baseFilename(prefix: "Screenshot", date: date), "Screenshot 2026-10-12 at 09.41.07")
        XCTAssertEqual(ImageOutput.baseFilename(prefix: "a/b:c", date: date), "a-b-c 2026-10-12 at 09.41.07")
        XCTAssertEqual(ImageOutput.baseFilename(prefix: "  ", date: date), "2026-10-12 at 09.41.07")
    }

    func testSaveCreatesFolderAndAvoidsCollisions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("EasyScreenTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = TestImages.solid(width: 40, height: 20)
        let date = Date()
        let first = try ImageOutput.save(image, scale: 2, to: folder, prefix: "Shot", date: date, format: .png)
        let second = try ImageOutput.save(image, scale: 2, to: folder, prefix: "Shot", date: date, format: .png)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.contains("(2)"))

        let loaded = try XCTUnwrap(CapturedImage.load(from: first))
        XCTAssertEqual(loaded.image.width, 40)
        XCTAssertEqual(loaded.scale, 2, "PNG should carry 144 dpi so it reopens at Retina scale")

        let jpeg = try ImageOutput.save(image, scale: 1, to: folder, prefix: "Shot", date: date, format: .jpeg)
        XCTAssertEqual(jpeg.pathExtension, "jpg")
        XCTAssertEqual(ImageOutput.format(for: jpeg), .jpeg)
    }

    func testClipboardContainsPNG() {
        let image = TestImages.solid(width: 10, height: 10)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("EasyScreenTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        ImageOutput.copyToClipboard(image, scale: 1, pasteboard: pasteboard)
        XCTAssertNotNil(pasteboard.data(forType: .png))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }
}

final class AnnotationTests: XCTestCase {
    func testRectangleHitTestingStrokeVsInterior() {
        let a = Annotation(kind: .rectangle(CGRect(x: 10, y: 10, width: 100, height: 50)), color: .red, lineWidth: 4)
        XCTAssertTrue(a.hitTest(CGPoint(x: 10, y: 30), tolerance: 3, includeInterior: false))
        XCTAssertFalse(a.hitTest(CGPoint(x: 60, y: 35), tolerance: 3, includeInterior: false))
        XCTAssertTrue(a.hitTest(CGPoint(x: 60, y: 35), tolerance: 3, includeInterior: true))
        XCTAssertFalse(a.hitTest(CGPoint(x: 200, y: 200), tolerance: 3, includeInterior: true))
    }

    func testEllipseHitTesting() {
        let a = Annotation(kind: .ellipse(CGRect(x: 0, y: 0, width: 100, height: 100)), color: .red, lineWidth: 2)
        XCTAssertTrue(a.hitTest(CGPoint(x: 100, y: 50), tolerance: 3, includeInterior: false))
        XCTAssertFalse(a.hitTest(CGPoint(x: 50, y: 50), tolerance: 3, includeInterior: false))
        XCTAssertTrue(a.hitTest(CGPoint(x: 50, y: 50), tolerance: 3, includeInterior: true))
    }

    func testArrowHitTesting() {
        let a = Annotation(kind: .arrow(from: .zero, to: CGPoint(x: 100, y: 0)), color: .red, lineWidth: 4)
        XCTAssertTrue(a.hitTest(CGPoint(x: 50, y: 3), tolerance: 3, includeInterior: false))
        XCTAssertFalse(a.hitTest(CGPoint(x: 50, y: 30), tolerance: 3, includeInterior: false))
    }

    func testTextFrameGrowsWithBackgroundPadding() {
        let box = Annotation.TextBox(origin: CGPoint(x: 5, y: 5), string: "Hello", fontSize: 20,
                                     hasBackground: true, backgroundColor: .white)
        let frame = AnnotationRenderer.textFrame(for: box)
        let text = AnnotationRenderer.textSize(for: box)
        XCTAssertGreaterThan(frame.width, text.width)
        XCTAssertGreaterThan(frame.height, text.height)
        XCTAssertEqual(frame.origin, box.origin)
    }

    func testSquareConstraintAndSnap() {
        let r = Geometry.rect(from: .zero, to: CGPoint(x: 30, y: -10), square: true)
        XCTAssertEqual(r.width, r.height)
        let snapped = Geometry.snap45(from: .zero, to: CGPoint(x: 100, y: 8))
        XCTAssertEqual(snapped.y, 0, accuracy: 0.001)
    }

    func testSelectionRectFromCenter() {
        let r = OverlayView.rect(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 60, y: 70), square: false, fromCenter: true)
        XCTAssertEqual(r, CGRect(x: 40, y: 30, width: 20, height: 40))
    }
}

final class EditorModelTests: XCTestCase {
    private func makeModel() -> EditorModel {
        let suite = "EasyScreenTests-\(UUID().uuidString)"
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        return EditorModel(capture: CapturedImage(image: TestImages.solid(width: 200, height: 100), scale: 2, date: Date()),
                           preferences: prefs)
    }

    func testCanvasSizeUsesScale() {
        XCTAssertEqual(makeModel().canvasSize, CGSize(width: 100, height: 50))
    }

    func testUndoRedo() {
        let model = makeModel()
        model.add(model.makeAnnotation(.rectangle(CGRect(x: 1, y: 1, width: 10, height: 10))))
        model.add(model.makeAnnotation(.ellipse(CGRect(x: 5, y: 5, width: 10, height: 10))))
        XCTAssertEqual(model.annotations.count, 2)
        model.undo()
        XCTAssertEqual(model.annotations.count, 1)
        model.undo()
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.canUndo)
        model.redo()
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertTrue(model.canRedo)
    }

    func testStyleChangeAppliesToSelectionAsOneUndoStep() {
        let model = makeModel()
        let a = model.makeAnnotation(.rectangle(CGRect(x: 1, y: 1, width: 10, height: 10)))
        model.add(a)
        model.selectedID = a.id
        model.lineWidth = 7
        model.lineWidth = 9
        XCTAssertEqual(model.selected?.lineWidth, 9)
        model.undo()
        XCTAssertEqual(model.selected?.lineWidth, a.lineWidth)
    }

    func testUnexportedChangesTracking() {
        let model = makeModel()
        XCTAssertFalse(model.hasUnexportedChanges)
        model.add(model.makeAnnotation(.arrow(from: .zero, to: CGPoint(x: 20, y: 20))))
        XCTAssertTrue(model.hasUnexportedChanges)
        model.exportedChangeCount = model.changeCount
        XCTAssertFalse(model.hasUnexportedChanges)
    }

    func testRenderKeepsPixelSizeAndDrawsAnnotations() throws {
        let model = makeModel()
        model.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        let box = Annotation.TextBox(origin: CGPoint(x: 10, y: 10), string: "Hi", fontSize: 14,
                                     hasBackground: true, backgroundColor: NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        model.add(model.makeAnnotation(.text(box)))
        let rendered = try XCTUnwrap(model.renderImage())
        XCTAssertEqual(rendered.width, 200)
        XCTAssertEqual(rendered.height, 100)

        // The label background (blue) should appear near the text origin; the
        // far corner should still be the original gray.
        let rep = NSBitmapImageRep(cgImage: rendered)
        let inside = try XCTUnwrap(rep.colorAt(x: 24, y: 24)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(inside.blueComponent, 0.6)
        let corner = try XCTUnwrap(rep.colorAt(x: 195, y: 95)?.usingColorSpace(.sRGB))
        XCTAssertEqual(corner.blueComponent, corner.redComponent, accuracy: 0.05)
    }
}

enum TestImages {
    static func solid(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }
}
