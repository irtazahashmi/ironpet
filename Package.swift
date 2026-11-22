// swift-tools-version:5.10
import PackageDescription

// The Mac app, its tests and the Mac-only packages are left out on Linux and Windows, where CI builds and tests only IronPetCore.
// That keeps package resolution from cloning FluidAudio and Hummingbird, and `swift test` from compiling the app.
#if os(Linux) || os(Windows)
let macDependencies: [Package.Dependency] = []
let macTargets: [Target] = []
#else
let macDependencies: [Package.Dependency] = [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
        // Pinned to releases whose manifests need Swift 6.1 or older, because CI builds with 6.1 and later ones declare tools 6.2.
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", exact: "2.16.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", exact: "2.6.0"),
        // Hummingbird's own dependencies resolve to their newest releases, which need Swift 6.2. Pinning them here keeps
        // the build on the Swift 6.1 that CI uses. None is imported by ironpet itself. Raise them together with CI's toolchain.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1"),
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.9.1"),
        .package(url: "https://github.com/apple/swift-system.git", exact: "1.8.1"),
        // The remote API serves HTTPS through Network.framework, the system's TLS, which Hummingbird already links on macOS. Named here
        // so ironpet can import it; it was already resolved as a dependency of Hummingbird and adds nothing to the binary.
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", exact: "1.28.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", exact: "2.11.0"),
        .package(url: "https://github.com/apple/swift-distributed-tracing.git", exact: "1.5.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", exact: "1.0.4"),
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.30.3"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", exact: "2.10.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", exact: "1.3.0"),
]
let macTargets: [Target] = [
        .testTarget(name: "IronPetKitTests", dependencies: ["IronPetKit"], path: "Tests/IronPetKitTests"),
        .target(name: "IronPetObjC", path: "Sources/IronPetObjC"),
        .executableTarget(name: "IronPet", dependencies: ["IronPetCore", "IronPetKit", "IronPetObjC", .product(name: "JMESPath", package: "jmespath.swift"), .product(name: "QuickJS", package: "QuickJS-Swift"), .product(name: "FluidAudio", package: "FluidAudio"), .product(name: "Hummingbird", package: "hummingbird"), .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"), .product(name: "NIOTransportServices", package: "swift-nio-transport-services")], path: "Sources/IronPet"),
        .testTarget(name: "IronPetTests", dependencies: ["IronPet", "IronPetCore"], path: "Tests/IronPetTests"),
]
#endif

let package = Package(
    name: "IronPet",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "IronPetKit", targets: ["IronPetKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/adam-fowler/jmespath.swift", exact: "1.0.3"),
        .package(path: "Vendor/QuickJS-Swift"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    ] + macDependencies,
    targets: [
        // The wire types, the client and the sprite atlas that the iOS app and the Mac app share. Every Apple-only import (CryptoKit, Security, CoreGraphics, ImageIO, SwiftUI, AppKit) sits behind `canImport`, so it builds for iOS and for Linux.
        .target(name: "IronPetKit", dependencies: [.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows]))], path: "Sources/IronPetKit"),
        // SQLite for Linux and Windows. Apple platforms use the SQLite3 module from the SDK, so nothing links this there.
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
        // The half of ironpet that needs no UI and no Mac framework: stores, the agent client, automations, tasks, the API layer
        // and the platform protocols. Tests/IronPetCoreTests/ImportAllowListTests.swift fails when a file here imports a framework
        // outside its allow list. A feature with no UI lands here, and UI code calls only IronPetAPI.
        .target(name: "IronPetCore", dependencies: ["IronPetKit", .product(name: "JMESPath", package: "jmespath.swift"), .product(name: "QuickJS", package: "QuickJS-Swift"), .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows])), .target(name: "CSQLite", condition: .when(platforms: [.linux, .windows]))], path: "Sources/IronPetCore"),
        .testTarget(name: "IronPetCoreTests", dependencies: ["IronPetCore", .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux, .windows]))], path: "Tests/IronPetCoreTests", exclude: ["Contract/Fixtures"], resources: [.copy("Fixtures")]),
    ] + macTargets
)
