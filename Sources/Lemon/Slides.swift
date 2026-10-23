import AppKit
import UniformTypeIdentifiers

/// PPTX/PPT → PDF and images, drawn by Lemon from the slide XML.
// ponytail: solid fills, rect/roundRect/ellipse/line geometry, pictures, tables and styled text with placeholder
// inheritance. Gradients use their first stop; effects, charts, SmartArt, picture crops and flips are not drawn.
enum Slides {
  struct Shape {
    var rect: CGRect
    var rotation: CGFloat = 0
    var geom = "rect"
    var fill: NSColor? = nil, line: NSColor? = nil
    var lineWidth: CGFloat = 0.75
    var image: CGImage? = nil
    var text: NSAttributedString? = nil
    var anchor = "t"
    var insets = NSEdgeInsets(top: 3.6, left: 7.2, bottom: 3.6, right: 7.2)
  }

  struct Slide {
    var background: NSColor = .white
    var shapes: [Shape] = []
  }

  struct Deck {
    var size: CGSize
    var slides: [Slide]
  }

  static func load(_ u: URL) throws -> Deck {
    let deck = u.pathExtension.lowercased() == "ppt" ? try ppt(u) : try pptx(u)
    guard !deck.slides.isEmpty else { throw ToolError("\(u.lastPathComponent) has no slides") }
    return deck
  }

  // MARK: Output

