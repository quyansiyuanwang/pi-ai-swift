# Attribution

PiAI is a native Swift port of the **OpenAI-compatible Chat Completions
subset** of [`@earendil-works/pi-ai`](https://github.com/earendil-works/pi),
version **1.2.0**.

- Upstream package: `@earendil-works/pi-ai` (npm)
- Upstream source: [`packages/ai/src`](https://github.com/earendil-works/pi/tree/main/packages/ai/src)
- Upstream version ported: **1.2.0**
- Upstream license: **MIT**
- Upstream copyright: **Copyright (c) 2025 Mario Zechner**

The Swift sources mirror the structure and behavior of the upstream
TypeScript files listed in [`docs/PORTING.md`](docs/PORTING.md). Where a direct
port was not possible (Swift value semantics, no third-party JSON-Schema or
partial-JSON dependency, a simplified event protocol defined by this package's
public contract), the deviation is documented there.

## Upstream license

The upstream project is distributed under the MIT License. Its license text is
reproduced verbatim below and its copyright notice is retained in this
repository's [`LICENSE`](LICENSE).

```
MIT License

Copyright (c) 2025 Mario Zechner

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Scope

Only the subset required by an OpenAI-compatible Chat Completions client is
ported. Other upstream providers (Anthropic, Google, Bedrock, Azure, Mistral,
pi-messages, Codex, Cloudflare, OpenRouter, …), image generation, OAuth,
model stores, session resources and the CLI are intentionally out of scope.
See [`docs/PORTING.md`](docs/PORTING.md) for the full file-by-file mapping.
