// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BatterySoH",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "BatterySoH", targets: ["BatterySoH"]),
        .executable(name: "sohstat", targets: ["sohstat"]),
        .library(name: "BatteryKit", targets: ["BatteryKit"]),
    ],
    targets: [
        .target(
            name: "BatteryKit",
            linkerSettings: [.linkedFramework("IOKit")]
        ),
        .executableTarget(
            name: "BatterySoH",
            dependencies: ["BatteryKit"]
        ),
        .executableTarget(
            name: "sohstat",
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
