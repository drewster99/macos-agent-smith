<div align="center">

<img src="docs/assets/app-icon.png" width="128" alt="Agent Smith app icon" />

# Agent Smith

**A multi-agent workforce for your Mac.** You hand it a task; a team of LLM agents plans it, does the work in a real shell, and reviews itself — with a dedicated security agent watching every move.

A native macOS app. Swift 6, SwiftUI, on-device. Your API keys, your machine.

<img src="docs/assets/screenshot.png" width="820" alt="Agent Smith orchestrating tasks" />

</div>

## Why it's different

Most AI coding tools are a single agent in a chat loop that you watch. Agent Smith is a small, self-supervising team: an **orchestrator** turns your request into tracked tasks and delegates them, a **worker** carries them out in a real shell, a **security agent** rates every action *before* it runs, and each task's **acceptance criteria** get independently judged before anything is called done. It runs locally, works with any model you point it at, and keeps working through a task list — not just a single prompt.

## The cast

Four fixed roles, each with one job:

| Agent | Role |
| --- | --- |
| **Smith** | Orchestrator. Talks to you, breaks requests into tasks, supervises the work, reviews results. Never touches the tools itself. |
| **Brown** | Worker. Spawned per task with the bash, file, and process tools to actually get things done. |
| **Security Agent** | Security gatekeeper. Silently rates every one of Brown's tool calls — `SAFE` / `WARN` / `UNSAFE` / `ABORT` — and can stop the line. |
| **Summarizer** | Distills finished tasks into memory the team can draw on later. |

## Highlights

- **Real tools, real shell** — Brown runs `bash`, reads and edits files, manages processes, fetches the web. Not a sandbox toy.
- **Security built in, not bolted on** — the Security Agent gates destructive and open-world actions before they run. Separation of duties by design.
- **Work is checked, not rubber-stamped** — every task is judged against its acceptance criteria by independent validators before it's marked done.
- **Multi-session** — run independent jobs side by side in their own tabs and windows.
- **Persistent memory** — semantic-search-backed memory so the team remembers what it learned across runs.
- **Agent inspector** — open any agent's full conversation, tool calls, and security verdicts, live or after the fact.
- **Bring your own model** — Anthropic, Gemini, Ollama, LM Studio, OpenRouter, Mistral, xAI, and any OpenAI-compatible endpoint, via [SwiftLLMKit](https://github.com/drewster99/swift-llm-kit). Keys live in the Keychain, never in config.
- **Usage & cost tracking** — every call is metered and grouped by run.
- **MCP support** — extend the team with Model Context Protocol servers.

## Requirements

- **To run:** macOS 26.2 or later, and an API key for at least one supported provider (or a local model via Ollama / LM Studio).
- **To build from source:** the above, plus Xcode 16 or later.

## Install

Download the latest build from [Releases](https://github.com/drewster99/macos-agent-smith/releases), unzip, and drag **Agent Smith** to your Applications folder. On first launch of an unsigned alpha build, macOS Gatekeeper may ask you to right-click the app → **Open** to confirm. Then add a provider API key in Settings and you're ready.

### Build from source

Clone and open in Xcode — Swift Package Manager resolves the dependencies automatically, no side-by-side checkouts needed:

```
git clone https://github.com/drewster99/macos-agent-smith.git
open macos-agent-smith/AgentSmith/AgentSmith.xcodeproj
```

Run the `AgentSmith` scheme. The engine lives in the local Swift package `AgentSmithKit` (`AgentSmithPackage/`), which pulls [swift-llm-kit](https://github.com/drewster99/swift-llm-kit) and [swift-semantic-search](https://github.com/drewster99/swift-semantic-search) as versioned dependencies. Run the package tests from the terminal:

```
cd AgentSmithPackage && swift test --skip MemoryStoreIntegrationTests
```

## A note on safety

Agent Smith runs LLM-generated commands — including a real shell — on your machine. The Security Agent vets actions before they run, but it's a mitigation, not a sandbox, and LLMs make mistakes. This is early software: keep backups, point it at work you can afford to have go sideways, and use it at your own risk.

## License

Licensed under the [Apache License 2.0](LICENSE). Copyright © 2026 Nuclear Cyborg Corp.
