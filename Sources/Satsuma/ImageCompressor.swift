import Compression
import CoreGraphics
import Foundation
import ImageIO

/// Format-preserving image compression.
///
/// - JPEG / HEIC / WebP: binary-search the lowest quality whose result still
///   matches the original (SSIM measured on full-resolution crops), then strip
///   metadata (and losslessly re-pack JPEGs with jpegtran when available).
/// - PNG: reduce to a ≤256-colour palette with dithering, keeping transparency;
///   falls back to lossless re-encoding when a palette would visibly hurt.
/// - The result is only kept when it is actually smaller than the original.
enum ImageCompressor {
    enum Level {
        case recommended, extreme
        var minSSIM: Double { self == .recommended ? 0.975 : 0.955 }
        var paletteSSIM: Double { self == .recommended ? 0.965 : 0.945 }
        var paletteColors: Int { self == .recommended ? 256 : 128 }
    }

    struct Result { let url: URL; let before: Int; let after: Int }

    static func compress(_ url: URL, level: Level) throws -> Result {
        let before = fileSize(url)
        let ext = Catalog.normalizedExt(url.pathExtension)
        let image = try ImageOps.loadOriented(url)

        let data: Data
        switch ext {
        case "jpg":
            data = try searchQuality(image, level: level) { try encode($0, type: "public.jpeg", quality: $1) }
            let packed = losslessJPEGRepack(data)
            return try finish(url, ext: ext, data: packed.count < data.count ? packed : data, before: before)
        case "heic":
            data = try searchQuality(image, level: level) { try encode($0, type: "public.heic", quality: $1) }
        case "webp":
            data = try searchQuality(image, level: level) { try webp($0, quality: $1) }
        case "png":
            data = try compressPNG(image, level: level)
        case "tiff":
            data = try encode(image, type: "public.tiff", quality: 1, tiffLZW: true)
        default:
            throw ConversionError("Compress works on JPG, PNG, HEIC, WebP and TIFF. Convert .\(ext) first.")
        }
        return try finish(url, ext: ext, data: data, before: before)
    }

    private static func finish(_ url: URL, ext: String, data: Data, before: Int) throws -> Result {
        guard data.count < before else {
            throw ConversionError("\(url.lastPathComponent) is already optimized")
        }
        let out = Output.url(for: url, ext: url.pathExtension.isEmpty ? ext : url.pathExtension, suffix: " (compressed)")
        try data.write(to: out)
        return Result(url: out, before: before, after: data.count)
    }

    static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: Lossy formats

    /// Smallest encoding whose SSIM against the original stays above the target.
    private static func searchQuality(_ image: CGImage, level: Level, encoder: (CGImage, Double) throws -> Data) throws -> Data {
        let reference = Crops(image)
        var lo = 0.30, hi = 0.92
        var best = try encoder(image, hi)
        for _ in 0..<6 {
            let q = (lo + hi) / 2
            let candidate = try encoder(image, q)
            guard let decoded = decode(candidate) else { break }
            if reference.ssim(against: decoded) >= level.minSSIM {
                best = candidate
                hi = q
            } else {
                lo = q
            }
        }
        return best
    }

