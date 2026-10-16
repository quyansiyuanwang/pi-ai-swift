# PORTING — upstream `@earendil-works/pi-ai` → Swift `PiAI`

This document records how the Swift port maps to the upstream TypeScript source
(`packages/ai/src/**`, version 1.2.0) and every intentional deviation.

## Status

| Milestone | Scope | Status |
| --- | --- | --- |
| M1 | Core type layer + `JSONValue` / `JSONSchema` | ✅ done |
| M2 | OpenAI Completions (non-streaming) + error body + retry | ✅ done |
| M3 | OpenAI Completions (SSE streaming) + tool fragment accumulation + reasoning + cancellation | ✅ done |
| M4 | Full test coverage + CI + docs + LICENSE/ATTRIBUTION | ✅ done |
| M5 | `calculateCost` / `clampThinkingLevel` + offline example | ✅ done |
| M6 | OpenAI Responses API (`openai-responses`) streaming + non-streaming | ✅ done |
| M7 | Anthropic Messages API (`anthropic-messages`) streaming + non-streaming | ✅ done |

## M1 type mapping

| Upstream (`types.ts`) | Swift | Notes |
| --- | --- | --- |
| `Model<Api>` | `Model` | Simplified public shape per `TASK.md`. |
| `SystemMessage` | `SystemMessage` | Prompt sections / incremental tools omitted (M1 subset). |
| `UserMessage` | `UserMessage` | `content: string \| (TextContent \| ImageContent)[]` → `MessageContent`. |
| `AssistantMessage` | `AssistantMessage` | Includes `responseModel`, `responseId`, `usage`, `stopReason`, `errorMessage`. |
| `ToolResultMessage` | `ToolResultMessage` | Includes `details`, `usage`, `isError`. Nested tool-call records omitted. |
| `Message` | `Message` | Tagged enum: `system` / `user` / `assistant` / `toolResult`. |
| `TextContent` | `TextContent` | |
| `ThinkingContent` | `ThinkingContent` | |
| `ImageContent` | `ImageContent` | |
| `ToolCall` | `ToolCall` | `arguments: JsonObject` → `JSONValue` with `argumentsObject` accessor. |
| `Usage` | `Usage` | Nested `Usage.Cost` mirrors `usage.cost`. |
| `StopReason` | `StopReason` | Same raw values (`toolUse`, …). |
| `Tool` | `Tool` | `parameters` is `JSONSchema` instead of TypeBox `TSchema`. |
| `ConstrainedSamplingConfig \| false` | `ConstrainedSampling` | `false` is modelled as `.disabled`. |
| `Context` | `ChatContext` | `systemPrompt` / `messages` / `tools`. |
| `AssistantMessageEvent` | `AssistantMessageEvent` | Simplified event protocol (see below). |
| `StreamOptions` (subset) | `ChatOptions` | `apiKey`, `temperature`, `maxTokens`, `toolChoice`, `headers`, `signal`. |
| `AbortSignal` | `CancellationSignal` | Lock-protected, thread-safe, `Sendable`. |
| `JsonValue` / `JsonObject` | `JSONValue` / `JSONObject` | Self-contained, no dependency. |
| TypeBox `TSchema` | `JSONSchema` | Self-implemented JSON Schema subset. |

## Intentional deviations from upstream

1. **`Model.baseURL` vs `Model.baseUrl`.** The Swift property is `baseURL`
   (`TASK.md` public API) but it encodes under the upstream `baseUrl` JSON key
   so upstream model catalogs stay compatible. It also omits catalog-only
   fields (`cost`, `input`, `thinkingLevelMap`, `compat`, …) in M1.
2. **Simplified `AssistantMessageEvent`.** Upstream emits `start` plus
   per-block `*_start` / `*_delta` / `*_end` events carrying a shared `partial`
   message, then `done`/`error` with a `reason`. The Swift port implements the
   `TASK.md` contract: `.start`, `.textDelta`, `.thinkingDelta`,
   `.toolCallDelta(index:id:name:argumentsFragment:)`, `.done(AssistantMessage)`,
   `.error(any Error)`. Per-block start/end and `reason` are folded into the
   final message's `stopReason`.
