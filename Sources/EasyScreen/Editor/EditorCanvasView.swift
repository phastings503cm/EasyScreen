import AppKit
import Carbon.HIToolbox
import Combine

/// The drawing surface: shows the screenshot and lets the user draw, select,
/// move, resize and type annotations. Coordinates are image points with a
/// top-left origin; the enclosing scroll view handles zoom.
final class EditorCanvasView: NSView, NSTextViewDelegate, NSMenuItemValidation {
    let model: EditorModel
    private let baseImage: NSImage
    private var cancellables = Set<AnyCancellable>()

    private enum Handle: Equatable {
        case corner(Int) // 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right
        case arrowStart
        case arrowEnd
    }

    private enum Gesture {
        case none
        case creating(id: UUID, start: CGPoint)
        case moving(id: UUID, last: CGPoint, editOnClick: Bool)
        case resizing(id: UUID, handle: Handle, original: Annotation)
    }

    private var gesture: Gesture = .none
    private var gestureStartAnnotations: [Annotation] = []

    // Inline text editing.
    private var textView: NSTextView?
    private var editingID: UUID?
    private var editStartAnnotations: [Annotation] = []
    private var appliedTextStyle: String?
    private var textUndoManager = UndoManager()
    /// The click that ended text editing shouldn't also start a new shape.
    private var swallowedMouseDownTimestamp: TimeInterval?

    var isEditingText: Bool { editingID != nil }

    init(model: EditorModel) {
        self.model = model
        self.baseImage = NSImage(cgImage: model.image, size: model.canvasSize)
        super.init(frame: CGRect(origin: .zero, size: model.canvasSize))

        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.needsDisplay = true
                self.syncTextViewWithModel()
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var magnification: CGFloat {
        max(enclosingScrollView?.magnification ?? 1, 0.01)
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: model.tool == .text ? .iBeam : (model.tool == .select ? .arrow : .crosshair))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = magnification >= 2 ? .none : .high
        baseImage.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        for annotation in model.annotations where annotation.id != editingID {
            AnnotationRenderer.draw(annotation)
        }

        if let editingID, let textView, model.annotations.contains(where: { $0.id == editingID }) {
            drawDashedOutline(textView.frame.insetBy(dx: -2 / magnification, dy: -2 / magnification))
        } else if let selected = model.selected {
            drawSelectionDecorations(for: selected)
        }
    }

