// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StatementManager",
    platforms: [.macOS(.v14)],
    products: [.library(name: "StatementCore", targets: ["StatementCore"])],
    dependencies: [.package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.1"), .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.20")],
    targets: [
        .target(name: "StatementCore", dependencies: ["CoreXLSX", "ZIPFoundation"]),
        .testTarget(name: "StatementCoreTests", dependencies: ["StatementCore", "ZIPFoundation"], path: "Tests/StatementManagerTests")
    ]
)
