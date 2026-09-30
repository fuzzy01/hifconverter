// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hifconverter",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "hifconvert", targets: ["hifconvert"]),
        .executable(name: "hifconvert-check", targets: ["hifconvert-check"])
    ],
    targets: [
        .target(
            name: "Hifconverter",
            swiftSettings: [.unsafeFlags(["-enable-testing"])]
        ),
        .executableTarget(name: "hifconvert", dependencies: ["Hifconverter"]),
        .executableTarget(
            name: "hifconvert-check",
            dependencies: ["Hifconverter"],
            path: "Tests/hifconvertTests"
        )
    ]
)
