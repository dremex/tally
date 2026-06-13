// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tally",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .executableTarget(
            name: "Tally",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/Tally"
        ),
        .testTarget(
            name: "TallyTests",
            dependencies: ["Tally"],
            path: "Tests/TallyTests"
        )
    ]
)
