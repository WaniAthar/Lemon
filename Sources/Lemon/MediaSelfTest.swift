import AppKit
import AVFoundation
import SwiftUI

extension SelfTest {
  /// Video and audio editing tools on generated media.
  static func mediaPack(dir: URL) async {
    func tool(_ id: String) -> Tool { Tools.all.first { $0.id == id }! }
    func info(_ u: URL) async throws -> MediaInfo { try await FFmpeg.probe(u) }
    func near(_ a: Double, _ b: Double, _ tol: Double = 0.15) -> Bool { abs(a - b) <= tol }

    // 2 s, 128x128 fine checkerboard (2 px cells) MOV with a 440 Hz AAC track; WAVs with tone, padded tone.
    let tone = dir.appendingPathComponent("m-tone.wav"), padded = dir.appendingPathComponent("m-padded.wav")
    writeTone(tone, seconds: 2, lead: 0, tail: 0)
    writeTone(padded, seconds: 1, lead: 0.5, tail: 0.5)
    let silentMov = dir.appendingPathComponent("m-checker.mov"), mov = dir.appendingPathComponent("m-av.mov")
    let small = dir.appendingPathComponent("m-small.mov")
    do {
      try await makeChecker(silentMov, side: 128)
      try await makeChecker(small, side: 64)
      try await FFmpeg.exec(["-i", silentMov.path, "-i", tone.path, "-c:v", "copy", "-c:a", "aac", "-shortest", "-f", "mov", "fd:"], stdout: mov)
    } catch { check(false, "media fixtures: \(error.localizedDescription)"); return }

    await attempt("probe: size, duration, tracks") {
      let i = try await info(mov)
      return i.size == CGSize(width: 128, height: 128) && near(i.duration, 2) && i.hasVideo && i.hasAudio && i.channels == 2
    }
    var mkv = mov
    await attempt("trim MOV keeps container and length") {
      let out = try await MediaTools.trim(mov, 0.5...1.5)
      let d = try await info(out).duration
      return out.pathExtension == "mov" && near(d, 1)
    }
    await attempt("trim WAV") { near(try await info(try await MediaTools.trim(tone, 0.25...0.75)).duration, 0.5, 0.02) }
    await attempt("trim MKV (re-encoded, frame-accurate)") {
      mkv = try await FFmpeg.convert(mov, ext: "mkv", format: "matroska", args: FFmpeg.video[2].args)
      let out = try await MediaTools.trim(mkv, 1.0...2.0)
      let d = try await info(out).duration
      return out.pathExtension == "mkv" && near(d, 1)
    }
    await attempt("audible range finds the tone inside silence") {
      guard let r = try await MediaTools.audibleRange(padded, thresholdDB: -40) else { return false }
      return near(r.lowerBound, 0.5, 0.03) && near(r.upperBound, 1.5, 0.03)
    }
    await attempt("edit.trim one-click cuts silence") { near(try await info(try await tool("edit.trim").run([padded])[0]).duration, 1, 0.05) }
    await attempt("split MOV merged drops the middle clip") {
      let outs = try await MediaTools.split(mov, cuts: [1.2, 0.5], removed: [1], merged: true)
      let d = try await info(outs[0]).duration
      return outs.count == 1 && near(d, 1.3)
    }
    await attempt("split MOV into separate clips") {
      let outs = try await MediaTools.split(mov, cuts: [0.5, 1.2], removed: [1], merged: false)
      let d = [try await info(outs[0]).duration, try await info(outs[1]).duration]
      return outs.count == 2 && near(d[0], 0.5) && near(d[1], 0.8) && outs[1].lastPathComponent.contains("-part2")
    }
    await attempt("split MKV merged (ffmpeg)") {
      let outs = try await MediaTools.split(mkv, cuts: [0.5, 1.2], removed: [1], merged: true)
      let i = try await info(outs[0])
      return outs[0].pathExtension == "mkv" && near(i.duration, 1.3) && i.hasAudio
    }
    await attempt("edit.split.video one-click halves") { try await tool("edit.split.video").run([mov]).count == 2 }
    await attempt("join: different sizes, silent + sound, duration ≈ sum") {
      let out = try await tool("edit.join").run([mov, small])[0]
      let i = try await info(out)
      return near(i.duration, 4, 0.2) && i.size == CGSize(width: 128, height: 128) && i.hasAudio
    }
    await attempt("speed 2x video with audio") {
      let i = try await info(try await MediaTools.speed(mov, factor: 2))
      return near(i.duration, 1, 0.1) && i.hasAudio
    }
    await attempt("speed 4x drops audio when asked") {
      let i = try await info(try await MediaTools.speed(mov, factor: 4, keepAudio: false))
      return near(i.duration, 0.5, 0.12) && !i.hasAudio
    }
    await attempt("speed 0.25x audio (chained atempo)") { near(try await info(try await MediaTools.speed(tone, factor: 0.25)).duration, 8, 0.1) }
    check(MediaTools.atempo(4) == "atempo=2.0,atempo=2.0" && MediaTools.atempo(0.25) == "atempo=0.5,atempo=0.5", "atempo chain")
    await attempt("snapshots at chosen times") {
      let folder = try await MediaTools.snapshots(mov, at: [0.2, 1.0, 1.8])
      return try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }.count == 3
    }
    await attempt("snapshots of MKV via preview proxy") {
      let folder = try await tool("edit.snapshots").run([mkv])[0]
      return try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }.count == 10
    }

    // Redaction: box in the centre from 0.5 s to 1.5 s.
    let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    let inner = CGRect(x: 40, y: 40, width: 48, height: 48), outer = CGRect(x: 2, y: 2, width: 24, height: 24)
    for style in VideoRedactStyle.allCases {
      await attempt("redact \(style.rawValue): box changes only inside, only during the range") {
        let out = try await MediaTools.redact(mov, [Redaction(rect: box, start: 0.5, end: 1.5)], style: style)
        let during = try await frame(out, 1.0), before = try await frame(out, 0.2)
        let a = stats(during, inner), b = stats(before, inner), o = stats(during, outer)
        let hidden = style == .black ? a.mean < 0.08 : a.deviation < 0.06
        let audio = try await info(out).hasAudio
        return hidden && b.deviation > 0.2 && o.deviation > 0.2 && audio
      }
    }
    await expectError("redact without boxes asks for the editor") { _ = try await tool("edit.redact.video").run([mov]) }

    await attempt("bleep: silence in range, tone kept outside") {
      let out = try await MediaTools.bleep(tone, ranges: [0.5...1.0], tone: false)
      return rms(out, 0.55...0.95).rms < 0.001 && near(rms(out, 1.1...1.9).rms, 0.212, 0.01)
    }
    await attempt("bleep: 1 kHz tone in range") {
      let r = rms(try await MediaTools.bleep(tone, ranges: [0.5...1.0]), 0.55...0.95)
      return near(r.rms, 0.177, 0.01) && near(r.crossingsPerSecond, 2000, 60)
    }
    await attempt("bleep OGG keeps the format") {
      let ogg = try await FFmpeg.convert(tone, ext: "ogg", format: "ogg", args: FFmpeg.audio[4].args)
      let out = try await MediaTools.bleep(ogg, ranges: [0.2...0.4])
      let d = try await info(out).duration
      return out.pathExtension == "ogg" && near(d, 2, 0.05)
    }
    await attempt("channels: mono") { try await info(try await tool("edit.channels").run([tone])[0]).channels == 1 }
    await attempt("channels: stereo with left muted") {
      let out = try await MediaTools.channels(tone, stereo: true, left: 0, right: 1)
      return rms(out, 0.2...1.8, channel: 0).rms < 0.001 && near(rms(out, 0.2...1.8, channel: 1).rms, 0.212, 0.01)
    }
    await attempt("audio to video: waveform MP4 has video and audio") {
      let out = try await tool("edit.audio2video").run([tone])[0]
      let asset = AVURLAsset(url: out)
      let v = try await asset.loadTracks(withMediaType: .video), a = try await asset.loadTracks(withMediaType: .audio)
      let d = try await asset.load(.duration).seconds, size = try await info(out).size
      return !v.isEmpty && !a.isEmpty && near(d, 2, 0.6) && size == CGSize(width: 1920, height: 1080)
    }
    await attempt("audio to video: still image, square") {
      let pic = dir.appendingPathComponent("m-pic.png")
      try ImageTools.write(try await MediaTools.waveformImage(tone, size: CGSize(width: 300, height: 200)), props: [:], type: .png, to: pic)
      let out = try await MediaTools.audioToVideo(tone, image: pic, canvas: CGSize(width: 1080, height: 1080))
      return try await info(out).size == CGSize(width: 1080, height: 1080)
    }
    await attempt("compress video (HEVC, 720p cap) and estimate") {
      let s = VideoCompressSettings(quality: 30, codec: .hevc, maxSide: 1280)
      let out = try await MediaTools.compressVideo(mov, settings: s)
      let est = try await MediaTools.estimateCompressed(mov, settings: s)
      let d = try await info(out).duration
      return near(d, 2) && est.exact && est.bytes > 0
    }
    await attempt("edit.compress.video one-click") { near(try await info(try await tool("edit.compress.video").run([mov])[0]).duration, 2) }
    await attempt("loudness: -23 LUFS and -14 LUFS targets") {
      let before = try await MediaTools.loudness(tone).i
      let a = try await MediaTools.loudness(try await MediaTools.normalizeLoudness(tone, target: -23)).i
      let b = try await MediaTools.loudness(try await MediaTools.normalizeLoudness(tone, target: -14, truePeak: -1)).i
      return abs(before + 23) > 5 && near(a, -23, 1) && near(b, -14, 1)
    }
    await attempt("loudness keeps WAV") {
      let out = try await MediaTools.normalizeLoudness(tone, target: -16)
      let rate = try AVAudioFile(forReading: out).fileFormat.sampleRate
      return out.pathExtension == "wav" && rate == 44_100
    }
    await attempt("peaks") { let p = try await MediaTools.peaks(padded, count: 40); return p.count == 40 && p[0] < 0.01 && p[20] > 0.25 }

    if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
      await renderMediaEditors(mov: mov, wav: tone, to: URL(fileURLWithPath: CommandLine.arguments[i + 1]).deletingPathExtension().appendingPathExtension("media.png"))
    }
  }

  // MARK: Fixtures and measurements

  static func writeTone(_ url: URL, seconds: Double, lead: Double, tail: Double) {
    let rate = 44_100.0, n = Int((lead + seconds + tail) * rate)
    let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
    let file = try! AVAudioFile(forWriting: url, settings: fmt.settings)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
    buf.frameLength = AVAudioFrameCount(n)
    for c in 0..<2 {
      for i in 0..<n {
        let t = Double(i) / rate
        buf.floatChannelData![c][i] = t < lead || t >= lead + seconds ? 0 : Float(sin(t * 2 * .pi * 440)) * 0.3
      }
    }
    try! file.write(from: buf)
  }

  static func makeChecker(_ url: URL, side: Int) async throws {
    let w = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000, AVVideoMaxKeyFrameIntervalKey: 5],
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
    ])
    w.add(input)
    w.startWriting()
    w.startSession(atSourceTime: .zero)
    for i in 0..<20 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
      var pb: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
      CVPixelBufferLockBaseAddress(pb!, [])
      let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self), row = CVPixelBufferGetBytesPerRow(pb!)
      for y in 0..<side {
        for x in 0..<side {
          let v: UInt8 = (x / 2 + y / 2) % 2 == 0 ? 255 : 0
          let p = base + y * row + x * 4
          p[0] = v; p[1] = v; p[2] = v; p[3] = 255
        }
      }
      CVPixelBufferUnlockBaseAddress(pb!, [])
      adaptor.append(pb!, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
    }
    input.markAsFinished()
    w.endSession(atSourceTime: CMTime(value: 20, timescale: 10))
    await w.finishWriting()
  }

  static func frame(_ u: URL, _ t: Double) async throws -> CGImage {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: try await MediaTools.playable(u)))
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    return try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
  }

  /// Mean and standard deviation of gray levels (0–1) in `r` (pixels, top-left origin).
  static func stats(_ img: CGImage, _ r: CGRect) -> (mean: Double, deviation: Double) {
    let rep = NSBitmapImageRep(cgImage: img)
    var vals: [Double] = []
    for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) { vals.append(Double(rep.colorAt(x: x, y: y)?.brightnessComponent ?? 0)) } }
    let mean = vals.reduce(0, +) / Double(vals.count)
    return (mean, (vals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(vals.count)).squareRoot())
  }

  static func rms(_ u: URL, _ r: ClosedRange<Double>, channel: Int = 0) -> (rms: Double, crossingsPerSecond: Double) {
    guard let f = try? AVAudioFile(forReading: u),
          let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)), (try? f.read(into: b)) != nil
    else { return (-1, 0) }
    let rate = f.processingFormat.sampleRate, s = b.floatChannelData![channel]
    let lo = Int(r.lowerBound * rate), hi = min(Int(r.upperBound * rate), Int(b.frameLength))
    var sum = 0.0, cross = 0
    for i in lo..<hi {
      sum += Double(s[i] * s[i])
      if i > lo && (s[i] >= 0) != (s[i - 1] >= 0) { cross += 1 }
    }
    return ((sum / Double(hi - lo)).squareRoot(), Double(cross) / (r.upperBound - r.lowerBound))
  }

  // MARK: Rendering

  static func renderMediaEditors(mov: URL, wav: URL, to out: URL) async {
    for u in [mov, wav] {
      let c = MediaClip(u)
      await c.loaded()
      c.seek(0.7)
      MediaClip.preloaded[u] = c
    }
    defer { MediaClip.preloaded = [:] }
    lemonPlainRender = true
    defer { lemonPlainRender = false }
    func card<V: View>(_ w: CGFloat, _ h: CGFloat, _ v: V) -> some View { EditorChrome(content: v).frame(width: w, height: h) }
    let views = VStack(alignment: .leading, spacing: 20) {
      HStack(alignment: .top, spacing: 20) {
        card(860, 600, TrimEditor(url: mov, close: {}))
        card(900, 640, SplitEditor(url: mov, close: {}))
        card(900, 600, SpeedEditor(url: mov, close: {}))
        card(860, 600, SnapshotsEditor(url: mov, close: {}))
      }
      HStack(alignment: .top, spacing: 20) {
        card(900, 640, RedactVideoEditor(url: mov, close: {}))
        card(920, 600, VideoCompressEditor(url: mov, close: {}))
        card(620, 560, JoinEditor(urls: [mov, wav], close: {}))
      }
      HStack(alignment: .top, spacing: 20) {
        card(860, 600, TrimEditor(url: wav, close: {}))
        card(860, 520, BleepEditor(url: wav, close: {}))
        card(860, 520, ChannelsEditor(url: wav, close: {}))
        card(900, 560, AudioToVideoEditor(url: wav, close: {}))
        card(900, 560, LoudnessEditor(url: wav, close: {}))
      }
    }
    .padding(20).background(Color(red: 0.75, green: 0.82, blue: 0.9))
    let r = ImageRenderer(content: views)
    if let t = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
      try? png.write(to: out)
      print("rendered", out.path)
    }
  }
}
