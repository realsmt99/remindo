// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Remindo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Remindo", targets: ["Remindo"])
    ],
    targets: [
        .executableTarget(
            name: "Remindo",
            path: "Sources/Remindo"
        )
    ]
)
