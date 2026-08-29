# Section Navigation Fluidity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce section-switching stalls by preventing repeated dashboard reloads during navigation.

**Architecture:** Match the existing `hasLoaded` pattern used by section view models. Add one dashboard-level `load()` method and let views call it once, while explicit sync/import refresh paths keep forcing fresh data.

**Tech Stack:** SwiftUI, XCTest, GRDB-backed `HealthStore`.

## Global Constraints

Keep UI unchanged. Do not add dependencies. Keep changes scoped to dashboard loading and refresh call sites.

---

### Task 1: Dashboard Load State

**Files:**
- Modify: `HealthCheck/HealthCheck/ViewModels/DashboardViewModel.swift`
- Modify: `HealthCheck/HealthCheck/Views/DashboardView.swift`
- Modify: `HealthCheck/HealthCheck/Views/ContentView.swift`
- Test: `HealthCheck/HealthCheckTests/DashboardViewModelTests.swift`

**Interfaces:**
- Produces: `DashboardViewModel.hasLoaded: Bool`
- Produces: `DashboardViewModel.load() throws`
- Consumes: existing `loadToday()`, `loadThisWeek()`, and `loadWellness()`

- [ ] **Step 1: Write the failing test**

Add this XCTest case to `DashboardViewModelTests`:

```swift
@MainActor
func test_load_marksDashboardAsLoaded() throws {
    let store = try HealthStore(path: ":memory:")
    let viewModel = DashboardViewModel(
        store: store,
        resolver: SourcePriorityResolver(priority: ["Watch", "iPhone"])
    )

    XCTAssertFalse(viewModel.hasLoaded)
    try viewModel.load()

    XCTAssertTrue(viewModel.hasLoaded)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: dashboard view model tests.
Expected: FAIL because `DashboardViewModel` has no `hasLoaded` or `load()`.

- [ ] **Step 3: Implement minimal code**

Add `@Published private(set) var hasLoaded = false` and:

```swift
func load() throws {
    hasLoaded = true
    try loadToday()
    try loadThisWeek()
    try loadWellness()
}
```

Update `DashboardView`:

```swift
.task { if !viewModel.hasLoaded { try? viewModel.load() } }
```

Update `ContentView` sync/import refresh branches to call `dashboardViewModel.load()` where they currently call all three dashboard loading methods together.

- [ ] **Step 4: Run verification**

Run dashboard tests and refresh Xcode diagnostics for modified Swift files. Build the project if needed.
