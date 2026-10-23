import AppKit
import SwiftUI

// MARK: - Window

final class EditorPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}

/// Floating glass windows for tools that need a decision (crop area, compression level, rotation).
@MainActor enum EditorWindow {
  private static var open: [NSPanel] = []

  static func show<Content: View>(size: CGSize, @ViewBuilder content: (_ close: @escaping () -> Void) -> Content) {
    // Room around the card for its shadow; a plain borderless panel gets no system border or shadow outline.
    let framed = CGSize(width: size.width + 2 * editorMargin, height: size.height + 2 * editorMargin)
    let panel = EditorPanel(contentRect: NSRect(origin: .zero, size: framed), styleMask: [.borderless],
                            backing: .buffered, defer: false)
    let close: () -> Void = { [weak panel] in
      guard let panel else { return }
      NSAnimationContext.runAnimationGroup({ $0.duration = 0.16; panel.animator().alphaValue = 0 }) {
        MainActor.assumeIsolated {
          panel.orderOut(nil)
          open.removeAll { $0 === panel }
        }
      }
    }
    panel.contentView = NSHostingView(rootView: EditorChrome(content: content(close)))
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .floating
    panel.minSize = NSSize(width: 520, height: 420)
    panel.center()
    open.append(panel)
    NSApp.activate()
    panel.makeKeyAndOrderFront(nil)
  }
}

/// Space around an editor card for its shadow.
let editorMargin: CGFloat = 24

/// Glass card that springs in when the window opens.
struct EditorChrome<Content: View>: View {
  let content: Content
  @State private var shown = false

  var body: some View {
    content
      .padding(20)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .lemonGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
      .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
      .padding(editorMargin)
      .scaleEffect(shown ? 1 : 0.93)
      .opacity(shown ? 1 : 0)
      .onAppear { withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { shown = true } }
  }
}

/// Lets the user drag the borderless window by its header.
struct WindowDragArea: NSViewRepresentable {
  final class DragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
  }
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Shared controls

struct EditorHeader: View {
  let title: String, subtitle: String, symbol: String
  let close: () -> Void

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.black)
        .frame(width: 34, height: 34)
        .lemonGlass(Circle(), tint: lemonYellow)
      VStack(alignment: .leading, spacing: 1) {
        Text(title).font(.system(size: 15, weight: .semibold))
        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
      Spacer()
      Button(action: close) {
        Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
      }
      .lemonButton(shape: .circle)
      .keyboardShortcut(.cancelAction)
    }
    .background(WindowDragArea())
  }
}

struct LemonButtonStyle: ButtonStyle {
  enum Shape { case capsule, circle }
  var primary = false
  var shape = Shape.capsule
  @State private var hover = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .semibold))
      .padding(.horizontal, shape == .capsule ? 18 : 0)
      .padding(.vertical, shape == .capsule ? 9 : 0)
      .foregroundStyle(primary ? Color.black : Color.primary)
      .lemonGlass(Capsule(), tint: primary ? lemonYellow : nil, interactive: true)
      .shadow(color: primary && hover ? lemonYellow.opacity(0.5) : .clear, radius: 8)
      .scaleEffect(configuration.isPressed ? 0.93 : hover ? 1.04 : 1)
      .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
      .animation(.easeOut(duration: 0.15), value: hover)
      .onHover { hover = $0 }
  }
}

/// Segmented choice: the native segmented control (Liquid Glass on macOS 26+).
struct Chips<T: Hashable>: View {
  let options: [T]
  let label: (T) -> String
  @Binding var selection: T

  var body: some View {
    Picker("", selection: Binding(get: { selection }, set: { v in withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { selection = v } })) {
      ForEach(options, id: \.self) { Text(label($0)).tag($0) }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
  }
}

extension View {
  /// Native Liquid Glass buttons on macOS 26+ (yellow-tinted prominent glass for the main action); `LemonButtonStyle` before.
  @MainActor @ViewBuilder func lemonButton(primary: Bool = false, shape: LemonButtonStyle.Shape = .capsule) -> some View {
    if #available(macOS 26.0, *), !lemonPlainRender {
      if primary {
        buttonStyle(.glassProminent).tint(lemonYellow).foregroundStyle(.black)
          .controlSize(.large).buttonBorderShape(shape == .circle ? .circle : .capsule)
      } else {
        buttonStyle(.glass).controlSize(shape == .circle ? .regular : .large).buttonBorderShape(shape == .circle ? .circle : .capsule)
      }
    } else {
      buttonStyle(LemonButtonStyle(primary: primary, shape: shape))
    }
  }
}

