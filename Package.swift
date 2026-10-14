// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "mdock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "mdock", path: "Sources/mdock"),
        .executableTarget(name: "MdockDesktop", path: "Sources/MdockDesktop"),
        // Accelerator bridge host services (see accel/CONTRACT.md)
        .executableTarget(name: "mdock-vt", path: "Sources/mdock-vt"),
        .executableTarget(name: "mdock-ml", path: "Sources/mdock-ml"),
        .executableTarget(name: "mdock-llm", path: "Sources/mdock-llm"),
    ]
)