    private func drawDashedOutline(_ rect: CGRect) {
        let unit = 1 / magnification
        let path = NSBezierPath(rect: rect)
        path.lineWidth = unit
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
        path.setLineDash([4 * unit, 3 * unit], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    private func drawSelectionDecorations(for annotation: Annotation) {
        switch annotation.kind {
        case .text, .ellipse:
            drawDashedOutline(annotation.bounds)
        default:
            break
        }
        let size = 9 / magnification
        for (_, point) in handles(for: annotation) {
            let rect = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = 1.5 / magnification
            NSColor.white.setFill()
            path.fill()
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    private func handles(for annotation: Annotation) -> [(Handle, CGPoint)] {
        switch annotation.kind {
        case .rectangle(let raw), .ellipse(let raw):
            let r = raw.standardized
            return [(.corner(0), CGPoint(x: r.minX, y: r.minY)), (.corner(1), CGPoint(x: r.maxX, y: r.minY)),
                    (.corner(2), CGPoint(x: r.minX, y: r.maxY)), (.corner(3), CGPoint(x: r.maxX, y: r.maxY))]
        case .arrow(let a, let b):
            return [(.arrowStart, a), (.arrowEnd, b)]
        case .text:
            return []
        }
    }

    private func handleHit(_ p: CGPoint) -> (Annotation, Handle)? {
        guard let selected = model.selected else { return nil }
        let reach = 8 / magnification
        for (handle, point) in handles(for: selected) where hypot(p.x - point.x, p.y - point.y) <= reach {
            return (selected, handle)
        }
        return nil
    }

    private func topmostHit(_ p: CGPoint, includeInterior: Bool) -> Annotation? {
        let tolerance = 5 / magnification
        return model.annotations.reversed().first { $0.hitTest(p, tolerance: tolerance, includeInterior: includeInterior) }
    }

    // MARK: Mouse

    private func point(for event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        if isEditingText {
            // Clicking outside the text box finishes editing.
            commitTextEditing()
            window?.makeFirstResponder(self)
            return
        }
        if let swallowed = swallowedMouseDownTimestamp, swallowed == event.timestamp {
            swallowedMouseDownTimestamp = nil
            return
        }
        window?.makeFirstResponder(self)

        let p = point(for: event)
        gestureStartAnnotations = model.annotations
        gesture = .none

        if let (annotation, handle) = handleHit(p) {
            gesture = .resizing(id: annotation.id, handle: handle, original: annotation)
            return
        }

        let hit = topmostHit(p, includeInterior: model.tool == .select)

        if event.clickCount >= 2, let hit, hit.isText {
            model.selectedID = hit.id
            beginEditing(hit.id)
            return
        }

        switch model.tool {
        case .select:
            if let hit {
                model.selectedID = hit.id
                gesture = .moving(id: hit.id, last: p, editOnClick: false)
            } else {
                model.selectedID = nil
            }

        case .text:
            if let hit {
                model.selectedID = hit.id
                gesture = .moving(id: hit.id, last: p, editOnClick: hit.isText)
            } else {
                beginNewText(at: p)
            }

        case .rectangle, .ellipse, .arrow:
            if let hit {
                model.selectedID = hit.id
                gesture = .moving(id: hit.id, last: p, editOnClick: false)
            } else {
                let kind: Annotation.Kind
                switch model.tool {
                case .rectangle: kind = .rectangle(CGRect(origin: p, size: .zero))
                case .ellipse: kind = .ellipse(CGRect(origin: p, size: .zero))
                default: kind = .arrow(from: p, to: p)
                }
                let annotation = model.makeAnnotation(kind)
                model.add(annotation, recordUndo: false)
                model.selectedID = annotation.id
                gesture = .creating(id: annotation.id, start: p)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = point(for: event)
        let shift = event.modifierFlags.contains(.shift)
        autoscroll(with: event)

        switch gesture {
        case .none:
            break

        case .creating(let id, let start):
            model.update(id) { annotation in
                switch annotation.kind {
                case .rectangle: annotation.kind = .rectangle(Geometry.rect(from: start, to: p, square: shift))
                case .ellipse: annotation.kind = .ellipse(Geometry.rect(from: start, to: p, square: shift))
                case .arrow: annotation.kind = .arrow(from: start, to: shift ? Geometry.snap45(from: start, to: p) : p)
                case .text: break
                }
            }

        case .moving(let id, let last, let editOnClick):
            model.update(id) { $0 = $0.offsetBy(dx: p.x - last.x, dy: p.y - last.y) }
            gesture = .moving(id: id, last: p, editOnClick: editOnClick)

        case .resizing(let id, let handle, let original):
            model.update(id) { annotation in
                switch (original.kind, handle) {
                case (.rectangle(let raw), .corner(let index)), (.ellipse(let raw), .corner(let index)):
                    let r = raw.standardized
                    let corners = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                   CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
                    let anchor = corners[3 - index]
                    let rect = Geometry.rect(from: anchor, to: p, square: shift)
                    if case .rectangle = original.kind {
                        annotation.kind = .rectangle(rect)
                    } else {
                        annotation.kind = .ellipse(rect)
                    }
                case (.arrow(_, let b), .arrowStart):
                    annotation.kind = .arrow(from: shift ? Geometry.snap45(from: b, to: p) : p, to: b)
                case (.arrow(let a, _), .arrowEnd):
                    annotation.kind = .arrow(from: a, to: shift ? Geometry.snap45(from: a, to: p) : p)
                default:
                    break
                }
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            gesture = .none
            window?.invalidateCursorRects(for: self)
        }
        switch gesture {
        case .none:
            break

        case .creating(let id, _):
            if let annotation = model.annotations.first(where: { $0.id == id }), isDegenerate(annotation) {
                model.remove(id, recordUndo: false)
            } else {
                model.pushUndo(gestureStartAnnotations)
            }

        case .moving(let id, _, let editOnClick):
            if model.annotations != gestureStartAnnotations {
                model.pushUndo(gestureStartAnnotations)
            } else if editOnClick {
                beginEditing(id)
            }

        case .resizing:
            model.pushUndo(gestureStartAnnotations)
        }
    }

    private func isDegenerate(_ annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .rectangle(let r), .ellipse(let r):
            return r.width < 3 && r.height < 3
        case .arrow(let a, let b):
            return hypot(b.x - a.x, b.y - a.y) < 4
        case .text(let box):
            return box.string.isEmpty
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.isEmpty, let char = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = EditorTool.allCases.first(where: { $0.shortcut == char }) {
            model.tool = tool
            window?.invalidateCursorRects(for: self)
            return
        }

        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch Int(event.keyCode) {
        case kVK_Delete, kVK_ForwardDelete:
            model.deleteSelected()
        case kVK_Escape:
            if model.selectedID != nil {
                model.selectedID = nil
            } else {
                window?.performClose(nil)
            }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if let selected = model.selected, selected.isText { beginEditing(selected.id) }
        case kVK_LeftArrow: nudge(dx: -step, dy: 0)
        case kVK_RightArrow: nudge(dx: step, dy: 0)
        case kVK_UpArrow: nudge(dx: 0, dy: -step)
        case kVK_DownArrow: nudge(dx: 0, dy: step)
        default:
            super.keyDown(with: event)
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        guard let id = model.selectedID else { return }
        let before = model.annotations
        model.update(id) { $0 = $0.offsetBy(dx: dx, dy: dy) }
        model.pushUndo(before)
    }

    // MARK: Menu actions (responder chain)

    @objc func delete(_ sender: Any?) {
        model.deleteSelected()
    }

    @objc func undo(_ sender: Any?) {
        if isEditingText {
            textUndoManager.undo()
        } else {
            model.undo()
        }
    }

    @objc func redo(_ sender: Any?) {
        if isEditingText {
            textUndoManager.redo()
        } else {
            model.redo()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            return isEditingText ? textUndoManager.canUndo : model.canUndo
        case #selector(redo(_:)):
            return isEditingText ? textUndoManager.canRedo : model.canRedo
        case #selector(delete(_:)):
            return model.selectedID != nil
        default:
            return true
        }
    }

    // MARK: Text editing

    private func beginNewText(at p: CGPoint) {
        let font = AnnotationRenderer.font(size: model.fontSize)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let pad = AnnotationRenderer.textPadding(fontSize: model.fontSize)
        let origin = CGPoint(x: p.x - pad.width, y: p.y - lineHeight / 2 - pad.height)
        let annotation = model.makeAnnotation(.text(model.makeTextBox(at: origin)))
        editStartAnnotations = model.annotations
        model.add(annotation, recordUndo: false)
        model.selectedID = annotation.id
        startTextView(for: annotation.id)
    }

    func beginEditing(_ id: UUID) {
        guard !isEditingText, model.annotations.first(where: { $0.id == id })?.isText == true else { return }
        editStartAnnotations = model.annotations
        model.selectedID = id
        startTextView(for: id)
    }

    private func startTextView(for id: UUID) {
        guard let annotation = model.annotations.first(where: { $0.id == id }), let box = annotation.textBox else { return }
        editingID = id
        appliedTextStyle = nil
        textUndoManager = UndoManager()

        let tv = NSTextView(frame: AnnotationRenderer.textFrame(for: box))
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.heightTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                 height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 0
        tv.focusRingType = .none
        tv.wantsLayer = true
        tv.layer?.masksToBounds = true
        tv.string = box.string
        tv.delegate = self
        addSubview(tv)
        textView = tv
        syncTextViewWithModel()
        window?.makeFirstResponder(tv)
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        needsDisplay = true
    }

    /// Keeps the live text view's style and size in step with the model (the
    /// toolbar can change font size / colors while typing).
    private func syncTextViewWithModel() {
        guard let editingID, let tv = textView else { return }
        guard let annotation = model.annotations.first(where: { $0.id == editingID }),
              let box = annotation.textBox
        else {
            // Annotation vanished (e.g. undo) – drop the editor.
            cancelTextEditing()
            return
        }

        let style = "\(annotation.color.hexString)|\(box.fontSize)|\(box.hasBackground)|\(box.backgroundColor.hexString)"
        if style != appliedTextStyle {
            appliedTextStyle = style
            let attributes = AnnotationRenderer.textAttributes(fontSize: box.fontSize, color: annotation.color)
            let pad = AnnotationRenderer.textPadding(fontSize: box.fontSize)
            tv.font = AnnotationRenderer.font(size: box.fontSize)
            tv.textColor = annotation.color
            tv.insertionPointColor = annotation.color
            tv.typingAttributes = attributes
            if let storage = tv.textStorage, storage.length > 0 {
                storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
            }
            tv.textContainerInset = NSSize(width: pad.width, height: pad.height)
            tv.drawsBackground = box.hasBackground
            tv.backgroundColor = box.hasBackground ? box.backgroundColor : .clear
            tv.layer?.cornerRadius = box.hasBackground ? AnnotationRenderer.cornerRadius(fontSize: box.fontSize) : 0
        }

        var frame = AnnotationRenderer.textFrame(for: box)
        frame.size.width += max(4, box.fontSize * 0.3) // room for the caret
        if tv.frame != frame {
            tv.frame = frame
            tv.minSize = frame.size
        }
    }

    func textDidChange(_ notification: Notification) {
        guard let editingID, let tv = textView else { return }
        let string = tv.string
        model.update(editingID) { annotation in
            guard var box = annotation.textBox else { return }
            box.string = string
            annotation.kind = .text(box)
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        if let event = NSApp.currentEvent, event.type == .leftMouseDown, event.window === window {
            swallowedMouseDownTimestamp = event.timestamp
        }
        commitTextEditing()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else {
                commitTextEditing()
                window?.makeFirstResponder(self)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            commitTextEditing()
            window?.makeFirstResponder(self)
            return true
        default:
            return false
        }
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        textUndoManager
    }

    /// Finishes editing: empty text boxes are removed, everything else becomes
    /// a single undo step.
    func commitTextEditing() {
        guard let id = editingID else { return }
        editingID = nil
        tearDownTextView()
        if let box = model.annotations.first(where: { $0.id == id })?.textBox,
           box.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            model.remove(id, recordUndo: false)
        }
        model.pushUndo(editStartAnnotations)
        editStartAnnotations = []
        needsDisplay = true
    }

    private func cancelTextEditing() {
        guard editingID != nil else { return }
        editingID = nil
        tearDownTextView()
        editStartAnnotations = []
        needsDisplay = true
    }

    private func tearDownTextView() {
        guard let tv = textView else { return }
        textView = nil
        tv.delegate = nil
        let wasFirstResponder = window?.firstResponder === tv
        tv.removeFromSuperview()
        if wasFirstResponder { window?.makeFirstResponder(self) }
    }
}
