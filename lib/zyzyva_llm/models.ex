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

    * `:text`   - general chat/synthesis/parsing. Default `openai/gpt-oss-120b`.
    * `:fast`   - low-latency / cheaper work. Default `openai/gpt-oss-20b`.
    * `:search` - Groq's web-search model. Default `groq/compound`.
  """

  @default_text "openai/gpt-oss-120b"
  @default_fast "openai/gpt-oss-20b"
  @default_search "groq/compound"

  @doc "Returns the model id for the given role."
  @spec model(:text | :fast | :search) :: String.t()
  def model(:text), do: resolve("ZYZYVA_LLM_TEXT_MODEL", :text, @default_text)
  def model(:fast), do: resolve("ZYZYVA_LLM_FAST_MODEL", :fast, @default_fast)
  def model(:search), do: resolve("ZYZYVA_LLM_SEARCH_MODEL", :search, @default_search)

  defp resolve(env_var, role, default) do
    System.get_env(env_var) || configured(role) || default
  end

  defp configured(role) do
    :zyzyva_llm
    |> Application.get_env(:models, %{})
    |> Map.get(role)
  end
end
