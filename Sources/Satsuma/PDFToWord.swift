import AppKit
import PDFKit

/// Layout-preserving PDF → DOCX conversion.
///
/// 1. Characters + positions come from PDFKit; real font/size/color come from
///    our content-stream scanner, matched by position.
/// 2. Characters are grouped into lines, lines into segments (big gaps become
///    tab stops) and paragraphs (wrapped lines are re-joined, hyphens removed).
/// 3. Bullets become Word lists, drawn rules become paragraph borders, links
///    become hyperlinks, and vertical gaps become paragraph spacing.
enum PDFToWord {
    static func convert(_ url: URL, to out: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw ConversionError("Can't open PDF") }
        var pages: [PageLayout] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            pages.append(PageLayout(page: page, index: i))
        }
        guard !pages.isEmpty else { throw ConversionError("PDF has no pages") }
        let fonts = FontMapper(pages: pages)
        try DocxWriter(pages: pages, fonts: fonts).write(to: out)
    }
}

// MARK: - Model

struct StyledChar {
    var ch: String
    var rect: CGRect           // PDFKit selection box (line height)
    var run: TextRun?
    var link: URL?
    var isSpace: Bool { ch.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct Segment {
    var chars: [StyledChar]
    var minX: CGFloat { chars.first(where: { !$0.isSpace })?.rect.minX ?? chars.first?.rect.minX ?? 0 }
    var maxX: CGFloat { chars.last(where: { !$0.isSpace })?.rect.maxX ?? chars.last?.rect.maxX ?? 0 }
    var text: String { chars.map(\.ch).joined() }
}

struct Line {
    var segments: [Segment]
    var top: CGFloat
    var bottom: CGFloat
    var baseline: CGFloat
    var size: CGFloat           // dominant font size
    var minX: CGFloat { segments.first?.minX ?? 0 }
    var maxX: CGFloat { segments.last?.maxX ?? 0 }
    var allChars: [StyledChar] { segments.flatMap(\.chars) }
    var boldRatio: CGFloat {
        let chars = allChars.filter { !$0.isSpace }
        guard !chars.isEmpty else { return 0 }
        return CGFloat(chars.filter { $0.run.map { FontMapper.isBold($0.font) } ?? false }.count) / CGFloat(chars.count)
    }
}

enum Alignment: String { case left, center, right, both }

final class Paragraph {
    var lines: [Line] = []
    var bullet: String? = nil
    var bulletX: CGFloat = 0
    var textLeft: CGFloat = 0        // left edge of wrapped text
    var firstLeft: CGFloat = 0       // left edge of first line's text
    var align: Alignment = .left
    var lineSpacing: CGFloat = 0     // points, exact
    var spaceBefore: CGFloat = 0     // points
    var tabs: [(kind: String, pos: CGFloat)] = []
    var borderBottom: (space: CGFloat, size: CGFloat, color: String)? = nil
    var borderTop: (space: CGFloat, size: CGFloat, color: String)? = nil
    var shading: String? = nil
    var pageBreakBefore = false
    var image: (png: Data, size: CGSize)? = nil
    var imageRect: CGRect = .zero
    var isRuleOnly = false

    var top: CGFloat { image != nil || isRuleOnly ? imageRect.maxY : (lines.first?.top ?? 0) }
    var firstBaseline: CGFloat { image != nil || isRuleOnly ? imageRect.minY : (lines.first?.baseline ?? 0) }
    var lastBaseline: CGFloat { image != nil || isRuleOnly ? imageRect.minY : (lines.last?.baseline ?? 0) }
    var size: CGFloat { lines.first?.size ?? 10 }
}

// MARK: - Page layout analysis

final class PageLayout {
    let index: Int
    let mediaBox: CGRect
    var lines: [Line] = []
    var paragraphs: [Paragraph] = []
    var contentLeft: CGFloat = 0
    var contentRight: CGFloat = 0
    var samples: [(font: PDFFontInfo, text: String, width: CGFloat, size: CGFloat)] = []
    private var dots: [Dot] = []

    private let bulletChars: Set<String> = ["•", "●", "◦", "▪", "■", "□", "‣", "∙", "·", "–", "−", "-", "∗", "*", "➢", "➤", "►", "✓", "✔", "○"]

    init(page: PDFPage, index: Int) {
        self.index = index
        mediaBox = page.bounds(for: .mediaBox)
        let scan = page.pageRef.map(PDFStyleScanner.scan)
        let chars = PageLayout.extractChars(page: page, runs: scan?.runs ?? [])
        lines = PageLayout.buildLines(chars)
        dots = scan?.dots ?? []
        guard !lines.isEmpty || !(scan?.images.isEmpty ?? true) else { return }

        let bodyLines = lines.filter { !$0.segments.isEmpty }
        contentLeft = bodyLines.map(\.minX).min() ?? mediaBox.minX + 72
        contentRight = bodyLines.map(\.maxX).max() ?? mediaBox.maxX - 72
        collectSamples()
        buildParagraphs()
        attachRules(scan?.rules ?? [])
        applyShading(scan?.shades ?? [])
        addImages(scan?.images ?? [], page: page)
        paragraphs.sort { $0.top > $1.top }
    }

    // Characters with PDFKit positions, decorated with scanner style and links.
    private static func extractChars(page: PDFPage, runs: [TextRun]) -> [StyledChar] {
        guard let text = page.string as NSString? else { return [] }
        let links: [(CGRect, URL)] = page.annotations.compactMap { a in
            guard a.type == "Link" else { return nil }
            if let u = a.url { return (a.bounds, u) }
            if let u = (a.action as? PDFActionURL)?.url { return (a.bounds, u) }
            return nil
        }
        var out: [StyledChar] = []
        var textLine: [Int] = []          // PDFKit line number of each char
        var lineNo = 0
        out.reserveCapacity(text.length)
        var i = 0
        while i < text.length {
            let r = text.rangeOfComposedCharacterSequence(at: i)
            defer { i = r.location + r.length }
            var ch = text.substring(with: r)
            if ch == "\n" || ch == "\r" { lineNo += 1; continue }
            guard let sel = page.selection(for: r) else { continue }
            var rect = sel.bounds(for: page)
            guard rect.width > 0 || ch == " " else { continue }
            ch = normalize(ch)
            // PDFKit stretches the character before a non-text glyph (icons) over the gap.
            let typical = rect.height * 0.75
            if ch != " ", rect.width > max(typical * 2, 14) {
                if let prev = out.last, abs(prev.rect.midY - rect.midY) < 1, prev.rect.maxX <= rect.maxX {
                    rect.origin.x = prev.rect.maxX
                }
                rect.size.width = typical * 0.7
            }
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let link = links.first(where: { $0.0.insetBy(dx: -1, dy: -2).contains(center) })?.1
            out.append(StyledChar(ch: ch, rect: rect, run: nil, link: link))
            textLine.append(lineNo)
        }

        let pageHasRupeeFont = runs.contains { $0.font.baseName.lowercased().contains("rupee") }

        // Pick one baseline per PDFKit line: the one whose runs span the same width as the line.
        // (PDFKit sometimes gives two visual lines one tall shared box.)
        var byLine: [Int: [Int]] = [:]
        for (idx, n) in textLine.enumerated() { byLine[n, default: []].append(idx) }
        for (_, idxs) in byLine {
            let visible = idxs.filter { !out[$0].isSpace }
            guard let f = visible.first else { continue }
            let minX = visible.map { out[$0].rect.minX }.min()!, maxX = visible.map { out[$0].rect.maxX }.max()!
            let box = visible.reduce(out[f].rect) { $0.union(out[$1].rect) }
            let nearby = runs.filter { $0.baseline >= box.minY - 2 && $0.baseline <= box.maxY + 1 && $0.x1 > minX - 2 && $0.x0 < maxX + 2 }
            var clusters: [CGFloat: [TextRun]] = [:]
            for r in nearby { clusters[(r.baseline * 2).rounded() / 2, default: []].append(r) }
            let chosen = clusters.min { a, b in
                func score(_ rs: [TextRun]) -> CGFloat {
                    let lo = rs.map(\.x0).min()!, hi = rs.map(\.x1).max()!
                    return abs(lo - minX) + abs(hi - maxX)
                }
                return score(a.value) < score(b.value)
            }?.key
            for idx in idxs {
                var run: TextRun? = nil
                if let base = chosen {
                    run = bestRun(for: out[idx].rect, in: nearby.filter { abs($0.baseline - base) < 1.5 })
                }
                if run == nil { run = bestRun(for: out[idx].rect, in: nearby.isEmpty ? runs : nearby) }
                out[idx].run = run
                // This font draws the rupee sign in the backtick slot.
                if out[idx].ch == "`", pageHasRupeeFont { out[idx].ch = "₹" }
            }
        }
        return out
    }

    private static func normalize(_ ch: String) -> String {
        switch ch {
        case "\u{FB00}": return "ff"
        case "\u{FB01}": return "fi"
        case "\u{FB02}": return "fl"
        case "\u{FB03}": return "ffi"
        case "\u{FB04}": return "ffl"
        case "\u{00A0}", "\t": return " "
        default: return ch
        }
    }

    private static func bestRun(for rect: CGRect, in runs: [TextRun]) -> TextRun? {
        var best: TextRun?
        var bestScore = CGFloat.greatestFiniteMagnitude
        let cx = rect.midX
        for r in runs where r.baseline >= rect.minY - 2 && r.baseline <= rect.maxY + 1 {
            let dx = cx < r.x0 ? r.x0 - cx : (cx > r.x1 ? cx - r.x1 : 0)
            guard dx < 4 else { continue }
            // Prefer the run whose baseline sits lowest inside the box (not a superscript), then horizontal fit.
            let score = dx * 10 + abs(r.baseline - (rect.minY + rect.height * 0.25)) * 0.1
            if score < bestScore { bestScore = score; best = r }
        }
        return best
    }

    private static func buildLines(_ chars: [StyledChar]) -> [Line] {
        // Group by vertical overlap of PDFKit's (line-height) boxes.
        var groups: [[StyledChar]] = []
        for c in chars.sorted(by: { $0.rect.midY > $1.rect.midY }) {
            if let i = groups.indices.last, let ref = groups[i].first,
               abs(ref.rect.midY - c.rect.midY) < min(ref.rect.height, c.rect.height) * 0.45 {
                groups[i].append(c)
            } else {
                groups.append([c])
            }
        }
        return groups.compactMap { g -> Line? in
            let sorted = g.sorted { $0.rect.minX < $1.rect.minX }
            let visible = sorted.filter { !$0.isSpace }
            guard !visible.isEmpty else { return nil }
            let sizes = visible.compactMap { $0.run?.size }
            let size = mode(sizes.map { ($0 * 2).rounded() / 2 }) ?? (visible[0].rect.height / 1.2)
            let baselines = visible.compactMap { $0.run }.filter { abs($0.size - size) < 0.6 }.map(\.baseline)
            let baseline = mode(baselines.map { ($0 * 2).rounded() / 2 }) ?? visible[0].rect.minY + visible[0].rect.height * 0.22

            // Split where the gap is much wider than a space.
            var segments: [Segment] = []
            var current: [StyledChar] = []
            var lastVisible: StyledChar?
            let bigGap = max(size * 2.2, 16)
            for c in sorted {
                if !c.isSpace, let lv = lastVisible, c.rect.minX - lv.rect.maxX > bigGap {
                    while current.last?.isSpace == true { current.removeLast() }
                    if !current.isEmpty { segments.append(Segment(chars: current)) }
                    current = []
                }
                if c.isSpace && (current.isEmpty || current.last?.isSpace == true) { continue }
                current.append(c)
                if !c.isSpace { lastVisible = c }
            }
            while current.last?.isSpace == true { current.removeLast() }
            if !current.isEmpty { segments.append(Segment(chars: current)) }
            return Line(segments: segments,
                        top: g.map(\.rect.maxY).max()!, bottom: g.map(\.rect.minY).min()!,
                        baseline: baseline, size: size)
        }
    }

    private func collectSamples() {
        for line in lines {
            for seg in line.segments {
                // Consecutive characters sharing one font give a width sample.
                var start = 0
                let cs = seg.chars
                while start < cs.count {
                    guard let f = cs[start].run?.font else { start += 1; continue }
                    var end = start
                    while end + 1 < cs.count, cs[end + 1].run?.font === f || (cs[end + 1].isSpace && end + 2 < cs.count && cs[end + 2].run?.font === f) { end += 1 }
                    if end > start + 2 {
                        let text = cs[start...end].map(\.ch).joined()
                        let width = cs[end].rect.maxX - cs[start].rect.minX
                        if let size = cs[start].run?.size, width > 0 { samples.append((f, text, width, size)) }
                    }
                    start = end + 1
                }
            }
        }
    }

    // MARK: Paragraphs

    private func bulletInfo(_ line: Line) -> (String, CGFloat, Line)? {
        // A small shape drawn just left of the line's first character.
        if let dot = dots.first(where: { $0.rect.midY > line.bottom && $0.rect.midY < line.top && $0.rect.maxX <= line.minX && line.minX - $0.rect.maxX < 16 }) {
            return (dot.rect.width - dot.rect.height < 0.5 && dot.rect.width > 3.5 ? "▪" : "•", dot.rect.minX, line)
        }
        guard var first = line.segments.first, let c = first.chars.first, bulletChars.contains(c.ch) else { return nil }
        var segs = line.segments
        let bulletX = c.rect.minX
        if first.chars.count == 1 {
            guard segs.count > 1 else { return nil }
            segs.removeFirst()
        } else {
            // Require a gap or space after the bullet so "-5%" isn't treated as a list.
            let next = first.chars[1]
            guard next.isSpace || next.rect.minX - c.rect.maxX > 1.5 else { return nil }
            first.chars.removeFirst()
            while first.chars.first?.isSpace == true { first.chars.removeFirst() }
            segs[0] = first
        }
        var l = line
        l.segments = segs
        return (c.ch, bulletX, l)
    }

    private func firstWordWidth(_ line: Line) -> CGFloat {
        guard let seg = line.segments.first else { return 0 }
        let chars = seg.chars
        guard let first = chars.first else { return 0 }
        let end = chars.firstIndex(where: \.isSpace).map { max(0, $0 - 1) } ?? chars.count - 1
        return chars[end].rect.maxX - first.rect.minX
    }

    private func isCentered(_ line: Line) -> Bool {
        let mid = (contentLeft + contentRight) / 2
        return line.segments.count == 1 && abs((line.minX + line.maxX) / 2 - mid) < 4 && line.minX > contentLeft + 12
    }

    private func buildParagraphs() {
        var current: Paragraph?
        let spaceWidth: (Line) -> CGFloat = { $0.size * 0.3 }

        for raw in lines {
            let bullet = bulletInfo(raw)
            let line = bullet?.2 ?? raw
            guard !line.segments.isEmpty else { continue }

            if let p = current, bullet == nil, let last = p.lines.last, canJoin(p, last, line, spaceWidth(last)) {
                if p.lines.count == 1 && line.minX < p.firstLeft - 3 { p.textLeft = line.minX }
                p.lines.append(line)
                continue
            }

            let p = Paragraph()
            p.lines = [line]
            p.firstLeft = line.minX
            p.textLeft = line.minX
            if let (b, x, _) = bullet { p.bullet = b; p.bulletX = x }
            paragraphs.append(p)
            current = p
        }

        for p in paragraphs { finish(p) }
    }

    private func canJoin(_ p: Paragraph, _ last: Line, _ next: Line, _ space: CGFloat) -> Bool {
        guard last.segments.count == 1, next.segments.count == 1, !isCentered(last) || isCentered(next) else { return false }
        guard abs(last.size - next.size) < 0.6 else { return false }
        let pitch = last.baseline - next.baseline
        guard pitch > 0, pitch < last.size * 1.75 else { return false }
        if p.lines.count >= 2 {
            let prevPitch = p.lines[p.lines.count - 2].baseline - last.baseline
            guard abs(prevPitch - pitch) < 1.5 else { return false }
        }
        // Left edges line up (or the first line was indented).
        let expectedLeft = p.lines.count == 1 ? p.firstLeft : p.textLeft
        let indentOK = abs(next.minX - expectedLeft) < 3 || (p.lines.count == 1 && p.bullet == nil && next.minX < p.firstLeft - 3 && p.firstLeft - next.minX < 50)
        guard indentOK else { return false }
        if isCentered(last) { return true }
        // The next line's first word would not have fit on this line → it wrapped.
        guard last.maxX + space + firstWordWidth(next) > contentRight - 2 else { return false }
        // Don't merge a bold heading into following regular text.
        if (last.boldRatio > 0.9) != (next.boldRatio > 0.9) && p.lines.count == 1 && last.maxX < contentRight - 40 { return false }
        return true
    }

    private func finish(_ p: Paragraph) {
        let first = p.lines[0]
        let mid = (contentLeft + contentRight) / 2

        if p.lines.allSatisfy(isCentered) && p.bullet == nil {
            p.align = .center
        } else if p.lines.count == 1 && first.segments.count == 1 && abs(first.maxX - contentRight) < 3 && first.minX > mid {
            p.align = .right
        } else if p.lines.count >= 2 && p.lines.dropLast().allSatisfy({ abs($0.maxX - contentRight) < 2.5 }) {
            p.align = .both
        }

        if first.segments.count > 1 {
            for seg in first.segments.dropFirst() {
                if abs(seg.maxX - contentRight) < 4 {
                    p.tabs.append(("right", contentRight))
                } else if abs((seg.minX + seg.maxX) / 2 - mid) < 6 {
                    p.tabs.append(("center", mid))
                } else {
                    p.tabs.append(("left", seg.minX))
                }
            }
        }

        if p.lines.count >= 2 {
            let pitches = zip(p.lines, p.lines.dropFirst()).map { $0.baseline - $1.baseline }
            p.lineSpacing = pitches.reduce(0, +) / CGFloat(pitches.count)
        }
    }

    // MARK: Rules & images

    private func attachRules(_ rules: [HRule]) {
        let width = contentRight - contentLeft
        let wide = rules.filter { $0.rect.width >= width * 0.3 }
        var seen: [CGFloat] = []
        for rule in wide.sorted(by: { $0.rect.midY > $1.rect.midY }) {
            // Drop duplicates (the same line drawn twice).
            if seen.contains(where: { abs($0 - rule.rect.midY) < 1 }) { continue }
            seen.append(rule.rect.midY)
            let y = rule.rect.midY
            let thickness = max(0.25, rule.rect.height)
            let color = rule.color ?? "000000"
            let above = paragraphs.filter { $0.lastBaseline > y }.min { $0.lastBaseline - y < $1.lastBaseline - y }
            let below = paragraphs.filter { $0.top < y }.max { $0.top < $1.top }
            let gapAbove = above.map { $0.lastBaseline - y } ?? .infinity
            let gapBelow = below.map { y - $0.top } ?? .infinity

            // Only a rule hugging a line becomes its border; looser rules are dividers of their own.
            if let p = above, gapAbove <= gapBelow + 2, gapAbove < p.size * 0.9, p.borderBottom == nil, p.image == nil {
                let descent = p.size * 0.22
                p.borderBottom = (max(0, gapAbove - descent), thickness, color)
            } else if let p = below, gapBelow < p.size * 0.6, p.borderTop == nil, p.image == nil {
                p.borderTop = (max(0, gapBelow), thickness, color)
            } else {
                let p = Paragraph()
                p.isRuleOnly = true
                p.imageRect = rule.rect
                p.textLeft = rule.rect.minX
                p.firstLeft = rule.rect.minX
                p.borderBottom = (0, thickness, color)
                paragraphs.append(p)
            }
        }
    }

    private func applyShading(_ shades: [Shade]) {
        for p in paragraphs where p.image == nil && !p.isRuleOnly {
            let inside = shades.filter { s in
                p.lines.allSatisfy { s.rect.insetBy(dx: -1, dy: -1).contains(CGPoint(x: $0.minX, y: ($0.top + $0.bottom) / 2)) }
            }
            // The smallest enclosing box is the most specific background.
            p.shading = inside.min { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }?.color
        }
    }

    private func addImages(_ placements: [ImagePlacement], page: PDFPage) {
        let pageArea = mediaBox.width * mediaBox.height
        let hasText = !lines.isEmpty
        let candidates = placements.filter { p in
            let r = p.rect.intersection(mediaBox)
            guard !r.isNull, r.width >= 12, r.height >= 12 else { return false }
            // A page-sized image under real text is a scanned background; skip it.
            return !(hasText && r.width * r.height > pageArea * 0.7)
        }
        guard !candidates.isEmpty, let bitmap = try? PDFOps.render(page, dpi: 200) else { return }
        let scale = CGFloat(bitmap.width) / mediaBox.width
        for placement in candidates {
            let r = placement.rect.intersection(mediaBox)
            // Bitmap rows run top-down.
            let crop = CGRect(x: (r.minX - mediaBox.minX) * scale, y: (mediaBox.maxY - r.maxY) * scale,
                              width: r.width * scale, height: r.height * scale).integral
            guard let cg = bitmap.cropping(to: crop) else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            let p = Paragraph()
            p.image = (png, r.size)
            p.imageRect = r
            p.textLeft = r.minX
            p.firstLeft = r.minX
            paragraphs.append(p)
        }
    }
}

func mode<T: Hashable>(_ values: [T]) -> T? {
    var counts: [T: Int] = [:]
    for v in values { counts[v, default: 0] += 1 }
    return counts.max { $0.value < $1.value }?.key
}

// MARK: - Font mapping

/// Picks a Word font for each PDF font: the real family when it's installed,
/// otherwise the common font whose letter widths match the PDF most closely.
final class FontMapper {
    struct Face: Hashable { let family: String; let bold: Bool; let italic: Bool }

    private var map: [ObjectIdentifier: Face] = [:]
    /// Extra spacing per character (points) that makes the Word font as wide as the PDF font.
    private var tracking: [ObjectIdentifier: CGFloat] = [:]
    let defaultFamily: String
    let defaultSize: CGFloat

    static let serif = ["Times New Roman", "Georgia", "Cambria", "Book Antiqua", "Garamond", "Palatino Linotype"]
    static let sans = ["Arial", "Calibri", "Helvetica", "Verdana", "Tahoma", "Trebuchet MS", "Segoe UI"]
    static let mono = ["Courier New", "Consolas", "Menlo"]

    static func isBold(_ f: PDFFontInfo) -> Bool {
        let n = f.baseName.lowercased()
        if f.flags & 262_144 != 0 { return true }
        return ["bold", "black", "heavy", "semibold", "demi", "cmbx", "cmb10", "-bd", "extrab", "ultrab"].contains { n.contains($0) }
            || n.hasSuffix("bd") || n.hasSuffix("-b")
    }

    static func isItalic(_ f: PDFFontInfo) -> Bool {
        let n = f.baseName.lowercased()
        if f.flags & 64 != 0 { return true }
        return ["italic", "oblique", "cmti", "cmsl", "cmmi", "cmbxti", "slant", "-it", ",it"].contains { n.contains($0) }
            || n.hasSuffix("it") && !n.hasSuffix("unit")
    }

    static func isSmallCaps(_ f: PDFFontInfo) -> Bool {
        let n = f.baseName.lowercased()
        return n.contains("caps") || n.contains("cmcsc") || n.contains("smallcap") || n.hasSuffix("-sc") || n.hasSuffix("sc10")
    }

    static func fontClass(_ f: PDFFontInfo) -> [String] {
        let n = f.baseName.lowercased()
        if f.flags & 1 != 0 || ["mono", "courier", "cmtt", "code", "consol", "menlo", "typewriter"].contains(where: n.contains) { return mono }
        if ["sans", "arial", "helvet", "cmss", "calibri", "verdana", "roboto", "lato", "inter", "segoe", "tahoma", "gothic", "avenir", "futura", "frutiger"].contains(where: n.contains) {
            return sans
        }
        // Font descriptor flag 2 = serif; TeX fonts often omit it.
        let tex = n.hasPrefix("cm") || n.hasPrefix("lm") || n.hasPrefix("sf")
        if f.flags != 0 && f.flags & 2 == 0 && !tex { return sans }
        return serif
    }

    init(pages: [PageLayout]) {
        var samplesByFont: [ObjectIdentifier: (font: PDFFontInfo, items: [(String, CGFloat, CGFloat)])] = [:]
        var fontsUsed: [ObjectIdentifier: PDFFontInfo] = [:]
        var sizeCounts: [CGFloat: Int] = [:]
        var charCountByFamily: [String: Int] = [:]

        for page in pages {
            for s in page.samples {
                let id = ObjectIdentifier(s.font)
                samplesByFont[id, default: (s.font, [])].items.append((s.text, s.width, s.size))
            }
            for line in page.lines {
                for c in line.allChars {
                    guard let r = c.run else { continue }
                    fontsUsed[ObjectIdentifier(r.font)] = r.font
                    sizeCounts[(r.size * 2).rounded() / 2, default: 0] += 1
                }
            }
        }

        // Group PDF fonts by family-ish key so bold/italic variants share one Word family.
        var familyChoice: [String: String] = [:]
        for (id, font) in fontsUsed {
            let bold = FontMapper.isBold(font), italic = FontMapper.isItalic(font)
            let key = FontMapper.familyKey(font)
            let family: String
            if let installed = FontMapper.installedFamily(font) {
                family = installed
            } else if let chosen = familyChoice[key] {
                family = chosen
            } else {
                let items = samplesByFont[id]?.items ?? []
                family = FontMapper.bestMatch(items: items, candidates: FontMapper.fontClass(font), bold: bold, italic: italic)
                familyChoice[key] = family
            }
            map[id] = Face(family: family, bold: bold, italic: italic)
            tracking[id] = FontMapper.trackingPerEm(items: samplesByFont[id]?.items ?? [], family: family, bold: bold, italic: italic)
            charCountByFamily[family, default: 0] += 1
        }
        defaultFamily = charCountByFamily.max { $0.value < $1.value }?.key ?? "Times New Roman"
        defaultSize = sizeCounts.max { $0.value < $1.value }?.key ?? 11
    }

    func face(for run: TextRun?) -> Face {
        guard let run else { return Face(family: defaultFamily, bold: false, italic: false) }
        return map[ObjectIdentifier(run.font)] ?? Face(family: defaultFamily, bold: false, italic: false)
    }

    /// Spacing to add to each character, in points per point of font size.
    func trackingPerEm(for run: TextRun?) -> CGFloat {
        guard let run else { return 0 }
        return tracking[ObjectIdentifier(run.font)] ?? 0
    }

    private static func trackingPerEm(items: [(String, CGFloat, CGFloat)], family: String, bold: Bool, italic: Bool) -> CGFloat {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        var diff: CGFloat = 0, chars: CGFloat = 0
        for (text, width, size) in items.prefix(400) {
            guard let font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: size) else { continue }
            let measured = (text as NSString).size(withAttributes: [.font: font]).width
            let n = CGFloat(text.count - 1)
            guard n > 0 else { continue }
            diff += (width - measured) / size
            chars += n
        }
        guard chars > 20 else { return 0 }
        // Clamp: beyond this, letters visibly collide or drift apart.
        return min(0.06, max(-0.08, diff / chars))
    }

    private static func familyKey(_ f: PDFFontInfo) -> String {
        let n = f.baseName.lowercased()
        // TeX fonts: cmr10, cmbx12, cmti10 … all one family.
        if n.hasPrefix("cm") || n.hasPrefix("sfrm") || n.hasPrefix("sfbx") || n.hasPrefix("sfti") { return "computer-modern" }
        if n.hasPrefix("lmroman") { return "latin-modern" }
        return String(n.split(whereSeparator: { $0 == "-" || $0 == "," }).first ?? Substring(n))
    }

    /// The font's real family when it is installed on this Mac (e.g. ArialMT → Arial).
    private static func installedFamily(_ f: PDFFontInfo) -> String? {
        let ps = f.baseName.replacingOccurrences(of: ",", with: "-")
        if let font = NSFont(name: ps, size: 10), let family = font.familyName { return family }
        let base = String(ps.split(separator: "-").first ?? Substring(ps))
        if let font = NSFont(name: base, size: 10), let family = font.familyName { return family }
        return nil
    }

    private static func bestMatch(items: [(String, CGFloat, CGFloat)], candidates: [String], bold: Bool, italic: Bool) -> String {
        let available = candidates.filter { NSFontManager.shared.availableMembers(ofFontFamily: $0) != nil }
        guard !items.isEmpty, !available.isEmpty else { return available.first ?? candidates[0] }
        var best = available[0]
        var bestErr = CGFloat.greatestFiniteMagnitude
        for family in available {
            var traits: NSFontTraitMask = []
            if bold { traits.insert(.boldFontMask) }
            if italic { traits.insert(.italicFontMask) }
            var pdfTotal: CGFloat = 0, fontTotal: CGFloat = 0
            for (text, width, size) in items.prefix(200) {
                guard let font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: 5, size: size) else { continue }
                pdfTotal += width
                fontTotal += (text as NSString).size(withAttributes: [.font: font]).width
            }
            guard fontTotal > 0 else { continue }
            let err = abs(log(pdfTotal / fontTotal))
            if err < bestErr { bestErr = err; best = family }
        }
        return best
    }
}
