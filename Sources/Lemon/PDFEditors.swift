import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared

private let reflow = Animation.spring(response: 0.32, dampingFraction: 0.75)

fileprivate extension View {
  /// Lets neighbouring glass shapes blend and morph on macOS 26+.
  @MainActor @ViewBuilder func glassGroup(_ spacing: CGFloat) -> some View {
    if #available(macOS 26.0, *), !lemonPlainRender { GlassEffectContainer(spacing: spacing) { self } } else { self }
  }
}

/// Page thumbnails rendered off the main thread, cached per file and page.
@MainActor final class PageThumbs: ObservableObject {
  @Published private(set) var images: [String: NSImage] = [:]
  @Published private(set) var sizes: [String: CGSize] = [:]  // points, as displayed
  private var started: Set<URL> = []

  static func key(_ u: URL, _ page: Int) -> String { "\(u.path)#\(page)" }

  /// Starts rendering `u` (all pages, or just the first `limit`); awaitable for offscreen renders.
  @discardableResult func load(_ u: URL, limit: Int = .max) -> Task<Void, Never> {
    guard started.insert(u).inserted else { return Task {} }
    return Task.detached(priority: .userInitiated) { [weak self] in
      if FileKind(u) != .pdf {
        let img = ImageTools.preview(u, maxPixel: 360), size = ImageTools.orientedSize(u)
        await self?.set(u, 0, img, size)
        return
      }
      guard let doc = PDFDocument(url: u), !doc.isLocked else { return }
      for i in 0..<min(doc.pageCount, limit) {
        guard let p = doc.page(at: i) else { continue }
        let img = p.thumbnail(of: NSSize(width: 360, height: 360), for: .cropBox)
        await self?.set(u, i, img, PDFTools.displayedSize(p))
      }
    }
  }

  private func set(_ u: URL, _ i: Int, _ img: NSImage?, _ size: CGSize) {
    let k = Self.key(u, i)
    images[k] = img
    sizes[k] = size
  }
}

/// Live reorder: items spring aside as a drag passes over them. Finder files dropped on an item go to `onFiles`.
struct ReorderDelegate<Item: Identifiable>: DropDelegate {
  let item: Item
  @Binding var items: [Item]
  @Binding var dragging: Item.ID?
  var onFiles: (([URL]) -> Void)? = nil

  func dropEntered(info: DropInfo) {
    guard let d = dragging, d != item.id, let from = items.firstIndex(where: { $0.id == d }),
          let to = items.firstIndex(where: { $0.id == item.id }) else { return }
    withAnimation(reflow) { items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to) }
  }

  func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: dragging == nil ? .copy : .move) }

  func performDrop(info: DropInfo) -> Bool {
    if dragging != nil { dragging = nil; return true }
    guard let onFiles else { return false }
    loadFileURLs(info.itemProviders(for: [.fileURL]), onFiles)
    return true
  }
}

@MainActor func loadFileURLs(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) {
  Task { @MainActor in
    var urls: [URL] = []
    for p in providers {
      let u: URL? = await withCheckedContinuation { c in _ = p.loadObject(ofClass: NSURL.self) { o, _ in c.resume(returning: o as? URL) } }
      if let u { urls.append(u) }
    }
    if !urls.isEmpty { done(urls) }
  }
}

@MainActor private func circleTool(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
  Button(action: action) { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 32, height: 32) }
    .lemonButton(shape: .circle)
    .help(help)
}

private func label(_ title: String, _ value: String? = nil) -> some View {
  HStack {
    Text(title).font(.system(size: 12, weight: .semibold))
    Spacer()
    if let value {
      Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit()).contentTransition(.numericText()).animation(.snappy, value: value)
    }
  }
}

/// Glass panel for the inspector column.
@MainActor private func inspectorCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
  VStack(alignment: .leading, spacing: 16, content: content)
    .padding(14)
    .frame(width: 300)
    .frame(maxHeight: .infinity, alignment: .top)
    .lemonGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
}

// MARK: - Organize PDF

struct OrganizeEditor: View {
  let close: () -> Void
  @State private var sources: [URL]
  @State private var pages: [PageRef]
  @State private var selection: Set<UUID> = []
  @State private var anchor: UUID?
  @State private var history: [[PageRef]] = []
  @State private var equalize = false
  @State private var zoom: CGFloat = 130
  @State private var dragging: UUID?
  @State private var dropTarget = false
  @ObservedObject private var thumbs: PageThumbs
  @Namespace private var ns

