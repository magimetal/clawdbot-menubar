// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClawdbotMenu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ClawdbotMenu", targets: ["ClawdbotMenu"])
    ],
    targets: [
        .executableTarget(
            name: "ClawdbotMenu",
            path: "ClawdbotMenu"
        )
    ]
)
