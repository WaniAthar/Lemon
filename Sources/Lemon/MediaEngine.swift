import AppKit
import AVFoundation

/// What ffmpeg sees in a file. `size` is as displayed (rotation applied, like ffmpeg's autorotate).
struct MediaInfo {
  var duration = 0.0
  var size = CGSize.zero
  var fps = 0.0
  var hasVideo = false, hasAudio = false
  var channels = 0, sampleRate = 0
}

struct Redaction: Equatable, Sendable {
  var rect: CGRect  // normalized, top-left origin
  var start: Double, end: Double
}

enum VideoRedactStyle: String, CaseIterable, Sendable { case blur = "Blur", pixelate = "Pixelate", black = "Black" }

struct VideoCompressSettings: Equatable, Sendable {
  enum Codec: String, CaseIterable, Sendable { case h264 = "H.264", hevc = "HEVC" }
  var quality = 50  // VideoToolbox constant quality, 1–100
  var codec = Codec.h264
  var maxSide: Int? = nil

  var args: [String] {
    var a = ["-c:v", codec == .h264 ? "h264_videotoolbox" : "hevc_videotoolbox", "-q:v", "\(quality)", "-pix_fmt", "yuv420p"]
    if codec == .hevc { a += ["-tag:v", "hvc1"] }  // QuickTime only plays HEVC tagged hvc1
    if let m = maxSide {
      a += ["-vf", "scale=w='min(iw,\(m))':h='min(ih,\(m))':force_original_aspect_ratio=decrease:force_divisible_by=2"]
    }
    return a + ["-c:a", "aac", "-b:a", "128k"]
  }
}

struct Loudness { var i, tp, lra, thresh, offset: Double }

extension FFmpeg {
  /// Runs ffmpeg with the given arguments. `fd:` reads `stdin` and writes `stdout`; any other input must be a path in
  /// the temporary directory (see `staged`), the only place the helper can reach since it inherits Lemon's sandbox.
  /// Returns stderr: pass `log: "info"` for stream info and filter reports.
  @discardableResult
  static func exec(_ args: [String], stdin: URL? = nil, stdout: URL? = nil, log: String = "error", check: Bool = true) async throws -> String {
    guard let binary else { throw ToolError("ffmpeg is missing from this build") }
    if let stdout, !FileManager.default.createFile(atPath: stdout.path, contents: nil) {
      throw ToolError("Can't write \(stdout.lastPathComponent)")
    }
    let inH = try stdin.map { try FileHandle(forReadingFrom: $0) } ?? .nullDevice
    let outH = try stdout.map { try FileHandle(forWritingTo: $0) } ?? .nullDevice
    defer { try? inH.close(); try? outH.close() }
    let p = Process()
    p.executableURL = binary
    p.arguments = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", log, "-y"] + args
    p.standardInput = inH
    p.standardOutput = outH
    let err = Pipe()
    p.standardError = err
    // drain stderr while running so a chatty log can't fill the pipe and stall ffmpeg
    let errData = Task.detached { err.fileHandleForReading.readDataToEndOfFile() }
    let status: Int32 = try await withCheckedThrowingContinuation { cont in
      p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
      do { try p.run() } catch { try? err.fileHandleForWriting.close(); cont.resume(throwing: error) }
    }
    let text = String(decoding: await errData.value, as: UTF8.self)
    if check && status != 0 {
      if let stdout { try? FileManager.default.removeItem(at: stdout) }
      let msg = text.split(separator: "\n").last.map(String.init) ?? ""
      throw ToolError("ffmpeg failed" + (msg.isEmpty ? "" : ": \(msg)"))
    }
    return text
  }

  static func temp(_ ext: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lemon-\(UUID().uuidString).\(ext)")
  }

