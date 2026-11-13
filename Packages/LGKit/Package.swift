// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LGKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LGKit", targets: ["LGKit"]),
        .executable(name: "lgctl", targets: ["lgctl"]),
    ],
    targets: [
        .target(name: "LGKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "lgctl", dependencies: ["LGKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "LGKitTests", dependencies: ["LGKit"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
