# 0001 — Extract a shared LLM library and migrate off deprecated Groq models

Status: Draft (awaiting go-ahead)
Date: 2026-06-26

## Context

Groq is shutting down every Llama model currently in use across these repos:

- `meta-llama/llama-4-scout` (vision) — shutdown 2026-07-17 (~3 weeks). No Groq
  replacement exists; Groq no longer offers any vision model.
- `llama-3.3-70b-versatile` (text) — shutdown 2026-08-16 (~7 weeks). Replacement:
  `openai/gpt-oss-120b`.
- `llama-3.1-8b-instant`, `qwen/qwen3-32b`, `llama-4-maverick` — only used in
  scripts/tests, not production paths.

Today the LLM call logic is duplicated across many repos in slightly different
shapes, so a model change means editing many files in many projects. SeoKit
already contains the most complete LLM abstraction we own — a provider router
over six providers, returning a uniform success shape, with test seams. We will
promote that layer into its own library so model changes happen in one place.

## Goal

A single shared library, `zyzyva_llm`, that:

1. Owns the canonical list of which model to use for each role, overridable by
   environment variable at runtime so an emergency model swap needs no redeploy.
2. Provides a thin, uniform client for chat completions across all our LLM
   providers, lifted from SeoKit's existing provider modules.
3. Becomes the one place a deprecated model gets replaced going forward.

Distributed the same way as our other shared libraries — a GitHub dependency
(`zyzyva/zyzyva_llm`), matching `zyzyva_telemetry` and `seo_kit`.

## Non-goals

- Not rewriting each app's higher-level logic (JSON-schema validation, retry
  loops, prompt construction). Those stay in the apps that own them.
- Not building a provider-agnostic fallback/failover engine. Apps that already
  orchestrate fallback (the contacts4us card scanner) keep doing so.
- Not changing snacks4sale's language; it is TypeScript and cannot consume an
  Elixir library. It is handled separately.

## The library

### Model registry
- Exposes the chosen model for each role: a general text role, a fast/low-latency
  role, and a search role (Groq's compound search model, which is not deprecated).
- Each role has a sensible built-in default and can be overridden by an
  environment variable without code changes or redeploys.
- Confirmed default for the text role: `openai/gpt-oss-120b` (closest quality
  match to the retiring 70B model, and cheaper per token). Fast role default:
  `openai/gpt-oss-20b`.

### Provider client
- Lifted from SeoKit's existing six provider modules (Anthropic, Gemini, Grok,
  Groq, OpenAI, Perplexity) plus the router that dispatches by provider name.
- Uniform success and error shape, matching SeoKit's current contract so the
  move is behaviour-preserving.
- Keeps SeoKit's test seam: callers can inject a stub HTTP client.
- Accepts an explicit API key per call; falls back to a configured source so each
  consuming app can supply its own key the way it does today.
- Emits token-usage telemetry consistent with our existing telemetry events.

### Dependencies
- Only the HTTP client and the native JSON module, plus telemetry. No Phoenix,
  no SEO code. This keeps it safe for every consumer to depend on.

## SeoKit convergence

SeoKit's LLM layer is the source of the lifted code, so SeoKit must end up
depending on the new library rather than carrying its own copy. To protect
SeoKit's existing consumers (campaign_forge, site_forge, provisioner, shipyard):

- SeoKit keeps its current public modules and function names. Internally they
  delegate to the new library. Existing callers and SeoKit's own tests do not
  change.
- SeoKit gains a dependency on the new library and deletes its private provider
  implementations.

Resulting layering:

```
zyzyva_llm
   |--- seo_kit ---> campaign_forge, site_forge, provisioner, shipyard
   |--- the text apps directly (lead_intelligence, marketing_research,
         church_voter_guides, hunter_dev, campaign_forge, site_forge)
```

## Rollout — two waves by deadline

### Wave 1 — vision, by 2026-07-17 (urgent; not a library task)
Groq has no vision model anymore, so these need a different vision provider, not
a model-string swap. Decisions still open (see Open Decisions):

- contacts4us card scanner: Groq Llama-4-Scout is the tier-3 cross-provider
  failover behind two Gemini tiers. Replace or remove that tier.
- snacks4sale: Groq Llama-4-Scout is the only provider. Must move to a vision
  provider. TypeScript, handled in its own client.

### Wave 2 — text, by 2026-08-16 (the library)
Replace `llama-3.3-70b-versatile` with `openai/gpt-oss-120b` via the library.

Per-app handling:
- campaign_forge, site_forge: today call SeoKit-style Groq providers — migrate to
  the library client; model comes from the registry.
- seo_kit: converged as above; its Groq provider becomes a thin delegate.
- lead_intelligence, marketing_research: their Groq client's chat path moves to
  the library; the model comes from the registry. marketing_research's
  `groq/compound` search path is untouched (not deprecated).
- church_voter_guides: its chat transport moves to the library; the
  JSON-from-markdown parsing and retry logic stay in the app.
- hunter_dev: the consultant and voice paths source their model from the registry.
  Their JSON-schema validation, retry-with-feedback, and the latency-sensitive
  voice pipeline stay in the app. (Voice may later be pointed at the fast role via
  env if latency needs it — no redeploy required.)
- contacts4us OCR Groq tier: only the model id is sourced from the registry; the
  fallback-chain orchestration is untouched. (Superseded by Wave 1 if that tier
  is removed.)

Non-production references (scripts/tests in seo_kit and contacts4us) are updated
opportunistically, not on the critical path.

## Acceptance criteria

- The library compiles, has tests (including the injected-HTTP-client seam), and
  publishes a uniform chat contract for all six providers.
- Changing a role's model in one place (library default or env var) changes the
  model used by every consuming app.
- SeoKit's public LLM/Audit/Visibility behaviour is unchanged; its tests pass
  with the provider code removed and delegated to the library.
- No production code path references a deprecated model after rollout.
- Each consuming app compiles, its tests pass, and it is redeployed.

## Out of scope

- Vision-provider selection (tracked as open decisions, Wave 1).
- snacks4sale implementation details beyond "move off Groq vision".
- Any change to non-LLM SeoKit functionality.

## Open decisions (blocking Wave 1 only)

1. Text default model — confirmed `openai/gpt-oss-120b` unless changed.
2. contacts4us card-scanner failover tier — drop Groq (Gemini-only) vs. add a
   non-Groq vision provider for cross-vendor resilience.
3. snacks4sale vision provider — Gemini vs. OpenAI vs. Anthropic.
