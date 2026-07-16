# Model capability & limits audit

_Generated 2026-07-16 from the AgentSmith SwiftLLMKit workspace._

**Sources**
- **OURS** — `~/Library/Application Support/SwiftLLMKit/com.nuclearcyborg.AgentSmith/model_catalog.json` (the app's derived catalog; capability booleans + limits)
- **LiteLLM** — `.../litellm_metadata.json` (upstream `model_prices_and_context_window.json`, keyed per provider/region)
- **TRUTH** — authoritative where I can assert it: the Claude family from Anthropic's model docs, flagship GPT-5.x / Gemini-3.x from provider docs. `?` = **not independently verified** (don't trust it as ground truth — resolve manually).

Cap cells read **TRUTH / OURS / LiteLLM**. `—` in a LiteLLM cell = the model has no matching LiteLLM key at all. ⚠️ marks rows where **OURS disagrees with LiteLLM**.

## Discrepancy summary (OURS vs LiteLLM, matched models only)

- Parallel tool calling mismatches: **268**
- Vision mismatches: **112**
- Thinking/reasoning mismatches: **143**
- max-output-tokens mismatches: **63**
- max-context mismatches: **73**

## Table A — capabilities

### Alibaba Cloud  
`builtin.alibabacloud` — 87 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `deepseek-v4-flash` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | azure_ai/deepseek-v4-flash, deepseek-v4-flash, deepseek/deepseek-v4-flash, fireworks_ai/accounts/fireworks/models/deepseek-v4-flash, fireworks_ai/deepseek-v4-flash, libertai/deepseek-v4-flash, pinstripes/ps/deepseek-v4-flash, tencent/deepseek-v4-flash, tensormesh/deepseek-ai/DeepSeek-V4-Flash |
| `deepseek-v4-flash-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `deepseek-v4-pro` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | azure_ai/deepseek-v4-pro, deepseek-v4-pro, deepseek/deepseek-v4-pro, fireworks_ai/accounts/fireworks/models/deepseek-v4-pro, fireworks_ai/deepseek-v4-pro, tencent/deepseek-v4-pro |
| `deepseek-v4-pro-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `glm-5.1` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | openrouter/z-ai/glm-5.1, zai/glm-5.1 |
| `glm-5.2` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | cloudflare/@cf/zai-org/glm-5.2 |
| `glm-5.2-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `kimi-k2.5` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | azure_ai/kimi-k2.5, baseten/moonshotai/Kimi-K2.5, moonshot/kimi-k2.5, openrouter/moonshotai/kimi-k2.5, together_ai/moonshotai/Kimi-K2.5, wandb/moonshotai/Kimi-K2.5 |
| `kimi-k2.7-code` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | cloudflare/@cf/moonshotai/kimi-k2.7-code |
| `pre-qwen-mt-lite` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `pre-zhongyun-test-chat` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen-flash` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen-flash |
| `qwen-flash-2025-07-28` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen-flash-2025-07-28 |
| `qwen-flash-2025-07-28-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen-flash-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen-mt-flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen-mt-lite` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen-mt-plus` | ?/N/N | ?/N/N | ?/N/N |  | novita/qwen/qwen-mt-plus |
| `qwen-plus` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen-plus |
| `qwen-plus-2025-07-28` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen-plus-2025-07-28 |
| `qwen-plus-2025-09-11` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen-plus-2025-09-11 |
| `qwen-plus-2025-12-01` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen-plus-2025-12-01-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen-plus-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen-vl-ocr` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen-vl-ocr-2025-11-20` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-14b` | ?/N/N | ?/N/N | ?/N/N |  | deepinfra/Qwen/Qwen3-14B, fireworks_ai/accounts/fireworks/models/qwen3-14b, nebius/Qwen/Qwen3-14B |
| `qwen3-235b-a22b` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | deepinfra/Qwen/Qwen3-235B-A22B, fireworks_ai/accounts/fireworks/models/qwen3-235b-a22b, hyperbolic/Qwen/Qwen3-235B-A22B, nebius/Qwen/Qwen3-235B-A22B |
| `qwen3-235b-a22b-instruct-2507` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | crusoe/Qwen/Qwen3-235B-A22B-Instruct-2507, deepinfra/Qwen/Qwen3-235B-A22B-Instruct-2507, fireworks_ai/accounts/fireworks/models/qwen3-235b-a22b-instruct-2507, novita/qwen/qwen3-235b-a22b-instruct-2507, replicate/qwen/qwen3-235b-a22b-instruct-2507, scaleway/qwen/qwen3-235b-a22b-instruct-2507, wandb/Qwen/Qwen3-235B-A22B-Instruct-2507 |
| `qwen3-235b-a22b-thinking-2507` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | deepinfra/Qwen/Qwen3-235B-A22B-Thinking-2507, fireworks_ai/accounts/fireworks/models/qwen3-235b-a22b-thinking-2507, novita/qwen/qwen3-235b-a22b-thinking-2507, openrouter/qwen/qwen3-235b-a22b-thinking-2507, together_ai/Qwen/Qwen3-235B-A22B-Thinking-2507, wandb/Qwen/Qwen3-235B-A22B-Thinking-2507 |
| `qwen3-30b-a3b` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen3-30b-a3b, deepinfra/Qwen/Qwen3-30B-A3B, fireworks_ai/accounts/fireworks/models/qwen3-30b-a3b, nebius/Qwen/Qwen3-30B-A3B, pinstripes/ps/qwen3-30b-a3b |
| `qwen3-30b-a3b-instruct-2507` | ?/N/N | ?/N/N | ?/N/N |  | fireworks_ai/accounts/fireworks/models/qwen3-30b-a3b-instruct-2507 |
| `qwen3-30b-a3b-thinking-2507` | ?/N/N | ?/N/N | ?/N/N |  | fireworks_ai/accounts/fireworks/models/qwen3-30b-a3b-thinking-2507 |
| `qwen3-32b` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | deepinfra/Qwen/Qwen3-32B, fireworks_ai/accounts/fireworks/models/qwen3-32b, groq/qwen/qwen3-32b, nebius/Qwen/Qwen3-32B, ovhcloud/Qwen3-32B, sambanova/Qwen3-32B |
| `qwen3-8b` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | fireworks_ai/accounts/fireworks/models/qwen3-8b, llamagate/qwen3-8b |
| `qwen3-asr-flash-2025-09-08-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-asr-flash-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-coder-30b-a3b-instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | fireworks_ai/accounts/fireworks/models/qwen3-coder-30b-a3b-instruct, novita/qwen/qwen3-coder-30b-a3b-instruct, scaleway/qwen/qwen3-coder-30b-a3b-instruct |
| `qwen3-coder-480b-a35b-instruct` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct, fireworks_ai/accounts/fireworks/models/qwen3-coder-480b-a35b-instruct, novita/qwen/qwen3-coder-480b-a35b-instruct, wandb/Qwen/Qwen3-Coder-480B-A35B-Instruct |
| `qwen3-coder-flash` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen3-coder-flash |
| `qwen3-coder-flash-2025-07-28` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen3-coder-flash-2025-07-28 |
| `qwen3-coder-plus` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen3-coder-plus, openrouter/qwen/qwen3-coder-plus |
| `qwen3-coder-plus-2025-07-22` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen3-coder-plus-2025-07-22 |
| `qwen3-coder-plus-2025-09-23` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-max` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | dashscope/qwen3-max, novita/qwen/qwen3-max |
| `qwen3-max-2025-09-23` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-max-preview` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen3-max-preview |
| `qwen3-next-80b-a3b-instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | dashscope/qwen3-next-80b-a3b-instruct, deepinfra/Qwen/Qwen3-Next-80B-A3B-Instruct, fireworks_ai/accounts/fireworks/models/qwen3-next-80b-a3b-instruct, novita/qwen/qwen3-next-80b-a3b-instruct, together_ai/Qwen/Qwen3-Next-80B-A3B-Instruct |
| `qwen3-next-80b-a3b-thinking` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | dashscope/qwen3-next-80b-a3b-thinking, deepinfra/Qwen/Qwen3-Next-80B-A3B-Thinking, fireworks_ai/accounts/fireworks/models/qwen3-next-80b-a3b-thinking, novita/qwen/qwen3-next-80b-a3b-thinking, together_ai/Qwen/Qwen3-Next-80B-A3B-Thinking |
| `qwen3-vl-235b-a22b-instruct` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | dashscope/qwen3-vl-235b-a22b-instruct, fireworks_ai/accounts/fireworks/models/qwen3-vl-235b-a22b-instruct, novita/qwen/qwen3-vl-235b-a22b-instruct |
| `qwen3-vl-235b-a22b-thinking` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | dashscope/qwen3-vl-235b-a22b-thinking, fireworks_ai/accounts/fireworks/models/qwen3-vl-235b-a22b-thinking, novita/qwen/qwen3-vl-235b-a22b-thinking |
| `qwen3-vl-30b-a3b-instruct` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | fireworks_ai/accounts/fireworks/models/qwen3-vl-30b-a3b-instruct, novita/qwen/qwen3-vl-30b-a3b-instruct |
| `qwen3-vl-30b-a3b-thinking` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | fireworks_ai/accounts/fireworks/models/qwen3-vl-30b-a3b-thinking, novita/qwen/qwen3-vl-30b-a3b-thinking |
| `qwen3-vl-32b-instruct` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | dashscope/qwen3-vl-32b-instruct, fireworks_ai/accounts/fireworks/models/qwen3-vl-32b-instruct |
| `qwen3-vl-32b-thinking` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | dashscope/qwen3-vl-32b-thinking |
| `qwen3-vl-8b-instruct` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | fireworks_ai/accounts/fireworks/models/qwen3-vl-8b-instruct, novita/qwen/qwen3-vl-8b-instruct |
| `qwen3-vl-8b-thinking` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-vl-flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-vl-flash-2025-10-15` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-vl-flash-2025-10-15-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-vl-flash-2026-01-22-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-vl-flash-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-vl-plus` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | dashscope/qwen3-vl-plus |
| `qwen3-vl-plus-2025-09-23` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-vl-plus-2025-12-19` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-vl-plus-2025-12-19-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.5-122b-a10b` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | libertai/qwen3.5-122b-a10b, openrouter/qwen/qwen3.5-122b-a10b |
| `qwen3.5-27b` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | openrouter/qwen/qwen3.5-27b |
| `qwen3.5-35b-a3b` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | openrouter/qwen/qwen3.5-35b-a3b |
| `qwen3.5-397b-a17b` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | openrouter/qwen/qwen3.5-397b-a17b, scaleway/qwen/qwen3.5-397b-a17b, together_ai/Qwen/Qwen3.5-397B-A17B |
| `qwen3.5-flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.5-flash-2026-02-23` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.5-plus` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | dashscope/qwen3.5-plus |
| `qwen3.6-35b-a3b` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | libertai/qwen3.6-35b-a3b, pinstripes/ps/qwen3.6-35b-a3b, scaleway/qwen/qwen3.6-35b-a3b |
| `qwen3.6-flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.6-flash-2026-04-16` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.6-flash-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.6-plus-2026-04-02` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.7-max` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.7-max-2026-05-20` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.7-max-2026-06-08` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.7-max-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.7-plus` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.7-plus-2026-05-26` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.7-plus-us` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `wan2.6-image` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `wan2.6-t2i` | ?/N/— | ?/N/— | ?/N/— |  | — |

### Anthropic  
`builtin.anthropic` — 10 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `claude-fable-5` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | anthropic.claude-fable-5, azure_ai/claude-fable-5, claude-fable-5, eu.anthropic.claude-fable-5, global.anthropic.claude-fable-5, us.anthropic.claude-fable-5, vertex_ai/claude-fable-5, vertex_ai/claude-fable-5@default |
| `claude-haiku-4-5-20251001` | Y/N/N | Y/Y/Y | Y/Y/Y |  | claude-haiku-4-5-20251001 |
| `claude-opus-4-1-20250805` | Y/N/N | Y/Y/Y | Y/Y/Y |  | claude-opus-4-1-20250805 |
| `claude-opus-4-5-20251101` | Y/N/N | Y/Y/Y | Y/Y/Y |  | claude-opus-4-5-20251101 |
| `claude-opus-4-6` | Y/N/N | Y/Y/Y | Y/Y/Y |  | azure_ai/claude-opus-4-6, claude-opus-4-6, perplexity/anthropic/claude-opus-4-6, vertex_ai/claude-opus-4-6, vertex_ai/claude-opus-4-6@default |
| `claude-opus-4-7` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | anthropic.claude-opus-4-7, au.anthropic.claude-opus-4-7, azure_ai/claude-opus-4-7, claude-opus-4-7, eu.anthropic.claude-opus-4-7, global.anthropic.claude-opus-4-7, jp.anthropic.claude-opus-4-7, perplexity/anthropic/claude-opus-4-7, us.anthropic.claude-opus-4-7, vertex_ai/claude-opus-4-7, vertex_ai/claude-opus-4-7@default |
| `claude-opus-4-8` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | anthropic.claude-opus-4-8, au.anthropic.claude-opus-4-8, azure_ai/claude-opus-4-8, claude-opus-4-8, eu.anthropic.claude-opus-4-8, global.anthropic.claude-opus-4-8, jp.anthropic.claude-opus-4-8, us.anthropic.claude-opus-4-8, vertex_ai/claude-opus-4-8, vertex_ai/claude-opus-4-8@default |
| `claude-sonnet-4-5-20250929` | Y/N/N | Y/Y/Y | Y/Y/Y |  | claude-sonnet-4-5-20250929 |
| `claude-sonnet-4-6` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | anthropic.claude-sonnet-4-6, au.anthropic.claude-sonnet-4-6, azure_ai/claude-sonnet-4-6, claude-sonnet-4-6, eu.anthropic.claude-sonnet-4-6, global.anthropic.claude-sonnet-4-6, jp.anthropic.claude-sonnet-4-6, snowflake/claude-sonnet-4-6, us.anthropic.claude-sonnet-4-6, vertex_ai/claude-sonnet-4-6, vertex_ai/claude-sonnet-4-6@default |
| `claude-sonnet-5` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | anthropic.claude-sonnet-5, au.anthropic.claude-sonnet-5, azure_ai/claude-sonnet-5, claude-sonnet-5, eu.anthropic.claude-sonnet-5, global.anthropic.claude-sonnet-5, jp.anthropic.claude-sonnet-5, us.anthropic.claude-sonnet-5, vertex_ai/claude-sonnet-5, vertex_ai/claude-sonnet-5@default |

### Gemini  
`builtin.gemini` — 54 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `antigravity-preview-05-2026` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `aqa` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `deep-research-max-preview-04-2026` | ?/N/— | ?/N/— | ?/Y/— |  | — |
| `deep-research-preview-04-2026` | ?/N/— | ?/N/— | ?/Y/— |  | — |
| `deep-research-pro-preview-12-2025` | ?/N/N | ?/Y/Y | ?/Y/N | ⚠️ think | deep-research-pro-preview-12-2025, gemini/deep-research-pro-preview-12-2025, vertex_ai/deep-research-pro-preview-12-2025 |
| `gemini-2.0-flash` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | gemini-2.0-flash, gemini/gemini-2.0-flash, vercel_ai_gateway/google/gemini-2.0-flash |
| `gemini-2.0-flash-001` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | deepinfra/google/gemini-2.0-flash-001, gemini-2.0-flash-001, gemini/gemini-2.0-flash-001, openrouter/google/gemini-2.0-flash-001 |
| `gemini-2.0-flash-lite` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | gemini-2.0-flash-lite, gemini/gemini-2.0-flash-lite, vercel_ai_gateway/google/gemini-2.0-flash-lite |
| `gemini-2.0-flash-lite-001` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | gemini-2.0-flash-lite-001, gemini/gemini-2.0-flash-lite-001 |
| `gemini-2.5-computer-use-preview-10-2025` | ?/N/N | ?/Y/Y | ?/Y/N | ⚠️ think | gemini-2.5-computer-use-preview-10-2025, gemini/gemini-2.5-computer-use-preview-10-2025 |
| `gemini-2.5-flash` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | deepinfra/google/gemini-2.5-flash, gemini-2.5-flash, gemini/gemini-2.5-flash, oci/google.gemini-2.5-flash, openrouter/google/gemini-2.5-flash, perplexity/google/gemini-2.5-flash, replicate/google/gemini-2.5-flash, vercel_ai_gateway/google/gemini-2.5-flash |
| `gemini-2.5-flash-image` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | gemini-2.5-flash-image, gemini/gemini-2.5-flash-image, vertex_ai/gemini-2.5-flash-image |
| `gemini-2.5-flash-lite` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | gemini-2.5-flash-lite, gemini/gemini-2.5-flash-lite, oci/google.gemini-2.5-flash-lite |
| `gemini-2.5-flash-native-audio-latest` | ?/N/N | ?/N/N | ?/Y/N | ⚠️ think | gemini-2.5-flash-native-audio-latest, gemini/gemini-2.5-flash-native-audio-latest |
| `gemini-2.5-flash-native-audio-preview-09-2025` | ?/N/N | ?/N/N | ?/Y/N | ⚠️ think | gemini-2.5-flash-native-audio-preview-09-2025, gemini/gemini-2.5-flash-native-audio-preview-09-2025 |
| `gemini-2.5-flash-native-audio-preview-12-2025` | ?/N/N | ?/N/N | ?/Y/N | ⚠️ think | gemini-2.5-flash-native-audio-preview-12-2025, gemini/gemini-2.5-flash-native-audio-preview-12-2025 |
| `gemini-2.5-flash-preview-tts` | ?/N/N | ?/N/N | ?/N/N |  | gemini-2.5-flash-preview-tts, gemini/gemini-2.5-flash-preview-tts |
| `gemini-2.5-pro` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | deepinfra/google/gemini-2.5-pro, gemini-2.5-pro, gemini/gemini-2.5-pro, github_copilot/gemini-2.5-pro, oci/google.gemini-2.5-pro, openrouter/google/gemini-2.5-pro, perplexity/google/gemini-2.5-pro, vercel_ai_gateway/google/gemini-2.5-pro |
| `gemini-2.5-pro-preview-tts` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | gemini-2.5-pro-preview-tts, gemini/gemini-2.5-pro-preview-tts |
| `gemini-3-flash-preview` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | gemini-3-flash-preview, gemini/gemini-3-flash-preview, gmi/google/gemini-3-flash-preview, openrouter/google/gemini-3-flash-preview, perplexity/google/gemini-3-flash-preview, vertex_ai/gemini-3-flash-preview |
| `gemini-3-pro-image` | ?/N/N | ?/Y/Y | ?/Y/N | ⚠️ think | gemini-3-pro-image, gemini/gemini-3-pro-image, vertex_ai/gemini-3-pro-image |
| `gemini-3-pro-image-preview` | ?/N/N | ?/Y/Y | ?/Y/N | ⚠️ think | gemini-3-pro-image-preview, gemini/gemini-3-pro-image-preview, vertex_ai/gemini-3-pro-image-preview |
| `gemini-3-pro-preview` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | gemini-3-pro-preview, gemini/gemini-3-pro-preview, github_copilot/gemini-3-pro-preview, gmi/google/gemini-3-pro-preview, openrouter/google/gemini-3-pro-preview, perplexity/google/gemini-3-pro-preview, vertex_ai/gemini-3-pro-preview |
| `gemini-3.1-flash-image` | ?/N/N | ?/Y/Y | ?/Y/N | ⚠️ think | gemini-3.1-flash-image, gemini/gemini-3.1-flash-image, vertex_ai/gemini-3.1-flash-image |
| `gemini-3.1-flash-image-preview` | ?/N/N | ?/Y/Y | ?/Y/N | ⚠️ think | gemini-3.1-flash-image-preview, gemini/gemini-3.1-flash-image-preview, vertex_ai/gemini-3.1-flash-image-preview |
| `gemini-3.1-flash-lite` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | gemini-3.1-flash-lite, gemini/gemini-3.1-flash-lite, openrouter/google/gemini-3.1-flash-lite, vertex_ai/gemini-3.1-flash-lite |
| `gemini-3.1-flash-lite-image` | ?/N/— | ?/N/— | ?/Y/— |  | — |
| `gemini-3.1-flash-lite-preview` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | gemini-3.1-flash-lite-preview, gemini/gemini-3.1-flash-lite-preview, openrouter/google/gemini-3.1-flash-lite-preview, vertex_ai/gemini-3.1-flash-lite-preview |
| `gemini-3.1-flash-live-preview` | ?/N/N | ?/Y/Y | ?/N/N |  | gemini-3.1-flash-live-preview, gemini/gemini-3.1-flash-live-preview |
| `gemini-3.1-flash-tts-preview` | ?/N/— | ?/N/— | ?/Y/— |  | — |
| `gemini-3.1-pro-preview` | Y/N/N | Y/Y/Y | Y/Y/Y |  | gemini-3.1-pro-preview, gemini/gemini-3.1-pro-preview, openrouter/google/gemini-3.1-pro-preview, vertex_ai/gemini-3.1-pro-preview |
| `gemini-3.1-pro-preview-customtools` | Y/N/N | Y/Y/Y | Y/Y/Y |  | gemini-3.1-pro-preview-customtools, gemini/gemini-3.1-pro-preview-customtools, vertex_ai/gemini-3.1-pro-preview-customtools |
| `gemini-3.5-flash` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | gemini-3.5-flash, gemini/gemini-3.5-flash, vertex_ai/gemini-3.5-flash |
| `gemini-3.5-live-translate-preview` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `gemini-embedding-001` | ?/N/N | ?/N/N | ?/N/N |  | gemini-embedding-001, gemini/gemini-embedding-001, vercel_ai_gateway/google/gemini-embedding-001 |
| `gemini-embedding-2` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | gemini-embedding-2, gemini/gemini-embedding-2, vertex_ai/gemini-embedding-2 |
| `gemini-embedding-2-preview` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | gemini-embedding-2-preview, gemini/gemini-embedding-2-preview, vertex_ai/gemini-embedding-2-preview |
| `gemini-flash-latest` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | gemini-flash-latest, gemini/gemini-flash-latest |
| `gemini-flash-lite-latest` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | gemini-flash-lite-latest, gemini/gemini-flash-lite-latest |
| `gemini-omni-flash-preview` | ?/N/N | ?/Y/Y | ?/Y/Y |  | gemini-omni-flash-preview, gemini/gemini-omni-flash-preview |
| `gemini-pro-latest` | ?/N/N | ?/Y/Y | ?/Y/Y |  | gemini-pro-latest, gemini/gemini-pro-latest |
| `gemini-robotics-er-1.5-preview` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | gemini-robotics-er-1.5-preview, gemini/gemini-robotics-er-1.5-preview |
| `gemini-robotics-er-1.6-preview` | ?/N/— | ?/N/— | ?/Y/— |  | — |
| `gemma-4-26b-a4b-it` | ?/N/N | ?/N/Y | ?/Y/Y | ⚠️ vis | cloudflare/@cf/google/gemma-4-26b-a4b-it, scaleway/google/gemma-4-26b-a4b-it |
| `gemma-4-31b-it` | ?/N/N | ?/N/Y | ?/Y/Y | ⚠️ vis | libertai/gemma-4-31b-it, sambanova/gemma-4-31B-it, tensormesh/google/gemma-4-31B-it |
| `imagen-4.0-fast-generate-001` | ?/N/N | ?/N/N | ?/N/N |  | gemini/imagen-4.0-fast-generate-001, vertex_ai/imagen-4.0-fast-generate-001 |
| `imagen-4.0-generate-001` | ?/N/N | ?/N/N | ?/N/N |  | gemini/imagen-4.0-generate-001, vertex_ai/imagen-4.0-generate-001 |
| `imagen-4.0-ultra-generate-001` | ?/N/N | ?/N/N | ?/N/N |  | aiml/google/imagen-4.0-ultra-generate-001, gemini/imagen-4.0-ultra-generate-001, vertex_ai/imagen-4.0-ultra-generate-001 |
| `lyria-3-clip-preview` | ?/N/N | ?/N/N | ?/N/N |  | gemini/lyria-3-clip-preview |
| `lyria-3-pro-preview` | ?/N/N | ?/N/N | ?/N/N |  | gemini/lyria-3-pro-preview |
| `nano-banana-pro-preview` | ?/N/— | ?/N/— | ?/Y/— |  | — |
| `veo-3.1-fast-generate-preview` | ?/N/N | ?/N/N | ?/N/N |  | gemini/veo-3.1-fast-generate-preview, vertex_ai/veo-3.1-fast-generate-preview |
| `veo-3.1-generate-preview` | ?/N/N | ?/N/N | ?/N/N |  | gemini/veo-3.1-generate-preview, vertex_ai/veo-3.1-generate-preview |
| `veo-3.1-lite-generate-preview` | ?/N/N | ?/N/N | ?/N/N |  | gemini/veo-3.1-lite-generate-preview |

