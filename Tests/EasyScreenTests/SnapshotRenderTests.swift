import AppKit
import SwiftUI
import XCTest
@testable import EasyScreen

/// Renders the main UI surfaces to PNGs for visual review. Skipped unless
/// `EASYSCREEN_SNAPSHOT_DIR` is set:
///
///     EASYSCREEN_SNAPSHOT_DIR=/tmp/shots swift test --filter SnapshotRenderTests
@MainActor
final class SnapshotRenderTests: XCTestCase {
    private var outputDir: URL!

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["EASYSCREEN_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set EASYSCREEN_SNAPSHOT_DIR to render UI snapshots")
        }
        outputDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    }

    func testRenderSelectionOverlay() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let size = screen.frame.size
        let scale = screen.backingScaleFactor
        let desktop = FakeDesktop.render(size: size, scale: scale)
        let snapshot = DisplaySnapshot(screen: screen, displayID: screen.displayID ?? 0, image: desktop)

        // One fake window so hover highlighting has something to find.
        let windowFrame = CGRect(x: screen.cgFrame.minX + size.width * 0.55, y: screen.cgFrame.minY + size.height * 0.2,
                                 width: size.width * 0.35, height: size.height * 0.5)
        let controller = SelectionOverlayController()

        // State 1: hovering a window (no drag yet).
        do {
            let (window, view) = makeOverlay(snapshot: snapshot,
                                             windows: [OnScreenWindow(frame: windowFrame, ownerName: "Fake")],
                                             controller: controller)
            let hover = CGPoint(x: windowFrame.midX - screen.cgFrame.minX, y: windowFrame.midY - screen.cgFrame.minY)
            view.updateMouse(global: NSPoint(x: screen.frame.minX + hover.x, y: screen.frame.maxY - hover.y))
            try saveLayerTree(view, name: "overlay-hover-window")
            window.close()
        }

        // State 2: dragging out a region.
        do {
            let (window, view) = makeOverlay(snapshot: snapshot, windows: [], controller: controller)
            let start = CGPoint(x: size.width * 0.15, y: size.height * 0.3)
            let end = CGPoint(x: size.width * 0.45, y: size.height * 0.62)
            view.mouseDown(with: mouseEvent(.leftMouseDown, at: start, in: window))
            view.mouseDragged(with: mouseEvent(.leftMouseDragged, at: end, in: window))
            try saveLayerTree(view, name: "overlay-dragging")
            window.close()
        }
    }

    func testRenderEditor() throws {
        let image = FakeDesktop.render(size: CGSize(width: 900, height: 560), scale: 2)
        let suite = "EasyScreenSnapshots-\(UUID().uuidString)"
        let controller = EditorWindowController(capture: CapturedImage(image: image, scale: 2, date: Date()), savedURL: nil)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let model = controller.model

        model.color = NSColor(hexString: "#FF3B30FF")!
        model.lineWidth = 5
        model.add(model.makeAnnotation(.ellipse(CGRect(x: 60, y: 70, width: 220, height: 120))))
        model.add(model.makeAnnotation(.rectangle(CGRect(x: 360, y: 60, width: 260, height: 160))))
        model.color = NSColor(hexString: "#007AFFFF")!
        model.add(model.makeAnnotation(.arrow(from: CGPoint(x: 700, y: 420), to: CGPoint(x: 520, y: 260))))
        model.color = NSColor(hexString: "#FF3B30FF")!
        model.add(model.makeAnnotation(.text(Annotation.TextBox(
            origin: CGPoint(x: 70, y: 260), string: "Label with background", fontSize: 24,
            hasBackground: true, backgroundColor: .white))))
        model.color = .white
        let plain = model.makeAnnotation(.text(Annotation.TextBox(
            origin: CGPoint(x: 70, y: 340), string: "Plain text, no background", fontSize: 24,
            hasBackground: false, backgroundColor: .white)))
        model.add(plain)
        model.tool = .select
        model.selectedID = model.annotations[1].id

        let window = try XCTUnwrap(controller.window)
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.contentView?.layoutSubtreeIfNeeded()
        try save(try XCTUnwrap(window.contentView), name: "editor")

        // The flattened export.
        let rendered = try XCTUnwrap(model.renderImage())
        let data = try XCTUnwrap(ImageOutput.data(for: rendered, scale: 2, format: .png))
        try data.write(to: outputDir.appendingPathComponent("editor-export.png"))

        // Text tool selected → toolbar shows text controls.
        model.selectedID = plain.id
        window.contentView?.layoutSubtreeIfNeeded()
        try save(try XCTUnwrap(window.contentView), name: "editor-text-selected")
        model.exportedChangeCount = model.changeCount
        window.close()
    }

    func testRenderSettings() throws {
        let suite = "EasyScreenSnapshots-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        prefs.saveToFolder = true

        let hosting = NSHostingView(rootView: SettingsView(prefs: prefs, hotkeys: .shared).frame(height: 1100))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 1100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        try save(hosting, name: "settings")
        window.close()
    }

    // MARK: Helpers

    private func makeOverlay(snapshot: DisplaySnapshot, windows: [OnScreenWindow],
                             controller: SelectionOverlayController) -> (NSWindow, OverlayView) {
        let size = snapshot.screen.frame.size
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = OverlayView(snapshot: snapshot, windows: windows, controller: controller)
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        return (window, view)
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, in window: NSWindow) -> NSEvent {
        // `point` is in the flipped view's coordinates; windows are bottom-up.
        let location = NSPoint(x: point.x, y: window.frame.height - point.y)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: 1)!
    }

    /// Renders the Core Animation tree (needed for layer-only content).
    private func saveLayerTree(_ view: NSView, name: String) throws {
        // Core Animation only builds the tree for windows that are ordered in;
        // park the window far off-screen so nothing flashes for the user.
        if let window = view.window {
            window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
            window.orderFrontRegardless()
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let layer = try XCTUnwrap(view.layer)
        let scale: CGFloat = 2
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                              | CGBitmapInfo.byteOrder32Little.rawValue))
        // The tree is geometry-flipped; mirror it into this y-up context.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        layer.render(in: ctx)
        let image = try XCTUnwrap(ctx.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: outputDir.appendingPathComponent("\(name).png"))
    }

    private func save(_ view: NSView, name: String) throws {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try data.write(to: outputDir.appendingPathComponent("\(name).png"))
    }
}

