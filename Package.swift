// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Darkslide",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Darkslide",
            path: "App/Sources"
        )
    ]
)