3. **`ToolCall.arguments` is `JSONValue`.** Upstream types it as `JsonObject`.
   Keeping the general value preserves malformed/empty argument payloads during
   streaming; `argumentsObject` exposes the object form.
4. **`JSONSchema` is lossless but not TypeBox.** Unknown keywords are preserved
   verbatim in `JSONSchema.extra`, and single nested schemas (`items`, `not`) are
   stored behind a reference box to break Swift's recursive value-type
   restriction.
5. **System message content** is `MessageContent` (string or blocks); named
   prompt sections and incremental `toolsAdded` / `toolsRemoved` are deferred.
6. **`ToolResultMessage`** omits `nestedCalls` and `durationMs` in M1 (codemode
   bookkeeping is out of scope for the OpenAI-compatible subset).
7. **Cost calculation** (`calculateCost`) and `clampThinkingLevel` are scheduled
   for a later milestone; `Model` currently carries no pricing catalog.

## M2 mapping

M2 ports the non-streaming subset of the OpenAI-compatible Chat Completions
provider plus its shared error/retry utilities.

| Upstream | Swift | Notes |
| --- | --- | --- |
| `utils/error-body.ts` | `Utils/ErrorBody.swift` | `normalize` / `format` / `truncate` / `extractMessage`; only the `ProviderHTTPError` shape is probed. |
| `utils/provider-retry.ts` | `Utils/ProviderRetry.swift` | Same policy (retryable statuses, `x-should-retry`, `Retry-After`, exponential backoff + jitter, abortable sleep). |
| `utils/pi-user-agent.ts` | `Utils/PiUserAgent.swift` | Reports host OS name/version/arch instead of Node's `os.platform()/release()/arch()`. |
| `utils/sanitize-unicode.ts` | `Utils/SanitizeUnicode.swift` | Removes unpaired UTF-16 surrogates. |
| SDK HTTP error object | `HTTP/ProviderHTTPError.swift` | Carries `status`, lowercase `headers`, truncated `body`, extracted `message`. |
| `fetch` / SDK transport | `HTTP/HTTPClient.swift` | `HTTPClient` protocol + `URLSessionHTTPClient`; non-2xx throws, `URLError` becomes a network error. |
| `api/openai-completions.ts` `createClient` + `buildParams` | `Providers/OpenAIRequestBuilder.swift` | Builds the `POST .../chat/completions` request and JSON body. |
| `api/openai-completions.ts` `convertMessages` | `Providers/OpenAIRequestBuilder.swift` | system/user(text+image)/assistant/tool-result conversion. |
| `api/openai-completions.ts` `convertTools` | `Providers/OpenAIRequestBuilder.swift` | `{"type":"function","function":{name,description,parameters}}`. |
| `api/openai-completions.ts` streaming parser + `parseChunkUsage` + `mapStopReason` | `Providers/OpenAIResponseParser.swift` | Consumes one full `ChatCompletion` object instead of chunks. |
| `stream()` | `Providers/ChatCompleting.swift` + `Providers/OpenAICompletionsProvider.swift` | `complete(...)` builds, retries, and parses. |

### M2 deviations

1. **Non-streaming derivation.** Upstream `openai-completions` is streaming-only
   (`stream: true`). M2 sends `stream: false` and parses the full response body.
   Block ordering follows the streaming parser: reasoning (`thinking`) precedes
   answer text; tool calls follow.
2. **`max_tokens`, not `max_completion_tokens`.** Per `TASK.md`, the request
   body always uses `max_tokens` and omits `store`, `prompt_cache_key`,
   `stream_options`, compat/vendor fields, session-affinity headers, and
   github-copilot handling.
3. **Throw-on-error `complete`.** Upstream returns an exhausted
   `AssistantMessage` with `stopReason == .error`. `ChatCompleting.complete`
   throws instead: non-2xx responses throw `ProviderHTTPError` and transport
   failures throw a network `ProviderHTTPError`. (A `finish_reason` that maps
   to `.error` still produces a message with `stopReason == .error` and
   `errorMessage`, matching upstream.)
4. **Tool-call JSON arguments are best effort.** Empty or malformed
   `function.arguments` strings become `{}` rather than throwing;
   `OpenAIResponseError/invalidToolArguments(_:)` is exposed for API
   completeness but intentionally not thrown by the parser.
