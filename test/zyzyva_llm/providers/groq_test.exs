defmodule ZyzyvaLlm.Providers.GroqTest do
  # async: false — the "no api key" test mutates the GROQ_API_KEY env var.
  use ExUnit.Case, async: false

  alias ZyzyvaLlm.Providers.Groq

  defmodule SuccessStub do
    def post(_url, _opts) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "hello"}}]}}}
    end
  end

  defmodule RateLimitStub do
    def post(_url, _opts) do
      {:ok, %{status: 429, body: %{"error" => "rate limited"}}}
    end
  end

  defmodule TransportErrorStub do
    def post(_url, _opts), do: {:error, :timeout}
  end

  defmodule CaptureStub do
    def post(_url, opts) do
      send(self(), {:request_body, opts[:body]})
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "ok"}}]}}}
    end
  end

  @messages [%{role: "user", content: "hi"}]

  test "returns the assistant text on success" do
    assert {:ok, "hello"} = Groq.chat(@messages, api_key: "k", http_client: SuccessStub)
  end

  test "returns an api_error tuple on a non-200 response" do
    assert {:error, {:api_error, 429, _body}} =
             Groq.chat(@messages, api_key: "k", http_client: RateLimitStub)
  end

  test "returns request_failed on a transport error" do
    assert {:error, {:request_failed, :timeout}} =
             Groq.chat(@messages, api_key: "k", http_client: TransportErrorStub)
  end

  test "errors when no api key can be resolved" do
    original = System.get_env("GROQ_API_KEY")
    System.delete_env("GROQ_API_KEY")
    on_exit(fn -> if original, do: System.put_env("GROQ_API_KEY", original) end)

    assert {:error, :api_key_not_configured} = Groq.chat(@messages, http_client: SuccessStub)
  end

  test "sends the requested model in the body" do
    Groq.chat(@messages, api_key: "k", model: "my-model", http_client: CaptureStub)
    assert_received {:request_body, body}
    assert body =~ "my-model"
  end

  test "defaults to gpt-oss-120b when no model is given" do
    Groq.chat(@messages, api_key: "k", http_client: CaptureStub)
    assert_received {:request_body, body}
    assert body =~ "openai/gpt-oss-120b"
  end
end
