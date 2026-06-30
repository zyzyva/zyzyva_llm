defmodule ZyzyvaLlm do
  @moduledoc """
  Shared LLM client and model registry for zyzyva apps.

  Two responsibilities:

    * **Provider client** — a uniform `chat/3` over every provider we use
      (Anthropic, Gemini, Grok, Groq, OpenAI, Perplexity), plus a `vision/4`
      surface beside it for image input (`:gemini`, `:groq`). Every call returns
      the same `{:ok, text}` / `{:error, reason}` shape.

    * **Model registry** — `model/1` returns the canonical model id for a role
      (`:text`, `:fast`, `:search`, `:vision`, `:vision_secondary`,
      `:vision_fallback`). Defaults live here and are overridable by environment
      variable at runtime, so swapping a model needs no redeploy.

  ## Examples

      messages = [%{role: "user", content: "Say hi"}]

      ZyzyvaLlm.chat(:groq, messages, model: ZyzyvaLlm.model(:text))
      #=> {:ok, "Hi there!"}

  API keys resolve, in order, from the call's `:api_key` option, then
  `:zyzyva_llm` application config (e.g. `config :zyzyva_llm, groq_api_key: ...`),
  then the provider's standard environment variable (e.g. `GROQ_API_KEY`).
  """

  alias ZyzyvaLlm.Providers.{Anthropic, Gemini, Grok, Groq, OpenAI, Perplexity, Vision}

  @type provider :: :anthropic | :gemini | :grok | :groq | :openai | :perplexity
  @type role :: :text | :fast | :search | :vision | :vision_secondary | :vision_fallback
  @type message :: %{role: String.t(), content: String.t()}
  @type image :: %{data: String.t(), mime_type: String.t()}

  @doc """
  Returns the canonical model id for a role. See `ZyzyvaLlm.Models`.
  """
  @spec model(role()) :: String.t()
  defdelegate model(role), to: ZyzyvaLlm.Models

  @doc """
  Sends a chat request to the given provider.

  ## Options

    * `:api_key` - provider API key (falls back to config, then env var)
    * `:model` - model id override (falls back to the provider's default)
    * `:max_tokens` - max response tokens (default: 4096)
    * `:http_client` - HTTP client module for testing (default: `Req`)
  """
  @spec chat(provider(), [message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat(provider, messages, opts \\ [])

  def chat(:anthropic, messages, opts), do: Anthropic.chat(messages, opts)
  def chat(:gemini, messages, opts), do: Gemini.chat(messages, opts)
  def chat(:grok, messages, opts), do: Grok.chat(messages, opts)
  def chat(:groq, messages, opts), do: Groq.chat(messages, opts)
  def chat(:openai, messages, opts), do: OpenAI.chat(messages, opts)
  def chat(:perplexity, messages, opts), do: Perplexity.chat(messages, opts)

  @doc """
  Sends a vision (image input) request to the given provider.

  A surface beside `chat/3`: takes a provider (`:gemini` or `:groq`), a text
  `prompt`, an `image` (`%{data: base64, mime_type: mime}`), and options, and
  returns the same uniform shapes `chat/3` does. The caller parses the returned
  text; the library does not.

  ## Options

    * `:model` - a registry role (e.g. `:vision`) or an explicit model id
    * `:max_tokens` - max response tokens (default: 4096)
    * `:reasoning_effort` - passed through; Groq honors `"none"`, Gemini ignores it
    * `:timeout` - per-request receive timeout in ms (default: 120_000)
    * `:api_key` - provider API key (falls back to config, then env var)
    * `:http_client` - HTTP client module for testing (default: `Req`)

  The Groq Qwen vision model is a reasoning model: pass `reasoning_effort: "none"`
  and a generous `:max_tokens`, or it spends the token budget reasoning and
  truncates the extraction.
  """
  @spec vision(:gemini | :groq, String.t(), image(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def vision(provider, prompt, image, opts \\ [])
  def vision(:gemini, prompt, image, opts), do: Vision.call(:gemini, prompt, image, opts)
  def vision(:groq, prompt, image, opts), do: Vision.call(:groq, prompt, image, opts)

  @doc """
  Sends a chat request using the configured default provider.

  The default provider is read from `config :zyzyva_llm, :default_provider`
  and falls back to `:groq`.
  """
  @spec chat_default([message()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def chat_default(messages, opts \\ []) do
    provider = Application.get_env(:zyzyva_llm, :default_provider, :groq)
    chat(provider, messages, opts)
  end
end
