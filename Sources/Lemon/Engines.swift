import AppKit
import AVFoundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

// MARK: - Images (ImageIO, Vision)

struct CompressSettings: Equatable, Sendable {
  enum Format: String, CaseIterable, Sendable { case keep = "Same", jpeg = "JPEG", heic = "HEIC" }
  var quality = 0.7
  var maxSide: Int? = nil
  var format = Format.keep
  var targetBytes: Int? = nil
}

enum ImageTools {
  static func canWrite(_ t: UTType) -> Bool {
    (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(t.identifier)
  }

  /// Full-size decode with EXIF orientation applied to the pixels.
  static func decode(_ src: URL) throws -> (CGImage, [CFString: Any]) {
    if src.pathExtension.lowercased() == "svg" { return (try svg(src), [:]) }
    guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else {
      throw ToolError("Can't read \(src.lastPathComponent)")
    }
    let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    let opts: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: max(w, h, 1),
    ]
    guard let img = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else {
      throw ToolError("Can't decode \(src.lastPathComponent)")
    }
    return (img, props)
  }

  /// Metadata kept on conversion. Orientation is dropped because `decode` already rotated the pixels.
  static func keptMetadata(_ props: [CFString: Any]) -> [CFString: Any] {
    var p: [CFString: Any] = [:]
    for k in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
      if let v = props[k] { p[k] = v }
    }
    if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
      tiff[kCGImagePropertyTIFFOrientation] = nil
      p[kCGImagePropertyTIFFDictionary] = tiff
    }
    return p
  }

  static func write(_ img: CGImage, props: [CFString: Any], type: UTType, to url: URL) throws {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
      throw ToolError("This Mac can't write \(url.pathExtension.uppercased())")
    }
    var p = props
    p[kCGImageDestinationLossyCompressionQuality] = 0.85
    CGImageDestinationAddImage(d, type == .jpeg ? flatten(img) : img, p as CFDictionary)
    guard CGImageDestinationFinalize(d) else { throw ToolError("Couldn't save \(url.lastPathComponent)") }
  }

  /// JPEG has no alpha: put transparent pixels on white instead of black.
  static func flatten(_ img: CGImage) -> CGImage {
    let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
    let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    guard !opaque.contains(img.alphaInfo),
          let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return img }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(rect)
    ctx.draw(img, in: rect)
    return ctx.makeImage() ?? img
  }

  static func convert(_ src: URL, to type: UTType, ext: String) throws -> URL {
    let (img, props) = try decode(src)
    let out = outputURL(for: src, ext: ext)
    try write(img, props: keptMetadata(props), type: type, to: out)
    return out
  }

  /// Removes EXIF/GPS/XMP without re-encoding when the format allows it; keeps orientation so the photo isn't rotated.
  static func strip(_ src: URL) throws -> URL {
    guard let s = CGImageSourceCreateWithURL(src as CFURL, nil), let type = CGImageSourceGetType(s) else {
      throw ToolError("Can't read \(src.lastPathComponent)")
    }
    let out = outputURL(for: src, ext: src.pathExtension, suffix: "-clean")
    let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
    let meta = CGImageMetadataCreateMutable()
    if let o = props[kCGImagePropertyOrientation] {
      CGImageMetadataSetValueMatchingImageProperty(meta, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, o as CFTypeRef)
    }
    if let d = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) {
      let opts: [CFString: Any] = [
        kCGImageDestinationMetadata: meta,
        kCGImageDestinationMergeMetadata: false,
        kCGImageMetadataShouldExcludeGPS: true,
      ]
      if CGImageDestinationCopyImageSource(d, s, opts as CFDictionary, nil) { return out }
    }
    // Lossless copy not supported for this format: re-encode with no metadata.
    try? FileManager.default.removeItem(at: out)
    let (img, _) = try decode(src)
    let t = UTType(type as String) ?? .png
    try write(img, props: [:], type: canWrite(t) ? t : .png, to: out)
    return out
  }

  // MARK: Editors (crop, rotate, compress)

  /// Oriented preview for editor windows.
  static func preview(_ src: URL, maxPixel: Int = 1600) -> NSImage? {
    guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
          let img = CGImageSourceCreateThumbnailAtIndex(s, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
          ] as CFDictionary) else { return nil }
    return NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
  }

  /// Pixel size as displayed (EXIF orientations 5–8 swap width and height).
  static func orientedSize(_ src: URL) -> CGSize {
    guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return .zero }
    let w = p[kCGImagePropertyPixelWidth] as? Int ?? 0, h = p[kCGImagePropertyPixelHeight] as? Int ?? 0
    return (p[kCGImagePropertyOrientation] as? Int ?? 1) >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
  }

  static func sameTypeOrPNG(_ src: URL) -> (UTType, String) {
    let ext = canonicalExt(src.pathExtension)
    if let t = UTType(filenameExtension: ext), canWrite(t) { return (t, ext) }
    return (.png, "png")
  }

  /// `rect` is normalized (0–1) in the displayed image, origin top-left.
  static func crop(_ src: URL, rect r: CGRect) throws -> URL {
    let (img, props) = try decode(src)
    let W = CGFloat(img.width), H = CGFloat(img.height)
    let px = CGRect(x: r.minX * W, y: r.minY * H, width: r.width * W, height: r.height * H).integral
      .intersection(CGRect(x: 0, y: 0, width: W, height: H))
    guard px.width >= 1, px.height >= 1, let cropped = img.cropping(to: px) else { throw ToolError("The crop area is empty") }
    let (type, ext) = sameTypeOrPNG(src)
    let out = outputURL(for: src, ext: ext, suffix: "-cropped")
    try write(cropped, props: keptMetadata(props), type: type, to: out)
    return out
  }

  /// Clockwise quarter turns, flips applied in the image's own frame first (as the editor previews it).
  static func transform(_ src: URL, quarterTurns: Int, flipH: Bool = false, flipV: Bool = false) throws -> URL {
    let (img, props) = try decode(src)
    let t = ((quarterTurns % 4) + 4) % 4
    let W = img.width, H = img.height
    let (nw, nh) = t % 2 == 0 ? (W, H) : (H, W)
    guard let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ToolError("Can't rotate \(src.lastPathComponent)") }
    ctx.translateBy(x: CGFloat(nw) / 2, y: CGFloat(nh) / 2)
    ctx.rotate(by: -CGFloat(t) * .pi / 2)
    ctx.scaleBy(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
    ctx.draw(img, in: CGRect(x: -CGFloat(W) / 2, y: -CGFloat(H) / 2, width: CGFloat(W), height: CGFloat(H)))
    guard let result = ctx.makeImage() else { throw ToolError("Can't rotate \(src.lastPathComponent)") }
    let (type, ext) = sameTypeOrPNG(src)
    let out = outputURL(for: src, ext: ext, suffix: "-rotated")
    try write(result, props: keptMetadata(props), type: type, to: out)
    return out
  }

  static func rotate(_ src: URL) throws -> URL { try transform(src, quarterTurns: 1) }

  static func scaled(_ img: CGImage, maxSide: Int) -> CGImage {
    let longest = max(img.width, img.height)
    guard longest > maxSide else { return img }
    let k = Double(maxSide) / Double(longest)
    let w = max(1, Int(Double(img.width) * k)), h = max(1, Int(Double(img.height) * k))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return img }
    ctx.interpolationQuality = .high
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage() ?? img
  }

  static func encode(_ img: CGImage, props: [CFString: Any], type: UTType, quality: Double) -> Data? {
    let data = NSMutableData()
    guard let d = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    var p = props
    p[kCGImageDestinationLossyCompressionQuality] = quality
    CGImageDestinationAddImage(d, type == .jpeg ? flatten(img) : img, p as CFDictionary)
    return CGImageDestinationFinalize(d) ? data as Data : nil
  }

  /// Lossy formats keep their type; lossless ones (PNG, TIFF...) become JPEG unless a format is chosen.
  static func compressTarget(_ src: URL, _ f: CompressSettings.Format) -> (UTType, String) {
    switch f {
    case .jpeg: return (.jpeg, "jpg")
    case .heic: return (.heic, "heic")
    case .keep:
      let ext = canonicalExt(src.pathExtension)
      let lossy: [String: UTType] = ["jpg": .jpeg, "heic": .heic, "avif": UTType("public.avif") ?? .heic]
      if let t = lossy[ext], canWrite(t) { return (t, ext) }
      return (.jpeg, "jpg")
    }
  }

  /// Encoded bytes for `src`. With a target size: the highest quality that fits, shrinking the image if even low quality is too big.
  static func compressedData(_ src: URL, settings s: CompressSettings) throws -> (data: Data, ext: String) {
    let (decoded, props) = try decode(src)
    var img = s.maxSide.map { scaled(decoded, maxSide: $0) } ?? decoded
    let (type, ext) = compressTarget(src, s.format)
    let meta = keptMetadata(props)
    guard let target = s.targetBytes else {
      guard let d = encode(img, props: meta, type: type, quality: s.quality) else { throw ToolError("Couldn't compress \(src.lastPathComponent)") }
      return (d, ext)
    }
    for _ in 0..<6 {
      var lo = 0.02, hi = 0.95, best: Data?
      for _ in 0..<7 {
        let q = (lo + hi) / 2
        if let d = encode(img, props: meta, type: type, quality: q), d.count <= target { best = d; lo = q } else { hi = q }
      }
      if let best { return (best, ext) }
      img = scaled(img, maxSide: Int(Double(max(img.width, img.height)) * 0.75))
    }
    throw ToolError("Can't get \(src.lastPathComponent) that small; try a larger target")
  }

  static func compress(_ src: URL, settings: CompressSettings) throws -> URL {
    let (data, ext) = try compressedData(src, settings: settings)
    let out = outputURL(for: src, ext: ext, suffix: "-small")
    try data.write(to: out)
    return out
  }

  /// One-click default: quality 0.6, long side capped at 4096 px.
  static func compress(_ src: URL) throws -> URL { try compress(src, settings: CompressSettings(quality: 0.6, maxSide: 4096)) }

  /// Grid of square-cropped tiles, 600 px each.
  static func collage(_ urls: [URL]) throws -> URL {
    let cols = Int(ceil(sqrt(Double(urls.count)))), rows = Int(ceil(Double(urls.count) / Double(cols)))
    let cell = 600, gap = 12
    let w = cols * cell + (cols + 1) * gap, h = rows * cell + (rows + 1) * gap
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw ToolError("Couldn't create collage") }
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    for (i, u) in urls.enumerated() {
      let (img, _) = try decode(u)
      let side = min(img.width, img.height)
      guard let square = img.cropping(to: CGRect(x: (img.width - side) / 2, y: (img.height - side) / 2, width: side, height: side)) else { continue }
      let col = i % cols, row = i / cols
      let x = gap + col * (cell + gap), y = h - (row + 1) * (cell + gap)  // first image top-left
      ctx.draw(square, in: CGRect(x: x, y: y, width: cell, height: cell))
    }
    guard let out = ctx.makeImage() else { throw ToolError("Couldn't create collage") }
    let url = outputURL(for: urls[0].deletingLastPathComponent().appendingPathComponent("Collage"), ext: "jpg")
    try write(out, props: [:], type: .jpeg, to: url)
    return url
  }

  static func toPDF(_ urls: [URL]) throws -> URL {
    let doc = PDFDocument()
    for u in urls {
      let (img, _) = try decode(u)
      if let page = PDFPage(image: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))) {
        doc.insert(page, at: doc.pageCount)
      }
    }
    let out = outputURL(for: urls[0], ext: "pdf", suffix: urls.count > 1 ? "-combined" : "")
    guard doc.pageCount > 0, doc.write(to: out) else { throw ToolError("Couldn't create the PDF") }
    return out
  }

  static func ocr(_ src: URL) throws -> URL {
    let (img, _) = try decode(src)
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: img).perform([req])
    let text = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    guard !text.isEmpty else { throw ToolError("No text found in \(src.lastPathComponent)") }
    let out = outputURL(for: src, ext: "txt")
    try text.write(to: out, atomically: true, encoding: .utf8)
    return out
  }

  /// Saves the decoded QR payloads as text and copies them to the clipboard.
  static func qr(_ src: URL) throws -> URL {
    let (img, _) = try decode(src)
    let req = VNDetectBarcodesRequest()
    try VNImageRequestHandler(cgImage: img).perform([req])
    let codes = (req.results ?? []).compactMap(\.payloadStringValue)
    guard !codes.isEmpty else { throw ToolError("No QR code found in \(src.lastPathComponent)") }
    let text = codes.joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    let out = outputURL(for: src, ext: "txt", suffix: "-qr")
    try text.write(to: out, atomically: true, encoding: .utf8)
    return out
  }
}

