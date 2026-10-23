import AppKit
import CoreImage
import PDFKit
import SwiftUI

// MARK: - Shared

/// Transparency backdrop.
struct Checkerboard: View {
  var body: some View {
    Canvas { ctx, size in
      let s: CGFloat = 10
      ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
      for y in 0..<Int(size.height / s) + 1 {
        for x in 0..<Int(size.width / s) + 1 where (x + y) % 2 == 0 {
          ctx.fill(Path(CGRect(x: CGFloat(x) * s, y: CGFloat(y) * s, width: s, height: s)), with: .color(Color(white: 0.85)))
        }
      }
    }
  }
}

@MainActor private func sectionTitle(_ s: String) -> some View {
  Text(s).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
}

@MainActor private func paneLabel(_ s: String) -> some View {
  Text(s).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.white)
    .padding(.horizontal, 8).padding(.vertical, 4)
    .lemonGlass(Capsule(), tint: .black.opacity(0.35))
}

/// Small glass capsule button (tokens, inline actions).
@MainActor private func pill(_ title: String, action: @escaping () -> Void) -> some View {
  Button(action: action) {
    Text(title).font(.system(size: 11, weight: .semibold, design: .monospaced))
      .padding(.horizontal, 9).padding(.vertical, 4)
      .lemonGlass(Capsule(), interactive: true)
  }
  .buttonStyle(.plain)
}

private extension View {
  func lemonSwitch() -> some View { toggleStyle(.switch).tint(lemonYellow).controlSize(.small) }
}

private func cgColor(_ c: Color) -> CGColor { NSColor(c).usingColorSpace(.sRGB)?.cgColor ?? CGColor(gray: 1, alpha: 1) }

/// First page of a PDF, or the image itself, for previews (max side `maxPixel`).
private func previewBase(_ u: URL, maxPixel: CGFloat) -> CGImage? {
  if FileKind(u) == .pdf {
    guard let page = PDFDocument(url: u)?.page(at: 0)?.pageRef else { return nil }
    let b = PDFTools.upright(page).box
    return PDFTools.render(page, scale: maxPixel / max(b.width, b.height, 1))
  }
  return ImageTools.previewCG(u, maxPixel: Int(maxPixel))
}

// MARK: - Remove background

struct RemoveBGEditor: View {
  static let swatches: [UInt32] = [0xFFFFFF, 0x1C1C1E, 0xFFD21A, 0x0A84FF, 0x34C759, 0xFF3B30]
  let urls: [URL]
  let close: () -> Void
  private let base: CGImage?
  @State private var mask: CIImage?
  @State private var failed: String?
  @State private var feather = 0.0
  @State private var replace = false
  @State private var color = Color.white
  @State private var result: NSImage?
  @State private var renderer = PreviewRenderer()

  init(urls: [URL], close: @escaping () -> Void, mask: CIImage? = nil) {
    self.urls = urls
    self.close = close
    base = ImageTools.previewCG(urls[0], maxPixel: 900)
    _mask = State(initialValue: mask)
    _result = State(initialValue: nsImage(mask.flatMap { m in base.flatMap { ImageTools.cutout($0, mask: m) } }))
  }