5. **Retry test seams.** `ProviderRetryOptions` adds `baseBackoffMs`,
   `maxBackoffMs`, `jitterFraction`, `random`, and `sleep` so tests can assert
   backoff deterministically. Defaults mirror the pinned SDK policy.
6. **`tool_choice` is emitted from `ChatOptions.toolChoice`.** Upstream keeps
   `toolChoice` on the options (`SimpleStreamOptions`) and forwards it to
   `params.tool_choice`. Swift mirrors that with the ``ToolChoice`` enum
   (`auto` / `none` / `required` / forced function); `nil` omits the field.
7. **Error body normalization** only understands the Swift `ProviderHTTPError`
   shape; the upstream SDK-specific probes (Mistral `statusCode`, `openai`
   `error`, `@google/genai`, Bedrock `$metadata`/`$response`) are unnecessary.
8. **Tool-result images** are not forwarded as a follow-up user message; an
   image-only tool result serializes as `"(no tool output)"`.

## Testing note

The build host only has Apple Command Line Tools installed (no full Xcode), so
`XCTest` is not available. Tests therefore use the toolchain-bundled
**Swift Testing** framework (`import Testing`, `@Suite` / `@Test` / `#expect`).
`swift test` discovers and runs them normally. This is an infrastructure choice,
not an API deviation.

## M3 mapping

M3 ports the streaming (server-sent events) subset of the OpenAI-compatible
Chat Completions provider.

| Upstream | Swift | Notes |
| --- | --- | --- |
| `api/openai-completions.ts` `stream()` | `Providers/OpenAICompletionsProvider.swift` + `Providers/OpenAIStreamParser.swift` | `ChatProvider.stream(model:context:options:)` returns `AsyncThrowingStream<AssistantMessageEvent, Error>`. |
| OpenAI SDK SSE reader | `Utils/SSEFrameDecoder.swift` | Byte-oriented framing: split on `\n`, tolerate `\r`, ignore non-`data:` lines, exact UTF-8 across chunk boundaries. |
| `utils/json-parse.ts` `repairJson` / `parseJsonWithRepair` | `Utils/JSONParse.swift` | Tool arguments are parsed once, after all fragments have been concatenated. |
| `utils/event-stream.ts` (`AssistantMessageEventStream`) | `AsyncThrowingStream` | No custom event queue; the public event protocol is simplified. |
| `utils/abort*.ts` (`AbortSignal`) | `CancellationSignal` + `Task.cancel()` | `abort()` / `cancel()` and task cancellation both interrupt the stream. |
| `chat.completions.create(params, { signal })` | `HTTP/HTTPStreamingClient.swift` | `StreamingHTTPClient` / `URLSession.bytes(for:)`; `URLSessionHTTPClient` conforms. |
| `retryProviderRequest(() => create(...))` | `ProviderRetry.retry` | Wraps stream *establishment* only, matching upstream. |
| `parseChunkUsage` / `mapStopReason` | `Providers/OpenAIResponseParser.swift` (reused) | Shared with the M2 non-streaming path. |

### M3 deviations

1. **Simplified event protocol.** Upstream emits `start` plus per-block
   `*_start` / `*_delta` / `*_end` events carrying a shared `partial` message,
   then `done`/`error` with a `reason`. The Swift port emits `.start`, flat
   `.textDelta` / `.thinkingDelta` / `.toolCallDelta`, then `.done(message)`.
   The per-block start/end ordering is preserved inside the final message's
   `content` array.
2. **`[DONE]` tolerates a missing `finish_reason`.** Upstream throws
   `Stream ended without finish_reason` whenever `supportsFinishReason` is set
   (the default) and no chunk carried one. Because the task contract defines
   `[DONE]` as a terminator, the Swift port infers `stop` / `toolUse` from the
   accumulated content when `[DONE]` is seen without a `finish_reason`, and only
   throws ``OpenAIStreamError/missingFinishReason`` for a clean EOF with neither.
3. **No partial JSON decoding.** The `partial-json` dependency is omitted. Raw
   argument fragments are forwarded verbatim in `.toolCallDelta`; the final
   arguments are parsed once via ``JSONParse/parse(_:)`` (with the upstream
   repair pass) and fall back to `{}` when malformed.
