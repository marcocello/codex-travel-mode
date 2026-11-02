# Proof Plan

## Contract-Repair State
- The prior contract overclaimed AppKit Quit causality, treated best-effort prior-SSID recovery as an Off/termination gate, let the controller author system and provider-transport outcomes, and underspecified provider bytes, helper identity, sudo authorization, receipt consumption, and sealing. Evidence from that contract is stale and cannot authorize completion.
- Scope is not reduced: exact prior-SSID equality remains required for a successful live acceptance run, while mandatory Off/Quit policy remains aligned with the upstream transaction contract. Dependency proofs retain AppKit-causality and internal-join-count authority.

## Definition Of Done
- `LiveTravelModeProofHarnessTests.swift` and `ReadinessCoreHardeningTests.swift` deterministically prove preflight non-mutation, MAC/one-time arming, long-lived ephemeral-key observer authentication, fixed provider protocol, exact helper/sudo checks, fixed system probes, exact-process Accessibility readback, failure cleanup, sealing/redaction, and an independent multi-artifact oracle.
- A captured live run uses a fresh exact signed app process per scenario and the matching dynamic enabled helper for manual Stop, manual Quit, and exact-PID owner death on Battery Power with a physical lid and operator-attested iPhone target.
- Live acceptance derives sustained outbound target connectivity, mandatory power/journal cleanup, process-exit ordering, staged owner-death recovery, and final exact prior-SSID equality without claiming that SSID mismatch gates Off/Quit or that the live observer proves AppKit causality.
- Current unavailable physical/signing/provider prerequisites remain `NEED_INPUT`; local green tests cannot complete this feature.

## Primary Proof
Type: cli-subprocess

Boundary:
- Producer: supervised operator, manual production controls, physical lid, exact app process death, and versioned provider.
- Activation: MAC-armed controller orchestration plus typed heartbeat requests to a separate exact-hash observer; the observer performs provider transport, while real signed app/helper Start, Stop, Quit, owner-death, and startup recovery paths remain unchanged.
- Read-back: sealed controller command/operator/cleanup-request facts, hash-chained and observer-signed system/network/process/helper/journal/provider-transport facts, observer-copied signed provider receipts, a signed final observer seal, and a separate exact-hash oracle.
- Unsafe edge: battery clamshell operation, persistent sleep override, Wi-Fi association, helper privilege, app death, and public traffic are live guarded edges and are not faked.

Command:
```bash
scripts/proof_run_capture \
  --feature-dir docs/features/supervised-travel-mode-readiness \
  --timeout-seconds 1800 \
  --note "Guarded live battery acceptance with split observer and independent oracle"
```

The retained runner first executes the deterministic harness suite, then obtains app/config paths from the controlling TTY after capture begins. The new live controller re-enters the app path in memory, independently verifies the app and embedded-helper hashes against the receipt, and does not persist the plaintext path. Raw live evidence is written under the retained attempt directory. The wrapper emits only role labels and digests and redacts the entered paths from captured output.

Expected evidence:
- Preflight observer facts and live revalidation bind the same unexpired five-minute receipt, one-time marker, exact controller hash, observer public key/PID/start/hash, and signed preflight/live handshakes from the same observer. The live handshake has a new exact client PID/start identity, authenticates with the receipt/sidecar, and continues the preflight request sequence without reset; machine/baseline, provider, signed app, embedded helper, dynamic running-helper SecCode identity, enabled registration, and fixed NOPASSWD query also remain bound.
- Before every fresh scenario there is no app process and the anchored mandatory baseline plus distinct non-empty prior/target SSIDs hold. Each app PID/start identity is new and exact.
- Every provider sequence is `1...N`, contains fresh 32-byte nonces and valid 64-byte signatures under the configured 32-byte key, spans at least ten seconds, fits the capability-derived clock bound, and cross-references TaskMetrics plus observer snapshots within two seconds on each side.
- Stop and Quit show manual production actions, mandatory SleepDisabled/Wi-Fi-power/journal cleanup, and process ordering. Final prior-SSID equality is an additional acceptance condition, not evidence of the product's failure-policy causality.
- Owner death shows exact-PID/start `SIGKILL`, helper-only mandatory sleep/journal stage while the app journal remains, manual fresh relaunch, mandatory app recovery, exact prior SSID, and final journal absence.
- Any safety `NSRunningApplication.terminate`, direct rescue, AC sample, stale identity, unauthorized journal query, observer/controller conflation, hash drift, artifact mutation, provider/proxy/route failure, or missing observation produces nonzero completion.

