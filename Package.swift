// swift-tools-version: 6.2
import PackageDescription

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.2"),
    .package(url: "https://github.com/dduan/TOMLDecoder.git", exact: "0.4.5"),
    .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.5.2"),
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
]
var serviceDependencies: [Target.Dependency] = ["AudioCore", "AudioRuntime", "AudioHTTP", .product(name: "Vapor", package: "vapor")]
var targets: [Target] = [
    .target(name: "AudioCore", dependencies: [.product(name: "TOMLDecoder", package: "TOMLDecoder")]),
    .target(name: "AudioRuntime", dependencies: ["AudioCore", .product(name: "Crypto", package: "swift-crypto")]),
    .target(name: "AudioMCP", dependencies: ["AudioCore", .product(name: "MCP", package: "swift-sdk"), .product(name: "Vapor", package: "vapor")]),
    .target(name: "AudioHTTP", dependencies: ["AudioCore", "AudioMCP", .product(name: "Vapor", package: "vapor")], resources: [.copy("Resources/AdminUI")]),
    .target(name: "AudioTestSupport", dependencies: ["AudioCore"], path: "Tests/Support"),
    .testTarget(name: "AudioCoreTests", dependencies: ["AudioCore", "AudioTestSupport"]),
    .testTarget(name: "AudioHTTPTests", dependencies: ["AudioCore", "AudioHTTP", "AudioRuntime", "AudioTestSupport", .product(name: "VaporTesting", package: "vapor")]),
    .testTarget(name: "AudioRuntimeTests", dependencies: ["AudioCore", "AudioRuntime", "AudioTestSupport"]),
]
let products: [Product] = [.executable(name: "omni-mlx", targets: ["OmniMLX"])]

#if os(macOS)
dependencies += [
    .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "8d86630ade569728aaea3dc1a29fc44e2efa719b"),
    .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.31.4"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.31.4"),
    .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.9"),
    .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.8.1"),
]
targets += [
    .target(name: "MLXAudioBackend", dependencies: [
        "AudioCore", "AudioRuntime",
        .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        .product(name: "MLXAudioTTS", package: "mlx-audio-swift"),
        .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
    ]),
]
serviceDependencies.append("MLXAudioBackend")
#endif

targets.append(.executableTarget(name: "OmniMLX", dependencies: serviceDependencies))

let package = Package(name: "OmniMLX", platforms: [.macOS(.v14)], products: products, dependencies: dependencies, targets: targets)
