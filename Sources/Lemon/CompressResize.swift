import AppKit
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PDF compression

struct PDFCompressSettings: Equatable, Sendable {
  var quality = 0.6  // JPEG quality for images inside the PDF
  var dpi = 150      // images are downsampled to this resolution
  var targetBytes: Int? = nil
}

extension PDFTools {
  /// Redraws every page through a Quartz filter, as Preview's "Reduce File Size" does: images are re-encoded as JPEG at
  /// `quality` and downsampled to `dpi`. Text and vector art stay vector.
  // ponytail: links, form fields and annotations are not carried over by the redraw
  static func filtered(_ src: URL, quality: Double, dpi: Int, to out: URL) throws {
    guard let doc = CGPDFDocument(src as CFURL), doc.numberOfPages > 0 else { throw ToolError("Can't open \(src.lastPathComponent)") }
    if doc.isEncrypted && !doc.isUnlocked { throw ToolError("\(src.lastPathComponent) is password-protected") }
    let filterURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".qfilter")
    let plist: [String: Any] = [
      "Domains": ["Applications": true, "Printing": true], "FilterType": 1, "Name": "Lemon",
      "FilterData": ["ColorSettings": ["ImageSettings": [
        "Compression Quality": quality, "ImageCompression": "ImageJPEGCompress",
        "ImageScaleSettings": ["ImageResolution": dpi, "ImageScaleInterpolate": true, "ImageSizeMax": dpi * 17, "ImageSizeMin": 0],
      ]]],
    ]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: filterURL)
    defer { try? FileManager.default.removeItem(at: filterURL) }
    guard let filter = QuartzFilter(url: filterURL), let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else {
      throw ToolError("Couldn't compress \(src.lastPathComponent)")
    }
    filter.apply(to: ctx)
    for i in 1...doc.numberOfPages {
      guard let page = doc.page(at: i) else { continue }
      let media = page.getBoxRect(.mediaBox)
      let turned = page.rotationAngle % 180 != 0
      var rect = CGRect(origin: .zero, size: turned ? CGSize(width: media.height, height: media.width) : media.size)
      ctx.beginPage(mediaBox: &rect)
      ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: rect, rotate: 0, preserveAspectRatio: true))
      ctx.drawPDFPage(page)
      ctx.endPage()
    }
    filter.remove(from: ctx)
    ctx.closePDF()
  }

  /// Read from disk each time: URL.resourceValues caches, which hides a file rewritten in a loop.
  private static func fileSize(_ u: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0 }

  /// With a target size: the highest resolution, then the highest quality, that fits.
  static func compress(_ src: URL, settings s: PDFCompressSettings, to out: URL) throws {
    guard let target = s.targetBytes else { return try filtered(src, quality: s.quality, dpi: s.dpi, to: out) }
    for dpi in [300, 200, 150, 110, 72, 50, 36] {
      try filtered(src, quality: 0.05, dpi: dpi, to: out)
      guard fileSize(out) <= target else { continue }  // too big even at the lowest quality: drop resolution
      var lo = 0.05, hi = 0.92
      for _ in 0..<5 {
        let q = (lo + hi) / 2
        try filtered(src, quality: q, dpi: dpi, to: out)
        if fileSize(out) <= target { lo = q } else { hi = q }
      }
      try filtered(src, quality: lo, dpi: dpi, to: out)
      return
    }
    try? FileManager.default.removeItem(at: out)
    throw ToolError("Can't get \(src.lastPathComponent) under \(formatBytes(target)); its text and vector art can't shrink further")
  }

  static func compress(_ src: URL, settings: PDFCompressSettings) throws -> URL {
    let out = outputURL(for: src, ext: "pdf", suffix: "-small")
    try compress(src, settings: settings, to: out)
    return out
  }

  static func firstPage(_ u: URL, side: CGFloat = 900) -> NSImage? {
    guard let p = PDFDocument(url: u)?.page(at: 0) else { return nil }
    let b = p.bounds(for: .mediaBox).size
    let k = side / max(b.width, b.height, 1)
    return p.thumbnail(of: NSSize(width: b.width * k, height: b.height * k), for: .mediaBox)
  }
}