  init(urls: [URL], close: @escaping () -> Void, thumbs: PageThumbs? = nil) {
    self.close = close
    _sources = State(initialValue: urls)
    _pages = State(initialValue: PDFTools.allPages(urls))
    let thumbs = thumbs ?? PageThumbs()
    self.thumbs = thumbs
    urls.forEach { thumbs.load($0) }
  }

  private var selected: [PageRef] { pages.filter { selection.contains($0.id) } }
  private var maxWidth: CGFloat { pages.map { shown($0).width }.max() ?? 1 }
  private var multi: Bool { Set(pages.map(\.source)).count > 1 }

  private func size(_ p: PageRef) -> CGSize { thumbs.sizes[PageThumbs.key(sources[p.source], p.page)] ?? CGSize(width: 612, height: 792) }
  private func shown(_ p: PageRef) -> CGSize { let s = size(p); return p.turns % 2 == 0 ? s : CGSize(width: s.height, height: s.width) }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: sources.count > 1 ? "Merge & Organize" : "Organize PDF",
                   subtitle: "\(pages.count) pages · \(sources.count == 1 ? sources[0].lastPathComponent : "\(sources.count) files")",
                   symbol: "square.grid.3x3", close: close)
      ZStack(alignment: .bottom) {
        grid
        toolbar.padding(.bottom, 12)
      }
      HStack(spacing: 10) {
        Chips(options: [false, true], label: { $0 ? "Equal widths" : "Original sizes" }, selection: $equalize)
        Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
        Slider(value: $zoom, in: 80...240).tint(lemonYellow).frame(width: 120)
        Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
        Spacer()
        Text(selection.isEmpty ? "Drop PDFs or images to insert" : "\(selection.count) selected")
          .font(.system(size: 12)).foregroundStyle(.secondary).contentTransition(.numericText())
        Button("Save PDF") { apply() }
          .lemonButton(primary: true)
          .keyboardShortcut(.defaultAction)
          .disabled(pages.isEmpty)
      }
    }
    .animation(reflow, value: equalize)
  }

  private var grid: some View {
    ScrollView {
      LazyVGrid(columns: [GridItem(.adaptive(minimum: zoom, maximum: zoom), spacing: 16)], spacing: 16) {
        ForEach(Array(pages.enumerated()), id: \.element.id) { i, p in
          cell(p, number: i + 1)
            .onDrag {
              history.append(pages)
              dragging = p.id
              return NSItemProvider(object: p.id.uuidString as NSString)
            }
            .onDrop(of: [.text, .fileURL], delegate: ReorderDelegate(item: p, items: $pages, dragging: $dragging) { insert($0, at: i) })
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
      }
      .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 70)  // room for the floating toolbar
      .animation(reflow, value: zoom)
    }
    .background(Color.black.opacity(dropTarget ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(lemonYellow, lineWidth: dropTarget ? 2 : 0))
    .onDrop(of: [.fileURL], isTargeted: $dropTarget) { loadFileURLs($0) { insert($0, at: pages.count) }; return true }
    .onTapGesture { withAnimation(.snappy) { selection = []; dragging = nil } }
  }

  private func cell(_ p: PageRef, number: Int) -> some View {
    let box = CGSize(width: zoom, height: zoom * 1.3)
    let s = shown(p)
    var fit = aspectFit(s, in: box)
    if !equalize { fit = CGSize(width: fit.width * s.width / maxWidth, height: fit.height * s.width / maxWidth) }
    let base = p.turns % 2 == 0 ? fit : CGSize(width: fit.height, height: fit.width)
    let on = selection.contains(p.id)
    return VStack(spacing: 6) {
      ZStack {
        if let img = thumbs.images[PageThumbs.key(sources[p.source], p.page)] {
          Image(nsImage: img).resizable().transition(.opacity)
        } else {
          Color.white.overlay(ProgressView().controlSize(.small))
        }
      }
      .frame(width: base.width, height: base.height)
      .background(.white)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .rotationEffect(.degrees(Double(p.turns) * 90))
      .shadow(color: .black.opacity(on ? 0.35 : 0.2), radius: on ? 10 : 5, y: 3)
      .frame(width: box.width, height: box.height)
      .padding(4)
      .background {
        if on { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(lemonYellow, lineWidth: 3) }
      }
      .scaleEffect(dragging == p.id ? 0.92 : on ? 1.03 : 1)
      .opacity(dragging == p.id ? 0.5 : 1)
      Text(multi ? "\(number) · \(sources[p.source].deletingPathExtension().lastPathComponent)" : "\(number)")
        .font(.system(size: 11, weight: on ? .bold : .medium).monospacedDigit())
        .lineLimit(1).truncationMode(.middle)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(on ? lemonYellow : .clear, in: Capsule())
        .foregroundStyle(on ? Color.black : Color.secondary)
        .contentTransition(.numericText())
    }
    .contentShape(Rectangle())
    .onTapGesture { tap(p) }
    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: on)
  }

  /// Floating glass tools over the grid; they morph in when something is selected.
  private var toolbar: some View {
    HStack(spacing: 6) {
      circleTool("arrow.uturn.backward", "Undo (⌘Z)") { undo() }.keyboardShortcut("z").disabled(history.isEmpty)
      circleTool("checkmark.circle", "Select all (⌘A)") { withAnimation(.snappy) { selection = Set(pages.map(\.id)) } }.keyboardShortcut("a")
      if !selection.isEmpty {
        Group {
          circleTool("rotate.left", "Rotate left") { rotate(-1) }.keyboardShortcut(.leftArrow)
          circleTool("rotate.right", "Rotate right") { rotate(1) }.keyboardShortcut(.rightArrow)
          circleTool("plus.square.on.square", "Duplicate (⌘D)") { duplicate() }.keyboardShortcut("d")
          circleTool("trash", "Delete (⌫)") { delete() }.keyboardShortcut(.delete, modifiers: [])
        }
        .transition(.scale(scale: 0.6).combined(with: .opacity))
      }
    }
    .padding(6)
    .lemonGlass(Capsule())
    .glassGroup(6)
    .animation(.spring(response: 0.35, dampingFraction: 0.75), value: selection.isEmpty)
  }

  // MARK: Edits

  private func tap(_ p: PageRef) {
    let flags = NSEvent.modifierFlags
    withAnimation(.snappy) {
      if flags.contains(.shift), let a = anchor, let i = pages.firstIndex(where: { $0.id == a }), let j = pages.firstIndex(of: p) {
        selection.formUnion(pages[min(i, j)...max(i, j)].map(\.id))
      } else if flags.contains(.command) {
        if selection.remove(p.id) == nil { selection.insert(p.id) }
        anchor = p.id
      } else {
        selection = [p.id]
        anchor = p.id
      }
      dragging = nil
    }
  }

  private func edit(_ change: () -> Void) {
    history.append(pages)
    withAnimation(.spring(response: 0.45, dampingFraction: 0.72), change)
  }

  private func undo() {
    guard let last = history.popLast() else { return }
    withAnimation(reflow) { pages = last; selection.formIntersection(pages.map(\.id)) }
  }

  private func rotate(_ d: Int) { edit { for i in pages.indices where selection.contains(pages[i].id) { pages[i].turns += d } } }

  private func delete() { edit { pages.removeAll { selection.contains($0.id) }; selection = [] } }

  private func duplicate() {
    edit {
      let copies = selected.map { PageRef(source: $0.source, page: $0.page, turns: $0.turns) }
      let at = (pages.lastIndex { selection.contains($0.id) } ?? pages.count - 1) + 1
      pages.insert(contentsOf: copies, at: at)
      selection = Set(copies.map(\.id))
    }
  }

  private func insert(_ urls: [URL], at index: Int) {
    let files = urls.filter { [.pdf, .image].contains(FileKind($0)) && PDFTools.pageCount($0) > 0 }
    guard !files.isEmpty else { return Toast.show("Only PDFs and images can be inserted", symbol: "exclamationmark.triangle") }
    edit {
      var new: [PageRef] = []
      for u in files {
        let s = sources.firstIndex(of: u) ?? { sources.append(u); thumbs.load(u); return sources.count - 1 }()
        new += (0..<PDFTools.pageCount(u)).map { PageRef(source: s, page: $0) }
      }
      pages.insert(contentsOf: new, at: min(index, pages.count))
      selection = Set(new.map(\.id))
    }
  }

  private func apply() {
    let s = sources, p = pages, eq = equalize
    close()
    Runner.perform("Organize PDF", symbol: "square.grid.3x3") { [try PDFTools.organize(s, pages: p, equalizeWidths: eq)] }
  }
}

