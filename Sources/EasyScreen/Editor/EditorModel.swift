import AppKit
import Combine

/// State for one editor window: the screenshot, its annotations, the current
/// tool / style, and undo history.
final class EditorModel: ObservableObject {
    let image: CGImage
    let scale: CGFloat
    let captureDate: Date
    /// The file this screenshot lives in (auto-saved or saved from the editor).
    @Published var fileURL: URL?

    /// Canvas size in points (image pixels ÷ scale).
    var canvasSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }

    @Published private(set) var annotations: [Annotation] = []
    @Published var selectedID: UUID? {
        didSet { if selectedID != oldValue { syncStyleFromSelection() } }
    }
    @Published var tool: EditorTool = .rectangle {
        didSet { if tool != oldValue && tool != .select { selectedID = nil } }
    }

    // Style: changing any of these also restyles the selected annotation.
    @Published var color: NSColor { didSet { styleChanged(.color) } }
    @Published var lineWidth: CGFloat { didSet { styleChanged(.lineWidth) } }
    @Published var fontSize: CGFloat { didSet { styleChanged(.fontSize) } }
    @Published var textBackground: Bool { didSet { styleChanged(.textBackground) } }
    @Published var textBackgroundColor: NSColor {
        didSet { styleChanged(.textBackgroundColor) }
    }

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Incremented on every edit; compared against `exportedChangeCount` to
    /// know whether the latest annotations were copied or saved somewhere.
    @Published private(set) var changeCount = 0
    var exportedChangeCount = 0
    var hasUnexportedChanges: Bool { !annotations.isEmpty && changeCount != exportedChangeCount }

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var isSyncingStyle = false
    private var coalesceKey: String?
    private var coalesceDate = Date.distantPast
    private let preferences: Preferences

    init(capture: CapturedImage, preferences: Preferences = .shared) {
        self.image = capture.image
        self.scale = capture.scale
        self.captureDate = capture.date
        self.preferences = preferences
        self.color = preferences.editorColor
        self.lineWidth = CGFloat(preferences.editorLineWidth)
        self.fontSize = CGFloat(preferences.editorFontSize)
        self.textBackground = preferences.editorTextBackground
        self.textBackgroundColor = preferences.editorTextBackgroundColor
    }

    var selected: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    /// Which style controls are relevant right now.
    var showsTextControls: Bool {
        if let selected { return selected.isText }
        return tool == .text
    }

    // MARK: Mutation

    /// Records the given state as an undo step (call with the state *before*
    /// a change once the change is known to be real).
    func pushUndo(_ previous: [Annotation]) {
        guard previous != annotations else { return }
        undoStack.append(previous)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        coalesceKey = nil
        changeCount += 1
        updateUndoFlags()
    }

    /// Changes annotations without recording undo (used during drags; the
    /// caller records one undo step when the gesture ends).
    func setAnnotationsWithoutUndo(_ new: [Annotation]) {
        annotations = new
    }

    func add(_ annotation: Annotation, recordUndo: Bool = true) {
        let before = annotations
        annotations.append(annotation)
        if recordUndo { pushUndo(before) }
    }

    func update(_ id: UUID, recordUndo: Bool = false, _ mutate: (inout Annotation) -> Void) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        let before = annotations
        var copy = annotations[index]
        mutate(&copy)
        guard copy != annotations[index] else { return }
        annotations[index] = copy
        if recordUndo { pushUndo(before) }
    }

    func remove(_ id: UUID, recordUndo: Bool = true) {
        let before = annotations
        annotations.removeAll { $0.id == id }
        if selectedID == id { selectedID = nil }
        if recordUndo { pushUndo(before) }
    }

    func deleteSelected() {
        guard let selectedID else { return }
        remove(selectedID)
    }

    func bringToFront(_ id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }), index != annotations.count - 1 else { return }
        var copy = annotations
        let item = copy.remove(at: index)
        copy.append(item)
        annotations = copy
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        afterHistoryJump()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        afterHistoryJump()
    }

    private func afterHistoryJump() {
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
        coalesceKey = nil
        changeCount += 1
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    // MARK: Style

    private enum StyleProperty: String {
        case color, lineWidth, fontSize, textBackground, textBackgroundColor
    }

    private func styleChanged(_ property: StyleProperty) {
        guard !isSyncingStyle else { return }
        persistStyle()
        guard let selected else { return }

        var updated = selected
        switch property {
        case .color:
            updated.color = color
        case .lineWidth:
            guard !selected.isText else { return }
            updated.lineWidth = lineWidth
        case .fontSize, .textBackground, .textBackgroundColor:
            guard var box = selected.textBox else { return }
            box.fontSize = fontSize
            box.hasBackground = textBackground
            box.backgroundColor = textBackgroundColor
            updated.kind = .text(box)
        }
        guard updated != selected, let index = annotations.firstIndex(where: { $0.id == selected.id }) else { return }

        // Slider drags produce many changes; fold them into one undo step.
        let before = annotations
        annotations[index] = updated
        let now = Date()
        let key = "\(property.rawValue)-\(selected.id)"
        let coalescing = coalesceKey == key && now.timeIntervalSince(coalesceDate) < 1.5
        if !coalescing {
            pushUndo(before)
            coalesceKey = key
        } else {
            changeCount += 1
        }
        coalesceDate = now
    }

    private func persistStyle() {
        preferences.editorColor = color
        preferences.editorLineWidth = Double(lineWidth)
        preferences.editorFontSize = Double(fontSize)
        preferences.editorTextBackground = textBackground
        preferences.editorTextBackgroundColor = textBackgroundColor
    }

    /// Mirrors the selected annotation's style in the toolbar.
    private func syncStyleFromSelection() {
        guard let selected else { return }
        isSyncingStyle = true
        defer { isSyncingStyle = false }
        color = selected.color
        if let box = selected.textBox {
            fontSize = box.fontSize
            textBackground = box.hasBackground
            textBackgroundColor = box.backgroundColor
        } else {
            lineWidth = selected.lineWidth
        }
    }

    /// Builds a new annotation using the current style.
    func makeAnnotation(_ kind: Annotation.Kind) -> Annotation {
        Annotation(kind: kind, color: color, lineWidth: lineWidth)
    }

    func makeTextBox(at origin: CGPoint) -> Annotation.TextBox {
        Annotation.TextBox(origin: origin, string: "", fontSize: fontSize, hasBackground: textBackground,
                           backgroundColor: textBackgroundColor)
    }

    // MARK: Rendering

    /// Flattens the screenshot and annotations into a full-resolution image.
    func renderImage() -> CGImage? {
        guard !annotations.isEmpty else { return image }
        let width = image.width, height = image.height
        let bitmapInfo = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let preferredSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: preferredSpace ?? srgb, bitmapInfo: bitmapInfo)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: srgb, bitmapInfo: bitmapInfo)
        else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Switch to flipped, point-based coordinates to match the canvas.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: scale, y: -scale)
        let nsContext = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        for annotation in annotations {
            AnnotationRenderer.draw(annotation)
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
