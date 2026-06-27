defmodule ZyzyvaLlm.Providers.Anthropic do
  @moduledoc """
  Anthropic Claude provider. Uses the Messages API; `"system"` messages are
  hoisted into the top-level `system` field.
  """

  @behaviour ZyzyvaLlm.Provider

  alias ZyzyvaLlm.ApiKey

  @api_url "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-20250514"
  @anthropic_version "2023-06-01"

  @impl true
  def chat(messages, opts \\ []) do
    model = opts[:model] || @default_model
    max_tokens = opts[:max_tokens] || 4096
    http = opts[:http_client] || Req

    case ApiKey.resolve(:anthropic, opts) do
      nil ->
        {:error, :api_key_not_configured}

      key ->
        {system_messages, user_messages} = extract_system(messages)

        body =
          %{model: model, max_tokens: max_tokens, messages: format_messages(user_messages)}
          |> maybe_add_system(system_messages)
          |> JSON.encode!()

        case http.post(@api_url,
               body: body,
               headers: [
                 {"content-type", "application/json"},
                 {"x-api-key", key},
                 {"anthropic-version", @anthropic_version}
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
    response_body
    |> Map.get("content", [])
    |> Enum.find(%{}, &(&1["type"] == "text"))
    |> Map.get("text", "")
  end

  defp extract_system(messages) do
    Enum.split_with(messages, fn msg -> msg.role == "system" end)
  end

  defp maybe_add_system(body, []), do: body

  defp maybe_add_system(body, system_messages) do
    system_text = Enum.map_join(system_messages, "\n\n", & &1.content)
    Map.put(body, :system, system_text)
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg -> %{role: msg.role, content: msg.content} end)
  end
end
