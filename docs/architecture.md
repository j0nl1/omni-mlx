# Architecture

Omni-MLX separates audio contracts, scheduling, transport, and inference. HTTP and MCP adapters call the same application use cases. Native MLX and attached HTTP backends implement the same audio ports.

| Module | Responsibility |
| --- | --- |
| AudioCore | Configuration, catalogs, audio contracts, use cases, and scheduling |
| AudioRuntime | Embedded lifecycle, attached HTTP backend, and API key persistence |
| AudioHTTP | Audio API and separate local administration listener |
| AudioMCP | MCP tools and Streamable HTTP adaptation |
| MLXAudioBackend | Checkpoint state, reference conditioning, decoding, and WAV output |
| OmniMLX | Composition root and executable entry point |
| web | React, Effect, and HeroUI client compiled into static resources |

The public interfaces do not import MLX. Native inference is included on macOS. Non-macOS builds omit MLX and can use attached operation; deployment on those platforms remains unverified.

## Execution behavior

A resource group serializes requests through a bounded FIFO queue. Speech and transcription on the same native device share a group, with one in-flight request. Deadlines include queue wait.

Each native adapter retains one active model family. Switching between Qwen and Whisper releases the previous family and cached references. Repeated requests to the active model reuse weights, trading model-switch latency for bounded retained state.

Speech chunks are written into a private temporary WAV and returned as one complete file. Generation that reaches its token limit without the audio stop token discards the incomplete result.

Native timeouts and cancellation are cooperative. Bounded GPU work can continue after a deadline or cancellation. The adapter drains it, discards a late result, and retains its resource permit until completion. Shutdown also waits for active work. The timeout is not a hard process deadline.

Input errors leave the engine usable. Unexpected native errors mark it unavailable until restart. A fatal native or Metal crash affects the whole server process; an external supervisor can restart it. Process-level isolation and forced inference termination are not provided.

Temporary files are removed on normal unwind. Fatal process exits can leave private files in the system temporary directory.

## Distribution

HTTP and native inference run in one process, with no Python worker or separate inference executable. Models, voice references, and configuration remain separate assets.

The release has one executable plus SwiftPM resources and required Swift compatibility libraries. Resources include the static administration UI and MLX's Metal library. Keep them beside the executable after extraction.

Dependency versions are pinned in the package manifests. Tests use injected engines and deterministic audio fixtures. Real checkpoint validation requires separately provisioned assets and listening evaluation.
