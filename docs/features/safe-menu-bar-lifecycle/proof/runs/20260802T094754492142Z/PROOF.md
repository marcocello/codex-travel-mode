# Proof Plan

## Definition Of Done
- The packaged menu-bar UI renders every lifecycle state and drives the production Start, Stop, Retry Cleanup, and Quit entrypoints.
- Popover dismissal preserves Active while explicit Stop restores.
- Failed cleanup prevents Off and prevents termination; successful cleanup permits both.
- Startup recovery blocks Start and remains visible until a terminal cleanup result.
- Hotspot configuration is rendered only in clean Off; the other states render their lifecycle-specific summary, activity, or recovery surface, and status-item accessibility identifies every lifecycle state while the popover is hidden.
- Every state exposes a full-width primary lifecycle action. Off exposes a readiness checklist, Active exposes a protected-session summary, transitions expose focused activity, and Cleanup Required exposes recovery guidance.
- Quit during Preparing defers termination through cancellation and compensation, exiting only after verified Off or remaining alive in Cleanup Required.
- The production Codex-running check recognizes the live `com.openai.codex` application even when its executable/display name differs, and rejects missing, terminated, or nonmatching application identities.
- Native proof and release-check bundles execute from a temporary runtime directory; the retained attempt contains screenshots, logs, and independent read-back but no `.app` bundle that Spotlight can present as another installed application.

## Primary Proof
Type: native-ui-subprocess

Boundary:
- Producer: native accessibility presses against controls discovered inside `StatusBarController`'s actual `NSPopover` content view, plus real AppKit termination requests submitted to the proof process.
- Activation path: launch a separately packaged proof app, wait for its actual `NSStatusBarButton` to attach, open and dismiss the production transient popover, press production Start, Stop, Retry Cleanup, and Quit controls, and send single and repeated termination requests.
- Consumer: StatusBarController, MenuBarContentView, AppDelegate termination coordination, and the production session coordinator.
- Durable state: a temporary production session journal plus visible app lifecycle and pending-Quit state.
- Read-back: raw accessibility snapshots bound to the actual popover content-view identity and window number; direct reads from the actual status button and image objects; opaque decoded screenshots rendered from that same visible popover; process IDs and external-driver liveness receipts; AppKit termination decisions/replies; production activation-task publications; lifecycle publications; session journals; and an ordered outer-provider command trace.
- Read-back for the reported regressions: the production workspace adapter must observe a currently running `com.openai.codex` bundle through `NSWorkspace`; focused gateway tests derive matching from raw running-application identities; and the runner searches the retained attempt for any `.app` directory after the native driver exits.
- Unsafe edge: system power, helper, and Wi-Fi providers are replaced at their outer app boundary; the menu-bar UI and lifecycle path are not replaced.

Command:
```bash
"${CODEX_HOME:-$HOME/.codex}/scripts/proof_run_capture" \
  --feature-dir docs/features/safe-menu-bar-lifecycle \
  --timeout-seconds 180 \
  --note "Render and drive every lifecycle-specific menu-bar surface"
```

