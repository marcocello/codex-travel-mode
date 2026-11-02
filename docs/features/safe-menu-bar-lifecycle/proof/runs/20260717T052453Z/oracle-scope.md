# Proof Plan

## Definition Of Done
- The packaged menu-bar UI renders every lifecycle state and drives the production Start, Stop, Retry Cleanup, and Quit entrypoints.
- Popover dismissal preserves Active while explicit Stop restores.
- Failed cleanup prevents Off and prevents termination; successful cleanup permits both.
- Startup recovery blocks Start and remains visible until a terminal cleanup result.
- Settings remain locked outside clean Off, and status-item accessibility identifies every lifecycle state while the popover is hidden.
- Quit during Preparing defers termination through cancellation and compensation, exiting only after verified Off or remaining alive in Cleanup Required.

## Primary Proof
Type: native-ui-subprocess

Boundary:
- Producer: native presses against the built proof app's real status item and production SwiftUI controls, plus real AppKit termination requests from the proof process.
- Activation path: launch a separately packaged proof app, open and dismiss the real transient popover, press production Start, Stop, Retry Cleanup, and Quit controls, and send single and repeated termination requests.
- Consumer: StatusBarController, MenuBarContentView, AppDelegate termination coordination, and the production session coordinator.
- Durable state: a temporary production session journal plus visible app lifecycle and pending-Quit state.
- Read-back: raw in-process accessibility snapshots, decoded screenshots, process IDs and liveness receipts, AppKit termination decisions/replies, lifecycle publications, session journals, and an ordered outer-provider command trace.
- Unsafe edge: system power, helper, and Wi-Fi providers are replaced at their outer app boundary; the menu-bar UI and lifecycle path are not replaced.

Command:
```bash
PROOF_OUTPUT_DIR="$(mktemp -d)"
export PROOF_OUTPUT_DIR
scripts/proof_run_capture --serious --feature-dir docs/features/safe-menu-bar-lifecycle --source-path Package.swift --source-path CodexTravelMode-Info.plist --source-path Sources/CodexTravelModeApp --source-path Sources/CodexTravelModeCore --source-path Tests/LifecycleUIProofApp --source-path Tests/CodexTravelModeCoreTests/MenuBarLifecycleProofTests.swift --source-path scripts/build-local-app.sh --source-path scripts/build-lifecycle-ui-proof-app --source-path scripts/run_lifecycle_ui_proof --source-path scripts/proof_run_capture --source-path docs/features/safe-menu-bar-lifecycle/proof/run.sh --behavior-boundary "native menu-bar controls and AppKit termination requests -> production status controller, view, app state, and session coordinator -> controlled outer providers -> raw accessibility, process, journal, termination, and command read-back" --oracle-scope "$(cat docs/features/safe-menu-bar-lifecycle/PROOF.md)" --notes "Menu-bar lifecycle, verified Stop, cleanup retry, popover dismissal, repeated Quit, and Preparing compensation proof" --screenshot "$PROOF_OUTPUT_DIR/off.png" --screenshot "$PROOF_OUTPUT_DIR/preparing.png" --screenshot "$PROOF_OUTPUT_DIR/active.png" --screenshot "$PROOF_OUTPUT_DIR/restoring.png" --screenshot "$PROOF_OUTPUT_DIR/recovery.png" --screenshot "$PROOF_OUTPUT_DIR/cleanup-required.png" --provider-readback "$PROOF_OUTPUT_DIR/lifecycle-readback.json" -- docs/features/safe-menu-bar-lifecycle/proof/run.sh
```

