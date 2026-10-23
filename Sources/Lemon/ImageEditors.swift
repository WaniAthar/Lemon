import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared

/// Groups neighbouring glass so it blends and morphs on macOS 26+.
struct GlassGroup<Content: View>: View {
  var spacing: CGFloat = 10
  @ViewBuilder let content: Content

  var body: some View {
    if #available(macOS 26.0, *), !lemonPlainRender { GlassEffectContainer(spacing: spacing) { content } } else { content }
  }
}

/// Scrolls in a window; offscreen self-test renders can't draw NSScrollView, so it lays out flat there.
struct Inspector<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    if lemonPlainRender { content.frame(minHeight: 0, maxHeight: .infinity, alignment: .top).clipped() } else { ScrollView { content }.scrollIndicators(.never) }
  }
}

extension View {
  /// Interactive glass for floating controls over the image.
  @MainActor func controlGlass<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
    lemonGlass(shape, tint: tint, interactive: true)
  }

  /// Inspector card on glass.
  @MainActor func card() -> some View {
    padding(14).frame(maxWidth: .infinity, alignment: .leading).lemonGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
  }
}

extension ImageTools {
  static func previewCG(_ src: URL, maxPixel: Int) -> CGImage? {
    preview(src, maxPixel: maxPixel)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
  }
}

func nsImage(_ cg: CGImage?) -> NSImage? { cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } }

/// Live previews: renders off the main thread as fast as it can, always on the newest request.
/// While a render runs, newer requests replace the queued one, so dragging a slider never waits or stalls.
@MainActor final class PreviewRenderer {
  private var running = false
  private var pending: (work: @Sendable () -> CGImage?, done: @MainActor (CGImage?) -> Void)?

  func submit(_ work: @escaping @Sendable () -> CGImage?, done: @escaping @MainActor (CGImage?) -> Void) {
    pending = (work, done)
    if !running { pump() }
  }

  private func pump() {
    guard let next = pending else { running = false; return }
    pending = nil
    running = true
    Task {
      let img = await Task.detached(operation: next.work).value
      next.done(img)
      pump()
    }
  }
}

struct LabeledSlider: View {
  let label: String
  @Binding var value: Double
  var range: ClosedRange<Double> = 0...1
  var reset = 0.0
  var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))" }

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack {
        Text(label).font(.system(size: 12, weight: .medium))
          .help("Double-click to reset")
          .onTapGesture(count: 2) { withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { value = reset } }
        Spacer()
        Text(format(value)).font(.system(size: 11, weight: .semibold).monospacedDigit())
          .foregroundStyle(value == reset ? .secondary : .primary)
          .contentTransition(.numericText(value: value))
          .animation(.snappy, value: value)
      }
      Slider(value: $value, in: range).tint(lemonYellow).controlSize(.small)
    }
  }
}

struct Footer<Leading: View>: View {
  let title: String
  var disabled = false
  let apply: () -> Void
  @ViewBuilder let leading: Leading

  var body: some View {
    HStack(spacing: 10) {
      leading
      Spacer()
      Button(title, action: apply)
        .lemonButton(primary: true)
        .keyboardShortcut(.defaultAction)
        .disabled(disabled)
    }
  }
}

@MainActor private func glassTag(_ s: String) -> some View {
  Text(s).font(.system(size: 10, weight: .bold)).tracking(0.8)
    .padding(.horizontal, 10).padding(.vertical, 5)
    .lemonGlass(Capsule(), tint: .black.opacity(0.25))
}

// MARK: - Edit (adjustments)

struct AdjustEditor: View {
  typealias Row = (name: String, key: WritableKeyPath<Adjustments, Double>, bipolar: Bool)
  static let groups: [(String, [Row])] = [
    ("Light", [("Exposure", \.exposure, true), ("Brightness", \.brightness, true), ("Contrast", \.contrast, true),
               ("Highlights", \.highlights, true), ("Shadows", \.shadows, true), ("Whites", \.whites, true), ("Blacks", \.blacks, true)]),
    ("Color", [("Temperature", \.temperature, true), ("Tint", \.tint, true), ("Saturation", \.saturation, true),
               ("Vibrance", \.vibrance, true), ("Hue", \.hue, true)]),
    ("Detail & Effects", [("Sharpness", \.sharpness, false), ("Clarity", \.clarity, true), ("Noise reduction", \.noise, false),
                          ("Vignette", \.vignette, true), ("Grain", \.grain, false), ("Fade", \.fade, false), ("Blur", \.blur, false)]),
  ]

