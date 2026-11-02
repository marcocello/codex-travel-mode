# Lid-triggered iPhone internet handoff

## Summary
While Travel Mode is active, switch to the configured iPhone once when the lid closes, verify that it owns a usable internet path, and recover from genuine path loss without repeated association churn.

## Desired Behavior
- Sample lid state when a session becomes active. An already-closed lid triggers one handoff; otherwise an open-to-closed transition triggers the forced iPhone handoff.
- On lid close, target the configured iPhone even if another Wi-Fi network remains associated.
- If the configured iPhone already owns a healthy path, do not power-cycle or reassociate Wi-Fi.
- Declare success only when association to the configured SSID is confirmed, the Wi-Fi device has a usable address, the default route uses that device, and a bounded outbound reachability check succeeds.
- Model SSID identity, address, default-route ownership, reachability, ordinary disconnection, and command failure separately.
- If Wi-Fi is off, enable it through a result-bearing gateway; the transactional session later restores its original power state.
- Failed handoff uses cancelable backoff with a finite budget that stops within 30 seconds, surfaces the failure, and waits for explicit Retry or a new qualifying transition.
- While the lid remains closed and the path remains healthy, monitoring performs no additional join command.
- A healthy-to-unhealthy transition may start one bounded recovery episode after cooldown; it does not restart on every poll.
- While the lid is open, preserve an existing healthy network. An explicit disconnection may use the configured hotspot as fallback under the same bounded verification rules.
- Stop or restore cancels in-flight joins, probes, sleeps, and retries so no ended session can mutate networking later.

## Session And Episode Ownership
- One `TravelInternetHandoffCoordinator` is the sole owner of lid history, connectivity history, pending cooldown recovery, runtime state, Retry, and the one allowed association episode.
- Successful transactional Start returns its exact durable `session_id`. Every observation, state publication, Retry, power command, association command, and result carries that `session_id`, an app-session generation, and an `episode_id` where applicable.
- Transactional power and association APIs reject a missing or stale expected `session_id` before persisting a mutation intent. A completion from session A cannot bind to session B even when both sessions use the same Wi-Fi device.
- At most one episode exists per active app-session generation. Triggers received during an episode are coalesced into current observation state and never create a concurrent episode.

## Deterministic Episode Policy
- Production uses a monotonic clock. An episode deadline is 30 seconds after the trigger is accepted, including provider reads, power enablement, association, verification, probe, and backoff.
- An episode makes at most three association attempts. Default operation limits are two seconds for one combined provider observation, three seconds for a power mutation, five seconds for association, and two seconds for one reachability probe; every operation receives the lesser of its default limit and the remaining episode budget.
- Failed attempts use cancelable backoff of one second before attempt two and two seconds before attempt three. No operation starts at or after the episode deadline.
- Provider timeouts, retryable provider failures, power-command failures, association-command failures, partial local connectivity, unreachable responses, non-2xx HTTP responses, and probe timeouts may consume another attempt while budget remains. Invalid frozen configuration, missing credential, stale session identity, and cancellation are terminal for that episode without another attempt.
- Exhaustion latches a failed state. Unchanged polls do not clear it. Explicit Retry bypasses cooldown and creates one new episode with a fresh 30-second budget. A later authoritative open-to-closed edge, a later confirmed associated-to-disconnected edge while open, or a later healthy-to-unhealthy target transition while closed is also a new qualifying transition.
- Closed-lid healthy-to-unhealthy recovery has a five-second cooldown measured from the last verified healthy target result. A loss during cooldown records one pending recovery; if the lid is still closed and the target is still unhealthy at expiry, exactly one episode starts.

## Lid And Open-Network Rules
- Lid state is a typed provider reading. Unknown, malformed, timed-out, or failed lid observation is not treated as open and cannot synthesize a transition. The first later authoritative closed sample is treated as the active session's initial closed sample when no earlier authoritative sample exists.
- Initial authoritative open plus ordinary disconnection waits and does not fall back. While open, fallback requires a prior authoritative associated/healthy observation followed by a confirmed ordinary disconnection; provider failure, unknown association, or partial path loss is not ordinary disconnection.
- Reopening during a close-triggered or closed-recovery episode invalidates and cancels that episode before any further mutation. A later close is a new qualifying transition. A close-open-close flap therefore produces no concurrent work and at most one episode for each accepted close edge.
- Opening after a verified target connection preserves that path. It does not disconnect or restore the prior SSID; Stop owns restoration.

