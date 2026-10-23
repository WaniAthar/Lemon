import AppKit
import SwiftUI

let alwaysShowFanKey = "alwaysShowFan"
let lemonYellow = Color(red: 1, green: 0.78, blue: 0.1)

func fileURLs(_ pb: NSPasteboard) -> [URL] {
  pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
}

/// Self-test previews: offscreen rendering can't draw glass, so use plain fills.
@MainActor var lemonPlainRender = false

extension View {
  /// Native Liquid Glass on macOS 26+, material before.
  /// `interactive` glass reacts to the pointer (scales and shimmers), for controls.
  @MainActor @ViewBuilder func lemonGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
    if lemonPlainRender {
      background(tint ?? Color.white.opacity(0.8), in: shape).overlay(shape.stroke(Color.black.opacity(0.08)))
    } else if #available(macOS 26.0, *) {
      glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
    } else {
      background((tint ?? .clear).opacity(0.6), in: shape).background(.regularMaterial, in: shape)
    }
  }
}

// MARK: - Geometry

/// Shared by drawing (SwiftUI, y-down) and hit-testing (AppKit, y-up).
/// Angles are degrees clockwise from the top; petal 0 is centred at the top.
enum DialGeo {
  static let dial: CGFloat = 2 * (disc(Tools.maxInFan) + 14)  // room for the largest ring
  static let size = NSSize(width: dial, height: dial)
  static let hub: CGFloat = 60
  static let gap: CGFloat = 7, corner: CGFloat = 16

  /// The ring widens past 8 petals so labels keep their room.
  static func outer(_ n: Int) -> CGFloat { 160 + CGFloat(max(n - 8, 0)) * 12 }
  static func inner(_ n: Int) -> CGFloat { 68 + CGFloat(max(n - 8, 0)) * 3 }
  static func disc(_ n: Int) -> CGFloat { outer(n) + 16 }

  static func span(_ n: Int) -> Double { 360 / Double(n) }

  static func index(dx: CGFloat, dy: CGFloat, of n: Int) -> Int? {
    let d = hypot(dx, dy)
    guard n > 0, d >= inner(n) - 4, d <= disc(n) + 12 else { return nil }
    var a = atan2(Double(dx), Double(dy)) * 180 / .pi  // 0 = up, clockwise
    if a < 0 { a += 360 }
    return Int((a + span(n) / 2).truncatingRemainder(dividingBy: 360) / span(n))
  }
}

/// A petal: annular sector with a constant-width gap to its neighbours and rounded corners.
struct Petal: Shape {
  var mid: Double, span: Double  // degrees clockwise from the top
  var rIn: CGFloat, rOut: CGFloat

  func path(in rect: CGRect) -> Path {
    let c = CGPoint(x: rect.midX, y: rect.midY)
    let k = DialGeo.corner
    func pt(_ deg: Double, _ r: CGFloat) -> CGPoint {
      let t = deg * .pi / 180
      return CGPoint(x: c.x + r * CGFloat(sin(t)), y: c.y - r * CGFloat(cos(t)))
    }
    func edge(_ r: CGFloat) -> Double { asin(min(1, Double(DialGeo.gap / 2 / r))) * 180 / .pi }
    func toward(_ a: CGPoint, _ b: CGPoint, _ dist: CGFloat) -> CGPoint {
      let len = max(hypot(b.x - a.x, b.y - a.y), 1)
      return CGPoint(x: a.x + (b.x - a.x) * dist / len, y: a.y + (b.y - a.y) * dist / len)
    }
    let s = mid - span / 2, e = mid + span / 2
    let oS = s + edge(rOut), oE = e - edge(rOut), iS = s + edge(rIn), iE = e - edge(rIn)
    let ko = Double(k / rOut) * 180 / .pi, ki = Double(k / rIn) * 180 / .pi
    var p = Path()
    func arc(_ a0: Double, _ a1: Double, _ r: CGFloat) {
      let steps = max(6, Int(abs(a1 - a0) / 2))
      for i in 0...steps { p.addLine(to: pt(a0 + (a1 - a0) * Double(i) / Double(steps), r)) }
    }
    p.move(to: pt(oS + ko, rOut))
    arc(oS + ko, oE - ko, rOut)
    p.addQuadCurve(to: toward(pt(oE, rOut), pt(iE, rIn), k), control: pt(oE, rOut))
    p.addLine(to: toward(pt(iE, rIn), pt(oE, rOut), k * 0.7))
    p.addQuadCurve(to: pt(iE - ki * 0.7, rIn), control: pt(iE, rIn))
    arc(iE - ki * 0.7, iS + ki * 0.7, rIn)
    p.addQuadCurve(to: toward(pt(iS, rIn), pt(oS, rOut), k * 0.7), control: pt(iS, rIn))
    p.addLine(to: toward(pt(oS, rOut), pt(iS, rIn), k))
    p.addQuadCurve(to: pt(oS + ko, rOut), control: pt(oS, rOut))
    p.closeSubpath()
    return p
  }
}

