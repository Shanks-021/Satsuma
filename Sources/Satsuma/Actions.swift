import AppKit

@MainActor
enum Actions {
    static func perform(_ action: Action, urls: [URL]) {
        switch action {
        case .airdrop:
            NSApp.activate(ignoringOtherApps: true)
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
        case .float:
            FloatShelf.shared.add(urls)
        case .copy:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
            HUD.shared.showDone("Copied \(urls.count) item\(urls.count == 1 ? "" : "s")", outputs: [])
        case .copyPath:
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
            HUD.shared.showDone("Path copied", outputs: [])
        case .terminal:
            var isDir: ObjCBool = false
            let first = urls[0]
            let dir = FileManager.default.fileExists(atPath: first.path, isDirectory: &isDir) && isDir.boolValue
                ? first : first.deletingLastPathComponent()
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
            }
        case .moveTo, .copyTo:
            transfer(urls, move: action == .moveTo)
        case .trash:
            NSWorkspace.shared.recycle(urls) { _, error in
                if let error { HUD.shared.showError(error.localizedDescription, outputs: []) }
                else { HUD.shared.showDone("Moved to Trash", outputs: []) }
            }
        }
    }

    private static func transfer(_ urls: [URL], move: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = move ? "Move Here" : "Copy Here"
        panel.message = "\(move ? "Move" : "Copy") \(urls.count) item\(urls.count == 1 ? "" : "s") to…"
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        var outputs: [URL] = [], errors: [String] = []
        for url in urls {
            let target = Output.unique(dest.appendingPathComponent(url.lastPathComponent))
            do {
                if move { try FileManager.default.moveItem(at: url, to: target) }
                else { try FileManager.default.copyItem(at: url, to: target) }
                outputs.append(target)
            } catch { errors.append(error.localizedDescription) }
        }
        if errors.isEmpty { HUD.shared.showDone("\(move ? "Moved" : "Copied") \(outputs.count) item\(outputs.count == 1 ? "" : "s")", outputs: outputs) }
        else { HUD.shared.showError(errors.joined(separator: "\n"), outputs: outputs) }
    }
}

// MARK: - HUD

/// A small floating status card at the bottom of the screen.
@MainActor
final class HUD {
    static let shared = HUD()

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private var hideWork: DispatchWorkItem?
    private var outputs: [URL] = []

    private init() {
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 340, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        spinner.style = .spinning
        spinner.controlSize = .small
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 3
        icon.symbolConfiguration = .init(pointSize: 18, weight: .semibold)

        let stack = NSStackView(views: [spinner, icon, label])
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: blur.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(reveal))
        blur.addGestureRecognizer(click)
    }

    func showProgress(_ text: String) {
        show(text, symbol: nil, spinning: true, duration: nil)
    }

    func showDone(_ text: String, outputs: [URL]) {
        self.outputs = outputs
        let hint = outputs.isEmpty ? "" : "  (click to show)"
        show(text + hint, symbol: "checkmark.circle.fill", color: .systemGreen, spinning: false, duration: 2.5)
    }

    func showError(_ text: String, outputs: [URL]) {
        self.outputs = outputs
        show(text, symbol: "exclamationmark.triangle.fill", color: .systemOrange, spinning: false, duration: 6)
    }

    private func show(_ text: String, symbol: String?, color: NSColor = .labelColor, spinning: Bool, duration: Double?) {
        hideWork?.cancel()
        label.stringValue = text
        spinner.isHidden = !spinning
        spinning ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        icon.isHidden = symbol == nil
        if let symbol { icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        icon.contentTintColor = color

        let lines = min(3, text.components(separatedBy: "\n").count)
        let width = min(520, max(260, label.intrinsicContentSize.width + 70))
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(CGRect(x: screen.midX - width / 2, y: screen.minY + 80,
                              width: width, height: CGFloat(40 + lines * 16)), display: true)
        panel.orderFrontRegardless()

        if let duration {
            let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
        }
    }

    @objc private func reveal() {
        if !outputs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        panel.orderOut(nil)
    }
}

// MARK: - Float shelf

/// A floating shelf that holds files so you can drag them somewhere later.
@MainActor
final class FloatShelf: NSObject, NSWindowDelegate {
    static let shared = FloatShelf()

    private var panel: NSPanel?
    private var stack = NSStackView()
    private(set) var items: [URL] = []

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) { items.append(url) }
        rebuild()
        show()
    }

    func show() {
        if panel == nil { makePanel() }
        panel?.orderFrontRegardless()
    }

    private func makePanel() {
        let p = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 220, height: 260),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.title = "Float"
        p.level = .floating
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        p.isReleasedWhenClosed = false

        let drop = ShelfDropView()
        drop.onDrop = { [weak self] urls in self?.add(urls) }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let flipped = FlippedView()
        flipped.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        flipped.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = flipped
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])

        let clear = NSButton(title: "Clear", target: self, action: #selector(clear))
        clear.bezelStyle = .rounded
        clear.controlSize = .small
        let all = ShelfItemView(urls: { [weak self] in self?.items ?? [] }, title: "Drag all", symbol: "square.stack.3d.up")

        let footer = NSStackView(views: [all, NSView(), clear])
        footer.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 6, right: 8)

        let root = NSStackView(views: [scroll, footer])
        root.orientation = .vertical
        root.spacing = 0
        drop.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: drop.topAnchor),
            root.bottomAnchor.constraint(equalTo: drop.bottomAnchor),
            root.leadingAnchor.constraint(equalTo: drop.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
            footer.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        p.contentView = drop

        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(CGPoint(x: screen.maxX - 240, y: screen.maxY - 300))
        }
        panel = p
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for url in items {
            stack.addArrangedSubview(ShelfItemView(urls: { [url] }, title: url.lastPathComponent, fileIcon: url))
        }
        panel?.title = "Float — \(items.count)"
    }

    @objc private func clear() {
        items.removeAll()
        rebuild()
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        items.removeAll()
        rebuild()
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class ShelfDropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Ignore drags that started from the shelf itself.
        sender.draggingSource is ShelfItemView ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        onDrop?(urls)
        return !urls.isEmpty
    }
}

/// One shelf row; drag it to carry its file(s) elsewhere, double-click to open.
private final class ShelfItemView: NSView, NSDraggingSource {
    private let urls: () -> [URL]

    init(urls: @escaping () -> [URL], title: String, fileIcon: URL? = nil, symbol: String? = nil) {
        self.urls = urls
        super.init(frame: .zero)
        let image = NSImageView()
        if let fileIcon { image.image = NSWorkspace.shared.icon(forFile: fileIcon.path) }
        else if let symbol { image.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 24).isActive = true
        image.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let label = NSTextField(labelWithString: title)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [image, label])
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
        ])
        toolTip = fileIcon == nil ? "Drag to carry all files" : "Drag to carry the file; double-click to open"
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { urls().forEach { NSWorkspace.shared.open($0) } }
    }

    override func mouseDragged(with event: NSEvent) {
        let files = urls()
        guard !files.isEmpty else { return }
        let items = files.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: url.path))
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : [.copy, .generic]
    }

    // Let modifier keys reach the wheel monitor instead of changing the drag operation.
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
