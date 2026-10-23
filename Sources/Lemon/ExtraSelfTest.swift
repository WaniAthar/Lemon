import AppKit
import CoreImage
import CoreText
import CryptoKit
import ImageIO
import PDFKit
import SwiftUI

extension SelfTest {
  static func extrasPack(dir: URL) async {
    func run(_ id: String, _ urls: [URL]) async throws -> [URL] { try await Tools.all.first { $0.id == id }!.run(urls) }
    func alpha(_ img: CGImage, _ x: Int, _ y: Int) -> UInt8 { rgba(img).px[(y * img.width + x) * 4 + 3] }  // y from the top
    let red = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    // Remove background: compositing with a known mask (centre square kept).
    let subject = image(200, 200) { c in
      c.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.9, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
      c.setFillColor(red); c.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
    }
    let mask = CIImage(cgImage: image(100, 100) { c in  // half size: the cut-out scales it up
      c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
      c.setFillColor(CGColor(gray: 1, alpha: 1)); c.fill(CGRect(x: 25, y: 25, width: 50, height: 50))
    })
    await attempt("remove bg: background alpha 0, subject alpha 1, colour fill, feather softens the edge") {
      guard let cut = ImageTools.cutout(subject, mask: mask), let filled = ImageTools.cutout(subject, mask: mask, fill: white),
            let soft = ImageTools.cutout(subject, mask: mask, feather: 3) else { return false }
      let hard = alpha(cut, 50, 100), feathered = alpha(soft, 50, 100)
      return alpha(cut, 5, 5) < 3 && alpha(cut, 100, 100) > 252 && pixel(NSBitmapImageRep(cgImage: cut), 100, 100, is: red)
        && pixel(NSBitmapImageRep(cgImage: filled), 5, 5, is: white) && alpha(filled, 5, 5) == 255
        && hard > 200 && feathered > 40 && feathered < 220 && alpha(soft, 5, 5) < 3
    }
    // Vision on a photo-like subject: a dark figure on a flat backdrop.
    let figure = dir.appendingPathComponent("figure.png")
    let scene = image(600, 600) { c in
      c.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.9, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 600, height: 600))
      c.setFillColor(CGColor(srgbRed: 0.85, green: 0.3, blue: 0.2, alpha: 1)); c.fillEllipse(in: CGRect(x: 230, y: 380, width: 140, height: 140))
      c.fill(CGRect(x: 200, y: 60, width: 200, height: 320))
    }
    try? ImageTools.write(scene, props: [:], type: .png, to: figure)
    do {
      _ = try ImageTools.subjectMask(scene)
      await attempt("edit.removebg (Vision): backdrop transparent, figure opaque") {
        let out = try await run("edit.removebg", [figure])[0]
        let (img, _) = try ImageTools.decode(out)
        return out.lastPathComponent == "figure-nobg.png" && alpha(img, 10, 10) < 20 && alpha(img, 300, 400) > 230
      }
    } catch {
      print("SKIP Vision subject lifting here (\(error.localizedDescription)); compositing tested above")
    }

    // Protect and unlock.
    let doc = dir.appendingPathComponent("Report.pdf")
    textPDF(doc, ["R1", "R2", "R3"])
    func text(_ u: URL) -> String { PDFDocument(url: u)?.string ?? "" }
    var locked = doc
    await attempt("protect: encrypted, needs the open password, permissions kept") {
      locked = try PDFTools.protect(doc, user: "open-sesame", owner: "owner-pw", allowPrinting: true, allowCopying: false)
      guard let d = PDFDocument(url: locked), d.isEncrypted, d.isLocked, !d.unlock(withPassword: "wrong"), d.unlock(withPassword: "open-sesame") else { return false }
      return locked.lastPathComponent == "Report-protected.pdf" && d.allowsPrinting && !d.allowsCopying && d.permissionsStatus == .user
        && d.string?.contains("PAGE-R1") == true
    }
    await attempt("protect: permissions password only opens freely but restricts") {
      let u = try PDFTools.protect(doc, user: "", owner: "owner-pw", allowPrinting: false, allowCopying: false)
      guard let d = PDFDocument(url: u) else { return false }
      return d.isEncrypted && !d.isLocked && !d.allowsPrinting && !d.allowsCopying
    }
    await expectError("protect with no password fails") { _ = try PDFTools.protect(doc, user: "", owner: "", allowPrinting: true, allowCopying: true) }
    await expectError("edit.protect one-click refuses (needs a password)") { _ = try await run("edit.protect", [doc]) }
    await expectError("unlock: wrong password") { _ = try PDFTools.unlock(locked, password: "nope") }
    await expectError("unlock: open password can't lift restrictions") { _ = try PDFTools.unlock(locked, password: "open-sesame") }
    await expectError("edit.unlock one-click needs the password") { _ = try await run("edit.unlock", [locked]) }
    await attempt("unlock round-trip: owner password gives a plain copy") {
      let u = try PDFTools.unlock(locked, password: "owner-pw")
      guard let d = PDFDocument(url: u) else { return false }
      return !d.isEncrypted && !d.isLocked && d.pageCount == 3 && d.allowsCopying && text(u).contains("PAGE-R2")
        && u.lastPathComponent == "Report-protected-unlocked.pdf"
    }
    await attempt("unlock: open password works when nothing is restricted") {
      let p = try PDFTools.protect(doc, user: "pw", owner: "", allowPrinting: true, allowCopying: true)
      return PDFDocument(url: try PDFTools.unlock(p, password: "pw"))?.isEncrypted == false
    }

    // Watermark.
    let plain = dir.appendingPathComponent("plain.png"), stamp = dir.appendingPathComponent("stamp.png")
    solidImage(plain, white)
    solidImage(stamp, red)
    await attempt("watermark: image mark lands bottom-right, rest untouched") {
      let s = WatermarkStyle(image: stamp, position: .bottomRight, opacity: 1, size: 0.25, rotation: 0)
      let out = try Watermark.apply(plain, s)
      let rep = NSBitmapImageRep(cgImage: try ImageTools.decode(out).0)
      // 400x200: mark 100x50, margin 8, so centred at (342, 167) from the top-left
      return out.lastPathComponent == "plain-watermarked.png" && pixel(rep, 342, 167, is: red) && pixel(rep, 300, 150, is: red)
        && pixel(rep, 50, 50, is: white) && pixel(rep, 395, 195, is: white)
    }
    await attempt("watermark: text top-left at full opacity, nothing bottom-right") {
      let s = WatermarkStyle(text: "WWWW", position: .topLeft, opacity: 1, size: 0.4, rotation: 0, color: 0x000000)
      let (w, _, px) = rgba(Watermark.watermarked(try ImageTools.decode(plain).0, s, mark: nil)!)
      func dark(_ xs: Range<Int>, _ ys: Range<Int>) -> Int { ys.reduce(0) { n, y in n + xs.filter { px[(y * w + $0) * 4] < 80 }.count } }
      return dark(0..<200, 0..<100) > 200 && dark(200..<400, 100..<200) == 0
    }
    await attempt("watermark: tiled covers the page, opacity blends") {
      let s = WatermarkStyle(image: stamp, position: .tiled, opacity: 0.5, size: 0.15, rotation: 0)
      let rep = NSBitmapImageRep(cgImage: Watermark.watermarked(try ImageTools.decode(plain).0, s, mark: try Watermark.mark(s))!)
      let reds = stride(from: 5, to: 400, by: 10).flatMap { x in stride(from: 5, to: 200, by: 10).map { (x, $0) } }
        .filter { (rep.colorAt(x: $0.0, y: $0.1)?.greenComponent ?? 1) < 0.7 }
      let blended = reds.allSatisfy { (rep.colorAt(x: $0.0, y: $0.1)?.greenComponent ?? 0) > 0.35 }
      return reds.count > 120 && blended
    }
    await attempt("edit.watermark PDF keeps pages and text, adds the mark") {
      let u = try await run("edit.watermark", [doc])[0]
      return PDFDocument(url: u)?.pageCount == 3 && text(u).contains("PAGE-R3") && text(u).contains("CONFIDENTIAL")
    }

    // Page numbers.
    func pageTexts(_ u: URL) -> [String] { PDFDocument(url: u).map { PDFTools.pages($0).map { $0.string ?? "" } } ?? [] }
    await attempt("page numbers: Page N of M, first page skipped") {
      let t = pageTexts(try PDFTools.number(doc, PageNumberStyle(format: .pageOf, skipFirst: true)))
      return t.count == 3 && !t[0].contains("Page") && t[1].contains("Page 2 of 3") && t[2].contains("Page 3 of 3") && t[2].contains("PAGE-R3")
    }
    await attempt("page numbers: start number and N / M, top right") {
      let t = pageTexts(try PDFTools.number(doc, PageNumberStyle(top: true, align: .right, format: .slash, start: 5)))
      return t[0].contains("5 / 7") && t[2].contains("7 / 7")
    }
    await attempt("edit.pagenumbers one-click: -numbered, plain numbers") {
      let u = try await run("edit.pagenumbers", [doc])[0]
      return u.lastPathComponent == "Report-numbered.pdf" && pageTexts(u)[1].contains("2")
    }
    await attempt("page numbers land at the bottom centre") {
      let u = try PDFTools.number(doc, PageNumberStyle(fontSize: 40))
      guard let page = CGPDFDocument(u as CFURL)?.page(at: 1), let img = PDFTools.render(page, scale: 1) else { return false }
      let (w, h, px) = rgba(img)
      func dark(_ xs: Range<Int>, _ ys: Range<Int>) -> Int { ys.reduce(0) { n, y in n + xs.filter { px[(y * w + $0) * 4] < 100 }.count } }
      return dark(w / 2 - 40..<w / 2 + 40, h - 110..<h - 40) > 30 && dark(0..<w, 0..<100) == 0
    }

    // Searchable PDF (OCR).
    let scan = dir.appendingPathComponent("scan.png")
    let words = image(1400, 400) { c in
      c.setFillColor(white); c.fill(CGRect(x: 0, y: 0, width: 1400, height: 400))
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: "LEMON SEARCH TEST", attributes: [
        .font: NSFont.systemFont(ofSize: 110, weight: .bold), NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
      ]))
      c.textPosition = CGPoint(x: 60, y: 150)
      CTLineDraw(line, c)
    }
    try? ImageTools.write(words, props: [:], type: .png, to: scan)
    await attempt("edit.searchable: scanned PDF gains selectable text, same page size") {
      let scanned = try ImageTools.toPDF([scan])
      guard (PDFDocument(url: scanned)?.string ?? "").isEmpty else { return false }
      let u = try await run("edit.searchable", [scanned])[0]
      guard let d = PDFDocument(url: u), let s = d.string else { return false }
      return u.lastPathComponent == "scan-searchable.pdf" && s.contains("LEMON") && s.contains("SEARCH")
        && d.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 1400, height: 400)
        && d.findString("SEARCH", withOptions: .caseInsensitive).count == 1
    }
    await attempt("edit.searchable: image becomes a searchable PDF") {
      text(try await run("edit.searchable", [scan])[0]).contains("TEST")
    }
    await expectError("edit.searchable: blank page reports no text") { _ = try await run("edit.searchable", [plain]) }

    // Batch rename.
    let rdir = dir.appendingPathComponent("rename")
    try? FileManager.default.createDirectory(at: rdir, withIntermediateDirectories: true)
    func file(_ name: String, _ body: String) -> URL {
      let u = rdir.appendingPathComponent(name)
      try? body.write(to: u, atomically: true, encoding: .utf8)
      return u
    }
    let one = file("1.txt", "one"), two = file("2.txt", "two"), a = file("Alpha beta.md", "a")
    _ = file("x-2.md", "taken")
    check(Rename.plan([a], RenameRule(pattern: "x-{n}", start: 2))[0].problem == "Already exists", "rename: existing file is a conflict")
    check(Rename.plan([one, two], RenameRule(pattern: "same")).allSatisfy { $0.problem == "Duplicate name" }, "rename: duplicate targets conflict")
    check(Rename.plan([one], RenameRule(pattern: "a/b"))[0].problem == "Invalid name" && Rename.plan([one], RenameRule(pattern: " "))[0].problem == "Invalid name",
          "rename: invalid and empty names flagged")
    check(Rename.plan([a], RenameRule(pattern: "{name}", find: " ", replace: "_", letterCase: .lower))[0].to.lastPathComponent == "alpha_beta.md"
          && Rename.plan([a, one], RenameRule(pattern: "pic-{n}", start: 7, pad: 3)).map(\.to.lastPathComponent) == ["pic-007.md", "pic-008.txt"]
          && Rename.plan([a], RenameRule(pattern: "{date}-{name}"))[0].to.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}-Alpha beta\.md$"#, options: .regularExpression) != nil,
          "rename: tokens, padding, find/replace, case")
    await expectError("rename: refuses a plan with conflicts") { _ = try Rename.apply(Rename.plan([one, two], RenameRule(pattern: "same"))) }
    await attempt("rename: shifting counters (1→2, 2→3) renames in place without clobbering") {
      let outs = try Rename.apply(Rename.plan([one, two], RenameRule(pattern: "{n}", start: 2)))
      let read = { (n: String) in try? String(contentsOf: rdir.appendingPathComponent(n), encoding: .utf8) }
      let left = try FileManager.default.contentsOfDirectory(atPath: rdir.path)
      return outs.map(\.lastPathComponent) == ["2.txt", "3.txt"] && read("2.txt") == "one" && read("3.txt") == "two"
        && !FileManager.default.fileExists(atPath: one.path) && left.allSatisfy { !$0.hasPrefix(".lemon-rename") }
    }
    await attempt("rename: case-only change of one file") {
      let outs = try Rename.apply(Rename.plan([a], RenameRule(pattern: "{name}", letterCase: .upper)))
      let names = try FileManager.default.contentsOfDirectory(atPath: rdir.path)
      return names.contains("ALPHA BETA.md") && outs.count == 1
    }
    await attempt("act.rename one-click: {name}-{n}") {
      try await run("act.rename", [rdir.appendingPathComponent("3.txt")]).map(\.lastPathComponent) == ["3-1.txt"]
    }

    // Checksums.
    let abc = dir.appendingPathComponent("abc.txt")
    try? Data("abc".utf8).write(to: abc)
    await attempt("checksum: SHA-256 / SHA-1 / MD5 of \"abc\"") {
      let d = try Checksum.digests(abc)
      return d[.sha256] == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        && d[.sha1] == "a9993e364706816aba3e25717850c26c9cd0d89d" && d[.md5] == "900150983cd24fb0d6963f7d28e17f72"
    }
    await attempt("checksum: streamed multi-chunk file matches one-shot") {
      let big = dir.appendingPathComponent("big.bin")
      let data = Data((0..<(3 << 20) + 123).map { UInt8(truncatingIfNeeded: $0 &* 31) })
      try data.write(to: big)
      return try Checksum.digests(big)[.sha256] == SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    check(Checksum.normalized("  BA7816BF  abc.txt\n") == "ba7816bf" && Checksum.normalized("") == "", "checksum: pasted hash normalized")
    await attempt("act.checksum one-click copies shasum-style lines") {
      _ = try await run("act.checksum", [abc])
      return NSPasteboard.general.string(forType: .string) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  abc.txt"
    }

    // Icon set and GIF.
    await attempt("img.icns: one file, 7 sizes") {
      let u = try await run("img.icns", [figure])[0]
      return u.pathExtension == "icns" && (CGImageSourceCreateWithURL(u as CFURL, nil).map(CGImageSourceGetCount) ?? 0) >= 5
    }
    await attempt("img.gif: one frame per image") {
      let u = try await run("img.gif", [plain, stamp, figure])[0]
      return u.pathExtension == "gif" && CGImageSourceCreateWithURL(u as CFURL, nil).map(CGImageSourceGetCount) == 3
    }

    // Routing.
    func ids(_ urls: [URL], _ m: FanMode) -> [String] { Tools.available(for: urls, mode: m).map(\.id) }
    check(["edit.protect", "edit.unlock", "edit.pagenumbers", "edit.watermark", "edit.searchable"].allSatisfy(ids([doc], .edit).contains)
          && ["act.rename", "act.checksum"].allSatisfy(ids([doc, plain], .action).contains)
          && ids([plain], .convert).contains("img.icns") && ids([plain, stamp], .convert).contains("img.gif") && !ids([plain], .convert).contains("img.gif"),
          "extras routed")
    print("image edit dial:", Tools.available(for: [plain], mode: .edit).map(\.short))

    if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
      renderExtras(photo: figure, mask: (try? ImageTools.subjectMask(scene)) ?? mask, pdf: doc, files: [abc, figure, doc],
                   to: URL(fileURLWithPath: CommandLine.arguments[i + 1]).deletingPathExtension().appendingPathExtension("extras.png"))
    }
  }

  static func renderExtras(photo: URL, mask: CIImage, pdf: URL, files: [URL], to out: URL) {
    lemonPlainRender = true
    defer { lemonPlainRender = false }
    func shot<V: View>(_ v: V, _ w: CGFloat, _ h: CGFloat) -> CGImage? {
      let r = ImageRenderer(content: EditorChrome(content: v).frame(width: w, height: h))
      r.scale = 1
      return r.cgImage
    }
    let digests = Dictionary(uniqueKeysWithValues: files.map { u in (u, Result { try Checksum.digests(u) }) })
    let shots = [
      shot(RemoveBGEditor(urls: [photo], close: {}, mask: mask), 920, 600),
      shot(WatermarkEditor(urls: [photo], close: {}), 920, 640),
      shot(PageNumbersEditor(urls: [pdf], close: {}), 860, 620),
      shot(RenameEditor(urls: files, close: {}, rule: RenameRule(pattern: "file-{n}", pad: 2, letterCase: .lower)), 760, 600),
      shot(ProtectEditor(urls: [pdf], close: {}), 520, 470),
      shot(UnlockEditor(urls: [pdf], close: {}), 520, 340),
      shot(ChecksumEditor(urls: files, close: {}, digests: digests, compare: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"), 680, 460),
    ].compactMap { $0 }
    let sheet = ImageTools.bitmap(1900, 2700)!
    sheet.setFillColor(CGColor(srgbRed: 0.75, green: 0.82, blue: 0.9, alpha: 1))
    sheet.fill(CGRect(x: 0, y: 0, width: 1900, height: 2700))
    for (i, img) in shots.enumerated() {
      sheet.draw(img, in: CGRect(x: 20 + (i % 2) * 960, y: 2700 - (i / 2 + 1) * 670, width: img.width, height: img.height))
    }
    try? ImageTools.write(sheet.makeImage()!, props: [:], type: .png, to: out)
    print("rendered", out.path)
  }
}
