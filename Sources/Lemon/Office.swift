import AppKit
import PDFKit
import UniformTypeIdentifiers

extension Tools {
  static let office: [Tool] = [
    // PDF (after the PNG/JPG/DOCX/RTF/TXT petals in `convert`)
    Tool(id: "pdf.pptx", mode: .convert, title: "Convert to PPTX", short: "PPTX", symbol: "rectangle.on.rectangle", kinds: [.pdf],
         run: each(OfficeTools.pdfToPPTX)),
    Tool(id: "pdf.xlsx", mode: .convert, title: "Convert to XLSX (tables)", short: "XLSX", symbol: "tablecells", kinds: [.pdf],
         run: each(Sheets.pdfToXLSX)),
    Tool(id: "pdf.epub", mode: .convert, title: "Convert to EPUB", short: "EPUB", symbol: "book", kinds: [.pdf],
         run: each(OfficeTools.pdfToEPUB)),
    Tool(id: "pdf.md", mode: .convert, title: "Convert to Markdown", short: "MD", symbol: "number", kinds: [.pdf],
         run: each(OfficeTools.pdfToMarkdown)),
    // Documents
    Tool(id: "doc.md", mode: .convert, title: "Convert to Markdown", short: "MD", symbol: "number", kinds: [.document],
         outputExt: "md", run: each(OfficeTools.docToMarkdown)),
    Tool(id: "doc.epub", mode: .convert, title: "Convert to EPUB", short: "EPUB", symbol: "book", kinds: [.document],
         outputExt: "epub", run: each(OfficeTools.docToEPUB)),
    // Slides
    Tool(id: "slides.pdf", mode: .convert, title: "Convert to PDF", short: "PDF", symbol: "doc.richtext", kinds: [.slides],
         run: each(Slides.pdf)),
    Tool(id: "slides.jpg", mode: .convert, title: "Slides to JPG", short: "JPG", symbol: "photo", kinds: [.slides],
         run: eachMany { try Slides.images($0, type: .jpeg, ext: "jpg") }),
    Tool(id: "slides.png", mode: .convert, title: "Slides to PNG", short: "PNG", symbol: "photo", kinds: [.slides],
         run: eachMany { try Slides.images($0, type: .png, ext: "png") }),
    // Spreadsheets
    Tool(id: "sheet.xlsx", mode: .convert, title: "Convert to XLSX", short: "XLSX", symbol: "tablecells", kinds: [.spreadsheet],
         outputExt: "xlsx", run: each { try Sheets.convert($0, ext: "xlsx") }),
    Tool(id: "sheet.ods", mode: .convert, title: "Convert to ODS", short: "ODS", symbol: "tablecells", kinds: [.spreadsheet],
         outputExt: "ods", run: each { try Sheets.convert($0, ext: "ods") }),
    Tool(id: "sheet.pdf", mode: .convert, title: "Convert to PDF", short: "PDF", symbol: "doc.richtext", kinds: [.spreadsheet],
         run: each(Sheets.pdf)),
    // Subtitles
    Tool(id: "sub.txt", mode: .convert, title: "Dialogue to TXT", short: "TXT", symbol: "text.alignleft", kinds: [.subtitle],
         run: each(OfficeTools.subtitleText)),
  ]
}

// MARK: - Document model shared by the Markdown, EPUB and DOCX writers

struct Run: Equatable {
  var text: String
  var bold = false, italic = false
  var link: String? = nil
}

enum Block {
  case heading(Int, [Run]), para([Run]), item(ordered: Bool, [Run])
  case image(Data, CGSize)  // JPEG, display size in points
  case pageBreak
}

enum OfficeTools {
  // MARK: Inputs DocTools can't read itself

  /// EPUB and text clippings as attributed text; nil for formats NSAttributedString handles.
  static func read(_ u: URL) throws -> NSAttributedString? {
    switch u.pathExtension.lowercased() {
    case "epub": return attributed(try epubBlocks(u))
    case "textclipping": return try clipping(u)
    default: return nil
    }
  }

