// swift-tools-version:6.0
import PackageDescription

let vendor = #filePath.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/") + "/Vendor"

let package = Package(
    name: "Beacon",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Beacon",
            path: "Sources/Beacon",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "5", "-F", vendor])
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("EventKit"),
                .linkedFramework("QuartzCore"),
                .unsafeFlags(["-F", vendor, "-framework", "Sparkle", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks", "-Xlinker", "-rpath", "-Xlinker", vendor])
            ]
        ),
        .testTarget(
            name: "BeaconTests",
            dependencies: ["Beacon"],
            path: "Tests/BeaconTests",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "5", "-F", vendor])
            ]
        )
    ]
)