// MARK: - PDF (PDFKit)

enum PDFTools {
  static func open(_ u: URL) throws -> PDFDocument {
    guard let d = PDFDocument(url: u) else { throw ToolError("Can't open \(u.lastPathComponent)") }
    if d.isLocked { throw ToolError("\(u.lastPathComponent) is password-protected") }
    return d
  }

  static func save(_ d: PDFDocument, to out: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws -> URL {
    guard d.write(to: out, withOptions: options) else { throw ToolError("Couldn't save \(out.lastPathComponent)") }
    return out
  }

  static func pages(_ d: PDFDocument) -> [PDFPage] {
    (0..<d.pageCount).compactMap { d.page(at: $0) }
  }

  static func merge(_ urls: [URL]) throws -> URL {
    let merged = PDFDocument()
    for u in urls {
      for p in pages(try open(u)) { merged.insert(p.copy() as! PDFPage, at: merged.pageCount) }
    }
    return try save(merged, to: outputURL(for: urls[0], ext: "pdf", suffix: "-merged"))
  }

  static func split(_ u: URL) throws -> [URL] {
    try pages(try open(u)).enumerated().map { i, p in
      let single = PDFDocument()
      single.insert(p.copy() as! PDFPage, at: 0)
      return try save(single, to: outputURL(for: u, ext: "pdf", suffix: "-p\(i + 1)"))
    }
  }

  /// Each page at 300 dpi, long side capped at 6000 px.
  static func images(_ u: URL, type: UTType, ext: String) throws -> [URL] {
    try pages(try open(u)).enumerated().map { i, p in
      guard let cg = OfficeTools.pageImage(p, dpi: 300, maxSide: 6000) else { throw ToolError("Couldn't render page \(i + 1)") }
      let out = outputURL(for: u, ext: ext, suffix: "-p\(i + 1)")
      try ImageTools.write(cg, props: [:], type: type, to: out)
      return out
    }
  }

  /// Text-only reflow into a document format.
  static func document(_ u: URL, as type: NSAttributedString.DocumentType, ext: String) throws -> URL {
    let s = NSMutableAttributedString()
    for p in pages(try open(u)) {
      if let a = p.attributedString { s.append(a); s.append(NSAttributedString(string: "\n\n")) }
    }
    guard s.length > 0 else { throw ToolError("No text in \(u.lastPathComponent)") }
    let data = try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: [.documentType: type])
    let out = outputURL(for: u, ext: ext)
    try data.write(to: out)
    return out
  }

