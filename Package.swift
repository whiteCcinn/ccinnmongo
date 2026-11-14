// swift-tools-version: 6.0
import PackageDescription

let strictSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
]

let package = Package(
    name: "CcinnMongo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BSON", targets: ["BSON"]),
        .library(name: "MongoWire", targets: ["MongoWire"]),
        .library(name: "MongoKit", targets: ["MongoKit"]),
        .library(name: "CcinnMongoKit", targets: ["CcinnMongoKit"]),
        .library(name: "CcinnMongoMCP", targets: ["CcinnMongoMCP"]),
        .executable(name: "CcinnMongo", targets: ["CcinnMongo"]),
    ],
    targets: [
        // Pure BSON value model, binary codec, shell-syntax / Extended JSON.
        .target(name: "BSON", swiftSettings: strictSettings),
        // MongoDB wire-protocol messages and framing. No I/O.
        .target(name: "MongoWire", dependencies: ["BSON"], swiftSettings: strictSettings),
        // Transport, authentication, topology, pooling and version-aware operations.
        .target(name: "MongoKit", dependencies: ["BSON", "MongoWire"], swiftSettings: strictSettings),
        // UI-independent application logic (profiles, export, schema, explain, ...).
        .target(name: "CcinnMongoKit", dependencies: ["BSON", "MongoKit"], swiftSettings: strictSettings),
        // Model Context Protocol server (stdio JSON-RPC) exposing saved connections to AI clients. No UI.
        .target(name: "CcinnMongoMCP", dependencies: ["BSON", "MongoKit", "CcinnMongoKit"], swiftSettings: strictSettings),
        // SwiftUI application (and the headless `mcp` subcommand).
        .executableTarget(
            name: "CcinnMongo",
            dependencies: ["BSON", "MongoKit", "CcinnMongoKit", "CcinnMongoMCP"],
            swiftSettings: strictSettings
        ),

        .testTarget(name: "BSONTests", dependencies: ["BSON"], swiftSettings: strictSettings),
        .testTarget(name: "MongoWireTests", dependencies: ["BSON", "MongoWire"], swiftSettings: strictSettings),
        .testTarget(name: "MongoKitTests", dependencies: ["BSON", "MongoWire", "MongoKit"], swiftSettings: strictSettings),
        .testTarget(name: "CcinnMongoKitTests", dependencies: ["BSON", "MongoKit", "CcinnMongoKit"], exclude: ["Fixtures"], swiftSettings: strictSettings),
        .testTarget(name: "CcinnMongoMCPTests", dependencies: ["BSON", "MongoKit", "CcinnMongoKit", "CcinnMongoMCP"], swiftSettings: strictSettings),
        .testTarget(name: "IntegrationTests", dependencies: ["BSON", "MongoKit", "CcinnMongoKit", "CcinnMongoMCP"], swiftSettings: strictSettings),
    ],
    swiftLanguageModes: [.v6]
)
