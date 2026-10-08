// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Polyglot",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "Polyglot", targets: ["Polyglot"]),
    ],
    targets: [
        .target(name: "Polyglot", path: "Sources/Polyglot"),
        .testTarget(name: "PolyglotTests", dependencies: ["Polyglot"], path: "Tests/PolyglotTests"),
    ]
)
