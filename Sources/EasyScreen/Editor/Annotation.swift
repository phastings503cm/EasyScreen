import AppKit

enum EditorTool: String, CaseIterable, Identifiable {
    case select, rectangle, ellipse, arrow, text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "Select"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Circle"
        case .arrow: return "Arrow"
        case .text: return "Text"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: return "v"
        case .rectangle: return "r"
        case .ellipse: return "o"
        case .arrow: return "a"
        case .text: return "t"
        }
    }
}

/// A single mark drawn on top of the screenshot. Geometry is in image points
/// (pixels ÷ scale), with the origin at the top-left.
struct Annotation: Identifiable, Equatable {
    struct TextBox: Equatable {
        /// Top-left of the text box (including background padding).
        var origin: CGPoint
        var string: String
        var fontSize: CGFloat
        var hasBackground: Bool
        var backgroundColor: NSColor
    }

    enum Kind: Equatable {
        case rectangle(CGRect)
        case ellipse(CGRect)
        case arrow(from: CGPoint, to: CGPoint)
        case text(TextBox)
    }

    let id: UUID
    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat

    init(id: UUID = UUID(), kind: Kind, color: NSColor, lineWidth: CGFloat) {
        self.id = id
        self.kind = kind
        self.color = color
        self.lineWidth = lineWidth
    }

    var isText: Bool {
        if case .text = kind { return true }
        return false
    }

    var textBox: TextBox? {
        if case .text(let box) = kind { return box }
        return nil
    }

    /// Bounding box used for selection outlines and hit testing.
    var bounds: CGRect {
        switch kind {
        case .rectangle(let r), .ellipse(let r):
            return r.standardized.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case .arrow(let a, let b):
            let head = AnnotationRenderer.arrowHeadLength(lineWidth: lineWidth)
            return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
                .insetBy(dx: -head / 2, dy: -head / 2)
        case .text(let box):
            return AnnotationRenderer.textFrame(for: box)
        }
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Annotation {
        var copy = self
        switch kind {
        case .rectangle(let r): copy.kind = .rectangle(r.offsetBy(dx: dx, dy: dy))
        case .ellipse(let r): copy.kind = .ellipse(r.offsetBy(dx: dx, dy: dy))
        case .arrow(let a, let b):
            copy.kind = .arrow(from: CGPoint(x: a.x + dx, y: a.y + dy), to: CGPoint(x: b.x + dx, y: b.y + dy))
        case .text(var box):
            box.origin = CGPoint(x: box.origin.x + dx, y: box.origin.y + dy)
            copy.kind = .text(box)
        }
        return copy
    }

    // MARK: Hit testing

    /// - Parameters:
    ///   - tolerance: grab distance in image points.
    ///   - includeInterior: when true, clicking inside a rectangle / circle hits it.
    func hitTest(_ p: CGPoint, tolerance: CGFloat, includeInterior: Bool) -> Bool {
        let reach = tolerance + lineWidth / 2
        switch kind {
        case .rectangle(let raw):
            let r = raw.standardized
            if includeInterior, r.insetBy(dx: -reach, dy: -reach).contains(p) { return true }
            let outer = r.insetBy(dx: -reach, dy: -reach)
            let inner = r.insetBy(dx: reach, dy: reach)
            return outer.contains(p) && (inner.isEmpty || !inner.contains(p))
        case .ellipse(let raw):
            let r = raw.standardized
            let rx = max(r.width / 2, 0.5), ry = max(r.height / 2, 0.5)
            let nx = (p.x - r.midX) / rx, ny = (p.y - r.midY) / ry
            let d = sqrt(nx * nx + ny * ny)
            if includeInterior, d <= 1 { return true }
            return abs(d - 1) * min(rx, ry) <= reach
        case .arrow(let a, let b):
            return Geometry.distance(from: p, toSegment: a, b) <= reach + 2
        case .text(let box):
            return AnnotationRenderer.textFrame(for: box).insetBy(dx: -tolerance / 2, dy: -tolerance / 2).contains(p)
        }
    }
}

enum Geometry {
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func rect(from a: CGPoint, to b: CGPoint, square: Bool) -> CGRect {
        var dx = b.x - a.x, dy = b.y - a.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        return CGRect(x: min(a.x, a.x + dx), y: min(a.y, a.y + dy), width: abs(dx), height: abs(dy))
    }

    /// Snaps the direction from `a` to `b` to the nearest 45°.
    static func snap45(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: a.x + cos(angle) * length, y: a.y + sin(angle) * length)
    }
}

