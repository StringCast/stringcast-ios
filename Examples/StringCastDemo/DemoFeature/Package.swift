// swift-tools-version:5.9
import PackageDescription

/// A feature module with its own strings, like the packages of a modular app. Its `Feature` table
/// ends up in `StringCastDemo.app/DemoFeature_DemoFeature.bundle`, which StringCast uploads and intercepts.
let package = Package(
    name: "DemoFeature",
    defaultLocalization: "en",
    platforms: [.iOS(.v15)],
    products: [.library(name: "DemoFeature", targets: ["DemoFeature"])],
    targets: [
        .target(name: "DemoFeature", resources: [.process("Resources")]),
    ]
)
