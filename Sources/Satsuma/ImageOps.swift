import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ImageOps {
    static let typeForExt: [String: String] = [
        "jpg": "public.jpeg", "png": "public.png", "heic": "public.heic",
        "tiff": "public.tiff", "gif": "com.compuserve.gif", "bmp": "com.microsoft.bmp",
        "avif": "public.avif",
    ]

    static func canWrite(ext: String) -> Bool {
        guard let id = typeForExt[ext] else { return false }
        let writable = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return writable.contains(id)
    }

    /// Loads the first frame of any image ImageIO or NSImage can read (incl. SVG).
    static func load(_ url: URL) throws -> CGImage {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            return img
        }
        if let ns = NSImage(contentsOf: url) {
            var rect = CGRect(origin: .zero, size: CGSize(width: ns.size.width * 2, height: ns.size.height * 2))
            if let img = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return img }
        }
        throw ConversionError("Can't read image \(url.lastPathComponent)")
    }

    /// Applies EXIF orientation so rotations/flips start from what the user sees.
    static func loadOriented(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return try load(url) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
        ]
        if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
        return try load(url)
    }

    static func write(_ image: CGImage, to url: URL, ext: String, quality: Double = 0.9) throws {
        if ext == "webp" { return try writeWebP(image, to: url, quality: quality) }
        if ext == "pdf" { return try writePDF([image], to: url) }
        guard let type = typeForExt[ext],
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else {
            throw ConversionError("Can't write .\(ext)")
        }
        let img = (ext == "jpg" || ext == "bmp") ? flattened(image) : image
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError("Failed to save \(url.lastPathComponent)") }
    }

    static func writeWebP(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let cwebp = Tools.cwebp else { throw ConversionError("cwebp not found. Install with: brew install webp") }
        let tmp = Output.tempURL(ext: "png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try write(image, to: tmp, ext: "png")
        try Tools.run(cwebp, ["-quiet", "-q", String(Int(quality * 100)), tmp.path, "-o", url.path])
    }

    static func writePDF(_ images: [CGImage], to url: URL) throws {
        let doc = PDFDocument()
        for (i, img) in images.enumerated() {
            let ns = NSImage(cgImage: img, size: CGSize(width: img.width, height: img.height))
            if let page = PDFPage(image: ns) { doc.insert(page, at: i) }
        }
        guard doc.write(to: url) else { throw ConversionError("Failed to write PDF") }
    }

    /// Composites onto white; formats without alpha would otherwise turn transparency black.
    static func flattened(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// Extension to save a tool's result in: keep the source format when we can write it.
    static func outputExt(for url: URL) -> String {
        let ext = Catalog.normalizedExt(url.pathExtension)
        return (canWrite(ext: ext) || ext == "webp" && Tools.cwebp != nil) ? ext : "png"
    }

    // MARK: Operations

    static func convert(_ url: URL, to ext: String) throws -> URL {
        let out = Output.url(for: url, ext: ext)
        try write(try loadOriented(url), to: out, ext: ext)
        return out
    }

    static func compress(_ url: URL) throws -> URL {
        let out = Output.url(for: url, ext: "jpg", suffix: " (compressed)")
        try write(try loadOriented(url), to: out, ext: "jpg", quality: 0.6)
        return out
    }

    static func resizeHalf(_ url: URL) throws -> URL {
        let img = try loadOriented(url)
        let w = max(1, img.width / 2), h = max(1, img.height / 2)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError("Resize failed")
        }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let ext = outputExt(for: url)
        let out = Output.url(for: url, ext: ext, suffix: " (half)")
        try write(ctx.makeImage()!, to: out, ext: ext)
        return out
    }

    static func filtered(_ url: URL, suffix: String, _ transform: (CIImage) -> CIImage) throws -> URL {
        let ci = CIImage(cgImage: try loadOriented(url))
        let result = transform(ci)
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(result, from: result.extent) else { throw ConversionError("Image filter failed") }
        let ext = outputExt(for: url)
        let out = Output.url(for: url, ext: ext, suffix: suffix)
        try write(cg, to: out, ext: ext)
        return out
    }

    static func rotate(_ url: URL) throws -> URL {
        try filtered(url, suffix: " (rotated)") { $0.oriented(.right) }
    }

    static func flip(_ url: URL) throws -> URL {
        try filtered(url, suffix: " (flipped)") { $0.oriented(.upMirrored) }
    }

    static func grayscale(_ url: URL) throws -> URL {
        try filtered(url, suffix: " (gray)") { $0.applyingFilter("CIPhotoEffectMono") }
    }

    static func combineToPDF(_ urls: [URL]) throws -> URL {
        let images = try urls.map(loadOriented)
        let out = Output.unique(urls[0].deletingLastPathComponent().appendingPathComponent("Combined.pdf"))
        try writePDF(images, to: out)
        return out
    }
}
