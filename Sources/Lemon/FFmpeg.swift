import Foundation

/// Bundled LGPL ffmpeg (scripts/build-ffmpeg.sh) for formats Apple's frameworks can't encode or read:
/// MP3, OGG, OPUS, WMA, MKV, WEBM, AVI, WMV, WEBP.
enum FFmpeg {
  /// Inside the app: Contents/MacOS/ffmpeg. During development: Support/bin/ffmpeg in the repo.
  static let binary: URL? = {
    if let u = Bundle.main.url(forAuxiliaryExecutable: "ffmpeg") { return u }
    let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Support/bin/ffmpeg").standardized
    return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
  }()

  /// Converts `src` into a new file next to it. ffmpeg reads and writes through descriptors Lemon opens,
  /// so the sandboxed helper needs no file access of its own.
  static func convert(_ src: URL, ext: String, format: String, args: [String], suffix: String = "") async throws -> URL {
    let out = outputURL(for: src, ext: ext, suffix: suffix)
    try await run(input: src, output: out, format: format, args: args)
    return out
  }

  static func run(input: URL, output: URL, format: String, args: [String]) async throws {
    guard let binary else { throw ToolError("ffmpeg is missing from this build") }
    guard FileManager.default.createFile(atPath: output.path, contents: nil) else { throw ToolError("Can't write \(output.lastPathComponent)") }
    let inH = try FileHandle(forReadingFrom: input)
    let outH = try FileHandle(forWritingTo: output)
    let p = Process()
    p.executableURL = binary
    p.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-i", "fd:"] + args + ["-f", format, "fd:"]
    p.standardInput = inH
    p.standardOutput = outH
    let err = Pipe()
    p.standardError = err
    let status: Int32 = try await withCheckedThrowingContinuation { cont in
      p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
      do { try p.run() } catch { cont.resume(throwing: error) }
    }
    try? inH.close()
    try? outH.close()
    guard status == 0 else {
      try? FileManager.default.removeItem(at: output)
      let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .split(separator: "\n").last.map(String.init) ?? ""
      throw ToolError("Couldn't convert \(input.lastPathComponent)" + (msg.isEmpty ? "" : ": \(msg)"))
    }
  }

  // MARK: Presets (format name, ffmpeg muxer, codec arguments)

  static let audio: [(ext: String, format: String, args: [String])] = [
    ("mp3", "mp3", ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]),
    ("m4a", "ipod", ["-vn", "-c:a", "aac", "-b:a", "256k"]),
    ("wav", "wav", ["-vn", "-c:a", "pcm_s16le"]),
    ("flac", "flac", ["-vn", "-c:a", "flac"]),
    ("ogg", "ogg", ["-vn", "-c:a", "libvorbis", "-q:a", "5"]),
    ("opus", "opus", ["-vn", "-c:a", "libopus", "-b:a", "128k"]),
    ("aiff", "aiff", ["-vn", "-c:a", "pcm_s16be"]),
    ("wma", "asf", ["-vn", "-c:a", "wmav2", "-b:a", "192k"]),
  ]

  static let h264 = ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]
  static let video: [(ext: String, format: String, args: [String])] = [
    ("mp4", "mp4", h264 + ["-c:a", "aac", "-b:a", "192k"]),
    ("mov", "mov", h264 + ["-c:a", "aac", "-b:a", "192k"]),
    ("mkv", "matroska", h264 + ["-c:a", "aac", "-b:a", "192k"]),
    ("webm", "webm", ["-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0", "-row-mt", "1", "-deadline", "realtime", "-cpu-used", "8",
                      "-c:a", "libopus", "-b:a", "128k"]),
    ("avi", "avi", ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]),
    ("wmv", "asf", ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]),
  ]

  // ponytail: fixed 12 fps / 480 px / first 15 s; options arrive with the GIF editor.
  static let gif = ["-t", "15", "-an", "-vf", "fps=12,scale=480:-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"]

  /// Drops the audio without re-encoding the video, keeping the container.
  static func mute(_ src: URL) async throws -> URL {
    let ext = canonicalExt(src.pathExtension)
    let muxers = ["mp4": "mp4", "m4v": "mp4", "mov": "mov", "mkv": "matroska", "webm": "webm", "avi": "avi", "wmv": "asf"]
    guard let format = muxers[ext] else { return try await convert(src, ext: "mp4", format: "mp4", args: h264 + ["-an"], suffix: "-muted") }
    return try await convert(src, ext: ext, format: format, args: ["-c:v", "copy", "-an"], suffix: "-muted")
  }

  /// WebP from any image ImageIO can read (ffmpeg decodes a PNG we hand it).
  static func webp(_ src: URL) async throws -> URL {
    let (img, _) = try ImageTools.decode(src)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
    try ImageTools.write(img, props: [:], type: .png, to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }
    let out = outputURL(for: src, ext: "webp")
    try await run(input: tmp, output: out, format: "webp", args: ["-c:v", "libwebp", "-quality", "85"])
    return out
  }
}
