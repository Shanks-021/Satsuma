import AppKit
import CoreGraphics

/// One text-showing operation from a page's content stream (Tj/TJ/'/").
struct TextRun {
    let font: PDFFontInfo
    let size: CGFloat        // effective size in page points
    let color: String?       // "RRGGBB", nil for black
    let x0: CGFloat
    let x1: CGFloat
    let baseline: CGFloat
}

/// A thin horizontal line drawn on the page (section underline, divider).
struct HRule { let rect: CGRect; let color: String? }

/// A small filled shape (drawn list bullet).
struct Dot { let rect: CGRect }

/// A light filled rectangle behind text (code block, callout).
struct Shade { let rect: CGRect; let color: String }

/// Where an image is painted on the page.
struct ImagePlacement { let rect: CGRect }

final class PDFFontInfo {
    let baseName: String     // without the "ABCDEF+" subset prefix
    let flags: Int
    private let isType0: Bool
    private let firstChar: Int
    private let widths: [CGFloat]
    private let missingWidth: CGFloat
    private let cidWidths: [Int: CGFloat]
    private let defaultCIDWidth: CGFloat
    private let widthScale: CGFloat   // 1/1000 for normal fonts, FontMatrix for Type3

    var twoByte: Bool { isType0 }

    init(dict: CGPDFDictionaryRef) {
        var name = PDFRead.name(dict, "BaseFont") ?? "Unknown"
        if let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 {
            name = String(name[name.index(after: plus)...])
        }
        baseName = name
        let subtype = PDFRead.name(dict, "Subtype") ?? ""
        isType0 = subtype == "Type0"

        var descriptor: CGPDFDictionaryRef?
        var cid: [Int: CGFloat] = [:]
        var dw: CGFloat = 1000
        if isType0, let desc = PDFRead.array(dict, "DescendantFonts"), let d0 = PDFRead.dict(at: 0, desc) {
            dw = PDFRead.number(d0, "DW") ?? 1000
            descriptor = PDFRead.dict(d0, "FontDescriptor")
            if let w = PDFRead.array(d0, "W") { cid = PDFFontInfo.parseW(w) }
        } else {
            descriptor = PDFRead.dict(dict, "FontDescriptor")
        }
        cidWidths = cid
        defaultCIDWidth = dw
        firstChar = Int(PDFRead.number(dict, "FirstChar") ?? 0)
        widths = PDFRead.array(dict, "Widths").map(PDFRead.numbers) ?? []
        flags = Int(descriptor.flatMap { PDFRead.number($0, "Flags") } ?? 0)
        missingWidth = descriptor.flatMap { PDFRead.number($0, "MissingWidth") } ?? 500
        if subtype == "Type3", let m = PDFRead.array(dict, "FontMatrix").map(PDFRead.numbers), let a = m.first {
            widthScale = a
        } else {
            widthScale = 0.001
        }
    }

    /// Glyph advance in text space units (multiply by font size).
    func width(_ code: Int) -> CGFloat {
        if isType0 { return (cidWidths[code] ?? defaultCIDWidth) * widthScale }
        let i = code - firstChar
        let w = (i >= 0 && i < widths.count) ? widths[i] : missingWidth
        return w * widthScale
    }

    private static func parseW(_ arr: CGPDFArrayRef) -> [Int: CGFloat] {
        var out: [Int: CGFloat] = [:]
        let n = CGPDFArrayGetCount(arr)
        var i = 0
        while i < n {
            guard let first = PDFRead.number(at: i, arr) else { break }
            if let list = PDFRead.array(at: i + 1, arr) {
                for (k, w) in PDFRead.numbers(list).enumerated() { out[Int(first) + k] = w }
                i += 2
            } else if let last = PDFRead.number(at: i + 1, arr), let w = PDFRead.number(at: i + 2, arr) {
                if last >= first && last - first < 70000 {
                    for c in Int(first)...Int(last) { out[c] = w }
                }
                i += 3
            } else { break }
        }
        return out
    }
}