### Hugging Face  
`builtin.huggingface` — 102 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `CohereLabs/aya-expanse-32b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `CohereLabs/aya-vision-32b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `CohereLabs/c4ai-command-a-03-2025` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `CohereLabs/c4ai-command-r-08-2024` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `CohereLabs/c4ai-command-r7b-12-2024` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `CohereLabs/c4ai-command-r7b-arabic-02-2025` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `CohereLabs/command-a-plus-05-2026-bf16` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `CohereLabs/command-a-plus-05-2026-fp8` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `CohereLabs/command-a-plus-05-2026-w4a4` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `CohereLabs/command-a-reasoning-08-2025` | ?/N/N | ?/N/N | ?/N/N |  | oci/cohere.command-a-reasoning-08-2025 |
| `CohereLabs/command-a-translate-08-2025` | ?/N/N | ?/N/N | ?/N/N |  | oci/cohere.command-a-translate-08-2025 |
| `CohereLabs/command-a-vision-07-2025` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | oci/cohere.command-a-vision-07-2025 |
| `CohereLabs/tiny-aya-earth` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `CohereLabs/tiny-aya-global` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `CohereLabs/tiny-aya-water` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `MiniMaxAI/MiniMax-M1-80k` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | fireworks_ai/accounts/fireworks/models/minimax-m1-80k, novita/minimaxai/minimax-m1-80k |
| `MiniMaxAI/MiniMax-M2` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | fireworks_ai/accounts/fireworks/models/minimax-m2, minimax/MiniMax-M2, novita/minimax/minimax-m2, openrouter/minimax/minimax-m2 |
| `MiniMaxAI/MiniMax-M2.1` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | gmi/MiniMaxAI/MiniMax-M2.1, minimax/MiniMax-M2.1, novita/minimax/minimax-m2.1, openrouter/minimax/minimax-m2.1 |
| `MiniMaxAI/MiniMax-M2.5` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | baseten/MiniMaxAI/MiniMax-M2.5, minimax/MiniMax-M2.5, openrouter/minimax/minimax-m2.5, tensormesh/MiniMaxAI/MiniMax-M2.5, wandb/MiniMaxAI/MiniMax-M2.5 |
| `MiniMaxAI/MiniMax-M2.7` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | pinstripes/ps/minimax-m2.7, sambanova/MiniMax-M2.7 |
| `MiniMaxAI/MiniMax-M3` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | fireworks_ai/accounts/fireworks/models/minimax-m3, fireworks_ai/minimax-m3, minimax/MiniMax-M3 |
| `Qwen/Qwen2.5-72B-Instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | deepinfra/Qwen/Qwen2.5-72B-Instruct, hyperbolic/Qwen/Qwen2.5-72B-Instruct, nebius/Qwen/Qwen2.5-72B-Instruct |
| `Qwen/Qwen2.5-7B-Instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | deepinfra/Qwen/Qwen2.5-7B-Instruct, novita/qwen/qwen2.5-7b-instruct |
| `Qwen/Qwen2.5-VL-72B-Instruct` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | nebius/Qwen/Qwen2.5-VL-72B-Instruct, novita/qwen/qwen2.5-vl-72b-instruct, ovhcloud/Qwen2.5-VL-72B-Instruct |
| `Qwen/Qwen3-14B` | ?/N/N | ?/N/N | ?/N/N |  | deepinfra/Qwen/Qwen3-14B, fireworks_ai/accounts/fireworks/models/qwen3-14b, nebius/Qwen/Qwen3-14B |
| `Qwen/Qwen3-235B-A22B` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | deepinfra/Qwen/Qwen3-235B-A22B, fireworks_ai/accounts/fireworks/models/qwen3-235b-a22b, hyperbolic/Qwen/Qwen3-235B-A22B, nebius/Qwen/Qwen3-235B-A22B |
| `Qwen/Qwen3-235B-A22B-Instruct-2507` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | crusoe/Qwen/Qwen3-235B-A22B-Instruct-2507, deepinfra/Qwen/Qwen3-235B-A22B-Instruct-2507, fireworks_ai/accounts/fireworks/models/qwen3-235b-a22b-instruct-2507, novita/qwen/qwen3-235b-a22b-instruct-2507, replicate/qwen/qwen3-235b-a22b-instruct-2507, scaleway/qwen/qwen3-235b-a22b-instruct-2507, wandb/Qwen/Qwen3-235B-A22B-Instruct-2507 |
| `Qwen/Qwen3-235B-A22B-Thinking-2507` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | deepinfra/Qwen/Qwen3-235B-A22B-Thinking-2507, fireworks_ai/accounts/fireworks/models/qwen3-235b-a22b-thinking-2507, novita/qwen/qwen3-235b-a22b-thinking-2507, openrouter/qwen/qwen3-235b-a22b-thinking-2507, together_ai/Qwen/Qwen3-235B-A22B-Thinking-2507, wandb/Qwen/Qwen3-235B-A22B-Thinking-2507 |
| `Qwen/Qwen3-32B` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | deepinfra/Qwen/Qwen3-32B, fireworks_ai/accounts/fireworks/models/qwen3-32b, groq/qwen/qwen3-32b, nebius/Qwen/Qwen3-32B, ovhcloud/Qwen3-32B, sambanova/Qwen3-32B |
| `Qwen/Qwen3-Coder-30B-A3B-Instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | fireworks_ai/accounts/fireworks/models/qwen3-coder-30b-a3b-instruct, novita/qwen/qwen3-coder-30b-a3b-instruct, scaleway/qwen/qwen3-coder-30b-a3b-instruct |
| `Qwen/Qwen3-Coder-480B-A35B-Instruct` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | deepinfra/Qwen/Qwen3-Coder-480B-A35B-Instruct, fireworks_ai/accounts/fireworks/models/qwen3-coder-480b-a35b-instruct, novita/qwen/qwen3-coder-480b-a35b-instruct, wandb/Qwen/Qwen3-Coder-480B-A35B-Instruct |
| `Qwen/Qwen3-Coder-Next` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `Qwen/Qwen3-Next-80B-A3B-Instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | dashscope/qwen3-next-80b-a3b-instruct, deepinfra/Qwen/Qwen3-Next-80B-A3B-Instruct, fireworks_ai/accounts/fireworks/models/qwen3-next-80b-a3b-instruct, novita/qwen/qwen3-next-80b-a3b-instruct, together_ai/Qwen/Qwen3-Next-80B-A3B-Instruct |
| `Qwen/Qwen3-VL-235B-A22B-Instruct` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | dashscope/qwen3-vl-235b-a22b-instruct, fireworks_ai/accounts/fireworks/models/qwen3-vl-235b-a22b-instruct, novita/qwen/qwen3-vl-235b-a22b-instruct |
| `Qwen/Qwen3-VL-235B-A22B-Thinking` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | dashscope/qwen3-vl-235b-a22b-thinking, fireworks_ai/accounts/fireworks/models/qwen3-vl-235b-a22b-thinking, novita/qwen/qwen3-vl-235b-a22b-thinking |
| `Qwen/Qwen3-VL-30B-A3B-Instruct` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | fireworks_ai/accounts/fireworks/models/qwen3-vl-30b-a3b-instruct, novita/qwen/qwen3-vl-30b-a3b-instruct |
| `Qwen/Qwen3.5-122B-A10B` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | libertai/qwen3.5-122b-a10b, openrouter/qwen/qwen3.5-122b-a10b |
| `Qwen/Qwen3.5-27B` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | openrouter/qwen/qwen3.5-27b |
| `Qwen/Qwen3.5-35B-A3B` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | openrouter/qwen/qwen3.5-35b-a3b |
| `Qwen/Qwen3.5-397B-A17B` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | openrouter/qwen/qwen3.5-397b-a17b, scaleway/qwen/qwen3.5-397b-a17b, together_ai/Qwen/Qwen3.5-397B-A17B |
| `Qwen/Qwen3.5-9B` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `Qwen/Qwen3.6-27B` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | libertai/qwen3.6-27b |
| `Qwen/Qwen3.6-35B-A3B` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | libertai/qwen3.6-35b-a3b, pinstripes/ps/qwen3.6-35b-a3b, scaleway/qwen/qwen3.6-35b-a3b |
| `Sao10K/L3-8B-Lunaris-v1` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `Sao10K/L3-8B-Stheno-v3.2` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | novita/Sao10K/L3-8B-Stheno-v3.2 |
| `XiaomiMiMo/MiMo-V2.5-Pro` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | openrouter/xiaomi/mimo-v2.5-pro |
| `alpindale/WizardLM-2-8x22B` | ?/N/N | ?/N/N | ?/N/N |  | deepinfra/microsoft/WizardLM-2-8x22B, novita/microsoft/wizardlm-2-8x22b |
| `baidu/ERNIE-4.5-VL-424B-A47B-Base-PT` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `deepcogito/cogito-671b-v2.1` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `deepcogito/cogito-671b-v2.1-FP8` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `deepreinforce-ai/Ornith-1.0-35B` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `deepreinforce-ai/Ornith-1.0-35B-FP8` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `deepseek-ai/DeepSeek-R1` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | azure_ai/deepseek-r1, deepinfra/deepseek-ai/DeepSeek-R1, deepseek/deepseek-r1, fireworks_ai/accounts/fireworks/models/deepseek-r1, hyperbolic/deepseek-ai/DeepSeek-R1, nebius/deepseek-ai/DeepSeek-R1, openrouter/deepseek/deepseek-r1, replicate/deepseek-ai/deepseek-r1, sambanova/DeepSeek-R1, snowflake/deepseek-r1, together_ai/deepseek-ai/DeepSeek-R1, vercel_ai_gateway/deepseek/deepseek-r1 |
| `deepseek-ai/DeepSeek-R1-0528` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | crusoe/deepseek-ai/DeepSeek-R1-0528, deepinfra/deepseek-ai/DeepSeek-R1-0528, fireworks_ai/accounts/fireworks/models/deepseek-r1-0528, hyperbolic/deepseek-ai/DeepSeek-R1-0528, lambda_ai/deepseek-r1-0528, nebius/deepseek-ai/DeepSeek-R1-0528, novita/deepseek/deepseek-r1-0528, openrouter/deepseek/deepseek-r1-0528, wandb/deepseek-ai/DeepSeek-R1-0528 |
| `deepseek-ai/DeepSeek-R1-Distill-Llama-70B` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | deepinfra/deepseek-ai/DeepSeek-R1-Distill-Llama-70B, fireworks_ai/accounts/fireworks/models/deepseek-r1-distill-llama-70b, gradient_ai/deepseek-r1-distill-llama-70b, nebius/deepseek-ai/DeepSeek-R1-Distill-Llama-70B, novita/deepseek/deepseek-r1-distill-llama-70b, nscale/deepseek-ai/DeepSeek-R1-Distill-Llama-70B, ovhcloud/DeepSeek-R1-Distill-Llama-70B, sambanova/DeepSeek-R1-Distill-Llama-70B, vercel_ai_gateway/deepseek/deepseek-r1-distill-llama-70b |
| `deepseek-ai/DeepSeek-V3` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | azure_ai/deepseek-v3, deepinfra/deepseek-ai/DeepSeek-V3, deepseek/deepseek-v3, fireworks_ai/accounts/fireworks/models/deepseek-v3, hyperbolic/deepseek-ai/DeepSeek-V3, nebius/deepseek-ai/DeepSeek-V3, replicate/deepseek-ai/deepseek-v3, together_ai/deepseek-ai/DeepSeek-V3, vercel_ai_gateway/deepseek/deepseek-v3 |
| `deepseek-ai/DeepSeek-V3-0324` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | azure_ai/deepseek-v3-0324, baseten/deepseek-ai/DeepSeek-V3-0324, crusoe/deepseek-ai/DeepSeek-V3-0324, deepinfra/deepseek-ai/DeepSeek-V3-0324, fireworks_ai/accounts/fireworks/models/deepseek-v3-0324, gmi/deepseek-ai/DeepSeek-V3-0324, hyperbolic/deepseek-ai/DeepSeek-V3-0324, lambda_ai/deepseek-v3-0324, nebius/deepseek-ai/DeepSeek-V3-0324, novita/deepseek/deepseek-v3-0324, sambanova/DeepSeek-V3-0324, wandb/deepseek-ai/DeepSeek-V3-0324 |
| `deepseek-ai/DeepSeek-V3.1` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | azure_ai/deepseek-v3.1, baseten/deepseek-ai/DeepSeek-V3.1, deepinfra/deepseek-ai/DeepSeek-V3.1, novita/deepseek/deepseek-v3.1, replicate/deepseek-ai/deepseek-v3.1, sambanova/DeepSeek-V3.1, together_ai/deepseek-ai/DeepSeek-V3.1, wandb/deepseek-ai/DeepSeek-V3.1 |
| `deepseek-ai/DeepSeek-V3.1-Terminus` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | deepinfra/deepseek-ai/DeepSeek-V3.1-Terminus, novita/deepseek/deepseek-v3.1-terminus |
| `deepseek-ai/DeepSeek-V3.2` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | azure_ai/deepseek-v3.2, deepseek/deepseek-v3.2, gmi/deepseek-ai/DeepSeek-V3.2, novita/deepseek/deepseek-v3.2, openrouter/deepseek/deepseek-v3.2, sambanova/DeepSeek-V3.2 |
| `deepseek-ai/DeepSeek-V3.2-Exp` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | novita/deepseek/deepseek-v3.2-exp, openrouter/deepseek/deepseek-v3.2-exp |
| `deepseek-ai/DeepSeek-V4-Flash` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | azure_ai/deepseek-v4-flash, deepseek-v4-flash, deepseek/deepseek-v4-flash, fireworks_ai/accounts/fireworks/models/deepseek-v4-flash, fireworks_ai/deepseek-v4-flash, libertai/deepseek-v4-flash, pinstripes/ps/deepseek-v4-flash, tencent/deepseek-v4-flash, tensormesh/deepseek-ai/DeepSeek-V4-Flash |
| `deepseek-ai/DeepSeek-V4-Pro` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | azure_ai/deepseek-v4-pro, deepseek-v4-pro, deepseek/deepseek-v4-pro, fireworks_ai/accounts/fireworks/models/deepseek-v4-pro, fireworks_ai/deepseek-v4-pro, tencent/deepseek-v4-pro |
| `google/gemma-3-12b-it` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | crusoe/google/gemma-3-12b-it, deepinfra/google/gemma-3-12b-it, google.gemma-3-12b-it, novita/google/gemma-3-12b-it |
| `google/gemma-3-27b-it` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | deepinfra/google/gemma-3-27b-it, fireworks_ai/accounts/fireworks/models/gemma-3-27b-it, gemini/gemma-3-27b-it, google.gemma-3-27b-it, nebius/google/gemma-3-27b-it, novita/google/gemma-3-27b-it, scaleway/google/gemma-3-27b-it |
| `google/gemma-3-4b-it` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | deepinfra/google/gemma-3-4b-it, google.gemma-3-4b-it |
| `google/gemma-3n-E4B-it` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `google/gemma-4-26B-A4B-it` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | cloudflare/@cf/google/gemma-4-26b-a4b-it, scaleway/google/gemma-4-26b-a4b-it |
| `google/gemma-4-31B-it` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | libertai/gemma-4-31b-it, sambanova/gemma-4-31B-it, tensormesh/google/gemma-4-31B-it |
| `inclusionAI/Ling-2.6-1T` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `meta-llama/Llama-3.1-8B-Instruct` | ?/N/N | ?/N/N | ?/N/N |  | novita/meta-llama/llama-3.1-8b-instruct, nscale/meta-llama/Llama-3.1-8B-Instruct, oci/meta.llama-3.1-8b-instruct, ovhcloud/Llama-3.1-8B-Instruct, perplexity/llama-3.1-8b-instruct, wandb/meta-llama/Llama-3.1-8B-Instruct |
| `meta-llama/Llama-3.3-70B-Instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | azure_ai/Llama-3.3-70B-Instruct, crusoe/meta-llama/Llama-3.3-70B-Instruct, deepinfra/meta-llama/Llama-3.3-70B-Instruct, hyperbolic/meta-llama/Llama-3.3-70B-Instruct, meta_llama/Llama-3.3-70B-Instruct, nebius/meta-llama/Llama-3.3-70B-Instruct, novita/meta-llama/llama-3.3-70b-instruct, nscale/meta-llama/Llama-3.3-70B-Instruct, oci/meta.llama-3.3-70b-instruct, scaleway/meta/llama-3.3-70b-instruct, wandb/meta-llama/Llama-3.3-70B-Instruct |
| `meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | azure_ai/Llama-4-Maverick-17B-128E-Instruct-FP8, deepinfra/meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8, lambda_ai/llama-4-maverick-17b-128e-instruct-fp8, meta_llama/Llama-4-Maverick-17B-128E-Instruct-FP8, novita/meta-llama/llama-4-maverick-17b-128e-instruct-fp8, oci/meta.llama-4-maverick-17b-128e-instruct-fp8, together_ai/meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8 |
| `meta-llama/Llama-4-Scout-17B-16E-Instruct` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | azure_ai/Llama-4-Scout-17B-16E-Instruct, cloudflare/@cf/meta/llama-4-scout-17b-16e-instruct, deepinfra/meta-llama/Llama-4-Scout-17B-16E-Instruct, groq/meta-llama/llama-4-scout-17b-16e-instruct, lambda_ai/llama-4-scout-17b-16e-instruct, novita/meta-llama/llama-4-scout-17b-16e-instruct, nscale/meta-llama/Llama-4-Scout-17B-16E-Instruct, oci/meta.llama-4-scout-17b-16e-instruct, sambanova/Llama-4-Scout-17B-16E-Instruct, together_ai/meta-llama/Llama-4-Scout-17B-16E-Instruct, wandb/meta-llama/Llama-4-Scout-17B-16E-Instruct |
| `meta-llama/Llama-Guard-4-12B` | ?/N/N | ?/N/N | ?/N/N |  | deepinfra/meta-llama/Llama-Guard-4-12B, groq/meta-llama/llama-guard-4-12b |
| `microsoft/phi-4` | ?/N/N | ?/N/N | ?/N/N |  | azure_ai/Phi-4, deepinfra/microsoft/phi-4 |
| `moonshotai/Kimi-K2-Instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | deepinfra/moonshotai/Kimi-K2-Instruct, fireworks_ai/accounts/fireworks/models/kimi-k2-instruct, hyperbolic/moonshotai/Kimi-K2-Instruct, novita/moonshotai/kimi-k2-instruct, together_ai/moonshotai/Kimi-K2-Instruct, wandb/moonshotai/Kimi-K2-Instruct |
| `moonshotai/Kimi-K2-Instruct-0905` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | baseten/moonshotai/Kimi-K2-Instruct-0905, deepinfra/moonshotai/Kimi-K2-Instruct-0905, fireworks_ai/accounts/fireworks/models/kimi-k2-instruct-0905, groq/moonshotai/kimi-k2-instruct-0905, together_ai/moonshotai/Kimi-K2-Instruct-0905 |
| `moonshotai/Kimi-K2.5` | ?/N/N | ?/Y/Y | ?/Y/Y |  | azure_ai/kimi-k2.5, baseten/moonshotai/Kimi-K2.5, moonshot/kimi-k2.5, openrouter/moonshotai/kimi-k2.5, together_ai/moonshotai/Kimi-K2.5, wandb/moonshotai/Kimi-K2.5 |
| `moonshotai/Kimi-K2.6` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | azure_ai/kimi-k2.6, cloudflare/@cf/moonshotai/kimi-k2.6, moonshot/kimi-k2.6, tensormesh/moonshotai/Kimi-K2.6 |
| `moonshotai/Kimi-K2.7-Code` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | cloudflare/@cf/moonshotai/kimi-k2.7-code |
| `nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-BF16` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-NVFP4` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openai/gpt-oss-120b` | ?/N/Y | ?/N/Y | ?/Y/Y | ⚠️ par,vis | azure_ai/gpt-oss-120b, baseten/openai/gpt-oss-120b, bedrock_mantle/openai.gpt-oss-120b, cerebras/gpt-oss-120b, cloudflare/@cf/openai/gpt-oss-120b, crusoe/openai/gpt-oss-120b, deepinfra/openai/gpt-oss-120b, fireworks_ai/accounts/fireworks/models/gpt-oss-120b, fireworks_ai/gpt-oss-120b, groq/openai/gpt-oss-120b, novita/openai/gpt-oss-120b, openrouter/openai/gpt-oss-120b, ovhcloud/gpt-oss-120b, replicate/openai/gpt-oss-120b, sambanova/gpt-oss-120b, scaleway/openai/gpt-oss-120b, tensormesh/openai/gpt-oss-120b, together_ai/openai/gpt-oss-120b, wandb/openai/gpt-oss-120b, watsonx/openai/gpt-oss-120b |
| `openai/gpt-oss-20b` | ?/N/Y | ?/N/Y | ?/Y/Y | ⚠️ par,vis | bedrock_mantle/openai.gpt-oss-20b, cloudflare/@cf/openai/gpt-oss-20b, darkbloom/gpt-oss-20b, deepinfra/openai/gpt-oss-20b, fireworks_ai/accounts/fireworks/models/gpt-oss-20b, fireworks_ai/gpt-oss-20b, groq/openai/gpt-oss-20b, novita/openai/gpt-oss-20b, openrouter/openai/gpt-oss-20b, ovhcloud/gpt-oss-20b, replicateopenai/gpt-oss-20b, tensormesh/openai/gpt-oss-20b, together_ai/openai/gpt-oss-20b, wandb/openai/gpt-oss-20b |
| `openai/gpt-oss-safeguard-20b` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | bedrock_mantle/openai.gpt-oss-safeguard-20b, fireworks_ai/accounts/fireworks/models/gpt-oss-safeguard-20b, groq/openai/gpt-oss-safeguard-20b, openai.gpt-oss-safeguard-20b |
| `pearl-ai/Gemma-4-31B-it-pearl` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `prism-ml/Ternary-Bonsai-27B-gguf` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `stepfun-ai/Step-3.5-Flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `stepfun-ai/Step-3.7-Flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `zai-org/AutoGLM-Phone-9B-Multilingual` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | novita/zai-org/autoglm-phone-9b-multilingual |
| `zai-org/GLM-4-32B-0414` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `zai-org/GLM-4.5-Air` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | novita/zai-org/glm-4.5-air, pinstripes/ps/glm-4.5-air, vercel_ai_gateway/zai/glm-4.5-air, zai/glm-4.5-air |
| `zai-org/GLM-4.5V` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | novita/zai-org/glm-4.5v, zai/glm-4.5v |
| `zai-org/GLM-4.6` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | baseten/zai-org/GLM-4.6, novita/zai-org/glm-4.6, openrouter/z-ai/glm-4.6, together_ai/zai-org/GLM-4.6, vercel_ai_gateway/zai/glm-4.6, zai/glm-4.6 |
| `zai-org/GLM-4.6V-Flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `zai-org/GLM-4.7` | ?/N/Y | ?/N/Y | ?/Y/Y | ⚠️ par,vis | baseten/zai-org/GLM-4.7, novita/zai-org/glm-4.7, openrouter/z-ai/glm-4.7, together_ai/zai-org/GLM-4.7, zai/glm-4.7 |
| `zai-org/GLM-4.7-Flash` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | cloudflare/@cf/zai-org/glm-4.7-flash, openrouter/z-ai/glm-4.7-flash, zai/glm-4.7-flash |
| `zai-org/GLM-5` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | baseten/zai-org/GLM-5, openrouter/z-ai/glm-5, zai/glm-5 |
| `zai-org/GLM-5.1` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | openrouter/z-ai/glm-5.1, zai/glm-5.1 |
| `zai-org/GLM-5.1-FP8` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `zai-org/GLM-5.2` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | cloudflare/@cf/zai-org/glm-5.2 |

### LM Studio  
`builtin.lmstudio` — 2 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `qwen2.5-coder-7b-instruct-mlx` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `text-embedding-nomic-embed-text-v1.5` | ?/N/— | ?/N/— | ?/N/— |  | — |