// MARK: - Dial view

final class DialModel: ObservableObject {
  @Published var urls: [URL] = []
  @Published var mode: FanMode = .convert
  @Published var tools: [Tool] = []
  @Published var hover: Int?
  @Published var shown = false  // drives the opening animation

  func load(_ urls: [URL], mode: FanMode) {
    self.urls = urls
    setMode(mode)
    shown = false
    DispatchQueue.main.async { self.shown = true }
  }

  func setMode(_ m: FanMode) {
    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
      mode = m
      tools = Tools.available(for: urls, mode: m)
      hover = nil
    }
  }
}

struct DialContent: View {
  @ObservedObject var model: DialModel

  var body: some View {
    let n = model.tools.count
    ZStack {
      Color.clear.lemonGlass(Circle().inset(by: DialGeo.dial / 2 - DialGeo.disc(n)))
      ForEach(Array(model.tools.enumerated()), id: \.element.id) { i, _ in
        petalGlass(i, n).modifier(PetalMotion(model: model, index: i, n: n))
      }
      Color.clear.lemonGlass(Circle().inset(by: DialGeo.dial / 2 - DialGeo.hub))
      ForEach(Array(model.tools.enumerated()), id: \.element.id) { i, tool in
        petalLabel(i, n, tool).modifier(PetalMotion(model: model, index: i, n: n))
      }
      Text(n == 0 ? "No \(model.mode.label.lowercased()) tools" : model.urls.count == 1 ? model.urls[0].lastPathComponent : "\(model.urls.count) files")
        .font(.system(size: 12, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: DialGeo.hub * 2 - 20)
    }
    .frame(width: DialGeo.dial, height: DialGeo.dial)
  }

  @ViewBuilder private func petalGlass(_ i: Int, _ n: Int) -> some View {
    let span = DialGeo.span(n)
    let shape = Petal(mid: Double(i) * span, span: span, rIn: DialGeo.inner(n), rOut: DialGeo.outer(n))
    if model.hover == i {
      shape.fill(lemonYellow).shadow(color: lemonYellow.opacity(0.5), radius: 8)
    } else {
      Color.clear.lemonGlass(shape, tint: .white.opacity(0.55))
    }
  }

  private func petalLabel(_ i: Int, _ n: Int, _ tool: Tool) -> some View {
    let span = DialGeo.span(n), t = Double(i) * span * .pi / 180, on = model.hover == i
    let r = (DialGeo.inner(n) + DialGeo.outer(n)) / 2
    let labelWidth = min(84, 2 * r * CGFloat(sin(span / 2 * .pi / 180)) * 0.84)  // chord at the label radius
    return VStack(spacing: 4) {
      if model.mode != .convert { Image(systemName: tool.symbol).font(.system(size: 17, weight: .medium)) }
      Text(tool.short.uppercased())
        .font(.system(size: model.mode == .convert ? 15 : 11, weight: .semibold))
        .tracking(0.6)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(maxWidth: labelWidth)
    }
    .foregroundStyle(on ? Color.black : Color.primary)
    .offset(x: r * CGFloat(sin(t)), y: -r * CGFloat(cos(t)))
  }
}

/// Hover push and the staggered fly-out, shared by a petal's glass and its label so they move together.
struct PetalMotion: ViewModifier {
  @ObservedObject var model: DialModel
  let index: Int, n: Int

