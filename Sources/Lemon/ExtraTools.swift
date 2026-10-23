import AppKit
import CoreImage
import CoreText
import CryptoKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

// MARK: - Registry

extension Tools {
  static let extras: [Tool] = [
    // Convert (Shift)
    Tool(id: "img.icns", mode: .convert, title: "Convert to ICNS (app icon)", short: "ICNS", symbol: "app.dashed",
         kinds: [.image], outputExt: "icns", run: each(ImageTools.icns)),
    Tool(id: "img.gif", mode: .convert, title: "Animated GIF", short: "GIF", symbol: "photo.stack", kinds: [.image], needsMany: true,
         run: { [try ImageTools.animatedGIF($0)] }),
    // Edit (Command)
    Tool(id: "edit.removebg", mode: .edit, title: "Remove background", short: "Remove BG", symbol: "person.and.background.dotted",
         kinds: [.image], editor: { urls in EditorWindow.show(size: CGSize(width: 920, height: 600)) { RemoveBGEditor(urls: urls, close: $0) } },
         run: each { try ImageTools.removeBackground($0) }),
    Tool(id: "edit.watermark", mode: .edit, title: "Watermark", short: "Watermark", symbol: "signature",
         kinds: [.image, .pdf], editor: { urls in EditorWindow.show(size: CGSize(width: 920, height: 640)) { WatermarkEditor(urls: urls, close: $0) } },
         run: each { try Watermark.apply($0, WatermarkStyle()) }),
    Tool(id: "edit.pagenumbers", mode: .edit, title: "Page numbers", short: "Numbers", symbol: "number",
         kinds: [.pdf], editor: { urls in EditorWindow.show(size: CGSize(width: 860, height: 620)) { PageNumbersEditor(urls: urls, close: $0) } },
         run: each { try PDFTools.number($0, PageNumberStyle()) }),
    Tool(id: "edit.protect", mode: .edit, title: "Protect PDF", short: "Protect", symbol: "lock.doc",
         kinds: [.pdf], editor: { urls in EditorWindow.show(size: CGSize(width: 520, height: 470)) { ProtectEditor(urls: urls, close: $0) } },
         run: { _ in throw ToolError("Protect needs a password") }),  // always opened in the editor
    Tool(id: "edit.unlock", mode: .edit, title: "Unlock PDF", short: "Unlock", symbol: "lock.open",
         kinds: [.pdf], editor: { urls in EditorWindow.show(size: CGSize(width: 520, height: 340)) { UnlockEditor(urls: urls, close: $0) } },
         run: each { try PDFTools.unlock($0, password: "") }),  // only works when no password is set; the editor asks
    Tool(id: "edit.searchable", mode: .edit, title: "Make searchable (OCR)", short: "OCR", symbol: "doc.text.magnifyingglass",
         kinds: [.pdf, .image], run: each(PDFTools.searchable)),
    // Actions (Control)
    Tool(id: "act.rename", mode: .action, title: "Batch rename", short: "Rename", symbol: "character.cursor.ibeam", kinds: FileKind.all,
         editor: { urls in EditorWindow.show(size: CGSize(width: 760, height: 600)) { RenameEditor(urls: urls, close: $0) } },
         run: { try Rename.apply(Rename.plan($0, RenameRule(pattern: "{name}-{n}"))) }),
    Tool(id: "act.checksum", mode: .action, title: "Checksum", short: "Checksum", symbol: "checkmark.shield", kinds: FileKind.all,
         writesNextToSource: false,
         editor: { urls in EditorWindow.show(size: CGSize(width: 680, height: 460)) { ChecksumEditor(urls: urls, close: $0) } },
         run: { try await Checksum.copySHA256($0) }),
  ]
}

// MARK: - Remove background (Vision)

