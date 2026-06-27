defmodule ZyzyvaLlm.Providers.Groq do
  @moduledoc """
  Groq provider. Uses the OpenAI-compatible chat completions API.
  """

  @behaviour ZyzyvaLlm.Provider

  alias ZyzyvaLlm.ApiKey

  @api_url "https://api.groq.com/openai/v1/chat/completions"
  @default_model "openai/gpt-oss-120b"

  @impl true
  def chat(messages, opts \\ []) do
    model = opts[:model] || @default_model
    max_tokens = opts[:max_tokens] || 4096
    http = opts[:http_client] || Req

    case ApiKey.resolve(:groq, opts) do
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