Expected evidence:
- Screenshots and raw accessibility read-back distinguish Off, Preparing, Active, Restoring, startup Recovery, and Cleanup Required with the exact contract labels, primary actions, control enabled states, status-item labels, symbols, and tints.
- Dismissing and reopening the popover preserves Active and produces zero cleanup commands.
- Preparing and startup Recovery are visibly distinct, disable Start/settings, and remain identifiable from the hidden-popover status-item accessibility label.
- Stop success shows Restoring before Off and clears the proof journal.
- Injected cleanup failure or cancelled cleanup authorization keeps the app alive, shows Cleanup Required, disables Start/settings, and exposes Retry Cleanup.
- Quit during Active waits; injected failure cancels termination, while retry success terminates.
- Quit during each delayed Preparing stage records termination intent, cancels or compensates, and either terminates from verified Off or remains alive in Cleanup Required with no unresolved activation task.
- Two real external termination requests during delayed cleanup remain visible as two raw inputs even when AppKit coalesces the second before delegate delivery. Every callback actually delivered while cleanup is pending returns terminate-later; a callback delivered after pending-Quit Cleanup Required returns cancel; none returns terminate-now. Both success and failure dispatch one cleanup and prevent early exit; success emits a deferred allow reply and exits, while failure emits a deferred cancel reply and stays alive.
- Stop-originated Retry Cleanup succeeds to Off without terminating. Quit-originated failure preserves pending intent and exposes Retry Cleanup & Quit; success exits only after verified Off.
- Quit during startup recovery coalesces with the owned recovery task and follows the same verified-Off or Cleanup Required rule.
- Cancelling the pre-Start notice produces zero provider commands and clean Off; cancellation after durable ownership compensates or becomes Cleanup Required.
- Quit from clean Off terminates with zero power or Wi-Fi commands.
- The separately built release app contains no lifecycle proof provider, scenario selector, proof executable, or proof environment switch.

## Claimed Behavior Coverage
| FEATURE claim | Real production entrypoint proof drives | Fake boundary used | Read-back |
| --- | --- | --- | --- |
| Lifecycle is visible and accessible | Real status item and popover | Outer system providers | Screenshot and accessibility labels |
| Preparing and startup recovery block controls | Real launch and Start controls | Delayed outer acquisition/recovery | Screenshots, accessibility labels, disabled controls |
| Dismiss hides without stopping | Real popover dismissal | Outer system providers | Process/session state and zero cleanup trace |
| Stop success/failure is truthful | Real Stop and Retry controls | Injected outer cleanup outcome | UI state, journal, command trace |
| Quit waits, cancels, or completes correctly | Real application termination request | Injected outer cleanup outcome | Process liveness and final journal |
| Quit compensates Preparing | Real Quit during delayed Start stages | Delayed helper/app mutation providers | Termination intent, process liveness, journals, final lifecycle |
| Repeated termination cannot bypass cleanup | Two real external AppKit termination requests | Delayed/failing cleanup provider | Two raw request inputs, actual delivered callback decisions, deferred reply, one cleanup trace, process liveness |
| Retry semantics preserve origin | Real Retry Cleanup and Retry Cleanup & Quit controls | Failing-then-success cleanup provider | Action labels, pending-Quit state, process and journal outcome |

## Fake Boundary Ledger
- Fake: privileged helper, power, Wi-Fi, reachability, and deterministic cleanup outcomes.
- Allowed because: UI proof must not mutate the host; these are outer providers while the real app UI and lifecycle remain active.
- Not faked: built app launch, status item, popover, production controls, AppDelegate termination path, session coordinator, journal, accessibility read-back, or process exit.
- Composition: a separate proof-only executable injects controlled outer providers through production constructors. The shipped executable has no argument or environment path that selects them, and a release-bundle guard rejects proof symbols/assets.

## Proof Scope
Proves:
- The built menu-bar app truthfully presents and coordinates lifecycle, Stop, cleanup retry, popover dismissal, and Quit behavior.

Does not prove:
- Real administrator prompts, physical lid behavior, iPhone internet, or helper restoration after force-quit.