func aspectFit(_ content: CGSize, in box: CGSize) -> CGSize {
  guard content.width > 0, content.height > 0 else { return .zero }
  let k = min(box.width / content.width, box.height / content.height)
  return CGSize(width: content.width * k, height: content.height * k)
}

func formatBytes(_ n: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

func subtitle(_ urls: [URL]) -> String { urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) images" }

// MARK: - Crop

enum CropAspect: String, CaseIterable {
  case free = "Free", square = "1:1", r43 = "4:3", r32 = "3:2", r169 = "16:9", r916 = "9:16"
  var ratio: CGFloat? {
    switch self {
    case .free: nil
    case .square: 1
    case .r43: 4 / 3
    case .r32: 3 / 2
    case .r169: 16 / 9
    case .r916: 9 / 16
    }
  }
}

struct CropHandle: Hashable {
  var left = false, right = false, top = false, bottom = false
  var isCorner: Bool { (left || right) && (top || bottom) }
  static let all: [CropHandle] = [
    .init(left: true, top: true), .init(right: true, top: true), .init(left: true, bottom: true), .init(right: true, bottom: true),
    .init(top: true), .init(bottom: true), .init(left: true), .init(right: true),
  ]
}

struct CropEditor: View {
  let urls: [URL]
  let close: () -> Void
  private let images: [NSImage?]
  private let sizes: [CGSize]
  @State private var rects: [CGRect]  // normalized, top-left origin
  @State private var index = 0
  @State private var aspect = CropAspect.free
  @State private var start: CGRect?
  @State private var active: CropHandle?
  @State private var moving = false
  private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
  private let minSide: CGFloat = 0.04

  init(urls: [URL], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    images = urls.map { ImageTools.preview($0) }
    sizes = urls.map { ImageTools.orientedSize($0) }
    _rects = State(initialValue: Array(repeating: Self.unit, count: urls.count))
  }

  private var rect: CGRect { rects[index] }
  private var pixel: CGSize { sizes[index] }
  private var dragging: Bool { active != nil || moving }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Crop", subtitle: subtitle(urls), symbol: "crop", close: close)
      GeometryReader { geo in canvas(geo.size) }
      if urls.count > 1 { strip }
      HStack(spacing: 10) {
        Chips(options: CropAspect.allCases, label: \.rawValue, selection: $aspect)
        Spacer()
        Text("\(Int(rect.width * pixel.width)) × \(Int(rect.height * pixel.height))")
          .font(.system(size: 12, weight: .medium).monospacedDigit())
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
        Button("Reset") { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { aspect = .free; rects = rects.map { _ in Self.unit } } }
          .lemonButton()
        Button(urls.count == 1 ? "Crop" : "Crop \(urls.count)") { apply() }
          .lemonButton(primary: true)
          .keyboardShortcut(.defaultAction)
      }
    }
    .onChange(of: aspect) { _, a in
      withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
        rects = sizes.map { fitted(a.ratio, pixel: $0) }
      }
    }
  }

  // MARK: Canvas

  private func canvas(_ box: CGSize) -> some View {
    let fit = aspectFit(pixel, in: CGSize(width: box.width - 24, height: box.height - 24))
    let r = CGRect(x: rect.minX * fit.width, y: rect.minY * fit.height, width: rect.width * fit.width, height: rect.height * fit.height)
    return ZStack(alignment: .topLeading) {
      if let img = images[index] {
        Image(nsImage: img).resizable().frame(width: fit.width, height: fit.height)
      }
      // dim everything outside the crop
      Path { p in
        p.addRect(CGRect(origin: .zero, size: fit))
        p.addRect(r)
      }
      .fill(Color.black.opacity(dragging ? 0.6 : 0.45), style: FillStyle(eoFill: true))
      .allowsHitTesting(false)
      ThirdsGrid()
        .stroke(Color.white.opacity(0.7), lineWidth: 0.6)
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
        .opacity(dragging ? 1 : 0)
        .allowsHitTesting(false)
      Rectangle()
        .strokeBorder(Color.white, lineWidth: 2)
        .background(Color.white.opacity(0.001))
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
        .gesture(moveGesture(fit))
        .onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() }
      ForEach(CropHandle.all.filter { aspect == .free || $0.isCorner }, id: \.self) { h in
        handle(h, in: r, fit: fit)
      }
    }
    .frame(width: fit.width, height: fit.height)
    .clipShape(RoundedRectangle(cornerRadius: 6))
    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    .frame(width: box.width, height: box.height)
    .animation(.easeOut(duration: 0.15), value: dragging)
  }

  private func handle(_ h: CropHandle, in r: CGRect, fit: CGSize) -> some View {
    let x = h.left ? r.minX : h.right ? r.maxX : r.midX
    let y = h.top ? r.minY : h.bottom ? r.maxY : r.midY
    let on = active == h
    return Group {
      if h.isCorner {
        Circle().fill(.white).frame(width: 16, height: 16)
      } else {
        Capsule().fill(.white).frame(width: h.top || h.bottom ? 26 : 7, height: h.top || h.bottom ? 7 : 26)
      }
    }
    .shadow(color: .black.opacity(0.35), radius: 3)
    .scaleEffect(on ? 1.35 : 1)
    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: on)
    .frame(width: 30, height: 30)
    .contentShape(Rectangle())
    .position(x: x, y: y)
    .gesture(
      DragGesture(minimumDistance: 0)
        .onChanged { v in
          if start == nil { start = rect; active = h }
          guard let s = start else { return }
          // translation is relative to where the drag began: rebase on the start rect's handle position
          let sx = h.left ? s.minX : h.right ? s.maxX : s.midX, sy = h.top ? s.minY : h.bottom ? s.maxY : s.midY
          let target = CGPoint(x: min(max(sx + v.translation.width / fit.width, 0), 1),
                               y: min(max(sy + v.translation.height / fit.height, 0), 1))
          rects[index] = resized(s, handle: h, to: target)
        }
        .onEnded { _ in start = nil; active = nil }
    )
  }

  private func moveGesture(_ fit: CGSize) -> some Gesture {
    DragGesture()
      .onChanged { v in
        if start == nil { start = rect; moving = true }
        guard let s = start else { return }
        var r = s.offsetBy(dx: v.translation.width / fit.width, dy: v.translation.height / fit.height)
        r.origin.x = min(max(r.minX, 0), 1 - r.width)
        r.origin.y = min(max(r.minY, 0), 1 - r.height)
        rects[index] = r
      }
      .onEnded { _ in start = nil; moving = false }
  }

  /// Moves the dragged edges to `p`, keeping the opposite side fixed and the aspect ratio if one is chosen.
  private func resized(_ s: CGRect, handle h: CropHandle, to p: CGPoint) -> CGRect {
    var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
    if h.left { minX = min(p.x, maxX - minSide) }
    if h.right { maxX = max(p.x, minX + minSide) }
    if h.top { minY = min(p.y, maxY - minSide) }
    if h.bottom { maxY = max(p.y, minY + minSide) }
    var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    if let ratio = aspect.ratio {
      // normalized height for this width at the pixel aspect ratio
      var w = r.width, hgt = r.width * pixel.width / (pixel.height * ratio)
      let maxH = h.top ? s.maxY : 1 - s.minY, maxW = h.left ? s.maxX : 1 - s.minX
      if hgt > maxH { hgt = maxH; w = hgt * pixel.height * ratio / pixel.width }
      w = min(w, maxW)
      hgt = w * pixel.width / (pixel.height * ratio)
      r = CGRect(x: h.left ? s.maxX - w : s.minX, y: h.top ? s.maxY - hgt : s.minY, width: w, height: hgt)
    }
    return r
  }

  /// Largest centred rect with `ratio` (pixel aspect), or the whole image.
  private func fitted(_ ratio: CGFloat?, pixel: CGSize) -> CGRect {
    guard let ratio, pixel.width > 0, pixel.height > 0 else { return Self.unit }
    let imageRatio = pixel.width / pixel.height
    let (w, h) = ratio > imageRatio ? (1, imageRatio / ratio) : (ratio / imageRatio, 1)
    return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
  }

  // MARK: Strip and apply

  private var strip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(urls.indices, id: \.self) { i in
          ZStack(alignment: .bottomTrailing) {
            if let img = images[i] { Image(nsImage: img).resizable().scaledToFill() }
            if rects[i] != Self.unit {
              Image(systemName: "crop").font(.system(size: 9, weight: .bold)).padding(4)
                .lemonGlass(Circle(), tint: lemonYellow).foregroundStyle(.black).padding(3)
                .transition(.scale.combined(with: .opacity))
            }
          }
          .frame(width: 54, height: 54)
          .clipShape(RoundedRectangle(cornerRadius: 9))
          .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(i == index ? lemonYellow : .clear, lineWidth: 2.5))
          .scaleEffect(i == index ? 1.06 : 1)
          .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { index = i } }
        }
      }
      .padding(4)
    }
    .frame(height: 66)
  }

  private func apply() {
    let jobs = Array(zip(urls, rects))
    close()
    Runner.perform("Crop", symbol: "crop") { try jobs.map { try ImageTools.crop($0.0, rect: $0.1) } }
  }
}

