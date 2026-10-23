import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// Timeline editors work on one file: one window per dropped file.
@MainActor func eachWindow<V: View>(_ urls: [URL], size: CGSize, _ make: @escaping (URL, @escaping () -> Void) -> V) {
  for u in urls { EditorWindow.show(size: size) { make(u, $0) } }
}

private let spring = Animation.spring(response: 0.35, dampingFraction: 0.78)

/// Header, a stage (video or big waveform), an optional controls column and a glass bar with the timeline.
struct MediaScaffold<Stage: View, Side: View, Bar: View>: View {
  let title: String, symbol: String
  @ObservedObject var clip: MediaClip
  let close: () -> Void
  @ViewBuilder var stage: Stage
  @ViewBuilder var side: Side
  @ViewBuilder var bar: Bar

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: title, subtitle: clip.url.lastPathComponent, symbol: symbol) { clip.stop(); close() }
      HStack(alignment: .top, spacing: 16) {
        stage.frame(maxWidth: .infinity, maxHeight: .infinity)
        side
      }
      VStack(spacing: 10) { bar }
        .padding(12)
        .lemonGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
  }
}

/// Video preview for video, the waveform timeline (with the same marks) for audio.
@MainActor @ViewBuilder func stageOrWave(_ clip: MediaClip, range: Binding<ClosedRange<Double>>? = nil, markers: [Double] = [],
                                         shaded: [ClosedRange<Double>] = []) -> some View {
  if clip.isVideo {
    MediaStage(clip: clip)
  } else {
    TimelineView(clip: clip, range: range, markers: markers, shaded: shaded)
      .padding(14)
      .lemonGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay(LoadingBadge(clip: clip))
  }
}

struct Labeled<Content: View>: View {
  let title: String
  var value: String? = nil
  @ViewBuilder var content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(title).font(.system(size: 12, weight: .semibold))
        Spacer()
        if let value {
          Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit()).contentTransition(.numericText()).animation(.snappy, value: value)
        }
      }
      content
    }
  }
}

@MainActor func applyButton(_ title: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
  Button(title, action: action).lemonButton(primary: true).keyboardShortcut(.defaultAction).disabled(disabled)
}

func info(_ text: String) -> some View {
  Text(text).font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
}

// MARK: - Trim

struct TrimEditor: View {
  let close: () -> Void
  @StateObject private var clip: MediaClip
  @State private var range = 0.0...1.0
  @State private var autoSilence = false
  @State private var threshold = -45.0
  @State private var job: Task<Void, Never>?

  init(url: URL, close: @escaping () -> Void) {
    _clip = StateObject(wrappedValue: MediaClip.make(url))
    self.close = close
  }

  var body: some View {
    MediaScaffold(title: "Trim", symbol: "scissors", clip: clip, close: close) {
      stageOrWave(clip, range: $range)
    } side: {
      EmptyView()
    } bar: {
      if clip.isVideo { TimelineView(clip: clip, range: $range).frame(height: 64) }
      HStack(spacing: 12) {
        Transport(clip: clip)
        if !clip.isVideo {
          Toggle("Auto-trim silence", isOn: $autoSilence).toggleStyle(.switch).controlSize(.small).tint(lemonYellow)
          if autoSilence {
            Slider(value: $threshold, in: -70...(-20)).frame(width: 110).tint(lemonYellow)
            info("\(Int(threshold)) dB").frame(width: 44, alignment: .leading)
          }
        }
        Spacer()
        info("\(timecode(range.lowerBound)) – \(timecode(range.upperBound)) · \(String(format: "%.1f", range.upperBound - range.lowerBound)) s")
        Button("Reset") { withAnimation(spring) { autoSilence = false; range = 0...clip.duration } }.lemonButton()
        applyButton("Trim", disabled: !clip.ready) {
          let u = clip.url, r = range
          clip.stop(); close()
          Runner.perform("Trim", symbol: "scissors") { [try await MediaTools.trim(u, r)] }
        }
      }
    }
    .onAppear { if clip.duration > 0 { range = 0...clip.duration } }
    .onChange(of: clip.duration) { _, d in range = 0...d }
    .onChange(of: range) { _, r in clip.loop = r }
    .onChange(of: autoSilence) { detect() }
    .onChange(of: threshold) { detect() }
  }

