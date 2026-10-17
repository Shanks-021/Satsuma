import AppKit

/// Shows the wheel panel and routes a chosen option to the converter.
@MainActor
final class WheelController: NSObject, NSWindowDelegate {
    static let shared = WheelController()

    enum Mode { case drag, keyboard }

    private let panel: WheelPanel
    private let view = WheelView()
    private(set) var kind: WheelKind = .convert
    private(set) var mode: Mode = .drag
    private var urls: [URL] = []
    private(set) var center: CGPoint = .zero
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { panel.isVisible }

    override init() {
        panel = WheelPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: true)
        super.init()
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.contentView = view
        panel.delegate = self

        view.onChoose = { [weak self] index, droppedURLs in self?.choose(index, droppedURLs: droppedURLs) }
        view.onCancel = { [weak self] in self?.hide() }
        view.onNextWheel = { [weak self] in
            guard let self else { return }
            self.show(self.kind.next, urls: self.urls, at: self.center, mode: self.mode)
        }
        view.switchHandler = { [weak self] kind in
            guard let self else { return }
            self.show(kind, urls: self.urls, at: self.center, mode: self.mode)
        }
    }

    func show(_ kind: WheelKind, urls: [URL], at point: CGPoint, mode: Mode) {
        hideWork?.cancel()
        self.kind = kind
        self.urls = urls
        self.mode = mode
        self.center = point

        let options = Catalog.options(for: kind, urls: urls)
        view.configure(kind: kind, options: options, fileCount: urls.count, keyboard: mode == .keyboard)

        let size = view.preferredSize
        var frame = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
        // Stay on the screen the cursor is on.
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })?.frame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - size)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - size)
        }
        panel.setFrame(frame, display: true)

        if mode == .keyboard {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func hide(after delay: Double = 0) {
        hideWork?.cancel()
        guard delay > 0 else { panel.orderOut(nil); return }
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func choose(_ index: Int, droppedURLs: [URL]?) {
        let files = (droppedURLs?.isEmpty == false ? droppedURLs! : urls)
        let options = Catalog.options(for: kind, urls: files)
        hide()
        guard options.indices.contains(index) else { return }
        Converter.perform(options[index], on: files)
    }

    func windowDidResignKey(_ notification: Notification) {
        if mode == .keyboard { hide() }
    }
}

final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Draws the radial menu and acts as the drop target.
final class WheelView: NSView {
    var onChoose: ((Int, [URL]?) -> Void)?
    var onCancel: (() -> Void)?
    var onNextWheel: (() -> Void)?

    private var kind: WheelKind = .convert
    private var options: [WheelOption] = []
    private var fileCount = 0
    private var keyboard = false
    private var highlighted: Int? { didSet { if highlighted != oldValue { highlightChanged() } } }

    private let innerRadius: CGFloat = 62
    private var outerRadius: CGFloat = 170
    var preferredSize: CGFloat { (outerRadius + 14) * 2 }

    static let accent = NSColor(srgbRed: 1.0, green: 0.55, blue: 0.10, alpha: 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(kind: WheelKind, options: [WheelOption], fileCount: Int, keyboard: Bool) {
        self.kind = kind
        self.options = options
        self.fileCount = fileCount
        self.keyboard = keyboard
        // Grow the ring so labels don't collide.
        outerRadius = options.count > 8 ? 190 : 170
        highlighted = keyboard && !options.isEmpty ? 0 : nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    // MARK: Geometry

    private var centerPoint: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }
    private var step: CGFloat { options.isEmpty ? 360 : 360 / CGFloat(options.count) }

    /// Segment 0 sits at 12 o'clock; the rest follow clockwise.
    private func segmentAngles(_ i: Int) -> (start: CGFloat, end: CGFloat) {
        let mid = 90 - CGFloat(i) * step
        return (mid - step / 2, mid + step / 2)
    }

    private func index(at point: CGPoint) -> Int? {
        let dx = point.x - centerPoint.x, dy = point.y - centerPoint.y
        let dist = hypot(dx, dy)
        guard !options.isEmpty, dist > innerRadius, dist < outerRadius + 40 else { return nil }
        var angle = atan2(dy, dx) * 180 / .pi
        angle = (90 - angle + step / 2).truncatingRemainder(dividingBy: 360)
        if angle < 0 { angle += 360 }
        return min(options.count - 1, Int(angle / step))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let c = centerPoint
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let ringColor = dark ? NSColor(white: 0.13, alpha: 0.94) : NSColor(white: 0.98, alpha: 0.96)
        let lineColor = dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.08)
        let textColor = dark ? NSColor.white : NSColor.black

        // Ring with soft shadow.
        let ring = NSBezierPath(ovalIn: CGRect(x: c.x - outerRadius, y: c.y - outerRadius, width: outerRadius * 2, height: outerRadius * 2))
        ring.append(NSBezierPath(ovalIn: CGRect(x: c.x - innerRadius, y: c.y - innerRadius, width: innerRadius * 2, height: innerRadius * 2)))
        ring.windingRule = .evenOdd
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 12
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -3)
        shadow.set()
        ringColor.setFill()
        ring.fill()
        // Solid center disc so the label stays readable over any background.
        let hub = innerRadius - 6
        NSBezierPath(ovalIn: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2)).fill()
        NSGraphicsContext.restoreGraphicsState()

        for (i, option) in options.enumerated() {
            let (start, end) = segmentAngles(i)
            if i == highlighted {
                let seg = NSBezierPath()
                seg.appendArc(withCenter: c, radius: outerRadius - 4, startAngle: start + 1, endAngle: end - 1)
                seg.appendArc(withCenter: c, radius: innerRadius + 4, startAngle: end - 1, endAngle: start + 1, clockwise: true)
                seg.close()
                Self.accent.setFill()
                seg.fill()
            }
            if options.count > 1 {
                let a = start * .pi / 180
                let line = NSBezierPath()
                line.move(to: CGPoint(x: c.x + cos(a) * innerRadius, y: c.y + sin(a) * innerRadius))
                line.line(to: CGPoint(x: c.x + cos(a) * outerRadius, y: c.y + sin(a) * outerRadius))
                lineColor.setStroke()
                line.lineWidth = 1
                line.stroke()
            }

            // Icon and label at the middle of the segment.
            let mid = (start + end) / 2 * .pi / 180
            let r = (innerRadius + outerRadius) / 2 + 4
            let p = CGPoint(x: c.x + cos(mid) * r, y: c.y + sin(mid) * r)
            let color = i == highlighted ? NSColor.white : textColor
            if let img = NSImage(systemSymbolName: option.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .medium).applying(.init(paletteColors: [color]))) {
                let s = img.size
                img.draw(in: CGRect(x: p.x - s.width / 2, y: p.y + 2, width: s.width, height: s.height))
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: color,
            ]
            let text = NSAttributedString(string: option.title, attributes: attrs)
            let ts = text.size()
            text.draw(at: CGPoint(x: p.x - ts.width / 2, y: p.y - ts.height - 2))
        }

        drawCenter(textColor: textColor)
    }

    private func drawCenter(textColor: NSColor) {
        let c = centerPoint
        let cancelling = highlighted == nil && !keyboard
        let title = options.isEmpty ? "Nothing here" : (cancelling ? "Cancel" : kind.title)
        let sub: String
        if keyboard { sub = "Tab · switch" }
        else { sub = "\(fileCount) file\(fileCount == 1 ? "" : "s")" }

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: cancelling || options.isEmpty ? textColor.withAlphaComponent(0.6) : Self.accent,
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: textColor.withAlphaComponent(0.55),
        ]
        let t = NSAttributedString(string: title, attributes: titleAttrs)
        let s = NSAttributedString(string: sub, attributes: subAttrs)
        t.draw(at: CGPoint(x: c.x - t.size().width / 2, y: c.y))
        s.draw(at: CGPoint(x: c.x - s.size().width / 2, y: c.y - s.size().height - 2))
    }

    private func highlightChanged() {
        needsDisplay = true
        if highlighted != nil && Settings.haptics {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    // MARK: Drag & drop

    private func local(_ sender: NSDraggingInfo) -> CGPoint { convert(sender.draggingLocation, from: nil) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = index(at: local(sender))
        return highlighted == nil ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = index(at: local(sender)) else { onCancel?(); return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
        onChoose?(i, urls)
        return true
    }

    // MARK: Mouse & keyboard (used when opened with the hotkey)

    override func mouseMoved(with event: NSEvent) {
        guard keyboard else { return }
        if let i = index(at: convert(event.locationInWindow, from: nil)) { highlighted = i }
    }

    override func mouseDown(with event: NSEvent) {
        if let i = index(at: convert(event.locationInWindow, from: nil)) { onChoose?(i, nil) } else { onCancel?() }
    }

    override func keyDown(with event: NSEvent) {
        let count = options.count
        switch Int(event.keyCode) {
        case 53: onCancel?()                                        // Esc
        case 48: onNextWheel?()                                     // Tab
        case 36, 76: if let h = highlighted { onChoose?(h, nil) }   // Return / Enter
        case 124, 125:                                              // → ↓ clockwise
            if count > 0 { highlighted = ((highlighted ?? -1) + 1) % count }
        case 123, 126:                                              // ← ↑ counter-clockwise
            if count > 0 { highlighted = ((highlighted ?? 0) - 1 + count) % count }
        default:
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // In keyboard mode, the wheel modifiers switch wheels too.
        let flags = event.modifierFlags.intersection(Settings.relevantFlags)
        if !flags.isEmpty, let k = Settings.kind(for: flags), k != kind {
            switchHandler?(k)
        }
    }

    var switchHandler: ((WheelKind) -> Void)?

    func debugHighlight(_ i: Int?) { highlighted = i }
}
