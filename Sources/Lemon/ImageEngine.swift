import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

// MARK: - Adjust

/// Slider values: bipolar ones are -1...1, the rest 0...1; all zero means unchanged.
struct Adjustments: Equatable, Sendable {
  var exposure = 0.0, brightness = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
  var temperature = 0.0, tint = 0.0, saturation = 0.0, vibrance = 0.0, hue = 0.0
  var sharpness = 0.0, clarity = 0.0, noise = 0.0, vignette = 0.0, grain = 0.0, fade = 0.0, blur = 0.0
}

/// Background presets for Add BG.
enum FrameBackground: Equatable, Sendable {
  case gradient(Int), solid(Int), image(URL)

  static let gradients: [(name: String, stops: [UInt32])] = [
    ("Citrus", [0xFFE259, 0xFFA751]), ("Meadow", [0xC6F28B, 0x3DAA6A]), ("Sunset", [0xFF9A6C, 0xE2537A, 0x6A3DA8]),
    ("Sky", [0xA8E0FF, 0x4A8FE7]), ("Mint", [0xD4FCE6, 0x7ED9B5]), ("Violet", [0xB79CFF, 0x5B3FD1]),
    ("Graphite", [0x5E6470, 0x1F2229]), ("Sorbet", [0xFFC3D0, 0xFFE5B4, 0xB8F0E0]), ("Lagoon", [0x43C6CB, 0x1D6FA3]),
    ("Frost", [0xF4F8FC, 0xC9D8EA]), ("Emerald", [0x2BC48A, 0x0B5E4B]), ("Orchid", [0xF6A6E8, 0xA154D6]),
  ]
  static let solids: [UInt32] = [0xFFFFFF, 0xF2F2F2, 0x1C1C1E, 0xFFD21A, 0xFF6B5E, 0x5AC8FA, 0x34C759, 0xAF52DE]

  static func color(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}

struct FrameStyle: Equatable, Sendable {
  enum Ratio: String, CaseIterable, Sendable {
    case auto = "Auto", square = "Square", landscape = "16:9", portrait = "4:5"
    var value: CGFloat? { [nil, 1, 16 / 9, 4 / 5][Ratio.allCases.firstIndex(of: self)!] }
  }
  var background = FrameBackground.gradient(0)
  var padding = 0.08  // of the image's long side
  var corner = 0.03   // of the image's long side
  var shadow = 0.5
  var ratio = Ratio.auto
}

// MARK: - Annotate

struct Mark: Equatable, Sendable {
  enum Kind: String, CaseIterable, Sendable { case pen, highlighter, arrow, rect, ellipse, text }
  var kind: Kind
  var points: [CGPoint]  // image pixels, origin top-left
  var color: UInt32
  var width: CGFloat     // image pixels
  var text = ""
}

// MARK: - Redact

enum RedactStyle: String, CaseIterable, Sendable { case blur = "Blur", pixelate = "Pixelate", solid = "Solid" }

// MARK: - Metadata

struct MetaField: Identifiable, Hashable, Sendable {
  let group: String
  let dict: String  // kCGImageProperty...Dictionary
  let key: String
  let value: String
  var id: String { dict + "/" + key }
}

extension ImageTools {
  static let ci = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