  static func text(_ u: URL) throws -> URL {
    let s = try open(u).string ?? ""
    guard !s.isEmpty else { throw ToolError("No text in \(u.lastPathComponent) (scanned? try Pages to images, then Extract text)") }
    let out = outputURL(for: u, ext: "txt")
    try s.write(to: out, atomically: true, encoding: .utf8)
    return out
  }

  static func compress(_ u: URL) throws -> URL {
    try save(try open(u), to: outputURL(for: u, ext: "pdf", suffix: "-small"),
             options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
  }

  static func rotate(_ u: URL) throws -> URL {
    let d = try open(u)
    for p in pages(d) { p.rotation = (p.rotation + 90) % 360 }
    return try save(d, to: outputURL(for: u, ext: "pdf", suffix: "-rotated"))
  }

  static func strip(_ u: URL) throws -> URL {
    let d = try open(u)
    d.documentAttributes = [:]
    return try save(d, to: outputURL(for: u, ext: "pdf", suffix: "-clean"))
  }
}

// MARK: - Video and audio (AVFoundation)

enum MediaTools {
  /// Streams `src` through `process` (in place, per buffer) into a new file with `settings`.
  static func transcode(_ src: URL, ext: String, suffix: String = "", channels: AVAudioChannelCount? = nil,
                        settings: (AVAudioFormat) -> [String: Any],
                        process: ((AVAudioPCMBuffer, AVAudioPCMBuffer) -> Void)? = nil) throws -> URL {
    let input = try AVAudioFile(forReading: src)
    let fmt = input.processingFormat
    let outFmt = channels.flatMap { AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: $0) } ?? fmt
    let out = outputURL(for: src, ext: ext, suffix: suffix)
    var s = settings(outFmt)
    s[AVNumberOfChannelsKey] = outFmt.channelCount
    let output = try AVAudioFile(forWriting: out, settings: s, commonFormat: outFmt.commonFormat, interleaved: outFmt.isInterleaved)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 32_768),
          let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 32_768) else { throw ToolError("Out of memory") }
    while input.framePosition < input.length {
      try input.read(into: buf)
      if buf.frameLength == 0 { break }
      if let process {
        outBuf.frameLength = buf.frameLength
        process(buf, outBuf)
        try output.write(from: outBuf)
      } else {
        try output.write(from: buf)
      }
    }
    return out
  }

  /// Where `src` can be rewritten in its own format; otherwise AAC in M4A.
  static func sameOrM4A(_ src: URL) -> (ext: String, settings: (AVAudioFormat) -> [String: Any]) {
    let ext = canonicalExt(src.pathExtension)
    if ["wav", "aiff", "caf"].contains(ext) {
      return (ext, { fmt in [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: fmt.sampleRate, AVLinearPCMBitDepthKey: 16,
                             AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: ext == "aiff"] })
    }
    return ("m4a", { fmt in [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: fmt.sampleRate, AVEncoderBitRateKey: 256_000] })
  }

  /// Peak-normalizes to -0.2 dBFS.
  static func normalize(_ src: URL) throws -> URL {
    // pass 1: find the peak
    let input = try AVAudioFile(forReading: src)
    guard let buf = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32_768) else { throw ToolError("Out of memory") }
    var peak: Float = 0
    while input.framePosition < input.length {
      try input.read(into: buf)
      if buf.frameLength == 0 { break }
      for c in 0..<Int(buf.format.channelCount) {
        for i in 0..<Int(buf.frameLength) { peak = max(peak, abs(buf.floatChannelData![c][i])) }
      }
    }
    guard peak > 0 else { throw ToolError("\(src.lastPathComponent) is silent") }
    let gain = 0.977 / peak
    let target = sameOrM4A(src)
    return try transcode(src, ext: target.ext, suffix: "-normalized", settings: target.settings) { inp, out in
      for c in 0..<Int(inp.format.channelCount) {
        for i in 0..<Int(inp.frameLength) { out.floatChannelData![c][i] = inp.floatChannelData![c][i] * gain }
      }
    }
  }

  static func mono(_ src: URL) throws -> URL {
    let target = sameOrM4A(src)
    return try transcode(src, ext: target.ext, suffix: "-mono", channels: 1, settings: target.settings) { inp, out in
      let n = Int(inp.format.channelCount)
      for i in 0..<Int(inp.frameLength) {
        var sum: Float = 0
        for c in 0..<n { sum += inp.floatChannelData![c][i] }
        out.floatChannelData![0][i] = sum / Float(n)
      }
    }
  }

  /// 10 evenly spaced PNG frames in a folder next to the video.
  static func snapshots(_ src: URL) async throws -> URL {
    let asset = AVURLAsset(url: src)
    let seconds = try await asset.load(.duration).seconds
    guard seconds > 0 else { throw ToolError("\(src.lastPathComponent) has no frames") }
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    let dir = outputURL(for: src, ext: "", suffix: "-snapshots")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    for i in 0..<10 {
      let t = CMTime(seconds: seconds * (Double(i) + 0.5) / 10, preferredTimescale: 600)
      let img = try await gen.image(at: t).image
      try ImageTools.write(img, props: [:], type: .png, to: dir.appendingPathComponent(String(format: "%02d.png", i + 1)))
    }
    return dir
  }
}

