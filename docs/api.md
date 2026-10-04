# HTTP and MCP interfaces

## HTTP routes

| Method | Path | Result |
| --- | --- | --- |
| GET | `/v1` | Service name and available version-one routes |
| GET | `/v1/models` | Configured model aliases and operations |
| GET | `/v1/voices` | Voice IDs, locales, and compatible models |
| GET | `/v1/capabilities` | Protocol version, formats, and supported options |
| POST | `/v1/audio/speech` | Complete mono PCM16 WAV |
| POST | `/v1/audio/transcriptions` | JSON transcript with `text` |
| GET | `/health/live` | Process liveness |
| GET | `/health/ready` | Runtime and configuration readiness |

When authentication is configured, send `Authorization: Bearer <key>`. Only `/v1` and `/health/live` are unauthenticated. Readiness does not imply that weights have been loaded or evaluated.

`GET /v1` returns the service name and an `endpoints` array of HTTP `method` and `path` objects, generated from registered routes. It includes no configured model IDs, voice assets, or client secrets.

### Speech

Send `application/json` with `model`, `input`, and `voice`. Optional `response_format` must be `wav`; WAV is also the default:

```json
{"model":"tts","input":"Hello from Omni-MLX.","voice":"narrator","response_format":"wav"}
```

The response has content type `audio/wav`. Public streaming, MP3 output, speed, instructions, and other unimplemented fields return errors.

### Transcription

Send `multipart/form-data` with an audio `file` and `model`. Optional fields are `language` and `response_format=json`.

Native decoding supports WAV, MP3, M4A, FLAC, AIFF/AIF, and CAF where AVFoundation can decode the input. The filename extension must match a supported format. Languages are lowercase two-letter codes available in the configured checkpoint. Prompts, timestamps, and other unimplemented fields return errors.

### OpenAI clients

This is a subset of the OpenAI audio interface. Set the client's base URL to the audio listener's `/v1` URL and request WAV output explicitly:

```python
import os
from openai import OpenAI

client = OpenAI(
    base_url="http://127.0.0.1:8080/v1",
    api_key=os.environ["OMNI_MLX_CLIENT_KEY"],
)
audio = client.audio.speech.create(
    model="tts", voice="narrator", input="Hello from Omni-MLX.", response_format="wav"
)
audio.write_to_file("speech.wav")
with open("recording.wav", "rb") as recording:
    transcript = client.audio.transcriptions.create(model="stt", file=recording, language="en")
print(transcript.text)
```

The Python package is a client dependency, not a server requirement. Chat and embedding routes are not implemented. Voice and capability discovery are Omni-MLX extensions.

### Errors and limits

Errors use a JSON `error` object with a message, type, and code. Invalid credentials return 401. A full queue returns 429 with `Retry-After`. Input and output limits are configured in TOML. A deadline error can arrive after the timeout because GPU work must drain before its resource permit is released.

## MCP

Enable an `[mcp]` configuration section. The endpoint is `/mcp` on the audio listener; it uses the same bearer keys, catalogs, and inference queue.

| Tool | Arguments | Result |
| --- | --- | --- |
| `list_models` | None | Model IDs and operations |
| `list_voices` | None | Voice IDs, locales, and compatible models |
| `generate_speech` | `model`, `voice`, `input` | Inline WAV audio content |
| `transcribe_audio` | `model`, `audio_base64`, `filename`, optional `language` | Text and structured transcript |

Transcription accepts plain base64 audio bytes and a filename such as `recording.wav`. It does not fetch URLs or read client-supplied server paths. Clients need MCP audio support and sufficient inference time and response size for base64 audio.

The service uses the official Swift MCP SDK. Its transport is stateless Streamable HTTP: POST returns JSON, notifications return 202, and GET/DELETE return 405. It provides no persistent SSE stream, server-initiated requests, session IDs, OAuth discovery, or stdio transport. Experimental client extensions are not negotiated.

For a proxy or browser client, configure exact origins:

```toml
[mcp]
allowed_origins = ["https://audio.example.test"]
```

Replace this illustrative origin with the actual client origin. HTTP origins are also supported. An empty section permits the audio listener's loopback origins. A proxy must forward `/mcp` to the audio listener alongside `/v1`.

## Administration API

These routes exist only on the administration listener:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/keys` | List key metadata |
| POST | `/api/keys` | Create a key with JSON `name` |
| DELETE | `/api/keys/:id` | Revoke a key |

Mutations require `X-Omni-MLX-Local: 1`. The panel has no login or password. Host and origin checks restrict it to trusted local access. It sets no cross-origin access policy. Secrets appear once at creation; listings reveal neither secrets nor hashes.
