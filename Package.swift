// swift-tools-version:5.10
import PackageDescription

var products: [Product] = [
    .library(name: "RoomyCore", targets: ["RoomyCore"]),
    .executable(name: "roomy-scan", targets: ["roomy-scan"]),
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(name: "RoomyCore"),
    .executableTarget(name: "roomy-scan", dependencies: ["RoomyCore"]),
    .testTarget(name: "RoomyCoreTests", dependencies: ["RoomyCore"]),
]

#if os(macOS)
products.append(.executable(name: "Roomy", targets: ["Roomy"]))
// Sparkle delivers signed updates to the app (see scripts/release.sh).
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"))
targets.append(.executableTarget(
    name: "Roomy",
    dependencies: ["RoomyCore", .product(name: "Sparkle", package: "Sparkle")]
))
#endif

let package = Package(
    name: "Roomy",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
