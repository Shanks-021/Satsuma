import AppKit
import Carbon

/// Detects file drags anywhere on screen and opens a wheel when a modifier is tapped.
///
/// Needs no Accessibility permission: global *mouse* monitors are allowed, and
/// modifier state is polled with `NSEvent.modifierFlags`. A drag of files is
/// recognised when the system drag pasteboard changes after mouse-down.
@MainActor
final class DragMonitor {
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var monitors: [Any] = []
    private var timer: Timer?
    private var countAtMouseDown = 0
    private var isFileDrag = false
    private var lastFlags: NSEvent.ModifierFlags = []

    func start() {
        countAtMouseDown = dragPasteboard.changeCount
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.mouseDown() }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor in self?.ensurePolling() }
        }
        // Drags that start in our own windows (the Float shelf).
        let localDown = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.mouseDown()
            return event
        }
        monitors = [down, dragged, localDown].compactMap { $0 }
    }

    private func mouseDown() {
        countAtMouseDown = dragPasteboard.changeCount
        isFileDrag = false
        lastFlags = currentFlags
        ensurePolling()
    }

    private func ensurePolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private var currentFlags: NSEvent.ModifierFlags {
        NSEvent.modifierFlags.intersection(Settings.relevantFlags)
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return mouseUp() }

        if !isFileDrag {
            guard dragPasteboard.changeCount != countAtMouseDown, !draggedFiles().isEmpty else { return }
            isFileDrag = true
            lastFlags = currentFlags
        }

        let flags = currentFlags
        guard flags != lastFlags else { return }
        lastFlags = flags
        // Tapping (pressing) a wheel's modifier opens it; releasing keeps it open.
        guard !flags.isEmpty, let kind = Settings.kind(for: flags) else { return }
        let wheel = WheelController.shared
        if wheel.isVisible && wheel.kind == kind { return }
        // Switching wheels keeps the same spot; a new wheel opens under the cursor.
        let point = wheel.isVisible ? wheel.center : NSEvent.mouseLocation
        wheel.show(kind, urls: draggedFiles(), at: point, mode: .drag)
    }

    private func mouseUp() {
        timer?.invalidate()
        timer = nil
        if isFileDrag && WheelController.shared.isVisible && WheelController.shared.mode == .drag {
            // The drop (if it landed on the wheel) is delivered around now; hide shortly after.
            WheelController.shared.hide(after: 0.4)
        }
        isFileDrag = false
        countAtMouseDown = dragPasteboard.changeCount
    }

    private func draggedFiles() -> [URL] {
        dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

// MARK: - Settings

enum Settings {
    static let relevantFlags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]

    static let defaults: [WheelKind: NSEvent.ModifierFlags] = [
        .convert: .shift, .tools: .command, .actions: .control,
    ]

    static let choices: [(String, NSEvent.ModifierFlags)] = [
        ("⇧ Shift", .shift), ("⌃ Control", .control), ("⌥ Option", .option), ("⌘ Command", .command),
        ("⇧⌥ Shift-Option", [.shift, .option]), ("Off", []),
    ]

    static func mask(for kind: WheelKind) -> NSEvent.ModifierFlags {
        let key = "mask.\(kind.rawValue)"
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaults[kind]! }
        return NSEvent.ModifierFlags(rawValue: UInt(UserDefaults.standard.integer(forKey: key)))
    }

    static func setMask(_ mask: NSEvent.ModifierFlags, for kind: WheelKind) {
        UserDefaults.standard.set(Int(mask.rawValue), forKey: "mask.\(kind.rawValue)")
    }

    static func kind(for flags: NSEvent.ModifierFlags) -> WheelKind? {
        WheelKind.allCases.first { let m = mask(for: $0); return !m.isEmpty && m == flags }
    }

    static func symbols(_ mask: NSEvent.ModifierFlags) -> String {
        var s = ""
        if mask.contains(.control) { s += "⌃" }
        if mask.contains(.option) { s += "⌥" }
        if mask.contains(.shift) { s += "⇧" }
        if mask.contains(.command) { s += "⌘" }
        return s.isEmpty ? "off" : s
    }

    static var haptics: Bool {
        get { UserDefaults.standard.object(forKey: "haptics") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "haptics") }
    }
}

// MARK: - Global hotkey (Carbon hotkeys need no special permission)

enum HotKey {
    nonisolated(unsafe) static var handler: (() -> Void)?
    nonisolated(unsafe) private static var ref: EventHotKeyRef?

    /// ⌃⌥Space by default.
    static func register(keyCode: Int = kVK_Space, modifiers: Int = controlKey | optionKey) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x5354_534D), id: 1) // 'STSM'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &ref)
    }
}

/// Reads the current Finder selection (asks for Automation permission the first time).
enum FinderSelection {
    static func urls() -> [URL] {
        let source = """
        tell application "Finder"
            set out to ""
            repeat with f in (get selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            NSLog("[Satsuma] Finder selection failed: \(error)")
            return []
        }
        return (result?.stringValue ?? "")
            .split(separator: "\n")
            .map { URL(fileURLWithPath: String($0)) }
    }
}