  private func detect() {
    job?.cancel()
    guard autoSilence else { return }
    let u = clip.url, db = threshold
    job = Task {
      try? await Task.sleep(nanoseconds: 150_000_000)
      guard !Task.isCancelled, let r = try? await MediaTools.audibleRange(u, thresholdDB: db), !Task.isCancelled else { return }
      withAnimation(spring) { range = r }
    }
  }
}

// MARK: - Split

struct SplitEditor: View {
  enum Output: String, CaseIterable { case clips = "Separate clips", merged = "Merged" }
  let close: () -> Void
  @StateObject private var clip: MediaClip
  @State private var cuts: [Double] = []
  @State private var removed: Set<Int> = []
  @State private var output = Output.clips

  init(url: URL, close: @escaping () -> Void) {
    _clip = StateObject(wrappedValue: MediaClip.make(url))
    self.close = close
  }

  private var bounds: [Double] { [0] + cuts.sorted() + [clip.duration] }
  private var segments: [ClosedRange<Double>] { (0..<bounds.count - 1).map { bounds[$0]...bounds[$0 + 1] } }

  var body: some View {
    MediaScaffold(title: "Split", symbol: "scissors", clip: clip, close: close) {
      MediaStage(clip: clip)
    } side: {
      EmptyView()
    } bar: {
      TimelineView(clip: clip, markers: cuts.sorted(), shaded: removed.sorted().filter { $0 < segments.count }.map { segments[$0] }) { i in
        cuts.removeAll { $0 == cuts.sorted()[i] }
        removed = []
      }
      .frame(height: 64)
      ScrollView(.horizontal, showsIndicators: false) {
        GlassGroup(spacing: 6) {
          HStack(spacing: 6) {
            ForEach(segments.indices, id: \.self) { i in
              let off = removed.contains(i)
              Button {
                withAnimation(spring) { if off { removed.remove(i) } else { removed.insert(i) } }
              } label: {
                Label("\(i + 1) · \(timecode(segments[i].lowerBound))–\(timecode(segments[i].upperBound))",
                      systemImage: off ? "xmark.circle.fill" : "checkmark.circle.fill")
                  .strikethrough(off)
                  .font(.system(size: 11, weight: .semibold).monospacedDigit())
                  .foregroundStyle(off ? Color.secondary : Color.primary)
                  .padding(.horizontal, 10).padding(.vertical, 6)
                  .lemonGlass(Capsule(), tint: off ? .red.opacity(0.25) : lemonYellow.opacity(0.35), interactive: true)
              }
              .buttonStyle(.plain)
              .help(off ? "Keep this clip" : "Remove this clip")
            }
          }
          .padding(2)
        }
      }
      HStack(spacing: 12) {
        Transport(clip: clip)
        Button { withAnimation(spring) { addCut() } } label: { Label("Split at playhead", systemImage: "scissors") }
          .lemonButton()
          .keyboardShortcut("b", modifiers: [])
        Spacer()
        Chips(options: Output.allCases, label: \.rawValue, selection: $output)
        applyButton(output == .clips ? "Export \(segments.count - removed.count)" : "Export", disabled: cuts.isEmpty || removed.count == segments.count) {
          let u = clip.url, c = cuts, r = removed, m = output == .merged
          clip.stop(); close()
          Runner.perform("Split", symbol: "scissors") { try await MediaTools.split(u, cuts: c, removed: r, merged: m) }
        }
      }
    }
  }

  private func addCut() {
    let t = clip.time
    guard t > 0.1, t < clip.duration - 0.1, !cuts.contains(where: { abs($0 - t) < 0.1 }) else { return }
    // the clip being split keeps its removed state on both halves
    let seg = segments.firstIndex { $0.contains(t) } ?? 0
    removed = Set(removed.flatMap { $0 < seg ? [$0] : $0 == seg ? [$0, $0 + 1] : [$0 + 1] })
    cuts.append(t)
  }
}

// MARK: - Join

struct JoinEditor: View {
  struct Item: Identifiable { let id = UUID(); let url: URL; var thumb: CGImage?; var info: MediaInfo? }
  let close: () -> Void
  @State private var items: [Item]

  init(urls: [URL], close: @escaping () -> Void) {
    _items = State(initialValue: urls.map { Item(url: $0) })
    self.close = close
  }

  private var total: Double { items.compactMap { $0.info?.duration }.reduce(0, +) }

