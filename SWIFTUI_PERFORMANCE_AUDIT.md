# SwiftUI Performance Audit - macos-agent-smith

## Audit Target
Main transcript views in macos-agent-smith: ChannelLogView and all subviews/data that feed it.

## SwiftUI Best Practices Applied

### Official Apple Sources (3+ required)

1. **Apple Developer Documentation: Understanding and improving SwiftUI performance**
   - URL: https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance
   - Key practices:
     - Keep view bodies fast and rely on limited dependencies
     - Move business logic and non-UI work out of views to model types
     - SwiftUI recreates views and recalculates view bodies frequently

2. **Apple WWDC25: Optimize SwiftUI performance with Instruments (Session 306)**
   - URL: https://developer.apple.com/videos/play/wwdc2025/306/
   - Key practices:
     - View bodies run on the main thread; delays cause hitches
     - Avoid heavy computation in computed properties accessed during view body evaluation
     - Cache results and reuse formatters instead of recreating them each time
     - Design granular data flow to update views only when necessary
     - Use per-view models to ensure only specific views update when their data changes

3. **Apple Developer Documentation: Performance analysis**
   - URL: https://developer.apple.com/documentation/swiftui/performance-analysis
   - Key practices:
     - Use Instruments to detect hangs and hitches
     - Analyze long view body updates and frequent SwiftUI updates

4. **Apple Developer Documentation: Improving your app's rendering efficiency**
   - URL: https://developer.apple.com/documentation/xcode/improving-your-app-s-rendering-efficiency/
   - Key practices:
     - Profile with SwiftUI instrument to identify long-running view body updates
     - Reorganize views to avoid frequent updates
     - Limit frame rate and duration of animations

### Additional High-Quality Sources

5. **Medium: Optimizing SwiftUI Performance: Best Practices**
   - URL: https://medium.com/@garejakirit/optimizing-swiftui-performance-best-practices-93b9cc91c623
   - Key practices:
     - Minimize view body computation - extract reusable subviews
     - Use @StateObject over @ObservedObject when instantiating within a view
     - Avoid deep view nesting; flatten hierarchies

6. **Medium: Optimizing SwiftUI: Reducing Body Recalculation**
   - URL: https://medium.com/@wesleymatlock/optimizing-swiftui-reducing-body-recalculation-and-minimizing-state-updates-8f7944253725
   - Key practices:
     - Avoid heavy computations in body property
     - Use @ObservationIgnored on containers of view models
     - Use stable unique identifiers in ForEach
     - Use .onChange to react to state changes rather than including side effects in body

7. **Swiftyn: Optimizing SwiftUI View Render Performance**
   - URL: https://www.swiftyn.com/articles/optimizing-swiftui-view-render-performance
   - Key practices:
     - Move heavy logic out of body into ViewModel or @StateObject
     - Use _onChange(of:perform:) or task(id:priority:_:) for async work
     - Break state into smaller focused pieces
     - Use @StateObject for objects tied to view lifecycle

8. **Dev.to: SwiftUI Performance and Stability: Avoiding the Most Costly Mistakes**
   - URL: https://dev.to/arshtechpro/swiftui-performance-and-stability-avoiding-the-most-costly-mistakes-234c
   - Key practices:
     - Don't use @State with reference types (use @StateObject)
     - Don't place heavy computations in computed properties within view body
     - Use identity-based iteration (ForEach(items)) over index-based (ForEach(tasks.indices))
     - Initialize formatters in init() and store in properties

---

## Violations Found

### Critical Violations

**C1: ChannelLogView - ChannelGroupingIndex rebuilt on every body pass**
- File: `AgentSmith/AgentSmith/Views/ChannelLogView.swift`
- Line: 265
- Description: `ChannelGroupingIndex` struct is instantiated fresh from `visibleMessages` on every body pass. While the comment explains this is O(window) and better than the previous O(n²) approach, this still creates new dictionary instances on every render. Should be cached in @State and updated via .onChange.

**C2: ChannelLogView - visibleMessages array created on every body pass**
- File: `AgentSmith/AgentSmith/Views/ChannelLogView.swift`
- Line: 260
- Description: `let visibleMessages = windowStart == 0 ? messages : Array(messages[windowStart...])` creates a new array copy on every body evaluation. For large windows (up to 3000 rows), this is expensive.

**C3: ChannelTimestamp - let binding inside body**
- File: `AgentSmith/AgentSmith/Views/ChannelLogView.swift`
- Line: 99-106
- Description: `let _isVisible: Bool = { ... }()` closure executed on every body pass. While small, this is unnecessary - should be a computed property or direct switch expression.

### High Severity Violations

**H1: ChannelLogView - windowStartIndex() called on every body pass**
- File: `AgentSmith/AgentSmith/Views/ChannelLogView.swift`
- Line: 259
- Description: `windowStartIndex()` method called on every body evaluation. Should cache result in @State and update via .onChange when messages or maxVisibleCount changes.

**H2: MainViewDetailColumn - TimestampPreferences created on every body pass**
- File: `AgentSmith/AgentSmith/Views/Main/MainViewDetailColumn.swift`
- Line: 54-61
- Description: New `TimestampPreferences` instance created inline for ChannelLogView on every body pass. Should be cached.

### Medium Severity Violations

**M1: ChannelLogView - Multiple let bindings in body that could be cached**
- File: `AgentSmith/AgentSmith/Views/ChannelLogView.swift`
- Line: 259-265
- Description: Multiple computed values (windowStart, visibleMessages, index) are derived on every body pass.

---

## Fixes Applied

| Issue ID | Problem | Fix | Commit Hash |
|----------|---------|-----|-------------|
| - | - | - | - |

---

## Files Analyzed

### Core Transcript Views
1. `AgentSmith/AgentSmith/Views/ChannelLogView.swift` (1642 lines)
2. `AgentSmith/AgentSmith/Views/Main/MainViewDetailColumn.swift` (128 lines)
3. `AgentSmith/AgentSmith/Views/MainView.swift` (380 lines)

### ChannelLog Subviews (in ChannelLog folder)
4. `AgentSmith/AgentSmith/Views/ChannelLog/MessageRowSenderHeader.swift`
5. `AgentSmith/AgentSmith/Views/ChannelLog/ChannelLogRestoreHistoryButton.swift`
6. `AgentSmith/AgentSmith/Views/ChannelLog/ChannelLogLoadEarlierButton.swift`
7. `AgentSmith/AgentSmith/Views/ChannelLog/MessageRowCopyOverlay.swift`
8. `AgentSmith/AgentSmith/Views/ChannelLog/ChannelLogScrollToBottomButton.swift`

### Related Banner Views
9. `AgentSmith/AgentSmith/Views/Banners/ChannelBanners.swift`

## Notes

- No `var xxxx: some View` anti-patterns found (all are correctly named `body`)
- Functions returning `-> some View` are used extensively but these are view builder functions, not computed properties - this is acceptable per SwiftUI best practices when used to break up complex bodies
- The main performance issues are around repeated computations in view bodies that should be cached with @State and updated via .onChange