  private struct Key: Equatable { let feather: Double, replace: Bool, color: Color, ready: Bool }
  private var fill: CGColor? { replace ? cgColor(color) : nil }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Remove Background", subtitle: subtitle(urls), symbol: "person.and.background.dotted", close: close)
      HStack(alignment: .top, spacing: 16) {
        HStack(spacing: 12) {
          pane("BEFORE", nsImage(base), checker: false)
          pane("AFTER", result, checker: true)
            .overlay {
              if let failed {
                Label(failed, systemImage: "exclamationmark.triangle").font(.system(size: 12, weight: .medium)).padding(12)
                  .lemonGlass(Capsule())
              } else if mask == nil {
                ProgressView("Finding the subject…").controlSize(.small).padding(14).lemonGlass(RoundedRectangle(cornerRadius: 14))
              }
            }
        }
        Inspector { inspector }.frame(width: 240)
      }
      Footer(title: urls.count == 1 ? "Save PNG" : "Save \(urls.count)", disabled: mask == nil, apply: apply) {
        if urls.count > 1 { Text("Each image gets its own cut-out").font(.caption).foregroundStyle(.secondary) }
      }
    }
    .task { await findSubject() }
    .onChange(of: Key(feather: feather, replace: replace, color: color, ready: mask != nil)) { _, k in
      guard let m = mask, let img = base else { return }
      let f = fill
      renderer.submit({ ImageTools.cutout(img, mask: m, feather: k.feather, fill: f) }) { out in result = nsImage(out) }
    }
  }

  private func pane(_ label: String, _ img: NSImage?, checker: Bool) -> some View {
    let aspect = base.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? 1
    return ZStack {
      if checker { Checkerboard() }
      if let img { Image(nsImage: img).resizable() }
    }
    .aspectRatio(aspect, contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .overlay(alignment: .topLeading) { paneLabel(label).padding(8) }
    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var inspector: some View {
    VStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 10) {
        sectionTitle("BACKGROUND")
        Chips(options: [false, true], label: { $0 ? "Color" : "Transparent" }, selection: $replace)
        if replace {
          HStack(spacing: 6) {
            ForEach(Self.swatches, id: \.self) { hex in
              let c = Color(cgColor: FrameBackground.color(hex))
              Circle().fill(c).frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12)))
                .padding(2)
                .overlay { if cgColor(color) == cgColor(c) { Circle().strokeBorder(lemonYellow, lineWidth: 2.5) } }
                .onTapGesture { color = c }
            }
            ColorPicker("", selection: $color, supportsOpacity: false).labelsHidden()
          }
          .transition(.opacity)
        }
      }
      .card()
      VStack(alignment: .leading, spacing: 10) {
        sectionTitle("EDGE")
        LabeledSlider(label: "Feather", value: $feather, range: 0...2, format: { String(format: "%.1f", $0) })
        Text("Softens the cut-out edge, e.g. for hair.").font(.caption).foregroundStyle(.secondary)
      }
      .card()
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: replace)
  }

  private func findSubject() async {
    guard mask == nil, let img = base else { return }
    let r = await Task.detached { Result { try ImageTools.subjectMask(img) } }.value
    switch r {
    case .success(let m): mask = m
    case .failure(let e): failed = e.localizedDescription
    }
  }

  private func apply() {
    let k = feather, f = fill, files = urls
    close()
    Runner.perform("Remove background", symbol: "person.and.background.dotted") {
      try await Task.detached { try files.map { try ImageTools.removeBackground($0, feather: k, fill: f) } }.value
    }
  }
}

// MARK: - Watermark

struct WatermarkEditor: View {
  enum Kind: String, CaseIterable { case text = "Text", image = "Image" }
  static let colors: [UInt32] = [0x808080, 0xFFFFFF, 0x1C1C1E, 0xFF3B30, 0x0A84FF]
  let urls: [URL]
  let close: () -> Void
  private let base: CGImage?
  @State private var style = WatermarkStyle()
  @State private var kind = Kind.text
  @State private var picked: URL?
  @State private var mark: CGImage?
  @State private var result: NSImage?
  @State private var renderer = PreviewRenderer()

  init(urls: [URL], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    base = previewBase(urls[0], maxPixel: 1000)
    _result = State(initialValue: nsImage(base.flatMap { Watermark.watermarked($0, WatermarkStyle(), mark: nil) }))
  }

