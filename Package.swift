// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hifconverter",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "hifconvert", targets: ["hifconvert"]),
        .executable(name: "hifconvert-check", targets: ["hifconvert-check"]),
        .executable(name: "HIFConverter", targets: ["HIFConverter"])
    ],
    targets: [
        .target(
            name: "Hifconverter",
            swiftSettings: [.unsafeFlags(["-enable-testing"])]
        ),
        .executableTarget(name: "hifconvert", dependencies: ["Hifconverter"]),
        .executableTarget(
            name: "HIFConverter",
            dependencies: ["Hifconverter"],
            path: "Sources/HIFConverterApp"
        ),
        .executableTarget(
            name: "hifconvert-check",
            dependencies: ["Hifconverter"],
            path: "Tests/hifconvertTests"
        )
    ]
)