Expected evidence:
- Six opaque, non-black, visually meaningful screenshots and raw accessibility read-back distinguish Off, Preparing, Active, Restoring, startup Recovery, and Cleanup Required with the exact contract labels, primary actions, lifecycle-specific surface identifiers, status-item labels, symbols, and tints. Every screenshot, press, and accessibility snapshot is bound to `StatusBarController`'s actual popover content-view identity and visible window number; every status record is read directly from its actual `NSStatusBarButton` and image objects.
- Off contains enabled hotspot setup controls and the readiness surface. Active, Preparing, Restoring, Recovery, and Cleanup Required contain no `hotspot.*` configuration controls. Active contains the protected-session surface, transitions contain the activity surface, and Cleanup Required contains the recovery surface.
- In every lifecycle snapshot, the actual `travel.primary-action` remains a native accessible button; retained screenshots are visually inspected to confirm that its clickable style spans the action area.
- Dismissing and reopening the popover preserves Active and produces zero cleanup commands.
- Preparing and startup Recovery are visibly distinct, disable Start/settings, and remain identifiable from the hidden-popover status-item accessibility label.
- Stop success shows Restoring before Off and clears the proof journal.
- Injected cleanup failure or cancelled cleanup authorization keeps the app alive, shows Cleanup Required, disables Start/settings, and exposes Retry Cleanup.
- Quit during Active waits; injected failure cancels termination, while retry success terminates.
- Quit during each delayed Preparing stage records termination intent, produces a cancellation receipt from the controlled provider gate, settles the published production activation task, compensates, and either terminates from verified Off or remains externally observed alive in Cleanup Required. The late helper-lease compensation-failure case must take the latter path.
- Two real external termination requests during delayed cleanup remain visible as two raw inputs even when AppKit coalesces the second before delegate delivery. Every callback actually delivered while cleanup is pending returns terminate-later; a callback delivered after pending-Quit Cleanup Required returns cancel; none returns terminate-now. Both success and failure dispatch one cleanup and prevent early exit; success emits a deferred allow reply and exits, while failure emits a deferred cancel reply and stays alive.
- Stop-originated Retry Cleanup succeeds to Off without terminating. Quit-originated failure preserves pending intent and exposes Retry Cleanup & Quit; a fresh second real Quit submitted after Cleanup Required must be cancelled, the external driver must still observe the process alive, and success exits only after an actual Retry press verifies Off.
- Quit during startup recovery coalesces with the one owned recovery task. The proof covers both verified-Off exit and injected recovery failure that emits a deferred cancel reply and remains externally observed alive in Cleanup Required.
- An injected cleanup authorization-cancellation record contains a unique password/raw-command sentinel in provider-only evidence. The independent oracle requires that sentinel and its sensitive fragments to be absent from the actual rendered accessibility and status-item read-back.
- Cancelling the pre-Start notice produces zero provider commands and clean Off; cancellation after durable ownership compensates or becomes Cleanup Required.
- Quit from clean Off terminates with zero power or Wi-Fi commands.
- The separately built release app is fully inventoried. Both the main executable and embedded sleep helper are scanned independently, and every bundle file is scanned for proof executable, provider, scenario selector, argument, and environment-switch signatures; all occurrence counts and matching-path lists must be empty.
- With Codex running in the current GUI session, the default production gateway reports it running through the live workspace adapter. Controlled identity fixtures prove that only a live exact `com.openai.codex` match succeeds.
- After the proof driver finishes and temporary runtime cleanup runs, a recursive filesystem read-back finds zero retained `.app` directories below the attempt output.

## Claimed Behavior Coverage
| FEATURE claim | Real production entrypoint proof drives | Fake boundary used | Read-back |
| --- | --- | --- | --- |
| Lifecycle is visible and accessible | Real status item and popover | Outer system providers | Screenshot and accessibility labels |
| Lifecycle-specific hierarchy | Real status item and popover | Outer system providers | Screenshots, surface identifiers, native primary action, and absence of configuration controls outside Off |
| Preparing and startup recovery block actions | Real launch and Start controls | Delayed outer acquisition/recovery | Screenshots, accessibility labels, disabled primary action |
| Dismiss hides without stopping | Real popover dismissal | Outer system providers | Process/session state and zero cleanup trace |
| Stop success/failure is truthful | Real Stop and Retry controls | Injected outer cleanup outcome | UI state, journal, command trace |
| Quit waits, cancels, or completes correctly | Real application termination request | Injected outer cleanup outcome | Process liveness and final journal |
| Quit compensates Preparing | Real Quit during delayed Start stages | Delayed helper/app mutation providers | Termination intent, process liveness, journals, final lifecycle |
| Repeated termination cannot bypass cleanup | Two real external AppKit termination requests | Delayed/failing cleanup provider | Two raw request inputs, actual delivered callback decisions, deferred reply, one cleanup trace, process liveness |
| Retry semantics preserve origin | Real Retry Cleanup and Retry Cleanup & Quit controls | Failing-then-success cleanup provider | Action labels, pending-Quit state, process and journal outcome |
| Failed Quit cannot bypass cancellation | Fresh real Quit after pending-Quit Cleanup Required | Failing cleanup provider | Actual terminate-cancel decision and external-driver liveness before Retry |
| Recovery failure retains ownership | Real Quit while startup recovery is held | Delayed failing recovery provider | One recovery dispatch, deferred cancel, Cleanup Required, external-driver liveness |
| Provider detail is not rendered | Real failed-Quit UI/status surfaces | Sensitive sentinel injected only at provider failure boundary | Exact raw provider sentinel plus negative scan of rendered popover and status strings |
| Codex readiness survives executable-name changes | Default production gateway and macOS workspace adapter | None for the live check; raw identity fixtures for negative cases | Live exact bundle identifier plus gateway Boolean |
| Proof apps do not pollute application search | Native proof driver and release build | Temporary local runtime directory | Recursive retained-output scan after driver cleanup |

