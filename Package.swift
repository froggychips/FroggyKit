// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FroggyKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "FroggyKit", targets: ["FroggyKit"]),
    ],
    targets: [
        .target(name: "FroggyKit", path: "Sources/FroggyKit"),
        .testTarget(
            name: "FroggyKitTests",
            dependencies: ["FroggyKit"],
            path: "Tests/FroggyKitTests"
        ),
    ]
)
