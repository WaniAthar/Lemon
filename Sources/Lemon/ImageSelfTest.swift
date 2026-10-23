import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension SelfTest {
  /// RGBA bytes, row 0 at the top.
  static func rgba(_ img: CGImage) -> (w: Int, h: Int, px: [UInt8]) {
    var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
    px.withUnsafeMutableBytes { buf in
      let c = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
    return (img.width, img.height, px)
  }

  static func image(_ w: Int, _ h: Int, _ paint: (CGContext) -> Void) -> CGImage {
    let c = ImageTools.bitmap(w, h)!
    paint(c)
    return c.makeImage()!
  }

  static func imagePack(dir: URL) async {
    func props(_ u: URL) -> [CFString: Any] {
      CGImageSourceCreateWithURL(u as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
    }
    func mean(_ img: CGImage, channel: Int) -> Double {
      let (_, _, px) = rgba(img)
      return Double(stride(from: channel, to: px.count, by: 4).reduce(0) { $0 + Int(px[$1]) }) / Double(px.count / 4)
    }
    func run(_ id: String, _ urls: [URL]) async throws -> [URL] { try await Tools.all.first { $0.id == id }!.run(urls) }

    // Photo-like JPEG with camera, date, GPS and orientation 6.
    let photo = dir.appendingPathComponent("camera.jpg")
    let muted = image(40, 20) { $0.setFillColor(CGColor(srgbRed: 0.5, green: 0.45, blue: 0.4, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 40, height: 20)) }
    let d = CGImageDestinationCreateWithURL(photo as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, muted, [
      kCGImagePropertyOrientation: 6,
      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Lemon", kCGImagePropertyTIFFModel: "Squeezer 1"],
      kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2026:10:22 10:00:00"],
      kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 12.97, kCGImagePropertyGPSLatitudeRef: "N"],
    ] as CFDictionary)
    CGImageDestinationFinalize(d)

    // Edit
    await attempt("adjust: exposure brightens, temperature warms, saturation -1 greys") {
      let bright = ImageTools.adjusted(muted, Adjustments(exposure: 0.5))!
      let warm = ImageTools.adjusted(muted, Adjustments(temperature: 0.8))!
      let grey = rgba(ImageTools.adjusted(muted, Adjustments(saturation: -1))!).px
      let warmth = { (i: CGImage) in mean(i, channel: 0) - mean(i, channel: 2) }
      return mean(bright, channel: 1) > mean(muted, channel: 1) + 20 && warmth(warm) > warmth(muted) + 10
        && abs(Int(grey[0]) - Int(grey[2])) <= 2
    }
    await attempt("adjust: every slider renders") {
      var all = Adjustments()
      for g in AdjustEditor.groups { for r in g.1 { all[keyPath: r.key] = 0.5 } }
      return ImageTools.adjusted(muted, all).map { $0.width == 40 && $0.height == 20 } ?? false
    }
    await attempt("edit.adjust keeps format, size, orientation baked in") {
      let out = try await run("edit.adjust", [photo])[0]
      let p = props(out)
      return out.lastPathComponent == "camera-edited.jpg" && p[kCGImagePropertyPixelWidth] as? Int == 20 && p[kCGImagePropertyPixelHeight] as? Int == 40
    }

    // Add BG
    await attempt("frame: padding and canvas ratio set the size") {
      let src = image(200, 100) { $0.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 200, height: 100)) }
      var s = FrameStyle(background: .solid(3), padding: 0.1, corner: 0, shadow: 0)
      let plain = ImageTools.framed(src, s)!
      s.ratio = .square
      let square = ImageTools.framed(src, s)!
      s.ratio = .landscape
      let wide = ImageTools.framed(src, s)!
      let (w, _, px) = rgba(plain)
      let corner = Array(px[0..<3]), centre = Array(px[(70 * w + 120) * 4..<(70 * w + 120) * 4 + 3])
      return plain.width == 240 && plain.height == 140 && square.width == 240 && square.height == 240 && wide.width == 249 && wide.height == 140
        && corner == [0xFF, 0xD2, 0x1A] && centre == [0, 0, 255]
    }
    await attempt("edit.frame writes PNG") {
      let out = try await run("edit.frame", [photo])[0]
      return out.lastPathComponent == "camera-framed.png" && (props(out)[kCGImagePropertyPixelHeight] as? Int ?? 0) > 40
    }

    // Annotate
    await attempt("annotate: marks land at image pixels (top-left origin)") {
      let white = image(100, 80) { $0.setFillColor(CGColor(gray: 1, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 100, height: 80)) }
      let out = ImageTools.annotated(white, [
        Mark(kind: .rect, points: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 40)], color: 0xFF0000, width: 4),
        Mark(kind: .pen, points: [CGPoint(x: 70, y: 70), CGPoint(x: 90, y: 70)], color: 0x0000FF, width: 4),
      ])!
      let (w, _, px) = rgba(out)
      func at(_ x: Int, _ y: Int) -> [UInt8] { Array(px[(y * w + x) * 4..<(y * w + x) * 4 + 3]) }
      return at(10, 25) == [255, 0, 0] && at(30, 25) == [255, 255, 255] && at(80, 70) == [0, 0, 255] && at(80, 10) == [255, 255, 255]
    }
    await attempt("annotate: highlighter multiplies, text draws") {
      let grey = image(60, 60) { $0.setFillColor(CGColor(gray: 0.5, alpha: 1)); $0.fill(CGRect(x: 0, y: 0, width: 60, height: 60)) }
      let hl = rgba(ImageTools.annotated(grey, [Mark(kind: .highlighter, points: [CGPoint(x: 0, y: 30), CGPoint(x: 60, y: 30)], color: 0xFFFFFF, width: 4)])!)
      let txt = ImageTools.annotated(grey, [Mark(kind: .text, points: [CGPoint(x: 2, y: 2)], color: 0xFF0000, width: 6, text: "Hi")])!
      let p = (30 * 60 + 30) * 4
      return abs(Int(hl.px[p]) - Int(rgba(grey).px[p])) <= 2 && mean(txt, channel: 0) > mean(grey, channel: 0) + 3  // white × grey = grey
    }

    // Redact
    let noise = image(200, 200) { c in
      var rng = SystemRandomNumberGenerator()
      for y in 0..<200 { for x in 0..<200 {
        c.setFillColor(CGColor(gray: .random(in: 0...1, using: &rng), alpha: 1)); c.fill(CGRect(x: x, y: y, width: 1, height: 1))
      } }
    }
    let box = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
    func variation(_ px: [UInt8]) -> Double {  // mean neighbour difference inside the box
      var sum = 0, n = 0
      for y in 52..<148 { for x in 52..<147 { sum += abs(Int(px[(y * 200 + x) * 4]) - Int(px[(y * 200 + x + 1) * 4])); n += 1 } }
      return Double(sum) / Double(n)
    }
    for style in RedactStyle.allCases {
      await attempt("redact \(style.rawValue): no original detail inside, untouched outside") {
        let src = rgba(noise).px
        let out = rgba(ImageTools.redacted(noise, boxes: [box], style: style, strength: 0)!).px
        var diff = 0
        for y in 52..<148 { for x in 52..<148 { let i = (y * 200 + x) * 4; diff += abs(Int(out[i]) - Int(src[i])) } }
        let outside = out[0..<4800] == src[0..<4800]  // top 6 rows
        let black = (52..<148).allSatisfy { (y: Int) -> Bool in out[(y * 200 + 100) * 4] == 0 }
        let inside = style == .solid ? black : variation(out) < variation(src) * 0.15
        return inside && outside && Double(diff) / (96 * 96) > 40
      }
    }
    await attempt("edit.redact strips all metadata (no thumbnail, GPS or EXIF)") {
      let out = try await run("edit.redact", [photo])[0]
      let s = CGImageSourceCreateWithURL(out as CFURL, nil)!
      let p = props(out)
      let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
      let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
      let thumbs = p[kCGImagePropertyThumbnailImages] as? [Any] ?? []
      let clean = p[kCGImagePropertyGPSDictionary] == nil && tiff[kCGImagePropertyTIFFMake] == nil && exif[kCGImagePropertyExifDateTimeOriginal] == nil
      return clean && CGImageSourceGetCount(s) == 1 && thumbs.isEmpty
    }

    // Metadata
    await attempt("metadata: fields grouped camera/date/location") {
      let groups = Dictionary(grouping: ImageTools.metadataFields(photo), by: \.group).mapValues { Set($0.map(\.key)) }
      return groups["Camera"]?.isSuperset(of: ["Make", "Model"]) == true && groups["Date"]?.contains("DateTimeOriginal") == true
        && groups["Location"]?.contains("Latitude") == true && !groups.values.contains { $0.contains("Orientation") }
    }
    var lossless = false
    await attempt("metadata: remove selected keeps the rest and orientation") {
      let fields = ImageTools.metadataFields(photo).filter { $0.group == "Location" || $0.key == "Make" }
      let out = try ImageTools.removeMetadata(photo, fields: fields)
      let p = props(out)
      lossless = (try? Data(contentsOf: out).range(of: Data(contentsOf: photo).suffix(200))) != nil  // same JPEG scan data
      let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
      let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
      return p[kCGImagePropertyGPSDictionary] == nil && tiff[kCGImagePropertyTIFFMake] == nil && tiff[kCGImagePropertyTIFFModel] as? String == "Squeezer 1"
        && exif[kCGImagePropertyExifDateTimeOriginal] != nil && p[kCGImagePropertyOrientation] as? Int == 6 && p[kCGImagePropertyPixelWidth] as? Int == 40
    }
    check(lossless, "metadata: remove selected is lossless for JPEG")
    await attempt("metadata: remove selected works on PNG too") {
      let png = try ImageTools.convert(photo, to: .png, ext: "png")
      let fields = ImageTools.metadataFields(png).filter { $0.key == "Model" }
      let p = props(try ImageTools.removeMetadata(png, fields: fields))
      return !fields.isEmpty && (p[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] == nil && p[kCGImagePropertyPixelWidth] as? Int == 20
    }

    // Compress percentage target (what the Percent mode asks for)
    await attempt("compress: percentage target fits") {
      let big = dir.appendingPathComponent("noise-pct.png")
      try ImageTools.write(noise, props: [:], type: .png, to: big)
      let original = (try big.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return try ImageTools.compressedData(big, settings: CompressSettings(targetBytes: original * 30 / 100)).data.count <= original * 30 / 100
    }

    if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
      renderImageEditors(photo: photo, to: URL(fileURLWithPath: CommandLine.arguments[i + 1]).deletingPathExtension().appendingPathExtension("image-editors.png"))
    }
  }

  static func renderImageEditors(photo: URL, to out: URL) {
    lemonPlainRender = true
    defer { lemonPlainRender = false }
    let pic = photo.deletingLastPathComponent().appendingPathComponent("scene.png")
    let c = ImageTools.bitmap(1200, 800)!
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [FrameBackground.color(0x87C5F5), FrameBackground.color(0xF7D27A)] as CFArray, locations: nil)!
    c.drawLinearGradient(g, start: CGPoint(x: 0, y: 800), end: CGPoint(x: 0, y: 0), options: [])
    c.setFillColor(FrameBackground.color(0x2E7D4F)); c.fillEllipse(in: CGRect(x: -200, y: -500, width: 1600, height: 800))
    c.setFillColor(FrameBackground.color(0xFFD21A)); c.fillEllipse(in: CGRect(x: 820, y: 520, width: 160, height: 160))
    try? ImageTools.write(c.makeImage()!, props: [:], type: .png, to: pic)
    // one render per window, tiled two per row
    func shot<V: View>(_ v: V, _ w: CGFloat, _ h: CGFloat) -> CGImage? {
      let r = ImageRenderer(content: EditorChrome(content: v).frame(width: w, height: h))
      r.scale = 1
      return r.cgImage
    }
    let shots = [
      shot(AdjustEditor(urls: [pic], close: {}), 940, 640), shot(FrameEditor(urls: [pic], close: {}), 900, 640),
      shot(AnnotateEditor(urls: [pic], marks: [
        Mark(kind: .arrow, points: [CGPoint(x: 300, y: 600), CGPoint(x: 820, y: 620)], color: 0xFF3B30, width: 10),
        Mark(kind: .ellipse, points: [CGPoint(x: 800, y: 100), CGPoint(x: 1000, y: 300)], color: 0x0A84FF, width: 8),
        Mark(kind: .text, points: [CGPoint(x: 60, y: 60)], color: 0x1C1C1E, width: 12, text: "Top left"),
        Mark(kind: .highlighter, points: [CGPoint(x: 60, y: 200), CGPoint(x: 500, y: 200)], color: 0xFFD21A, width: 10),
      ], close: {}), 900, 680), shot(RedactEditor(urls: [pic], close: {}), 880, 660),
      shot(MetadataEditor(urls: [photo], close: {}), 640, 600), shot(CompressEditor(urls: [pic], close: {}), 860, 560),
    ].compactMap { $0 }
    let sheet = ImageTools.bitmap(1900, 2160)!
    sheet.setFillColor(CGColor(srgbRed: 0.75, green: 0.82, blue: 0.9, alpha: 1))
    sheet.fill(CGRect(x: 0, y: 0, width: 1900, height: 2160))
    for (i, img) in shots.enumerated() {
      sheet.draw(img, in: CGRect(x: 20 + (i % 2) * 960, y: 2160 - (i / 2 + 1) * 710, width: img.width, height: img.height))
    }
    try? ImageTools.write(sheet.makeImage()!, props: [:], type: .png, to: out)
    print("rendered", out.path)
  }
}
