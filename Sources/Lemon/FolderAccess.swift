import AppKit

/// Sandbox write access for saving next to originals. Granting the home folder once covers everything inside it.
@MainActor final class FolderAccess: ObservableObject {
  static let shared = FolderAccess()
  private let key = "folderBookmarks"
  @Published private(set) var folders: [URL] = []
  private var bookmarks: [Data] = []

  /// The user's real home; NSHomeDirectory() is the sandbox container.
  static var realHome: URL {
    if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return URL(fileURLWithPath: String(cString: dir)) }
    return FileManager.default.homeDirectoryForCurrentUser
  }

  private init() {
    for data in UserDefaults.standard.array(forKey: key) as? [Data] ?? [] {
      var stale = false
      guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
            url.startAccessingSecurityScopedResource() else { continue }
      folders.append(url)
      bookmarks.append(data)
    }
  }

  var hasAny: Bool { !folders.isEmpty }

  func covers(_ dir: URL) -> Bool {
    let p = dir.standardizedFileURL.path
    return folders.contains { p == $0.path || p.hasPrefix($0.path == "/" ? "/" : $0.path + "/") }
  }

  /// True when `dir` is writable, asking once if nothing saved covers it.
  func ensure(_ dir: URL) -> Bool {
    covers(dir) || (add(message: "Lemon saves converted files next to the originals. Allow your Home folder once and it won't ask again.") && covers(dir))
  }

  @discardableResult
  func add(message: String = "Choose a folder Lemon may save converted files into. Allowing your Home folder covers everything inside it.") -> Bool {
    NSApp.activate()
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.directoryURL = Self.realHome
    panel.prompt = "Allow"
    panel.message = message
    guard panel.runModal() == .OK, let url = panel.url,
          let data = try? url.bookmarkData(options: .withSecurityScope),
          url.startAccessingSecurityScopedResource() else { return false }
    folders.append(url)
    bookmarks.append(data)
    UserDefaults.standard.set(bookmarks, forKey: key)
    return true
  }

  func remove(_ url: URL) {
    guard let i = folders.firstIndex(of: url) else { return }
    url.stopAccessingSecurityScopedResource()
    folders.remove(at: i)
    bookmarks.remove(at: i)
    UserDefaults.standard.set(bookmarks, forKey: key)
  }
}