// MARK: - Merge PDFs

struct MergeEditor: View {
  struct Doc: Identifiable { let id = UUID(); let url: URL; let pages: Int }

  let close: () -> Void
  @State private var docs: [Doc]
  @State private var dragging: UUID?
  @ObservedObject private var thumbs: PageThumbs

  init(urls: [URL], close: @escaping () -> Void, thumbs: PageThumbs? = nil) {
    self.close = close
    _docs = State(initialValue: urls.map { Doc(url: $0, pages: PDFTools.pageCount($0)) })
    let thumbs = thumbs ?? PageThumbs()
    self.thumbs = thumbs
    urls.forEach { thumbs.load($0, limit: 1) }
  }

  private var total: Int { docs.map(\.pages).reduce(0, +) }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Merge PDFs", subtitle: "\(docs.count) documents · \(total) pages", symbol: "doc.on.doc", close: close)
      ScrollView {
        VStack(spacing: 8) {
          ForEach(Array(docs.enumerated()), id: \.element.id) { i, d in
            row(d, number: i + 1)
              .onDrag { dragging = d.id; return NSItemProvider(object: d.id.uuidString as NSString) }
              .onDrop(of: [.text], delegate: ReorderDelegate(item: d, items: $docs, dragging: $dragging))
          }
        }
        .padding(4)
        .glassGroup(8)
      }
      HStack {
        Text("Drag to change the order").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Button("Organize pages…") {
          let urls = docs.map(\.url), t = thumbs
          close()
          EditorWindow.show(size: CGSize(width: 900, height: 680)) { OrganizeEditor(urls: urls, close: $0, thumbs: t) }
        }
        .lemonButton()
        Button("Merge \(docs.count)") { apply() }
          .lemonButton(primary: true)
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func row(_ d: Doc, number: Int) -> some View {
    HStack(spacing: 12) {
      Text("\(number)").font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
        .frame(width: 22).foregroundStyle(.secondary).contentTransition(.numericText())
      Group {
        if let img = thumbs.images[PageThumbs.key(d.url, 0)] { Image(nsImage: img).resizable().scaledToFit() } else { Color.white }
      }
      .frame(width: 40, height: 52)
      .background(.white)
      .clipShape(RoundedRectangle(cornerRadius: 4))
      .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(d.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
        Text(d.pages == 1 ? "1 page" : "\(d.pages) pages").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      Spacer()
      Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
    .lemonGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .scaleEffect(dragging == d.id ? 1.03 : 1)
    .opacity(dragging == d.id ? 0.6 : 1)
    .contentShape(Rectangle())
  }

  private func apply() {
    let urls = docs.map(\.url)
    close()
    Runner.perform("Merge PDFs", symbol: "doc.on.doc") { [try PDFTools.merge(urls)] }
  }
}

// MARK: - Image strip (Create PDF, Collage)

struct ImageItem: Identifiable {
  let id = UUID()
  let url: URL
  let image: NSImage?
  init(_ url: URL) { self.url = url; image = ImageTools.preview(url, maxPixel: 800) }
}

struct ImageStrip: View {
  @Binding var items: [ImageItem]
  @Binding var selected: UUID?
  @State private var dragging: UUID?

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
          ZStack(alignment: .topLeading) {
            if let img = item.image { Image(nsImage: img).resizable().scaledToFill() } else { Color.gray }
            Text("\(i + 1)").font(.system(size: 9, weight: .bold).monospacedDigit())
              .padding(.horizontal, 5).padding(.vertical, 2)
              .background(.black.opacity(0.5), in: Capsule()).foregroundStyle(.white).padding(3)
              .contentTransition(.numericText())
          }
          .frame(width: 54, height: 54)
          .clipShape(RoundedRectangle(cornerRadius: 9))
          .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(item.id == selected ? lemonYellow : .clear, lineWidth: 2.5))
          .scaleEffect(dragging == item.id ? 0.9 : item.id == selected ? 1.06 : 1)
          .opacity(dragging == item.id ? 0.5 : 1)
          .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { selected = item.id; dragging = nil } }
          .onDrag { dragging = item.id; return NSItemProvider(object: item.id.uuidString as NSString) }
          .onDrop(of: [.text], delegate: ReorderDelegate(item: item, items: $items, dragging: $dragging))
        }
      }
      .padding(6)
    }
    .frame(height: 70)
    .lemonGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}

