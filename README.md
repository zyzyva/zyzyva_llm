# ZyzyvaLlm

Shared LLM client and model registry for zyzyva apps. One place to pick which
model each app uses, and a uniform client across every provider we call.

## Why

Providers deprecate models. When that happens we want to change the model in
*one* place and bump this library, instead of editing many strings across many
repos. `ZyzyvaLlm.Models` is that one place.

## Install

```elixir
{:zyzyva_llm, github: "zyzyva/zyzyva_llm"}
```

## Usage

```elixir
messages = [
  %{role: "system", content: "You are concise."},
  %{role: "user", content: "Say hi"}
]

# Pick the model by role from the registry, not by hardcoding a string.
ZyzyvaLlm.chat(:groq, messages, model: ZyzyvaLlm.model(:text))
#=> {:ok, "Hi!"}
```

Every provider returns the same shape:

- `{:ok, text}` on success
- `{:error, :api_key_not_configured}` when no key resolves
- `{:error, {:api_error, status, body}}` on a non-200 response
- `{:error, {:request_failed, reason}}` on a transport error

### Vision (image input)

`vision/4` is a surface beside `chat/3` for sending an image plus a prompt to a
vision model. It returns the same shapes above; the caller parses the returned
text. The image is base64 bytes plus a MIME type, and both `:gemini` and `:groq`
are served by one OpenAI-compatible request path.

```elixir
image = %{data: Base.encode64(bytes), mime_type: "image/jpeg"}

ZyzyvaLlm.vision(:gemini, "Extract the contact fields as JSON.", image,
  model: ZyzyvaLlm.model(:vision)
)
#=> {:ok, "..."}
```

The Groq Qwen vision model (`:vision_fallback`) is a reasoning model: pass
`reasoning_effort: "none"` and a generous `:max_tokens`, or it spends the token
budget reasoning and truncates the extraction.

```elixir
ZyzyvaLlm.vision(:groq, prompt, image,
  model: ZyzyvaLlm.model(:vision_fallback),
  reasoning_effort: "none",
  max_tokens: 8192
)
```

### Vision failover chain

`vision_chain/4` runs an ordered list of stages over `vision/4` so consuming apps
share one resilience walk instead of re-implementing it. Each stage is a list of
entries whose order is the acceptance hierarchy (earliest preferred); within a
stage every entry fires concurrently, each bounded by its own `:timeout`. The
caller supplies a `:validator` that decides whether a leg's raw text is usable and
what the parsed value is — the library never parses domain data.

```elixir
stages = [
  # stage 1: primary Gemini alone
  [%{provider: :gemini, model: :vision, timeout: 30_000}],
  # stage 2 (only if stage 1 yields nothing usable): secondary Gemini and the
  # Groq Qwen fallback, raced together, accepted by hierarchy (cross-vendor)
  [
    %{provider: :gemini, model: :vision_secondary, timeout: 30_000},
    %{provider: :groq, model: :vision_fallback, reasoning_effort: "none",
      max_tokens: 8192, timeout: 30_000}
  ]
]

ZyzyvaLlm.vision_chain(stages, prompt, image,
  validator: fn text -> MyApp.parse(text) end,
  api_key: key
)
#=> {:ok, parsed, %{provider: :gemini, model: "gemini-3.1-flash-lite", stage: 1, usage: %{...}}}
```

Returns:

- `{:ok, parsed, %{provider:, model:, stage:, usage:}}` — the validator's parsed
  value plus which provider/model won, the 1-based stage, and the winning
  response's token `usage` (or `nil`).
- `{:error, :exhausted}` — every leg in every stage failed transiently or was
  judged unusable.
- the underlying client error as-is (e.g. `{:error, {:api_error, 400, body}}`) when
  a leg hits a permanent 4xx (except 429) — the chain short-circuits, since no
  provider will do better.

Transient failures (429, any 5xx, transport errors, a missing key on one provider)
and validator-rejected 200s advance to the next leg/stage; a bounded in-leg retry
(`:max_retries`, default 1) covers transient provider blips. Image downscaling is
not handled here (a too-large image surfaces as the provider's own client error);
it is deferred pending a dependency decision.

## Providers

`:anthropic`, `:gemini`, `:grok`, `:groq`, `:openai`, `:perplexity`.

## Model registry

`ZyzyvaLlm.model/1` resolves a role to a model id. Resolution order:

1. Environment variable (no redeploy needed):
   - `:text`             → `ZYZYVA_LLM_TEXT_MODEL` (default `openai/gpt-oss-120b`)
   - `:fast`             → `ZYZYVA_LLM_FAST_MODEL` (default `openai/gpt-oss-20b`)
   - `:search`           → `ZYZYVA_LLM_SEARCH_MODEL` (default `groq/compound`)
   - `:vision`           → `ZYZYVA_LLM_VISION_MODEL` (default `gemini-3.1-flash-lite`)
   - `:vision_secondary` → `ZYZYVA_LLM_VISION_SECONDARY_MODEL` (default `gemini-2.5-flash-lite`)
   - `:vision_fallback`  → `ZYZYVA_LLM_VISION_FALLBACK_MODEL` (default `qwen/qwen3.6-27b`)
2. App config: `config :zyzyva_llm, models: %{text: "..."}`
3. Built-in default.

## API keys

Resolved per call, in order:

1. `:api_key` option on the call
2. `config :zyzyva_llm, <provider>_api_key: "..."`
3. Standard env var: `GROQ_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`,
   `GEMINI_API_KEY`, `XAI_API_KEY` (grok), `PERPLEXITY_API_KEY`.

## Testing

Inject a stub HTTP client (any module with `post/2`) via the `:http_client`
option:

```elixir
defmodule SuccessStub do
  def post(_url, _opts),
    do: {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "hi"}}]}}}
end

ZyzyvaLlm.chat(:groq, messages, api_key: "k", http_client: SuccessStub)
```

## Scope

Text chat completions (`chat/3`), single-call vision input (`vision/4`), and the
staged-race vision failover chain (`vision_chain/4`). The library returns raw
provider text and uniform errors; prompts and parsing stay in the consuming apps.
Image downscaling for the chain is deferred pending a dependency decision.