4. **Cancellation is distinct from failure.** `CancellationSignal.cancel()` /
   `abort()` and consuming-`Task` cancellation finish the stream by throwing
   `CancellationError` (never a retryable `.error` event). Other
   provider/transport failures are delivered as a final `.error` event.
5. **Streaming always requests usage.** `buildParams` sets
   `stream_options.include_usage = true`; there is no compat switch to disable
   it. `max_tokens`, `stream: true`, and the M2 simplifications otherwise apply.
6. **Retry scope.** Retries cover the HTTP response head only; a failure after
   the stream has started is surfaced as `.error` without re-issuing the
   request, matching upstream's `retryProviderRequest` placement.
7. **Test transport buffers.** `URLSession.bytes(for:)` on top of a custom
   `URLProtocol` may buffer the mock body until the protocol completes, so
   provider-level tests assert end-to-end wiring while byte-boundary UTF-8 and
   framing are covered deterministically by `SSEFrameDecoderTests`.

## M4 mapping (tests, CI, docs)

M4 completes the engineering surface around the ported code.

| Deliverable | File | Notes |
| --- | --- | --- |
| README | `README.md` | Install, quick start, streaming, tools, public API, upstream relationship. |
| CI | `.github/workflows/ci.yml` | macOS runner runs `swift build -Xswiftc -warnings-as-errors` and `swift test -Xswiftc -warnings-as-errors`. |
| License | `LICENSE` | MIT, upstream copyright retained. |
| Attribution | `ATTRIBUTION.md` | Notes the port from `earendil-works/pi@1.2.0` (MIT). |
| Porting doc | `docs/PORTING.md` | This file: file-by-file mapping + consolidated deviations. |

### M4 deviations

1. **CI uses a macOS runner only.** Upstream is runtime-agnostic; PiAI targets
   macOS 13+/iOS 16+, so the workflow runs on `macos-15`. `swift build` builds
   the library and the `PiAIExamples` executable; `swift test` runs the tests.
2. **Tests use Swift Testing, not XCTest.** See the Testing note above: the
   build host has only Apple Command Line Tools. `swift test` discovers the
   suites normally.

## M5 mapping (pricing, thinking levels, example)

M5 ports the two pure helpers of upstream `models.ts` and adds an offline,
end-to-end example.

| Upstream | Swift | Notes |
| --- | --- | --- |
| `models.ts` `calculateCost` | `Models.swift` (`Model.calculateCost(usage:)`, `Model.applyingCost(to:)`) | Returns a `Usage.Cost` instead of mutating (Swift value semantics). |
| `models.ts` `getSupportedThinkingLevels` | `Models.swift` (`Model.supportedThinkingLevels`) | Same opt-in rule for `xhigh` / `max`. |
| `models.ts` `clampThinkingLevel` | `Models.swift` (`Model.clampThinkingLevel(_:)`) | Same nearest-higher-then-lower clamp. |
| `providers/model-schema.ts` `ModelCost*` / `ThinkingLevelMap` / `ModelInputModality` | `Types/Model.swift` | Codable, backward-compatible defaults. |
| `api/openai-completions.ts` tool-call loop | `Examples/PiAIExamples` + `Tests/PiAITests/EndToEndExampleTests.swift` | Deterministic `URLProtocol` mock; no API key. |

### M5 deviations

1. **`calculateCost` returns instead of mutating.** Upstream writes into
   `usage.cost` and returns it. Swift's value semantics make that surprising, so
   the port returns a fresh ``Usage/Cost``; ``Model/applyingCost(to:)`` provides
   the in-place-style convenience.
2. **`input`, `cost`, `thinkingLevelMap` are optional on the wire.** Decoding a
   model catalog that predates these fields succeeds with defaults
   (`input == [.text]`, `cost == .zero`, `thinkingLevelMap == nil`). Encoding
   always emits `input` and `cost`.
3. **`ThinkingLevelMap` is tri-state.** ``ThinkingLevelMap/Value`` distinguishes
   a missing key (provider default), `null` (``ThinkingLevelMap/Value/unsupported``)
   and a mapped string, matching `Partial<Record<ModelThinkingLevel, string | null>>`.
