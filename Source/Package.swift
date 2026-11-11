// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "d7n", platforms: [.macOS(.v26)], products: [.executable(name: "d7n", targets: ["d7n"])], targets: [.executableTarget(name: "d7n"), .testTarget(name: "d7nTests", dependencies: ["d7n"])], swiftLanguageModes: [.v5])
