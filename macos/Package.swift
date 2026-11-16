// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Rays",
    platforms: [.macOS(.v26)],
    targets: [
        .binaryTarget(name: "dl_engineFFI", path: "../build/dl_engineFFI.xcframework"),
        .executableTarget(
            name: "Rays",
            dependencies: ["dl_engineFFI"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
