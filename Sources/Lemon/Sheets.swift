import AppKit
import PDFKit

struct Sheet {
  var name: String
  var rows: [[String]]
}

/// Spreadsheet reading (CSV, TSV, XLSX, ODS, XLS) and writing (XLSX, ODS, PDF). Cells are text; numbers are written back as numbers.
enum Sheets {
  static func read(_ u: URL) throws -> [Sheet] {
    let ext = canonicalExt(u.pathExtension), name = u.deletingPathExtension().lastPathComponent
    switch ext {
    case "csv", "tsv":
      let text = try (try? String(contentsOf: u, encoding: .utf8)) ?? String(contentsOf: u, encoding: .isoLatin1)
      return [Sheet(name: name, rows: TextTools.parse(text, separator: ext == "tsv" ? "\t" : ","))]
    case "xlsx": return try xlsx(u)
    case "ods": return try ods(u)
    case "xls": return try xls(u)
    default: throw ToolError("Can't read \(u.lastPathComponent) as a spreadsheet")
    }
  }

  static func convert(_ src: URL, ext: String) throws -> URL {
    let sheets = try read(src)
    let out = outputURL(for: src, ext: ext)
    try (ext == "ods" ? odsData(sheets) : xlsxData(sheets)).write(to: out)
    return out
  }

  /// Excel shows 15 significant digits; integers without a decimal point.
  static func number(_ d: Double) -> String { String(format: "%.15g", d) }

  static func isNumber(_ s: String) -> Bool {
    s.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?([eE][-+]?[0-9]+)?$", options: .regularExpression) != nil && Double(s) != nil
  }

  static func column(_ i: Int) -> String {
    var n = i + 1, s = ""
    while n > 0 { s = String(UnicodeScalar(UInt8(65 + (n - 1) % 26))) + s; n = (n - 1) / 26 }
    return s
  }

  static func set(_ grid: inout [[String]], _ r: Int, _ c: Int, _ v: String) {
    guard r >= 0, c >= 0, !v.isEmpty, r < 1_048_576, c < 16_384 else { return }
    while grid.count <= r { grid.append([]) }
    while grid[r].count <= c { grid[r].append("") }
    grid[r][c] = v
  }

  static func trimmed(_ rows: [[String]]) -> [[String]] {
    var rows = rows.map { r in Array(r.prefix(through: r.lastIndex { !$0.isEmpty } ?? -1)) }
    while rows.last?.isEmpty == true { rows.removeLast() }
    return rows
  }

  static func uniqueNames(_ sheets: [Sheet]) -> [String] {
    var seen = Set<String>()
    return sheets.enumerated().map { i, s in
      var n = String(s.name.map { "[]:*?/\\".contains($0) ? "_" : $0 }.prefix(31)).trimmingCharacters(in: .whitespaces)
      if n.isEmpty { n = "Sheet\(i + 1)" }
      var u = n, k = 2
      while seen.contains(u.lowercased()) { u = String(n.prefix(27)) + " (\(k))"; k += 1 }
      seen.insert(u.lowercased())
      return u
    }
  }

  // MARK: XLSX

