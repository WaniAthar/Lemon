import AppKit
import ImageIO
import PDFKit

// MARK: - Organize / merge

/// One output page: page `page` of `sources[source]`, turned clockwise `turns` extra quarter turns.
struct PageRef: Identifiable, Hashable, Sendable {
  var id = UUID()
  var source: Int
  var page: Int
  var turns = 0
}

extension PDFTools {
  /// Pages in a PDF, or 1 for an image (0 if it can't be read).
  static func pageCount(_ u: URL) -> Int {
    FileKind(u) == .pdf ? (PDFDocument(url: u).flatMap { $0.isLocked ? nil : $0.pageCount } ?? 0) : 1
  }

  /// PDFs open as they are; images become a one-page document at 72 dpi.
  static func document(_ u: URL) throws -> PDFDocument {
    if FileKind(u) == .pdf { return try open(u) }
    let (img, _) = try ImageTools.decode(u)
    let d = PDFDocument()
    guard let p = PDFPage(image: NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))) else {
      throw ToolError("Can't read \(u.lastPathComponent)")
    }
    d.insert(p, at: 0)
    return d
  }

  static func allPages(_ sources: [URL]) -> [PageRef] {
    sources.enumerated().flatMap { s, u in (0..<pageCount(u)).map { PageRef(source: s, page: $0) } }
  }

  static func organized(_ sources: [URL], pages refs: [PageRef], equalizeWidths: Bool) throws -> PDFDocument {
    let docs = try sources.map(document)
    let out = PDFDocument()
    for r in refs {
      guard let p = docs[r.source].page(at: r.page)?.copy() as? PDFPage else { continue }
      p.rotation = ((p.rotation + r.turns * 90) % 360 + 360) % 360
      out.insert(p, at: out.pageCount)
    }
    guard out.pageCount > 0 else { throw ToolError("No pages left to save") }
    return equalizeWidths ? try equalized(out) : out
  }

  static func organize(_ sources: [URL], pages: [PageRef], equalizeWidths: Bool = false) throws -> URL {
    let merged = Set(pages.map(\.source)).count > 1
    return try save(try organized(sources, pages: pages, equalizeWidths: equalizeWidths),
                    to: outputURL(for: sources[0], ext: "pdf", suffix: merged ? "-merged" : "-organized"))
  }

  /// Crop box as shown, after rotation.
  static func displayedSize(_ p: PDFPage) -> CGSize {
    let b = p.bounds(for: .cropBox).size
    return p.rotation % 180 == 0 ? b : CGSize(width: b.height, height: b.width)
  }

  /// Redraws every page scaled to the widest page's width, rotation baked in. Text and vectors stay vectors.
  // ponytail: links and form fields are flattened by the redraw; re-add annotations if anyone needs them interactive
  static func equalized(_ doc: PDFDocument) throws -> PDFDocument {
    let ps = pages(doc)
    let width = ps.map { displayedSize($0).width }.max() ?? 0
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
      throw ToolError("Couldn't resize pages")
    }
    for p in ps {
      let s = displayedSize(p), k = width / max(s.width, 1)
      var box = CGRect(x: 0, y: 0, width: width, height: (s.height * k).rounded())
      ctx.beginPage(mediaBox: &box)
      ctx.scaleBy(x: k, y: k)
      p.transform(ctx, for: .cropBox)
      p.draw(with: .cropBox, to: ctx)
      ctx.endPage()
    }
    ctx.closePDF()
    guard let out = PDFDocument(data: data as Data) else { throw ToolError("Couldn't resize pages") }
    return out
  }
}

// MARK: - Create PDF

struct PageSetup: Equatable, Sendable {
  enum Size: String, CaseIterable, Sendable {
    case fit = "Fit image", a4 = "A4", letter = "Letter"
    var points: CGSize? { self == .a4 ? CGSize(width: 595.28, height: 841.89) : self == .letter ? CGSize(width: 612, height: 792) : nil }
  }
  enum Orientation: String, CaseIterable, Sendable { case auto = "Auto", portrait = "Portrait", landscape = "Landscape" }
  enum Fit: String, CaseIterable, Sendable { case fit = "Fit", fill = "Fill" }

  var size = Size.a4
  var orientation = Orientation.auto
  var margin: CGFloat = 36  // points
  var fit = Fit.fit

  /// Page size, area inside the margins, and where the image lands (points; centred, so y-up or y-down alike).
  func geometry(_ image: CGSize) -> (page: CGSize, content: CGRect, image: CGRect) {
    guard let base = size.points else {
      let page = CGSize(width: image.width + 2 * margin, height: image.height + 2 * margin)
      let r = CGRect(x: margin, y: margin, width: image.width, height: image.height)
      return (page, r, r)
    }
    let landscape = orientation == .landscape || (orientation == .auto && image.width > image.height)
    let page = landscape ? CGSize(width: base.height, height: base.width) : base
    let content = CGRect(origin: .zero, size: page).insetBy(dx: margin, dy: margin)
    guard image.width > 0, image.height > 0, content.width > 0, content.height > 0 else { return (page, content, content) }
    let k = (fit == .fit ? min : max)(content.width / image.width, content.height / image.height)
    let s = CGSize(width: image.width * k, height: image.height * k)
    return (page, content, CGRect(x: content.midX - s.width / 2, y: content.midY - s.height / 2, width: s.width, height: s.height))
  }
}