  var body: some View {
    VStack(spacing: 14) {
      EditorHeader(title: "Join videos", subtitle: "\(items.count) videos · drag to reorder", symbol: "rectangle.stack.badge.plus", close: close)
      List {
        ForEach(Array(items.enumerated()), id: \.element.id) { n, item in
          HStack(spacing: 12) {
            Text("\(n + 1)").font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
            ZStack {
              Color.black
              if let t = item.thumb { Image(decorative: t, scale: 1).resizable().scaledToFill() }
            }
            .frame(width: 80, height: 45).clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
              Text(item.url.lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
              if let i = item.info {
                info("\(timecode(i.duration)) · \(Int(i.size.width))×\(Int(i.size.height))" + (i.hasAudio ? "" : " · no sound"))
              }
            }
            Spacer()
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
          }
          .padding(.vertical, 6).padding(.horizontal, 10)
          .lemonGlass(RoundedRectangle(cornerRadius: 14, style: .continuous))
          .listRowSeparator(.hidden)
          .listRowBackground(Color.clear)
        }
        .onMove { items.move(fromOffsets: $0, toOffset: $1) }
      }
      .listStyle(.plain)
      .scrollContentBackground(.hidden)
      HStack(spacing: 12) {
        if let first = items.first?.info {
          info("MP4 · \(Int(first.size.width))×\(Int(first.size.height)) · \(timecode(total))")
        }
        Spacer()
        applyButton("Join \(items.count)", disabled: items.count < 2) {
          let urls = items.map(\.url)
          close()
          Runner.perform("Join", symbol: "rectangle.stack.badge.plus") { [try await MediaTools.join(urls)] }
        }
      }
      .padding(12)
      .lemonGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    .task {
      for i in items.indices {
        let u = items[i].url
        let probed = try? await FFmpeg.probe(u)
        let gen = (try? await MediaTools.playable(u)).map { AVAssetImageGenerator(asset: AVURLAsset(url: $0)) }
        gen?.appliesPreferredTrackTransform = true
        gen?.maximumSize = CGSize(width: 200, height: 200)
        let thumb = try? await gen?.image(at: CMTime(seconds: min(0.5, (probed?.duration ?? 1) / 2), preferredTimescale: 600)).image
        withAnimation(spring) { items[i].info = probed; items[i].thumb = thumb }
      }
    }
  }
}

// MARK: - Speed

struct SpeedEditor: View {
  let close: () -> Void
  @StateObject private var clip: MediaClip
  @State private var speed = 2.0
  @State private var keepAudio = true
  private static let presets = [0.25, 0.5, 1.5, 2, 4]

  init(url: URL, close: @escaping () -> Void) {
    _clip = StateObject(wrappedValue: MediaClip.make(url))
    self.close = close
  }

  var body: some View {
    MediaScaffold(title: "Change speed", symbol: "gauge.with.dots.needle.67percent", clip: clip, close: close) {
      stageOrWave(clip)
    } side: {
      VStack(alignment: .leading, spacing: 16) {
        Text(String(format: "%g×", speed))
          .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
          .contentTransition(.numericText(value: speed))
          .animation(spring, value: speed)
        Chips(options: Self.presets, label: { String(format: "%g×", $0) }, selection: $speed)
        Labeled(title: "Custom") {
          Slider(value: Binding(get: { speed }, set: { speed = ($0 * 20).rounded() / 20 }), in: 0.25...4).tint(lemonYellow)
        }
        if clip.isVideo { Toggle("Keep sound", isOn: $keepAudio).toggleStyle(.switch).controlSize(.small).tint(lemonYellow) }
        Spacer(minLength: 0)
      }
      .frame(width: 250)
    } bar: {
      if clip.isVideo { TimelineView(clip: clip).frame(height: 50) }
      HStack(spacing: 12) {
        Transport(clip: clip)
        Spacer()
        info("\(timecode(clip.duration)) → \(timecode(clip.duration / speed))")
        applyButton("Apply", disabled: speed == 1 || !clip.ready) {
          let u = clip.url, f = speed, k = keepAudio
          clip.stop(); close()
          Runner.perform("Change speed", symbol: "gauge.with.dots.needle.67percent") { [try await MediaTools.speed(u, factor: f, keepAudio: k)] }
        }
      }
    }
    .onAppear { clip.rate = Float(speed) }
    .onChange(of: speed) { _, s in clip.rate = Float(s) }
  }
}

// MARK: - Snapshots

struct SnapshotsEditor: View {
  let close: () -> Void
  @StateObject private var clip: MediaClip
  @State private var times: [Double] = []

