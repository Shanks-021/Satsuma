import AppKit

enum MediaOps {
    static func convert(_ url: URL, to ext: String) throws -> URL {
        let out = Output.url(for: url, ext: ext)
        let input = ["-i", url.path]
        let h264 = ["-c:v", "libx264", "-crf", "23", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k"]
        switch ext {
        case "mp4", "mov":
            try Tools.ffmpeg(input + h264 + ["-movflags", "+faststart", out.path])
        case "mkv":
            // Stream copy is instant when the codecs fit; re-encode otherwise.
            do { try Tools.ffmpeg(input + ["-c", "copy", out.path]) }
            catch { try Tools.ffmpeg(input + h264 + [out.path]) }
        case "webm":
            try Tools.ffmpeg(input + ["-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0", "-row-mt", "1",
                                      "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k", out.path])
        case "gif":
            try Tools.ffmpeg(input + ["-vf", "fps=12,scale='min(640,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                                      "-loop", "0", out.path])
        case "mp3": try Tools.ffmpeg(input + ["-vn", "-c:a", "libmp3lame", "-q:a", "2", out.path])
        case "m4a": try Tools.ffmpeg(input + ["-vn", "-c:a", "aac", "-b:a", "192k", out.path])
        case "wav": try Tools.ffmpeg(input + ["-vn", "-c:a", "pcm_s16le", out.path])
        case "aiff": try Tools.ffmpeg(input + ["-vn", "-c:a", "pcm_s16be", out.path])
        case "flac": try Tools.ffmpeg(input + ["-vn", "-c:a", "flac", out.path])
        case "ogg", "opus": try Tools.ffmpeg(input + ["-vn", "-c:a", "libopus", "-b:a", "128k", out.path])
        default: throw ConversionError("Can't convert to .\(ext)")
        }
        return out
    }

    static func videoTool(_ url: URL, _ tool: Tool) throws -> URL {
        let input = ["-i", url.path]
        let h264 = ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac"]
        switch tool {
        case .compress:
            let out = Output.url(for: url, ext: "mp4", suffix: " (compressed)")
            try Tools.ffmpeg(input + h264 + ["-crf", "28", "-preset", "slow", "-b:a", "128k", "-movflags", "+faststart", out.path])
            return out
        case .scale720:
            let out = Output.url(for: url, ext: "mp4", suffix: " (720p)")
            try Tools.ffmpeg(input + ["-vf", "scale=-2:'min(720,ih)'"] + h264 + ["-crf", "23", out.path])
            return out
        case .mute:
            let out = Output.url(for: url, ext: url.pathExtension, suffix: " (muted)")
            try Tools.ffmpeg(input + ["-c:v", "copy", "-an", out.path])
            return out
        case .rotate:
            let out = Output.url(for: url, ext: "mp4", suffix: " (rotated)")
            try Tools.ffmpeg(input + ["-vf", "transpose=1"] + h264 + ["-crf", "20", out.path])
            return out
        case .firstFrame:
            let out = Output.url(for: url, ext: "png")
            try Tools.ffmpeg(["-ss", "0.5"] + input + ["-frames:v", "1", out.path])
            return out
        default:
            throw ConversionError("Unsupported video tool")
        }
    }

    static func audioTool(_ url: URL, _ tool: Tool) throws -> URL {
        let input = ["-i", url.path]
        let ext = url.pathExtension.lowercased()
        switch tool {
        case .compress:
            let out = Output.url(for: url, ext: "mp3", suffix: " (compressed)")
            try Tools.ffmpeg(input + ["-vn", "-c:a", "libmp3lame", "-b:a", "128k", out.path])
            return out
        case .normalize:
            let out = Output.url(for: url, ext: ext, suffix: " (normalized)")
            try Tools.ffmpeg(input + ["-vn", "-af", "loudnorm=I=-16:TP=-1.5:LRA=11", out.path])
            return out
        case .mono:
            let out = Output.url(for: url, ext: ext, suffix: " (mono)")
            try Tools.ffmpeg(input + ["-vn", "-ac", "1", out.path])
            return out
        case .reverse:
            let out = Output.url(for: url, ext: ext, suffix: " (reversed)")
            try Tools.ffmpeg(input + ["-vn", "-af", "areverse", out.path])
            return out
        default:
            throw ConversionError("Unsupported audio tool")
        }
    }
}

enum ArchiveOps {
    static func zip(_ urls: [URL]) throws -> URL {
        let parent = urls[0].deletingLastPathComponent()
        let name = urls.count == 1 ? urls[0].lastPathComponent : "Archive"
        let out = Output.unique(parent.appendingPathComponent(name).appendingPathExtension("zip"))
        if urls.count == 1 {
            try Tools.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, out.path])
        } else {
            let sameParent = urls.allSatisfy { $0.deletingLastPathComponent() == parent }
            let items = sameParent ? urls.map(\.lastPathComponent) : urls.map(\.path)
            try Tools.run("/usr/bin/zip", ["-r", "-y", "-q", out.path] + items, cwd: parent)
        }
        return out
    }

    static func extract(_ url: URL) throws -> URL {
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        var base = url.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        let dest = Output.unique(parent.appendingPathComponent(base))

        if ext == "gz" && !name.hasSuffix(".tar.gz") {
            // Plain gzip of a single file.
            let out = Output.unique(parent.appendingPathComponent(url.deletingPathExtension().lastPathComponent))
            try Tools.run("/bin/sh", ["-c", "/usr/bin/gunzip -c \"$1\" > \"$2\"", "sh", url.path, out.path])
            return out
        }
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        switch ext {
        case "zip": try Tools.run("/usr/bin/ditto", ["-x", "-k", url.path, dest.path])
        case "tar", "gz", "tgz", "bz2", "xz": try Tools.run("/usr/bin/tar", ["-xf", url.path, "-C", dest.path])
        default:
            // bsdtar also reads 7z and many RAR files.
            try Tools.run("/usr/bin/tar", ["-xf", url.path, "-C", dest.path])
        }
        return dest
    }
}

/// Runs a chosen wheel option on files, reporting progress in the HUD.
@MainActor
enum Converter {
    static func perform(_ option: WheelOption, on urls: [URL]) {
        switch option.op {
        case .action(let action):
            Actions.perform(action, urls: urls)
        case .convert, .tool:
            runJobs(option, urls)
        }
    }

