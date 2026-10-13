# Remote (HTTPS) MCP Support — Implementation Plan

Status: FINAL plan (v2) — revised after an external review by Codex (see §16). Planning/research only — no source code was changed in producing this document; this markdown file is the only repository modification.
Date of research: 2026-10-13. Repo: `drewster99/macos-agent-smith`, checkout `/Users/andrew/Documents/ncc_source/cursor/macos-agent-smith` (branch `main`, HEAD `ee8a3fc1`).

## 0. How to read this document

Every statement is tagged so that confirmed facts are never confused with proposals:

- **[FACT-REPO]** — verified by reading the code in this checkout (file/type named).
- **[FACT-SDK]** — verified by reading `modelcontextprotocol/swift-sdk` 0.12.1 (the version pinned in `AgentSmithPackage/Package.resolved`, revision `a0ae212e`).
- **[FACT-SPEC]** — taken from the official MCP specification (rev. 2025-11-25) / Atlassian public docs, fetched 2026-10-13.
- **[DECISION]** — a recommendation this plan makes. Changeable, but implementation steps assume it.
- **[OPEN]** — a question that needs Drew's (or a spike's) answer before or during the relevant phase.
- **[RISK]** — a credible stumbling block, with its mitigation.

## 1. Goals and non-goals

Goals
1. Let the user add MCP servers reachable over HTTPS (Streamable HTTP; legacy HTTP+SSE only if cheap) alongside today's local stdio servers.
2. UI to add / edit / enable-disable / authenticate / re-authenticate / monitor / delete remote servers.
3. Saved configurations that survive restarts; secrets only in the Keychain.
4. Authentication: OAuth 2.1 (browser sign-in, PKCE, discovery, dynamic client registration) first; plus static bearer token, API-key/custom header, and HTTP Basic (e.g. Atlassian email+API token) as practical alternatives; "none" for open servers.
5. The same remote endpoint configured more than once, each instance fully independent (own name, own credentials, own tool toggles, own status). Canonical example: Atlassian Rovo MCP (`https://mcp.atlassian.com/v2/mcp`) signed in with two or more different Atlassian accounts for different projects.
6. Every remote tool still flows through the existing Security Agent scoping / per-call gating. Remote MCP must never become a way around it.

Non-goals (this plan)
- Running an MCP *server* inside Agent Smith. MCP resources/prompts/sampling/elicitation UI (tools only, as today) — see §13 for what to do with server-initiated requests.
- Enterprise device-flow/SSO, mTLS client certificates (listed as future work).
- Changing how Brown/Smith/Security Agent behave beyond what remote tools require.

## 2. Verified findings about the current code (grounding)

### 2.1 Configuration model and persistence
- **[FACT-REPO]** `AgentSmithPackage/Sources/AgentSmithKit/MCP/MCPServerConfig.swift`: `MCPServerConfig` (Codable, Identifiable) is **stdio-only**: `id, name, enabled, command, args, workingDirectory, envVarNames, secretArgIndices, disabledTools`. `command` is *required* in the decoder (`c.decode(String.self, forKey: .command)`); all other later fields decode with defaults (tolerant decoding style).
- **[FACT-REPO]** Persistence: `PersistenceManager.saveMCPServerConfigs / loadMCPServerConfigs` (`Persistence/PersistenceManager.swift` ~L658-672) writes a single JSON **array** to `~/Library/Application Support/AgentSmith/mcp_servers.json` (global, shared by all sessions), atomic write, plain `JSONEncoder`/`JSONDecoder` — **no schema version field**. `SharedAppState` writes it through `SerialPersistenceWriter<[MCPServerConfig]>` (`mcpServersWriter`).
- **[FACT-REPO]** `SharedAppState.loadPersistedState()` (~L853) does `mcpServers = try await basePersistence.loadMCPServerConfigs()` inside a do/catch that only logs and leaves `mcpServers = []` on failure. **Consequence:** if an older build opens a file containing an entry that fails to decode (e.g. a remote entry without `command`), the *whole* array fails, the server list silently becomes empty, and the next edit in that older build would overwrite the file and destroy the remote entries. See §9 (downgrade safety).
- **[FACT-REPO]** `MCPConfigImport` (`MCP/MCPConfigImport.swift`) parses the Claude-Desktop/Cursor `{ "mcpServers": { name: { command, args, env, cwd } } }` blob. It only understands stdio entries (`command` required; entries with only `url` are skipped with warning "no command specified"). Env values are all routed to the Keychain.
- **[FACT-REPO]** Docs: `docs/claude/persistence-and-storage.md` lists `mcp_servers.json` as GLOBAL; project rule: JSON files only, no database; session-scoped state belongs on `AppViewModel`, global on `SharedAppState`.

### 2.2 Secrets
- **[FACT-REPO]** `MCP/MCPSecretStore.swift`: generic-password Keychain items, service `com.agentsmith.mcp.<bundleID>`, account namespaced `<serverUUID>/env/<NAME>` and `<serverUUID>/arg/<index>`; saves to the Data-Protection keychain with fallback to the legacy login keychain when `errSecMissingEntitlement`; `kSecAttrAccessibleAfterFirstUnlock`; reads probe both keychains; `deleteAll(serverID:envVarNames:secretArgIndices:)` enumerates *known* account names (it cannot enumerate by prefix). Protocol `MCPSecretWriting` (save only) exists so import can be unit-tested with an in-memory fake.
- **[FACT-REPO]** Entitlements (`AgentSmith/AgentSmith.entitlements`): `keychain-access-groups` = `P8MA38JTXY.$(CFBundleIdentifier)`, `automation.apple-events`. Project settings: `ENABLE_APP_SANDBOX = NO`, `ENABLE_HARDENED_RUNTIME = YES`, `MACOSX_DEPLOYMENT_TARGET = 26.2` (app) / macOS 15 (AgentSmithKit package).
- **[FACT-REPO]** `AgentSmith/Info.plist` sets `NSAllowsArbitraryLoads = true` (App Transport Security fully open), `GENERATE_INFOPLIST_FILE = YES` and `INFOPLIST_FILE = AgentSmith/Info.plist`. **No `CFBundleURLTypes`** (no custom URL scheme) and no `onOpenURL` / `NWListener` / `ASWebAuthenticationSession` anywhere in the app or package (grep-verified). So the app has no OAuth callback receiver today.

### 2.3 Client / host architecture and lifecycle
- **[FACT-REPO]** `MCP/MCPClientHost.swift` is an `actor`. **One host per session** (`AppViewModel.mcpHost`, created once per session in `AppViewModel.start()` ~L1035-1055, registered with `SharedAppState.registerMCPHost`, held weakly by `SharedAppState.mcpHostBoxes`). Config changes fan out from `SharedAppState.updateMCPServers(_:)` to every live host via `applyConfigChange(configs:)`.
- **[FACT-REPO]** Consequence for remote: with *N* open sessions and *M* enabled servers, today there are *N×M* independent connections (for stdio, N×M subprocesses). For remote OAuth this means N concurrent holders of the same refresh token (see §6.5).
- **[FACT-REPO]** `Connection` struct is hard-wired to a `Process`, three `Pipe`s and a `StderrBuffer`. `launchProcess` builds `StdioTransport(input:output:)` and `Client(name:version:)`. `performConnect` → `connectWithDeadline` races `client.connect(transport:)` against *process exit* (`kill(pid,0)`) and a 120 s deadline; `teardown` disconnects the client and `process.terminate()`. None of this applies to HTTP (no pid, no stderr, no process-exit signal).
- **[FACT-REPO]** `needsRelaunch(old:new:)` compares only stdio fields (`command`, `args`, `workingDirectory`, `envVarNames`, `secretArgIndices`); it would never relaunch on a URL/auth change.
- **[FACT-REPO]** No reconnect logic, and failure semantics are narrower than "everything becomes `.failed`" (review): a *connect* failure publishes `.failed` and nothing retries; `callTool` just throws without changing connection status; `refreshTools` catches errors and publishes `.connected` with `toolCount: 0` while the previously stored tools stay in the `Connection`; and `applyConfigChange` restarts a *missing* connection on **any** later config update (not only on an enable toggle). `performConnect`/`refreshTools`/notification handlers resume after `await` and mutate whatever connection currently occupies that UUID (no generation check), so a stale failure can tear down a replacement connection. `applyConfigChange` also builds `Dictionary(uniqueKeysWithValues:)` over config ids, which traps on duplicate ids. stdio servers rarely drop mid-session; remote connections will (idle timeouts, deploys, token expiry, laptop sleep), so remote recovery must explicitly replace these semantics (§6.1, §6.6).
- **[FACT-REPO]** `MCPServerStatus` (state `connecting|connected|failed|disabled`, `toolCount`, `error`, `stderrTail`, `advertisedToolNames`, `toolDescriptions`, `serverInstructions`) is published through `onStatusChanged` → `SharedAppState.reportMCPStatuses` ("latest report wins" across hosts, keyed by server UUID) → UI. `statusBadge()` in `MCPServerManagementView` switches exhaustively over the four states.
- **[FACT-REPO]** Tool listing: `refreshTools` calls `client.listTools()` **once, without following `nextCursor`** (`let (tools, _) = try await client.listTools()`). Atlassian's `?tools=all` variant is documented as a *paginated* list → tools would be silently truncated. Must page.
- **[FACT-REPO]** `callTool` is cancellation-aware (sends `notifications/cancelled` via `RequestContext`); `MCPBridgedTool.executionTimeout` is a flat 4 h; tools are normalised to text/images (audio, embedded resources, resource links are placeholders). `tools/list_changed` is handled via `client.onNotification` with a detached refresh to avoid a message-loop deadlock (comment in `performConnect` — must be preserved).
- **[FACT-REPO]** `waitUntilSettled(timeout:)` is used by `OrchestrationRuntime` (`spawnBrown`, ~L5932-5943) with a 5 s settle window before Security Agent scoping. Interactive/slow remote connects will routinely miss it; the runtime already re-scopes when tools appear later (candidate fingerprint).

### 2.4 Tool naming, policies and Security Agent integration (matters hugely for multi-account)
- **[FACT-REPO]** `MCPToolNaming`: every tool is `mcp__<serverSlug>__<tool>` where the slug is the *sanitized server display name* (`[A-Za-z0-9_-]`, runs of `_` collapsed, max 49 chars) and the whole name is ≤ 64 chars. `MCPClientHost.assignPrefixedToolNames` resolves collisions by appending `_2`, `_3`… **per tool**, in connection order (sorted by name, then id).
- **[FACT-REPO]** Uniqueness of *names* is only validated on the raw string in the editor (`MCPServerEditorSheet.save()`: `$0.name == trimmedName && $0.id != id`). Two different names that sanitize to the same slug ("Atlassian Work" and "Atlassian_Work" and "Atlassian  Work") pass validation but silently collide, and their tools get `_2` suffixes — which tool belongs to which account then depends on sort order.
- **[FACT-REPO]** Persisted policy is keyed by the **prefixed tool name**: `globalToolPolicies` (Settings → Tools; `ToolsSettingsView`), per-task `userToolOverrides` (`TaskToolOverrideEditor`, `TaskStore`), and Security Agent scoping (`SecurityEvaluator`: `groupID = "mcp__\(mcp.serverName)"`). **Renaming a server therefore orphans all of its policies/overrides** (the TaskToolOverrideEditor even has an "Other (disconnected MCP)" bucket for leftover names).
- **[FACT-REPO]** `MCPBridgedTool.identityToken` = `serverID.uuidString` — salts the scoping fingerprint so a re-created same-named server forces re-scope. `isDestructive`/`isOpenWorld` fail closed (`?? true`); annotation hints are untrusted. Security Agent is told the group description = the server's `instructions`, or "External MCP server configured by the user. It provided no description of itself." (`SecurityEvaluator` ~L412-425, 1504-1525). The group `id` and `name` are derived from `serverName` (the display name, not the tool prefix), so two instances *are* separate groups today, but their **descriptions** (server instructions) and tool descriptions are identical, the group id changes on rename, and two names that sanitize alike are not separated by the slug. Security Agent classification reads `mcp.openWorldHint` directly (not `MCPBridgedTool.isOpenWorld`). See §7.3.
- **[FACT-REPO]** `ToolSafetyClassification` explicitly treats MCP tools as untrusted/unclassified; `SecurityEvaluator` ~L1885-1891 attaches a "user-approved MCP tool" note for any `mcp__` name. Remote servers are a *larger* trust gap than local ones (third party hosts the code and can change tools at any time) — the existing per-turn candidate-fingerprint re-scope covers redefinition (ROADMAP "candidate identity = content hash of name+description+schema").