  static func render(_ image: CIImage, extent: CGRect) -> CGImage? {
    ci.createCGImage(image, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
  }

  static func bitmap(_ w: Int, _ h: Int) -> CGContext? {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
  }

  /// Saves next to the source in its own format when writable, keeping metadata minus orientation (pixels are already upright).
  static func save(_ img: CGImage, from src: URL, props: [CFString: Any], suffix: String) throws -> URL {
    let (type, ext) = sameTypeOrPNG(src)
    let out = outputURL(for: src, ext: ext, suffix: suffix)
    try write(img, props: props, type: type, to: out)
    return out
  }

  // MARK: Adjust

  /// `scale` is preview pixels per original pixel, so radius-based effects look the same in the preview and the output.
  static func adjusted(_ input: CGImage, _ a: Adjustments, scale: CGFloat = 1) -> CGImage? {
    let extent = CGRect(x: 0, y: 0, width: input.width, height: input.height)
    var img = CIImage(cgImage: input)
    func f(_ name: String, _ params: [String: Any]) {
      img = img.applyingFilter(name, parameters: params)
    }
    if a.exposure != 0 { f("CIExposureAdjust", [kCIInputEVKey: a.exposure * 2]) }
    if a.temperature != 0 || a.tint != 0 {
      // a cooler target neutral renders the image warmer
      f("CITemperatureAndTint", ["inputNeutral": CIVector(x: 6500, y: 0),
                                 "inputTargetNeutral": CIVector(x: 6500 - a.temperature * 3000, y: a.tint * 60)])
    }
    if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
      f("CIColorControls", [kCIInputBrightnessKey: a.brightness * 0.25, kCIInputContrastKey: 1 + a.contrast * 0.5,
                            kCIInputSaturationKey: 1 + a.saturation])
    }
    if a.highlights != 0 || a.shadows != 0 || a.whites != 0 || a.blacks != 0 || a.fade != 0 {
      let b = a.blacks * 0.2, w = a.whites * 0.2
      f("CIToneCurve", [
        "inputPoint0": CIVector(x: max(-b, 0), y: max(b, 0) + a.fade * 0.22),
        "inputPoint1": CIVector(x: 0.25, y: 0.25 + a.shadows * 0.12 + a.fade * 0.08),
        "inputPoint2": CIVector(x: 0.5, y: 0.5),
        "inputPoint3": CIVector(x: 0.75, y: 0.75 + a.highlights * 0.12),
        "inputPoint4": CIVector(x: 1 - max(w, 0), y: 1 + min(w, 0)),
      ])
    }
    if a.vibrance != 0 { f("CIVibrance", ["inputAmount": a.vibrance]) }
    if a.hue != 0 { f("CIHueAdjust", [kCIInputAngleKey: a.hue * .pi]) }
    if a.noise > 0 { f("CINoiseReduction", ["inputNoiseLevel": a.noise * 0.06, "inputSharpness": 0.4]) }
    if a.clarity != 0 {
      // ponytail: clarity is a large-radius unsharp mask, not a local-contrast (Laplacian) filter
      f("CIUnsharpMask", [kCIInputRadiusKey: 30 * scale, kCIInputIntensityKey: a.clarity * 0.8])
    }
    if a.sharpness > 0 { f("CISharpenLuminance", [kCIInputSharpnessKey: a.sharpness * 2, kCIInputRadiusKey: max(1.5 * scale, 0.5)]) }
    if a.blur > 0 {
      img = img.clampedToExtent().applyingGaussianBlur(sigma: a.blur * 25 * scale).cropped(to: extent)
    }
    if a.vignette != 0 {
      f("CIVignetteEffect", [kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                             kCIInputRadiusKey: hypot(extent.width, extent.height) * 0.42,
                             kCIInputIntensityKey: a.vignette, "inputFalloff": 0.6])
    }
    if a.grain > 0 {
      let k = a.grain * 0.5
      let noise = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: extent)
        .applyingFilter("CIColorMatrix", parameters: [  // grey noise centred on 0.5, which soft light leaves unchanged
          "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: k, y: 0, z: 0, w: 0),
          "inputBVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
          "inputBiasVector": CIVector(x: 0.5 - k / 2, y: 0.5 - k / 2, z: 0.5 - k / 2, w: 1),
        ])
      img = noise.applyingFilter("CISoftLightBlendMode", parameters: [kCIInputBackgroundImageKey: img])
    }
    return render(img.cropped(to: extent), extent: extent)
  }

  static func adjust(_ src: URL, _ a: Adjustments) throws -> URL {
    let (img, props) = try decode(src)
    guard let out = adjusted(img, a) else { throw ToolError("Couldn't edit \(src.lastPathComponent)") }
    return try save(out, from: src, props: keptMetadata(props), suffix: "-edited")
  }

  // MARK: Frame

