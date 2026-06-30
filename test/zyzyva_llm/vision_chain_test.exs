defmodule ZyzyvaLlm.VisionChainTest do
  # async: false — the retry tests share an ETS table id via application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # base64 of "hello"
  @image %{data: "aGVsbG8=", mime_type: "image/png"}

  @usage %{"prompt_tokens" => 11, "completion_tokens" => 7, "total_tokens" => 18}

  # Stub that branches on the model id carried in the request body, so a single
  # shared http_client can drive every leg of a multi-provider stage.
  defmodule ChainStub do
    def post(_url, opts) do
      opts[:body] |> JSON.decode!() |> Map.fetch!("model") |> respond()
    end

    defp respond("ok-primary"), do: ok("PRIMARY")
    defp respond("ok-secondary"), do: ok("SECONDARY")
    defp respond("ok-fallback"), do: ok("FALLBACK")
    defp respond("unusable"), do: ok("UNUSABLE")
    defp respond("429"), do: {:ok, %{status: 429, body: %{"error" => "rate limited"}}}
    defp respond("500"), do: {:ok, %{status: 500, body: %{"error" => "overloaded"}}}
    defp respond("400"), do: {:ok, %{status: 400, body: %{"error" => "bad image"}}}
    defp respond("transport"), do: {:error, :econnrefused}
    # a 200 with a non-map body makes the leg's response extraction raise
    defp respond("crash"), do: {:ok, %{status: 200, body: "<html>not json</html>"}}

    defp respond("hang") do
      receive do
        :never -> :ok
      end
    end

    defp ok(text) do
      {:ok,
       %{
         status: 200,
         body: %{
           "choices" => [%{"message" => %{"content" => text}}],
           "usage" => %{"prompt_tokens" => 11, "completion_tokens" => 7, "total_tokens" => 18}
         }
       }}
    end
  end

  # Counts every attempt in a shared ETS table whose id is published via app env
  # (the legs run in separate Task processes, so the table id must be reachable).
  defmodule CountingStub do
    def post(_url, _opts) do
      :zyzyva_llm
      |> Application.get_env(:retry_table)
      |> :ets.update_counter(:count, 1)

      {:ok, %{status: 429, body: %{"error" => "rate limited"}}}
    end
  end

  # Counts attempts (shared ETS table) and always returns an unusable 200.
  defmodule CountingUnusableStub do
    def post(_url, _opts) do
      :zyzyva_llm
      |> Application.get_env(:retry_table)
      |> :ets.update_counter(:count, 1)

      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "UNUSABLE"}}]}}}
    end
  end

  # Fails transiently on the first attempt, then recovers on the retry.
  defmodule RecoverStub do
    def post(_url, _opts) do
      n =
        :zyzyva_llm
        |> Application.get_env(:retry_table)
        |> :ets.update_counter(:count, 1)

      recover(n)
    end

    defp recover(1), do: {:ok, %{status: 503, body: %{"error" => "overloaded"}}}

    defp recover(_) do
      {:ok, %{status: 200, body: %{"choices" => [%{"message" => %{"content" => "RECOVERED"}}]}}}
    end
  end

  defp validator do
    fn
      "UNUSABLE" -> :error
      text -> {:ok, "parsed:" <> text}
    end
  end

  defp opts(extra \\ []) do
    [api_key: "k", http_client: ChainStub, validator: validator()] ++ extra
  end

  describe "stage progression" do
    test "stage 1 usable short-circuits and stage 2 never fires" do
      stages = [
        [%{provider: :gemini, model: "ok-primary"}],
        # a client error here would short-circuit if stage 2 ever ran
        [%{provider: :groq, model: "400"}]
      ]

      assert {:ok, "parsed:PRIMARY", meta} = ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
      assert meta == %{provider: :gemini, model: "ok-primary", stage: 1, usage: @usage}
    end

    test "stage 1 transient failure advances to stage 2 and the higher-hierarchy leg wins" do
      stages = [
        [%{provider: :gemini, model: "429"}],
        [%{provider: :gemini, model: "ok-secondary"}, %{provider: :groq, model: "ok-fallback"}]
      ]

      assert {:ok, "parsed:SECONDARY", meta} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())

      assert meta == %{provider: :gemini, model: "ok-secondary", stage: 2, usage: @usage}
    end

    test "the lower-hierarchy leg wins when the higher one fails transiently" do
      stages = [
        [%{provider: :gemini, model: "429"}],
        [%{provider: :gemini, model: "500"}, %{provider: :groq, model: "ok-fallback"}]
      ]

      assert {:ok, "parsed:FALLBACK", meta} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())

      assert meta == %{provider: :groq, model: "ok-fallback", stage: 2, usage: @usage}
    end

    test "every leg failing transiently returns {:error, :exhausted}" do
      stages = [
        [%{provider: :gemini, model: "429"}],
        [%{provider: :gemini, model: "500"}, %{provider: :groq, model: "transport"}]
      ]

      assert {:error, :exhausted} = ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
    end

    test "an unusable 200 falls through exactly like a transient failure" do
      stages = [
        [%{provider: :gemini, model: "unusable"}],
        [%{provider: :groq, model: "ok-fallback"}]
      ]

      assert {:ok, "parsed:FALLBACK", %{stage: 2}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
    end
  end

  describe "client-side short-circuit" do
    test "a 4xx other than 429 short-circuits immediately and is returned as-is" do
      stages = [
        [%{provider: :gemini, model: "400"}],
        # a usable result here would win if the chain did not short-circuit first
        [%{provider: :groq, model: "ok-fallback"}]
      ]

      assert {:error, {:api_error, 400, %{"error" => "bad image"}}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
    end
  end

  describe "in-stage race / timeout" do
    test "a hung higher-hierarchy leg does not block a fast usable leg" do
      stages = [
        [
          %{provider: :gemini, model: "hang", timeout: 20},
          %{provider: :groq, model: "ok-fallback", timeout: 1000}
        ]
      ]

      assert {:ok, "parsed:FALLBACK", meta} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())

      assert meta.provider == :groq
      assert meta.stage == 1
    end
  end

  describe "crash containment" do
    test "a leg that raises on a malformed body does not crash the caller and falls through" do
      stages = [
        [%{provider: :gemini, model: "crash"}],
        [%{provider: :groq, model: "ok-fallback"}]
      ]

      log =
        capture_log(fn ->
          assert {:ok, "parsed:FALLBACK", %{stage: 2}} =
                   ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
        end)

      assert log =~ "leg crashed"
    end

    test "a validator that raises does not crash the caller and falls through" do
      stages = [
        [%{provider: :gemini, model: "ok-primary"}],
        [%{provider: :groq, model: "ok-fallback"}]
      ]

      raising_validator = fn
        "PRIMARY" -> raise "boom"
        text -> {:ok, "parsed:" <> text}
      end

      log =
        capture_log(fn ->
          assert {:ok, "parsed:FALLBACK", %{stage: 2}} =
                   ZyzyvaLlm.vision_chain(stages, "p", @image,
                     api_key: "k",
                     http_client: ChainStub,
                     validator: raising_validator
                   )
        end)

      assert log =~ "leg crashed"
    end
  end

  describe "validator contract" do
    test "raises a clear error when :validator is missing" do
      stages = [[%{provider: :groq, model: "ok-fallback"}]]

      assert_raise KeyError, fn ->
        ZyzyvaLlm.vision_chain(stages, "p", @image, api_key: "k", http_client: ChainStub)
      end
    end

    test "raises ArgumentError when :validator is not a 1-arity function" do
      stages = [[%{provider: :groq, model: "ok-fallback"}]]

      assert_raise ArgumentError, fn ->
        ZyzyvaLlm.vision_chain(stages, "p", @image,
          api_key: "k",
          http_client: ChainStub,
          validator: :not_a_function
        )
      end
    end
  end

  describe "bounded in-leg retry" do
    setup do
      table = :ets.new(:retry_counter, [:public])
      :ets.insert(table, {:count, 0})
      Application.put_env(:zyzyva_llm, :retry_table, table)
      on_exit(fn -> Application.delete_env(:zyzyva_llm, :retry_table) end)
      {:ok, table: table}
    end

    test "an unusable 200 is not retried in-leg", %{table: table} do
      stages = [[%{provider: :groq, model: "x"}]]

      assert {:error, :exhausted} =
               ZyzyvaLlm.vision_chain(stages, "p", @image,
                 api_key: "k",
                 http_client: CountingUnusableStub,
                 validator: validator(),
                 max_retries: 3
               )

      # called exactly once: an unusable 200 falls through without an in-leg retry
      assert [{:count, 1}] = :ets.lookup(table, :count)
    end

    test "retries a transient error and stops at :max_retries", %{table: table} do
      stages = [[%{provider: :groq, model: "429"}]]

      assert {:error, :exhausted} =
               ZyzyvaLlm.vision_chain(stages, "p", @image,
                 api_key: "k",
                 http_client: CountingStub,
                 validator: validator(),
                 max_retries: 2
               )

      # 1 initial attempt + 2 retries
      assert [{:count, 3}] = :ets.lookup(table, :count)
    end

    test "a retry can recover and win", %{table: _table} do
      stages = [[%{provider: :groq, model: "anything"}]]

      assert {:ok, "parsed:RECOVERED", %{stage: 1}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image,
                 api_key: "k",
                 http_client: RecoverStub,
                 validator: validator(),
                 max_retries: 1
               )
    end

    test "defaults to a single retry when :max_retries is not given", %{table: table} do
      stages = [[%{provider: :groq, model: "429"}]]

      assert {:error, :exhausted} =
               ZyzyvaLlm.vision_chain(stages, "p", @image,
                 api_key: "k",
                 http_client: CountingStub,
                 validator: validator()
               )

      # 1 initial attempt + 1 default retry
      assert [{:count, 2}] = :ets.lookup(table, :count)
    end
  end
end
