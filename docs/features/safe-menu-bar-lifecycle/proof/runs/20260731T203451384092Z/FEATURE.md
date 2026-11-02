# Safe menu-bar Stop and Quit lifecycle

## Summary
Make the menu-bar widget accurately expose the Travel Mode lifecycle and ensure explicit Stop and Quit complete verified restoration before the app reports Off or terminates.

## Desired Behavior
- The header and status-item icon visibly distinguish Off, Preparing, Active, Restoring, and Cleanup Required, including while the popover is hidden.
- The active-session action is labeled `Stop & Restore`. It enters Restoring, disables conflicting controls, waits for the structured cleanup result, and reports Off only after verified success.
- If cleanup fails or administrator authorization is cancelled, the app remains running in Cleanup Required, shows a user-safe reason, keeps Start disabled, and offers Retry Cleanup.
- Quit while Active or while a recovery journal exists performs Stop & Restore and terminates only after verified success.
- Quit while Preparing records termination intent, defers termination, cancels cancellable activation work, and runs transactional compensation for any uncertain app mutation or helper lease. It exits only from clean Off; failed compensation cancels termination and shows Cleanup Required.
- Quit while cleanly Off performs no power or Wi-Fi mutation and terminates immediately.
- OS termination requests remain deferred while in-app cleanup is running. Unexpected process death is handled by the privileged lease feature.
- Startup recovery is visible and Start remains unavailable until recovery succeeds.
- Dismissing the transient popover only hides the controls; it does not stop an active session. The status-item icon continues to communicate Active state.
- Settings are editable only in clean Off. Status and errors never expose hotspot passwords or raw privileged scripts.
- The popover presents one lifecycle-specific task at a time: setup and readiness while Off, protected-session status while Active, focused activity during transitions, and recovery guidance when cleanup is required.
- The primary lifecycle action spans the available action area, while Refresh Status and Quit remain visually secondary.

## Lifecycle-Specific Surface

- Off is the only state that renders hotspot configuration controls. It groups fallback-network setup separately from a concise readiness checklist for the saved hotspot, credential, Codex process, Wi-Fi device, location permission, and target visibility.
- Active removes configuration controls instead of showing a disabled form. It renders a compact protected-session summary that names the fallback hotspot, current Wi-Fi state, Codex state, and the fact that the pre-session power and Wi-Fi settings will be restored by Stop or Quit.
- Preparing, Restoring, and startup Recovery remove configuration controls and render a native indeterminate progress indicator with state-specific explanation. They do not invent step completion or percentage progress that the application does not actually know.
- Cleanup Required removes configuration controls and leads with a visually distinct recovery callout, the bounded safe error message, and the appropriate Retry action. It explains that the app stays open until restoration succeeds.
- Every lifecycle state keeps its text heading and primary action accessible without relying on symbol shape or color alone. Readiness rows pair their status symbol with an explicit textual value.
- State changes may use a short opacity transition, but reduced-motion preference disables that transition. No continuous decorative animation runs while the popover is hidden.
- The interface uses native SwiftUI controls, system semantic colors, and SF Symbols. It introduces no third-party UI runtime.

## Deterministic Lifecycle Presentation

The UI derives presentation from the structured session lifecycle plus explicit startup-recovery and pending-Quit state. `isRunning` is not a presentation oracle.

| Presentation | Header | Primary action | Popover surface | Status-item accessibility label | Symbol and tint |
| --- | --- | --- | --- | --- | --- |
| Off | `Travel Mode Off` | `Start`, enabled only when `canStart` | Editable setup and readiness | `Codex Travel Mode: Off` | `wifi.router`, secondary |
| Preparing | `Preparing Travel Mode` | `Preparing…`, disabled | Focused activity | `Codex Travel Mode: Preparing` | `hourglass`, orange |
| Active | `Travel Mode On` | `Stop & Restore`, enabled | Protected-session summary | `Codex Travel Mode: Active` | `wifi.router.fill`, green |
| Restoring | `Restoring Travel Mode` | `Restoring…`, disabled | Focused activity | `Codex Travel Mode: Restoring` | `arrow.triangle.2.circlepath`, orange |
| Startup Recovery | `Recovering Travel Mode` | `Recovering…`, disabled | Focused activity | `Codex Travel Mode: Recovering` | `arrow.triangle.2.circlepath`, orange |
| Cleanup Required after Stop/recovery | `Cleanup Required` | `Retry Cleanup`, enabled when no cleanup call is in flight | Recovery guidance | `Codex Travel Mode: Cleanup Required` | `exclamationmark.triangle.fill`, red |
| Cleanup Required after Quit | `Cleanup Required` | `Retry Cleanup & Quit`, enabled when no cleanup call is in flight | Recovery guidance | `Codex Travel Mode: Cleanup Required` | `exclamationmark.triangle.fill`, red |

Cleanup Required and transition lifecycle text take precedence over stale connectivity success. User-visible error text is a bounded product message and never raw provider output, a command line, or a privileged script.