## Connectivity And Reachability Contract
- Provider fields use independent typed results: lid, Wi-Fi power, exact UTF-8 SSID identity, addresses, and default-route interface each produce a value, an ordinary unavailable/disconnected value where meaningful, or a categorized failure (`timed_out`, `command_failed`, `malformed_output`, or `unavailable`). Display strings and raw command text are never classification inputs outside the platform adapter.
- Exact SSID comparison uses UTF-8 bytes. Canonically equivalent but byte-distinct names are different networks.
- A usable address is a syntactically valid unicast IPv4 or IPv6 address that is not unspecified, loopback, multicast, or link-local. At least one usable address must exist on the configured device and the authoritative default-route interface must exactly equal that device.
- Target health is evaluated in order: exact configured SSID, usable address, matching default route, bounded reachability probe, then a post-probe provider read that still has the exact SSID, usable address, and matching route. Command success or a synthetic connection label never establishes health.
- The production probe performs a credential-free `GET` to `https://captive.apple.com/hotspot-detect.html` using an ephemeral URL session, platform TLS validation, no request body, no cookies, no cache, no credential storage, no redirects, and a two-second-or-remaining-budget timeout. Only a direct HTTP 2xx response is reachable; response content is not interpreted.
- Runtime failures distinguish `lid_provider_failed`, `connectivity_provider_failed`, `wifi_power_command_failed`, `association_command_failed`, `reachability_failed`, `partial_connectivity`, `stale_session`, and `cancelled`. Ordinary disconnection is a connectivity state, not an error.

## Power And Cancellation Ordering
- Association backends must never enable Wi-Fi implicitly. The order when power is off is typed power read, session-bound journaled enable, verified power read-back, then session-bound association. Unknown or failed power read means no association.
- Stop, Quit, helper-loss restore, and recovery first invalidate the app-session generation, reject new Retry/ticks, cancel the sole episode, and request bounded provider termination. Transactional Stop then cancels and awaits any dispatched runtime mutation, reconciles its durable intent/read-back, and restores the captured baseline before the episode is awaited to quiescence.
- Every suspension is followed by cancellation plus app generation, `session_id`, and `episode_id` validation before another command or state publication. Providers that ignore cooperative cancellation may complete their already-dispatched outer call, but their stale result cannot dispatch a later command, bind to another journal, or publish runtime state.

## Scope
- Lid-transition state, runtime association, structured connectivity health, bounded retry/backoff, reachability verification, and cancellation.

## Non-Goals
- Discovering or selecting the hotspot.
- Persistently restoring power settings or owning the privileged sleep override.
- Restoring the pre-travel SSID after Stop; `transactional-travel-session` owns that recovery context and bounded attempt.
- Permanently changing global network-service order.

## Scenarios
- Office Wi-Fi is healthy and the lid closes: one switch episode targets the iPhone, then repeated healthy polls produce zero additional joins.
- Travel Mode becomes active with the lid already closed: one handoff episode starts.
- The iPhone associates but lacks an address, default route, or outbound reachability: status is not connected and bounded recovery runs.
- The system Wi-Fi provider fails: the structured error is shown and is not labeled ordinary disconnection.
- The verified iPhone path drops while closed: one bounded recovery episode begins.
- Travel Mode stops during backoff or verification: work is cancelled and no later join occurs.

## External Contract
- Connectivity observation exposes SSID, address presence, default-route interface, outbound reachability, and categorized provider error independently.
- Runtime states include preserving current network, handoff pending, associating, verifying, connected via configured hotspot, retrying, and failed with a user-safe reason.
- The reachability probe uses a bounded timeout, requires no credentials, and sends no hotspot password or application data.
- Explicit Retry is available only for the current active session's latched failed state.

## Resolution Rules
- A verified healthy target path wins over a lid-close force request and makes the operation idempotent.
- Command dispatch success and SSID equality alone never imply internet success.
- Only a state transition or explicit Retry starts a new association episode; the polling level alone does not.

## Constraints
- Never join once per poll merely because the lid remains closed.
- Passwords flow only from Keychain into the association boundary and never into status, logs, probe requests, or evidence.
- All retries, sleeps, provider calls, and reachability checks are bounded and cancellation-aware.
- Do not claim internet from a synthetic network-name placeholder.
- No association implementation may change Wi-Fi power as a side effect.

## Implementation Routing
- Required skills: coding-research, coding-feature-execute, coding-proof-author, coding-feature-quality
