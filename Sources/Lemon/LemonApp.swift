import SwiftUI

@main
struct LemonApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @AppStorage(alwaysShowFanKey) private var alwaysShow = false

  /// Self-test runs launch the app too; they shouldn't add a menu bar item.
  private static let selfTest = CommandLine.arguments.contains("--selftest")

  var body: some Scene {
    MenuBarExtra(isInserted: .constant(!Self.selfTest)) {
      Toggle("Show Lemon on Every File Drag", isOn: $alwaysShow)
      Text("While dragging: ⇧ Convert · ⌘ Edit · ⌃ Actions")
      Divider()
      Button("Show Shelf") { Shelves.newShelf() }
      Button("Allow a Folder…") { FolderAccess.shared.add() }
      SettingsLink { Text("Settings…") }.keyboardShortcut(",")
      Divider()
      Button("Quit Lemon") { NSApp.terminate(nil) }.keyboardShortcut("q")
    } label: {
      Image(nsImage: .lemonTemplate)
    }
    Settings { SettingsView() }
  }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  private var watcher: DragWatcher?

  func applicationDidFinishLaunching(_ notification: Notification) {
    if CommandLine.arguments.contains("--selftest") {
      Task { exit(await SelfTest.run()) }
      return
    }
    watcher = DragWatcher()
    watcher?.start()
    // One prompt on first launch instead of one per folder later.
    if !FolderAccess.shared.hasAny {
      DispatchQueue.main.async {
        FolderAccess.shared.add(message: "Welcome to Lemon. Allow your Home folder so converted files can be saved next to the originals. You'll only be asked once.")
      }
    }
  }
}

struct SettingsView: View {
  @AppStorage(alwaysShowFanKey) private var alwaysShow = false
  @ObservedObject private var access = FolderAccess.shared
  @AppStorage(shelfRemoveAfterDragKey) private var removeAfterDrag = false

  var body: some View {
    Form {
      Section("Lemon") {
        Toggle("Show on every file drag", isOn: $alwaysShow)
        Text("When off, hold Shift (convert), Command (edit) or Control (actions) while dragging files.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Float shelf") {
        Toggle("Remove items after dragging them out", isOn: $removeAfterDrag)
      }
      Section("Folders Lemon can save into") {
        ForEach(access.folders, id: \.self) { url in
          HStack {
            Image(systemName: "folder")
            Text(url.path).lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Remove") { access.remove(url) }
          }
        }
        Button("Allow a Folder…") { access.add() }
      }
    }
    .formStyle(.grouped)
    .frame(width: 480, height: 360)
  }
}