/// Draws annotations into the current (flipped) `NSGraphicsContext`. Used both
/// by the on-screen canvas and when rendering the final image.
enum AnnotationRenderer {
    static func font(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .bold)
    }

    static func textPadding(fontSize: CGFloat) -> CGSize {
        CGSize(width: (fontSize * 0.4).rounded(), height: (fontSize * 0.2).rounded())
    }

    static func cornerRadius(fontSize: CGFloat) -> CGFloat {
        (fontSize * 0.3).rounded()
    }

    static func arrowHeadLength(lineWidth: CGFloat) -> CGFloat {
        max(lineWidth * 3.6, 14)
    }

    static func textAttributes(fontSize: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font(size: fontSize), .foregroundColor: color]
    }

    /// Size of the text itself (without padding). Empty strings still get one
    /// line's height so the caret has somewhere to live.
    static func textSize(for box: Annotation.TextBox) -> CGSize {
        let measured = box.string.isEmpty ? "W" : box.string
        // A trailing newline doesn't count towards the bounding rect; pad it.
        let string = measured.hasSuffix("\n") ? measured + " " : measured
        let attributed = NSAttributedString(string: string, attributes: textAttributes(fontSize: box.fontSize, color: .black))
        let rect = attributed.boundingRect(with: CGSize(width: 100_000, height: 100_000),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        let width = box.string.isEmpty ? box.fontSize * 0.5 : ceil(rect.width)
        return CGSize(width: width, height: ceil(rect.height))
    }

    static func textFrame(for box: Annotation.TextBox) -> CGRect {
        let size = textSize(for: box)
        let pad = textPadding(fontSize: box.fontSize)
        return CGRect(x: box.origin.x, y: box.origin.y,
                      width: size.width + pad.width * 2, height: size.height + pad.height * 2)
    }

    static func shapeShadow() -> NSShadow {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        return shadow
    }

    static func draw(_ annotation: Annotation) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        switch annotation.kind {
        case .rectangle(let raw):
            shapeShadow().set()
            let r = raw.standardized
            let path = NSBezierPath(roundedRect: r, xRadius: min(annotation.lineWidth, r.width / 2),
                                    yRadius: min(annotation.lineWidth, r.height / 2))
            path.lineWidth = annotation.lineWidth
            path.lineJoinStyle = .round
            annotation.color.setStroke()
            path.stroke()

        case .ellipse(let raw):
            shapeShadow().set()
            let path = NSBezierPath(ovalIn: raw.standardized)
            path.lineWidth = annotation.lineWidth
            annotation.color.setStroke()
            path.stroke()

        case .arrow(let a, let b):
            shapeShadow().set()
            drawArrow(from: a, to: b, lineWidth: annotation.lineWidth, color: annotation.color)

        case .text(let box):
            drawText(box, color: annotation.color)
        }
    }

    static func drawArrow(from a: CGPoint, to b: CGPoint, lineWidth: CGFloat, color: NSColor) {
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length > 0.5 else { return }
        let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
        let headLength = min(arrowHeadLength(lineWidth: lineWidth), length)
        let headHalfWidth = headLength * 0.45
        let base = CGPoint(x: b.x - ux * headLength, y: b.y - uy * headLength)

        let path = NSBezierPath()
        path.move(to: a)
        // Stop the shaft inside the head so the round cap doesn't poke out.
        path.line(to: CGPoint(x: base.x + ux * headLength * 0.3, y: base.y + uy * headLength * 0.3))
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.setStroke()

        let head = NSBezierPath()
        head.move(to: b)
        head.line(to: CGPoint(x: base.x - uy * headHalfWidth, y: base.y + ux * headHalfWidth))
        head.line(to: CGPoint(x: base.x + uy * headHalfWidth, y: base.y - ux * headHalfWidth))
        head.close()
        head.lineJoinStyle = .round
        head.lineWidth = max(1, lineWidth * 0.5)
        color.setFill()

        // One transparency layer so the shadow is cast once for shaft + head.
        if let ctx = NSGraphicsContext.current?.cgContext {
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            path.stroke()
            head.fill()
            head.stroke()
            ctx.endTransparencyLayer()
        } else {
            path.stroke()
            head.fill()
        }
    }

    static func drawText(_ box: Annotation.TextBox, color: NSColor) {
        let frame = textFrame(for: box)
        let pad = textPadding(fontSize: box.fontSize)

        let textRect = frame.insetBy(dx: pad.width, dy: pad.height)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

        if box.hasBackground {
            NSGraphicsContext.saveGraphicsState()
            shapeShadow().set()
            let radius = cornerRadius(fontSize: box.fontSize)
            box.backgroundColor.setFill()
            NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius).fill()
            NSGraphicsContext.restoreGraphicsState()
        } else {
            // Without a label, a contrasting outline keeps text legible on
            // any background. Stroke first, then fill on top, so only the
            // outer half of the stroke shows.
            var outline = textAttributes(fontSize: box.fontSize, color: color)
            outline[.strokeColor] = outlineColor(for: color)
            outline[.strokeWidth] = 16 // percent of the font size
            NSAttributedString(string: box.string, attributes: outline).draw(with: textRect, options: options)
        }

        let attributed = NSAttributedString(string: box.string,
                                            attributes: textAttributes(fontSize: box.fontSize, color: color))
        attributed.draw(with: textRect, options: options)
    }

    static func outlineColor(for color: NSColor) -> NSColor {
        color.perceivedBrightness > 0.6
            ? NSColor(white: 0.08, alpha: 0.9)
            : NSColor(white: 1, alpha: 0.95)
    }
}

extension NSColor {
    /// Rough perceived brightness (0…1) used to pick contrasting decorations.
    var perceivedBrightness: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}
