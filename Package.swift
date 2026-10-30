// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FingerPath",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "FingerPath", targets: ["FingerPath"])],
    targets: [.executableTarget(name: "FingerPath", path: "Sources/FingerPath")]
)
