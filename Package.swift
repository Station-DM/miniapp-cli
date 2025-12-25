// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MiniAppCLI",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "miniapp", targets: ["miniapp"])
    ],
    targets: [
        .executableTarget(
            name: "miniapp",
            path: "Sources"
        )
    ]
)
