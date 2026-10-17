import AppKit
import PDFKit

enum PDFOps {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ConversionError("Can't open PDF \(url.lastPathComponent)") }
        return doc
    }

    /// Renders every page at 300 DPI. One page -> one file; many -> a folder.
    static func toImages(_ url: URL, ext: String) throws -> URL {
        let doc = try open(url)
        let count = doc.pageCount
        guard count > 0 else { throw ConversionError("PDF has no pages") }
        let base = url.deletingPathExtension().lastPathComponent
        var outDir = url.deletingLastPathComponent()
        if count > 1 {
            outDir = Output.unique(outDir.appendingPathComponent("\(base) pages"))
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        }
        for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            let img = try render(page, dpi: 300)
            let name = count > 1 ? "\(base) \(i + 1)" : base
            let out = Output.unique(outDir.appendingPathComponent(name).appendingPathExtension(ext))
            try ImageOps.write(img, to: out, ext: ext)
        }
        return count > 1 ? outDir : Output.url(for: url, ext: ext)
    }

    static func render(_ page: PDFPage, dpi: CGFloat) throws -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = rotated ? CGSize(width: box.height, height: box.width) : box.size
        var scale = dpi / 72
        // Keep huge pages from allocating gigabytes.
        let maxSide: CGFloat = 12000
        scale = min(scale, maxSide / max(size.width, size.height, 1))
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError("Page too large to render")
        }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let img = ctx.makeImage() else { throw ConversionError("Render failed") }
        return img
    }

    static func attributedText(_ url: URL) throws -> NSAttributedString {
        let doc = try open(url)
        let result = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            if let s = doc.page(at: i)?.attributedString {
                if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
                result.append(s)
            }
        }
        return result
    }

    static func compress(_ url: URL) throws -> URL {
        let doc = try open(url)
        let out = Output.url(for: url, ext: "pdf", suffix: " (compressed)")
        var options: [PDFDocumentWriteOption: Any] = [:]
        if #available(macOS 13.4, *) {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
        }
        guard doc.write(to: out, withOptions: options) else { throw ConversionError("Failed to write PDF") }
        return out
    }

    static func split(_ url: URL) throws -> URL {
        let doc = try open(url)
        let base = url.deletingPathExtension().lastPathComponent
        let dir = Output.unique(url.deletingLastPathComponent().appendingPathComponent("\(base) split"))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
            let single = PDFDocument()
            single.insert(page, at: 0)
            single.write(to: dir.appendingPathComponent("\(base) \(i + 1).pdf"))
        }
        return dir
    }

    static func rotate(_ url: URL) throws -> URL {
        let doc = try open(url)
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i) { page.rotation = (page.rotation + 90) % 360 }
        }
        let out = Output.url(for: url, ext: "pdf", suffix: " (rotated)")
        guard doc.write(to: out) else { throw ConversionError("Failed to write PDF") }
        return out
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let merged = PDFDocument()
        for url in urls {
            let doc = try open(url)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { merged.insert(page, at: merged.pageCount) }
            }
        }
        let out = Output.unique(urls[0].deletingLastPathComponent().appendingPathComponent("Merged.pdf"))
        guard merged.write(to: out) else { throw ConversionError("Failed to write PDF") }
        return out
    }
}

/// Rich-text documents. AppKit's HTML importer needs the main thread, so these run there.
enum DocOps {
    static func read(_ url: URL, category: FileCategory) throws -> NSAttributedString {
        switch category {
        case .markdown:
            let md = try String(contentsOf: url, encoding: .utf8)
            return try fromHTML(Markdown.toHTML(md, title: url.deletingPathExtension().lastPathComponent))
        case .pdf:
            return try PDFOps.attributedText(url)
        default:
            if url.pathExtension.lowercased() == "txt" {
                let text: String
                if let utf8 = try? String(contentsOf: url, encoding: .utf8) { text = utf8 }
                else { text = try String(contentsOf: url, encoding: .isoLatin1) }
                return NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
            }
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
        }
    }

    static func fromHTML(_ html: String) throws -> NSAttributedString {
        try NSAttributedString(data: Data(html.utf8),
                               options: [.documentType: NSAttributedString.DocumentType.html,
                                         .characterEncoding: String.Encoding.utf8.rawValue],
                               documentAttributes: nil)
    }