  // ponytail: only the plist clippings macOS has written since 10.12; old resource-fork clippings fail with a message.
  static func clipping(_ u: URL) throws -> NSAttributedString {
    guard let plist = try? PropertyListSerialization.propertyList(from: Data(contentsOf: u), format: nil) as? [String: Any],
          let d = plist["UTI-Data"] as? [String: Any] else { throw ToolError("Can't read \(u.lastPathComponent) (an old-style clipping?)") }
    for k in ["public.rtf", "com.apple.flat-rtfd"] {
      if let data = d[k] as? Data, let s = try? NSAttributedString(data: data, options: [:], documentAttributes: nil) { return s }
    }
    for k in ["public.utf8-plain-text", "public.utf16-plain-text", "public.plain-text", "public.url"] {
      if let s = d[k] as? String { return NSAttributedString(string: s) }
      if let data = d[k] as? Data, let s = String(data: data, encoding: k.contains("utf16") ? .utf16 : .utf8) { return NSAttributedString(string: s) }
    }
    throw ToolError("\(u.lastPathComponent) holds no text")
  }

  static func epubBlocks(_ u: URL) throws -> [Block] {
    let z = try ZipReader(u)
    guard let opfPath = z.xml("META-INF/container.xml")?.first("rootfile")?.attr("full-path"), let opf = z.xml(opfPath) else {
      throw ToolError("\(u.lastPathComponent) isn't a valid EPUB")
    }
    var hrefs: [String: String] = [:]
    for i in opf.first("manifest")?.kids("item") ?? [] { if let id = i.attr("id"), let h = i.attr("href") { hrefs[id] = h } }
    var out: [Block] = []
    for ref in opf.first("spine")?.kids("itemref") ?? [] {
      guard let href = ref.attr("idref").flatMap({ hrefs[$0] })?.components(separatedBy: "#")[0],
            let body = z.xml(resolvePart(opfPath, href))?.first("body") else { continue }
      out += blocks(html: body)
    }
    guard out.contains(where: { if case .image = $0 { false } else { true } }) else { throw ToolError("No text in \(u.lastPathComponent)") }
    return out
  }

