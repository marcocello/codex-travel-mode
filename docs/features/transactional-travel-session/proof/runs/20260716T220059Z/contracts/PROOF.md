# Proof Plan

## Definition Of Done
- The real session coordinator drives the full state transition and durable journal lifecycle.
- Exact app-owned Wi-Fi power is restored and the helper lease is verified released before Off; prior association is restored when available and reported without blocking power cleanup when unavailable.
- Unowned cleanup performs no mutation, failed capture performs no mutation, and partial cleanup remains visible and retryable.
- Recovery and a concurrent Start cannot overwrite or clear each other's journals.
- Process death at each write-ahead mutation boundary recovers without losing ownership, and Quit during Preparing compensates before termination.

## Primary Proof
Type: migration-internal

Boundary:
- Producer: Start, Stop, Quit, and startup-recovery requests submitted through a real short-lived process hosting the production Travel Mode session coordinator.
- Activation path: the normal app-state lifecycle calls the real durable settings store, helper-lease client, and app-owned command gateway interfaces; the proof kills and relaunches the coordinator process at declared mutation boundaries.
- Consumer: session transition logic, app-owned mutation ownership, lease coordination, restoration orchestration, and recovery serialization.
- Durable state: a temporary real journal store plus a process-independent state/trace file for recorded system-command effects.
- Read-back: lifecycle state, journal contents, structured cleanup result, and observed power values after each transition.
- Unsafe edge: the privileged helper client and Wi-Fi commands are replaced only at their outer interfaces with stateful fakes that expose lease receipts, reads, writes, failures, and ordering.

Command:
```bash
scripts/proof_run_capture --serious --feature-dir docs/features/transactional-travel-session --source-path Sources/CodexTravelModeCore --source-path Tests/CodexTravelModeCoreTests --source-path scripts/proof_run_capture --source-path docs/features/transactional-travel-session/proof/run.sh --behavior-boundary "Start, Stop, and recovery requests -> production session coordinator and durable store -> gateway state transitions -> journal and power read-back" --oracle-scope "$(cat docs/features/transactional-travel-session/PROOF.md)" --notes "Transactional Travel Mode session and exact restoration proof" -- docs/features/transactional-travel-session/proof/run.sh
```

Expected evidence:
- Active is impossible without an acquired lease receipt, and Off is impossible without a verified released receipt.
- Stop or Quit while Off and recovery without a journal produce zero gateway or helper mutations.
- Capture or durable-readback failure leaves the state Off and produces zero mutations.
- Wi-Fi power baselines of enabled and disabled each round-trip exactly when Travel Mode changes power.
- A captured prior network is reassociated after Travel Mode changed to the iPhone when that network is available.
- An unavailable prior network produces a bounded non-blocking warning while exact Wi-Fi power restoration and helper release still complete.
- A command that reports success but reads back the wrong value enters `cleanup_required` and retains the journal.
- An unrelated power setting changed during the active session is untouched by cleanup.
- A failed mandatory restore retains the journal, reports `cleanup_required`, and succeeds on retry without duplicate unrelated writes.
- A failed Wi-Fi power write is observed as failure rather than logged as success.
- Interleaved recovery and Start requests cannot clear or replace a different session ID.
- Killing the coordinator after intent persistence, after command dispatch, after verification, and before completion recording leaves a recoverable journal; relaunch restores the captured baseline and clears only after verified cleanup.
- Quit during capture, helper acquisition, mutation dispatch, and verification either reaches clean Off and exits or remains alive in `cleanup_required`; no unresolved activation terminates normally.
- A helper owner-death release receipt satisfies cleanup only for the exact session, lease request, lease, and helper generation recorded by the app; any stale or mismatched binding is rejected.