// MARK: - Create PDF

struct CreatePDFEditor: View {
  let close: () -> Void
  @State private var items: [ImageItem]
  @State private var selected: UUID?
  @State private var setup = PageSetup()
  private let pixels: [URL: CGSize]

  init(urls: [URL], close: @escaping () -> Void) {
    self.close = close
    let items = urls.map(ImageItem.init)
    _items = State(initialValue: items)
    _selected = State(initialValue: items.first?.id)
    pixels = Dictionary(urls.map { ($0, ImageTools.orientedSize($0)) }, uniquingKeysWith: { a, _ in a })
  }

  private var current: ImageItem? { items.first { $0.id == selected } ?? items.first }
  private var geometry: (page: CGSize, content: CGRect, image: CGRect) { setup.geometry(current.flatMap { pixels[$0.url] } ?? CGSize(width: 1, height: 1)) }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Create PDF", subtitle: subtitle(items.map(\.url)), symbol: "doc.badge.plus", close: close)
      HStack(alignment: .top, spacing: 18) {
        GeometryReader { g in preview(g.size) }
        controls
      }
      if items.count > 1 { ImageStrip(items: $items, selected: $selected) }
      HStack {
        Text(items.count == 1 ? "1 page" : "\(items.count) pages").font(.system(size: 12)).foregroundStyle(.secondary)
          .contentTransition(.numericText())
        Spacer()
        Button("Create PDF") { apply() }
          .lemonButton(primary: true)
          .keyboardShortcut(.defaultAction)
      }
    }
    .animation(.spring(response: 0.42, dampingFraction: 0.78), value: setup)
    .animation(.spring(response: 0.42, dampingFraction: 0.78), value: selected)
  }

  /// The page as a white sheet with the image placed exactly as the engine will draw it.
  private func preview(_ box: CGSize) -> some View {
    let g = geometry
    let fit = aspectFit(g.page, in: CGSize(width: box.width - 30, height: box.height - 30))
    let k = fit.width / max(g.page.width, 1)
    return ZStack(alignment: .topLeading) {
      Color.white
      if let img = current?.image {
        Image(nsImage: img).resizable()
          .frame(width: g.image.width * k, height: g.image.height * k)
          .offset(x: (g.image.minX - g.content.minX) * k, y: (g.image.minY - g.content.minY) * k)
          .frame(width: g.content.width * k, height: g.content.height * k, alignment: .topLeading)
          .clipped()
          .offset(x: g.content.minX * k, y: g.content.minY * k)
      }
      Rectangle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(lemonYellow.opacity(0.9))
        .frame(width: g.content.width * k, height: g.content.height * k)
        .offset(x: g.content.minX * k, y: g.content.minY * k)
        .opacity(setup.margin > 0 ? 1 : 0)
    }
    .frame(width: fit.width, height: fit.height)
    .clipShape(RoundedRectangle(cornerRadius: 3))
    .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    .frame(width: box.width, height: box.height)
  }

  private var controls: some View {
    inspectorCard {
      VStack(alignment: .leading, spacing: 6) {
        label("Page size")
        Chips(options: PageSetup.Size.allCases, label: \.rawValue, selection: $setup.size)
      }
      VStack(alignment: .leading, spacing: 6) {
        label("Orientation")
        Chips(options: PageSetup.Orientation.allCases, label: \.rawValue, selection: $setup.orientation)
      }
      .opacity(setup.size == .fit ? 0.4 : 1)
      .disabled(setup.size == .fit)
      VStack(alignment: .leading, spacing: 6) {
        label("Margins", "\(Int(setup.margin)) pt")
        Slider(value: $setup.margin, in: 0...72, step: 6).tint(lemonYellow)
      }
      VStack(alignment: .leading, spacing: 6) {
        label("Image")
        Chips(options: PageSetup.Fit.allCases, label: \.rawValue, selection: $setup.fit)
      }
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 2) {
        Text("\(Int(geometry.page.width)) × \(Int(geometry.page.height)) pt")
          .font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit()).contentTransition(.numericText())
        Text(String(format: "%.0f × %.0f mm", geometry.page.width / 72 * 25.4, geometry.page.height / 72 * 25.4))
          .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
      }
    }
  }

  private func apply() {
    let urls = items.map(\.url), s = setup
    close()
    Runner.perform("Create PDF", symbol: "doc.badge.plus") { [try ImageTools.toPDF(urls, setup: s)] }
  }
}

