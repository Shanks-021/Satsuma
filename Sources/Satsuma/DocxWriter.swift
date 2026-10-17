import AppKit

/// Writes the analysed pages as a .docx (WordprocessingML) package.
final class DocxWriter {
    private let pages: [PageLayout]
    private let fonts: FontMapper
    private var rels: [(id: String, xml: String)] = []
    private var media: [(name: String, data: Data)] = []
    private var bulletNums: [String: Int] = [:]
    private var drawingID = 1

    // Page-level geometry (points), shared by all pages.
    private let pageSize: CGSize
    private let marginLeft: CGFloat
    private let marginRight: CGFloat
    private var marginTop: CGFloat
    private let marginBottom: CGFloat

    init(pages: [PageLayout], fonts: FontMapper) {
        self.pages = pages
        self.fonts = fonts
        let box = pages[0].mediaBox
        pageSize = box.size
        let withText = pages.filter { !$0.paragraphs.isEmpty }
        let left = withText.map { $0.paragraphs.map { $0.bullet != nil ? $0.bulletX : min($0.firstLeft, $0.textLeft) }.min() ?? $0.contentLeft }.min() ?? box.minX + 72
        let right = withText.map(\.contentRight).max() ?? box.maxX - 72
        let top = withText.compactMap { $0.paragraphs.map(\.top).max() }.max() ?? box.maxY - 72
        marginLeft = max(0, left - box.minX)
        marginRight = max(0, box.maxX - right - 1)
        marginTop = max(0, box.maxY - top)
        // Leave room below the lowest line, with slack for small font-metric drift.
        let lowest = withText.compactMap { page in page.paragraphs.map { $0.lastBaseline - $0.size * 0.3 - page.mediaBox.minY }.min() }.min() ?? 36
        marginBottom = min(36, max(0, lowest - 10))
    }