// MARK: - Text formats (CSV/TSV, SRT/VTT)

enum TextTools {
  /// CSV/TSV parser that honours quoted fields with embedded separators, quotes and newlines.
  static func parse(_ text: String, separator: Character) -> [[String]] {
    var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
    var it = text.makeIterator()
    while let ch = it.next() {
      if quoted {
        if ch == "\"" {
          if let next = it.next() {
            if next == "\"" { field.append("\"") } else {
              quoted = false
              if next == separator { row.append(field); field = "" }
              else if next == "\n" || next == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
              else { field.append(next) }
            }
          } else { quoted = false }
        } else { field.append(ch) }
      } else if ch == "\"" && field.isEmpty { quoted = true }
      else if ch == separator { row.append(field); field = "" }
      else if ch == "\n" || ch == "\r\n" { row.append(field); rows.append(row); row = []; field = "" }
      else { field.append(ch) }
    }
    if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
    return rows
  }

  static func delimited(_ src: URL, to sep: Character, ext: String) throws -> URL {
    guard let rows = try Sheets.read(src).first?.rows else { throw ToolError("\(src.lastPathComponent) has no sheets") }  // ponytail: first sheet only
    let text = rows.map { row in
      row.map { f in
        f.contains(sep) || f.contains("\"") || f.contains("\n") ? "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : f
      }.joined(separator: String(sep))
    }.joined(separator: "\n") + "\n"
    let out = outputURL(for: src, ext: ext)
    try text.write(to: out, atomically: true, encoding: .utf8)
    return out
  }

