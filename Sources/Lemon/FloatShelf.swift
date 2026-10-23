import AppKit
import Quartz
import QuickLookThumbnailing
import SwiftUI

let shelfRemoveAfterDragKey = "shelfRemoveAfterDrag"

// MARK: - Model

@MainActor final class ShelfModel: ObservableObject {
  @Published private(set) var items: [URL] = [] {
    didSet {
      onChange?()
      if items.isEmpty && !oldValue.isEmpty { onEmpty?() }
    }
  }
  @Published var selection: Set<URL> = []
  @Published var expanded = false { didSet { onChange?() } }
  @Published var list = false { didSet { onChange?() } }
  @Published var dropTarget = false
  @Published var closing = false
  @Published var pulls = 0  // wiggles the paper clip
  @Published var thumbs: [URL: NSImage] = [:]
  var frames: [URL: CGRect] = [:]  // item frames for the rubber band, reported by the view
  var onChange: (() -> Void)?      // the window size may have changed
  var onEmpty: (() -> Void)?
  private var anchor: URL?

  static let spring = Animation.spring(response: 0.38, dampingFraction: 0.74)

  var selected: [URL] { items.filter(selection.contains) }

  /// Adds files not already on the shelf; returns how many were new.
  @discardableResult func add(_ urls: [URL]) -> Int {
    var seen = Set(items)
    let new = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
    guard !new.isEmpty else { return 0 }
    withAnimation(Self.spring) { items += new }
    for u in new {
      let req = QLThumbnailGenerator.Request(fileAt: u, size: CGSize(width: 128, height: 128), scale: 2, representationTypes: .all)
      QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
        guard let img = rep?.nsImage else { return }
        Task { @MainActor in self?.thumbs[u] = img }
      }
    }
    return new.count
  }

  func remove(_ urls: [URL]) {
    let gone = Set(urls)
    withAnimation(Self.spring) {
      selection.subtract(gone)
      items.removeAll(where: gone.contains)
    }
  }

  /// After a drag out: the items slide away and the paper clip springs back.
  func pullOut(_ urls: [URL]) {
    withAnimation(.spring(response: 0.3, dampingFraction: 0.3)) { pulls += 1 }
    remove(urls)
  }

  func clear() { remove(items) }

  func thumb(_ u: URL) -> NSImage { thumbs[u] ?? NSWorkspace.shared.icon(forFile: u.path) }

  /// Finder-style: plain click selects one, ⌘ toggles, ⇧ selects the range from the last clicked item.
  func click(_ u: URL, command: Bool = false, shift: Bool = false) {
    if shift, let a = anchor, let i = items.firstIndex(of: a), let j = items.firstIndex(of: u) {
      selection = Set(items[min(i, j)...max(i, j)])
      return
    }
    if command { selection.formSymmetricDifference([u]) } else { selection = [u] }
    anchor = u
  }

  func selectAll() { selection = Set(items) }

  /// What a context menu or drag on `u` acts on: the selection if `u` is in it, else `u` alone (and selects it).
  func targets(_ u: URL, select: Bool = false) -> [URL] {
    if selection.contains(u) { return selected }
    if select { click(u) }
    return [u]
  }

  /// Type-to-select: first item whose name starts with `prefix`, ignoring case.
  @discardableResult func typeSelect(_ prefix: String) -> URL? {
    guard let u = items.first(where: { $0.lastPathComponent.lowercased().hasPrefix(prefix.lowercased()) }) else { return nil }
    selection = [u]
    anchor = u
    return u
  }

  func rubberBand(_ r: CGRect, base: Set<URL>) {
    selection = base.union(frames.filter { items.contains($0.key) && $0.value.intersects(r) }.keys)
  }
}

enum ShelfGeo {
  static let margin: CGFloat = 8, snapDistance: CGFloat = 48
  static let compact = CGSize(width: 150, height: 170)
  static let columns = 4, cell = CGSize(width: 76, height: 94)

