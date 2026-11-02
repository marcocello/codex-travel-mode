# Proof Plan

## Definition Of Done

- The production configuration flow consumes structured snapshots from the public CoreWLAN boundary and never references the private `airport` executable.
- Every frozen discovery status, partial remembered result, exact ordering rule, loading state, manual-entry path, and stale-refresh guard is exercised.
- Draft edits never change the committed Start/runtime snapshot, and every non-Off session lifecycle plus Save/Start/double-Save concurrency is locked.
- Revision-specific Keychain staging, active-pointer read-back, orphan cleanup, legacy migration, and every save failure order preserve exactly one coherent active revision.
- Real process death after each durable boundary is recovered by a new process using the production file transaction and a durable recording Keychain boundary.
- Native rendered UI evidence supports independently asserted raw state; screenshots or proof-authored PASS booleans are never the oracle.

## Primary Proof

Type: native-ui-subprocess

Boundary:
- Producer: the built debug proof app's real configuration view and production `TravelModeAppState`, plus a separate save worker process using the production transaction store.
- Activation path: launch the app or worker as a separate PID with only outer CoreWLAN, Keychain, session-lifecycle, and persistence-fault providers replaced; drive refresh, selection/manual entry, Save, dismiss/reopen, terminate, and `SIGKILL` at declared durable boundaries.
- Consumer: production discovery mapping, exact option merge, draft/committed separation, UI control state, active pointer, save journal, startup recovery, Start eligibility, and password-load boundary.
- Durable state: a temporary production configuration root and a durable recording Keychain provider whose vault is excluded from evidence while its trace contains only opaque references and non-secret fingerprints.
- Read-back: independently asserted XCTest results, process IDs and signals, boundary markers, active pointer/journal bytes, redacted provider trace, accessibility or view-state snapshots, and decoded PNG screenshots.
- Unsafe edge: live RF scanning, real location authorization, and the real Keychain service are replaced. Release builds exclude proof composition; no proof provider or environment selector is present in the packaged release app.

Command:
```bash
PROOF_OUTPUT_DIR="$(mktemp -d)"
export PROOF_OUTPUT_DIR
scripts/proof_run_capture --serious --feature-dir docs/features/reliable-hotspot-configuration --source-path Package.swift --source-path CodexTravelMode-Info.plist --source-path Sources --source-path Tests --source-path Packaging --source-path scripts/build-local-app.sh --source-path scripts/build-hotspot-configuration-proof-app --source-path scripts/run_hotspot_configuration_ui_proof --source-path scripts/proof_run_capture --source-path docs/features/reliable-hotspot-configuration/proof/run.sh --behavior-boundary "native configuration controls and real worker PIDs -> production discovery, app-state, and transactional settings flow -> controlled scanner, lifecycle, Keychain, and persistence edges -> raw revisions, redacted traces, control snapshots, and screenshots" --oracle-scope "$(cat docs/features/reliable-hotspot-configuration/PROOF.md)" --notes "Public hotspot discovery and crash-safe configuration proof" --screenshot "$PROOF_OUTPUT_DIR/discovery-error.png" --screenshot "$PROOF_OUTPUT_DIR/manual-selection.png" --provider-readback "$PROOF_OUTPUT_DIR/provider-readback.json" -- docs/features/reliable-hotspot-configuration/proof/run.sh
```

Expected evidence:
- A fresh store shows loading during a gated scan, no selected SSID or iPhone heuristic, and disabled Start.
- Remembered and visible inputs prove saved-first/provider-order/UTF-8-byte-order merging, exact-only de-duplication, and distinct `Office`/`office` options.
- `not_determined`, `denied`, `restricted`, `services_disabled`, `no_wifi_interface`, `provider_failed`, and completed-empty states produce distinct UI snapshots; remembered values survive partial failure and raw error strings never become options.
- A stale scan completion cannot replace the latest result or a manual draft.
- Manual save after denied discovery commits the exact SSID, clears the password draft, survives reopen/relaunch, and makes Start eligible without a Keychain read during rendering or refresh.
- A valid committed revision stays selected and Start-eligible after invisible, empty, or failed discovery.
- Unsaved draft values disable Start and never reach the runtime snapshot. Blank password preserves only the exact same committed SSID; a changed or fresh SSID requires a new password.
- Keychain stage failure, verification failure, pointer pre-commit failure, and credential deletion failure retain the prior revision or a coherent committed candidate as defined by pointer read-back; a fresh failed store has no revision. Ambiguous pointer failure is resolved by authoritative read-back.
- Separate worker PIDs are killed before staging, after verified staging, after pointer commit, and during previous-credential cleanup. A new PID recovers to the prior or fully committed revision and never deletes the active credential reference. Cleanup-pending permits validated Start but rejects another Save until cleanup succeeds.
- Complete legacy SSID/credential state migrates once. A missing/invalid legacy device becomes null and keeps Start disabled; incomplete or unreadable legacy SSID/credential state creates no active revision and remains available for manual resave.
- Save/Start, double Save, Quit/save, and Preparing/Active/Restoring/Cleanup Required lock snapshots show no forbidden mutation.
- The provider trace contains only opaque credential references, operation names, and non-secret fingerprints. The password sentinel is absent from every captured artifact, log, screenshot, committed record, and journal.

