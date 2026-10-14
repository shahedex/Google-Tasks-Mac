// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GoogleTasks",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GoogleTasks",
            path: "Sources/GoogleTasks"
        )
    ]
)
