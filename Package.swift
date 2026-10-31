// swift-tools-version:5.10
import PackageDescription

var products: [Product] = [
    .library(name: "RoomyCore", targets: ["RoomyCore"]),
    .executable(name: "roomy-scan", targets: ["roomy-scan"]),
]

var targets: [Target] = [
    .target(name: "RoomyCore"),
    .executableTarget(name: "roomy-scan", dependencies: ["RoomyCore"]),
]

#if os(macOS)
products.append(.executable(name: "Roomy", targets: ["Roomy"]))
targets.append(.executableTarget(name: "Roomy", dependencies: ["RoomyCore"]))
#endif

let package = Package(
    name: "Roomy",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
