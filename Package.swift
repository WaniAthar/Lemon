// swift-tools-version:5.10
import PackageDescription

let package = Package(
  name: "Lemon",
  platforms: [.macOS(.v14)],
  targets: [.executableTarget(name: "Lemon", path: "Sources/Lemon")]
)