### 2.5 UI surfaces
- **[FACT-REPO]** `Views/SettingsView.swift` tab "MCP Servers" → `MCPServerManagementView` (list of `MCPServerRow` GroupBoxes: enable switch, name, status badge, `command args` summary, server instructions, Edit/Delete, collapsible error + stderr, per-tool checkboxes with descriptions; header buttons "Paste JSON…" and "Add Server") → `MCPServerEditorSheet` (520×560; fields Name / Command / Working dir / Arguments with per-row Secret flag / Environment variables) and `MCPPasteJSONSheet`.
- **[FACT-REPO]** Delete (`deleteServer`) removes Keychain secrets via `deleteAll` *then* updates the list. Editor save writes Keychain items in phases with orphan cleanup (M11) but is **not transactional** (review): earlier Keychain writes remain if a later write fails, cleanup deletes can run before the config is durable, and the config is persisted by an asynchronous enqueue (`SharedAppState.updateMCPServers` → `mcpServersWriter.enqueue`) with no durability result shown to the UI. OAuth's rotating credentials make those partial-failure cases more consequential, so it is not a template to copy (§5.6).
- **[FACT-REPO]** Other consumers of the server list: `ToolsSettingsView`, `TaskToolOverrideEditor` (per-server Auto/On/Off), `AppViewModel.announceMCPFailuresIfNeeded` (one-time `.mcpStatus` warning in the transcript when a server fails, keyed per server UUID; `MainViewDetailColumn` has an "open MCP settings" deep-link via `SharedAppState.settingsSelectedTab = .mcp`).
- **[FACT-REPO]** Repo UI rules (guard tests in `CodeStyleGuardTests`): no `: some View` properties besides `body`, no `Lazy*` containers, no `.onTapGesture`, no multiple trailing closures, per-file ratchets on `body` length and `-> some View` function size, no `@ObservedObject`. New SwiftUI must be split into small subviews accordingly. `ChannelMessageKind` is a closed enum guarded by tests; new transcript semantics must use typed kinds/severity, never prose matching (CLAUDE.md "Never drive behavior by matching free text").

### 2.6 Dependencies and tests
- **[FACT-REPO]** `AgentSmithPackage/Package.swift`: `modelcontextprotocol/swift-sdk` `.upToNextMinor(from: "0.12.1")`; the `MCP` product is already linked into `AgentSmithKit`. Transitive: `eventsource` 1.5.1 (SSE parser; already resolved), `swift-nio`, `swift-crypto`, `swift-log`.
- **[FACT-REPO]** Existing MCP tests (`AgentSmithPackage/Tests/AgentSmithTests`): `MCPToolTests` (naming, value conversion, config import, secret account names), `MCPSIGPIPEScopeTests`, `MCPClientHostIntegrationTests` and `MCPMinimalWiringTests` (opt-in via `MCP_INTEGRATION=1`, real `npx @modelcontextprotocol/server-everything`). There is no HTTP/OAuth test infrastructure. Package tests are run with `swift test --skip MemoryStoreIntegrationTests` from `AgentSmithPackage/`; builds go through the drews-xcode-mcp tools (CLAUDE.md).

### 2.7 What the SDK (0.12.1) already gives us, and where it falls short
(Items re-verified against SDK source after the external review; corrections that came from that review are marked "(review)".)

- **[FACT-SDK]** `HTTPClientTransport` (public `actor`, conforms to the public `Transport` protocol): Streamable HTTP over `URLSession`. Sends `Accept: application/json, text/event-stream`, `MCP-Protocol-Version`, tracks `Mcp-Session-Id`, opens a GET SSE stream when `streaming: true`, honours SSE `retry`, resumes with `Last-Event-ID`, treats a **POST** 404 with a session id as "Session expired". Default protocol version `Version.latest` = `2025-11-25`. Public hooks: `configuration: URLSessionConfiguration`, `requestModifier: (URLRequest)->URLRequest` (synchronous), `authorizer: HTTPClientAuthorizer?`. **The initializer that accepts a caller-built `URLSession` is `internal`**, so we cannot install a redirect-refusing `URLSessionTaskDelegate` through the public API (review).
- **[FACT-SDK]** It does **not** implement the deprecated 2024-11-05 HTTP+SSE transport; it has **no automatic reconnect after `Client`/transport disconnect** (`disconnect()` calls `session.invalidateAndCancel()` and finishes the receive stream, so reconnecting requires a *fresh* transport and `Client`); and it maps HTTP failures to coarse `MCPError.internalError("Authentication required" / "Server error: 5xx" / "Too many requests")` strings — status codes, `Retry-After` and authorizer errors are not available to the host as typed values (review).
- **[FACT-SDK]** The **GET (standalone SSE) path behaves differently from POST** (review): any non-200 GET response (including 401/403/404) throws `MCPError.internalError("HTTP error: <n>")` inside the SDK's own retry loop. It does **not** call the authorizer's `handleChallenge`, does **not** clear a dead session id, and the error is only logged, not surfaced to the host. 405 cancels the stream task (valid: "server offers no standalone stream"). So a token that expires while only the GET stream is open, or a session that expired server-side, is invisible to us unless we patch or replace the transport.
- **[FACT-SDK]** `OAuthAuthorizer` (public; implements the public protocol `HTTPClientAuthorizer`) implements RFC 9728 protected-resource discovery, RFC 8414 + OIDC discovery, RFC 7591 dynamic client registration, authorization-code + PKCE (S256; refuses an AS without S256), RFC 8707 `resource`, refresh-token grant, 403 `insufficient_scope` step-up with attempt caps, `client_credentials`, `private_key_jwt`, endpoint overrides, an `accessTokenProvider` escape hatch, HTTPS-or-loopback enforcement and a literal-IP SSRF check. A `cimdNotSupported(clientID:)` error shows partial Client-ID-Metadata-Document support.
- **[FACT-SDK] Gaps / gotchas (verified in source):**
  1. `TokenStorage` (`save/load/clear` of `OAuthAccessToken`: value, expiry, scopes, issuer, refreshToken, clientID) is **synchronous and non-throwing**; the default is in-memory. `clear()` carries no *reason* (rejected token vs AS change vs deliberate removal). `OAuthAccessToken` has no resource binding.
  2. The interactive step is `OAuthAuthorizationDelegate.presentAuthorizationURL(_:) async throws -> URL`: **we** must open the browser *and* receive the redirect. The SDK ships no loopback listener. Without a delegate it does a headless GET (tests only).
  3. `defaultAuthorizationRedirectURI()` picks a random loopback port (`http://127.0.0.1:<49152-65535>/callback`) per `OAuthConfiguration`; DCR registers that exact URI.
  4. **(review; corrects the first draft)** A non-empty `client_id` does **not** skip dynamic registration. `maybeRegisterClient` only checks the *case* (`.none(clientID:)`), and `OAuthClientRegistrar.register` then POSTs to `registration_endpoint` whenever the AS advertises one — except when the client id is an https-URL-with-path and the AS advertises `client_id_metadata_document_supported` (CIMD). A restored public DCR client would therefore *re-register* at the next re-authorization and receive a different `client_id` than the one the stored refresh token was issued to. The registration result (secret, secret expiry) is held in private state; only the `client_id` leaks into `OAuthAccessToken.clientID`.
  5. **(review)** The dependency-injecting `OAuthAuthorizer.init`, `OAuthTokenEndpointClient`, `OAuthDiscoveryClient` and `OAuthClientRegistrar` are **internal**. Public: `HTTPClientAuthorizer`, `OAuthConfiguration`, `OAuthAccessToken`, `OAuthAuthorizationDelegate`, `TokenStorage`, `OAuthAuthorizationCodeFlow`, PKCE helpers. The first draft's "reuse the SDK's token-endpoint client" fallback therefore does not exist.
  6. **(review; corrects an overstatement)** On a 401 with a stored refresh token, `handleChallenge` first calls `tokenStorage.clear()`, rediscovers metadata, then tries to refresh. A token-endpoint **4xx** makes `refreshAccessToken` return `false` (the distinction between `invalid_grant`, `invalid_client` and others is lost) and the code then proceeds to full interactive acquisition; network/5xx errors propagate as thrown errors instead. It also reuses the refresh token captured *before* rediscovery against the *newly discovered* token endpoint, with no issuer/binding re-check.
  7. **(review)** Discovery accepts a metadata document whose `issuer` mismatches the candidate as a fallback (`firstValid`) and compares issuers case-insensitively over the whole URL; RFC 8414 §3.3 requires an identical issuer and rejection on mismatch.
  8. **(review)** After a refresh the SDK saves `decoded.refreshToken` directly — if the AS omits a replacement refresh token the stored one is lost instead of retained.
  9. SDK URL checks: the private-address check is for **literal IPs only** (its comment: "DNS rebinding is not prevented here"); it is applied to authorization/token/registration endpoints and some metadata URLs; the loopback-HTTP allowance for authorization servers is `package`-scoped and cannot be set from our package (review).
  10. `OAuthAuthorizer` is documented as "do not share across multiple transports"; its state is only safe under one owning transport actor.
  11. Server→client requests with no registered handler (sampling/roots/elicitation) already receive a JSON-RPC `methodNotFound` reply (`Client.handleIncomingRequest`) — they do not hang (review). Keep a regression test only.
- **Consequence:** the SDK's *`Client`*, *transport* and *OAuth building blocks* save a great deal of work, but it is **not** drop-in for a durable, multi-session, multi-account, hardened client. §6.0 defines a Phase-0 go/no-go between concrete options.

### 2.8 External requirements and server facts
- **[FACT-SPEC]** Streamable HTTP (2025-11-25): single endpoint supporting POST and GET; client must send `Accept: application/json, text/event-stream`; response to a request may be JSON or SSE; `Mcp-Session-Id` returned on initialize must be echoed on every request; a 404 for a known session ID means "start a new session by re-sending `initialize` without the id"; clients should DELETE the endpoint with the session id to end a session (server may 405); `MCP-Protocol-Version` on every subsequent request; resumability via `Last-Event-ID`; backwards-compat: POST initialize first, and if it yields 400/404/405 fall back to GET expecting an `endpoint` SSE event (old HTTP+SSE).
- **[FACT-SPEC]** Authorization (2025-11-25): OAuth 2.1 based, optional for servers. Client MUST support RFC 9728 (WWW-Authenticate `resource_metadata`, then `/.well-known/oauth-protected-resource[/path]`), RFC 8414 and OIDC discovery with the documented path-insertion order, PKCE with S256 (refuse if the AS does not advertise `code_challenge_methods_supported`), RFC 8707 `resource` parameter on both authorize and token requests, Bearer on every request, never in a query string; MUST NOT send a server any token not issued by that server's AS; redirect URIs MUST be localhost or HTTPS, exact-matched; scope from the `WWW-Authenticate` challenge is authoritative; scope step-up on 403 `insufficient_scope` with bounded retries; registration priority: pre-registered → Client ID Metadata Documents (CIMD, HTTPS-URL client id) → RFC 7591 DCR → ask the user.
- **[FACT-SPEC]** Atlassian Rovo MCP (public docs, fetched 2026-10-13): recommended endpoint `https://mcp.atlassian.com/v2/mcp`; `?tools=all` = paginated flat tool list; also `/v1/mcp`, `/v1/mcp/authv2`; legacy SSE `https://mcp.atlassian.com/v1/sse` — support ended after 2026-06-30 (so **legacy HTTP+SSE is not needed for Atlassian**). The default v2 endpoint returns only a few *primary* tools (incl. `atlassianUserInfo`, `getAccessibleAtlassianResources`, `discover`, `executeRead`, `executeWrite`, `executeDestructive`); other operations are deferred and invoked through the executor tools (§7.6). Auth: OAuth 2.1 in browser; or, if the org admin enables it, personal API token via `Authorization: Basic base64(email:token)` or service-account key via `Authorization: Bearer <key>`. The current supported-tools page lists Jira Service Management as supporting both OAuth and API token (an older help page said API-token only — docs are inconsistent; do not hard-code per-product auth). Whether one OAuth grant spans several sites is **not established** (`getAccessibleAtlassianResources` lists the sites the authenticated user can access) → live acceptance test. After the v1→v2 migration, clients may need to clear cached client IDs. Product IP allow-lists are enforced for tool calls (sign-in can succeed, then calls 403). MCP use consumes Rovo credits per Atlassian's operation-specific documentation.

