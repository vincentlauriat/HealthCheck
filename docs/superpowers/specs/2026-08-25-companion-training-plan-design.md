# Companion Training Plan Offline Design

## Goal

The Companion app must remain useful when the Mac is not reachable. A paired iPhone should keep showing the latest training plan it successfully received, and the user should be able to mark planned sessions as done locally.

## Scope

This change is limited to the Companion app and shared exchange model where needed. Completion marks are local to the iPhone for this iteration. They are not sent back to the Mac, and the Mac remains the source of truth for generating the plan.

## Behavior

- When a training plan is fetched successfully, the Companion stores it locally.
- On launch, if a cached plan exists, the Companion displays it without contacting the Mac.
- If refresh fails because the Mac is unreachable, the cached plan remains visible and the app shows a non-destructive warning.
- Unpairing clears the cached plan and local completion marks.
- Each planned session can be toggled done or not done from the Companion.
- Completion marks survive app relaunches and work offline.
- Completion marks are keyed deterministically from the week date, session position, and session summary content, so no server-side state is required.

## Presentation

The paired Companion screen should prioritize:

- Current connection and sync status in a compact header.
- The active race goal when present.
- This week's sessions as the primary content.
- Other weeks as secondary expandable content.
- Clear visual state for done sessions.

The unpaired screen keeps the pairing workflow but should look less like a raw settings form.

## Data Flow

`CompanionViewModel` loads cached state from `UserDefaults` at initialization. Successful `refreshTrainingPlan()` writes the latest `TrainingPlanResponse` using the shared `ExchangeCoding` encoder. Done-session ids are persisted as an array in `UserDefaults`.

`CompanionRootView` reads `trainingPlan`, derives the current week using the local calendar, and calls a view model toggle method when the user taps a session completion control.

## Error Handling

Cache decoding failures are treated as absent cache. Refresh failures do not erase existing plan data. Unauthorized or unpair operations still clear sensitive pairing state as they do today.

## Tests

Add or update Companion view model tests for:

- Relaunch restores cached training plan.
- Failed refresh preserves cached training plan.
- Unpair clears cached training plan and completion marks.
- Toggling a session completion persists across relaunch.