  private var effective: WatermarkStyle {
    var s = style
    s.image = kind == .image ? picked : nil
    if kind == .image && picked == nil { s.text = "" }
    return s
  }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Watermark", subtitle: subtitle(urls), symbol: "signature", close: close)
      HStack(alignment: .top, spacing: 16) {
        Group {
          if let result { Image(nsImage: result).resizable().scaledToFit().shadow(color: .black.opacity(0.18), radius: 10, y: 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        Inspector { inspector }.frame(width: 260)
      }
      Footer(title: urls.count == 1 ? "Save" : "Save \(urls.count)", disabled: effective.text.isEmpty && effective.image == nil, apply: apply) {
        if urls.count > 1 { Text("Applies to all \(urls.count) files").font(.caption).foregroundStyle(.secondary) }
      }
    }
    .onChange(of: effective) { _, s in
      let img = base, m = s.image == nil ? nil : mark
      renderer.submit({ img.flatMap { Watermark.watermarked($0, s, mark: m) } }) { out in result = nsImage(out) }
    }
  }

  private var inspector: some View {
    VStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 10) {
        sectionTitle("MARK")
        Chips(options: Kind.allCases, label: \.rawValue, selection: $kind)
        if kind == .text {
          TextField("Text", text: $style.text).textFieldStyle(.roundedBorder)
          HStack(spacing: 6) {
            ForEach(Self.colors, id: \.self) { c in
              Circle().fill(Color(cgColor: FrameBackground.color(c))).frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12)))
                .padding(2)
                .overlay { if c == style.color { Circle().strokeBorder(lemonYellow, lineWidth: 2.5) } }
                .onTapGesture { style.color = c }
            }
          }
        } else {
          HStack {
            Button(picked == nil ? "Choose image…" : "Change…", action: pickImage).lemonButton()
            if let picked { Text(picked.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
          }
        }
      }
      .card()
      VStack(alignment: .leading, spacing: 10) {
        sectionTitle("POSITION")
        HStack(alignment: .center, spacing: 14) {
          grid
          Toggle("Tiled", isOn: Binding(get: { style.position == .tiled }, set: { style.position = $0 ? .tiled : .center }))
            .lemonSwitch()
        }
      }
      .card()
      VStack(alignment: .leading, spacing: 10) {
        LabeledSlider(label: "Opacity", value: $style.opacity, range: 0.05...1, reset: 0.3)
        LabeledSlider(label: "Size", value: $style.size, range: 0.05...1, reset: 0.5)
        LabeledSlider(label: "Rotation", value: $style.rotation, range: -90...90, reset: 30, format: { "\(Int($0.rounded()))°" })
      }
      .card()
    }
    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: kind)
  }

  /// 3x3 anchor picker.
  private var grid: some View {
    VStack(spacing: 4) {
      ForEach(0..<3, id: \.self) { r in
        HStack(spacing: 4) {
          ForEach(0..<3, id: \.self) { c in
            let p = WatermarkStyle.Position(rawValue: r * 3 + c)!
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .fill(style.position == p ? lemonYellow : Color.primary.opacity(0.12))
              .frame(width: 22, height: 16)
              .contentShape(Rectangle())
              .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { style.position = p } }
          }
        }
      }
    }
    .padding(6)
    .lemonGlass(RoundedRectangle(cornerRadius: 9, style: .continuous))
    .opacity(style.position == .tiled ? 0.45 : 1)
  }

  private func pickImage() {
    let p = NSOpenPanel()
    p.allowedContentTypes = [.image]
    p.level = .modalPanel  // editor windows float
    guard p.runModal() == .OK, let u = p.url else { return }
    mark = ImageTools.previewCG(u, maxPixel: 800)
    picked = u
  }

  private func apply() {
    let s = effective, files = urls
    close()
    Runner.perform("Watermark", symbol: "signature") { try await Task.detached { try files.map { try Watermark.apply($0, s) } }.value }
  }
}

// MARK: - Page numbers

struct PageNumbersEditor: View {
  let urls: [URL]
  let close: () -> Void
  private let pages: [CGPDFPage]
  @State private var style = PageNumberStyle()
  @State private var result: NSImage?
  @State private var renderer = PreviewRenderer()

  init(urls: [URL], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    pages = PDFDocument(url: urls[0]).map { PDFTools.pages($0).compactMap(\.pageRef) } ?? []
    _result = State(initialValue: nsImage(Self.render(pages, PageNumberStyle())))
  }

