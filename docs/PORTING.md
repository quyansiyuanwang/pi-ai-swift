# PORTING — upstream `@earendil-works/pi-ai` → Swift `PiAI`

This document records how the Swift port maps to the upstream TypeScript source
(`packages/ai/src/**`, version 1.2.0) and every intentional deviation.

## Status

| Milestone | Scope | Status |
| --- | --- | --- |
| M1 | Core type layer + `JSONValue` / `JSONSchema` | ✅ done |
| M2 | OpenAI Completions (non-streaming) + error body + retry | ⏳ |
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
| `StreamOptions` (subset) | `ChatOptions` | `apiKey`, `temperature`, `maxTokens`, `headers`, `signal`. |
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

## Testing note

The build host only has Apple Command Line Tools installed (no full Xcode), so
`XCTest` is not available. Tests therefore use the toolchain-bundled
**Swift Testing** framework (`import Testing`, `@Suite` / `@Test` / `#expect`).
`swift test` discovers and runs them normally. This is an infrastructure choice,
not an API deviation.