  static func xlsx(_ u: URL) throws -> [Sheet] {
    let z = try ZipReader(u)
    let wbPath = z.xml("_rels/.rels")?.kids("Relationship").first { $0.attr("Type")?.hasSuffix("/officeDocument") == true }?.attr("Target")
      .map { resolvePart("", $0) } ?? "xl/workbook.xml"
    guard let wb = z.xml(wbPath) else { throw ToolError("\(u.lastPathComponent) isn't a valid XLSX file") }
    let dir = (wbPath as NSString).deletingLastPathComponent
    func text(_ e: XMLElement) -> String {
      e.elements.map { $0.localName == "t" ? $0.stringValue ?? "" : $0.localName == "r" ? $0.kid("t")?.stringValue ?? "" : "" }.joined()
    }
    let shared = (z.xml(dir + "/sharedStrings.xml")?.kids("si") ?? []).map(text)
    // styles whose number format is a date, so serials come out as dates
    var custom: [Int: String] = [:]
    let styles = z.xml(dir + "/styles.xml")
    for f in styles?.first("numFmts")?.kids("numFmt") ?? [] { if let id = f.attr("numFmtId").flatMap(Int.init) { custom[id] = f.attr("formatCode") ?? "" } }
    let dateStyles = Set((styles?.first("cellXfs")?.kids("xf") ?? []).enumerated().compactMap { i, xf -> Int? in
      let id = xf.attr("numFmtId").flatMap(Int.init) ?? 0
      if (14...22).contains(id) || (45...47).contains(id) { return i }
      guard let code = custom[id]?.lowercased().replacingOccurrences(of: "\"[^\"]*\"|\\[[^\\]]*\\]", with: "", options: .regularExpression) else { return nil }
      return code.contains("yy") || code.contains("d") || code.contains("h:") ? i : nil
    })
    let rels = z.rels(wbPath)
    let sheets: [Sheet] = (wb.first("sheets")?.kids("sheet") ?? []).compactMap { s in
      guard let rid = s.attr("r:id"), let path = rels[rid], let x = z.xml(path) else { return nil }
      var grid: [[String]] = []
      var r = -1
      for row in x.first("sheetData")?.kids("row") ?? [] {
        r = row.attr("r").flatMap(Int.init).map { $0 - 1 } ?? r + 1
        var c = -1
        for cell in row.kids("c") {
          c = cell.attr("r").map(colIndex) ?? c + 1
          let v = cell.kid("v")?.stringValue ?? ""
          let value: String
          switch cell.attr("t") {
          case "s": value = Int(v).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? ""
          case "inlineStr": value = cell.kid("is").map(text) ?? ""
          case "b": value = v == "1" ? "TRUE" : "FALSE"
          case "str", "e": value = v
          default:
            guard let d = Double(v) else { value = v; break }
            value = cell.attr("s").flatMap(Int.init).map(dateStyles.contains) == true ? date(d) : number(d)
          }
          set(&grid, r, c, value)
        }
      }
      return Sheet(name: s.attr("name") ?? "Sheet", rows: grid)
    }
    guard !sheets.isEmpty else { throw ToolError("\(u.lastPathComponent) has no sheets") }
    return sheets
  }

  /// "BC12" → 54 (letters only).
  static func colIndex(_ ref: String) -> Int {
    ref.uppercased().prefix { $0.isLetter }.reduce(0) { $0 * 26 + Int($1.asciiValue! - 64) } - 1
  }

