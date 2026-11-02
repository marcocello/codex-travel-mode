# Proof Plan

## Definition Of Done
- A real helper subprocess owns the lease protocol and durable helper journal.
- Clean release, owner death, helper restart, and interrupted acquisition all restore the exact original value.
- Unauthenticated, stale-session, concurrent-owner, and arbitrary-command requests are rejected without power mutation.
- The app cannot enter Active until helper acquisition and read-back verification succeed.
- Owner-death cleanup leaves an exact durable released receipt that the recovering app can verify without reading the original power baseline.
- Definitive request rejection, uncertain dispatch, and authoritative not-found remain distinguishable, and helper loss revokes an already-Active app.

## Primary Proof
Type: cli-subprocess

Boundary:
- Producer: the production lease-client state mapping, a real short-lived owner process, and production app-state/session wiring.
- Activation path: launch a separate proof-helper executable hosting the production lease state machine, communicate through a test connector with kernel-derived connection lifetime, acquire a lease, then exercise clean release, owner death, helper restart, and live Active revocation. A focused `NSXPCConnection` adapter test drives real anonymous-XPC invalidation into the same connection-lifetime callback.
- Consumer: helper authorization checks, lease state machine, durable helper journal, watchdog, restoration, and app-side result handling.
- Durable state: a temporary helper journal and a stateful power-setting file owned by the fake outer command.
- Read-back: helper status responses, helper process exit/restart behavior, journal contents, command trace, and observed final power value.
- Unsafe edge: administrator authorization, `SMAppService` bootstrap, code-signing verdict, privileged Mach lookup, and real `pmset` are replaced by a test connector, principal policy, fixed fake executable, and temporary service sandbox. The packaged root helper has no test-mode, command-path, or environment override.

Command:
```bash
scripts/proof_run_capture --serious --feature-dir docs/features/crash-safe-sleep-override-lease --source-path Package.swift --source-path Sources --source-path Tests --source-path scripts --source-path CodexTravelMode-Info.plist --source-path Packaging --source-path docs/features/crash-safe-sleep-override-lease/proof/run.sh --behavior-boundary "production lease client and app session wiring -> real owner and proof-helper subprocesses using the production lease state machine -> durable helper journal and fixed outer power command -> status, invalidation, trace, receipt, and exact-value read-back" --oracle-scope "$(cat docs/features/crash-safe-sleep-override-lease/PROOF.md)" --notes "Crash-safe sleep-override lease and owner-death restoration proof" -- docs/features/crash-safe-sleep-override-lease/proof/run.sh
```

Expected evidence:
- Disabled and enabled baselines each round-trip exactly after clean release.
- Repeated acquire/status/release for the same session is idempotent and produces no duplicate mutation.
- Killing the connection-owning process without a release produces the exact restored value and durable released receipt within five seconds when the backend is healthy.
- Restarting the helper with an orphaned journal restores before accepting a new lease.
- Interruption before journal persistence, after persistence, after mutation, and before the acquisition response each leave either a clean baseline or a recoverable helper journal that startup reconciles.
- Killing the app after the helper commits acquisition but before its response is received still lets recovery query by the persisted lease request ID and obtain the exact active or released binding.
- A reachable authenticated helper's authoritative not-found permits app-journal cleanup, while unavailable, interrupted, or unauthenticated resolution never clears ownership.
- A mutation followed by failed verification compensates back to the recorded baseline.
- Failed restoration persists `cleanup_required` within two seconds; deterministic clock advancement proves automatic 250 ms, 500 ms, 1 s, and capped 2 s retries, while manual retry bypasses delay and restores exactly once.
- Owner-death and clean release each persist a matching released receipt before the active helper journal disappears; helper restart at either side of that transition reconciles to the same receipt.
- Status for the exact session/request/lease/generation returns released after owner death, while a different value in any part of the binding cannot reuse that receipt.
- Receipt acknowledgement removes only the same-principal exact safe-to-retire receipt and never an active or different lease record. Multiple unacknowledged receipts survive later acquisitions without overwrite.
- A second owner, stale lease ID, different principal, and unauthenticated connection produce no power writes. The typed XPC interface exposes no PID/principal/command/path selector; an out-of-interface selector or malformed envelope is rejected before service dispatch, and metacharacter-bearing allowed IDs cannot alter the fixed executable or arguments.
- Definitive pre-dispatch acquisition rejection leaves the app Off; uncertain acquisition remains `cleanup_required` until exact resolution.
- `TravelModeAppState -> TravelSessionCoordinator -> production lease client mapping -> helper service` reaches Active only with an exact active receipt, and helper connection loss while Active stops app work and produces verified Off or `cleanup_required`.
- Baseline enabled performs no acquire write, but a drift to disabled during the lease is restored to enabled on release.