  init(url: URL, close: @escaping () -> Void) {
    _clip = StateObject(wrappedValue: MediaClip.make(url))
    self.close = close
  }

  var body: some View {
    MediaScaffold(title: "Snapshots", symbol: "photo.on.rectangle", clip: clip, close: close) {
      MediaStage(clip: clip)
    } side: {
      EmptyView()
    } bar: {
      TimelineView(clip: clip, markers: times) { i in times.remove(at: i) }.frame(height: 64)
      HStack(spacing: 12) {
        Transport(clip: clip)
        Button { withAnimation(spring) { add(clip.time) } } label: { Label("Add frame", systemImage: "plus") }
          .lemonButton()
          .keyboardShortcut("m", modifiers: [])
        Button("10 evenly") {
          withAnimation(spring) { times = (0..<10).map { clip.duration * (Double($0) + 0.5) / 10 } }
        }
        .lemonButton()
        Button("Clear") { withAnimation(spring) { times = [] } }.lemonButton().disabled(times.isEmpty)
        Spacer()
        applyButton(times.count == 1 ? "Save 1 PNG" : "Save \(times.count) PNGs", disabled: times.isEmpty) {
          let u = clip.url, t = times
          clip.stop(); close()
          Runner.perform("Snapshots", symbol: "photo.on.rectangle") { [try await MediaTools.snapshots(u, at: t)] }
        }
      }
    }
  }

  private func add(_ t: Double) {
    guard !times.contains(where: { abs($0 - t) < 0.04 }) else { return }
    times.append(t)
    times.sort()
  }
}

// MARK: - Redact video

struct RedactVideoEditor: View {
  let close: () -> Void
  @StateObject private var clip: MediaClip
  @State private var boxes: [Redaction] = []
  @State private var selected: Int?
  @State private var style = VideoRedactStyle.blur
  @State private var drawing: CGRect?
  @State private var moveStart: CGRect?
  @Namespace private var ns

  init(url: URL, close: @escaping () -> Void) {
    _clip = StateObject(wrappedValue: MediaClip.make(url))
    self.close = close
  }

  private var selectedRange: Binding<ClosedRange<Double>>? {
    guard let i = selected, i < boxes.count else { return nil }
    return Binding(get: { boxes[i].start...boxes[i].end }, set: { boxes[i].start = $0.lowerBound; boxes[i].end = $0.upperBound })
  }

  var body: some View {
    MediaScaffold(title: "Redact video", symbol: "eye.slash", clip: clip, close: close) {
      MediaStage(clip: clip) { r in canvas(r) }
    } side: {
      EmptyView()
    } bar: {
      TimelineView(clip: clip, range: selectedRange, shaded: boxes.indices.filter { $0 != selected }.map { boxes[$0].start...boxes[$0].end },
                   shade: .gray)
        .frame(height: 64)
      HStack(spacing: 12) {
        Transport(clip: clip)
        Chips(options: VideoRedactStyle.allCases, label: \.rawValue, selection: $style)
        if selected != nil {
          Button { withAnimation(spring) { deleteSelected() } } label: { Image(systemName: "trash").frame(width: 30, height: 30) }
            .lemonButton(shape: .circle)
            .keyboardShortcut(.delete, modifiers: [])
            .help("Delete the selected box")
            .transition(.scale.combined(with: .opacity))
        }
        Spacer()
        info(boxes.isEmpty ? "Drag on the video to cover an area" : "\(boxes.count) area\(boxes.count == 1 ? "" : "s")")
        applyButton("Redact", disabled: boxes.isEmpty) {
          let u = clip.url, b = boxes, s = style
          clip.stop(); close()
          Runner.perform("Redact", symbol: "eye.slash") { [try await MediaTools.redact(u, b, style: s)] }
        }
      }
    }
  }