  static func framed(_ img: CGImage, _ s: FrameStyle) -> CGImage? {
    let W = CGFloat(img.width), H = CGFloat(img.height), long = max(W, H)
    let pad = (s.padding * long).rounded()
    var cw = W + 2 * pad, ch = H + 2 * pad
    if let r = s.ratio.value { if cw / ch < r { cw = (ch * r).rounded() } else { ch = (cw / r).rounded() } }
    guard let ctx = bitmap(Int(cw), Int(ch)) else { return nil }
    let canvas = CGRect(x: 0, y: 0, width: cw, height: ch)
    switch s.background {
    case .gradient(let i):
      let stops = FrameBackground.gradients[i % FrameBackground.gradients.count].stops
      let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: stops.map(FrameBackground.color) as CFArray, locations: nil)!
      ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: ch), end: CGPoint(x: cw, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    case .solid(let i):
      ctx.setFillColor(FrameBackground.color(FrameBackground.solids[i % FrameBackground.solids.count]))
      ctx.fill(canvas)
    case .image(let u):
      ctx.setFillColor(CGColor(gray: 0.5, alpha: 1))
      ctx.fill(canvas)
      if let (bg, _) = try? decode(u) {  // aspect fill
        let k = max(cw / CGFloat(bg.width), ch / CGFloat(bg.height))
        let size = CGSize(width: CGFloat(bg.width) * k, height: CGFloat(bg.height) * k)
        ctx.interpolationQuality = .high
        ctx.draw(bg, in: CGRect(x: (cw - size.width) / 2, y: (ch - size.height) / 2, width: size.width, height: size.height))
      }
    }
    let rect = CGRect(x: ((cw - W) / 2).rounded(), y: ((ch - H) / 2).rounded(), width: W, height: H)
    let radius = min(s.corner * long, min(W, H) / 2)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if s.shadow > 0 {
      ctx.saveGState()
      ctx.setShadow(offset: CGSize(width: 0, height: -long * 0.012 * s.shadow), blur: long * 0.06 * s.shadow,
                    color: CGColor(gray: 0, alpha: 0.5 * s.shadow))
      ctx.addPath(path)
      ctx.setFillColor(CGColor(gray: 0, alpha: 1))
      ctx.fillPath()
      ctx.restoreGState()
    }
    ctx.addPath(path)
    ctx.clip()
    ctx.clear(rect)  // transparent images show the background, not the shadow fill
    ctx.draw(img, in: rect)
    return ctx.makeImage()
  }

  static func frame(_ src: URL, _ s: FrameStyle) throws -> URL {
    let (img, _) = try decode(src)
    guard let out = framed(img, s) else { throw ToolError("Couldn't frame \(src.lastPathComponent)") }
    let url = outputURL(for: src, ext: "png", suffix: "-framed")
    try write(out, props: [:], type: .png, to: url)
    return url
  }

  // MARK: Annotate

  /// Draws into a y-down context whose units are image pixels (the editor's Canvas and the export share this).
  static func draw(_ marks: [Mark], in cg: CGContext) {
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    defer { NSGraphicsContext.restoreGraphicsState() }
    for m in marks {
      guard let first = m.points.first else { continue }
      let last = m.points.last!
      let color = FrameBackground.color(m.color)
      cg.saveGState()
      cg.setLineCap(.round)
      cg.setLineJoin(.round)
      cg.setLineWidth(m.width)
      cg.setStrokeColor(color)
      cg.setFillColor(color)
      let box = CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y))
      switch m.kind {
      case .pen, .highlighter:
        if m.kind == .highlighter {
          cg.setBlendMode(.multiply)
          cg.setLineWidth(m.width * 3)
          cg.setLineCap(.butt)
        }
        cg.addLines(between: m.points.count == 1 ? [first, first] : m.points)
        cg.strokePath()
      case .arrow:
        let angle = atan2(last.y - first.y, last.x - first.x), head = max(m.width * 4, 12)
        let base = CGPoint(x: last.x - cos(angle) * head * 0.8, y: last.y - sin(angle) * head * 0.8)
        cg.addLines(between: [first, base])
        cg.strokePath()
        cg.addLines(between: [last,
                              CGPoint(x: last.x - head * cos(angle - 0.45), y: last.y - head * sin(angle - 0.45)),
                              CGPoint(x: last.x - head * cos(angle + 0.45), y: last.y - head * sin(angle + 0.45))])
        cg.fillPath()
      case .rect: cg.stroke(box)
      case .ellipse: cg.strokeEllipse(in: box)
      case .text:
        NSAttributedString(string: m.text, attributes: [
          .font: NSFont.systemFont(ofSize: max(m.width * 6, 10), weight: .bold), .foregroundColor: NSColor(cgColor: color) ?? .red,
        ]).draw(at: first)
      }
      cg.restoreGState()
    }
  }

  static func annotated(_ img: CGImage, _ marks: [Mark]) -> CGImage? {
    guard let ctx = bitmap(img.width, img.height) else { return nil }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    ctx.translateBy(x: 0, y: CGFloat(img.height))
    ctx.scaleBy(x: 1, y: -1)
    draw(marks, in: ctx)
    return ctx.makeImage()
  }

  static func annotate(_ src: URL, _ marks: [Mark]) throws -> URL {
    let (img, props) = try decode(src)
    guard let out = annotated(img, marks) else { throw ToolError("Couldn't annotate \(src.lastPathComponent)") }
    return try save(out, from: src, props: keptMetadata(props), suffix: "-annotated")
  }

  // MARK: Redact

  /// `boxes` are normalized, origin top-left. Blur is pixelated first: a plain Gaussian blur can be partly undone.
  static func redacted(_ img: CGImage, boxes: [CGRect], style: RedactStyle, strength: Double = 0.5) -> CGImage? {
    let W = CGFloat(img.width), H = CGFloat(img.height)
    let extent = CGRect(x: 0, y: 0, width: W, height: H)
    let base = CIImage(cgImage: img)
    var out = base
    for b in boxes {
      let r = CGRect(x: b.minX * W, y: (1 - b.maxY) * H, width: b.width * W, height: b.height * H).integral.intersection(extent)  // CI is y-up
      guard r.width >= 1, r.height >= 1 else { continue }
      let patch: CIImage
      if style == .solid {
        patch = CIImage(color: .black).cropped(to: r)
      } else {
        // blocks scale with the box so even a big strength-0 box keeps no readable detail
        let block = max(8, max(r.width, r.height) * (0.06 + 0.14 * strength), max(W, H) * 0.01)
        var p = base.clampedToExtent().applyingFilter("CIPixellate", parameters: [
          kCIInputCenterKey: CIVector(x: r.minX, y: r.minY), kCIInputScaleKey: block,
        ])
        if style == .blur { p = p.applyingGaussianBlur(sigma: block * 0.6) }
        patch = p.cropped(to: r)
      }
      out = patch.composited(over: out)
    }
    return render(out.cropped(to: extent), extent: extent)
  }

  /// Saves with no metadata at all, so no embedded thumbnail keeps the original pixels.
  static func redact(_ src: URL, boxes: [CGRect], style: RedactStyle, strength: Double = 0.5) throws -> URL {
    let (img, _) = try decode(src)
    guard let out = redacted(img, boxes: boxes, style: style, strength: strength) else { throw ToolError("Couldn't redact \(src.lastPathComponent)") }
    return try save(out, from: src, props: [:], suffix: "-redacted")
  }

  // MARK: Metadata

  static let metaDicts: [(CFString, String)] = [
    (kCGImagePropertyTIFFDictionary, "TIFF"), (kCGImagePropertyExifDictionary, "EXIF"), (kCGImagePropertyExifAuxDictionary, "EXIF"),
    (kCGImagePropertyGPSDictionary, "GPS"), (kCGImagePropertyIPTCDictionary, "IPTC"),
  ]

  static func metadataFields(_ src: URL) -> [MetaField] {
    guard let s = CGImageSourceCreateWithURL(src as CFURL, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] else { return [] }
    let camera: Set = ["Make", "Model", "LensMake", "LensModel", "LensSpecification", "FNumber", "ExposureTime", "ISOSpeedRatings",
                       "FocalLength", "FocalLenIn35mmFilm", "Flash", "MeteringMode", "ExposureProgram", "WhiteBalance", "BodySerialNumber",
                       "SerialNumber", "LensSerialNumber", "ApertureValue", "ShutterSpeedValue", "ExposureBiasValue", "BrightnessValue"]
    let software: Set = ["Software", "HostComputer", "ProcessingSoftware"]
    let structural: Set = ["Orientation", "PixelXDimension", "PixelYDimension", "ColorSpace"]  // describe the pixels, not the person
    var fields: [MetaField] = []
    for (dict, name) in metaDicts {
      guard let d = props[dict] as? [String: Any] else { continue }
      for (k, v) in d where !structural.contains(k) && !(v is [String: Any]) {
        let group = dict == kCGImagePropertyGPSDictionary ? "Location"
          : k.hasPrefix("DateTime") || k.hasPrefix("OffsetTime") || k.hasPrefix("SubsecTime") ? "Date"
          : camera.contains(k) || dict == kCGImagePropertyExifAuxDictionary ? "Camera"
          : software.contains(k) ? "Software" : "Other \(name)"
        let value = (v as? [Any]).map { $0.map { "\($0)" }.joined(separator: ", ") } ?? "\(v)"
        fields.append(MetaField(group: group, dict: dict as String, key: k, value: value))
      }
    }
    return fields.sorted { ($0.group, $0.key) < ($1.group, $1.key) }
  }

  /// Removes only `fields`, losslessly when the format allows it; orientation always stays.
  /// Any location field removes all GPS data (ImageIO strips GPS as one block).
  static func removeMetadata(_ src: URL, fields: [MetaField]) throws -> URL {
    guard let s = CGImageSourceCreateWithURL(src as CFURL, nil), let type = CGImageSourceGetType(s) else {
      throw ToolError("Can't read \(src.lastPathComponent)")
    }
    let gps = kCGImagePropertyGPSDictionary as String
    let out = outputURL(for: src, ext: src.pathExtension, suffix: "-clean")
    func leftovers() -> Bool {  // some formats (PNG) keep fields outside the XMP tree, so check what was written
      guard let p = CGImageSourceCreateWithURL(out as CFURL, nil).flatMap({ CGImageSourceCopyPropertiesAtIndex($0, 0, nil) }) as? [String: Any]
      else { return true }
      return fields.contains { (p[$0.dict] as? [String: Any])?[$0.key] != nil }
    }
    if let meta = CGImageSourceCopyMetadataAtIndex(s, 0, nil).flatMap({ CGImageMetadataCreateMutableCopy($0) }),
       let d = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) {
      for f in fields where f.dict != gps {
        if let tag = CGImageMetadataCopyTagMatchingImageProperty(meta, f.dict as CFString, f.key as CFString),
           let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) {
          CGImageMetadataRemoveTagWithPath(meta, nil, "\(prefix):\(name)" as CFString)
        }
      }
      // ponytail: maker notes and other data with no XMP mapping are dropped too (more private, never less)
      let opts: [CFString: Any] = [kCGImageDestinationMetadata: meta, kCGImageDestinationMergeMetadata: false,
                                   kCGImageMetadataShouldExcludeGPS: fields.contains { $0.dict == gps }]
      if CGImageDestinationCopyImageSource(d, s, opts as CFDictionary, nil), !leftovers() { return out }
    }
    // No lossless path: re-encode the stored pixels without the chosen keys (orientation kept as stored).
    try? FileManager.default.removeItem(at: out)
    var props = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any] ?? [:]
    for f in fields {
      var d = props[f.dict as CFString] as? [CFString: Any] ?? [:]
      d[f.key as CFString] = nil
      props[f.dict as CFString] = f.dict == gps ? nil : d
    }
    props[kCGImageDestinationLossyCompressionQuality] = 0.95
    guard let d = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else {
      throw ToolError("Couldn't save \(out.lastPathComponent)")
    }
    CGImageDestinationAddImage(d, img, props as CFDictionary)
    guard CGImageDestinationFinalize(d), !leftovers() else {
      try? FileManager.default.removeItem(at: out)
      throw ToolError("Couldn't remove the selected fields from \(src.lastPathComponent)")
    }
    return out
  }
}
