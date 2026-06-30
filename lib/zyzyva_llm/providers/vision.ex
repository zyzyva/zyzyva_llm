defmodule ZyzyvaLlm.Providers.Vision do
  @moduledoc """
  Shared vision (image input) request path for the OpenAI-compatible providers.

  One internal path serves every vision provider because the request body, the
  `image_url` content part, and the `choices[].message.content` extraction are
  identical — only the base URL and the resolved API key differ. Structurally
  this mirrors the Groq text provider (Bearer auth, a `{model, max_tokens,
  messages}` body), not the Gemini text provider: Gemini is reached here through
  its OpenAI-compatibility endpoint, not its native `generateContent` API.

  The image is base64-encoded bytes plus a MIME type, sent as a single
  `data:<mime>;base64,...` `image_url` part alongside the prompt text in one user
  message. `:reasoning_effort` passes straight through (Groq honors `"none"`,
  Gemini ignores it). For the Groq Qwen vision model, a reasoning model, pass
  `reasoning_effort: "none"` and a generous `:max_tokens` or it spends the token
  budget reasoning and truncates the extraction.
  """

  alias ZyzyvaLlm.{ApiKey, Models}

  @type image :: %{data: String.t(), mime_type: String.t()}

  @doc """
  Sends a single-provider vision request. Returns the uniform client shapes:
  `{:ok, text}`, `{:error, :api_key_not_configured}`,
  `{:error, {:api_error, status, body}}`, or `{:error, {:request_failed, reason}}`.
  """
  @spec call(:gemini | :groq, String.t(), image(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def call(provider, prompt, image, opts \\ []) do
    max_tokens = opts[:max_tokens] || 4096
    timeout = opts[:timeout] || 120_000
    http = opts[:http_client] || Req

    case ApiKey.resolve(provider, opts) do
      nil ->
        {:error, :api_key_not_configured}

      key ->
        body =
          %{
            model: resolve_model(opts[:model], provider),
            max_tokens: max_tokens,
            messages: [user_message(prompt, image)]
          }
          |> maybe_put(:reasoning_effort, opts[:reasoning_effort])
          |> JSON.encode!()

        case http.post(base_url(provider),
               body: body,
               headers: [
                 {"content-type", "application/json"},
                 {"authorization", "Bearer #{key}"}
               ],
               receive_timeout: timeout
             ) do
          {:ok, %{status: 200, body: response_body}} ->
            {:ok, extract_text(response_body)}

          {:ok, %{status: status, body: response_body}} ->
            {:error, {:api_error, status, response_body}}

          {:error, reason} ->
            {:error, {:request_failed, reason}}
        end
    end
  end

  defp base_url(:gemini),
    do: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"

  defp base_url(:groq), do: "https://api.groq.com/openai/v1/chat/completions"

  defp resolve_model(nil, provider), do: Models.model(default_role(provider))
  defp resolve_model(role, _provider) when is_atom(role), do: Models.model(role)
  defp resolve_model(id, _provider) when is_binary(id), do: id

  defp default_role(:gemini), do: :vision
  defp default_role(:groq), do: :vision_fallback

  defp user_message(prompt, %{data: data, mime_type: mime_type}) do
    %{
      role: "user",
      content: [
        %{type: "text", text: prompt},
        %{type: "image_url", image_url: %{url: "data:#{mime_type};base64,#{data}"}}
      ]
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp extract_text(response_body) do
    text =
      response_body
      |> Map.get("choices", [])
      |> List.first(%{})
      |> get_in([Access.key("message", %{}), Access.key("content", "")])

    text || ""
  end
end
