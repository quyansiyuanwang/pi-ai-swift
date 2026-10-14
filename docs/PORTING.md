# PORTING — upstream `@earendil-works/pi-ai` → Swift `PiAI`

This document records how the Swift port maps to the upstream TypeScript source
(`packages/ai/src/**`, version 1.2.0) and every intentional deviation.

## Status

| Milestone | Scope | Status |
| --- | --- | --- |
| M1 | Core type layer + `JSONValue` / `JSONSchema` | ✅ done |
| M2 | OpenAI Completions (non-streaming) + error body + retry | ✅ done |
| M3 | OpenAI Completions (SSE streaming) + tool fragment accumulation + reasoning + cancellation | ⏳ |
| M4 | Full test coverage + CI + docs | ⏳ |
| M5 | Live endpoint example + `v0.1.0` tag | ⏳ |

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
