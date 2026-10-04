import { Effect, Schema } from "effect";

export const APIKey = Schema.Struct({
  id: Schema.String,
  name: Schema.String,
  prefix: Schema.String,
  created_at: Schema.Number,
  revoked_at: Schema.optionalKey(Schema.Number),
});
export type APIKey = typeof APIKey.Type;
const KeyList = Schema.Struct({
  data: Schema.Array(APIKey),
  audio_api_url: Schema.String,
  fixed_key_enabled: Schema.Boolean,
});
export type KeyList = typeof KeyList.Type;
const CreatedKey = Schema.Struct({ key: APIKey, secret: Schema.String });
export type CreatedKey = typeof CreatedKey.Type;

export class APIError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "APIError";
  }
}

const request = (path: string, method = "GET", body?: object) =>
  Effect.tryPromise({
    try: async (signal) => {
      const response = await fetch(`/api/${path}`, {
        method,
        signal: AbortSignal.any([signal, AbortSignal.timeout(10_000)]),
        credentials: "omit",
        cache: "no-store",
        headers: {
          "X-Omni-MLX-Local": "1",
          ...(body ? { "Content-Type": "application/json" } : {}),
        },
        body: body ? JSON.stringify(body) : undefined,
      });
      if (!response.ok) {
        const error: unknown = await response.json().catch(() => null);
        const message =
          typeof error === "object" &&
          error !== null &&
          "error" in error &&
          typeof error.error === "object" &&
          error.error !== null &&
          "message" in error.error &&
          typeof error.error.message === "string"
            ? error.error.message
            : "The request failed. Try again.";
        throw new APIError(message);
      }
      return response.status === 204
        ? null
        : ((await response.json()) as unknown);
    },
    catch: (error) =>
      error instanceof APIError
        ? error
        : new APIError(
            "Cannot reach the local server. Check that omni-mlx is running, then retry.",
          ),
  });

const decode =
  <S extends Schema.Constraint>(schema: S) =>
  (input: unknown) =>
    Schema.decodeUnknownEffect(schema)(input).pipe(
      Effect.mapError(
        () =>
          new APIError(
            "The server returned an unexpected response. Refresh the panel.",
          ),
      ),
    );

export const api = {
  list: () => request("keys").pipe(Effect.flatMap(decode(KeyList))),
  create: (name: string) =>
    request("keys", "POST", { name }).pipe(Effect.flatMap(decode(CreatedKey))),
  revoke: (id: string) =>
    request(`keys/${encodeURIComponent(id)}`, "DELETE").pipe(Effect.asVoid),
};
