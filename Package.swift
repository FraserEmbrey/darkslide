// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Develop",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Develop",
            path: "App/Sources"
        )
    ]
)