/// Small helpers over the CGPDF dictionary/array C API.
enum PDFRead {
    static func name(_ d: CGPDFDictionaryRef, _ key: String) -> String? {
        var p: UnsafePointer<CChar>?
        return CGPDFDictionaryGetName(d, key, &p) ? p.map { String(cString: $0) } : nil
    }
    static func number(_ d: CGPDFDictionaryRef, _ key: String) -> CGFloat? {
        var v: CGPDFReal = 0
        return CGPDFDictionaryGetNumber(d, key, &v) ? v : nil
    }
    static func dict(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFDictionaryRef? {
        var r: CGPDFDictionaryRef?
        return CGPDFDictionaryGetDictionary(d, key, &r) ? r : nil
    }
    static func array(_ d: CGPDFDictionaryRef, _ key: String) -> CGPDFArrayRef? {
        var r: CGPDFArrayRef?
        return CGPDFDictionaryGetArray(d, key, &r) ? r : nil
    }
    static func number(at i: Int, _ a: CGPDFArrayRef) -> CGFloat? {
        var v: CGPDFReal = 0
        return CGPDFArrayGetNumber(a, i, &v) ? v : nil
    }
    static func array(at i: Int, _ a: CGPDFArrayRef) -> CGPDFArrayRef? {
        var r: CGPDFArrayRef?
        return CGPDFArrayGetArray(a, i, &r) ? r : nil
    }
    static func dict(at i: Int, _ a: CGPDFArrayRef) -> CGPDFDictionaryRef? {
        var r: CGPDFDictionaryRef?
        return CGPDFArrayGetDictionary(a, i, &r) ? r : nil
    }
    static func numbers(_ a: CGPDFArrayRef) -> [CGFloat] {
        (0..<CGPDFArrayGetCount(a)).map { number(at: $0, a) ?? 0 }
    }
}

/// Walks a page's content stream and records text runs (with real font, size and
/// color), thin horizontal rules, and image placements.
final class PDFStyleScanner {
    private(set) var runs: [TextRun] = []
    private(set) var rules: [HRule] = []
    private(set) var images: [ImagePlacement] = []
    private(set) var dots: [Dot] = []
    private(set) var shades: [Shade] = []

    private struct GState {
        var ctm = CGAffineTransform.identity
        var fill: String? = nil
        var fillRGB: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        var stroke: String? = nil
        var lineWidth: CGFloat = 1
    }
    private var gs = GState()
    private var stack: [GState] = []

    private var tm = CGAffineTransform.identity
    private var tlm = CGAffineTransform.identity
    private var font: PDFFontInfo?
    private var fontSize: CGFloat = 0
    private var tc: CGFloat = 0, tw: CGFloat = 0, th: CGFloat = 1, tl: CGFloat = 0, rise: CGFloat = 0

    private var fontCache: [Int: PDFFontInfo] = [:]
    private var streams: [CGPDFContentStreamRef] = []
    private var depth = 0

    private var pathRects: [CGRect] = []
    private var pathSegments: [(CGPoint, CGPoint)] = []
    private var current: CGPoint = .zero
    private var subpathStart: CGPoint = .zero
    private var pathBox: CGRect = .null
    private var hasCurves = false

    static func scan(_ page: CGPDFPage) -> PDFStyleScanner {
        let s = PDFStyleScanner()
        let cs = CGPDFContentStreamCreateWithPage(page)
        s.run(cs)
        return s
    }