struct ThirdsGrid: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    for k in 1...2 {
      let x = r.minX + r.width * CGFloat(k) / 3, y = r.minY + r.height * CGFloat(k) / 3
      p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
      p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
    }
    return p
  }
}

// MARK: - Compress

struct CompressEditor: View {
  enum Mode: String, CaseIterable { case quality = "Quality", target = "Size", percent = "Percent" }
  enum Preset: String, CaseIterable {
    case large = "Large", medium = "Medium", small = "Small"
    var quality: Double { [0.85, 0.7, 0.45][Preset.allCases.firstIndex(of: self)!] }
  }
  enum Unit: String, CaseIterable { case kb = "KB", mb = "MB" }
  enum MaxSide: String, CaseIterable {
    case original = "Original", k4 = "4K", p1080 = "1080p", p720 = "720p"
    var pixels: Int? { [nil, 3840, 1920, 1280][MaxSide.allCases.firstIndex(of: self)!] }
  }

  let urls: [URL]
  let close: () -> Void
  private let original: NSImage?
  private let originalBytes: Int
  @State private var mode = Mode.quality
  @State private var quality = 0.7
  @State private var target = 500.0
  @State private var percent = 50.0
  @State private var unit = Unit.kb
  @State private var maxSide = MaxSide.original
  @State private var format = CompressSettings.Format.keep
  @State private var after: NSImage?
  @State private var newBytes = 0
  @State private var split: CGFloat = 0.5
  @State private var working = false
  @State private var error: String?
  @State private var job: Task<Void, Never>?

