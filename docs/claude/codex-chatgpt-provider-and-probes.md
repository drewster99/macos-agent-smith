# ChatGPT-subscription provider, effort/reasoning control, and model probes

_Split verbatim from `CLAUDE.md` (2026-10-07); `CLAUDE.md` keeps the binding summary and links here._

### The ChatGPT-subscription provider (`builtin.codex-chatgpt`, SwiftLLMKit 0.0.204)

A ChatGPT OAuth token reaches exactly one endpoint, `chatgpt.com/backend-api/codex/responses`, which speaks the **Responses** shape — so the kit routes this apiType to `CodexResponsesProvider`, not the chat/completions provider. Its credential is the `codex` CLI's `~/.codex/auth.json`, **never the Keychain**, and that has two consequences in this app:

- **Anything asking "can this provider be called?" or "what bearer lists its models?" asks the kit** — `providerHasCredential` / `modelListingCredential(for:)` — never the Keychain. The headless sweep used to gate on a Keychain key by hostname and skipped every subscription model as "no API key"; the in-app Probe Now seeded from the Keychain and silently probed everything.
- **Endpoint facts, verified live 2026-09-19:** `temperature`, `top_p` and `max_output_tokens` are rejected (`Unsupported parameter`), as is a `{role: system}` input item (`System messages are not allowed`) — so every system turn, including a trailing steering turn, folds into `instructions`, and `TrailingSystemTurnProbe` skips this apiType the way it skips Gemini (the nonce would echo from the top and fabricate a pass). Images (`input_image`), PDFs (`input_file`), `text.format` structured output, `developer` items and `parallel_tool_calls: false` are all accepted, and so is `prompt_cache_key`, which the provider sends per instance (one per role per conversation) because it measurably brings the prefix-cache hit forward by a turn. The Codex model decoder states `mustNeverSendTemperatureParam` for every model as a vendor fact; the provider still SENDS temperature when asked and not flagged, so a probe (which strips the flag) measures the real rejection instead of recording a silently dropped parameter as "accepted".

**Probe only what is new.** Two sweep modes exist so a prober change never forces a full re-probe of the ~1,600-record store: `--only-unprobed` drops every target that already has a reusable local record before a single call (no gap-filling, no age check — "new and nothing else"); `--reuse-store` seeds from the record and fills only its gaps. Reuse accepts any record from `ModelProber.oldestReusableProberVersion` up — a bump that changes the MEANING of measurements raises that constant, a bump that merely asks one more thing (v8 added `ultra`) does not — and a reused record is asked only the ladder levels its version knew and is stored again under that same version, so filling gaps never launders it and voids its ladder. The default reuse age window is 30 days; the store is mostly 30–60 days old, so pass `--reuse-max-age-days` deliberately.

**Forced probes must speak the dialect.** Every probe that bypasses production gating by forcing raw body keys (`extraJSONOverrides`) asks the kit for the spelling instead of hardcoding the chat/completions one: `ReasoningControl.reasoningEffortOverrides(level:for:)` (`reasoning.effort` here, `reasoning_effort` elsewhere), `reasoningDisableOverrides(for:)`, `LLMResponseFormat.forcedOverrides(for:)` (`text.format` vs `response_format`), `LLMToolChoice.wireValue(for:)` (flat `{type, name}`), and the strict-tools probe's flat tool shape. The first sweep after the serializer fix recorded "refused every reasoning mechanism" for every model because the effort candidate forced the chat/completions key at an endpoint that answers `Unsupported parameter: reasoning_effort`.

