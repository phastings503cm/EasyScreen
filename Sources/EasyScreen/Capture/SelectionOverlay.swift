import AppKit
import Carbon.HIToolbox

/// Drives the full-screen "screenshot mode" overlay across every display.
///
/// Each display is frozen (we show the snapshot taken just before), dimmed,
/// outlined with an accent border and labelled with a banner, so it is obvious
/// that a capture is in progress. The user drags out a region, clicks a window,
/// presses Return for the whole screen, or Esc to cancel.
@MainActor
final class SelectionOverlayController {
    private var windows: [OverlayWindow] = []
    private var views: [OverlayView] = []
    private var completion: ((CapturedImage?) -> Void)?
    private var mouseMonitor: Any?
    /// The app that was frontmost before screenshot mode started, so focus can
    /// be handed back when the editor isn't going to open.
    private(set) var previousApp: NSRunningApplication?
    private(set) var isActive = false

    func begin(snapshots: [DisplaySnapshot], windows onScreenWindows: [OnScreenWindow],
               completion: @escaping (CapturedImage?) -> Void) {
        self.completion = completion
        isActive = true
        previousApp = NSWorkspace.shared.frontmostApplication

        for snapshot in snapshots {
            let screen = snapshot.screen
            let window = OverlayWindow(screen: screen)
            let view = OverlayView(snapshot: snapshot, windows: onScreenWindows, controller: self)
            view.frame = NSRect(origin: .zero, size: screen.frame.size)
            window.contentView = view
            window.alphaValue = 0
            windows.append(window)
            views.append(view)
        }

        NSApp.activate(ignoringOtherApps: true)
        for window in windows {
            window.orderFrontRegardless()
        }
        updateMouseLocation()

        // The window under the cursor gets keyboard focus.
        let target = windowUnderMouse() ?? windows.first
        target?.makeKey()
        if let view = target?.contentView { target?.makeFirstResponder(view) }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            for window in windows { window.animator().alphaValue = 1 }
        }
        NSCursor.crosshair.set()

        // Tracks the cursor between displays so only one shows the loupe.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.updateMouseLocation()
            return event
        }
    }

    func updateMouseLocation() {
        let global = NSEvent.mouseLocation
        for view in views {
            view.updateMouse(global: global)
        }
        if let window = windowUnderMouse(), !window.isKeyWindow, !views.contains(where: { $0.isDragging }) {
            window.makeKey()
            if let view = window.contentView { window.makeFirstResponder(view) }
        }
    }

    private func windowUnderMouse() -> OverlayWindow? {
        let global = NSEvent.mouseLocation
        return windows.first { NSMouseInRect(global, $0.frame, false) }
    }

    func cancel() {
        finish(with: nil)
    }

    func finish(with result: CapturedImage?) {
        guard isActive else { return }
        isActive = false
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil

        for window in windows {
            window.orderOut(nil)
            window.contentView = nil
        }
        windows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()

        let completion = self.completion
        self.completion = nil
        completion?(result)
    }
}

// MARK: - Window

final class OverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - View

/// One display's overlay. The frozen screenshot and the dimming are
/// GPU-composited layers, so tracking the mouse on a 5K/6K display only
/// redraws the small loupe and labels, never the full frame.
final class OverlayView: NSView {
    private let snapshot: DisplaySnapshot
    private weak var controller: SelectionOverlayController?
    /// On-screen windows in this view's (flipped, top-left origin) coordinates.
    private let windowRects: [CGRect]
    private let showMagnifier = Preferences.shared.showMagnifier

    private let imageView = NSImageView()
    private let decorations: OverlayDecorationsView
    private let sizeLabel = PillLabelView()
    private let banner = OverlayBannerView()
    private let loupe: LoupeView

    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var moveAnchor: CGPoint?
    private var spaceHeld = false
    private(set) var isDragging = false

