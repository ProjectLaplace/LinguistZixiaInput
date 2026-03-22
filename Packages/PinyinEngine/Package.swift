// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PinyinEngine",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "PinyinEngine",
            targets: ["PinyinEngine"]),
        .executable(
            name: "pinyin-eval",
            targets: ["PinyinEval"]),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "PinyinEngine",
            dependencies: [],
            resources: [
                .process("Resources")
            ]),
        .executableTarget(
            name: "PinyinEval",
            dependencies: ["PinyinEngine"]),
        .testTarget(
            name: "PinyinEngineTests",
            dependencies: ["PinyinEngine"]),
    ]
)