### Mistral  
`builtin.mistral` — 60 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `codestral-2508` | ?/N/N | ?/N/N | ?/N/N |  | mistral/codestral-2508 |
| `codestral-embed` | ?/N/N | ?/N/N | ?/N/N |  | mistral/codestral-embed, vercel_ai_gateway/mistral/codestral-embed |
| `codestral-embed-2505` | ?/N/N | ?/N/N | ?/N/N |  | mistral/codestral-embed-2505 |
| `codestral-latest` | ?/N/N | ?/N/N | ?/N/N |  | codestral/codestral-latest, mistral/codestral-latest, text-completion-codestral/codestral-latest |
| `devstral-2512` | ?/N/N | ?/N/N | ?/N/N |  | mistral/devstral-2512, openrouter/mistralai/devstral-2512 |
| `devstral-latest` | ?/N/N | ?/N/N | ?/N/N |  | mistral/devstral-latest |
| `devstral-medium-latest` | ?/N/N | ?/N/N | ?/N/N |  | mistral/devstral-medium-latest |
| `labs-leanstral-1-5` | ?/N/— | ?/Y/— | ?/Y/— |  | — |
| `labs-leanstral-1-5-1` | ?/N/— | ?/Y/— | ?/Y/— |  | — |
| `magistral-medium-2509` | ?/N/N | ?/Y/N | ?/Y/Y | ⚠️ vis | mistral/magistral-medium-2509 |
| `magistral-medium-latest` | ?/N/N | ?/Y/N | ?/Y/Y | ⚠️ vis | mistral/magistral-medium-latest |
| `magistral-small-2509` | ?/N/N | ?/Y/N | ?/Y/Y | ⚠️ vis | mistral.magistral-small-2509 |
| `magistral-small-latest` | ?/N/N | ?/Y/N | ?/Y/Y | ⚠️ vis | mistral/magistral-small-latest |
| `ministral-14b-2512` | ?/N/N | ?/Y/Y | ?/N/N |  | openrouter/mistralai/ministral-14b-2512 |
| `ministral-14b-latest` | ?/N/— | ?/Y/— | ?/N/— |  | — |
| `ministral-3b-2512` | ?/N/N | ?/Y/Y | ?/N/N |  | openrouter/mistralai/ministral-3b-2512 |
| `ministral-3b-latest` | ?/N/— | ?/Y/— | ?/N/— |  | — |
| `ministral-8b-2512` | ?/N/N | ?/Y/Y | ?/N/N |  | mistral/ministral-8b-2512, openrouter/mistralai/ministral-8b-2512 |
| `ministral-8b-latest` | ?/N/N | ?/Y/Y | ?/N/N |  | mistral/ministral-8b-latest |
| `mistral-code-agent-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mistral-code-fim-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mistral-code-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mistral-embed` | ?/N/N | ?/N/N | ?/N/N |  | mistral/mistral-embed, vercel_ai_gateway/mistral/mistral-embed |
| `mistral-embed-2312` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mistral-large-2512` | ?/N/N | ?/Y/Y | ?/N/N |  | mistral/mistral-large-2512, openrouter/mistralai/mistral-large-2512 |
| `mistral-large-latest` | ?/N/N | ?/Y/Y | ?/N/N |  | azure/mistral-large-latest, azure_ai/mistral-large-latest, mistral/mistral-large-latest |
| `mistral-medium` | ?/N/N | ?/Y/N | ?/Y/N | ⚠️ vis,think | mistral/mistral-medium |
| `mistral-medium-2505` | ?/N/Y | ?/Y/N | ?/N/N | ⚠️ par,vis | azure_ai/mistral-medium-2505, mistral/mistral-medium-2505, watsonx/mistralai/mistral-medium-2505 |
| `mistral-medium-2508` | ?/N/N | ?/Y/Y | ?/N/N |  | mistral/mistral-medium-2508 |
| `mistral-medium-2604` | ?/N/N | ?/Y/Y | ?/Y/Y |  | mistral/mistral-medium-2604 |
| `mistral-medium-3` | ?/N/N | ?/Y/N | ?/Y/N | ⚠️ vis,think | vertex_ai/mistral-medium-3, vertex_ai/mistral-medium-3@001, vertex_ai/mistralai/mistral-medium-3, vertex_ai/mistralai/mistral-medium-3@001 |
| `mistral-medium-3-5` | ?/N/N | ?/Y/Y | ?/Y/Y |  | mistral/mistral-medium-3-5 |
| `mistral-medium-3.5` | ?/N/— | ?/Y/— | ?/Y/— |  | — |
| `mistral-medium-latest` | ?/N/N | ?/Y/Y | ?/Y/Y |  | mistral/mistral-medium-latest |
| `mistral-moderation-2603` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mistral-ocr-2512` | ?/N/N | ?/Y/N | ?/N/N | ⚠️ vis | mistral/mistral-ocr-2512 |
| `mistral-ocr-3` | ?/N/— | ?/Y/— | ?/N/— |  | — |
| `mistral-ocr-3-0` | ?/N/— | ?/Y/— | ?/N/— |  | — |
| `mistral-ocr-4` | ?/N/— | ?/Y/— | ?/N/— |  | — |
| `mistral-ocr-4-0` | ?/N/N | ?/Y/N | ?/N/N | ⚠️ vis | mistral/mistral-ocr-4-0 |
| `mistral-ocr-latest` | ?/N/N | ?/Y/N | ?/N/N | ⚠️ vis | mistral/mistral-ocr-latest |
| `mistral-small-2506` | ?/N/— | ?/Y/— | ?/N/— |  | — |
| `mistral-small-2603` | ?/N/— | ?/Y/— | ?/Y/— |  | — |
| `mistral-small-latest` | ?/N/N | ?/Y/Y | ?/Y/N | ⚠️ think | mistral/mistral-small-latest |
| `mistral-tiny-2407` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mistral-tiny-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mistral-vibe-cli-fast` | ?/N/— | ?/Y/— | ?/Y/— |  | — |
| `mistral-vibe-cli-latest` | ?/N/— | ?/Y/— | ?/Y/— |  | — |
| `mistral-vibe-cli-with-tools` | ?/N/— | ?/Y/— | ?/Y/— |  | — |
| `open-mistral-nemo` | ?/N/N | ?/N/N | ?/N/N |  | mistral/open-mistral-nemo |
| `open-mistral-nemo-2407` | ?/N/N | ?/N/N | ?/N/N |  | mistral/open-mistral-nemo-2407 |
| `voxtral-mini-2602` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `voxtral-mini-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `voxtral-mini-realtime-2602` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `voxtral-mini-realtime-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `voxtral-mini-transcribe-realtime-2602` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `voxtral-mini-tts-2603` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `voxtral-mini-tts-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `voxtral-small-2507` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `voxtral-small-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |

### Ollama (local)  
`builtin.ollama` — 1 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `qwen2.5-coder:7b` | ?/N/— | ?/N/— | ?/N/— |  | — |

### Ollama (cloud)  
`builtin.ollama-cloud` — 34 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `deepseek-v3.1:671b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `deepseek-v3.2` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | azure_ai/deepseek-v3.2, deepseek/deepseek-v3.2, gmi/deepseek-ai/DeepSeek-V3.2, novita/deepseek/deepseek-v3.2, openrouter/deepseek/deepseek-v3.2, sambanova/DeepSeek-V3.2 |
| `deepseek-v4-flash` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | azure_ai/deepseek-v4-flash, deepseek-v4-flash, deepseek/deepseek-v4-flash, fireworks_ai/accounts/fireworks/models/deepseek-v4-flash, fireworks_ai/deepseek-v4-flash, libertai/deepseek-v4-flash, pinstripes/ps/deepseek-v4-flash, tencent/deepseek-v4-flash, tensormesh/deepseek-ai/DeepSeek-V4-Flash |
| `deepseek-v4-pro` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | azure_ai/deepseek-v4-pro, deepseek-v4-pro, deepseek/deepseek-v4-pro, fireworks_ai/accounts/fireworks/models/deepseek-v4-pro, fireworks_ai/deepseek-v4-pro, tencent/deepseek-v4-pro |
| `devstral-2:123b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `devstral-small-2:24b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `gemini-3-flash-preview` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | gemini-3-flash-preview, gemini/gemini-3-flash-preview, gmi/google/gemini-3-flash-preview, openrouter/google/gemini-3-flash-preview, perplexity/google/gemini-3-flash-preview, vertex_ai/gemini-3-flash-preview |
| `gemma3:12b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `gemma3:27b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `gemma3:4b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `gemma4:31b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `glm-4.7` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | baseten/zai-org/GLM-4.7, novita/zai-org/glm-4.7, openrouter/z-ai/glm-4.7, together_ai/zai-org/GLM-4.7, zai/glm-4.7 |
| `glm-5` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | baseten/zai-org/GLM-5, openrouter/z-ai/glm-5, zai/glm-5 |
| `glm-5.1` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | openrouter/z-ai/glm-5.1, zai/glm-5.1 |
| `glm-5.2` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | cloudflare/@cf/zai-org/glm-5.2 |
| `gpt-oss:120b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `gpt-oss:20b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `kimi-k2.5` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | azure_ai/kimi-k2.5, baseten/moonshotai/Kimi-K2.5, moonshot/kimi-k2.5, openrouter/moonshotai/kimi-k2.5, together_ai/moonshotai/Kimi-K2.5, wandb/moonshotai/Kimi-K2.5 |
| `kimi-k2.6` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | azure_ai/kimi-k2.6, cloudflare/@cf/moonshotai/kimi-k2.6, moonshot/kimi-k2.6, tensormesh/moonshotai/Kimi-K2.6 |
| `kimi-k2.7-code` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | cloudflare/@cf/moonshotai/kimi-k2.7-code |
| `minimax-m2.1` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | gmi/MiniMaxAI/MiniMax-M2.1, minimax/MiniMax-M2.1, novita/minimax/minimax-m2.1, openrouter/minimax/minimax-m2.1 |
| `minimax-m2.5` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | baseten/MiniMaxAI/MiniMax-M2.5, minimax/MiniMax-M2.5, openrouter/minimax/minimax-m2.5, tensormesh/MiniMaxAI/MiniMax-M2.5, wandb/MiniMaxAI/MiniMax-M2.5 |
| `minimax-m2.7` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | pinstripes/ps/minimax-m2.7, sambanova/MiniMax-M2.7 |
| `minimax-m3` | ?/N/N | ?/Y/Y | ?/Y/Y |  | fireworks_ai/accounts/fireworks/models/minimax-m3, fireworks_ai/minimax-m3, minimax/MiniMax-M3 |
| `ministral-3:14b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `ministral-3:3b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `ministral-3:8b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mistral-large-3:675b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nemotron-3-nano:30b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nemotron-3-super` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nemotron-3-ultra` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-coder-next` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3-coder:480b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen3.5:397b` | ?/N/— | ?/N/— | ?/N/— |  | — |

### OpenAI  
`builtin.openai` — 129 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `babbage-002` | ?/N/N | ?/N/N | ?/N/N |  | babbage-002 |
| `chat-latest` | ?/N/— | ?/Y/— | ?/Y/— |  | — |
| `chatgpt-image-latest` | ?/N/N | ?/N/N | ?/N/N |  | chatgpt-image-latest |
| `davinci-002` | ?/N/N | ?/N/N | ?/N/N |  | davinci-002 |
| `gpt-3.5-turbo` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-3.5-turbo, github_copilot/gpt-3.5-turbo, gpt-3.5-turbo, openrouter/openai/gpt-3.5-turbo, vercel_ai_gateway/openai/gpt-3.5-turbo |
| `gpt-3.5-turbo-0125` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | azure/gpt-3.5-turbo-0125, gpt-3.5-turbo-0125 |
| `gpt-3.5-turbo-1106` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-3.5-turbo-1106 |
| `gpt-3.5-turbo-16k` | ?/N/N | ?/N/N | ?/N/N |  | gpt-3.5-turbo-16k, openrouter/openai/gpt-3.5-turbo-16k |
| `gpt-3.5-turbo-instruct` | ?/N/N | ?/N/N | ?/N/N |  | gpt-3.5-turbo-instruct, vercel_ai_gateway/openai/gpt-3.5-turbo-instruct |
| `gpt-3.5-turbo-instruct-0914` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-3.5-turbo-instruct-0914, gpt-3.5-turbo-instruct-0914 |
| `gpt-4` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-4, github_copilot/gpt-4, gpt-4, openrouter/openai/gpt-4 |
| `gpt-4-0613` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-4-0613, github_copilot/gpt-4-0613, gpt-4-0613 |
| `gpt-4-turbo` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4-turbo, gpt-4-turbo, vercel_ai_gateway/openai/gpt-4-turbo |
| `gpt-4-turbo-2024-04-09` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4-turbo-2024-04-09, gpt-4-turbo-2024-04-09 |
| `gpt-4.1` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4.1, github_copilot/gpt-4.1, gpt-4.1, openrouter/openai/gpt-4.1, replicate/openai/gpt-4.1, vercel_ai_gateway/openai/gpt-4.1 |
| `gpt-4.1-2025-04-14` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4.1-2025-04-14, azure/us/gpt-4.1-2025-04-14, github_copilot/gpt-4.1-2025-04-14, gpt-4.1-2025-04-14 |
| `gpt-4.1-mini` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4.1-mini, gpt-4.1-mini, openrouter/openai/gpt-4.1-mini, replicate/openai/gpt-4.1-mini, vercel_ai_gateway/openai/gpt-4.1-mini |
| `gpt-4.1-mini-2025-04-14` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4.1-mini-2025-04-14, azure/us/gpt-4.1-mini-2025-04-14, gpt-4.1-mini-2025-04-14 |
| `gpt-4.1-nano` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4.1-nano, gpt-4.1-nano, openrouter/openai/gpt-4.1-nano, replicate/openai/gpt-4.1-nano, vercel_ai_gateway/openai/gpt-4.1-nano |
| `gpt-4.1-nano-2025-04-14` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4.1-nano-2025-04-14, azure/us/gpt-4.1-nano-2025-04-14, gpt-4.1-nano-2025-04-14 |
| `gpt-4o` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4o, github_copilot/gpt-4o, gmi/openai/gpt-4o, gpt-4o, openrouter/openai/gpt-4o, replicate/openai/gpt-4o, vercel_ai_gateway/openai/gpt-4o |
| `gpt-4o-2024-05-13` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4o-2024-05-13, github_copilot/gpt-4o-2024-05-13, gpt-4o-2024-05-13, openrouter/openai/gpt-4o-2024-05-13 |
| `gpt-4o-2024-08-06` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/eu/gpt-4o-2024-08-06, azure/global-standard/gpt-4o-2024-08-06, azure/global/gpt-4o-2024-08-06, azure/gpt-4o-2024-08-06, azure/us/gpt-4o-2024-08-06, github_copilot/gpt-4o-2024-08-06, gpt-4o-2024-08-06 |
| `gpt-4o-2024-11-20` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/eu/gpt-4o-2024-11-20, azure/global-standard/gpt-4o-2024-11-20, azure/global/gpt-4o-2024-11-20, azure/gpt-4o-2024-11-20, azure/us/gpt-4o-2024-11-20, github_copilot/gpt-4o-2024-11-20, gpt-4o-2024-11-20 |
| `gpt-4o-mini` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/global-standard/gpt-4o-mini, azure/gpt-4o-mini, github_copilot/gpt-4o-mini, gmi/openai/gpt-4o-mini, gpt-4o-mini, replicate/openai/gpt-4o-mini, vercel_ai_gateway/openai/gpt-4o-mini |
| `gpt-4o-mini-2024-07-18` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/eu/gpt-4o-mini-2024-07-18, azure/gpt-4o-mini-2024-07-18, azure/us/gpt-4o-mini-2024-07-18, github_copilot/gpt-4o-mini-2024-07-18, gpt-4o-mini-2024-07-18 |
| `gpt-4o-mini-search-preview` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | gpt-4o-mini-search-preview |
| `gpt-4o-mini-search-preview-2025-03-11` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | gpt-4o-mini-search-preview-2025-03-11 |
| `gpt-4o-mini-transcribe` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-4o-mini-transcribe, gpt-4o-mini-transcribe |
| `gpt-4o-mini-transcribe-2025-03-20` | ?/N/N | ?/N/N | ?/N/N |  | gpt-4o-mini-transcribe-2025-03-20 |
| `gpt-4o-mini-transcribe-2025-12-15` | ?/N/N | ?/N/N | ?/N/N |  | gpt-4o-mini-transcribe-2025-12-15 |
| `gpt-4o-mini-tts` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-4o-mini-tts, gpt-4o-mini-tts |
| `gpt-4o-mini-tts-2025-03-20` | ?/N/N | ?/N/N | ?/N/N |  | gpt-4o-mini-tts-2025-03-20 |
| `gpt-4o-mini-tts-2025-12-15` | ?/N/N | ?/N/N | ?/N/N |  | gpt-4o-mini-tts-2025-12-15 |
| `gpt-4o-search-preview` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | gpt-4o-search-preview |
| `gpt-4o-search-preview-2025-03-11` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | gpt-4o-search-preview-2025-03-11 |
| `gpt-4o-transcribe` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-4o-transcribe, gpt-4o-transcribe |
| `gpt-4o-transcribe-diarize` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-4o-transcribe-diarize, gpt-4o-transcribe-diarize |
| `gpt-5` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5, github_copilot/gpt-5, gmi/openai/gpt-5, gpt-5, oci/openai.gpt-5, openrouter/openai/gpt-5, replicate/openai/gpt-5 |
| `gpt-5-2025-08-07` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5-2025-08-07, azure/gpt-5-2025-08-07, azure/us/gpt-5-2025-08-07, gpt-5-2025-08-07 |
| `gpt-5-chat-latest` | ?/N/Y | Y/Y/Y | N/Y/Y | ⚠️ par | azure/gpt-5-chat-latest, gpt-5-chat-latest |
| `gpt-5-codex` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5-codex, gpt-5-codex, openrouter/openai/gpt-5-codex |
| `gpt-5-mini` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5-mini, github_copilot/gpt-5-mini, gpt-5-mini, oci/openai.gpt-5-mini, openrouter/openai/gpt-5-mini, perplexity/openai/gpt-5-mini, replicate/openai/gpt-5-mini |
| `gpt-5-mini-2025-08-07` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5-mini-2025-08-07, azure/gpt-5-mini-2025-08-07, azure/us/gpt-5-mini-2025-08-07, gpt-5-mini-2025-08-07 |
| `gpt-5-nano` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5-nano, gpt-5-nano, oci/openai.gpt-5-nano, openrouter/openai/gpt-5-nano, replicate/openai/gpt-5-nano |
| `gpt-5-nano-2025-08-07` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5-nano-2025-08-07, azure/gpt-5-nano-2025-08-07, azure/us/gpt-5-nano-2025-08-07, gpt-5-nano-2025-08-07 |
| `gpt-5-pro` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5-pro, gpt-5-pro |
| `gpt-5-pro-2025-10-06` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | gpt-5-pro-2025-10-06 |
| `gpt-5-search-api` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | gpt-5-search-api |
| `gpt-5-search-api-2025-10-14` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | gpt-5-search-api-2025-10-14 |
| `gpt-5.1` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5.1, azure/global/gpt-5.1, azure/gpt-5.1, azure/us/gpt-5.1, github_copilot/gpt-5.1, gmi/openai/gpt-5.1, gpt-5.1, perplexity/openai/gpt-5.1 |
| `gpt-5.1-2025-11-13` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.1-2025-11-13, gpt-5.1-2025-11-13 |
| `gpt-5.1-chat-latest` | ?/N/N | Y/Y/Y | N/Y/Y |  | gpt-5.1-chat-latest |
| `gpt-5.1-codex` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5.1-codex, azure/global/gpt-5.1-codex, azure/gpt-5.1-codex, azure/us/gpt-5.1-codex, gpt-5.1-codex |
| `gpt-5.1-codex-max` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.1-codex-max, chatgpt/gpt-5.1-codex-max, github_copilot/gpt-5.1-codex-max, gpt-5.1-codex-max, openrouter/openai/gpt-5.1-codex-max |
| `gpt-5.1-codex-mini` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5.1-codex-mini, azure/global/gpt-5.1-codex-mini, azure/gpt-5.1-codex-mini, azure/us/gpt-5.1-codex-mini, chatgpt/gpt-5.1-codex-mini, gpt-5.1-codex-mini |
| `gpt-5.2` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.2, chatgpt/gpt-5.2, github_copilot/gpt-5.2, gmi/openai/gpt-5.2, gpt-5.2, openrouter/openai/gpt-5.2, perplexity/openai/gpt-5.2 |
| `gpt-5.2-2025-12-11` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.2-2025-12-11, gpt-5.2-2025-12-11 |
| `gpt-5.2-chat-latest` | ?/N/Y | Y/Y/Y | N/Y/Y | ⚠️ par | gpt-5.2-chat-latest |
| `gpt-5.2-codex` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.2-codex, chatgpt/gpt-5.2-codex, gpt-5.2-codex, openrouter/openai/gpt-5.2-codex |
| `gpt-5.2-pro` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.2-pro, gpt-5.2-pro, openrouter/openai/gpt-5.2-pro |
| `gpt-5.2-pro-2025-12-11` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.2-pro-2025-12-11, gpt-5.2-pro-2025-12-11 |
| `gpt-5.3-chat-latest` | ?/N/Y | Y/Y/Y | N/Y/Y | ⚠️ par | chatgpt/gpt-5.3-chat-latest, gpt-5.3-chat-latest |
| `gpt-5.3-codex` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.3-codex, chatgpt/gpt-5.3-codex, github_copilot/gpt-5.3-codex, gpt-5.3-codex |
| `gpt-5.4` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5.4, azure/gpt-5.4, azure/us/gpt-5.4, azure_ai/gpt-5.4, bedrock_mantle/openai.gpt-5.4, chatgpt/gpt-5.4, gpt-5.4 |
| `gpt-5.4-2026-03-05` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5.4-2026-03-05, azure/gpt-5.4-2026-03-05, azure/us/gpt-5.4-2026-03-05, azure_ai/gpt-5.4-2026-03-05, gpt-5.4-2026-03-05 |
| `gpt-5.4-mini` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.4-mini, azure_ai/gpt-5.4-mini, gpt-5.4-mini |
| `gpt-5.4-mini-2026-03-17` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.4-mini-2026-03-17, azure_ai/gpt-5.4-mini-2026-03-17, gpt-5.4-mini-2026-03-17 |
| `gpt-5.4-nano` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.4-nano, azure_ai/gpt-5.4-nano, gpt-5.4-nano |
| `gpt-5.4-nano-2026-03-17` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.4-nano-2026-03-17, azure_ai/gpt-5.4-nano-2026-03-17, gpt-5.4-nano-2026-03-17 |
| `gpt-5.4-pro` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.4-pro, azure_ai/gpt-5.4-pro, chatgpt/gpt-5.4-pro, gpt-5.4-pro |
| `gpt-5.4-pro-2026-03-05` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.4-pro-2026-03-05, azure_ai/gpt-5.4-pro-2026-03-05, gpt-5.4-pro-2026-03-05 |
| `gpt-5.5` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5.5, azure/gpt-5.5, azure/us/gpt-5.5, azure_ai/gpt-5.5, bedrock_mantle/openai.gpt-5.5, gpt-5.5 |
| `gpt-5.5-2026-04-23` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5.5-2026-04-23, azure/gpt-5.5-2026-04-23, azure/us/gpt-5.5-2026-04-23, azure_ai/gpt-5.5-2026-04-23, gpt-5.5-2026-04-23 |
| `gpt-5.5-pro` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.5-pro, gpt-5.5-pro |
| `gpt-5.5-pro-2026-04-23` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/gpt-5.5-pro-2026-04-23, gpt-5.5-pro-2026-04-23 |
| `gpt-5.6-luna` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5.6-luna, azure/gpt-5.6-luna, azure/us/gpt-5.6-luna, bedrock_mantle/openai.gpt-5.6-luna, gpt-5.6-luna |
| `gpt-5.6-sol` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5.6-sol, azure/gpt-5.6-sol, azure/us/gpt-5.6-sol, bedrock_mantle/openai.gpt-5.6-sol, gpt-5.6-sol |
| `gpt-5.6-terra` | Y/N/Y | Y/Y/Y | Y/Y/Y | ⚠️ par | azure/eu/gpt-5.6-terra, azure/gpt-5.6-terra, azure/us/gpt-5.6-terra, bedrock_mantle/openai.gpt-5.6-terra, gpt-5.6-terra |
| `gpt-audio` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-audio |
| `gpt-audio-1.5` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-audio-1.5 |
| `gpt-audio-2025-08-28` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | azure/gpt-audio-2025-08-28, gpt-audio-2025-08-28 |
| `gpt-audio-mini` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-audio-mini |
| `gpt-audio-mini-2025-10-06` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | azure/gpt-audio-mini-2025-10-06, gpt-audio-mini-2025-10-06 |
| `gpt-audio-mini-2025-12-15` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-audio-mini-2025-12-15 |
| `gpt-image-1` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-image-1, azure/high/1024-x-1024/gpt-image-1, azure/high/1024-x-1536/gpt-image-1, azure/high/1536-x-1024/gpt-image-1, azure/low/1024-x-1024/gpt-image-1, azure/low/1024-x-1536/gpt-image-1, azure/low/1536-x-1024/gpt-image-1, azure/medium/1024-x-1024/gpt-image-1, azure/medium/1024-x-1536/gpt-image-1, azure/medium/1536-x-1024/gpt-image-1, gpt-image-1, high/1024-x-1024/gpt-image-1, high/1024-x-1536/gpt-image-1, high/1536-x-1024/gpt-image-1, low/1024-x-1024/gpt-image-1, low/1024-x-1536/gpt-image-1, low/1536-x-1024/gpt-image-1, medium/1024-x-1024/gpt-image-1, medium/1024-x-1536/gpt-image-1, medium/1536-x-1024/gpt-image-1 |
| `gpt-image-1-mini` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-image-1-mini, azure/high/1024-x-1024/gpt-image-1-mini, azure/high/1024-x-1536/gpt-image-1-mini, azure/high/1536-x-1024/gpt-image-1-mini, azure/low/1024-x-1024/gpt-image-1-mini, azure/low/1024-x-1536/gpt-image-1-mini, azure/low/1536-x-1024/gpt-image-1-mini, azure/medium/1024-x-1024/gpt-image-1-mini, azure/medium/1024-x-1536/gpt-image-1-mini, azure/medium/1536-x-1024/gpt-image-1-mini, gpt-image-1-mini, low/1024-x-1024/gpt-image-1-mini, low/1024-x-1536/gpt-image-1-mini, low/1536-x-1024/gpt-image-1-mini, medium/1024-x-1024/gpt-image-1-mini, medium/1024-x-1536/gpt-image-1-mini, medium/1536-x-1024/gpt-image-1-mini |
| `gpt-image-1.5` | ?/N/N | ?/Y/Y | ?/N/N |  | 1024-x-1024/gpt-image-1.5, 1024-x-1536/gpt-image-1.5, 1536-x-1024/gpt-image-1.5, azure/gpt-image-1.5, gpt-image-1.5, high/1024-x-1024/gpt-image-1.5, high/1024-x-1536/gpt-image-1.5, high/1536-x-1024/gpt-image-1.5, low/1024-x-1024/gpt-image-1.5, low/1024-x-1536/gpt-image-1.5, low/1536-x-1024/gpt-image-1.5, medium/1024-x-1024/gpt-image-1.5, medium/1024-x-1536/gpt-image-1.5, medium/1536-x-1024/gpt-image-1.5, standard/1024-x-1024/gpt-image-1.5, standard/1024-x-1536/gpt-image-1.5, standard/1536-x-1024/gpt-image-1.5 |
| `gpt-image-2` | ?/N/N | ?/Y/Y | ?/N/N |  | aiml/openai/gpt-image-2, azure/gpt-image-2, gpt-image-2 |
| `gpt-image-2-2026-04-21` | ?/N/N | ?/Y/Y | ?/N/N |  | azure/gpt-image-2-2026-04-21, gpt-image-2-2026-04-21 |
| `gpt-realtime` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-realtime |
| `gpt-realtime-1.5` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-realtime-1.5 |
| `gpt-realtime-2` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-realtime-2 |
| `gpt-realtime-2.1` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-realtime-2.1 |
| `gpt-realtime-2.1-mini` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-realtime-2.1-mini |
| `gpt-realtime-2025-08-28` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | azure/gpt-realtime-2025-08-28, gpt-realtime-2025-08-28 |
| `gpt-realtime-mini` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-realtime-mini |
| `gpt-realtime-mini-2025-10-06` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | azure/gpt-realtime-mini-2025-10-06, gpt-realtime-mini-2025-10-06 |
| `gpt-realtime-mini-2025-12-15` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-realtime-mini-2025-12-15 |
| `gpt-realtime-translate` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `gpt-realtime-whisper` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-realtime-whisper, gpt-realtime-whisper |
| `o1` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/o1, o1, openrouter/openai/o1, replicate/openai/o1, vercel_ai_gateway/openai/o1 |
| `o1-2024-12-17` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/eu/o1-2024-12-17, azure/o1-2024-12-17, azure/us/o1-2024-12-17, o1-2024-12-17 |
| `o1-pro` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | o1-pro |
| `o1-pro-2025-03-19` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | o1-pro-2025-03-19 |
| `o3` | ?/N/N | ?/Y/Y | ?/Y/Y |  | azure/o3, o3, vercel_ai_gateway/openai/o3 |
| `o3-2025-04-16` | ?/N/N | ?/Y/Y | ?/Y/Y |  | azure/o3-2025-04-16, azure/us/o3-2025-04-16, o3-2025-04-16 |
| `o3-deep-research` | ?/N/Y | ?/Y/Y | ?/N/Y | ⚠️ par,think | azure/o3-deep-research, o3-deep-research |
| `o3-deep-research-2025-06-26` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | o3-deep-research-2025-06-26 |
| `o3-mini` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | azure/o3-mini, o3-mini, openrouter/openai/o3-mini, vercel_ai_gateway/openai/o3-mini |
| `o3-mini-2025-01-31` | ?/N/N | ?/N/N | ?/Y/Y |  | azure/eu/o3-mini-2025-01-31, azure/o3-mini-2025-01-31, azure/us/o3-mini-2025-01-31, o3-mini-2025-01-31 |
| `o3-pro` | ?/N/N | ?/Y/Y | ?/Y/Y |  | azure/o3-pro, o3-pro |
| `o3-pro-2025-06-10` | ?/N/N | ?/Y/Y | ?/Y/Y |  | azure/o3-pro-2025-06-10, o3-pro-2025-06-10 |
| `o4-mini` | ?/N/N | ?/Y/Y | ?/Y/Y |  | azure/o4-mini, o4-mini, replicate/openai/o4-mini, vercel_ai_gateway/openai/o4-mini |
| `o4-mini-2025-04-16` | ?/N/N | ?/Y/Y | ?/Y/Y |  | azure/o4-mini-2025-04-16, azure/us/o4-mini-2025-04-16, o4-mini-2025-04-16 |
| `o4-mini-deep-research` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | o4-mini-deep-research |
| `o4-mini-deep-research-2025-06-26` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | o4-mini-deep-research-2025-06-26 |
| `omni-moderation-2024-09-26` | ?/N/N | ?/N/N | ?/N/N |  | omni-moderation-2024-09-26 |
| `omni-moderation-latest` | ?/N/N | ?/N/N | ?/N/N |  | omni-moderation-latest |
| `sora-2` | ?/N/N | ?/N/N | ?/N/N |  | azure/sora-2, openai/sora-2, sora-2 |
| `sora-2-pro` | ?/N/N | ?/N/N | ?/N/N |  | azure/sora-2-pro, openai/sora-2-pro, sora-2-pro |
| `text-embedding-3-large` | ?/N/N | ?/N/N | ?/N/N |  | azure/text-embedding-3-large, text-embedding-3-large, vercel_ai_gateway/openai/text-embedding-3-large |
| `text-embedding-3-small` | ?/N/N | ?/N/N | ?/N/N |  | azure/text-embedding-3-small, github_copilot/text-embedding-3-small, text-embedding-3-small, vercel_ai_gateway/openai/text-embedding-3-small |
| `text-embedding-ada-002` | ?/N/N | ?/N/N | ?/N/N |  | azure/text-embedding-ada-002, github_copilot/text-embedding-ada-002, text-embedding-ada-002, vercel_ai_gateway/openai/text-embedding-ada-002 |
| `tts-1` | ?/N/N | ?/N/N | ?/N/N |  | azure/tts-1, tts-1 |
| `tts-1-1106` | ?/N/N | ?/N/N | ?/N/N |  | tts-1-1106 |
| `tts-1-hd` | ?/N/N | ?/N/N | ?/N/N |  | azure/tts-1-hd, tts-1-hd |
| `tts-1-hd-1106` | ?/N/N | ?/N/N | ?/N/N |  | tts-1-hd-1106 |
| `whisper-1` | ?/N/N | ?/N/N | ?/N/N |  | azure/whisper-1, whisper-1 |

### OpenRouter  
`builtin.openrouter` — 343 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `ai21/jamba-large-1.7` | ?/N/N | ?/N/N | ?/N/N |  | jamba-large-1.7 |
| `aion-labs/aion-2.0` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `aion-labs/aion-3.0` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `aion-labs/aion-3.0-mini` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `aion-labs/aion-rp-llama-3.1-8b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `allenai/olmo-3-32b-think` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | publicai/allenai/Olmo-3-32B-Think |
| `amazon/nova-2-lite-v1` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `amazon/nova-lite-v1` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | amazon-nova/nova-lite-v1 |
| `amazon/nova-micro-v1` | ?/N/N | ?/N/N | ?/N/N |  | amazon-nova/nova-micro-v1 |
| `amazon/nova-premier-v1` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | amazon-nova/nova-premier-v1 |
| `amazon/nova-pro-v1` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | amazon-nova/nova-pro-v1 |
| `anthracite-org/magnum-v4-72b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `anthropic/claude-3-haiku` | ?/N/N | ?/Y/Y | ?/N/N |  | openrouter/anthropic/claude-3-haiku, vercel_ai_gateway/anthropic/claude-3-haiku, vertex_ai/claude-3-haiku, vertex_ai/claude-3-haiku@20240307 |
| `anthropic/claude-fable-5` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | anthropic.claude-fable-5, azure_ai/claude-fable-5, claude-fable-5, eu.anthropic.claude-fable-5, global.anthropic.claude-fable-5, us.anthropic.claude-fable-5, vertex_ai/claude-fable-5, vertex_ai/claude-fable-5@default |
| `anthropic/claude-haiku-4.5` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | github_copilot/claude-haiku-4.5, openrouter/anthropic/claude-haiku-4.5, vercel_ai_gateway/anthropic/claude-haiku-4.5 |
| `anthropic/claude-opus-4` | ?/N/N | ?/Y/Y | ?/Y/Y |  | gmi/anthropic/claude-opus-4, openrouter/anthropic/claude-opus-4, vercel_ai_gateway/anthropic/claude-opus-4, vertex_ai/claude-opus-4, vertex_ai/claude-opus-4@20250514 |
| `anthropic/claude-opus-4.1` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/anthropic/claude-opus-4.1, vercel_ai_gateway/anthropic/claude-opus-4.1 |
| `anthropic/claude-opus-4.5` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | github_copilot/claude-opus-4.5, gmi/anthropic/claude-opus-4.5, openrouter/anthropic/claude-opus-4.5, vercel_ai_gateway/anthropic/claude-opus-4.5 |
| `anthropic/claude-opus-4.6` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/anthropic/claude-opus-4.6, vercel_ai_gateway/anthropic/claude-opus-4.6 |
| `anthropic/claude-opus-4.7` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/anthropic/claude-opus-4.7 |
| `anthropic/claude-opus-4.7-fast` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `anthropic/claude-opus-4.8` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `anthropic/claude-opus-4.8-fast` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `anthropic/claude-sonnet-4` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | github_copilot/claude-sonnet-4, gmi/anthropic/claude-sonnet-4, openrouter/anthropic/claude-sonnet-4, vercel_ai_gateway/anthropic/claude-sonnet-4, vertex_ai/claude-sonnet-4, vertex_ai/claude-sonnet-4@20250514 |
| `anthropic/claude-sonnet-4.5` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | github_copilot/claude-sonnet-4.5, gmi/anthropic/claude-sonnet-4.5, openrouter/anthropic/claude-sonnet-4.5, vercel_ai_gateway/anthropic/claude-sonnet-4.5 |
| `anthropic/claude-sonnet-4.6` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/anthropic/claude-sonnet-4.6 |
| `anthropic/claude-sonnet-5` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | anthropic.claude-sonnet-5, au.anthropic.claude-sonnet-5, azure_ai/claude-sonnet-5, claude-sonnet-5, eu.anthropic.claude-sonnet-5, global.anthropic.claude-sonnet-5, jp.anthropic.claude-sonnet-5, us.anthropic.claude-sonnet-5, vertex_ai/claude-sonnet-5, vertex_ai/claude-sonnet-5@default |
| `arcee-ai/coder-large` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `arcee-ai/trinity-large-thinking` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `arcee-ai/virtuoso-large` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `baidu/ernie-4.5-vl-424b-a47b` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | novita/baidu/ernie-4.5-vl-424b-a47b |
| `bytedance-seed/seed-1.6` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `bytedance-seed/seed-1.6-flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `bytedance-seed/seed-2.0-lite` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `bytedance-seed/seed-2.0-mini` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `bytedance/ui-tars-1.5-7b` | ?/N/N | ?/N/N | ?/N/N |  | openrouter/bytedance/ui-tars-1.5-7b |
| `cognitivecomputations/dolphin-mistral-24b-venice-edition` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `cognitivecomputations/dolphin-mistral-24b-venice-edition:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `cohere/command-a` | ?/N/N | ?/N/N | ?/N/N |  | vercel_ai_gateway/cohere/command-a |
| `cohere/command-r-08-2024` | ?/N/N | ?/N/N | ?/N/N |  | command-r-08-2024, oci/cohere.command-r-08-2024 |
| `cohere/command-r-plus-08-2024` | ?/N/N | ?/N/N | ?/N/N |  | command-r-plus-08-2024, oci/cohere.command-r-plus-08-2024 |
| `cohere/command-r7b-12-2024` | ?/N/N | ?/N/N | ?/N/N |  | command-r7b-12-2024 |
| `cohere/north-mini-code:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `deepcogito/cogito-v2.1-671b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `deepseek/deepseek-chat` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | deepseek-chat, deepseek/deepseek-chat, openrouter/deepseek/deepseek-chat |
| `deepseek/deepseek-chat-v3-0324` | ?/N/N | ?/N/N | ?/N/N |  | openrouter/deepseek/deepseek-chat-v3-0324 |
| `deepseek/deepseek-chat-v3.1` | ?/N/N | ?/N/N | ?/Y/Y |  | openrouter/deepseek/deepseek-chat-v3.1 |
| `deepseek/deepseek-r1` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | azure_ai/deepseek-r1, deepinfra/deepseek-ai/DeepSeek-R1, deepseek/deepseek-r1, fireworks_ai/accounts/fireworks/models/deepseek-r1, hyperbolic/deepseek-ai/DeepSeek-R1, nebius/deepseek-ai/DeepSeek-R1, openrouter/deepseek/deepseek-r1, replicate/deepseek-ai/deepseek-r1, sambanova/DeepSeek-R1, snowflake/deepseek-r1, together_ai/deepseek-ai/DeepSeek-R1, vercel_ai_gateway/deepseek/deepseek-r1 |
| `deepseek/deepseek-r1-0528` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | crusoe/deepseek-ai/DeepSeek-R1-0528, deepinfra/deepseek-ai/DeepSeek-R1-0528, fireworks_ai/accounts/fireworks/models/deepseek-r1-0528, hyperbolic/deepseek-ai/DeepSeek-R1-0528, lambda_ai/deepseek-r1-0528, nebius/deepseek-ai/DeepSeek-R1-0528, novita/deepseek/deepseek-r1-0528, openrouter/deepseek/deepseek-r1-0528, wandb/deepseek-ai/DeepSeek-R1-0528 |
| `deepseek/deepseek-r1-distill-llama-70b` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | deepinfra/deepseek-ai/DeepSeek-R1-Distill-Llama-70B, fireworks_ai/accounts/fireworks/models/deepseek-r1-distill-llama-70b, gradient_ai/deepseek-r1-distill-llama-70b, nebius/deepseek-ai/DeepSeek-R1-Distill-Llama-70B, novita/deepseek/deepseek-r1-distill-llama-70b, nscale/deepseek-ai/DeepSeek-R1-Distill-Llama-70B, ovhcloud/DeepSeek-R1-Distill-Llama-70B, sambanova/DeepSeek-R1-Distill-Llama-70B, vercel_ai_gateway/deepseek/deepseek-r1-distill-llama-70b |
| `deepseek/deepseek-v3.1-terminus` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | deepinfra/deepseek-ai/DeepSeek-V3.1-Terminus, novita/deepseek/deepseek-v3.1-terminus |
| `deepseek/deepseek-v3.2` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | azure_ai/deepseek-v3.2, deepseek/deepseek-v3.2, gmi/deepseek-ai/DeepSeek-V3.2, novita/deepseek/deepseek-v3.2, openrouter/deepseek/deepseek-v3.2, sambanova/DeepSeek-V3.2 |
| `deepseek/deepseek-v3.2-exp` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | novita/deepseek/deepseek-v3.2-exp, openrouter/deepseek/deepseek-v3.2-exp |
| `deepseek/deepseek-v4-flash` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | azure_ai/deepseek-v4-flash, deepseek-v4-flash, deepseek/deepseek-v4-flash, fireworks_ai/accounts/fireworks/models/deepseek-v4-flash, fireworks_ai/deepseek-v4-flash, libertai/deepseek-v4-flash, pinstripes/ps/deepseek-v4-flash, tencent/deepseek-v4-flash, tensormesh/deepseek-ai/DeepSeek-V4-Flash |
| `deepseek/deepseek-v4-pro` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | azure_ai/deepseek-v4-pro, deepseek-v4-pro, deepseek/deepseek-v4-pro, fireworks_ai/accounts/fireworks/models/deepseek-v4-pro, fireworks_ai/deepseek-v4-pro, tencent/deepseek-v4-pro |
| `google/gemini-2.5-flash` | ?/N/Y | ?/Y/Y | ?/N/Y | ⚠️ par,think | deepinfra/google/gemini-2.5-flash, gemini-2.5-flash, gemini/gemini-2.5-flash, oci/google.gemini-2.5-flash, openrouter/google/gemini-2.5-flash, perplexity/google/gemini-2.5-flash, replicate/google/gemini-2.5-flash, vercel_ai_gateway/google/gemini-2.5-flash |
| `google/gemini-2.5-flash-image` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | gemini-2.5-flash-image, gemini/gemini-2.5-flash-image, vertex_ai/gemini-2.5-flash-image |
| `google/gemini-2.5-flash-lite` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | gemini-2.5-flash-lite, gemini/gemini-2.5-flash-lite, oci/google.gemini-2.5-flash-lite |
| `google/gemini-2.5-pro` | ?/N/Y | ?/Y/Y | ?/N/Y | ⚠️ par,think | deepinfra/google/gemini-2.5-pro, gemini-2.5-pro, gemini/gemini-2.5-pro, github_copilot/gemini-2.5-pro, oci/google.gemini-2.5-pro, openrouter/google/gemini-2.5-pro, perplexity/google/gemini-2.5-pro, vercel_ai_gateway/google/gemini-2.5-pro |
| `google/gemini-2.5-pro-preview` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `google/gemini-2.5-pro-preview-05-06` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `google/gemini-3-flash-preview` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | gemini-3-flash-preview, gemini/gemini-3-flash-preview, gmi/google/gemini-3-flash-preview, openrouter/google/gemini-3-flash-preview, perplexity/google/gemini-3-flash-preview, vertex_ai/gemini-3-flash-preview |
| `google/gemini-3-pro-image` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | gemini-3-pro-image, gemini/gemini-3-pro-image, vertex_ai/gemini-3-pro-image |
| `google/gemini-3-pro-image-preview` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | gemini-3-pro-image-preview, gemini/gemini-3-pro-image-preview, vertex_ai/gemini-3-pro-image-preview |
| `google/gemini-3.1-flash-image` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | gemini-3.1-flash-image, gemini/gemini-3.1-flash-image, vertex_ai/gemini-3.1-flash-image |
| `google/gemini-3.1-flash-image-preview` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | gemini-3.1-flash-image-preview, gemini/gemini-3.1-flash-image-preview, vertex_ai/gemini-3.1-flash-image-preview |
| `google/gemini-3.1-flash-lite` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | gemini-3.1-flash-lite, gemini/gemini-3.1-flash-lite, openrouter/google/gemini-3.1-flash-lite, vertex_ai/gemini-3.1-flash-lite |
| `google/gemini-3.1-flash-lite-image` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `google/gemini-3.1-flash-lite-preview` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | gemini-3.1-flash-lite-preview, gemini/gemini-3.1-flash-lite-preview, openrouter/google/gemini-3.1-flash-lite-preview, vertex_ai/gemini-3.1-flash-lite-preview |
| `google/gemini-3.1-pro-preview` | ?/N/N | ?/Y/Y | ?/Y/Y |  | gemini-3.1-pro-preview, gemini/gemini-3.1-pro-preview, openrouter/google/gemini-3.1-pro-preview, vertex_ai/gemini-3.1-pro-preview |
| `google/gemini-3.1-pro-preview-customtools` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | gemini-3.1-pro-preview-customtools, gemini/gemini-3.1-pro-preview-customtools, vertex_ai/gemini-3.1-pro-preview-customtools |
| `google/gemini-3.5-flash` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | gemini-3.5-flash, gemini/gemini-3.5-flash, vertex_ai/gemini-3.5-flash |
| `google/gemma-2-27b-it` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `google/gemma-3-12b-it` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | crusoe/google/gemma-3-12b-it, deepinfra/google/gemma-3-12b-it, google.gemma-3-12b-it, novita/google/gemma-3-12b-it |
| `google/gemma-3-27b-it` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | deepinfra/google/gemma-3-27b-it, fireworks_ai/accounts/fireworks/models/gemma-3-27b-it, gemini/gemma-3-27b-it, google.gemma-3-27b-it, nebius/google/gemma-3-27b-it, novita/google/gemma-3-27b-it, scaleway/google/gemma-3-27b-it |
| `google/gemma-3-4b-it` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | deepinfra/google/gemma-3-4b-it, google.gemma-3-4b-it |
| `google/gemma-3n-e4b-it` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `google/gemma-4-26b-a4b-it` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | cloudflare/@cf/google/gemma-4-26b-a4b-it, scaleway/google/gemma-4-26b-a4b-it |
| `google/gemma-4-26b-a4b-it:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `google/gemma-4-31b-it` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | libertai/gemma-4-31b-it, sambanova/gemma-4-31B-it, tensormesh/google/gemma-4-31B-it |
| `google/gemma-4-31b-it:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `google/lyria-3-clip-preview` | ?/N/N | ?/N/N | ?/N/N |  | gemini/lyria-3-clip-preview |
| `google/lyria-3-pro-preview` | ?/N/N | ?/N/N | ?/N/N |  | gemini/lyria-3-pro-preview |
| `gryphe/mythomax-l2-13b` | ?/N/N | ?/N/N | ?/N/N |  | deepinfra/Gryphe/MythoMax-L2-13b, fireworks_ai/accounts/fireworks/models/mythomax-l2-13b, novita/gryphe/mythomax-l2-13b, openrouter/gryphe/mythomax-l2-13b |
| `ibm-granite/granite-4.0-h-micro` | ?/N/N | ?/N/N | ?/N/N |  | cloudflare/@cf/ibm-granite/granite-4.0-h-micro |
| `ibm-granite/granite-4.1-8b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `inception/mercury-2` | ?/N/N | ?/N/N | ?/N/N |  | inception/mercury-2 |
| `inclusionai/ling-2.6-1t` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `inclusionai/ling-2.6-flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `inclusionai/ring-2.6-1t` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `inflection/inflection-3-pi` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `inflection/inflection-3-productivity` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `kwaipilot/kat-coder-air-v2.5` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `kwaipilot/kat-coder-pro-v2` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `kwaipilot/kat-coder-pro-v2.5` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mancer/weaver` | ?/N/N | ?/N/N | ?/N/N |  | openrouter/mancer/weaver |
| `meta-llama/llama-3.1-70b-instruct` | ?/N/N | ?/N/N | ?/N/N |  | oci/meta.llama-3.1-70b-instruct, perplexity/llama-3.1-70b-instruct |
| `meta-llama/llama-3.1-8b-instruct` | ?/N/N | ?/N/N | ?/N/N |  | novita/meta-llama/llama-3.1-8b-instruct, nscale/meta-llama/Llama-3.1-8B-Instruct, oci/meta.llama-3.1-8b-instruct, ovhcloud/Llama-3.1-8B-Instruct, perplexity/llama-3.1-8b-instruct, wandb/meta-llama/Llama-3.1-8B-Instruct |
| `meta-llama/llama-3.2-11b-vision-instruct` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | azure_ai/Llama-3.2-11B-Vision-Instruct, cloudflare/@cf/meta/llama-3.2-11b-vision-instruct, deepinfra/meta-llama/Llama-3.2-11B-Vision-Instruct, oci/meta.llama-3.2-11b-vision-instruct |
| `meta-llama/llama-3.2-1b-instruct` | ?/N/N | ?/N/N | ?/N/N |  | cloudflare/@cf/meta/llama-3.2-1b-instruct |
| `meta-llama/llama-3.2-3b-instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | cloudflare/@cf/meta/llama-3.2-3b-instruct, deepinfra/meta-llama/Llama-3.2-3B-Instruct, hyperbolic/meta-llama/Llama-3.2-3B-Instruct, novita/meta-llama/llama-3.2-3b-instruct |
| `meta-llama/llama-3.2-3b-instruct:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `meta-llama/llama-3.3-70b-instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | azure_ai/Llama-3.3-70B-Instruct, crusoe/meta-llama/Llama-3.3-70B-Instruct, deepinfra/meta-llama/Llama-3.3-70B-Instruct, hyperbolic/meta-llama/Llama-3.3-70B-Instruct, meta_llama/Llama-3.3-70B-Instruct, nebius/meta-llama/Llama-3.3-70B-Instruct, novita/meta-llama/llama-3.3-70b-instruct, nscale/meta-llama/Llama-3.3-70B-Instruct, oci/meta.llama-3.3-70b-instruct, scaleway/meta/llama-3.3-70b-instruct, wandb/meta-llama/Llama-3.3-70B-Instruct |
| `meta-llama/llama-3.3-70b-instruct:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `meta-llama/llama-4-maverick` | ?/N/N | ?/N/N | ?/N/N |  | vercel_ai_gateway/meta/llama-4-maverick |
| `meta-llama/llama-4-scout` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | vercel_ai_gateway/meta/llama-4-scout |
| `meta-llama/llama-guard-4-12b` | ?/N/N | ?/N/N | ?/N/N |  | deepinfra/meta-llama/Llama-Guard-4-12B, groq/meta-llama/llama-guard-4-12b |
| `microsoft/phi-4` | ?/N/N | ?/N/N | ?/N/N |  | azure_ai/Phi-4, deepinfra/microsoft/phi-4 |
| `microsoft/wizardlm-2-8x22b` | ?/N/N | ?/N/N | ?/N/N |  | deepinfra/microsoft/WizardLM-2-8x22B, novita/microsoft/wizardlm-2-8x22b |
| `minimax/minimax-01` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `minimax/minimax-m1` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `minimax/minimax-m2` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | fireworks_ai/accounts/fireworks/models/minimax-m2, minimax/MiniMax-M2, novita/minimax/minimax-m2, openrouter/minimax/minimax-m2 |
| `minimax/minimax-m2-her` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `minimax/minimax-m2.1` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | gmi/MiniMaxAI/MiniMax-M2.1, minimax/MiniMax-M2.1, novita/minimax/minimax-m2.1, openrouter/minimax/minimax-m2.1 |
| `minimax/minimax-m2.5` | ?/N/N | ?/N/N | ?/Y/Y |  | baseten/MiniMaxAI/MiniMax-M2.5, minimax/MiniMax-M2.5, openrouter/minimax/minimax-m2.5, tensormesh/MiniMaxAI/MiniMax-M2.5, wandb/MiniMaxAI/MiniMax-M2.5 |
| `minimax/minimax-m2.7` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | pinstripes/ps/minimax-m2.7, sambanova/MiniMax-M2.7 |
| `minimax/minimax-m3` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | fireworks_ai/accounts/fireworks/models/minimax-m3, fireworks_ai/minimax-m3, minimax/MiniMax-M3 |
| `mistralai/codestral-2508` | ?/N/N | ?/N/N | ?/N/N |  | mistral/codestral-2508 |
| `mistralai/devstral-2512` | ?/N/N | ?/N/N | ?/N/N |  | mistral/devstral-2512, openrouter/mistralai/devstral-2512 |
| `mistralai/ministral-14b-2512` | ?/N/N | ?/Y/Y | ?/N/N |  | openrouter/mistralai/ministral-14b-2512 |
| `mistralai/ministral-3b-2512` | ?/N/N | ?/Y/Y | ?/N/N |  | openrouter/mistralai/ministral-3b-2512 |
| `mistralai/ministral-8b-2512` | ?/N/N | ?/Y/Y | ?/N/N |  | mistral/ministral-8b-2512, openrouter/mistralai/ministral-8b-2512 |
| `mistralai/mistral-large` | ?/N/N | ?/N/N | ?/N/N |  | azure_ai/mistral-large, openrouter/mistralai/mistral-large, snowflake/mistral-large, vercel_ai_gateway/mistral/mistral-large, vertex_ai/mistral-large@2407, vertex_ai/mistral-large@2411-001, vertex_ai/mistral-large@latest, watsonx/mistralai/mistral-large |
| `mistralai/mistral-large-2407` | ?/N/N | ?/N/N | ?/N/N |  | azure_ai/mistral-large-2407, mistral/mistral-large-2407 |
| `mistralai/mistral-large-2512` | ?/N/N | ?/Y/Y | ?/N/N |  | mistral/mistral-large-2512, openrouter/mistralai/mistral-large-2512 |
| `mistralai/mistral-medium-3` | ?/N/N | ?/N/N | ?/N/N |  | vertex_ai/mistral-medium-3, vertex_ai/mistral-medium-3@001, vertex_ai/mistralai/mistral-medium-3, vertex_ai/mistralai/mistral-medium-3@001 |
| `mistralai/mistral-medium-3-5` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | mistral/mistral-medium-3-5 |
| `mistralai/mistral-medium-3.1` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mistralai/mistral-nemo` | ?/N/N | ?/N/N | ?/N/N |  | azure_ai/mistral-nemo, novita/mistralai/mistral-nemo, vertex_ai/mistral-nemo@2407, vertex_ai/mistral-nemo@latest |
| `mistralai/mistral-saba` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mistralai/mistral-small-24b-instruct-2501` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | deepinfra/mistralai/Mistral-Small-24B-Instruct-2501, fireworks_ai/accounts/fireworks/models/mistral-small-24b-instruct-2501, together_ai/mistralai/Mistral-Small-24B-Instruct-2501 |
| `mistralai/mistral-small-2603` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mistralai/mistral-small-3.1-24b-instruct` | ?/N/N | ?/N/N | ?/N/N |  | cloudflare/@cf/mistralai/mistral-small-3.1-24b-instruct, openrouter/mistralai/mistral-small-3.1-24b-instruct |
| `mistralai/mistral-small-3.2-24b-instruct` | ?/N/N | ?/N/N | ?/N/N |  | openrouter/mistralai/mistral-small-3.2-24b-instruct |
| `mistralai/mixtral-8x22b-instruct` | ?/N/N | ?/N/N | ?/N/N |  | fireworks_ai/accounts/fireworks/models/mixtral-8x22b-instruct, openrouter/mistralai/mixtral-8x22b-instruct, vercel_ai_gateway/mistral/mixtral-8x22b-instruct |
| `mistralai/voxtral-small-24b-2507` | ?/N/N | ?/N/N | ?/N/N |  | mistral.voxtral-small-24b-2507, scaleway/mistralai/voxtral-small-24b-2507 |
| `moonshotai/kimi-k2` | ?/N/N | ?/N/N | ?/N/N |  | vercel_ai_gateway/moonshotai/kimi-k2 |
| `moonshotai/kimi-k2-0905` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | novita/moonshotai/kimi-k2-0905 |
| `moonshotai/kimi-k2-thinking` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | baseten/moonshotai/Kimi-K2-Thinking, crusoe/moonshotai/Kimi-K2-Thinking, fireworks_ai/accounts/fireworks/models/kimi-k2-thinking, gmi/moonshotai/Kimi-K2-Thinking, moonshot/kimi-k2-thinking, novita/moonshotai/kimi-k2-thinking |
| `moonshotai/kimi-k2.5` | ?/N/N | ?/Y/Y | ?/N/Y | ⚠️ think | azure_ai/kimi-k2.5, baseten/moonshotai/Kimi-K2.5, moonshot/kimi-k2.5, openrouter/moonshotai/kimi-k2.5, together_ai/moonshotai/Kimi-K2.5, wandb/moonshotai/Kimi-K2.5 |
| `moonshotai/kimi-k2.6` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | azure_ai/kimi-k2.6, cloudflare/@cf/moonshotai/kimi-k2.6, moonshot/kimi-k2.6, tensormesh/moonshotai/Kimi-K2.6 |
| `moonshotai/kimi-k2.7-code` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | cloudflare/@cf/moonshotai/kimi-k2.7-code |
| `morph/morph-v3-fast` | ?/N/N | ?/N/N | ?/N/N |  | morph/morph-v3-fast, vercel_ai_gateway/morph/morph-v3-fast |
| `morph/morph-v3-large` | ?/N/N | ?/N/N | ?/N/N |  | morph/morph-v3-large, vercel_ai_gateway/morph/morph-v3-large |
| `nex-agi/nex-n2-mini` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nex-agi/nex-n2-pro` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nousresearch/hermes-3-llama-3.1-405b` | ?/N/N | ?/N/N | ?/N/N |  | deepinfra/NousResearch/Hermes-3-Llama-3.1-405B, nebius/NousResearch/Hermes-3-Llama-3.1-405B |
| `nousresearch/hermes-3-llama-3.1-405b:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nousresearch/hermes-3-llama-3.1-70b` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | deepinfra/NousResearch/Hermes-3-Llama-3.1-70B, hyperbolic/NousResearch/Hermes-3-Llama-3.1-70B |
| `nousresearch/hermes-4-405b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nousresearch/hermes-4-70b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nvidia/llama-3.3-nemotron-super-49b-v1.5` | ?/N/N | ?/N/N | ?/N/N |  | deepinfra/nvidia/Llama-3.3-Nemotron-Super-49B-v1.5 |
| `nvidia/nemotron-3-nano-30b-a3b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nvidia/nemotron-3-nano-30b-a3b:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nvidia/nemotron-3-super-120b-a12b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nvidia/nemotron-3-super-120b-a12b:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nvidia/nemotron-3-ultra-550b-a55b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nvidia/nemotron-3-ultra-550b-a55b:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nvidia/nemotron-3.5-content-safety:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nvidia/nemotron-nano-12b-v2-vl:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `nvidia/nemotron-nano-9b-v2:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openai/gpt-3.5-turbo` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-3.5-turbo, github_copilot/gpt-3.5-turbo, gpt-3.5-turbo, openrouter/openai/gpt-3.5-turbo, vercel_ai_gateway/openai/gpt-3.5-turbo |
| `openai/gpt-3.5-turbo-0613` | ?/N/N | ?/N/N | ?/N/N |  | github_copilot/gpt-3.5-turbo-0613 |
| `openai/gpt-3.5-turbo-16k` | ?/N/N | ?/N/N | ?/N/N |  | gpt-3.5-turbo-16k, openrouter/openai/gpt-3.5-turbo-16k |
| `openai/gpt-3.5-turbo-instruct` | ?/N/N | ?/N/N | ?/N/N |  | gpt-3.5-turbo-instruct, vercel_ai_gateway/openai/gpt-3.5-turbo-instruct |
| `openai/gpt-4` | ?/N/N | ?/N/N | ?/N/N |  | azure/gpt-4, github_copilot/gpt-4, gpt-4, openrouter/openai/gpt-4 |
| `openai/gpt-4-turbo` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | azure/gpt-4-turbo, gpt-4-turbo, vercel_ai_gateway/openai/gpt-4-turbo |
| `openai/gpt-4-turbo-preview` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-4-turbo-preview |
| `openai/gpt-4.1` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4.1, github_copilot/gpt-4.1, gpt-4.1, openrouter/openai/gpt-4.1, replicate/openai/gpt-4.1, vercel_ai_gateway/openai/gpt-4.1 |
| `openai/gpt-4.1-mini` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4.1-mini, gpt-4.1-mini, openrouter/openai/gpt-4.1-mini, replicate/openai/gpt-4.1-mini, vercel_ai_gateway/openai/gpt-4.1-mini |
| `openai/gpt-4.1-nano` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4.1-nano, gpt-4.1-nano, openrouter/openai/gpt-4.1-nano, replicate/openai/gpt-4.1-nano, vercel_ai_gateway/openai/gpt-4.1-nano |
| `openai/gpt-4o` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4o, github_copilot/gpt-4o, gmi/openai/gpt-4o, gpt-4o, openrouter/openai/gpt-4o, replicate/openai/gpt-4o, vercel_ai_gateway/openai/gpt-4o |
| `openai/gpt-4o-2024-05-13` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/gpt-4o-2024-05-13, github_copilot/gpt-4o-2024-05-13, gpt-4o-2024-05-13, openrouter/openai/gpt-4o-2024-05-13 |
| `openai/gpt-4o-2024-08-06` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/eu/gpt-4o-2024-08-06, azure/global-standard/gpt-4o-2024-08-06, azure/global/gpt-4o-2024-08-06, azure/gpt-4o-2024-08-06, azure/us/gpt-4o-2024-08-06, github_copilot/gpt-4o-2024-08-06, gpt-4o-2024-08-06 |
| `openai/gpt-4o-2024-11-20` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/eu/gpt-4o-2024-11-20, azure/global-standard/gpt-4o-2024-11-20, azure/global/gpt-4o-2024-11-20, azure/gpt-4o-2024-11-20, azure/us/gpt-4o-2024-11-20, github_copilot/gpt-4o-2024-11-20, gpt-4o-2024-11-20 |
| `openai/gpt-4o-mini` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/global-standard/gpt-4o-mini, azure/gpt-4o-mini, github_copilot/gpt-4o-mini, gmi/openai/gpt-4o-mini, gpt-4o-mini, replicate/openai/gpt-4o-mini, vercel_ai_gateway/openai/gpt-4o-mini |
| `openai/gpt-4o-mini-2024-07-18` | ?/N/Y | ?/Y/Y | ?/N/N | ⚠️ par | azure/eu/gpt-4o-mini-2024-07-18, azure/gpt-4o-mini-2024-07-18, azure/us/gpt-4o-mini-2024-07-18, github_copilot/gpt-4o-mini-2024-07-18, gpt-4o-mini-2024-07-18 |
| `openai/gpt-4o-mini-search-preview` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | gpt-4o-mini-search-preview |
| `openai/gpt-4o-search-preview` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | gpt-4o-search-preview |
| `openai/gpt-5` | ?/N/Y | ?/N/Y | ?/Y/Y | ⚠️ par,vis | azure/gpt-5, github_copilot/gpt-5, gmi/openai/gpt-5, gpt-5, oci/openai.gpt-5, openrouter/openai/gpt-5, replicate/openai/gpt-5 |
| `openai/gpt-5-chat` | ?/N/Y | ?/N/Y | ?/Y/Y | ⚠️ par,vis | azure/gpt-5-chat, gpt-5-chat, openrouter/openai/gpt-5-chat |
| `openai/gpt-5-codex` | ?/N/Y | ?/N/Y | ?/Y/Y | ⚠️ par,vis | azure/gpt-5-codex, gpt-5-codex, openrouter/openai/gpt-5-codex |
| `openai/gpt-5-image` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openai/gpt-5-image-mini` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openai/gpt-5-mini` | ?/N/Y | ?/N/Y | ?/Y/Y | ⚠️ par,vis | azure/gpt-5-mini, github_copilot/gpt-5-mini, gpt-5-mini, oci/openai.gpt-5-mini, openrouter/openai/gpt-5-mini, perplexity/openai/gpt-5-mini, replicate/openai/gpt-5-mini |
| `openai/gpt-5-nano` | ?/N/Y | ?/N/Y | ?/Y/Y | ⚠️ par,vis | azure/gpt-5-nano, gpt-5-nano, oci/openai.gpt-5-nano, openrouter/openai/gpt-5-nano, replicate/openai/gpt-5-nano |
| `openai/gpt-5-pro` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/gpt-5-pro, gpt-5-pro |
| `openai/gpt-5.1` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/eu/gpt-5.1, azure/global/gpt-5.1, azure/gpt-5.1, azure/us/gpt-5.1, github_copilot/gpt-5.1, gmi/openai/gpt-5.1, gpt-5.1, perplexity/openai/gpt-5.1 |
| `openai/gpt-5.1-chat` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/eu/gpt-5.1-chat, azure/global/gpt-5.1-chat, azure/gpt-5.1-chat, azure/us/gpt-5.1-chat |
| `openai/gpt-5.1-codex` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/eu/gpt-5.1-codex, azure/global/gpt-5.1-codex, azure/gpt-5.1-codex, azure/us/gpt-5.1-codex, gpt-5.1-codex |
| `openai/gpt-5.1-codex-max` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/gpt-5.1-codex-max, chatgpt/gpt-5.1-codex-max, github_copilot/gpt-5.1-codex-max, gpt-5.1-codex-max, openrouter/openai/gpt-5.1-codex-max |
| `openai/gpt-5.1-codex-mini` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/eu/gpt-5.1-codex-mini, azure/global/gpt-5.1-codex-mini, azure/gpt-5.1-codex-mini, azure/us/gpt-5.1-codex-mini, chatgpt/gpt-5.1-codex-mini, gpt-5.1-codex-mini |
| `openai/gpt-5.2` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/gpt-5.2, chatgpt/gpt-5.2, github_copilot/gpt-5.2, gmi/openai/gpt-5.2, gpt-5.2, openrouter/openai/gpt-5.2, perplexity/openai/gpt-5.2 |
| `openai/gpt-5.2-chat` | ?/N/Y | ?/Y/Y | ?/N/Y | ⚠️ par,think | azure/gpt-5.2-chat, openrouter/openai/gpt-5.2-chat |
| `openai/gpt-5.2-codex` | ?/N/Y | ?/N/Y | ?/Y/Y | ⚠️ par,vis | azure/gpt-5.2-codex, chatgpt/gpt-5.2-codex, gpt-5.2-codex, openrouter/openai/gpt-5.2-codex |
| `openai/gpt-5.2-pro` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/gpt-5.2-pro, gpt-5.2-pro, openrouter/openai/gpt-5.2-pro |
| `openai/gpt-5.3-chat` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/gpt-5.3-chat |
| `openai/gpt-5.3-codex` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/gpt-5.3-codex, chatgpt/gpt-5.3-codex, github_copilot/gpt-5.3-codex, gpt-5.3-codex |
| `openai/gpt-5.4` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/eu/gpt-5.4, azure/gpt-5.4, azure/us/gpt-5.4, azure_ai/gpt-5.4, bedrock_mantle/openai.gpt-5.4, chatgpt/gpt-5.4, gpt-5.4 |
| `openai/gpt-5.4-image-2` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openai/gpt-5.4-mini` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/gpt-5.4-mini, azure_ai/gpt-5.4-mini, gpt-5.4-mini |
| `openai/gpt-5.4-nano` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/gpt-5.4-nano, azure_ai/gpt-5.4-nano, gpt-5.4-nano |
| `openai/gpt-5.4-pro` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/gpt-5.4-pro, azure_ai/gpt-5.4-pro, chatgpt/gpt-5.4-pro, gpt-5.4-pro |
| `openai/gpt-5.5` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/eu/gpt-5.5, azure/gpt-5.5, azure/us/gpt-5.5, azure_ai/gpt-5.5, bedrock_mantle/openai.gpt-5.5, gpt-5.5 |
| `openai/gpt-5.5-pro` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/gpt-5.5-pro, gpt-5.5-pro |
| `openai/gpt-5.6-luna` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/eu/gpt-5.6-luna, azure/gpt-5.6-luna, azure/us/gpt-5.6-luna, bedrock_mantle/openai.gpt-5.6-luna, gpt-5.6-luna |
| `openai/gpt-5.6-luna-pro` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openai/gpt-5.6-sol` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/eu/gpt-5.6-sol, azure/gpt-5.6-sol, azure/us/gpt-5.6-sol, bedrock_mantle/openai.gpt-5.6-sol, gpt-5.6-sol |
| `openai/gpt-5.6-sol-pro` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openai/gpt-5.6-terra` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/eu/gpt-5.6-terra, azure/gpt-5.6-terra, azure/us/gpt-5.6-terra, bedrock_mantle/openai.gpt-5.6-terra, gpt-5.6-terra |
| `openai/gpt-5.6-terra-pro` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openai/gpt-audio` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-audio |
| `openai/gpt-audio-mini` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | gpt-audio-mini |
| `openai/gpt-chat-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openai/gpt-oss-120b` | ?/N/Y | ?/N/Y | ?/Y/Y | ⚠️ par,vis | azure_ai/gpt-oss-120b, baseten/openai/gpt-oss-120b, bedrock_mantle/openai.gpt-oss-120b, cerebras/gpt-oss-120b, cloudflare/@cf/openai/gpt-oss-120b, crusoe/openai/gpt-oss-120b, deepinfra/openai/gpt-oss-120b, fireworks_ai/accounts/fireworks/models/gpt-oss-120b, fireworks_ai/gpt-oss-120b, groq/openai/gpt-oss-120b, novita/openai/gpt-oss-120b, openrouter/openai/gpt-oss-120b, ovhcloud/gpt-oss-120b, replicate/openai/gpt-oss-120b, sambanova/gpt-oss-120b, scaleway/openai/gpt-oss-120b, tensormesh/openai/gpt-oss-120b, together_ai/openai/gpt-oss-120b, wandb/openai/gpt-oss-120b, watsonx/openai/gpt-oss-120b |
| `openai/gpt-oss-20b` | ?/N/Y | ?/N/Y | ?/Y/Y | ⚠️ par,vis | bedrock_mantle/openai.gpt-oss-20b, cloudflare/@cf/openai/gpt-oss-20b, darkbloom/gpt-oss-20b, deepinfra/openai/gpt-oss-20b, fireworks_ai/accounts/fireworks/models/gpt-oss-20b, fireworks_ai/gpt-oss-20b, groq/openai/gpt-oss-20b, novita/openai/gpt-oss-20b, openrouter/openai/gpt-oss-20b, ovhcloud/gpt-oss-20b, replicateopenai/gpt-oss-20b, tensormesh/openai/gpt-oss-20b, together_ai/openai/gpt-oss-20b, wandb/openai/gpt-oss-20b |
| `openai/gpt-oss-20b:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openai/gpt-oss-safeguard-20b` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | bedrock_mantle/openai.gpt-oss-safeguard-20b, fireworks_ai/accounts/fireworks/models/gpt-oss-safeguard-20b, groq/openai/gpt-oss-safeguard-20b, openai.gpt-oss-safeguard-20b |
| `openai/o1` | ?/N/Y | ?/Y/Y | ?/N/Y | ⚠️ par,think | azure/o1, o1, openrouter/openai/o1, replicate/openai/o1, vercel_ai_gateway/openai/o1 |
| `openai/o1-pro` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | o1-pro |
| `openai/o3` | ?/N/N | ?/Y/Y | ?/Y/Y |  | azure/o3, o3, vercel_ai_gateway/openai/o3 |
| `openai/o3-deep-research` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | azure/o3-deep-research, o3-deep-research |
| `openai/o3-mini` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | azure/o3-mini, o3-mini, openrouter/openai/o3-mini, vercel_ai_gateway/openai/o3-mini |
| `openai/o3-mini-high` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | openrouter/openai/o3-mini-high |
| `openai/o3-pro` | ?/N/N | ?/Y/Y | ?/Y/Y |  | azure/o3-pro, o3-pro |
| `openai/o4-mini` | ?/N/N | ?/Y/Y | ?/Y/Y |  | azure/o4-mini, o4-mini, replicate/openai/o4-mini, vercel_ai_gateway/openai/o4-mini |
| `openai/o4-mini-deep-research` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | o4-mini-deep-research |
| `openai/o4-mini-high` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openrouter/auto` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/openrouter/auto |
| `openrouter/bodybuilder` | ?/N/N | ?/N/N | ?/N/N |  | openrouter/openrouter/bodybuilder |
| `openrouter/free` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/openrouter/free |
| `openrouter/fusion` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `openrouter/pareto-code` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `perceptron/perceptron-mk1` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `perplexity/sonar` | ?/N/N | ?/N/N | ?/N/N |  | perplexity/perplexity/sonar, perplexity/sonar, vercel_ai_gateway/perplexity/sonar |
| `perplexity/sonar-deep-research` | ?/N/N | ?/N/N | ?/Y/Y |  | perplexity/sonar-deep-research |
| `perplexity/sonar-pro` | ?/N/N | ?/N/N | ?/N/N |  | perplexity/sonar-pro, vercel_ai_gateway/perplexity/sonar-pro |
| `perplexity/sonar-pro-search` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `perplexity/sonar-reasoning-pro` | ?/N/N | ?/N/N | ?/Y/Y |  | perplexity/sonar-reasoning-pro, vercel_ai_gateway/perplexity/sonar-reasoning-pro |
| `poolside/laguna-m.1` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `poolside/laguna-m.1:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `poolside/laguna-xs-2.1` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `poolside/laguna-xs-2.1:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen-2.5-72b-instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | novita/qwen/qwen-2.5-72b-instruct |
| `qwen/qwen-2.5-7b-instruct` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen-2.5-coder-32b-instruct` | ?/N/N | ?/N/N | ?/N/N |  | openrouter/qwen/qwen-2.5-coder-32b-instruct |
| `qwen/qwen-plus` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen-plus |
| `qwen/qwen-plus-2025-07-28` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen-plus-2025-07-28 |
| `qwen/qwen-plus-2025-07-28:thinking` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen2.5-vl-72b-instruct` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | nebius/Qwen/Qwen2.5-VL-72B-Instruct, novita/qwen/qwen2.5-vl-72b-instruct, ovhcloud/Qwen2.5-VL-72B-Instruct |
| `qwen/qwen3-14b` | ?/N/N | ?/N/N | ?/N/N |  | deepinfra/Qwen/Qwen3-14B, fireworks_ai/accounts/fireworks/models/qwen3-14b, nebius/Qwen/Qwen3-14B |
| `qwen/qwen3-235b-a22b` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | deepinfra/Qwen/Qwen3-235B-A22B, fireworks_ai/accounts/fireworks/models/qwen3-235b-a22b, hyperbolic/Qwen/Qwen3-235B-A22B, nebius/Qwen/Qwen3-235B-A22B |
| `qwen/qwen3-235b-a22b-2507` | ?/N/N | ?/N/N | ?/N/N |  | openrouter/qwen/qwen3-235b-a22b-2507 |
| `qwen/qwen3-235b-a22b-thinking-2507` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | deepinfra/Qwen/Qwen3-235B-A22B-Thinking-2507, fireworks_ai/accounts/fireworks/models/qwen3-235b-a22b-thinking-2507, novita/qwen/qwen3-235b-a22b-thinking-2507, openrouter/qwen/qwen3-235b-a22b-thinking-2507, together_ai/Qwen/Qwen3-235B-A22B-Thinking-2507, wandb/Qwen/Qwen3-235B-A22B-Thinking-2507 |
| `qwen/qwen3-30b-a3b` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen3-30b-a3b, deepinfra/Qwen/Qwen3-30B-A3B, fireworks_ai/accounts/fireworks/models/qwen3-30b-a3b, nebius/Qwen/Qwen3-30B-A3B, pinstripes/ps/qwen3-30b-a3b |
| `qwen/qwen3-30b-a3b-instruct-2507` | ?/N/N | ?/N/N | ?/N/N |  | fireworks_ai/accounts/fireworks/models/qwen3-30b-a3b-instruct-2507 |
| `qwen/qwen3-30b-a3b-thinking-2507` | ?/N/N | ?/N/N | ?/N/N |  | fireworks_ai/accounts/fireworks/models/qwen3-30b-a3b-thinking-2507 |
| `qwen/qwen3-32b` | ?/N/N | ?/N/N | ?/Y/Y |  | deepinfra/Qwen/Qwen3-32B, fireworks_ai/accounts/fireworks/models/qwen3-32b, groq/qwen/qwen3-32b, nebius/Qwen/Qwen3-32B, ovhcloud/Qwen3-32B, sambanova/Qwen3-32B |
| `qwen/qwen3-8b` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | fireworks_ai/accounts/fireworks/models/qwen3-8b, llamagate/qwen3-8b |
| `qwen/qwen3-coder` | ?/N/N | ?/N/N | ?/N/N |  | openrouter/qwen/qwen3-coder, vercel_ai_gateway/alibaba/qwen3-coder |
| `qwen/qwen3-coder-30b-a3b-instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | fireworks_ai/accounts/fireworks/models/qwen3-coder-30b-a3b-instruct, novita/qwen/qwen3-coder-30b-a3b-instruct, scaleway/qwen/qwen3-coder-30b-a3b-instruct |
| `qwen/qwen3-coder-flash` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | dashscope/qwen3-coder-flash |
| `qwen/qwen3-coder-next` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen3-coder-plus` | ?/N/N | ?/N/N | ?/Y/Y |  | dashscope/qwen3-coder-plus, openrouter/qwen/qwen3-coder-plus |
| `qwen/qwen3-coder:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen3-max` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | dashscope/qwen3-max, novita/qwen/qwen3-max |
| `qwen/qwen3-max-thinking` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen3-next-80b-a3b-instruct` | ?/N/Y | ?/N/N | ?/N/N | ⚠️ par | dashscope/qwen3-next-80b-a3b-instruct, deepinfra/Qwen/Qwen3-Next-80B-A3B-Instruct, fireworks_ai/accounts/fireworks/models/qwen3-next-80b-a3b-instruct, novita/qwen/qwen3-next-80b-a3b-instruct, together_ai/Qwen/Qwen3-Next-80B-A3B-Instruct |
| `qwen/qwen3-next-80b-a3b-instruct:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen3-next-80b-a3b-thinking` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | dashscope/qwen3-next-80b-a3b-thinking, deepinfra/Qwen/Qwen3-Next-80B-A3B-Thinking, fireworks_ai/accounts/fireworks/models/qwen3-next-80b-a3b-thinking, novita/qwen/qwen3-next-80b-a3b-thinking, together_ai/Qwen/Qwen3-Next-80B-A3B-Thinking |
| `qwen/qwen3-vl-235b-a22b-instruct` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | dashscope/qwen3-vl-235b-a22b-instruct, fireworks_ai/accounts/fireworks/models/qwen3-vl-235b-a22b-instruct, novita/qwen/qwen3-vl-235b-a22b-instruct |
| `qwen/qwen3-vl-235b-a22b-thinking` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | dashscope/qwen3-vl-235b-a22b-thinking, fireworks_ai/accounts/fireworks/models/qwen3-vl-235b-a22b-thinking, novita/qwen/qwen3-vl-235b-a22b-thinking |
| `qwen/qwen3-vl-30b-a3b-instruct` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | fireworks_ai/accounts/fireworks/models/qwen3-vl-30b-a3b-instruct, novita/qwen/qwen3-vl-30b-a3b-instruct |
| `qwen/qwen3-vl-30b-a3b-thinking` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | fireworks_ai/accounts/fireworks/models/qwen3-vl-30b-a3b-thinking, novita/qwen/qwen3-vl-30b-a3b-thinking |
| `qwen/qwen3-vl-32b-instruct` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | dashscope/qwen3-vl-32b-instruct, fireworks_ai/accounts/fireworks/models/qwen3-vl-32b-instruct |
| `qwen/qwen3-vl-8b-instruct` | ?/N/Y | ?/N/Y | ?/N/N | ⚠️ par,vis | fireworks_ai/accounts/fireworks/models/qwen3-vl-8b-instruct, novita/qwen/qwen3-vl-8b-instruct |
| `qwen/qwen3-vl-8b-thinking` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen3.5-122b-a10b` | ?/N/N | ?/Y/Y | ?/Y/Y |  | libertai/qwen3.5-122b-a10b, openrouter/qwen/qwen3.5-122b-a10b |
| `qwen/qwen3.5-27b` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/qwen/qwen3.5-27b |
| `qwen/qwen3.5-35b-a3b` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/qwen/qwen3.5-35b-a3b |
| `qwen/qwen3.5-397b-a17b` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | openrouter/qwen/qwen3.5-397b-a17b, scaleway/qwen/qwen3.5-397b-a17b, together_ai/Qwen/Qwen3.5-397B-A17B |
| `qwen/qwen3.5-9b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen3.5-flash-02-23` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/qwen/qwen3.5-flash-02-23 |
| `qwen/qwen3.5-plus-02-15` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/qwen/qwen3.5-plus-02-15 |
| `qwen/qwen3.5-plus-20260420` | ?/N/— | ?/Y/— | ?/Y/— |  | — |
| `qwen/qwen3.6-27b` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | libertai/qwen3.6-27b |
| `qwen/qwen3.6-35b-a3b` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | libertai/qwen3.6-35b-a3b, pinstripes/ps/qwen3.6-35b-a3b, scaleway/qwen/qwen3.6-35b-a3b |
| `qwen/qwen3.6-flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen3.6-max-preview` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen3.6-plus` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/qwen/qwen3.6-plus |
| `qwen/qwen3.7-max` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `qwen/qwen3.7-plus` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `rekaai/reka-edge` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `rekaai/reka-flash-3` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `relace/relace-apply-3` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `relace/relace-search` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `sakana/fugu-ultra` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `sao10k/l3-lunaris-8b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `sao10k/l3.1-euryale-70b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `sao10k/l3.3-euryale-70b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `stepfun/step-3.5-flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `stepfun/step-3.7-flash` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `tencent/hunyuan-a13b-instruct` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `tencent/hy3` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `tencent/hy3-preview` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `tencent/hy3:free` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `thedrummer/cydonia-24b-v4.1` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `thedrummer/rocinante-12b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `thedrummer/skyfall-36b-v2` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `thedrummer/unslopnemo-12b` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `undi95/remm-slerp-l2-13b` | ?/N/N | ?/N/N | ?/N/N |  | openrouter/undi95/remm-slerp-l2-13b |
| `upstage/solar-pro-3` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `writer/palmyra-x5` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `x-ai/grok-4.20` | ?/N/N | ?/N/N | ?/N/N |  | oci/xai.grok-4.20 |
| `x-ai/grok-4.20-multi-agent` | ?/N/N | ?/N/N | ?/N/N |  | oci/xai.grok-4.20-multi-agent |
| `x-ai/grok-4.3` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | bedrock_mantle/xai.grok-4.3, xai/grok-4.3 |
| `x-ai/grok-4.5` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | xai/grok-4.5 |
| `x-ai/grok-build-0.1` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `xiaomi/mimo-v2.5` | ?/N/N | ?/Y/Y | ?/Y/Y |  | openrouter/xiaomi/mimo-v2.5 |
| `xiaomi/mimo-v2.5-pro` | ?/N/N | ?/N/N | ?/Y/Y |  | openrouter/xiaomi/mimo-v2.5-pro |
| `z-ai/glm-4.5` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | deepinfra/zai-org/GLM-4.5, novita/zai-org/glm-4.5, vercel_ai_gateway/zai/glm-4.5, wandb/zai-org/GLM-4.5, zai/glm-4.5 |
| `z-ai/glm-4.5-air` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | novita/zai-org/glm-4.5-air, pinstripes/ps/glm-4.5-air, vercel_ai_gateway/zai/glm-4.5-air, zai/glm-4.5-air |
| `z-ai/glm-4.5v` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | novita/zai-org/glm-4.5v, zai/glm-4.5v |
| `z-ai/glm-4.6` | ?/N/Y | ?/N/N | ?/Y/Y | ⚠️ par | baseten/zai-org/GLM-4.6, novita/zai-org/glm-4.6, openrouter/z-ai/glm-4.6, together_ai/zai-org/GLM-4.6, vercel_ai_gateway/zai/glm-4.6, zai/glm-4.6 |
| `z-ai/glm-4.6v` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | novita/zai-org/glm-4.6v |
| `z-ai/glm-4.7` | ?/N/Y | ?/Y/Y | ?/Y/Y | ⚠️ par | baseten/zai-org/GLM-4.7, novita/zai-org/glm-4.7, openrouter/z-ai/glm-4.7, together_ai/zai-org/GLM-4.7, zai/glm-4.7 |
| `z-ai/glm-4.7-flash` | ?/N/N | ?/Y/Y | ?/Y/Y |  | cloudflare/@cf/zai-org/glm-4.7-flash, openrouter/z-ai/glm-4.7-flash, zai/glm-4.7-flash |
| `z-ai/glm-5` | ?/N/N | ?/N/N | ?/Y/Y |  | baseten/zai-org/GLM-5, openrouter/z-ai/glm-5, zai/glm-5 |
| `z-ai/glm-5-turbo` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `z-ai/glm-5.1` | ?/N/N | ?/N/N | ?/Y/Y |  | openrouter/z-ai/glm-5.1, zai/glm-5.1 |
| `z-ai/glm-5.2` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | cloudflare/@cf/zai-org/glm-5.2 |
| `z-ai/glm-5v-turbo` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `~anthropic/claude-fable-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `~anthropic/claude-haiku-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `~anthropic/claude-opus-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `~anthropic/claude-sonnet-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `~google/gemini-flash-latest` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | gemini-flash-latest, gemini/gemini-flash-latest |
| `~google/gemini-pro-latest` | ?/N/N | ?/N/Y | ?/N/Y | ⚠️ vis,think | gemini-pro-latest, gemini/gemini-pro-latest |
| `~moonshotai/kimi-latest` | ?/N/N | ?/N/Y | ?/N/N | ⚠️ vis | moonshot/kimi-latest |
| `~openai/gpt-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `~openai/gpt-mini-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `~x-ai/grok-latest` | ?/N/— | ?/N/— | ?/N/— |  | — |

### Grok  
`builtin.xai` — 10 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `grok-4.20-0309-non-reasoning` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `grok-4.20-0309-reasoning` | ?/N/N | ?/Y/Y | ?/Y/Y |  | xai/grok-4.20-0309-reasoning |
| `grok-4.20-multi-agent-0309` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `grok-4.3` | ?/N/N | ?/Y/Y | ?/Y/Y |  | bedrock_mantle/xai.grok-4.3, xai/grok-4.3 |
| `grok-4.5` | ?/N/N | ?/Y/Y | ?/Y/Y |  | xai/grok-4.5 |
| `grok-build-0.1` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `grok-imagine-image` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `grok-imagine-image-quality` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `grok-imagine-video` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `grok-imagine-video-1.5` | ?/N/— | ?/N/— | ?/N/— |  | — |

### z.ai  
`builtin.zai` — 8 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `glm-4.5` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | deepinfra/zai-org/GLM-4.5, novita/zai-org/glm-4.5, vercel_ai_gateway/zai/glm-4.5, wandb/zai-org/GLM-4.5, zai/glm-4.5 |
| `glm-4.5-air` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | novita/zai-org/glm-4.5-air, pinstripes/ps/glm-4.5-air, vercel_ai_gateway/zai/glm-4.5-air, zai/glm-4.5-air |
| `glm-4.6` | ?/N/Y | ?/N/N | ?/N/Y | ⚠️ par,think | baseten/zai-org/GLM-4.6, novita/zai-org/glm-4.6, openrouter/z-ai/glm-4.6, together_ai/zai-org/GLM-4.6, vercel_ai_gateway/zai/glm-4.6, zai/glm-4.6 |
| `glm-4.7` | ?/N/Y | ?/N/Y | ?/N/Y | ⚠️ par,vis,think | baseten/zai-org/GLM-4.7, novita/zai-org/glm-4.7, openrouter/z-ai/glm-4.7, together_ai/zai-org/GLM-4.7, zai/glm-4.7 |
| `glm-5` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | baseten/zai-org/GLM-5, openrouter/z-ai/glm-5, zai/glm-5 |
| `glm-5-turbo` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `glm-5.1` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | openrouter/z-ai/glm-5.1, zai/glm-5.1 |
| `glm-5.2` | ?/N/N | ?/N/N | ?/N/Y | ⚠️ think | cloudflare/@cf/zai-org/glm-5.2 |

### mlx_lm.server on 8080  
`provider-1566D9B4` — 4 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `mlx-community/GLM-4.7-Flash-4bit` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mlx-community/Qwen2.5-7B-Instruct-4bit` | ?/N/— | ?/N/— | ?/N/— |  | — |
| `mlx-community/Qwen2.5.1-Coder-7B-Instruct-4bit` | ?/N/— | ?/N/— | ?/N/— |  | — |

