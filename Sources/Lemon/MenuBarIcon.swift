import AppKit

extension NSImage {
  /// Menu bar lemon slice: rind ring plus eight segments. A template image, so macOS tints it for light, dark and
  /// tinted menu bars.
  static let lemonTemplate: NSImage = {
    let size: CGFloat = 18
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
      let c = CGPoint(x: size / 2, y: size / 2)
      let rind = NSBezierPath(ovalIn: NSRect(x: 1.2, y: 1.2, width: size - 2.4, height: size - 2.4))
      rind.lineWidth = 1.4
      NSColor.black.setStroke()
      rind.stroke()
      // Segments: wedges stroked with round joins so their corners are soft, like a real slice, with a pith gap
      // before the rind.
      let round: CGFloat = 1.1
      let rIn: CGFloat = 1.9 + round / 2, rOut: CGFloat = 5.5 - round / 2, gap: CGFloat = 0.55 + round
      NSColor.black.set()
      for i in 0..<8 {
        let mid = CGFloat(i) * .pi / 4 + .pi / 8
        let half = CGFloat.pi / 8
        let dOut = asin(gap / 2 / rOut), dIn = asin(min(1, gap / 2 / rIn))
        let p = NSBezierPath()
        p.appendArc(withCenter: c, radius: rOut, startAngle: (mid - half + dOut) * 180 / .pi, endAngle: (mid + half - dOut) * 180 / .pi)
        p.appendArc(withCenter: c, radius: rIn, startAngle: (mid + half - dIn) * 180 / .pi, endAngle: (mid - half + dIn) * 180 / .pi, clockwise: true)
        p.close()
        p.lineWidth = round
        p.lineJoinStyle = .round
        p.fill()
        p.stroke()
      }
      return true
    }
    img.isTemplate = true
    img.accessibilityDescription = "Lemon"
    return img
  }()
}