    func write(to url: URL) throws {
        let body = buildBody()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("satsuma-docx-\(UUID().uuidString)")
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tmp) }
        for dir in ["_rels", "docProps", "word/_rels", "word/media"] {
            try fm.createDirectory(at: tmp.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        func put(_ path: String, _ s: String) throws { try s.write(to: tmp.appendingPathComponent(path), atomically: true, encoding: .utf8) }

        try put("[Content_Types].xml", contentTypes())
        try put("_rels/.rels", rootRels)
        try put("docProps/app.xml", appXML)
        try put("docProps/core.xml", coreXML())
        try put("word/document.xml", documentXML(body))
        try put("word/styles.xml", stylesXML())
        try put("word/numbering.xml", numberingXML())
        try put("word/settings.xml", settingsXML)
        try put("word/_rels/document.xml.rels", documentRels())
        for m in media { try m.data.write(to: tmp.appendingPathComponent("word/media/\(m.name)")) }

        try? fm.removeItem(at: url)
        try Tools.run("/usr/bin/zip", ["-X", "-r", "-q", url.path, "[Content_Types].xml", "_rels", "docProps", "word"], cwd: tmp)
    }

    // MARK: Body

    private func twips(_ pt: CGFloat) -> Int { Int((pt * 20).rounded()) }

    private func buildBody() -> String {
        var xml = ""
        let ratio = typicalLineRatio()
        // Single-line paragraphs take the measured line pitch of multi-line paragraphs of
        // the same font size (documents usually use one fixed pitch per size).
        let multi = pages.flatMap(\.paragraphs).filter { $0.lines.count >= 2 && $0.lineSpacing > 0 }
        func pitch(for size: CGFloat) -> CGFloat {
            let same = multi.filter { abs($0.size - size) < 0.6 }.map(\.lineSpacing).sorted()
            if !same.isEmpty { return same[same.count / 2] }
            return size * ratio
        }
        for page in pages {
            for p in page.paragraphs where p.lineSpacing == 0 && p.image == nil && !p.isRuleOnly { p.lineSpacing = pitch(for: p.size) }
        }
        // Word puts a line's baseline about one descent above the bottom of its exact-height
        // line box, so set the top margin from where the first baseline must land.
        let firstLineOffsets = pages.compactMap { page -> CGFloat? in
            guard let p = page.paragraphs.first, p.image == nil, !p.isRuleOnly else { return nil }
            return page.mediaBox.maxY - p.firstBaseline - (p.lineSpacing - p.size * 0.22)
        }
        if let m = firstLineOffsets.min() { marginTop = max(0, m) }
        for (pi, page) in pages.enumerated() {
            var prevBaseline: CGFloat? = nil
            var prevSpacing: CGFloat = 0
            // Space we could not remove (Word has no negative spacing); repaid from later gaps.
            var debt: CGFloat = 0
            func settle(_ raw: CGFloat) -> CGFloat {
                if raw < 0 { debt += -raw; return 0 }
                let pay = min(raw, debt)
                debt -= pay
                return raw - pay
            }
            let pageTop = page.mediaBox.maxY - marginTop
            for (i, p) in page.paragraphs.enumerated() {
                if p.lineSpacing == 0 && p.image == nil && !p.isRuleOnly { p.lineSpacing = p.size * ratio }
                // Gap from the previous baseline to this paragraph's first baseline, minus the line itself.
                if p.image != nil || p.isRuleOnly {
                    let prevBottom = prevBaseline.map { $0 - prevSpacing * 0.25 } ?? pageTop
                    p.spaceBefore = settle(prevBottom - p.imageRect.maxY)
                } else if let prev = prevBaseline {
                    let distance = prev - p.firstBaseline
                    // A single line closer to the previous one than its own line height: shrink the line.
                    if p.lines.count == 1 && distance < p.lineSpacing { p.lineSpacing = max(p.size * 1.05, distance) }
                    p.spaceBefore = settle(distance - p.lineSpacing)
                } else {
                    p.spaceBefore = max(0, pageTop - p.firstBaseline - (p.lineSpacing - p.size * 0.22))
                }
                if pi > 0 && i == 0 { p.pageBreakBefore = true }
                xml += paragraphXML(p, page: page)
                prevBaseline = p.image != nil || p.isRuleOnly ? p.imageRect.minY : p.lastBaseline
                prevSpacing = p.image != nil ? 0 : p.lineSpacing
            }
        }
        return xml
    }


    /// Median baseline-to-baseline distance divided by font size, from multi-line paragraphs.
    private func typicalLineRatio() -> CGFloat {
        let ratios = pages.flatMap(\.paragraphs).filter { $0.lines.count >= 2 && $0.lineSpacing > 0 }.map { $0.lineSpacing / $0.size }.sorted()
        guard !ratios.isEmpty else { return 1.2 }
        return min(1.6, max(1.0, ratios[ratios.count / 2]))
    }

    private func paragraphXML(_ p: Paragraph, page: PageLayout) -> String {
        var ppr = ""
        if p.pageBreakBefore { ppr += "<w:pageBreakBefore/>" }
        if let b = p.bullet {
            ppr += "<w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(numId(for: b))\"/></w:numPr>"
        }
        if p.borderTop != nil || p.borderBottom != nil {
            ppr += "<w:pBdr>"
            if let t = p.borderTop { ppr += "<w:top w:val=\"single\" w:sz=\"\(max(2, Int(t.size * 8)))\" w:space=\"\(min(31, Int(t.space.rounded())))\" w:color=\"\(t.color)\"/>" }
            if let b = p.borderBottom { ppr += "<w:bottom w:val=\"single\" w:sz=\"\(max(2, Int(b.size * 8)))\" w:space=\"\(min(31, Int(b.space.rounded())))\" w:color=\"\(b.color)\"/>" }
            ppr += "</w:pBdr>"
        }
        if let shade = p.shading { ppr += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(shade)\"/>" }
        if !p.tabs.isEmpty {
            ppr += "<w:tabs>" + p.tabs.map { "<w:tab w:val=\"\($0.kind)\" w:pos=\"\(twips($0.pos - page.mediaBox.minX - marginLeft))\"/>" }.joined() + "</w:tabs>"
        }
        let before = twips(p.spaceBefore)
        if p.isRuleOnly {
            ppr += "<w:spacing w:before=\"\(before)\" w:after=\"0\" w:line=\"20\" w:lineRule=\"exact\"/>"
        } else if p.image != nil {
            ppr += "<w:spacing w:before=\"\(before)\" w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/>"
        } else {
            ppr += "<w:spacing w:before=\"\(before)\" w:after=\"0\" w:line=\"\(twips(p.lineSpacing))\" w:lineRule=\"exact\"/>"
        }

        let left = p.textLeft - page.mediaBox.minX - marginLeft
        if p.bullet != nil {
            let hanging = max(6, p.textLeft - p.bulletX)
            ppr += "<w:ind w:left=\"\(twips(left))\" w:right=\"0\" w:hanging=\"\(twips(hanging))\"/>"
        } else if p.align == .center || p.align == .right {
            ppr += "<w:ind w:left=\"0\" w:right=\"0\"/>"
        } else {
            let first = p.firstLeft - p.textLeft
            let firstAttr = first > 0.5 ? " w:firstLine=\"\(twips(first))\"" : ""
            ppr += "<w:ind w:left=\"\(twips(max(0, left)))\" w:right=\"0\"\(firstAttr)/>"
        }
        ppr += "<w:jc w:val=\"\(p.align == .both ? "both" : p.align.rawValue)\"/>"
        // Paragraph mark size (also sizes the bullet).
        let markSize = Int((p.size * 2).rounded())
        ppr += "<w:rPr><w:sz w:val=\"\(markSize)\"/><w:szCs w:val=\"\(markSize)\"/></w:rPr>"

        var content = ""
        if let image = p.image {
            content = imageRun(image.png, size: image.size)
        } else if !p.isRuleOnly {
            content = runsXML(p)
        } else {
            ppr = ppr.replacingOccurrences(of: "<w:sz w:val=\"\(markSize)\"/><w:szCs w:val=\"\(markSize)\"/>", with: "<w:sz w:val=\"2\"/><w:szCs w:val=\"2\"/>")
        }
        return "<w:p><w:pPr>\(ppr)</w:pPr>\(content)</w:p>"
    }

    // MARK: Runs

    private struct RunStyle: Equatable {
        var face: FontMapper.Face
        var halfPoints: Int
        var color: String?
        var vert: String?
        var spacing: Int    // twentieths of a point per character
        var smallCaps: Bool
    }

    private enum Token { case text(String, RunStyle, URL?), tab(RunStyle) }

    private func runsXML(_ p: Paragraph) -> String {
        var tokens: [Token] = []
        var lastStyle: RunStyle?

        func style(_ c: StyledChar, line: Line) -> RunStyle {
            let face = fonts.face(for: c.run)
            let size = c.run?.size ?? line.size
            var vert: String? = nil
            if let r = c.run, r.size < line.size * 0.85 {
                if r.baseline > line.baseline + line.size * 0.2 { vert = "superscript" }
                else if r.baseline < line.baseline - line.size * 0.1 { vert = "subscript" }
            }
            // Word scales super/subscript itself, so keep the line size for those.
            let hp = Int(((vert == nil ? size : line.size) * 2).rounded())
            let track = Int((fonts.trackingPerEm(for: c.run) * size * 20).rounded())
            let caps = c.run.map { FontMapper.isSmallCaps($0.font) } ?? false
            return RunStyle(face: face, halfPoints: hp, color: c.run?.color, vert: vert, spacing: vert == nil && !caps ? track : 0, smallCaps: caps)
        }

        func append(_ s: String, _ st: RunStyle, _ link: URL?) {
            if case .text(let t, let pst, let pl)? = tokens.last, pst == st, pl == link {
                tokens[tokens.count - 1] = .text(t + s, st, link)
            } else {
                tokens.append(.text(s, st, link))
            }
            lastStyle = st
        }

        for (li, line) in p.lines.enumerated() {
            if li > 0 {
                // Re-join wrapped lines; drop the hyphen of a word split across lines.
                if case .text(let t, let st, let l)? = tokens.last, t.hasSuffix("-"), t.dropLast().last?.isLetter == true,
                   line.segments.first?.chars.first?.ch.first?.isLetter == true {
                    if shouldDehyphenate(t, line) { tokens[tokens.count - 1] = .text(String(t.dropLast()), st, l) }
                } else if let st = lastStyle {
                    append(" ", st, nil)
                }
            }
            for (si, seg) in line.segments.enumerated() {
                if si > 0, let st = lastStyle { tokens.append(.tab(st)) }
                for c in seg.chars {
                    if c.isSpace {
                        if let st = lastStyle { append(" ", st, c.link) }
                        continue
                    }
                    append(c.ch, style(c, line: line), c.link)
                }
            }
        }

        var xml = ""
        var i = 0
        while i < tokens.count {
            if case .text(_, _, let link?) = tokens[i] {
                var group = ""
                while i < tokens.count, case .text(let t, let st, let l) = tokens[i], l == link {
                    group += runXML(t, st, hyperlink: true)
                    i += 1
                }
                xml += "<w:hyperlink r:id=\"\(relID(forLink: link))\" w:history=\"1\">\(group)</w:hyperlink>"
                continue
            }
            switch tokens[i] {
            case .text(let t, let st, _): xml += runXML(t, st, hyperlink: false)
            case .tab(let st): xml += "<w:r>\(rPr(st))<w:tab/></w:r>"
            }
            i += 1
        }
        return xml
    }

    private func shouldDehyphenate(_ text: String, _ next: Line) -> Bool {
        let before = text.dropLast()
        guard let lastChar = before.last, lastChar.isLetter,
              let nextFirst = next.segments.first?.chars.first?.ch.first else { return false }
        // "Tensor-" + "Flow": a capital after a line-end hyphen is a split CamelCase word.
        if nextFirst.isUppercase { return true }
        // Keep real compounds ("real-time") — only join when the result is a known word.
        let head = before.split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
        let tail = String(next.segments.first?.chars.prefix(while: { $0.ch.first?.isLetter == true }).map(\.ch).joined() ?? "")
        let joined = head + tail
        guard !head.isEmpty, !tail.isEmpty else { return true }
        // NSSpellChecker belongs to the main thread; conversion runs in the background.
        func isWord(_ w: String) -> Bool {
            let check = { NSSpellChecker.shared.checkSpelling(of: w, startingAt: 0).location == NSNotFound }
            return Thread.isMainThread ? check() : DispatchQueue.main.sync(execute: check)
        }
        return isWord(joined) || !(isWord(head) && isWord(tail))
    }

    private func rPr(_ st: RunStyle) -> String {
        var s = "<w:rPr>"
        let f = escape(st.face.family)
        s += "<w:rFonts w:ascii=\"\(f)\" w:hAnsi=\"\(f)\" w:cs=\"\(f)\"/>"
        if st.face.bold { s += "<w:b/><w:bCs/>" }
        if st.face.italic { s += "<w:i/><w:iCs/>" }
        if st.smallCaps { s += "<w:smallCaps/>" }
        if let c = st.color { s += "<w:color w:val=\"\(c)\"/>" }
        if st.spacing != 0 { s += "<w:spacing w:val=\"\(st.spacing)\"/>" }
        s += "<w:sz w:val=\"\(st.halfPoints)\"/><w:szCs w:val=\"\(st.halfPoints)\"/>"
        if let v = st.vert { s += "<w:vertAlign w:val=\"\(v)\"/>" }
        return s + "</w:rPr>"
    }

    private func runXML(_ text: String, _ st: RunStyle, hyperlink: Bool) -> String {
        "<w:r>\(rPr(st))<w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r>"
    }

    private func imageRun(_ png: Data, size: CGSize) -> String {
        let n = media.count + 1
        let name = "image\(n).png"
        media.append((name, png))
        let rid = "rIdImg\(n)"
        rels.append((rid, "<Relationship Id=\"\(rid)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/\(name)\"/>"))
        let cx = Int(size.width * 12700), cy = Int(size.height * 12700)
        let id = drawingID
        drawingID += 1
        return """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(id)" name="Picture \(id)"/>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="\(id)" name="\(name)"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(rid)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    private var linkIDs: [URL: String] = [:]
    private func relID(forLink url: URL) -> String {
        if let id = linkIDs[url] { return id }
        let id = "rIdLink\(linkIDs.count + 1)"
        linkIDs[url] = id
        rels.append((id, "<Relationship Id=\"\(id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(escape(url.absoluteString))\" TargetMode=\"External\"/>"))
        return id
    }

    private func numId(for bullet: String) -> Int {
        if let n = bulletNums[bullet] { return n }
        let n = bulletNums.count + 1
        bulletNums[bullet] = n
        return n
    }

    private func escape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default:
                // XML 1.0 forbids most control characters.
                if ch.value < 0x20 && ch != "\t" && ch != "\n" && ch != "\r" { continue }
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    // MARK: Package parts

    private let ns = """
    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
    """

    private func documentXML(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(ns)><w:body>\(body)<w:sectPr><w:pgSz w:w="\(twips(pageSize.width))" w:h="\(twips(pageSize.height))"/>\
        <w:pgMar w:top="\(twips(marginTop))" w:right="\(twips(marginRight))" w:bottom="\(twips(marginBottom))" w:left="\(twips(marginLeft))" w:header="0" w:footer="0" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
    }

    private func stylesXML() -> String {
        let f = escape(fonts.defaultFamily)
        let hp = Int((fonts.defaultSize * 2).rounded())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="\(f)" w:hAnsi="\(f)" w:cs="\(f)" w:eastAsia="\(f)"/><w:sz w:val="\(hp)"/><w:szCs w:val="\(hp)"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:widowControl w:val="0"/><w:spacing w:before="0" w:after="0" w:line="240" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
        <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/></w:style>\
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/></w:style>\
        </w:styles>
        """
    }

    private func numberingXML() -> String {
        var abstract = "", nums = ""
        for (bullet, n) in bulletNums.sorted(by: { $0.value < $1.value }) {
            let glyph = ["-", "−", "–"].contains(bullet) ? "–" : (bullet == "*" || bullet == "∗" ? "∗" : bullet)
            abstract += """
            <w:abstractNum w:abstractNumId="\(n)"><w:multiLevelType w:val="hybridMultilevel"/>\
            <w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="\(escape(glyph))"/><w:lvlJc w:val="left"/>\
            <w:pPr><w:ind w:left="360" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/></w:rPr></w:lvl></w:abstractNum>
            """
            nums += "<w:num w:numId=\"\(n)\"><w:abstractNumId w:val=\"\(n)\"/></w:num>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(abstract)\(nums)</w:numbering>
        """
    }

    private let settingsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:autoHyphenation/><w:consecutiveHyphenLimit w:val="2"/><w:hyphenationZone w:val="140"/><w:defaultTabStop w:val="720"/><w:characterSpacingControl w:val="doNotCompress"/><w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
    """

    private func documentRels() -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rIdStyles" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rIdNumbering" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/>\
        <Relationship Id="rIdSettings" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings" Target="settings.xml"/>
        """
        for r in rels { xml += r.xml }
        return xml + "</Relationships>"
    }

    private func contentTypes() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
        </Types>
        """
    }

    private let rootRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
    </Relationships>
    """

    private let appXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>Satsuma</Application></Properties>
    """

    private func coreXML() -> String {
        let now = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """
    }
}
