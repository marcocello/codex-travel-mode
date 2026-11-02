# Proof Plan

## Definition Of Done
- The production monitoring path reacts to lid and connectivity transitions rather than repeatedly acting on the current level.
- A healthy configured iPhone path remains stable across repeated ticks with exactly one association episode.
- Success requires SSID, address, default route, and outbound reachability together.
- Provider failure, partial connectivity, bounded retry exhaustion, and cancellation remain distinct and observable.

## Primary Proof
Type: worker-scheduler

Boundary:
- Producer: production Travel Mode activation, lid observations, network observations, Stop, and explicit Retry events.
- Activation path: run the normal app-state monitoring and engine path across controlled ticks and transitions.
- Consumer: lid-transition tracker, association episode coordinator, command gateway, reachability verifier, retry policy, and cancellation ownership.
- Durable state: an event/command trace and final runtime connectivity state for the active session.
- Read-back: association attempt count and timing, target SSID, route/address observations, local probe receipts, runtime state, and post-cancellation command trace.
- Unsafe edge: macOS lid/Wi-Fi providers and the external internet endpoint are replaced only at the outer boundary by stateful providers and a real local HTTP probe server.

Command:
```bash
scripts/proof_run_capture --serious --feature-dir docs/features/lid-triggered-iphone-internet --provider-readback provider-readback.json --source-path Package.swift --source-path Sources/CodexTravelModeCore --source-path Tests/IPhoneInternetHandoffProofWorker --source-path Tests/CodexTravelModeCoreTests/IPhoneInternetHandoffProofTests.swift --source-path scripts/run_iphone_internet_handoff_proof --source-path scripts/proof_run_capture --source-path docs/features/lid-triggered-iphone-internet/proof/run.sh --behavior-boundary "Travel Mode, lid, network, Stop, and Retry events -> production monitor and handoff coordinator -> outer Wi-Fi provider and real local reachability server -> command trace, probe receipt, transactional journal, and connectivity-state read-back" --oracle-scope "$(cat docs/features/lid-triggered-iphone-internet/PROOF.md)" --notes "Transition-triggered iPhone handoff, internet verification, bounded retry, exact restoration, and cross-session cancellation proof" -- docs/features/lid-triggered-iphone-internet/proof/run.sh
```

Expected evidence:
- Open-to-closed and initially-closed scenarios each produce one association episode.
- A lid-close event while the configured iPhone already has a verified healthy path produces zero Wi-Fi power or join commands.
- Ten additional healthy closed-lid ticks produce zero additional power or join commands.
- SSID-only, address-only, wrong-route, and failed-probe scenarios never report connected.
- A healthy route generates a real request receipt from the local probe server before connected is reported.
- Wi-Fi-enable failure prevents association and remains a structured `wifi_power_command_failed` error distinct from `connectivity_provider_failed` and ordinary disconnection.
- Provider command failure remains an error rather than disconnection.
- Retry attempts remain within the configured count and elapsed budget.
- A healthy-to-unhealthy transition starts exactly one new bounded recovery episode; after exhaustion, only explicit Retry or another qualifying transition starts another.
- An explicit open-lid disconnection starts one bounded fallback episode without changing the healthy-open-network preservation rule.
- Stop during power, association, connectivity observation, probe, and backoff prevents every later command and state publication for the ended session.
- Session A work released after Stop and Start B cannot create a mutation intent in B's journal or publish into B; B remains independently usable.
- When Wi-Fi begins off, the raw journal and command trace show journaled power enable with verified read-back before association and exact baseline restoration after Stop. No association backend emits a hidden power command.
- Reopening cancels a close-owned episode; a later close owns one fresh episode. Initial open-and-disconnected, provider failure, and partial open-path loss do not masquerade as the explicit associated-to-disconnected fallback edge.
- Exact-byte SSID fixtures keep canonically equivalent names distinct.

## Claimed Behavior Coverage
| FEATURE claim | Real production entrypoint proof drives | Fake boundary used | Read-back |
| --- | --- | --- | --- |
| One handoff per qualifying transition | Production lid-monitor ticks | Stateful outer lid/Wi-Fi provider | Association trace across repeated ticks |
| Internet requires a usable target path | Production verification path | Stateful outer Wi-Fi provider plus local HTTP server | SSID/address/route state and probe receipt |
| Bounded retry after real failure | Production retry coordinator | Controllable provider failures and clock | Attempt trace, elapsed budget, terminal state |
| Recovery and open-lid fallback start only from transitions | Production health, Retry, and disconnection events | Stateful outer provider | Episode IDs and bounded association trace |
| Stop cancels future mutations | Production Stop request and transactional cleanup | Delayed outer operations | Post-stop trace, state publication, session identity, journal reconciliation, and restored baseline |
| Power ordering and cross-session isolation | Production session-bound mutation APIs | Off baseline and delayed session-A providers | Raw journal revisions, command order, exact restore, and session-B journal |

