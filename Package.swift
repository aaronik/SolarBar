// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SolarBar",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "SolarBar", targets: ["SolarBar"])],
    targets: [.executableTarget(name: "SolarBar")]
)