    private static func encode(_ image: CGImage, type: String, quality: Double, tiffLZW: Bool = false) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
            throw ConversionError("Can't encode \(type)")
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if type == "public.jpeg" {
            props[kCGImagePropertyJFIFDictionary] = [kCGImagePropertyJFIFIsProgressive: true]
        }
        if tiffLZW { props[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFCompression: 5] }
        let img = type == "public.jpeg" ? ImageOps.flattened(image) : image
        // Only pixels are written: EXIF, GPS and other metadata are dropped.
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError("Encoding failed") }
        return data as Data
    }

    private static func webp(_ image: CGImage, quality: Double) throws -> Data {
        guard let cwebp = Tools.cwebp else { throw ConversionError("cwebp not found. Install with: brew install webp") }
        let src = Output.tempURL(ext: "png"), dst = Output.tempURL(ext: "webp")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        try encode(image, type: "public.png", quality: 1).write(to: src)
        try Tools.run(cwebp, ["-quiet", "-m", "6", "-metadata", "none", "-q", String(Int(quality * 100)), src.path, "-o", dst.path])
        return try Data(contentsOf: dst)
    }

    /// Optimized Huffman tables + progressive scan; pixels are untouched.
    private static func losslessJPEGRepack(_ data: Data) -> Data {
        guard let jpegtran = Tools.find("jpegtran") else { return data }
        let src = Output.tempURL(ext: "jpg"), dst = Output.tempURL(ext: "jpg")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: dst) }
        do {
            try data.write(to: src)
            try Tools.run(jpegtran, ["-copy", "none", "-optimize", "-progressive", "-outfile", dst.path, src.path])
            return try Data(contentsOf: dst)
        } catch {
            return data
        }
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: PNG

    private static func compressPNG(_ image: CGImage, level: Level) throws -> Data {
        let pixels = RGBAImage(image)
        let lossless = try encode(image, type: "public.png", quality: 1)

        let palette = Quantizer.palette(for: pixels, maxColors: level.paletteColors)
        let indices = Quantizer.remap(pixels, palette: palette, dither: true)
        let quantized = PNGWriter.indexed(width: pixels.width, height: pixels.height, palette: palette, indices: indices)

        // Check the palette version still looks like the original.
        if let decoded = decode(quantized) {
            let score = Crops(image).ssim(against: decoded, smooth: true)
            if ProcessInfo.processInfo.environment["SATSUMA_DEBUG"] != nil {
                print("palette ssim", score, "size", quantized.count, "lossless", lossless.count)
            }
            if score >= level.paletteSSIM && quantized.count < lossless.count { return quantized }
        }
        return lossless
    }
}

// MARK: - Similarity

/// SSIM on luminance, computed on full-resolution crops so compression
/// artefacts are not hidden by downscaling.
struct Crops {
    private let rects: [CGRect]
    private let reference: [[Float]]
    private static let side = 384

    init(_ image: CGImage) {
        let w = image.width, h = image.height, s = Crops.side
        var rects: [CGRect] = []
        if w <= s * 2 && h <= s * 2 {
            rects = [CGRect(x: 0, y: 0, width: w, height: h)]
        } else {
            // Five crops: centre and the four "rule of thirds" points.
            for (fx, fy) in [(0.5, 0.5), (0.33, 0.33), (0.67, 0.33), (0.33, 0.67), (0.67, 0.67)] {
                let cw = min(s, w), ch = min(s, h)
                let x = min(max(0, Int(Double(w) * fx) - cw / 2), w - cw)
                let y = min(max(0, Int(Double(h) * fy) - ch / 2), h - ch)
                rects.append(CGRect(x: x, y: y, width: cw, height: ch))
            }
        }
        self.rects = rects
        reference = rects.map { Crops.luma(image, $0) }
    }

    /// `smooth` compares 3×3-blurred pixels: dithering is meant to be averaged by the eye.
    func ssim(against other: CGImage, smooth: Bool = false) -> Double {
        var total = 0.0
        for (i, r) in rects.enumerated() {
            let w = Int(r.width), h = Int(r.height)
            var a = reference[i], b = Crops.luma(other, r)
            if smooth { a = Crops.blur(a, w, h); b = Crops.blur(b, w, h) }
            total += Crops.ssim(a, b, width: w, height: h)
        }
        return total / Double(rects.count)
    }