## Fake Boundary Ledger
- Fake: privileged helper, power, Wi-Fi, reachability, and deterministic cleanup outcomes.
- Fake for secondary Codex matching cases: immutable running-application identity snapshots at the outer `NSWorkspace` boundary.
- Allowed because: UI proof must not mutate the host; these are outer providers while the real app UI and lifecycle remain active.
- Not faked: built app launch, status item, popover, production controls, AppDelegate termination path, session coordinator, journal, accessibility read-back, or process exit.
- Composition: a separate proof-only executable injects controlled outer providers through production constructors. The shipped executable has no argument or environment path that selects them, and a release-bundle guard rejects proof symbols/assets.

## Proof Scope
Proves:
- The built menu-bar app truthfully presents and coordinates lifecycle, Stop, cleanup retry, popover dismissal, and Quit behavior.
- The production readiness path detects the currently running Codex bundle by exact bundle identity and proof execution retains no searchable application bundle.

Does not prove:
- Real administrator prompts, physical lid behavior, iPhone internet, or helper restoration after force-quit.

False-green risks:
- A view-model test could bypass AppKit termination; the proof launches the built app and observes process liveness.
- Popover dismissal could appear active from stale text while cleanup ran; the proof checks the command trace and reopens the popover.
- Quit could terminate after showing Cleanup Required; the proof injects failure and verifies the process remains alive.
- Cancelling Start could be mistaken for safe cleanup; the proof requests Quit after durable intent and after helper acquisition, then requires compensation read-back before process exit.
- Producer-written PASS flags could mirror implementation assumptions; the runner rejects verdict/check/assertion keys and a separate XCTest process derives every criterion from raw events.
- A static heading swap could leave the same dense disabled form in every state; the oracle requires mutually exclusive lifecycle surfaces and absence of `hotspot.*` controls outside Off.
- A `pgrep -x Codex` implementation could pass a mocked process-name test while the real app runs as `ChatGPT`; the proof requires the live production workspace adapter to observe `com.openai.codex`.
- A proof could pass while leaving multiple release/proof apps searchable; the runner checks the retained attempt after temporary runtime cleanup and fails on any `.app` directory.
- SwiftUI's synthetic accessibility button reports a zero frame in the self-process hierarchy even while visible and clickable, so the independent oracle proves the native button role and the parent visually inspects the retained screenshot for full-width styling.

Evidence strength:
- Native packaged-app UI automation with screenshots, accessibility, journal, command-trace, and process read-back; unsafe providers remain controlled.

## Secondary Guards
- `swift test`
- `REQUIRE_LIVE_CODEX_RUNNING=1 swift test --filter LocalTravelCommandGatewayTests`
- `scripts/build-local-app.sh`
- `git diff --check`

## Environment And Data
- A macOS GUI session, built proof-configured app, native UI driver, temporary journal, and non-secret provider fixtures.
- A running Codex desktop bundle with identifier `com.openai.codex`; the proof prints the observed identity without exposing user data.
- No live power/network mutation or hotspot password.

