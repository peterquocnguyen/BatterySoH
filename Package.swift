// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatteryBuddy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BatteryBuddy", targets: ["BatteryBuddy"]),
        .executable(name: "bbstat", targets: ["bbstat"]),
        .library(name: "BatteryKit", targets: ["BatteryKit"]),
    ],
    targets: [
        .target(
            name: "BatteryKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "BatteryBuddy",
            dependencies: ["BatteryKit"]
        ),
        .executableTarget(
            name: "bbstat",
            dependencies: ["BatteryKit"]
        ),
        .testTarget(
            name: "BatteryKitTests",
            dependencies: ["BatteryKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