## Termination And Action Ownership

- Clean Off means the lifecycle is known to be Off, no activation/save/cleanup/recovery task is in flight, and no unresolved durable journal exists. Only this state may return terminate-now without invoking cleanup.
- The first termination callback outside clean Off records pending Quit intent, returns terminate-later, and owns one cleanup task. Further termination, Stop, or Retry requests while that task is running coalesce with it and do not dispatch another cleanup.
- AppKit may coalesce a repeated external termination request before delivering another delegate callback. Every callback AppKit does deliver while Preparing, Restoring, startup recovery, or cleanup is pending returns terminate-later. A callback delivered after pending-Quit Cleanup Required returns cancel. Neither case returns terminate-now, dispatches a second cleanup, or permits early exit.
- Verified Off authorizes termination. Cleanup Required cancels the current AppKit termination reply and keeps the pending Quit intent visible. `Retry Cleanup & Quit` starts one new cleanup attempt and terminates only after that attempt verifies Off.
- A Stop-originated cleanup failure does not create Quit intent. `Retry Cleanup` reaching Off leaves the app running.
- Quit during startup recovery joins or follows the owned recovery cleanup and exits only from verified Off. Failure remains Cleanup Required with pending Quit intent.
- Repeated Stop, Retry, and Quit actions are disabled or coalesced while cleanup is in flight.

## Authorization Cancellation

- Cancelling the informational pre-Start prompt makes zero system calls and leaves clean Off.
- A definitive administrator denial before any durable session ownership or dispatched mutation leaves Off with a safe Start failure.
- Cancellation or failure after a journal, helper lease, or mutation may be owned or uncertain and must run compensation. If compensation cannot be verified, the result is Cleanup Required.
- Cancelling administrator authorization during cleanup is a cleanup failure: the app stays alive and exposes Retry Cleanup or Retry Cleanup & Quit.

## Scope
- Menu-bar presentation, user actions, termination coordination, lifecycle visibility, and cleanup retry UX.

## Non-Goals
- Owning power commands, the privileged helper, the durable journal, or network policy.
- Providing an in-app bypass that force-quits without cleanup.
- Treating ordinary click-away popover dismissal as Stop.

## Scenarios
- Stop succeeds: Restoring is visible, then the app becomes Off and Start is enabled.
- Stop fails: the UI never says Stopped or Off; Retry Cleanup remains available.
- Quit while Active: termination waits for cleanup and proceeds only after success.
- Quit while Preparing: the app remains alive while activation is cancelled or compensated, then exits only after verified Off.
- Quit while Preparing after the helper lease exists and compensation fails: termination is cancelled, the production activation task settles, Cleanup Required remains visible, and the process stays alive.
- Quit while cleanly Off: no system command is made.
- The user clicks outside the transient popover while Active: the popover hides, the session remains Active, and the status icon reflects it.
- The app launches with an interrupted session: recovery state is visible and Start is blocked.
- Quit during startup recovery: the owned recovery is reused; success exits from verified Off, while failure cancels termination and keeps Cleanup Required alive with pending Quit intent.

## External Contract
- UI consumes the session lifecycle and structured cleanup result; it does not infer success from command dispatch.
- Termination coordination returns terminate-now only from clean Off, terminate-later while Preparing or cleanup is being cancelled/compensated, and cancel when compensation reaches Cleanup Required.
- The status item has distinct accessible labels for each lifecycle state.
- A failed Quit keeps pending termination intent as product state; it is not inferred from a stale AppDelegate Boolean.

## Resolution Rules
- Popover dismissal means hide. Explicit `Stop & Restore` and Quit mean restore.
- Cleanup Required takes precedence over stale success text or previous connectivity status.
- Start is available only from clean Off with valid saved configuration.
- Preparing, Restoring, startup Recovery, and Cleanup Required always win over stale `isRunning`, network, or previous success text.
- A second external termination request joins the first request whether AppKit delivers or coalesces its delegate callback; it never bypasses restoration.

## Constraints
- UI code must not call `pmset`, Wi-Fi commands, or privileged scripts directly.
- Do not terminate after a failed in-app cleanup request.
- Do not terminate merely because an in-flight Start task was cancelled; reconcile its durable intent and helper status first.
- Do not hide Cleanup Required behind a generic stopped state.
- Proof-only providers and scenario selectors must not be reachable from the shipped app binary or release bundle.
- Do not show editable or disabled hotspot configuration controls outside clean Off; lifecycle summaries must use committed, non-secret state only.

## Ambiguity Check
- Selected: closing or quitting the app restores; transient click-away dismissal only hides the menu so background Travel Mode remains usable.
- Rejected: every popover dismissal turns Travel Mode Off.
- Tradeoff: Active state must remain obvious in the menu-bar icon while the popover is hidden.

## Implementation Routing
- Required skills: coding-ui-improvement, coding-feature-execute, coding-proof-author