### MyVast  
`provider-E44F148D` — 1 models

| Model ID | Parallel (T/O/L) | Vision (T/O/L) | Thinking (T/O/L) | Δ | LiteLLM keys |
|---|---|---|---|---|---|
| `Qwen/Qwen3.5-122B-A10B-FP8` | ?/N/— | ?/N/— | ?/N/— |  | — |

## Table B — token limits

`maxOut` / `maxCtx` show **OURS → LiteLLM**. ⚠️ marks a mismatch.

### Alibaba Cloud  
`builtin.alibabacloud`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `deepseek-v4-flash` | 8192 → 384000 | 1000000 → 1048576 | ⚠️ |
| `deepseek-v4-flash-us` | None → — | None → — |  |
| `deepseek-v4-pro` | 8192 → 384000 | 1000000 → 1048576 | ⚠️ |
| `deepseek-v4-pro-us` | None → — | None → — |  |
| `glm-5.1` | None → 128000 | None → 202752 |  |
| `glm-5.2` | None → 262144 | None → 262144 |  |
| `glm-5.2-us` | None → — | None → — |  |
| `kimi-k2.5` | None → 262144 | None → 262144 |  |
| `kimi-k2.7-code` | None → 262144 | None → 262144 |  |
| `pre-qwen-mt-lite` | None → — | None → — |  |
| `pre-zhongyun-test-chat` | None → — | None → — |  |
| `qwen-flash` | None → 32768 | None → 997952 |  |
| `qwen-flash-2025-07-28` | None → 32768 | None → 997952 |  |
| `qwen-flash-2025-07-28-us` | None → — | None → — |  |
| `qwen-flash-us` | None → — | None → — |  |
| `qwen-mt-flash` | None → — | None → — |  |
| `qwen-mt-lite` | None → — | None → — |  |
| `qwen-mt-plus` | None → 8192 | None → 16384 |  |
| `qwen-plus` | None → 16384 | None → 129024 |  |
| `qwen-plus-2025-07-28` | None → 32768 | None → 997952 |  |
| `qwen-plus-2025-09-11` | None → 32768 | None → 997952 |  |
| `qwen-plus-2025-12-01` | None → — | None → — |  |
| `qwen-plus-2025-12-01-us` | None → — | None → — |  |
| `qwen-plus-us` | None → — | None → — |  |
| `qwen-vl-ocr` | None → — | None → — |  |
| `qwen-vl-ocr-2025-11-20` | None → — | None → — |  |
| `qwen3-14b` | None → 40960 | None → 40960 |  |
| `qwen3-235b-a22b` | None → 262144 | None → 262144 |  |
| `qwen3-235b-a22b-instruct-2507` | None → 262144 | None → 262144 |  |
| `qwen3-235b-a22b-thinking-2507` | None → 262144 | None → 262144 |  |
| `qwen3-30b-a3b` | None → 131072 | None → 131072 |  |
| `qwen3-30b-a3b-instruct-2507` | None → 262144 | None → 262144 |  |
| `qwen3-30b-a3b-thinking-2507` | None → 262144 | None → 262144 |  |
| `qwen3-32b` | None → 131072 | None → 131072 |  |
| `qwen3-8b` | None → 40960 | None → 40960 |  |
| `qwen3-asr-flash-2025-09-08-us` | None → — | None → — |  |
| `qwen3-asr-flash-us` | None → — | None → — |  |
| `qwen3-coder-30b-a3b-instruct` | None → 262144 | None → 262144 |  |
| `qwen3-coder-480b-a35b-instruct` | None → 262144 | None → 262144 |  |
| `qwen3-coder-flash` | None → 65536 | None → 997952 |  |
| `qwen3-coder-flash-2025-07-28` | None → 65536 | None → 997952 |  |
| `qwen3-coder-plus` | None → 65536 | None → 997952 |  |
| `qwen3-coder-plus-2025-07-22` | None → 65536 | None → 997952 |  |
| `qwen3-coder-plus-2025-09-23` | None → — | None → — |  |
| `qwen3-max` | None → 65536 | None → 262144 |  |
| `qwen3-max-2025-09-23` | None → — | None → — |  |
| `qwen3-max-preview` | None → 65536 | None → 258048 |  |
| `qwen3-next-80b-a3b-instruct` | None → 262144 | None → 262144 |  |
| `qwen3-next-80b-a3b-thinking` | None → 262144 | None → 262144 |  |
| `qwen3-vl-235b-a22b-instruct` | None → 262144 | None → 262144 |  |
| `qwen3-vl-235b-a22b-thinking` | None → 262144 | None → 262144 |  |
| `qwen3-vl-30b-a3b-instruct` | None → 262144 | None → 262144 |  |
| `qwen3-vl-30b-a3b-thinking` | None → 262144 | None → 262144 |  |
| `qwen3-vl-32b-instruct` | None → 32768 | None → 131072 |  |
| `qwen3-vl-32b-thinking` | None → 32768 | None → 131072 |  |
| `qwen3-vl-8b-instruct` | None → 32768 | None → 131072 |  |
| `qwen3-vl-8b-thinking` | None → — | None → — |  |
| `qwen3-vl-flash` | None → — | None → — |  |
| `qwen3-vl-flash-2025-10-15` | None → — | None → — |  |
| `qwen3-vl-flash-2025-10-15-us` | None → — | None → — |  |
| `qwen3-vl-flash-2026-01-22-us` | None → — | None → — |  |
| `qwen3-vl-flash-us` | None → — | None → — |  |
| `qwen3-vl-plus` | None → 32768 | None → 260096 |  |
| `qwen3-vl-plus-2025-09-23` | None → — | None → — |  |
| `qwen3-vl-plus-2025-12-19` | None → — | None → — |  |
| `qwen3-vl-plus-2025-12-19-us` | None → — | None → — |  |
| `qwen3.5-122b-a10b` | None → 262144 | None → 262144 |  |
| `qwen3.5-27b` | None → 65536 | None → 262144 |  |
| `qwen3.5-35b-a3b` | None → 65536 | None → 262144 |  |
| `qwen3.5-397b-a17b` | None → 65536 | None → 262144 |  |
| `qwen3.5-flash` | None → — | None → — |  |
| `qwen3.5-flash-2026-02-23` | None → — | None → — |  |
| `qwen3.5-plus` | None → 65536 | None → 991808 |  |
| `qwen3.6-35b-a3b` | None → 262144 | None → 262144 |  |
| `qwen3.6-flash` | None → — | None → — |  |
| `qwen3.6-flash-2026-04-16` | None → — | None → — |  |
| `qwen3.6-flash-us` | None → — | None → — |  |
| `qwen3.6-plus-2026-04-02` | None → — | None → — |  |
| `qwen3.7-max` | None → — | None → — |  |
| `qwen3.7-max-2026-05-20` | None → — | None → — |  |
| `qwen3.7-max-2026-06-08` | None → — | None → — |  |
| `qwen3.7-max-us` | None → — | None → — |  |
| `qwen3.7-plus` | None → — | None → — |  |
| `qwen3.7-plus-2026-05-26` | None → — | None → — |  |
| `qwen3.7-plus-us` | None → — | None → — |  |
| `wan2.6-image` | None → — | None → — |  |
| `wan2.6-t2i` | None → — | None → — |  |

