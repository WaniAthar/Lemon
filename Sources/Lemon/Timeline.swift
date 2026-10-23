import AppKit
import AVFoundation
import AVKit
import SwiftUI

func timecode(_ t: Double) -> String {
  let s = max(t, 0)
  return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
}

// MARK: - Clip model

/// One media file in an editor: duration, filmstrip or waveform, and an AVPlayer that loops the chosen range.
/// Formats AVFoundation can't play are previewed through an ffmpeg proxy (`MediaTools.playable`).
@MainActor final class MediaClip: NSObject, ObservableObject {
  let url: URL
  let isVideo: Bool
  @Published private(set) var duration = 0.0
  @Published private(set) var size = CGSize.zero
  @Published private(set) var thumbs: [CGImage] = []
  @Published private(set) var wave: [Float] = []
  @Published private(set) var ready = false
  @Published private(set) var error: String?
  @Published private(set) var playing = false
  @Published var time = 0.0
  var rate: Float = 1 { didSet { if playing { player?.rate = rate } } }
  var loop: ClosedRange<Double>?
  private(set) var player: AVPlayer?
  private var loader: Task<Void, Never>?

  init(_ url: URL) {
    self.url = url
    isVideo = FileKind(url) == .video
    super.init()
    loader = Task { await load() }
  }

  func loaded() async { await loader?.value }

  /// Self-test renders use clips loaded beforehand (an offscreen render can't wait for loading).
  static var preloaded: [URL: MediaClip] = [:]
  static func make(_ url: URL) -> MediaClip { preloaded[url] ?? MediaClip(url) }

  private func load() async {
    do {
      let src = try await MediaTools.playable(url)
      let asset = AVURLAsset(url: src)
      duration = try await asset.load(.duration).seconds
      let item = AVPlayerItem(asset: asset)
      item.audioTimePitchAlgorithm = .spectral  // speed preview keeps pitch, like atempo
      let p = AVPlayer(playerItem: item)
      p.actionAtItemEnd = .pause
      p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
        MainActor.assumeIsolated { self?.tick(t.seconds) }
      }
      NotificationCenter.default.addObserver(self, selector: #selector(ended), name: AVPlayerItem.didPlayToEndTimeNotification, object: item)
      player = p
      ready = true
      if isVideo, let track = try await asset.loadTracks(withMediaType: .video).first {
        let (natural, t) = try await track.load(.naturalSize, .preferredTransform)
        let r = CGRect(origin: .zero, size: natural).applying(t)
        size = CGSize(width: abs(r.width), height: abs(r.height))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 240, height: 240)
        for i in 0..<12 {
          thumbs.append(try await gen.image(at: CMTime(seconds: duration * (Double(i) + 0.5) / 12, preferredTimescale: 600)).image)
        }
      } else if !isVideo {
        let w = try await MediaTools.peaks(src, count: 600)
        withAnimation(.easeOut(duration: 0.3)) { wave = w }
      }
    } catch {
      self.error = error.localizedDescription
    }
  }

  private func tick(_ t: Double) {
    guard playing else { return }
    time = t
    if let loop, t >= loop.upperBound { seek(loop.lowerBound) }
  }

  @objc private func ended() {
    guard playing else { return }
    seek(loop?.lowerBound ?? 0)
    player?.rate = rate
  }

  func seek(_ t: Double) {
    time = min(max(t, 0), duration)
    player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
  }

  func toggle() {
    guard let player else { return }
    if playing {
      player.pause()
    } else {
      if let loop, !(loop.lowerBound..<loop.upperBound).contains(time) { seek(loop.lowerBound) }
      player.rate = rate
    }
    playing.toggle()
  }

  func stop() {
    player?.pause()
    playing = false
  }
}

// MARK: - Preview

struct PlayerSurface: NSViewRepresentable {
  let player: AVPlayer?
  func makeNSView(context: Context) -> AVPlayerView {
    let v = AVPlayerView()
    v.controlsStyle = .none
    v.videoGravity = .resizeAspect
    v.player = player
    return v
  }
  func updateNSView(_ v: AVPlayerView, context: Context) { if v.player !== player { v.player = player } }
}

