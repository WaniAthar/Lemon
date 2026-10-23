import AppKit
import CoreText
import PDFKit
import SwiftUI

extension SelfTest {
  /// PDF with one line of text per page, e.g. ["A1", "A2"], each page `size` points.
  static func textPDF(_ url: URL, _ texts: [String], size: CGSize = CGSize(width: 612, height: 792)) {
    var box = CGRect(origin: .zero, size: size)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    for t in texts {
      ctx.beginPage(mediaBox: &box)
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: "PAGE-\(t)", attributes: [.font: NSFont.systemFont(ofSize: 24)]))
      ctx.textPosition = CGPoint(x: 40, y: size.height / 2)
      CTLineDraw(line, ctx)
      ctx.endPage()
    }
    ctx.closePDF()
  }

  static func solidImage(_ url: URL, _ color: CGColor, width: Int = 400, height: Int = 200) {
    let c = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setFillColor(color)
    c.fill(CGRect(x: 0, y: 0, width: width, height: height))
    try! ImageTools.write(c.makeImage()!, props: [:], type: .png, to: url)
  }

  /// Rough colour match at (x, y), origin top-left, comparing raw components (everything here is sRGB).
  static func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, is c: CGColor) -> Bool {
    guard let p = rep.colorAt(x: x, y: y), let q = c.components, q.count >= 3 else { return false }
    let got = [p.redComponent, p.greenComponent, p.blueComponent]
    return zip(got, q).allSatisfy { abs($0 - $1) < 0.1 }
  }

  static func pdfPack(dir: URL) async {
    let a = dir.appendingPathComponent("A.pdf"), b = dir.appendingPathComponent("B.pdf")
    textPDF(a, ["A1", "A2", "A3"])
    textPDF(b, ["B1"], size: CGSize(width: 300, height: 400))
    func texts(_ d: PDFDocument) -> [String] { PDFTools.pages(d).map { ($0.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) } }

    await attempt("organize: order, rotation, deletion, duplication") {
      let refs = [PageRef(source: 0, page: 2, turns: 1), PageRef(source: 0, page: 0), PageRef(source: 1, page: 0, turns: -1),
                  PageRef(source: 0, page: 0, turns: 2)]
      let out = try PDFTools.organize([a, b], pages: refs)
      guard let d = PDFDocument(url: out) else { return false }
      return out.lastPathComponent == "A-merged.pdf" && d.pageCount == 4
        && PDFTools.pages(d).map(\.rotation) == [90, 0, 270, 180]
        && texts(d) == ["PAGE-A3", "PAGE-A1", "PAGE-B1", "PAGE-A1"]
    }
    await attempt("organize one file is named -organized") {
      try PDFTools.organize([a], pages: [PageRef(source: 0, page: 1)]).lastPathComponent == "A-organized.pdf"
    }
    await attempt("organize inserts images as pages") {
      let img = dir.appendingPathComponent("ins.png")
      solidImage(img, CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
      let d = try PDFTools.organized([a, img], pages: [PageRef(source: 1, page: 0), PageRef(source: 0, page: 1)], equalizeWidths: false)
      return d.pageCount == 2 && d.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 400, height: 200) && texts(d)[1] == "PAGE-A2"
    }
    await attempt("organize: equalize widths scales to the widest page") {
      let d = try PDFTools.organized([a, b], pages: [PageRef(source: 0, page: 0), PageRef(source: 1, page: 0), PageRef(source: 1, page: 0, turns: 1)],
                                     equalizeWidths: true)
      let boxes = PDFTools.pages(d).map { $0.bounds(for: .mediaBox).size }
      return boxes.allSatisfy { $0.width == 612 } && boxes.map(\.height) == [792, 816, 459]
        && texts(d) == ["PAGE-A1", "PAGE-B1", "PAGE-B1"] && PDFTools.pages(d).allSatisfy { $0.rotation == 0 }
    }
    await expectError("organize with every page deleted fails") { _ = try PDFTools.organize([a], pages: []) }
    await attempt("edit.organize one-click keeps every page") {
      PDFDocument(url: try await Tools.all.first { $0.id == "edit.organize" }!.run([a, b])[0])?.pageCount == 4
    }

    let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), green = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
    let blue = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), yellow = CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    let imgs = [red, green, blue, yellow].enumerated().map { i, c -> URL in
      let u = dir.appendingPathComponent("tile\(i).png")
      solidImage(u, c)
      return u
    }

    func pageSizes(_ u: URL) -> [CGSize] { PDFDocument(url: u).map { PDFTools.pages($0).map { $0.bounds(for: .mediaBox).size } } ?? [] }
    func close(_ s: CGSize, _ w: CGFloat, _ h: CGFloat) -> Bool { abs(s.width - w) < 0.5 && abs(s.height - h) < 0.5 }
    await attempt("create PDF: A4 auto turns landscape for a wide image, Letter portrait when asked") {
      let a4 = pageSizes(try ImageTools.toPDF([imgs[0]], setup: PageSetup(size: .a4)))
      let letter = pageSizes(try ImageTools.toPDF([imgs[0], imgs[1]], setup: PageSetup(size: .letter, orientation: .portrait)))
      let fit = pageSizes(try ImageTools.toPDF([imgs[0]], setup: PageSetup(size: .fit, margin: 10)))
      return a4.count == 1 && close(a4[0], 841.89, 595.28) && letter.count == 2 && letter.allSatisfy { close($0, 612, 792) }
        && close(fit[0], 420, 220)
    }
    await attempt("create PDF: margins respected") {
      // Letter portrait, 72 pt margins: the 400x200 image fits to 468x234, centred.
      let u = try ImageTools.toPDF([imgs[0]], setup: PageSetup(size: .letter, orientation: .portrait, margin: 72))
      guard let page = CGPDFDocument(u as CFURL)?.page(at: 1) else { return false }
      let ctx = CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.setFillColor(white); ctx.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
      ctx.drawPDFPage(page)
      let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
      return pixel(rep, 36, 396, is: white) && pixel(rep, 76, 396, is: red) && pixel(rep, 536, 396, is: red)
        && pixel(rep, 545, 396, is: white) && pixel(rep, 306, 270, is: white) && pixel(rep, 306, 285, is: red)
    }

    await attempt("collage: preset size and grid tiles in order") {
      let u = try ImageTools.collage(imgs, layout: CollageLayout(style: .grid, preset: .square, spacing: 20))
      let (img, _) = try ImageTools.decode(u)
      let rep = NSBitmapImageRep(cgImage: img)
      return img.width == 2048 && img.height == 2048 && pixel(rep, 5, 5, is: white)
        && pixel(rep, 512, 512, is: red) && pixel(rep, 1536, 512, is: green) && pixel(rep, 512, 1536, is: blue) && pixel(rep, 1536, 1536, is: yellow)
    }
    await attempt("collage: featured puts the first image large on the left") {
      let u = try ImageTools.collage(Array(imgs.prefix(3)), layout: CollageLayout(style: .featured, preset: .wide, spacing: 10,
                                                                                    background: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)))
      let (img, _) = try ImageTools.decode(u)
      let rep = NSBitmapImageRep(cgImage: img)
      return img.width == 1920 && img.height == 1080 && pixel(rep, 600, 540, is: red) && pixel(rep, 1600, 270, is: green)
        && pixel(rep, 1600, 810, is: blue) && pixel(rep, 3, 3, is: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    }
    await attempt("collage: columns and A4 / 4:5 presets") {
      let cols = try ImageTools.collage(Array(imgs.prefix(2)), layout: CollageLayout(style: .columns, preset: .portrait))
      let (c, _) = try ImageTools.decode(cols)
      let rep = NSBitmapImageRep(cgImage: c)
      let (a4, _) = try ImageTools.decode(try ImageTools.collage(imgs, layout: CollageLayout(preset: .a4)))
      return c.width == 1080 && c.height == 1350 && pixel(rep, 270, 675, is: red) && pixel(rep, 810, 675, is: green)
        && a4.width == 1240 && a4.height == 1754
    }
    check(CollageLayout.Style.allCases.allSatisfy { s in
      CollageLayout.Preset.allCases.allSatisfy { p in
        let l = CollageLayout(style: s, preset: p, spacing: 12)
        let canvas = CGRect(origin: .zero, size: p.size)
        return (1...9).allSatisfy { n in
          let f = l.frames(n)
          return f.count == n && f.allSatisfy { canvas.contains($0) && $0.width > 0 }
            && f.indices.allSatisfy { i in f.indices.allSatisfy { j in i == j || f[i].intersection(f[j]).width * f[i].intersection(f[j]).height < 0.01 } }
        }
      }
    }, "collage: every layout tiles 1–9 images inside the canvas without overlap")

    func ids(_ urls: [URL]) -> [String] { Tools.available(for: urls, mode: .edit).map(\.id) }
    check(ids([a]).contains("edit.organize") && ids([a, b]).contains("edit.merge") && ids(imgs).contains("edit.collage")
          && ids([imgs[0]]).contains("edit.createpdf") && !ids([imgs[0]]).contains("edit.collage"), "PDF pack tools routed")

    if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
      let out = URL(fileURLWithPath: CommandLine.arguments[i + 1]).deletingPathExtension().appendingPathExtension("pdfeditors.png")
      let thumbs = PageThumbs()
      for u in [a, b] { await thumbs.load(u).value }
      lemonPlainRender = true
      defer { lemonPlainRender = false }
      let views = VStack(spacing: 20) {
        HStack(spacing: 20) {
          EditorChrome(content: OrganizeEditor(urls: [a, b], close: {}, thumbs: thumbs)).frame(width: 900, height: 680)
          EditorChrome(content: MergeEditor(urls: [a, b, a], close: {}, thumbs: thumbs)).frame(width: 640, height: 560)
        }
        HStack(spacing: 20) {
          EditorChrome(content: CreatePDFEditor(urls: imgs, close: {})).frame(width: 900, height: 660)
          EditorChrome(content: CollageEditor(urls: imgs, close: {})).frame(width: 920, height: 660)
        }
      }.padding(20).background(Color(red: 0.75, green: 0.82, blue: 0.9))
      if let t = ImageRenderer(content: views).nsImage?.tiffRepresentation,
         let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
        try? png.write(to: out)
        print("rendered", out.path)
      }
    }
  }
}
