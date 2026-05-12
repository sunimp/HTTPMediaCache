// swift-tools-version: 5.10
//
//  Package.swift
//  HTTPMediaCache
//
//  Created by Sun on 2026/5/9.
//

import PackageDescription

let package = Package(
    name: "HTTPMediaCache",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(name: "HTTPMediaCache", targets: ["HTTPMediaCache"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.99.0"),
    ],
    targets: [
        .target(
            name: "HTTPMediaCache",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/HTTPMediaCache"
        ),
        .testTarget(
            name: "HTTPMediaCacheTests",
            dependencies: ["HTTPMediaCache"],
            path: "Tests/HTTPMediaCacheTests"
        ),
    ]
)
