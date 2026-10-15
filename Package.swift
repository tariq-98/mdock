// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "mdock",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "mdock", path: "Sources/mdock", exclude: ["Info.plist"],
            // Embedded Info.plist: names mdock in macOS privacy prompts (Local Network).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                           "-Xlinker", "Sources/mdock/Info.plist"])]),
        .executableTarget(name: "MdockDesktop", path: "Sources/MdockDesktop"),
        // Accelerator bridge host services (see accel/CONTRACT.md)
        .executableTarget(name: "mdock-vt", path: "Sources/mdock-vt"),
        .executableTarget(name: "mdock-ml", path: "Sources/mdock-ml"),
        .executableTarget(name: "mdock-llm", path: "Sources/mdock-llm"),
    ]
)