  let urls: [URL]
  let close: () -> Void
  private let base: CGImage?
  private let scale: CGFloat
  @State private var a = Adjustments()
  @State private var result: NSImage?
  @State private var comparing = false
  @State private var renderer = PreviewRenderer()

  init(urls: [URL], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    base = ImageTools.previewCG(urls[0], maxPixel: 1100)
    let full = ImageTools.orientedSize(urls[0])
    scale = base.map { CGFloat(max($0.width, $0.height)) / max(full.width, full.height, 1) } ?? 1
  }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Edit", subtitle: subtitle(urls), symbol: "slider.horizontal.3", close: close)
      HStack(alignment: .top, spacing: 16) {
        preview
        Inspector {
          VStack(spacing: 12) {
            ForEach(Self.groups, id: \.0) { g in
              VStack(alignment: .leading, spacing: 10) {
                Text(g.0.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
                ForEach(g.1, id: \.name) { r in LabeledSlider(label: r.name, value: $a[dynamicMember: r.key], range: r.bipolar ? -1...1 : 0...1) }
              }
              .card()
            }
          }
        }
        .frame(width: 260)
      }
      Footer(title: urls.count == 1 ? "Save" : "Save \(urls.count)", disabled: a == Adjustments(), apply: apply) {
        Button("Reset all") { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { a = Adjustments() } }
          .lemonButton()
          .disabled(a == Adjustments())
        if urls.count > 1 { Text("Applies to all \(urls.count) images").font(.caption).foregroundStyle(.secondary) }
      }
    }
    .onChange(of: a) { _, new in
      let img = base, s = scale
      renderer.submit({ img.flatMap { ImageTools.adjusted($0, new, scale: s) } }) { out in result = nsImage(out) }
    }
  }

  private var preview: some View {
    let shown = comparing || a == Adjustments() ? nsImage(base) : result ?? nsImage(base)
    return ZStack(alignment: .top) {
      if let shown { Image(nsImage: shown).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous)) }
      glassTag(comparing ? "ORIGINAL" : "HOLD TO COMPARE").padding(10)
        .animation(.easeOut(duration: 0.12), value: comparing)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in comparing = true }.onEnded { _ in comparing = false })
  }

  private func apply() {
    let s = a, files = urls
    close()
    Runner.perform("Edit", symbol: "slider.horizontal.3") { try await Task.detached { try files.map { try ImageTools.adjust($0, s) } }.value }
  }
}

// MARK: - Add BG (frame)

struct FrameEditor: View {
  let urls: [URL]
  let close: () -> Void
  private let base: CGImage?
  @State private var style = FrameStyle()
  @State private var result: NSImage?
  @State private var renderer = PreviewRenderer()
  @Namespace private var ns

