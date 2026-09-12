// swift-tools-version: 6.0
import PackageDescription

// PunchlistCore deliberately contains no UIKit, SwiftUI, AVFoundation or
// PDFKit. Everything that decides what is true — schema, migrations, ids,
// clocks, repositories, the report's layout model — lives here, so it builds
// and tests on Linux CI with no simulator. The app target on top of it is the
// only place Apple frameworks appear.
let package = Package(
    name: "Punchlist",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PunchlistCore", targets: ["PunchlistCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // swift-crypto shims to CryptoKit on Apple platforms and provides the
        // same API on Linux, which keeps the snapshot hash identical in CI and
        // on device.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "PunchlistCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            // .copy, not .process: .process flattens the directory tree, and the
            // migration runner addresses files by subdirectory.
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "PunchlistCoreTests",
            dependencies: ["PunchlistCore"]
        ),
    ]
)
