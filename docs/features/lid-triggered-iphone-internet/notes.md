# Implementation Notes

## 2026-07-17 contract repair

Implementation paused before production edits because quality review found undefined cross-session ownership, an unjournaled power side effect in the CoreWLAN association backend, non-deterministic retry/cooldown behavior, and proof that could pass from XCTest assertions without raw boundary evidence.

The repaired contract selects one session-bound coordinator; exact transactional `session_id`, app generation, and episode identity; three attempts within one 30-second monotonic deadline; one-second and two-second backoff; a five-second recovery cooldown; exact UTF-8 SSID identity; typed independent provider results; a credential-free direct 2xx probe with pre/post route read-back; and cancellation/restoration ordering that rejects stale completions before later commands or publications.

Product rules selected here are: initial open-and-disconnected waits; only confirmed associated-to-disconnected falls back while open; reopening cancels a close-owned episode; and a later close starts a fresh episode. The rejected implementation was extending the existing level-triggered `forceFallback` flag because it cannot own transition epochs, retries, or cross-session cancellation safely.

The proof contract now requires a separate worker PID, raw provider/journal/HTTP artifacts, an independent XCTest consumer, literal production policy values under a manual clock, exact power restoration, and a Stop-A/Start-B stale-completion scenario.

## 2026-07-17 implementation hardening

The production coordinator now authorizes every episode and mutation with the exact durable session ID, app generation, episode ID, and monotonically claimed attempt. Busy work is rejected before a later attempt can advance ownership, so a rejected concurrent Retry cannot retire an operation already in flight.

App lifecycle cancellation covers both directions of the race: a stale monitoring tick cannot publish or mutate after Stop, and a late Start completion is compensated with `stopKeepAwake()` if Stop invalidated activation while the outer start call was suspended. Reopen, Stop, and generation invalidation revoke the exact episode token before awaiting its task.

Dispatched power and association failures are reconciled against authoritative read-back before another attempt or restoration. Confirmed applied state updates the journal's changed flags, confirmed not-applied state clears the pending intent, and uncertain read-back enters cleanup-required recovery. Both cooperative task cancellation and an outer command result categorized as cancelled remain terminal after reconciliation.

Closed-lid provider gaps preserve the last authoritative healthy-target observation so a later authoritative disconnection can schedule one cooldown recovery. Open-lid provider gaps clear the prior path and therefore cannot synthesize the explicit associated-to-disconnected fallback edge.

The final proof worker records 23 raw scenarios from a separate process and exposes no verdict fields. Its independent oracle derives 13 behavior judgments from exact identity-bearing command traces, linked local HTTP request receipts, journal revisions, retry timing, cancellation ordering, and a raw budget-exhaustion trace in which the last operation begins at 29 seconds with a one-second cap and no work begins at or after 30 seconds.

## 2026-07-17 proof command repair

The first captured run failed before invoking the worker because the documented command did not create or export the runner's required isolated `PROOF_OUTPUT_DIR`; its provider-readback path also pointed outside that directory. The proof contract was repaired to create one unique directory, export it to the runner, and capture the raw artifact from that exact location. This changes only proof invocation, not product behavior or acceptance criteria.
