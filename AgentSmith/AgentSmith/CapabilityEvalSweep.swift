import Foundation
import SwiftLLMKit
import Synchronization

/// Concurrency machinery for the capability sweep: admission scheduling under global and
/// per-provider caps, the provider-scoped billing breaker, per-target transcript buffering,
/// and the memoized per-provider vendor-payload fetch.
///
/// The storage synchronization contract lives here in one sentence so nobody has to
/// reconstruct it from the call sites: every `LLMKitManager` access is `@MainActor`
/// (compiler-enforced), and the sweep touches it at exactly three points — the ADMISSION
/// read that snapshots a target's context, the mid-flight provider FACTORIES (stateless
/// construction, no store state), and the COMPLETION write (`storeProbeResult`, one per
/// target). Workers hold value snapshots between those points, never live kit state, so a
/// lost update is impossible by construction: each target has exactly one owner, and each
/// record file belongs to exactly one target.

/// The sweep's concurrency caps, parsed once from the command line.
///
/// Both defaults apply even when no flag is given: bounded concurrency is the sweep's normal
/// shape, and `--concurrency 1` is the way to ask for the old strictly-sequential behavior.
///
/// `nonisolated`: pure data consulted synchronously inside the scheduler actor, so it must
/// not inherit the app target's default MainActor isolation.
nonisolated struct SweepConcurrencyLimits: Sendable {
    /// Models probed at once across all providers (`--concurrency`, default 10).
    let global: Int
    /// Models probed at once against one provider when no override names it
    /// (`--provider-concurrency prov=N`, default 4). Deliberately below the global cap:
    /// this is the rate-limit control, and the HuggingFace router and OpenRouter multiplex
    /// many upstream vendors behind one key.
    let perProviderDefault: Int
    /// Per-provider overrides by provider ID, e.g. `--provider-concurrency builtin.openrouter=6`.
    let perProviderOverrides: [String: Int]

    static let defaultGlobal = 10
    static let defaultPerProvider = 4

    func limit(forProviderID providerID: String) -> Int {
        min(global, perProviderOverrides[providerID] ?? perProviderDefault)
    }

    /// Parses `--concurrency N` and repeatable `--provider-concurrency prov=N` (comma-separable).
    /// Malformed values are a loud exit, not a silent default — a sweep sized wrong costs money.
    static func fromArguments(_ arguments: [String] = CommandLine.arguments) -> SweepConcurrencyLimits {
        var global = defaultGlobal
        var overrides: [String: Int] = [:]
        var index = 0
        while index < arguments.count {
            defer { index += 1 }
            switch arguments[index] {
            case "--concurrency":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value >= 1 else {
                    print("--concurrency requires a positive integer"); exit(1)
                }
                global = value
                index += 1
            case "--provider-concurrency":
                guard index + 1 < arguments.count else {
                    print("--provider-concurrency requires provider=N"); exit(1)
                }
                for spec in arguments[index + 1].split(separator: ",") {
                    let parts = spec.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2, let value = Int(parts[1]), value >= 1 else {
                        print("--provider-concurrency entry '\(spec)' is not provider=N with N >= 1"); exit(1)
                    }
                    overrides[String(parts[0])] = value
                }
                index += 1
            default:
                break
            }
        }
        return SweepConcurrencyLimits(global: global, perProviderDefault: defaultPerProvider,
                                      perProviderOverrides: overrides)
    }
}

