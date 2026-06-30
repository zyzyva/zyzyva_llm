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

Text chat completions (`chat/3`) and single-call vision input (`vision/4`). The
library returns raw provider text and uniform errors; prompts and parsing stay in
the consuming apps. The staged-race vision failover chain is the next slice.
