// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Trasivo",
    platforms: [.iOS(.v13)],
    products: [
        .library(name: "Trasivo", targets: ["Trasivo"]),
        .library(name: "TrasivoStorage", targets: ["TrasivoStorage"]),
        .library(name: "TrasivoUI", targets: ["TrasivoUI"])
    ],
    targets: [
        .target(name: "Trasivo", path: "native/ios/Sources/Trasivo"),
        .target(name: "TrasivoStorage", dependencies: ["Trasivo"], path: "native/ios/Sources/TrasivoStorage"),
        .target(name: "TrasivoUI", dependencies: ["Trasivo"], path: "native/ios/Sources/TrasivoUI"),
        .testTarget(name: "TrasivoTests", dependencies: ["Trasivo"], path: "native/ios/Tests/TrasivoTests"),
        .testTarget(name: "TrasivoStorageTests", dependencies: ["TrasivoStorage"], path: "native/ios/Tests/TrasivoStorageTests")
    ],
    swiftLanguageVersions: [.v5]
)