## Claimed Behavior Coverage
| FEATURE claim | Real production entrypoint proof drives | Fake boundary used | Read-back |
| --- | --- | --- | --- |
| Capture before mutation and fail closed | Production Start request | Stateful outer command gateway | Command order, lifecycle state, durable journal |
| Restore exact app-owned values and release lease | Production Stop request | Stateful Wi-Fi gateway and helper client | Observed Wi-Fi state, lease receipt, and cleanup result |
| Restore prior association without stranding power cleanup | Production Stop request | Stateful association gateway | Final SSID when available and bounded warning when unavailable |
| Verify writes and leave unrelated settings alone | Production Start/Stop | Stateful gateway with mismatching read-back and unrelated state | `cleanup_required`, retained journal, untouched unrelated value |
| Keep partial cleanup recoverable | Production Stop and retry | Injected outer write failure | Retained journal, `cleanup_required`, successful retry |
| Serialize recovery and Start | Production recovery and Start requests | Delayed outer reads/writes | Session IDs, final journal, final state |
| Recover interrupted mutation intent | Real coordinator process termination and relaunch | Process-independent outer state file | Pending intent, observed state, restored baseline, final journal |
| Compensate Quit during Preparing | Production Quit during each activation stage | Delayed/failing outer operations | Process liveness, termination intent, cleanup result, final journal |

## Fake Boundary Ledger
- Fake: only the privileged helper client and macOS Wi-Fi command execution.
- Allowed because: these commands are unsafe to mutate in deterministic contract proof; the feature claim is the production transaction and recovery logic.
- Not faked: lifecycle entrypoints, coordinator process death/relaunch, state machine, durable app-journal encoding/read-back, write-ahead ordering, lease ordering, ownership rules, cleanup ordering, or result interpretation.

## Proof Scope
Proves:
- Travel Mode journals, restores, verifies, and recovers exactly its mandatory app-owned power values while coordinating one helper lease, and handles prior-network reassociation as an observable bounded best-effort result.

Does not prove:
- Real administrator authorization, process-death cleanup, a real Mac lid, or a real iPhone hotspot.

False-green risks:
- A test could assert calls without verifying durable state; the proof reads the journal and observed gateway state after every transition.
- The app could bypass or forget the helper lease; the proof requires acquisition before Active and verified release before Off.
- Failure could clear the journal anyway; the proof injects each mandatory failure and retries from persisted state.
- A test could model interruption as an ordinary thrown error; the proof kills a real coordinator process after externally observed boundary markers and relaunches from disk.

Evidence strength:
- Deterministic integration proof across the production coordinator and real durable store with only unsafe OS commands faked.

## Secondary Guards
- `swift test`
- `git diff --check`

## Environment And Data
- SwiftPM, a temporary non-secret journal store, non-secret SSID fixtures, and a stateful command-gateway fake.
- No administrator prompt, live power mutation, network mutation, or hotspot password.

## Anti-Gaming Review
- Fake pass risk: source contains new lifecycle names but still clears state on failure. Proof catch: injected restoration failures require a retained journal and `cleanup_required` read-back.
- Fake pass risk: command exit zero is treated as restoration. Proof catch: a successful write with mismatching read-back must remain cleanup required.
- Fake pass risk: cleanup disables any active global override without ownership. Proof catch: Stop while Off with no journal must record zero mutations.
- Fake pass risk: cleanup rewrites a broad power snapshot. Proof catch: an unrelated value changed during Active must remain changed after cleanup.
- Fake pass risk: the iPhone remains selected even though the captured prior network is available. Proof catch: the available-prior-network scenario requires reassociation read-back, while the unavailable scenario must terminate within its bound and report a warning.
- Fake pass risk: the app still reads or writes `SleepDisabled` directly. Proof catch: the app proof exposes only the helper lease interface and requires no direct sleep-override gateway call.
- Fake pass risk: a Wi-Fi command runs before its mutation intent reaches durable storage. Proof catch: the outer trace rejects any operation whose intent ID is not already readable from the journal, then process death exercises every later boundary.
- Fake pass risk: Quit during Preparing exits while a lease or Wi-Fi mutation is unresolved. Proof catch: termination is requested at each delayed activation stage and process liveness plus journals are read back.
- Broken implementation that would still pass: the outer fake cannot establish real macOS authorization behavior; `supervised-travel-mode-readiness` owns that gap.

## Manual Gaps
- Real privileged and crash behavior is covered by later queue items.
