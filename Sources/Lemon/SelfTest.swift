import AppKit
import SwiftUI
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// `Lemon --selftest`: runs every tool on generated files and reports PASS/FAIL. Returns the failure count.
@MainActor enum SelfTest {
  static var failures = 0

  static func check(_ ok: Bool, _ name: String) {
    print(ok ? "PASS" : "FAIL", name)
    if !ok { failures += 1 }
  }

  static func attempt(_ name: String, _ body: () async throws -> Bool) async {
    do { check(try await body(), name) } catch { check(false, "\(name): \(error.localizedDescription)") }
  }

  static func expectError(_ name: String, _ body: () async throws -> Void) async {
    do { try await body(); check(false, name) } catch { check(true, name) }
  }

  static func run() async -> Int32 {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lemon-selftest-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    func tool(_ id: String) -> Tool { Tools.all.first { $0.id == id }! }
    func run(_ id: String, _ urls: [URL]) async throws -> [URL] { try await tool(id).run(urls) }
    func props(_ u: URL) -> [CFString: Any] {
      CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
    }
    func text(_ u: URL) throws -> String { try String(contentsOf: u, encoding: .utf8) }
    func write(_ name: String, _ s: String) -> URL {
      let u = dir.appendingPathComponent(name)
      try! s.write(to: u, atomically: true, encoding: .utf8)
      return u
    }

    // Image: 40x20 JPEG with GPS and orientation 6 (displayed rotated 90°).
    let jpg = dir.appendingPathComponent("photo.jpg")
    let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
    let d = CGImageDestinationCreateWithURL(jpg as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, [
      kCGImagePropertyOrientation: 6,
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.97, kCGImagePropertyGPSLatitudeRef: "N"],
    ] as CFDictionary)
    CGImageDestinationFinalize(d)

