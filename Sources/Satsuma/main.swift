import PDFKit
import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DragMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Satsuma")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        monitor.start()
        HotKey.handler = { [weak self] in self?.openWheelForFinderSelection() }
        HotKey.register()

        if !UserDefaults.standard.bool(forKey: "didWelcome") {
            UserDefaults.standard.set(true, forKey: "didWelcome")
            showHelp()
        }
    }

    // Rebuilt each time so check marks reflect current settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hint = WheelKind.allCases.map { "\(Settings.symbols(Settings.mask(for: $0))) \($0.title)" }.joined(separator: "  ·  ")
        let header = NSMenuItem(title: "Drag files, then tap:  \(hint)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let finder = NSMenuItem(title: "Open Wheel for Finder Selection  (⌃⌥Space)", action: #selector(openWheelForFinderSelection), keyEquivalent: "")
        finder.target = self
        menu.addItem(finder)
        let shelf = NSMenuItem(title: "Show Float Shelf", action: #selector(showShelf), keyEquivalent: "")
        shelf.target = self
        menu.addItem(shelf)
        menu.addItem(.separator())

        let keys = NSMenuItem(title: "Wheel Keys", action: nil, keyEquivalent: "")
        let keysMenu = NSMenu()
        for kind in WheelKind.allCases {
            let item = NSMenuItem(title: "\(kind.title) Wheel", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, mask) in Settings.choices {
                let choice = NSMenuItem(title: title, action: #selector(setWheelKey(_:)), keyEquivalent: "")
                choice.target = self
                choice.representedObject = [kind.rawValue, Int(mask.rawValue)] as [Any]
                choice.state = Settings.mask(for: kind) == mask ? .on : .off
                sub.addItem(choice)
            }
            item.submenu = sub
            keysMenu.addItem(item)
        }
        keys.submenu = keysMenu
        menu.addItem(keys)

        let haptics = NSMenuItem(title: "Haptic Feedback", action: #selector(toggleHaptics), keyEquivalent: "")
        haptics.target = self
        haptics.state = Settings.haptics ? .on : .off
        menu.addItem(haptics)

        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        let tools = NSMenuItem(title: "ffmpeg: \(Tools.ffmpeg ?? "not found — video/audio disabled")", action: nil, keyEquivalent: "")
        tools.isEnabled = false
        menu.addItem(tools)

        menu.addItem(.separator())
        let help = NSMenuItem(title: "How to Use…", action: #selector(showHelp), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(NSMenuItem(title: "Quit Satsuma", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func openWheelForFinderSelection() {
        let urls = FinderSelection.urls()
        guard !urls.isEmpty else {
            HUD.shared.showError("Select files in Finder first", outputs: [])
            return
        }
        WheelController.shared.show(.convert, urls: urls, at: NSEvent.mouseLocation, mode: .keyboard)
    }

    @objc private func showShelf() { FloatShelf.shared.show() }

    @objc private func setWheelKey(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [Any],
              let raw = info[0] as? String, let kind = WheelKind(rawValue: raw),
              let mask = info[1] as? Int else { return }
        Settings.setMask(NSEvent.ModifierFlags(rawValue: UInt(mask)), for: kind)
    }

    @objc private func toggleHaptics() { Settings.haptics.toggle() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            HUD.shared.showError("Login item: \(error.localizedDescription)", outputs: [])
        }
    }

    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Satsuma"
        let k = { Settings.symbols(Settings.mask(for: $0)) }
        alert.informativeText = """
        1. Start dragging one or more files (from Finder, the desktop, anywhere).
        2. While dragging, tap a key:
             \(k(.convert))  Convert — change the format
             \(k(.tools))  Tools — compress, resize, rotate, merge, zip…
             \(k(.actions))  Actions — AirDrop, Float, copy path, Terminal…
           You can let go of the key; the wheel stays open.
        3. Drop the file on an option. Drop in the middle to cancel.

        Results are saved next to the original file.
        Keyboard: select files in Finder and press ⌃⌥Space. Use arrows, Return, Tab, Esc.
        Everything runs locally on your Mac.
        """
        alert.runModal()
    }
}

// Test hook: Satsuma --run <convert:ext|tool:name> <files...>
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--run" {
    MainActor.assumeIsolated { TestRunner.run(Array(CommandLine.arguments.dropFirst(2))) }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

@MainActor
enum TestRunner {
    static let tools: [String: Tool] = [
        "compress": .compress, "half": .resizeHalf, "rotate": .rotate, "flip": .flip, "gray": .grayscale,
        "combine": .combinePDF, "720": .scale720, "mute": .mute, "frame": .firstFrame, "normalize": .normalize,
        "mono": .mono, "reverse": .reverse, "merge": .mergePDF, "split": .splitPDF, "rotatepdf": .rotatePDF,
        "zip": .zip, "extract": .unarchive,
    ]

    static func run(_ args: [String]) {
        if args[0] == "layout" {
            // layout <pdf>: dump the paragraphs found on page 1
            let doc = PDFDocument(url: URL(fileURLWithPath: args[1]))!
            let page = PageLayout(page: doc.page(at: 0)!, index: 0)
            for p in page.paragraphs.prefix(Int(args.count > 2 ? args[2] : "12") ?? 12) {
                let text = p.lines.first.map { $0.allChars.map(\.ch).joined() } ?? (p.image != nil ? "[image]" : "[rule]")
                print(String(format: "base=%.1f top=%.1f size=%.1f lines=%d", p.firstBaseline, p.top, p.size, p.lines.count),
                      p.lines.first.map { l in l.allChars.compactMap { $0.run }.map { "\($0.font.baseName)@\(String(format: "%.1f/%.1f", $0.size, $0.baseline))" }.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }.joined(separator: ",") } ?? "",
                      "|", text.prefix(40))
            }
            return
        }
        if args[0] == "fonts" {
            // fonts <pdf>: list each PDF font with the Word face chosen for it
            let doc = PDFDocument(url: URL(fileURLWithPath: args[1]))!
            var seen = Set<String>()
            for i in 0..<doc.pageCount {
                guard let ref = doc.page(at: i)?.pageRef else { continue }
                for r in PDFStyleScanner.scan(ref).runs where seen.insert(r.font.baseName).inserted {
                    print(r.font.baseName, "flags", r.font.flags, "bold", FontMapper.isBold(r.font), "italic", FontMapper.isItalic(r.font))
                }
            }
            return
        }
        if args[0].hasPrefix("wheel:") {
            // wheel:<kind>:<out.png>:<highlight> files...
            let parts = args[0].split(separator: ":").map(String.init)
            let files = args.dropFirst().map { URL(fileURLWithPath: $0) }
            let view = WheelView()
            view.configure(kind: WheelKind(rawValue: parts[1])!, options: Catalog.options(for: WheelKind(rawValue: parts[1])!, urls: files),
                           fileCount: files.count, keyboard: true)
            view.debugHighlight(Int(parts[3]))
            view.appearance = NSAppearance(named: .darkAqua)
            view.frame = CGRect(x: 0, y: 0, width: view.preferredSize, height: view.preferredSize)
            let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
            view.cacheDisplay(in: view.bounds, to: rep)
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: parts[2]))
            return
        }
        let spec = args[0].split(separator: ":").map(String.init)
        let files = args.dropFirst().map { URL(fileURLWithPath: $0) }
        let op: Operation = spec[0] == "convert" ? .convert(spec[1]) : .tool(tools[spec[1]]!)
        let batch = spec[0] == "tool" && ["zip", "merge", "combine"].contains(spec[1])
        for job in batch ? [files] : files.map({ [$0] }) {
            do { print("OK  ", try Converter.execute(op, job, commonCategory(of: job)).path) }
            catch { print("FAIL", job[0].lastPathComponent, error.localizedDescription) }
        }
    }
}
