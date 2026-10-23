import Compression
import Foundation
import zlib

// MARK: - ZIP (OOXML, ODF and EPUB packages)

// ponytail: no ZIP64 or encryption; office packages and EPUBs stay well under 4 GB.
struct ZipWriter {
  private(set) var data = Data()
  private var central = Data()
  private var count: UInt16 = 0

  /// `store` keeps the bytes uncompressed (EPUB/ODF `mimetype` must be stored and first).
  mutating func add(_ name: String, _ content: Data, store: Bool = false) {
    let crc = content.withUnsafeBytes { UInt32(crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count))) }
    var body = content, method: UInt16 = 0
    if !store, content.count > 64, let d = Zip.deflate(content), d.count < content.count { body = d; method = 8 }
    let nameData = Data(name.utf8), offset = UInt32(data.count)
    var common = Data()
    common.le(UInt16(20)); common.le(UInt16(0x0800)); common.le(method); common.le(UInt16(0)); common.le(UInt16(0x21))  // utf-8 names, 1980-01-01
    common.le(crc); common.le(UInt32(body.count)); common.le(UInt32(content.count)); common.le(UInt16(nameData.count)); common.le(UInt16(0))
    data.le(UInt32(0x04034b50)); data += common; data += nameData; data += body
    central.le(UInt32(0x02014b50)); central.le(UInt16(20)); central += common
    central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt16(0)); central.le(UInt32(0)); central.le(offset); central += nameData
    count += 1
  }

  mutating func add(_ name: String, _ text: String, store: Bool = false) { add(name, Data(text.utf8), store: store) }

  func finished() -> Data {
    var out = data + central
    out.le(UInt32(0x06054b50)); out.le(UInt16(0)); out.le(UInt16(0)); out.le(count); out.le(count)
    out.le(UInt32(central.count)); out.le(UInt32(data.count)); out.le(UInt16(0))
    return out
  }

  func write(to url: URL) throws { try finished().write(to: url) }
}

struct ZipReader {
  private let b: [UInt8]
  private var entries: [String: (offset: Int, method: Int, csize: Int, usize: Int)] = [:]
  private(set) var names: [String] = []

  init(_ url: URL) throws {
    b = [UInt8](try Data(contentsOf: url))
    let bad = ToolError("\(url.lastPathComponent) isn't a valid package (zip)")
    guard b.count >= 22, let eocd = stride(from: b.count - 22, through: max(0, b.count - 65_557), by: -1).first(where: { u32($0) == 0x06054b50 })
    else { throw bad }
    var p = Int(u32(eocd + 16))
    for _ in 0..<Int(u16(eocd + 10)) {
      guard p + 46 <= b.count, u32(p) == 0x02014b50 else { throw bad }
      let n = Int(u16(p + 28)), e = Int(u16(p + 30)), c = Int(u16(p + 32))
      guard p + 46 + n <= b.count else { throw bad }
      let name = String(decoding: b[(p + 46)..<(p + 46 + n)], as: UTF8.self)
      entries[name] = (Int(u32(p + 42)), Int(u16(p + 10)), Int(u32(p + 20)), Int(u32(p + 24)))
      names.append(name)
      p += 46 + n + e + c
    }
  }

  private func u16(_ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
  private func u32(_ i: Int) -> UInt32 { UInt32(u16(i)) | UInt32(u16(i + 2)) << 16 }

  /// Entry bytes; names match case-insensitively as a fallback (OOXML part names are case-insensitive).
  func read(_ name: String) -> Data? {
    let name = name.hasPrefix("/") ? String(name.dropFirst()) : name
    guard let e = entries[name] ?? entries.first(where: { $0.key.lowercased() == name.lowercased() })?.value,
          e.offset + 30 <= b.count else { return nil }
    let start = e.offset + 30 + Int(u16(e.offset + 26)) + Int(u16(e.offset + 28))
    guard start + e.csize <= b.count else { return nil }
    let raw = b[start..<(start + e.csize)]
    if e.method == 0 { return Data(raw) }
    guard e.method == 8 else { return nil }
    return Zip.inflate(Data(raw), size: e.usize)
  }

  func xml(_ name: String) -> XMLElement? { xmlRoot(read(name)) }
}

enum Zip {
  /// Raw DEFLATE (RFC 1951), which is what ZIP method 8 stores.
  static func deflate(_ d: Data) -> Data? {
    var out = Data(count: d.count + 1024)
    let n = out.withUnsafeMutableBytes { o in
      d.withUnsafeBytes { i in
        compression_encode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, o.count, i.bindMemory(to: UInt8.self).baseAddress!, i.count, nil, COMPRESSION_ZLIB)
      }
    }
    guard n > 0 else { return nil }
    out.count = n
    return out
  }

