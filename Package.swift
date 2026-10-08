// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StringCast",
    platforms: [
        .iOS(.v13),
        .macOS(.v11),
        .tvOS(.v13),
    ],
    products: [
        .library(name: "StringCast", targets: ["StringCast"]),
    ],
    targets: [
        .target(name: "StringCast", path: "Sources/StringCast"),
        .testTarget(name: "StringCastTests", dependencies: ["StringCast"], path: "Tests/StringCastTests"),
    ]
)
