// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "TypeSafe",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "TypeSafe", targets: ["TypeSafe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.0.6"),
    ],
    targets: [
        .target(
            name: "TypeSafe",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "OrderedCollections", package: "swift-collections"),
            ]
        ),
        .testTarget(
            name: "TypeSafeTests",
            dependencies: ["TypeSafe"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
