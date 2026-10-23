import AppKit
import AVFoundation
import UniformTypeIdentifiers

enum FileKind: Hashable {
  case image, pdf, video, audio, document, spreadsheet, subtitle, archive, other

  static let all: Set<FileKind> = [.image, .pdf, .video, .audio, .document, .spreadsheet, .subtitle, .archive, .other]

  init(_ url: URL) {
    let ext = url.pathExtension.lowercased()
    if ["srt", "vtt"].contains(ext) { self = .subtitle; return }
    if ["csv", "tsv", "xlsx", "xls", "ods"].contains(ext) { self = .spreadsheet; return }
    if ["mkv", "webm", "avi", "wmv", "flv", "m4v", "3gp", "mts", "m2ts"].contains(ext) { self = .video; return }
    if ["ogg", "oga", "opus", "wma", "flac", "ape", "caf"].contains(ext) { self = .audio; return }
    let t = UTType(filenameExtension: ext) ?? .data
    if t.conforms(to: .pdf) { self = .pdf }
    else if t.conforms(to: .image) { self = .image }
    else if t.conforms(to: .movie) { self = .video }
    else if t.conforms(to: .audio) { self = .audio }
    else if t.conforms(to: .archive) || t.conforms(to: .zip) || ["tgz", "gz", "bz2", "xz", "7z", "rar"].contains(ext) { self = .archive }
    else if t.conforms(to: .text) || t.conforms(to: .rtf) || ["doc", "docx", "odt", "rtfd", "md", "markdown"].contains(ext) { self = .document }
    else { self = .other }
  }
}

/// Dial modes, switched by holding a key while the dial is open.
enum FanMode: String, CaseIterable {
  case convert, edit, action

  /// Command → edit, Control → actions, otherwise convert (Shift).
  init(_ flags: NSEvent.ModifierFlags) {
    self = flags.contains(.command) ? .edit : flags.contains(.control) ? .action : .convert
  }
}

struct Tool: Identifiable {
  let id: String
  let mode: FanMode
  let title: String   // capsule in the dial centre
  let short: String   // petal label
  let symbol: String  // SF Symbol
  let kinds: Set<FileKind>
  var outputExt: String? = nil  // convert mode: hidden when the files already have this format
  var needsMany = false         // only offered for 2+ files
  var writesNextToSource = true // needs folder access before running
  var editor: (@MainActor ([URL]) -> Void)? = nil  // opens a window for choices; `run` is the one-click default
  let run: ([URL]) async throws -> [URL]
}

struct ToolError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}

func each(_ f: @escaping (URL) async throws -> URL) -> ([URL]) async throws -> [URL] {
  { urls in
    var out: [URL] = []
    for u in urls { out.append(try await f(u)) }
    return out
  }
}

func eachMany(_ f: @escaping (URL) async throws -> [URL]) -> ([URL]) async throws -> [URL] {
  { urls in
    var out: [URL] = []
    for u in urls { out += try await f(u) }
    return out
  }
}

/// Next to the source, never overwriting: `photo.jpg`, `photo-1.jpg`, ...
func outputURL(for src: URL, ext: String, suffix: String = "", keepExtension: Bool = false) -> URL {
  let dir = src.deletingLastPathComponent()
  let base = (keepExtension ? src.lastPathComponent : src.deletingPathExtension().lastPathComponent) + suffix
  func make(_ n: Int) -> URL {
    let u = dir.appendingPathComponent(n == 0 ? base : "\(base)-\(n)")
    return ext.isEmpty ? u : u.appendingPathExtension(ext)
  }
  var n = 0
  while FileManager.default.fileExists(atPath: make(n).path) { n += 1 }
  return make(n)
}

/// Same-format spellings: jpeg → jpg, tif → tiff, aif → aiff.
func canonicalExt(_ ext: String) -> String {
  ["jpeg": "jpg", "tif": "tiff", "aif": "aiff", "htm": "html", "markdown": "md"][ext.lowercased()] ?? ext.lowercased()
}

