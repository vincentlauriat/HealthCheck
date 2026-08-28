# Section Navigation Fluidity Design

## Goal

Make switching between HealthCheck sections feel fluid by avoiding repeated synchronous data reloads during navigation.

## Root Cause

Section view models are retained by `HealthCheckApp`, but their `load` methods are `@MainActor` and perform SQL reads plus aggregation work synchronously. Most sections already guard initial `.task` loads with `hasLoaded`; `DashboardView` does not, so returning to Accueil reruns `loadToday`, `loadThisWeek`, and `loadWellness`.

## Approach

Add dashboard load state matching the existing section pattern. `DashboardView` should only perform its initial load once. Explicit refresh paths after imports, Withings sync, or companion sync keep forcing reloads so new data still appears.

Keep the first patch small: do not redesign the store, do not change the visible UI, and do not move every view model to async in this pass.

## Components

- `DashboardViewModel`: add `hasLoaded` and a `load()` entry point that performs the three dashboard loads and marks the model loaded.
- `DashboardView`: call `load()` only if the dashboard has not loaded yet.
- `ContentView`: use the new dashboard `load()` helper in refresh paths where all dashboard metrics are refreshed together.
- `DashboardViewModelTests`: prove a full load flips `hasLoaded`, so the view can skip repeated reloads.

## Testing

Run the dashboard view model test first and confirm it fails before implementation. After implementation, run the same test and refresh Xcode diagnostics for the touched Swift files. Build the project if diagnostics do not expose issues.
