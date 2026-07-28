# SwiftUI Performance Audit - Task Cost View

**App:** macos-agent-smith  
**Audit Target:** Task Cost view in Agent Smith  
**Date:** 2026-01-XX  
**Project Path:** /Users/andrew/cursor/macos-agent-smith

---

## Section 1: SwiftUI Performance Best Practices Applied

The following best practices and sources guided this audit:

### Apple Official Sources (3+)

1. **Apple Developer - Understanding and Improving SwiftUI Performance**  
   URL: https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance  
   **Key Guidance:** Keep view bodies fast; move business logic out of views; SwiftUI recreates views and recalculates view bodies frequently.

2. **Apple WWDC25 Session 306 - Optimize SwiftUI Performance with Instruments**  
   URL: https://developer.apple.com/videos/play/wwdc2025/306/  
   **Key Guidance:** Keep view bodies fast to meet frame deadlines; avoid expensive computations in bodies; use granular dependencies to avoid unnecessary updates; cache expensive calculations.

3. **Apple Developer - State**  
   URL: https://developer.apple.com/documentation/swiftui/state  
   **Key Guidance:** Avoid side effects and performance-intensive work when initializing state; state changes trigger body recalculation.

4. **Apple Developer - Creating Performant Scrollable Stacks**  
   URL: https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks  
   **Key Guidance:** Use lazy stacks for performance when profiling shows benefit; standard stacks calculate geometry for all subviews.

5. **Apple Developer - Reducing Main Thread Work by Doing Less**  
   URL: https://developer.apple.com/tutorials/instruments/reducing-main-thread-work-by-doing-less  
   **Key Guidance:** Use lazy evaluation to only do necessary work; analyze view body getter executions with Instruments.

### Additional Authoritative Sources

6. **Swift Programming - SwiftUI Performance Optimization**  
   URL: https://swiftprogramming.com/swiftui-performance-optimization/  
   **Key Guidance:** Avoid expensive operations (filtering, sorting) in body; use View Decomposition to extract subviews; use stable identifiers in ForEach.

7. **Dev.to - SwiftUI Performance Optimization: Smooth UIs, Less Recomputing**  
   URL: https://dev.to/sebastienlato/swiftui-performance-optimization-smooth-uis-less-recomputing-422k  
   **Key Guidance:** Store processed results in @State instead of computing in body; use .onChange to update cached state; break up heavy views into smaller subviews.

8. **Avanderlee - @Observable Macro Performance Increase**  
   URL: https://www.avanderlee.com/swiftui/observable-macro-performance-increase-observableobject/  
   **Key Guidance:** @Observable prevents unnecessary redraws compared to ObservableObject; views only redraw for properties actually used.

---

## Section 2: Violations Found

### Category C: Computed Properties in View Bodies

| ID | Severity | File | Line | Description |
|----|----------|------|------|-------------|
| C1 | Medium | TaskCostDetailSheet.swift | 44-46 | `summary` computed property called 6+ times in body; each call invokes `aggregator.summarize()` which processes all records |
| C2 | Low | TaskCostDetailSheet.swift | 227 | `contextResets` computed inline in efficiencySection body via `records.filter()` |
| C3 | Low | TaskCostDetailSheet.swift | 374-376 | `sorted` and `displayedTurns` computed in turnTimelineSection body via `records.sorted()` and `Array(suffix())` |
| C4 | Low | TaskCostDetailSheet.swift | 490-495 | `toolFrequency(records)` called in toolUsageSection body, iterates all records |

### Category H: Helper Functions Returning `-> some View` (Should be View Structs)

| ID | Severity | File | Line | Description |
|----|----------|------|------|-------------|
| H1 | Low | TaskCostDetailSheet.swift | 100-162 | `headerSection() -> some View` - large view-building function, should be extracted to `HeaderSection: View` struct |
| H2 | Low | TaskCostDetailSheet.swift | 168-211 | `costBreakdownSection() -> some View` - should be `CostBreakdownSection: View` struct |
| H3 | Low | TaskCostDetailSheet.swift | 217-233 | `efficiencySection() -> some View` - should be `EfficiencySection: View` struct |
| H4 | Low | TaskCostDetailSheet.swift | 239-271 | `toolUsageSection() -> some View` - should be `ToolUsageSection: View` struct |
| H5 | Low | TaskCostDetailSheet.swift | 323-366 | `configurationSection() -> some View` - should be `ConfigurationSection: View` struct |
| H6 | Low | TaskCostDetailSheet.swift | 372-412 | `turnTimelineSection() -> some View` - should be `TurnTimelineSection: View` struct |
| H7 | Low | TaskCostDetailSheet.swift | 423-443 | `turnDisclosureControls(totalTurns:shownTurns:) -> some View` - should be `TurnDisclosureControls: View` struct |
| H8 | Low | TaskCostDetailSheet.swift | 457-462 | `headerStat(label:value:color:) -> some View` - should be `HeaderStat: View` struct |
| H9 | Low | TaskCostDetailSheet.swift | 464-469 | `miniStat(label:value:color:) -> some View` - should be `MiniStat: View` struct |
| H10 | Low | TaskCostDetailSheet.swift | 471-479 | `costRow(name:cost:detail:color:) -> some View` - should be `CostRow: View` struct |
| H11 | Low | TaskCostDetailSheet.swift | 481-488 | `tokenRow(label:count:cost:) -> some View` - should be `TokenRow: View` struct |
| H12 | Low | TaskCostDetailSheet.swift | 447-455 | `card(title:content:) -> some View` - generic container, borderline case |

