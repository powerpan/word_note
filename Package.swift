// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "WordNote",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WordNote", targets: ["WordNote"]),
        .library(name: "WordNoteCore", targets: ["WordNoteCore"])
    ],
    targets: [
        .executableTarget(
            name: "WordNote",
            dependencies: ["WordNoteCore"],
            path: "Sources/WordNote"
        ),
        .target(
            name: "WordNoteCore",
            path: "Sources/WordNoteCore"
        ),
        .testTarget(
            name: "WordNoteCoreTests",
            dependencies: ["WordNoteCore"],
            path: "Tests/WordNoteCoreTests",
            resources: [.copy("Fixtures")]
        )
    ],
    swiftLanguageVersions: [.v5]
)
