defmodule ZyzyvaLlm do
  @moduledoc """
  Shared LLM client and model registry for zyzyva apps.

  Two responsibilities:

    * **Provider client** — a uniform `chat/3` over every provider we use
      (Anthropic, Gemini, Grok, Groq, OpenAI, Perplexity). Every provider
      returns the same `{:ok, text}` / `{:error, reason}` shape.

    * **Model registry** — `model/1` returns the canonical model id for a role
      (`:text`, `:fast`, `:search`). Defaults live here and are overridable by
      environment variable at runtime, so swapping a model needs no redeploy.

  ## Examples

      messages = [%{role: "user", content: "Say hi"}]

      ZyzyvaLlm.chat(:groq, messages, model: ZyzyvaLlm.model(:text))
      #=> {:ok, "Hi there!"}

  API keys resolve, in order, from the call's `:api_key` option, then
  `:zyzyva_llm` application config (e.g. `config :zyzyva_llm, groq_api_key: ...`),
  then the provider's standard environment variable (e.g. `GROQ_API_KEY`).
  """

  alias ZyzyvaLlm.Providers.{Anthropic, Gemini, Grok, Groq, OpenAI, Perplexity}

  @type provider :: :anthropic | :gemini | :grok | :groq | :openai | :perplexity
  @type role :: :text | :fast | :search
  @type message :: %{role: String.t(), content: String.t()}

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
