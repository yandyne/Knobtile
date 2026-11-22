// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Knobtile",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CoreV2", path: "Sources/CoreV2"),
        .target(name: "Engine", dependencies: ["CoreV2"], path: "Sources/Engine", resources: [.copy("Resources/Plugins")]),
        .executableTarget(name: "coremon", dependencies: ["CoreV2"], path: "Sources/coremon"),
        .executableTarget(name: "monoengine", dependencies: ["Engine"], path: "Sources/monoengine"),
        .executableTarget(name: "Knobtile", dependencies: ["CoreV2", "Engine"], path: "Sources/Knobtile"),
        .testTarget(name: "KnobtileTests", dependencies: ["Knobtile", "CoreV2", "Engine"], path: "Tests"),
    ]
)
