# TASK — PiAI: pi-ai 的 Swift 移植

你是本仓库的开发 agent。请阅读本文件后按里程碑推进，**每个里程碑保证 `swift build && swift test` 通过并提交**。

## 目标
把上游 `@earendil-works/pi-ai` 中「OpenAI 兼容 Chat Completions」所需子集，忠实移植为原生 Swift 包 `PiAI`。
最终供 macOS 应用直接链接，**运行期不依赖 Node.js**。

## 上游参考（唯一事实来源）
已克隆到 `.tmp/pi`（软链，gitignored）。源码在：
- `packages/ai/src/types.ts`
- `packages/ai/src/api/openai-completions.ts`
- `packages/ai/src/api/simple-options.ts`
- `packages/ai/src/api/transform-messages.ts`
- `packages/ai/src/api/openai-prompt-cache.ts`
- `packages/ai/src/api/constrained-sampling.ts`
- `packages/ai/src/models.ts`
- `packages/ai/src/providers/model-schema.ts`
- `packages/ai/src/providers/compat-schema.ts`
- `packages/ai/src/utils/{event-stream,json-parse,retry,provider-retry,error-body,headers,text,transcript,sanitize-unicode,hash,uuid,sleep,abort,abort-signals,pi-user-agent,provider-env}.ts`

上游版本 1.2.0，MIT。**不要凭记忆臆造 API，逐文件对照移植**。测试 fixtures 可参考 `packages/ai/test/**`。

## 范围
### 必做
1. 类型层（`types.ts`）：`Model`、`Message`（system/user/assistant/toolResult）、内容块（text/thinking/toolCall/image）、`Tool`、`ToolCall`、`ToolResultMessage`、`Usage`、`AssistantMessageEvent`、`ChatContext`、`ChatOptions`。
2. Provider：`openai-completions` 的流式与非流式；请求构造（model/messages/tools/tool_choice/temperature/max_tokens）；SSE 解析；工具调用分片累积；`reasoning_content`；错误体解析；重试（429/5xx、Retry-After、指数退避）；取消。
3. 工具 JSON Schema：自实现 `JSONValue` / `JSONSchema`（Codable），不引第三方（上游用 typebox，Swift 侧自建等价类型）。
4. utils：event-stream、json-parse（流式 JSON）、retry、provider-retry、error-body、headers、text、transcript、sanitize-unicode、hash、uuid、sleep、abort/abort-signals、pi-user-agent（简化）、provider-env（简化）。
5. `models.ts`：`calculateCost`、`clampThinkingLevel`（不移植厂商目录）。

### 不做
其它 provider（anthropic/google/bedrock/azure/mistral/pi-messages/codex/cloudflare/openrouter）、images、oauth、models-store、session-resources、cli、`providers/*.js` 厂商定义、`github-copilot-headers`。
架构上保留 `ChatProvider` 协议以便后续扩展。

## 公共 API（务必稳定，供消费方机械对接）
```swift
public struct Model: Sendable, Codable {
    public var id, name, api, provider, baseURL: String
    public var contextWindow, maxTokens: Int
    public var reasoning: Bool
    public var headers: [String: String]
}

public enum AssistantMessageEvent: Sendable {
    case start
    case textDelta(String)
    case thinkingDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsFragment: String)
    case done(AssistantMessage)
    case error(Error)
}

public struct ChatOptions: Sendable {
    public var apiKey: String
    public var temperature: Double?
    public var maxTokens: Int?
    public var headers: [String: String]
    public var signal: CancellationSignal?   // 支持取消
}

public protocol ChatProvider: Sendable {
    func stream(model: Model, context: ChatContext, options: ChatOptions)
        -> AsyncThrowingStream<AssistantMessageEvent, Error>
}
```
命名尽量贴近上游；偏差记入 `docs/PORTING.md`。

## 行为规范（易错点）
1. SSE 只按 `\n` 分帧，容忍 `\r`；忽略非 `data:` 行；`[DONE]` 结束；UTF-8 跨 chunk 边界正确。
2. `delta.tool_calls[]` 按 `index` 累积 id/name/arguments（参数逐片拼接后再解析 JSON）。
3. `reasoning_content` → `thinkingDelta`，不混入正文。
4. assistant `content=null` 且有 tool_calls 时正确回传；tool 结果用 `tool_call_id` 关联。
5. 429/5xx 重试，尊重 `Retry-After`；不可重试立即抛。
6. `abort()` / `Task.cancel()` 必须中断进行中的流。

## 工程要求
- SwiftPM，`swift-tools-version:6.0`，macOS 13+ / iOS 16+，**零第三方依赖**。
- Swift 6 严格并发零警告；公共类型 `Sendable`。
- 测试用 `URLProtocol` 注入假 HTTP，覆盖：正常流、工具分片、`[DONE]`、中途断开、429 重试、错误体、UTF-8 跨边界、取消。
- CI：GitHub Actions（macOS）`swift build && swift test`。
- 文档：README（安装/快速开始/API）、`docs/PORTING.md`（上游对照表）。

## 里程碑
- M1 类型层 + JSONValue/JSONSchema（含单测）
- M2 非流式 + 错误体 + 重试
- M3 流式 SSE + 工具分片 + reasoning + 取消
- M4 测试补全 + CI + 文档
- M5 真实端点示例 + `v0.1.0` tag

## Definition of Done
- [ ] `swift build && swift test` 全绿、零警告
- [ ] `.tmp/` 未被提交，仓库无上游源码
- [ ] 公共 API 与本文件一致，README 有完整示例
- [ ] CI 通过，`v0.1.0` tag
- [ ] `LICENSE`(MIT) 与 `ATTRIBUTION.md` 就位

## 工作方式
按里程碑提交，每步可编译可测试。需要并行可自行拆分，但保持单一事实来源。全部代码 MIT，保留上游归属。
