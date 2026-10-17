import Foundation

struct ConversionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Tools {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

    static func find(_ name: String) -> String? {
        for dir in searchPaths {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static let ffmpeg = find("ffmpeg")
    static let cwebp = find("cwebp")

    /// Runs a command and throws with its stderr tail when it fails.
    @discardableResult
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        // Read both pipes before waiting so a full pipe buffer can't stall the process.
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let tail = String(decoding: errData, as: UTF8.self)
                .split(separator: "\n").suffix(3).joined(separator: " ")
            throw ConversionError("\((executable as NSString).lastPathComponent) failed: \(tail)")
        }
        return String(decoding: outData, as: UTF8.self)
    }

    static func ffmpeg(_ args: [String]) throws {
        guard let ffmpeg else { throw ConversionError("ffmpeg not found. Install it with: brew install ffmpeg") }
        try run(ffmpeg, ["-hide_banner", "-loglevel", "error", "-y"] + args)
    }
}

enum Output {
    /// "photo.heic" + "jpg" -> "photo.jpg", or "photo 2.jpg" if that exists.
    static func url(for source: URL, ext: String, suffix: String = "") -> URL {
        let dir = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        return unique(dir.appendingPathComponent(base).appendingPathExtension(ext))
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(n)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    static func tempURL(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("satsuma-\(UUID().uuidString)")
            .appendingPathExtension(ext)
    }
}