    init(snapshot: DisplaySnapshot, windows: [OnScreenWindow], controller: SelectionOverlayController) {
        self.snapshot = snapshot
        self.controller = controller
        let size = snapshot.screen.frame.size
        let bounds = CGRect(origin: .zero, size: size)
        let screenCG = snapshot.screen.cgFrame
        self.windowRects = windows.compactMap { window in
            let local = window.frame.offsetBy(dx: -screenCG.minX, dy: -screenCG.minY)
            let clipped = local.intersection(bounds)
            return clipped.isNull || clipped.width < 8 || clipped.height < 8 ? nil : clipped
        }
        self.decorations = OverlayDecorationsView(frame: bounds, scale: snapshot.screen.backingScaleFactor)
        self.loupe = LoupeView(snapshot: snapshot)
        super.init(frame: bounds)
        wantsLayer = true

        imageView.frame = bounds
        imageView.image = NSImage(cgImage: snapshot.image, size: size)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        imageView.autoresizingMask = [.width, .height]
        decorations.autoresizingMask = [.width, .height]

        for view in [imageView, decorations, sizeLabel, banner, loupe] as [NSView] {
            addSubview(view)
        }
        sizeLabel.isHidden = true
        loupe.isHidden = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// All mouse events go to this view, never to the decorative subviews.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self, userInfo: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    // MARK: State helpers

    func updateMouse(global: NSPoint) {
        let frame = snapshot.screen.frame
        let inside = NSMouseInRect(global, frame, false)
        let newMouse: CGPoint? = inside ? CGPoint(x: global.x - frame.minX, y: frame.maxY - global.y) : nil
        if newMouse != mouse || isDragging {
            mouse = newMouse
            refresh()
        }
        if inside { NSCursor.crosshair.set() }
    }

    private var selectionRect: CGRect? {
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return Self.rect(from: start, to: current, square: NSEvent.modifierFlags.contains(.shift),
                         fromCenter: NSEvent.modifierFlags.contains(.option))
            .intersection(bounds)
    }

    static func rect(from start: CGPoint, to end: CGPoint, square: Bool, fromCenter: Bool) -> CGRect {
        var dx = end.x - start.x
        var dy = end.y - start.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if fromCenter {
            return CGRect(x: start.x - abs(dx), y: start.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return CGRect(x: min(start.x, start.x + dx), y: min(start.y, start.y + dy), width: abs(dx), height: abs(dy))
    }

    private var hoveredWindowRect: CGRect? {
        guard !isDragging, let mouse else { return nil }
        return windowRects.first { $0.contains(mouse) }
    }

    private func point(for event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let p = point(for: event)
        dragStart = p
        dragCurrent = p
        isDragging = true
        mouse = p
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(for: event)
        if spaceHeld, let anchor = moveAnchor, let start = dragStart, let current = dragCurrent {
            // Space + drag moves the whole selection.
            var dx = p.x - anchor.x
            var dy = p.y - anchor.y
            let rect = CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                              width: abs(current.x - start.x), height: abs(current.y - start.y))
            dx = min(max(dx, -rect.minX), bounds.width - rect.maxX)
            dy = min(max(dy, -rect.minY), bounds.height - rect.maxY)
            dragStart = CGPoint(x: start.x + dx, y: start.y + dy)
            dragCurrent = CGPoint(x: current.x + dx, y: current.y + dy)
            moveAnchor = p
        } else {
            dragCurrent = p
        }
        mouse = p
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging, let start = dragStart else { return }
        let end = point(for: event)
        dragCurrent = end
        isDragging = false

        let isClick = hypot(end.x - start.x, end.y - start.y) < 4
        let rect: CGRect
        if isClick {
            // A plain click captures the window under the cursor, or the whole
            // screen when clicking the desktop.
            rect = windowRects.first { $0.contains(start) } ?? bounds
        } else {
            guard let selection = selectionRect, selection.width >= 2, selection.height >= 2 else {
                dragStart = nil
                dragCurrent = nil
                refresh()
                return
            }
            rect = selection
        }
        finish(rect: rect)
    }

    override func rightMouseDown(with event: NSEvent) {
        if isDragging {
            isDragging = false
            dragStart = nil
            dragCurrent = nil
            refresh()
        } else {
            controller?.cancel()
        }
    }

    private func finish(rect: CGRect) {
        let scale = snapshot.scale
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height))
        guard !pixelRect.isEmpty, let cropped = snapshot.image.cropping(to: pixelRect) else {
            controller?.cancel()
            return
        }
        controller?.finish(with: CapturedImage(image: cropped, scale: scale, date: Date()))
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            controller?.cancel()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let selection = selectionRect, selection.width >= 2, selection.height >= 2 {
                isDragging = false
                finish(rect: selection)
            } else {
                finish(rect: bounds)
            }
        case kVK_Space:
            if !event.isARepeat {
                spaceHeld = true
                moveAnchor = mouse ?? dragCurrent
            }
        default:
            super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if Int(event.keyCode) == kVK_Space {
            spaceHeld = false
            moveAnchor = nil
        }
    }