  /// Subtitle cues as (timing line, text lines); handles both SRT and VTT input.
  static func cues(_ src: URL) throws -> [(String, [String])] {
    let text = try String(contentsOf: src, encoding: .utf8).replacingOccurrences(of: "\r\n", with: "\n")
    return text.components(separatedBy: "\n\n").compactMap { block in
      let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
      guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
      return (lines[i], Array(lines[(i + 1)...]))
    }
  }

  static func toSRT(_ src: URL) throws -> URL {
    let body = try cues(src).enumerated().map { n, cue in
      // VTT allows "mm:ss.mmm" and cue settings after the times; SRT needs "hh:mm:ss,mmm".
      let times = cue.0.components(separatedBy: "-->").map { part -> String in
        var t = part.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0].replacingOccurrences(of: ".", with: ",")
        if t.filter({ $0 == ":" }).count == 1 { t = "00:" + t }
        return t
      }
      return "\(n + 1)\n\(times.joined(separator: " --> "))\n\(cue.1.joined(separator: "\n"))"
    }.joined(separator: "\n\n")
    let out = outputURL(for: src, ext: "srt")
    try (body + "\n").write(to: out, atomically: true, encoding: .utf8)
    return out
  }

  static func toVTT(_ src: URL) throws -> URL {
    let body = try cues(src).map { cue in
      "\(cue.0.replacingOccurrences(of: ",", with: "."))\n\(cue.1.joined(separator: "\n"))"
    }.joined(separator: "\n\n")
    let out = outputURL(for: src, ext: "vtt")
    try ("WEBVTT\n\n" + body + "\n").write(to: out, atomically: true, encoding: .utf8)
    return out
  }
}