  static func size(count: Int, expanded: Bool, list: Bool) -> CGSize {
    guard expanded else { return compact }
    let body = list ? CGFloat(count) * 32 : CGFloat((max(count, 1) + columns - 1) / columns) * (cell.height + 6)
    return CGSize(width: 352, height: min(max(body + 70, 180), 460))
  }

  static func clamp(_ r: CGRect, in vf: CGRect) -> CGRect {
    let v = vf.insetBy(dx: margin, dy: margin)
    var r = r
    r.origin.x = min(max(r.minX, v.minX), v.maxX - r.width)
    r.origin.y = min(max(r.minY, v.minY), v.maxY - r.height)
    return r
  }

  /// Released within `snapDistance` of (or past) a screen edge: attach flush to it. Otherwise just keep it on screen.
  static func snap(_ f: CGRect, in vf: CGRect) -> (edge: CGRectEdge?, frame: CGRect) {
    var r = clamp(f, in: vf)
    let d: [(CGRectEdge, CGFloat)] = [(.minXEdge, f.minX - vf.minX), (.maxXEdge, vf.maxX - f.maxX),
                                     (.minYEdge, f.minY - vf.minY), (.maxYEdge, vf.maxY - f.maxY)]
    guard let near = d.min(by: { $0.1 < $1.1 }), near.1 <= snapDistance else { return (nil, r) }
    let v = vf.insetBy(dx: margin, dy: margin)
    switch near.0 {
    case .minXEdge: r.origin.x = v.minX
    case .maxXEdge: r.origin.x = v.maxX - r.width
    case .minYEdge: r.origin.y = v.minY
    case .maxYEdge: r.origin.y = v.maxY - r.height
    @unknown default: break
    }
    return (near.0, r)
  }

  /// New size keeping the top-left corner, or the attached right/bottom edge, in place.
  static func place(_ size: CGSize, from f: CGRect, edge: CGRectEdge?, in vf: CGRect) -> CGRect {
    var r = CGRect(x: f.minX, y: f.maxY - size.height, width: size.width, height: size.height)
    if edge == .maxXEdge { r.origin.x = f.maxX - size.width }
    if edge == .minYEdge { r.origin.y = f.minY }
    return clamp(r, in: vf)
  }
}

// MARK: - Shelves

@MainActor enum Shelves {
  static var open: [ShelfPanel] = []
  static weak var dragSource: ShelfModel?  // a shelf ignores its own drags

  /// The Float action: adds to the frontmost shelf, or opens one at the cursor.
  @discardableResult static func float(_ urls: [URL]) -> [URL] {
    let live = open.filter { !$0.model.closing }
    let front = NSApp.orderedWindows.lazy.compactMap { $0 as? ShelfPanel }.first { live.contains($0) }
    let shelf = front ?? live.last ?? make(at: NSEvent.mouseLocation)
    shelf.model.add(urls)
    shelf.orderFrontRegardless()
    return []
  }

  static func newShelf() {
    let vf = NSScreen.main?.visibleFrame ?? .zero
    make(at: NSPoint(x: vf.midX, y: vf.midY)).makeKey()
  }

  @discardableResult static func make(at p: NSPoint) -> ShelfPanel {
    let s = ShelfPanel(at: p)
    open.append(s)
    s.orderFrontRegardless()
    return s
  }
}

// MARK: - Window

final class ShelfHostingView: NSHostingView<ShelfView> {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ShelfPanel: NSPanel, NSDraggingSource, QLPreviewPanelDataSource {
  let model = ShelfModel()
  private var edge: CGRectEdge?
  private var moveStart: (mouse: NSPoint, origin: NSPoint)?
  private var timer: Timer?
  private var pos: [CGFloat] = [], vel: [CGFloat] = [0, 0, 0, 0], target = NSRect.zero
  private var typed = "", typedAt = Date.distantPast
  private var preview: [URL] = []
  private var dragged: [URL] = []

