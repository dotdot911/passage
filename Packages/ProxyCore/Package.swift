// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ProxyCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TunnelCore", targets: ["TunnelCore"]),
        .library(name: "HTTPEngine", targets: ["HTTPEngine"]),
        .library(name: "Storage", targets: ["Storage"]),
        .library(name: "IPC", targets: ["IPC"]),
        .library(name: "CertKit", targets: ["CertKit"]),
        .library(name: "ProxyModel", targets: ["ProxyModel"]),
        .library(name: "Viewing", targets: ["Viewing"]),
        .library(name: "Rules", targets: ["Rules"]),
        .library(name: "Archive", targets: ["Archive"]),
        .library(name: "Scripting", targets: ["Scripting"]),
    ],
    dependencies: [
        // 2.104.0 made ByteToMessageHandler conform to ChannelInboundHandler under `Decoder: ~Copyable`;
        // the iOS 17 Swift runtime cannot evaluate that conformance, so `as? _ChannelInboundHandler`
        // fails and NIO traps when the handler is added. Stay on 2.103.x until iOS 18 is the minimum.
        .package(url: "https://github.com/apple/swift-nio.git", "2.103.0"..<"2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5"),
        .package(url: "https://github.com/apple/swift-nio-http2.git", from: "1.46.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "CLwIP",
            exclude: ["lwip/COPYING"],
            cSettings: [
                .headerSearchPath("port"),
                .headerSearchPath("lwip/include"),
                // lwIP is third-party C: silence its warnings, and keep Clang modules off so its
                // `struct ip6_hdr` does not clash with <netinet/ip6.h> from the Darwin module.
                .unsafeFlags(["-Wno-everything", "-fno-modules"]),
            ]
        ),
        .target(
            name: "CZstd",
            exclude: ["lib/LICENSE"],
            cSettings: [
                // Decompression only, portable C (no x86 assembly), no legacy formats.
                .define("ZSTD_DISABLE_ASM"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
                .unsafeFlags(["-Wno-everything"]),
            ]
        ),
        .target(name: "ProxyModel"),
        .target(name: "Viewing", dependencies: ["CZstd", "ProxyModel"]),
        .target(name: "Rules", dependencies: ["ProxyModel"]),
        .target(name: "Archive", dependencies: ["ProxyModel", "Viewing", .product(name: "Yams", package: "Yams")]),
        .target(name: "Scripting", dependencies: ["ProxyModel", "Viewing", .product(name: "Crypto", package: "swift-crypto")]),
        .target(name: "NetStack", dependencies: ["CLwIP", "ProxyModel"]),
        .target(name: "Packet", dependencies: ["ProxyModel"]),
        .target(name: "CertKit", dependencies: [
            "ProxyModel",
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .target(name: "Bridge", dependencies: [
            "NetStack",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .target(name: "Storage", dependencies: ["ProxyModel", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "HTTPEngine", dependencies: [
            "ProxyModel", "CertKit", "Rules",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOHTTP2", package: "swift-nio-http2"),
        ]),
        .target(name: "IPC", dependencies: ["ProxyModel"]),
        .target(name: "TunnelCore", dependencies: [
            "Bridge", "CertKit", "HTTPEngine", "NetStack", "Packet", "ProxyModel", "Rules",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .target(name: "TestSupport", dependencies: [
            "HTTPEngine", "ProxyModel",
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ], path: "Tests/TestSupport"),
        .testTarget(name: "NetStackTests", dependencies: ["NetStack", "TestSupport"]),
        .testTarget(name: "PacketTests", dependencies: ["Packet", "ProxyModel"]),
        .testTarget(name: "CertKitTests", dependencies: [
            "CertKit",
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOTLS", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .testTarget(name: "BridgeTests", dependencies: ["Bridge", "TestSupport", .product(name: "NIOPosix", package: "swift-nio")]),
        .testTarget(name: "StorageTests", dependencies: ["Storage", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "HTTPEngineTests", dependencies: [
            "HTTPEngine", "CertKit", "TestSupport", "Rules", "Scripting",
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
            .product(name: "NIOHTTP2", package: "swift-nio-http2"),
            .product(name: "NIOTLS", package: "swift-nio"),
        ]),
        .testTarget(name: "IPCTests", dependencies: ["IPC", "ProxyModel"]),
        .testTarget(name: "RulesTests", dependencies: ["Rules", "ProxyModel"]),
        .testTarget(name: "ArchiveTests", dependencies: ["Archive", "ProxyModel"]),
        .testTarget(name: "ScriptingTests", dependencies: ["Scripting", "ProxyModel"]),
        .testTarget(name: "ViewingTests", dependencies: ["Viewing", "ProxyModel"]),
        .testTarget(name: "TunnelCoreTests", dependencies: [
            "TunnelCore", "TestSupport", "Packet", "Rules",
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOHTTP1", package: "swift-nio"),
        ]),
    ]
)