    override func flagsChanged(with event: NSEvent) {
        refresh()
    }

    // MARK: Presentation

    private func refresh() {
        let selection = selectionRect.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        let hovered = selection == nil ? hoveredWindowRect : nil
        decorations.update(selection: selection, hovered: hovered, crosshair: isDragging ? nil : mouse)

        // Size label (in output pixels), below the selection or above it.
        if let selection {
            let scale = snapshot.scale
            sizeLabel.text = "\(Int((selection.width * scale).rounded())) × \(Int((selection.height * scale).rounded()))"
            let size = sizeLabel.fittingSize
            var origin = CGPoint(x: selection.midX - size.width / 2, y: selection.maxY + 8)
            if origin.y + size.height > bounds.height - 4 { origin.y = selection.minY - 8 - size.height }
            origin.x = min(max(origin.x, 4), bounds.width - size.width - 4)
            origin.y = min(max(origin.y, 4), bounds.height - size.height - 4)
            sizeLabel.frame = CGRect(origin: origin, size: size)
            sizeLabel.isHidden = false
        } else {
            sizeLabel.isHidden = true
        }

        // Loupe follows the cursor, flipping away from screen edges.
        if showMagnifier, let mouse {
            let size = loupe.frame.size
            var origin = CGPoint(x: mouse.x + 24, y: mouse.y + 24)
            if origin.x + size.width > bounds.width - 4 { origin.x = mouse.x - 24 - size.width }
            if origin.y + size.height > bounds.height - 4 { origin.y = mouse.y - 24 - size.height }
            loupe.setFrameOrigin(origin)
            loupe.point = mouse
            loupe.isHidden = false
        } else {
            loupe.isHidden = true
        }

        // Banner sits below the menu bar and jumps to the bottom when the
        // cursor or selection gets close to it.
        let bannerSize = banner.frame.size
        let menuBarInset = max(snapshot.screen.frame.maxY - snapshot.screen.visibleFrame.maxY, 0)
        var bannerFrame = CGRect(x: (bounds.width - bannerSize.width) / 2, y: menuBarInset + 18,
                                 width: bannerSize.width, height: bannerSize.height)
        let avoid = bannerFrame.insetBy(dx: -40, dy: -40)
        let mouseNear = mouse.map { avoid.contains($0) } ?? false
        let selectionNear = selection.map { $0.intersects(avoid) } ?? false
        if mouseNear || selectionNear {
            bannerFrame.origin.y = bounds.height - bannerSize.height - 28
        }
        if banner.frame.origin != bannerFrame.origin {
            banner.setFrameOrigin(bannerFrame.origin)
        }
    }
}

// MARK: - Decorations (layers only)

/// Dimming, outlines, handles and crosshair as Core Animation layers so
/// updates are cheap regardless of display resolution.
final class OverlayDecorationsView: NSView {
    private let root = CALayer()
    private let dim = (0..<4).map { _ in CALayer() }
    private let hoverFill = CALayer()
    private let hoverOutline = CAShapeLayer()
    private let outlineDark = CAShapeLayer()
    private let outlineDashed = CAShapeLayer()
    private let handles = (0..<4).map { _ in CALayer() }
    private let crossDark = CAShapeLayer()
    private let crossLight = CAShapeLayer()
    private let screenBorder = CALayer()