  /// Block structure of an XHTML body: headings, paragraphs and list items with bold/italic/link runs.
  // ponytail: images and table layout are dropped; cells become paragraphs.
  static func blocks(html body: XMLElement) -> [Block] {
    let blockNames: Set<String> = ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "section", "article",
                                   "main", "header", "footer", "nav", "aside", "figure", "figcaption", "table", "thead", "tbody", "tr", "td", "th",
                                   "dl", "dt", "dd", "hr", "body"]
    var out: [Block] = []
    func inline(_ n: XMLNode, _ style: Run, _ runs: inout [Run]) {
      if n.kind == .text { runs.append(Run(text: n.stringValue ?? "", bold: style.bold, italic: style.italic, link: style.link)); return }
      guard let e = n as? XMLElement, let name = e.localName?.lowercased(), !["script", "style", "img", "head"].contains(name) else { return }
      if name == "br" { runs.append(Run(text: "\n")); return }
      var s = style
      if ["b", "strong"].contains(name) { s.bold = true }
      if ["i", "em", "cite"].contains(name) { s.italic = true }
      if name == "a", let h = e.attr("href"), h.contains(":") { s.link = h }
      for c in e.children ?? [] { inline(c, s, &runs) }
    }
    func emit(_ runs: [Run], _ make: ([Run]) -> Block) {
      let r = tidy(runs)
      if !r.isEmpty { out.append(make(r)) }
    }
    func walk(_ e: XMLElement, ordered: Bool) {
      let name = e.localName?.lowercased() ?? ""
      if ["script", "style", "head", "img"].contains(name) { return }
      if name.count == 2, name.hasPrefix("h"), let l = Int(name.dropFirst()) {
        var r: [Run] = []; inline(e, Run(text: ""), &r); emit(r) { .heading(l, $0) }; return
      }
      if name == "li" { var r: [Run] = []; inline(e, Run(text: ""), &r); emit(r) { .item(ordered: ordered, $0) }; return }
      let hasBlocks = e.elements.contains { blockNames.contains($0.localName?.lowercased() ?? "") }
      guard hasBlocks else { var r: [Run] = []; inline(e, Run(text: ""), &r); emit(r) { .para($0) }; return }
      var pending: [Run] = []
      for c in e.children ?? [] {
        if let ce = c as? XMLElement, blockNames.contains(ce.localName?.lowercased() ?? "") {
          emit(pending) { .para($0) }; pending = []
          walk(ce, ordered: name == "ol" ? true : name == "ul" ? false : ordered)
        } else { inline(c, Run(text: ""), &pending) }
      }
      emit(pending) { .para($0) }
    }
    walk(body, ordered: false)
    return out
  }

  /// Collapses HTML whitespace and merges neighbouring runs with the same style.
  static func tidy(_ runs: [Run]) -> [Run] {
    var out: [Run] = []
    for var r in runs {
      r.text = r.text.replacingOccurrences(of: "[ \\t\\r\\n]+", with: " ", options: .regularExpression)
      if r.text.isEmpty { continue }
      if let last = out.last, last.bold == r.bold, last.italic == r.italic, last.link == r.link { out[out.count - 1].text += r.text } else { out.append(r) }
    }
    if !out.isEmpty { out[0].text = String(out[0].text.drop { $0 == " " }) }
    if !out.isEmpty { out[out.count - 1].text = String(out[out.count - 1].text.reversed().drop { $0 == " " }.reversed()) }
    return out.filter { !$0.text.isEmpty }
  }

  static func attributed(_ blocks: [Block]) -> NSAttributedString {
    let out = NSMutableAttributedString(), fm = NSFontManager.shared
    var n = 0
    for b in blocks {
      var size: CGFloat = 12, bold = false, prefix = "", indent: CGFloat = 0
      let runs: [Run]
      switch b {
      case .heading(let l, let r): size = [24, 18, 15, 13, 12, 12][min(max(l, 1), 6) - 1]; bold = true; runs = r; n = 0
      case .para(let r): runs = r; n = 0
      case .item(let ordered, let r): n += 1; prefix = ordered ? "\(n).\t" : "•\t"; indent = 18; runs = r
      case .image, .pageBreak: continue
      }
      let ps = NSMutableParagraphStyle()
      ps.paragraphSpacing = 6
      ps.headIndent = indent
      ps.tabStops = indent > 0 ? [NSTextTab(textAlignment: .left, location: indent)] : []
      let base = NSFont.systemFont(ofSize: size)
      out.append(NSAttributedString(string: prefix, attributes: [.font: base, .paragraphStyle: ps]))
      for r in runs {
        var f = base
        if bold || r.bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if r.italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        var a: [NSAttributedString.Key: Any] = [.font: f, .paragraphStyle: ps]
        if let l = r.link, let u = URL(string: l) { a[.link] = u }
        out.append(NSAttributedString(string: r.text, attributes: a))
      }
      out.append(NSAttributedString(string: "\n", attributes: [.font: base, .paragraphStyle: ps]))
    }
    return out
  }

  // MARK: NSAttributedString → blocks

  static func blocks(_ s: NSAttributedString) -> [Block] {
    var sizes: [CGFloat: Int] = [:]
    s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { v, r, _ in
      sizes[((v as? NSFont)?.pointSize ?? 12).rounded(), default: 0] += r.length
    }
    let body = sizes.max { $0.value < $1.value }?.key ?? 12
    let ns = s.string as NSString
    var out: [Block] = []
    ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in
      guard r.length > 0 else { return }
      var runs = self.runs(s.attributedSubstring(from: r))
      let text = runs.map(\.text).joined().trimmingCharacters(in: .whitespaces)
      guard !text.isEmpty else { return }
      if let list = (s.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)?.textLists.last {
        // Cocoa puts the marker in the text: "\t•\tItem"
        if runs[0].text.hasPrefix("\t"), let i = runs[0].text.dropFirst().firstIndex(of: "\t") { runs[0].text = String(runs[0].text[runs[0].text.index(after: i)...]) }
        let ordered = ["decimal", "alpha", "roman", "latin", "octal", "hex"].contains { list.markerFormat.rawValue.lowercased().contains($0) }
        out.append(.item(ordered: ordered, runs.filter { !$0.text.isEmpty }))
        return
      }
      var size: CGFloat = 0
      s.enumerateAttribute(.font, in: r) { v, _, _ in size = max(size, (v as? NSFont)?.pointSize ?? 12) }
      let bold = runs.allSatisfy { $0.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
      if size >= body * 1.5 { out.append(.heading(1, plain(runs))) }
      else if size >= body * 1.25 { out.append(.heading(2, plain(runs))) }
      else if size > body * 1.05 || (bold && text.count < 60 && !".:;,".contains(text.last!)) { out.append(.heading(3, plain(runs))) }
      else { out.append(.para(runs)) }
    }
    return out
  }

  private static func plain(_ runs: [Run]) -> [Run] { runs.map { Run(text: $0.text, italic: $0.italic, link: $0.link) } }

  static func runs(_ a: NSAttributedString) -> [Run] {
    var out: [Run] = []
    a.enumerateAttributes(in: NSRange(location: 0, length: a.length)) { at, r, _ in
      let t = (a.string as NSString).substring(with: r).replacingOccurrences(of: "\n", with: "")
      let traits = (at[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
      let link = (at[.link] as? URL)?.absoluteString ?? at[.link] as? String
      let run = Run(text: t, bold: traits.contains(.bold), italic: traits.contains(.italic), link: link)
      if let last = out.last, last.bold == run.bold, last.italic == run.italic, last.link == run.link { out[out.count - 1].text += t } else { out.append(run) }
    }
    return out.filter { !$0.text.isEmpty }
  }

  // MARK: Markdown

  static func markdown(_ blocks: [Block]) -> String {
    func esc(_ s: String) -> String {
      var o = ""
      for ch in s { if "\\*_`[]".contains(ch) { o.append("\\") }; o.append(ch) }
      return o
    }
    func inline(_ runs: [Run]) -> String {
      runs.map { r in
        let t = esc(r.text), core = t.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return t }
        var s = core
        if r.bold || r.italic { let m = r.bold && r.italic ? "***" : r.bold ? "**" : "*"; s = m + s + m }
        if let l = r.link { s = "[\(s)](\(l.replacingOccurrences(of: " ", with: "%20")))" }
        let lead = t.prefix { $0 == " " }, trail = String(t.reversed().prefix { $0 == " " })
        return lead + s + trail
      }.joined()
    }
    var parts: [String] = [], n = 0, prevItem = false
    for b in blocks {
      var line: String, item = false
      switch b {
      case .heading(let l, let r): line = String(repeating: "#", count: min(l, 6)) + " " + inline(r)
      case .para(let r):
        line = inline(r)
        if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("- ") { line = "\\" + line }
      case .item(let ordered, let r):
        n = prevItem ? n + 1 : 1; item = true
        line = (ordered ? "\(n). " : "- ") + inline(r)
      case .image, .pageBreak: continue
      }
      if item && prevItem { parts[parts.count - 1] += "\n" + line } else { parts.append(line) }
      prevItem = item
    }
    return parts.joined(separator: "\n\n") + "\n"
  }

  // MARK: EPUB 3

  static func xhtml(_ blocks: [Block]) -> String {
    func inline(_ runs: [Run]) -> String {
      runs.map { r in
        var s = xmlEscape(r.text)
        if r.bold { s = "<strong>\(s)</strong>" }
        if r.italic { s = "<em>\(s)</em>" }
        if let l = r.link { s = "<a href=\"\(xmlEscape(l))\">\(s)</a>" }
        return s
      }.joined()
    }
    var html = "", list: Bool? = nil
    func close() { if let o = list { html += o ? "</ol>\n" : "</ul>\n"; list = nil } }
    for b in blocks {
      if case .item(let o, let r) = b {
        if list != o { close(); html += o ? "<ol>\n" : "<ul>\n"; list = o }
        html += "<li>\(inline(r))</li>\n"
        continue
      }
      close()
      switch b {
      case .heading(let l, let r): html += "<h\(min(l, 6))>\(inline(r))</h\(min(l, 6))>\n"
      case .para(let r): html += "<p>\(inline(r))</p>\n"
      default: break
      }
    }
    close()
    return html
  }

  static func epub(title: String, chapters: [(title: String, blocks: [Block])], to out: URL) throws {
    func page(_ t: String, _ body: String) -> String {
      """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE html>
      <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="en" lang="en">
      <head><meta charset="utf-8"/><title>\(xmlEscape(t))</title></head>
      <body>
      \(body)</body>
      </html>
      """
    }
    var z = ZipWriter()
    z.add("mimetype", "application/epub+zip", store: true)
    z.add("META-INF/container.xml", """
      <?xml version="1.0" encoding="UTF-8"?>
      <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
      <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
      </container>
      """)
    var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>\n", spine = "", toc = ""
    for (i, c) in chapters.enumerated() {
      z.add("OEBPS/c\(i + 1).xhtml", page(c.title, xhtml(c.blocks)))
      manifest += "<item id=\"c\(i + 1)\" href=\"c\(i + 1).xhtml\" media-type=\"application/xhtml+xml\"/>\n"
      spine += "<itemref idref=\"c\(i + 1)\"/>\n"
      toc += "<li><a href=\"c\(i + 1).xhtml\">\(xmlEscape(c.title))</a></li>\n"
    }
    z.add("OEBPS/nav.xhtml", page(title, "<nav epub:type=\"toc\" id=\"toc\"><h1>Contents</h1>\n<ol>\n\(toc)</ol></nav>\n"))
    let modified = ISO8601DateFormatter().string(from: Date())
    z.add("OEBPS/content.opf", """
      <?xml version="1.0" encoding="UTF-8"?>
      <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid" xml:lang="en">
      <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
      <dc:identifier id="uid">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>
      <dc:title>\(xmlEscape(title))</dc:title>
      <dc:language>en</dc:language>
      <meta property="dcterms:modified">\(modified)</meta>
      </metadata>
      <manifest>
      \(manifest)</manifest>
      <spine>
      \(spine)</spine>
      </package>
      """)
    try z.write(to: out)
  }

  /// One chapter per top-level heading (or one for the whole text).
  static func chapters(_ blocks: [Block], title: String) -> [(title: String, blocks: [Block])] {
    var out: [(title: String, blocks: [Block])] = []
    for b in blocks {
      if case .heading(1, let r) = b { out.append((r.map(\.text).joined(), [b])); continue }
      if out.isEmpty { out.append((title, [])) }
      out[out.count - 1].blocks.append(b)
    }
    return out.isEmpty ? [(title, [])] : out
  }

  static func docToMarkdown(_ src: URL) throws -> URL {
    let out = outputURL(for: src, ext: "md")
    try markdown(blocks(try DocTools.read(src))).write(to: out, atomically: true, encoding: .utf8)
    return out
  }

  static func docToEPUB(_ src: URL) throws -> URL {
    let title = src.deletingPathExtension().lastPathComponent
    let out = outputURL(for: src, ext: "epub")
    try epub(title: title, chapters: chapters(blocks(try DocTools.read(src)), title: title), to: out)
    return out
  }

  // MARK: PDF → structured text

  /// Per page: headings by font size, list items by their markers, wrapped lines joined into paragraphs.
  /// Pages with almost no text (scans) get a rendered image when `scans` is set.
  static func pdfBlocks(_ d: PDFDocument, scans: Bool) -> [[Block]] {
    struct Line { let text: String, size: CGFloat, bold: Bool }
    let pages = PDFTools.pages(d)
    let lines: [[Line]] = pages.map { p in
      guard let a = p.attributedString else { return [] }
      var out: [Line] = []
      (a.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: a.length), options: .byLines) { s, r, _, _ in
        let t = (s ?? "").trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var size: CGFloat = 0, boldChars = 0
        a.enumerateAttribute(.font, in: r) { v, rr, _ in
          let f = v as? NSFont
          size = max(size, f?.pointSize ?? 12)
          if f?.fontDescriptor.symbolicTraits.contains(.bold) == true || f?.fontName.lowercased().contains("bold") == true { boldChars += rr.length }
        }
        out.append(Line(text: t, size: size, bold: boldChars * 2 > r.length))
      }
      return out
    }
    var sizes: [CGFloat: Int] = [:]
    for l in lines.joined() { sizes[l.size.rounded(), default: 0] += l.text.count }
    let body = sizes.max { $0.value < $1.value }?.key ?? 12
    let marker = try! NSRegularExpression(pattern: "^([•◦▪●‣∙·\\-–*]|\\d{1,3}[.)])\\s+")

    return zip(pages, lines).map { page, lines in
      var out: [Block] = [], para = ""
      func flush() { if !para.isEmpty { out.append(.para([Run(text: para)])); para = "" } }
      let longest = lines.map(\.text.count).max() ?? 0
      for l in lines {
        let ns = l.text as NSString
        if l.size >= body * 1.2, l.text.count < 120 {
          flush()
          let level = l.size >= body * 1.6 ? 1 : 2
          // a heading wrapped over two lines stays one heading
          if case .heading(level, let r)? = out.last { out[out.count - 1] = .heading(level, [Run(text: r[0].text + " " + l.text)]) }
          else { out.append(.heading(level, [Run(text: l.text)])) }
        } else if let m = marker.firstMatch(in: l.text, range: NSRange(location: 0, length: ns.length)) {
          flush()
          out.append(.item(ordered: ns.substring(to: 1).first!.isNumber, [Run(text: ns.substring(from: m.range.length), bold: l.bold)]))
        } else {
          if para.isEmpty { para = l.text }
          else if para.hasSuffix("-"), para.dropLast().last?.isLetter == true { para = String(para.dropLast()) + l.text }
          else { para += " " + l.text }
          if Double(l.text.count) < Double(longest) * 0.7 || l.text.hasSuffix(":") { flush() }
        }
      }
      flush()
      let chars = lines.reduce(0) { $0 + $1.text.count }
      if scans, chars < 20, let img = pageJPEG(page, dpi: 150) {
        let b = page.bounds(for: .mediaBox).size, k = min(1, 468 / max(b.width, 1))
        out.append(.image(img, CGSize(width: b.width * k, height: b.height * k)))
      }
      return out
    }
  }

  static func pageJPEG(_ p: PDFPage, dpi: CGFloat, maxSide: CGFloat = 4000) -> Data? {
    guard let img = pageImage(p, dpi: dpi, maxSide: maxSide) else { return nil }
    return ImageTools.encode(img, props: [:], type: .jpeg, quality: 0.85)
  }

  static func pageImage(_ p: PDFPage, dpi: CGFloat, maxSide: CGFloat) -> CGImage? {
    var b = p.bounds(for: .mediaBox).size
    if p.rotation % 180 != 0 { b = CGSize(width: b.height, height: b.width) }
    let k = min(dpi / 72, maxSide / max(b.width, b.height, 1))
    return p.thumbnail(of: NSSize(width: (b.width * k).rounded(), height: (b.height * k).rounded()), for: .mediaBox)
      .cgImage(forProposedRect: nil, context: nil, hints: nil)
  }

  static func pdfToMarkdown(_ src: URL) throws -> URL {
    let blocks = pdfBlocks(try PDFTools.open(src), scans: false).joined()
    guard !blocks.isEmpty else { throw ToolError("No text in \(src.lastPathComponent) (scanned? try Pages to images, then Extract text)") }
    let out = outputURL(for: src, ext: "md")
    try markdown(Array(blocks)).write(to: out, atomically: true, encoding: .utf8)
    return out
  }

  static func pdfToEPUB(_ src: URL) throws -> URL {
    let d = try PDFTools.open(src)
    let pages = pdfBlocks(d, scans: false)
    guard pages.contains(where: { !$0.isEmpty }) else { throw ToolError("No text in \(src.lastPathComponent)") }
    let title = (d.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? src.deletingPathExtension().lastPathComponent
    let out = outputURL(for: src, ext: "epub")
    try epub(title: title, chapters: pages.enumerated().map { ("Page \($0.offset + 1)", $0.element) }, to: out)
    return out
  }

  /// Paragraphs and headings per page, a page break between pages, and the page image for scans.
  static func pdfToDOCX(_ src: URL) throws -> URL {
    let d = try PDFTools.open(src)
    let pages = pdfBlocks(d, scans: true)
    var blocks: [Block] = []
    for (i, p) in pages.enumerated() { if i > 0 { blocks.append(.pageBreak) }; blocks += p }
    let size = d.page(at: 0)?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792)
    let out = outputURL(for: src, ext: "docx")
    try docx(blocks, page: size, to: out)
    return out
  }

  // MARK: DOCX writer

  static func docx(_ blocks: [Block], page: CGSize, to out: URL) throws {
    func runs(_ r: [Run], bold: Bool = false) -> String {
      r.map { r in
        let pr = (r.bold || bold ? "<w:b/>" : "") + (r.italic ? "<w:i/>" : "")
        return "<w:r>\(pr.isEmpty ? "" : "<w:rPr>\(pr)</w:rPr>")<w:t xml:space=\"preserve\">\(xmlEscape(r.text))</w:t></w:r>"
      }.joined()
    }
    var body = "", media: [Data] = [], n = 0
    for b in blocks {
      switch b {
      case .heading(let l, let r): body += "<w:p><w:pPr><w:pStyle w:val=\"Heading\(min(l, 3))\"/></w:pPr>\(runs(r))</w:p>"; n = 0
      case .para(let r): body += "<w:p>\(runs(r))</w:p>"; n = 0
      case .item(let ordered, let r):
        n += 1
        body += "<w:p><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr>\(runs([Run(text: ordered ? "\(n).\t" : "•\t")] + r))</w:p>"
      case .pageBreak: body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
      case .image(let data, let size):
        media.append(data)
        let i = media.count, cx = Int(size.width * 12700), cy = Int(size.height * 12700)
        body += """
          <w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
          <wp:docPr id="\(i)" name="Picture \(i)"/><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
          <pic:pic><pic:nvPicPr><pic:cNvPr id="\(i)" name="image\(i).jpg"/><pic:cNvPicPr/></pic:nvPicPr>\
          <pic:blipFill><a:blip r:embed="rImg\(i)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
          <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
          </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>
          """
      }
    }
    let w = Int(page.width * 20), h = Int(page.height * 20)
    var z = ZipWriter()
    z.add("[Content_Types].xml", """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
      <Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/>\
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
      <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/></Types>
      """)
    z.add("_rels/.rels", rels([("rId1", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument", "word/document.xml")]))
    z.add("word/_rels/document.xml.rels", rels([("rStyles", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles", "styles.xml")]
      + media.indices.map { ("rImg\($0 + 1)", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image", "media/image\($0 + 1).jpg") }))
    for (i, m) in media.enumerated() { z.add("word/media/image\(i + 1).jpg", m, store: true) }
    func heading(_ l: Int, _ size: Int) -> String {
      """
      <w:style w:type="paragraph" w:styleId="Heading\(l)"><w:name w:val="heading \(l)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/>\
      <w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="\(l - 1)"/></w:pPr>\
      <w:rPr><w:b/><w:sz w:val="\(size)"/></w:rPr></w:style>
      """
    }
    z.add("word/styles.xml", """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
      <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/>\
      <w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr><w:rPr><w:sz w:val="22"/></w:rPr></w:style>\
      \(heading(1, 36))\(heading(2, 28))\(heading(3, 24))</w:styles>
      """)
    z.add("word/document.xml", """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
      xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
      xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
      <w:body>\(body)<w:sectPr><w:pgSz w:w="\(w)" w:h="\(h)"/>\
      <w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr></w:body></w:document>
      """)
    try z.write(to: out)
  }

  static func rels(_ items: [(id: String, type: String, target: String)]) -> String {
    "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
      + items.map { "<Relationship Id=\"\($0.id)\" Type=\"\($0.type)\" Target=\"\(xmlEscape($0.target))\"/>" }.joined() + "</Relationships>"
  }

  // MARK: PDF → PPTX

  // ponytail: each slide is the page as a picture; text isn't editable. Text boxes over it would need font matching.
  static func pdfToPPTX(_ src: URL) throws -> URL {
    let pages = PDFTools.pages(try PDFTools.open(src))
    guard let first = pages.first else { throw ToolError("\(src.lastPathComponent) has no pages") }
    func size(_ p: PDFPage) -> CGSize {
      let b = p.bounds(for: .mediaBox).size
      return p.rotation % 180 == 0 ? b : CGSize(width: b.height, height: b.width)
    }
    // PowerPoint accepts slide sides from 1 to 56 inches
    let s0 = size(first), k = min(1, 4032 / max(s0.width, s0.height)), minK = max(1, 72 / min(s0.width, s0.height))
    let slide = CGSize(width: s0.width * max(k, minK), height: s0.height * max(k, minK))
    var images: [Data] = [], places: [CGRect] = []
    for (i, p) in pages.enumerated() {
      guard let jpg = pageJPEG(p, dpi: 200, maxSide: 3000) else { throw ToolError("Couldn't render page \(i + 1)") }
      let s = size(p), f = min(slide.width / s.width, slide.height / s.height)
      let w = s.width * f, h = s.height * f
      images.append(jpg)
      places.append(CGRect(x: (slide.width - w) / 2, y: (slide.height - h) / 2, width: w, height: h))
    }
    let out = outputURL(for: src, ext: "pptx")
    try PPTXWriter.write(slide: slide, pictures: Array(zip(images, places)), to: out)
    return out
  }

  // MARK: Subtitles → dialogue

  static func subtitleText(_ src: URL) throws -> URL {
    let lines = try TextTools.cues(src).flatMap(\.1).map {
      $0.replacingOccurrences(of: "<[^>]+>|\\{\\\\[^}]*\\}", with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }.filter { !$0.isEmpty }
    guard !lines.isEmpty else { throw ToolError("No dialogue in \(src.lastPathComponent)") }
    let out = outputURL(for: src, ext: "txt")
    try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8)
    return out
  }
}

// MARK: - PPTX writer (pictures only)

enum PPTXWriter {
  static func emu(_ pt: CGFloat) -> Int { Int((pt * 12700).rounded()) }

  static func write(slide: CGSize, pictures: [(Data, CGRect)], to out: URL) throws {
    let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    let tree = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
    let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    var z = ZipWriter()
    var types = """
      \(head)<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
      <Default Extension="xml" ContentType="application/xml"/><Default Extension="jpg" ContentType="image/jpeg"/>\
      <Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>\
      <Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>\
      <Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>\
      <Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>
      """
    z.add("_rels/.rels", OfficeTools.rels([("rId1", rel + "officeDocument", "ppt/presentation.xml")]))
    var presRels: [(id: String, type: String, target: String)] = [("rId1", rel + "slideMaster", "slideMasters/slideMaster1.xml"), ("rId2", rel + "theme", "theme/theme1.xml")]
    var ids = ""
    for (i, (jpg, r)) in pictures.enumerated() {
      let n = i + 1
      types += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
      presRels.append(("rIdS\(n)", rel + "slide", "slides/slide\(n).xml"))
      ids += "<p:sldId id=\"\(255 + n)\" r:id=\"rIdS\(n)\"/>"
      z.add("ppt/media/page\(n).jpg", jpg, store: true)
      z.add("ppt/slides/_rels/slide\(n).xml.rels", OfficeTools.rels([("rId1", rel + "slideLayout", "../slideLayouts/slideLayout1.xml"),
                                                                     ("rId2", rel + "image", "../media/page\(n).jpg")]))
      z.add("ppt/slides/slide\(n).xml", """
        \(head)<p:sld \(ns)><p:cSld><p:spTree>\(tree)<p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \(n)"/>\
        <p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
        <p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
        <p:spPr><a:xfrm><a:off x="\(emu(r.minX))" y="\(emu(r.minY))"/><a:ext cx="\(emu(r.width))" cy="\(emu(r.height))"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic></p:spTree></p:cSld>\
        <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
        """)
    }
    z.add("[Content_Types].xml", types + "</Types>")
    z.add("ppt/_rels/presentation.xml.rels", OfficeTools.rels(presRels))
    z.add("ppt/presentation.xml", """
      \(head)<p:presentation \(ns) saveSubsetFonts="1"><p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
      <p:sldIdLst>\(ids)</p:sldIdLst><p:sldSz cx="\(emu(slide.width))" cy="\(emu(slide.height))"/><p:notesSz cx="6858000" cy="9144000"/>\
      </p:presentation>
      """)
    z.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", OfficeTools.rels([("rId1", rel + "slideLayout", "../slideLayouts/slideLayout1.xml"),
                                                                           ("rId2", rel + "theme", "../theme/theme1.xml")]))
    z.add("ppt/slideMasters/slideMaster1.xml", """
      \(head)<p:sldMaster \(ns)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\(tree)</p:spTree></p:cSld>\
      <p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" \
      accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>\
      <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst></p:sldMaster>
      """)
    z.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", OfficeTools.rels([("rId1", rel + "slideMaster", "../slideMasters/slideMaster1.xml")]))
    z.add("ppt/slideLayouts/slideLayout1.xml", """
      \(head)<p:sldLayout \(ns) type="blank" preserve="1"><p:cSld name="Blank"><p:spTree>\(tree)</p:spTree></p:cSld>\
      <p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
      """)
    z.add("ppt/theme/theme1.xml", theme)
    try z.write(to: out)
  }

  static let theme: String = {
    let colors = [("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "44546A"), ("lt2", "E7E6E6"), ("accent1", "4472C4"), ("accent2", "ED7D31"),
                  ("accent3", "A5A5A5"), ("accent4", "FFC000"), ("accent5", "5B9BD5"), ("accent6", "70AD47"), ("hlink", "0563C1"), ("folHlink", "954F72")]
      .map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
    let fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>"
    let line = "<a:ln w=\"6350\"><a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill></a:ln>"
    let effect = "<a:effectStyle><a:effectLst/></a:effectStyle>"
    let font = "<a:latin typeface=\"Helvetica Neue\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>"
    return """
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Lemon"><a:themeElements>\
      <a:clrScheme name="Lemon">\(colors)</a:clrScheme>\
      <a:fontScheme name="Lemon"><a:majorFont>\(font)</a:majorFont><a:minorFont>\(font)</a:minorFont></a:fontScheme>\
      <a:fmtScheme name="Lemon"><a:fillStyleLst>\(fill)\(fill)\(fill)</a:fillStyleLst><a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>\
      <a:effectStyleLst>\(effect)\(effect)\(effect)</a:effectStyleLst><a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme>\
      </a:themeElements></a:theme>
      """
  }()
}