  init(at p: NSPoint) {
    super.init(contentRect: NSRect(origin: .zero, size: ShelfGeo.compact), styleMask: [.borderless, .nonactivatingPanel],
               backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let host = ShelfHostingView(rootView: ShelfView(model: model, panel: self))
    host.sizingOptions = []
    contentView = host
    let s = ShelfGeo.compact
    setFrame(ShelfGeo.clamp(NSRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height), in: visible(p)),
             display: false)
    target = frame
    model.onChange = { [weak self] in self?.relayout() }
    model.onEmpty = { [weak self] in self?.dismiss() }
  }

  override var canBecomeKey: Bool { true }

  private func visible(_ p: NSPoint? = nil) -> NSRect {
    let s = p.flatMap { p in NSScreen.screens.first { $0.frame.contains(p) } } ?? screen ?? NSScreen.main
    return s?.visibleFrame ?? .zero
  }

  func dismiss() {
    guard !model.closing else { return }
    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { model.closing = true }
    if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().dataSource === self { QLPreviewPanel.shared().orderOut(nil) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      self.orderOut(nil)
      Shelves.open.removeAll { $0 === self }
    }
  }

  // MARK: Moving and springs

  private func relayout() {
    let m = model
    animate(to: ShelfGeo.place(ShelfGeo.size(count: m.items.count, expanded: m.expanded, list: m.list), from: target, edge: edge, in: visible()))
  }

  func dragMove() {
    let mouse = NSEvent.mouseLocation
    if moveStart == nil {
      moveStart = (mouse, frame.origin)
      timer?.invalidate()
      timer = nil
      edge = nil  // dragging away detaches
    }
    guard let s = moveStart else { return }
    setFrameOrigin(NSPoint(x: s.origin.x + mouse.x - s.mouse.x, y: s.origin.y + mouse.y - s.mouse.y))
    target = frame
  }

  func endMove() {
    moveStart = nil
    let snapped = ShelfGeo.snap(frame, in: visible(NSEvent.mouseLocation))
    edge = snapped.edge
    animate(to: snapped.frame)
  }

