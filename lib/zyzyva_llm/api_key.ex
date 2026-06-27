defmodule ZyzyvaLlm.ApiKey do
  @moduledoc false

  # Standard environment variable name per provider.
  @env_vars %{
    anthropic: "ANTHROPIC_API_KEY",
    gemini: "GEMINI_API_KEY",
    grok: "XAI_API_KEY",
    groq: "GROQ_API_KEY",
    openai: "OPENAI_API_KEY",
    perplexity: "PERPLEXITY_API_KEY"
  }

  @doc """
  Resolves a provider's API key from, in order: the call's `:api_key` option,
  `:zyzyva_llm` application config (`<provider>_api_key`), then the provider's
  standard environment variable. Returns `nil` when none is set.
  """
  @spec resolve(atom(), keyword()) :: String.t() | nil
  def resolve(provider, opts) do
    opts[:api_key] ||
      Application.get_env(:zyzyva_llm, :"#{provider}_api_key") ||
      System.get_env(Map.fetch!(@env_vars, provider))
  end
end