### Anthropic  
`builtin.anthropic`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `claude-fable-5` | 128000 → 128000 | 1000000 → 1000000 |  |
| `claude-haiku-4-5-20251001` | 64000 → 64000 | 200000 → 200000 |  |
| `claude-opus-4-1-20250805` | 32000 → 32000 | 200000 → 200000 |  |
| `claude-opus-4-5-20251101` | 64000 → 64000 | 200000 → 200000 |  |
| `claude-opus-4-6` | 128000 → 128000 | 1000000 → 1000000 |  |
| `claude-opus-4-7` | 128000 → 128000 | 1000000 → 1000000 |  |
| `claude-opus-4-8` | 128000 → 128000 | 1000000 → 1000000 |  |
| `claude-sonnet-4-5-20250929` | 64000 → 64000 | 1000000 → 200000 | ⚠️ |
| `claude-sonnet-4-6` | 128000 → 64000 | 1000000 → 1000000 | ⚠️ |
| `claude-sonnet-5` | 128000 → 128000 | 1000000 → 1000000 |  |

### Gemini  
`builtin.gemini`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `antigravity-preview-05-2026` | 65536 → — | 131072 → — |  |
| `aqa` | 1024 → — | 7168 → — |  |
| `deep-research-max-preview-04-2026` | 65536 → — | 131072 → — |  |
| `deep-research-preview-04-2026` | 65536 → — | 131072 → — |  |
| `deep-research-pro-preview-12-2025` | 65536 → 32768 | 131072 → 65536 | ⚠️ |
| `gemini-2.0-flash` | 8192 → 8192 | 1048576 → 1048576 |  |
| `gemini-2.0-flash-001` | 8192 → 1000000 | 1048576 → 1048576 | ⚠️ |
| `gemini-2.0-flash-lite` | 8192 → 8192 | 1048576 → 1048576 |  |
| `gemini-2.0-flash-lite-001` | 8192 → 8192 | 1048576 → 1048576 |  |
| `gemini-2.5-computer-use-preview-10-2025` | 65536 → 64000 | 131072 → 128000 | ⚠️ |
| `gemini-2.5-flash` | 65536 → 1000000 | 1048576 → 1048576 | ⚠️ |
| `gemini-2.5-flash-image` | 32768 → 32768 | 32768 → 32768 |  |
| `gemini-2.5-flash-lite` | 65536 → 65536 | 1048576 → 1048576 |  |
| `gemini-2.5-flash-native-audio-latest` | 8192 → 8192 | 131072 → 1048576 | ⚠️ |
| `gemini-2.5-flash-native-audio-preview-09-2025` | 8192 → 8192 | 131072 → 1048576 | ⚠️ |
| `gemini-2.5-flash-native-audio-preview-12-2025` | 8192 → 8192 | 131072 → 1048576 | ⚠️ |
| `gemini-2.5-flash-preview-tts` | 16384 → — | 8192 → — |  |
| `gemini-2.5-pro` | 65536 → 1000000 | 1048576 → 1048576 | ⚠️ |
| `gemini-2.5-pro-preview-tts` | 16384 → 65535 | 8192 → 1048576 | ⚠️ |
| `gemini-3-flash-preview` | 65536 → 65536 | 1048576 → 1048576 |  |
| `gemini-3-pro-image` | 32768 → 32768 | 131072 → 65536 | ⚠️ |
| `gemini-3-pro-image-preview` | 32768 → 32768 | 131072 → 65536 | ⚠️ |
| `gemini-3-pro-preview` | 65536 → 65536 | 1048576 → 1048576 |  |
| `gemini-3.1-flash-image` | 65536 → 32768 | 65536 → 65536 | ⚠️ |
| `gemini-3.1-flash-image-preview` | 65536 → 32768 | 65536 → 65536 | ⚠️ |
| `gemini-3.1-flash-lite` | 65536 → 65536 | 1048576 → 1048576 |  |
| `gemini-3.1-flash-lite-image` | 65536 → — | 65536 → — |  |
| `gemini-3.1-flash-lite-preview` | 65536 → 65536 | 1048576 → 1048576 |  |
| `gemini-3.1-flash-live-preview` | 65536 → 65536 | 131072 → 131072 |  |
| `gemini-3.1-flash-tts-preview` | 16384 → — | 8192 → — |  |
| `gemini-3.1-pro-preview` | 65536 → 65536 | 1048576 → 1048576 |  |
| `gemini-3.1-pro-preview-customtools` | 65536 → 65536 | 1048576 → 1048576 |  |
| `gemini-3.5-flash` | 65536 → 65535 | 1048576 → 1048576 | ⚠️ |
| `gemini-3.5-live-translate-preview` | 32768 → — | 16384 → — |  |
| `gemini-embedding-001` | 1 → 2048 | 2048 → 2048 | ⚠️ |
| `gemini-embedding-2` | 1 → 8192 | 8192 → 8192 | ⚠️ |
| `gemini-embedding-2-preview` | 1 → 8192 | 8192 → 8192 | ⚠️ |
| `gemini-flash-latest` | 65536 → 65535 | 1048576 → 1048576 | ⚠️ |
| `gemini-flash-lite-latest` | 65536 → 65535 | 1048576 → 1048576 | ⚠️ |
| `gemini-omni-flash-preview` | 65536 → 65535 | 131072 → 1048576 | ⚠️ |
| `gemini-pro-latest` | 65536 → 65535 | 1048576 → 1048576 | ⚠️ |
| `gemini-robotics-er-1.5-preview` | 65536 → 65535 | 1048576 → 1048576 | ⚠️ |
| `gemini-robotics-er-1.6-preview` | 65536 → — | 131072 → — |  |
| `gemma-4-26b-a4b-it` | 32768 → 256000 | 262144 → 256000 | ⚠️ |
| `gemma-4-31b-it` | 32768 → 262144 | 262144 → 262144 | ⚠️ |
| `imagen-4.0-fast-generate-001` | 8192 → — | 480 → — |  |
| `imagen-4.0-generate-001` | 8192 → — | 480 → — |  |
| `imagen-4.0-ultra-generate-001` | 8192 → — | 480 → — |  |
| `lyria-3-clip-preview` | 65536 → 8192 | 1048576 → 131072 | ⚠️ |
| `lyria-3-pro-preview` | 65536 → 8192 | 1048576 → 131072 | ⚠️ |
| `nano-banana-pro-preview` | 32768 → — | 131072 → — |  |
| `veo-3.1-fast-generate-preview` | 8192 → 1024 | 480 → 1024 | ⚠️ |
| `veo-3.1-generate-preview` | 8192 → 1024 | 480 → 1024 | ⚠️ |
| `veo-3.1-lite-generate-preview` | 8192 → 1024 | 480 → 1024 | ⚠️ |