    static func convert(_ url: URL, to ext: String, category: FileCategory) throws -> URL {
        let out = Output.url(for: url, ext: ext)

        // Markdown -> HTML is better done directly than through AppKit's HTML export.
        if category == .markdown && ext == "html" {
            let md = try String(contentsOf: url, encoding: .utf8)
            try Markdown.toHTML(md, title: url.deletingPathExtension().lastPathComponent)
                .write(to: out, atomically: true, encoding: .utf8)
            return out
        }

        if category == .pdf && ext == "docx" {
            try PDFToWord.convert(url, to: out)
            return out
        }

        let text = try read(url, category: category)
        switch ext {
        case "txt", "md":
            try text.string.write(to: out, atomically: true, encoding: .utf8)
        case "pdf":
            try writePDF(text, to: out)
        default:
            let types: [String: NSAttributedString.DocumentType] = [
                "docx": .officeOpenXML, "rtf": .rtf, "html": .html, "odt": .openDocument, "doc": .docFormat,
            ]
            guard let type = types[ext] else { throw ConversionError("Can't write .\(ext)") }
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: type])
            try data.write(to: out)
        }
        return out
    }

    /// Lays text out on US Letter pages with 1" margins.
    static func writePDF(_ text: NSAttributedString, to url: URL) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 72
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { throw ConversionError("Can't create PDF") }

        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let containerSize = CGSize(width: mediaBox.width - margin * 2, height: mediaBox.height - margin * 2)

        var containers: [NSTextContainer] = []
        repeat {
            let c = NSTextContainer(size: containerSize)
            c.lineFragmentPadding = 0
            layout.addTextContainer(c)
            containers.append(c)
            _ = layout.glyphRange(for: c)
        } while NSMaxRange(layout.glyphRange(for: containers.last!)) < layout.numberOfGlyphs && containers.count < 5000

        for c in containers {
            ctx.beginPDFPage(nil)
            // AppKit text draws top-down, so flip the page coordinates.
            ctx.translateBy(x: 0, y: mediaBox.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            let range = layout.glyphRange(for: c)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

enum TableOps {
    static func parse(_ text: String, separator: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false
        var chars = Array(text).makeIterator()
        var pending: Character? = nil
        while let c = pending ?? chars.next() {
            pending = nil
            if inQuotes {
                if c == "\"" {
                    if let n = chars.next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == separator {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func convert(_ url: URL, to ext: String) throws -> URL {
        let text = try String(contentsOf: url, encoding: .utf8)
        let rows = parse(text, separator: url.pathExtension.lowercased() == "tsv" ? "\t" : ",")
        let out = Output.url(for: url, ext: ext)
        let result: String
        switch ext {
        case "csv":
            result = rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n") + "\n"
        case "tsv":
            result = rows.map { $0.map { $0.replacingOccurrences(of: "\t", with: " ") }.joined(separator: "\t") }
                .joined(separator: "\n") + "\n"
        case "json":
            guard let header = rows.first else { throw ConversionError("Empty table") }
            let objects = rows.dropFirst().map { row in
                Dictionary(uniqueKeysWithValues: header.enumerated().map { i, key in (key, i < row.count ? row[i] : "") })
            }
            let data = try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
            result = String(decoding: data, as: UTF8.self)
        case "html":
            let esc = Markdown.escape
            var html = "<!doctype html><meta charset=utf-8><table border=1 cellpadding=4 style=\"border-collapse:collapse;font-family:-apple-system\">\n"
            for (i, row) in rows.enumerated() {
                let tag = i == 0 ? "th" : "td"
                html += "<tr>" + row.map { "<\(tag)>\(esc($0))</\(tag)>" }.joined() + "</tr>\n"
            }
            result = html + "</table>\n"
        default:
            throw ConversionError("Can't write .\(ext)")
        }
        try result.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func csvField(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" })
            ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            : s
    }
}

/// Small Markdown -> HTML converter: headings, lists, quotes, code, emphasis, links, images.
enum Markdown {
    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func inline(_ s: String) -> String {
        var t = escape(s)
        let rules: [(String, String)] = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"!\[([^\]]*)\]\(([^)\s]+)\)"#, "<img alt=\"$1\" src=\"$2\">"),
            (#"\[([^\]]+)\]\(([^)\s]+)\)"#, "<a href=\"$2\">$1</a>"),
            (#"\*\*([^*]+)\*\*"#, "<strong>$1</strong>"),
            (#"__([^_]+)__"#, "<strong>$1</strong>"),
            (#"(?<![*\w])\*([^*]+)\*(?!\*)"#, "<em>$1</em>"),
            (#"(?<![_\w])_([^_]+)_(?![_\w])"#, "<em>$1</em>"),
            (#"~~([^~]+)~~"#, "<del>$1</del>"),
        ]
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return t
    }

    static func toHTML(_ md: String, title: String) -> String {
        var html: [String] = []
        var paragraph: [String] = []
        var listTag: String? = nil
        var inCode = false
        var code: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { html.append("<p>" + paragraph.map(inline).joined(separator: " ") + "</p>") }
            paragraph = []
        }
        func closeList() {
            if let tag = listTag { html.append("</\(tag)>"); listTag = nil }
        }

        for rawLine in md.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    html.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>")
                    code = []; inCode = false
                } else { flushParagraph(); closeList(); inCode = true }
                continue
            }
            if inCode { code.append(rawLine); continue }
            if line.isEmpty { flushParagraph(); closeList(); continue }

            if let m = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flushParagraph(); closeList()
                let level = line[m].count - 1
                html.append("<h\(level)>\(inline(String(line[m.upperBound...])))</h\(level)>")
            } else if line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flushParagraph(); closeList(); html.append("<hr>")
            } else if line.hasPrefix(">") {
                flushParagraph(); closeList()
                html.append("<blockquote>" + inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)) + "</blockquote>")
            } else if let m = line.range(of: #"^([-*+]|\d+[.)]) "#, options: .regularExpression) {
                flushParagraph()
                let tag = line.first!.isNumber ? "ol" : "ul"
                if listTag != tag { closeList(); html.append("<\(tag)>"); listTag = tag }
                html.append("<li>" + inline(String(line[m.upperBound...])) + "</li>")
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        if inCode { html.append("<pre><code>" + escape(code.joined(separator: "\n")) + "</code></pre>") }
        flushParagraph(); closeList()

        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>body{font-family:"Helvetica Neue",Helvetica,Arial,sans-serif;max-width:720px;margin:40px auto;padding:0 16px;line-height:1.5}
        pre{background:#f4f4f4;padding:12px;overflow:auto}code{font-family:Menlo,monospace}
        blockquote{border-left:3px solid #ccc;margin-left:0;padding-left:12px;color:#555}</style>
        </head><body>
        \(html.joined(separator: "\n"))
        </body></html>
        """
    }
}