## 3. Design principles and key decisions

1. **[DECISION] Remote servers are a second kind of the same concept** (an "MCP server entry"), not a separate feature: same list, same tool toggles, same Security Agent path, same bridging into `MCPBridgedTool`. Only connection and auth differ.
2. **[DECISION] Instance = independent configuration with its own UUID.** "Same remote more than once" is simply N entries with identical `url` and different `id`, name and credentials. Nothing in storage is keyed by URL. A `catalogID`/template (e.g. `atlassian-rovo`) is only a UI convenience for prefilling.
3. **[DECISION] Keep per-session `MCPClientHost` connections (one per session per enabled server) for v1, but put all credential state behind one process-wide credential owner** (§6.5) so sessions never race on rotating refresh tokens, never each pop a browser, and auth state is global. A shared connection per instance across sessions is *possible* (routing plus per-session subscriptions) but changes failure domains and isolation; deferred, revisit if connection counts hurt (§14).
4. **[DECISION] Interactive sign-in is only ever initiated by an explicit user action** (a button) — never by a background connect, a session start, or an agent tool call.
5. **[DECISION] HTTPS only** for remote endpoints, except literal loopback for local development. The app's `NSAllowsArbitraryLoads = true` must not be relied on; the validator is ours.
6. **[DECISION] Tool-name stability and authority:** each entry has a stable `toolPrefix` distinct from the editable display name, and the host publishes **one authoritative raw-name → public-name table per instance** that all UIs, policies and Security Agent consume (§7.2).
7. **[DECISION] Identity safety:** credentials, policies and security approvals are bound to (instance id, canonical endpoint, issuer, authenticated account). Replacing any of these resets credentials and approvals (§7.5).
8. **[DECISION] The SDK strategy is decided by a Phase-0 go/no-go with retained contract tests** (§6.0), not assumed.
9. **[DECISION] Unknown outcome ≠ retryable.** Once a request may have reached the server, a failed tool call is reported as "outcome unknown" and is never auto-replayed.

## 4. Data model (proposal)

### 4.1 Types
```swift
// AgentSmithKit/MCP/RemoteMCPServerConfig.swift  (new)
public struct RemoteMCPServerConfig: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID                       // instance identity; keys Keychain, tool fingerprints, group ids
    public var name: String                   // display name; unique (case-insensitive, trimmed)
    public var toolPrefix: String             // sanitized slug used in mcp__<prefix>__tool; unique BY SLUG; stable
    public var enabled: Bool
    public var url: URL                       // https only (literal loopback http allowed for dev)
    public var catalogID: String?             // e.g. "atlassian-rovo"; UI hint only
    public var accountLabel: String?          // USER-ENTERED, unverified; shown in UI and to the model
    public var verifiedIdentity: VerifiedIdentity? // from a validated id_token or a catalog-declared identity tool; display "reported by server"
    public var auth: RemoteMCPAuth
    public var plainHeaders: [String: String] // non-secret headers (e.g. X-Org); deny-list enforced
    public var secretHeaderNames: [String]    // names only; values live in the static credential record (§4.3)
    public var disabledTools: Set<String>     // deny-list (today's semantics)
    public var newToolsDefault: NewToolsDefault // .enabled (today's behavior) | .disabled (allow-list mode: tools not yet seen stay off)
    public var requestTimeoutSeconds: Int?    // initialize/list timeout override
    public var schemaVersion: Int             // = 1
    public var unknownFields: [String: JSONValue] // preserved verbatim on re-save (forward compat, §9.2)
}

public enum RemoteMCPAuth: Codable, Sendable, Equatable {
    case none
    case bearerToken                          // secret in static credential record
    case basic(username: String)              // Atlassian: email + API token (needs org-admin enablement)
    case customHeader(name: String)           // e.g. X-API-Key
    case oauth(RemoteMCPOAuthSettings)
}

public struct RemoteMCPOAuthSettings: Codable, Sendable, Equatable {
    public var registration: Registration     // .dynamic (default) | .preRegistered(clientID) | .clientIDMetadataDocument(URL)
    public var scopeOverride: String?         // nil = follow server challenge / metadata
    public var preferredRedirectPort: UInt16? // best-effort preference only (§6.3); NOT a correctness requirement
    public var browserHint: BrowserHint       // .default | .copyLinkOnly | .chosen(bundleID)
    // Runtime facts that must survive restart but are NOT secrets live in the credential record's
    // non-secret header (issuer, resource, client_id, granted scopes, generation) — see §4.3.
}
```
- **[DECISION]** Runtime-only state (connection status, auth state, tool lists, errors) stays out of the persisted struct, as today.
- **[DECISION]** Unify at the host boundary with `enum MCPServerDefinition { case stdio(MCPServerConfig); case remote(RemoteMCPServerConfig) }` exposing `id`, `name`, `toolPrefix`, `enabled`, `disabledTools`. `MCPClientHost.start/applyConfigChange` take `[MCPServerDefinition]`; UI lists use the same enum so one list shows both kinds.
- **[DECISION]** `newToolsDefault` exists because today's server-level Auto/On/Off controls and `disabledTools` only act on *currently advertised* tools (§2.4); a remote server can add tools later (Atlassian v2 does), and the user must be able to say "new tools stay off until I enable them".
- **[OPEN-1]** Alternative: one file with an optional `remote` payload on `MCPServerConfig`. Rejected as default because of downgrade safety (§9.2) and because `command` is currently mandatory.

### 4.2 Files
- **[DECISION]** New global file `~/Library/Application Support/AgentSmith/mcp_remote_servers.json` — a versioned envelope `{ "schemaVersion": 1, "servers": [ … ] }` written by a second `SerialPersistenceWriter`, with load/save methods added to `PersistenceManager` beside the stdio ones. `mcp_servers.json` is **unchanged and is still written only with stdio entries**.
- Saves report durability through `SerialPersistenceWriter.flush()` (which returns whether the write is durable) so the UI never claims success before the file is on disk (§5.6).
- Backups: copy the previous remote file into `backups/` before every schema bump and before any write that follows a decode problem; a failed backup **blocks** the destructive write.
- **[OPEN-2]** Manual ordering across kinds (not available today; default: stdio first, then remote, each in file order).

### 4.3 Credential storage layout (replaces the first draft's per-name accounts)
The first draft proposed many fixed accounts (`<id>/header/<NAME>` etc.) and a "known namespaces" delete list. Review showed header names are dynamic (so a fixed list cannot enumerate them), the SDK token object lacks binding data, and Keychain failures must be surfaced. Revised, using **two Keychain items per instance** (same service string as `MCPSecretStore`, new throwing `RemoteMCPCredentialStore` — the existing `MCPSecretStore` keeps its current semantics for stdio):

1. `<id>/static` — JSON `{ schemaVersion, bearer?, basicPassword?, headers: {NAME: value} }`. One item, atomic, enumerable; deleting an instance deletes exactly `<id>/static` and `<id>/oauth`.
2. `<id>/oauth` — JSON **credential envelope** owned by the app (not the SDK type):
   `{ schemaVersion, instanceID, canonicalResource, issuer, tokenEndpoint, registration: {clientID, authMethod, clientSecret?, secretExpiresAt?, registeredRedirectURI, registrationEndpoint?}, generation (monotonic Int), accessToken, accessTokenExpiresAt, refreshToken?, scopes, tokenType, obtainedAt, boundIdentity? }`.
   - `generation` increments on every successful token write; it is how stale 401s are recognised (§6.5).
   - The envelope binds tokens to `canonicalResource` + `issuer` + `tokenEndpoint` so a changed URL/issuer can never send an old token (§6.3).
- Writes: Keychain write **precedes** use of a rotated token. If the write fails, the new token is kept in memory for this process only, state becomes `credentialsNotPersisted` (loud UI banner: "You will need to sign in again after quitting"), and the failure is logged without secrets. Reads/deletes are throwing; a failed delete during instance removal leaves a visible "could not remove credentials" notice and a retry entry (not silent).
- Keychain attributes unchanged: AfterFirstUnlock, Data-Protection keychain with legacy fallback on `errSecMissingEntitlement`.
- Unit-tested with an in-memory fake store implementing read/write/delete protocols (same pattern as `MCPSecretWriting`).

## 5. UX plan