    init(frame: NSRect, scale: CGFloat) {
        super.init(frame: frame)
        root.isGeometryFlipped = true
        layer = root
        wantsLayer = true

        let accent = NSColor.controlAccentColor
        let dimColor = NSColor.black.withAlphaComponent(0.42).cgColor
        for layer in dim {
            layer.backgroundColor = dimColor
        }
        hoverFill.backgroundColor = accent.withAlphaComponent(0.12).cgColor
        hoverOutline.strokeColor = accent.cgColor
        hoverOutline.lineWidth = 2
        outlineDark.strokeColor = NSColor.black.withAlphaComponent(0.6).cgColor
        outlineDark.lineWidth = 1
        outlineDashed.strokeColor = NSColor.white.cgColor
        outlineDashed.lineWidth = 1
        outlineDashed.lineDashPattern = [5, 4]
        crossDark.strokeColor = NSColor.black.withAlphaComponent(0.25).cgColor
        crossDark.lineWidth = 1
        crossLight.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        crossLight.lineWidth = 1
        crossLight.lineDashPattern = [4, 4]
        for shape in [hoverOutline, outlineDark, outlineDashed, crossDark, crossLight] {
            shape.fillColor = nil
            shape.contentsScale = scale
        }
        for handle in handles {
            handle.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
            handle.cornerRadius = 3.5
            handle.backgroundColor = NSColor.white.cgColor
            handle.borderColor = accent.cgColor
            handle.borderWidth = 1
            handle.contentsScale = scale
        }
        screenBorder.borderColor = accent.withAlphaComponent(0.85).cgColor
        screenBorder.borderWidth = 4

        for layer in dim + [hoverFill, hoverOutline, crossDark, crossLight, outlineDark, outlineDashed] + handles
            + [screenBorder] {
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "hidden": NSNull(),
                             "frame": NSNull(), "opacity": NSNull()]
            root.addSublayer(layer)
        }
        update(selection: nil, hovered: nil, crosshair: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(selection: CGRect?, hovered: CGRect?, crosshair: CGPoint?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let b = bounds
        screenBorder.frame = b

        // Four strips around the hole (or one full strip when there's no hole).
        if let hole = selection ?? hovered {
            dim[0].frame = CGRect(x: 0, y: 0, width: b.width, height: hole.minY)
            dim[1].frame = CGRect(x: 0, y: hole.maxY, width: b.width, height: b.height - hole.maxY)
            dim[2].frame = CGRect(x: 0, y: hole.minY, width: hole.minX, height: hole.height)
            dim[3].frame = CGRect(x: hole.maxX, y: hole.minY, width: b.width - hole.maxX, height: hole.height)
        } else {
            dim[0].frame = b
            for layer in dim.dropFirst() { layer.frame = .zero }
        }

        if let hovered {
            hoverFill.isHidden = false
            hoverOutline.isHidden = false
            hoverFill.frame = hovered
            hoverOutline.path = CGPath(rect: hovered.insetBy(dx: 1, dy: 1), transform: nil)
        } else {
            hoverFill.isHidden = true
            hoverOutline.isHidden = true
        }

        if let selection {
            outlineDark.isHidden = false
            outlineDashed.isHidden = false
            outlineDark.path = CGPath(rect: selection.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            outlineDashed.path = CGPath(rect: selection.insetBy(dx: 0.5, dy: 0.5), transform: nil)
            let corners = [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
                           CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)]
            for (handle, corner) in zip(handles, corners) {
                handle.isHidden = false
                handle.position = corner
            }
        } else {
            outlineDark.isHidden = true
            outlineDashed.isHidden = true
            for handle in handles { handle.isHidden = true }
        }

        if let p = crosshair {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: p.y + 0.5))
            path.addLine(to: CGPoint(x: b.width, y: p.y + 0.5))
            path.move(to: CGPoint(x: p.x + 0.5, y: 0))
            path.addLine(to: CGPoint(x: p.x + 0.5, y: b.height))
            crossDark.path = path
            crossLight.path = path
            crossDark.isHidden = false
            crossLight.isHidden = false
        } else {
            crossDark.isHidden = true
            crossLight.isHidden = true
        }
    }
}

// MARK: - Small drawn views

/// A rounded dark label ("1280 × 720").
final class PillLabelView: NSView {
    var text = "" {
        didSet { if text != oldValue { needsDisplay = true; invalidateIntrinsicContentSize() } }
    }
    var font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private let padH: CGFloat = 8, padV: CGFloat = 4

