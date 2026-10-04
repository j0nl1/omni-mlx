# Getting started

Build, configure, and run Omni-MLX on an Apple Silicon Mac. Commands below assume the repository root unless stated otherwise.

## Requirements

Native inference requires an Apple Silicon Mac running macOS 14 or later. Memory requirements depend on the checkpoint, quantization, and input length.

To build from source, install Swift 6.2 or later, full Xcode with its Metal compiler, and Node.js 22.12 or later with npm. Check Metal with `xcrun metal --version`; if it is missing, install the Xcode component with `xcodebuild -downloadComponent MetalToolchain`.

A packaged application needs no Swift, Xcode, Node.js, or Python installation to run. It needs its accompanying resource bundles, runtime libraries, and separately provisioned model and voice assets.

## Quick start

Run these commands from a checkout on an Apple Silicon Mac:

```sh
./scripts/build-ui.sh
./scripts/package-release.sh
mkdir -p runtime
tar -xzf dist/omni-mlx-macos-arm64.tar.gz -C runtime
cp configs/service.example.toml config.local.toml
```

The example expects these assets beside `config.local.toml`:

```text
.models/
  qwen3-base/                     # Compatible Qwen Base checkpoint and tokenizers
  whisper/                       # Compatible Whisper checkpoint and tokenizer
assets/
  voices/narrator/
    reference.wav                # Reference recording, at most 30 seconds
    reference.txt                # Matching UTF-8 transcript
```

Provision checkpoints compatible with MLX Audio Swift and supply your reference recording and transcript. Edit the paths and model profiles in `config.local.toml` to match your files. The service does not download weights during requests. See [configuration and model provisioning](configuration.md) for required checkpoint files and voice bindings.

Validate the configuration and start the packaged executable:

```sh
./runtime/omni-mlx-macos-arm64/omni-mlx check-config --config config.local.toml
./runtime/omni-mlx-macos-arm64/omni-mlx serve --config config.local.toml
```

`check-config` validates the catalog and configured paths. Startup also checks native checkpoint structure; weights are loaded on the first inference request.

| Interface | Default address | Access |
| --- | --- | --- |
| Audio API | `http://127.0.0.1:8080/v1` | Bearer key for audio operations and catalogs |
| Administration panel | `http://127.0.0.1:8081` | Trusted local access; no login |
| MCP, when enabled | `http://127.0.0.1:8080/mcp` | Same bearer keys as the audio API |

Open the panel, create a client key, and copy its secret. The secret is shown once; the server stores its hash. Revocation applies to subsequent requests without a restart.

## Make an audio request

Set the key you created in the panel:

```sh
export OMNI_MLX_CLIENT_KEY="your-generated-key"
```

Generate speech using the example model and voice aliases:

```sh
curl http://127.0.0.1:8080/v1/audio/speech \
  --header "Authorization: Bearer $OMNI_MLX_CLIENT_KEY" \
  --json '{"model":"tts","voice":"narrator","input":"Hello from Omni-MLX.","response_format":"wav"}' \
  --output speech.wav
```

Transcribe an audio file:

```sh
curl http://127.0.0.1:8080/v1/audio/transcriptions \
  --header "Authorization: Bearer $OMNI_MLX_CLIENT_KEY" \
  --form model=stt \
  --form file=@recording.wav \
  --form language=en
```

An OpenAI-compatible client can use `http://127.0.0.1:8080/v1` as its base URL. Request WAV output explicitly for speech. `GET /v1` lists available routes without authentication; catalogs and audio operations require a key when authentication is configured. See the [HTTP API reference](api.md).

## Connect an MCP client

Add this section to your configuration and restart:

```toml
[mcp]
```

Connect a Streamable HTTP client to `http://127.0.0.1:8080/mcp` with `Authorization: Bearer <key>`. It exposes `list_models`, `list_voices`, `generate_speech`, and `transcribe_audio`. Speech returns inline WAV audio; transcription accepts base64 audio bytes and a filename.

See the [MCP reference](api.md#mcp) for arguments, origin configuration, and transport limits.

## Distribution and development

`scripts/package-release.sh` produces `dist/omni-mlx-macos-arm64.tar.gz`. Keep the executable, resource bundles, and `lib` directory together when moving it. The archive includes the UI, Metal resources, examples, and dependency notices. Model weights, reference recordings, private configuration, and client keys are separate assets.

The application uses ad-hoc signing and is not notarized. It does not install a background service automatically.

From an extracted package, copy `configs/service.example.toml` to `config.local.toml`, provision its assets, and run:

```sh
./omni-mlx serve --config config.local.toml
```

See [CONTRIBUTING.md](../CONTRIBUTING.md) for development commands and the [architecture overview](architecture.md) for inference adapters, scheduling, and failure behavior. An [attached configuration](../configs/attached.example.toml) can forward operations to another Omni-MLX instance with a matching catalog.
