// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "hasocket",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "HASocketCore", path: "Sources/HASocketCore"),
        .executableTarget(name: "hasocket", dependencies: ["HASocketCore"], path: "Sources/hasocket"),
        .executableTarget(name: "HASocketMenuBar", dependencies: ["HASocketCore"], path: "Sources/HASocketMenuBar"),
    ]
)
