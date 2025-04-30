// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CoreOCR",
    platforms: [
        .macOS(.v10_15) // Vision and PDFKit require macOS 10.15 or later
    ],
    products: [
        // Library product exposing the CoreOCRLib module
        .library(
            name: "CoreOCRLib",
            type: .dynamic,
            targets: ["CoreOCRLib"]),
        // Executable product providing the command-line tool
        .executable(
            name: "CoreOCRCLI",
            targets: ["CoreOCRCLI"])
    ],
    dependencies: [
        // Library for parsing command-line arguments
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0"),
    ],
    targets: [
        // The core OCR logic library target
        .target(
            name: "CoreOCRLib",
            dependencies: [] // System frameworks like Vision and PDFKit are linked automatically
            // Add resources here if needed
        ),
        // The command-line interface executable target
        .executableTarget(
            name: "CoreOCRCLI", // Name of the executable target
            dependencies: [
                "CoreOCRLib", // Depends on the core library
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        // Test target (add or modify as needed)
        // .testTarget(
        //     name: "CoreOCRTests",
        //     dependencies: ["CoreOCRLib"]),
    ]
)