  private func canvas(_ r: CGRect) -> some View {
    func px(_ n: CGRect) -> CGRect { CGRect(x: r.minX + n.minX * r.width, y: r.minY + n.minY * r.height, width: n.width * r.width, height: n.height * r.height) }
    func norm(_ a: CGPoint, _ b: CGPoint) -> CGRect {
      let p = CGPoint(x: min(max((a.x - r.minX) / r.width, 0), 1), y: min(max((a.y - r.minY) / r.height, 0), 1))
      let q = CGPoint(x: min(max((b.x - r.minX) / r.width, 0), 1), y: min(max((b.y - r.minY) / r.height, 0), 1))
      return CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(p.x - q.x), height: abs(p.y - q.y))
    }
    return ZStack(alignment: .topLeading) {
      Color.white.opacity(0.001)
        .frame(width: r.width, height: r.height)
        .offset(x: r.minX, y: r.minY)
        .gesture(
          DragGesture(minimumDistance: 4)
            .onChanged { v in drawing = norm(v.startLocation, v.location) }
            .onEnded { _ in
              if let d = drawing, d.width > 0.02, d.height > 0.02 {
                withAnimation(spring) {
                  boxes.append(Redaction(rect: d, start: 0, end: clip.duration))
                  selected = boxes.count - 1
                }
              }
              drawing = nil
            }
        )
        .onTapGesture { withAnimation(spring) { selected = nil } }
      ForEach(boxes.indices, id: \.self) { i in
        let b = px(boxes[i].rect), live = (boxes[i].start...boxes[i].end).contains(clip.time), on = selected == i
        box(live: live)
          .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? lemonYellow : .white.opacity(live ? 0.6 : 0.4),
                                                                  style: StrokeStyle(lineWidth: on ? 2.5 : 1.5, dash: live ? [] : [5, 4])))
          .frame(width: b.width, height: b.height)
          .contentShape(Rectangle())
          .offset(x: b.minX, y: b.minY)
          .onTapGesture { withAnimation(spring) { selected = i } }
          .gesture(
            DragGesture(minimumDistance: 2)
              .onChanged { v in
                if moveStart == nil { moveStart = boxes[i].rect; selected = i }
                guard let s = moveStart else { return }
                var n = s.offsetBy(dx: v.translation.width / r.width, dy: v.translation.height / r.height)
                n.origin.x = min(max(n.minX, 0), 1 - n.width)
                n.origin.y = min(max(n.minY, 0), 1 - n.height)
                boxes[i].rect = n
              }
              .onEnded { _ in moveStart = nil }
          )
          .onHover { $0 ? NSCursor.openHand.push() : NSCursor.pop() }
      }
      if let d = drawing {
        let b = px(d)
        RoundedRectangle(cornerRadius: 4).strokeBorder(lemonYellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
          .background(lemonYellow.opacity(0.12))
          .frame(width: b.width, height: b.height)
          .offset(x: b.minX, y: b.minY)
          .allowsHitTesting(false)
      }
    }
  }

  /// Preview of the style (the export does the real, irreversible version).
  @ViewBuilder private func box(live: Bool) -> some View {
    let shape = RoundedRectangle(cornerRadius: 4)
    if !live {
      shape.fill(Color.white.opacity(0.06))
    } else if style == .black {
      shape.fill(Color.black)
    } else if style == .pixelate {
      shape.fill(.ultraThinMaterial).overlay(Image(systemName: "square.grid.3x3.fill").font(.system(size: 18)).foregroundStyle(.white.opacity(0.6)))
    } else {
      shape.fill(.ultraThinMaterial)
    }
  }

  private func deleteSelected() {
    guard let i = selected, i < boxes.count else { return }
    boxes.remove(at: i)
    selected = nil
  }
}

// MARK: - Bleep (redact audio)

struct BleepEditor: View {
  enum Sound: String, CaseIterable { case bleep = "Bleep", silence = "Silence" }
  let close: () -> Void
  @StateObject private var clip: MediaClip
  @State private var ranges: [ClosedRange<Double>] = []
  @State private var selected = 0
  @State private var sound = Sound.bleep

  init(url: URL, close: @escaping () -> Void) {
    _clip = StateObject(wrappedValue: MediaClip.make(url))
    self.close = close
  }

  private var current: Binding<ClosedRange<Double>>? {
    guard selected < ranges.count else { return nil }
    return Binding(get: { ranges[selected] }, set: { ranges[selected] = $0 })
  }