  /// Shows the first numbered page.
  private static func render(_ pages: [CGPDFPage], _ s: PageNumberStyle) -> CGImage? {
    let i = s.skipFirst && pages.count > 1 ? 1 : 0
    guard i < pages.count else { return nil }
    let page = pages[i]
    let (box, t) = PDFTools.upright(page)
    let k = 900 / max(box.width, box.height, 1)
    guard let c = ImageTools.bitmap(Int(box.width * k), Int(box.height * k)) else { return nil }
    c.setFillColor(CGColor(gray: 1, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height))
    c.scaleBy(x: k, y: k)
    c.saveGState()
    c.concatenate(t)
    c.drawPDFPage(page)
    c.restoreGState()
    s.draw(in: c, box: box, index: i, count: pages.count)
    return c.makeImage()
  }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Page Numbers", subtitle: subtitle(urls), symbol: "number", close: close)
      HStack(alignment: .top, spacing: 16) {
        Group {
          if let result { Image(nsImage: result).resizable().scaledToFit().shadow(color: .black.opacity(0.18), radius: 10, y: 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        Inspector { inspector }.frame(width: 270)
      }
      Footer(title: urls.count == 1 ? "Save" : "Save \(urls.count)", disabled: pages.isEmpty, apply: apply) {
        Text("\(pages.count) page\(pages.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
      }
    }
    .onChange(of: style) { _, s in
      let p = pages
      renderer.submit({ Self.render(p, s) }) { out in result = nsImage(out) }
    }
  }

  private var inspector: some View {
    VStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 10) {
        sectionTitle("POSITION")
        Chips(options: [true, false], label: { $0 ? "Top" : "Bottom" }, selection: $style.top)
        Chips(options: PageNumberStyle.Align.allCases, label: \.rawValue, selection: $style.align)
      }
      .card()
      VStack(alignment: .leading, spacing: 10) {
        sectionTitle("FORMAT")
        Chips(options: PageNumberStyle.Format.allCases, label: \.rawValue, selection: $style.format)
        LabeledSlider(label: "Font size", value: $style.fontSize, range: 6...28, reset: 11, format: { "\(Int($0.rounded())) pt" })
      }
      .card()
      VStack(alignment: .leading, spacing: 10) {
        Stepper("Start at \(style.start)", value: $style.start, in: 0...9999).font(.system(size: 12, weight: .medium))
        Toggle("Skip first page", isOn: $style.skipFirst).font(.system(size: 12, weight: .medium)).lemonSwitch()
      }
      .card()
    }
  }

  private func apply() {
    let s = style, files = urls
    close()
    Runner.perform("Page numbers", symbol: "number") { try await Task.detached { try files.map { try PDFTools.number($0, s) } }.value }
  }
}

// MARK: - Protect and unlock

