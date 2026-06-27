defmodule ZyzyvaLlm.Providers.Grok do
  @moduledoc """
  xAI Grok provider. Uses the OpenAI-compatible API at api.x.ai.
  """

  @behaviour ZyzyvaLlm.Provider

  alias ZyzyvaLlm.ApiKey

  @api_url "https://api.x.ai/v1/chat/completions"
  @default_model "grok-4-0709"

  @impl true
  def chat(messages, opts \\ []) do
    model = opts[:model] || @default_model
    max_tokens = opts[:max_tokens] || 4096
    http = opts[:http_client] || Req

    case ApiKey.resolve(:grok, opts) do
      nil ->
        {:error, :api_key_not_configured}

      key ->
        body =
          JSON.encode!(%{
            model: model,
            max_tokens: max_tokens,
            messages: format_messages(messages)
          })

        case http.post(@api_url,
               body: body,
               headers: [
                 {"content-type", "application/json"},
                 {"authorization", "Bearer #{key}"}
               ],
               receive_timeout: 120_000
             ) do
          {:ok, %{status: 200, body: response_body}} ->
            {:ok, extract_text(response_body)}

          {:ok, %{status: status, body: body}} ->
            {:error, {:api_error, status, body}}

          {:error, reason} ->
            {:error, {:request_failed, reason}}
        end
    end
  end

  defp extract_text(response_body) do
    text =
      response_body
      |> Map.get("choices", [])
      |> List.first(%{})
      |> get_in([Access.key("message", %{}), Access.key("content", "")])

    text || ""
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg -> %{role: msg.role, content: msg.content} end)
  end
end
