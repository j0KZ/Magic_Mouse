// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MagicMouseGestures",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MagicMouseGestures", targets: ["MagicMouseGestures"]),
        .executable(name: "mmg-probe", targets: ["mmg-probe"]),
    ],
    targets: [
        .target(name: "MagicMouseKit"),
        .executableTarget(name: "MagicMouseGestures", dependencies: ["MagicMouseKit"]),
        .executableTarget(name: "mmg-probe", dependencies: ["MagicMouseKit"]),
    ]
)