  /// A copy of `src` in the temporary directory (an APFS clone, so instant on the same volume). Remove with `unstage`.
  static func staged(_ src: URL) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lemon-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let u = dir.appendingPathComponent("in." + src.pathExtension.lowercased())  // plain name: no ':' or ',' for ffmpeg to misread
    try FileManager.default.copyItem(at: src, to: u)
    return u
  }

  static func unstage(_ u: URL) { try? FileManager.default.removeItem(at: u.deletingLastPathComponent()) }

  static func probe(_ src: URL) async throws -> MediaInfo {
    let log = try await exec(["-i", "fd:"], stdin: src, log: "info", check: false)
    func match(_ pattern: String, _ s: Substring) -> [String]? {
      guard let m = try? Regex(pattern).firstMatch(in: s) else { return nil }
      return (1..<m.output.count).map { m.output[$0].substring.map(String.init) ?? "" }
    }
    var info = MediaInfo()
    var rotated = false
    for line in log.split(separator: "\n") {
      if let d = match(#"Duration: (\d+):(\d+):([\d.]+)"#, line) {
        info.duration = Double(d[0])! * 3600 + Double(d[1])! * 60 + Double(d[2])!
      } else if line.contains("Stream #"), line.contains(": Video:"), !line.contains("attached pic"), !info.hasVideo {
        info.hasVideo = true
        if let s = match(#", (\d{2,5})x(\d{2,5})"#, line) { info.size = CGSize(width: Int(s[0])!, height: Int(s[1])!) }
        if let f = match(#"([\d.]+) fps"#, line) { info.fps = Double(f[0]) ?? 0 }
      } else if line.contains("Stream #"), line.contains(": Audio:"), !info.hasAudio {
        info.hasAudio = true
        if let a = match(#"(\d+) Hz, ([^,]+)"#, line) {
          info.sampleRate = Int(a[0]) ?? 0
          let layouts = ["mono": 1, "stereo": 2, "2.1": 3, "quad": 4, "5.0": 5, "5.1": 6, "6.1": 7, "7.1": 8]
          info.channels = layouts[a[1].components(separatedBy: "(")[0]] ?? Int(a[1].components(separatedBy: " ")[0]) ?? 2
        }
      } else if let r = match(#"rotation of (-?[\d.]+) degrees"#, line), let deg = Double(r[0]) {
        rotated = Int(abs(deg).rounded()) % 180 == 90
      }
    }
    if rotated { info.size = CGSize(width: info.size.height, height: info.size.width) }
    guard info.hasVideo || info.hasAudio else { throw ToolError("Can't read \(src.lastPathComponent)") }
    return info
  }
}

extension MediaTools {
  static let avTypes: [String: AVFileType] = ["mov": .mov, "mp4": .mp4, "m4v": .m4v, "m4a": .m4a, "wav": .wav, "aiff": .aiff, "caf": .caf]
  static let copyMuxers = ["mp4": "mp4", "m4v": "mp4", "mov": "mov", "mkv": "matroska", "webm": "webm", "avi": "avi", "wmv": "asf",
                           "mp3": "mp3", "m4a": "ipod", "wav": "wav", "flac": "flac", "ogg": "ogg", "opus": "opus", "aiff": "aiff",
                           "wma": "asf", "aac": "adts"]

  /// Re-encode settings that keep the container when ffmpeg can write it, otherwise MP4 / M4A.
  static func preset(for src: URL, video: Bool) -> (ext: String, format: String, args: [String]) {
    let ext = canonicalExt(src.pathExtension)
    return video ? FFmpeg.video.first { $0.ext == ext } ?? FFmpeg.video[0] : FFmpeg.audio.first { $0.ext == ext } ?? FFmpeg.audio[1]
  }

  static func reencode(_ src: URL, suffix: String, video: Bool, before: [String] = [], filters: [String]) async throws -> URL {
    let p = preset(for: src, video: video)
    let out = outputURL(for: src, ext: p.ext, suffix: suffix)
    try await FFmpeg.exec(before + ["-i", "fd:"] + filters + p.args + ["-f", p.format, "fd:"], stdin: src, stdout: out)
    return out
  }

  static func export(_ asset: AVAsset, range: CMTimeRange? = nil, type: AVFileType, to out: URL) async throws {
    guard let s = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { throw ToolError("Can't export \(out.lastPathComponent)") }
    s.outputURL = out
    s.outputFileType = type
    if let range { s.timeRange = range }
    await s.export()
    guard s.status == .completed else { throw ToolError(s.error?.localizedDescription ?? "Couldn't save \(out.lastPathComponent)") }
  }

  static func cmRange(_ r: ClosedRange<Double>) -> CMTimeRange {
    CMTimeRange(start: CMTime(seconds: r.lowerBound, preferredTimescale: 600), end: CMTime(seconds: r.upperBound, preferredTimescale: 600))
  }

  // MARK: Preview and PCM

  private static var proxies: [URL: URL] = [:]

  /// `src`, or a temporary H.264/AAC copy AVFoundation can play (MKV, WEBM, AVI, WMV, OGG, OPUS, WMA). Cached per file.
  static func playable(_ src: URL) async throws -> URL {
    if let p = proxies[src] { return p }
    let asset = AVURLAsset(url: src)
    if (try? await asset.load(.isPlayable)) == true, (try? await asset.load(.tracks))?.isEmpty == false { return src }
    let video = FileKind(src) == .video
    let tmp = FFmpeg.temp(video ? "mp4" : "m4a")
    // ponytail: full-resolution proxy so snapshots stay sharp; a small preview proxy if long files feel slow
    try await FFmpeg.exec(["-i", "fd:"] + (video ? FFmpeg.h264 + ["-c:a", "aac", "-b:a", "160k", "-f", "mp4", "fd:"]
                                             : ["-vn", "-c:a", "aac", "-b:a", "192k", "-f", "ipod", "fd:"]), stdin: src, stdout: tmp)
    proxies[src] = tmp
    return tmp
  }

  /// Audio AVAudioFile can read: `src` itself, or a temporary WAV ffmpeg decodes (OGG, OPUS, WMA, video soundtracks).
  static func pcmSource(_ src: URL) async throws -> (url: URL, temporary: Bool) {
    if FileKind(src) == .audio, (try? AVAudioFile(forReading: src)) != nil { return (src, false) }
    let tmp = FFmpeg.temp("wav")
    do {
      try await FFmpeg.exec(["-i", "fd:", "-vn", "-c:a", "pcm_s16le", "-f", "wav", "fd:"], stdin: src, stdout: tmp)
    } catch { throw ToolError("\(src.lastPathComponent) has no readable audio") }
    return (tmp, true)
  }

  /// Calls `body` with consecutive PCM chunks and the frame position each starts at.
  static func readPCM(_ src: URL, _ body: (AVAudioPCMBuffer, AVAudioFramePosition) throws -> Void) async throws -> (frames: Int64, rate: Double) {
    let (url, temporary) = try await pcmSource(src)
    defer { if temporary { try? FileManager.default.removeItem(at: url) } }
    let f = try AVAudioFile(forReading: url)
    guard let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 65_536) else { throw ToolError("Out of memory") }
    while f.framePosition < f.length {
      let pos = f.framePosition
      try f.read(into: buf)
      if buf.frameLength == 0 { break }
      try body(buf, pos)
    }
    return (f.length, f.processingFormat.sampleRate)
  }

  /// Peak level (0–1) in `count` equal slices.
  static func peaks(_ src: URL, count: Int) async throws -> [Float] {
    var fine: [Float] = []  // per 256 frames, folded into `count` slices at the end
    var bucket: Float = 0, inBucket = 0
    _ = try await readPCM(src) { b, _ in
      let ch = b.floatChannelData!
      for i in 0..<Int(b.frameLength) {
        for c in 0..<Int(b.format.channelCount) { bucket = max(bucket, abs(ch[c][i])) }
        inBucket += 1
        if inBucket == 256 { fine.append(bucket); bucket = 0; inBucket = 0 }
      }
    }
    if inBucket > 0 { fine.append(bucket) }
    guard !fine.isEmpty else { return [] }
    let n = min(count, fine.count)
    return (0..<n).map { k in fine[k * fine.count / n..<max(k * fine.count / n + 1, (k + 1) * fine.count / n)].max()! }
  }

  /// From the first to the last 10 ms window louder than `db` (RMS, dBFS), or nil when all of it is quieter.
  static func audibleRange(_ src: URL, thresholdDB db: Double) async throws -> ClosedRange<Double>? {
    let limit = Float(pow(10, db / 20))
    var first: Int64?, last: Int64 = 0
    var sum: Float = 0, n = 0, windowStart: Int64 = 0, window = 441
    let (_, rate) = try await readPCM(src) { b, pos in
      window = Int(b.format.sampleRate / 100)
      let ch = b.floatChannelData!, cc = Int(b.format.channelCount)
      for i in 0..<Int(b.frameLength) {
        if n == 0 { windowStart = pos + Int64(i) }
        for c in 0..<cc { sum += ch[c][i] * ch[c][i] / Float(cc) }
        n += 1
        if n == window {
          if (sum / Float(n)).squareRoot() > limit { first = first ?? windowStart; last = windowStart + Int64(n) }
          sum = 0; n = 0
        }
      }
    }
    guard let first else { return nil }
    return Double(first) / rate...Double(last) / rate
  }

  /// Streams decoded audio through `process` (input chunk, output chunk, chunk start frame) into a file in the same
  /// format where possible: WAV/AIFF/CAF/M4A natively, MP3/FLAC/OGG/OPUS/WMA re-encoded by ffmpeg, anything else M4A.
  static func processAudio(_ src: URL, suffix: String,
                           _ process: @escaping (AVAudioPCMBuffer, AVAudioPCMBuffer, AVAudioFramePosition) -> Void) async throws -> URL {
    let (url, temporary) = try await pcmSource(src)
    defer { if temporary { try? FileManager.default.removeItem(at: url) } }
    let ext = canonicalExt(src.pathExtension)
    let viaFFmpeg = !["wav", "aiff", "caf", "m4a"].contains(ext) && FFmpeg.audio.contains { $0.ext == ext }
    let target = sameOrM4A(viaFFmpeg ? URL(fileURLWithPath: "x.wav") : src)
    let out = viaFFmpeg ? FFmpeg.temp("wav") : outputURL(for: src, ext: target.ext, suffix: suffix)
    do {  // scope closes the output so its header is final before ffmpeg reads it
      let input = try AVAudioFile(forReading: url)
      let fmt = input.processingFormat
      let output = try AVAudioFile(forWriting: out, settings: target.settings(fmt).merging([AVNumberOfChannelsKey: fmt.channelCount]) { $1 },
                                   commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
      guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 32_768),
            let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 32_768) else { throw ToolError("Out of memory") }
      while input.framePosition < input.length {
        let pos = input.framePosition
        try input.read(into: buf)
        if buf.frameLength == 0 { break }
        outBuf.frameLength = buf.frameLength
        process(buf, outBuf, pos)
        try output.write(from: outBuf)
      }
    }
    guard viaFFmpeg else { return out }
    defer { try? FileManager.default.removeItem(at: out) }
    let p = preset(for: src, video: false)
    let final = outputURL(for: src, ext: p.ext, suffix: suffix)
    try await FFmpeg.exec(["-i", "fd:"] + p.args + ["-f", p.format, "fd:"], stdin: out, stdout: final)
    return final
  }

  // MARK: Trim, split, join, speed

  /// Keeps `r` (seconds) in the same container. AVFoundation passthrough for MP4/MOV/M4A/WAV/AIFF/CAF; ffmpeg stream copy
  /// for other audio; other video is re-encoded, since stream copy can only start at a keyframe and VideoToolbox
  /// files often have one keyframe every few seconds.
  static func trim(_ src: URL, _ r: ClosedRange<Double>) async throws -> URL {
    let ext = canonicalExt(src.pathExtension)
    guard r.upperBound - r.lowerBound > 0.01 else { throw ToolError("The selection is empty") }
    if let type = avTypes[ext] {
      let out = outputURL(for: src, ext: ext, suffix: "-trimmed")
      try await export(AVURLAsset(url: src), range: cmRange(r), type: type, to: out)
      return out
    }
    let cut = ["-ss", "\(r.lowerBound)", "-t", "\(r.upperBound - r.lowerBound)"]
    let video = FileKind(src) == .video
    guard !video, let muxer = copyMuxers[ext] else {
      return try await reencode(src, suffix: "-trimmed", video: video, before: cut, filters: [])
    }
    let out = outputURL(for: src, ext: ext, suffix: "-trimmed")
    try await FFmpeg.exec(cut + ["-i", "fd:", "-c", "copy", "-f", muxer, "fd:"], stdin: src, stdout: out)
    return out
  }

  /// One-click trim: cut silence (below -50 dB) from both ends.
  static func trimSilence(_ src: URL, thresholdDB: Double = -50) async throws -> URL {
    guard let r = try await audibleRange(src, thresholdDB: thresholdDB) else { throw ToolError("\(src.lastPathComponent) is silent") }
    let d = try await FFmpeg.probe(src).duration
    guard r.lowerBound > 0.05 || r.upperBound < d - 0.05 else { throw ToolError("No silence to trim in \(src.lastPathComponent)") }
    return try await trim(src, r)
  }

  /// Clips between `cuts`; clips whose index is in `removed` are dropped. Separate files, or the rest joined into one.
  static func split(_ src: URL, cuts: [Double], removed: Set<Int> = [], merged: Bool) async throws -> [URL] {
    let info = try await FFmpeg.probe(src)
    let bounds = [0] + cuts.filter { $0 > 0.05 && $0 < info.duration - 0.05 }.sorted() + [info.duration]
    let kept = (0..<bounds.count - 1).filter { !removed.contains($0) }.map { bounds[$0]...bounds[$0 + 1] }
    guard !kept.isEmpty else { throw ToolError("Every clip is removed") }
    let ext = canonicalExt(src.pathExtension)
    if !merged {
      var outs: [URL] = []
      for (n, r) in kept.enumerated() {
        let part = try await trim(src, r)
        let named = outputURL(for: src, ext: part.pathExtension, suffix: "-part\(n + 1)")
        try FileManager.default.moveItem(at: part, to: named)
        outs.append(named)
      }
      return outs
    }
    if let type = avTypes[ext] {
      let asset = AVURLAsset(url: src)
      let comp = AVMutableComposition()
      var at = CMTime.zero
      for r in kept {
        let range = cmRange(r)
        try await comp.insertTimeRange(range, of: asset, at: at)
        at = at + range.duration
      }
      let out = outputURL(for: src, ext: ext, suffix: "-edited")
      try await export(comp, type: type, to: out)
      return [out]
    }
    // Input-side seeks on a staged copy: frame-accurate and each clip starts at 0, as concat wants.
    let staged = try FFmpeg.staged(src)
    defer { FFmpeg.unstage(staged) }
    let inputs = kept.flatMap { ["-ss", "\($0.lowerBound)", "-t", "\($0.upperBound - $0.lowerBound)", "-i", staged.path] }
    let a = info.hasAudio ? 1 : 0
    let pads = kept.indices.map { "[\($0):v]" + (a == 1 ? "[\($0):a]" : "") }.joined()
    let p = preset(for: src, video: true)
    let out = outputURL(for: src, ext: p.ext, suffix: "-edited")
    try await FFmpeg.exec(inputs + ["-filter_complex", "\(pads)concat=n=\(kept.count):v=1:a=\(a)[v]" + (a == 1 ? "[a]" : ""), "-map", "[v]"]
                          + (a == 1 ? ["-map", "[a]"] : []) + p.args + ["-f", p.format, "fd:"], stdout: out)
    return [out]
  }

  /// One MP4 in the given order; every clip scaled and letterboxed to the first one's size, silent clips get silence.
  static func join(_ urls: [URL]) async throws -> URL {
    guard urls.count > 1 else { throw ToolError("Join needs at least two videos") }
    var infos: [MediaInfo] = []
    for u in urls { infos.append(try await FFmpeg.probe(u)) }
    guard infos.allSatisfy(\.hasVideo) else { throw ToolError("Only videos can be joined") }
    let W = max(2, Int(infos[0].size.width) / 2 * 2), H = max(2, Int(infos[0].size.height) / 2 * 2)
    let fps = infos[0].fps > 0 ? min(infos[0].fps, 60) : 30
    let audio = infos.contains(where: \.hasAudio)
    var staged: [URL] = []
    defer { staged.forEach(FFmpeg.unstage) }
    for u in urls { staged.append(try FFmpeg.staged(u)) }
    var graph: [String] = [], pads = ""
    for (i, info) in infos.enumerated() {
      graph.append("[\(i):v]scale=\(W):\(H):force_original_aspect_ratio=decrease:force_divisible_by=2,pad=\(W):\(H):(ow-iw)/2:(oh-ih)/2,fps=\(fps),format=yuv420p[v\(i)]")
      pads += "[v\(i)]"
      guard audio else { continue }
      let fmt = "aformat=sample_fmts=fltp:sample_rates=48000:channel_layouts=stereo[a\(i)]"
      graph.append(info.hasAudio ? "[\(i):a]\(fmt)" : "anullsrc=r=48000:cl=stereo,atrim=duration=\(info.duration),\(fmt)")
      pads += "[a\(i)]"
    }
    // ponytail: concat needs equal SAR; scale keeps square pixels for the usual inputs (setsar isn't in the build)
    graph.append("\(pads)concat=n=\(urls.count):v=1:a=\(audio ? 1 : 0)[v]" + (audio ? "[a]" : ""))
    let out = outputURL(for: urls[0], ext: "mp4", suffix: "-joined")
    try await FFmpeg.exec(staged.flatMap { ["-i", $0.path] } + ["-filter_complex", graph.joined(separator: ";"), "-map", "[v]"]
                          + (audio ? ["-map", "[a]"] : []) + FFmpeg.h264 + ["-c:a", "aac", "-b:a", "192k", "-f", "mp4", "fd:"], stdout: out)
    return out
  }

  /// atempo steps within 0.5–2 (the classic per-filter range), e.g. 4 → 2,2 and 0.25 → 0.5,0.5.
  static func atempo(_ factor: Double) -> String {
    var f = factor, steps: [Double] = []
    while f > 2 { steps.append(2); f /= 2 }
    while f < 0.5 { steps.append(0.5); f /= 0.5 }
    return (steps + [f]).map { "atempo=\($0)" }.joined(separator: ",")
  }

  static func speed(_ src: URL, factor: Double, keepAudio: Bool = true) async throws -> URL {
    guard factor > 0 else { throw ToolError("Speed must be above zero") }
    let info = try await FFmpeg.probe(src)
    var filters: [String] = []
    if info.hasVideo {
      // faster keeps the source frame rate instead of multiplying it
      filters += ["-filter:v", "setpts=PTS/\(factor)" + (factor > 1 && info.fps > 0 ? ",fps=\(info.fps)" : "")]
    }
    filters += info.hasAudio && (keepAudio || !info.hasVideo) ? ["-filter:a", atempo(factor)] : ["-an"]
    return try await reencode(src, suffix: "-" + String(format: "%g", factor) + "x", video: info.hasVideo, filters: filters)
  }

  // MARK: Snapshots

  static func snapshots(_ src: URL, at times: [Double]) async throws -> URL {
    guard !times.isEmpty else { throw ToolError("Pick at least one frame") }
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: try await playable(src)))
    gen.appliesPreferredTrackTransform = true
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let dir = outputURL(for: src, ext: "", suffix: "-snapshots")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    for (i, t) in times.sorted().enumerated() {
      let img = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
      try ImageTools.write(img, props: [:], type: .png, to: dir.appendingPathComponent(String(format: "%02d.png", i + 1)))
    }
    return dir
  }

  static func snapshots(_ src: URL, count: Int) async throws -> URL {
    let d = try await FFmpeg.probe(src).duration
    guard d > 0 else { throw ToolError("\(src.lastPathComponent) has no frames") }
    return try await snapshots(src, at: (0..<count).map { d * (Double($0) + 0.5) / Double(count) })
  }

  // MARK: Redaction

  /// Re-encodes every frame; inside each box only a handful of averaged samples survive (blur/pixelate) or nothing (black),
  /// so the hidden pixels can't be recovered. Metadata, chapters, cover art and subtitles are dropped.
  static func redact(_ src: URL, _ boxes: [Redaction], style: VideoRedactStyle) async throws -> URL {
    guard !boxes.isEmpty else { throw ToolError("Draw the areas to hide in the editor") }
    let info = try await FFmpeg.probe(src)
    guard info.hasVideo, info.size.width > 0 else { throw ToolError("\(src.lastPathComponent) has no video") }
    let W = Int(info.size.width), H = Int(info.size.height)
    var graph: [String] = [], last = "0:v"
    for (i, b) in boxes.enumerated() {
      let x = min(max(Int(b.rect.minX * Double(W)) / 2 * 2, 0), W - 2), y = min(max(Int(b.rect.minY * Double(H)) / 2 * 2, 0), H - 2)
      let w = max(2, min(Int((b.rect.width * Double(W)).rounded(.up) + 1) / 2 * 2, W - x))
      let h = max(2, min(Int((b.rect.height * Double(H)).rounded(.up) + 1) / 2 * 2, H - y))
      let on = "enable='between(t,\(b.start),\(b.end))'"
      if style == .black {
        graph.append("[\(last)]drawbox=x=\(x):y=\(y):w=\(w):h=\(h):color=black:t=fill:\(on)[v\(i)]")
      } else {
        // ponytail: fixed strength, 8 (blur) or 12 (pixelate) samples across the longer side
        let k = style == .blur ? 8.0 : 12.0, s = Double(max(w, h)) / k
        let tw = max(1, Int(Double(w) / s)), th = max(1, Int(Double(h) / s))
        graph.append("[\(last)]split[b\(i)][c\(i)];[c\(i)]crop=\(w):\(h):\(x):\(y),scale=\(tw):\(th):flags=area,"
                     + "scale=\(w):\(h):flags=\(style == .blur ? "bicubic" : "neighbor")[r\(i)];[b\(i)][r\(i)]overlay=\(x):\(y):\(on)[v\(i)]")
      }
      last = "v\(i)"
    }
    return try await reencode(src, suffix: "-redacted", video: true, filters: [
      "-filter_complex", graph.joined(separator: ";"), "-map", "[\(last)]", "-map", "0:a?",
      "-map_metadata", "-1", "-map_chapters", "-1",
    ])
  }

  /// Silence or a 1 kHz tone over `ranges` (seconds).
  static func bleep(_ src: URL, ranges: [ClosedRange<Double>], tone: Bool = true) async throws -> URL {
    guard !ranges.isEmpty else { throw ToolError("Mark the parts to bleep in the editor") }
    return try await processAudio(src, suffix: "-bleeped") { inp, out, start in
      let rate = inp.format.sampleRate
      for i in 0..<Int(inp.frameLength) {
        let t = Double(start + Int64(i)) / rate
        let hit = ranges.contains { $0.contains(t) }
        let beep = Float(sin(2 * .pi * 1000 * t)) * 0.25
        for c in 0..<Int(inp.format.channelCount) {
          out.floatChannelData![c][i] = hit ? (tone ? beep : 0) : inp.floatChannelData![c][i]
        }
      }
    }
  }

  // MARK: Channels, loudness

  /// Mono or stereo with per-side volume (1 = unchanged), in the source format.
  static func channels(_ src: URL, stereo: Bool, left: Double = 1, right: Double = 1) async throws -> URL {
    let info = try await FFmpeg.probe(src)
    guard info.hasAudio else { throw ToolError("\(src.lastPathComponent) has no audio") }
    func g(_ v: Double) -> String { String(format: "%.4f", v) }
    let two = info.channels >= 2
    let pan = stereo ? "pan=stereo|c0=\(g(left))*c0|c1=\(g(right))*\(two ? "c1" : "c0")"
                     : two ? "pan=mono|c0=\(g(left / 2))*c0+\(g(right / 2))*c1" : "pan=mono|c0=\(g((left + right) / 2))*c0"
    let down = info.channels > 2 ? "aformat=channel_layouts=stereo," : ""
    return try await reencode(src, suffix: stereo ? "-stereo" : "-mono", video: false, filters: ["-af", down + pan])
  }

  /// EBU R128 measurement (ffmpeg loudnorm, first pass).
  static func loudness(_ src: URL) async throws -> Loudness {
    let log = try await FFmpeg.exec(["-i", "fd:", "-vn", "-af", "loudnorm=print_format=json", "-f", "wav", "fd:"], stdin: src, log: "info")
    guard let a = log.range(of: "{", options: .backwards), let b = log.range(of: "}", options: .backwards),
          let json = try? JSONSerialization.jsonObject(with: Data(log[a.lowerBound...b.lowerBound].utf8)) as? [String: String] else {
      throw ToolError("Couldn't measure \(src.lastPathComponent)")
    }
    func v(_ k: String) -> Double { Double(json[k] ?? "") ?? -.infinity }
    let m = Loudness(i: v("input_i"), tp: v("input_tp"), lra: v("input_lra"), thresh: v("input_thresh"), offset: v("target_offset"))
    guard m.i.isFinite, m.tp.isFinite, m.thresh.isFinite else { throw ToolError("\(src.lastPathComponent) is silent") }
    return m
  }

  /// Two-pass loudnorm to `target` LUFS with a true-peak ceiling, keeping the sample rate and format.
  static func normalizeLoudness(_ src: URL, target: Double, truePeak: Double = -1.5) async throws -> URL {
    let m = try await loudness(src)
    let rate = try await FFmpeg.probe(src).sampleRate
    let lra = min(max(m.lra.isFinite ? m.lra : 7, 7), 20)  // a target at least the measured range keeps it linear
    let af = "loudnorm=I=\(target):TP=\(truePeak):LRA=\(lra):measured_I=\(m.i):measured_TP=\(m.tp):measured_LRA=\(m.lra.isFinite ? m.lra : 0)"
      + ":measured_thresh=\(m.thresh):offset=\(m.offset.isFinite ? m.offset : 0):linear=true,aresample=\(rate > 0 ? rate : 48000)"
    return try await reencode(src, suffix: "-normalized", video: false, filters: ["-af", af])
  }

  // MARK: Audio to video, compression

  /// Bars of the waveform on a dark canvas.
  static func waveformImage(_ src: URL, size: CGSize) async throws -> CGImage {
    let bars = 120
    let p = try await peaks(src, count: bars)
    let W = Int(size.width), H = Int(size.height)
    guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ToolError("Out of memory") }
    ctx.setFillColor(CGColor(red: 0.07, green: 0.07, blue: 0.08, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(CGColor(red: 1, green: 0.78, blue: 0.1, alpha: 1))
    let top = max(p.max() ?? 1, 0.001)
    let area = CGRect(x: size.width * 0.08, y: size.height * 0.3, width: size.width * 0.84, height: size.height * 0.4)
    let step = area.width / CGFloat(bars)
    for i in 0..<bars {
      let v = i * p.count / bars < p.count ? CGFloat(p[i * p.count / bars] / top) : 0
      let h = max(step * 0.6, area.height * v)
      ctx.addPath(CGPath(roundedRect: CGRect(x: area.minX + CGFloat(i) * step + step * 0.2, y: area.midY - h / 2, width: step * 0.6, height: h),
                         cornerWidth: step * 0.3, cornerHeight: step * 0.3, transform: nil))
    }
    ctx.fillPath()
    guard let img = ctx.makeImage() else { throw ToolError("Couldn't draw the waveform") }
    return img
  }

  /// MP4 with a still picture (or the waveform) for the length of the audio.
  static func audioToVideo(_ src: URL, image: URL? = nil, canvas: CGSize = CGSize(width: 1920, height: 1080)) async throws -> URL {
    let still = FFmpeg.temp("png")
    defer { try? FileManager.default.removeItem(at: still) }
    let img = if let image { try ImageTools.decode(image).0 } else { try await waveformImage(src, size: canvas) }
    try ImageTools.write(img, props: [:], type: .png, to: still)
    let W = Int(canvas.width), H = Int(canvas.height)
    let out = outputURL(for: src, ext: "mp4")
    try await FFmpeg.exec(["-i", "fd:", "-loop", "1", "-framerate", "2", "-i", still.path, "-filter_complex",
                           "[1:v]scale=\(W):\(H):force_original_aspect_ratio=decrease:force_divisible_by=2,pad=\(W):\(H):(ow-iw)/2:(oh-ih)/2:color=black,format=yuv420p[v]",
                           "-map", "[v]", "-map", "0:a", "-shortest"] + FFmpeg.h264 + ["-c:a", "aac", "-b:a", "192k", "-f", "mp4", "fd:"],
                          stdin: src, stdout: out)
    return out
  }

  static func compressVideo(_ src: URL, settings: VideoCompressSettings) async throws -> URL {
    let out = outputURL(for: src, ext: "mp4", suffix: "-small")
    try await FFmpeg.exec(["-i", "fd:"] + settings.args + ["-f", "mp4", "fd:"], stdin: src, stdout: out)
    return out
  }

  /// Result size: exact for short videos, else extrapolated from a 4 s sample in the middle.
  static func estimateCompressed(_ src: URL, settings: VideoCompressSettings) async throws -> (bytes: Int, exact: Bool) {
    let d = try await FFmpeg.probe(src).duration
    let sample = min(d, 4), exact = d <= 8
    let tmp = FFmpeg.temp("mp4")
    defer { try? FileManager.default.removeItem(at: tmp) }
    try await FFmpeg.exec((exact ? [] : ["-ss", "\(d / 2 - 2)", "-t", "\(sample)"]) + ["-i", "fd:"] + settings.args + ["-f", "mp4", "fd:"],
                          stdin: src, stdout: tmp)
    let bytes = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    return (exact ? bytes : Int(Double(bytes) * d / sample), exact)
  }
}
