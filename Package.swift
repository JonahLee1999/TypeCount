// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeCount",
    platforms: [.macOS("15.6")],
    products: [.executable(name: "TypeCount", targets: ["TypeCount"])],
    targets: [
        .executableTarget(name: "TypeCount"),
        .testTarget(name: "TypeCountTests", dependencies: ["TypeCount"])
    ]
)