  var body: some View {
    MediaScaffold(title: "Bleep audio", symbol: "waveform.badge.minus", clip: clip, close: close) {
      stageOrWave(clip, range: current, shaded: ranges.indices.filter { $0 != selected }.map { ranges[$0] })
    } side: {
      EmptyView()
    } bar: {
      ScrollView(.horizontal, showsIndicators: false) {
        GlassGroup(spacing: 6) {
          HStack(spacing: 6) {
            ForEach(ranges.indices, id: \.self) { i in
              HStack(spacing: 6) {
                Text("\(timecode(ranges[i].lowerBound))–\(timecode(ranges[i].upperBound))")
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                  .onTapGesture { withAnimation(spring) { ranges.remove(at: i); selected = max(0, min(selected, ranges.count - 1)) } }
              }
              .font(.system(size: 11, weight: .semibold).monospacedDigit())
              .padding(.horizontal, 10).padding(.vertical, 6)
              .lemonGlass(Capsule(), tint: i == selected ? lemonYellow.opacity(0.6) : nil, interactive: true)
              .onTapGesture { withAnimation(spring) { selected = i; clip.seek(ranges[i].lowerBound) } }
            }
          }
          .padding(2)
        }
      }
      .frame(height: ranges.isEmpty ? 0 : 34)
      HStack(spacing: 12) {
        Transport(clip: clip)
        Button { withAnimation(spring) { add() } } label: { Label("Mark at playhead", systemImage: "plus") }
          .lemonButton()
          .keyboardShortcut("m", modifiers: [])
        Chips(options: Sound.allCases, label: \.rawValue, selection: $sound)
        Spacer()
        applyButton(sound == .bleep ? "Bleep" : "Silence", disabled: ranges.isEmpty) {
          let u = clip.url, r = ranges, tone = sound == .bleep
          clip.stop(); close()
          Runner.perform("Bleep", symbol: "waveform.badge.minus") { [try await MediaTools.bleep(u, ranges: r, tone: tone)] }
        }
      }
    }
  }

  private func add() {
    let t = min(clip.time, max(clip.duration - 0.2, 0))
    ranges.append(t...min(t + 1, clip.duration))
    selected = ranges.count - 1
  }
}

// MARK: - Channels

struct ChannelsEditor: View {
  enum Layout: String, CaseIterable { case mono = "Mono", stereo = "Stereo" }
  let close: () -> Void
  @StateObject private var clip: MediaClip
  @State private var layout = Layout.stereo
  @State private var left = 1.0
  @State private var right = 1.0
  @State private var source: MediaInfo?

  init(url: URL, close: @escaping () -> Void) {
    _clip = StateObject(wrappedValue: MediaClip.make(url))
    self.close = close
  }

  var body: some View {
    MediaScaffold(title: "Audio channels", symbol: "speaker.wave.2", clip: clip, close: close) {
      stageOrWave(clip)
    } side: {
      VStack(alignment: .leading, spacing: 16) {
        Chips(options: Layout.allCases, label: \.rawValue, selection: $layout)
        Labeled(title: "Left", value: "\(Int(left * 100))%") { Slider(value: $left, in: 0...2).tint(lemonYellow) }
        Labeled(title: "Right", value: "\(Int(right * 100))%") { Slider(value: $right, in: 0...2).tint(lemonYellow) }
        if let s = source {
          info("Source: \(s.channels == 1 ? "mono" : s.channels == 2 ? "stereo" : "\(s.channels) channels") · \(s.sampleRate / 1000) kHz")
        }
        Spacer(minLength: 0)
      }
      .frame(width: 240)
    } bar: {
      HStack(spacing: 12) {
        Transport(clip: clip)
        Spacer()
        Button("Reset") { withAnimation(spring) { left = 1; right = 1 } }.lemonButton()
        applyButton("Apply") {
          let u = clip.url, st = layout == .stereo, l = left, r = right
          clip.stop(); close()
          Runner.perform("Audio channels", symbol: "speaker.wave.2") { [try await MediaTools.channels(u, stereo: st, left: l, right: r)] }
        }
      }
    }
    .task {
      source = try? await FFmpeg.probe(clip.url)
      if source?.channels == 1 { layout = .stereo }
    }
  }
}

// MARK: - Audio to video

enum VideoCanvas: String, CaseIterable {
  case landscape = "1080p", square = "Square", vertical = "Vertical"
  var size: CGSize { [CGSize(width: 1920, height: 1080), CGSize(width: 1080, height: 1080), CGSize(width: 1080, height: 1920)][Self.allCases.firstIndex(of: self)!] }
}

struct AudioToVideoEditor: View {
  enum Picture: String, CaseIterable { case waveform = "Waveform", image = "Image" }
  let close: () -> Void
  @StateObject private var clip: MediaClip
  @State private var picture = Picture.waveform
  @State private var canvas = VideoCanvas.landscape
  @State private var image: URL?
  @State private var preview: CGImage?