    private func run(_ cs: CGPDFContentStreamRef) {
        streams.append(cs)
        let info = Unmanaged.passUnretained(self).toOpaque()
        let scanner = CGPDFScannerCreate(cs, PDFStyleScanner.table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        streams.removeLast()
    }

    // MARK: Operand helpers

    private static func me(_ info: UnsafeMutableRawPointer?) -> PDFStyleScanner {
        Unmanaged<PDFStyleScanner>.fromOpaque(info!).takeUnretainedValue()
    }
    private static func num(_ s: CGPDFScannerRef) -> CGFloat? {
        var v: CGPDFReal = 0
        return CGPDFScannerPopNumber(s, &v) ? v : nil
    }
    private static func nums(_ s: CGPDFScannerRef, _ n: Int) -> [CGFloat]? {
        var out = [CGFloat](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            guard let v = num(s) else { return nil }
            out[i] = v
        }
        return out
    }
    private static func allNums(_ s: CGPDFScannerRef) -> [CGFloat] {
        var out: [CGFloat] = []
        while let v = num(s) { out.insert(v, at: 0) }
        return out
    }
    private static func name(_ s: CGPDFScannerRef) -> String? {
        var p: UnsafePointer<CChar>?
        return CGPDFScannerPopName(s, &p) ? p.map { String(cString: $0) } : nil
    }

    // MARK: State changes

    private func setFont(_ resName: String, _ size: CGFloat) {
        fontSize = size
        guard let cs = streams.last, let obj = CGPDFContentStreamGetResource(cs, "Font", resName) else { font = nil; return }
        var d: CGPDFDictionaryRef?
        guard CGPDFObjectGetValue(obj, .dictionary, &d), let dict = d else { font = nil; return }
        let key = Int(bitPattern: UnsafeRawPointer(dict))
        if let f = fontCache[key] { font = f; return }
        let f = PDFFontInfo(dict: dict)
        fontCache[key] = f
        font = f
    }

    private func setFill(_ comps: [CGFloat]) {
        if let (hex, rgb) = PDFStyleScanner.color(comps) { gs.fill = hex; gs.fillRGB = rgb }
    }

    private func setStroke(_ comps: [CGFloat]) {
        if let (hex, _) = PDFStyleScanner.color(comps) { gs.stroke = hex }
    }

    /// Color components (gray, RGB or CMYK) → ("RRGGBB" or nil for near-black, sRGB triple).
    private static func color(_ comps: [CGFloat]) -> (String?, (CGFloat, CGFloat, CGFloat))? {
        var rgb: (CGFloat, CGFloat, CGFloat)
        switch comps.count {
        case 1: rgb = (comps[0], comps[0], comps[0])
        case 3: rgb = (comps[0], comps[1], comps[2])
        case 4:
            var cmyk = comps.map { min(max($0, 0), 1) } + [1]
            guard let c = NSColor(colorSpace: .genericCMYK, components: &cmyk, count: 5).usingColorSpace(.sRGB) else { return nil }
            rgb = (c.redComponent, c.greenComponent, c.blueComponent)
        default: return nil
        }
        rgb = (min(max(rgb.0, 0), 1), min(max(rgb.1, 0), 1), min(max(rgb.2, 0), 1))
        let R = Int((rgb.0 * 255).rounded()), G = Int((rgb.1 * 255).rounded()), B = Int((rgb.2 * 255).rounded())
        let hex = (R < 40 && G < 40 && B < 40) ? nil : String(format: "%02X%02X%02X", R, G, B)
        return (hex, rgb)
    }

    private func textOrigin() -> CGPoint { CGPoint(x: 0, y: rise).applying(tm.concatenating(gs.ctm)) }

    private func effectiveSize() -> CGFloat {
        let m = tm.concatenating(gs.ctm)
        return abs(fontSize) * hypot(m.c, m.d)
    }

    private func advance(_ string: CGPDFStringRef) {
        guard let font, let bytes = CGPDFStringGetBytePtr(string) else { return }
        let len = CGPDFStringGetLength(string)
        var i = 0
        var tx: CGFloat = 0
        while i < len {
            var code = Int(bytes[i])
            var isSpace = false
            if font.twoByte && i + 1 < len {
                code = code << 8 | Int(bytes[i + 1])
                i += 2
            } else {
                isSpace = code == 32
                i += 1
            }
            tx += (font.width(code) * fontSize + tc + (isSpace ? tw : 0)) * th
        }
        tm = CGAffineTransform(translationX: tx, y: 0).concatenating(tm)
    }

    private func kern(_ n: CGFloat) {
        tm = CGAffineTransform(translationX: -n / 1000 * fontSize * th, y: 0).concatenating(tm)
    }

    private func record(from start: CGPoint) {
        guard let font else { return }
        let end = textOrigin()
        let size = effectiveSize()
        guard size > 0.5 else { return }
        runs.append(TextRun(font: font, size: size, color: gs.fill,
                            x0: min(start.x, end.x), x1: max(start.x, end.x), baseline: start.y))
    }

    private func showString(_ s: CGPDFScannerRef) {
        var str: CGPDFStringRef?
        guard CGPDFScannerPopString(s, &str), let str else { return }
        let start = textOrigin()
        advance(str)
        record(from: start)
    }

    private func showArray(_ s: CGPDFScannerRef) {
        var arr: CGPDFArrayRef?
        guard CGPDFScannerPopArray(s, &arr), let arr else { return }
        let start = textOrigin()
        for i in 0..<CGPDFArrayGetCount(arr) {
            var str: CGPDFStringRef?
            var n: CGPDFReal = 0
            if CGPDFArrayGetString(arr, i, &str), let str { advance(str) }
            else if CGPDFArrayGetNumber(arr, i, &n) { kern(n) }
        }
        record(from: start)
    }

    private func nextLine() {
        tlm = CGAffineTransform(translationX: 0, y: -tl).concatenating(tlm)
        tm = tlm
    }

    private func moveText(_ x: CGFloat, _ y: CGFloat) {
        tlm = CGAffineTransform(translationX: x, y: y).concatenating(tlm)
        tm = tlm
    }

    // MARK: Paths (only to find thin horizontal rules)

    private func addRect(_ r: [CGFloat]) {
        let rect = CGRect(x: r[0], y: r[1], width: r[2], height: r[3]).applying(gs.ctm).standardized
        pathRects.append(rect)
        pathBox = pathBox.union(rect)
    }

    private func extend(_ p: CGPoint) { pathBox = pathBox.union(CGRect(origin: p, size: .zero)) }

    private func curveTo(_ v: [CGFloat]) {
        hasCurves = true
        for k in stride(from: 0, to: v.count, by: 2) { extend(CGPoint(x: v[k], y: v[k + 1]).applying(gs.ctm)) }
        if v.count >= 2 { current = CGPoint(x: v[v.count - 2], y: v[v.count - 1]).applying(gs.ctm) }
    }

    private func moveTo(_ p: [CGFloat]) {
        current = CGPoint(x: p[0], y: p[1]).applying(gs.ctm)
        subpathStart = current
        extend(current)
    }

    private func lineTo(_ p: [CGFloat]) {
        let next = CGPoint(x: p[0], y: p[1]).applying(gs.ctm)
        pathSegments.append((current, next))
        current = next
        extend(next)
    }

    private func fillPath() {
        for r in pathRects where r.height <= 2.5 && r.width >= 30 { rules.append(HRule(rect: r, color: gs.fill)) }
        let b = pathBox
        if !b.isNull {
            // Small round/square blob → a drawn list bullet.
            if b.width >= 1.5, b.width <= 8, b.height >= 1.5, b.height <= 8, abs(b.width - b.height) < 1.5 {
                dots.append(Dot(rect: b))
            }
            // Large, light, non-white box → background shading.
            let (r, g, bl) = gs.fillRGB
            let light = r > 0.75 && g > 0.75 && bl > 0.75
            let white = r > 0.985 && g > 0.985 && bl > 0.985
            if b.width > 60, b.height > 10, light, !white, let hex = gs.fill {
                shades.append(Shade(rect: b, color: hex))
            }
        }
        clearPath()
    }

    private func strokePath() {
        let scale = hypot(gs.ctm.c, gs.ctm.d)
        let thickness = max(0.4, gs.lineWidth * (scale == 0 ? 1 : scale))
        for (a, b) in pathSegments where abs(a.y - b.y) < 0.5 && abs(a.x - b.x) >= 30 {
            rules.append(HRule(rect: CGRect(x: min(a.x, b.x), y: a.y - thickness / 2, width: abs(a.x - b.x), height: thickness), color: gs.stroke))
        }
        for r in pathRects where r.height <= 1.5 && r.width >= 30 { rules.append(HRule(rect: r, color: gs.stroke)) }
        clearPath()
    }

    private func clearPath() {
        pathRects.removeAll()
        pathSegments.removeAll()
        pathBox = .null
        hasCurves = false
    }

    private func doXObject(_ name: String) {
        guard depth < 8, let cs = streams.last, let obj = CGPDFContentStreamGetResource(cs, "XObject", name) else { return }
        var stream: CGPDFStreamRef?
        guard CGPDFObjectGetValue(obj, .stream, &stream), let stream, let dict = CGPDFStreamGetDictionary(stream) else { return }
        switch PDFRead.name(dict, "Subtype") {
        case "Image":
            let r = CGRect(x: 0, y: 0, width: 1, height: 1).applying(gs.ctm).standardized
            images.append(ImagePlacement(rect: r))
        case "Form":
            stack.append(gs)
            if let m = PDFRead.array(dict, "Matrix").map(PDFRead.numbers), m.count == 6 {
                gs.ctm = CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]).concatenating(gs.ctm)
            }
            let resources = PDFRead.dict(dict, "Resources")
            let child = CGPDFContentStreamCreateWithStream(stream, resources ?? CGPDFStreamGetDictionary(stream)!, cs)
            depth += 1
            let savedTM = tm, savedTLM = tlm
            run(child)
            tm = savedTM; tlm = savedTLM
            depth -= 1
            gs = stack.popLast() ?? GState()
        default: break
        }
    }

