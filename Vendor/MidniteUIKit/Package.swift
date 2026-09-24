// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MidniteUIKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "MidniteUIKit", targets: ["MidniteUIKit"])],
    targets: [.target(name: "MidniteUIKit")]
)