### Category M: @State Properties Causing Broad Invalidation

| ID | Severity | File | Line | Description |
|----|----------|------|------|-------------|
| M1 | Low | TaskCostDetailSheet.swift | 42 | `turnDisplayLimit` @State - changing this invalidates entire turnTimelineSection; acceptable because user-driven and limited by incremental buttons |

---

## Section 3: Fixes Applied

### Fix 1: Cache `summary` computed property in @State

**Issue IDs:** C1  
**Problem:** `summary` computed property called 6+ times in body, each invoking `aggregator.summarize()` which processes all records.  
**Fix:** Changed to `@State private var summary: UsageSummary = .empty(scopeLabel: "")` and populate via `.onChange(of: records.count)` when records change.  
**Commit:** a8ea5d907af6f19763834c4a6c129164973cdd50

### Fix 2: Cache `toolCounts` in @State

**Issue IDs:** C4  
**Problem:** `toolFrequency(records)` iterates all records on every body recalculation.  
**Fix:** Changed to `@State private var toolCounts: [(tool: String, count: Int)] = []` and populate via `.onChange(of: records.count)`.  
**Commit:** a8ea5d907af6f19763834c4a6c129164973cdd50

### Fix 3: Cache sorted turns data in @State

**Issue IDs:** C3  
**Problem:** `records.sorted()` and `Array(suffix())` computed on every body recalculation.  
**Fix:** Changed to `@State private var sortedTurns: [UsageRecord] = []` and `@State private var displayedTurns: [UsageRecord] = []`, updated via `.onChange(of: records.count)` and `.onChange(of: turnDisplayLimit)`.  
**Commit:** a8ea5d907af6f19763834c4a6c129164973cdd50

### Fix 4: Cache contextResets count in @State

**Issue IDs:** C2  
**Problem:** `records.filter { $0.preResetInputTokens != nil }.count` computed on every body recalculation.  
**Fix:** Changed to `@State private var contextResetsCount: Int = 0`, updated via `.onChange(of: records.count)`.  
**Commit:** a8ea5d907af6f19763834c4a6c129164973cdd50

### Fix 5-H: Refactor ALL helper functions to View structs (COMPLETE)

**Issue IDs:** H1-H12  
**Problem:** Functions returning `-> some View` are anti-pattern; each call creates new view instance.  
**Fix:** Extracted ALL 12 helper functions to dedicated `struct: View` types:
- H1: headerSection → HeaderSection
- H2: costBreakdownSection → CostBreakdownSection
- H3: efficiencySection → EfficiencySection
- H4: toolUsageSection → ToolUsageSection
- H5: configurationSection → ConfigurationSection
- H6: turnTimelineSection → TurnTimelineSection
- H7: turnDisclosureControls → TurnDisclosureControls
- H8: headerStat → HeaderStat
- H9: miniStat → MiniStat
- H10: costRow → CostRow
- H11: tokenRow → TokenRow
- H12: card → CardView (generic container)  
**Commit:** c9def6c70fdf69eb60bc05bb54ff4d2fab89bbeb

### Fix 6: Restore correct behavior for turn display controls

**Issue IDs:** Behavioral regression from Fix 5-H  
**Problem:** TurnDisclosureControls owned its own @State turnDisplayLimit, disconnecting it from parent; buttons had no effect on displayed turns.  
**Fix:** Changed TurnDisclosureControls to use `@Binding var turnDisplayLimit: Int`, updated TurnTimelineSection to receive `displayedTurnStartOffset` parameter instead of computing it, wired binding from TaskCostDetailSheet.  
**Commit:** 7f1d5ae

### Fix 7: Complete caching - all derived data pre-computed