// MARK: - Actions (Control mode)

@MainActor enum ActionTools {
  static func airDrop(_ urls: [URL]) throws -> [URL] {
    guard let s = NSSharingService(named: .sendViaAirDrop), s.canPerform(withItems: urls) else {
      throw ToolError("AirDrop isn't available")
    }
    NSApp.activate()
    s.perform(withItems: urls)
    return []
  }

  static func copy(_ urls: [URL]) -> [URL] {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects(urls as [NSURL])
    return []
  }

  static func copyPath(_ urls: [URL]) -> [URL] {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(urls.map(\.path).joined(separator: "\n"), forType: .string)
    return []
  }

  static func move(_ urls: [URL]) throws -> [URL] {
    NSApp.activate()
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.prompt = "Move Here"
    panel.message = "Move \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") to…"
    guard panel.runModal() == .OK, let dest = panel.url else { throw ToolError("Move cancelled") }
    return try urls.map { u in
      let target = outputURL(for: dest.appendingPathComponent(u.lastPathComponent), ext: u.pathExtension)
      try FileManager.default.moveItem(at: u, to: target)
      return target
    }
  }

  static func terminal(_ urls: [URL]) async throws -> [URL] {
    let u = urls[0]
    let dir = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? u : u.deletingLastPathComponent()
    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    _ = try await NSWorkspace.shared.open([dir], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    return []
  }
}

