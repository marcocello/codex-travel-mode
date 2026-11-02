# Implementation Notes

## 2026-07-31 lifecycle-specific UI contract and proof revision

The previous UI kept hotspot configuration and a flat status table visible in every lifecycle state, merely disabling the form outside Off. That made Active and Cleanup Required visually noisy and allowed a text-only state swap to satisfy the earlier oracle.

The revised contract preserves all restoration and termination behavior while making the popover surface state-specific: editable setup and readiness in Off, a protected-session summary in Active, focused indeterminate activity during transitions, and recovery guidance in Cleanup Required. The proof now requires mutually exclusive accessibility-identified surfaces and excludes hotspot configuration controls outside Off. External Designer references informed the hierarchy and transition restraint; no external component or dependency was adopted.

The first pre-change run showed that SwiftUI's synthetic accessibility button exposes a zero frame even though the production control is visible and accepts the native press action. The invalid numeric frame threshold was removed before product implementation. The product requirement remains full-width; the executable oracle verifies the native accessible button and the parent inspects the retained native screenshots for its geometry.

## 2026-07-17 contract and proof repair

Quality review found that the original proof accepted producer-authored `verdict: PASS` and aggregate booleans, omitted Off and Restoring screenshots, had no executable proof driver, and did not define a safe proof-only composition. It also left repeated AppKit termination requests, failed-Quit retry intent, startup-recovery Quit, action coalescing, and authorization-cancellation stages ambiguous.

The repaired contract makes structured lifecycle plus explicit recovery and pending-Quit state the only presentation truth. It defines exact header/action/status-item mappings, preserves Quit intent after failed cleanup, coalesces repeated termination and cleanup actions, permits terminate-now only from known clean Off, and distinguishes pre-ownership cancellation from uncertain post-ownership cleanup.

The repaired proof requires a separate packaged proof app that reuses production UI, AppDelegate, app-state, and session-coordinator code while injecting only outer providers. It records raw PID-bound accessibility, lifecycle, termination, journal, command, and process evidence; a separate XCTest oracle derives the verdict; and a release-bundle guard proves the shipped app cannot select proof providers.

## 2026-07-17 repeated AppKit request contract repair

After implementation began, the native repeated-Quit proof demonstrated that AppKit can coalesce a second real external termination request while it is waiting for the first deferred reply. The previous proof assumption that two requests must yield two delegate callbacks was therefore false at the real boundary; its timing-based second decision was removed.

The repaired contract preserves two real external request inputs but judges only callbacks AppKit actually delivers. A nil-by-default AppDelegate observer records the synchronous decision and later deferred reply separately: in-flight callbacks must be terminate-later, callbacks delivered after pending-Quit Cleanup Required must cancel, and no repeated request may return terminate-now, start another cleanup, or permit early exit. The native proof failed at the old two-callback assertion before this repair, and the independent oracle now checks the state- and order-specific invariant without synthesizing a delegate re-entry.

## 2026-07-17 evaluator-driven real-boundary proof repair

Independent evaluation found that the prior green artifact used a proof-only host window instead of `StatusBarController`'s `NSPopover`, read mirrored status values instead of the actual status button, did not submit a fresh real Quit after failed cleanup, omitted late-Preparing compensation failure and Quit-during-recovery failure, lacked a sensitive-detail leak sentinel, scanned too little of the release bundle, narrated activation completion, and accepted black or transparent PNGs.

The repaired oracle was first run against the old artifact and failed because `popover_content_view_id` was absent. This established red at the newly required actual-object boundary without weakening any existing lifecycle criteria. The proof app now composes only controlled outer providers and otherwise drives the real status controller, popover, controls, AppDelegate, app state, activation task, session coordinator, and journal. Object identities and window numbers bind inputs, accessibility, screenshots, and direct status reads to those production objects.

The scenario matrix now includes 16 processes. New cases cover failed compensation after the lease-acquired Preparing boundary and failed Quit during startup recovery. The failed-Quit case injects an authorization-cancellation record containing a unique password/raw-command sentinel, requires a fresh second external Quit to return terminate-cancel, obtains an atomic external-driver liveness receipt before Retry, and then exits only after the real Retry control reaches verified Off. Retained failure processes use the same cross-process liveness handshake before the driver reaps them.

Screenshot capture now renders the actual visible popover content view at backing scale into an opaque bitmap. The independent oracle decodes all six PNGs and checks opacity, non-black coverage, and color diversity. Release exclusion now inventories every file, scans both the main executable and sleep helper independently, and scans the complete bundle for every proof selector or artifact signature.

During the repaired full run, two proof-driver races were found and fixed without changing product behavior: startup recovery could request the popover before AppKit finished its first event-loop turn, and a liveness JSON file could be observed between creation and completion. The driver now waits for actual status-button window attachment plus one event-loop turn, and publishes liveness receipts with an atomic rename.