## Fake Boundary Ledger
- Fake: macOS lid state, Wi-Fi association/status, monotonic time advancement, and the remote internet endpoint.
- Allowed because: physical lid and network mutation are unsafe/non-deterministic locally; the real production monitor, coordinator, retry, cancellation, and health decision remain active.
- Not faked: event activation, transition detection, state machine, association episode ownership, production policy values, reachability client, transactional mutation journal, retry policy, cancellation, or read-back interpretation.

## Raw Artifact And Independent Oracle
- `iphone-internet-handoff-proof-worker` runs as a separate PID and writes `provider-readback.json`; it records raw events, typed provider observations, session/app-generation/episode identities, monotonic timestamps, operation timeouts, command dispatches, transactional journal revisions, runtime-state publications, local HTTP receipts, and final state. It emits no verdict or assertion booleans.
- `scripts/run_iphone_internet_handoff_proof` validates schema, worker PID, required scenario names, and forbidden self-attestation keys before running `IPhoneInternetHandoffProofTests` in a separate test process against `PROOF_ARTIFACT_PATH`.
- The independent oracle cross-references probe nonce and receipt ID, requires an empty request body and absence of Authorization/Cookie/password sentinels, verifies contiguous ordering and identity, and derives transition counts, deadlines, cancellation, health, and restoration outcomes from raw evidence.
- Forbidden artifact keys include `pass`, `passed`, `verdict`, `checks`, `assertions`, `expected`, `matches`, `within_budget`, and `no_churn` at every nesting level.

## Proof Scope
Proves:
- Travel Mode performs one transition-owned iPhone handoff, verifies a complete usable path, retries finitely, and stops all work when the session ends.

Does not prove:
- Actual RF association to an iPhone, physical closed-lid operation, battery behavior, or a public internet endpoint.

False-green risks:
- Only the first closed-lid tick could be tested; the proof drives ten additional healthy ticks.
- A fake implementation could equate SSID with internet; each missing health dimension is varied independently.
- Cancellation could update UI while a delayed join still executes; the proof releases delayed operations after Stop and requires zero later commands.
- A stale session-A task could be accepted by a same-device session B; the proof restarts before releasing A and inspects B's journal plus state trace.
- A join backend could secretly turn Wi-Fi on; the proof uses an off baseline and independently records every raw power mutation and journal revision.

Evidence strength:
- Deterministic reactive integration proof with real production coordination, production 30-second policy values under a manual monotonic clock, a real local reachability server, and transactional journal read-back; physical network behavior remains a live gap.

## Secondary Guards
- `swift test`
- `git diff --check`

## Environment And Data
- SwiftPM, controlled clocks/providers, non-secret SSID fixtures, and a local loopback HTTP server.
- No live Wi-Fi mutation, hotspot password, or external network.

## Anti-Gaming Review
- Fake pass risk: a Boolean `forceFallback` remains level-triggered. Proof catch: repeated closed-lid ticks must not increase command count.
- Fake pass risk: verification checks only one health field. Proof catch: SSID, address, route, and probe are independently absent or wrong.
- Fake pass risk: retries are finite in tests but unbounded in production time. Proof catch: attempts and elapsed budget are both asserted through the real coordinator.
- Fake pass risk: the coordinator immediately restarts after exhaustion or ignores Wi-Fi-enable failure. Proof catch: the post-exhaustion idle interval and failed enable trace must contain zero joins until explicit Retry.
- Broken implementation that would still pass: simulated macOS providers cannot prove iPhone or clamshell hardware behavior; supervised readiness owns that gap.

## Manual Gaps
- Real iPhone association and closed-lid battery connectivity are required by `supervised-travel-mode-readiness`.
- The loopback server proves the production URLSession request, privacy policy, status handling, timeout/cancellation, and pre/post route ordering; it cannot prove that a real public request egresses through the provider-reported default-route device.