## Claimed Behavior Coverage
| Claim | Real entrypoint | Live read-back | Dependency authority |
| --- | --- | --- | --- |
| Preflight cannot arm by stale/tampered state | Real CLI plus TTY challenge | MAC, sidecar/marker lifecycle, zero command mutations | Harness tests |
| Mac has outbound connectivity over attested target while closed | Manual Start and physical close | Provider signature/nonce/time, TaskMetrics, adjacent observer lid/battery/SSID/address/exact-remote route | Handoff proof owns internal join count |
| Stop restores accepted state | Manual `Stop & Restore` | Mandatory cleanup, then exact prior SSID acceptance | Transaction proof owns best-effort failure policy |
| Quit cleanup precedes exit | Manual production Quit | Mandatory cleanup and external exact-process ordering | Lifecycle proof owns AppKit causality |
| Owner death recovers owned stages | Exact-PID `SIGKILL`, manual relaunch | Helper-only then app recovery observer facts | Lease/transaction proofs own internal causality |

## Raw Artifacts And Oracle
- Controller owns only `command-events.json`, `operator-events.json`, and cleanup-request facts in `cleanup-events.json`; heartbeat entries are typed action requests without transport outcomes. The one preflight-bound observer process owns `preflight-readback.json`, signed hash-chained envelopes in `observer-events.json` and `provider-transport-events.json`, provider execution/TaskMetrics, unchanged provider-signed receipts in `provider-receipts.json`, and signed `observer-seal.json`. `arming-receipt.json` is HMAC-authenticated and one-time consumed. `seal-manifest.json` binds filename, role, author PID/hash, byte length, mode `0400`, and SHA-256.
- Raw event schemas require version, run/scenario, contiguous sequence, wall and monotonic times, author role/PID/hash, event kind, and whitelisted typed facts. They forbid all verdict/assertion/expected-result fields recursively.
- The observer alone records fixed system/network/process/helper/journal facts and all provider transport/TaskMetrics facts. It validates dynamic helper PID with SecCode and distinguishes fixed-query authorized-present, authorized-absent, and unauthorized/indeterminate. Controller-authored provider responses, addresses, routes, metrics, receipts, or other observed outcomes are rejected.
- The oracle PID/hash differs from controller/observer, opens only sealed files, verifies the arming-bound observer public key, mode-`0600` socket under the bound mode-`0700` output directory, same-UID and controller-hash peer evidence, exactly one signed preflight handshake plus one signed authenticated live handshake, continuous request sequence, exact observer PID/start/hash continuity, every event signature/previous-envelope hash, and final observer seal before interpreting facts. It rejects observer death, replacement, or any extra attach, recomputes every file digest before and after evaluation, reconstructs the byte-exact provider payload, and alone writes `oracle-report.json`.
- Captured artifacts and proof metadata must contain neither protected plaintext nor absolute sensitive paths. Redaction uses role labels and salted digests; a secret/path sentinel scan is mandatory.