enum Tools {
  static let maxInFan = 12

  /// Tools for the dragged files in one mode, in dial order (first is at the top).
  static func available(for urls: [URL], mode: FanMode) -> [Tool] {
    guard !urls.isEmpty else { return [] }
    let kinds = Set(urls.map(FileKind.init))
    let exts = Set(urls.map { canonicalExt($0.pathExtension) })
    return Array(all.filter {
      $0.mode == mode && kinds.isSubset(of: $0.kinds) && (!$0.needsMany || urls.count > 1)
        && !(exts.count == 1 && $0.outputExt == exts.first)
    }.prefix(maxInFan))
  }

  static let all: [Tool] = convert + edit + actions

  // MARK: Convert (Shift)

  private static func image(_ type: UTType, _ ext: String) -> Tool {
    Tool(id: "img.\(ext)", mode: .convert, title: "Convert to \(ext.uppercased())", short: ext.uppercased(), symbol: "photo",
         kinds: [.image], outputExt: ext, run: each { try ImageTools.convert($0, to: type, ext: ext) })
  }

  private static func doc(_ type: NSAttributedString.DocumentType, _ ext: String) -> Tool {
    Tool(id: "doc.\(ext)", mode: .convert, title: "Convert to \(ext.uppercased())", short: ext.uppercased(), symbol: "doc.text",
         kinds: [.document], outputExt: ext, run: each { try DocTools.write($0, as: type, ext: ext) })
  }

  private static func archive(_ ext: String, _ flags: [String]) -> Tool {
    Tool(id: "arc.\(ext)", mode: .convert, title: "Convert to \(ext.uppercased())", short: ext == "tar.gz" ? "GZIP" : ext.uppercased(),
         symbol: "archivebox", kinds: [.archive], outputExt: ext, run: each { try ArchiveTools.repack($0, ext: ext, flags: flags) })
  }