  init(urls: [URL], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    original = ImageTools.preview(urls[0], maxPixel: 2000)
    originalBytes = (try? urls[0].resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }

  private var settings: CompressSettings { settings(bytes: originalBytes) }

  /// Percent mode targets a share of each file's own size.
  private func settings(bytes: Int) -> CompressSettings {
    let t: Int? = switch mode {
    case .quality: nil
    case .target: Int(target * (unit == .kb ? 1024 : 1_048_576))
    case .percent: max(1, Int(Double(bytes) * percent / 100))
    }
    return CompressSettings(quality: quality, maxSide: maxSide.pixels, format: format, targetBytes: t)
  }

  private var preset: Binding<Preset?> {
    Binding(get: { Preset.allCases.first { abs($0.quality - quality) < 0.001 } }, set: { if let p = $0 { quality = p.quality } })
  }

  private var saved: Int { originalBytes > 0 && newBytes > 0 ? Int((1 - Double(newBytes) / Double(originalBytes)) * 100) : 0 }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Compress", subtitle: subtitle(urls), symbol: "arrow.down.right.and.arrow.up.left", close: close)
      HStack(alignment: .top, spacing: 18) {
        BeforeAfter(before: original, after: after, split: $split)
        controls.frame(width: 250)
      }
      HStack {
        if urls.count > 1 {
          Text("Preview shows the first image; settings apply to all \(urls.count).").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button(urls.count == 1 ? "Compress" : "Compress \(urls.count)") { apply() }
          .lemonButton(primary: true)
          .keyboardShortcut(.defaultAction)
          .disabled(error != nil)
      }
    }
    .onAppear(perform: recompute)
    .onChange(of: settings) { _, _ in recompute() }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 16) {
      Chips(options: Mode.allCases, label: \.rawValue, selection: $mode)
      Group {
        if mode == .quality {
          VStack(alignment: .leading, spacing: 6) {
            Chips(options: Preset.allCases.map { Optional($0) }, label: { $0?.rawValue ?? "" }, selection: preset)
              .padding(.bottom, 6)
            HStack {
              Text("Quality").font(.system(size: 12, weight: .semibold))
              Spacer()
              Text("\(Int(quality * 100))%").font(.system(size: 12, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(quality * 100))
            }
            Slider(value: $quality, in: 0.05...1).tint(lemonYellow)
          }
        } else if mode == .target {
          HStack {
            TextField("Size", value: $target, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
            Chips(options: Unit.allCases, label: \.rawValue, selection: $unit)
          }
        } else {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Text("Reduce to").font(.system(size: 12, weight: .semibold))
              Spacer()
              Text("\(Int(percent))% of original").font(.system(size: 12, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(percent))
            }
            Slider(value: $percent, in: 10...90, step: 5).tint(lemonYellow)
          }
        }
      }
      .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
      .animation(.spring(response: 0.35, dampingFraction: 0.8), value: mode)

      VStack(alignment: .leading, spacing: 6) {
        Text("Max size").font(.system(size: 12, weight: .semibold))
        Chips(options: MaxSide.allCases, label: \.rawValue, selection: $maxSide)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("Format").font(.system(size: 12, weight: .semibold))
        Chips(options: CompressSettings.Format.allCases, label: \.rawValue, selection: $format)
      }
      Spacer(minLength: 0)
      resultCard
    }
  }