**The Codex listing's reasoning levels are a menu, not the accepted set.** The merge is gap-fill, provider payload first, so a decoded ladder would beat the probe's — and the listing is wrong in both directions: it omits `none` for gpt-5.5 (accepted) and declares `ultra` for gpt-6-astra (refused by name). The decoder therefore states NOTHING about the ladder — not even `.supportedLevelsUnknown`, which still occupies the field and blocks the gap-fill; the probe establishes it, `ultra` is in `EffortRank.table` so it gets asked (the complete-ladder gate is keyed on the WRITING prober's version, so older seven-level records keep projecting), and `ReasoningControl.effortOffFormPermitted` lets the probed `reasoningCanBeDisabled` decide whether `none` may be sent.

Before 0.0.197 the Codex serializer dropped images and documents entirely (the probe recorded `vision = false` with the evidence "I don't see an image attached") and ignored `extraJSONOverrides`, so every forced probe graded a bare request's success as support. Probe records for this provider written before then are wrong on vision, PDF, temperature, effort ladders, structured output and tool_choice; re-probe rather than trust them.

### Effort, reasoning control, and model capabilities (SwiftLLMKit 0.0.140)

The library separates two things that used to share the name "effort", and Agent Smith's UI has to say which:

- **General effort** (`ModelConfiguration.effort`) — Anthropic `output_config.effort`, applies even with reasoning off.
- **Reasoning effort** (`.reasoningEffort`) — `reasoning_effort`, reasoning models only.

`RoleModelConfigOverrideEditor` therefore has TWO effort rows. They are not interchangeable: a model may accept one and reject the other with HTTP 400. The asterisk on an off-ladder level comes from `EffortSupport.rejects`, which fails safe — an unknown ladder marks nothing rather than inventing a warning.

**Every model-override sheet must start from the existing `ModelMetadataOverride` and mutate only what it owns.** They used to rebuild it field-by-field from `existing?.x`, which silently dropped every field that sheet didn't know about — so a field added to the library was wiped by whichever editor the user opened next. Preserving by default fails safe; enumerating fails lossy. This applies to `CapabilitiesEditorSheet`, `BehaviorFlagsEditorSheet` and `PricingEditorSheet` alike.

**Anything added to `ModelMetadataOverride` needs a UI control**, or a wrong value is uncorrectable. Capabilities are free — `CapabilitiesEditorSheet` iterates `ModelCapability.allCases`. Typed non-boolean fields are not: `ReasoningControl` needed its own picker (in `BehaviorFlagsEditorSheet`, since both answer "how do I talk to this model"), with "Inherit" as a real selection distinct from every mechanism — it means no source has said, which is not "no reasoning control".

**`CapabilityEvalRunner` reports and probes the two ladders separately.** Its forced-`reasoning_effort` probe writes the reasoning ladder by construction; the general ladder is gated by `supportsUnconditionalGeneralEffortEmission` (true only for Anthropic), because a flag-gated endpoint silently drops the field and would turn "no error" into a recorded false positive.

## Model-probe conventions (from "Conventions specific to this repo")

### Local model metadata mapping

**Decided 2026-09-22 (user):** `ModelProvider.liteLLMProviderName == nil` continues to mean that the provider is unmapped. The literal mapping `LOCAL` is a distinct, intentional pseudo-provider for endpoints whose models are outside LiteLLM. Agent Smith offers `LOCAL` in the provider-mapping picker and renders it as a neutral local state: provider API facts and probe evidence still apply, but no LiteLLM limits, pricing, or capability metadata are expected. Do not collapse `LOCAL` back into `nil`, and do not add it to LiteLLM's downloaded metadata index as though it were upstream data.

### Standard and deep model probes

**Decided 2026-09-22 (user):** the Capabilities editor offers two explicit probe depths. Standard Probe keeps the inexpensive core battery. Deep Probe additionally runs every safe, applicable probe supported by SwiftLLMKit, including effort ladders, structured output, reasoning controls, tool-choice modes, strict tools, system messages, assistant prefill, parallel tools, and bounded thinking-budget searches. Deep Probe always runs the standard battery itself first; it must never require a separate prior Probe action or report that prerequisite as a user error. Deep Probe must remain an explicit action because it can make many paid model calls; adding a new empirically probeable capability means adding it to the deep battery. The Capabilities screen derives its Standard/Deep label from the persisted profile's probed evidence; do not create a parallel marker whose value can disagree with the probe record.