### Hugging Face  
`builtin.huggingface`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `CohereLabs/aya-expanse-32b` | None → — | None → — |  |
| `CohereLabs/aya-vision-32b` | None → — | None → — |  |
| `CohereLabs/c4ai-command-a-03-2025` | None → — | None → — |  |
| `CohereLabs/c4ai-command-r-08-2024` | None → — | None → — |  |
| `CohereLabs/c4ai-command-r7b-12-2024` | None → — | None → — |  |
| `CohereLabs/c4ai-command-r7b-arabic-02-2025` | None → — | None → — |  |
| `CohereLabs/command-a-plus-05-2026-bf16` | None → — | None → — |  |
| `CohereLabs/command-a-plus-05-2026-fp8` | None → — | None → — |  |
| `CohereLabs/command-a-plus-05-2026-w4a4` | None → — | None → — |  |
| `CohereLabs/command-a-reasoning-08-2025` | None → 4000 | None → 256000 |  |
| `CohereLabs/command-a-translate-08-2025` | None → 4000 | None → 256000 |  |
| `CohereLabs/command-a-vision-07-2025` | None → 4000 | None → 128000 |  |
| `CohereLabs/tiny-aya-earth` | None → — | None → — |  |
| `CohereLabs/tiny-aya-global` | None → — | None → — |  |
| `CohereLabs/tiny-aya-water` | None → — | None → — |  |
| `MiniMaxAI/MiniMax-M1-80k` | None → 40000 | None → 1000000 |  |
| `MiniMaxAI/MiniMax-M2` | None → 204800 | None → 204800 |  |
| `MiniMaxAI/MiniMax-M2.1` | None → 131072 | None → 1000000 |  |
| `MiniMaxAI/MiniMax-M2.5` | None → 197000 | None → 1000000 |  |
| `MiniMaxAI/MiniMax-M2.7` | None → 1000192 | None → 1000192 |  |
| `MiniMaxAI/MiniMax-M3` | None → 512000 | None → 1000000 |  |
| `Qwen/Qwen2.5-72B-Instruct` | None → 131072 | None → 131072 |  |
| `Qwen/Qwen2.5-7B-Instruct` | None → 32768 | None → 32768 |  |
| `Qwen/Qwen2.5-VL-72B-Instruct` | None → 131072 | None → 131072 |  |
| `Qwen/Qwen3-14B` | None → 40960 | None → 40960 |  |
| `Qwen/Qwen3-235B-A22B` | None → 262144 | None → 262144 |  |
| `Qwen/Qwen3-235B-A22B-Instruct-2507` | None → 262144 | None → 262144 |  |
| `Qwen/Qwen3-235B-A22B-Thinking-2507` | None → 262144 | 256000 → 262144 | ⚠️ |
| `Qwen/Qwen3-32B` | None → 131072 | None → 131072 |  |
| `Qwen/Qwen3-Coder-30B-A3B-Instruct` | None → 262144 | None → 262144 |  |
| `Qwen/Qwen3-Coder-480B-A35B-Instruct` | None → 262144 | None → 262144 |  |
| `Qwen/Qwen3-Coder-Next` | None → — | None → — |  |
| `Qwen/Qwen3-Next-80B-A3B-Instruct` | None → 262144 | 262144 → 262144 |  |
| `Qwen/Qwen3-VL-235B-A22B-Instruct` | None → 262144 | None → 262144 |  |
| `Qwen/Qwen3-VL-235B-A22B-Thinking` | None → 262144 | None → 262144 |  |
| `Qwen/Qwen3-VL-30B-A3B-Instruct` | None → 262144 | None → 262144 |  |
| `Qwen/Qwen3.5-122B-A10B` | None → 262144 | None → 262144 |  |
| `Qwen/Qwen3.5-27B` | None → 65536 | None → 262144 |  |
| `Qwen/Qwen3.5-35B-A3B` | None → 65536 | None → 262144 |  |
| `Qwen/Qwen3.5-397B-A17B` | None → 65536 | 262144 → 262144 |  |
| `Qwen/Qwen3.5-9B` | None → — | None → — |  |
| `Qwen/Qwen3.6-27B` | None → 262144 | None → 262144 |  |
| `Qwen/Qwen3.6-35B-A3B` | None → 262144 | None → 262144 |  |
| `Sao10K/L3-8B-Lunaris-v1` | None → — | None → — |  |
| `Sao10K/L3-8B-Stheno-v3.2` | None → 32000 | None → 8192 |  |
| `XiaomiMiMo/MiMo-V2.5-Pro` | None → 16384 | None → 1048576 |  |
| `alpindale/WizardLM-2-8x22B` | None → 65536 | None → 65536 |  |
| `baidu/ERNIE-4.5-VL-424B-A47B-Base-PT` | None → — | None → — |  |
| `deepcogito/cogito-671b-v2.1` | None → — | None → — |  |
| `deepcogito/cogito-671b-v2.1-FP8` | None → — | None → — |  |
| `deepreinforce-ai/Ornith-1.0-35B` | None → — | None → — |  |
| `deepreinforce-ai/Ornith-1.0-35B-FP8` | None → — | None → — |  |
| `deepseek-ai/DeepSeek-R1` | 20480 → 163840 | 128000 → 163840 | ⚠️ |
| `deepseek-ai/DeepSeek-R1-0528` | None → 164000 | None → 164000 |  |
| `deepseek-ai/DeepSeek-R1-Distill-Llama-70B` | None → 131072 | None → 131072 |  |
| `deepseek-ai/DeepSeek-V3` | 8192 → 163840 | 65536 → 163840 | ⚠️ |
| `deepseek-ai/DeepSeek-V3-0324` | None → 163840 | None → 163840 |  |
| `deepseek-ai/DeepSeek-V3.1` | 16384 → 163840 | 128000 → 163840 | ⚠️ |
| `deepseek-ai/DeepSeek-V3.1-Terminus` | None → 163840 | None → 163840 |  |
| `deepseek-ai/DeepSeek-V3.2` | None → 163840 | None → 163840 |  |
| `deepseek-ai/DeepSeek-V3.2-Exp` | None → 163840 | None → 163840 |  |
| `deepseek-ai/DeepSeek-V4-Flash` | None → 384000 | None → 1048576 |  |
| `deepseek-ai/DeepSeek-V4-Pro` | None → 384000 | None → 1048576 |  |
| `google/gemma-3-12b-it` | None → 131072 | None → 131072 |  |
| `google/gemma-3-27b-it` | None → 131072 | None → 131072 |  |
| `google/gemma-3-4b-it` | None → 131072 | None → 131072 |  |
| `google/gemma-3n-E4B-it` | None → — | None → — |  |
| `google/gemma-4-26B-A4B-it` | None → 256000 | None → 256000 |  |
| `google/gemma-4-31B-it` | None → 262144 | None → 262144 |  |
| `inclusionAI/Ling-2.6-1T` | None → — | None → — |  |
| `meta-llama/Llama-3.1-8B-Instruct` | None → 131072 | None → 131072 |  |
| `meta-llama/Llama-3.3-70B-Instruct` | None → 131072 | None → 131072 |  |
| `meta-llama/Llama-4-Maverick-17B-128E-Instruct-FP8` | None → 1048576 | None → 1048576 |  |
| `meta-llama/Llama-4-Scout-17B-16E-Instruct` | None → 327680 | None → 10485760 |  |
| `meta-llama/Llama-Guard-4-12B` | None → 163840 | None → 163840 |  |
| `microsoft/phi-4` | None → 16384 | None → 16384 |  |
| `moonshotai/Kimi-K2-Instruct` | None → 131072 | None → 131072 |  |
| `moonshotai/Kimi-K2-Instruct-0905` | None → 262144 | 262144 → 262144 |  |
| `moonshotai/Kimi-K2.5` | 256000 → 262144 | 256000 → 262144 | ⚠️ |
| `moonshotai/Kimi-K2.6` | None → 262144 | None → 262144 |  |
| `moonshotai/Kimi-K2.7-Code` | None → 262144 | None → 262144 |  |
| `nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-BF16` | None → — | None → — |  |
| `nvidia/NVIDIA-Nemotron-3-Ultra-550B-A55B-NVFP4` | None → — | None → — |  |
| `openai/gpt-oss-120b` | 32768 → 131072 | 131072 → 131072 | ⚠️ |
| `openai/gpt-oss-20b` | 32768 → 131072 | 131072 → 131072 | ⚠️ |
| `openai/gpt-oss-safeguard-20b` | None → 131072 | None → 131072 |  |
| `pearl-ai/Gemma-4-31B-it-pearl` | None → — | None → — |  |
| `prism-ml/Ternary-Bonsai-27B-gguf` | None → — | None → — |  |
| `stepfun-ai/Step-3.5-Flash` | None → — | None → — |  |
| `stepfun-ai/Step-3.7-Flash` | None → — | None → — |  |
| `zai-org/AutoGLM-Phone-9B-Multilingual` | None → 65536 | None → 65536 |  |
| `zai-org/GLM-4-32B-0414` | None → — | None → — |  |
| `zai-org/GLM-4.5-Air` | None → 128000 | None → 131072 |  |
| `zai-org/GLM-4.5V` | None → 32000 | None → 128000 |  |
| `zai-org/GLM-4.6` | 200000 → 200000 | 200000 → 204800 | ⚠️ |
| `zai-org/GLM-4.6V-Flash` | None → — | None → — |  |
| `zai-org/GLM-4.7` | 200000 → 200000 | 200000 → 204800 | ⚠️ |
| `zai-org/GLM-4.7-Flash` | None → 131072 | None → 200000 |  |
| `zai-org/GLM-5` | None → 128000 | None → 202752 |  |
| `zai-org/GLM-5.1` | None → 128000 | None → 202752 |  |
| `zai-org/GLM-5.1-FP8` | None → — | None → — |  |
| `zai-org/GLM-5.2` | None → 262144 | None → 262144 |  |