// MARK: - Collage

struct CollageEditor: View {
  struct RenderKey: Equatable { let layout: CollageLayout; let order: [UUID] }

  let close: () -> Void
  @State private var items: [ImageItem]
  @State private var selected: UUID?
  @State private var layout = CollageLayout()
  @State private var preview: NSImage?
  private static let swatches: [CGColor] = [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 0.95, green: 0.94, blue: 0.9, alpha: 1),
                                            CGColor(red: 1, green: 0.78, blue: 0.1, alpha: 1), CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)]

  init(urls: [URL], close: @escaping () -> Void) {
    self.close = close
    _items = State(initialValue: urls.map(ImageItem.init))
  }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Collage", subtitle: subtitle(items.map(\.url)), symbol: "square.grid.2x2", close: close)
      HStack(alignment: .top, spacing: 18) {
        GeometryReader { g in
          let fit = aspectFit(layout.preset.size, in: CGSize(width: g.size.width - 30, height: g.size.height - 30))
          Group {
            if let preview { Image(nsImage: preview).resizable() } else { Color(cgColor: layout.background) }
          }
          .frame(width: fit.width, height: fit.height)
          .clipShape(RoundedRectangle(cornerRadius: 4))
          .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
          .frame(width: g.size.width, height: g.size.height)
          .animation(.spring(response: 0.42, dampingFraction: 0.78), value: layout.preset)
        }
        controls
      }
      ImageStrip(items: $items, selected: $selected)
      HStack {
        Text("Drag thumbnails to reorder").font(.system(size: 12)).foregroundStyle(.secondary)
        Spacer()
        Button("Create Collage") { apply() }
          .lemonButton(primary: true)
          .keyboardShortcut(.defaultAction)
      }
    }
    .task(id: RenderKey(layout: layout, order: items.map(\.id))) { await render() }
  }

  private var controls: some View {
    inspectorCard {
      VStack(alignment: .leading, spacing: 6) {
        label("Layout")
        Chips(options: CollageLayout.Style.allCases, label: \.rawValue, selection: $layout.style)
      }
      VStack(alignment: .leading, spacing: 6) {
        label("Size", "\(Int(layout.preset.size.width)) × \(Int(layout.preset.size.height))")
        Chips(options: CollageLayout.Preset.allCases, label: \.rawValue, selection: $layout.preset)
      }
      VStack(alignment: .leading, spacing: 6) {
        label("Spacing", "\(Int(layout.spacing)) px")
        Slider(value: $layout.spacing, in: 0...80, step: 2).tint(lemonYellow)
      }
      VStack(alignment: .leading, spacing: 6) {
        label("Corners", "\(Int(layout.radius)) px")
        Slider(value: $layout.radius, in: 0...120, step: 4).tint(lemonYellow)
      }
      VStack(alignment: .leading, spacing: 8) {
        label("Background")
        HStack(spacing: 8) {
          ForEach(Self.swatches, id: \.self) { c in
            Circle().fill(Color(cgColor: c)).frame(width: 24, height: 24)
              .overlay(Circle().strokeBorder(Color.primary.opacity(0.15)))
              .overlay(Circle().strokeBorder(lemonYellow, lineWidth: layout.background == c ? 3 : 0).padding(-4))
              .onTapGesture { withAnimation(.snappy) { layout.background = c } }
          }
          ColorPicker("", selection: $layout.background, supportsOpacity: false).labelsHidden()
        }
      }
    }
  }

  /// Small render off the main thread; `task(id:)` cancels it when settings change mid-render.
  private func render() async {
    try? await Task.sleep(nanoseconds: 60_000_000)  // debounce slider drags
    if Task.isCancelled { return }
    let l = layout, imgs = items.compactMap { $0.image?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    let scale = 900 / max(l.preset.size.width, l.preset.size.height)
    let cg = await Task.detached { l.render(imgs, scale: scale) }.value
    if Task.isCancelled { return }
    if let cg { withAnimation(.easeOut(duration: 0.15)) { preview = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) } }
  }

  private func apply() {
    let urls = items.map(\.url), l = layout
    close()
    Runner.perform("Collage", symbol: "square.grid.2x2") { [try ImageTools.collage(urls, layout: l)] }
  }
}