False-green risks:
- A view-model test could bypass AppKit termination; the proof launches the built app and observes process liveness.
- Popover dismissal could appear active from stale text while cleanup ran; the proof checks the command trace and reopens the popover.
- Quit could terminate after showing Cleanup Required; the proof injects failure and verifies the process remains alive.
- Cancelling Start could be mistaken for safe cleanup; the proof requests Quit after durable intent and after helper acquisition, then requires compensation read-back before process exit.
- Producer-written PASS flags could mirror implementation assumptions; the runner rejects verdict/check/assertion keys and a separate XCTest process derives every criterion from raw events.

Evidence strength:
- Native packaged-app UI automation with screenshots, accessibility, journal, command-trace, and process read-back; unsafe providers remain controlled.

## Secondary Guards
- `swift test`
- `scripts/build-local-app.sh`
- `git diff --check`

## Environment And Data
- A macOS GUI session, built proof-configured app, native UI driver, temporary journal, and non-secret provider fixtures.
- No live power/network mutation or hotspot password.

## Anti-Gaming Review
- Fake pass risk: inner state tests pass while AppDelegate still always terminates. Proof catch: real process liveness is checked after an injected cleanup failure.
- Fake pass risk: popover dismissal invokes cleanup. Proof catch: dismiss/reopen requires Active with zero cleanup trace.
- Fake pass risk: screenshots show labels but actions are not wired. Proof catch: controls are clicked and durable journal/process outcomes are read back.
- Fake pass risk: Quit during Preparing immediately terminates once the Start task receives cancellation. Proof catch: delayed activation stages are terminated only after journal and helper-release read-back, with a failure case that must keep the process alive.
- Broken implementation that would still pass: proof-configured outer providers cannot establish real helper and hardware behavior; supervised readiness owns that gap.

## Manual Gaps
- Self-process native accessibility proves rendered controls and actions without requiring global Accessibility permission. It does not prove VoiceOver speech order; supervised readiness owns that optional live check.

## Raw Artifact And Independent Oracle
- `lifecycle-readback.json` has `schema_version: 1`, one driver PID, and a nonempty `scenarios` array. It contains no verdict or derived assertion fields.
- Every scenario records a unique launch ID and proof-app PID; ordered native input events; lifecycle and pending-Quit publications; popover shown/hidden state; raw status-item accessibility label, symbol, and tint; rendered accessibility elements with identifier, role, label, value, enabled state, and frame; journal snapshots; outer provider commands; each external AppKit termination request input, every synchronous delegate decision AppKit actually delivers, each later deferred allow/cancel reply, and driver-observed process liveness or exit status. Request inputs and delivered callbacks are separate records because AppKit may coalesce repeated requests before delegate delivery.
- Required scenarios include clean Off Quit, pre-Start cancel, Preparing Quit before journal, Preparing Quit after journal, Preparing Quit after lease, Active dismiss/reopen, Stop success, Stop failure/retry success, Quit failure/retry success, repeated Quit during delayed success, repeated Quit during failure, startup recovery success, startup recovery failure, and Quit during startup recovery.
- `scripts/run_lifecycle_ui_proof` verifies schema, required scenario names, PID/source binding, real PNG metadata, and absence of `pass`, `passed`, `verdict`, `checks`, `assertions`, `expected`, or aggregate observation booleans before invoking `MenuBarLifecycleProofTests` in a separate process with `LIFECYCLE_PROOF_ARTIFACT_PATH`.
- The independent oracle derives exact lifecycle mapping, ordering, command counts, journal clearing/retention, pending-Quit behavior, process liveness, and release exclusion from those raw records. For repeated Quit it requires two external request inputs, one cleanup dispatch, no terminate-now callback, terminate-later for every delivered in-flight callback, cancel for any callback delivered after Cleanup Required, and the matching deferred allow/cancel process outcome without assuming one callback per request.
- Each declared screenshot is a decodable PNG captured from the proof-launched app and is bound to the producing PID and raw accessibility snapshot.
