defmodule ZyzyvaLlm.Providers.VisionTest do
  # async: false — some tests mutate provider/registry env vars.
  use ExUnit.Case, async: false

  alias ZyzyvaLlm.Providers.Vision

  defmodule SuccessStub do
    def post(_url, _opts) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "extracted"}}]}}}
    end
  end

  defmodule RateLimitStub do
    def post(_url, _opts), do: {:ok, %{status: 429, body: %{"error" => "rate limited"}}}
  end

  defmodule TransportErrorStub do
    def post(_url, _opts), do: {:error, :timeout}
  end

  defmodule CaptureStub do
    def post(url, opts) do
      send(self(), {:request, url, opts})
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "ok"}}]}}}
    end
  end

  # base64 of "hello"
  @image %{data: "aGVsbG8=", mime_type: "image/png"}

  describe "uniform return shapes" do
    test "returns the model text on a 200" do
      assert {:ok, "extracted"} =
               Vision.call(:groq, "read this", @image, api_key: "k", http_client: SuccessStub)
    end

    test "returns an api_error tuple on a non-200 response" do
      assert {:error, {:api_error, 429, _body}} =
               Vision.call(:groq, "read this", @image, api_key: "k", http_client: RateLimitStub)
    end

    test "returns request_failed on a transport error" do
      assert {:error, {:request_failed, :timeout}} =
               Vision.call(:groq, "read this", @image,
                 api_key: "k",
                 http_client: TransportErrorStub
               )
    end

    test "errors when no gemini key resolves" do
      original = System.get_env("GEMINI_API_KEY")
      System.delete_env("GEMINI_API_KEY")
      on_exit(fn -> if original, do: System.put_env("GEMINI_API_KEY", original) end)

      assert {:error, :api_key_not_configured} =
               Vision.call(:gemini, "read this", @image, http_client: SuccessStub)
    end

    test "errors when no groq key resolves" do
      original = System.get_env("GROQ_API_KEY")
      System.delete_env("GROQ_API_KEY")
      on_exit(fn -> if original, do: System.put_env("GROQ_API_KEY", original) end)

      assert {:error, :api_key_not_configured} =
               Vision.call(:groq, "read this", @image, http_client: SuccessStub)
    end
  end

  describe "request body" do
    test "carries the prompt and the base64 image as an image_url content part" do
      Vision.call(:groq, "read this card", @image, api_key: "k", http_client: CaptureStub)
      assert_received {:request, _url, opts}

      decoded = JSON.decode!(opts[:body])
      assert [message] = decoded["messages"]
      assert message["role"] == "user"

      parts = message["content"]
      assert %{"type" => "text", "text" => "read this card"} in parts

      assert %{
               "type" => "image_url",
               "image_url" => %{"url" => "data:image/png;base64,aGVsbG8="}
             } in parts
    end

    test "reasoning_effort and max_tokens reach the request body" do
      Vision.call(:groq, "p", @image,
        api_key: "k",
        max_tokens: 2048,
        reasoning_effort: "none",
        http_client: CaptureStub
      )

      assert_received {:request, _url, opts}
      decoded = JSON.decode!(opts[:body])
      assert decoded["max_tokens"] == 2048
      assert decoded["reasoning_effort"] == "none"
    end

    test "omits reasoning_effort when the caller does not pass it" do
      Vision.call(:groq, "p", @image, api_key: "k", http_client: CaptureStub)
      assert_received {:request, _url, opts}
      refute Map.has_key?(JSON.decode!(opts[:body]), "reasoning_effort")
    end

    test "passes the timeout option through as receive_timeout" do
      Vision.call(:groq, "p", @image, api_key: "k", timeout: 5000, http_client: CaptureStub)
      assert_received {:request, _url, opts}
      assert opts[:receive_timeout] == 5000
    end
  end

  describe "model resolution" do
    test "an explicit model id passes through to the body" do
      Vision.call(:groq, "p", @image,
        api_key: "k",
        model: "explicit-id",
        http_client: CaptureStub
      )

      assert_received {:request, _url, opts}
      assert JSON.decode!(opts[:body])["model"] == "explicit-id"
    end

    test "an atom model resolves through the registry" do
      Vision.call(:gemini, "p", @image, api_key: "k", model: :vision, http_client: CaptureStub)
      assert_received {:request, _url, opts}
      assert JSON.decode!(opts[:body])["model"] == "gemini-3.1-flash-lite"
    end

    test "an env override wins for a role" do
      System.put_env("ZYZYVA_LLM_VISION_MODEL", "env-vision-model")
      on_exit(fn -> System.delete_env("ZYZYVA_LLM_VISION_MODEL") end)

      Vision.call(:gemini, "p", @image, api_key: "k", model: :vision, http_client: CaptureStub)
      assert_received {:request, _url, opts}
      assert JSON.decode!(opts[:body])["model"] == "env-vision-model"
    end

    test "defaults to the :vision role for gemini when no model is given" do
      Vision.call(:gemini, "p", @image, api_key: "k", http_client: CaptureStub)
      assert_received {:request, _url, opts}
      assert JSON.decode!(opts[:body])["model"] == "gemini-3.1-flash-lite"
    end

    test "defaults to the :vision_fallback role for groq when no model is given" do
      Vision.call(:groq, "p", @image, api_key: "k", http_client: CaptureStub)
      assert_received {:request, _url, opts}
      assert JSON.decode!(opts[:body])["model"] == "qwen/qwen3.6-27b"
    end
  end

  describe "provider routing" do
    test "gemini routes to its openai-compatibility endpoint with a bearer header" do
      Vision.call(:gemini, "p", @image, api_key: "gk", http_client: CaptureStub)
      assert_received {:request, url, opts}

      assert url == "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions"
      refute url =~ "generateContent"
      assert {"authorization", "Bearer gk"} in opts[:headers]
    end

    test "groq routes to its chat-completions endpoint with a bearer header" do
      Vision.call(:groq, "p", @image, api_key: "qk", http_client: CaptureStub)
      assert_received {:request, url, opts}

      assert url == "https://api.groq.com/openai/v1/chat/completions"
      assert {"authorization", "Bearer qk"} in opts[:headers]
    end
  end
end