    private static func runJobs(_ option: WheelOption, _ urls: [URL]) {
        let cat = commonCategory(of: urls)
        // Jobs that take all files at once produce a single output.
        let batch: Bool
        if case .tool(let t) = option.op, [.zip, .mergePDF, .combinePDF].contains(t) { batch = true } else { batch = false }
        let jobs: [[URL]] = batch ? [urls] : urls.map { [$0] }
        // Rich-text import/export uses AppKit's HTML engine, which must run on the main thread.
        let mainThreadOnly: Bool
        if case .convert(let ext) = option.op, [.document, .markdown, .pdf].contains(cat), !(cat == .pdf && ext == "docx") {
            mainThreadOnly = true
        } else {
            mainThreadOnly = false
        }

        HUD.shared.showProgress("\(option.title) — \(urls.count) file\(urls.count == 1 ? "" : "s")…")

        var isCompress = false
        if case .tool(let t) = option.op, t == .compress || t == .compressMax { isCompress = true }
        var before = 0, after = 0

        let work: () -> (outputs: [URL], errors: [String]) = {
            var outputs: [URL] = [], errors: [String] = []
            for job in jobs {
                do {
                    let out = try execute(option.op, job, cat)
                    outputs.append(out)
                    if isCompress {
                        before += job.map(ImageCompressor.fileSize).reduce(0, +)
                        after += ImageCompressor.fileSize(out)
                    }
                }
                catch { errors.append("\(job[0].lastPathComponent): \(error.localizedDescription)") }
            }
            return (outputs, errors)
        }

        let finish: ((outputs: [URL], errors: [String])) -> Void = { result in
            if result.errors.isEmpty {
                let n = result.outputs.count
                if isCompress && before > 0 {
                    let saved = Int((1 - Double(after) / Double(before)) * 100)
                    let fmt = ByteCountFormatter()
                    HUD.shared.showDone("Saved \(saved)% — \(fmt.string(fromByteCount: Int64(before))) → \(fmt.string(fromByteCount: Int64(after)))", outputs: result.outputs)
                } else {
                    HUD.shared.showDone("Done — \(n) file\(n == 1 ? "" : "s") created", outputs: result.outputs)
                }
            } else {
                HUD.shared.showError(result.errors.joined(separator: "\n"), outputs: result.outputs)
            }
        }

        if mainThreadOnly {
            // Let the HUD draw before blocking the main thread.
            DispatchQueue.main.async { finish(work()) }
        } else {
            DispatchQueue.global(qos: .userInitiated).async {
                let result = work()
                DispatchQueue.main.async { finish(result) }
            }
        }
    }

    nonisolated static func execute(_ op: Operation, _ files: [URL], _ cat: FileCategory) throws -> URL {
        let url = files[0]
        switch op {
        case .convert(let ext):
            switch cat {
            case .image: return try ImageOps.convert(url, to: ext)
            case .video, .audio: return try MediaOps.convert(url, to: ext)
            case .pdf where ext == "png" || ext == "jpg": return try PDFOps.toImages(url, ext: ext)
            case .pdf, .document, .markdown: return try DocOps.convert(url, to: ext, category: cat)
            case .table: return try TableOps.convert(url, to: ext)
            default: throw ConversionError("No converter for this file")
            }
        case .tool(let tool):
            switch (tool, cat) {
            case (.zip, _): return try ArchiveOps.zip(files)
            case (.unarchive, _): return try ArchiveOps.extract(url)
            case (.mergePDF, _): return try PDFOps.merge(files)
            case (.combinePDF, _): return try ImageOps.combineToPDF(files)
            case (.compress, .image): return try ImageCompressor.compress(url, level: .recommended).url
            case (.compressMax, .image): return try ImageCompressor.compress(url, level: .extreme).url
            case (.resizeHalf, _): return try ImageOps.resizeHalf(url)
            case (.rotate, .image): return try ImageOps.rotate(url)
            case (.flip, _): return try ImageOps.flip(url)
            case (.grayscale, _): return try ImageOps.grayscale(url)
            case (.compress, .pdf): return try PDFOps.compress(url)
            case (.splitPDF, _): return try PDFOps.split(url)
            case (.rotatePDF, _): return try PDFOps.rotate(url)
            case (_, .video): return try MediaOps.videoTool(url, tool)
            case (_, .audio): return try MediaOps.audioTool(url, tool)
            default: throw ConversionError("Tool not available for this file")
            }
        case .action:
            throw ConversionError("Actions are not jobs")
        }
    }
}
