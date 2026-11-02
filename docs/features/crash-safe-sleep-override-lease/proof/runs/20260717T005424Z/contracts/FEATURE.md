# Crash-safe lid-sleep override lease

## Summary
Move the persistent lid-closed sleep override behind an app-bundled `SMAppService` LaunchDaemon and connection-owned XPC lease so the exact original value is restored after normal Stop, Quit, app crash, force-quit, helper restart, lost response, or stale-session recovery.

## Desired Behavior
- Lease acquisition accepts the app's durably recorded session and lease request IDs and executes this order: read the exact original `SleepDisabled` value; persist and read back a `prepared` helper journal; issue only the fixed all-power-source `disablesleep` write when needed; observe the target value; persist and read back `applied` then `active`; only then return an active helper-issued lease ID and generation bound to that request. The filesystem write and external power command are deliberately separate write-ahead steps, not one atomic operation.
- Production uses a macOS 13+ `SMAppService` LaunchDaemon with a privileged Mach service. The helper accepts only an app connection satisfying the expected app identifier and the helper's own signing team; the app applies the reciprocal helper requirement. The helper derives the caller principal and connection lifetime from XPC, never from request data.
- Definitive pre-dispatch registration, approval, peer-authentication, or connection rejection produces zero helper mutation and may return the app to Off. Once an acquire request may have reached the helper, the app retains its journal in `cleanup_required` until an authenticated helper returns the exact active or released binding, or authoritatively reports that the persisted session/request was never accepted. Transport unavailability and authorization failure are never represented as not-found.
- If the original value is already enabled, acquisition records that fact and performs no initial write. The lease still owns only `SleepDisabled` for its lifetime; release or owner-death cleanup reads it back and restores the captured enabled value if external drift changed it.
- Normal Stop and Quit release the lease and verify restoration before cleanup is reported complete.
- Unexpected app disconnect, client PID death, force-quit, helper restart with a stale lease, or interruption between mutation and acquisition response triggers restoration from the helper-owned journal.
- After verified restoration, the helper durably writes and reads back an immutable released receipt for the exact session ID, lease request ID, lease ID, and acquisition generation before it removes the active helper journal. The receipt confirms restoration without exposing the original `SleepDisabled` value.
- The helper journal has explicit `prepared`, `applied`, `active`, `restoring`, `restored`, and `receipt_committed` phases plus `cleanup_required`. Startup reconciliation treats every pre-receipt phase as possibly applied, observes current state, and restores the captured baseline. A matching committed receipt plus journal authorizes journal removal without a duplicate power write; a mismatch or corrupt record blocks new acquisition in `cleanup_required`.
- Production stores the active journal at `/Library/Application Support/com.codex.travelmode/SleepOverrideLease/active-lease.json` and receipts below the sibling `released-receipts` directory. The root helper creates directories as `root:wheel` mode `0750` and files mode `0600`, rejects symlinks/non-root ownership/unsafe modes, and uses atomic replacement plus immediate decode/read-back. The journal carries schema version, monotonic revision, full binding, server-observed principal, baseline, changed flag, lifecycle phase, pending fixed operation, timestamps, and last failure; updates use exact revision CAS. Receipts carry no baseline.
- Acquisition is idempotent by session and lease request ID; status, cleanup retry, and release are idempotent by the resulting exact binding. Generation is unique per acquisition and stable across helper restart and recovery. Exactly one Travel Mode lease may own the override at a time.
- Released receipts are keyed by the full binding and retained independently, so an unacknowledged older receipt is neither overwritten by nor blocks a later lease. Only an exact acknowledgement from the same authenticated principal may retire one receipt.
- Connection invalidation schedules restoration immediately. With a healthy fixed power backend, owner-death cleanup must produce a verified released receipt within five seconds. On failure the helper persists `cleanup_required` within two seconds and retries automatically after 250 ms, 500 ms, 1 s, then at a capped 2 s interval while alive, without changing the baseline. An authenticated `retry-cleanup` request bypasses the delay but uses the same serialized operation. Production uses a monotonic clock; proof injects a deterministic clock/backoff driver.
- Helper interruption, invalidation, or restart while the app still considers Travel Mode Active revokes Active, stops Travel Mode work, and drives verified recovery or `cleanup_required`; the UI may not continue reporting Active after helper protection is lost.
- Production has no direct unleased `pmset` fallback. Unsigned development runs, unapproved helpers, and unavailable helpers fail closed.

## Scope
- The sole production owner for reading, changing, journaling, and restoring the persistent lid-sleep override.
- The unprivileged app coordinates the lease but does not issue competing override commands.

## Non-Goals
- Wi-Fi power or association restoration while the app is absent.
- Hotspot configuration, failover policy, or menu-bar presentation.
- Thermal monitoring or a claim that closed-lid operation is safe in an enclosed space.

## Scenarios
- Original override is disabled: acquire enables it; clean release restores disabled.
- Original override is enabled: acquire and release preserve enabled.
- The app is killed while the lease is active: the helper observes owner death and restores the baseline.
- The helper restarts with an orphaned journal: it restores before accepting another lease.
- The helper restores after owner death while the app is absent: a recovering app later obtains the exact released receipt for its recorded session and lease and can finish app-owned cleanup.
- The helper disappears while the app remains alive: the app revokes Active immediately, stops the polling/failover loop, and recovers from exact helper state rather than silently continuing.
- Registration or peer authentication fails before request dispatch: the app remains Off and the helper records zero mutation. A connection drops after possible dispatch: the app remains `cleanup_required` until exact resolution.
- A stale or different session requests release: the request is rejected without changing power state.
- A stale session presents another lease's released receipt: status rejects the mismatch and does not authorize Off or another mutation.
- Mutation succeeds but verification fails: acquisition fails and compensating restoration runs from the durable record.

## External Contract
- The privileged boundary supports narrowly scoped acquire, resolve, status, release, acknowledge-release, and retry-cleanup operations with session, lease request, lease, and generation identifiers plus structured outcomes.
- Status distinguishes unavailable, acquiring, active, restoring, cleanup required, and released.
- Resolve distinguishes authoritative not-found from unavailable or unauthenticated transport. Not-found is valid only from a reachable authenticated helper for the exact persisted session/request.
- Released status is backed by the exact durable receipt, not inferred from current global state. The helper retains an unacknowledged receipt; only a matching authenticated acknowledgement issued after app-journal cleanup may retire it.
- The helper accepts only the fixed sleep-override operation; it is not a general shell-command runner.

## Constraints
- Authenticate both XPC peers with identifier-and-team code-signing requirements and apply least privilege. The helper also binds the server-observed effective user ID into its caller principal.
- Bind owner death to invalidation of the accepted authenticated XPC connection; the typed production interface exposes no caller-supplied PID, principal, command, power key, or executable-path parameter.
- Persist no credentials, hotspot passwords, arbitrary commands, or unrelated system state.
- Do not return the captured original `SleepDisabled` value to the unprivileged app or include it in the app journal.
- Modify no power key other than the owned lid-sleep override.
- Restore the captured original value, never an unconditional default.
- The supported packaged app must fail closed when the helper is unavailable; development runs may not silently claim crash protection.
- Never clear the active helper journal before its matching verified release receipt is durably readable; startup reconciliation must resolve an interrupted journal-to-receipt transition idempotently.
- Persist released receipts separately by full binding. A newer acquisition may not overwrite an older receipt, and acknowledgement may remove only the same-principal exact receipt.

## Implementation Routing
- Required skills: coding-research, coding-feature-execute, coding-proof-author, coding-feature-quality