  init(urls: [URL], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    base = ImageTools.previewCG(urls[0], maxPixel: 900)
    _result = State(initialValue: nsImage(base.flatMap { ImageTools.framed($0, FrameStyle()) }))
  }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Add Background", subtitle: subtitle(urls), symbol: "photo.artframe", close: close)
      HStack(alignment: .top, spacing: 16) {
        Group {
          if let result { Image(nsImage: result).resizable().scaledToFit().shadow(color: .black.opacity(0.18), radius: 10, y: 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        Inspector { inspector }.frame(width: 260)
      }
      Footer(title: urls.count == 1 ? "Save" : "Save \(urls.count)", apply: apply) {
        if urls.count > 1 { Text("Applies to all \(urls.count) images").font(.caption).foregroundStyle(.secondary) }
      }
    }
    .onChange(of: style) { _, s in
      let img = base
      renderer.submit({ img.flatMap { ImageTools.framed($0, s) } }) { out in withAnimation(.easeOut(duration: 0.15)) { result = nsImage(out) } }
    }
  }

  private var inspector: some View {
    VStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 10) {
        Text("BACKGROUND").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
        let all = FrameBackground.gradients.indices.map(FrameBackground.gradient) + FrameBackground.solids.indices.map(FrameBackground.solid)
        VStack(alignment: .leading, spacing: 8) {  // plain stacks, not a lazy grid, so the offscreen render shows every swatch
          ForEach(0..<(all.count + 6) / 6, id: \.self) { row in
            HStack(spacing: 6) {
              ForEach(row * 6..<min(row * 6 + 6, all.count + 1), id: \.self) { i in
                if i < all.count { swatch(all[i]) } else { picker }
              }
            }
          }
        }
      }
      .card()
      VStack(alignment: .leading, spacing: 10) {
        LabeledSlider(label: "Padding", value: $style.padding, range: 0...0.3, reset: 0.08)
        LabeledSlider(label: "Corner radius", value: $style.corner, range: 0...0.12, reset: 0.03)
        LabeledSlider(label: "Shadow", value: $style.shadow, reset: 0.5)
      }
      .card()
      VStack(alignment: .leading, spacing: 8) {
        Text("CANVAS").font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
        Chips(options: FrameStyle.Ratio.allCases, label: \.rawValue, selection: $style.ratio)
      }
      .card()
    }
  }

  private var ring: some View {
    Circle().strokeBorder(lemonYellow, lineWidth: 2.5).frame(width: 38, height: 38).matchedGeometryEffect(id: "ring", in: ns)
  }

  private var picker: some View {
    Button(action: pickImage) {
      Image(systemName: "photo.badge.plus").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28)
    }
    .lemonButton(shape: .circle)
    .overlay { if case .image = style.background { ring } }
    .frame(width: 34, height: 34)
    .help("Background image…")
  }

  private func swatch(_ bg: FrameBackground) -> some View {
    let fill: AnyShapeStyle = switch bg {
    case .gradient(let i): AnyShapeStyle(LinearGradient(colors: FrameBackground.gradients[i].stops.map { Color(cgColor: FrameBackground.color($0)) },
                                                        startPoint: .topLeading, endPoint: .bottomTrailing))
    case .solid(let i): AnyShapeStyle(Color(cgColor: FrameBackground.color(FrameBackground.solids[i])))
    case .image: AnyShapeStyle(Color.gray)
    }
    let name = if case .gradient(let i) = bg { FrameBackground.gradients[i].name } else { "" }
    return Circle().fill(fill).frame(width: 28, height: 28)
      .overlay(Circle().strokeBorder(Color.black.opacity(0.1)))
      .overlay { if style.background == bg { ring } }
      .frame(width: 34, height: 34)
      .contentShape(Circle())
      .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { style.background = bg } }
      .help(name)
  }

  private func pickImage() {
    let p = NSOpenPanel()
    p.allowedContentTypes = [.image]
    p.level = .modalPanel  // editor windows float
    if p.runModal() == .OK, let u = p.url { withAnimation { style.background = .image(u) } }
  }

  private func apply() {
    let s = style, files = urls
    close()
    Runner.perform("Add background", symbol: "photo.artframe") { try await Task.detached { try files.map { try ImageTools.frame($0, s) } }.value }
  }
}

// MARK: - Annotate

struct AnnotateEditor: View {
  static let colors: [UInt32] = [0xFF3B30, 0xFF9500, 0xFFD21A, 0x34C759, 0x0A84FF, 0xAF52DE, 0x1C1C1E, 0xFFFFFF]
  static let symbols: [Mark.Kind: String] = [.pen: "pencil.tip", .highlighter: "highlighter", .arrow: "arrow.up.right",
                                             .rect: "rectangle", .ellipse: "circle", .text: "textformat"]
  let urls: [URL]
  let close: () -> Void
  private let image: NSImage?
  private let pixel: CGSize
  @State private var marks: [Mark] = []
  @State private var redo: [Mark] = []
  @State private var current: Mark?
  @State private var kind = Mark.Kind.pen
  @State private var color: UInt32 = 0xFF3B30
  @State private var size = 4.0
  @State private var text = "Text"
  @Namespace private var ns

