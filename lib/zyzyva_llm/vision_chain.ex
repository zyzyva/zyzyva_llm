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

  Failure handling mirrors slice 01's return values:

    * Transient (try another leg/stage): `{:api_error, 429, _}`, any
      `{:api_error, status, _}` with `status >= 500`, `{:request_failed, _}`, and
      `:api_key_not_configured` (that one provider is unavailable). A
      validator-rejected 200 also falls through like a transient failure.
    * Client-side / permanent (short-circuit the whole chain, returned as-is):
      `{:api_error, status, _}` with `status` in 400..499 except 429 — no provider
      will do better, so the first such error ends the chain.

  A bounded in-leg retry on a transient provider error is allowed (`:max_retries`,
  default 1); the headline resilience is the cross-vendor stage, not deep
  same-vendor retries.

  A leg that raises (a validator that throws, a malformed provider body, a bad
  model id) is contained: the crash is logged and that leg falls through like a
  transient failure rather than taking down the caller process.
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

  @default_timeout 120_000

  @doc """
  Runs the staged-race chain. Returns `{:ok, parsed, metadata}` on the first
  usable result, `{:error, :exhausted}` when no leg in any stage is usable, or the
  underlying client-side error tuple as-is on a permanent short-circuit.

  `opts` requires `:validator` (`fun(String.t()) :: {:ok, parsed} | :error`) and
  passes `:api_key` / `:http_client` through to every leg. `:max_retries`
  (default 1) bounds the in-leg transient retry.
  """
  @spec run([[entry()]], String.t(), Vision.image(), keyword()) ::
          {:ok, term(), metadata()} | {:error, term()}
  def run(stages, prompt, image, opts) do
    opts |> Keyword.fetch!(:validator) |> ensure_validator!()
    run_stages(stages, 1, prompt, image, opts)
  end

  defp ensure_validator!(validator) when is_function(validator, 1), do: :ok

  defp ensure_validator!(_validator),
    do:
      raise(ArgumentError, "ZyzyvaLlm.vision_chain requires :validator to be a 1-arity function")

  defp run_stages([], _stage_number, _prompt, _image, _opts), do: {:error, :exhausted}

  defp run_stages([stage | rest], stage_number, prompt, image, opts) do
    stage
    |> run_stage(stage_number, prompt, image, opts)
    |> advance(rest, stage_number, prompt, image, opts)
  end

  defp advance({:ok, parsed, metadata}, _rest, _stage_number, _prompt, _image, _opts),
    do: {:ok, parsed, metadata}

  defp advance(:exhausted, rest, stage_number, prompt, image, opts),
    do: run_stages(rest, stage_number + 1, prompt, image, opts)

  defp advance({:error, _reason} = error, _rest, _stage_number, _prompt, _image, _opts),
    do: error

  # Fire every leg first (so they run concurrently), then settle each within its
  # own timeout, then accept by hierarchy order.
  defp run_stage(entries, stage_number, prompt, image, opts) do
    entries
    |> Enum.map(&spawn_leg(&1, prompt, image, opts))
    |> Enum.map(&settle_leg/1)
    |> decide(stage_number)
  end

  defp spawn_leg(entry, prompt, image, opts) do
    timeout = Map.get(entry, :timeout, @default_timeout)
    task = Task.async(fn -> run_leg(entry, prompt, image, opts) end)
    {entry, task, timeout}
  end

  defp settle_leg({entry, task, timeout}) do
    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        {entry, outcome}

      # nil: the leg overran its timeout (hung) and was brutal-killed above, so
      # treat it as a transient skip. Leg-internal crashes are contained in
      # run_leg/4 and already come back through the {:ok, outcome} arm as :skip.
      _timed_out ->
        {entry, :skip}
    end
  end

  defp decide(results, stage_number) do
    Enum.reduce_while(results, :exhausted, fn
      {entry, {:accept, parsed, info}}, _acc ->
        {:halt, {:ok, parsed, metadata(entry, info, stage_number)}}

      {_entry, {:client_error, error}}, _acc ->
        {:halt, error}

      {_entry, :skip}, acc ->
        {:cont, acc}
    end)
  end

  defp metadata(entry, %{model: model, usage: usage}, stage_number) do
    %{provider: entry.provider, model: model, stage: stage_number, usage: usage}
  end

  defp run_leg(entry, prompt, image, opts) do
    attempt_leg(entry, prompt, image, opts, Keyword.get(opts, :max_retries, 1))
  rescue
    exception ->
      log_leg_crash(entry, inspect(exception.__struct__))
      :skip
  catch
    kind, reason ->
      log_leg_crash(entry, "#{kind} #{inspect(reason)}")
      :skip
  end

  defp log_leg_crash(entry, detail) do
    Logger.warning(
      "ZyzyvaLlm.vision_chain leg crashed " <>
        "(#{inspect(entry.provider)}/#{inspect(Map.get(entry, :model))}): #{detail}"
    )
  end

  defp attempt_leg(entry, prompt, image, opts, retries_left) do
    entry
    |> call_vision(prompt, image, opts)
    |> classify(opts[:validator])
    |> resolve_attempt(entry, prompt, image, opts, retries_left)
  end

  defp resolve_attempt(:transient, entry, prompt, image, opts, retries_left)
       when retries_left > 0,
       do: attempt_leg(entry, prompt, image, opts, retries_left - 1)

  defp resolve_attempt(:transient, _entry, _prompt, _image, _opts, _retries_left), do: :skip
  defp resolve_attempt(outcome, _entry, _prompt, _image, _opts, _retries_left), do: outcome

  defp classify({:ok, text, info}, validator), do: validate(validator.(text), info)

  defp classify({:error, {:api_error, status, _body}} = error, _validator)
       when status in 400..499 and status != 429,
       do: {:client_error, error}

  defp classify({:error, _transient}, _validator), do: :transient

  defp validate({:ok, parsed}, info), do: {:accept, parsed, info}
  # A validator-rejected 200 falls through like a transient failure, but is NOT
  # retried in-leg (the same provider would return the same unusable result).
  defp validate(:error, _info), do: :skip
  # A non-conforming validator return is treated as unusable rather than crashing.
  defp validate(_other, _info), do: :skip

  defp call_vision(entry, prompt, image, opts) do
    leg_opts =
      [
        http_client: opts[:http_client],
        api_key: opts[:api_key],
        model: Map.get(entry, :model),
        max_tokens: Map.get(entry, :max_tokens),
        reasoning_effort: Map.get(entry, :reasoning_effort),
        timeout: Map.get(entry, :timeout)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Vision.call_with_usage(entry.provider, prompt, image, leg_opts)
  end
end