extension ImageTools {
  /// Soft subject mask (white = keep) the size of `img`, from Vision's subject lifting.
  static func subjectMask(_ img: CGImage) throws -> CIImage {
    let req = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: img)
    try handler.perform([req])
    guard let obs = req.results?.first, !obs.allInstances.isEmpty else { throw ToolError("No subject found") }
    return CIImage(cvPixelBuffer: try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler))
  }

  /// `feather` softens the mask edge, in percent of the shorter side; `fill` replaces the background (nil = transparent).
  static func cutout(_ img: CGImage, mask: CIImage, feather: Double = 0, fill: CGColor? = nil) -> CGImage? {
    let extent = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    var m = mask.transformed(by: CGAffineTransform(scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
    if feather > 0 { m = m.clampedToExtent().applyingGaussianBlur(sigma: feather * min(extent.width, extent.height) / 100).cropped(to: extent) }
    let bg = fill.map { CIImage(color: CIColor(cgColor: $0)).cropped(to: extent) } ?? CIImage.empty()
    let out = CIImage(cgImage: img).applyingFilter("CIBlendWithRedMask", parameters: [kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: m])
    return render(out, extent: extent)
  }

  static func removeBackground(_ src: URL, feather: Double = 0, fill: CGColor? = nil) throws -> URL {
    let (img, props) = try decode(src)
    guard let out = cutout(img, mask: try subjectMask(img), feather: feather, fill: fill) else { throw ToolError("Couldn't cut out the subject") }
    let url = outputURL(for: src, ext: "png", suffix: "-nobg")
    try write(out, props: keptMetadata(props), type: .png, to: url)
    return url
  }

  // MARK: Icon set and GIF

  /// Square icon sizes 16–1024 in one .icns (non-square images are centred on transparency).
  static func icns(_ src: URL) throws -> URL {
    let (img, _) = try decode(src)
    let sides = [16, 32, 64, 128, 256, 512, 1024]
    let out = outputURL(for: src, ext: "icns")
    guard let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.icns.identifier as CFString, sides.count, nil) else {
      throw ToolError("This Mac can't write ICNS")
    }
    for s in sides {
      guard let c = bitmap(s, s) else { continue }
      let fit = aspectFit(CGSize(width: img.width, height: img.height), in: CGSize(width: s, height: s))
      c.interpolationQuality = .high
      c.draw(img, in: CGRect(x: (CGFloat(s) - fit.width) / 2, y: (CGFloat(s) - fit.height) / 2, width: fit.width, height: fit.height))
      CGImageDestinationAddImage(d, c.makeImage()!, nil)
    }
    guard CGImageDestinationFinalize(d) else { throw ToolError("Couldn't save \(out.lastPathComponent)") }
    return out
  }

  /// One frame per image, sized to the first (max 800 px), looping.
  static func animatedGIF(_ urls: [URL], delay: Double = 0.5) throws -> URL {
    let frames = try urls.map { try decode($0).0 }
    let first = CGSize(width: frames[0].width, height: frames[0].height)
    let size = aspectFit(first, in: CGSize(width: min(first.width, 800), height: min(first.height, 800)))
    let out = outputURL(for: urls[0], ext: "gif", suffix: "-animated")
    guard let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else {
      throw ToolError("This Mac can't write GIF")
    }
    CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    for f in frames {
      guard let c = bitmap(Int(size.width), Int(size.height)) else { continue }
      c.setFillColor(CGColor(gray: 1, alpha: 1))
      c.fill(CGRect(origin: .zero, size: size))
      let fit = aspectFit(CGSize(width: f.width, height: f.height), in: size)
      c.draw(f, in: CGRect(x: (size.width - fit.width) / 2, y: (size.height - fit.height) / 2, width: fit.width, height: fit.height))
      CGImageDestinationAddImage(d, c.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
    }
    guard CGImageDestinationFinalize(d) else { throw ToolError("Couldn't save \(out.lastPathComponent)") }
    return out
  }
}

// MARK: - PDF: redraw, protect, unlock, page numbers, OCR

extension PDFTools {
  /// Upright page box (rotation applied) and a transform that draws the page into it.
  static func upright(_ page: CGPDFPage) -> (box: CGRect, transform: CGAffineTransform) {
    let crop = page.getBoxRect(.cropBox)
    let turned = abs(page.rotationAngle) % 180 == 90
    let box = CGRect(x: 0, y: 0, width: turned ? crop.height : crop.width, height: turned ? crop.width : crop.height)
    return (box, page.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
  }

  /// Redraws every page into a new PDF, vectors and text kept, then lets `extra` draw on top (upright box, page index, count).
  // ponytail: links, annotations and form fields aren't carried over; copy them with PDFKit if anyone needs them
  static func redraw(_ src: URL, suffix: String, _ extra: (CGContext, CGRect, Int, Int) throws -> Void) throws -> URL {
    let pages = PDFTools.pages(try open(src)).compactMap(\.pageRef)
    let out = outputURL(for: src, ext: "pdf", suffix: suffix)
    guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw ToolError("Couldn't create \(out.lastPathComponent)") }
    do {
      for (i, page) in pages.enumerated() {
        var (box, t) = upright(page)
        ctx.beginPage(mediaBox: &box)
        ctx.saveGState()
        ctx.concatenate(t)
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        try extra(ctx, box, i, pages.count)
        ctx.endPage()
      }
      ctx.closePDF()
    } catch {
      ctx.closePDF()
      try? FileManager.default.removeItem(at: out)
      throw error
    }
    return out
  }

  /// A page rendered upright at `scale` points per pixel, white behind.
  static func render(_ page: CGPDFPage, scale: CGFloat) -> CGImage? {
    let (box, t) = upright(page)
    guard let c = ImageTools.bitmap(Int(box.width * scale), Int(box.height * scale)) else { return nil }
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height))
    c.scaleBy(x: scale, y: scale)
    c.concatenate(t)
    c.drawPDFPage(page)
    return c.makeImage()
  }

  /// Empty `user` opens without a password but still enforces the permissions; empty `owner` reuses `user`.
  static func protect(_ src: URL, user: String, owner: String, allowPrinting: Bool, allowCopying: Bool) throws -> URL {
    guard !user.isEmpty || !owner.isEmpty else { throw ToolError("Set a password") }
    // PDFAccessPermissions is a plain enum in Swift: combine its bits by hand.
    var perms = PDFAccessPermissions.allowsContentAccessibility.rawValue
    if allowPrinting { perms |= PDFAccessPermissions.allowsLowQualityPrinting.rawValue | PDFAccessPermissions.allowsHighQualityPrinting.rawValue }
    if allowCopying { perms |= PDFAccessPermissions.allowsContentCopying.rawValue }
    return try save(try open(src), to: outputURL(for: src, ext: "pdf", suffix: "-protected"), options: [
      .userPasswordOption: user, .ownerPasswordOption: owner.isEmpty ? user : owner, .accessPermissionsOption: perms,
    ])
  }

  /// Writes an unencrypted copy. Needs the open password, or the permissions password for a PDF that only restricts.
  static func unlock(_ src: URL, password: String) throws -> URL {
    guard let d = PDFDocument(url: src) else { throw ToolError("Can't open \(src.lastPathComponent)") }
    guard d.isEncrypted else { throw ToolError("\(src.lastPathComponent) isn't protected") }
    guard d.unlock(withPassword: password) else {
      throw ToolError(password.isEmpty ? "\(src.lastPathComponent) needs its password" : "Wrong password for \(src.lastPathComponent)")
    }
    guard d.permissionsStatus == .owner || !restricted(d) else { throw ToolError("Removing restrictions needs the permissions password") }
    // PDFKit keeps the encryption when saving the same document: copy the pages into a fresh one.
    let plain = PDFDocument()
    for p in pages(d) { plain.insert(p.copy() as! PDFPage, at: plain.pageCount) }
    plain.documentAttributes = d.documentAttributes
    return try save(plain, to: outputURL(for: src, ext: "pdf", suffix: "-unlocked"))
  }

  private static func restricted(_ d: PDFDocument) -> Bool {
    !(d.allowsPrinting && d.allowsCopying && d.allowsDocumentChanges && d.allowsContentAccessibility)
  }

  static func number(_ src: URL, _ s: PageNumberStyle) throws -> URL {
    try redraw(src, suffix: "-numbered") { ctx, box, i, n in s.draw(in: ctx, box: box, index: i, count: n) }
  }

  /// Image of each page with an invisible, selectable text layer from Vision OCR. Images become one-page PDFs.
  static func searchable(_ src: URL) throws -> URL {
    var found = 0
    let out: URL
    if FileKind(src) == .image {
      let (img, _) = try ImageTools.decode(src)
      var box = CGRect(x: 0, y: 0, width: img.width, height: img.height)
      out = outputURL(for: src, ext: "pdf", suffix: "-searchable")
      guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw ToolError("Couldn't create \(out.lastPathComponent)") }
      ctx.beginPage(mediaBox: &box)
      found += drawText(try recognize(img), in: ctx, rect: box)
      ctx.draw(img, in: box)
      ctx.endPage()
      ctx.closePDF()
    } else {
      let doc = try open(src)
      out = try redraw(src, suffix: "-searchable") { ctx, box, i, _ in
        guard let page = doc.page(at: i)?.pageRef, let img = render(page, scale: 2) else { return }
        found += drawText(try recognize(img), in: ctx, rect: box)
      }
    }
    if found == 0 {
      try? FileManager.default.removeItem(at: out)
      throw ToolError("No text found in \(src.lastPathComponent)")
    }
    return out
  }

  static func recognize(_ img: CGImage) throws -> [VNRecognizedTextObservation] {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage: img).perform([req])
    return req.results ?? []
  }

  /// Invisible text stretched over each recognised line's box (Vision boxes are normalized, origin bottom-left, like PDF).
  static func drawText(_ lines: [VNRecognizedTextObservation], in ctx: CGContext, rect: CGRect) -> Int {
    ctx.saveGState()
    ctx.setTextDrawingMode(.invisible)
    var n = 0
    for o in lines {
      guard let s = o.topCandidates(1).first?.string, !s.isEmpty else { continue }
      let b = CGRect(x: rect.minX + o.boundingBox.minX * rect.width, y: rect.minY + o.boundingBox.minY * rect.height,
                     width: o.boundingBox.width * rect.width, height: o.boundingBox.height * rect.height)
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: NSFont(name: "Helvetica", size: b.height * 0.85)!]))
      let w = CTLineGetTypographicBounds(line, nil, nil, nil)
      ctx.textMatrix = CGAffineTransform(scaleX: b.width / max(w, 1), y: 1)
      ctx.textPosition = CGPoint(x: b.minX, y: b.minY + b.height * 0.2)
      CTLineDraw(line, ctx)
      n += 1
    }
    ctx.textMatrix = .identity
    ctx.restoreGState()
    return n
  }
}

