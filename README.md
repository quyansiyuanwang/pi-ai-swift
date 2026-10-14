# PiAI

A native Swift port of the **OpenAI-compatible Chat Completions** subset of
[`@earendil-works/pi-ai`](https://github.com/earendil-works/pi) (upstream
version **1.2.0**, MIT).

PiAI links directly into macOS / iOS apps and has **no runtime dependency on
Node.js** and **no third-party Swift packages**. It provides streaming and
non-streaming chat completions, tool calling, reasoning content, retry with
backoff, cancellation, a self-contained JSON-Schema type, and token-cost
calculation.

> Ported from `earendil-works/pi@1.2.0`. See [`ATTRIBUTION.md`](ATTRIBUTION.md)
> and [`docs/PORTING.md`](docs/PORTING.md) for the upstream mapping and every
> intentional deviation.

## Features

- ✅ Streaming SSE and non-streaming Chat Completions
- ✅ `delta.tool_calls[]` fragment accumulation by `index`
- ✅ `reasoning_content` → thinking deltas (kept out of the answer)
- ✅ 429 / 5xx retry with `Retry-After` + exponential backoff
- ✅ Cooperative cancellation (`CancellationSignal` / `Task.cancel()`)
- ✅ Self-contained `JSONValue` / `JSONSchema` (no TypeBox / no dependencies)
- ✅ `calculateCost` pricing tiers and `clampThinkingLevel`
- ✅ Swift 6 strict concurrency, `Sendable` public types, zero warnings

## Requirements

| | |
| --- | --- |
| Swift | 6.0+ (`swift-tools-version:6.0`) |
| Platforms | macOS 13+, iOS 16+ |
| Dependencies | none |

## Installation

Add PiAI to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/<owner>/pi-ai-swift.git", from: "0.1.0")
],
targets: [
    .target(name: "MyApp", dependencies: ["PiAI"])
]
```

## Quick start

### Non-streaming

```swift
import PiAI

let model = Model(
    id: "gpt-4o-mini",
    name: "GPT-4o mini",
    api: "openai-completions",
    provider: "openai",
    baseURL: "https://api.openai.com/v1",
    contextWindow: 128_000,
    maxTokens: 16_384
)

let provider = OpenAICompletionsProvider()
let context = ChatContext(
    systemPrompt: "You are a helpful assistant.",
    messages: [.user(UserMessage(content: "Hello!", timestamp: 0))]
)

let message = try await provider.complete(
    model: model,
    context: context,
    options: ChatOptions(apiKey: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "")
)

let text = message.content.compactMap {
    if case .text(let block) = $0 { return block.text }
    return nil
}.joined()
print(text)
```

### Streaming

```swift
let stream = provider.stream(
    model: model,
    context: context,
    options: ChatOptions(apiKey: apiKey)
)

for try await event in stream {
    switch event {
    case .start:
        print("…")
    case .textDelta(let delta):
        print(delta, terminator: "")
    case .thinkingDelta(let delta):
        print("[thinking] \(delta)", terminator: "")
    case .toolCallDelta(let index, let id, let name, let fragment):
        print("[tool \(index)] id=\(id ?? "-") name=\(name ?? "-") args+=\(fragment)")
    case .done(let message):
        print("\nstop reason: \(message.stopReason.rawValue)")
    case .error(let error):
        print("\nerror: \(error)")
    }
}
```

### Tool calling

```swift
let weatherTool = Tool(
    name: "get_weather",
    description: "Get the current weather for a city.",
    parameters: JSONSchema(
        type: [.object],
        properties: ["city": JSONSchema(type: [.string], description: "City name.")],
        required: ["city"]
    )
)

let context = ChatContext(
    messages: [.user(UserMessage(content: "What's the weather in Paris?", timestamp: 0))],
    tools: [weatherTool]
)

let stream = provider.stream(model: model, context: context, options: ChatOptions(apiKey: apiKey))
var assistant: AssistantMessage?
for try await event in stream {
    if case .done(let message) = event { assistant = message }
}

