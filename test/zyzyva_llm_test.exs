defmodule ZyzyvaLlmTest do
  use ExUnit.Case, async: true

  doctest ZyzyvaLlm, only: []

  defmodule EchoStub do
    # OpenAI-compatible success shape (works for groq/openai/grok/perplexity).
    def post(_url, _opts) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "routed"}}]}}}
    end
  end

  @messages [%{role: "user", content: "hi"}]

  test "chat/3 routes to the named provider" do
    assert {:ok, "routed"} =
             ZyzyvaLlm.chat(:groq, @messages, api_key: "k", http_client: EchoStub)
  end

  test "chat_default/2 uses the default provider (groq)" do
    assert {:ok, "routed"} =
             ZyzyvaLlm.chat_default(@messages, api_key: "k", http_client: EchoStub)
  end

  test "model/1 delegates to the registry" do
    assert is_binary(ZyzyvaLlm.model(:text))
  end

  test "vision/4 routes to the named provider" do
    image = %{data: "aGVsbG8=", mime_type: "image/png"}

    assert {:ok, "routed"} =
             ZyzyvaLlm.vision(:groq, "extract", image, api_key: "k", http_client: EchoStub)
  end

  test "vision_chain/4 runs a stage and returns the accepted value with metadata" do
    image = %{data: "aGVsbG8=", mime_type: "image/png"}
    stages = [[%{provider: :groq, model: "m"}]]

    assert {:ok, "routed", %{provider: :groq, model: "m", stage: 1}} =
             ZyzyvaLlm.vision_chain(stages, "extract", image,
               api_key: "k",
               http_client: EchoStub,
               validator: fn text -> {:ok, text} end
             )
  end
end