  private var resultCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error {
        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.red)
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
          Text(newBytes > 0 ? formatBytes(newBytes) : "…").fontWeight(.semibold)
            .contentTransition(.numericText())
        }
        .font(.system(size: 12).monospacedDigit())
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .lemonGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: newBytes)
  }

  /// Re-encodes the first image off the main thread whenever a setting changes (latest change wins).
  private func recompute() {
    job?.cancel()
    let s = settings, url = urls[0]
    working = true
    job = Task {
      try? await Task.sleep(nanoseconds: 120_000_000)  // debounce slider drags
      if Task.isCancelled { return }
      let result: Result<Data, Error> = await Task.detached { Result { try ImageTools.compressedData(url, settings: s).data } }.value
      if Task.isCancelled { return }
      withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
        switch result {
        case .success(let data): newBytes = data.count; after = NSImage(data: data); error = nil
        case .failure(let e): error = e.localizedDescription
        }
        working = false
      }
    }
  }

  private func apply() {
    let jobs = urls.map { ($0, settings(bytes: (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)) }
    close()
    Runner.perform("Compress", symbol: "arrow.down.right.and.arrow.up.left") { try jobs.map { try ImageTools.compress($0.0, settings: $0.1) } }
  }
}

/// Original on the left, result on the right, with a draggable divider.
struct BeforeAfter: View {
  let before: NSImage?
  let after: NSImage?
  @Binding var split: CGFloat
  @State private var dragging = false