extension ImageTools {
  static func toPDF(_ urls: [URL], setup: PageSetup) throws -> URL {
    let data = NSMutableData()
    guard let consumer = CGDataConsumer(data: data as CFMutableData), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil) else {
      throw ToolError("Couldn't create the PDF")
    }
    for u in urls {
      let (img, _) = try decode(u)
      let g = setup.geometry(CGSize(width: img.width, height: img.height))
      var box = CGRect(origin: .zero, size: g.page)
      ctx.beginPage(mediaBox: &box)
      ctx.clip(to: g.content)
      ctx.interpolationQuality = .high
      ctx.draw(img, in: g.image)
      ctx.endPage()
    }
    ctx.closePDF()
    let out = outputURL(for: urls[0], ext: "pdf", suffix: urls.count > 1 ? "-combined" : "")
    try (data as Data).write(to: out)
    return out
  }
}

// MARK: - Collage

struct CollageLayout: Equatable, Sendable {
  enum Style: String, CaseIterable, Sendable { case grid = "Grid", rows = "Rows", columns = "Columns", featured = "Featured" }
  enum Preset: String, CaseIterable, Sendable {
    case square = "Square", wide = "16:9", portrait = "4:5", a4 = "A4"
    var size: CGSize {
      switch self {
      case .square: CGSize(width: 2048, height: 2048)
      case .wide: CGSize(width: 1920, height: 1080)
      case .portrait: CGSize(width: 1080, height: 1350)
      case .a4: CGSize(width: 1240, height: 1754)  // 150 dpi
      }
    }
  }

  var style = Style.grid
  var preset = Preset.square
  var spacing: CGFloat = 16  // px, also the outer border
  var radius: CGFloat = 0
  var background = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

  /// Tile rects in output pixels, origin top-left, in image order.
  func frames(_ n: Int) -> [CGRect] {
    guard n > 0 else { return [] }
    let size = preset.size, g = spacing
    let inner = CGRect(origin: .zero, size: size).insetBy(dx: g, dy: g)
    /// `r` cut into `k` equal parts side by side (along x) or stacked (along y).
    func cut(_ r: CGRect, _ k: Int, alongX: Bool) -> [CGRect] {
      let len = ((alongX ? r.width : r.height) - CGFloat(k - 1) * g) / CGFloat(k)
      return (0..<k).map { i in
        let o = CGFloat(i) * (len + g)
        return alongX ? CGRect(x: r.minX + o, y: r.minY, width: len, height: r.height) : CGRect(x: r.minX, y: r.minY + o, width: r.width, height: len)
      }
    }
    /// `n` items over `lines` lines, the extra ones going to the last lines.
    func counts(_ lines: Int) -> [Int] { (0..<lines).map { n / lines + ($0 >= lines - n % lines ? 1 : 0) } }

    switch style {
    case .grid:
      let cols = Int(ceil(sqrt(Double(n)))), rows = Int(ceil(Double(n) / Double(cols)))
      let w = (inner.width - CGFloat(cols - 1) * g) / CGFloat(cols)
      return cut(inner, rows, alongX: false).enumerated().flatMap { i, row -> [CGRect] in
        let k = min(cols, n - i * cols), total = CGFloat(k) * w + CGFloat(k - 1) * g
        return cut(CGRect(x: row.midX - total / 2, y: row.minY, width: total, height: row.height), k, alongX: true)  // short last row centred
      }
    case .rows, .columns:
      let alongX = style == .columns
      let lines = Int(ceil(sqrt(Double(n))))
      return zip(cut(inner, lines, alongX: alongX), counts(lines)).flatMap { cut($0, $1, alongX: !alongX) }
    case .featured:
      guard n > 1 else { return [inner] }
      let wide = size.width >= size.height
      let big = wide ? CGRect(x: inner.minX, y: inner.minY, width: (inner.width - g) * 2 / 3, height: inner.height)
                     : CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: (inner.height - g) * 2 / 3)
      let rest = wide ? CGRect(x: big.maxX + g, y: inner.minY, width: inner.maxX - big.maxX - g, height: inner.height)
                      : CGRect(x: inner.minX, y: big.maxY + g, width: inner.width, height: inner.maxY - big.maxY - g)
      return [big] + cut(rest, n - 1, alongX: !wide)
    }
  }

  /// Draws the collage at `scale` × the preset size (previews use a small scale).
  func render(_ images: [CGImage], scale: CGFloat = 1) -> CGImage? {
    let size = preset.size
    guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    ctx.setFillColor(background)
    ctx.fill(CGRect(origin: .zero, size: size))
    ctx.interpolationQuality = .high
    for (img, f) in zip(images, frames(images.count)) where f.width > 0 && f.height > 0 {
      let r = CGRect(x: f.minX, y: size.height - f.maxY, width: f.width, height: f.height)  // to y-up
      let k = max(r.width / CGFloat(img.width), r.height / CGFloat(img.height))
      let s = CGSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
      let corner = min(radius, r.width / 2, r.height / 2)
      ctx.saveGState()
      ctx.addPath(CGPath(roundedRect: r, cornerWidth: corner, cornerHeight: corner, transform: nil))
      ctx.clip()
      ctx.draw(img, in: CGRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
      ctx.restoreGState()
    }
    return ctx.makeImage()
  }
}

extension ImageTools {
  static func collage(_ urls: [URL], layout: CollageLayout) throws -> URL {
    let side = Int(max(layout.preset.size.width, layout.preset.size.height))  // no tile needs more pixels than the canvas
    let images = try urls.map { u in
      // straight from ImageIO: NSImage.cgImage re-renders in the display colour space and shifts colours
      guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
            let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: side] as CFDictionary)
      else { throw ToolError("Can't read \(u.lastPathComponent)") }
      return img
    }
    guard let img = layout.render(images) else { throw ToolError("Couldn't create collage") }
    let url = outputURL(for: urls[0].deletingLastPathComponent().appendingPathComponent("Collage"), ext: "jpg")
    try write(img, props: [:], type: .jpeg, to: url)
    return url
  }
}