  init(urls: [URL], marks: [Mark] = [], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    _marks = State(initialValue: marks)
    image = ImageTools.preview(urls[0], maxPixel: 1800)
    pixel = ImageTools.orientedSize(urls[0])
  }

  private var unit: CGFloat { max(pixel.width, pixel.height) / 600 }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Annotate", subtitle: urls[0].lastPathComponent, symbol: "pencil.tip.crop.circle", close: close)
      GeometryReader { g in canvas(g.size) }
      HStack(spacing: 12) {
        HStack(spacing: 4) {
          ForEach(Self.colors, id: \.self) { c in
            Circle().fill(Color(cgColor: FrameBackground.color(c))).frame(width: 20, height: 20)
              .overlay(Circle().strokeBorder(Color.black.opacity(0.15)))
              .padding(3)
              .overlay { if c == color { Circle().strokeBorder(lemonYellow, lineWidth: 2.5).matchedGeometryEffect(id: "c", in: ns) } }
              .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { color = c } }
          }
        }
        LabeledSlider(label: "Size", value: $size, range: 1...16, reset: 4, format: { "\(Int($0))" }).frame(width: 130)
        if kind == .text {
          TextField("Text", text: $text).textFieldStyle(.roundedBorder).frame(width: 120)
            .transition(.opacity.combined(with: .move(edge: .leading)))
        }
        Spacer()
        Button { undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 30, height: 30) }
          .lemonButton(shape: .circle).keyboardShortcut("z").disabled(marks.isEmpty)
        Button { redoLast() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 30, height: 30) }
          .lemonButton(shape: .circle).keyboardShortcut("z", modifiers: [.command, .shift]).disabled(redo.isEmpty)
        Button("Save") { apply() }
          .lemonButton(primary: true).keyboardShortcut(.defaultAction).disabled(marks.isEmpty)
      }
      .animation(.spring(response: 0.3, dampingFraction: 0.8), value: kind)
    }
  }

  private func canvas(_ box: CGSize) -> some View {
    let fit = aspectFit(pixel, in: CGSize(width: box.width, height: box.height - 56))
    let k = fit.width / max(pixel.width, 1)
    let shown = marks + (current.map { [$0] } ?? [])
    return VStack(spacing: 10) {
      palette
      ZStack {
        if let image { Image(nsImage: image).resizable() }
        Canvas { ctx, _ in
          ctx.withCGContext { cg in
            cg.scaleBy(x: k, y: k)
            ImageTools.draw(shown, in: cg)
          }
        }
      }
      .frame(width: fit.width, height: fit.height)
      .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
      .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
      .contentShape(Rectangle())
      .gesture(draw(k))
      .onHover { $0 ? NSCursor.crosshair.push() : NSCursor.pop() }
    }
    .frame(width: box.width, height: box.height)
  }

  private var palette: some View {
    GlassGroup(spacing: 6) {
      HStack(spacing: 6) {
        ForEach(Mark.Kind.allCases, id: \.self) { m in
          Button { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { kind = m } } label: {
            Image(systemName: Self.symbols[m]!).font(.system(size: 14, weight: .semibold)).frame(width: 26, height: 26)
          }
          .lemonButton(primary: m == kind, shape: .circle)
          .help(m.rawValue.capitalized)
        }
      }
    }
    .frame(height: 46)
  }

  private func draw(_ k: CGFloat) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { v in
        let p = CGPoint(x: v.location.x / k, y: v.location.y / k)
        if current == nil {
          let start = CGPoint(x: v.startLocation.x / k, y: v.startLocation.y / k)
          current = Mark(kind: kind, points: [start], color: kind == .highlighter && color == 0xFF3B30 ? 0xFFD21A : color,
                         width: size * unit, text: text)
        }
        switch kind {
        case .pen, .highlighter: current?.points.append(p)
        case .text: current?.points = [p]
        default: current?.points = [current!.points[0], p]
        }
      }
      .onEnded { _ in
        if let m = current, m.kind != .text || !m.text.isEmpty { marks.append(m); redo = [] }
        current = nil
      }
  }

  private func undo() { if let m = marks.popLast() { redo.append(m) } }
  private func redoLast() { if let m = redo.popLast() { marks.append(m) } }

  private func apply() {
    let m = marks, file = urls[0]
    close()
    // ponytail: annotates the first image only; marks are in that image's pixels
    Runner.perform("Annotate", symbol: "pencil.tip.crop.circle") { try await Task.detached { [try ImageTools.annotate(file, m)] }.value }
  }
}