  /// Damped spring on the window frame (NSWindow's animator only eases).
  private func animate(to t: NSRect) {
    target = t
    guard timer == nil else { return }
    pos = [frame.minX, frame.minY, frame.width, frame.height]
    let tm = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] tm in
      MainActor.assumeIsolated { if let self { self.step() } else { tm.invalidate() } }
    }
    RunLoop.main.add(tm, forMode: .common)
    timer = tm
  }

  private func step() {
    let dt: CGFloat = 1.0 / 120, k: CGFloat = 260, c: CGFloat = 24  // ~0.4s with a touch of overshoot
    let goal = [target.minX, target.minY, target.width, target.height]
    var done = true
    for i in 0..<4 {
      vel[i] += (-k * (pos[i] - goal[i]) - c * vel[i]) * dt
      pos[i] += vel[i] * dt
      if abs(pos[i] - goal[i]) > 0.3 || abs(vel[i]) > 4 { done = false }
    }
    if done {
      timer?.invalidate()
      timer = nil
      vel = [0, 0, 0, 0]
      setFrame(target, display: true)
      invalidateShadow()
    } else {
      setFrame(NSRect(x: pos[0], y: pos[1], width: max(pos[2], 40), height: max(pos[3], 40)), display: true)
    }
  }

  // MARK: Keyboard

  override func sendEvent(_ e: NSEvent) {
    if e.type == .keyDown, key(e) { return }
    super.sendEvent(e)
  }

  private func key(_ e: NSEvent) -> Bool {
    let m = model
    switch e.keyCode {
    case 49: quickLook(); return true                          // space
    case 51, 117: m.remove(m.selected); return true             // delete, forward delete
    case 53:                                                    // escape
      if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible { QLPreviewPanel.shared().orderOut(nil) }
      else if m.expanded { withAnimation(ShelfModel.spring) { m.expanded = false } }
      return true
    default: break
    }
    let chars = e.charactersIgnoringModifiers ?? ""
    if e.modifierFlags.contains(.command) {
      switch chars {
      case "a": m.selectAll()
      case "c": _ = ActionTools.copy(m.selected)
      case "o": m.selected.forEach { NSWorkspace.shared.open($0) }
      default: return false
      }
      return true
    }
    guard e.modifierFlags.intersection([.control, .option]).isEmpty, let ch = chars.first, !ch.isNewline,
          ch.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return false }
    if Date().timeIntervalSince(typedAt) > 1 { typed = "" }
    typed += chars
    typedAt = Date()
    m.typeSelect(typed)
    return true
  }

  // MARK: Quick Look

  func quickLook() {
    let ql = QLPreviewPanel.shared()!
    if ql.isVisible { return ql.orderOut(nil) }
    preview = model.selected.isEmpty ? model.items : model.selected
    guard !preview.isEmpty else { return }
    NSApp.activate()
    makeKey()
    ql.makeKeyAndOrderFront(nil)
    ql.dataSource = self
    ql.reloadData()
  }

  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = self }
  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) { panel.dataSource = nil }
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { preview.count }
  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { preview[index] as NSURL }

  // MARK: Dragging out

  /// Starts a real file drag from inside a SwiftUI gesture (the current event is its mouse-dragged event).
  func dragOut(_ urls: [URL]) {
    guard dragged.isEmpty, !urls.isEmpty, let event = NSApp.currentEvent, let view = contentView else { return }
    dragged = urls
    Shelves.dragSource = model
    let p = view.convert(event.locationInWindow, from: nil)
    let items = urls.enumerated().map { i, u -> NSDraggingItem in
      let item = NSDraggingItem(pasteboardWriter: u as NSURL)
      let o = CGFloat(min(i, 4)) * 4
      item.setDraggingFrame(NSRect(x: p.x - 28 + o, y: p.y - 28 - o, width: 56, height: 56), contents: model.thumb(u))
      return item
    }
    view.beginDraggingSession(with: items, event: event, source: self)
  }

  func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
    context == .outsideApplication ? [.copy, .move, .link, .generic] : [.copy, .generic]
  }

  func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
    let urls = dragged
    dragged = []
    Shelves.dragSource = nil
    // A move leaves a stale path behind, so it always leaves the shelf.
    if operation.contains(.move) || (!operation.isEmpty && UserDefaults.standard.bool(forKey: shelfRemoveAfterDragKey)) {
      model.pullOut(urls)
    }
  }
}

// MARK: - Glass

extension View {
  /// Interactive Liquid Glass that morphs between compact and expanded via `id`; `lemonGlass` before macOS 26.
  @MainActor @ViewBuilder func shelfGlass<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false,
                                                     id: String? = nil, in ns: Namespace.ID) -> some View {
    if !lemonPlainRender, #available(macOS 26.0, *) {
      glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: shape)
        .glassEffectID(id ?? "", in: ns)
    } else {
      lemonGlass(shape, tint: tint)
    }
  }
}

struct ShelfGlassGroup<Content: View>: View {
  var spacing: CGFloat = 10
  @ViewBuilder let content: Content
  var body: some View {
    if !lemonPlainRender, #available(macOS 26.0, *) { GlassEffectContainer(spacing: spacing) { content } } else { content }
  }
}

// MARK: - Views

