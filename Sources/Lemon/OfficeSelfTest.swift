import AppKit
import CoreText
import PDFKit

extension SelfTest {
  /// Compound file holding one stream (padded past the 4096-byte mini-stream cutoff).
  static func compoundFile(_ name: String, _ stream: Data) -> Data {
    var s = stream
    if s.count < 4096 { s += Data(count: 4096 - s.count) }
    let sectors = (s.count + 511) / 512
    var h = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) + Data(count: 16)
    h.le(UInt16(0x3E)); h.le(UInt16(3)); h.le(UInt16(0xFFFE)); h.le(UInt16(9)); h.le(UInt16(6)); h += Data(count: 6)
    h.le(UInt32(0)); h.le(UInt32(1)); h.le(UInt32(1)); h.le(UInt32(0)); h.le(UInt32(4096))  // dirs, FAT sectors, first dir, txn, cutoff
    h.le(UInt32(0xFFFFFFFE)); h.le(UInt32(0)); h.le(UInt32(0xFFFFFFFE)); h.le(UInt32(0))
    h.le(UInt32(0)); for _ in 1..<109 { h.le(UInt32(0xFFFFFFFF)) }
    var fat = Data(); fat.le(UInt32(0xFFFFFFFD)); fat.le(UInt32(0xFFFFFFFE))
    for i in 0..<sectors { fat.le(UInt32(i == sectors - 1 ? 0xFFFFFFFE : 3 + i)) }
    while fat.count < 512 { fat.le(UInt32(0xFFFFFFFF)) }
    func entry(_ n: String, type: UInt8, start: UInt32, size: Int, child: UInt32) -> Data {
      var e = Data(); for u in n.utf16 { e.le(u) }; e += Data(count: 64 - e.count)
      e.le(UInt16((n.utf16.count + 1) * 2)); e.append(type); e.append(1)
      e.le(UInt32(0xFFFFFFFF)); e.le(UInt32(0xFFFFFFFF)); e.le(child); e += Data(count: 36)
      e.le(start); e.le(UInt32(size)); e.le(UInt32(0))
      return e
    }
    var dir = entry("Root Entry", type: 5, start: 0xFFFFFFFE, size: 0, child: 1) + entry(name, type: 2, start: 2, size: s.count, child: 0xFFFFFFFF)
    dir += Data(count: 512 - dir.count)
    return h + fat + dir + s + Data(count: sectors * 512 - s.count)
  }

  static func record(_ type: UInt16, _ payload: Data, ver: UInt16 = 0) -> Data {
    var d = Data(); d.le(ver); d.le(type); d.le(UInt32(payload.count)); return d + payload
  }

  static func biff(_ type: UInt16, _ payload: Data) -> Data { var d = Data(); d.le(type); d.le(UInt16(payload.count)); return d + payload }

  static func xlsFixture() -> Data {
    func bof(_ dt: UInt16) -> Data { var p = Data(); p.le(UInt16(0x0600)); p.le(dt); p += Data(count: 12); return biff(0x0809, p) }
    var sst = Data(); sst.le(UInt32(2)); sst.le(UInt32(2))
    for s in ["Fruit", "Pear"] { sst.le(UInt16(s.count)); sst.append(0); sst += Data(s.utf8) }
    func sheetRec(_ off: UInt32) -> Data { var p = Data(); p.le(off); p += Data([0, 0, 6, 0]); p += Data("Prices".utf8); return biff(0x0085, p) }
    let globalsLen = bof(5).count + sheetRec(0).count + biff(0x00FC, sst).count + biff(0x000A, Data()).count
    var cells = Data()
    var p = Data(); p.le(UInt16(0)); p.le(UInt16(0)); p.le(UInt16(0)); p.le(UInt32(0)); cells += biff(0x00FD, p)
    p = Data(); p.le(UInt16(0)); p.le(UInt16(1)); p.le(UInt16(0)); p.le(UInt64(3.5.bitPattern)); cells += biff(0x0203, p)
    p = Data(); p.le(UInt16(1)); p.le(UInt16(0)); p.le(UInt16(0)); p.le(UInt32(1)); cells += biff(0x00FD, p)
    p = Data(); p.le(UInt16(1)); p.le(UInt16(1)); p.le(UInt16(0)); p.le(UInt32(42 << 2 | 2)); cells += biff(0x027E, p)
    return bof(5) + sheetRec(UInt32(globalsLen)) + biff(0x00FC, sst) + biff(0x000A, Data()) + bof(0x10) + cells + biff(0x000A, Data())
  }

  static func pptFixture() -> Data {
    var doc = Data(); doc.le(UInt32(5760)); doc.le(UInt32(4320)); doc += Data(count: 32)
    func u32(_ v: UInt32) -> Data { var d = Data(); d.le(v); return d }
    var chars = Data(); for u in "Legacy Title".utf16 { chars.le(u) }
    let list = record(0x03F3, Data(count: 20)) + record(0x0F9F, u32(0)) + record(0x0FA0, chars)
      + record(0x0F9F, u32(1)) + record(0x0FA8, Data("Point one\rPoint two".utf8))
    return record(0x03E8, record(0x03E9, doc) + record(0x0FF0, list, ver: 0x000F), ver: 0x000F)
  }

  /// Two-slide deck: a title placeholder placed by the layout, a red rectangle, and a text box.
  static func pptxFixture(_ url: URL) throws {
    let ns = "xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\""
    let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
    let grp = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"
    var z = ZipWriter()
    z.add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")
    z.add("ppt/presentation.xml", "<p:presentation \(ns)><p:sldIdLst><p:sldId id=\"256\" r:id=\"s1\"/><p:sldId id=\"257\" r:id=\"s2\"/></p:sldIdLst><p:sldSz cx=\"9144000\" cy=\"5143500\"/></p:presentation>")
    z.add("ppt/_rels/presentation.xml.rels", OfficeTools.rels([("s1", rel + "slide", "slides/slide1.xml"), ("s2", rel + "slide", "slides/slide2.xml")]))
    z.add("ppt/theme/theme1.xml", PPTXWriter.theme)
    z.add("ppt/slideMasters/slideMaster1.xml", """
      <p:sldMaster \(ns)><p:cSld><p:spTree>\(grp)</p:spTree></p:cSld><p:txStyles><p:titleStyle><a:lvl1pPr algn="ctr"><a:defRPr sz="4000" b="1">\
      <a:solidFill><a:schemeClr val="accent1"/></a:solidFill></a:defRPr></a:lvl1pPr></p:titleStyle></p:txStyles></p:sldMaster>
      """)
    z.add("ppt/slideMasters/_rels/slideMaster1.xml.rels", OfficeTools.rels([("t", rel + "theme", "../theme/theme1.xml")]))
    z.add("ppt/slideLayouts/slideLayout1.xml", """
      <p:sldLayout \(ns)><p:cSld><p:spTree>\(grp)<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr>\
      <p:spPr><a:xfrm><a:off x="457200" y="228600"/><a:ext cx="8229600" cy="1143000"/></a:xfrm></p:spPr>\
      <p:txBody><a:bodyPr anchor="ctr"/><a:p><a:r><a:t>Click to edit</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sldLayout>
      """)
    z.add("ppt/slideLayouts/_rels/slideLayout1.xml.rels", OfficeTools.rels([("m", rel + "slideMaster", "../slideMasters/slideMaster1.xml")]))
    for n in 1...2 { z.add("ppt/slides/_rels/slide\(n).xml.rels", OfficeTools.rels([("l", rel + "slideLayout", "../slideLayouts/slideLayout1.xml")])) }
    z.add("ppt/slides/slide1.xml", """
      <p:sld \(ns)><p:cSld><p:spTree>\(grp)<p:sp><p:nvSpPr><p:cNvPr id="2" name="Title"/><p:cNvSpPr/><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/>\
      <p:txBody><a:bodyPr/><a:p><a:r><a:rPr lang="en-US"/><a:t>Hello Deck</a:t></a:r></a:p></p:txBody></p:sp>\
      <p:sp><p:nvSpPr><p:cNvPr id="3" name="Box"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="2540000"/><a:ext cx="2540000" cy="1270000"/></a:xfrm>\
      <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:solidFill><a:srgbClr val="FF0000"/></a:solidFill></p:spPr></p:sp></p:spTree></p:cSld></p:sld>
      """)
    z.add("ppt/slides/slide2.xml", """
      <p:sld \(ns)><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val="0000FF"/></a:solidFill></p:bgPr></p:bg><p:spTree>\(grp)\
      <p:sp><p:nvSpPr><p:cNvPr id="2" name="Text"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="914400" y="914400"/><a:ext cx="5000000" cy="914400"/></a:xfrm></p:spPr>\
      <p:txBody><a:bodyPr/><a:p><a:pPr><a:buChar char="•"/></a:pPr><a:r><a:rPr sz="2400" b="1"/><a:t>Second slide</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>
      """)
    try z.write(to: url)
  }

  static func officePack(dir: URL) async {
    func run(_ id: String, _ urls: [URL]) async throws -> [URL] { try await Tools.all.first { $0.id == id }!.run(urls) }
    func write(_ name: String, _ s: String) -> URL {
      let u = dir.appendingPathComponent(name); try! s.write(to: u, atomically: true, encoding: .utf8); return u
    }
    func str(_ d: Data?) -> String { d.map { String(decoding: $0, as: UTF8.self) } ?? "" }

    await attempt("zip: deflate + store round-trip") {
      var z = ZipWriter()
      let big = String(repeating: "lemon ", count: 500)
      z.add("a/b.txt", big); z.add("s", "stored", store: true)
      let u = dir.appendingPathComponent("t.zip"); try z.write(to: u)
      let r = try ZipReader(u)
      let size = try Data(contentsOf: u).count
      return str(r.read("a/b.txt")) == big && str(r.read("s")) == "stored" && size < big.count
    }

    // PDF: a title, a paragraph, a two-column table; second page is a "scan" (a picture, no text).
    let pdf = dir.appendingPathComponent("report.pdf")
    do {
      var box = CGRect(x: 0, y: 0, width: 612, height: 792)
      let ctx = CGContext(pdf as CFURL, mediaBox: &box, nil)!
      ctx.beginPage(mediaBox: &box)
      func line(_ s: String, _ size: CGFloat, _ x: CGFloat, _ y: CGFloat) {
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: NSFont(name: "Helvetica", size: size)!])), ctx)
      }
      line("Quarterly Report", 28, 40, 700)
      line("Sales grew steadily this quarter.", 12, 40, 650)
      line("Name", 12, 40, 600); line("Qty", 12, 300, 600)
      line("Apple", 12, 40, 585); line("12", 12, 300, 585)
      ctx.endPage()
      ctx.beginPage(mediaBox: &box)
      ctx.setFillColor(CGColor(gray: 0.3, alpha: 1)); ctx.fill(CGRect(x: 100, y: 100, width: 400, height: 500))
      ctx.endPage()
      ctx.closePDF()
    }
    await attempt("pdf.png renders at 300 dpi") {
      let p = try await run("pdf.png", [pdf])
      let rep = NSBitmapImageRep(data: try Data(contentsOf: p[0]))
      return p.count == 2 && rep?.pixelsWide == 2550
    }
    await attempt("pdf.md: heading and paragraph") {
      let md = try String(contentsOf: try await run("pdf.md", [pdf])[0], encoding: .utf8)
      return md.contains("# Quarterly Report") && md.contains("Sales grew steadily this quarter.")
    }
    await attempt("pdf.xlsx: columns split, one sheet per page") {
      let x = try await run("pdf.xlsx", [pdf])[0]
      let s = try Sheets.read(x)
      return s.count == 2 && s[0].rows.contains(["Name", "Qty"]) && s[0].rows.contains(["Apple", "12"]) && s[0].rows.first == ["Quarterly Report"]
    }
    await attempt("pdf.epub: mimetype first and stored, OPF + nav, text reads back") {
      let e = try await run("pdf.epub", [pdf])[0]
      let b = [UInt8](try Data(contentsOf: e))
      let first = String(decoding: b[30..<38], as: UTF8.self), method = Int(b[8]) | Int(b[9]) << 8
      let z = try ZipReader(e)
      let opf = z.xml("OEBPS/content.opf")
      let nav = opf?.first("manifest")?.kids("item").contains { $0.attr("properties") == "nav" } == true
      let back = OfficeTools.markdown(try OfficeTools.epubBlocks(e))
      return first == "mimetype" && method == 0 && String(decoding: b[38..<58], as: UTF8.self) == "application/epub+zip"
        && opf?.attr("version") == "3.0" && nav && opf?.first("spine")?.kids("itemref").count == 2 && back.contains("Quarterly Report")
    }
    await attempt("pdf.docx: paragraphs, page break, scanned page embedded as image") {
      let d = try await run("pdf.docx", [pdf])[0]
      let z = try ZipReader(d)
      let xml = str(z.read("word/document.xml"))
      return try z.read("word/media/image1.jpg") != nil && xml.contains("w:type=\"page\"") && xml.contains("Heading1")
        && DocTools.read(d).string.contains("Sales grew steadily")
    }
    var pptx = pdf
    await attempt("pdf.pptx: one slide per page, valid package, renders back to 2 pages") {
      pptx = try await run("pdf.pptx", [pdf])[0]
      let z = try ZipReader(pptx)
      let slides = z.names.filter { $0.hasPrefix("ppt/slides/slide") }.count
      let back = PDFDocument(url: try await run("slides.pdf", [pptx])[0])
      return slides == 2 && z.xml("ppt/presentation.xml")?.first("sldSz")?.attr("cx") == "7772400" && back?.pageCount == 2
    }

    // Slides
    let deck = dir.appendingPathComponent("deck.pptx")
    try? pptxFixture(deck)
    await attempt("slides.pdf: page per slide, inherited title placeholder and text box drawn") {
      let d = PDFDocument(url: try await run("slides.pdf", [deck])[0])
      let t0 = d?.page(at: 0)?.string ?? "", t1 = d?.page(at: 1)?.string ?? ""
      return d?.pageCount == 2 && t0.contains("Hello Deck") && !t0.contains("Click to edit") && t1.contains("Second slide")
        && d?.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 720, height: 405)
    }
    await attempt("slides.png: fills and backgrounds at 2x") {
      let p = try await run("slides.png", [deck])
      guard p.count == 2, let a = NSBitmapImageRep(data: try Data(contentsOf: p[0])), let b = NSBitmapImageRep(data: try Data(contentsOf: p[1])) else { return false }
      // red box at (0, 200)–(200, 300) pt; title text colour accent1 somewhere; slide 2 is blue
      return a.pixelsWide == 1440 && pixel(a, 100, 500, is: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        && pixel(a, 1000, 700, is: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) && pixel(b, 10, 10, is: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    }
    let ppt = dir.appendingPathComponent("old.ppt")
    try? compoundFile("PowerPoint Document", pptFixture()).write(to: ppt)
    await attempt("PPT (97–2003): text slides to PDF") {
      let d = PDFDocument(url: try await run("slides.pdf", [ppt])[0])
      return d?.pageCount == 1 && d?.string?.contains("Legacy Title") == true && d?.string?.contains("Point two") == true
    }
    await expectError("PPT that isn't a compound file fails clearly") { _ = try await run("slides.pdf", [write("fake.ppt", "nope")]) }

    // Documents
    let html = write("article.html", """
      <html><body><h1>Big Title</h1><p>Some <b>bold</b> and <i>italic</i> with a <a href="https://example.com">link</a>.</p>\
      <ul><li>First item</li><li>Second item</li></ul></body></html>
      """)
    await attempt("doc.md from HTML: heading, emphasis, list, link") {
      let md = try String(contentsOf: try await run("doc.md", [html])[0], encoding: .utf8)
      return md.contains("# Big Title") && md.contains("**bold**") && md.contains("*italic*") && md.contains("[link](https://example.com")
        && md.contains("- First item\n- Second item")
    }
    var epub = html
    await attempt("doc.epub then EPUB → TXT/PDF") {
      epub = try await run("doc.epub", [html])[0]
      let txt = try String(contentsOf: try await run("doc.txt", [epub])[0], encoding: .utf8)
      let pdfOut = PDFDocument(url: try await run("doc.pdf", [epub])[0])
      return txt.contains("Big Title") && txt.contains("Second item") && pdfOut?.string?.contains("bold") == true
    }
    await attempt("EPUB → DOCX opens in NSAttributedString") { try DocTools.read(try await run("doc.docx", [epub])[0]).string.contains("First item") }
    await attempt("EPUB → MD keeps headings") { try String(contentsOf: try await run("doc.md", [epub])[0], encoding: .utf8).contains("# Big Title") }
    await attempt("textClipping read") {
      let clip = dir.appendingPathComponent("snippet.textClipping")
      let plist: [String: Any] = ["UTI-Data": ["public.utf8-plain-text": "Clipped words"]]
      try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: clip)
      let out = try await run("doc.txt", [clip])[0]
      return try FileKind(clip) == .document && String(contentsOf: out, encoding: .utf8).contains("Clipped words")
    }
    await attempt("RTFD package read") {
      let s = NSAttributedString(string: "Rich package", attributes: [.font: NSFont.systemFont(ofSize: 12)])
      let rtfd = dir.appendingPathComponent("pack.rtfd")
      try s.rtfdFileWrapper(from: NSRange(location: 0, length: s.length))!.write(to: rtfd, originalContentsURL: nil)
      let out = try await run("doc.txt", [rtfd])[0]
      return try FileKind(rtfd) == .document && String(contentsOf: out, encoding: .utf8).contains("Rich package")
    }

    // Spreadsheets
    let csv = write("stock.csv", "item,count,zip\npear,3,007\n\"fig, dried\",2.5,x\n")
    var xlsx = csv
    await attempt("sheet.xlsx: numbers stored as numbers, text inline, round-trips to CSV") {
      xlsx = try await run("sheet.xlsx", [csv])[0]
      let x = str(try ZipReader(xlsx).read("xl/worksheets/sheet1.xml"))
      let back = try String(contentsOf: try await run("sheet.csv", [xlsx])[0], encoding: .utf8)
      return x.contains("<c r=\"B2\"><v>3</v></c>") && x.contains("<c r=\"C2\" t=\"inlineStr\">") && back == "item,count,zip\npear,3,007\n\"fig, dried\",2.5,x\n"
    }
    await attempt("sheet.ods from XLSX round-trips") {
      let ods = try await run("sheet.ods", [xlsx])[0]
      let b = [UInt8](try Data(contentsOf: ods))
      return try String(decoding: b[30..<38], as: UTF8.self) == "mimetype" && ( Sheets.read(ods))[0].rows == (try Sheets.read(csv))[0].rows
    }
    await attempt("XLSX reader: shared strings, dates, sparse cells, sheets") {
      let u = dir.appendingPathComponent("shared.xlsx")
      var z = ZipWriter()
      let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
      z.add("_rels/.rels", OfficeTools.rels([("r1", rel + "/officeDocument", "xl/workbook.xml")]))
      z.add("xl/workbook.xml", "<workbook xmlns:r=\"\(rel)\"><sheets><sheet name=\"A\" r:id=\"a\"/><sheet name=\"B\" r:id=\"b\"/></sheets></workbook>")
      z.add("xl/_rels/workbook.xml.rels", OfficeTools.rels([("a", rel + "/worksheet", "worksheets/s1.xml"), ("b", rel + "/worksheet", "worksheets/s2.xml")]))
      z.add("xl/sharedStrings.xml", "<sst><si><t>hi</t></si><si><r><t>ri</t></r><r><t>ch</t></r></si></sst>")
      z.add("xl/styles.xml", "<styleSheet><cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/></cellXfs></styleSheet>")
      z.add("xl/worksheets/s1.xml", "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"C1\" t=\"s\"><v>1</v></c></row><row r=\"3\"><c r=\"B3\" s=\"1\"><v>45292</v></c><c r=\"C3\"><v>0.1</v></c></row></sheetData></worksheet>")
      z.add("xl/worksheets/s2.xml", "<worksheet><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>two</t></is></c></row></sheetData></worksheet>")
      try z.write(to: u)
      let s = try Sheets.read(u)
      return s.count == 2 && s[0].rows == [["hi", "", "rich"], [], ["", "2024-01-01", "0.1"]] && s[1].name == "B" && s[1].rows == [["two"]]
    }
    await attempt("XLS (BIFF8): shared strings, numbers, RK") {
      let xls = dir.appendingPathComponent("legacy.xls")
      try compoundFile("Workbook", xlsFixture()).write(to: xls)
      let s = try Sheets.read(xls)
      let csvOut = try String(contentsOf: try await run("sheet.csv", [xls])[0], encoding: .utf8)
      return s.first?.name == "Prices" && s.first?.rows == [["Fruit", "3.5"], ["Pear", "42"]] && csvOut == "Fruit,3.5\nPear,42\n"
    }
    await attempt("sheet.pdf: grid table paginated") {
      let rows = (1...120).map { "row \($0),\($0 * 2)" }.joined(separator: "\n")
      let d = PDFDocument(url: try await run("sheet.pdf", [write("long.csv", "name,value\n" + rows)])[0])
      return (d?.pageCount ?? 0) >= 2 && d?.page(at: 0)?.string?.contains("row 1") == true && d?.string?.contains("row 120") == true
    }

    // Subtitles and images
    await attempt("sub.txt: dialogue only") {
      let srt = write("talk.srt", "1\n00:00:01,000 --> 00:00:02,000\n<i>Hello</i> there\n\n2\n00:00:03,000 --> 00:00:04,000\nGeneral Kenobi\n")
      return try String(contentsOf: try await run("sub.txt", [srt])[0], encoding: .utf8) == "Hello there\nGeneral Kenobi\n"
    }
    let svg = write("logo.svg", "<svg xmlns='http://www.w3.org/2000/svg' width='120' height='80'><rect width='120' height='80' fill='#00ff00'/></svg>")
    await attempt("SVG input rasterizes at its size for every image conversion") {
      var ok = FileKind(svg) == .image
      for id in ["img.png", "img.jpg", "img.webp", "img.heic"] {
        let out = try await run(id, [svg])[0]
        let p = CGImageSourceCreateWithURL(out as CFURL, nil).flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
        ok = ok && p?[kCGImagePropertyPixelWidth] as? Int == 120 && p?[kCGImagePropertyPixelHeight] as? Int == 80
      }
      let rep = NSBitmapImageRep(data: try Data(contentsOf: try await run("img.png", [svg])[0]))!
      return ok && pixel(rep, 60, 40, is: CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
    }

    // Routing
    func ids(_ u: URL) -> [String] { Tools.available(for: [u], mode: .convert).map(\.id) }
    check(FileKind(deck) == .slides && FileKind(ppt) == .slides && FileKind(epub) == .document, "PPTX/PPT are slides, EPUB is a document")
    check(ids(deck) == ["slides.pdf", "slides.jpg", "slides.png"], "slides convert to PDF/JPG/PNG")
    check(ids(pdf) == ["pdf.png", "pdf.jpg", "pdf.docx", "pdf.rtf", "pdf.txt", "pdf.pptx", "pdf.xlsx", "pdf.epub", "pdf.md"], "PDF convert petals in order")
    check(ids(xlsx) == ["sheet.csv", "sheet.tsv", "sheet.ods", "sheet.pdf"] && ids(epub).contains("doc.md") && !ids(epub).contains("doc.epub"),
          "sheet and document petals hide their own format")
    check([pdf, deck, xlsx, epub, html, svg].allSatisfy { u in FanMode.allCases.allSatisfy { Tools.available(for: [u], mode: $0).count <= Tools.maxInFan } },
          "office kinds stay within \(Tools.maxInFan) petals")
  }
}