// MARK: - Redact

struct RedactEditor: View {
  let urls: [URL]
  let close: () -> Void
  private let base: CGImage?
  private let pixel: CGSize
  @State private var boxes: [CGRect] = []  // normalized, top-left origin
  @State private var selected: Int?
  @State private var style = RedactStyle.pixelate
  @State private var strength = 0.5
  @State private var result: NSImage?
  @State private var renderer = PreviewRenderer()
  @State private var drag: (index: Int, start: CGRect, isNew: Bool)?

  init(urls: [URL], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    base = ImageTools.previewCG(urls[0], maxPixel: 1400)
    pixel = ImageTools.orientedSize(urls[0])
  }

  private struct Key: Equatable { let boxes: [CGRect], style: RedactStyle, strength: Double }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Redact", subtitle: subtitle(urls), symbol: "eye.slash.circle", close: close)
      GeometryReader { g in canvas(g.size) }
      HStack(spacing: 12) {
        Chips(options: RedactStyle.allCases, label: \.rawValue, selection: $style)
        LabeledSlider(label: "Strength", value: $strength, reset: 0.5).frame(width: 150)
          .opacity(style == .solid ? 0.4 : 1).disabled(style == .solid)
        Button { delete() } label: { Image(systemName: "trash").frame(width: 30, height: 30) }
          .lemonButton(shape: .circle).keyboardShortcut(.delete, modifiers: []).disabled(selected == nil)
          .help("Delete the selected area")
        Spacer()
        Text(boxes.isEmpty ? "Drag over what to hide" : "\(boxes.count) area\(boxes.count == 1 ? "" : "s")")
          .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).contentTransition(.numericText())
        Button(urls.count == 1 ? "Save" : "Save \(urls.count)") { apply() }
          .lemonButton(primary: true).keyboardShortcut(.defaultAction).disabled(boxes.isEmpty)
      }
    }
    .onChange(of: Key(boxes: boxes, style: style, strength: strength)) { _, key in
      let img = base
      renderer.submit({ img.flatMap { ImageTools.redacted($0, boxes: key.boxes, style: key.style, strength: key.strength) } }) { out in
        result = nsImage(out)
      }
    }
  }

  private func canvas(_ box: CGSize) -> some View {
    let fit = aspectFit(pixel, in: CGSize(width: box.width - 16, height: box.height - 16))
    return ZStack(alignment: .topLeading) {
      if let img = boxes.isEmpty ? nsImage(base) : result ?? nsImage(base) { Image(nsImage: img).resizable() }
      ForEach(boxes.indices, id: \.self) { i in
        let r = boxes[i]
        RoundedRectangle(cornerRadius: 3)
          .strokeBorder(i == selected ? lemonYellow : Color.white.opacity(0.85), style: StrokeStyle(lineWidth: i == selected ? 2.5 : 1.5, dash: i == selected ? [] : [5, 4]))
          .frame(width: r.width * fit.width, height: r.height * fit.height)
          .offset(x: r.minX * fit.width, y: r.minY * fit.height)
          .allowsHitTesting(false)
      }
    }
    .frame(width: fit.width, height: fit.height)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
    .contentShape(Rectangle())
    .gesture(gesture(fit))
    .frame(width: box.width, height: box.height)
    .animation(.easeOut(duration: 0.12), value: selected)
  }

  /// Drag inside an area moves it, anywhere else draws a new one; a click selects.
  private func gesture(_ fit: CGSize) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { v in
        let s = CGPoint(x: v.startLocation.x / fit.width, y: v.startLocation.y / fit.height)
        let p = CGPoint(x: min(max(v.location.x / fit.width, 0), 1), y: min(max(v.location.y / fit.height, 0), 1))
        if drag == nil {
          if let i = boxes.lastIndex(where: { $0.contains(s) }) {
            drag = (i, boxes[i], false)
          } else {
            boxes.append(CGRect(origin: s, size: .zero))
            drag = (boxes.count - 1, boxes[boxes.count - 1], true)
          }
          selected = drag!.index
        }
        guard let d = drag else { return }
        if d.isNew {
          boxes[d.index] = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
        } else {
          var r = d.start.offsetBy(dx: v.translation.width / fit.width, dy: v.translation.height / fit.height)
          r.origin.x = min(max(r.minX, 0), 1 - r.width)
          r.origin.y = min(max(r.minY, 0), 1 - r.height)
          boxes[d.index] = r
        }
      }
      .onEnded { _ in
        if let d = drag, d.isNew, boxes[d.index].width * fit.width < 4 || boxes[d.index].height * fit.height < 4 {
          boxes.remove(at: d.index)  // a click on empty space just deselects
          selected = nil
        }
        drag = nil
      }
  }

  private func delete() {
    guard let i = selected else { return }
    boxes.remove(at: i)
    selected = nil
  }

  private func apply() {
    let b = boxes, s = style, k = strength, files = urls
    close()
    // ponytail: the same normalized areas apply to every image (fits batches of same-layout screenshots)
    Runner.perform("Redact", symbol: "eye.slash.circle") {
      try await Task.detached { try files.map { try ImageTools.redact($0, boxes: b, style: s, strength: k) } }.value
    }
  }
}