private struct ShelfFrames: PreferenceKey {
  static let defaultValue: [URL: CGRect] = [:]
  static func reduce(value: inout [URL: CGRect], nextValue: () -> [URL: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension AnyTransition {
  /// In: pops in. Out: slides up out of the clip and shrinks while the rest close the gap.
  static let shelfItem = AnyTransition.asymmetric(
    insertion: .scale(scale: 0.5).combined(with: .opacity),
    removal: .offset(y: -36).combined(with: .scale(scale: 0.4, anchor: .top)).combined(with: .opacity))
}

struct ShelfView: View {
  @ObservedObject var model: ShelfModel
  weak var panel: ShelfPanel?
  @AppStorage(shelfRemoveAfterDragKey) private var removeAfterDrag = false
  @State private var band: CGRect?
  @State private var bandBase: Set<URL> = []
  @Namespace private var ns
  private let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

  var body: some View {
    ShelfGlassGroup(spacing: 14) {
      ZStack {
        if model.expanded { expanded.transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top))) }
        else { compact.transition(.opacity.combined(with: .scale(scale: 0.9))) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .shelfGlass(shape, id: "shelf", in: ns)
      .overlay(shape.strokeBorder(lemonYellow, lineWidth: 3).opacity(model.dropTarget ? 1 : 0))
    }
    .scaleEffect(model.closing ? 0.5 : model.dropTarget ? 1.03 : 1)
    .opacity(model.closing ? 0 : 1)
    .animation(ShelfModel.spring, value: model.dropTarget)
    .onDrop(of: [.fileURL], delegate: ShelfDrop(model: model))
  }

  private var countLabel: String { model.items.count == 1 ? "1 item" : "\(model.items.count) items" }

  private var move: some Gesture {
    DragGesture(minimumDistance: 2).onChanged { _ in panel?.dragMove() }.onEnded { _ in panel?.endMove() }
  }

  private func fileDrag(_ urls: @escaping () -> [URL]) -> some Gesture {
    DragGesture(minimumDistance: 4).onChanged { _ in panel?.dragOut(urls()) }
  }

  private func setExpanded(_ e: Bool) { withAnimation(ShelfModel.spring) { model.expanded = e } }

  // MARK: Compact

  private var compact: some View {
    VStack(spacing: 8) {
      if model.items.isEmpty {
        VStack(spacing: 6) {
          Image(systemName: "tray.and.arrow.down").font(.system(size: 26, weight: .medium))
          Text("Drop files").font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.secondary)
        .frame(width: 104, height: 104)
        .background(RoundedRectangle(cornerRadius: 16).strokeBorder(.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .padding(.top, 12)
      } else {
        stack
          .frame(width: 130, height: 116)
          .contentShape(Rectangle())
          .onTapGesture { setExpanded(true) }
          .gesture(fileDrag { model.items })
          .contextMenu { menu(model.items) }
      }
      Text(countLabel)
        .font(.system(size: 11, weight: .semibold))
        .contentTransition(.numericText(value: Double(model.items.count)))
        .padding(.horizontal, 10).padding(.vertical, 4)
        .shelfGlass(Capsule(), tint: .white.opacity(0.4), interactive: true, id: "count", in: ns)
    }
    .padding(.bottom, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .gesture(move)
  }

  /// Up to three tilted cards held by a paper clip; the stack re-fans as cards leave.
  private var stack: some View {
    let cards = Array(model.items.suffix(3))
    let tilt: [Double] = [0, -9, 8], dx: [CGFloat] = [0, -7, 8], dy: [CGFloat] = [0, 3, 5]
    return ZStack {
      ForEach(Array(cards.enumerated()), id: \.element) { i, u in
        let depth = cards.count - 1 - i
        Image(nsImage: model.thumb(u)).resizable().scaledToFit()
          .frame(width: 66, height: 66)
          .padding(5)
          .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
          .rotationEffect(.degrees(tilt[depth]))
          .offset(x: dx[depth], y: dy[depth] + 4)
          .transition(.shelfItem)
      }
      Image(systemName: "paperclip")
        .font(.system(size: 24, weight: .bold))
        .foregroundStyle(Color(white: 0.35))
        .rotationEffect(.degrees(model.pulls % 2 == 0 ? 28 : 8), anchor: .bottom)
        .offset(x: 2, y: -48)
      Text("\(model.items.count)")
        .font(.system(size: 12, weight: .bold).monospacedDigit())
        .contentTransition(.numericText(value: Double(model.items.count)))
        .foregroundStyle(.black)
        .frame(minWidth: 24, minHeight: 24)
        .padding(.horizontal, 3)
        .shelfGlass(Capsule(), tint: lemonYellow, id: "badge", in: ns)
        .offset(x: 46, y: -46)
    }
    .animation(ShelfModel.spring, value: model.items)
  }

  // MARK: Expanded

  private var expanded: some View {
    VStack(spacing: 0) {
      header.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
      GeometryReader { g in
        scroll {
          items
            .frame(maxWidth: .infinity, minHeight: g.size.height, alignment: .top)
            .contentShape(Rectangle())
            .onTapGesture { model.selection = [] }
            .gesture(rubberBand)
            .overlay(alignment: .topLeading) {
              if let band {
                RoundedRectangle(cornerRadius: 4).fill(lemonYellow.opacity(0.18))
                  .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(lemonYellow, lineWidth: 1))
                  .frame(width: band.width, height: band.height)
                  .offset(x: band.minX, y: band.minY)
                  .allowsHitTesting(false)
              }
            }
            .coordinateSpace(name: "shelf")
            .onPreferenceChange(ShelfFrames.self) { model.frames = $0 }
        }
      }
    }
  }

  /// Offscreen renders can't draw NSScrollView.
  @ViewBuilder private func scroll<C: View>(@ViewBuilder _ c: () -> C) -> some View {
    if lemonPlainRender { c() } else { ScrollView { c() } }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Text("\(model.items.count)")
        .font(.system(size: 12, weight: .bold).monospacedDigit())
        .contentTransition(.numericText(value: Double(model.items.count)))
        .foregroundStyle(.black)
        .frame(minWidth: 26, minHeight: 26)
        .shelfGlass(Capsule(), tint: lemonYellow, id: "badge", in: ns)
      Text(model.items.count == 1 ? "item" : "items")
        .font(.system(size: 13, weight: .semibold))
      Spacer(minLength: 4)
      Chips(options: [false, true], label: { $0 ? "List" : "Icons" }, selection: $model.list)
      Menu {
        Toggle("Remove After Dragging Out", isOn: $removeAfterDrag)
        Divider()
        Button("Clear All", role: .destructive) { model.clear() }
      } label: {
        Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).frame(width: 26, height: 26)
      }
      .menuStyle(.borderlessButton)
      .menuIndicator(.hidden)
      .fixedSize()
      .shelfGlass(Circle(), interactive: true, id: "menu", in: ns)
      Button { setExpanded(false) } label: {
        Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11, weight: .bold)).frame(width: 26, height: 26)
      }
      .lemonButton(shape: .circle)
    }
    .contentShape(Rectangle())
    .gesture(move)
  }