  static var convert: [Tool] {
    var images = [image(.jpeg, "jpg"), image(.png, "png"),
                  Tool(id: "img.webp", mode: .convert, title: "Convert to WEBP", short: "WEBP", symbol: "photo", kinds: [.image],
                       outputExt: "webp", run: each(FFmpeg.webp)),
                  image(.heic, "heic")]
    images.append(image(.tiff, "tiff"))
    if let avif = UTType("public.avif"), ImageTools.canWrite(avif) { images.append(image(avif, "avif")) }
    images += [
      image(.bmp, "bmp"),
      Tool(id: "img.topdf", mode: .convert, title: "Convert to PDF", short: "PDF", symbol: "doc.richtext", kinds: [.image],
           outputExt: "pdf", run: { [try ImageTools.toPDF($0)] }),
    ]
    return images + [
      // PDF
      Tool(id: "pdf.png", mode: .convert, title: "Pages to PNG", short: "PNG", symbol: "photo", kinds: [.pdf],
           run: eachMany { try PDFTools.images($0, type: .png, ext: "png") }),
      Tool(id: "pdf.jpg", mode: .convert, title: "Pages to JPG", short: "JPG", symbol: "photo", kinds: [.pdf],
           run: eachMany { try PDFTools.images($0, type: .jpeg, ext: "jpg") }),
      Tool(id: "pdf.docx", mode: .convert, title: "Convert to DOCX (text)", short: "DOCX", symbol: "doc.text", kinds: [.pdf],
           run: each { try PDFTools.document($0, as: .officeOpenXML, ext: "docx") }),
      Tool(id: "pdf.rtf", mode: .convert, title: "Convert to RTF (text)", short: "RTF", symbol: "doc.plaintext", kinds: [.pdf],
           run: each { try PDFTools.document($0, as: .rtf, ext: "rtf") }),
      Tool(id: "pdf.txt", mode: .convert, title: "Convert to TXT", short: "TXT", symbol: "text.alignleft", kinds: [.pdf],
           run: each(PDFTools.text)),
      // Audio and video through the bundled ffmpeg, which also reads OGG, WMA, MKV, WEBM, AVI...
    ] + FFmpeg.audio.map { f in
      Tool(id: "aud.\(f.ext)", mode: .convert, title: "Convert to \(f.ext.uppercased())", short: f.ext.uppercased(), symbol: "waveform",
           kinds: [.audio], outputExt: f.ext, run: each { try await FFmpeg.convert($0, ext: f.ext, format: f.format, args: f.args) })
    } + FFmpeg.video.map { f in
      Tool(id: "vid.\(f.ext)", mode: .convert, title: "Convert to \(f.ext.uppercased())", short: f.ext.uppercased(), symbol: "film",
           kinds: [.video], outputExt: f.ext, run: each { try await FFmpeg.convert($0, ext: f.ext, format: f.format, args: f.args) })
    } + [
      Tool(id: "vid.gif", mode: .convert, title: "Convert to GIF (first 15s)", short: "GIF", symbol: "photo.stack", kinds: [.video],
           outputExt: "gif", run: each { try await FFmpeg.convert($0, ext: "gif", format: "gif", args: FFmpeg.gif) }),
      Tool(id: "vid.mp3", mode: .convert, title: "Extract audio (MP3)", short: "MP3", symbol: "waveform", kinds: [.video],
           run: each { try await FFmpeg.convert($0, ext: "mp3", format: "mp3", args: FFmpeg.audio[0].args) }),
      Tool(id: "vid.m4a", mode: .convert, title: "Extract audio (M4A)", short: "M4A", symbol: "waveform", kinds: [.video],
           run: each { try await FFmpeg.convert($0, ext: "m4a", format: "ipod", args: FFmpeg.audio[1].args) }),
      // Documents
      Tool(id: "doc.pdf", mode: .convert, title: "Convert to PDF", short: "PDF", symbol: "doc.richtext", kinds: [.document],
           outputExt: "pdf", run: each { try await DocTools.pdf($0) }),
      doc(.officeOpenXML, "docx"), doc(.rtf, "rtf"), doc(.plain, "txt"), doc(.html, "html"), doc(.openDocument, "odt"),
      // Spreadsheets and subtitles
      Tool(id: "sheet.csv", mode: .convert, title: "Convert to CSV", short: "CSV", symbol: "tablecells", kinds: [.spreadsheet],
           outputExt: "csv", run: each { try TextTools.delimited($0, to: ",", ext: "csv") }),
      Tool(id: "sheet.tsv", mode: .convert, title: "Convert to TSV", short: "TSV", symbol: "tablecells", kinds: [.spreadsheet],
           outputExt: "tsv", run: each { try TextTools.delimited($0, to: "\t", ext: "tsv") }),
      Tool(id: "sub.srt", mode: .convert, title: "Convert to SRT", short: "SRT", symbol: "captions.bubble", kinds: [.subtitle],
           outputExt: "srt", run: each(TextTools.toSRT)),
      Tool(id: "sub.vtt", mode: .convert, title: "Convert to VTT", short: "VTT", symbol: "captions.bubble", kinds: [.subtitle],
           outputExt: "vtt", run: each(TextTools.toVTT)),
      // Archives
      archive("zip", ["--format", "zip"]), archive("tar", []), archive("tar.gz", ["-z"]),
    ]
  }

  // MARK: Edit (Command)