4. **`Model.input` is modelled but not yet consumed.** Upstream
   `api/transform-messages.ts` downgrades images to a placeholder when
   `model.input` excludes `image`; the Swift request builder currently forwards
   images unconditionally. This is a known gap (see deviations summary).
5. **The `v0.1.0` tag is intentionally not created by the porting agent.**
   Tagging is left to the repository owner; `PiAI.version` already reports
   `0.1.0`.

## M6 mapping (OpenAI Responses)

M6 adds the `openai-responses` provider (`POST {baseURL}/responses`) with both
SSE streaming and a Swift-specific non-streaming `complete`.

| Upstream | Swift | Notes |
| --- | --- | --- |
| `api/openai-responses.ts` `buildParams` | `Providers/OpenAIResponsesRequestBuilder.swift` | `model`, `input`, `stream`, `store: false`, `tools`, `max_output_tokens` (min 16), `temperature`, `top_p`, optional `tool_choice` and `reasoning.effort`. |
| `api/openai-responses-shared.ts` `convertResponsesMessages` | `Providers/OpenAIResponsesRequestBuilder.swift` | System/developer instructions, user `input_text`/`input_image`, assistant `output_text` and `function_call`, tool `function_call_output`. |
| `api/openai-responses-shared.ts` `convertResponsesTools` | `Providers/OpenAIResponsesRequestBuilder.swift` | `{type: "function", name, description, parameters, strict: false}`. |
| `api/openai-responses-shared.ts` `processResponsesStream` | `Providers/OpenAIResponsesStreamParser.swift` | `response.output_item.added/done`, text/reasoning/function-call deltas, `response.completed`/`incomplete`, `response.failed`/`error`. |
| `api/openai-responses.ts` streaming `stream()` | `Providers/OpenAIResponsesProvider.swift` | `ChatProvider` + `ChatCompleting`, `ProviderRetry`, `CancellationSignal`. |

### M6 deviations

1. **Non-streaming derivation.** Upstream is streaming-only; M6 adds a
   `stream: false` path that parses the full `response` object (tolerating an
   SDK-style `{"response": ...}` envelope).
2. **Simplified request fields.** `store: false` is always sent; compat flags,
   `prompt_cache_*`, `include: ["reasoning.encrypted_content"]`, service tiers,
   session affinity and vendor-specific handling are omitted.
3. **Reasoning effort is a provider property.** Because `ChatOptions` is kept
   stable, `OpenAIResponsesProvider.reasoningEffort` is forwarded as
   `reasoning: { effort }` when set; `model.thinkingLevelMap` remapping and
   `configuration_update` items are not ported.
4. **Tool-call ids keep only the `call_id`.** Upstream persists
   `call_id|item_id`; the port uses the `call_id` for streaming, non-streaming
   and replay (assistant `function_call` items omit the Responses `id`).
5. **Reasoning replay is best effort.** A thinking block is only replayed when
   its `thinkingSignature` parses as a JSON object; the `input_image` details
   and grammar/custom tool items are not ported.

## M7 mapping (Anthropic Messages)

M7 adds the `anthropic-messages` provider (`POST {baseURL}/v1/messages`) with
both SSE streaming and a Swift-specific non-streaming `complete`.

| Upstream | Swift | Notes |
| --- | --- | --- |
| `api/anthropic-messages.ts` `buildParams` | `Providers/AnthropicMessagesRequestBuilder.swift` | `model`, `max_tokens`, `messages`, `stream`, top-level `system`, `temperature`, `top_p`, optional `tools` and `thinking: { type: "enabled", budget_tokens }`. |
| `api/anthropic-messages.ts` `convertContentBlocks` / `convertMessages` | `Providers/AnthropicMessagesRequestBuilder.swift` | system folding, user text/image blocks, assistant text/thinking/tool_use replay, grouped `tool_result` turns. |
| `api/anthropic-messages.ts` `convertTools` | `Providers/AnthropicMessagesRequestBuilder.swift` | `{ name, description, input_schema }`. |
| `api/anthropic-messages.ts` `normalizeToolCallId` | `Providers/AnthropicMessagesRequestBuilder.swift` | `[a-zA-Z0-9_-]` sanitization, truncated to 64 characters. |
| `api/anthropic-messages.ts` `iterateAnthropicEvents` / stream loop | `Providers/AnthropicMessagesStreamParser.swift` | `message_start`, `content_block_start/delta/stop`, `message_delta`, `message_stop`, `error`. |
| `api/anthropic-messages.ts` `mapStopReason` | `Providers/AnthropicMessagesStreamParser.swift` (`AnthropicMessagesMapping`) | `end_turn`/`stop_sequence` → stop, `max_tokens` → length, `tool_use` → toolUse. |
| `api/anthropic-messages.ts` streaming `stream()` | `Providers/AnthropicMessagesProvider.swift` | `ChatProvider` + `ChatCompleting`, `ProviderRetry`, `CancellationSignal`. |