**Issue IDs:** C5-C9 (body-time computations in child views)  
**Problem:** Child views (CostBreakdownSection, ConfigurationSection, TurnTimelineSection) performed derived computations in body or had computed properties feeding body.  
**Fix:** Moved ALL derived data computation to TaskCostDetailSheet.updateCachedData(): costByAgent, tokenBreakdown, efficiencyMetrics, configRows, turnRows. All child views now receive pre-computed data with zero body-time aggregation. Changed cache trigger to `.onChange(of: records)` for content-change detection. Restored real per-turn cost calculation (was returning 0).  
**Commit:** dda4ac866573848756d7ce761477c9b159826c00

### Fix 8: Eliminate final body-time computations in Task Cost hierarchy

**Issue IDs:** C10-C12 (remaining body-time values)  
**Problem:** HeaderSection had computed properties resolvedTitle/resolvedStatus; ToolUsageSection computed maxCount in body; CostBreakdownSection used ForEach with indices.  
**Fix:** 
- HeaderSection: Now receives resolvedTitle, resolvedStatus, durationText as pre-computed parameters
- ToolUsageSection: Now receives maxCount as pre-computed parameter  
- CostBreakdownSection: Uses TokenBreakdownRow (Identifiable) for stable ForEach iteration instead of indices
**Commit:** e17e68a38aea321a1545efc555313f7c7b03df32

---

## Build Verification

**Build Command:** `xcodebuild -project AgentSmith/AgentSmith.xcodeproj -scheme AgentSmith -destination 'platform=macOS' clean build`  
**Result:** BUILD SUCCEEDED  
**Warnings:** None (project code only; dependency warnings allowed)

---

## Summary

- **Audit Log Path:** /Users/andrew/cursor/macos-agent-smith/TASK_COST_SWIFTUI_AUDIT.md
- **Sources Cited:** 8 total
  - **4 Apple Official Sources:**
    1. https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance
    2. https://developer.apple.com/videos/play/wwdc2025/306/
    3. https://developer.apple.com/documentation/swiftui/state
    4. https://developer.apple.com/documentation/swiftui/creating-performant-scrollable-stacks
  - **4 Authoritative Third-Party Sources:**
    5. https://swiftprogramming.com/swiftui-performance-optimization/
    6. https://dev.to/sebastienlato/swiftui-performance-optimization-smooth-uis-less-recomputing-422k
    7. https://www.avanderlee.com/swiftui/observable-macro-performance-increase-observableobject/
    8. https://www.hackingwithswift.com/books/ios-swiftui/sharing-swiftui-state-with-observable
- **Apple Official Source Count:** 4
- **Issues Fixed:** 25 total
  - 12 computed properties/derived data cached or pre-computed (C1-C12)
  - 12 helper functions extracted to View structs (H1-H12)
  - 1 behavioral regression fixed (TurnDisclosureControls binding)
  - Note: Equatable conformance added to UsageRecord.swift as supporting change
- **Commits Made:** 7 total for this task (on top of base a8ea5d9)
  1. 152ed0d: Update audit log with commit hash and build results
  2. c9def6c70fdf69eb60bc05bb54ff4d2fab89bbeb: Complete extraction of all remaining -> some View helpers
  3. 206acc2: Update audit log with complete fix list and final commit hashes
  4. 7f1d5ae: Fix TurnDisclosureControls binding and TurnTimelineSection parameters
  5. df14b89: Update audit log with all commits and complete source list
  6. dda4ac866573848756d7ce761477c9b159826c00: Complete caching refactor - all derived data pre-computed
  7. e17e68a38aea321a1545efc555313f7c7b03df32: Eliminate final body-time computations (HeaderSection params, ToolUsageSection maxCount, TokenBreakdownRow)
- **Build Status:** BUILD SUCCEEDED (clean build)
- **Remaining Concerns:** NONE
  - Grep verification (TaskCostDetailSheet.swift): No remaining `var ...: some View` except `body` (exit code 1 = none found)
  - Grep verification (TaskCostDetailSheet.swift): No remaining `func ... -> some View` (exit code 1 = none found)
  - File-by-file verification: All Task Cost child views (HeaderSection, CostBreakdownSection, EfficiencySection, ToolUsageSection, ConfigurationSection, TurnTimelineSection, TurnDisclosureControls, CardView, HeaderStat, MiniStat, CostRow, TokenRow) checked - no non-body `var ...: some View` or `func ... -> some View`
  - Behavioral verification: TurnDisclosureControls correctly updates parent turnDisplayLimit via @Binding
  - Behavioral verification: Per-turn costs display real values (computeTurnCost uses aggregator.pricingLookup)
  - Cache invalidation: Uses `.onChange(of: records)` which tracks array identity; parent dashboard provides new array instances when content changes
  - ForEach stability: All ForEach use stable Identifiable or unique key paths (no indices)