struct ProtectEditor: View {
  let urls: [URL]
  let close: () -> Void
  @State private var user = ""
  @State private var owner = ""
  @State private var printing = true
  @State private var copying = false

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Protect PDF", subtitle: subtitle(urls), symbol: "lock.doc", close: close)
      VStack(alignment: .leading, spacing: 8) {
        sectionTitle("OPEN PASSWORD")
        SecureField("Needed to open the PDF (optional)", text: $user).textFieldStyle(.roundedBorder)
      }
      .card()
      VStack(alignment: .leading, spacing: 10) {
        sectionTitle("PERMISSIONS")
        SecureField("Permissions password", text: $owner).textFieldStyle(.roundedBorder)
        Toggle("Allow printing", isOn: $printing).lemonSwitch()
        Toggle("Allow copying text and images", isOn: $copying).lemonSwitch()
        Text(owner.isEmpty ? "Without a permissions password, the open password also lifts these limits." : "The permissions password lifts these limits.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .font(.system(size: 12, weight: .medium))
      .card()
      Spacer(minLength: 0)
      Footer(title: "Protect", disabled: user.isEmpty && owner.isEmpty, apply: apply) {
        Label("Saves a protected copy", systemImage: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func apply() {
    let u = user, o = owner, p = printing, c = copying, files = urls
    close()
    Runner.perform("Protect PDF", symbol: "lock.doc") {
      try await Task.detached { try files.map { try PDFTools.protect($0, user: u, owner: o, allowPrinting: p, allowCopying: c) } }.value
    }
  }
}

struct UnlockEditor: View {
  let urls: [URL]
  let close: () -> Void
  @State private var password = ""
  @State private var error: String?
  @State private var working = false

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Unlock PDF", subtitle: subtitle(urls), symbol: "lock.open", close: close)
      VStack(alignment: .leading, spacing: 8) {
        sectionTitle("PASSWORD")
        SecureField("Open or permissions password", text: $password).textFieldStyle(.roundedBorder).onSubmit(unlock)
        if let error {
          Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.red).transition(.opacity)
        }
      }
      .card()
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: error)
      Spacer(minLength: 0)
      Footer(title: "Unlock", disabled: working, apply: unlock) {
        if working { ProgressView().controlSize(.small) }
        Label("Saves a copy without a password", systemImage: "doc.on.doc").font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func unlock() {
    let pw = password, files = urls
    working = true
    Task {
      let r = await Task.detached { Result { try files.map { try PDFTools.unlock($0, password: pw) } } }.value
      working = false
      switch r {
      case .success(let outs):
        close()
        Runner.perform("Unlock PDF", symbol: "lock.open", quiet: true) { outs }
      case .failure(let e):
        error = e.localizedDescription
        password = ""
      }
    }
  }
}

// MARK: - Batch rename

struct RenameEditor: View {
  let urls: [URL]
  let close: () -> Void
  @State private var rule = RenameRule(pattern: "{name}")

  init(urls: [URL], close: @escaping () -> Void, rule: RenameRule = RenameRule(pattern: "{name}")) {
    self.urls = urls
    self.close = close
    _rule = State(initialValue: rule)
  }

  // ponytail: re-plans (a stat per file) on every keystroke; debounce if thousands of files ever get dropped
  private var plan: [RenameItem] { Rename.plan(urls, rule) }

  var body: some View {
    let items = plan
    let problems = items.filter { $0.problem != nil }.count, changes = items.filter(\.changed).count
    VStack(spacing: 14) {
      EditorHeader(title: "Batch Rename", subtitle: subtitle(urls).replacingOccurrences(of: "images", with: "files"),
                   symbol: "character.cursor.ibeam", close: close)
      HStack(alignment: .top, spacing: 16) {
        Inspector { controls }.frame(width: 290)
        Inspector {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { row($0) }
          }
          .card()
        }
      }
      Footer(title: changes <= 1 ? "Rename" : "Rename \(changes)", disabled: problems > 0 || changes == 0, apply: apply) {
        if problems > 0 {
          Label("\(problems) conflict\(problems == 1 ? "" : "s")", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 12, weight: .medium)).foregroundStyle(.red)
        } else {
          Text(changes == 0 ? "No changes" : "\(changes) of \(items.count) will change").font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }

  private var controls: some View {
    VStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        sectionTitle("NAME")
        TextField("Pattern", text: $rule.pattern).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
        HStack(spacing: 6) {
          ForEach(["{name}", "{n}", "{date}"], id: \.self) { t in pill(t) { rule.pattern += t } }
        }
      }
      .card()
      VStack(alignment: .leading, spacing: 8) {
        sectionTitle("COUNTER {n}")
        Stepper("Start at \(rule.start)", value: $rule.start, in: 0...99_999).font(.system(size: 12, weight: .medium))
        Chips(options: [1, 2, 3, 4], label: { String(repeating: "0", count: $0 - 1) + "1" }, selection: $rule.pad)
      }
      .card()
      VStack(alignment: .leading, spacing: 8) {
        sectionTitle("FIND & REPLACE")
        TextField("Find", text: $rule.find).textFieldStyle(.roundedBorder)
        TextField("Replace with", text: $rule.replace).textFieldStyle(.roundedBorder)
      }
      .card()
      VStack(alignment: .leading, spacing: 8) {
        sectionTitle("CASE")
        Chips(options: RenameRule.LetterCase.allCases, label: \.rawValue, selection: $rule.letterCase)
      }
      .card()
    }
  }

  private func row(_ it: RenameItem) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(it.from.lastPathComponent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      HStack(spacing: 6) {
        Image(systemName: it.problem != nil ? "exclamationmark.triangle.fill" : "arrow.turn.down.right")
          .font(.system(size: 10, weight: .bold))
          .foregroundStyle(it.problem != nil ? Color.red : it.changed ? lemonYellow : Color.secondary)
        Text(it.to.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
          .foregroundStyle(it.problem != nil ? Color.red : it.changed ? Color.primary : Color.secondary)
        Spacer(minLength: 4)
        if let p = it.problem { Text(p).font(.system(size: 10, weight: .semibold)).foregroundStyle(.red) }
      }
    }
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func apply() {
    let r = rule, files = urls
    close()
    Runner.perform("Rename", symbol: "character.cursor.ibeam") { try Rename.apply(Rename.plan(files, r)) }
  }
}

// MARK: - Checksum

struct ChecksumEditor: View {
  let urls: [URL]
  let close: () -> Void
  @State private var algo = Checksum.sha256
  @State private var digests: [URL: Result<[Checksum: String], Error>]
  @State private var compare = ""
  @State private var copied: URL?

  init(urls: [URL], close: @escaping () -> Void, digests: [URL: Result<[Checksum: String], Error>] = [:], compare: String = "") {
    self.urls = urls
    self.close = close
    _digests = State(initialValue: digests)
    _compare = State(initialValue: compare)
  }

  private func hash(_ u: URL) -> String? { (try? digests[u]?.get())?[algo] }
  private var wanted: String { Checksum.normalized(compare) }
  private var match: URL? { wanted.isEmpty ? nil : urls.first { hash($0) == wanted } }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Checksum", subtitle: subtitle(urls).replacingOccurrences(of: "images", with: "files"), symbol: "checkmark.shield", close: close)
      HStack {
        Chips(options: Checksum.allCases, label: \.rawValue, selection: $algo)
        Spacer()
      }
      Inspector {
        VStack(spacing: 8) { ForEach(urls, id: \.self, content: row) }
      }
      compareField
    }
    .task { await computeAll() }
  }

  private func row(_ u: URL) -> some View {
    let h = hash(u)
    return HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(u.lastPathComponent).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        switch digests[u] {
        case .none: ProgressView().controlSize(.small)
        case .failure(let e): Text(e.localizedDescription).font(.system(size: 11)).foregroundStyle(.red)
        case .success: Text(h ?? "").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(2).foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
      if let h {
        Button { copy(h, u) } label: {
          Image(systemName: copied == u ? "checkmark" : "doc.on.doc").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
            .contentTransition(.symbolEffect(.replace))
        }
        .lemonButton(shape: .circle)
        .help("Copy \(algo.rawValue)")
      }
    }
    .card()
    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(match == u ? Color.green : .clear, lineWidth: 2))
  }

  private var compareField: some View {
    let state: Bool? = wanted.isEmpty ? nil : match != nil
    return HStack(spacing: 10) {
      Image(systemName: state == nil ? "equal.circle" : state! ? "checkmark.circle.fill" : "xmark.circle.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(state == nil ? Color.secondary : state! ? Color.green : Color.red)
        .contentTransition(.symbolEffect(.replace))
      TextField("Paste a hash to compare", text: $compare).textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
      if let state {
        Text(state ? (urls.count > 1 ? "Matches \(match!.lastPathComponent)" : "Match") : "No match")
          .font(.system(size: 12, weight: .semibold)).foregroundStyle(state ? Color.green : Color.red).lineLimit(1)
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 11)
    .lemonGlass(RoundedRectangle(cornerRadius: 14, style: .continuous),
                tint: state == nil ? nil : state! ? Color.green.opacity(0.3) : Color.red.opacity(0.28))
    .animation(.easeOut(duration: 0.15), value: state)
  }

  private func copy(_ h: String, _ u: URL) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(h, forType: .string)
    withAnimation { copied = u }
  }

  private func computeAll() async {
    for u in urls where digests[u] == nil {
      digests[u] = await Task.detached { Result { try Checksum.digests(u) } }.value
    }
  }
}