  static func pdf(_ src: URL) throws -> URL {
    let deck = try load(src)
    let out = outputURL(for: src, ext: "pdf")
    var box = CGRect(origin: .zero, size: deck.size)
    guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw ToolError("Couldn't create \(out.lastPathComponent)") }
    for s in deck.slides {
      ctx.beginPage(mediaBox: &box)
      draw(s, size: deck.size, in: ctx)
      ctx.endPage()
    }
    ctx.closePDF()
    return out
  }

  static func images(_ src: URL, type: UTType, ext: String) throws -> [URL] {
    let deck = try load(src)
    let k = min(2, 4000 / max(deck.size.width, deck.size.height))
    let w = Int(deck.size.width * k), h = Int(deck.size.height * k)
    return try deck.slides.enumerated().map { i, s in
      guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ToolError("Out of memory") }
      ctx.scaleBy(x: k, y: k)
      draw(s, size: deck.size, in: ctx)
      guard let img = ctx.makeImage() else { throw ToolError("Couldn't render slide \(i + 1)") }
      let out = outputURL(for: src, ext: ext, suffix: "-slide\(i + 1)")
      try ImageTools.write(img, props: [:], type: type, to: out)
      return out
    }
  }

  /// Draws into a context whose origin is bottom-left, in points.
  static func draw(_ s: Slide, size: CGSize, in ctx: CGContext) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    defer { NSGraphicsContext.current = saved; ctx.restoreGState() }
    ctx.setFillColor(s.background.cgColor)
    ctx.fill(CGRect(origin: .zero, size: size))
    for sh in s.shapes {
      ctx.saveGState()
      if sh.rotation != 0 {
        ctx.translateBy(x: sh.rect.midX, y: sh.rect.midY); ctx.rotate(by: sh.rotation * .pi / 180); ctx.translateBy(x: -sh.rect.midX, y: -sh.rect.midY)
      }
      let r = sh.rect, path = CGMutablePath()
      switch sh.geom {
      case "ellipse": path.addEllipse(in: r)
      case "roundRect": let c = min(r.width, r.height) * 0.1667; path.addRoundedRect(in: r, cornerWidth: c, cornerHeight: c)
      case "line": path.move(to: CGPoint(x: r.minX, y: r.minY)); path.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
      default: path.addRect(r)
      }
      if let f = sh.fill, sh.geom != "line" { ctx.addPath(path); ctx.setFillColor(f.cgColor); ctx.fillPath() }
      if let img = sh.image {
        ctx.saveGState(); ctx.translateBy(x: r.minX, y: r.maxY); ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size)); ctx.restoreGState()
      }
      if let l = sh.line { ctx.addPath(path); ctx.setStrokeColor(l.cgColor); ctx.setLineWidth(sh.lineWidth); ctx.strokePath() }
      if let t = sh.text, t.length > 0 {
        let box = CGRect(x: r.minX + sh.insets.left, y: r.minY + sh.insets.top,
                         width: max(1, r.width - sh.insets.left - sh.insets.right), height: r.height - sh.insets.top - sh.insets.bottom)
        let h = t.boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let y = sh.anchor == "ctr" ? box.midY - h / 2 : sh.anchor == "b" ? box.maxY - h : box.minY
        t.draw(with: CGRect(x: box.minX, y: y, width: box.width, height: h + 1), options: [.usesLineFragmentOrigin, .usesFontLeading])
      }
      ctx.restoreGState()
    }
  }

  // MARK: PPTX

  struct Part {
    let path: String, xml: XMLElement, rels: [String: String]
  }

  struct Context {
    let zip: ZipReader
    let colors: [String: NSColor]
    let majorFont: String?, minorFont: String?
    let slide: Part, layout: Part?, master: Part?
  }

  static func pptx(_ u: URL) throws -> Deck {
    let z = try ZipReader(u)
    guard let pres = z.xml("ppt/presentation.xml") else { throw ToolError("\(u.lastPathComponent) isn't a valid PPTX file") }
    let sz = pres.first("sldSz")
    let size = CGSize(width: emu(sz?.attr("cx")) ?? 720, height: emu(sz?.attr("cy")) ?? 540)
    let rels = z.rels("ppt/presentation.xml")
    func part(_ path: String?) -> Part? { path.flatMap { p in z.xml(p).map { Part(path: p, xml: $0, rels: z.rels(p)) } } }
    var themes: [String: (colors: [String: NSColor], major: String?, minor: String?)] = [:]
    let slides: [Slide] = (pres.first("sldIdLst")?.kids("sldId") ?? []).compactMap { id in
      guard let slide = part(id.attr("r:id").flatMap { rels[$0] }) else { return nil }
      let layout = part(slide.rels.values.first { $0.contains("slideLayouts/") })
      let master = part(layout?.rels.values.first { $0.contains("slideMasters/") })
      let themePath = master?.rels.values.first { $0.contains("theme/") } ?? "ppt/theme/theme1.xml"
      if themes[themePath] == nil {
        let t = z.xml(themePath)
        var colors: [String: NSColor] = [:]
        for c in t?.first("clrScheme")?.elements ?? [] {
          if let name = c.localName, let v = c.kid("srgbClr")?.attr("val") ?? c.kid("sysClr")?.attr("lastClr"), let col = hex(v) { colors[name] = col }
        }
        themes[themePath] = (colors, t?.first("majorFont")?.kid("latin")?.attr("typeface"), t?.first("minorFont")?.kid("latin")?.attr("typeface"))
      }
      let th = themes[themePath]!
      let c = Context(zip: z, colors: th.colors, majorFont: th.major, minorFont: th.minor, slide: slide, layout: layout, master: master)
      var s = Slide()
      for p in [slide, layout, master].compactMap({ $0 }) {
        if let bg = p.xml.at("cSld", "bg", "bgPr").flatMap({ fill($0, c) }) { s.background = bg; break }
        if let ref = p.xml.at("cSld", "bg", "bgRef"), let col = color(ref, c) { s.background = col; break }
      }
      let showMaster = slide.xml.attr("showMasterSp") != "0" && layout?.xml.attr("showMasterSp") != "0"
      if showMaster, let m = master?.xml.at("cSld", "spTree") { s.shapes += shapes(m, part: master!, c, placeholders: false) }
      if let l = layout?.xml.at("cSld", "spTree") { s.shapes += shapes(l, part: layout!, c, placeholders: false) }
      if let t = slide.xml.at("cSld", "spTree") { s.shapes += shapes(t, part: slide, c, placeholders: true) }
      return s
    }
    return Deck(size: size, slides: slides)
  }

  static func emu(_ s: String?) -> CGFloat? { s.flatMap(Double.init).map { CGFloat($0) / 12700 } }

  static func rect(_ xfrm: XMLElement?) -> CGRect? {
    guard let off = xfrm?.kid("off"), let ext = xfrm?.kid("ext") else { return nil }
    return CGRect(x: emu(off.attr("x")) ?? 0, y: emu(off.attr("y")) ?? 0, width: emu(ext.attr("cx")) ?? 0, height: emu(ext.attr("cy")) ?? 0)
  }

  /// The layout or master placeholder a slide placeholder inherits from (matched by idx, then type).
  static func inherited(_ ph: XMLElement, in part: Part?) -> XMLElement? {
    guard let tree = part?.xml.at("cSld", "spTree") else { return nil }
    let all = tree.all("sp").filter { $0.at("nvSpPr", "nvPr", "ph") != nil }
    func type(_ p: XMLElement?) -> String {
      let t = p?.attr("type") ?? "body"
      return ["ctrTitle", "title"].contains(t) ? "title" : ["obj", "body", "subTitle"].contains(t) ? "body" : t
    }
    if let idx = ph.attr("idx"), let m = all.first(where: { $0.at("nvSpPr", "nvPr", "ph")?.attr("idx") == idx }) { return m }
    return all.first { type($0.at("nvSpPr", "nvPr", "ph")) == type(ph) }
  }

  static func shapes(_ tree: XMLElement, part: Part, _ c: Context, placeholders: Bool, map: (CGRect) -> CGRect = { $0 }) -> [Shape] {
    var out: [Shape] = []
    for e in tree.elements {
      switch e.localName {
      case "sp", "cxnSp":
        let ph = e.first("ph")
        if ph != nil && !placeholders { continue }
        let lph = ph.flatMap { inherited($0, in: c.layout) }, mph = ph.flatMap { inherited($0, in: c.master) }
        let spPr = e.kid("spPr")
        guard let r = rect(spPr?.kid("xfrm")) ?? rect(lph?.at("spPr", "xfrm")) ?? rect(mph?.at("spPr", "xfrm")) else { continue }
        var s = Shape(rect: map(r))
        s.rotation = CGFloat(Double(spPr?.kid("xfrm")?.attr("rot") ?? "") ?? 0) / 60000
        s.geom = e.localName == "cxnSp" ? "line" : spPr?.kid("prstGeom")?.attr("prst") ?? "rect"
        if s.geom.lowercased().contains("line") || s.geom.contains("Connector") { s.geom = "line" }
        let style = e.kid("style")
        if let spPr, spPr.kid("noFill") == nil {
          s.fill = fill(spPr, c) ?? (style?.kid("fillRef")?.attr("idx") != "0" ? style?.kid("fillRef").flatMap { color($0, c) } : nil)
        }
        if let ln = spPr?.kid("ln") {
          s.lineWidth = max(0.5, emu(ln.attr("w")) ?? 0.75)
          if ln.kid("noFill") == nil { s.line = fill(ln, c) ?? style?.kid("lnRef").flatMap { color($0, c) } }
        } else if let ref = style?.kid("lnRef"), ref.attr("idx") != "0" { s.line = color(ref, c) }
        if let body = e.kid("txBody") {
          let kind = ph.map { ["title", "ctrTitle"].contains($0.attr("type") ?? "") ? "title" : "body" } ?? "other"
          let bodyPrs = [body.kid("bodyPr"), lph?.at("txBody", "bodyPr"), mph?.at("txBody", "bodyPr")].compactMap { $0 }
          s.anchor = bodyPrs.lazy.compactMap { $0.attr("anchor") }.first ?? "t"
          let bp = body.kid("bodyPr")
          s.insets = NSEdgeInsets(top: emu(bp?.attr("tIns")) ?? 3.6, left: emu(bp?.attr("lIns")) ?? 7.2,
                                  bottom: emu(bp?.attr("bIns")) ?? 3.6, right: emu(bp?.attr("rIns")) ?? 7.2)
          let scale = CGFloat(Double(bp?.kid("normAutofit")?.attr("fontScale") ?? "") ?? 100_000) / 100_000
          let styles = [body.kid("lstStyle"), lph?.at("txBody", "lstStyle"), mph?.at("txBody", "lstStyle"),
                        c.master?.xml.at("txStyles", kind == "title" ? "titleStyle" : kind == "body" ? "bodyStyle" : "otherStyle")].compactMap { $0 }
          s.text = text(body, styles: styles, title: kind == "title", scale: scale, c)
        }
        if s.fill != nil || s.line != nil || (s.text?.length ?? 0) > 0 { out.append(s) }
      case "pic":
        guard let r = rect(e.at("spPr", "xfrm")), let id = e.first("blip")?.attr("r:embed"), let path = part.rels[id],
              let data = c.zip.read(path), let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
        out.append(Shape(rect: map(r), image: img))
      case "grpSp":
        let x = e.at("grpSpPr", "xfrm")
        guard let r = rect(x), let o = x?.kid("chOff"), let ce = x?.kid("chExt") else { continue }
        let co = CGPoint(x: emu(o.attr("x")) ?? 0, y: emu(o.attr("y")) ?? 0)
        let cs = CGSize(width: emu(ce.attr("cx")) ?? r.width, height: emu(ce.attr("cy")) ?? r.height)
        let sx = cs.width > 0 ? r.width / cs.width : 1, sy = cs.height > 0 ? r.height / cs.height : 1
        out += shapes(e, part: part, c, placeholders: placeholders) { cr in
          map(CGRect(x: r.minX + (cr.minX - co.x) * sx, y: r.minY + (cr.minY - co.y) * sy, width: cr.width * sx, height: cr.height * sy))
        }
      case "graphicFrame":
        guard let r = rect(e.kid("xfrm")), let tbl = e.first("tbl") else { continue }
        let widths = tbl.first("tblGrid")?.kids("gridCol").map { emu($0.attr("w")) ?? 0 } ?? []
        var y = r.minY
        let other = c.master?.xml.at("txStyles", "otherStyle")
        for row in tbl.kids("tr") {
          let h = emu(row.attr("h")) ?? 20
          var x = r.minX
          for (i, cell) in row.kids("tc").enumerated() {
            let w = i < widths.count ? widths[i] : 72
            var s = Shape(rect: map(CGRect(x: x, y: y, width: w, height: h)))
            s.line = NSColor(white: 0.6, alpha: 1)
            s.fill = cell.kid("tcPr").flatMap { fill($0, c) }
            s.text = cell.kid("txBody").map { text($0, styles: [other].compactMap { $0 }, title: false, scale: 1, c) }
            out.append(s)
            x += w
          }
          y += h
        }
      default: continue
      }
    }
    return out
  }

  /// Paragraphs with level styles resolved through the shape, layout, master and master text styles.
  static func text(_ body: XMLElement, styles: [XMLElement], title: Bool, scale: CGFloat, _ c: Context) -> NSAttributedString {
    let out = NSMutableAttributedString()
    var number = 0
    for (pi, p) in body.kids("p").enumerated() {
      let pPr = p.kid("pPr")
      let lvl = (Int(pPr?.attr("lvl") ?? "") ?? 0) + 1
      let chain = [pPr].compactMap { $0 } + styles.compactMap { $0.kid("lvl\(lvl)pPr") }
      let defs = chain.compactMap { $0.kid("defRPr") }
      func prop(_ name: String, _ rPr: XMLElement?) -> String? { rPr?.attr(name) ?? defs.lazy.compactMap { $0.attr(name) }.first }
      let ps = NSMutableParagraphStyle()
      ps.alignment = ["ctr": .center, "r": .right, "just": .justified][chain.lazy.compactMap { $0.attr("algn") }.first ?? "l"] ?? .left
      let marL = chain.lazy.compactMap { emu($0.attr("marL")) }.first ?? 0, indent = chain.lazy.compactMap { emu($0.attr("indent")) }.first ?? 0
      ps.headIndent = marL; ps.firstLineHeadIndent = max(0, marL + indent)
      ps.tabStops = [NSTextTab(textAlignment: .left, location: marL)]
      if let pct = chain.lazy.compactMap({ $0.at("lnSpc", "spcPct")?.attr("val") }).first.flatMap(Double.init) { ps.lineHeightMultiple = pct / 100_000 }
      if let pts = chain.lazy.compactMap({ $0.at("spcBef", "spcPts")?.attr("val") }).first.flatMap(Double.init), pi > 0 { ps.paragraphSpacingBefore = pts / 100 }
      func attrs(_ rPr: XMLElement?) -> [NSAttributedString.Key: Any] {
        let size = CGFloat(Double(prop("sz", rPr) ?? "") ?? 1800) / 100 * scale
        var face = rPr?.kid("latin")?.attr("typeface") ?? defs.lazy.compactMap { $0.kid("latin")?.attr("typeface") }.first ?? (title ? "+mj-lt" : "+mn-lt")
        if face == "+mj-lt" { face = c.majorFont ?? "" } else if face == "+mn-lt" { face = c.minorFont ?? "" }
        var traits: NSFontTraitMask = []
        if ["1", "true"].contains(prop("b", rPr) ?? "") { traits.insert(.boldFontMask) }
        if ["1", "true"].contains(prop("i", rPr) ?? "") { traits.insert(.italicFontMask) }
        let fm = NSFontManager.shared
        var font = fm.font(withFamily: face, traits: traits, weight: 5, size: size) ?? NSFont(name: face, size: size)
        if font == nil {
          font = NSFont.systemFont(ofSize: size)
          if !traits.isEmpty { font = fm.convert(font!, toHaveTrait: traits) }
        }
        let col = rPr?.kid("solidFill").flatMap { color($0, c) } ?? defs.lazy.compactMap { $0.kid("solidFill").flatMap { color($0, c) } }.first
          ?? c.colors["dk1"] ?? .black
        var a: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: col, .paragraphStyle: ps]
        if let u = rPr?.attr("u"), u != "none" { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return a
      }
      let runs = p.elements.filter { ["r", "br", "fld"].contains($0.localName ?? "") }
      let firstAttrs = attrs(runs.first?.kid("rPr") ?? p.kid("endParaRPr"))
      if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: firstAttrs)) }
      let hasText = runs.contains { !($0.kid("t")?.stringValue ?? "").isEmpty }
      // bullets: the first of buNone / buChar / buAutoNum found walking up the chain
      if hasText, let bu = chain.lazy.compactMap({ $0.kid("buNone") ?? $0.kid("buChar") ?? $0.kid("buAutoNum") }).first, bu.localName != "buNone" {
        number = bu.localName == "buAutoNum" ? number + 1 : 0
        let mark = bu.localName == "buChar" ? (bu.attr("char") ?? "•") : "\(number)."
        out.append(NSAttributedString(string: mark + (marL + indent < marL ? "\t" : " "), attributes: firstAttrs))
      }
      for r in runs {
        if r.localName == "br" { out.append(NSAttributedString(string: "\u{2028}", attributes: firstAttrs)); continue }
        out.append(NSAttributedString(string: r.kid("t")?.stringValue ?? "", attributes: attrs(r.kid("rPr"))))
      }
    }
    return out
  }

  /// Colour of a fill element (solidFill / gradFill child) or of a colour-holding element itself.
  static func fill(_ e: XMLElement, _ c: Context) -> NSColor? {
    if let s = e.kid("solidFill") { return color(s, c) }
    if let g = e.kid("gradFill")?.first("gs") { return color(g, c) }
    return nil
  }

  static func color(_ e: XMLElement, _ c: Context) -> NSColor? {
    guard let k = e.elements.first(where: { ["srgbClr", "schemeClr", "sysClr", "prstClr", "scrgbClr"].contains($0.localName ?? "") }) else { return nil }
    var col: NSColor?
    switch k.localName {
    case "srgbClr": col = hex(k.attr("val") ?? "")
    case "sysClr": col = hex(k.attr("lastClr") ?? "")
    case "prstClr": col = ["black": NSColor.black, "white": .white, "red": .red, "green": .green, "blue": .blue, "yellow": .yellow, "gray": .gray][k.attr("val") ?? ""]
    case "scrgbClr":
      func v(_ n: String) -> CGFloat { CGFloat(Double(k.attr(n) ?? "") ?? 0) / 100_000 }
      col = NSColor(srgbRed: v("r"), green: v("g"), blue: v("b"), alpha: 1)
    default:
      let v = k.attr("val") ?? ""
      col = c.colors[["tx1": "dk1", "bg1": "lt1", "tx2": "dk2", "bg2": "lt2"][v] ?? v]
    }
    guard var rgb = col?.usingColorSpace(.sRGB) else { return nil }
    func mod(_ n: String) -> CGFloat? { k.kid(n)?.attr("val").flatMap(Double.init).map { CGFloat($0) / 100_000 } }
    var r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
    if mod("lumMod") != nil || mod("lumOff") != nil {  // in HSL
      let mx = max(r, g, b), mn = min(r, g, b)
      var l = (mx + mn) / 2
      let d = mx - mn, s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
      var h: CGFloat = 0
      if d > 0 { h = mx == r ? ((g - b) / d).truncatingRemainder(dividingBy: 6) : mx == g ? (b - r) / d + 2 : (r - g) / d + 4 }
      l = min(1, max(0, l * (mod("lumMod") ?? 1) + (mod("lumOff") ?? 0)))
      let C = (1 - abs(2 * l - 1)) * s, X = C * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)), m = l - C / 2
      let hh = (h + 6).truncatingRemainder(dividingBy: 6)
      let (r1, g1, b1): (CGFloat, CGFloat, CGFloat) = hh < 1 ? (C, X, 0) : hh < 2 ? (X, C, 0) : hh < 3 ? (0, C, X) : hh < 4 ? (0, X, C) : hh < 5 ? (X, 0, C) : (C, 0, X)
      (r, g, b) = (r1 + m, g1 + m, b1 + m)
    }
    if let t = mod("tint") { (r, g, b) = (1 - (1 - r) * t, 1 - (1 - g) * t, 1 - (1 - b) * t) }
    if let s = mod("shade") { (r, g, b) = (r * s, g * s, b * s) }
    rgb = NSColor(srgbRed: r, green: g, blue: b, alpha: mod("alpha") ?? 1)
    return rgb
  }

  static func hex(_ s: String) -> NSColor? {
    guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
    return NSColor(srgbRed: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
  }

  // MARK: PPT (PowerPoint 97–2003)

  // ponytail: text only, laid out as title + bullets on blank slides; fast-saved files may show superseded text.
  static func ppt(_ u: URL) throws -> Deck {
    guard let b = try CompoundFile(u).stream("PowerPoint Document") else { throw ToolError("\(u.lastPathComponent) isn't a PowerPoint file") }
    func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
    var size = CGSize(width: 720, height: 540)
    var outline: [[(Int, String)]] = [], drawings: [[(Int, String)]] = []
    var inOutline = false, inSlide = false, textType = 1
    func walk(_ start: Int, _ end: Int) {
      var p = start
      while p + 8 <= end {
        let ver = u16(p), type = u16(p + 2), len = u32(p + 4), d = p + 8
        guard d + len <= end else { return }
        if ver & 0xF == 0xF {
          switch type {
          case 0x03EE: drawings.append([]); inSlide = true; walk(d, d + len); inSlide = false
          case 0x03F8, 0x03F0, 0x0FC8: break  // masters, notes, handouts
          case 0x0FF0:
            if ver >> 4 == 0 { inOutline = true; walk(d, d + len); inOutline = false }
          default: walk(d, d + len)
          }
        } else {
          switch type {
          case 0x03E9 where len >= 8: size = CGSize(width: CGFloat(u32(d)) / 8, height: CGFloat(u32(d + 4)) / 8)  // master units, 576/inch
          case 0x03F3 where inOutline: outline.append([])
          case 0x0F9F where len >= 4: textType = u32(d)
          case 0x0FA0, 0x0FA8:
            let t = type == 0x0FA0 ? String(decoding: stride(from: d, to: d + len - 1, by: 2).map { UInt16(b[$0]) | UInt16(b[$0 + 1]) << 8 }, as: UTF16.self)
                                   : String(decoding: b[d..<(d + len)].map { UInt16($0) }, as: UTF16.self)
            if inOutline, !outline.isEmpty { outline[outline.count - 1].append((textType, t)) }
            else if inSlide, !drawings.isEmpty { drawings[drawings.count - 1].append((textType, t)) }
          default: break
          }
        }
        p = d + len
      }
    }
    walk(0, b.count)
    if size.width < 72 || size.height < 72 { size = CGSize(width: 720, height: 540) }
    let n = max(outline.count, drawings.count)
    guard n > 0 else { throw ToolError("No slides found in \(u.lastPathComponent)") }
    let slides: [Slide] = (0..<n).map { i in
      let texts = (i < outline.count ? outline[i] : []) + (i < drawings.count ? drawings[i] : [])
      let titleIdx = texts.firstIndex { $0.0 == 0 || $0.0 == 6 }
      func para(_ s: String, size: CGFloat, bold: Bool, bullet: Bool) -> NSAttributedString {
        let ps = NSMutableParagraphStyle(); ps.paragraphSpacingBefore = bullet ? 6 : 0
        if bullet { ps.headIndent = 24; ps.tabStops = [NSTextTab(textAlignment: .left, location: 24)] }
        let lines = s.replacingOccurrences(of: "\u{0B}", with: "\u{2028}").components(separatedBy: "\r").filter { !$0.isEmpty }
        return NSAttributedString(string: lines.map { (bullet ? "•\t" : "") + $0 }.joined(separator: "\n"),
                                  attributes: [.font: bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size), .paragraphStyle: ps, .foregroundColor: NSColor.black])
      }
      var s = Slide()
      let w = size.width, h = size.height
      if let t = titleIdx {
        var sh = Shape(rect: CGRect(x: w * 0.06, y: h * 0.04, width: w * 0.88, height: h * 0.2)); sh.anchor = "ctr"
        sh.text = para(texts[t].1, size: 32, bold: true, bullet: false); s.shapes.append(sh)
      }
      let body = NSMutableAttributedString()
      for (k, t) in texts.enumerated() where k != titleIdx {
        if body.length > 0 { body.append(NSAttributedString(string: "\n")) }
        body.append(para(t.1, size: 20, bold: false, bullet: true))
      }
      var sh = Shape(rect: CGRect(x: w * 0.06, y: h * 0.27, width: w * 0.88, height: h * 0.68)); sh.text = body
      s.shapes.append(sh)
      return s
    }
    return Deck(size: size, slides: slides)
  }
}

extension ImageTools {
  /// SVG rasterized at its own size (1 px per point) by AppKit's SVG support.
  static func svg(_ src: URL) throws -> CGImage {
    guard let img = NSImage(contentsOf: src), img.size.width >= 1, img.size.height >= 1 else { throw ToolError("Can't read \(src.lastPathComponent)") }
    let w = Int(img.size.width.rounded()), h = Int(img.size.height.rounded())
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ToolError("\(src.lastPathComponent) is too large") }
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.current = saved
    guard let out = ctx.makeImage() else { throw ToolError("Can't render \(src.lastPathComponent)") }
    return out
  }
}
