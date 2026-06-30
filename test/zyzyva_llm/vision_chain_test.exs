defmodule ZyzyvaLlm.VisionChainTest do
  # async: false — the retry tests share an ETS table id via application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # base64 of "hello"
  @image %{data: "aGVsbG8=", mime_type: "image/png"}

  @usage %{"prompt_tokens" => 11, "completion_tokens" => 7, "total_tokens" => 18}

  # A unique string standing in for domain content (OCR'd PII) that a misbehaving
  # validator might raise/throw; it must never reach the crash detail or the log.
  @marker "DOMAIN_MARKER_4f3a9b2c"

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
    defp respond("403"), do: {:ok, %{status: 403, body: %{"error" => "billing inactive"}}}
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

  # Counts attempts (shared ETS table) and always returns a permanent 400.
  defmodule CountingBadRequestStub do
    def post(_url, _opts) do
      :zyzyva_llm
      |> Application.get_env(:retry_table)
      |> :ets.update_counter(:count, 1)

      {:ok, %{status: 400, body: %{"error" => "bad image"}}}
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
    test "stage 1 usable wins and stage 2 never fires" do
      stages = [
        [%{provider: :gemini, model: "ok-primary"}],
        # a different usable result here would surface if stage 2 wrongly ran
        [%{provider: :groq, model: "ok-fallback"}]
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

    test "every leg failing transiently returns {:error, {:exhausted, _}}" do
      stages = [
        [%{provider: :gemini, model: "429"}],
        [%{provider: :gemini, model: "500"}, %{provider: :groq, model: "transport"}]
      ]

      assert {:error, {:exhausted, _outcomes}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
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

  describe "client 4xx does not short-circuit" do
    test "a higher-hierarchy 4xx still lets a usable lower-hierarchy leg win in the same stage" do
      stages = [
        [%{provider: :gemini, model: "400"}, %{provider: :groq, model: "ok-fallback"}]
      ]

      assert {:ok, "parsed:FALLBACK", meta} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())

      assert meta == %{provider: :groq, model: "ok-fallback", stage: 1, usage: @usage}
    end

    test "a stage-1 4xx with no usable leg advances to the next stage" do
      stages = [
        [%{provider: :gemini, model: "400"}],
        [%{provider: :groq, model: "ok-fallback"}]
      ]

      assert {:ok, "parsed:FALLBACK", %{provider: :groq, stage: 2}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
    end

    test "a 4xx with no usable leg anywhere returns {:error, {:exhausted, _}}" do
      stages = [[%{provider: :gemini, model: "400"}]]

      assert {:error, {:exhausted, [%{outcome: {:api_error, 400}}]}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
    end
  end

  describe "exhaustion leg outcomes" do
    test "a 403 is recorded as {:api_error, 403}" do
      stages = [[%{provider: :gemini, model: "403"}]]

      assert {:error, {:exhausted, [%{outcome: {:api_error, 403}}]}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
    end

    test "a transient code retried to exhaustion records the final attempt's status" do
      stages = [[%{provider: :gemini, model: "429"}]]

      assert {:error, {:exhausted, [%{outcome: {:api_error, 429}}]}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
    end

    test "a transport failure is recorded as {:request_failed, _}" do
      stages = [[%{provider: :gemini, model: "transport"}]]

      assert {:error, {:exhausted, [%{outcome: {:request_failed, :econnrefused}}]}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
    end

    test "a leg that exceeds its timeout is recorded as {:request_failed, :timeout}" do
      stages = [[%{provider: :gemini, model: "hang", timeout: 20}]]

      assert {:error, {:exhausted, [%{outcome: {:request_failed, :timeout}}]}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
    end

    test "a missing key is recorded as :api_key_not_configured" do
      original = System.get_env("GROQ_API_KEY")
      System.delete_env("GROQ_API_KEY")
      on_exit(fn -> if original, do: System.put_env("GROQ_API_KEY", original) end)

      stages = [[%{provider: :groq, model: "ok-fallback"}]]

      # no :api_key passed and GROQ_API_KEY cleared -> the leg resolves no key
      assert {:error, {:exhausted, [%{provider: :groq, outcome: :api_key_not_configured}]}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image,
                 http_client: ChainStub,
                 validator: validator()
               )
    end

    test "a validator-rejected 200 is recorded as :unusable" do
      stages = [[%{provider: :gemini, model: "unusable"}]]

      assert {:error, {:exhausted, [%{outcome: :unusable}]}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
    end

    test "a contained leg crash is recorded as {:crashed, _}" do
      stages = [[%{provider: :gemini, model: "crash"}]]

      log =
        capture_log(fn ->
          assert {:error, {:exhausted, [%{outcome: {:crashed, _}}]}} =
                   ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
        end)

      assert log =~ "leg crashed"
    end

    test "an unregistered model role is contained, not raised at the caller" do
      stages = [[%{provider: :gemini, model: :unregistered_role}]]

      log =
        capture_log(fn ->
          assert {:error,
                  {:exhausted,
                   [%{provider: :gemini, model: ":unregistered_role", outcome: {:crashed, _}}]}} =
                   ZyzyvaLlm.vision_chain(stages, "p", @image, opts())
        end)

      assert log =~ "leg crashed"
    end

    test "lists every attempted leg across stages in attempt order with stage/provider/model" do
      stages = [
        [%{provider: :gemini, model: "403"}],
        [%{provider: :gemini, model: "unusable"}, %{provider: :groq, model: "transport"}]
      ]

      assert {:error, {:exhausted, outcomes}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())

      assert outcomes == [
               %{stage: 1, provider: :gemini, model: "403", outcome: {:api_error, 403}},
               %{stage: 2, provider: :gemini, model: "unusable", outcome: :unusable},
               %{
                 stage: 2,
                 provider: :groq,
                 model: "transport",
                 outcome: {:request_failed, :econnrefused}
               }
             ]
    end

    test "an auth/billing 403 is detectable from the outcomes alone" do
      stages = [
        [%{provider: :gemini, model: "403"}],
        [%{provider: :groq, model: "500"}]
      ]

      assert {:error, {:exhausted, outcomes}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image, opts())

      assert Enum.any?(outcomes, fn o -> o.outcome in [{:api_error, 401}, {:api_error, 403}] end)
    end

    test "an all-unusable exhaustion is distinguishable from an all-errored one" do
      unusable = [
        [%{provider: :gemini, model: "unusable"}, %{provider: :groq, model: "unusable"}]
      ]

      assert {:error, {:exhausted, unusable_outcomes}} =
               ZyzyvaLlm.vision_chain(unusable, "p", @image, opts())

      assert Enum.all?(unusable_outcomes, fn o -> o.outcome == :unusable end)

      errored = [[%{provider: :gemini, model: "500"}, %{provider: :groq, model: "transport"}]]

      assert {:error, {:exhausted, errored_outcomes}} =
               ZyzyvaLlm.vision_chain(errored, "p", @image, opts())

      refute Enum.all?(errored_outcomes, fn o -> o.outcome == :unusable end)
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

    test "a validator that throws (non-exception) is also contained and falls through" do
      stages = [
        [%{provider: :gemini, model: "ok-primary"}],
        [%{provider: :groq, model: "ok-fallback"}]
      ]

      throwing_validator = fn
        "PRIMARY" -> throw(:boom)
        text -> {:ok, "parsed:" <> text}
      end

      log =
        capture_log(fn ->
          assert {:ok, "parsed:FALLBACK", %{stage: 2}} =
                   ZyzyvaLlm.vision_chain(stages, "p", @image,
                     api_key: "k",
                     http_client: ChainStub,
                     validator: throwing_validator
                   )
        end)

      assert log =~ "leg crashed"
    end
  end

  describe "crash detail is type-level (no domain content)" do
    test "a validator that raises records only the exception type, never the message" do
      stages = [[%{provider: :gemini, model: "ok-primary"}]]
      raising = fn _text -> raise @marker <> " secret card text" end

      {result, log} =
        with_log(fn ->
          ZyzyvaLlm.vision_chain(stages, "p", @image,
            api_key: "k",
            http_client: ChainStub,
            validator: raising
          )
        end)

      assert {:error, {:exhausted, [%{outcome: {:crashed, detail}}]}} = result
      assert detail == "RuntimeError"
      refute detail =~ @marker
      refute log =~ @marker
    end

    test "a validator that throws records only the kind, never the thrown value" do
      stages = [[%{provider: :gemini, model: "ok-primary"}]]
      throwing = fn _text -> throw(@marker <> " thrown domain value") end

      {result, log} =
        with_log(fn ->
          ZyzyvaLlm.vision_chain(stages, "p", @image,
            api_key: "k",
            http_client: ChainStub,
            validator: throwing
          )
        end)

      assert {:error, {:exhausted, [%{outcome: {:crashed, detail}}]}} = result
      assert detail == "throw"
      refute detail =~ @marker
      refute log =~ @marker
    end

    test "a validator that exits records only the exit kind, never the exit payload" do
      stages = [[%{provider: :gemini, model: "ok-primary"}]]
      exiting = fn _text -> exit(@marker <> " exit payload") end

      {result, log} =
        with_log(fn ->
          ZyzyvaLlm.vision_chain(stages, "p", @image,
            api_key: "k",
            http_client: ChainStub,
            validator: exiting
          )
        end)

      assert {:error, {:exhausted, [%{outcome: {:crashed, detail}}]}} = result
      assert detail == "exit"
      refute detail =~ @marker
      refute log =~ @marker
    end

    test "a validator that exits with a wrapped exception records the exception type only" do
      stages = [[%{provider: :gemini, model: "ok-primary"}]]
      exiting = fn _text -> exit({%RuntimeError{message: @marker}, []}) end

      {result, log} =
        with_log(fn ->
          ZyzyvaLlm.vision_chain(stages, "p", @image,
            api_key: "k",
            http_client: ChainStub,
            validator: exiting
          )
        end)

      assert {:error, {:exhausted, [%{outcome: {:crashed, detail}}]}} = result
      assert detail == "exit RuntimeError"
      refute detail =~ @marker
      refute log =~ @marker
    end

    test "a contained crash still falls through to a usable sibling leg" do
      stages = [
        [%{provider: :gemini, model: "ok-primary"}, %{provider: :groq, model: "ok-fallback"}]
      ]

      raising = fn
        "PRIMARY" -> raise @marker
        text -> {:ok, "parsed:" <> text}
      end

      {result, log} =
        with_log(fn ->
          ZyzyvaLlm.vision_chain(stages, "p", @image,
            api_key: "k",
            http_client: ChainStub,
            validator: raising
          )
        end)

      assert {:ok, "parsed:FALLBACK", %{provider: :groq, stage: 1}} = result
      refute log =~ @marker
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

    test "a validator return that breaks the {:ok, parsed} | :error contract is treated as unusable" do
      stages = [
        [%{provider: :gemini, model: "ok-primary"}],
        [%{provider: :groq, model: "ok-fallback"}]
      ]

      # Returns neither {:ok, parsed} nor :error for the stage-1 leg; the chain
      # treats the non-conforming value as unusable and falls through rather than
      # crashing or accepting it.
      non_conforming_validator = fn
        "PRIMARY" -> :nope
        text -> {:ok, "parsed:" <> text}
      end

      assert {:ok, "parsed:FALLBACK", %{stage: 2}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image,
                 api_key: "k",
                 http_client: ChainStub,
                 validator: non_conforming_validator
               )
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

      assert {:error, {:exhausted, _outcomes}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image,
                 api_key: "k",
                 http_client: CountingUnusableStub,
                 validator: validator(),
                 max_retries: 3
               )

      # called exactly once: an unusable 200 falls through without an in-leg retry
      assert [{:count, 1}] = :ets.lookup(table, :count)
    end

    test "a permanent 4xx is not retried in-leg", %{table: table} do
      stages = [[%{provider: :groq, model: "x"}]]

      assert {:error, {:exhausted, _outcomes}} =
               ZyzyvaLlm.vision_chain(stages, "p", @image,
                 api_key: "k",
                 http_client: CountingBadRequestStub,
                 validator: validator(),
                 max_retries: 3
               )

      # called exactly once: a permanent 4xx is out of contention, not retried
      assert [{:count, 1}] = :ets.lookup(table, :count)
    end

    test "retries a transient error and stops at :max_retries", %{table: table} do
      stages = [[%{provider: :groq, model: "429"}]]

      assert {:error, {:exhausted, _outcomes}} =
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

      assert {:error, {:exhausted, _outcomes}} =
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
