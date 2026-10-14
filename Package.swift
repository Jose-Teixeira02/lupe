// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Lupe",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Lupe", targets: ["Lupe"]),
        .library(name: "LupeCore", targets: ["LupeCore"]),
    ],
    targets: [
        .target(name: "LupeCore", path: "Sources/LupeCore"),
        .executableTarget(
            name: "Lupe",
            dependencies: ["LupeCore"],
            path: "Sources/Lupe",
            linkerSettings: [.linkedFramework("Carbon")]
        ),
        .executableTarget(name: "LupeChecks", dependencies: ["LupeCore"], path: "Sources/LupeChecks"),
    ],
    swiftLanguageModes: [.v5]
)