  static let edit: [Tool] = [
    Tool(id: "edit.compress", mode: .edit, title: "Compress", short: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
         kinds: [.image], editor: { urls in EditorWindow.show(size: CGSize(width: 860, height: 560)) { CompressEditor(urls: urls, close: $0) } },
         run: each(ImageTools.compress)),
    // PDF editors (PDFEditors.swift): Organize and Merge lead the PDF petals
    Tool(id: "edit.resize", mode: .edit, title: "Resize", short: "Resize", symbol: "arrow.up.left.and.arrow.down.right",
         kinds: [.image], editor: { urls in EditorWindow.show(size: CGSize(width: 860, height: 580)) { ResizeEditor(urls: urls, close: $0) } },
         run: each { try ImageTools.resize($0, ResizeSettings(width: 1920)) }),
    Tool(id: "edit.organize", mode: .edit, title: "Organize pages", short: "Organize", symbol: "square.grid.3x3",
         kinds: [.pdf], editor: { urls in EditorWindow.show(size: CGSize(width: 900, height: 680)) { OrganizeEditor(urls: urls, close: $0) } },
         run: { [try PDFTools.organize($0, pages: PDFTools.allPages($0))] }),
    Tool(id: "edit.merge", mode: .edit, title: "Merge PDFs", short: "Merge", symbol: "doc.on.doc",
         kinds: [.pdf], needsMany: true,
         editor: { urls in EditorWindow.show(size: CGSize(width: 640, height: 560)) { MergeEditor(urls: urls, close: $0) } },
         run: { [try PDFTools.merge($0)] }),
    Tool(id: "edit.compress.pdf", mode: .edit, title: "Compress", short: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
         kinds: [.pdf], editor: { urls in EditorWindow.show(size: CGSize(width: 880, height: 580)) { PDFCompressEditor(urls: urls, close: $0) } },
         run: each(PDFTools.compress)),
    Tool(id: "edit.adjust", mode: .edit, title: "Edit", short: "Edit", symbol: "slider.horizontal.3",
         kinds: [.image], editor: { urls in EditorWindow.show(size: CGSize(width: 940, height: 640)) { AdjustEditor(urls: urls, close: $0) } },
         run: each { try ImageTools.adjust($0, Adjustments(exposure: 0.1, contrast: 0.15, vibrance: 0.2)) }),
    Tool(id: "edit.annotate", mode: .edit, title: "Annotate", short: "Annotate", symbol: "pencil.tip.crop.circle",
         kinds: [.image], editor: { urls in EditorWindow.show(size: CGSize(width: 900, height: 680)) { AnnotateEditor(urls: urls, close: $0) } },
         run: each { try ImageTools.annotate($0, []) }),
    Tool(id: "edit.redact", mode: .edit, title: "Redact", short: "Redact", symbol: "eye.slash.circle",
         kinds: [.image], editor: { urls in EditorWindow.show(size: CGSize(width: 880, height: 660)) { RedactEditor(urls: urls, close: $0) } },
         run: each { try ImageTools.redact($0, boxes: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)], style: .pixelate) }),
    Tool(id: "edit.frame", mode: .edit, title: "Add background", short: "Add BG", symbol: "photo.artframe",
         kinds: [.image], editor: { urls in EditorWindow.show(size: CGSize(width: 900, height: 640)) { FrameEditor(urls: urls, close: $0) } },
         run: each { try ImageTools.frame($0, FrameStyle()) }),
    Tool(id: "edit.metadata", mode: .edit, title: "Remove metadata", short: "Metadata", symbol: "eye.slash",
         kinds: [.image], editor: { urls in EditorWindow.show(size: CGSize(width: 640, height: 600)) { MetadataEditor(urls: urls, close: $0) } },
         run: each(ImageTools.strip)),
    Tool(id: "edit.metadata.pdf", mode: .edit, title: "Remove metadata", short: "Metadata", symbol: "eye.slash",
         kinds: [.pdf], run: each(PDFTools.strip)),
    Tool(id: "edit.crop", mode: .edit, title: "Crop", short: "Crop", symbol: "crop",
         kinds: [.image], editor: { urls in EditorWindow.show(size: CGSize(width: 820, height: 640)) { CropEditor(urls: urls, close: $0) } },
         run: each { try ImageTools.crop($0, rect: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)) }),
    Tool(id: "edit.rotate", mode: .edit, title: "Rotate & Flip", short: "Rotate", symbol: "rotate.right",
         kinds: [.image], editor: { urls in EditorWindow.show(size: CGSize(width: 640, height: 600)) { RotateEditor(urls: urls, close: $0) } },
         run: each(ImageTools.rotate)),
    Tool(id: "edit.qr", mode: .edit, title: "Read QR code", short: "QR Code", symbol: "qrcode.viewfinder",
         kinds: [.image], run: each(ImageTools.qr)),
    Tool(id: "edit.ocr", mode: .edit, title: "Extract text", short: "Text", symbol: "text.viewfinder",
         kinds: [.image], run: each(ImageTools.ocr)),
    Tool(id: "edit.collage", mode: .edit, title: "Create collage", short: "Collage", symbol: "square.grid.2x2",
         kinds: [.image], needsMany: true,
         editor: { urls in EditorWindow.show(size: CGSize(width: 920, height: 660)) { CollageEditor(urls: urls, close: $0) } },
         run: { [try ImageTools.collage($0)] }),
    Tool(id: "edit.createpdf", mode: .edit, title: "Create PDF", short: "Create PDF", symbol: "doc.badge.plus",
         kinds: [.image], editor: { urls in EditorWindow.show(size: CGSize(width: 900, height: 660)) { CreatePDFEditor(urls: urls, close: $0) } },
         run: { [try ImageTools.toPDF($0)] }),
    Tool(id: "edit.split", mode: .edit, title: "Split PDF", short: "Split", symbol: "scissors",
         kinds: [.pdf], run: eachMany(PDFTools.split)),
    Tool(id: "edit.rotate.pdf", mode: .edit, title: "Rotate pages", short: "Rotate", symbol: "rotate.right",
         kinds: [.pdf], run: each(PDFTools.rotate)),
    // Media editors (MediaEditors.swift)
    Tool(id: "edit.trim", mode: .edit, title: "Trim", short: "Trim", symbol: "scissors", kinds: [.video, .audio],
         editor: { eachWindow($0, size: CGSize(width: 860, height: 600)) { TrimEditor(url: $0, close: $1) } },
         run: each { try await MediaTools.trimSilence($0) }),
    Tool(id: "edit.split.video", mode: .edit, title: "Split video", short: "Split", symbol: "square.split.2x1", kinds: [.video],
         editor: { eachWindow($0, size: CGSize(width: 900, height: 640)) { SplitEditor(url: $0, close: $1) } },
         run: eachMany { try await MediaTools.split($0, cuts: [try await FFmpeg.probe($0).duration / 2], merged: false) }),
    Tool(id: "edit.join", mode: .edit, title: "Join videos", short: "Join", symbol: "rectangle.stack.badge.plus", kinds: [.video],
         needsMany: true, editor: { urls in EditorWindow.show(size: CGSize(width: 620, height: 560)) { JoinEditor(urls: urls, close: $0) } },
         run: { [try await MediaTools.join($0)] }),
    Tool(id: "edit.compress.video", mode: .edit, title: "Compress", short: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
         kinds: [.video], editor: { eachWindow($0, size: CGSize(width: 920, height: 600)) { VideoCompressEditor(url: $0, close: $1) } },
         run: each { try await MediaTools.compressVideo($0, settings: VideoCompressSettings(quality: 45)) }),
    Tool(id: "edit.normalize", mode: .edit, title: "Normalize loudness", short: "Normalize", symbol: "speaker.wave.3", kinds: [.audio],
         editor: { eachWindow($0, size: CGSize(width: 900, height: 560)) { LoudnessEditor(url: $0, close: $1) } },
         run: each(MediaTools.normalize)),
    Tool(id: "edit.speed", mode: .edit, title: "Change speed", short: "Speed", symbol: "gauge.with.dots.needle.67percent", kinds: [.video, .audio],
         editor: { eachWindow($0, size: CGSize(width: 900, height: 600)) { SpeedEditor(url: $0, close: $1) } },
         run: each { try await MediaTools.speed($0, factor: 2) }),
    Tool(id: "edit.redact.video", mode: .edit, title: "Redact video", short: "Redact", symbol: "eye.slash", kinds: [.video],
         editor: { eachWindow($0, size: CGSize(width: 900, height: 640)) { RedactVideoEditor(url: $0, close: $1) } },
         run: each { try await MediaTools.redact($0, [], style: .blur) }),  // needs boxes: always opened in the editor
    Tool(id: "edit.bleep", mode: .edit, title: "Bleep audio", short: "Bleep", symbol: "waveform.badge.minus", kinds: [.audio],
         editor: { eachWindow($0, size: CGSize(width: 860, height: 520)) { BleepEditor(url: $0, close: $1) } },
         run: each { try await MediaTools.bleep($0, ranges: []) }),  // needs ranges: always opened in the editor
    Tool(id: "edit.snapshots", mode: .edit, title: "Video snapshots", short: "Snapshots", symbol: "photo.on.rectangle", kinds: [.video],
         editor: { eachWindow($0, size: CGSize(width: 860, height: 600)) { SnapshotsEditor(url: $0, close: $1) } },
         run: each { try await MediaTools.snapshots($0, count: 10) }),
    Tool(id: "edit.channels", mode: .edit, title: "Audio channels", short: "Channels", symbol: "speaker.wave.2", kinds: [.audio],
         editor: { eachWindow($0, size: CGSize(width: 860, height: 520)) { ChannelsEditor(url: $0, close: $1) } },
         run: each { try await MediaTools.channels($0, stereo: false) }),
    Tool(id: "edit.audio2video", mode: .edit, title: "Audio to video", short: "To Video", symbol: "film", kinds: [.audio],
         editor: { eachWindow($0, size: CGSize(width: 900, height: 560)) { AudioToVideoEditor(url: $0, close: $1) } },
         run: each { try await MediaTools.audioToVideo($0) }),
    Tool(id: "edit.mute", mode: .edit, title: "Mute video", short: "Mute", symbol: "speaker.slash",
         kinds: [.video], run: each(FFmpeg.mute)),
    Tool(id: "edit.mono", mode: .edit, title: "Mix down to mono", short: "Mono", symbol: "speaker",
         kinds: [.audio], run: each(MediaTools.mono)),
    Tool(id: "edit.extract", mode: .edit, title: "Extract archive", short: "Extract", symbol: "archivebox",
         kinds: [.archive], run: each(ArchiveTools.extract)),
  ]

  // MARK: Actions (Control)

  static let actions: [Tool] = [
    Tool(id: "act.airdrop", mode: .action, title: "AirDrop", short: "AirDrop", symbol: "dot.radiowaves.left.and.right", kinds: FileKind.all,
         writesNextToSource: false, run: { try await ActionTools.airDrop($0) }),
    Tool(id: "act.copy", mode: .action, title: "Copy files", short: "Copy", symbol: "doc.on.clipboard", kinds: FileKind.all,
         writesNextToSource: false, run: { await ActionTools.copy($0) }),
    Tool(id: "act.move", mode: .action, title: "Move to…", short: "Move", symbol: "folder", kinds: FileKind.all,
         writesNextToSource: false, run: { try await ActionTools.move($0) }),
    Tool(id: "act.path", mode: .action, title: "Copy path", short: "Copy Path", symbol: "link", kinds: FileKind.all,
         writesNextToSource: false, run: { await ActionTools.copyPath($0) }),
    Tool(id: "act.terminal", mode: .action, title: "Open in Terminal", short: "Terminal", symbol: "terminal", kinds: FileKind.all,
         writesNextToSource: false, run: { try await ActionTools.terminal($0) }),
    Tool(id: "act.float", mode: .action, title: "Float on a shelf", short: "Float", symbol: "tray", kinds: FileKind.all,
         writesNextToSource: false, editor: { Shelves.float($0) }, run: { await Shelves.float($0) }),
    Tool(id: "act.zip", mode: .action, title: "Compress to ZIP", short: "ZIP", symbol: "doc.zipper", kinds: FileKind.all,
         run: { [try ArchiveTools.zip($0)] }),
  ]
}