// MARK: - Page numbers

struct PageNumberStyle: Equatable, Sendable {
  enum Format: String, CaseIterable, Sendable { case plain = "1", slash = "1 / N", pageOf = "Page 1 of N" }
  enum Align: String, CaseIterable, Sendable { case left = "Left", center = "Center", right = "Right" }
  var top = false
  var align = Align.center
  var format = Format.plain
  var fontSize = 11.0
  var start = 1
  var skipFirst = false

  /// `index` is zero-based; nil when the page is skipped.
  func label(_ index: Int, of count: Int) -> String? {
    if skipFirst && index == 0 { return nil }
    let n = start + index, last = start + count - 1
    switch format {
    case .plain: return "\(n)"
    case .slash: return "\(n) / \(last)"
    case .pageOf: return "Page \(n) of \(last)"
    }
  }

  func draw(in ctx: CGContext, box: CGRect, index: Int, count: Int) {
    guard let s = label(index, of: count) else { return }
    let font = NSFont.systemFont(ofSize: fontSize)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
      .font: font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.15, alpha: 1),
    ]))
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    let margin = max(fontSize * 2.5, 24)
    let x = switch align {
    case .left: box.minX + margin
    case .center: box.midX - w / 2
    case .right: box.maxX - margin - w
    }
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: x, y: top ? box.maxY - margin : box.minY + margin - fontSize * 0.8)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
  }
}