## Claimed Behavior Coverage

| FEATURE criterion | Production entrypoint | Replaced outer edge | Independent read-back |
| --- | --- | --- | --- |
| 1. Public typed discovery | App refresh through production discovery mapper | File-controlled CoreWLAN/authorization provider | Typed snapshot, options, source guard, loading timing |
| 2. Exact selection and draft isolation | Manual field, selection, Start eligibility/runtime snapshot | Scanner inputs only | Control snapshot, committed pointer, runtime-capture trace |
| 3. Coherent save | Production Save and transaction store | Recording Keychain and declared persistence fault | Active record, journal, redacted ordered operations |
| 4. Crash recovery | Real save worker killed with `SIGKILL`, new recovery worker | Temporary root and recording Keychain | PIDs, signal, marker, before/after revision/inventory |
| 5. Secret confinement and migration | Launch recovery, migration, validation, association password load | Recording Keychain | Zero-read render/refresh trace, redacted inventory, sentinel scan |
| 6. Concurrency and lifecycle lock | App-state Save/Start/refresh/Quit actions | Controlled session lifecycle and gates | Operation order, control enabled states, unchanged active pointer |
| 7. Native UI behavior | Production SwiftUI configuration view in built proof app | Proof composition excluded from release | View/accessibility snapshots and decoded screenshots |

## Required Raw Artifact

`provider-readback.json` is schema version 1 and contains no top-level verdict. It must contain a nonempty `scenarios` array. Every scenario records:
- `name`, `launch_id`, `pid`, and when applicable `recovery_pid`, `boundary`, and `termination_signal`.
- `discovery_state`, exact `options`, draft/committed SSID values, control enabled states, and Start eligibility.
- `before_revision` and `after_revision` with revision ID, SSID, Wi-Fi device, and credential reference only.
- `credential_inventory` containing opaque references and non-secret fingerprints only.
- Ordered `operations` covering authorization, scan, stage, verify, pointer commit/read-back, cleanup, recovery, validation, and runtime snapshot.
- Screenshot path, window or rendered-view identifier, width, height, and source PID for UI scenarios.

The runner and XCTest derive PASS by asserting these raw facts. A producer-written `verdict`, `passed`, `checks`, or observation Boolean is rejected.

## Fake Boundary Ledger

- Fake: CoreWLAN/authorization results, Keychain storage, session lifecycle, and deterministic failure/checkpoint wrappers around production persistence operations.
- Allowed because: RF visibility, privacy prompts, secret storage, and deliberate process crashes are nondeterministic or unsafe outer edges. The production transaction store still owns journal schema, ordering, atomic replacement, read-back, resolution, and cleanup decisions.
- Not faked: app-state discovery mapping, UI draft and locks, exact merge/validation, active revision schema, save/recovery algorithm, Start snapshot choice, file persistence, app/worker process lifecycle, or oracle assertions.

## Proof Scope

Proves:
- The final built proof app and real worker processes use public typed discovery and a coherent Keychain/settings transaction across UI, failure, concurrency, and crash boundaries.

Does not prove:
- Live location-prompt wording, RF visibility, real Keychain UI, actual iPhone association, or internet access. Supervised readiness owns those live checks.

False-green risks:
- A proof driver could author PASS booleans. The runner rejects verdict/check fields and XCTest independently asserts raw artifacts.
- Screenshots could be placeholders. The runner decodes PNGs, requires realistic dimensions, and ties metadata to a live proof-app PID/view identifier.
- A unit fake could simulate process death. The proof records distinct worker PIDs, waits for a production boundary marker, sends `SIGKILL`, and recovers in a new process.
- A fake store could decide recovery. The proof uses the production file transaction with faults only at named outer writes.
- A password could leak into traces. The runner scans all captured artifacts for the sentinel and permits plaintext only inside the excluded fake-Keychain vault.
- Draft and committed state could still alias. The proof reads the runtime snapshot and active pointer after unsaved edits.

Evidence strength:
- Deterministic native rendered-UI plus real subprocess crash/relaunch proof with raw durable read-back and only OS/provider edges replaced.

## Secondary Guards

- `swift test`
- `scripts/build-local-app.sh`
- Release-bundle guard proving proof composition/providers are absent.
- Source guard rejecting `Apple80211`, `PrivateFrameworks`, and private `/airport` production references.
- `git diff --check`

## Environment And Data

- macOS, SwiftPM, a unique temporary configuration root, built debug proof app, real subprocesses, non-secret SSID fixtures, and a password sentinel confined to the recording Keychain vault.
- No live scan, network association, administrator mutation, real password, or external service.

## Manual Gaps

- If native GUI rendering is unavailable, the proof is `NEED_INPUT`; it cannot pass from static source checks. Accessibility driving may be replaced by direct event delivery to the same production view only if raw control snapshots and screenshots remain independently asserted.