    private static func blur(_ p: [Float], _ w: Int, _ h: Int) -> [Float] {
        var out = p
        guard w > 2, h > 2 else { return p }
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                var s: Float = 0
                for dy in -1...1 { for dx in -1...1 { s += p[(y + dy) * w + x + dx] } }
                out[y * w + x] = s / 9
            }
        }
        return out
    }

    /// Grayscale pixels of a crop, transparency composited over mid-grey so alpha changes count.
    private static func luma(_ image: CGImage, _ r: CGRect) -> [Float] {
        let w = Int(r.width), h = Int(r.height)
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { ptr in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.setFillColor(gray: 0.5, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // Draw the full image offset so the crop lands in the buffer (bitmap y runs bottom-up).
            ctx.draw(image, in: CGRect(x: -r.minX, y: -(CGFloat(image.height) - r.maxY), width: CGFloat(image.width), height: CGFloat(image.height)))
        }
        return buf.map(Float.init)
    }

    private static func ssim(_ a: [Float], _ b: [Float], width: Int, height: Int) -> Double {
        let win = 8, step = 4
        let c1: Float = 6.5025, c2: Float = 58.5225   // (0.01·255)², (0.03·255)²
        var sum = 0.0, count = 0
        var y = 0
        while y + win <= height {
            var x = 0
            while x + win <= width {
                var ma: Float = 0, mb: Float = 0
                for j in 0..<win { for i in 0..<win { let k = (y + j) * width + x + i; ma += a[k]; mb += b[k] } }
                let n = Float(win * win)
                ma /= n; mb /= n
                var va: Float = 0, vb: Float = 0, cov: Float = 0
                for j in 0..<win {
                    for i in 0..<win {
                        let k = (y + j) * width + x + i
                        let da = a[k] - ma, db = b[k] - mb
                        va += da * da; vb += db * db; cov += da * db
                    }
                }
                va /= n - 1; vb /= n - 1; cov /= n - 1
                let s = ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                sum += Double(s)
                count += 1
                x += step
            }
            y += step
        }
        return count == 0 ? 1 : sum / Double(count)
    }
}

// MARK: - Palette quantization

/// Straight (non-premultiplied) RGBA pixels.
struct RGBAImage {
    let width: Int, height: Int
    var data: [UInt8]

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        width = w; height = h
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        buf.withUnsafeMutableBytes { ptr in
            let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Un-premultiply.
        for i in stride(from: 0, to: buf.count, by: 4) {
            let a = Int(buf[i + 3])
            if a > 0 && a < 255 {
                for c in 0..<3 { buf[i + c] = UInt8(min(255, (Int(buf[i + c]) * 255 + a / 2) / a)) }
            }
        }
        data = buf
    }
}

enum Quantizer {
    typealias Color = (r: Float, g: Float, b: Float, a: Float)