/// A stand-in "desktop" so snapshots have something to look at.
enum FakeDesktop {
    static func render(size: CGSize, scale: CGFloat) -> CGImage {
        let width = Int(size.width * scale), height = Int(size.height * scale)
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        NSGradient(colors: [NSColor(srgbRed: 0.16, green: 0.35, blue: 0.62, alpha: 1),
                            NSColor(srgbRed: 0.55, green: 0.32, blue: 0.62, alpha: 1)])!
            .draw(in: CGRect(origin: .zero, size: size), angle: 35)

        func fakeWindow(_ rect: CGRect, title: String) {
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            NSColor(white: 0.93, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(x: rect.minX, y: rect.maxY - 28, width: rect.width, height: 28)).fill()
            for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: rect.minX + 10 + CGFloat(i) * 18, y: rect.maxY - 20, width: 12, height: 12)).fill()
            }
            (title as NSString).draw(at: CGPoint(x: rect.minX + 70, y: rect.maxY - 22),
                                     withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
            for line in 0..<8 {
                let y = rect.maxY - 60 - CGFloat(line) * 24
                guard y > rect.minY + 10 else { break }
                NSColor(white: 0.82, alpha: 1).setFill()
                NSBezierPath(roundedRect: CGRect(x: rect.minX + 20, y: y, width: rect.width * (line % 3 == 0 ? 0.5 : 0.8), height: 10),
                             xRadius: 5, yRadius: 5).fill()
            }
        }
        fakeWindow(CGRect(x: size.width * 0.05, y: size.height * 0.2, width: size.width * 0.45, height: size.height * 0.6),
                   title: "Notes")
        fakeWindow(CGRect(x: size.width * 0.55, y: size.height * 0.3, width: size.width * 0.35, height: size.height * 0.5),
                   title: "Fake")
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