/// Hands out sweep targets in catalog order under the concurrency caps, and owns the
/// provider-scoped billing breaker.
///
/// Admission scans FORWARD for the first target whose provider has a free slot, so one
/// saturated provider never head-of-line-blocks the others; order within a provider is
/// always catalog order. A provider whose account trips the billing breaker has its queued
/// targets counted and dropped — billing is a per-account fact, so re-learning it once per
/// model would spend calls to bury the one message that explains them all.
actor ProbeSweepScheduler {
    struct Admission: Sendable {
        /// Position in the original target list — the stable identity used for the
        /// `[i/total]` stamp and for sorting completed profiles back into catalog order.
        let index: Int
        let target: CapabilityEvalRunner.Target
    }

    /// A point-in-time view for the heartbeat line. "Handled" is derived by the reader as
    /// total − pending − in-flight, so it needs no second counter that could drift.
    struct ProgressSnapshot: Sendable {
        let pendingCount: Int
        let totalInFlight: Int
        let inFlightByProvider: [(providerID: String, count: Int)]
        let billingSkippedTotal: Int
    }

    private var pending: [Admission]
    private let limits: SweepConcurrencyLimits
    private var inFlightByProvider: [String: Int] = [:]
    private var totalInFlight = 0
    private var billingTrippedProviders: Set<String> = []
    private var billingSkippedByProvider: [String: Int] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(targets: [CapabilityEvalRunner.Target], limits: SweepConcurrencyLimits) {
        self.pending = targets.enumerated().map { Admission(index: $0.offset, target: $0.element) }
        self.limits = limits
    }

    /// The next admissible target, suspending while the caps are saturated. `nil` means the
    /// sweep is drained: nothing pending that isn't billing-skipped.
    func next() async -> Admission? {
        while true {
            pruneBillingTripped()
            if pending.isEmpty { return nil }
            if totalInFlight < limits.global,
               let index = pending.firstIndex(where: { hasFreeSlot(providerID: $0.target.providerID) }) {
                let admission = pending.remove(at: index)
                totalInFlight += 1
                inFlightByProvider[admission.target.providerID, default: 0] += 1
                return admission
            }
            // Saturation implies someone is in flight, so a `finish` (or a breaker trip)
            // is guaranteed to come and resume us — this cannot deadlock.
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func finish(providerID: String) {
        totalInFlight -= 1
        inFlightByProvider[providerID, default: 0] -= 1
        resumeWaiters()
    }

    /// Trips the billing breaker for one provider. Returns whether this call was the FIRST
    /// trip (the caller prints the full banner exactly once) and how many queued targets the
    /// trip skipped. In-flight probes against the provider are not cancelled: their calls
    /// fail on their own within seconds, establish nothing, and record nothing — cancellation
    /// machinery would buy nothing but bookkeeping.
    func tripBilling(providerID: String) -> (firstTrip: Bool, skippedCount: Int) {
        let firstTrip = billingTrippedProviders.insert(providerID).inserted
        pruneBillingTripped()
        resumeWaiters()
        return (firstTrip, billingSkippedByProvider[providerID, default: 0])
    }

    /// Providers whose queued targets were dropped by the breaker, with counts, for the
    /// end-of-run summary.
    func billingSkipSummary() -> [(providerID: String, skippedCount: Int)] {
        billingSkippedByProvider.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    func progressSnapshot() -> ProgressSnapshot {
        ProgressSnapshot(
            pendingCount: pending.count,
            totalInFlight: totalInFlight,
            inFlightByProvider: inFlightByProvider.filter { $0.value > 0 }
                .sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
            billingSkippedTotal: billingSkippedByProvider.values.reduce(0, +))
    }

    private func hasFreeSlot(providerID: String) -> Bool {
        inFlightByProvider[providerID, default: 0] < limits.limit(forProviderID: providerID)
    }

    private func pruneBillingTripped() {
        guard !billingTrippedProviders.isEmpty else { return }
        let dropped = pending.filter { billingTrippedProviders.contains($0.target.providerID) }
        guard !dropped.isEmpty else { return }
        for admission in dropped {
            billingSkippedByProvider[admission.target.providerID, default: 0] += 1
        }
        pending.removeAll { billingTrippedProviders.contains($0.target.providerID) }
    }

    private func resumeWaiters() {
        let resumed = waiters
        waiters.removeAll()
        for waiter in resumed { waiter.resume() }
    }
}

/// One target's narrative, buffered so the whole block prints atomically at completion
/// instead of interleaving with other workers' lines. The per-call REQUEST/RESPONSE lines
/// from SwiftLLMKit's logger still interleave — those are per-call and self-identifying;
/// this buffer is for the runner's own narrative, which is only readable as a block.
final class SweepTranscript: Sendable {
    private let lines = Mutex<[String]>([])

    func emit(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    /// Drains and returns everything emitted so far. Called once at completion; also safe
    /// after a deadline abandonment, where it returns whatever the battery got to.
    func drain() -> [String] {
        lines.withLock { buffered in
            let drained = buffered
            buffered = []
            return drained
        }
    }
}

/// Per-provider vendor payload, fetched once per provider and shared by every admission —
/// memoized as a `Task` so concurrent admissions for one provider await a single fetch
/// instead of racing to duplicate it. A FAILED fetch is evicted rather than memoized: the
/// sequential sweep retried the fetch on the provider's next model, and a transient network
/// blip must not strip seeding from a whole provider.
actor DecodedPayloadCache {
    private var fetches: [String: Task<[DecodedModelFacts], Error>] = [:]

    func models(for provider: ModelProvider, apiKey: String?) async throws -> [DecodedModelFacts] {
        if let existing = fetches[provider.id] {
            return try await existing.value
        }
        let fetch = Task { try await ModelFetchService().fetchModelFacts(from: provider, apiKey: apiKey) }
        fetches[provider.id] = fetch
        do {
            return try await fetch.value
        } catch {
            fetches[provider.id] = nil
            throw error
        }
    }
}