  init(url: URL, close: @escaping () -> Void) {
    _clip = StateObject(wrappedValue: MediaClip.make(url))
    self.close = close
  }

  var body: some View {
    MediaScaffold(title: "Audio to video", symbol: "film", clip: clip, close: close) {
      GeometryReader { g in
        let fit = aspectFit(canvas.size, in: g.size)
        ZStack {
          Color.black
          if let preview {
            Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit)
              .transition(.opacity)
          }
        }
        .frame(width: fit.width, height: fit.height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .frame(width: g.size.width, height: g.size.height)
        .animation(spring, value: canvas)
      }
    } side: {
      VStack(alignment: .leading, spacing: 16) {
        Labeled(title: "Picture") { Chips(options: Picture.allCases, label: \.rawValue, selection: $picture) }
        if picture == .image {
          Button { pick() } label: { Label(image?.lastPathComponent ?? "Choose image…", systemImage: "photo") .lineLimit(1) }
            .lemonButton()
        }
        Labeled(title: "Canvas", value: "\(Int(canvas.size.width))×\(Int(canvas.size.height))") {
          Chips(options: VideoCanvas.allCases, label: \.rawValue, selection: $canvas)
        }
        Spacer(minLength: 0)
      }
      .frame(width: 250)
    } bar: {
      HStack(spacing: 12) {
        Transport(clip: clip)
        Spacer()
        info("MP4 · \(timecode(clip.duration))")
        applyButton("Create video", disabled: picture == .image && image == nil) {
          let u = clip.url, img = picture == .image ? image : nil, size = canvas.size
          clip.stop(); close()
          Runner.perform("Audio to video", symbol: "film") { [try await MediaTools.audioToVideo(u, image: img, canvas: size)] }
        }
      }
    }
    .task(id: "\(picture)\(canvas)\(image?.path ?? "")") { await render() }
  }

  private func render() async {
    let img: CGImage?
    if picture == .image {
      img = image.flatMap { try? ImageTools.decode($0).0 }
    } else {
      img = try? await MediaTools.waveformImage(clip.url, size: CGSize(width: canvas.size.width / 3, height: canvas.size.height / 3))
    }
    withAnimation(spring) { preview = img }
  }

  private func pick() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.image]
    panel.message = "Choose a picture for the video"
    if panel.runModal() == .OK, let u = panel.url { image = u }
  }
}

// MARK: - Compress video

struct VideoCompressEditor: View {
  enum Level: String, CaseIterable { case balanced = "Balanced", strong = "Strong", custom = "Custom" }
  enum MaxSide: String, CaseIterable {
    case original = "Original", p1080 = "1080p", p720 = "720p", p480 = "480p"
    var pixels: Int? { [nil, 1920, 1280, 854][Self.allCases.firstIndex(of: self)!] }
  }
  let close: () -> Void
  @StateObject private var clip: MediaClip
  @State private var level = Level.balanced
  @State private var quality = 50.0
  @State private var codec = VideoCompressSettings.Codec.h264
  @State private var maxSide = MaxSide.original
  @State private var estimate: (bytes: Int, exact: Bool)?
  @State private var error: String?
  @State private var working = false
  private let originalBytes: Int

  init(url: URL, close: @escaping () -> Void) {
    _clip = StateObject(wrappedValue: MediaClip.make(url))
    self.close = close
    originalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
  }

  private var settings: VideoCompressSettings {
    VideoCompressSettings(quality: level == .balanced ? 50 : level == .strong ? 30 : Int(quality), codec: codec, maxSide: maxSide.pixels)
  }

  private var saved: Int {
    guard let e = estimate, originalBytes > 0 else { return 0 }
    return Int((1 - Double(e.bytes) / Double(originalBytes)) * 100)
  }