/// The video, aspect-fit, with the first frame as a poster and an overlay laid out in the video's own rect.
struct MediaStage<Overlay: View>: View {
  @ObservedObject var clip: MediaClip
  @ViewBuilder var overlay: (CGRect) -> Overlay

  var body: some View {
    GeometryReader { g in
      let fit = clip.size == .zero ? g.size : aspectFit(clip.size, in: g.size)
      let r = CGRect(x: (g.size.width - fit.width) / 2, y: (g.size.height - fit.height) / 2, width: fit.width, height: fit.height)
      ZStack(alignment: .topLeading) {
        ZStack {
          if let poster = clip.thumbs.first { Image(decorative: poster, scale: 1).resizable() }
          if clip.player != nil, !lemonPlainRender { PlayerSurface(player: clip.player) }
        }
        .frame(width: r.width, height: r.height)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .offset(x: r.minX, y: r.minY)
        overlay(r)
        LoadingBadge(clip: clip).frame(width: g.size.width, height: g.size.height)
      }
    }
  }
}

extension MediaStage where Overlay == EmptyView {
  init(clip: MediaClip) { self.init(clip: clip) { _ in EmptyView() } }
}

struct LoadingBadge: View {
  @ObservedObject var clip: MediaClip
  var body: some View {
    if let e = clip.error {
      Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 12)).padding(10)
        .lemonGlass(Capsule(), tint: .red.opacity(0.25))
    } else if !clip.ready {
      ProgressView().controlSize(.small).padding(10).lemonGlass(Circle())
    }
  }
}

// MARK: - Timeline

/// Filmstrip (video) or waveform (audio) with a scrubbing playhead, an optional range with draggable handles,
/// markers (tap to remove) and shaded ranges.
struct TimelineView: View {
  @ObservedObject var clip: MediaClip
  var range: Binding<ClosedRange<Double>>? = nil
  var markers: [Double] = []
  var shaded: [ClosedRange<Double>] = []
  var shade = Color.red
  var onMarkerTap: ((Int) -> Void)? = nil
  @State private var dragStart: ClosedRange<Double>?
  @State private var active: Bool?  // true: start handle, false: end handle