  var body: some View {
    GeometryReader { g in
      let fit = aspectFit(before?.size ?? .zero, in: g.size)
      let x = fit.width * split
      ZStack(alignment: .topLeading) {
        if let before { Image(nsImage: before).resizable().frame(width: fit.width, height: fit.height) }
        if let after {
          Image(nsImage: after).resizable().frame(width: fit.width, height: fit.height)
            .mask(HStack(spacing: 0) { Color.clear.frame(width: x); Color.black })
            .transition(.opacity)
        }
        Rectangle().fill(.white).frame(width: 2, height: fit.height).offset(x: x - 1).shadow(radius: 2)
        Image(systemName: "chevron.left.chevron.right")
          .font(.system(size: 11, weight: .bold))
          .foregroundStyle(.black)
          .frame(width: 32, height: 32)
          .lemonGlass(Circle(), tint: lemonYellow)
          .shadow(color: .black.opacity(0.3), radius: 4)
          .scaleEffect(dragging ? 1.15 : 1)
          .offset(x: x - 16, y: fit.height / 2 - 16)
        HStack {
          tag("BEFORE")
          Spacer()
          tag("AFTER")
        }
        .padding(8)
        .frame(width: fit.width)
      }
      .frame(width: fit.width, height: fit.height)
      .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { v in dragging = true; split = min(max(v.location.x / max(fit.width, 1), 0), 1) }
          .onEnded { _ in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { dragging = false } }
      )
      .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
      .frame(width: g.size.width, height: g.size.height)
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: dragging)
    }
  }

  private func tag(_ s: String) -> some View {
    Text(s).font(.system(size: 10, weight: .bold)).tracking(0.8)
      .padding(.horizontal, 8).padding(.vertical, 4)
      .lemonGlass(Capsule(), tint: .black.opacity(0.35))
      .foregroundStyle(.white)
  }
}

// MARK: - Rotate

struct RotateEditor: View {
  let urls: [URL]
  let close: () -> Void
  private let image: NSImage?
  private let pixel: CGSize
  @State private var turns = 0  // unbounded so the animation always spins the short way the user pressed
  @State private var flipH = false
  @State private var flipV = false

  init(urls: [URL], close: @escaping () -> Void) {
    self.urls = urls
    self.close = close
    image = ImageTools.preview(urls[0], maxPixel: 1400)
    pixel = ImageTools.orientedSize(urls[0])
  }

  private var odd: Bool { abs(turns) % 2 == 1 }
  private var unchanged: Bool { ((turns % 4) + 4) % 4 == 0 && !flipH && !flipV }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Rotate & Flip", subtitle: subtitle(urls), symbol: "rotate.right", close: close)
      GeometryReader { g in
        let shown = odd ? CGSize(width: pixel.height, height: pixel.width) : pixel
        let fit = aspectFit(shown, in: CGSize(width: g.size.width - 40, height: g.size.height - 40))
        let base = odd ? CGSize(width: fit.height, height: fit.width) : fit
        if let image {
          Image(nsImage: image).resizable()
            .frame(width: base.width, height: base.height)
            .scaleEffect(x: flipH ? -1 : 1, y: flipV ? -1 : 1)
            .rotationEffect(.degrees(Double(turns) * 90))
            .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            .frame(width: g.size.width, height: g.size.height)
        }
      }
      HStack(spacing: 8) {
        tool("rotate.left", "Left") { turns -= 1 }
        tool("rotate.right", "Right") { turns += 1 }
        tool("arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip H") { flipH.toggle() }
        tool("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip V") { flipV.toggle() }
        Spacer()
        Text(odd ? "\(Int(pixel.height)) × \(Int(pixel.width))" : "\(Int(pixel.width)) × \(Int(pixel.height))")
          .font(.system(size: 12, weight: .medium).monospacedDigit())
          .foregroundStyle(.secondary)
          .contentTransition(.numericText())
        Button("Reset") { spring { turns = 0; flipH = false; flipV = false } }
          .lemonButton()
          .disabled(unchanged)
        Button(urls.count == 1 ? "Apply" : "Apply to \(urls.count)") { apply() }
          .lemonButton(primary: true)
          .keyboardShortcut(.defaultAction)
          .disabled(unchanged)
      }
    }
  }

  private func spring(_ change: () -> Void) {
    withAnimation(.spring(response: 0.45, dampingFraction: 0.72), change)
  }

  private func tool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button { spring(action) } label: {
      Image(systemName: symbol).font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 36)
    }
    .lemonButton(shape: .circle)
    .help(help)
  }

  private func apply() {
    let t = turns, h = flipH, v = flipV, files = urls
    close()
    Runner.perform("Rotate", symbol: "rotate.right") { try files.map { try ImageTools.transform($0, quarterTurns: t, flipH: h, flipV: v) } }
  }
}
