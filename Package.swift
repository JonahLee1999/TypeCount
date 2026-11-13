// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TypeCount",
    platforms: [.macOS("15.6")],
    products: [.executable(name: "TypeCount", targets: ["TypeCount"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .executableTarget(
            name: "TypeCount",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        ),
        .testTarget(name: "TypeCountTests", dependencies: ["TypeCount"])
    ]
)
