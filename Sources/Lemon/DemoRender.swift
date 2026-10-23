import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `Lemon --selftest --demo out.gif`: renders the README demo frame by frame on a mock Mac desktop:
/// a file on the desktop is dragged, Shift/⌘/⌃ switch dial modes, and the converted file appears beside it.
/// Offscreen rendering can't draw Liquid Glass, so the dial uses plain fills.
extension SelfTest {
  private struct DesktopFile {
    var name: String
    var at: CGPoint
    var selected = false
    var opacity = 1.0
    var scale: CGFloat = 1
  }

  private struct DemoScene {
    var files: [DesktopFile] = []
    var cursor = CGPoint.zero
    var dragging = false           // the thumbnail follows the cursor
    var dial: (scale: CGFloat, opacity: Double) = (0, 0)
    var key: String?
    var toast: String?
  }

  private struct DemoFrame: View {
    let scene: DemoScene
    let model: DialModel
    let photo: NSImage?
    static let size = CGSize(width: 760, height: 540)
    static let menuBar: CGFloat = 26
    var dialCenter: CGPoint { CGPoint(x: Self.size.width / 2 + 60, y: Self.size.height / 2 + 14) }

    var body: some View {
      ZStack(alignment: .topLeading) {
        wallpaper
        ForEach(scene.files.indices, id: \.self) { i in icon(scene.files[i]) }
        DialContent(model: model)
          .scaleEffect(scene.dial.scale * 0.92)
          .opacity(scene.dial.opacity)
          .position(dialCenter)
        if scene.dragging, let photo {
          thumb(photo).opacity(0.85).position(x: scene.cursor.x + 30, y: scene.cursor.y + 38)
        }
        if let key {
          Text(key)
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.white.opacity(0.92), in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
            .position(x: Self.size.width / 2, y: Self.menuBar + 30)
        }
        if let toast = scene.toast {
          Label(toast, systemImage: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.white.opacity(0.95), in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .position(x: scene.cursor.x + 40, y: scene.cursor.y - 46)
        }
        menuBar
        Image(systemName: "cursorarrow")
          .font(.system(size: 24))
          .foregroundStyle(.black)
          .shadow(color: .white, radius: 0.8)
          .position(x: scene.cursor.x + 7, y: scene.cursor.y + 11)
      }
      .frame(width: Self.size.width, height: Self.size.height)
      .clipped()
    }

    private var key: String? { scene.key }

    /// A macOS-style wallpaper: deep blue to violet with a warm glow.
    private var wallpaper: some View {
      ZStack {
        LinearGradient(colors: [Color(red: 0.10, green: 0.14, blue: 0.42), Color(red: 0.45, green: 0.22, blue: 0.62)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
        RadialGradient(colors: [Color(red: 1, green: 0.55, blue: 0.35).opacity(0.75), .clear],
                       center: UnitPoint(x: 0.85, y: 0.95), startRadius: 0, endRadius: 420)
        RadialGradient(colors: [Color(red: 0.35, green: 0.65, blue: 1).opacity(0.55), .clear],
                       center: UnitPoint(x: 0.1, y: 0.15), startRadius: 0, endRadius: 380)
      }
    }

    private var menuBar: some View {
      HStack(spacing: 18) {
        Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
        Text("Finder").font(.system(size: 13, weight: .bold))
        ForEach(["File", "Edit", "View", "Go", "Window", "Help"], id: \.self) { Text($0).font(.system(size: 13)) }
        Spacer()
        Image(nsImage: lemonIcon).resizable().frame(width: 16, height: 16)
        Image(systemName: "wifi").font(.system(size: 13, weight: .semibold))
        Image(systemName: "battery.75percent").font(.system(size: 14))
        Text("Fri 9:41").font(.system(size: 13, weight: .medium))
      }
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .frame(width: Self.size.width, height: Self.menuBar)
      .background(.black.opacity(0.22))
    }

    /// The menu bar template icon tinted white, as macOS draws it on a dark menu bar.
    private var lemonIcon: NSImage {
      NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
        NSImage.lemonTemplate.draw(in: r)
        NSColor.white.set()
        r.fill(using: .sourceAtop)
        return true
      }
    }

    private func thumb(_ img: NSImage) -> some View {
      Image(nsImage: img).resizable().scaledToFill()
        .frame(width: 58, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .padding(3)
        .background(.white, in: RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }

    private func icon(_ f: DesktopFile) -> some View {
      VStack(spacing: 5) {
        if let photo {
          thumb(photo)
            .padding(6)
            .background(f.selected ? Color.white.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        Text(f.name)
          .font(.system(size: 12, weight: .medium))
          .foregroundStyle(.white)
          .padding(.horizontal, 6).padding(.vertical, 1)
          .background(f.selected ? Color(red: 0.0, green: 0.45, blue: 0.95) : .clear, in: RoundedRectangle(cornerRadius: 4))
          .shadow(color: f.selected ? .clear : .black.opacity(0.6), radius: 1.5, y: 1)
      }
      .scaleEffect(f.scale)
      .opacity(f.opacity)
      .position(f.at)
    }
  }

  static func renderDemo(photo src: URL, to out: URL) {
    lemonPlainRender = true
    defer { lemonPlainRender = false }
    let model = DialModel()
    let photo = ImageTools.preview(src, maxPixel: 240)
    let probe = DemoFrame(scene: DemoScene(), model: model, photo: nil)
    let center = probe.dialCenter
    let fileAt = CGPoint(x: 90, y: 110)
    var scene = DemoScene(files: [DesktopFile(name: "photo.jpg", at: fileAt)], cursor: CGPoint(x: 380, y: 460))
    var frames: [CGImage] = []

    func ease(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
    func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t) }
    func shot(_ n: Int = 1) {
      let r = ImageRenderer(content: DemoFrame(scene: scene, model: model, photo: photo))
      r.scale = 1
      if let img = r.cgImage { frames += Array(repeating: img, count: n) }
    }
    func move(to p: CGPoint, steps: Int) {
      let from = scene.cursor
      for s in 1...steps {
        scene.cursor = mix(from, p, ease(Double(s) / Double(steps)))
        model.hover = scene.dial.opacity > 0.5
          ? DialGeo.index(dx: (scene.cursor.x - center.x) / 0.92, dy: (center.y - scene.cursor.y) / 0.92, of: model.tools.count) : nil
        shot()
      }
    }
    func petal(_ i: Int) -> CGPoint {
      let n = max(model.tools.count, 1)
      let a = Double(i) * DialGeo.span(n) * .pi / 180
      let r = (DialGeo.inner(n) + DialGeo.outer(n)) / 2 * 0.92
      return CGPoint(x: center.x + r * CGFloat(sin(a)), y: center.y - r * CGFloat(cos(a)))
    }
    func tour(_ petals: [Int]) {
      for i in petals { move(to: petal(i), steps: 5); shot(3) }
    }
    func mode(_ m: FanMode, _ label: String) {
      model.setMode(m)
      model.hover = nil
      scene.key = label
      shot(4)
    }

    model.load([src], mode: .convert)
    model.shown = true
    model.hover = nil
    // 1. the desktop, cursor heads to the photo
    shot(6)
    move(to: CGPoint(x: fileAt.x + 4, y: fileAt.y - 6), steps: 12)
    // 2. click: selected
    scene.files[0].selected = true
    shot(5)
    // 3. drag it out: a faded copy stays, the thumbnail follows the cursor
    scene.dragging = true
    scene.files[0].opacity = 0.45
    move(to: CGPoint(x: center.x - 70, y: center.y - 10), steps: 10)
    move(to: center, steps: 4)
    // 4. tap Shift: the dial blooms
    scene.key = "⇧ Shift · Convert"
    for s in 1...6 {
      let t = ease(Double(s) / 6)
      scene.dial = (0.4 + 0.6 * t, t)
      shot()
    }
    tour([0, 1, 2])
    mode(.edit, "⌘ Command · Edit")
    tour([0, 1, 4])
    mode(.action, "⌃ Control · Actions")
    tour([0, 1])
    mode(.convert, "⇧ Shift · Convert")
    tour([1])  // WEBP
    // 5. drop: dial closes, the WebP pops onto the desktop beside the original
    shot(3)
    scene.dragging = false
    scene.key = nil
    for s in 1...4 {
      scene.dial = (1 - 0.15 * CGFloat(s) / 4, 1 - Double(s) / 4)
      shot()
    }
    model.hover = nil
    scene.files[0].opacity = 1
    scene.files[0].selected = false
    scene.files.append(DesktopFile(name: "photo.webp", at: CGPoint(x: fileAt.x, y: fileAt.y + 118), selected: true, scale: 0.2))
    for s in 1...7 {
      let t = Double(s) / 7
      scene.files[1].scale = CGFloat(1 + 0.25 * sin(t * .pi) * (1 - t)) * CGFloat(0.2 + 0.8 * ease(min(t * 1.4, 1)))
      shot()
    }
    scene.files[1].scale = 1
    scene.toast = "Saved photo.webp"
    move(to: CGPoint(x: fileAt.x + 150, y: fileAt.y + 175), steps: 8)
    shot(26)

    guard let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
    CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 15]] as CFDictionary
    for f in frames { CGImageDestinationAddImage(d, f, delay) }
    if CGImageDestinationFinalize(d) { print("rendered demo", out.path, "(\(frames.count) frames)") }
  }
}
