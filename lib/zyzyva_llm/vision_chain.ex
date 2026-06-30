defmodule ZyzyvaLlm.VisionChain do
  @moduledoc """
  Staged-race failover chain over the vision surface.

  Runs an ordered list of stages. Each stage is a list of entries whose order is
  the acceptance hierarchy (earliest preferred). Within a stage every entry's
  vision call fires concurrently, each bounded by its own `:timeout`; the chain
  accepts the highest-hierarchy entry whose raw text the caller's `:validator`
  judges usable. It advances to the next stage only when a stage yields nothing
  usable. The library owns *when to escalate and which result to accept*; the
  consuming app owns the prompt and the validator (it never parses domain data).

  A usable result always wins and ends the chain — within a stage by hierarchy
  (earliest preferred), across stages by the first stage that yields one. No
  failure of any kind short-circuits the chain: a failed leg (any provider error,
  including a 4xx) or a validator-rejected 200 is simply out of contention; a stage
  with no usable result advances to the next, and a chain with no usable result
  anywhere returns `{:error, {:exhausted, leg_outcomes}}`. The chain is cross-vendor
  with differing provider limits, so a 4xx on one provider does not mean another
  will fail too — the only way to know is to try the next leg/stage.

  On exhaustion, `leg_outcomes` lists every attempted leg in attempt order (stage,
  then hierarchy within the stage), each a `%{stage:, provider:, model:, outcome:}`
  with the resolved model id and the leg's final `outcome` after any bounded retry.
  The library reports what each leg did (raw status/reason); the consuming app maps
  that to its own copy/alerts. An `outcome` is one of:

    * `{:api_error, status}` — a non-200 HTTP response (e.g. 401/403 auth/billing,
      429, a 5xx, another 4xx). For a transient code retried to exhaustion this is
      the final attempt's status.
    * `{:request_failed, reason}` — a transport error; a leg that exceeds its
      `:timeout` records as `{:request_failed, :timeout}`.
    * `:api_key_not_configured` — no API key resolved for that provider.
    * `:unusable` — an HTTP 200 the validator rejected.
    * `{:crashed, detail}` — the leg raised/exited and was contained (`detail` a
      short descriptor), kept distinct from a request failure.

  The transient-vs-permanent distinction governs ONLY the bounded in-leg retry
  (`:max_retries`, default 1), never chain termination:

    * Transient — retried: `{:api_error, 429, _}`, any `{:api_error, status, _}`
      with `status >= 500`, and `{:request_failed, _}` (transport/timeout).
    * Permanent — not retried: a 4xx other than 429, `:api_key_not_configured`,
      and a validator-rejected 200 (a retry returns the same result).

  A leg that raises (a validator that throws, a malformed provider body, a bad
  model id) is contained: the crash is logged, recorded as `{:crashed, detail}`,
  and that leg falls through like a failed leg rather than taking down the caller.
  """

  alias ZyzyvaLlm.Providers.Vision

  require Logger

  @type entry :: %{
          required(:provider) => :gemini | :groq,
          required(:model) => atom() | String.t(),
          optional(:max_tokens) => pos_integer(),
          optional(:reasoning_effort) => String.t(),
          optional(:timeout) => pos_integer()
        }
  @type metadata :: %{
          provider: :gemini | :groq,
          model: String.t(),
          stage: pos_integer(),
          usage: map() | nil
        }
  @type outcome ::
          {:api_error, non_neg_integer()}
          | {:request_failed, term()}
          | :api_key_not_configured
          | :unusable
          | {:crashed, String.t()}
  @type leg_outcome :: %{
          stage: pos_integer(),
          provider: :gemini | :groq,
          model: String.t(),
          outcome: outcome()
        }

  @default_timeout 120_000

  @doc """
  Runs the staged-race chain. Returns `{:ok, parsed, metadata}` on the first
  usable result (within a stage by hierarchy, across stages by the first stage
  that yields one), or `{:error, {:exhausted, leg_outcomes}}` when no leg in any
  stage is usable — `leg_outcomes` is every attempted leg in attempt order, each
  carrying its `stage`, `provider`, resolved `model`, and final `outcome`. No
  failure short-circuits the chain.

  `opts` requires `:validator` (`fun(String.t()) :: {:ok, parsed} | :error`) and
  passes `:api_key` / `:http_client` through to every leg. `:max_retries`
  (default 1) bounds the in-leg transient retry.
  """
  @spec run([[entry()]], String.t(), Vision.image(), keyword()) ::
          {:ok, term(), metadata()} | {:error, {:exhausted, [leg_outcome()]}}
  def run(stages, prompt, image, opts) do
    opts |> Keyword.fetch!(:validator) |> ensure_validator!()
    run_stages(stages, 1, prompt, image, opts, [])
  end

  defp ensure_validator!(validator) when is_function(validator, 1), do: :ok

  defp ensure_validator!(_validator),
    do:
      raise(ArgumentError, "ZyzyvaLlm.vision_chain requires :validator to be a 1-arity function")

  defp run_stages([], _stage_number, _prompt, _image, _opts, acc),
    do: {:error, {:exhausted, acc}}

  defp run_stages([stage | rest], stage_number, prompt, image, opts, acc) do
    stage
    |> run_stage(stage_number, prompt, image, opts)
    |> advance(rest, stage_number, prompt, image, opts, acc)
  end

  defp advance({:ok, parsed, metadata}, _rest, _stage_number, _prompt, _image, _opts, _acc),
    do: {:ok, parsed, metadata}

  defp advance({:exhausted, stage_outcomes}, rest, stage_number, prompt, image, opts, acc),
    do: run_stages(rest, stage_number + 1, prompt, image, opts, acc ++ stage_outcomes)

  # Fire every leg first (so they run concurrently), then settle each within its
  # own timeout, then accept by hierarchy order / collect the failed legs.
  defp run_stage(entries, stage_number, prompt, image, opts) do
    entries
    |> Enum.map(&spawn_leg(&1, prompt, image, opts))
    |> Enum.map(&settle_leg/1)
    |> decide(stage_number)
  end

  defp spawn_leg(entry, prompt, image, opts) do
    {model_id, leg_fun} = prepare_leg(entry, prompt, image, opts)
    timeout = Map.get(entry, :timeout, @default_timeout)
    {entry, model_id, Task.async(leg_fun), timeout}
  end

  # Resolve the model id up front so it labels the leg outcome, but contain a
  # resolution failure (e.g. an unregistered role atom) here in the parent process
  # rather than letting it crash the whole chain — the leg becomes a contained
  # crash carrying a best-effort model label.
  defp prepare_leg(entry, prompt, image, opts) do
    model_id = Vision.resolve_model_id(Map.get(entry, :model), entry.provider)
    {model_id, fn -> run_leg(entry, model_id, prompt, image, opts) end}
  rescue
    exception ->
      detail = exception_detail(exception)
      label = model_label(entry)
      log_leg_crash(entry, label, detail)
      {label, fn -> {:failed, {:crashed, detail}} end}
  end

  defp model_label(entry), do: model_label_of(Map.get(entry, :model))
  defp model_label_of(model) when is_binary(model), do: model
  defp model_label_of(model), do: short_inspect(model)

  defp settle_leg({entry, model_id, task, timeout}) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, leg_result} ->
        {entry, model_id, leg_result}

      # nil: the leg overran its timeout (hung) and was brutal-killed above, so
      # record it as a transport timeout. (Leg-internal crashes are contained in
      # run_leg/5 and already arrive through the {:ok, leg_result} arm.)
      nil ->
        {entry, model_id, {:failed, {:request_failed, :timeout}}}

      # The task died abnormally for a reason other than overrunning its timeout;
      # record it as a crash (type-level only) rather than mislabeling it a timeout.
      {:exit, reason} ->
        {entry, model_id, {:failed, {:crashed, caught_detail(:exit, reason)}}}
    end
  end

  defp decide(results, stage_number) do
    results
    |> Enum.reduce_while([], fn
      {entry, _model_id, {:accept, parsed, info}}, _acc ->
        {:halt, {:ok, parsed, metadata(entry, info, stage_number)}}

      {entry, model_id, {:failed, outcome}}, acc ->
        {:cont, [leg_outcome(entry, model_id, outcome, stage_number) | acc]}
    end)
    |> finalize_stage()
  end

  defp finalize_stage({:ok, parsed, metadata}), do: {:ok, parsed, metadata}
  defp finalize_stage(outcomes) when is_list(outcomes), do: {:exhausted, Enum.reverse(outcomes)}

  defp leg_outcome(entry, model_id, outcome, stage_number) do
    %{stage: stage_number, provider: entry.provider, model: model_id, outcome: outcome}
  end

  defp metadata(entry, %{model: model, usage: usage}, stage_number) do
    %{provider: entry.provider, model: model, stage: stage_number, usage: usage}
  end

  defp run_leg(entry, model_id, prompt, image, opts) do
    attempt_leg(entry, model_id, prompt, image, opts, Keyword.get(opts, :max_retries, 1))
  rescue
    exception ->
      detail = exception_detail(exception)
      log_leg_crash(entry, model_id, detail)
      {:failed, {:crashed, detail}}
  catch
    kind, reason ->
      detail = caught_detail(kind, reason)
      log_leg_crash(entry, model_id, detail)
      {:failed, {:crashed, detail}}
  end

  # The crash detail is a SHORT, TYPE-LEVEL descriptor only — never the raised
  # message, the thrown value, the exit payload, or any provider/validator data
  # (which can carry domain content / PII). A raise records its struct name; a
  # throw records the kind only; an exit records the kind plus the wrapped
  # exception's struct name when present.
  defp exception_detail(exception), do: short_inspect(exception.__struct__)

  defp caught_detail(:exit, reason), do: "exit" <> exit_suffix(reason)
  defp caught_detail(kind, _reason), do: to_string(kind)

  defp exit_suffix({reason, _stacktrace}) when is_exception(reason),
    do: " " <> short_inspect(reason.__struct__)

  defp exit_suffix(_reason), do: ""

  @inspect_opts [printable_limit: 64, limit: 5]
  defp short_inspect(term), do: inspect(term, @inspect_opts)

  defp log_leg_crash(entry, model_id, detail) do
    Logger.warning(
      "ZyzyvaLlm.vision_chain leg crashed " <>
        "(#{short_inspect(entry.provider)}/#{short_inspect(model_id)}): #{detail}"
    )
  end

  defp attempt_leg(entry, model_id, prompt, image, opts, retries_left) do
    entry
    |> call_vision(model_id, prompt, image, opts)
    |> classify(opts[:validator])
    |> resolve_attempt(entry, model_id, prompt, image, opts, retries_left)
  end

  defp resolve_attempt({:retry, _outcome}, entry, model_id, prompt, image, opts, retries_left)
       when retries_left > 0,
       do: attempt_leg(entry, model_id, prompt, image, opts, retries_left - 1)

  # Retries exhausted: record the final attempt's outcome as the failure.
  defp resolve_attempt({:retry, outcome}, _entry, _model_id, _prompt, _image, _opts, _retries),
    do: {:failed, outcome}

  defp resolve_attempt(result, _entry, _model_id, _prompt, _image, _opts, _retries), do: result

  defp classify({:ok, text, info}, validator), do: validate(validator.(text), info)

  # Transient provider failures — eligible for the bounded in-leg retry; the
  # carried outcome is what gets recorded if the retries are exhausted.
  defp classify({:error, {:api_error, 429, _body}}, _validator), do: {:retry, {:api_error, 429}}

  defp classify({:error, {:api_error, status, _body}}, _validator) when status >= 500,
    do: {:retry, {:api_error, status}}

  defp classify({:error, {:request_failed, reason}}, _validator),
    do: {:retry, {:request_failed, reason}}

  # Permanent failures — no retry; out of contention but recorded. A 4xx other
  # than 429 (including 401/403 auth/billing) keeps its status code.
  defp classify({:error, {:api_error, status, _body}}, _validator),
    do: {:failed, {:api_error, status}}

  defp classify({:error, :api_key_not_configured}, _validator),
    do: {:failed, :api_key_not_configured}

  # Defensive: an error shape outside Vision's closed return contract is contained
  # and surfaced as a crash rather than raising. Not expected to fire today; the
  # detail is bounded so even an unforeseen reason cannot expand without bound.
  defp classify({:error, reason}, _validator), do: {:failed, {:crashed, short_inspect(reason)}}

  defp validate({:ok, parsed}, info), do: {:accept, parsed, info}
  # A validator-rejected 200 is out of contention and NOT retried (the same
  # provider returns the same unusable result). A non-conforming validator return
  # is treated the same way rather than crashing.
  defp validate(:error, _info), do: {:failed, :unusable}
  defp validate(_other, _info), do: {:failed, :unusable}

  defp call_vision(entry, model_id, prompt, image, opts) do
    leg_opts =
      [
        http_client: opts[:http_client],
        api_key: opts[:api_key],
        model: model_id,
        max_tokens: Map.get(entry, :max_tokens),
        reasoning_effort: Map.get(entry, :reasoning_effort),
        timeout: Map.get(entry, :timeout)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Vision.call_with_usage(entry.provider, prompt, image, leg_opts)
  end
end