## Anti-Gaming Review
- Fake pass risk: inner state tests pass while AppDelegate still always terminates. Proof catch: real process liveness is checked after an injected cleanup failure.
- Fake pass risk: popover dismissal invokes cleanup. Proof catch: dismiss/reopen requires Active with zero cleanup trace.
- Fake pass risk: screenshots show labels but actions are not wired. Proof catch: controls are clicked and durable journal/process outcomes are read back.
- Fake pass risk: Quit during Preparing immediately terminates once the Start task receives cancellation. Proof catch: delayed activation stages are terminated only after journal and helper-release read-back, with a failure case that must keep the process alive.
- Fake pass risk: a duplicate proof-only `NSWindow` or mirrored status fields can look correct while the shipped popover or status item is wrong. Proof catch: object identities and window numbers bind every press, snapshot, screenshot, and direct status read to `StatusBarController`'s actual objects.
- Fake pass risk: PNG headers and dimensions can pass while screenshots are transparent or black. Proof catch: the independent oracle decodes every PNG and requires opaque, non-black, sufficiently varied pixels in addition to its binding to the matching accessibility snapshot.
- Fake pass risk: provider failure text can leak a hotspot password or privileged command. Proof catch: an exact sensitive sentinel must exist in raw provider evidence and be absent from all actual rendered popover and status-item strings.
- Fake pass risk: lifecycle-specific copy is added without lifecycle-specific hierarchy. Proof catch: accessibility identifiers must be mutually exclusive by state, configuration controls must be absent outside Off, and the retained screenshots must visibly show the distinct compositions.
- Broken implementation that would still pass: proof-configured outer providers cannot establish real helper and hardware behavior; supervised readiness owns that gap.

## Manual Gaps
- Self-process native accessibility proves rendered controls and actions without requiring global Accessibility permission. It does not prove VoiceOver speech order; supervised readiness owns that optional live check.
- SwiftUI's synthetic button frame is unavailable through the self-process accessibility hierarchy, so full-width primary-action geometry is verified by parent inspection of the retained native screenshots rather than an automated frame threshold.

## Raw Artifact And Independent Oracle
- `lifecycle-readback.json` has `schema_version: 1`, one driver PID, and a nonempty `scenarios` array. It contains no verdict or derived assertion fields.
- Every scenario records a unique launch ID and proof-app PID; ordered native input events; lifecycle and pending-Quit publications; production activation-task state; popover shown/hidden state; direct actual status-button label, image symbol, tint, tooltip, and object identities; rendered accessibility elements with identifier, role, label, value, enabled state, and frame; journal snapshots; outer provider commands; each external AppKit termination request input; every synchronous delegate decision AppKit actually delivers; each later deferred allow/cancel reply; and driver-observed process liveness or exit status. Request inputs and delivered callbacks are separate records because AppKit may coalesce repeated requests before delegate delivery.
- Required scenarios are the following 16: clean Off Quit; pre-Start cancel; Preparing Quit before journal; Preparing Quit after journal; Preparing Quit after lease; Preparing Quit after lease with failed compensation; Active dismiss/reopen; Stop success; Stop failure/retry success; Quit failure/fresh-Quit cancellation/retry success; repeated Quit during delayed success; repeated Quit during failure; startup recovery success; startup recovery failure; Quit during startup recovery success; and Quit during startup recovery failure.
- `scripts/run_lifecycle_ui_proof` verifies schema, all required scenario names, PID/source binding, meaningful decoded PNGs, complete release inventory and zero-hit main/helper/bundle scans, and absence of `pass`, `passed`, `verdict`, `checks`, `assertions`, `expected`, or aggregate observation booleans before invoking `MenuBarLifecycleProofTests` in a separate process with `LIFECYCLE_PROOF_ARTIFACT_PATH`.
- The independent oracle derives exact lifecycle mapping, mutually exclusive lifecycle-specific surfaces, native primary-action presence, actual-object binding, activation cancellation/settlement ordering, command counts, journal clearing/retention, pending-Quit behavior, external liveness, sensitive-data non-exposure, PNG content, and release exclusion from those raw records. For repeated Quit it requires two external request inputs, one cleanup dispatch, no terminate-now callback, terminate-later for every delivered in-flight callback, cancel for any callback delivered after Cleanup Required, and the matching deferred allow/cancel process outcome without assuming one callback per request.
- Each declared screenshot is decoded and content-checked, captured from the actual proof-launched popover, and bound to the producing PID, popover content-view identity, visible window number, and matching raw accessibility snapshot.
