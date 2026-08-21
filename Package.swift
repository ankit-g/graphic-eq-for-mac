// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GraphicEQ",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "GraphicEQ",
            path: "Sources/GraphicEQ"
        )
    ]
)