  static func inflate(_ d: Data, size: Int) -> Data? {
    guard size > 0 else { return Data() }
    var out = Data(count: size)
    let n = out.withUnsafeMutableBytes { o in
      d.withUnsafeBytes { i in
        compression_decode_buffer(o.bindMemory(to: UInt8.self).baseAddress!, size, i.bindMemory(to: UInt8.self).baseAddress!, i.count, nil, COMPRESSION_ZLIB)
      }
    }
    return n == size ? out : nil
  }
}

extension Data {
  mutating func le<T: FixedWidthInteger>(_ v: T) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

// MARK: - OLE compound files (legacy XLS and PPT)

/// Reads streams from a Compound File Binary container.
struct CompoundFile {
  private let b: [UInt8]
  private let ss: Int
  private var fat: [UInt32] = [], miniFat: [UInt32] = []
  private var dir: [(name: String, type: UInt8, start: UInt32, size: Int)] = []
  private var ministream: [UInt8] = []

  init(_ url: URL) throws {
    b = [UInt8](try Data(contentsOf: url))
    let bad = ToolError("\(url.lastPathComponent) isn't a valid Office 97–2003 file")
    guard b.count >= 512, b[0..<8].elementsEqual([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) else { throw bad }
    ss = 1 << Int(b[30])
    guard ss == 512 || ss == 4096 else { throw bad }
    // FAT sectors: 109 in the header, the rest in the DIFAT chain
    var fatSectors = (0..<109).map { u32(76 + $0 * 4) }.filter { $0 < 0xFFFFFFFA }
    var d = u32(68), guardN = 0
    while d < 0xFFFFFFFA, guardN < 100_000, off(d) + ss <= b.count {
      let o = off(d)
      fatSectors += (0..<(ss / 4 - 1)).map { u32(o + $0 * 4) }.filter { $0 < 0xFFFFFFFA }
      d = u32(o + ss - 4); guardN += 1
    }
    for s in fatSectors where off(s) + ss <= b.count { fat += (0..<(ss / 4)).map { u32(off(s) + $0 * 4) } }
    let dirBytes = chain(u32(48))
    for i in 0..<(dirBytes.count / 128) {
      let e = Array(dirBytes[(i * 128)..<(i * 128 + 128)])
      let len = max(0, min(64, Int(e[64]) | Int(e[65]) << 8) - 2)
      let name = String(decoding: stride(from: 0, to: len, by: 2).map { UInt16(e[$0]) | UInt16(e[$0 + 1]) << 8 }, as: UTF16.self)
      let start = UInt32(e[116]) | UInt32(e[117]) << 8 | UInt32(e[118]) << 16 | UInt32(e[119]) << 24
      let size = Int(e[120]) | Int(e[121]) << 8 | Int(e[122]) << 16 | Int(e[123]) << 24
      dir.append((name, e[66], start, size))
    }
    guard let root = dir.first, root.type == 5 else { throw bad }
    ministream = chain(root.start)
    let mf = chain(u32(60))
    miniFat = stride(from: 0, to: mf.count - 3, by: 4).map { UInt32(mf[$0]) | UInt32(mf[$0 + 1]) << 8 | UInt32(mf[$0 + 2]) << 16 | UInt32(mf[$0 + 3]) << 24 }
  }

  private func u32(_ i: Int) -> UInt32 { UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24 }
  private func off(_ s: UInt32) -> Int { (Int(s) + 1) * ss }

  private func chain(_ start: UInt32) -> [UInt8] {
    var out: [UInt8] = [], s = start, n = 0
    while s < 0xFFFFFFFA, Int(s) < fat.count, n <= fat.count, off(s) + ss <= b.count {
      out += b[off(s)..<(off(s) + ss)]
      s = fat[Int(s)]; n += 1
    }
    return out
  }

  // ponytail: looks streams up by name anywhere in the tree; the formats read here keep their main stream at the top.
  func stream(_ name: String) -> [UInt8]? {
    guard let e = dir.first(where: { $0.type == 2 && $0.name.lowercased() == name.lowercased() }) else { return nil }
    if e.size >= 4096 { return Array(chain(e.start).prefix(e.size)) }
    var out: [UInt8] = [], s = e.start, n = 0
    while s < 0xFFFFFFFA, Int(s) < miniFat.count, n <= miniFat.count, (Int(s) + 1) * 64 <= ministream.count {
      out += ministream[(Int(s) * 64)..<(Int(s) * 64 + 64)]
      s = miniFat[Int(s)]; n += 1
    }
    return Array(out.prefix(e.size))
  }
}

// MARK: - XML

func xmlRoot(_ data: Data?) -> XMLElement? {
  guard let data else { return nil }
  return ((try? XMLDocument(data: data)) ?? (try? XMLDocument(data: data, options: .documentTidyHTML)))?.rootElement()
}

extension XMLElement {
  var elements: [XMLElement] { children?.compactMap { $0 as? XMLElement } ?? [] }
  func kids(_ name: String) -> [XMLElement] { elements.filter { $0.localName == name } }
  func kid(_ name: String) -> XMLElement? { elements.first { $0.localName == name } }
  /// Descendants by local name, document order.
  func all(_ name: String) -> [XMLElement] { elements.flatMap { ($0.localName == name ? [$0] : []) + $0.all(name) } }
  func first(_ name: String) -> XMLElement? {
    for e in elements { if e.localName == name { return e }; if let f = e.first(name) { return f } }
    return nil
  }
  /// Attribute by qualified name ("r:id"), else by local name.
  func attr(_ name: String) -> String? {
    let a = attributes ?? []
    return (a.first { $0.name == name } ?? (name.contains(":") ? nil : a.first { $0.localName == name }))?.stringValue
  }
  /// Walks `path` of child local names.
  func at(_ path: String...) -> XMLElement? { path.reduce(self as XMLElement?) { $0?.kid($1) } }
}

/// Escapes for XML text and attributes, dropping control characters XML can't hold.
func xmlEscape(_ s: String) -> String {
  var out = ""
  out.reserveCapacity(s.count)
  for u in s.unicodeScalars {
    switch u {
    case "&": out += "&amp;"
    case "<": out += "&lt;"
    case ">": out += "&gt;"
    case "\"": out += "&quot;"
    case "\t", "\n", "\r": out.unicodeScalars.append(u)
    default: if u.value >= 0x20 && u.value != 0xFFFE && u.value != 0xFFFF { out.unicodeScalars.append(u) }
    }
  }
  return out
}

/// Resolves a relationship target against the part that owns it: ("ppt/slides/slide1.xml", "../media/a.png") → "ppt/media/a.png".
func resolvePart(_ from: String, _ target: String) -> String {
  if target.hasPrefix("/") { return String(target.dropFirst()) }
  var parts = from.split(separator: "/").dropLast().map(String.init)
  for p in (target.removingPercentEncoding ?? target).split(separator: "/") {
    if p == ".." { _ = parts.popLast() } else if p != "." { parts.append(String(p)) }
  }
  return parts.joined(separator: "/")
}

extension ZipReader {
  /// Relationship id → resolved part path for `part` (reads `_rels/<name>.rels` beside it).
  func rels(_ part: String) -> [String: String] {
    let dir = (part as NSString).deletingLastPathComponent, file = (part as NSString).lastPathComponent
    let relsPath = (dir.isEmpty ? "" : dir + "/") + "_rels/\(file).rels"
    var out: [String: String] = [:]
    for r in xml(relsPath)?.kids("Relationship") ?? [] where r.attr("TargetMode") != "External" {
      if let id = r.attr("Id"), let t = r.attr("Target") { out[id] = resolvePart(part, t) }
    }
    return out
  }
}
