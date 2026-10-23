import AppKit
import SwiftUI

extension SelfTest {
  static func floatPack(dir: URL) async {
    let names = ["Alpha.txt", "bravo.png", "Charlie.pdf", "delta.mov", "echo.zip"]
    let urls = names.map { n -> URL in
      let u = dir.appendingPathComponent(n)
      try? Data(repeating: 1, count: 2048).write(to: u)
      return u
    }
    let (a, b, c, d, e) = (urls[0], urls[1], urls[2], urls[3], urls[4])

    let m = ShelfModel()
    check(m.add([a, b, c]) == 3 && m.add([a, URL(fileURLWithPath: dir.path + "/./bravo.png")]) == 0 && m.items.count == 3,
          "shelf: same file added twice is kept once")
    m.add([d, e])
    m.click(b)
    check(m.selection == [b], "shelf: click selects one")
    m.click(d, command: true)
    check(m.selection == [b, d], "shelf: ⌘-click adds")
    m.click(b, command: true)
    check(m.selection == [d], "shelf: ⌘-click toggles off")
    m.click(b)
    m.click(d, shift: true)
    check(m.selected == [b, c, d], "shelf: ⇧-click selects the range from the anchor")
    m.click(a, shift: true)
    check(m.selected == [a, b], "shelf: ⇧-range pivots on the same anchor")
    check(m.targets(c, select: true) == [c] && m.selection == [c], "shelf: dragging an unselected item selects it alone")
    m.selectAll()
    check(m.targets(c) == urls, "shelf: acting on a selected item uses the whole selection")
    check(m.typeSelect("CH") == c && m.selection == [c], "shelf: type-to-select ignores case")
    check(m.typeSelect("zz") == nil && m.selection == [c], "shelf: type-to-select miss keeps the selection")

    m.frames = [a: CGRect(x: 0, y: 0, width: 76, height: 94), b: CGRect(x: 82, y: 0, width: 76, height: 94),
                c: CGRect(x: 164, y: 0, width: 76, height: 94)]
    m.rubberBand(CGRect(x: 60, y: 20, width: 40, height: 10), base: [])
    check(m.selection == [a, b], "shelf: rubber band selects what it touches")
    m.rubberBand(CGRect(x: 200, y: 20, width: 5, height: 5), base: [e])
    check(m.selection == [c, e], "shelf: rubber band with ⌘ adds to the selection")

    var emptied = 0
    m.onEmpty = { emptied += 1 }
    m.remove([c])
    check(m.items == [a, b, d, e] && m.selection == [e], "shelf: remove prunes items and selection")
    m.pullOut([a, b])
    check(m.items == [d, e] && m.pulls == 1 && emptied == 0, "shelf: pull out removes and wiggles the clip")
    m.clear()
    check(m.items.isEmpty && emptied == 1, "shelf: removing the last item closes the shelf")

    // Edge snapping in a 1000x800 visible frame offset by the menu bar.
    let vf = CGRect(x: 0, y: 0, width: 1000, height: 775)
    let mid = ShelfGeo.snap(CGRect(x: 400, y: 300, width: 150, height: 170), in: vf)
    check(mid.edge == nil && mid.frame.origin == CGPoint(x: 400, y: 300), "snap: far from edges stays put")
    let left = ShelfGeo.snap(CGRect(x: 30, y: 300, width: 150, height: 170), in: vf)
    check(left.edge == .minXEdge && left.frame.minX == 8 && left.frame.minY == 300, "snap: near the left edge attaches to it")
    let right = ShelfGeo.snap(CGRect(x: 920, y: 300, width: 150, height: 170), in: vf)
    check(right.edge == .maxXEdge && right.frame.maxX == 992, "snap: dragged past the right edge attaches to it")
    let top = ShelfGeo.snap(CGRect(x: 400, y: 590, width: 150, height: 170), in: vf)
    check(top.edge == .maxYEdge && top.frame.maxY == 767, "snap: near the top attaches below the menu bar")
    let big = ShelfGeo.size(count: 9, expanded: true, list: false)
    let grown = ShelfGeo.place(big, from: right.frame, edge: .maxXEdge, in: vf)
    check(grown.maxX == right.frame.maxX && grown.maxY == right.frame.maxY && grown.width == 352,
          "expanding keeps the attached right edge and the top in place")
    check(ShelfGeo.place(big, from: CGRect(x: 400, y: 10, width: 150, height: 170), edge: nil, in: vf).minY == 8,
          "expanding near the bottom stays on screen")

    let txt = Tools.available(for: [a], mode: .action).map(\.id)
    check(txt.contains("act.float") && txt.count <= Tools.maxInFan, "Float is an action for any file")

    if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
      renderShelves(urls, to: URL(fileURLWithPath: CommandLine.arguments[i + 1]).deletingPathExtension().appendingPathExtension("float.png"))
    }
  }

  /// Compact, expanded grid and expanded list side by side (plain fills).
  static func renderShelves(_ urls: [URL], to out: URL) {
    lemonPlainRender = true
    defer { lemonPlainRender = false }
    func shelf(expanded: Bool, list: Bool) -> some View {
      let m = ShelfModel()
      m.add(urls)
      m.expanded = expanded
      m.list = list
      m.selection = [urls[1], urls[2]]
      let s = ShelfGeo.size(count: urls.count, expanded: expanded, list: list)
      return ShelfView(model: m).frame(width: s.width, height: s.height)
    }
    let views = HStack(alignment: .top, spacing: 24) {
      shelf(expanded: false, list: false)
      shelf(expanded: true, list: false)
      shelf(expanded: true, list: true)
    }.padding(24).background(Color(red: 0.75, green: 0.82, blue: 0.9))
    let r = ImageRenderer(content: views)
    r.scale = 2
    if let t = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
      try? png.write(to: out)
      print("rendered", out.path)
    }
  }
}