## Claimed Behavior Coverage
| FEATURE claim | Real production entrypoint proof drives | Fake boundary used | Read-back |
| --- | --- | --- | --- |
| Exact acquire and release | Production lease client | Fake fixed `pmset` executable | Helper status, command trace, final value |
| Same-session calls are idempotent | Repeated production client requests | Fake fixed `pmset` executable | Stable lease ID and non-duplicated trace |
| Restore after app death | Real owner PID exit | Fake fixed `pmset` executable | Watchdog trace, journal, final value |
| Recover after helper restart | Real helper restart with journal | Temporary service registration | Startup trace, journal removal, final value |
| Reject unsafe or stale requests | Real helper protocol | Test caller identity at outer authentication edge | Error response and zero mutation trace |
| Prove release after owner death | Production status and acknowledge calls after real owner exit | Fake fixed `pmset` executable | Exact released receipt, active-journal absence, mismatch rejection |
| Revoke an unprotected Active app | Production app state and coordinator health path | Test connector replacing privileged Mach bootstrap | Loop stopped, lifecycle/result, exact helper receipt or retained cleanup journal |
| Distinguish not-found from unavailable | Production client result mapping and coordinator recovery | Injected transport outcome | App journal clear only after authenticated authoritative not-found |

## Fake Boundary Ledger
- Fake: macOS administrator authorization, `SMAppService` bootstrap, code-signing verdict, privileged Mach-service lookup, and the final fixed `pmset` executable. A test connector replaces the production Mach transport for cross-process crash scenarios; a separate anonymous-XPC guard drives real `NSXPCConnection` invalidation. The negative protocol test invokes an unsupported typed selector/malformed frame at this outer connector rather than adding a production command operation.
- Allowed because: deterministic proof must not install a root daemon or disable real laptop sleep. The proof-helper is a separate product around the production lease state machine, so the packaged root helper exposes no test configuration surface.
- Not faked: production lease-client request/result mapping, helper state machine, owner connection loss, helper process restart, concurrency and exact-binding rules, durable journal/receipt stores, app session wiring, restoration decisions, or fixed operation construction.

## Proof Scope
Proves:
- The production lease state machine, client mapping, and app runtime can lease and automatically restore the exact persistent sleep override across normal and abnormal process lifecycles, with the privileged installation/signing boundary explicitly deferred.

Does not prove:
- Live ServiceManagement installation, Developer ID/notarization, a real administrator prompt, real code-sign verdicts across the packaged Mach service, or physical closed-lid behavior on a battery-powered Mac.

False-green risks:
- A unit mock could simulate owner death; the proof kills a real process observed by the real helper.
- A helper could restore only on clean release; the proof omits release and restarts the helper from its durable journal.
- Interrupted acquisition could strand a mutation before response; the proof terminates the helper at every persistence/mutation boundary and restarts it.
- Restore failure could discard recovery state; the proof fails the first restore, requires the journal, then retries.
- The helper could clear its active journal before leaving app-verifiable evidence; the proof kills and restarts it around receipt persistence and journal removal, then requires one exact released receipt.
- The helper could be a general command runner; the proof submits an arbitrary payload and requires rejection with zero outer writes.
- An unavailable helper could masquerade as authoritative not-found; the proof injects both and requires only the authenticated not-found path to clear app ownership.
- The app could remain visibly Active after helper restoration; the proof invalidates the live owner connection and reads back stopped app work plus Off or retained cleanup state.

Evidence strength:
- Deterministic black-box subprocess and durable-state proof with only unsafe macOS privilege and power mutation replaced.

## Secondary Guards
- `swift test`
- `scripts/validate_helper_packaging` builds an isolated app bundle and fails unless the helper is at `Contents/Resources/codex-travel-mode-sleep-helper`, the LaunchDaemon plist is valid at `Contents/Library/LaunchDaemons/com.codex.travelmode.sleep-helper.plist`, `BundleProgram` and `MachServices` match the fixed identifiers, reciprocal app/helper identifier-plus-team requirement builders are present, nested helper then outer app signatures verify, and no proof-helper product, proof-only argument, or environment-selected backend appears in the packaged helper or bundle.
- `git diff --check`

## Environment And Data
- SwiftPM, temporary directories, a real helper subprocess, a short-lived owner process, and a fake fixed power-setting executable.
- No live power mutation, credentials, or network access.

## Anti-Gaming Review
- Fake pass risk: the app owns restoration and the helper merely runs one command. Proof catch: app death occurs before release and the helper alone must restore.
- Fake pass risk: original `true` is always restored to `false`. Proof catch: both baselines round-trip.
- Fake pass risk: helper restart discards ownership. Proof catch: an orphaned durable journal must be reconciled before new acquisition.
- Fake pass risk: the app treats any old released receipt as proof. Proof catch: session ID, lease request ID, lease ID, and helper-generation mismatches are each rejected with zero power writes.
- Fake pass risk: the helper watches a caller-supplied PID. Proof catch: the production interface has no PID field, and killing the real connection-owning process triggers connection invalidation and cleanup.
- Broken implementation that would still pass: the test connector cannot establish the signed packaged Mach-service identity or live administrator approval; `supervised-travel-mode-readiness` owns that gap.

## Manual Gaps
- Live helper installation, bidirectional code-sign verification, Developer ID/notarization, administrator approval, and physical battery/lid behavior are required by `supervised-travel-mode-readiness`.