  var body: some View {
    GeometryReader { g in
      let w = g.size.width, h = g.size.height, d = max(clip.duration, 0.001)
      let x = { (t: Double) in CGFloat(t / d) * w }
      ZStack(alignment: .topLeading) {
        track(w: w, h: h)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .contentShape(Rectangle())
          .gesture(DragGesture(minimumDistance: 0).onChanged { clip.seek(Double($0.location.x / w) * d) })
        ForEach(shaded.indices, id: \.self) { i in
          RoundedRectangle(cornerRadius: 4).fill(shade.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(shade.opacity(0.8), lineWidth: 1))
            .frame(width: max(2, x(shaded[i].upperBound) - x(shaded[i].lowerBound)), height: h)
            .offset(x: x(shaded[i].lowerBound))
            .allowsHitTesting(false)
        }
        if let range { selection(range, x: x, w: w, h: h, d: d) }
        ForEach(markers.indices, id: \.self) { i in
          ZStack(alignment: .top) {
            Rectangle().fill(lemonYellow).frame(width: 2, height: h)
            Circle().fill(lemonYellow).frame(width: 12, height: 12).shadow(color: .black.opacity(0.3), radius: 2).offset(y: -4)
          }
          .frame(width: 18, height: h)
          .contentShape(Rectangle())
          .offset(x: x(markers[i]) - 9)
          .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) { onMarkerTap?(i) } }
          .help("Click to remove")
          .transition(.scale.combined(with: .opacity))
        }
        Capsule().fill(.white).frame(width: 3, height: h + 8)
          .shadow(color: .black.opacity(0.5), radius: 2)
          .offset(x: x(clip.time) - 1.5, y: -4)
          .allowsHitTesting(false)
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder private func track(w: CGFloat, h: CGFloat) -> some View {
    ZStack {
      Rectangle().fill(.black.opacity(0.35))
      if clip.isVideo {
        HStack(spacing: 0) {
          ForEach(clip.thumbs.indices, id: \.self) { i in
            Image(decorative: clip.thumbs[i], scale: 1).resizable().scaledToFill()
              .frame(width: w / CGFloat(max(clip.thumbs.count, 1)), height: h).clipped()
          }
        }
        .frame(width: w, height: h, alignment: .leading)
      } else {
        Canvas { ctx, size in
          guard !clip.wave.isEmpty else { return }
          let top = max(clip.wave.max() ?? 1, 0.001), n = clip.wave.count, bar = size.width / CGFloat(n)
          var p = Path()
          for (i, v) in clip.wave.enumerated() {
            let len = max(1, size.height * 0.9 * CGFloat(v / top))
            p.addRect(CGRect(x: CGFloat(i) * bar, y: (size.height - len) / 2, width: max(bar * 0.7, 0.5), height: len))
          }
          ctx.fill(p, with: .color(.white.opacity(0.85)))
        }
      }
    }
    .frame(width: w, height: h)
  }

  private func selection(_ range: Binding<ClosedRange<Double>>, x: (Double) -> CGFloat, w: CGFloat, h: CGFloat, d: Double) -> some View {
    let lo = x(range.wrappedValue.lowerBound), hi = x(range.wrappedValue.upperBound)
    return ZStack(alignment: .topLeading) {
      Rectangle().fill(.black.opacity(0.5)).frame(width: max(lo, 0), height: h)
      Rectangle().fill(.black.opacity(0.5)).frame(width: max(w - hi, 0), height: h).offset(x: hi)
      RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(lemonYellow, lineWidth: 3)
        .frame(width: max(hi - lo, 6), height: h).offset(x: lo)
      handle(range, start: true, at: lo, w: w, h: h, d: d)
      handle(range, start: false, at: hi, w: w, h: h, d: d)
    }
    .allowsHitTesting(true)
  }

  private func handle(_ range: Binding<ClosedRange<Double>>, start: Bool, at px: CGFloat, w: CGFloat, h: CGFloat, d: Double) -> some View {
    let on = active == start
    return Capsule().fill(lemonYellow)
      .frame(width: 9, height: h * 0.62)
      .overlay(Capsule().fill(.black.opacity(0.45)).frame(width: 2, height: h * 0.25))
      .shadow(color: .black.opacity(0.35), radius: 3)
      .scaleEffect(on ? 1.25 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.6), value: on)
      .frame(width: 24, height: h)
      .contentShape(Rectangle())
      .offset(x: px - 12)
      .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { v in
            if dragStart == nil { dragStart = range.wrappedValue; active = start }
            guard let s = dragStart else { return }
            let dt = Double(v.translation.width / w) * d, gap = min(0.1, d / 2)
            let t = start ? min(max(s.lowerBound + dt, 0), s.upperBound - gap) : max(min(s.upperBound + dt, d), s.lowerBound + gap)
            range.wrappedValue = start ? t...s.upperBound : s.lowerBound...t
            clip.seek(t)
          }
          .onEnded { _ in dragStart = nil; active = nil }
      )
  }
}

/// Play/pause and the time, as floating glass.
struct Transport: View {
  @ObservedObject var clip: MediaClip

  var body: some View {
    HStack(spacing: 10) {
      Button { clip.toggle() } label: {
        Image(systemName: clip.playing ? "pause.fill" : "play.fill")
          .font(.system(size: 13, weight: .bold))
          .contentTransition(.symbolEffect(.replace))
          .frame(width: 34, height: 34)
      }
      .lemonButton(shape: .circle)
      .keyboardShortcut(.space, modifiers: [])
      .disabled(!clip.ready)
      Text("\(timecode(clip.time)) / \(timecode(clip.duration))")
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .contentTransition(.numericText())
        .foregroundStyle(.secondary)
    }
  }
}