### M7 deviations

1. **Non-streaming derivation.** Upstream is streaming-only; M7 adds a
   `stream: false` path that parses the full `message` object (tolerating a
   `{"message": ...}` envelope).
2. **`max_tokens` fallback is a fixed default.** Upstream uses
   `options.maxTokens ?? model.maxTokens`; this subset sends
   `options.maxTokens ?? 4096` (``AnthropicMessagesRequestBuilder/defaultMaxTokens``)
   so a value is always present even when the model catalog omits `maxTokens`.
3. **No compat/caching/beta surface.** Provider compat flags, prompt-cache
   control blocks, beta headers, Claude Code OAuth identity, Bedrock/Vertex
   variants, strict tools, session affinity, mid-conversation system messages
   and count-tokens are not ported.
4. **Thinking replay requires a signature.** A `thinking` block with a
   non-empty `thinkingSignature` is replayed verbatim; a signature-less block is
   downgraded to plain text, and `redacted` blocks round-trip as
   `redacted_thinking`. Adaptive thinking / effort levels are not ported.
5. **Unknown stop reasons map to `.error`.** Upstream throws for an unhandled
   stop reason; the Swift mapping returns `.error` with a diagnostic message,
   matching the other providers.
6. **Tool-use `input` is best effort.** `input_json_delta` fragments are
   accumulated and parsed once on `content_block_stop`; malformed or missing
   arguments fall back to the `input` sent in `content_block_start` (usually
   `{}`).

## Upstream file correspondence

Every upstream file in scope and where its behavior lives in Swift.