### LM Studio  
`builtin.lmstudio`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `qwen2.5-coder-7b-instruct-mlx` | None → — | None → — |  |
| `text-embedding-nomic-embed-text-v1.5` | None → — | None → — |  |

### Mistral  
`builtin.mistral`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `codestral-2508` | 256000 → 256000 | 256000 → 256000 |  |
| `codestral-embed` | None → 8192 | 8192 → 8192 |  |
| `codestral-embed-2505` | None → 8192 | 8192 → 8192 |  |
| `codestral-latest` | 8191 → 8191 | 256000 → 32000 | ⚠️ |
| `devstral-2512` | 256000 → 256000 | 262144 → 262144 |  |
| `devstral-latest` | 256000 → 256000 | 262144 → 256000 | ⚠️ |
| `devstral-medium-latest` | 256000 → 256000 | 262144 → 256000 | ⚠️ |
| `labs-leanstral-1-5` | None → — | 262144 → — |  |
| `labs-leanstral-1-5-1` | None → — | 262144 → — |  |
| `magistral-medium-2509` | 40000 → 40000 | 131072 → 40000 | ⚠️ |
| `magistral-medium-latest` | 40000 → 40000 | 131072 → 40000 | ⚠️ |
| `magistral-small-2509` | None → 8192 | 131072 → 128000 | ⚠️ |
| `magistral-small-latest` | 40000 → 40000 | 262144 → 40000 | ⚠️ |
| `ministral-14b-2512` | None → 262144 | 262144 → 262144 |  |
| `ministral-14b-latest` | 262144 → — | 262144 → — |  |
| `ministral-3b-2512` | None → 131072 | 131072 → 131072 |  |
| `ministral-3b-latest` | 4096 → — | 131072 → — |  |
| `ministral-8b-2512` | 262144 → 262144 | 262144 → 262144 |  |
| `ministral-8b-latest` | 262144 → 262144 | 262144 → 262144 |  |
| `mistral-code-agent-latest` | None → — | 262144 → — |  |
| `mistral-code-fim-latest` | None → — | 256000 → — |  |
| `mistral-code-latest` | None → — | 256000 → — |  |
| `mistral-embed` | None → 8192 | 8192 → 8192 |  |
| `mistral-embed-2312` | None → — | 8192 → — |  |
| `mistral-large-2512` | 262144 → 262144 | 262144 → 262144 |  |
| `mistral-large-latest` | 262144 → 262144 | 262144 → 262144 |  |
| `mistral-medium` | 8191 → 8191 | 262144 → 32000 | ⚠️ |
| `mistral-medium-2505` | 8191 → 128000 | 131072 → 131072 | ⚠️ |
| `mistral-medium-2508` | 131072 → 131072 | 131072 → 131072 |  |
| `mistral-medium-2604` | 262144 → 262144 | 262144 → 262144 |  |
| `mistral-medium-3` | 8191 → 8191 | 262144 → 128000 | ⚠️ |
| `mistral-medium-3-5` | 262144 → 262144 | 262144 → 262144 |  |
| `mistral-medium-3.5` | None → — | 262144 → — |  |
| `mistral-medium-latest` | 262144 → 262144 | 262144 → 262144 |  |
| `mistral-moderation-2603` | None → — | 131072 → — |  |
| `mistral-ocr-2512` | None → — | 16384 → — |  |
| `mistral-ocr-3` | None → — | 16384 → — |  |
| `mistral-ocr-3-0` | None → — | 16384 → — |  |
| `mistral-ocr-4` | None → — | 16384 → — |  |
| `mistral-ocr-4-0` | None → — | 16384 → — |  |
| `mistral-ocr-latest` | None → — | 16384 → — |  |
| `mistral-small-2506` | None → — | 131072 → — |  |
| `mistral-small-2603` | None → — | 262144 → — |  |
| `mistral-small-latest` | 131072 → 131072 | 262144 → 131072 | ⚠️ |
| `mistral-tiny-2407` | None → — | 131072 → — |  |
| `mistral-tiny-latest` | 8191 → — | 131072 → — |  |
| `mistral-vibe-cli-fast` | None → — | 262144 → — |  |
| `mistral-vibe-cli-latest` | None → — | 262144 → — |  |
| `mistral-vibe-cli-with-tools` | None → — | 262144 → — |  |
| `open-mistral-nemo` | 128000 → 128000 | 131072 → 128000 | ⚠️ |
| `open-mistral-nemo-2407` | 128000 → 128000 | 131072 → 128000 | ⚠️ |
| `voxtral-mini-2602` | None → — | 16384 → — |  |
| `voxtral-mini-latest` | 8192 → — | 16384 → — |  |
| `voxtral-mini-realtime-2602` | None → — | 32768 → — |  |
| `voxtral-mini-realtime-latest` | None → — | 32768 → — |  |
| `voxtral-mini-transcribe-realtime-2602` | None → — | 32768 → — |  |
| `voxtral-mini-tts-2603` | None → — | 4096 → — |  |
| `voxtral-mini-tts-latest` | None → — | 4096 → — |  |
| `voxtral-small-2507` | None → — | 32768 → — |  |
| `voxtral-small-latest` | 8192 → — | 32768 → — |  |

### Ollama (local)  
`builtin.ollama`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `qwen2.5-coder:7b` | None → — | None → — |  |

### Ollama (cloud)  
`builtin.ollama-cloud`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `deepseek-v3.1:671b` | None → — | None → — |  |
| `deepseek-v3.2` | 163840 → 163840 | 163840 → 163840 |  |
| `deepseek-v4-flash` | 8192 → 384000 | 1000000 → 1048576 | ⚠️ |
| `deepseek-v4-pro` | 8192 → 384000 | 1000000 → 1048576 | ⚠️ |
| `devstral-2:123b` | None → — | None → — |  |
| `devstral-small-2:24b` | None → — | None → — |  |
| `gemini-3-flash-preview` | 65535 → 65536 | 1048576 → 1048576 | ⚠️ |
| `gemma3:12b` | None → — | None → — |  |
| `gemma3:27b` | None → — | None → — |  |
| `gemma3:4b` | None → — | None → — |  |
| `gemma4:31b` | None → — | None → — |  |
| `glm-4.7` | None → 200000 | None → 204800 |  |
| `glm-5` | None → 128000 | None → 202752 |  |
| `glm-5.1` | None → 128000 | None → 202752 |  |
| `glm-5.2` | None → 262144 | None → 262144 |  |
| `gpt-oss:120b` | None → — | None → — |  |
| `gpt-oss:20b` | None → — | None → — |  |
| `kimi-k2.5` | None → 262144 | None → 262144 |  |
| `kimi-k2.6` | None → 262144 | None → 262144 |  |
| `kimi-k2.7-code` | None → 262144 | None → 262144 |  |
| `minimax-m2.1` | None → 131072 | None → 1000000 |  |
| `minimax-m2.5` | None → 197000 | None → 1000000 |  |
| `minimax-m2.7` | None → 1000192 | None → 1000192 |  |
| `minimax-m3` | 512000 → 512000 | 512000 → 1000000 | ⚠️ |
| `ministral-3:14b` | None → — | None → — |  |
| `ministral-3:3b` | None → — | None → — |  |
| `ministral-3:8b` | None → — | None → — |  |
| `mistral-large-3:675b` | None → — | None → — |  |
| `nemotron-3-nano:30b` | None → — | None → — |  |
| `nemotron-3-super` | None → — | None → — |  |
| `nemotron-3-ultra` | None → — | None → — |  |
| `qwen3-coder-next` | None → — | None → — |  |
| `qwen3-coder:480b` | None → — | None → — |  |
| `qwen3.5:397b` | 65536 → — | None → — |  |

### OpenAI  
`builtin.openai`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `babbage-002` | 4096 → 4096 | 16384 → 16384 |  |
| `chat-latest` | 16384 → — | 128000 → — |  |
| `chatgpt-image-latest` | None → — | None → — |  |
| `davinci-002` | 4096 → 4096 | 16384 → 16384 |  |
| `gpt-3.5-turbo` | 4096 → 4096 | 16385 → 16385 |  |
| `gpt-3.5-turbo-0125` | 4096 → 4096 | 16385 → 16385 |  |
| `gpt-3.5-turbo-1106` | 4096 → 4096 | 16385 → 16385 |  |
| `gpt-3.5-turbo-16k` | 4096 → 4096 | 16385 → 16385 |  |
| `gpt-3.5-turbo-instruct` | 4096 → 4096 | 8192 → 8192 |  |
| `gpt-3.5-turbo-instruct-0914` | 4097 → 4097 | 8192 → 8192 |  |
| `gpt-4` | 4096 → 4096 | 8192 → 32768 | ⚠️ |
| `gpt-4-0613` | 4096 → 4096 | 8192 → 32768 | ⚠️ |
| `gpt-4-turbo` | 4096 → 4096 | 128000 → 128000 |  |
| `gpt-4-turbo-2024-04-09` | 4096 → 4096 | 128000 → 128000 |  |
| `gpt-4.1` | 32768 → 32768 | 1047576 → 1047576 |  |
| `gpt-4.1-2025-04-14` | 32768 → 32768 | 1047576 → 1047576 |  |
| `gpt-4.1-mini` | 32768 → 32768 | 1047576 → 1047576 |  |
| `gpt-4.1-mini-2025-04-14` | 32768 → 32768 | 1047576 → 1047576 |  |
| `gpt-4.1-nano` | 32768 → 32768 | 1047576 → 1047576 |  |
| `gpt-4.1-nano-2025-04-14` | 32768 → 32768 | 1047576 → 1047576 |  |
| `gpt-4o` | 16384 → 16384 | 128000 → 131072 | ⚠️ |
| `gpt-4o-2024-05-13` | 4096 → 4096 | 128000 → 128000 |  |
| `gpt-4o-2024-08-06` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-4o-2024-11-20` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-4o-mini` | 16384 → 16384 | 128000 → 131072 | ⚠️ |
| `gpt-4o-mini-2024-07-18` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-4o-mini-search-preview` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-4o-mini-search-preview-2025-03-11` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-4o-mini-transcribe` | 2000 → 2000 | 16000 → 16000 |  |
| `gpt-4o-mini-transcribe-2025-03-20` | 2000 → 2000 | 16000 → 16000 |  |
| `gpt-4o-mini-transcribe-2025-12-15` | 2000 → 2000 | 16000 → 16000 |  |
| `gpt-4o-mini-tts` | None → — | None → — |  |
| `gpt-4o-mini-tts-2025-03-20` | None → — | None → — |  |
| `gpt-4o-mini-tts-2025-12-15` | None → — | None → — |  |
| `gpt-4o-search-preview` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-4o-search-preview-2025-03-11` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-4o-transcribe` | 2000 → 2000 | 16000 → 16000 |  |
| `gpt-4o-transcribe-diarize` | 2000 → 2000 | 16000 → 16000 |  |
| `gpt-5` | 128000 → 128000 | 272000 → 409600 | ⚠️ |
| `gpt-5-2025-08-07` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5-chat-latest` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-5-codex` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5-mini` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5-mini-2025-08-07` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5-nano` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5-nano-2025-08-07` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5-pro` | 128000 → 128000 | 400000 → 400000 |  |
| `gpt-5-pro-2025-10-06` | 128000 → 128000 | 400000 → 400000 |  |
| `gpt-5-search-api` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5-search-api-2025-10-14` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5.1` | 128000 → 128000 | 272000 → 409600 | ⚠️ |
| `gpt-5.1-2025-11-13` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5.1-chat-latest` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-5.1-codex` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5.1-codex-max` | 128000 → 128000 | 272000 → 400000 | ⚠️ |
| `gpt-5.1-codex-mini` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5.2` | 128000 → 128000 | 272000 → 409600 | ⚠️ |
| `gpt-5.2-2025-12-11` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5.2-chat-latest` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-5.2-codex` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5.2-pro` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5.2-pro-2025-12-11` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5.3-chat-latest` | 16384 → 64000 | 128000 → 128000 | ⚠️ |
| `gpt-5.3-codex` | 128000 → 128000 | 272000 → 272000 |  |
| `gpt-5.4` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.4-2026-03-05` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.4-mini` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.4-mini-2026-03-17` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.4-nano` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.4-nano-2026-03-17` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.4-pro` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.4-pro-2026-03-05` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.5` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.5-2026-04-23` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.5-pro` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.5-pro-2026-04-23` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.6-luna` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.6-sol` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-5.6-terra` | 128000 → 128000 | 1050000 → 1050000 |  |
| `gpt-audio` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-audio-1.5` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-audio-2025-08-28` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-audio-mini` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-audio-mini-2025-10-06` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-audio-mini-2025-12-15` | 16384 → 16384 | 128000 → 128000 |  |
| `gpt-image-1` | None → — | None → — |  |
| `gpt-image-1-mini` | None → — | None → — |  |
| `gpt-image-1.5` | None → — | None → — |  |
| `gpt-image-2` | None → — | None → — |  |
| `gpt-image-2-2026-04-21` | None → — | None → — |  |
| `gpt-realtime` | 4096 → 4096 | 32000 → 32000 |  |
| `gpt-realtime-1.5` | 4096 → 4096 | 32000 → 32000 |  |
| `gpt-realtime-2` | 4096 → 4096 | 32000 → 32000 |  |
| `gpt-realtime-2.1` | 32000 → 32000 | 128000 → 128000 |  |
| `gpt-realtime-2.1-mini` | 4096 → 4096 | 128000 → 128000 |  |
| `gpt-realtime-2025-08-28` | 4096 → 4096 | 32000 → 32000 |  |
| `gpt-realtime-mini` | 4096 → 4096 | 128000 → 128000 |  |
| `gpt-realtime-mini-2025-10-06` | 4096 → 4096 | 128000 → 128000 |  |
| `gpt-realtime-mini-2025-12-15` | 4096 → 4096 | 128000 → 128000 |  |
| `gpt-realtime-translate` | None → — | None → — |  |
| `gpt-realtime-whisper` | None → — | None → — |  |
| `o1` | 100000 → 100000 | 200000 → 200000 |  |
| `o1-2024-12-17` | 100000 → 100000 | 200000 → 200000 |  |
| `o1-pro` | 100000 → 100000 | 200000 → 200000 |  |
| `o1-pro-2025-03-19` | 100000 → 100000 | 200000 → 200000 |  |
| `o3` | 100000 → 100000 | 200000 → 200000 |  |
| `o3-2025-04-16` | 100000 → 100000 | 200000 → 200000 |  |
| `o3-deep-research` | 100000 → 100000 | 200000 → 200000 |  |
| `o3-deep-research-2025-06-26` | 100000 → 100000 | 200000 → 200000 |  |
| `o3-mini` | 100000 → 100000 | 200000 → 200000 |  |
| `o3-mini-2025-01-31` | 100000 → 100000 | 200000 → 200000 |  |
| `o3-pro` | 100000 → 100000 | 200000 → 200000 |  |
| `o3-pro-2025-06-10` | 100000 → 100000 | 200000 → 200000 |  |
| `o4-mini` | 100000 → 100000 | 200000 → 200000 |  |
| `o4-mini-2025-04-16` | 100000 → 100000 | 200000 → 200000 |  |
| `o4-mini-deep-research` | 100000 → 100000 | 200000 → 200000 |  |
| `o4-mini-deep-research-2025-06-26` | 100000 → 100000 | 200000 → 200000 |  |
| `omni-moderation-2024-09-26` | 0 → — | 32768 → 32768 |  |
| `omni-moderation-latest` | 0 → — | 32768 → 32768 |  |
| `sora-2` | None → — | None → — |  |
| `sora-2-pro` | None → — | None → — |  |
| `text-embedding-3-large` | None → 8191 | 8191 → 8191 |  |
| `text-embedding-3-small` | None → 8191 | 8191 → 8191 |  |
| `text-embedding-ada-002` | None → 8191 | 8191 → 8191 |  |
| `tts-1` | None → — | None → — |  |
| `tts-1-1106` | None → — | None → — |  |
| `tts-1-hd` | None → — | None → — |  |
| `tts-1-hd-1106` | None → — | None → — |  |
| `whisper-1` | None → — | None → — |  |