## Deterministic Proof Matrix
- Arming/trust: HMAC tamper, wrong/missing 32-byte sidecar, receipt older than five minutes, challenge mismatch/digest leakage, changed machine/baseline/binary/provider/output, duplicate/raced `O_EXCL` marker, secret copied into evidence, environment-only opt-in, observer public-key/PID/start/hash mismatch, unsafe socket mode/location, wrong UID/controller hash, forged or duplicate phase handshake, concurrent/third/post-live attach, live attach without HMAC consumption, request-sequence reset, observer restart/death, event-signature or chain break, and final-seal mismatch.
- Preflight/runtime: pre-existing app, reused PID/start identity, AC in any authoritative sample, charge below 20 percent, target empty/equal/not visible, production Location unavailable after launch, harness AX untrusted, stale app/helper signature, dynamic helper SecCode/path/CDHash mismatch, disabled registration, helper PID restart without revalidation, cached/unauthorized/ambiguous sudo, or dirty journal.
- Provider: bad config/version/path/query, header file, partial Keychain pair, non-public origin/remote, redirect/cookie/cache/proxy, timeout/oversize, key/signature length/encoding, canonical-byte variation, capability skew over advertised or 30 seconds, nonce replay, sequence gap/duplicate, wrong run/scenario, receipt outside closed window, TaskMetrics absent, local address not on Wi-Fi, exact remote route wrong, and pre/post adjacency over two seconds.
- Orchestration: observer/controller same PID/hash/author role, controller-authored TaskMetrics/provider outcome, observer system-mutation request, raw sequence gap, file not `0400`, seal/hash drift, post-oracle mutation, manual action missing, app process not fresh, wrong PID killed, premature app-journal removal, helper journal retained, mandatory power mismatch, prior SSID mismatch accepted, and later scenario after failure.
- Cleanup: signal/timeout/evidence/controller/observer failure at every state, exact-process terminate revalidation, cleanup coalescing, rescue provenance, and permanent non-PASS after any `NSRunningApplication.terminate` or direct rescue.
- Policy separation: fixtures where mandatory cleanup reaches Off/Quit but prior SSID differs must produce live non-acceptance without asserting an Off/Quit policy violation; fixtures with correct ordering must not claim AppKit or helper causality beyond dependency evidence.

## Proof Scope And Anti-Gaming
Proves:
- The recorded Mac had sustained public outbound connectivity over the configured operator-attested target while physically closed on battery, and mandatory owned state plus exact prior SSID satisfied live acceptance after each production scenario.
- The harness is fail-closed and its controller cannot manufacture observer/provider outcomes.

Does not prove:
- Cryptographic iPhone identity, AppKit termination causality, internal join count, prior-SSID failure-policy causality, unattended safety, indefinite duration, or other platform combinations.

False-green catches:
- Self-authored clean state or provider transport fails observer signatures, hash-chain continuity, process continuity, and final-seal checks.
- Replayed/echoed heartbeat fails exact sequence, nonce, signed bytes, clock window, TaskMetrics, and adjacent route observations.
- Wrong installed helper fails dynamic SecCode/CDHash/path comparison.
- Clean Off with missing prior SSID remains valid upstream lifecycle behavior but fails this live acceptance run without redefining policy.
- Harness-triggered termination or rescue is retained as safety evidence and permanently invalidates PASS.

Evidence strength:
- Guarded live system proof with split local observation, byte-exact signed remote receipts, sealed artifacts, and an independent oracle; deterministic tests cover unavailable failure variants.

## Environment, Dependencies, And Manual Gap
- Required dependency evidence: fresh transactional-session, crash-safe lease, hotspot configuration, lid handoff, and menu-lifecycle proofs; full gate and evaluator remain separate completion requirements.
- Live requires the physical battery MacBook/iPhone session, exact Developer-signed enabled app/helper, AX-trusted harness, production Location approval, exact NOPASSWD fixed existence query, running Codex, and compatible HTTPS provider.
- Current live state remains `NEED_INPUT`: AC power, exact signed/registered runtime, fixed NOPASSWD prerequisite, and compatible provider/operator session are unavailable. Local implementation and deterministic proof may proceed, but the feature remains incomplete until captured live proof, gate, and evaluator pass.