    // MARK: Operator table

    private static let table: CGPDFOperatorTableRef = {
        let t = CGPDFOperatorTableCreate()!
        func on(_ op: String, _ cb: CGPDFOperatorCallback) { CGPDFOperatorTableSetCallback(t, op, cb) }

        on("q") { _, i in let m = me(i); m.stack.append(m.gs) }
        on("Q") { _, i in let m = me(i); if let g = m.stack.popLast() { m.gs = g } }
        on("cm") { s, i in
            guard let v = nums(s, 6) else { return }
            let m = me(i)
            m.gs.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(m.gs.ctm)
        }
        on("w") { s, i in if let v = num(s) { me(i).gs.lineWidth = v } }

        on("BT") { _, i in let m = me(i); m.tm = .identity; m.tlm = .identity }
        on("Tf") { s, i in
            guard let size = num(s), let n = name(s) else { return }
            me(i).setFont(n, size)
        }
        on("Tc") { s, i in if let v = num(s) { me(i).tc = v } }
        on("Tw") { s, i in if let v = num(s) { me(i).tw = v } }
        on("Tz") { s, i in if let v = num(s) { me(i).th = v / 100 } }
        on("TL") { s, i in if let v = num(s) { me(i).tl = v } }
        on("Ts") { s, i in if let v = num(s) { me(i).rise = v } }
        on("Td") { s, i in if let v = nums(s, 2) { me(i).moveText(v[0], v[1]) } }
        on("TD") { s, i in if let v = nums(s, 2) { let m = me(i); m.tl = -v[1]; m.moveText(v[0], v[1]) } }
        on("Tm") { s, i in
            guard let v = nums(s, 6) else { return }
            let m = me(i)
            m.tlm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            m.tm = m.tlm
        }
        on("T*") { _, i in me(i).nextLine() }
        on("Tj") { s, i in me(i).showString(s) }
        on("TJ") { s, i in me(i).showArray(s) }
        on("'") { s, i in let m = me(i); m.nextLine(); m.showString(s) }
        on("\"") { s, i in
            let m = me(i)
            var str: CGPDFStringRef?
            guard CGPDFScannerPopString(s, &str), let str, let v = nums(s, 2) else { return }
            m.tw = v[0]; m.tc = v[1]
            m.nextLine()
            let start = m.textOrigin()
            m.advance(str)
            m.record(from: start)
        }

        on("g") { s, i in me(i).setFill(allNums(s)) }
        on("rg") { s, i in me(i).setFill(allNums(s)) }
        on("k") { s, i in me(i).setFill(allNums(s)) }
        on("sc") { s, i in me(i).setFill(allNums(s)) }
        on("scn") { s, i in me(i).setFill(allNums(s)) }
        on("G") { s, i in me(i).setStroke(allNums(s)) }
        on("RG") { s, i in me(i).setStroke(allNums(s)) }
        on("K") { s, i in me(i).setStroke(allNums(s)) }
        on("SC") { s, i in me(i).setStroke(allNums(s)) }
        on("SCN") { s, i in me(i).setStroke(allNums(s)) }
        on("c") { s, i in if let v = nums(s, 6) { me(i).curveTo(v) } }
        on("v") { s, i in if let v = nums(s, 4) { me(i).curveTo(v) } }
        on("y") { s, i in if let v = nums(s, 4) { me(i).curveTo(v) } }

        on("re") { s, i in if let v = nums(s, 4) { me(i).addRect(v) } }
        on("m") { s, i in if let v = nums(s, 2) { me(i).moveTo(v) } }
        on("l") { s, i in if let v = nums(s, 2) { me(i).lineTo(v) } }
        on("h") { _, i in let m = me(i); m.pathSegments.append((m.current, m.subpathStart)); m.current = m.subpathStart }
        for op in ["f", "F", "f*", "B", "B*", "b", "b*"] { on(op) { _, i in me(i).fillPath() } }
        for op in ["S", "s"] { on(op) { _, i in me(i).strokePath() } }
        on("n") { _, i in me(i).clearPath() }
        on("Do") { s, i in if let n = name(s) { me(i).doXObject(n) } }
        return t
    }()
}
