import AppKit
import AVFoundation
import ImageIO
import PDFKit

extension SelfTest {
  static func compressResizePack(dir: URL) async {
    func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }

    // An image-heavy PDF: one page of noise (incompressible as JPEG at high quality) plus a text page.
    let noise = dir.appendingPathComponent("noise-big.png")
    let c = CGContext(data: nil, width: 1600, height: 1600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    var rng = SystemRandomNumberGenerator()
    for y in stride(from: 0, to: 1600, by: 2) { for x in stride(from: 0, to: 1600, by: 2) {
      c.setFillColor(CGColor(red: .random(in: 0...1, using: &rng), green: .random(in: 0...1, using: &rng), blue: .random(in: 0...1, using: &rng), alpha: 1))
      c.fill(CGRect(x: x, y: y, width: 2, height: 2))
    } }
    try? ImageTools.write(c.makeImage()!, props: [:], type: .png, to: noise)
    let text = dir.appendingPathComponent("words.txt")
    try? "Lemon keeps this sentence searchable".write(to: text, atomically: true, encoding: .utf8)
    guard let imagePDF = try? ImageTools.toPDF([noise]), let textPDF = try? await DocTools.pdf(text),
          let mixed = try? PDFTools.merge([imagePDF, textPDF]) else { return check(false, "PDF compression fixtures") }
    let original = size(mixed)

    await attempt("PDF compress (quality) shrinks images and keeps text") {
      let out = try PDFTools.compress(mixed, settings: PDFCompressSettings(quality: 0.5, dpi: 100))
      let doc = PDFDocument(url: out)
      return size(out) < original / 2 && doc?.pageCount == 2 && doc?.string?.contains("searchable") == true
    }
    await attempt("PDF compress (target size) fits the target") {
      let target = original / 6
      let out = try PDFTools.compress(mixed, settings: PDFCompressSettings(targetBytes: target))
      return size(out) <= target && size(out) > target / 20 && PDFDocument(url: out)?.string?.contains("searchable") == true
    }
    await expectError("PDF compress to an impossible size explains why") {
      _ = try PDFTools.compress(textPDF, settings: PDFCompressSettings(targetBytes: 200))
    }
    await attempt("PDF compress keeps rotated pages upright") {
      let rotated = try PDFTools.rotate(textPDF)  // 90°: portrait page shown landscape
      let out = try PDFTools.compress(rotated, settings: PDFCompressSettings())
      guard let page = PDFDocument(url: out)?.page(at: 0) else { return false }
      let b = page.bounds(for: .mediaBox)
      return b.width > b.height && page.rotation == 0
    }

    // Resize geometry.
    let src = CGSize(width: 4000, height: 3000)
    check(ResizeSettings(width: 1920).sizes(for: src).canvas == CGSize(width: 1920, height: 1440), "resize: width keeps aspect")
    check(ResizeSettings(height: 600).sizes(for: src).canvas == CGSize(width: 800, height: 600), "resize: height keeps aspect")
    check(ResizeSettings(percent: 25).sizes(for: src).canvas == CGSize(width: 1000, height: 750), "resize: percent")
    check(ResizeSettings(width: 1000, height: 1000, fit: .fit).sizes(for: src).canvas == CGSize(width: 1000, height: 750), "resize: fit inside box")
    let fill = ResizeSettings(width: 1000, height: 1000, fit: .fill).sizes(for: src)
    check(fill.canvas == CGSize(width: 1000, height: 1000) && fill.drawn == CGSize(width: 1333, height: 1000), "resize: fill crops to box")
    check(ResizeSettings(width: 1000, height: 1000, fit: .stretch).sizes(for: src).canvas == CGSize(width: 1000, height: 1000), "resize: stretch")
    check(ResizeSettings(width: 8000, allowEnlarge: false).sizes(for: src).canvas == src
            && ResizeSettings(width: 8000, allowEnlarge: true).sizes(for: src).canvas == CGSize(width: 8000, height: 6000),
          "resize: enlarging only when allowed")

    await attempt("resize file: 1600 → 400 px, named with the new size") {
      let out = try ImageTools.resize(noise, ResizeSettings(width: 400))
      let p = CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
      return out.lastPathComponent == "noise-big-400x400.png" && p[kCGImagePropertyPixelWidth] as? Int == 400
    }
    await attempt("resize file: fill crops a centred square") {
      let out = try ImageTools.resize(noise, ResizeSettings(width: 300, height: 150, fit: .fill))
      return ImageTools.orientedSize(out) == CGSize(width: 300, height: 150)
    }

    // Video target size.
    check(VideoCompressSettings.bitrate(forTarget: 10_000_000, duration: 10) == 7_392_000, "video: target size → bitrate")
    check(VideoCompressSettings(bitrate: 1_000_000).args.contains("-b:v") && !VideoCompressSettings(bitrate: 1_000_000).args.contains("-q:v"),
          "video: target size uses a bitrate, not constant quality")
    await attempt("video: compressing to a target lands under it") {
      let mov = dir.appendingPathComponent("target.mov")
      try await makeVideo(mov)
      let target = 60_000
      let rate = VideoCompressSettings.bitrate(forTarget: target, duration: try await AVURLAsset(url: mov).load(.duration).seconds)
      let out = try await MediaTools.compressVideo(mov, settings: VideoCompressSettings(bitrate: rate))
      return size(out) > 0 && size(out) <= target
    }
  }
}