// MARK: - Image resize

struct ResizeSettings: Equatable, Sendable {
  enum Fit: String, CaseIterable, Sendable { case fit = "Fit", fill = "Fill", stretch = "Stretch" }
  var width: Int? = nil   // nil: follows the other side's scale
  var height: Int? = nil
  var percent: Double? = nil  // overrides width/height
  var fit = Fit.fit
  var allowEnlarge = true

  /// Output canvas size and the size the whole image is drawn at (larger than the canvas for Fill, which then crops).
  func sizes(for src: CGSize) -> (canvas: CGSize, drawn: CGSize) {
    guard src.width > 0, src.height > 0 else { return (.zero, .zero) }
    func cap(_ k: CGFloat) -> CGFloat { allowEnlarge ? k : min(k, 1) }
    func round(_ s: CGSize) -> CGSize { CGSize(width: max(1, s.width.rounded()), height: max(1, s.height.rounded())) }
    if let p = percent {
      let s = round(CGSize(width: src.width * cap(p / 100), height: src.height * cap(p / 100)))
      return (s, s)
    }
    switch (width, height) {
    case let (w?, h?):
      let box = CGSize(width: CGFloat(w), height: CGFloat(h))
      switch fit {
      case .stretch:
        let s = allowEnlarge ? box : CGSize(width: min(box.width, src.width), height: min(box.height, src.height))
        return (round(s), round(s))
      case .fit:
        let k = cap(min(box.width / src.width, box.height / src.height))
        let s = round(CGSize(width: src.width * k, height: src.height * k))
        return (s, s)
      case .fill:
        let k = max(box.width / src.width, box.height / src.height)
        if !allowEnlarge && k > 1 {
          let s = CGSize(width: min(box.width, src.width), height: min(box.height, src.height))
          return (round(s), round(CGSize(width: src.width, height: src.height)))
        }
        return (round(box), round(CGSize(width: src.width * k, height: src.height * k)))
      }
    case let (w?, nil):
      let k = cap(CGFloat(w) / src.width)
      let s = round(CGSize(width: src.width * k, height: src.height * k))
      return (s, s)
    case let (nil, h?):
      let k = cap(CGFloat(h) / src.height)
      let s = round(CGSize(width: src.width * k, height: src.height * k))
      return (s, s)
    case (nil, nil):
      return (src, src)
    }
  }
}

extension ImageTools {
  static func resized(_ img: CGImage, _ s: ResizeSettings) -> CGImage? {
    let (canvas, drawn) = s.sizes(for: CGSize(width: img.width, height: img.height))
    guard let ctx = bitmap(Int(canvas.width), Int(canvas.height)) else { return nil }
    ctx.interpolationQuality = .high
    // Fill: centred, overflow cropped by the canvas
    ctx.draw(img, in: CGRect(x: (canvas.width - drawn.width) / 2, y: (canvas.height - drawn.height) / 2, width: drawn.width, height: drawn.height))
    return ctx.makeImage()
  }

  static func resize(_ src: URL, _ s: ResizeSettings) throws -> URL {
    let (img, props) = try decode(src)
    guard let out = resized(img, s) else { throw ToolError("Couldn't resize \(src.lastPathComponent)") }
    return try save(out, from: src, props: keptMetadata(props), suffix: "-\(out.width)x\(out.height)")
  }
}

// MARK: - PDF compress window

struct PDFCompressEditor: View {
  enum Mode: String, CaseIterable { case quality = "Quality", target = "Target size" }
  enum Preset: String, CaseIterable {
    case high = "High", medium = "Medium", low = "Low"
    var values: (quality: Double, dpi: Int) { [(0.8, 200), (0.6, 150), (0.35, 100)][Self.allCases.firstIndex(of: self)!] }
  }
  static let resolutions = [300, 200, 150, 100, 72]