  @ViewBuilder private var items: some View {
    if model.list {
      LazyVStack(spacing: 2) { ForEach(model.items, id: \.self) { cell($0) } }
        .padding(.horizontal, 10).padding(.bottom, 10)
    } else {
      LazyVGrid(columns: Array(repeating: GridItem(.fixed(ShelfGeo.cell.width), spacing: 6), count: ShelfGeo.columns), spacing: 6) {
        ForEach(model.items, id: \.self) { cell($0) }
      }
      .padding(.horizontal, 15).padding(.bottom, 12)
    }
  }

  private func cell(_ u: URL) -> some View {
    ShelfCell(url: u, thumb: model.thumb(u), selected: model.selection.contains(u), list: model.list)
      .background(GeometryReader { g in Color.clear.preference(key: ShelfFrames.self, value: [u: g.frame(in: .named("shelf"))]) })
      .contentShape(Rectangle())
      .gesture(fileDrag { model.targets(u, select: true) })
      .simultaneousGesture(TapGesture(count: 2).onEnded { NSWorkspace.shared.open(u) })
      .onTapGesture {
        let f = NSEvent.modifierFlags
        model.click(u, command: f.contains(.command), shift: f.contains(.shift))
      }
      .contextMenu { menu(model.targets(u)) }
      .transition(.shelfItem)
  }

