defmodule ZyzyvaLlm.Providers.Gemini do
  @moduledoc """
  Google Gemini provider. Uses the `generateContent` API; `"system"` messages
  are hoisted into `systemInstruction`.
  """

  @behaviour ZyzyvaLlm.Provider

  alias ZyzyvaLlm.ApiKey

  @api_base "https://generativelanguage.googleapis.com/v1beta/models"
  @default_model "gemini-2.5-flash"

  @impl true
  def chat(messages, opts \\ []) do
    model = opts[:model] || @default_model
    http = opts[:http_client] || Req

    case ApiKey.resolve(:gemini, opts) do
      nil ->
        {:error, :api_key_not_configured}

      key ->
        {system_messages, user_messages} = extract_system(messages)

        body =
          %{contents: format_messages(user_messages)}
          |> maybe_add_system(system_messages)
          |> JSON.encode!()

        url = "#{@api_base}/#{model}:generateContent?key=#{key}"

        case http.post(url,
               body: body,
               headers: [{"content-type", "application/json"}],
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
      get_in(
        response_body,
        ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]
      )

    text || ""
  end

  defp extract_system(messages) do
    Enum.split_with(messages, fn msg -> msg.role == "system" end)
  end

  defp maybe_add_system(body, []), do: body

  defp maybe_add_system(body, system_messages) do
    system_text = Enum.map_join(system_messages, "\n\n", & &1.content)
    Map.put(body, :systemInstruction, %{parts: [%{text: system_text}]})
  end

  defp format_messages(messages) do
    Enum.map(messages, fn msg ->
      %{role: gemini_role(msg.role), parts: [%{text: msg.content}]}
    end)
  end

  defp gemini_role("assistant"), do: "model"
  defp gemini_role(role), do: role
end