    private var attributes: [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: NSColor.white]
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var fittingSize: NSSize {
        let size = (text as NSString).size(withAttributes: attributes)
        return NSSize(width: ceil(size.width) + padH * 2, height: ceil(size.height) + padV * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        (text as NSString).draw(at: CGPoint(x: padH, y: padV), withAttributes: attributes)
    }
}

/// "Screenshot mode" banner so it's obvious a capture is in progress.
final class OverlayBannerView: NSView {
    private let title = "Screenshot mode"
    private let detail = "Drag to select  ·  Click a window  ·  ⏎ full screen  ·  Esc to cancel"
    private let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 15, weight: .bold), .foregroundColor: NSColor.white,
    ]
    private let detailAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(0.85),
    ]
    private let iconSize: CGFloat = 24
    private let padH: CGFloat = 18, padV: CGFloat = 11, gap: CGFloat = 12

    init() {
        super.init(frame: .zero)
        let titleSize = (title as NSString).size(withAttributes: titleAttrs)
        let detailSize = (detail as NSString).size(withAttributes: detailAttrs)
        let width = padH * 2 + iconSize + gap + ceil(max(titleSize.width, detailSize.width))
        let height = padV * 2 + ceil(titleSize.height) + 2 + ceil(detailSize.height)
        setFrameSize(NSSize(width: width, height: height))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.8).setFill()
        path.fill()
        accent.withAlphaComponent(0.9).setStroke()
        path.lineWidth = 1.5
        path.stroke()

        let iconRect = CGRect(x: padH, y: bounds.midY - iconSize / 2, width: iconSize, height: iconSize)
        if let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: iconSize, weight: .semibold)
                .applying(.init(paletteColors: [accent]))) {
            symbol.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let titleHeight = ceil((title as NSString).size(withAttributes: titleAttrs).height)
        let textX = iconRect.maxX + gap
        (title as NSString).draw(at: CGPoint(x: textX, y: padV), withAttributes: titleAttrs)
        (detail as NSString).draw(at: CGPoint(x: textX, y: padV + titleHeight + 2), withAttributes: detailAttrs)
    }
}

/// Magnified view of the pixels under the cursor, with pixel coordinates.
final class LoupeView: NSView {
    private let snapshot: DisplaySnapshot
    private let diameter: CGFloat = 128
    private let labelHeight: CGFloat = 26
    var point: CGPoint = .zero {
        didSet { if point != oldValue { needsDisplay = true } }
    }

    init(snapshot: DisplaySnapshot) {
        self.snapshot = snapshot
        super.init(frame: NSRect(x: 0, y: 0, width: 128 + 8, height: 128 + 26 + 4))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = snapshot.scale
        let loupe = CGRect(x: 4, y: 2, width: diameter, height: diameter)
        let samplePixels = (16 * scale).rounded() // 16 points around the cursor
        let sample = CGRect(x: (point.x * scale).rounded(.down) - samplePixels / 2,
                            y: (point.y * scale).rounded(.down) - samplePixels / 2,
                            width: samplePixels, height: samplePixels)
        let imageBounds = CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height)
        let available = sample.intersection(imageBounds)

        ctx.saveGState()
        NSBezierPath(ovalIn: loupe).addClip()
        NSColor.black.setFill()
        loupe.fill()
        if !available.isEmpty, let crop = snapshot.image.cropping(to: available) {
            let zoom = diameter / samplePixels
            let dest = CGRect(x: loupe.minX + (available.minX - sample.minX) * zoom,
                              y: loupe.minY + (available.minY - sample.minY) * zoom,
                              width: available.width * zoom, height: available.height * zoom)
            ctx.interpolationQuality = .none
            // CGContext draws images bottom-up; flip locally.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: dest.minY + dest.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(crop, in: dest)
            ctx.restoreGState()

            // Outline the pixel under the cursor.
            let center = CGRect(x: loupe.midX - zoom / 2, y: loupe.midY - zoom / 2, width: zoom, height: zoom)
            let marker = NSBezierPath(rect: center)
            marker.lineWidth = 1.5
            NSColor.controlAccentColor.setStroke()
            marker.stroke()
        }
        ctx.restoreGState()

        let ring = NSBezierPath(ovalIn: loupe)
        ring.lineWidth = 3
        NSColor.white.setStroke()
        ring.stroke()
        let outer = NSBezierPath(ovalIn: loupe.insetBy(dx: -1.5, dy: -1.5))
        outer.lineWidth = 1
        NSColor.black.withAlphaComponent(0.4).setStroke()
        outer.stroke()

        let coords = "\(Int((point.x * scale).rounded())), \(Int((point.y * scale).rounded()))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white,
        ]
        let size = (coords as NSString).size(withAttributes: attrs)
        let pill = CGRect(x: loupe.midX - size.width / 2 - 7, y: loupe.maxY + 4, width: size.width + 14, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (coords as NSString).draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + 3), withAttributes: attrs)
    }
}