  private var rubberBand: some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .named("shelf"))
      .onChanged { v in
        if band == nil { bandBase = NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty ? [] : model.selection }
        let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                       width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
        band = r
        model.rubberBand(r, base: bandBase)
      }
      .onEnded { _ in band = nil }
  }

  @ViewBuilder private func menu(_ urls: [URL]) -> some View {
    Button("Open") { urls.forEach { NSWorkspace.shared.open($0) } }
    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    Button("Quick Look") { model.selection = Set(urls); panel?.quickLook() }
    Button("Copy") { _ = ActionTools.copy(urls) }
    ShareLink(items: urls) { Label("Share…", systemImage: "square.and.arrow.up") }
    Divider()
    Button("Remove from Shelf") { model.remove(urls) }
    Button("Clear All") { model.clear() }
  }
}

struct ShelfCell: View {
  let url: URL, thumb: NSImage, selected: Bool, list: Bool

  var body: some View {
    let name = url.lastPathComponent
    if list {
      HStack(spacing: 8) {
        Image(nsImage: thumb).resizable().scaledToFit().frame(width: 22, height: 22)
        Text(name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
        Spacer(minLength: 6)
        Text(info.size).font(.system(size: 11).monospacedDigit()).foregroundStyle(selected ? .black.opacity(0.7) : .secondary)
        Text(info.kind).font(.system(size: 11)).lineLimit(1).foregroundStyle(selected ? .black.opacity(0.7) : .secondary)
          .frame(width: 84, alignment: .leading)
      }
      .foregroundStyle(selected ? Color.black : Color.primary)
      .padding(.horizontal, 8)
      .frame(height: 30)
      .background(selected ? lemonYellow : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    } else {
      VStack(spacing: 4) {
        Image(nsImage: thumb).resizable().scaledToFit()
          .frame(width: 56, height: 56)
          .padding(5)
          .background(selected ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        Text(name)
          .font(.system(size: 11, weight: .medium))
          .lineLimit(2).truncationMode(.middle)
          .multilineTextAlignment(.center)
          .foregroundStyle(selected ? Color.black : Color.primary)
          .padding(.horizontal, 4).padding(.vertical, 1)
          .background(selected ? lemonYellow : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
      }
      .frame(width: ShelfGeo.cell.width, height: ShelfGeo.cell.height, alignment: .top)
    }
  }

  private var info: (size: String, kind: String) {
    let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .localizedTypeDescriptionKey])
    let size = v?.isDirectory == true ? "--" : ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)
    return (size, v?.localizedTypeDescription ?? url.pathExtension.uppercased())
  }
}

/// SwiftUI drop target; reading the providers' URLs also extends the sandbox to them.
struct ShelfDrop: DropDelegate {
  let model: ShelfModel

  func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) && Shelves.dragSource !== model }
  func dropEntered(info: DropInfo) { if validateDrop(info: info) { model.dropTarget = true } }
  func dropExited(info: DropInfo) { model.dropTarget = false }

  func performDrop(info: DropInfo) -> Bool {
    model.dropTarget = false
    let providers = info.itemProviders(for: [.fileURL])
    Task { @MainActor in
      var urls: [URL] = []
      for p in providers {
        let u: URL? = await withCheckedContinuation { c in _ = p.loadObject(ofClass: URL.self) { u, _ in c.resume(returning: u) } }
        if let u { urls.append(u) }
      }
      model.add(urls)
    }
    return true
  }
}
