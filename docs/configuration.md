# Configuration

Copy [service.example.toml](../configs/service.example.toml) to `config.local.toml` for native inference, or use [attached.example.toml](../configs/attached.example.toml) to connect another Omni-MLX instance. Edit the example for your assets. Configuration changes require a restart.

Relative paths resolve against the configuration file's directory, independently of the working directory. Model directories and the asset root can use absolute paths. Voice files must remain inside `assets.root`, including after symlink resolution.

## Listeners and authorization

```toml
[server]
host = "127.0.0.1"
port = 8080

[admin]
port = 8081
keys_file = "state/api-keys.json"
```

The administration listener always binds to IPv4 loopback. It has no login; local users and processes that can access it are trusted administrators. It rejects foreign browser hosts and origins. Keep it private.

The key file stores SHA-256 digests of randomly generated 256-bit secrets, with owner-only permissions and atomic writes. One server process owns each key file. An accepted request can finish after its key is revoked.

An `[admin]` section enables bearer authorization, including before any client keys exist. Alternatively, `server.api_key_env` can name an environment variable containing a fixed key. A fixed key is additional to managed keys and cannot be revoked through the panel. Omitting both `[admin]` and `api_key_env` disables audio authorization.

Only the API index and process liveness are unauthenticated. Catalogs, audio operations, readiness, and MCP use the configured authorization policy. Optional `admin.audio_api_url` changes the URL displayed in the panel; it does not change binding or authorization.

## Model provisioning

Names such as `tts` and `stt` are operator-chosen aliases. Clients submit those aliases; filesystem paths remain on the server.

| Operation | Native profile | Checkpoint |
| --- | --- | --- |
| `speech` | `qwen3_base` | Qwen3-TTS Base with reference conditioning |
| `speech` | `qwen3_custom_voice` | Qwen3-TTS CustomVoice with preset speakers |
| `transcription` | `whisper` | Whisper compatible with MLX Audio Swift |

Each directory needs `config.json` and safetensors weights supported by the pinned MLX Audio Swift dependency. Model download and conversion are separate provisioning steps; the service does not download weights during requests.

Qwen additionally requires a matching `tts_model_type` (`base` or `custom_voice`), a readable `speech_tokenizer` directory with its configuration and assets, and `tokenizer.json` or the matching `vocab.json` and `merges.txt` files.

Provision a regular speech-tokenizer directory rather than relying on a directory symlink. Individual weight-file symlinks can share storage. If the upstream loader needs to generate `tokenizer.json`, provision it in advance or allow writes in an isolated model directory.

Whisper requires a local `tokenizer.json`. Explicit language selection also uses `generation_config.json` with checkpoint language IDs.

A successful configuration check does not prove weight compatibility, voice quality, or memory fit. Validate each checkpoint with real requests.

## Voices

Each voice has an ID, a display name, and explicit model bindings. Clients request the ID, not a reference file path:

```toml
[voices.narrator]
display_name = "Narrator"
description = "Reference voice for narration"

[voices.narrator.bindings.tts]
kind = "reference"
locale = "en-US"
audio = "voices/narrator/reference.wav"
transcript = "voices/narrator/reference.txt"
```

Audio and transcript paths are relative to `assets.root`. Reference audio is limited to 30 seconds. The transcript must be non-empty UTF-8 text matching the recording. Reference bindings require a Qwen Base profile.

For CustomVoice, use `kind = "preset"` and set `preset` to a checkpoint speaker. Preset bindings require `qwen3_custom_voice`.

Add a `[voices.<id>]` section for each voice. A voice can have bindings to several compatible speech models. Unknown or incompatible IDs are rejected.

`locale` describes the voice and its language prefix selects the Qwen generation language. Optional `language` overrides that choice. Supported aliases are `en`, `es`, `fr`, `de`, `it`, `pt`, `zh`, `ja`, `ko`, and `ru`. Locale metadata does not guarantee accent or identity; evaluate generated speech by listening.

## Resource limits

Native backends on one device share a resource group:

```toml
[resource_groups.local_gpu]
max_in_flight = 1
queue_capacity = 16
request_timeout_seconds = 300
```

The implementation requires one in-flight request per group. A full queue returns HTTP 429. Deadlines include queue wait. Native cancellation is cooperative; see [execution behavior](architecture.md#execution-behavior).

Server settings limit text characters, uploaded bytes, decoded audio duration, and output bytes. Model generation settings include token limits, sampling parameters, and maximum speech duration. The example lists these settings. Unsupported HTTP options are rejected rather than mapped silently.

## Attached backends

An attached backend forwards work to another Omni-MLX instance:

```toml
[backends.remote]
mode = "attached"
base_url = "http://127.0.0.1:9080"
api_key_env = "OMNI_MLX_UPSTREAM_API_KEY"
resource_group = "remote_gpu"
```

Configure the upstream audio listener at that address or replace it with your service origin. `base_url` excludes `/v1` and must not point to administration. The upstream must expose capabilities, catalogs, audio operations, and readiness, using protocol version 1 and matching model aliases and voice bindings.

Reference assets stay on the upstream service. The gateway does not transfer paths or manage the upstream process. A failed submission can leave execution uncertain; the resource group is quarantined until the operator checks the upstream and restarts the gateway. Configuration loops are unsupported.

## MCP origins

An empty `[mcp]` section permits the audio listener's loopback origins. `mcp.allowed_origins` adds exact accepted HTTP(S) origins and hostnames for proxies or browser clients. Paths, credentials, and wildcards are rejected. See [MCP](api.md#mcp).