### 5.1 Add flow
Settings → MCP Servers: replace the "Add Server" button with a menu **Add ▾**: "Local command (stdio)…", "Remote server (HTTPS)…", "Paste JSON…", and quick-add rows from a small built-in catalog (Atlassian Rovo; later others — a plain `[CatalogEntry]` struct, not remote-fetched). Remote sheet (new `RemoteMCPServerEditorSheet`, own file):
1. **URL** field with live validation (https, no fragment, no userinfo, host present; warn on non-standard ports/IP literals; reject query params that look like secrets, e.g. `?token=` / `?api_key=` → advise headers instead since URLs end up in logs; allow the benign `?tools=all` shape used by Atlassian).
2. **Name** (display) and read-only-by-default **Tool prefix** shown as a preview (`mcp__atlassian_work__…`), live collision check against all slugs.
3. **Account label** (optional, shown in list and fed to the LLM, §8).
4. **Authentication** segmented picker: *Sign in with browser (OAuth)* (default) · *Bearer token* · *Username + API token* · *Custom header* · *None*. A "Detect" button performs an unauthenticated probe (§6.1) and preselects OAuth when the server returns 401 + `WWW-Authenticate: Bearer`.
5. Advanced disclosure: extra headers, scope override, pre-registered client ID/secret, timeout.
6. **Test connection** button runs the real handshake without saving (using a throwaway id for Keychain draft accounts, same pattern as the editor's `draftID`), and shows tools discovered. Save is allowed even if untested (offline use) but OAuth entries are saved as *Needs sign-in*.
7. Save → staged commit with a durable result (§5.6).

### 5.2 List/row (extends `MCPServerRow`)
- Globe icon vs terminal icon; subtitle shows `host/path` (not full query) instead of `command args`; account label chip.
- New badges: `needs sign-in` (orange, with **Sign in** button), `signing in…`, `reconnecting (attempt n)`, `auth expired`, `forbidden`/`insufficient scope` (with **Re-authorize**), plus existing connecting/connected/failed/disabled.
- Row menu: Edit · **Sign in / Re-authenticate** · **Sign out (forget tokens)** · **Duplicate as new account…** · Copy URL · Reconnect now · Delete.
- Details disclosure: last connected time, negotiated protocol version, granted scopes, token expiry (relative), last HTTP status, last 20 events (connect/refresh/401), and a redacted request log toggle for diagnosing (never headers/tokens).
- Delete: confirmation dialog stating exactly what is removed (tokens + secrets) and that tasks referencing its tools will show them as disconnected.

### 5.3 Rename vs prefix
Editing Name does **not** change `toolPrefix`. Changing the prefix is a distinct "Change tool prefix…" action with a warning that existing tool policies/overrides keyed by the old prefix will be migrated (the app rewrites `globalToolPolicies` and per-task overrides keys, §9.3) — **[OPEN-3]**: do we implement the key-rewrite, or just block prefix edits after first save? Recommended for v1: block (simple, safe).

### 5.4 Multiple accounts UX (the Atlassian case)
- **Duplicate as new account…** on a remote row opens the editor prefilled with the same URL/catalog, empty credentials, name "Atlassian (account 2)", prefix suggested `atlassian_2`, then immediately offers **Sign in**.
- In the OAuth step show: "Sign in with the account you want for **this** entry. Your browser may silently reuse the account you're already signed in to — use *Copy link* to open it in a private window or another browser profile." (§7.4).
- After sign-in show "Signed in as …" only from a **verified identity** (validated OIDC `id_token`, or a catalog-declared identity tool — Atlassian's documented primary tool `atlassianUserInfo`, shown as "reported by server"); `initialize.serverInfo` is never used (it names the software, not the user). Offer to copy it into the user-editable `accountLabel`; otherwise prompt for a label. **[OPEN-4]** confirm in the Phase-0 spike that the identity tool is callable right after sign-in.
- Duplicate detection: when a second instance has the same canonical URL **and** the same verified subject (issuer + `sub`) as an existing one, warn ("Looks like the same account as 'Atlassian (work)'") but allow; without verified identity, warn only on identical labels.
- Tool list for each instance is independent; Settings → Tools and the per-task Tools editor already group by server so two groups appear ("MCP — Atlassian (work)", "MCP — Atlassian (personal)").

### 5.5 Notifications and transcript
- A remote server entering `needsSignIn` while enabled posts **one** `.mcpStatus` warning per (server, state-change) in each affected session transcript, with text derived from typed data (state + name), plus a deep-link button to Settings (the `onOpenMCPSettings` plumbing exists). Never gate logic on that text. Reuse `ChannelMessageKind.mcpStatus`; if a new kind is judged necessary, follow the closed-enum rules and update the four guard tests.
- A tool call that fails because of auth returns a typed `ToolExecutionResult` failure with a stable human sentence; Brown is told to stop retrying and ask the user (system-prompt note; plus the "abandoned tool failure" reporter already surfaces repeated failures).

### 5.6 Save, sign-out, delete and shutdown ordering (review #8, #26)
- **Save is a staged commit:** (1) validate (URL, slug uniqueness, headers); (2) write secrets to **draft** Keychain items under the instance id (same `draftID` pattern as today so retries reuse accounts); (3) persist the config and **await `SerialPersistenceWriter.flush()`** — only a durable `true` counts as success; (4) only then delete superseded secrets (cleanup failures are logged and surfaced, never block); (5) publish to `SharedAppState` and push the merged list to hosts. On any failure before (3) completes, roll back the newly written Keychain items and show the error; the in-memory list is not updated.
- **Test connection** uses a throwaway id; its Keychain items and loopback listener are deleted/closed on every exit path, including Cancel and app quit.
- **Sign-out:** takes effect immediately — snapshot invalidated, epoch bumped, in-flight auth work cancelled, hosts told to disconnect, then Keychain delete (throwing; failure surfaced with Retry).
- **Delete:** disconnect all hosts (authenticated DELETE best-effort), bump epoch so no late refresh can re-create Keychain items, delete both credential items, remove the config (durable flush), then clear policy keys for that prefix with a notice. A refresh in flight at deletion time is discarded by the epoch check (§6.5).
- **Shutdown/termination:** flush the remote-config writer, cancel auth operations, close listeners, disconnect hosts (existing `shutdownMCP`).

## 6. Transport, client and authentication design

### 6.0 SDK compatibility decision (prerequisite — Phase 0 go/no-go)
Review of the SDK source (§2.7) found gaps that cannot be papered over by wrappers: registration reuse (#4), internal-only OAuth collaborators (#5), refresh error classification and token-clear semantics (#6, #8), issuer validation (#7), GET-stream auth/session recovery, typed HTTP errors/`Retry-After`, and no way to install a redirect-refusing `URLSession` delegate. Three options:

| Option | What | Pros | Cons |
|---|---|---|---|
| **A. Patched fork of `swift-sdk`** (e.g. `drewster99/swift-sdk`, pinned like the owner's other forks) | Minimal patches: public `URLSession`/delegate injection; GET 401/403/404 routed to the authorizer/host; typed HTTP error with status + `Retry-After`; registration seeding (`.none(clientID:)` + "already registered" flag) and exposure of registration results; strict issuer equality; token-clear reason; keep refresh token when AS omits a new one; per-request generation hook | Small app-side code; keeps SDK `Client`, SSE parsing, Streamable HTTP | We own a fork (rebase on each SDK bump); upstream PRs may be slow |
| **B. Own transport + authorizer** on the SDK's **public** `Transport` / `HTTPClientAuthorizer` protocols (`RemoteMCPHTTPTransport` ≈ POST/GET/SSE/session/DELETE, `RemoteMCPOAuth` ≈ discovery/DCR/PKCE/refresh) | Full control: typed errors, redirects, generation-stamped credentials, timeouts, GET semantics | No fork; security-critical code is ours and testable via `URLProtocol` mocks | Larger (~1,500 lines + tests); re-implements RFC 9728/8414/7591/7636/8707 — must be reviewed carefully |
| **C. Unmodified SDK + wrappers** | Only the public API | Least code | **Rejected**: cannot meet requirements for registration persistence, GET-stream auth recovery, redirect protection, typed errors |

**[DECISION]** Phase 0 spikes A and B against the same retained contract-test suite (§11.3) and the real Atlassian endpoint; choose A if the patch set is ≤ ~10 small, upstreamable changes, otherwise B. Whichever wins, the rest of this plan is unchanged because everything is expressed through two internal seams: `RemoteMCPTransportFactory` (returns a `Transport` + a typed `TransportEvents` stream) and `RemoteMCPAuthorizer` (implements `HTTPClientAuthorizer` over the credential owner). **The go/no-go decision, its rationale and the contract-test results are recorded in this document before Phase 1 starts.**

### 6.1 Connect pipeline (`MCPClientHost`)
Refactor `Connection` into a transport-agnostic shape:
```swift
private struct Connection {
    var definition: MCPServerDefinition
    let generation: UInt64            // connection-attempt generation (stamps every async continuation)
    let client: Client
    let handle: TransportHandle       // .stdio(Process, pipes, stderrBuffer) | .http(transport, authBridge, sessionID?)
    var tools: [Tool]; var toolNameTable: [String: String]; var instructions: String?
}
```
- **Connection generations [DECISION, review #14].** Today `performConnect`, `refreshTools` and notification handlers resume after `await` and mutate "whatever connection currently occupies this UUID". With frequent remote reconnects that can tear down a replacement connection or let a stale `listTools` overwrite fresh tools. Every connect attempt, notification, status publication and tool snapshot is stamped with a generation and discarded if `connections[id]?.generation` has moved on. This also fixes the same latent race for stdio.
- `performConnect` switches on definition kind. The stdio path stays behaviorally identical (guarded by existing tests). Remote path: build the transport via the §6.0 factory, `client.connect(transport:)` raced against (a) a deadline and (b) a typed auth-required/transport-failed signal — **no pid watcher**.
- **Timeout policy is per phase [review #28]:** initialize/list ≤ `requestTimeoutSeconds` (default 60 s); ordinary POST requests: `timeoutIntervalForRequest` 60 s; tool execution keeps the existing generous bridged-tool timeout; interactive authorization: 5 min with Cancel; **long-lived GET stream: no request/resource timeout** (otherwise `URLSession` kills idle SSE and we loop). A `ping()` is a POST and proves nothing about the idle GET stream, so health = successful ping **and** stream-event liveness signals from the transport (stream closed events surfaced by A/B); do not infer GET health from ping.
- `URLSessionConfiguration`: **ephemeral**, `httpCookieStorage = nil`, `urlCache = nil`, no shared credentials, system proxy honoured, HTTP/2 allowed — so cookies/credentials never cross between instances (§7.1).
- Static auth headers come from the static credential record at connect time (held in memory only). OAuth bearer comes from the authorizer (§6.5).
- **Header deny-list** for user-supplied headers: `Authorization` (unless the auth mode is `customHeader` named so), `Host`, `Content-Length`, `Content-Type`, `Accept`, `Mcp-Session-Id`, `MCP-Protocol-Version`, `Cookie`, `Proxy-*`, `Transfer-Encoding`.
- **Session and stream semantics [review #31]** — the host must distinguish: (1) *normal SSE stream closure* — spec allows disconnect/resume within the same session → resume with `Last-Event-ID`, **not** a re-initialize; (2) *GET 405* — server offers no standalone stream → continue POST-only, not an error; (3) *transient network loss* → backoff reconnect (new transport, same intent), try session resume first if the server provided a session id and answers GET with `Last-Event-ID`; (4) *definitive session expiry* — **POST/GET 404 with a session id** → fresh `initialize` without the session id (spec requirement), then re-list tools; (5) *auth expiry on GET only* → authorizer path (needs option A/B transport behavior, §6.0).
- **Legacy HTTP+SSE:** not in v1 (SDK lacks it; Atlassian's legacy endpoint ended after 2026-06-30). Per spec a POST `initialize` returning 400/404/405 is a *hint*, not proof; only an `endpoint` SSE event on GET proves the legacy transport. For v1 show "This server doesn't speak Streamable HTTP; legacy SSE servers aren't supported yet" when POST fails 404/405 *and* an inexpensive GET returns `text/event-stream`.
- Server→client requests (sampling/roots/elicitation): SDK already replies `methodNotFound` (§2.7 #11); keep a regression test and a status counter, nothing to build.
- Teardown (disable, delete, sign-out, shutdown): cancel connect tasks; best-effort **authenticated** `DELETE` with `Mcp-Session-Id` and `MCP-Protocol-Version` (2 s cap; interactive auth **suppressed**; 405 ignored); `client.disconnect()`; drop stream; generation bump.
- **Tool paging and limits [review #16, now Phase 1]:** `refreshTools` follows `nextCursor` with cycle detection (visited-cursor set), caps (default 50 pages, 5,000 tools, 16 KB per description, 64 KB per input schema, 2 MB total list) and **atomic replace** of the tool snapshot; over-limit tools are dropped with a visible per-server warning rather than truncating silently. `tools/list_changed` notifications are **coalesced** (single-flight + 500 ms debounce, generation-stamped) so concurrent refreshes cannot complete out of order. Response/SSE event/image size caps (default 10 MB response, 4 MB SSE event, 8 MB image) produce explicit overflow errors. The existing detached-refresh pattern in `performConnect` (SDK message-loop deadlock avoidance) is preserved.
- On refresh failure the existing code publishes `.connected` with `toolCount: 0` and keeps the old tools (§2.3); for remote this is replaced by explicit states (`connected-stale` / `reconnecting`).

### 6.2 Auth modes

| Auth | Mechanism | Notes |
|---|---|---|
| none | no header | UI warns "unauthenticated" |
| bearer | `Authorization: Bearer <secret>` | secret read from `<id>/static` at connect |
| basic | `Authorization: Basic base64(utf8(user:secret))` | Atlassian personal API token (org-admin must enable it); document the email+token case |
| customHeader | `<Name>: <secret>` | X-API-Key style |
| oauth | `RemoteMCPAuthorizer` over the credential owner (§6.5) | below |

Static-credential 401/403 → `authFailed` (never a retry loop); one re-read of the Keychain in case the user just edited it.

### 6.3 OAuth specifics
- **Flow:** protected-resource discovery (WWW-Authenticate `resource_metadata` → well-known path variants) → AS metadata (RFC 8414 + OIDC order from the spec) → registration → authorization code + PKCE S256 → token → refresh. **Binding rules enforced by us before any token is sent (review #12):** issuer in metadata must be *exactly* equal (case-sensitive) to the discovered issuer, otherwise reject; the stored envelope's `issuer`, `tokenEndpoint` and `canonicalResource` must equal what rediscovery returns **before** an access or refresh token is sent anywhere; mismatch → tokens dropped, state `needsSignIn` ("This server's authorization provider changed").
- **Registration order:** pre-registered client (user-entered id[/secret]) → CIMD (only if the AS advertises `client_id_metadata_document_supported` *and* the project hosts a metadata document, **[OPEN-6]**) → DCR → ask the user. The registration result (client_id, secret, secret expiry, registered redirect URI) is stored in the envelope and **reused** on re-authorization; with option A/B we control "already registered" explicitly (the unmodified SDK would silently re-register, §2.7 #4). Treat `invalid_client` on refresh as "registration revoked/expired → re-register then needsSignIn", distinct from `invalid_grant`.
- **Redirect receiver [DECISION, corrected after review #22/#30]:** loopback `NWListener` on `127.0.0.1`. **Bind first, then build the redirect URI from the actual bound port** (never probe-then-release). Default: OS-assigned ephemeral port per sign-in — RFC 8252 §7.3 requires authorization servers to accept any port for loopback IP redirects. Because real servers vary (and DCR registers a concrete URI), keep `preferredRedirectPort` as a *best-effort* preference: try to bind it first; if busy, use an OS port. A busy port **must not** silently trigger new DCR for a *pre-registered* client (fail with a clear message instead); for DCR clients a changed port is re-registered only when the AS rejected the redirect. `localhost` vs `127.0.0.1` spelling and IPv6 are compatibility knobs resolved in the Atlassian spike (if `localhost` is required, listen on both `127.0.0.1` and `::1`).
- **Listener hardening:** accept only `GET /callback` from loopback; **ignore** malformed/unrelated requests without consuming the one-shot flow; bound request size (8 KB) and read time (5 s); validate `Host`, exact path, single `state`/`code` parameters (reject duplicates), and handle provider `error`/`error_description`; complete **exactly once** (cancel/timeout/success are mutually exclusive) and close the listener on every terminal path; serve a static "return to Agent Smith" page that never echoes the code. 5-minute timeout with a Cancel button.
- **Browser:** `NSWorkspace.shared.open` default browser, plus **Copy link** and "Open in…" browser picker (§7.4). No custom URL scheme in v1 (the spec requires localhost/HTTPS redirects; it would also need `CFBundleURLTypes` in `AgentSmith/Info.plist`, which currently has none).
- **Scopes:** challenge scope → `scopes_supported` → none; `scopeOverride` available. 403 `insufficient_scope` step-up only in a user-initiated context; in the background it becomes `needsReauthorization(scopes)`.
- **Refresh:** proactive (window raised to 120 s) and on 401, always through the credential owner (§6.5). Rotation: always persist the newest refresh token **before** use; if the response omits a new refresh token keep the old one.
- **Sign-out:** immediately invalidate the in-memory snapshot, bump generation, cancel in-flight auth work, delete `<id>/oauth` (throwing; surfaced), notify all hosts to disconnect, best-effort RFC 7009 revocation if `revocation_endpoint` is advertised; UI explains the grant may still be listed at the provider (e.g. Atlassian "connected apps").
- `client_credentials` (machine-to-machine): Phase 4 under Advanced; Atlassian service accounts use plain Bearer instead.

### 6.4 No surprise browsers
`RemoteMCPAuthorizer`'s interaction hook throws `interactionRequired` unless the credential owner reports a user-initiated sign-in for that instance. The host maps it to `needsSignIn` — no retry storm, no pop-up from a background connect, session start or tool call. Teardown paths (DELETE, disconnect) also pass a "no interaction" flag.

### 6.5 `RemoteMCPCredentialOwner` (process-wide, owned by `SharedAppState`)
Single owner of credentials and auth state per instance, designed after review #9, #10, #17–#19:
- **Per-instance operation owner + generations.** All mutations (sign-in, refresh, step-up, sign-out, delete, re-register) run through one serialized operation queue per instance with an `epoch` (bumped by sign-out/delete/endpoint change) and the credential `generation` (bumped per token write). An operation that completes under an obsolete epoch is discarded: it can never restore tokens, re-create Keychain items for a deleted instance, reconnect, or overwrite a newer sign-in. Actor isolation alone is not enough because the actor re-enters at every `await` (discovery, token POST, browser wait).
- **Synchronous snapshot for synchronous protocol methods.** `HTTPClientAuthorizer.authorizationHeader(for:)` is synchronous, so the owner publishes an immutable `CredentialSnapshot { generation, headerValue?, expiresAt }` in a lock-protected box per instance; sessions read it without hopping actors.
- **Stale-401 rule [review #10].** The authorizer bridge records which `generation` it last handed out. On 401: if the owner's current generation is **newer** than the one the rejected request used → just retry with the current token (no refresh, no clear). Only when the rejected generation **equals** the current one does a refresh start — coalesced so N sessions cause one refresh. A late 401 can therefore never clear or re-refresh a token that was already replaced.
- **Explicit lifecycle operations instead of "soft clear" [review #18].** Distinct operations: `invalidateAccessToken(generation)` (rejected), `refresh()`, `markNeedsSignIn(reason)` (only on `invalid_grant`/binding change/user sign-out), `removeGrant()`. A transient refresh failure (network/5xx/429) never drops the refresh token. This is expressed through our own authorizer (options A/B); the unmodified SDK `clear()` cannot carry these distinctions.
- Owns the sign-in flow (listener, browser, token write) and the instance's published `AuthState`: `signedOut | needsSignIn(reason) | signingIn | authorized(expiresAt) | refreshing | needsReauthorization(scopes) | credentialsNotPersisted | failed(reason)`, republished to `SharedAppState` for the UI. Hosts of closed sessions never own anything (no "first session owns auth" design: closing a session must not affect others).
- Keychain persistence per §4.3, write-before-use.
- Static-credential instances use the same owner for secret reads (so deletion and edits are race-free) but have no refresh logic.

### 6.6 Reconnect, status and monitoring
- **State model:** `MCPServerStatus.State` gains `needsSignIn, signingIn, reconnecting, authFailed, forbidden`. Every exhaustive switch is updated (`MCPServerManagementView.statusBadge`, `AppViewModel.announceMCPFailuresIfNeeded`, tests). New fields: `kind`, `lastConnectedAt`, `lastErrorKind` (typed: `network, tls, dns, http(status), protocol, auth, rateLimited, timeout, serverClosed, overflow`), `reconnectAttempt`, `nextRetryAt`, `protocolVersion`, `toolNameTable`.
- **Per-connection status, global auth [review #21].** `SharedAppState.reportMCPStatuses` today is "latest report wins" and never removes vanished entries. For remote it becomes keyed by `(sessionID, instanceID)`; the settings row shows the focused session's status (or an aggregate like "connected in 2 of 3 sessions"), while `AuthState` is global and comes from the credential owner. Vanished sessions' entries are removed on host shutdown.
- **Backoff [DECISION]:** exponential 1 s → 2 → 4 … cap 60 s, ±20 % jitter, reset after 60 s of stability, honour `Retry-After` on 429/503, stop after 8 consecutive failures (→ `failed`, user presses *Reconnect*). Pause while offline/asleep (`NWPathMonitor`), retry immediately when the network returns.
- **Never retry** on: 401 with no refresh path (→ `needsSignIn`), 403 (→ `forbidden`), TLS trust failures (→ `failed` with actionable text), HTTP 4xx other than 408/429.
- Every reconnect builds a **fresh transport and `Client`** (a disconnected SDK transport is dead, §2.7).
- After reconnect tools are re-listed; the existing candidate-fingerprint mechanism re-scopes if definitions changed.
- `waitUntilSettled` treats `needsSignIn`, `authFailed`, `forbidden`, `reconnecting` as settled so slow/unauthenticated remotes never hold Brown's start for the 5 s window.

### 6.7 Typed failures end to end [review #25]
`ToolExecutionResult` today is only `{ output: String, succeeded: Bool }` and the SDK wraps most transport/auth errors as `MCPError.internalError(String)`. Plan:
1. Option A/B surfaces a typed `RemoteMCPError` (status, `Retry-After`, auth-required, permission-denied, overflow, session-expired, **request-sent?** flag).
2. `MCPClientHost.callTool` classifies into `ToolFailureKind`: `authRequired`, `permissionDenied`, `cancelled`, `notExecuted` (failed before the request was sent / refused locally), `outcomeUnknown` (request may have been delivered — disconnect, timeout, stream drop after send), `serverError`, `toolReportedError`.
3. Additive, source-compatible change to `ToolExecutionResult`: optional `failureKind: ToolFailureKind?` (default nil; existing call sites unchanged). Control flow reads the typed kind — never the prose (CLAUDE.md rule).
4. The model-facing sentence for `outcomeUnknown` is explicit: "The request may have been executed on the remote server; verify the current state before retrying — do not repeat a write blindly." Never describe an unknown outcome as "retryable". `authRequired` tells Brown to stop and ask the user to sign in; a transcript `.mcpStatus` warning is posted from the typed state.
5. The host **never auto-retries** a tool call after it may have been sent.

## 7. Multiple instances of the same remote (detail)

### 7.1 Isolation guarantees (each is a test, §11)
1. Distinct UUIDs → distinct Keychain items (`<id>/static`, `<id>/oauth`) → no shared tokens, client registrations or secrets.
2. Each OAuth instance registers its own client (DCR) by default, so it holds its own registration and tokens. **No promise is made that the provider presents separate, independently revocable grants** — that is provider behavior (review #23); the UI copy says "sign in separately for each entry".
3. Separate ephemeral `URLSession` per connection with no cookie/credential/cache storage; no shared `Mcp-Session-Id`.
4. Distinct `toolPrefix` → distinct public tool names, policy keys and per-task overrides; **plus** a Security Agent group id derived from the instance (§7.3).
5. Credential owner keyed by instance id; a sign-in for instance A cannot satisfy a pending connect for B (the loopback `state` is bound to instance id + operation epoch).
6. **Duplication** ("Duplicate as new account…") copies only non-credential settings (URL, catalog id, headers' names without values, prefs). It **clears** tokens, client registration, verified identity, granted scopes, timestamps, redirect-port preference, and any listener/callback ownership, and gets a new UUID.

### 7.2 Naming — one authoritative table (review #15)
- **Prefix uniqueness is slug-level**: at save time compute `MCPToolNaming.sanitizeComponent(prefix)` (case-insensitive) and reject collisions across *all* stdio and remote entries (the existing check compares raw names only; "Atlassian Work" and "Atlassian_Work" both slug to `Atlassian_Work` today and then silently get `_2` suffixes by sort order). The same rule is applied on every load (§9.2).
- **Collisions inside one server** (sanitization/truncation) are resolved today by `assignPrefixedToolNames` over only the *enabled* tools, so disabling one colliding tool can rename another, and `ToolsSettingsView` / `TaskToolOverrideEditor` each rebuild names independently with `MCPToolNaming.prefixedName` (no collision resolution). **[DECISION]** Compute the public names over **all advertised tools** (stable regardless of toggles), store the result as `toolNameTable: [rawName: publicName]` in the status, and make `currentBridgedTools`, both policy editors and Security Agent read that one table. Save-time checks cannot cover future tool changes or offline saves, so this is the only robust fix; it also repairs the same latent problem for stdio.
- Prefix budget: 64-char tool-name cap, `maxServerSlugLength` 49, `minimumToolPartLength` 8. Atlassian tool names (e.g. ~24 chars) + `mcp__atlassian_personal__` (25) fit; warn when a prefix exceeds ~20 characters.

### 7.3 Telling the model and Security Agent which instance is which (corrected after review #7)
- **Verified:** Security Agent groups are *not* identical today: `groupID = "mcp__\(mcp.serverName)"` and the group `name` is `serverName` (`SecurityEvaluator` ~L1504-1525); only the *descriptions* (server instructions) are identical across two instances of one remote. The first draft was wrong to say the groups were indistinguishable, and also wrong that "distinct prefixes give distinct group ids" — the id is derived from the **display name**, not the prefix, so a rename would change it and two names that sanitize alike could collide.
- **[DECISION]** Group id becomes `mcp__<instanceID>` (UUID-based, rename-proof, collision-proof) with `name` = display name; group description = `"<server instructions or default> — Remote MCP server <host>, account: <accountLabel / verified identity>"`. Bridged tool descriptions get a `[<display name> — <account>] ` prefix (data field `instanceLabel` on `MCPBridgedTool`); the label is part of the description, so editing it changes the candidate fingerprint and forces a re-scope.
- **Open-world flag [review #7]:** forcing remote tools to `isOpenWorld = true` must be done where Security Agent reads it. `SecurityEvaluator` classification reads `mcp.openWorldHint` directly (not `isOpenWorld`), so overriding only `MCPBridgedTool.isOpenWorld` is insufficient. **[DECISION]** set the *effective* `openWorldHint = true` at `MCPBridgedTool` construction for remote definitions so every consumer sees the forced value.
- **What the per-server Auto/On/Off control really does [review #29]:** it writes individual `userToolOverrides`/`globalToolPolicies` keys for the tools *currently advertised* — it is a bulk edit, not a persistent server-level rule, and does not cover tools that appear later. So "this task may only use Atlassian (personal)" is **not** guaranteed today. **[DECISION]** add an instance-level rule: `newToolsDefault = .disabled` (allow-list mode, §4.1) for per-instance enforcement of "future tools stay off", and describe the UI control honestly ("sets all current tools"). A true *per-task instance restriction* (allow only instance X's tools for this task) is a small extension of the existing task tool override model — **[OPEN-11]** whether to build it in v1.

### 7.4 Getting a second account through browser SSO
The system browser will typically auto-select the already-signed-in Atlassian account. Mitigations (all UI-level, no protocol hack): (a) show the authorization URL with **Copy link** so the user can paste it into a private window / another profile / another browser; (b) an **Open in…** browser picker (`NSWorkspace.urlsForApplications(toOpen:)`); (c) optionally append `prompt=login` / `select_account` to the URL handed to the delegate only if the AS metadata advertises it in `prompt_values_supported` — **[OPEN-8]** confirm Atlassian honours it. The UI always shows "Signed in as …" after sign-in and, if it matches an existing instance's identity, warns before saving.

### 7.5 Identity, account replacement and security approvals (review #11, #23)
- **Verified:** `MCPBridgedTool.identityToken` is only `serverID.uuidString`; the scoping fingerprint hashes name + description + identityToken + schema (`ToolRegistry.fingerprint`). It does **not** include endpoint URL, authenticated principal, grant generation or server instructions. Re-authenticating the *same entry* as a different account, or editing its URL, can therefore keep an identical fingerprint when tool names/descriptions are unchanged, and explicit name-keyed policies survive anyway.
- **[DECISION]** `identityToken` for remote = hash(`instanceID` | canonical endpoint | issuer | account subject (verified identity if any) | credential *principal epoch*). Any of those changing → new fingerprint → forced re-scope. A **principal epoch** increments when sign-in completes with a different verified subject than before, or when the URL/issuer changes. Name-keyed `globalToolPolicies`/per-task overrides for that instance are **reset** (with a one-time notice listing what was reset) when the endpoint or principal changes, because they were granted for a different target.
- **Verified identity vs label:** `accountLabel` is user text. `verifiedIdentity` is set only from (a) an OIDC `id_token` validated per spec (issuer, audience, signature via JWKS, expiry), using `sub` as the durable key (email is display only), or (b) a catalog-declared **identity tool** (Atlassian: the documented primary tool `atlassianUserInfo`) called once after sign-in and shown as "reported by server". `initialize.serverInfo` identifies the software, not the user, and is never used for identity.
- Duplicate-account detection compares verified subjects (issuer + `sub`) when available, otherwise warns on identical labels only.

### 7.6 Atlassian Rovo specifics that change the security design (review #32, #33)
- **Verified (Atlassian docs, fetched 2026-10-13):** the default v2 endpoint `https://mcp.atlassian.com/v2/mcp` returns a few **primary tools** (including `atlassianUserInfo`, `getAccessibleAtlassianResources`, `discover`, `executeRead`, `executeWrite`, `executeDestructive`) and exposes the rest as *deferred operations* found via `discover` and invoked **through** the three executor tools. The flat, paginated list is `https://mcp.atlassian.com/v2/mcp?tools=all`.
- **Consequence:** on the default endpoint, disabling an individual operation in our per-tool toggles is meaningless — it is invoked as an *argument* of `executeWrite`/`executeDestructive`, so the toggle surface and Security Agent see only the outer tool. Security Agent still gates each outer call and sees its arguments, but there is no per-operation allow-list.
- **[DECISION / OPEN-12]** The catalog offers two Atlassian presets with plain-language labels: *"Flat tool list (granular control; many tools)"* — `?tools=all`, **recommended default** because it preserves per-tool toggles and per-tool Security Agent scoping, and makes pagination support mandatory — and *"Compact (discover/execute)"*. For the compact preset, `executeRead/Write/Destructive` are treated as high-risk tools whose arguments are surfaced to Security Agent. Drew to confirm the default.
- Docs for supported auth by product are not entirely consistent: the current supported-tools page lists Jira Service Management read/write as supporting **both** OAuth 2.1 and API token (an earlier help page said API-token only); the plan does not hard-code per-product auth rules and the UI surfaces server errors verbatim instead.
- "One OAuth grant spans several sites" is **not established** by the docs we could read (`getAccessibleAtlassianResources` lists the sites/`cloudId`s the *authenticated user* can access). It is therefore a live acceptance test (§11.5), not a promise in UI copy. API-token auth has different cloud-ID semantics from OAuth per Atlassian's docs.
- Product IP allow-lists apply to MCP tool calls; sign-in can succeed and calls then fail 403 — UI maps this to the `forbidden` state with explanatory text.

## 8. Credential storage and isolation (summary)
- Secrets (bearer, basic password, header values, OAuth tokens, client secret) → Keychain only (two items per instance, §4.3), accessible AfterFirstUnlock, DPK with legacy fallback exactly like `MCPSecretStore`. Never in JSON, logs, crash reports, transcript, LLM requests (`AgentSmith-LLM-Logs` are DEBUG request logs — tool *results* are logged there, so never echo tokens into tool output), or `task_update` text.
- `RemoteMCPServerConfig` JSON contains only non-secret fields (URL, labels, header *names*, client id, port, scopes).
- URL query secrets rejected (§5.1). Authorization header redaction in any diagnostics.
- Memory hygiene: tokens held in the credential owner's snapshot box; not stored in `MCPServerStatus`, not logged (`privacy: .private`), not copied to the pasteboard.
- Export/import: "Paste JSON" import of `{"mcpServers": {"x": {"url": "...", "headers": {...}}}}` (the common Cursor/Claude format for remote servers; the `"type":"http"|"sse"` key varies) should create *remote* entries; header values → Keychain; `Authorization: Bearer xyz` recognised as bearer auth. Entries with `"type":"sse"` → warn legacy/unsupported. This directly fixes today's "skipped: no command" behavior (`MCPConfigImport`).
- Backups: `mcp_remote_servers.json` contains no secrets so it is safe in app backups; Keychain items are not exported. Moving to another Mac requires re-sign-in (documented in UI).

## 9. Migration and backwards compatibility

### 9.1 Existing stdio configs
- `mcp_servers.json` and `MCPServerConfig` are **untouched**; zero migration for existing users; the stdio path in `MCPClientHost` is kept behaviorally identical (existing tests `MCPToolTests`, `MCPSIGPIPEScopeTests`, integration suites remain the regression net).
- `SharedAppState.mcpServers: [MCPServerConfig]` stays; add `remoteMCPServers: [RemoteMCPServerConfig]` and a computed `allMCPDefinitions`. `updateMCPServers` stays; add `updateRemoteMCPServers`. Both ultimately call one `pushDefinitionsToHosts()` so hosts always receive the merged list (otherwise `applyConfigChange` would tear down the other kind as "removed" — **[RISK]**: `applyConfigChange` treats ids absent from the new list as removed).
- `MCPToolNaming`, bridged tool, policies, Security Agent paths need no format change for prefixed names.

### 9.2 Downgrade / forward safety (the decode-failure trap, §2.1; strengthened after review #20)
- Remote entries live in a **separate file**, so an older build ignores it and never overwrites it. This is necessary but not sufficient (an older build can still add stdio names that collide with remote prefixes, or edit shared policy files with no knowledge of remote instances).
- **Validate on every load, new build or not:** duplicate UUIDs across *both* files (note: `MCPClientHost.applyConfigChange` uses `Dictionary(uniqueKeysWithValues:)`, which **traps** on duplicate ids — a hand-edited duplicate would crash the app today); duplicate/colliding slugs across stdio + remote; invalid URLs. Offenders are loaded **disabled** with a visible "conflict" badge and are never silently dropped or renamed.
- `schemaVersion`: a newer-than-known version opens read-only with a banner (no overwrite). Within a known version, **unknown fields on otherwise decodable entries are preserved** (`unknownFields`), and wholly undecodable entries are kept as raw JSON and re-written untouched.
- **Backup failure blocks destructive overwrite** (§4.2). A corrupt `mcp_servers.json` today yields a silently empty, *editable* list (`SharedAppState` logs and continues with `[]`, and the next save overwrites the file). **[DECISION]** harden the existing loader in a small separate change: on decode failure copy the file to `backups/mcp_servers-<timestamp>.json`, show a recovery banner, and keep the stdio list read-only until the user resolves it.

### 9.3 Policy-key migration
Prefixed names for existing stdio servers do not change. For remote entries created by the "Duplicate" flow no migration is needed. If [OPEN-3] later allows prefix change, rewrite keys in `globalToolPolicies` and per-session `tasks.json` `userToolOverrides` through the single `TaskStore` writer (CLAUDE.md: `TaskStore` is the single writer of `tasks.json`).

## 10. Security and privacy considerations
1. **Trust model.** A remote MCP server is third-party code that sees every argument Brown sends and returns text that enters the LLM context (a prompt-injection channel) — more exposure than a local server the user installed. All calls remain Security-Agent-gated; annotations stay untrusted (existing); `isDestructive`/`isOpenWorld` fail closed; remote tools are forced **effective** `openWorldHint = true` at bridge construction (§7.3) because they leave the machine.
2. **Data egress / cost.** Adding a remote server sends task data to that operator. First-enable consent text lists host and account. For Atlassian, MCP use consumes Rovo credits according to Atlassian's operation-specific documentation (not a uniform per-request charge; consumption and monetary billing are different things) — UI copy refers to Atlassian's documentation instead of quoting numbers.
3. **Network targets / SSRF.** User-entered URLs may point at localhost/RFC1918 hosts; allowed with a "local network host" badge (`NSLocalNetworkUsageDescription` already exists). The SDK's private-address check covers **literal IPs only and does not prevent DNS rebinding**; do not describe it as SSRF protection. Our validator additionally re-resolves and refuses OAuth endpoints (authorization/token/registration) that resolve to private ranges unless the *MCP endpoint itself* is on that private network (same-trust-zone rule) — **[OPEN-9]** whether to ship this extra DNS-aware check in v1. Intranet OAuth servers on RFC1918 literals are blocked by the SDK by design; surface that error clearly.
4. **TLS.** System trust only; no "ignore certificate errors" toggle in v1 (corporate MITM CAs installed in the macOS keychain already work).
5. **Redirect and credential-leak protection (review #13) — enforceable design.** Relying on `URLSession` stripping `Authorization` across hosts is not enough (custom API-key headers, token-request bodies, scheme/port changes, discovery redirects). **[DECISION]** every credential-bearing or credential-adjacent request type (MCP POST/GET/DELETE, discovery documents, DCR, token, revocation) is sent on a session whose `URLSessionTaskDelegate` **refuses any redirect that changes scheme, host or port** (and any redirect to non-HTTPS), and never forwards custom headers across origins. This needs the SDK patch or own transport from §6.0 (the public SDK API cannot install the delegate). Tests assert it for each request type.
6. **Token binding.** Tokens are only ever sent to the configured origin and only if issuer/resource/token-endpoint match the stored envelope (§6.3); mismatches drop tokens and require sign-in.
7. **Loopback receiver hardening** (§6.3): loopback only, state + PKCE, single use, bounded input, timeout, never logs or echoes the code; a squatting process that binds the port first gains nothing (PKCE) and the flow aborts on state mismatch.
8. **Phishing/consent.** The consent page belongs to the provider; we show the exact host before opening it and only open `https` authorization URLs.
9. **Logging.** Never log tokens, `Authorization`, cookies, secret headers, or URLs' query strings at info level (`privacy: .private`). DEBUG LLM request logs capture tool *results* — remote results may contain customer data; unchanged existing policy, documented.
10. **Resource-exhaustion by a hostile/buggy server.** Caps on pages, tools, description/schema size, response/SSE/image size, notification rate (§6.1) with explicit overflow errors; reconnect backoff; per-server concurrency cap for in-flight requests (default 8).
11. **Credential lifecycle.** Write-before-use, generation-checked, epoch-checked operations (§6.5); sign-out/delete ordering in §5.6; Keychain failures surface as state, never silently.
12. **Supply chain.** swift-sdk is `.upToNextMinor(from: "0.12.1")` and its OAuth surface is young. Whichever option §6.0 selects, pin the exact revision (fork or SDK) and run the retained contract suite on every bump.

## 11. Testing plan

### 11.1 Unit tests (package, `swift test --skip MemoryStoreIntegrationTests`)
- `RemoteMCPServerConfig` Codable round-trip, tolerant decoding, unknown fields preserved, schemaVersion handling, lossy array keeps bad entries raw, duplicate UUID / slug conflict handling on load, **`MCPClientHost` no longer traps on duplicate ids**.
- URL validator: https required, loopback exception, userinfo/fragment/secret-query rejection, punycode, `?tools=all` accepted.
- Header deny-list; Basic encoding (non-ASCII); redirect delegate refusing scheme/host/port change for **each** request type (MCP POST/GET/DELETE, discovery, DCR, token, revocation).
- Slug uniqueness (`Atlassian Work` vs `Atlassian_Work`), prefix budget, `toolNameTable` stability when tools are toggled, and `MCPToolNaming` invariants with two instances (extend the existing property-style tests); both policy editors consume the table.
- `RemoteMCPCredentialStore` with an in-memory fake: two instances, same URL → separate items; delete one leaves the other; throwing read/delete; failed rotation write → `credentialsNotPersisted`.
- Credential owner (deterministic clock + fake network): refresh coalescing (N callers → 1 token request); **late 401 with an old generation does not trigger a second refresh or clear the newer token**; rotation persisted before use; refresh-omits-new-refresh-token keeps old; transient 5xx/network keeps refresh token; `invalid_grant` → `needsSignIn`; `invalid_client` → re-register path; sign-out during rotation; delete during refresh (no Keychain item re-created); cancellation during callback completion; epoch/generation discard of obsolete completions; endpoint/account replacement resets approvals.
- Binding: issuer mismatch (case/trailing slash), changed token endpoint, changed resource → tokens not sent.
- Backoff scheduler, `Retry-After`, no-retry classes; typed error classification (`notExecuted` vs `outcomeUnknown`) and **no auto-replay**.
- Tool paging: cursor cycle, caps, overflow, atomic replace, coalesced `list_changed`.
- Persistence: backup-failure-blocks-write, corrupt stdio file → read-only recovery, durable save result from `flush()`.
- `MCPConfigImport` remote entries (`url`, `headers`, `type`).

### 11.2 Offline integration tests — **mandatory in the normal suite** (review #27)
- Authorization-server and MCP-server fixtures run in-process with a `URLProtocol` mock network (works with HTTPS URLs, no real sockets/TLS and no dependency on the SDK's package-scoped loopback-HTTP flag), implementing: Streamable HTTP POST JSON + SSE, session ids, 404 session expiry, GET-only 401/404, `tools/list` pagination, `tools/list_changed`, 401 + `WWW-Authenticate resource_metadata`, RFC 9728/8414 metadata, DCR, authorize (simulated browser via delegate), token with refresh rotation, `invalid_grant`, `insufficient_scope`, 429 + `Retry-After`, redirects to another origin, oversized bodies.
- Two instances of the same fixture server with two fake accounts: tokens/tools/names/policies isolated; signing out of one leaves the other connected; concurrent refresh from three simulated session hosts → one refresh; account replacement forces re-scope.
- Reconnect: server killed mid-session → `reconnecting` → recovery; session expiry → re-initialize; token expiry mid-call; disconnect after request sent → `outcomeUnknown`.
- Mixed stdio + remote `applyConfigChange` never tears down the other kind; host generation checks (stale connect/list completion discarded).
- Real-socket loopback server variant is opt-in (`MCP_REMOTE_INTEGRATION=1`), like the existing `MCP_INTEGRATION=1` suites; those stdio suites remain unchanged regression nets.

### 11.3 Phase-0 retained contract tests (go/no-go for §6.0)
Executable tests that every candidate (fork A, own B) must pass and that stay in the repo: registration reuse without re-registering; strict issuer equality; refresh classification (`invalid_grant`/`invalid_client`/5xx); token-clear reasons; GET-stream 401 → authorizer; GET/POST 404 session handling; typed errors incl. `Retry-After`; redirect refusal; header handling; unregistered server request → methodNotFound.

### 11.4 UI / guard tests
New views obey `CodeStyleGuardTests` ratchets (small subviews, no `Lazy*`, no `.onTapGesture`, no multiple trailing closures); accessibility labels on icon buttons; exhaustive switches updated.

### 11.5 Manual / live acceptance (checklist in the PR)
Atlassian OAuth account 1; **second account via private window/copy-link**; whether one grant spans several sites (do not promise in UI before this passes); `?tools=all` pagination and the compact discover/execute preset incl. executor-argument visibility to Security Agent; Basic API token (admin-enabled org); IP-allow-list 403 mapping; sleep/wake, VPN switch, corporate proxy; kill network during a write tool call (confirm `outcomeUnknown` text); app quit/relaunch with rotated refresh token; smoke test per CLAUDE.md (15 s run, screenshot, logs).

## 12. Phased rollout

**Phase 0 — SDK go/no-go spike (no UI; retained tests merge, spike code may not):** build contract tests (§11.3); implement A (fork patches) and B (own transport/authorizer) just far enough to run them; run against the offline fixtures and the **real Atlassian endpoint**; verify: loopback redirect acceptance (port variability, `127.0.0.1` vs `localhost`), DCR/registration reuse, refresh rotation, SSE GET staying alive > 60 s, `prompt=` support, `?tools=all` paging, `atlassianUserInfo` identity, multi-site grant behavior. **Exit criteria:** written decision A or B in this document + results; updated [OPEN] items.

**Phase 1 — Model, persistence, host refactor (flagged off):** `RemoteMCPServerConfig`, separate file + load validation + backup hardening (incl. existing stdio loader fix), `MCPServerDefinition`, transport-agnostic `Connection` with **generations**, `toolNameTable` (all-advertised naming) + both editors consuming it, tool paging/limits/coalescing, typed `ToolFailureKind`, static auth modes (none/bearer/basic/header), HTTP connect/teardown/DELETE, reconnect/backoff, new states, per-session status keying; offline tests. Hidden setting `remoteMCPEnabled` (UserDefaults) keeps it dark.

**Phase 2 — UI:** Add menu, remote editor, row badges/menu, durable save/delete ordering (§5.6), import of URL entries, Tools-settings labels, transcript notifications, catalog (Atlassian presets).

**Phase 3 — OAuth:** credential owner, envelope store, loopback receiver, sign-in/re-auth/sign-out UI, step-up, binding checks, instance duplication, second-account workflow, verified identity; fixture tests; Atlassian live acceptance.

**Phase 4 — Hardening & extras:** Security Agent group id/description/labels + effective open-world (small, can ship with Phase 2 if instances ≥ 2 are enabled earlier), identity-change approval reset, per-task instance restriction ([OPEN-11]), health/`NWPathMonitor` polish, diagnostics view, CIMD (if hosted), `client_credentials`, legacy SSE (if wanted), per-server timeouts. Flip the flag on, release notes.

**Gate:** multi-instance (≥ 2 enabled instances of the same URL) must not be enabled in any build until §7.2/§7.3/§7.5 (name table, group id, identity token) have landed — otherwise policies and Security Agent cannot tell accounts apart safely.

Each phase merges independently, builds via drews-xcode-mcp, `swift test --skip MemoryStoreIntegrationTests` green, and updates `ROADMAP.md` (mark completed items ✅, don't delete) and the MCP notes in `CLAUDE.md`/`docs/claude/`.

## 13. Stumbling blocks register (consolidated; "R" = added/changed by the external review)

| # | Area | Risk | Mitigation (section) |
|---|---|---|---|
| 1 | Persistence | Remote entries break older builds' all-or-nothing decode and then get overwritten (verified loader behaviour) | Separate file; lossy decode + unknown-field preservation; backup-before-write; read-only recovery (§9.2) |
| 2 | Persistence | Duplicate UUIDs crash `Dictionary(uniqueKeysWithValues:)` in the host (R) | Validate on load; conflicting entries load disabled (§9.2) |
| 3 | Naming | Slug collisions of different names; `_2` assignment order-dependent | Slug-level uniqueness on save *and* load (§7.2) |
| 4 | Naming | Intra-server collisions renamed by toggles; two editors recompute names independently (R) | One authoritative `toolNameTable` over all advertised tools (§7.2) |
| 5 | Policies | Policies keyed by prefixed name → rename orphans them; server-level Auto/On/Off only edits current tools (R) | Stable `toolPrefix`; `newToolsDefault`; honest UI copy (§5.3, §7.3) |
| 6 | Security Agent | Group id derived from display name, descriptions identical across accounts (R: groups are distinguishable today, but fragile) | UUID-based group id + account-labelled descriptions (§7.3) |
| 7 | Security Agent | Open-world override on `MCPBridgedTool.isOpenWorld` isn't what Security Agent reads (R) | Force effective `openWorldHint` at construction (§7.3) |
| 8 | Identity | Re-auth as another account or URL edit keeps same fingerprint; old policies survive (R) | Identity token includes endpoint/issuer/principal epoch; reset approvals (§7.5) |
| 9 | OAuth/SDK | Seeded client_id does **not** skip DCR; registration results private; OAuth collaborators internal (R) | §6.0 go/no-go (fork or own implementation) |
| 10 | OAuth/SDK | Issuer mismatch accepted; refresh token reused against rediscovered endpoint; refresh-omits-token drops old one (R) | Binding checks before sending any token; strict issuer equality (§6.3) |
| 11 | OAuth | Random/varying redirect port vs DCR; no listener/URL scheme exists | Bind-first listener, ephemeral port per RFC 8252, preferred-port as best effort, Atlassian spike (§6.3) |
| 12 | OAuth | Refresh-token rotation + N per-session hosts; late 401 clears a newly refreshed token (R) | Credential owner with generations/epochs; stale-401 rule (§6.5) |
| 13 | OAuth | Actor re-entrancy lets obsolete completions overwrite newer state (R) | Per-instance serialized ops + epoch checks (§6.5) |
| 14 | OAuth | Background connect could open a browser (SDK auto-acquires on 401) | Interaction hook refuses unless user-initiated (§6.4) |
| 15 | OAuth | `TokenStorage` sync/non-throwing, `clear()` reason-less; Keychain write failure after rotation (R) | App-owned envelope, throwing store, write-before-use, `credentialsNotPersisted` (§4.3) |
| 16 | Transport | GET stream 401/404 invisible to authorizer/host; HTTP errors untyped; no `Retry-After` (R) | Fork patches or own transport (§6.0), typed errors (§6.7) |
| 17 | Transport | Normal SSE closure ≠ session expiry; GET 405 is valid (R) | Distinct handling cases (§6.1) |
| 18 | Transport | Idle SSE vs URLSession timeouts; ping doesn't test the GET stream (R) | Per-phase timeouts; no timeout on stream; stream-liveness events (§6.1) |
| 19 | Transport | Redirects can leak credentials (custom headers, token bodies); SDK can't install redirect delegate (R) | Redirect-refusing delegate on every request type (§10.5) |
| 20 | Transport | SDK lacks legacy HTTP+SSE | v1 non-goal, clear message (§6.1) |
| 21 | Lifecycle | No reconnect; sleep/wake; stale async completions tear down replacement connections (R) | Backoff, `NWPathMonitor`, **connection generations** (§6.1, §6.6) |
| 22 | Lifecycle | `connectWithDeadline` assumes a pid; `needsRelaunch` compares only stdio fields | Transport-agnostic `Connection`; kind-aware relaunch comparison (§6.1) |
| 23 | Host | `applyConfigChange` treats ids missing from the pushed list as removed → mixed-kind list must always be merged | One merged push path (§9.1) |
| 24 | Status | "Latest report wins" status; vanished entries never removed (R) | `(sessionID, instanceID)` keyed status + global auth state (§6.6) |
| 25 | Tools | `listTools` ignores `nextCursor` (truncates `?tools=all`) | Cursor paging with cycle detection (§6.1) |
| 26 | Tools | Unbounded schemas/descriptions/responses/images; `list_changed` storms (R) | Caps, coalescing, atomic replace, overflow errors — Phase 1 (§6.1) |
| 27 | Tool calls | Replay after reconnect could duplicate side effects; "retryable" wording invites it (R) | `outcomeUnknown`, never auto-replay, typed failure kind (§6.7) |
| 28 | Security | Third-party egress, prompt injection from results, tool redefinition | Gating, forced open-world, fingerprint re-scope, consent text (§10) |
| 29 | Security | Cookie/credential bleed between instances | Ephemeral session per connection, no cookie store (§6.1) |
| 30 | Security | SDK private-IP check literal-only, DNS rebinding not prevented (R) | Don't claim SSRF protection; [OPEN-9] (§10.3) |
| 31 | UX | Browser SSO silently reuses first account; label isn't verified identity (R) | Copy link, browser picker, `prompt=`, verified identity vs label (§7.4, §7.5) |
| 32 | UX | OAuth interrupted → hung "signing in" | 5-min timeout, Cancel, exactly-once completion (§6.3) |
| 33 | UX | Editor "two-phase commit" is not transactional; config write is async-enqueued (R) | Staged commit with durable `flush()` result (§5.6) |
| 34 | UX | Settle window (5 s) misses slow remotes | Auth/reconnect states count as settled; late tools re-scope (existing) (§6.6) |
| 35 | Atlassian | v2 default endpoint hides operations behind `executeRead/Write/Destructive`; per-tool toggles meaningless (R) | Flat-list preset default; executor args shown to Security Agent (§7.6) |
| 36 | Atlassian | API-token auth needs admin enablement; IP allow-list causes post-login 403; v1→v2 cached client ids; multi-site OAuth unproven (R) | Per-status messages, "clear registration" action, live acceptance test (§7.6, §11.5) |
| 37 | Engineering | Repo guards (view-body ratchets, closed enums, no prose matching) | Small subviews; typed states; reuse `.mcpStatus` kind |
| 38 | Dependency | swift-sdk OAuth young; fork/own-implementation maintenance | Pin; retained contract suite on every bump (§11.3) |

## 14. Open decisions for Drew
1. **[OPEN-1]** Separate `mcp_remote_servers.json` (recommended) vs one unified file.
2. **[OPEN-2]** Manual ordering of servers?
3. **[OPEN-3]** Tool-prefix change after first save: block (recommended for v1) or implement policy-key rewrite via the single `TaskStore` writer.
4. **[OPEN-4/8]** Identity auto-label (`atlassianUserInfo`) and `prompt=login` support — settled by the Phase-0 spike.
5. **[OPEN-5]** Legacy HTTP+SSE transport: skip (recommended) or implement later.
6. **[OPEN-6]** Host a Client-ID-Metadata-Document / pre-register a public client with Atlassian? Needs a public HTTPS URL owned by the project.
7. **[OPEN-7]** Catalog contents beyond Atlassian.
8. **[OPEN-9]** DNS-aware private-network check for OAuth endpoints; allow private-network authorization servers?
9. **[OPEN-10]** SDK strategy: patched fork (A) vs own transport/authorizer (B) — decided by the Phase-0 go/no-go, but Drew may prefer one in advance (fork maintenance vs. owning security-critical code).
10. **[OPEN-11]** Per-task "only this instance" restriction in v1?
11. **[OPEN-12]** Atlassian default preset: flat list (`?tools=all`, recommended) vs compact discover/execute.
12. Shared vs per-session connections (plan keeps per-session; revisit if e.g. 10 sessions × 5 remotes = 50 connections/streams hurts).

## 15. Implementation checklist (file-level)
New: `MCP/RemoteMCPServerConfig.swift`, `MCP/MCPServerDefinition.swift`, `MCP/RemoteMCPCredentialOwner.swift`, `MCP/RemoteMCPCredentialStore.swift` (envelope + static record, throwing), `MCP/RemoteMCPAuthorizer.swift`, `MCP/RemoteMCPTransportFactory.swift` (+ own transport if option B), `MCP/OAuthLoopbackReceiver.swift`, `MCP/RemoteMCPURLValidator.swift`, `MCP/ReconnectPolicy.swift`, `MCP/MCPToolNameTable.swift`, `MCP/ToolFailureKind.swift`; app: `Views/RemoteMCPServerEditorSheet.swift`, `Views/RemoteMCPSignInSheet.swift`, `MCPServerRow` split into its own file.
Changed: `MCPClientHost.swift` (Connection, generations, performConnect/teardown/needsRelaunch/paging/limits/reconnect, name table over all advertised tools), `MCPServerStatus` (+states, typed errors, table), `MCPSecretStore.swift` (unchanged semantics; new store sits beside it), `MCPBridgedTool.swift` (instance label, effective open-world, identity token), `MCPConfigImport.swift` (url entries), `AgentTool.swift` (`ToolExecutionResult.failureKind`, additive), `PersistenceManager.swift` (remote file + stdio loader hardening), `SharedAppState.swift` (remote list, merged push, status keying, credential owner), `AppViewModel.swift` (announce on new states, host creation), `MCPServerManagementView.swift`, `SecurityEvaluator.swift` (group id/description, effective flags), `ToolsSettingsView.swift`/`TaskToolOverrideEditor.swift` (consume name table, labels), `OrchestrationRuntime.swift` (`waitUntilSettled` semantics only), `Package.swift` (SDK fork/pin if option A), tests, `ROADMAP.md`, `CLAUDE.md` MCP notes.

## 16. External review log (Codex) and disposition
- **Reviewer:** OpenAI Codex CLI `codex-cli 0.162.0`, non-interactive: `codex exec -s read-only -C <repo> --skip-git-repo-check -o codex_review_output.md "<prompt>" < /dev/null` (stdin closed; read-only sandbox, so it could inspect the repo and the SDK checkout but modify nothing). It reviewed the complete first draft (`draft_v1_sent_to_codex.md`, 64 KB) on 2026-10-13 and returned 34 numbered findings plus a "top 5" list. Full raw output: `codex_review_output.md`; invocation log: `codex_review_log.txt`; both kept in the task evidence folder (`~/Library/Application Support/AgentSmith/sessions/8701B623-C74A-4968-9BDE-DFB156C9E142/tasks/74F2387F-61BA-47B1-84D1-A3AFE8E55B85/evidence/`).
- **Re-check method:** each finding was checked against this checkout and the swift-sdk 0.12.1 source (and, for Atlassian, the current public docs) before incorporation. **All factual-error findings that I re-verified were correct**; none were rejected. Verified directly: seeded `client_id` does not skip registration (`OAuthAuthorizer.maybeRegisterClient` checks case only; `OAuthClientRegistrar.register`); internal-only OAuth collaborators; GET path never calls `handleChallenge`/clears the session id; `disconnect()` invalidates the URLSession; internal `URLSession` initializer; unregistered server requests get `methodNotFound`; issuer fallback + lowercase compare; refresh 4xx → `false`; `groupID = "mcp__\(serverName)"` and `flag(mcp.openWorldHint)` in `SecurityEvaluator`; `ToolExecutionResult` is `{output, succeeded}`; `SharedAppState.reportMCPStatuses` merge semantics; `refreshTools` publishing `.connected` on failure; `SerialPersistenceWriter.flush()` durability result; the Atlassian supported-tools page (primary tools + `discover`/`execute*`, `?tools=all`, JSM OAuth+API token, `atlassianUserInfo`). Not independently re-derivable (kept as stated, flagged for the spike): provider-side behavior such as Atlassian redirect-URI rules.
- **Material changes made because of the review (finding # → plan section):**
  1. #1, #2, #24 → new **§6.0 SDK go/no-go** (fork vs own transport/authorizer vs unmodified SDK, the latter rejected) and §2.7 rewritten; Phase 0 now ends in a decision with retained contract tests (§11.3).
  2. #3, #28, #31 → GET-stream/auth/session semantics, per-phase timeouts, fresh transport on reconnect, normal-closure vs session-expiry vs GET-405 distinctions (§6.1, §6.6).
  3. #4, #6 → corrected SDK/host failure semantics (§2.3, §2.7).
  4. #5 → removed the claim that rejection handlers must be built (§2.7 #11, §6.1).
  5. #7 → corrected Security Agent group claims; UUID-based group id; effective open-world at construction (§7.3).
  6. #8 → editor no longer cited as transactional; staged commit with durable flush (§2.5, §5.6).
  7. #9, #10, #17, #18, #19 → credential **owner** with per-instance serialized operations, epochs/generations, stale-401 rule, explicit lifecycle ops, app-owned credential envelope, two-item Keychain layout with throwing store and write-before-use (§4.3, §6.5).
  8. #11, #23 → identity token includes endpoint/issuer/principal epoch, approval reset, label vs verified identity, duplicate clears everything (§7.1, §7.5).
  9. #12, #13 → token-binding checks before sending any token, strict issuer equality, redirect-refusing delegate on every request type (§6.3, §10.5).
  10. #14 → connection generations in the host (§6.1).
  11. #15 → single authoritative tool-name table over all advertised tools consumed by host/UIs/Security Agent (§7.2).
  12. #16 → caps, coalescing, atomic replace moved into Phase 1 (§6.1, §12).
  13. #20 → load-time validation, duplicate-UUID trap, unknown-field preservation, backup-failure-blocks-write, read-only recovery for corrupt stdio file (§9.2).
  14. #21 → `(sessionID, instanceID)` status keying, global auth state; softened the shared-connection assertion (§3, §6.6).
  15. #22, #30 → listener binds first, OS-assigned port per RFC 8252, preferred port best-effort, hardened receiver rules; pinned-port requirement **withdrawn** (§6.3).
  16. #25 → typed failure path with `ToolFailureKind`, "outcome unknown" instead of "retryable" (§6.7).
  17. #26 → sign-out/delete/save/shutdown ordering section (§5.6).
  18. #27 → offline fixture tests made mandatory using a `URLProtocol` mock network (the SDK's loopback-HTTP flag is package-scoped), plus the deterministic race tests Codex listed (§11).
  19. #29 → honest description of per-server Auto/On/Off; `newToolsDefault`; per-task restriction as [OPEN-11] (§7.3).
  20. #32, #33 → Atlassian v2 executor model, flat-list default preset, identity tool, JSM auth correction, multi-site claim downgraded to an acceptance test (§7.6).
  21. #34 → narrowed SSRF and billing claims (§10.2, §10.3).
- **Partially adopted:** #17's "do not let the first session own auth" adopted as-is; #21's "shared connections are possible" adopted by rewording only (architecture decision unchanged: per-session for v1). Codex's "top 5" are all reflected: §6.0/§6.5/§7.2/§7.3/§7.5/§6.7/§11.
- Codex's output ended with a stray line "[X7 SYSTEM ACTIVE]" that is not part of the review content and was ignored.