// MARK: - Watermark

struct WatermarkStyle: Equatable, Sendable {
  /// 3x3 grid read left to right, top to bottom, then tiled across the page.
  enum Position: Int, CaseIterable, Sendable { case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight, tiled }
  var text = "CONFIDENTIAL"
  var image: URL? = nil  // an image mark replaces the text
  var position = Position.center
  var opacity = 0.3
  var size = 0.5         // mark width as a share of the page width
  var rotation = 30.0    // degrees, counter-clockwise
  var color: UInt32 = 0x808080

  /// Draws on `ctx` (y-up) over `box`. `mark` is the decoded `image`, loaded once by the caller.
  func draw(in ctx: CGContext, box: CGRect, mark: CGImage?) {
    let w = box.width * size
    let h: CGFloat
    let paint: (CGContext) -> Void
    if let mark {
      h = w * CGFloat(mark.height) / CGFloat(max(mark.width, 1))
      paint = { $0.draw(mark, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h)) }
    } else {
      guard !text.isEmpty else { return }
      func line(_ pt: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
          .font: NSFont.systemFont(ofSize: pt, weight: .bold), NSAttributedString.Key(kCTForegroundColorAttributeName as String): FrameBackground.color(color),
        ]))
      }
      let pt = 100 * w / max(CTLineGetTypographicBounds(line(100), nil, nil, nil), 1)
      let l = line(pt)
      var ascent: CGFloat = 0, descent: CGFloat = 0
      CTLineGetTypographicBounds(l, &ascent, &descent, nil)
      h = ascent + descent
      paint = { c in c.textMatrix = .identity; c.textPosition = CGPoint(x: -w / 2, y: (descent - ascent) / 2); CTLineDraw(l, c) }
    }
    let angle = rotation * .pi / 180
    let bound = CGRect(x: 0, y: 0, width: w, height: h).applying(CGAffineTransform(rotationAngle: angle)).size
    let m = 0.04 * min(box.width, box.height)
    var centers: [CGPoint] = []
    if position == .tiled {
      let sx = max(bound.width * 1.3, box.width * 0.08), sy = max(bound.height * 1.6, box.height * 0.08)
      var row = 0
      for y in stride(from: box.minY + sy / 2, to: box.maxY + sy / 2, by: sy) {
        for x in stride(from: box.minX + (row % 2 == 0 ? sx / 4 : sx * 3 / 4), to: box.maxX + sx / 2, by: sx) { centers.append(CGPoint(x: x, y: y)) }
        row += 1
      }
    } else {
      let col = position.rawValue % 3, row = position.rawValue / 3
      centers = [CGPoint(x: [box.minX + m + bound.width / 2, box.midX, box.maxX - m - bound.width / 2][col],
                         y: [box.maxY - m - bound.height / 2, box.midY, box.minY + m + bound.height / 2][row])]
    }
    for c in centers {
      ctx.saveGState()
      ctx.setAlpha(opacity)
      ctx.translateBy(x: c.x, y: c.y)
      ctx.rotate(by: angle)
      paint(ctx)
      ctx.restoreGState()
    }
  }
}

