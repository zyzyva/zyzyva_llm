defmodule ZyzyvaLlm.Models do
  @moduledoc """
  Canonical model registry.

  `model/1` returns the model id to use for a role. This is the single place a
  model id is defined, so replacing a model (e.g. when a provider deprecates
  one) happens here once.

  Resolution order, highest priority first:

    1. Environment variable (e.g. `ZYZYVA_LLM_TEXT_MODEL`) — lets you swap a
       model at runtime with no redeploy.
    2. Application config: `config :zyzyva_llm, models: %{text: "..."}`.
    3. The built-in default below.

  ## Roles

    * `:text`             - general chat/synthesis/parsing. Default `openai/gpt-oss-120b`.
    * `:fast`             - low-latency / cheaper work. Default `openai/gpt-oss-20b`.
    * `:search`           - Groq's web-search model. Default `groq/compound`.
    * `:vision`           - primary vision model. Default `gemini-3.1-flash-lite`.
    * `:vision_secondary` - secondary vision model. Default `gemini-2.5-flash-lite`.
    * `:vision_fallback`  - cross-vendor vision fallback. Default `qwen/qwen3.6-27b` (Groq).
  """

  @default_text "openai/gpt-oss-120b"
  @default_fast "openai/gpt-oss-20b"
  @default_search "groq/compound"
  @default_vision "gemini-3.1-flash-lite"
  @default_vision_secondary "gemini-2.5-flash-lite"
  @default_vision_fallback "qwen/qwen3.6-27b"

  @doc "Returns the model id for the given role."
  @spec model(:text | :fast | :search | :vision | :vision_secondary | :vision_fallback) ::
          String.t()
  def model(:text), do: resolve("ZYZYVA_LLM_TEXT_MODEL", :text, @default_text)
  def model(:fast), do: resolve("ZYZYVA_LLM_FAST_MODEL", :fast, @default_fast)
  def model(:search), do: resolve("ZYZYVA_LLM_SEARCH_MODEL", :search, @default_search)
  def model(:vision), do: resolve("ZYZYVA_LLM_VISION_MODEL", :vision, @default_vision)

  def model(:vision_secondary),
    do: resolve("ZYZYVA_LLM_VISION_SECONDARY_MODEL", :vision_secondary, @default_vision_secondary)

  def model(:vision_fallback),
    do: resolve("ZYZYVA_LLM_VISION_FALLBACK_MODEL", :vision_fallback, @default_vision_fallback)

  defp resolve(env_var, role, default) do
    System.get_env(env_var) || configured(role) || default
  end

  defp configured(role) do
    :zyzyva_llm
    |> Application.get_env(:models, %{})
    |> Map.get(role)
  end
end
