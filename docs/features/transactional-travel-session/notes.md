# Contract revision

## 2026-07-16 proof-host repair

The initial proof named real coordinator process death but provided only an XCTest filename and did not declare `Package.swift` or a separate process host as freshness inputs. It also required an app-owned mutation on every Start even when Wi-Fi already matched the required state.

The repaired proof builds a test-only executable that hosts the production coordinator and production atomic journal, injects only process-independent outer Wi-Fi/helper fakes, and is killed and relaunched at the declared write-ahead boundaries. The primary proof now declares `Package.swift` and all `Tests` as source inputs, and Start verifies any required mutation without manufacturing one.

This catches an in-process-only fake recovery test, a stale proof-host binary, and an implementation that changes Wi-Fi solely to satisfy the test. Behavior scope is not reduced.

The first proof-host test draft still trusted host-authored PASS/check Booleans and required every Quit scenario to exit Off. Contract review rejected that false-green path. The proof now derives outcomes from raw journal, provider, lease, ordered trace, and transition artifacts, and separately requires failed Quit compensation to keep the process alive in Cleanup Required. The strengthened artifact remains red against the unimplemented host.

A second review found that journal existence and a host-authored lease-match Boolean were still insufficient. XCTest now decodes the pending journal before SIGKILL, checks its baseline/target/phase and exact lease binding, compares every raw receipt identifier itself, and requires acquisition to precede Active. This further strengthens evidence without changing behavior scope.

A final review found two narrower false-green paths: successful cleanup did not tie every helper identity field back to the owned Active journal, and failed-compensation liveness was sampled only once. The proof now compares the full session/request/lease/generation tuple, rejects each one-field mismatch independently, and observes the failed process plus retained journal throughout a bounded interval before killing it.

Implementation review found that the first recovery-versus-Start host scenario was sequential despite the proof claiming an interleaving. The host proof now blocks a real recovery inside helper release, submits Start to that same coordinator, and requires the rejection event to precede release completion.

## Shared-source revalidation

The crash-safe sleep-override lease extended the shared coordinator, app-state wiring, package targets, and proof support after this foundation first completed. The transactional contract did not change, but its prior evidence source identities became stale. The feature therefore re-entered `repairing`, reran its 13-test subprocess proof against the combined implementation, and reran the 95-test repository gate before returning to `done`.

The executable proof implementation also made its one additional fake boundary explicit: a create-only store adapter injects deterministic read-back failure because the production atomic store deliberately exposes no hook between write and immediate read-back. All successful persistence, CAS, stale-session, process-death, and cleanup paths continue through the real file store.

The final evidence-integrity pass made the outer system fake reject every Wi-Fi write unless it can independently decode the matching prepared mutation intent, and widened captured source freshness from Core-only to all production `Sources`, including the app runtime wiring.

A stale-session repair tightened failure recording as well as clearing: after an old cleanup loses ownership, none of its error paths may mark the replacement journal. The proof now requires the replacement to remain in its original Preparing phase.

The process-death matrix was expanded after hostile review: all four write-ahead checkpoints now kill activation power-up, active-session association, and restoration power-down independently. This covers both mutation reconcilers and both power directions rather than extrapolating from activation alone.

Active-session writes are now registered as owned tasks. Stop, Quit, and recovery cancel and await that exact task before cleanup, while the app also awaits its cancelled polling loop after coordinator cleanup. A file-gated proof lets an association complete after cancellation and requires prior-SSID restoration before Off.

The unavailable-prior-network scenario now begins with Wi-Fi off, so the same cleanup must survive association failure, restore mandatory power to off, and release the helper lease.

Prior-network reassociation now receives an explicit production timeout. Its proof fake hangs until that supplied bound, then verifies warning, power-off restoration, and lease release within the scenario deadline.

Route-only connectivity is no longer treated as recoverable association identity. The production gateway adapter maps its synthetic `Connected on <device>` label to no prior SSID, and the captured proof drives the real local-status fallback through that adapter.

The final runtime-wiring repair adds a process-hosted Start/Stop case through `TravelModeAppState`, `TransactionalTravelCommandGateway`, and `GatewayTravelSessionSystemController`. The proof independently reads the raw gateway effects, Active journal baseline, released lease, cleared journal, and stopped app state instead of extrapolating from coordinator-only scenarios.

## 2026-07-17 uncertainty-window contract repair

The first fresh evaluator pass still failed four central uncertainty windows. A journal create can write successfully and then fail read-back before the coordinator records ownership; helper acquisition can succeed before its binding reaches the app journal; Quit can race that journal-create interval and miss `termination_requested`; and the command-timeout test did not rule out a child performing a late effect after returning `124`.

The proof contract is therefore being strengthened without reducing behavior scope: inject failure after the production store has written the journal, kill a real process with an active helper and app-unbound request, gate Quit after journal persistence but before create returns, and run a direct child that would emit a delayed marker unless timeout termination actually stops it. The evaluator's FAIL is the red contract result against the current implementation; implementation resumes only after these regressions are executable.

The strengthened proof ran red against the old coordinator: post-write failure reported Off with a Preparing journal, and the forced create/Quit race retained `termination_requested=false`. Production now separates the pre-create candidate selector from durable session ownership, resolves post-write failure by exact journal identity, retries termination marking after cancellation, and holds a reference-counted cleanup barrier so overlapping cleanup requests cannot admit a new Start or runtime mutation. Those two regressions, helper-receipt SIGKILL recovery, a SIGTERM-ignoring late-effect child, and concurrent Start inside the cancellation gap now pass.

## 2026-07-17 proof artifact publication repair

The repository gate exposed a race in the failed-compensation liveness case: the proof host wrote `result.json` before its provider, lease, trace, and retained-journal artifacts, while XCTest used the atomic appearance of `result.json` as the complete-case signal. The host now publishes `result.json` last. The focused case passed 20 consecutive runs and the full 13-case transaction proof passed before evidence refresh.