enum Watermark {
  static func mark(_ s: WatermarkStyle) throws -> CGImage? { try s.image.map { try ImageTools.decode($0).0 } }

  static func apply(_ src: URL, _ s: WatermarkStyle) throws -> URL {
    let mark = try mark(s)
    if FileKind(src) == .pdf {
      return try PDFTools.redraw(src, suffix: "-watermarked") { ctx, box, _, _ in s.draw(in: ctx, box: box, mark: mark) }
    }
    let (img, props) = try ImageTools.decode(src)
    guard let out = watermarked(img, s, mark: mark) else { throw ToolError("Couldn't watermark \(src.lastPathComponent)") }
    return try ImageTools.save(out, from: src, props: ImageTools.keptMetadata(props), suffix: "-watermarked")
  }

  static func watermarked(_ img: CGImage, _ s: WatermarkStyle, mark: CGImage?) -> CGImage? {
    guard let c = ImageTools.bitmap(img.width, img.height) else { return nil }
    let box = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    c.draw(img, in: box)
    s.draw(in: c, box: box, mark: mark)
    return c.makeImage()
  }
}

// MARK: - Batch rename

struct RenameRule: Equatable, Sendable {
  enum LetterCase: String, CaseIterable, Sendable { case keep = "Keep", lower = "lower", upper = "UPPER", title = "Title" }
  var pattern = "{name}"  // {name}, {n}, {date}
  var start = 1
  var pad = 1             // counter digits
  var find = ""
  var replace = ""
  var letterCase = LetterCase.keep
}

struct RenameItem: Identifiable, Equatable {
  let from: URL
  let to: URL
  var problem: String?
  var id: URL { from }
  var changed: Bool { from.lastPathComponent != to.lastPathComponent }
}

