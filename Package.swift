// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuickLaTeX",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuickLaTeX",
            path: "Sources/QuickLaTeX",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("PDFKit"),
            ]
        )
    ]
)
