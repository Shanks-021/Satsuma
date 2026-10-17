import Foundation
import UniformTypeIdentifiers

/// The three wheels, each opened by its own modifier key while dragging.
enum WheelKind: String, CaseIterable {
    case convert, tools, actions

    var title: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "Tools"
        case .actions: return "Actions"
        }
    }

    var next: WheelKind {
        let all = WheelKind.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

enum FileCategory {
    case image, video, audio, pdf, document, markdown, table, archive, other
}

enum Tool {
    case compress, compressMax, resizeHalf, rotate, flip, grayscale, combinePDF
    case scale720, mute, firstFrame
    case normalize, mono, reverse
    case mergePDF, splitPDF, rotatePDF
    case zip, unarchive
}

enum Action {
    case airdrop, float, copy, copyPath, terminal, moveTo, copyTo, trash
}

enum Operation {
    case convert(String)   // target file extension
    case tool(Tool)
    case action(Action)
}

struct WheelOption {
    let title: String
    let symbol: String
    let op: Operation
}

func category(of url: URL) -> FileCategory {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
        return .other
    }
    let ext = url.pathExtension.lowercased()
    let name = url.lastPathComponent.lowercased()
    if ["md", "markdown"].contains(ext) { return .markdown }
    if ["csv", "tsv"].contains(ext) { return .table }
    if ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z"].contains(ext) || name.hasSuffix(".tar.gz") { return .archive }
    if ["rtf", "rtfd", "doc", "docx", "odt", "pages", "txt", "html", "htm", "webarchive", "textclipping"].contains(ext) { return .document }
    guard let type = UTType(filenameExtension: ext) else { return .other }
    if type.conforms(to: .pdf) { return .pdf }
    if type.conforms(to: .image) { return .image }
    if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
    if type.conforms(to: .audio) { return .audio }
    if type.conforms(to: .plainText) || type.conforms(to: .text) { return .document }
    return .other
}

/// One category shared by all files, or `.other` when the selection is mixed.
func commonCategory(of urls: [URL]) -> FileCategory {
    let cats = urls.map(category(of:))
    guard let first = cats.first, cats.allSatisfy({ $0 == first }) else { return .other }
    return first
}

enum Catalog {
    static func options(for kind: WheelKind, urls: [URL]) -> [WheelOption] {
        guard !urls.isEmpty else { return [] }
        let cat = commonCategory(of: urls)
        let currentExts = Set(urls.map { normalizedExt($0.pathExtension) })
        let ff = Tools.ffmpeg != nil

        switch kind {
        case .convert:
            var exts: [String]
            switch cat {
            case .image:
                exts = ["jpg", "png", "heic", "tiff", "gif", "bmp"]
                if ImageOps.canWrite(ext: "avif") { exts.append("avif") }
                if Tools.cwebp != nil { exts.append("webp") }
                exts.append("pdf")
            case .video: exts = ff ? ["mp4", "mov", "mkv", "webm", "gif", "mp3", "m4a"] : []
            case .audio: exts = ff ? ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"] : []
            case .pdf: exts = ["png", "jpg", "txt", "docx", "rtf", "html", "md"]
            case .document: exts = ["pdf", "docx", "rtf", "txt", "html", "odt", "md"]
            case .markdown: exts = ["html", "pdf", "docx", "rtf", "txt"]
            case .table: exts = ["csv", "tsv", "json", "html"]
            case .archive, .other: exts = []
            }
            return exts
                .filter { !currentExts.contains($0) }
                .map { WheelOption(title: $0.uppercased(), symbol: symbol(forExt: $0), op: .convert($0)) }

        case .tools:
            var list: [WheelOption] = []
            switch cat {
            case .image:
                list += [
                    .init(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", op: .tool(.compress)),
                    .init(title: "Max Compress", symbol: "arrow.down.to.line.compact", op: .tool(.compressMax)),
                    .init(title: "Half Size", symbol: "square.resize.down", op: .tool(.resizeHalf)),
                    .init(title: "Rotate", symbol: "rotate.right", op: .tool(.rotate)),
                    .init(title: "Flip", symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", op: .tool(.flip)),
                    .init(title: "Grayscale", symbol: "circle.lefthalf.filled", op: .tool(.grayscale)),
                ]
                if urls.count > 1 {
                    list.append(.init(title: "To One PDF", symbol: "doc.on.doc", op: .tool(.combinePDF)))
                }
            case .video where ff:
                list += [
                    .init(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", op: .tool(.compress)),
                    .init(title: "720p", symbol: "square.resize.down", op: .tool(.scale720)),
                    .init(title: "Mute", symbol: "speaker.slash", op: .tool(.mute)),
                    .init(title: "Rotate", symbol: "rotate.right", op: .tool(.rotate)),
                    .init(title: "Frame", symbol: "photo", op: .tool(.firstFrame)),
                ]
            case .audio where ff:
                list += [
                    .init(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", op: .tool(.compress)),
                    .init(title: "Normalize", symbol: "waveform", op: .tool(.normalize)),
                    .init(title: "Mono", symbol: "speaker.wave.1", op: .tool(.mono)),
                    .init(title: "Reverse", symbol: "backward", op: .tool(.reverse)),
                ]
            case .pdf:
                list += [
                    .init(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", op: .tool(.compress)),
                    .init(title: "Split", symbol: "rectangle.split.3x1", op: .tool(.splitPDF)),
                    .init(title: "Rotate", symbol: "rotate.right", op: .tool(.rotatePDF)),
                ]
                if urls.count > 1 {
                    list.append(.init(title: "Merge", symbol: "doc.on.doc", op: .tool(.mergePDF)))
                }
            case .archive:
                list.append(.init(title: "Extract", symbol: "shippingbox.and.arrow.backward", op: .tool(.unarchive)))
            default: break
            }
            if cat != .archive {
                list.append(.init(title: "ZIP", symbol: "doc.zipper", op: .tool(.zip)))
            }
            return list

        case .actions:
            return [
                .init(title: "AirDrop", symbol: "airplayaudio", op: .action(.airdrop)),
                .init(title: "Float", symbol: "pin", op: .action(.float)),
                .init(title: "Copy", symbol: "doc.on.clipboard", op: .action(.copy)),
                .init(title: "Copy Path", symbol: "link", op: .action(.copyPath)),
                .init(title: "Terminal", symbol: "terminal", op: .action(.terminal)),
                .init(title: "Move To…", symbol: "folder", op: .action(.moveTo)),
                .init(title: "Copy To…", symbol: "folder.badge.plus", op: .action(.copyTo)),
                .init(title: "Trash", symbol: "trash", op: .action(.trash)),
            ]
        }
    }

    static func normalizedExt(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg", "jpe": return "jpg"
        case "tif": return "tiff"
        case "aif": return "aiff"
        case "htm": return "html"
        case "markdown": return "md"
        default: return ext.lowercased()
        }
    }

    static func symbol(forExt ext: String) -> String {
        switch ext {
        case "jpg", "png", "heic", "tiff", "bmp", "avif", "webp": return "photo"
        case "gif": return "photo.stack"
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "mkv", "webm": return "film"
        case "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff": return "music.note"
        case "txt", "md": return "doc.plaintext"
        case "html": return "chevron.left.forwardslash.chevron.right"
        case "csv", "tsv": return "tablecells"
        case "json": return "curlybraces"
        default: return "doc.text"
        }
    }
}
