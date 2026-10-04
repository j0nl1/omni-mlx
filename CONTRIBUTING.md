# Contributing

Omni-MLX is an early-stage Swift audio service. Keep audio contracts independent of transport and inference libraries, and preserve configuration-driven model and voice catalogs.

## Development setup

Native work requires an Apple Silicon Mac, macOS 14 or later, Swift 6.2 or later, and Xcode's Metal toolchain. The administration client also requires Node.js 22.12 or later and npm.

From the repository root:

```sh
./scripts/build-ui.sh
swift test -c release -j 4
./scripts/package-release.sh
```

Release-mode tests let testing and packaging share build artifacts. For debugger-driven iteration, use `swift test -j 4` and `swift build --product omni-mlx -j 4`.

For frontend development:

```sh
cd web
npm ci
npm run dev
```

Vite binds to loopback and proxies `/api` to administration at `http://127.0.0.1:8081`. Set `OMNI_MLX_ADMIN_ORIGIN` for a different local administration port. Run the service separately with your configuration. `npm run build` checks TypeScript and bundles the UI and dependency notices into SwiftPM resources.

## Changes and validation

Use the [architecture overview](docs/architecture.md) to place changes. Run tests relevant to changed behavior. HTTP and MCP changes should cover validation and authorization; inference changes should preserve resource ownership during cancellation and failure.

Document behavior and limitations using generic examples and configuration-driven values. Keep infrastructure inventories, private deployment scripts, configurations, weights, reference recordings, and keys outside the repository. Generated assets and build output are ignored.

Bug reports should include expected and actual behavior, reproduction steps, macOS and Swift versions, and the model profile. Supply minimal redacted configuration and logs when useful. Do not include credentials or private recordings.

Injected-engine tests do not prove checkpoint quality or memory requirements. For native generation changes, describe the checkpoint, quantization, request, and listening or transcription checks used.

## License

Contributions are distributed under [MIT](LICENSE). Preserve dependency notices; model and voice licenses remain separate from source licensing.