  func body(content: Content) -> some View {
    let t = Double(index) * DialGeo.span(n) * .pi / 180
    let push: CGFloat = model.hover == index ? 5 : 0
    return content
      .offset(x: push * CGFloat(sin(t)), y: -push * CGFloat(cos(t)))
      .animation(.easeOut(duration: 0.15), value: model.hover == index)
      .scaleEffect(model.shown ? 1 : 0.35)
      .opacity(model.shown ? 1 : 0)
      .animation(.spring(response: 0.38, dampingFraction: 0.68).delay(Double(index) * 0.025), value: model.shown)
      .transition(.scale(scale: 0.6).combined(with: .opacity))
  }
}

extension FanMode {
  var label: String { ["Convert", "Edit", "Actions"][FanMode.allCases.firstIndex(of: self)!] }
}

// MARK: - Panel and drop target

/// Hosts the dial and receives the drop. Dropping on a petal runs that tool.
final class DialView: NSView {
  let model = DialModel()
  var onDrop: ((Tool, [URL]) -> Void)?

  override init(frame: NSRect) {
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
    let host = NSHostingView(rootView: DialContent(model: model))
    host.frame = bounds
    host.autoresizingMask = [.width, .height]
    addSubview(host)
  }
  required init?(coder: NSCoder) { fatalError() }

  // Route drags to this view, not the hosting view inside it.
  override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

  // Near-invisible fill keeps transparent areas part of the drop target.
  override func draw(_ dirtyRect: NSRect) {
    NSColor(white: 0, alpha: 0.01).setFill()
    bounds.fill()
  }

  /// Dial centre in this view's (y-up) coordinates.
  var dialCenter: NSPoint { NSPoint(x: bounds.midX, y: bounds.maxY - DialGeo.dial / 2) }

  func setHover(_ h: Int?) {
    guard h != model.hover else { return }
    model.hover = h
    if h != nil { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
  }

  private func track(_ info: NSDraggingInfo) -> NSDragOperation {
    let p = convert(info.draggingLocation, from: nil)
    let h = DialGeo.index(dx: p.x - dialCenter.x, dy: p.y - dialCenter.y, of: model.tools.count)
    setHover(h)
    return h == nil ? [] : .copy
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
  override func draggingExited(_ sender: NSDraggingInfo?) { setHover(nil) }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { setHover(nil) }
    guard let i = model.hover, i < model.tools.count else { return false }
    let urls = fileURLs(sender.draggingPasteboard)  // reading here grants the sandbox access to them
    guard !urls.isEmpty else { return false }
    onDrop?(model.tools[i], urls)
    return true
  }
}

final class DialPanel: NSPanel {
  init(view: NSView) {
    super.init(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    contentView = view
    isOpaque = false
    backgroundColor = .clear
    hasShadow = false
    level = .popUpMenu
    hidesOnDeactivate = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
  }
  override var canBecomeKey: Bool { false }
}

/// Opens the dial around the cursor while files are dragged anywhere, with Shift, Command or Control held
/// (or on every drag if "always show" is on). Holding a key while it's open switches the mode.
@MainActor final class DragWatcher {
  private let view = DialView(frame: NSRect(origin: .zero, size: DialGeo.size))
  private lazy var panel = DialPanel(view: view)
  private var monitor: Any?
  private var poll: Timer?
  private var handledCount = NSPasteboard(name: .drag).changeCount
  private let triggers: NSEvent.ModifierFlags = [.shift, .command, .control]

  init() {
    view.onDrop = { tool, urls in Runner.run(tool, on: urls) }
  }

  func start() {
    monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
      MainActor.assumeIsolated { self?.dragged() }
    }
  }