  let urls: [URL]
  let close: () -> Void
  private let original: NSImage?
  private let originalBytes: Int
  @State private var mode = Mode.quality
  @State private var quality = 0.6
  @State private var dpi = 150
  @State private var target = 1.0
  @State private var unit = CompressEditor.Unit.mb
  @State private var after: NSImage?
  @State private var newBytes = 0
  @State private var split: CGFloat = 0.5
  @State private var working = false
  @State private var error: String?

  init(urls: [URL], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    original = PDFTools.firstPage(urls[0])
    originalBytes = (try? urls[0].resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }

  private var settings: PDFCompressSettings {
    PDFCompressSettings(quality: quality, dpi: dpi,
                        targetBytes: mode == .target ? Int(target * (unit == .kb ? 1024 : 1_048_576)) : nil)
  }

  private var preset: Binding<Preset?> {
    Binding(get: { Preset.allCases.first { abs($0.values.quality - quality) < 0.001 && $0.values.dpi == dpi } },
            set: { if let p = $0 { quality = p.values.quality; dpi = p.values.dpi } })
  }

  private var saved: Int { originalBytes > 0 && newBytes > 0 ? Int((1 - Double(newBytes) / Double(originalBytes)) * 100) : 0 }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Compress PDF", subtitle: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) PDFs",
                   symbol: "arrow.down.right.and.arrow.up.left", close: close)
      HStack(alignment: .top, spacing: 18) {
        BeforeAfter(before: original, after: after, split: $split)
        controls.frame(width: 260)
      }
      HStack {
        if urls.count > 1 {
          Text("Preview shows page 1 of the first PDF; settings apply to all \(urls.count).").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(urls.count == 1 ? "Compress" : "Compress \(urls.count)") { apply() }
          .lemonButton(primary: true)
          .keyboardShortcut(.defaultAction)
          .disabled(error != nil)
      }
    }
    .task(id: settings) { await recompute() }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 16) {
      Chips(options: Mode.allCases, label: \.rawValue, selection: $mode)
      if mode == .quality {
        VStack(alignment: .leading, spacing: 6) {
          Chips(options: Preset.allCases.map { Optional($0) }, label: { $0?.rawValue ?? "" }, selection: preset)
          HStack {
            Text("Image quality").font(.system(size: 12, weight: .semibold))
            Spacer()
            Text("\(Int(quality * 100))%").font(.system(size: 12, weight: .semibold).monospacedDigit())
              .contentTransition(.numericText()).animation(.snappy, value: Int(quality * 100))
          }
          Slider(value: $quality, in: 0.1...0.95).tint(lemonYellow)
        }
        VStack(alignment: .leading, spacing: 6) {
          Text("Image resolution").font(.system(size: 12, weight: .semibold))
          Chips(options: Self.resolutions, label: { "\($0) dpi" }, selection: $dpi)
        }
      } else {
        VStack(alignment: .leading, spacing: 6) {
          Text("Make each PDF at most").font(.system(size: 12, weight: .semibold))
          HStack {
            TextField("Size", value: $target, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
            Chips(options: CompressEditor.Unit.allCases, label: \.rawValue, selection: $unit)
          }
          Text("Lemon lowers image quality, then resolution, until it fits. Text stays sharp.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      Spacer(minLength: 0)
      resultCard
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mode)
  }

  private var resultCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error {
        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
      } else {
        HStack(alignment: .firstTextBaseline) {
          Text(saved > 0 ? "−\(saved)%" : "\(saved)%")
            .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
            .contentTransition(.numericText(value: Double(saved)))
            .foregroundStyle(saved > 0 ? Color.green : Color.orange)
          Spacer()
          if working { ProgressView().controlSize(.small).transition(.opacity) }
        }
        HStack(spacing: 6) {
          Text(formatBytes(originalBytes)).strikethrough().foregroundStyle(.secondary)
          Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
          Text(newBytes > 0 ? formatBytes(newBytes) : "…").fontWeight(.semibold).contentTransition(.numericText())
        }
        .font(.system(size: 12).monospacedDigit())
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .lemonGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: newBytes)
  }

  /// Compresses the first PDF to a temp file for the real result size and page-1 preview; `.task(id:)` cancels stale runs.
  private func recompute() async {
    working = true
    try? await Task.sleep(nanoseconds: 350_000_000)
    if Task.isCancelled { return }
    let src = urls[0], s = settings
    let result: Result<(Int, NSImage?), Error> = await Task.detached {
      let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
      defer { try? FileManager.default.removeItem(at: tmp) }
      return Result {
        try PDFTools.compress(src, settings: s, to: tmp)
        return ((try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, PDFTools.firstPage(tmp))
      }
    }.value
    if Task.isCancelled { return }
    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
      switch result {
      case .success(let (bytes, img)): newBytes = bytes; after = img; error = nil
      case .failure(let e): error = e.localizedDescription
      }
      working = false
    }
  }

  private func apply() {
    let s = settings, files = urls
    close()
    Runner.perform("Compress PDF", symbol: "arrow.down.right.and.arrow.up.left") {
      try await Task.detached { try files.map { try PDFTools.compress($0, settings: s) } }.value
    }
  }
}

// MARK: - Resize window

struct ResizeEditor: View {
  enum Mode: String, CaseIterable { case pixels = "Pixels", percent = "Percent", presets = "Presets" }
  struct Preset: Hashable {
    let name: String, width: Int, height: Int
    static let all = [
      Preset(name: "4K", width: 3840, height: 2160), Preset(name: "1080p", width: 1920, height: 1080),
      Preset(name: "720p", width: 1280, height: 720), Preset(name: "Square post", width: 1080, height: 1080),
      Preset(name: "Portrait post", width: 1080, height: 1350), Preset(name: "Story", width: 1080, height: 1920),
      Preset(name: "Header", width: 1500, height: 500), Preset(name: "Thumbnail", width: 320, height: 320),
      Preset(name: "App icon", width: 1024, height: 1024),
    ]
  }

  let urls: [URL]
  let close: () -> Void
  private let image: NSImage?
  private let pixel: CGSize
  @State private var mode = Mode.pixels
  @State private var width: Int?
  @State private var height: Int?
  @State private var locked = true
  @State private var percent = 50.0
  @State private var preset: Preset?
  @State private var fit = ResizeSettings.Fit.fit
  @State private var allowEnlarge = false

  init(urls: [URL], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    image = ImageTools.preview(urls[0], maxPixel: 1400)
    pixel = ImageTools.orientedSize(urls[0])
    _width = State(initialValue: Int(pixel.width))
    _height = State(initialValue: Int(pixel.height))
  }

  private var settings: ResizeSettings {
    switch mode {
    case .percent: return ResizeSettings(percent: percent, allowEnlarge: allowEnlarge)
    case .presets:
      guard let p = preset else { return ResizeSettings() }
      return ResizeSettings(width: p.width, height: p.height, fit: fit, allowEnlarge: allowEnlarge)
    case .pixels:
      // locked: one side drives, the other follows the aspect ratio
      return locked ? ResizeSettings(width: width, allowEnlarge: allowEnlarge)
                    : ResizeSettings(width: width, height: height, fit: fit, allowEnlarge: allowEnlarge)
    }
  }

  private var result: CGSize { settings.sizes(for: pixel).canvas }
  private var unchanged: Bool { result == pixel || (mode == .presets && preset == nil) }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Resize", subtitle: subtitle(urls), symbol: "arrow.up.left.and.arrow.down.right", close: close)
      HStack(alignment: .top, spacing: 18) {
        preview
        controls.frame(width: 280)
      }
      HStack {
        Text("\(Int(pixel.width)) × \(Int(pixel.height))  →  \(Int(result.width)) × \(Int(result.height)) px")
          .font(.system(size: 13, weight: .semibold).monospacedDigit())
          .contentTransition(.numericText())
          .animation(.snappy, value: result)
        if urls.count > 1 { Text("· sizes shown for the first image").font(.caption).foregroundStyle(.secondary) }
        Spacer()
        Button(urls.count == 1 ? "Resize" : "Resize \(urls.count)") { apply() }
          .lemonButton(primary: true)
          .keyboardShortcut(.defaultAction)
          .disabled(unchanged)
      }
    }
  }

  /// The image scaled to show the new proportions; Fill shows the part that will be kept.
  private var preview: some View {
    GeometryReader { g in
      let (canvas, drawn) = settings.sizes(for: pixel)
      let box = aspectFit(canvas == .zero ? pixel : canvas, in: CGSize(width: g.size.width - 20, height: g.size.height - 20))
      let k = canvas.width > 0 ? box.width / canvas.width : 1
      ZStack {
        if let image {
          Image(nsImage: image).resizable()
            .frame(width: drawn.width * k, height: drawn.height * k)
        }
      }
      .frame(width: box.width, height: box.height)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
      .frame(width: g.size.width, height: g.size.height)
      .animation(.spring(response: 0.4, dampingFraction: 0.8), value: settings)
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 16) {
      Chips(options: Mode.allCases, label: \.rawValue, selection: $mode)
      switch mode {
      case .pixels: pixelControls
      case .percent:
        VStack(alignment: .leading, spacing: 6) {
          HStack {
            Text("Scale").font(.system(size: 12, weight: .semibold))
            Spacer()
            TextField("", value: $percent, format: .number).textFieldStyle(.roundedBorder).frame(width: 64)
            Text("%").font(.system(size: 12, weight: .semibold))
          }
          Slider(value: $percent, in: 5...400, step: 1).tint(lemonYellow)
        }
      case .presets:
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          ForEach(Preset.all, id: \.self) { p in
            Button {
              withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { preset = p }
            } label: {
              VStack(spacing: 1) {
                Text(p.name).font(.system(size: 12, weight: .semibold))
                Text("\(p.width)×\(p.height)").font(.system(size: 10).monospacedDigit()).opacity(0.7)
              }
              .frame(maxWidth: .infinity)
            }
            .lemonButton(primary: preset == p)
          }
        }
        if preset != nil { fitChips }
      }
      Toggle("Allow enlarging", isOn: $allowEnlarge).toggleStyle(.switch).tint(lemonYellow)
      Spacer(minLength: 0)
    }
    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mode)
  }

  private var pixelControls: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        field("Width", value: Binding(get: { width }, set: { w in
          width = w
          if locked, let w { height = Int((CGFloat(w) * pixel.height / max(pixel.width, 1)).rounded()) }
        }))
        Button {
          withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { locked.toggle() }
          if locked, let w = width { height = Int((CGFloat(w) * pixel.height / max(pixel.width, 1)).rounded()) }
        } label: {
          Image(systemName: locked ? "link" : "link.badge.plus").font(.system(size: 13, weight: .semibold)).frame(width: 22, height: 22)
        }
        .lemonButton(primary: locked, shape: .circle)
        .help(locked ? "Keeping the aspect ratio" : "Free width and height")
        .padding(.top, 16)
        field("Height", value: Binding(get: { height }, set: { h in
          height = h
          if locked, let h { width = Int((CGFloat(h) * pixel.width / max(pixel.height, 1)).rounded()) }
        }))
      }
      if !locked { fitChips }
    }
  }

  private var fitChips: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("When proportions differ").font(.system(size: 12, weight: .semibold))
      Chips(options: ResizeSettings.Fit.allCases, label: \.rawValue, selection: $fit)
    }
  }

  private func field(_ title: String, value: Binding<Int?>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      TextField(title, value: value, format: .number).textFieldStyle(.roundedBorder).frame(width: 96)
    }
  }

  private func apply() {
    let s = settings, files = urls
    close()
    Runner.perform("Resize", symbol: "arrow.up.left.and.arrow.down.right") {
      try await Task.detached { try files.map { try ImageTools.resize($0, s) } }.value
    }
  }
}
