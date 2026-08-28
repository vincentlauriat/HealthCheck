# Companion Training Plan Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Companion training plan available offline and allow local done/not-done marking of planned sessions.

**Architecture:** `CompanionViewModel` owns persistence and state mutations. `CompanionRootView` renders a more task-oriented SwiftUI screen and delegates toggles to the view model. The shared training plan exchange model remains compatible and unchanged for this iteration.

**Tech Stack:** Swift, SwiftUI, Foundation, XCTest, Xcode build system.

## Global Constraints

- Scope is limited to the Companion app and Companion tests.
- Completion marks are local to the iPhone and are not sent back to the Mac.
- The Mac remains the source of truth for generating the training plan.
- Refresh failures must not erase an existing cached plan.
- Unpairing clears the cached plan and completion marks.

---

### Task 1: Persist Cached Plan And Completion Marks

**Files:**
- Modify: `HealthCheck/Companion/CompanionViewModel.swift`
- Test: `HealthCheck/CompanionTests/CompanionViewModelTests.swift`

**Interfaces:**
- Produces: `func trainingSessionID(week: TrainingWeekSummary, session: TrainingSessionSummary, index: Int) -> String`
- Produces: `func isTrainingSessionCompleted(id: String) -> Bool`
- Produces: `func toggleTrainingSessionCompleted(id: String)`

- [ ] **Step 1: Write failing tests**

Add tests that save a plan, relaunch the view model with the same `UserDefaults`, verify the plan is restored, verify unreachable refresh preserves it, verify toggle persists across relaunch, and verify `unpair()` clears both plan and completion marks.

- [ ] **Step 2: Implement persistence**

Store the latest successful `TrainingPlanResponse` as encoded `Data` in `UserDefaults`. Store completion ids as `[String]`. Decode cache at initialization and ignore corrupt cache.

- [ ] **Step 3: Run Companion view model tests**

Run the focused Companion view model tests and fix compile or logic issues.

### Task 2: Redesign Companion Training UI

**Files:**
- Modify: `HealthCheck/Companion/CompanionRootView.swift`

**Interfaces:**
- Consumes: `CompanionViewModel.trainingPlan`
- Consumes: `CompanionViewModel.trainingSessionID(week:session:index:)`
- Consumes: `CompanionViewModel.isTrainingSessionCompleted(id:)`
- Consumes: `CompanionViewModel.toggleTrainingSessionCompleted(id:)`

- [ ] **Step 1: Replace raw form layout for paired state**

Use a scroll-based layout with compact status, goal summary, this-week sessions, upcoming weeks, and unpair action.

- [ ] **Step 2: Add session completion controls**

Render each planned session with a button using `checkmark.circle.fill` / `circle`, toggling local completion. Dim completed session details without hiding them.

- [ ] **Step 3: Keep pairing screen functional**

Keep code entry and pair action, with clearer visual grouping and no unrelated protocol changes.

### Task 3: Verify Build And Diagnostics

**Files:**
- Verify: `HealthCheck/Companion/CompanionViewModel.swift`
- Verify: `HealthCheck/Companion/CompanionRootView.swift`

**Interfaces:**
- Consumes all code from tasks 1 and 2.

- [ ] **Step 1: Refresh Xcode diagnostics for changed files**

Use `XcodeRefreshCodeIssuesInFile` on the changed Swift files.

- [ ] **Step 2: Build project**

Use `BuildProject` with tests if practical. Report any build blocker with exact diagnostics.