| Upstream `packages/ai/src/…` | Swift | Coverage |
| --- | --- | --- |
| `types.ts` | `Types/Model.swift`, `Types/Chat.swift`, `Types/Message.swift`, `Types/Content.swift`, `Types/Tool.swift`, `Types/ToolChoice.swift`, `Types/Usage.swift`, `Types/Events.swift` | OpenAI-compatible subset. |
| `api/openai-completions.ts` | `Providers/OpenAIRequestBuilder.swift`, `Providers/OpenAIResponseParser.swift`, `Providers/OpenAIStreamParser.swift`, `Providers/OpenAICompletionsProvider.swift`, `Providers/ChatCompleting.swift`, `Providers/ChatProvider.swift` | Request build, non-streaming parse, SSE parse, retry, cancel. |
| `api/openai-responses.ts` | `Providers/OpenAIResponsesRequestBuilder.swift`, `Providers/OpenAIResponsesProvider.swift` | Request build, retry, cancellation. Compat flags, prompt caching, session affinity, ChatGPT sign-in, grammar tools and service tiers are out of scope. |
| `api/openai-responses-shared.ts` | `Providers/OpenAIResponsesStreamParser.swift`, `Providers/OpenAIResponsesResponseParser.swift` | Message/tool conversion, SSE event processing, usage/stop-reason mapping. |
| `api/anthropic-messages.ts` | `Providers/AnthropicMessagesRequestBuilder.swift`, `Providers/AnthropicMessagesStreamParser.swift`, `Providers/AnthropicMessagesResponseParser.swift`, `Providers/AnthropicMessagesProvider.swift` | Request build, message/tool conversion, SSE parse, non-streaming parse, retry, cancel. Compat flags, prompt caching, beta headers, Bedrock/Vertex variants and count-tokens are out of scope. |
| `api/simple-options.ts` | `Types/Chat.swift` (`ChatOptions`), `Models.swift` (`clampThinkingLevel`) | `toolChoice` / sampling simplifications only. |
| `api/transform-messages.ts` | `Providers/OpenAIRequestBuilder.swift` (`convertMessages`) | Message conversion; image downgrade **not** ported (see deviations). |
| `api/openai-prompt-cache.ts` | — | Not ported (no prompt-cache key support). |
| `api/constrained-sampling.ts` | `Types/Tool.swift` (`ConstrainedSampling`) | The config value is modelled; provider-side schema checking is not. |
| `models.ts` | `Models.swift` | `calculateCost` + `clampThinkingLevel` only (no vendor catalog / `Models` runtime). |
| `providers/model-schema.ts` | `Types/Model.swift`, `JSON/JSONSchema.swift` | Cost, thinking-level map, modalities, schema subset. |
| `providers/compat-schema.ts` | — | Compat overrides are out of scope. |
| `utils/event-stream.ts` | `Providers/OpenAICompletionsProvider.swift` | Replaced by `AsyncThrowingStream`. |
| `utils/json-parse.ts` | `Utils/JSONParse.swift` | Repair pass; partial JSON omitted. |
| `utils/retry.ts` | `Utils/ProviderRetry.swift` | Backoff primitives. |
| `utils/provider-retry.ts` | `Utils/ProviderRetry.swift` | Full retry policy + abortable sleep. |
| `utils/error-body.ts` | `Utils/ErrorBody.swift` | Normalize / format / truncate / extract. |
| `utils/headers.ts` | `HTTP/HTTPClient.swift`, `Providers/OpenAIRequestBuilder.swift` | Case-insensitive header handling. |
| `utils/text.ts` | — | Text helpers not needed by the subset. |
| `utils/transcript.ts` | `Types/Chat.swift` (`ChatContext`) | Simplified context. |
| `utils/sanitize-unicode.ts` | `Utils/SanitizeUnicode.swift` | Surrogate cleanup. |
| `utils/hash.ts` | — | Not ported (no prompt cache / fingerprinting). |
| `utils/uuid.ts` | — | `UUID` from Foundation is used directly. |
| `utils/sleep.ts` | `Utils/ProviderRetry.swift` (`abortableSleep`) | Abortable sleep. |
| `utils/abort.ts` / `utils/abort-signals.ts` | `Types/Chat.swift` (`CancellationSignal`) | Lock-protected, `Sendable`. |
| `utils/pi-user-agent.ts` | `Utils/PiUserAgent.swift` | Host OS/arch instead of Node `os`. |
| `utils/provider-env.ts` | — | API key is passed explicitly via `ChatOptions.apiKey`. |

## Known deviations summary

Consolidated list of every intentional difference from upstream; details are
in the per-milestone sections above.

1. **Public event protocol is simplified** (`AssistantMessageEvent`) — no
   per-block `*_start` / `*_end` events and no `reason` on `done`/`error`.
2. **`Model` uses `baseURL` but encodes `baseUrl`**, and its catalog fields are
   optional on decode for backward compatibility.
3. **`ToolCall.arguments` is a general `JSONValue`**, not a `JsonObject`.
4. **`JSONSchema` replaces TypeBox** (self-contained, `extra` preserves unknown
   keywords).
5. **`ChatCompleting.complete` throws on transport errors** instead of returning
   an error `AssistantMessage`; a provider `finish_reason` error still yields a
   message with `stopReason == .error`.
6. **`[DONE]` infers a missing `finish_reason`**; only a clean EOF without one
   throws `OpenAIStreamError/missingFinishReason`.
7. **No `partial-json` dependency** — tool argument fragments are emitted raw
   and parsed once at the end (falling back to `{}`).
8. **Retries cover request establishment only**, never a started stream.
9. **Streaming always requests usage** (`stream_options.include_usage`).
10. **`calculateCost` is pure** (returns instead of mutating `usage.cost`).
11. **Image downgrade based on `Model.input` is not implemented**; images are
    forwarded regardless of the declared modalities.
12. **Out of scope:** other providers, images, OAuth, model stores, session
    resources, CLI, vendor catalogs and `providers/*.js` definitions.