// MARK: - Metadata

struct MetadataEditor: View {
  static let order = ["Camera", "Date", "Location", "Software"]
  let urls: [URL]
  let close: () -> Void
  private let fields: [MetaField]
  @State private var chosen: Set<String>

  init(urls: [URL], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    fields = ImageTools.metadataFields(urls[0])
    _chosen = State(initialValue: Set(fields.filter { $0.group == "Location" }.map(\.id)))
  }

  private var groups: [String] {
    Set(fields.map(\.group)).sorted { (Self.order.firstIndex(of: $0) ?? 9, $0) < (Self.order.firstIndex(of: $1) ?? 9, $1) }
  }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Metadata", subtitle: subtitle(urls), symbol: "eye.slash", close: close)
      if fields.isEmpty {
        VStack(spacing: 8) {
          Image(systemName: "checkmark.seal").font(.system(size: 30)).foregroundStyle(.green)
          Text("No camera, date or location data found").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        Inspector {
          VStack(spacing: 12) { ForEach(groups, id: \.self, content: section) }
        }
      }
      Footer(title: "Remove all", apply: { apply(nil) }) {
        Text("Orientation is always kept").font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button(chosen.isEmpty ? "Remove selected" : "Remove \(chosen.count) selected") { apply(fields.filter { chosen.contains($0.id) }) }
          .lemonButton()
          .disabled(chosen.isEmpty)
      }
    }
  }

  private func section(_ group: String) -> some View {
    let items = fields.filter { $0.group == group }
    let all = items.allSatisfy { chosen.contains($0.id) }
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(group.uppercased()).font(.system(size: 10, weight: .bold)).tracking(0.8).foregroundStyle(.secondary)
        Spacer()
        Button(all ? "None" : "All") { toggle(items.map(\.id), on: !all) }
          .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      }
      ForEach(items) { f in
        HStack(spacing: 10) {
          Image(systemName: chosen.contains(f.id) ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 15))
            .foregroundStyle(chosen.contains(f.id) ? lemonYellow : Color.secondary)
            .contentTransition(.symbolEffect(.replace))
          Text(f.key).font(.system(size: 12, weight: .medium)).frame(width: 170, alignment: .leading)
          Text(f.value).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggle([f.id], on: !chosen.contains(f.id)) }
      }
    }
    .card()
  }

  private func toggle(_ ids: [String], on: Bool) {
    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { on ? chosen.formUnion(ids) : chosen.subtract(ids) }
  }

  /// nil removes everything.
  private func apply(_ selection: [MetaField]?) {
    let files = urls
    close()
    Runner.perform("Remove metadata", symbol: "eye.slash") {
      try await Task.detached { try files.map { u in try selection.map { try ImageTools.removeMetadata(u, fields: $0) } ?? ImageTools.strip(u) } }.value
    }
  }
}
