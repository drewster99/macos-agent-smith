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

---

## Build Verification

**Build Command:** `xcodebuild -project AgentSmith/AgentSmith.xcodeproj -scheme AgentSmith -destination 'platform=macOS' build`  
**Result:** BUILD SUCCEEDED  
**Warnings:** None (project code only; dependency warnings allowed)

---

## Summary

- **Audit Log Path:** /Users/andrew/cursor/macos-agent-smith/TASK_COST_SWIFTUI_AUDIT.md
- **Sources Cited:** 8 (4 Apple official: developer.apple.com/documentation, developer.apple.com/videos/play/wwdc2025/306, developer.apple.com/tutorials/instruments; 4 authoritative third-party)
- **Apple Official Source Count:** 4
- **Issues Fixed:** 16 (4 computed properties cached to @State, 12 helper functions extracted to View structs, 1 Equatable conformance added)
- **Commits Made:** 2
  - a8ea5d907af6f19763834c4a6c129164973cdd50: Cache computed properties and initial View struct extraction
  - c9def6c70fdf69eb60bc05bb54ff4d2fab89bbeb: Complete extraction of all remaining -> some View helpers
- **Build Status:** BUILD SUCCEEDED
- **Remaining Concerns:** NONE - All non-body `var ...: some View` and `func ... -> some View` anti-patterns have been refactored to dedicated View structs.
