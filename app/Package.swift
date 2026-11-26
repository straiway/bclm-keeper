// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BclmKeeper",
    platforms: [
        .macOS("13.0")   // SMAppService（登录自启动）要求 macOS 13
    ],
    targets: [
        .executableTarget(name: "BclmKeeper", path: "Sources/BclmKeeper")
    ]
)