// The final assistant message contains a `.toolCall` block once arguments are
// fully accumulated and parsed.
if case .toolCall(let call)? = assistant?.content.first(where: {
    if case .toolCall = $0 { return true }
    return false
}) {
    print("\(call.name)(\(call.arguments))")
}
```

### Cancellation

```swift
let signal = CancellationSignal()
let stream = provider.stream(
    model: model,
    context: context,
    options: ChatOptions(apiKey: apiKey, signal: signal)
)

// From any task:
signal.cancel()
```

Cancelling the signal (or the consuming task) finishes iteration by throwing
`CancellationError`; provider failures arrive as a final `.error` event.

## Public API overview

| Type | Purpose |
| --- | --- |
| `Model` | Model metadata incl. `input`, `cost`, `thinkingLevelMap` |
| `ChatContext` | `systemPrompt`, `messages`, `tools` |
| `ChatOptions` | `apiKey`, `temperature`, `maxTokens`, `toolChoice`, `headers`, `signal` |
| `ChatProvider` | `stream(model:context:options:) -> AsyncThrowingStream<AssistantMessageEvent, Error>` |
| `ChatCompleting` | `complete(model:context:options:) async throws -> AssistantMessage` |
| `OpenAICompletionsProvider` | OpenAI-compatible streaming + non-streaming implementation |
| `Message` / `AssistantMessage` / `ToolResultMessage` | Conversation messages |
| `ContentBlock` | `.text` / `.thinking` / `.image` / `.toolCall` |
| `AssistantMessageEvent` | `.start`, `.textDelta`, `.thinkingDelta`, `.toolCallDelta`, `.done`, `.error` |
| `Tool` / `ToolCall` / `JSONSchema` / `JSONValue` | Tool declarations and JSON schema |
| `Usage` / `Usage.Cost` | Token usage and cost |
| `CancellationSignal` | Cooperative cancellation |
| `HTTPClient` / `StreamingHTTPClient` | Pluggable transports (tests inject `URLProtocol`) |

### Pricing and thinking levels

```swift
let cost = model.calculateCost(usage: message.usage)   // Usage.Cost
let usageWithCost = model.applyingCost(to: message.usage)

let supported = model.supportedThinkingLevels          // [ModelThinkingLevel]
let clamped = model.clampThinkingLevel(.max)           // nearest supported level
```

`calculateCost` applies request-wide pricing tiers (the highest matching
`inputTokensAbove` wins) and bills 1h cache writes at twice the input rate.
`clampThinkingLevel` mirrors upstream: `xhigh` / `max` are opt-in via
`thinkingLevelMap`; an explicit `null` (``ThinkingLevelMap/Value/unsupported``)
marks a level as unavailable.

## Offline example

[`Examples/PiAIExamples`](Examples/PiAIExamples) runs the complete
"streaming + one tool call" chain against a mock `URLProtocol` — no API key and
no network:

```sh
swift run PiAIExamples
```

The same scenario is asserted by `Tests/PiAITests/EndToEndExampleTests.swift`.

## Relationship to upstream

PiAI is an independent, faithful port of a subset of `@earendil-works/pi-ai`.
Names, JSON wire formats, retry policy and pricing/thinking-level semantics are
kept as close to upstream as Swift allows. Every intentional deviation is
recorded in [`docs/PORTING.md`](docs/PORTING.md); upstream copyright and license
are retained in [`ATTRIBUTION.md`](ATTRIBUTION.md).

## Development

```sh
swift build -Xswiftc -warnings-as-errors
swift test  -Xswiftc -warnings-as-errors
```

CI runs both commands on a macOS runner
([`.github/workflows/ci.yml`](.github/workflows/ci.yml)).

## License

MIT. See [`LICENSE`](LICENSE) and [`ATTRIBUTION.md`](ATTRIBUTION.md).
