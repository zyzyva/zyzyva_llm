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

## Providers

`:anthropic`, `:gemini`, `:grok`, `:groq`, `:openai`, `:perplexity`.

## Model registry

`ZyzyvaLlm.model/1` resolves a role to a model id. Resolution order:

1. Environment variable (no redeploy needed):
   - `:text`   → `ZYZYVA_LLM_TEXT_MODEL` (default `openai/gpt-oss-120b`)
   - `:fast`   → `ZYZYVA_LLM_FAST_MODEL` (default `openai/gpt-oss-20b`)
   - `:search` → `ZYZYVA_LLM_SEARCH_MODEL` (default `groq/compound`)
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

Text chat completions only. Image/vision input is not supported here — apps that
do vision (e.g. contacts4us card scanning) own that logic.