  private func dragged() {
    guard !panel.isVisible else { return }
    let pb = NSPasteboard(name: .drag)
    // The drag pasteboard keeps its last contents; changeCount tells a new drag from a stale one.
    guard pb.changeCount != handledCount else { return }
    let flags = NSEvent.modifierFlags
    guard UserDefaults.standard.bool(forKey: alwaysShowFanKey) || !flags.intersection(triggers).isEmpty else { return }
    let urls = fileURLs(pb)
    guard !urls.isEmpty else { return }
    view.model.load(urls, mode: FanMode(flags))
    show()
  }

  private func show() {
    let m = NSEvent.mouseLocation
    var o = NSPoint(x: m.x - panel.frame.width / 2, y: m.y - (panel.frame.height - DialGeo.dial / 2))
    if let vf = (NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main)?.visibleFrame {
      o.x = min(max(o.x, vf.minX), vf.maxX - panel.frame.width)
      o.y = min(max(o.y, vf.minY), vf.maxY - panel.frame.height)
    }
    panel.setFrameOrigin(o)
    panel.orderFrontRegardless()
    poll = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
      MainActor.assumeIsolated {
        guard let self else { return t.invalidate() }
        if NSEvent.pressedMouseButtons & 1 == 0 {
          t.invalidate()
          self.poll = nil
          self.handledCount = NSPasteboard(name: .drag).changeCount
          // let a drop finish before hiding
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.panel.orderOut(nil) }
          return
        }
        // Holding a different key switches the mode; releasing keeps the current one.
        let flags = NSEvent.modifierFlags
        if !flags.intersection(self.triggers).isEmpty, FanMode(flags) != self.view.model.mode {
          self.view.model.setMode(FanMode(flags))
          NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
      }
    }
  }
}

// MARK: - Running tools

@MainActor enum Runner {
  static func run(_ tool: Tool, on urls: [URL]) {
    if tool.writesNextToSource {
      for dir in Set(urls.map { $0.deletingLastPathComponent() }) where !FolderAccess.shared.ensure(dir) {
        Toast.show("Lemon can't save in \(dir.lastPathComponent)", symbol: "lock")
        return
      }
    }
    if let editor = tool.editor { return editor(urls) }
    perform(tool.title, symbol: tool.symbol, quiet: !tool.writesNextToSource) { try await tool.run(urls) }
  }

  /// Shows progress and the result as a toast. `quiet` skips the progress toast for instant actions.
  static func perform(_ title: String, symbol: String, quiet: Bool = false, _ work: @escaping () async throws -> [URL]) {
    Task { @MainActor in
      if !quiet { Toast.show("\(title)…", symbol: symbol, sticky: true) }
      do {
        let outs = try await work()
        if outs.isEmpty {
          Toast.show("\(title): done", symbol: "checkmark.circle")
        } else {
          Toast.show(outs.count == 1 ? "Saved \(outs[0].lastPathComponent)" : "Saved \(outs.count) files", symbol: "checkmark.circle")
        }
      } catch {
        Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle")
      }
    }
  }
}

/// Small glass message near the cursor.
@MainActor enum Toast {
  private static var panel: NSPanel?
  private static var hide: DispatchWorkItem?

  static func show(_ text: String, symbol: String, sticky: Bool = false) {
    let content = Label(text, systemImage: symbol)
      .font(.system(size: 13, weight: .medium))
      .lineLimit(2)
      .frame(maxWidth: 420)
      .padding(.horizontal, 16).padding(.vertical, 10)
      .lemonGlass(Capsule())
      .padding(8)
      .fixedSize()
    let host = NSHostingView(rootView: content)
    let size = host.fittingSize
    let p = panel ?? {
      let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      p.isOpaque = false
      p.backgroundColor = .clear
      p.level = .statusBar
      p.ignoresMouseEvents = true
      p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
      return p
    }()
    panel = p
    p.contentView = host
    let m = NSEvent.mouseLocation
    p.setFrame(NSRect(x: m.x - size.width / 2, y: m.y + 24, width: size.width, height: size.height), display: true)
    p.orderFrontRegardless()
    hide?.cancel()
    guard !sticky else { return }
    let work = DispatchWorkItem { p.orderOut(nil) }
    hide = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
  }
}