// MARK: - Documents (NSAttributedString reads/writes txt, rtf, html, doc, docx, odt)

enum DocTools {
  static func read(_ u: URL) throws -> NSAttributedString {
    if let s = try OfficeTools.read(u) { return s }
    if ["md", "markdown"].contains(u.pathExtension.lowercased()) {
      let s = try String(contentsOf: u, encoding: .utf8)
      return NSAttributedString(try AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
    }
    return try NSAttributedString(url: u, options: [:], documentAttributes: nil)
  }

  static func write(_ src: URL, as type: NSAttributedString.DocumentType, ext: String) throws -> URL {
    let s = try read(src)
    var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
    if type == .plain || type == .html { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
    let data = try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: attrs)
    let out = outputURL(for: src, ext: ext)
    try data.write(to: out)
    return out
  }

  /// US Letter with 0.75in margins, paginated by the text system.
  @MainActor static func pdf(_ src: URL) throws -> URL {
    let s = try read(src)
    let out = outputURL(for: src, ext: "pdf")
    let info = NSPrintInfo(dictionary: [.jobSavingURL: out])
    info.jobDisposition = .save
    info.paperSize = NSSize(width: 612, height: 792)
    for m in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: m] = 54 }
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    info.isVerticallyCentered = false
    let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 108, height: 792 - 108))
    view.textStorage?.setAttributedString(s)
    view.isVerticallyResizable = true
    view.sizeToFit()
    let op = NSPrintOperation(view: view, printInfo: info)
    op.showsPrintPanel = false
    op.showsProgressPanel = false
    guard op.run(), FileManager.default.fileExists(atPath: out.path) else { throw ToolError("Couldn't create the PDF") }
    return out
  }
}

// MARK: - Archives (system ditto / bsdtar)

enum ArchiveTools {
  static func exec(_ tool: String, _ args: [String]) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    let err = Pipe()
    p.standardError = err
    try p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else {
      let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
      throw ToolError(msg.isEmpty ? "\(URL(fileURLWithPath: tool).lastPathComponent) failed" : msg)
    }
  }

  static func zip(_ urls: [URL]) throws -> URL {
    if urls.count == 1 {
      let out = outputURL(for: urls[0], ext: "zip", keepExtension: true)
      // --keepParent keeps a folder's own name; on a single file it would wrap it in the file's parent folder
      let isDir = (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
      try exec("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc"] + (isDir ? ["--keepParent"] : []) + [urls[0].path, out.path])
      return out
    }
    // Several items: stage them in one folder so the zip has a flat top level.
    let stage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stage) }
    for u in urls { try FileManager.default.copyItem(at: u, to: stage.appendingPathComponent(u.lastPathComponent)) }
    let out = outputURL(for: urls[0].deletingLastPathComponent().appendingPathComponent("Archive"), ext: "zip")
    try exec("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", stage.path, out.path])
    return out
  }

  /// Name without archive extensions: `a.tar.gz` → `a`.
  static func archiveBase(_ src: URL) -> URL {
    var base = src.deletingPathExtension()
    if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }
    return base
  }

  /// Rewrites one archive format as another without unpacking to disk (bsdtar reads `@archive` as input).
  static func repack(_ src: URL, ext: String, flags: [String]) throws -> URL {
    let out = outputURL(for: archiveBase(src).appendingPathExtension("x"), ext: ext)
    try exec("/usr/bin/bsdtar", ["-c"] + flags + ["-f", out.path, "@" + src.path])
    return out
  }

  /// Extracts zip, tar, gz, bz2, xz, 7z and more (libarchive) into a new folder next to the archive.
  static func extract(_ src: URL) throws -> URL {
    var base = src.deletingPathExtension()
    if base.pathExtension.lowercased() == "tar" { base = base.deletingPathExtension() }  // .tar.gz
    let dest = outputURL(for: base.appendingPathExtension("x"), ext: "")
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: false)
    do {
      try exec("/usr/bin/bsdtar", ["-x", "-f", src.path, "-C", dest.path])
    } catch {
      try? FileManager.default.removeItem(at: dest)
      throw error
    }
    return dest
  }
}