  var body: some View {
    MediaScaffold(title: "Compress video", symbol: "arrow.down.right.and.arrow.up.left", clip: clip, close: close) {
      MediaStage(clip: clip)
    } side: {
      VStack(alignment: .leading, spacing: 16) {
        Chips(options: Level.allCases, label: \.rawValue, selection: $level)
        if level == .custom {
          Labeled(title: "Quality", value: "\(Int(quality))") { Slider(value: $quality, in: 10...90, step: 1).tint(lemonYellow) }
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
        Labeled(title: "Encoder") { Chips(options: VideoCompressSettings.Codec.allCases, label: \.rawValue, selection: $codec) }
        Labeled(title: "Max size") { Chips(options: MaxSide.allCases, label: \.rawValue, selection: $maxSide) }
        Spacer(minLength: 0)
        resultCard
      }
      .frame(width: 270)
      .animation(spring, value: level)
    } bar: {
      HStack(spacing: 12) {
        Transport(clip: clip)
        Spacer()
        applyButton("Compress", disabled: error != nil) {
          let u = clip.url, s = settings
          clip.stop(); close()
          Runner.perform("Compress", symbol: "arrow.down.right.and.arrow.up.left") { [try await MediaTools.compressVideo(u, settings: s)] }
        }
      }
    }
    .task(id: settings) { await recompute() }
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
          Text(estimate.map { ($0.exact ? "" : "≈ ") + formatBytes($0.bytes) } ?? "…").fontWeight(.semibold).contentTransition(.numericText())
        }
        .font(.system(size: 12).monospacedDigit())
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .lemonGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .animation(spring, value: estimate?.bytes)
  }

  /// Encodes a sample (or all of a short video) whenever a setting changes; `.task(id:)` cancels the stale one.
  private func recompute() async {
    working = true
    try? await Task.sleep(nanoseconds: 250_000_000)
    if Task.isCancelled { return }
    do {
      let e = try await MediaTools.estimateCompressed(clip.url, settings: settings)
      if Task.isCancelled { return }
      withAnimation(spring) { estimate = e; error = nil }
    } catch {
      if !Task.isCancelled { self.error = error.localizedDescription }
    }
    working = false
  }
}

// MARK: - Normalize loudness

struct LoudnessEditor: View {
  enum Target: String, CaseIterable {
    case streaming = "Streaming", podcast = "Podcast", broadcast = "Broadcast", peak = "Peak"
    var lufs: Double? { [-14, -16, -23, nil][Self.allCases.firstIndex(of: self)!] }
  }
  let close: () -> Void
  @StateObject private var clip: MediaClip
  @State private var target = Target.podcast
  @State private var truePeak = -1.5
  @State private var measured: Loudness?
  @State private var error: String?

  init(url: URL, close: @escaping () -> Void) {
    _clip = StateObject(wrappedValue: MediaClip.make(url))
    self.close = close
  }

  var body: some View {
    MediaScaffold(title: "Normalize loudness", symbol: "speaker.wave.3", clip: clip, close: close) {
      stageOrWave(clip)
    } side: {
      VStack(alignment: .leading, spacing: 16) {
        Labeled(title: "Target", value: target.lufs.map { "\(Int($0)) LUFS" } ?? "−0.2 dBFS peak") {
          Chips(options: Target.allCases, label: \.rawValue, selection: $target)
        }
        if target != .peak {
          Labeled(title: "True peak", value: String(format: "%g dBTP", truePeak)) {
            Chips(options: [-1.0, -1.5, -2.0], label: { String(format: "%g", $0) }, selection: $truePeak)
          }
          .transition(.opacity)
        }
        Spacer(minLength: 0)
        card
      }
      .frame(width: 290)
      .animation(spring, value: target)
    } bar: {
      HStack(spacing: 12) {
        Transport(clip: clip)
        Spacer()
        applyButton("Normalize", disabled: error != nil) {
          let u = clip.url, t = target.lufs, tp = truePeak
          clip.stop(); close()
          Runner.perform("Normalize", symbol: "speaker.wave.3") {
            if let t { return [try await MediaTools.normalizeLoudness(u, target: t, truePeak: tp)] }
            return [try MediaTools.normalize(u)]
          }
        }
      }
    }
    .task {
      do { measured = try await MediaTools.loudness(clip.url) } catch { self.error = error.localizedDescription }
    }
  }

  private var card: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let error {
        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(.red)
      } else if let m = measured {
        let gain = (target.lufs ?? m.i) - m.i
        Text(target.lufs == nil ? "Peak" : String(format: "%+.1f dB", gain))
          .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
          .contentTransition(.numericText(value: gain))
        info(String(format: "Now %.1f LUFS · peak %.1f dBTP", m.i, m.tp))
      } else {
        HStack { ProgressView().controlSize(.small); info("Measuring…") }
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .lemonGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .animation(spring, value: target)
  }
}