enum Rename {
  static let dateFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
  }()

  static func name(_ u: URL, index: Int, _ r: RenameRule) -> String {
    let values = try? u.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    let date = values?.creationDate ?? values?.contentModificationDate ?? Date()
    let n = String(r.start + index)
    var s = r.pattern
      .replacingOccurrences(of: "{name}", with: u.deletingPathExtension().lastPathComponent)
      .replacingOccurrences(of: "{n}", with: String(repeating: "0", count: max(r.pad - n.count, 0)) + n)
      .replacingOccurrences(of: "{date}", with: dateFormat.string(from: date))
    if !r.find.isEmpty { s = s.replacingOccurrences(of: r.find, with: r.replace) }
    switch r.letterCase {
    case .keep: break
    case .lower: s = s.lowercased()
    case .upper: s = s.uppercased()
    case .title: s = s.capitalized
    }
    s = s.trimmingCharacters(in: .whitespaces)
    return u.pathExtension.isEmpty || s.isEmpty ? s : "\(s).\(u.pathExtension)"
  }

  /// New names with problems flagged: empty or invalid, two files getting the same name, or an existing file in the way.
  /// Names compare case-insensitively (the default APFS volume does).
  static func plan(_ urls: [URL], _ r: RenameRule) -> [RenameItem] {
    let sources = Set(urls.map { $0.path.lowercased() })
    var items = urls.enumerated().map { i, u in RenameItem(from: u, to: u.deletingLastPathComponent().appendingPathComponent(name(u, index: i, r))) }
    let counts = Dictionary(grouping: items, by: { $0.to.path.lowercased() }).mapValues(\.count)
    for i in items.indices {
      let n = items[i].to.lastPathComponent, key = items[i].to.path.lowercased()
      if n.isEmpty || n.hasPrefix(".") || n.contains("/") || n.contains(":") || items[i].to.deletingPathExtension().lastPathComponent.isEmpty {
        items[i].problem = "Invalid name"
      } else if counts[key, default: 0] > 1 {
        items[i].problem = "Duplicate name"
      } else if items[i].changed, !sources.contains(key), FileManager.default.fileExists(atPath: items[i].to.path) {
        items[i].problem = "Already exists"
      }
    }
    return items
  }

  /// Renames in two steps through temporary names, so swaps and shifted counters (1→2, 2→3) work.
  static func apply(_ items: [RenameItem]) throws -> [URL] {
    if let bad = items.first(where: { $0.problem != nil }) { throw ToolError("\(bad.from.lastPathComponent): \(bad.problem!)") }
    let todo = items.filter(\.changed)
    let fm = FileManager.default
    var moved: [(temp: URL, item: RenameItem)] = []
    do {
      for it in todo {
        let temp = it.from.deletingLastPathComponent().appendingPathComponent(".lemon-rename-\(UUID().uuidString)")
        try fm.moveItem(at: it.from, to: temp)
        moved.append((temp, it))
      }
      var done = 0
      do {
        for m in moved { try fm.moveItem(at: m.temp, to: m.item.to); done += 1 }
      } catch {
        for m in moved[done...] { try? fm.moveItem(at: m.temp, to: m.item.from) }
        for m in moved[..<done] { try? fm.moveItem(at: m.item.to, to: m.item.from) }
        throw error
      }
    } catch {
      for m in moved where fm.fileExists(atPath: m.temp.path) { try? fm.moveItem(at: m.temp, to: m.item.from) }
      throw error
    }
    return todo.map(\.to)
  }
}

// MARK: - Checksum

enum Checksum: String, CaseIterable, Sendable {
  case sha256 = "SHA-256", sha1 = "SHA-1", md5 = "MD5"

  /// All three digests (lowercase hex) in one pass, reading 1 MB at a time.
  static func digests(_ u: URL) throws -> [Checksum: String] {
    let h = try FileHandle(forReadingFrom: u)
    defer { try? h.close() }
    var a = SHA256(), b = Insecure.SHA1(), c = Insecure.MD5()
    while let d = try h.read(upToCount: 1 << 20), !d.isEmpty {
      a.update(data: d); b.update(data: d); c.update(data: d)
    }
    func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
    return [.sha256: hex(a.finalize()), .sha1: hex(b.finalize()), .md5: hex(c.finalize())]
  }

  /// Pasted hashes: case and surrounding text ignored (`shasum` output has the file name after the hash).
  static func normalized(_ s: String) -> String {
    s.split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
  }

  /// One-click: `shasum -a 256` style lines on the clipboard.
  static func copySHA256(_ urls: [URL]) async throws -> [URL] {
    let lines = try await Task.detached { try urls.map { "\(try digests($0)[.sha256]!)  \($0.lastPathComponent)" } }.value
    await MainActor.run {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
    return []
  }
}
