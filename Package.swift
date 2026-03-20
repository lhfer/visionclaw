// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ShrimpXR",
    platforms: [
        .visionOS(.v1)
    ],
    products: [
        .library(name: "ShrimpXR", targets: ["ShrimpXR"]),
    ],
    targets: [
        .target(
            name: "ShrimpXR",
            path: "ShrimpXR/Sources",
            resources: [
                .process("../Resources")
            ]
        ),
    ]
)