    for m in FanMode.allCases { print("\(m.label) tools for photo.jpg:", Tools.available(for: [jpg], mode: m).map(\.short)) }
    let avif = UTType("public.avif").map(ImageTools.canWrite) == true
    for id in ["img.png", "img.heic", "img.tiff", "img.bmp"] + (ImageTools.canWrite(.webP) ? ["img.webp"] : []) + (avif ? ["img.avif"] : []) {
      await attempt(id) {
        let p = props(try await run(id, [jpg])[0])
        // orientation baked in: 40x20 shown rotated becomes 20x40
        return p[kCGImagePropertyPixelWidth] as? Int == 20 && p[kCGImagePropertyPixelHeight] as? Int == 40
      }
    }
    var png = jpg
    await attempt("img.webp") {
      let p = props(try await run("img.webp", [jpg])[0])
      return p[kCGImagePropertyPixelWidth] as? Int == 20 && p[kCGImagePropertyPixelHeight] as? Int == 40
    }
    await attempt("img.jpg from PNG") {
      png = try await run("img.png", [jpg])[0]
      return props(try await run("img.jpg", [png])[0])[kCGImagePropertyPixelWidth] as? Int == 20
    }
    await attempt("img.topdf combines 2 images") { PDFDocument(url: try await run("img.topdf", [jpg, jpg])[0])?.pageCount == 2 }
    await attempt("edit.metadata removes GPS, keeps orientation and pixels") {
      let p = props(try await run("edit.metadata", [jpg])[0])
      return p[kCGImagePropertyGPSDictionary] == nil && p[kCGImagePropertyOrientation] as? Int == 6 && p[kCGImagePropertyPixelWidth] as? Int == 40
    }
    await attempt("edit.rotate") {
      let p = props(try await run("edit.rotate", [jpg])[0])
      return p[kCGImagePropertyPixelWidth] as? Int == 40 && p[kCGImagePropertyPixelHeight] as? Int == 20
    }
    await attempt("crop: top-left quarter") {
      let p = props(try ImageTools.crop(jpg, rect: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
      return p[kCGImagePropertyPixelWidth] as? Int == 10 && p[kCGImagePropertyPixelHeight] as? Int == 20
    }
    await attempt("edit.crop default") { props(try await run("edit.crop", [jpg])[0])[kCGImagePropertyPixelWidth] as? Int == 16 }
    await attempt("transform: half turn + flip keeps size, 3 turns swaps") {
      let a = props(try ImageTools.transform(jpg, quarterTurns: 2, flipH: true))
      let b = props(try ImageTools.transform(jpg, quarterTurns: -1))
      return a[kCGImagePropertyPixelWidth] as? Int == 20 && b[kCGImagePropertyPixelWidth] as? Int == 40
    }
    await attempt("transform: pixels land where the preview shows them") {
      // 2x1 image, red left / blue right; one clockwise turn puts red on top.
      let src = dir.appendingPathComponent("rb.png")
      let c = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
      c.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); c.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
      try ImageTools.write(c.makeImage()!, props: [:], type: .png, to: src)
      let (out, _) = try ImageTools.decode(try ImageTools.transform(src, quarterTurns: 1))
      let rep = NSBitmapImageRep(cgImage: out)
      return out.width == 1 && out.height == 2 && (rep.colorAt(x: 0, y: 0)?.redComponent ?? 0) > 0.9
    }
    await attempt("compress to a target size fits it") {
      // noisy 600x600 image so the size depends on quality
      let big = dir.appendingPathComponent("noise.png")
      let c = CGContext(data: nil, width: 600, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      var rng = SystemRandomNumberGenerator()
      for y in stride(from: 0, to: 600, by: 4) { for x in stride(from: 0, to: 600, by: 4) {
        c.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng), blue: 0.5, alpha: 1))
        c.fill(CGRect(x: x, y: y, width: 4, height: 4))
      } }
      try ImageTools.write(c.makeImage()!, props: [:], type: .png, to: big)
      let target = 40_000
      let data = try ImageTools.compressedData(big, settings: CompressSettings(targetBytes: target)).data
      let low = try ImageTools.compressedData(big, settings: CompressSettings(quality: 0.2)).data
      let high = try ImageTools.compressedData(big, settings: CompressSettings(quality: 0.9)).data
      return data.count <= target && data.count > target / 3 && low.count < high.count
    }
    await attempt("edit.compress image") { try await run("edit.compress", [png])[0].pathExtension == "jpg" }
    await attempt("edit.collage") { props(try await run("edit.collage", [jpg, png, jpg])[0])[kCGImagePropertyPixelWidth] as? Int == 2 * 600 + 3 * 12 }
    await expectError("edit.qr reports no code") { _ = try await run("edit.qr", [jpg]) }
    await imagePack(dir: dir)  // ImageSelfTest.swift
    do {  // live-preview budget: every adjustment on a 1100 px preview, 5 renders
      let c = CGContext(data: nil, width: 1100, height: 1100, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      c.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1100, height: 1100))
      let img = c.makeImage()!
      var all = Adjustments(exposure: 0.2, brightness: 0.1, contrast: 0.2, highlights: 0.2, shadows: 0.2, whites: 0.1, blacks: 0.1,
                            temperature: 0.2, tint: 0.1, saturation: 0.2, vibrance: 0.2, hue: 0.1, sharpness: 0.3, clarity: 0.3,
                            noise: 0.3, vignette: 0.3, grain: 0.3, fade: 0.1, blur: 0.1)
      _ = ImageTools.adjusted(img, all, scale: 0.5)  // warm up shaders
      let t0 = Date()
      for i in 0..<5 { all.exposure = Double(i) / 10; _ = ImageTools.adjusted(img, all, scale: 0.5) }
      let ms = Date().timeIntervalSince(t0) / 5 * 1000
      print(String(format: "preview render: %.0f ms (all adjustments, 1100 px)", ms))
      check(ms < 120, "live preview renders fast enough to track a slider")
    }

    // Documents.
    let txt = write("note.txt", "Hello Lemon\nSecond line")
    for id in ["doc.docx", "doc.rtf", "doc.html", "doc.odt"] {
      await attempt(id) { try DocTools.read(try await run(id, [txt])[0]).string.contains("Hello Lemon") }
    }
    var pdf = txt
    await attempt("doc.pdf") {
      pdf = try await run("doc.pdf", [txt])[0]
      return PDFDocument(url: pdf)?.string?.contains("Hello Lemon") == true
    }
    await attempt("doc.txt from DOCX") {
      let docx = try await run("doc.docx", [txt])[0]
      return try text(try await run("doc.txt", [docx])[0]).contains("Hello Lemon")
    }

    // PDF.
    await attempt("pdf.png") { try await run("pdf.png", [pdf]).allSatisfy { NSImage(contentsOf: $0) != nil } }
    await attempt("pdf.jpg") { try await run("pdf.jpg", [pdf]).allSatisfy { $0.pathExtension == "jpg" && NSImage(contentsOf: $0) != nil } }
    await attempt("pdf.txt") { try text(try await run("pdf.txt", [pdf])[0]).contains("Hello") }
    await attempt("pdf.docx") { try DocTools.read(try await run("pdf.docx", [pdf])[0]).string.contains("Hello") }
    await attempt("pdf.rtf") { try DocTools.read(try await run("pdf.rtf", [pdf])[0]).string.contains("Hello") }
    await attempt("edit.merge") { PDFDocument(url: try await run("edit.merge", [pdf, pdf])[0])?.pageCount == 2 }
    await attempt("edit.split") { try await run("edit.split", [pdf]).count == 1 }
    await attempt("edit.compress.pdf") { PDFDocument(url: try await run("edit.compress.pdf", [pdf])[0]) != nil }
    await attempt("edit.rotate.pdf") { PDFDocument(url: try await run("edit.rotate.pdf", [pdf])[0])?.page(at: 0)?.rotation == 90 }
    await attempt("edit.metadata.pdf") { PDFDocument(url: try await run("edit.metadata.pdf", [pdf])[0]) != nil }

    // Audio: 1s stereo sine WAV at -10 dBFS.
    let wav = dir.appendingPathComponent("tone.wav")
    do {  // scope closes the file so its header is final before the tools read it
      let fmt = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
      let file = try! AVAudioFile(forWriting: wav, settings: fmt.settings)
      let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 44_100)!
      buf.frameLength = 44_100
      for c in 0..<2 { for i in 0..<44_100 { buf.floatChannelData![c][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100)) * 0.3 } }
      try! file.write(from: buf)
    }
    func seconds(_ u: URL) async throws -> Double { try await AVURLAsset(url: u).load(.duration).seconds }
    // AVFoundation can read these back directly.
    for id in ["aud.m4a", "aud.aiff", "aud.flac", "aud.mp3"] {
      await attempt(id) { try await seconds(try await run(id, [wav])[0]) > 0.9 }
    }
    // These it can't: decode them back to WAV with ffmpeg, which also proves Lemon reads them.
    for id in ["aud.ogg", "aud.opus", "aud.wma"] {
      await attempt("\(id) and back to WAV") { try await seconds(try await run("aud.wav", [try await run(id, [wav])[0]])[0]) > 0.9 }
    }
    await attempt("aud.wav from AIFF") { try await seconds(try await run("aud.wav", [try await run("aud.aiff", [wav])[0]])[0]) > 0.9 }
    await attempt("edit.normalize raises peak to ~1.0") {
      let f = try AVAudioFile(forReading: try await run("edit.normalize", [wav])[0])
      let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
      try f.read(into: b)
      let peak = (0..<Int(b.frameLength)).map { abs(b.floatChannelData![0][$0]) }.max() ?? 0
      return peak > 0.95 && peak <= 1.0
    }
    await attempt("edit.mono") { try AVAudioFile(forReading: try await run("edit.mono", [wav])[0]).fileFormat.channelCount == 1 }

    // Video: 2s silent H.264 MOV.
    let mov = dir.appendingPathComponent("clip.mov")
    try! await makeVideo(mov)
    for id in ["vid.mp4", "edit.compress.video", "edit.mute"] {
      await attempt(id) { try await seconds(try await run(id, [mov])[0]) > 1.5 }
    }
    for id in ["vid.mkv", "vid.webm", "vid.avi", "vid.wmv"] {
      await attempt("\(id) and back to MP4") { try await seconds(try await run("vid.mp4", [try await run(id, [mov])[0]])[0]) > 1.5 }
    }
    await attempt("edit.mute keeps MKV container") {
      let mkv = try await run("vid.mkv", [mov])[0]
      return try await run("edit.mute", [mkv])[0].pathExtension == "mkv"
    }
    await attempt("vid.mov from MP4") { try await seconds(try await run("vid.mov", [try await run("vid.mp4", [mov])[0]])[0]) > 1.5 }
    await attempt("vid.gif") { (CGImageSourceCreateWithURL(try await run("vid.gif", [mov])[0] as CFURL, nil).map(CGImageSourceGetCount) ?? 0) >= 20 }
    await attempt("edit.snapshots") {
      let folder = try await run("edit.snapshots", [mov])[0]
      return try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }.count == 10
    }
    await expectError("vid.m4a fails cleanly on a silent video") { _ = try await run("vid.m4a", [mov]) }

    await mediaPack(dir: dir)  // MediaSelfTest.swift

    // Spreadsheets and subtitles.
    let csv = write("table.csv", "name,note\n\"Lemon, Inc\",\"says \"\"hi\"\"\"\nplain,two\n")
    await attempt("sheet.tsv keeps quoted commas") {
      let t = try text(try await run("sheet.tsv", [csv])[0])
      return t.contains("Lemon, Inc\tsays \"\"hi\"\"") == false && t.contains("Lemon, Inc\t\"says \"\"hi\"\"\"")
    }
    await attempt("sheet.csv round-trips") {
      let back = try text(try await run("sheet.csv", [try await run("sheet.tsv", [csv])[0]])[0])
      return back == "name,note\n\"Lemon, Inc\",\"says \"\"hi\"\"\"\nplain,two\n"
    }
    let srt = write("subs.srt", "1\n00:00:01,000 --> 00:00:02,500\nHello\n\n2\n00:00:03,000 --> 00:00:04,000\nWorld\n")
    await attempt("sub.vtt") {
      let v = try text(try await run("sub.vtt", [srt])[0])
      return v.hasPrefix("WEBVTT") && v.contains("00:00:01.000 --> 00:00:02.500\nHello")
    }
    await attempt("sub.srt from VTT round-trips") {
      let back = try text(try await run("sub.srt", [try await run("sub.vtt", [srt])[0]])[0])
      return back.contains("1\n00:00:01,000 --> 00:00:02,500\nHello") && back.contains("2\n00:00:03,000 --> 00:00:04,000\nWorld")
    }

    // Archives.
    var zip = txt
    await attempt("act.zip single") { zip = try await run("act.zip", [txt])[0]; return zip.lastPathComponent == "note.txt.zip" }
    await attempt("act.zip multiple") { try await run("act.zip", [txt, jpg])[0].lastPathComponent.hasPrefix("Archive") }
    await attempt("edit.extract") {
      FileManager.default.fileExists(atPath: try await run("edit.extract", [zip])[0].appendingPathComponent("note.txt").path)
    }
    for id in ["arc.tar", "arc.tar.gz"] {
      await attempt("\(id) then extract") {
        let repacked = try await run(id, [zip])[0]
        return FileManager.default.fileExists(atPath: try await run("edit.extract", [repacked])[0].appendingPathComponent("note.txt").path)
      }
    }
    await attempt("arc.zip from tar") {
      let tar = try await run("arc.tar", [zip])[0]
      return try await run("arc.zip", [tar])[0].pathExtension == "zip"
    }

    // Actions that only touch the clipboard.
    await attempt("act.path") { _ = try await run("act.path", [txt, jpg]); return NSPasteboard.general.string(forType: .string) == "\(txt.path)\n\(jpg.path)" }
    await attempt("act.copy") {
      _ = try await run("act.copy", [txt])
      return (NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL])?.first?.lastPathComponent == "note.txt"
    }

    // Routing.
    func ids(_ urls: [URL], _ m: FanMode) -> [String] { Tools.available(for: urls, mode: m).map(\.id) }
    check(!ids([jpg], .convert).contains("img.jpg") && ids([png], .convert).contains("img.jpg"), "convert hides the file's own format")
    check(ids([pdf, pdf], .edit).contains("edit.merge") && !ids([pdf], .edit).contains("edit.merge"), "Merge only for 2+ PDFs")
    check(ids([txt, jpg], .convert).isEmpty && ids([txt, jpg], .action).contains("act.zip"), "mixed kinds: no conversions, actions available")
    check(FanMode.allCases.allSatisfy { m in [jpg, pdf, mov, wav, txt, csv, srt, zip].allSatisfy { ids([$0], m).count <= Tools.maxInFan } },
          "dial never exceeds \(Tools.maxInFan) petals")
    check(FileKind(URL(fileURLWithPath: "a.mkv")) == .video && FileKind(URL(fileURLWithPath: "a.ogg")) == .audio, "MKV/OGG recognised")
    check(FanMode([.command]) == .edit && FanMode([.control]) == .action && FanMode([.shift]) == .convert, "modifier keys pick the mode")
    check(DialGeo.index(dx: 0, dy: 100, of: 6) == 0 && DialGeo.index(dx: 100, dy: 0, of: 4) == 1 && DialGeo.index(dx: 0, dy: 10, of: 6) == nil,
          "dial hit-testing: top is petal 0, clockwise, hub ignored")

    await compressResizePack(dir: dir)  // CompressResizeTests.swift
    await floatPack(dir: dir)
    await pdfPack(dir: dir)  // PDFSelfTest.swift
    await officePack(dir: dir)  // OfficeSelfTest.swift
    await extrasPack(dir: dir)  // ExtraSelfTest.swift
    if let i = CommandLine.arguments.firstIndex(of: "--demo"), i + 1 < CommandLine.arguments.count {
      let photo = dir.appendingPathComponent("demo/photo.jpg")
      try? FileManager.default.createDirectory(at: photo.deletingLastPathComponent(), withIntermediateDirectories: true)
      let c = CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
        CGColor(red: 1, green: 0.62, blue: 0.35, alpha: 1), CGColor(red: 0.42, green: 0.36, blue: 0.85, alpha: 1)] as CFArray, locations: nil)!
      c.drawLinearGradient(sky, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 300), options: [])
      c.setFillColor(CGColor(red: 1, green: 0.85, blue: 0.3, alpha: 1)); c.fillEllipse(in: CGRect(x: 150, y: 70, width: 100, height: 100))
      c.setFillColor(CGColor(red: 0.18, green: 0.2, blue: 0.35, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 400, height: 80))
      try? ImageTools.write(c.makeImage()!, props: [:], type: .jpeg, to: photo)
      renderDemo(photo: photo, to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
    }
    if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
      let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
      renderPreview(urls: [jpg], to: out)
      renderMenuBarIcon(to: out.deletingPathExtension().appendingPathExtension("menubar.png"))
      renderPreview(urls: [jpg, jpg], to: out.deletingPathExtension().appendingPathExtension("many.png"))
      let long = dir.appendingPathComponent("Holiday photos from the lake house weekend.jpg")
      try? FileManager.default.copyItem(at: jpg, to: long)
      renderPreview(urls: [long], to: out.deletingPathExtension().appendingPathExtension("long.png"))
      renderEditors(jpg: jpg, to: out.deletingPathExtension().appendingPathExtension("editors.png"))
    }
    print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
    return Int32(failures)
  }

  /// Renders the dial in each mode (plain fills; Liquid Glass only draws in a live window).
  static func renderPreview(urls: [URL], to out: URL) {
    lemonPlainRender = true
    defer { lemonPlainRender = false }
    let views = FanMode.allCases.map { m -> DialContent in
      let model = DialModel()
      model.load(urls, mode: m)
      model.hover = 0
      model.shown = true  // skip the opening animation
      return DialContent(model: model)
    }
    let r = ImageRenderer(content: HStack(spacing: 0) { ForEach(0..<views.count, id: \.self) { views[$0] } }
      .background(Color(red: 0.75, green: 0.82, blue: 0.9)))
    r.scale = 2
    if let t = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
      try? png.write(to: out)
      print("rendered", out.path)
    }
  }

  /// The three editor windows side by side (plain fills; native controls don't draw offscreen).
  static func renderEditors(jpg: URL, to out: URL) {
    lemonPlainRender = true
    defer { lemonPlainRender = false }
    let photo = dir(jpg).appendingPathComponent("preview.png")
    let c = CGContext(data: nil, width: 900, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let colors = [CGColor(red: 0.35, green: 0.6, blue: 0.9, alpha: 1), CGColor(red: 0.95, green: 0.75, blue: 0.2, alpha: 1), CGColor(red: 0.3, green: 0.7, blue: 0.4, alpha: 1)]
    for (i, col) in colors.enumerated() { c.setFillColor(col); c.fill(CGRect(x: 0, y: i * 200, width: 900, height: 200)) }
    try? ImageTools.write(c.makeImage()!, props: [:], type: .png, to: photo)
    let views = HStack(spacing: 20) {
      EditorChrome(content: CropEditor(urls: [photo, photo], close: {})).frame(width: 820, height: 640)
      EditorChrome(content: CompressEditor(urls: [photo], close: {})).frame(width: 860, height: 560)
      EditorChrome(content: RotateEditor(urls: [photo], close: {})).frame(width: 640, height: 600)
    }.padding(20).background(Color(red: 0.75, green: 0.82, blue: 0.9))
    let r = ImageRenderer(content: views)
    if let t = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
      try? png.write(to: out)
      print("rendered", out.path)
    }
  }

  private static func dir(_ u: URL) -> URL { u.deletingLastPathComponent() }

  /// The menu bar icon tinted as macOS does for light and dark menu bars, at 1x/2x/6x.
  static func renderMenuBarIcon(to out: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 520, pixelsHigh: 140, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    for (row, (bg, fg)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.15, alpha: 1), NSColor.white)].enumerated() {
      bg.setFill()
      NSRect(x: 0, y: CGFloat(row) * 70, width: 520, height: 70).fill()
      var x: CGFloat = 12
      for scale: CGFloat in [1, 2, 6] {
        let s = 18 * scale
        let tinted = NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
          NSImage.lemonTemplate.draw(in: r)
          fg.set()
          r.fill(using: .sourceAtop)
          return true
        }
        tinted.draw(in: NSRect(x: x, y: CGFloat(row) * 70 + (70 - min(s, 60)) / 2, width: min(s, 60), height: min(s, 60)))
        x += min(s, 60) + 24
      }
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: out)
  }

  static func makeVideo(_ url: URL) async throws {
    let w = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
    ])
    w.add(input)
    w.startWriting()
    w.startSession(atSourceTime: .zero)
    for i in 0..<20 {
      while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
      var pb: CVPixelBuffer?
      CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
      CVPixelBufferLockBaseAddress(pb!, [])
      memset(CVPixelBufferGetBaseAddress(pb!), Int32(i * 12), CVPixelBufferGetDataSize(pb!))
      CVPixelBufferUnlockBaseAddress(pb!, [])
      adaptor.append(pb!, withPresentationTime: CMTime(value: Int64(i), timescale: 10))
    }
    input.markAsFinished()
    w.endSession(atSourceTime: CMTime(value: 20, timescale: 10))
    await w.finishWriting()
  }
}
