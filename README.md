# Omni-MLX

A local audio server for speech generation and transcription on Apple Silicon. Run [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift) in one application executable, choose your models and voices in TOML, and connect through an OpenAI-style audio API or MCP. A built-in local panel manages API keys.

## Capabilities

- Generate WAV speech with Qwen3-TTS Base reference voices or CustomVoice speaker presets.
- Transcribe audio with Whisper, with optional language selection.
- Discover configured models, voices, and capabilities through the API.
- Give MCP clients access to catalogs, speech generation, and transcription.
- Create and revoke bearer keys from a React, Effect, and HeroUI panel.

The project is at an early stage. Validate checkpoint compatibility, memory use, and voice quality with your own assets.

## Example request

With the server running and a client key created in the local panel:

```sh
export OMNI_MLX_CLIENT_KEY="your-generated-key"

curl http://127.0.0.1:8080/v1/audio/speech \
  --header "Authorization: Bearer $OMNI_MLX_CLIENT_KEY" \
  --json '{"model":"tts","voice":"narrator","input":"Hello from Omni-MLX.","response_format":"wav"}' \
  --output speech.wav
```

`tts` and `narrator` are aliases from the example configuration. See the [API reference](docs/api.md) for transcription, discovery, and MCP tools.

## Get started

Build on an Apple Silicon Mac with macOS 14+, Swift 6.2+, full Xcode with its Metal compiler, and Node.js 22.12+ with npm:

```sh
./scripts/build-ui.sh
./scripts/package-release.sh
```

Follow the [getting started guide](docs/getting-started.md) to extract the package, provision model weights and voice assets, configure the service, and create your first key. Model weights are provisioned separately; requests do not download them.

The packaged application runs without Swift, Xcode, Node.js, or Python installed. Keep its resource bundles and runtime libraries alongside the executable.

## Let your agent set it up

Copy this into your agent chat from a checkout:

```text
Set up Omni-MLX from this repository on an Apple Silicon Mac.
1. Read README.md, docs/getting-started.md, docs/configuration.md,
   and the build and packaging scripts before running setup commands.
2. Check macOS, Swift, Xcode's Metal compiler, Node.js, and npm.
3. Build the administration UI and package the application.
4. Copy configs/service.example.toml to config.local.toml. Use my chosen
   compatible models and reference recordings; confirm missing assets.
5. Validate the configuration, start the server, and check readiness.
6. Show me the local administration panel so I can create a client key.
   Verify an authenticated catalog request and explain how to stop it.
Keep private configuration, model weights, recordings, and keys out of Git.
```

## Documentation

- [Getting started and distribution](docs/getting-started.md)
- [Configuration, models, and voices](docs/configuration.md)
- [HTTP API and MCP tools](docs/api.md)
- [Architecture and execution behavior](docs/architecture.md)
- [Contributing and development](CONTRIBUTING.md)

[MIT licensed](LICENSE). Dependencies, model checkpoints, and voice assets have their own licenses.
