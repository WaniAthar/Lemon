import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// `Lemon --selftest --demo out.gif`: renders the README demo (drag, Shift/⌘/⌃ dial modes, drop) frame by frame.
/// Offscreen rendering can't draw Liquid Glass, so the dial uses plain fills.
extension SelfTest {
  private struct DemoFrame: View {
    let model: DialModel
    let photo: NSImage?
    let cursor: CGPoint
    let dial: (scale: CGFloat, opacity: Double)
    let key: String?
    let toast: String?
    static let size = CGSize(width: 720, height: 520)

    var body: some View {
      ZStack(alignment: .topLeading) {
        Color(red: 0.80, green: 0.85, blue: 0.93)
        DialContent(model: model)
          .scaleEffect(dial.scale * 0.92)
          .opacity(dial.opacity)
          .position(x: Self.size.width / 2, y: Self.size.height / 2 + 6)
        if let key {
          Text(key)
            .font(.system(size: 15, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Color.white, in: Capsule())
            .overlay(Capsule().stroke(Color.black.opacity(0.08)))
            .position(x: Self.size.width / 2, y: 26)
        }
        if let photo {
          Image(nsImage: photo).resizable().scaledToFill()
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(0.9)
            .position(x: cursor.x + 26, y: cursor.y + 34)
        }
        Image(systemName: "cursorarrow")
          .font(.system(size: 24, weight: .regular))
          .foregroundStyle(.black)
          .shadow(color: .white, radius: 0.8)
          .position(x: cursor.x + 7, y: cursor.y + 11)
        if let toast {
          Label(toast, systemImage: "checkmark.circle.fill")
            .font(.system(size: 14, weight: .semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color.white, in: Capsule())
            .overlay(Capsule().stroke(Color.black.opacity(0.08)))
            .position(x: cursor.x, y: cursor.y - 44)
        }
      }
      .frame(width: Self.size.width, height: Self.size.height)
    }
  }

  static func renderDemo(photo src: URL, to out: URL) {
    lemonPlainRender = true
    defer { lemonPlainRender = false }
    let model = DialModel()
    let photo = ImageTools.preview(src, maxPixel: 200)
    let center = CGPoint(x: DemoFrame.size.width / 2, y: DemoFrame.size.height / 2 + 6)
    let start = CGPoint(x: 70, y: 470)
    var frames: [CGImage] = []

    func petal(_ i: Int) -> CGPoint {
      let n = max(model.tools.count, 1)
      let a = Double(i) * DialGeo.span(n) * .pi / 180
      let r = (DialGeo.inner(n) + DialGeo.outer(n)) / 2 * 0.92
      return CGPoint(x: center.x + r * CGFloat(sin(a)), y: center.y - r * CGFloat(cos(a)))
    }
    func ease(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }
    func mix(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
      CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    func frame(cursor: CGPoint, dial: (CGFloat, Double) = (1, 1), key: String? = nil, toast: String? = nil, holdFor n: Int = 1) {
      let r = ImageRenderer(content: DemoFrame(model: model, photo: photo, cursor: cursor, dial: dial, key: key, toast: toast))
      r.scale = 1
      guard let img = r.cgImage else { return }
      frames += Array(repeating: img, count: n)
    }
    /// Glides the cursor through petals, lighting each one it passes.
    func tour(_ petals: [Int], key: String, from: CGPoint) -> CGPoint {
      var at = from
      for i in petals {
        let to = petal(i)
        for s in 1...5 {
          let p = mix(at, to, ease(Double(s) / 5))
          model.hover = DialGeo.index(dx: p.x - center.x, dy: center.y - p.y, of: model.tools.count)
          frame(cursor: p, key: key)
        }
        frame(cursor: to, key: key, holdFor: 3)
        at = to
      }
      return at
    }

    model.load([src], mode: .convert)
    model.shown = true
    model.hover = nil
    // 1. drag the file in
    for s in 0...9 { frame(cursor: mix(start, center, ease(Double(s) / 9)), dial: (0, 0)) }
    // 2. tap Shift: the dial blooms
    for s in 1...6 {
      let t = ease(Double(s) / 6)
      frame(cursor: center, dial: (0.4 + 0.6 * t, t), key: "⇧ Shift · Convert")
    }
    var at = tour([0, 1, 2], key: "⇧ Shift · Convert", from: center)
    // 3. ⌘: edit tools
    model.setMode(.edit)
    model.hover = nil
    frame(cursor: at, key: "⌘ Command · Edit", holdFor: 4)
    at = tour([0, 1, 4], key: "⌘ Command · Edit", from: at)
    // 4. ⌃: actions
    model.setMode(.action)
    model.hover = nil
    frame(cursor: at, key: "⌃ Control · Actions", holdFor: 4)
    at = tour([0, 1], key: "⌃ Control · Actions", from: at)
    // 5. back to Convert, drop on WEBP, done
    model.setMode(.convert)
    model.hover = nil
    frame(cursor: at, key: "⇧ Shift · Convert", holdFor: 3)
    at = tour([1], key: "⇧ Shift · Convert", from: at)
    for s in 1...4 { frame(cursor: at, dial: (1 - 0.15 * Double(s) / 4, 1 - Double(s) / 4)) }
    model.hover = nil
    frame(cursor: at, dial: (0, 0), toast: "Saved photo.webp", holdFor: 22)

    guard let d = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, frames.count, nil) else { return }
    CGImageDestinationSetProperties(d, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / 15]] as CFDictionary
    for f in frames { CGImageDestinationAddImage(d, f, delay) }
    if CGImageDestinationFinalize(d) { print("rendered demo", out.path, "(\(frames.count) frames)") }
  }
}
