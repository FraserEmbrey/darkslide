// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Darkslide",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Darkslide",
            path: "App/Sources"
        ),
        // the Quick Look extension (App/QuickLook): an app extension's entry
        // point is NSExtensionMain, and build-app.sh puts it in PlugIns
        .executableTarget(
            name: "DarkslideQuickLook",
            path: "App/QuickLook",
            exclude: ["Info.plist", "QuickLook.entitlements"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"])]
        ),
    ]
)