    /// Median cut on a pixel sample, refined with a few k-means passes.
    static func palette(for img: RGBAImage, maxColors: Int) -> [[UInt8]] {
        let total = img.width * img.height
        let stride = max(1, total / 120_000)
        var samples: [Color] = []
        samples.reserveCapacity(total / stride + 1)
        var unique = Set<UInt32>()
        var i = 0
        while i < total {
            let p = i * 4
            let a = img.data[p + 3]
            // Fully transparent pixels collapse to one colour.
            let c: Color = a == 0 ? (0, 0, 0, 0) : (Float(img.data[p]), Float(img.data[p + 1]), Float(img.data[p + 2]), Float(a))
            samples.append(c)
            if unique.count <= maxColors {
                unique.insert(UInt32(img.data[p]) << 24 | UInt32(img.data[p + 1]) << 16 | UInt32(img.data[p + 2]) << 8 | UInt32(a))
            }
            i += stride
        }

        // Few enough distinct colours (and sampled densely): use them exactly.
        if unique.count <= maxColors && stride == 1 {
            return unique.map { v in [UInt8(v >> 24), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        }

        struct Box {
            var colors: [Color]
            var channel = 0
            var score: Float = 0
            init(_ colors: [Color]) {
                self.colors = colors
                guard colors.count > 1 else { return }
                var lo: (Float, Float, Float, Float) = (255, 255, 255, 255), hi: (Float, Float, Float, Float) = (0, 0, 0, 0)
                for c in colors {
                    lo = (min(lo.0, c.r), min(lo.1, c.g), min(lo.2, c.b), min(lo.3, c.a))
                    hi = (max(hi.0, c.r), max(hi.1, c.g), max(hi.2, c.b), max(hi.3, c.a))
                }
                // Perceptual-ish weights: green and alpha differences matter most.
                let ranges = [(hi.0 - lo.0) * 1.0, (hi.1 - lo.1) * 1.2, (hi.2 - lo.2) * 0.8, (hi.3 - lo.3) * 1.5]
                let k = ranges.indices.max { ranges[$0] < ranges[$1] }!
                channel = k
                score = ranges[k] * Float(colors.count).squareRoot()
            }
        }
        func component(_ c: Color, _ k: Int) -> Float { k == 0 ? c.r : k == 1 ? c.g : k == 2 ? c.b : c.a }

        var boxes = [Box(samples)]
        while boxes.count < maxColors {
            guard let bi = boxes.indices.max(by: { boxes[$0].score < boxes[$1].score }), boxes[bi].score > 0 else { break }
            let box = boxes.remove(at: bi)
            let k = box.channel
            let sortedColors = box.colors.sorted { component($0, k) < component($1, k) }
            let mid = sortedColors.count / 2
            boxes.append(Box(Array(sortedColors[..<mid])))
            boxes.append(Box(Array(sortedColors[mid...])))
        }

        var centers: [Color] = boxes.map { mean($0.colors) }
        // k-means refinement.
        for _ in 0..<4 {
            var sums = [(Float, Float, Float, Float, Float)](repeating: (0, 0, 0, 0, 0), count: centers.count)
            for c in samples {
                let k = nearest(c, centers)
                sums[k].0 += c.r; sums[k].1 += c.g; sums[k].2 += c.b; sums[k].3 += c.a; sums[k].4 += 1
            }
            for k in centers.indices where sums[k].4 > 0 {
                let n = sums[k].4
                centers[k] = (sums[k].0 / n, sums[k].1 / n, sums[k].2 / n, sums[k].3 / n)
            }
        }
        return centers.map { [clamp($0.r), clamp($0.g), clamp($0.b), clamp($0.a)] }
    }

    private static func mean(_ box: [Color]) -> Color {
        var r: Float = 0, g: Float = 0, b: Float = 0, a: Float = 0
        for c in box { r += c.r; g += c.g; b += c.b; a += c.a }
        let n = Float(max(1, box.count))
        return (r / n, g / n, b / n, a / n)
    }

    private static func clamp(_ v: Float) -> UInt8 { UInt8(min(255, max(0, v.rounded()))) }

    private static func distance(_ a: Color, _ b: Color) -> Float {
        let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b, da = a.a - b.a
        return dr * dr + dg * dg * 1.4 + db * db * 0.7 + da * da * 2
    }

    private static func nearest(_ c: Color, _ centers: [Color]) -> Int {
        var best = 0, bestD = Float.greatestFiniteMagnitude
        for (k, p) in centers.enumerated() {
            let d = distance(c, p)
            if d < bestD { bestD = d; best = k }
        }
        return best
    }

    /// Maps pixels to palette indices with damped Floyd–Steinberg dithering.
    static func remap(_ img: RGBAImage, palette: [[UInt8]], dither: Bool) -> [UInt8] {
        let w = img.width, h = img.height
        let centers: [Color] = palette.map { (Float($0[0]), Float($0[1]), Float($0[2]), Float($0[3])) }
        var out = [UInt8](repeating: 0, count: w * h)
        // Cache nearest-colour lookups on a 5-bit-per-channel grid.
        var cache = [Int16](repeating: -1, count: 1 << 20)
        var errCur = [Float](repeating: 0, count: (w + 2) * 4)
        var errNext = [Float](repeating: 0, count: (w + 2) * 4)
        let strength: Float = dither ? 0.8 : 0

        for y in 0..<h {
            for x in 0..<w {
                let p = (y * w + x) * 4
                let e = (x + 1) * 4
                var c: Color = (Float(img.data[p]) + errCur[e], Float(img.data[p + 1]) + errCur[e + 1],
                                Float(img.data[p + 2]) + errCur[e + 2], Float(img.data[p + 3]) + errCur[e + 3])
                c = (min(255, max(0, c.r)), min(255, max(0, c.g)), min(255, max(0, c.b)), min(255, max(0, c.a)))
                if img.data[p + 3] == 0 { c = (0, 0, 0, 0) }
                let kr = (Int(c.r) >> 3) << 15, kg = (Int(c.g) >> 3) << 10
                let key = kr | kg | (Int(c.b) >> 3) << 5 | Int(c.a) >> 3
                var idx = Int(cache[key])
                if idx < 0 { idx = nearest(c, centers); cache[key] = Int16(idx) }
                out[y * w + x] = UInt8(idx)

                guard strength > 0 else { continue }
                let q = centers[idx]
                let err = [(c.r - q.r) * strength, (c.g - q.g) * strength, (c.b - q.b) * strength, (c.a - q.a) * strength]
                for k in 0..<4 {
                    errCur[e + 4 + k] += err[k] * 7 / 16
                    errNext[e - 4 + k] += err[k] * 3 / 16
                    errNext[e + k] += err[k] * 5 / 16
                    errNext[e + 4 + k] += err[k] * 1 / 16
                }
            }
            swap(&errCur, &errNext)
            for i in errNext.indices { errNext[i] = 0 }
        }
        return out
    }
}

// MARK: - Indexed PNG writer

enum PNGWriter {
    /// Palette PNG with optional transparency (tRNS) and the smallest bit depth that fits.
    static func indexed(width: Int, height: Int, palette: [[UInt8]], indices: [UInt8]) -> Data {
        // Opaque entries last lets tRNS stop early; reorder so translucent colours come first.
        let order = palette.indices.sorted { palette[$0][3] < palette[$1][3] }
        var remap = [UInt8](repeating: 0, count: palette.count)
        for (newIndex, old) in order.enumerated() { remap[old] = UInt8(newIndex) }
        let sorted = order.map { palette[$0] }

        let depth = palette.count <= 2 ? 1 : palette.count <= 4 ? 2 : palette.count <= 16 ? 4 : 8
        let perByte = 8 / depth
        let rowBytes = (width + perByte - 1) / perByte

        var raw = [UInt8]()
        raw.reserveCapacity((rowBytes + 1) * height)
        for y in 0..<height {
            raw.append(0)   // filter: none (best for palette images)
            var byte: UInt8 = 0, filled = 0
            for x in 0..<width {
                byte = byte << depth | remap[Int(indices[y * width + x])]
                filled += 1
                if filled == perByte { raw.append(byte); byte = 0; filled = 0 }
            }
            if filled > 0 { raw.append(byte << (depth * (perByte - filled))) }
        }

        var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var ihdr = Data()
        ihdr.append(be32(width)); ihdr.append(be32(height))
        ihdr.append(contentsOf: [UInt8(depth), 3, 0, 0, 0])   // colour type 3 = palette
        chunk("IHDR", ihdr, into: &png)
        chunk("PLTE", Data(sorted.flatMap { $0[0..<3] }), into: &png)
        let alphas = sorted.map { $0[3] }
        if let lastTranslucent = alphas.lastIndex(where: { $0 < 255 }) {
            chunk("tRNS", Data(alphas[...lastTranslucent]), into: &png)
        }
        chunk("IDAT", zlib(raw), into: &png)
        chunk("IEND", Data(), into: &png)
        return png
    }

    private static func be32(_ v: Int) -> Data {
        Data([UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)])
    }

    private static func chunk(_ type: String, _ body: Data, into png: inout Data) {
        png.append(be32(body.count))
        var typed = Data(type.utf8)
        typed.append(body)
        png.append(typed)
        png.append(be32(Int(crc32(typed))))
    }

    /// zlib stream = 2-byte header + raw DEFLATE + Adler-32.
    private static func zlib(_ bytes: [UInt8]) -> Data {
        let capacity = bytes.count + bytes.count / 10 + 1024
        var dst = [UInt8](repeating: 0, count: capacity)
        let n = compression_encode_buffer(&dst, capacity, bytes, bytes.count, nil, COMPRESSION_ZLIB)
        var out = Data([0x78, 0xDA])
        out.append(contentsOf: dst[0..<n])
        var a: UInt32 = 1, b: UInt32 = 0
        for chunkStart in stride(from: 0, to: bytes.count, by: 5552) {
            for v in bytes[chunkStart..<min(bytes.count, chunkStart + 5552)] { a += UInt32(v); b += a }
            a %= 65521; b %= 65521
        }
        out.append(be32(Int(b << 16 | a)))
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