### OpenRouter  
`builtin.openrouter`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `ai21/jamba-large-1.7` | None → 256000 | None → 256000 |  |
| `aion-labs/aion-2.0` | None → — | None → — |  |
| `aion-labs/aion-3.0` | None → — | None → — |  |
| `aion-labs/aion-3.0-mini` | None → — | None → — |  |
| `aion-labs/aion-rp-llama-3.1-8b` | None → — | None → — |  |
| `allenai/olmo-3-32b-think` | None → 4096 | None → 32768 |  |
| `amazon/nova-2-lite-v1` | None → — | None → — |  |
| `amazon/nova-lite-v1` | None → 10000 | None → 300000 |  |
| `amazon/nova-micro-v1` | None → 10000 | None → 128000 |  |
| `amazon/nova-premier-v1` | None → 10000 | None → 1000000 |  |
| `amazon/nova-pro-v1` | None → 10000 | None → 300000 |  |
| `anthracite-org/magnum-v4-72b` | None → — | None → — |  |
| `anthropic/claude-3-haiku` | 4096 → 4096 | 200000 → 200000 |  |
| `anthropic/claude-fable-5` | 128000 → 128000 | 1000000 → 1000000 |  |
| `anthropic/claude-haiku-4.5` | 200000 → 200000 | 200000 → 200000 |  |
| `anthropic/claude-opus-4` | 32000 → 32000 | 200000 → 409600 | ⚠️ |
| `anthropic/claude-opus-4.1` | 32000 → 32000 | 200000 → 200000 |  |
| `anthropic/claude-opus-4.5` | 32000 → 64000 | 200000 → 409600 | ⚠️ |
| `anthropic/claude-opus-4.6` | 128000 → 128000 | 1000000 → 1000000 |  |
| `anthropic/claude-opus-4.7` | 128000 → 128000 | 1000000 → 1000000 |  |
| `anthropic/claude-opus-4.7-fast` | None → — | None → — |  |
| `anthropic/claude-opus-4.8` | None → — | None → — |  |
| `anthropic/claude-opus-4.8-fast` | None → — | None → — |  |
| `anthropic/claude-sonnet-4` | 64000 → 64000 | 1000000 → 1000000 |  |
| `anthropic/claude-sonnet-4.5` | 1000000 → 1000000 | 1000000 → 1000000 |  |
| `anthropic/claude-sonnet-4.6` | 128000 → 128000 | 1000000 → 1000000 |  |
| `anthropic/claude-sonnet-5` | 128000 → 128000 | 1000000 → 1000000 |  |
| `arcee-ai/coder-large` | None → — | None → — |  |
| `arcee-ai/trinity-large-thinking` | None → — | None → — |  |
| `arcee-ai/virtuoso-large` | None → — | None → — |  |
| `baidu/ernie-4.5-vl-424b-a47b` | None → 16000 | None → 123000 |  |
| `bytedance-seed/seed-1.6` | None → — | None → — |  |
| `bytedance-seed/seed-1.6-flash` | None → — | None → — |  |
| `bytedance-seed/seed-2.0-lite` | None → — | None → — |  |
| `bytedance-seed/seed-2.0-mini` | None → — | None → — |  |
| `bytedance/ui-tars-1.5-7b` | 2048 → 2048 | 131072 → 131072 |  |
| `cognitivecomputations/dolphin-mistral-24b-venice-edition` | None → — | None → — |  |
| `cognitivecomputations/dolphin-mistral-24b-venice-edition:free` | None → — | None → — |  |
| `cohere/command-a` | None → 8000 | None → 256000 |  |
| `cohere/command-r-08-2024` | None → 4096 | None → 128000 |  |
| `cohere/command-r-plus-08-2024` | None → 4096 | None → 128000 |  |
| `cohere/command-r7b-12-2024` | None → 4096 | None → 128000 |  |
| `cohere/north-mini-code:free` | None → — | None → — |  |
| `deepcogito/cogito-v2.1-671b` | None → — | None → — |  |
| `deepseek/deepseek-chat` | 8192 → 8192 | 65536 → 131072 | ⚠️ |
| `deepseek/deepseek-chat-v3-0324` | 8192 → 8192 | 65536 → 65536 |  |
| `deepseek/deepseek-chat-v3.1` | 163840 → 163840 | 163840 → 163840 |  |
| `deepseek/deepseek-r1` | 8192 → 163840 | 65336 → 163840 | ⚠️ |
| `deepseek/deepseek-r1-0528` | 8192 → 164000 | 65336 → 164000 | ⚠️ |
| `deepseek/deepseek-r1-distill-llama-70b` | None → 131072 | None → 131072 |  |
| `deepseek/deepseek-v3.1-terminus` | None → 163840 | None → 163840 |  |
| `deepseek/deepseek-v3.2` | 163840 → 163840 | 163840 → 163840 |  |
| `deepseek/deepseek-v3.2-exp` | 163840 → 163840 | 163840 → 163840 |  |
| `deepseek/deepseek-v4-flash` | 8192 → 384000 | 1000000 → 1048576 | ⚠️ |
| `deepseek/deepseek-v4-pro` | 8192 → 384000 | 1000000 → 1048576 | ⚠️ |
| `google/gemini-2.5-flash` | 8192 → 1000000 | 1048576 → 1048576 | ⚠️ |
| `google/gemini-2.5-flash-image` | None → 32768 | None → 32768 |  |
| `google/gemini-2.5-flash-lite` | None → 65536 | None → 1048576 |  |
| `google/gemini-2.5-pro` | 8192 → 1000000 | 1048576 → 1048576 | ⚠️ |
| `google/gemini-2.5-pro-preview` | None → — | None → — |  |
| `google/gemini-2.5-pro-preview-05-06` | None → — | None → — |  |
| `google/gemini-3-flash-preview` | 65535 → 65536 | 1048576 → 1048576 | ⚠️ |
| `google/gemini-3-pro-image` | None → 32768 | None → 65536 |  |
| `google/gemini-3-pro-image-preview` | None → 32768 | None → 65536 |  |
| `google/gemini-3.1-flash-image` | None → 32768 | None → 65536 |  |
| `google/gemini-3.1-flash-image-preview` | None → 32768 | None → 65536 |  |
| `google/gemini-3.1-flash-lite` | 65536 → 65536 | 1048576 → 1048576 |  |
| `google/gemini-3.1-flash-lite-image` | None → — | None → — |  |
| `google/gemini-3.1-flash-lite-preview` | 65536 → 65536 | 1048576 → 1048576 |  |
| `google/gemini-3.1-pro-preview` | 65536 → 65536 | 1048576 → 1048576 |  |
| `google/gemini-3.1-pro-preview-customtools` | None → 65536 | None → 1048576 |  |
| `google/gemini-3.5-flash` | None → 65535 | None → 1048576 |  |
| `google/gemma-2-27b-it` | None → — | None → — |  |
| `google/gemma-3-12b-it` | None → 131072 | None → 131072 |  |
| `google/gemma-3-27b-it` | None → 131072 | None → 131072 |  |
| `google/gemma-3-4b-it` | None → 131072 | None → 131072 |  |
| `google/gemma-3n-e4b-it` | None → — | None → — |  |
| `google/gemma-4-26b-a4b-it` | None → 256000 | None → 256000 |  |
| `google/gemma-4-26b-a4b-it:free` | None → — | None → — |  |
| `google/gemma-4-31b-it` | None → 262144 | None → 262144 |  |
| `google/gemma-4-31b-it:free` | None → — | None → — |  |
| `google/lyria-3-clip-preview` | None → 8192 | None → 131072 |  |
| `google/lyria-3-pro-preview` | None → 8192 | None → 131072 |  |
| `gryphe/mythomax-l2-13b` | None → 8192 | None → 4096 |  |
| `ibm-granite/granite-4.0-h-micro` | None → 131000 | None → 131000 |  |
| `ibm-granite/granite-4.1-8b` | None → — | None → — |  |
| `inception/mercury-2` | 50000 → 50000 | 128000 → 128000 |  |
| `inclusionai/ling-2.6-1t` | None → — | None → — |  |
| `inclusionai/ling-2.6-flash` | None → — | None → — |  |
| `inclusionai/ring-2.6-1t` | None → — | None → — |  |
| `inflection/inflection-3-pi` | None → — | None → — |  |
| `inflection/inflection-3-productivity` | None → — | None → — |  |
| `kwaipilot/kat-coder-air-v2.5` | None → — | None → — |  |
| `kwaipilot/kat-coder-pro-v2` | None → — | None → — |  |
| `kwaipilot/kat-coder-pro-v2.5` | None → — | None → — |  |
| `mancer/weaver` | 2000 → 2000 | 8000 → 8000 |  |
| `meta-llama/llama-3.1-70b-instruct` | None → 131072 | None → 131072 |  |
| `meta-llama/llama-3.1-8b-instruct` | None → 131072 | None → 131072 |  |
| `meta-llama/llama-3.2-11b-vision-instruct` | None → 131072 | None → 131072 |  |
| `meta-llama/llama-3.2-1b-instruct` | None → 60000 | None → 60000 |  |
| `meta-llama/llama-3.2-3b-instruct` | None → 131072 | None → 131072 |  |
| `meta-llama/llama-3.2-3b-instruct:free` | None → — | None → — |  |
| `meta-llama/llama-3.3-70b-instruct` | None → 131072 | None → 131072 |  |
| `meta-llama/llama-3.3-70b-instruct:free` | None → — | None → — |  |
| `meta-llama/llama-4-maverick` | None → 8192 | None → 131072 |  |
| `meta-llama/llama-4-scout` | None → 8192 | None → 131072 |  |
| `meta-llama/llama-guard-4-12b` | 8192 → 163840 | 8192 → 163840 | ⚠️ |
| `microsoft/phi-4` | None → 16384 | None → 16384 |  |
| `microsoft/wizardlm-2-8x22b` | None → 65536 | None → 65536 |  |
| `minimax/minimax-01` | None → — | None → — |  |
| `minimax/minimax-m1` | None → — | None → — |  |
| `minimax/minimax-m2` | 204800 → 204800 | 204800 → 204800 |  |
| `minimax/minimax-m2-her` | None → — | None → — |  |
| `minimax/minimax-m2.1` | 64000 → 131072 | 204000 → 1000000 | ⚠️ |
| `minimax/minimax-m2.5` | 65536 → 197000 | 196608 → 1000000 | ⚠️ |
| `minimax/minimax-m2.7` | None → 1000192 | None → 1000192 |  |
| `minimax/minimax-m3` | None → 512000 | None → 1000000 |  |
| `mistralai/codestral-2508` | None → 256000 | None → 256000 |  |
| `mistralai/devstral-2512` | 65536 → 256000 | 262144 → 262144 | ⚠️ |
| `mistralai/ministral-14b-2512` | 262144 → 262144 | 262144 → 262144 |  |
| `mistralai/ministral-3b-2512` | 131072 → 131072 | 131072 → 131072 |  |
| `mistralai/ministral-8b-2512` | 262144 → 262144 | 262144 → 262144 |  |
| `mistralai/mistral-large` | 8191 → 16384 | 128000 → 131072 | ⚠️ |
| `mistralai/mistral-large-2407` | None → 128000 | None → 128000 |  |
| `mistralai/mistral-large-2512` | 262144 → 262144 | 262144 → 262144 |  |
| `mistralai/mistral-medium-3` | 8191 → 8191 | 128000 → 128000 |  |
| `mistralai/mistral-medium-3-5` | None → 262144 | None → 262144 |  |
| `mistralai/mistral-medium-3.1` | None → — | None → — |  |
| `mistralai/mistral-nemo` | None → 128000 | None → 131072 |  |
| `mistralai/mistral-saba` | None → — | None → — |  |
| `mistralai/mistral-small-24b-instruct-2501` | None → 32768 | None → 32768 |  |
| `mistralai/mistral-small-2603` | None → — | None → — |  |
| `mistralai/mistral-small-3.1-24b-instruct` | 131072 → 131072 | 131072 → 131072 |  |
| `mistralai/mistral-small-3.2-24b-instruct` | 128000 → 128000 | 128000 → 128000 |  |
| `mistralai/mixtral-8x22b-instruct` | 65536 → 65536 | 65536 → 65536 |  |
| `mistralai/voxtral-small-24b-2507` | None → 16384 | None → 128000 |  |
| `moonshotai/kimi-k2` | None → 16384 | None → 131072 |  |
| `moonshotai/kimi-k2-0905` | None → 262144 | None → 262144 |  |
| `moonshotai/kimi-k2-thinking` | None → 262144 | None → 262144 |  |
| `moonshotai/kimi-k2.5` | 262144 → 262144 | 262144 → 262144 |  |
| `moonshotai/kimi-k2.6` | None → 262144 | None → 262144 |  |
| `moonshotai/kimi-k2.7-code` | None → 262144 | None → 262144 |  |
| `morph/morph-v3-fast` | 16000 → 16384 | 16000 → 32768 | ⚠️ |
| `morph/morph-v3-large` | 16000 → 16384 | 16000 → 32768 | ⚠️ |
| `nex-agi/nex-n2-mini` | None → — | None → — |  |
| `nex-agi/nex-n2-pro` | None → — | None → — |  |
| `nousresearch/hermes-3-llama-3.1-405b` | None → 131072 | None → 131072 |  |
| `nousresearch/hermes-3-llama-3.1-405b:free` | None → — | None → — |  |
| `nousresearch/hermes-3-llama-3.1-70b` | None → 131072 | None → 131072 |  |
| `nousresearch/hermes-4-405b` | None → — | None → — |  |
| `nousresearch/hermes-4-70b` | None → — | None → — |  |
| `nvidia/llama-3.3-nemotron-super-49b-v1.5` | None → 131072 | None → 131072 |  |
| `nvidia/nemotron-3-nano-30b-a3b` | None → — | None → — |  |
| `nvidia/nemotron-3-nano-30b-a3b:free` | None → — | None → — |  |
| `nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free` | None → — | None → — |  |
| `nvidia/nemotron-3-super-120b-a12b` | None → — | None → — |  |
| `nvidia/nemotron-3-super-120b-a12b:free` | None → — | None → — |  |
| `nvidia/nemotron-3-ultra-550b-a55b` | None → — | None → — |  |
| `nvidia/nemotron-3-ultra-550b-a55b:free` | None → — | None → — |  |
| `nvidia/nemotron-3.5-content-safety:free` | None → — | None → — |  |
| `nvidia/nemotron-nano-12b-v2-vl:free` | None → — | None → — |  |
| `nvidia/nemotron-nano-9b-v2:free` | None → — | None → — |  |
| `openai/gpt-3.5-turbo` | 4096 → 4096 | 16385 → 16385 |  |
| `openai/gpt-3.5-turbo-0613` | None → 4096 | None → 16384 |  |
| `openai/gpt-3.5-turbo-16k` | 4096 → 4096 | 16385 → 16385 |  |
| `openai/gpt-3.5-turbo-instruct` | None → 4096 | None → 8192 |  |
| `openai/gpt-4` | 4096 → 4096 | 8191 → 32768 | ⚠️ |
| `openai/gpt-4-turbo` | 4096 → 4096 | 128000 → 128000 |  |
| `openai/gpt-4-turbo-preview` | None → 4096 | None → 128000 |  |
| `openai/gpt-4.1` | 32768 → 32768 | 1047576 → 1047576 |  |
| `openai/gpt-4.1-mini` | 32768 → 32768 | 1047576 → 1047576 |  |
| `openai/gpt-4.1-nano` | 32768 → 32768 | 1047576 → 1047576 |  |
| `openai/gpt-4o` | 4096 → 16384 | 128000 → 131072 | ⚠️ |
| `openai/gpt-4o-2024-05-13` | 4096 → 4096 | 128000 → 128000 |  |
| `openai/gpt-4o-2024-08-06` | 16384 → 16384 | 128000 → 128000 |  |
| `openai/gpt-4o-2024-11-20` | 16384 → 16384 | 128000 → 128000 |  |
| `openai/gpt-4o-mini` | 16384 → 16384 | 128000 → 131072 | ⚠️ |
| `openai/gpt-4o-mini-2024-07-18` | 16384 → 16384 | 128000 → 128000 |  |
| `openai/gpt-4o-mini-search-preview` | None → 16384 | None → 128000 |  |
| `openai/gpt-4o-search-preview` | None → 16384 | None → 128000 |  |
| `openai/gpt-5` | 128000 → 128000 | 272000 → 409600 | ⚠️ |
| `openai/gpt-5-chat` | 16384 → 16384 | 128000 → 128000 |  |
| `openai/gpt-5-codex` | 128000 → 128000 | 272000 → 272000 |  |
| `openai/gpt-5-image` | None → — | None → — |  |
| `openai/gpt-5-image-mini` | None → — | None → — |  |
| `openai/gpt-5-mini` | 128000 → 128000 | 272000 → 272000 |  |
| `openai/gpt-5-nano` | 128000 → 128000 | 272000 → 272000 |  |
| `openai/gpt-5-pro` | 128000 → 128000 | 272000 → 400000 | ⚠️ |
| `openai/gpt-5.1` | 128000 → 128000 | 272000 → 409600 | ⚠️ |
| `openai/gpt-5.1-chat` | 128000 → 128000 | 128000 → 128000 |  |
| `openai/gpt-5.1-codex` | 128000 → 128000 | 272000 → 272000 |  |
| `openai/gpt-5.1-codex-max` | 128000 → 128000 | 400000 → 400000 |  |
| `openai/gpt-5.1-codex-mini` | 128000 → 128000 | 272000 → 272000 |  |
| `openai/gpt-5.2` | 128000 → 128000 | 272000 → 409600 | ⚠️ |
| `openai/gpt-5.2-chat` | 16384 → 16384 | 128000 → 128000 |  |
| `openai/gpt-5.2-codex` | 128000 → 128000 | 272000 → 272000 |  |
| `openai/gpt-5.2-pro` | 128000 → 128000 | 272000 → 272000 |  |
| `openai/gpt-5.3-chat` | 16384 → 16384 | 128000 → 128000 |  |
| `openai/gpt-5.3-codex` | 128000 → 128000 | 272000 → 272000 |  |
| `openai/gpt-5.4` | 128000 → 128000 | 1050000 → 1050000 |  |
| `openai/gpt-5.4-image-2` | None → — | None → — |  |
| `openai/gpt-5.4-mini` | 128000 → 128000 | 1050000 → 1050000 |  |
| `openai/gpt-5.4-nano` | 128000 → 128000 | 1050000 → 1050000 |  |
| `openai/gpt-5.4-pro` | 128000 → 128000 | 1050000 → 1050000 |  |
| `openai/gpt-5.5` | 128000 → 128000 | 1050000 → 1050000 |  |
| `openai/gpt-5.5-pro` | 128000 → 128000 | 1050000 → 1050000 |  |
| `openai/gpt-5.6-luna` | 128000 → 128000 | 1050000 → 1050000 |  |
| `openai/gpt-5.6-luna-pro` | None → — | None → — |  |
| `openai/gpt-5.6-sol` | 128000 → 128000 | 1050000 → 1050000 |  |
| `openai/gpt-5.6-sol-pro` | None → — | None → — |  |
| `openai/gpt-5.6-terra` | 128000 → 128000 | 1050000 → 1050000 |  |
| `openai/gpt-5.6-terra-pro` | None → — | None → — |  |
| `openai/gpt-audio` | None → 16384 | None → 128000 |  |
| `openai/gpt-audio-mini` | None → 16384 | None → 128000 |  |
| `openai/gpt-chat-latest` | None → — | None → — |  |
| `openai/gpt-oss-120b` | 32768 → 131072 | 131072 → 131072 | ⚠️ |
| `openai/gpt-oss-20b` | 32768 → 131072 | 131072 → 131072 | ⚠️ |
| `openai/gpt-oss-20b:free` | None → — | None → — |  |
| `openai/gpt-oss-safeguard-20b` | None → 131072 | None → 131072 |  |
| `openai/o1` | 100000 → 100000 | 200000 → 200000 |  |
| `openai/o1-pro` | None → 100000 | None → 200000 |  |
| `openai/o3` | 100000 → 100000 | 200000 → 200000 |  |
| `openai/o3-deep-research` | 100000 → 100000 | 200000 → 200000 |  |
| `openai/o3-mini` | 65536 → 100000 | 128000 → 200000 | ⚠️ |
| `openai/o3-mini-high` | 65536 → 65536 | 128000 → 128000 |  |
| `openai/o3-pro` | 100000 → 100000 | 200000 → 200000 |  |
| `openai/o4-mini` | 100000 → 100000 | 200000 → 200000 |  |
| `openai/o4-mini-deep-research` | None → 100000 | None → 200000 |  |
| `openai/o4-mini-high` | None → — | None → — |  |
| `openrouter/auto` | None → 2000000 | 2000000 → 2000000 |  |
| `openrouter/bodybuilder` | None → 128000 | 128000 → 128000 |  |
| `openrouter/free` | None → 200000 | 200000 → 200000 |  |
| `openrouter/fusion` | None → — | None → — |  |
| `openrouter/pareto-code` | None → — | None → — |  |
| `perceptron/perceptron-mk1` | None → — | None → — |  |
| `perplexity/sonar` | None → 128000 | 128000 → 128000 |  |
| `perplexity/sonar-deep-research` | None → 128000 | 128000 → 128000 |  |
| `perplexity/sonar-pro` | 8000 → 8000 | 200000 → 200000 |  |
| `perplexity/sonar-pro-search` | None → — | None → — |  |
| `perplexity/sonar-reasoning-pro` | None → 128000 | 128000 → 128000 |  |
| `poolside/laguna-m.1` | None → — | None → — |  |
| `poolside/laguna-m.1:free` | None → — | None → — |  |
| `poolside/laguna-xs-2.1` | None → — | None → — |  |
| `poolside/laguna-xs-2.1:free` | None → — | None → — |  |
| `qwen/qwen-2.5-72b-instruct` | None → 8192 | None → 32000 |  |
| `qwen/qwen-2.5-7b-instruct` | None → — | None → — |  |
| `qwen/qwen-2.5-coder-32b-instruct` | 33792 → 33792 | 33792 → 33792 |  |
| `qwen/qwen-plus` | None → 16384 | None → 129024 |  |
| `qwen/qwen-plus-2025-07-28` | None → 32768 | None → 997952 |  |
| `qwen/qwen-plus-2025-07-28:thinking` | None → — | None → — |  |
| `qwen/qwen2.5-vl-72b-instruct` | None → 131072 | None → 131072 |  |
| `qwen/qwen3-14b` | None → 40960 | None → 40960 |  |
| `qwen/qwen3-235b-a22b` | None → 262144 | None → 262144 |  |
| `qwen/qwen3-235b-a22b-2507` | 262144 → 262144 | 262144 → 262144 |  |
| `qwen/qwen3-235b-a22b-thinking-2507` | 262144 → 262144 | 262144 → 262144 |  |
| `qwen/qwen3-30b-a3b` | None → 131072 | None → 131072 |  |
| `qwen/qwen3-30b-a3b-instruct-2507` | None → 262144 | None → 262144 |  |
| `qwen/qwen3-30b-a3b-thinking-2507` | None → 262144 | None → 262144 |  |
| `qwen/qwen3-32b` | 131000 → 131072 | 131000 → 131072 | ⚠️ |
| `qwen/qwen3-8b` | None → 40960 | None → 40960 |  |
| `qwen/qwen3-coder` | 262100 → 262100 | 262100 → 262144 | ⚠️ |
| `qwen/qwen3-coder-30b-a3b-instruct` | None → 262144 | None → 262144 |  |
| `qwen/qwen3-coder-flash` | None → 65536 | None → 997952 |  |
| `qwen/qwen3-coder-next` | None → — | None → — |  |
| `qwen/qwen3-coder-plus` | 65536 → 65536 | 997952 → 997952 |  |
| `qwen/qwen3-coder:free` | None → — | None → — |  |
| `qwen/qwen3-max` | None → 65536 | None → 262144 |  |
| `qwen/qwen3-max-thinking` | None → — | None → — |  |
| `qwen/qwen3-next-80b-a3b-instruct` | None → 262144 | None → 262144 |  |
| `qwen/qwen3-next-80b-a3b-instruct:free` | None → — | None → — |  |
| `qwen/qwen3-next-80b-a3b-thinking` | None → 262144 | None → 262144 |  |
| `qwen/qwen3-vl-235b-a22b-instruct` | None → 262144 | None → 262144 |  |
| `qwen/qwen3-vl-235b-a22b-thinking` | None → 262144 | None → 262144 |  |
| `qwen/qwen3-vl-30b-a3b-instruct` | None → 262144 | None → 262144 |  |
| `qwen/qwen3-vl-30b-a3b-thinking` | None → 262144 | None → 262144 |  |
| `qwen/qwen3-vl-32b-instruct` | None → 32768 | None → 131072 |  |
| `qwen/qwen3-vl-8b-instruct` | None → 32768 | None → 131072 |  |
| `qwen/qwen3-vl-8b-thinking` | None → — | None → — |  |
| `qwen/qwen3.5-122b-a10b` | 65536 → 262144 | 262144 → 262144 | ⚠️ |
| `qwen/qwen3.5-27b` | 65536 → 65536 | 262144 → 262144 |  |
| `qwen/qwen3.5-35b-a3b` | 65536 → 65536 | 262144 → 262144 |  |
| `qwen/qwen3.5-397b-a17b` | 65536 → 65536 | 262144 → 262144 |  |
| `qwen/qwen3.5-9b` | None → — | None → — |  |
| `qwen/qwen3.5-flash-02-23` | 65536 → 65536 | 1000000 → 1000000 |  |
| `qwen/qwen3.5-plus-02-15` | 65536 → 65536 | 1000000 → 1000000 |  |
| `qwen/qwen3.5-plus-20260420` | 65536 → — | 1000000 → — |  |
| `qwen/qwen3.6-27b` | None → 262144 | None → 262144 |  |
| `qwen/qwen3.6-35b-a3b` | None → 262144 | None → 262144 |  |
| `qwen/qwen3.6-flash` | None → — | None → — |  |
| `qwen/qwen3.6-max-preview` | None → — | None → — |  |
| `qwen/qwen3.6-plus` | 65536 → 65536 | 1000000 → 1000000 |  |
| `qwen/qwen3.7-max` | None → — | None → — |  |
| `qwen/qwen3.7-plus` | None → — | None → — |  |
| `rekaai/reka-edge` | None → — | None → — |  |
| `rekaai/reka-flash-3` | None → — | None → — |  |
| `relace/relace-apply-3` | None → — | None → — |  |
| `relace/relace-search` | None → — | None → — |  |
| `sakana/fugu-ultra` | None → — | None → — |  |
| `sao10k/l3-lunaris-8b` | None → — | None → — |  |
| `sao10k/l3.1-euryale-70b` | None → — | None → — |  |
| `sao10k/l3.3-euryale-70b` | None → — | None → — |  |
| `stepfun/step-3.5-flash` | None → — | None → — |  |
| `stepfun/step-3.7-flash` | None → — | None → — |  |
| `tencent/hunyuan-a13b-instruct` | None → — | None → — |  |
| `tencent/hy3` | None → — | None → — |  |
| `tencent/hy3-preview` | None → — | None → — |  |
| `tencent/hy3:free` | None → — | None → — |  |
| `thedrummer/cydonia-24b-v4.1` | None → — | None → — |  |
| `thedrummer/rocinante-12b` | None → — | None → — |  |
| `thedrummer/skyfall-36b-v2` | None → — | None → — |  |
| `thedrummer/unslopnemo-12b` | None → — | None → — |  |
| `undi95/remm-slerp-l2-13b` | 4096 → 4096 | 6144 → 6144 |  |
| `upstage/solar-pro-3` | None → — | None → — |  |
| `writer/palmyra-x5` | None → — | None → — |  |
| `x-ai/grok-4.20` | None → 131072 | None → 131072 |  |
| `x-ai/grok-4.20-multi-agent` | None → 131072 | None → 131072 |  |
| `x-ai/grok-4.3` | None → 1000000 | None → 1000000 |  |
| `x-ai/grok-4.5` | None → 500000 | None → 500000 |  |
| `x-ai/grok-build-0.1` | None → — | None → — |  |
| `xiaomi/mimo-v2.5` | 131072 → 131072 | 1048576 → 1048576 |  |
| `xiaomi/mimo-v2.5-pro` | 16384 → 16384 | 1048576 → 1048576 |  |
| `z-ai/glm-4.5` | None → 131072 | None → 131072 |  |
| `z-ai/glm-4.5-air` | None → 128000 | None → 131072 |  |
| `z-ai/glm-4.5v` | None → 32000 | None → 128000 |  |
| `z-ai/glm-4.6` | 131000 → 200000 | 202800 → 204800 | ⚠️ |
| `z-ai/glm-4.6v` | None → 32768 | None → 131072 |  |
| `z-ai/glm-4.7` | 64000 → 200000 | 202752 → 204800 | ⚠️ |
| `z-ai/glm-4.7-flash` | 32000 → 131072 | 200000 → 200000 | ⚠️ |
| `z-ai/glm-5` | 128000 → 128000 | 202752 → 202752 |  |
| `z-ai/glm-5-turbo` | None → — | None → — |  |
| `z-ai/glm-5.1` | 65535 → 128000 | 202752 → 202752 | ⚠️ |
| `z-ai/glm-5.2` | None → 262144 | None → 262144 |  |
| `z-ai/glm-5v-turbo` | None → — | None → — |  |
| `~anthropic/claude-fable-latest` | None → — | None → — |  |
| `~anthropic/claude-haiku-latest` | None → — | None → — |  |
| `~anthropic/claude-opus-latest` | None → — | None → — |  |
| `~anthropic/claude-sonnet-latest` | None → — | None → — |  |
| `~google/gemini-flash-latest` | None → 65535 | None → 1048576 |  |
| `~google/gemini-pro-latest` | None → 65535 | None → 1048576 |  |
| `~moonshotai/kimi-latest` | None → 131072 | None → 131072 |  |
| `~openai/gpt-latest` | None → — | None → — |  |
| `~openai/gpt-mini-latest` | None → — | None → — |  |
| `~x-ai/grok-latest` | None → — | None → — |  |

### Grok  
`builtin.xai`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `grok-4.20-0309-non-reasoning` | None → — | None → — |  |
| `grok-4.20-0309-reasoning` | 2000000 → 2000000 | 2000000 → 2000000 |  |
| `grok-4.20-multi-agent-0309` | None → — | None → — |  |
| `grok-4.3` | 1000000 → 1000000 | 1000000 → 1000000 |  |
| `grok-4.5` | 500000 → 500000 | 500000 → 500000 |  |
| `grok-build-0.1` | None → — | None → — |  |
| `grok-imagine-image` | None → — | None → — |  |
| `grok-imagine-image-quality` | None → — | None → — |  |
| `grok-imagine-video` | None → — | None → — |  |
| `grok-imagine-video-1.5` | None → — | None → — |  |

### z.ai  
`builtin.zai`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `glm-4.5` | None → 131072 | None → 131072 |  |
| `glm-4.5-air` | None → 128000 | None → 131072 |  |
| `glm-4.6` | None → 200000 | None → 204800 |  |
| `glm-4.7` | None → 200000 | None → 204800 |  |
| `glm-5` | None → 128000 | None → 202752 |  |
| `glm-5-turbo` | None → — | None → — |  |
| `glm-5.1` | None → 128000 | None → 202752 |  |
| `glm-5.2` | None → 262144 | None → 262144 |  |

### mlx_lm.server on 8080  
`provider-1566D9B4`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `mlx-community/GLM-4.7-Flash-4bit` | None → — | None → — |  |
| `mlx-community/Llama-3.2-3B-Instruct-4bit` | None → — | None → — |  |
| `mlx-community/Qwen2.5-7B-Instruct-4bit` | None → — | None → — |  |
| `mlx-community/Qwen2.5.1-Coder-7B-Instruct-4bit` | None → — | None → — |  |

### MyVast  
`provider-E44F148D`

| Model ID | maxOut (OURS→LiteLLM) | maxCtx (OURS→LiteLLM) | Δ |
|---|---|---|---|
| `Qwen/Qwen3.5-122B-A10B-FP8` | None → — | None → — |  |