  static func date(_ serial: Double) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = serial < 1 ? "HH:mm:ss" : serial.truncatingRemainder(dividingBy: 1) == 0 ? "yyyy-MM-dd" : "yyyy-MM-dd HH:mm:ss"
    return f.string(from: Date(timeIntervalSince1970: ((serial - 25569) * 86400).rounded()))
  }

  static func xlsxData(_ sheets: [Sheet]) -> Data {
    let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main", rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    let names = uniqueNames(sheets)
    var z = ZipWriter(), types = "", wbSheets = ""
    var wbRels: [(id: String, type: String, target: String)] = [("rStyles", rel + "/styles", "styles.xml")]
    for (i, s) in sheets.enumerated() {
      var x = head + "<worksheet xmlns=\"\(main)\"><sheetData>"
      for (r, row) in s.rows.enumerated() where row.contains(where: { !$0.isEmpty }) {
        x += "<row r=\"\(r + 1)\">"
        for (c, v) in row.enumerated() where !v.isEmpty {
          let ref = "\(column(c))\(r + 1)"
          x += isNumber(v) ? "<c r=\"\(ref)\"><v>\(v)</v></c>" : "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(v))</t></is></c>"
        }
        x += "</row>"
      }
      z.add("xl/worksheets/sheet\(i + 1).xml", x + "</sheetData></worksheet>")
      types += "<Override PartName=\"/xl/worksheets/sheet\(i + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
      wbSheets += "<sheet name=\"\(xmlEscape(names[i]))\" sheetId=\"\(i + 1)\" r:id=\"rS\(i + 1)\"/>"
      wbRels.append(("rS\(i + 1)", rel + "/worksheet", "worksheets/sheet\(i + 1).xml"))
    }
    z.add("[Content_Types].xml", head + """
      <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>\
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
      <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(types)</Types>
      """)
    z.add("_rels/.rels", OfficeTools.rels([("rId1", rel + "/officeDocument", "xl/workbook.xml")]))
    z.add("xl/_rels/workbook.xml.rels", OfficeTools.rels(wbRels))
    z.add("xl/workbook.xml", head + "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rel)\"><sheets>\(wbSheets)</sheets></workbook>")
    z.add("xl/styles.xml", head + """
      <styleSheet xmlns="\(main)"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>\
      <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
      <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
      <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
      <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>\
      <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
      """)
    return z.finished()
  }

  // MARK: ODS

  static func ods(_ u: URL) throws -> [Sheet] {
    guard let content = try ZipReader(u).xml("content.xml") else { throw ToolError("\(u.lastPathComponent) isn't a valid ODS file") }
    let tables = content.all("table").filter { $0.name == "table:table" }
    guard !tables.isEmpty else { throw ToolError("\(u.lastPathComponent) has no sheets") }
    return tables.map { t in
      var grid: [[String]] = [], r = 0
      for row in t.all("table-row") {
        let rep = row.attr("table:number-rows-repeated").flatMap(Int.init) ?? 1
        var cells: [String] = []
        for cell in row.elements where ["table-cell", "covered-table-cell"].contains(cell.localName) {
          let n = cell.attr("table:number-columns-repeated").flatMap(Int.init) ?? 1
          let v: String
          switch cell.attr("office:value-type") {
          case "float", "percentage", "currency": v = cell.attr("office:value").flatMap(Double.init).map(number) ?? ""
          case "date": v = cell.attr("office:date-value") ?? ""
          case "time": v = cell.attr("office:time-value") ?? ""
          case "boolean": v = cell.attr("office:boolean-value") == "true" ? "TRUE" : "FALSE"
          default: v = cell.kids("p").map { $0.stringValue ?? "" }.joined(separator: "\n")
          }
          // trailing blank cells are often repeated to the sheet's full width
          cells += Array(repeating: v, count: v.isEmpty ? min(n, 256) : min(n, 16_384))
        }
        for _ in 0..<(cells.contains { !$0.isEmpty } ? min(rep, 10_000) : min(rep, 100)) {
          for (c, v) in cells.enumerated() { set(&grid, r, c, v) }
          r += 1
        }
      }
      return Sheet(name: t.attr("table:name") ?? "Sheet", rows: trimmed(grid))
    }
  }

  static func odsData(_ sheets: [Sheet]) -> Data {
    let names = uniqueNames(sheets)
    var body = ""
    for (i, s) in sheets.enumerated() {
      body += "<table:table table:name=\"\(xmlEscape(names[i]))\"><table:table-column table:number-columns-repeated=\"\(max(1, s.rows.map(\.count).max() ?? 1))\"/>"
      for row in s.rows {
        body += "<table:table-row>"
        for v in row {
          if v.isEmpty { body += "<table:table-cell/>" }
          else if isNumber(v) { body += "<table:table-cell office:value-type=\"float\" office:value=\"\(v)\"><text:p>\(v)</text:p></table:table-cell>" }
          else { body += "<table:table-cell office:value-type=\"string\">" + v.components(separatedBy: "\n").map { "<text:p>\(xmlEscape($0))</text:p>" }.joined() + "</table:table-cell>" }
        }
        body += "</table:table-row>"
      }
      if s.rows.isEmpty { body += "<table:table-row><table:table-cell/></table:table-row>" }
      body += "</table:table>"
    }
    let mime = "application/vnd.oasis.opendocument.spreadsheet"
    var z = ZipWriter()
    z.add("mimetype", mime, store: true)
    z.add("META-INF/manifest.xml", """
      <?xml version="1.0" encoding="UTF-8"?>
      <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">\
      <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="\(mime)"/>\
      <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/></manifest:manifest>
      """)
    z.add("content.xml", """
      <?xml version="1.0" encoding="UTF-8"?>
      <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
      xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" \
      office:version="1.2"><office:body><office:spreadsheet>\(body)</office:spreadsheet></office:body></office:document-content>
      """)
    return z.finished()
  }

  // MARK: XLS (BIFF8)

  // ponytail: text, numbers and formula results only; dates come out as serial numbers (needs XF → format lookup).
  static func xls(_ u: URL) throws -> [Sheet] {
    let cf = try CompoundFile(u)
    guard let b = cf.stream("Workbook") else {
      throw ToolError(cf.stream("Book") != nil ? "\(u.lastPathComponent) is an Excel 5/95 file; save it as XLSX first" : "\(u.lastPathComponent) has no workbook")
    }
    func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
    func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
    func f64(_ i: Int) -> Double { i + 8 <= b.count ? Double(bitPattern: (0..<8).reduce(UInt64(0)) { $0 | UInt64(b[i + $1]) << (8 * UInt64($1)) }) : 0 }
    func rk(_ v: Int) -> Double {
      let raw = UInt32(truncatingIfNeeded: v)
      let d = raw & 2 != 0 ? Double(Int32(bitPattern: raw) >> 2) : Double(bitPattern: UInt64(raw & 0xFFFF_FFFC) << 32)
      return raw & 1 != 0 ? d / 100 : d
    }
    /// XLUnicodeString body: flags byte then `n` characters, compressed (Latin-1) or UTF-16.
    func chars(_ i: Int, _ n: Int, _ end: Int) -> String {
      let wide = b[min(i, b.count - 1)] & 1 != 0, len = wide ? n * 2 : n, s = i + 1
      guard s + len <= min(end, b.count) else { return "" }
      return wide ? String(decoding: stride(from: s, to: s + len, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }, as: UTF16.self)
                  : String(decoding: b[s..<(s + len)].map { UInt16($0) }, as: UTF16.self)
    }
    var names: [Int: String] = [:], sst: [String] = [], sheets: [Sheet] = []
    var grid: [[String]]? = nil, sheetName = "", pendingFormula: (Int, Int)? = nil
    var p = 0
    while p + 4 <= b.count {
      let type = u16(p), len = u16(p + 2), d = p + 4, end = d + len
      defer { p = end }
      guard end <= b.count else { break }
      switch type {
      case 0x0809:  // BOF
        if u16(d + 2) == 0x10 { grid = []; sheetName = names[p] ?? "Sheet\(sheets.count + 1)" }
      case 0x000A:  // EOF
        if let g = grid { sheets.append(Sheet(name: sheetName, rows: trimmed(g))); grid = nil }
      case 0x0085:  // BOUNDSHEET
        if b[d + 5] == 0 { names[u32(d)] = chars(d + 7, Int(b[d + 6]), end) }
      case 0x00FC:  // SST, continued in CONTINUE records
        var segs = [(d, end)], q = end
        while q + 4 <= b.count, u16(q) == 0x003C { segs.append((q + 4, q + 4 + u16(q + 2))); q += 4 + u16(q + 2) }
        sst = readSST(b, segs, count: u32(d + 4))
      case 0x00FD where grid != nil:  // LABELSST
        let i = u32(d + 6); set(&grid!, u16(d), u16(d + 2), sst.indices.contains(i) ? sst[i] : "")
      case 0x0203 where grid != nil: set(&grid!, u16(d), u16(d + 2), number(f64(d + 6)))  // NUMBER
      case 0x027E where grid != nil: set(&grid!, u16(d), u16(d + 2), number(rk(u32(d + 6))))  // RK
      case 0x00BD where grid != nil:  // MULRK
        let r = u16(d), first = u16(d + 2)
        for k in 0..<max(0, (len - 6) / 6) { set(&grid!, r, first + k, number(rk(u32(d + 4 + k * 6 + 2)))) }
      case 0x0204 where grid != nil: set(&grid!, u16(d), u16(d + 2), chars(d + 8, u16(d + 6), end))  // LABEL
      case 0x0205 where grid != nil:  // BOOLERR
        if b[d + 7] == 0 { set(&grid!, u16(d), u16(d + 2), b[d + 6] != 0 ? "TRUE" : "FALSE") }
      case 0x0006 where grid != nil:  // FORMULA: cached result
        let r = u16(d), c = u16(d + 2)
        if u16(d + 12) != 0xFFFF { set(&grid!, r, c, number(f64(d + 6))) }
        else if b[d + 6] == 0 { pendingFormula = (r, c) }
        else if b[d + 6] == 1 { set(&grid!, r, c, b[d + 8] != 0 ? "TRUE" : "FALSE") }
      case 0x0207 where grid != nil:  // STRING after a text formula
        if let (r, c) = pendingFormula { set(&grid!, r, c, chars(d + 2, u16(d), end)); pendingFormula = nil }
      default: break
      }
    }
    guard !sheets.isEmpty else { throw ToolError("No sheets found in \(u.lastPathComponent)") }
    return sheets
  }

  /// Shared strings; a string's characters may continue in the next segment, which then starts with a fresh flags byte.
  static func readSST(_ b: [UInt8], _ segs: [(Int, Int)], count: Int) -> [String] {
    var seg = 0, p = segs[0].0 + 8, out: [String] = []
    func avail() -> Int { segs[seg].1 - p }
    func next() -> Bool { seg += 1; guard seg < segs.count else { return false }; p = segs[seg].0; return true }
    func byte() -> Int? { while avail() <= 0 { if !next() { return nil } }; p += 1; return Int(b[p - 1]) }
    func u16() -> Int? { guard let lo = byte(), let hi = byte() else { return nil }; return lo | hi << 8 }
    func skip(_ n: Int) { var n = n; while n > 0 { if avail() <= 0 { if !next() { return } }; let k = min(n, avail()); p += k; n -= k } }
    for _ in 0..<min(count, 10_000_000) {
      guard let n = u16(), let flags = byte() else { break }
      let runs = flags & 8 != 0 ? (u16() ?? 0) : 0
      var ext = 0
      if flags & 4 != 0 { for k in 0..<4 { ext |= (byte() ?? 0) << (8 * k) } }
      var wide = flags & 1 != 0, units: [UInt16] = []
      while units.count < n {
        if avail() <= 0 { guard next(), let f = byte() else { break }; wide = f & 1 != 0 }
        if wide { guard avail() >= 2 else { break }; units.append(UInt16(b[p]) | UInt16(b[p + 1]) << 8); p += 2 }
        else { units.append(UInt16(b[p])); p += 1 }
      }
      out.append(String(decoding: units, as: UTF16.self))
      skip(runs * 4 + ext)
    }
    return out
  }

  // MARK: PDF

  /// Grid table on Letter pages (landscape for wide sheets), scaled to fit the width, paginated by rows.
  static func pdf(_ src: URL) throws -> URL {
    let sheets = try read(src).map { Sheet(name: $0.name, rows: trimmed($0.rows)) }.filter { !$0.rows.isEmpty }
    guard !sheets.isEmpty else { throw ToolError("\(src.lastPathComponent) is empty") }
    let out = outputURL(for: src, ext: "pdf")
    guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { throw ToolError("Couldn't create \(out.lastPathComponent)") }
    let font = NSFont.systemFont(ofSize: 9), bold = NSFont.boldSystemFont(ofSize: 11)
    let ps = NSMutableParagraphStyle(); ps.lineBreakMode = .byTruncatingTail
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: ps, .foregroundColor: NSColor.black]
    let margin: CGFloat = 36, rowH: CGFloat = 15, pad: CGFloat = 4
    let gc = NSGraphicsContext(cgContext: ctx, flipped: true)
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = gc
    defer { NSGraphicsContext.current = saved }
    for sheet in sheets {
      let cols = sheet.rows.map(\.count).max() ?? 0
      var widths = Array(repeating: CGFloat(24), count: cols)
      for row in sheet.rows.prefix(1000) {  // ponytail: widths from the first 1000 rows
        for (c, v) in row.enumerated() where !v.isEmpty { widths[c] = min(220, max(widths[c], (v as NSString).size(withAttributes: attrs).width + 2 * pad)) }
      }
      let total = widths.reduce(0, +)
      let page = total > 612 - 2 * margin ? CGSize(width: 792, height: 612) : CGSize(width: 612, height: 792)
      let k = min(1, (page.width - 2 * margin) / max(total, 1))
      let title = sheets.count > 1 ? 20 : CGFloat(0)
      let perPage = max(1, Int((page.height - 2 * margin - title) / (rowH * k)))
      for start in stride(from: 0, to: sheet.rows.count, by: perPage) {
        var box = CGRect(origin: .zero, size: page)
        ctx.beginPage(mediaBox: &box)
        ctx.saveGState()
        ctx.translateBy(x: 0, y: page.height); ctx.scaleBy(x: 1, y: -1)
        if title > 0 { (sheet.name as NSString).draw(at: CGPoint(x: margin, y: margin - 2), withAttributes: [.font: bold, .foregroundColor: NSColor.black]) }
        ctx.translateBy(x: margin, y: margin + title); ctx.scaleBy(x: k, y: k)
        let rows = sheet.rows[start..<min(start + perPage, sheet.rows.count)]
        ctx.setStrokeColor(gray: 0.75, alpha: 1); ctx.setLineWidth(0.5)
        for (i, row) in rows.enumerated() {
          let y = CGFloat(i) * rowH
          if start + i == 0 { ctx.setFillColor(gray: 0.93, alpha: 1); ctx.fill(CGRect(x: 0, y: y, width: total, height: rowH)) }
          var x: CGFloat = 0
          for c in 0..<cols {
            if c < row.count, !row[c].isEmpty {
              (row[c].replacingOccurrences(of: "\n", with: " ") as NSString)
                .draw(with: CGRect(x: x + pad, y: y + 2, width: widths[c] - 2 * pad, height: rowH - 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            }
            ctx.stroke(CGRect(x: x, y: y, width: widths[c], height: rowH))
            x += widths[c]
          }
        }
        ctx.restoreGState()
        ctx.endPage()
      }
    }
    ctx.closePDF()
    return out
  }

  // MARK: PDF → XLSX

  /// A sheet per page; each text line is a row, split into cells at tabs and wide gaps between words.
  // ponytail: column detection is per line, so ragged tables don't line up into the same columns.
  static func pdfToXLSX(_ src: URL) throws -> URL {
    let pages = PDFTools.pages(try PDFTools.open(src))
    let sheets = pages.enumerated().map { i, p -> Sheet in
      let s = (p.string ?? "") as NSString
      var rows: [[String]] = []
      s.enumerateSubstrings(in: NSRange(location: 0, length: s.length), options: .byLines) { line, r, _, _ in
        guard let line, !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let height = p.selection(for: r)?.bounds(for: p).height ?? 12
        var cells: [String] = [], cell = "", gap = 0
        for (k, ch) in (line as NSString).enumeratedChars {
          let wide = ch == "\t" || (ch == " " && (gap > 0 || (p.selection(for: NSRange(location: r.location + k, length: 1))?.bounds(for: p).width ?? 0) > height * 0.8))
          if ch == " " { gap += 1 } else { gap = 0 }
          if wide || gap >= 2 { if !cell.trimmingCharacters(in: .whitespaces).isEmpty { cells.append(cell.trimmingCharacters(in: .whitespaces)) }; cell = "" }
          else { cell.append(ch) }
        }
        if !cell.trimmingCharacters(in: .whitespaces).isEmpty { cells.append(cell.trimmingCharacters(in: .whitespaces)) }
        rows.append(cells)
      }
      return Sheet(name: "Page \(i + 1)", rows: rows)
    }
    guard sheets.contains(where: { !$0.rows.isEmpty }) else { throw ToolError("No text in \(src.lastPathComponent) (scanned?)") }
    let out = outputURL(for: src, ext: "xlsx")
    try xlsxData(sheets).write(to: out)
    return out
  }
}

private extension NSString {
  /// UTF-16 offsets with their characters (offsets match PDFKit's string indices).
  var enumeratedChars: [(Int, Character)] {
    var out: [(Int, Character)] = []
    enumerateSubstrings(in: NSRange(location: 0, length: length), options: .byComposedCharacterSequences) { s, r, _, _ in
      if let c = s?.first { out.append((r.location, c)) }
    }
    return out
  }
}
