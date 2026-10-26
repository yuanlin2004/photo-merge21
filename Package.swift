// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PhotoMerge",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "photo-merge", targets: ["PhotoMerge"]),
               .executable(name: "photo-flip", targets: ["PhotoFlip"])],
    targets: [
        .target(name: "PhotoMergeCore"),
        .executableTarget(name: "PhotoMerge", dependencies: ["PhotoMergeCore"]),
        .executableTarget(name: "PhotoFlip", dependencies: ["PhotoMergeCore"]),
        .testTarget(name: "PhotoMergeCoreTests", dependencies: ["PhotoMergeCore"])
    ]
)
