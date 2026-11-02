# Transactional Travel Mode session restoration

## Summary
Make every Travel Mode activation an owned, durable, and recoverable transaction so the app cannot report Off until its mandatory app-owned power state has been restored and its privileged sleep-override lease has been released and verified. Prior Wi-Fi association is recoverable context, but remains bounded best effort rather than mandatory Off state.

## Desired Behavior
- Travel Mode exposes the lifecycle states `off`, `preparing`, `active`, `restoring`, and `cleanup_required`; only verified restoration may transition to `off`.
- Before any app-owned system mutation, `preparing` captures Wi-Fi power state and the currently associated network when available, assigns a unique session ID, persists the app journal, and reads it back successfully.
- Before each later app-owned Wi-Fi power or association command, the session persists and reads back a write-ahead mutation intent containing a unique operation ID, captured baseline, target, and phase. After dispatch, observed state is verified and the completed operation is persisted before the intent may be retired.
- Before helper acquisition, the app persists a unique lease request ID. The helper response binds that request to the session, helper-issued lease ID, and helper generation; the app persists and reads back only that binding and status receipt. The helper alone captures and owns the original lid-sleep override.
- Activation fails without changing the system when required state cannot be read or durably journaled.
- Stop restores the exact captured Wi-Fi power value, makes a bounded best-effort attempt to reassociate the captured prior network when Travel Mode changed association and a prior network was captured, then releases the helper lease. Off requires mandatory Wi-Fi power read-back and a verified released lease receipt; network reassociation failure remains visible but does not strand mandatory power cleanup.
- A Stop or Quit request with no owned active or recovery journal performs no power mutation.
- Every restoration or lease-release operation returns a structured result and is followed by read-back verification. Partial failure retains the app journal and lease identity, enters `cleanup_required`, and exposes a retryable error.
- Startup recovery completes or reaches `cleanup_required` before a new Start can begin. Concurrent Start, Stop, Quit, and recovery requests are serialized by session ID.
- Recovery treats every incomplete mutation intent as possibly applied: it reads current state, restores the captured baseline when required, and never clears recovery ownership merely because the command outcome was interrupted or is unknown.
- Quit during `preparing` records termination intent, cancels cancellable activation work, reconciles any uncertain helper acquisition and app-owned mutation intent, and terminates only after clean Off. Failed compensation leaves the app alive in `cleanup_required`.
- Unexpected process death may leave app-owned Wi-Fi state pending while the app is absent. The durable journal owns eventual Wi-Fi recovery on the next launch; immediate sleep-override restoration while the app is absent belongs to `crash-safe-sleep-override-lease`.
- Settings the app does not change are neither restored nor overwritten.

## Scope
- Session state, durable app journal, exact app-owned capture and restoration, helper-lease coordination, read-back verification, transition serialization, and recovery ownership.
- Wi-Fi power is mandatory restoration state when Travel Mode changed it. The prior associated network is app-owned recovery context and is restored on a bounded best-effort basis when Travel Mode changed association.

## Non-Goals
- Reading, changing, or journaling the lid-sleep baseline; that belongs exclusively to `crash-safe-sleep-override-lease`.
- Restoring Wi-Fi power or association immediately while the app process is absent.
- Hotspot discovery, lid-triggered failover, or menu-bar presentation.
- Restoring an entire `pmset` profile that Travel Mode did not mutate.

## Scenarios
- Helper lease acquisition succeeds and returns an active receipt; Stop does not become Off until release returns a verified restored receipt.
- Wi-Fi originally off is enabled for Travel Mode and returns to off after verified cleanup.
- Wi-Fi originally on and associated to another preferred network is switched to the iPhone, then reassociated to the captured network when it remains available.
- The captured prior network is unavailable at Stop; mandatory power and helper cleanup still complete, while the cleanup result reports that reassociation was not completed.
- Wi-Fi was on but unassociated before Start; cleanup restores mandatory power and helper state but does not manufacture a network association or require disassociation from the Travel Mode network before Off.
- Snapshot read or persistence fails; activation remains off and no privileged command runs.
- One restore step fails; independent cleanup is still attempted, the journal remains, and the app reports `cleanup_required` rather than Off.
- A stale session tries to clear a newer journal; the session mismatch is rejected.
- The app exits after intent persistence, after command dispatch, after verification, or before completion recording; relaunch resolves the pending operation and restores from the captured baseline.
- Quit arrives while capture, helper acquisition, app mutation, or mutation verification is pending; activation is cancelled or compensated and termination waits for verified Off.

## External Contract
- Lifecycle state is one of `off`, `preparing`, `active`, `restoring`, or `cleanup_required`.
- The app journal contains a session ID, phase, captured app-owned values, write-ahead operation IDs and phases, owned mutations, helper lease request/lease IDs, helper generation/status, termination intent, creation time, and last cleanup failure without secrets.
- Start succeeds only after app-state capture, durable read-back, helper lease acquisition, and verification of any app-owned mutation required for activation; when Wi-Fi already matches the required activation state, Start does not manufacture a mutation.
- Stop returns a cleanup result that distinguishes mandatory restoration failure from a non-blocking prior-network reassociation warning. Menu-bar presentation of that structured result belongs to `safe-menu-bar-lifecycle`.

## Resolution Rules
- The app journal is authoritative for app-owned mutations and the helper lease ID. The helper journal is authoritative for the lid-sleep override; current global state alone proves neither.
- After helper owner-death cleanup, only a helper-issued verified release receipt matching the app journal's exact session, lease request, lease, and generation may satisfy lease release; the app never infers release from global power state. The app acknowledges that receipt only after its own journal is durably cleared.
- A session may clear only its own journal.
- Off certifies exact mandatory Wi-Fi power restoration and verified helper release; it does not certify restoration of the prior Wi-Fi association.
- Mandatory power restoration failure blocks Off. A failed best-effort network reassociation is retired after its bounded attempt and does not redefine power cleanup success or retain recovery ownership.

## Constraints
- Do not persist the helper's original lid-sleep baseline, hotspot passwords, administrator credentials, shell output containing secrets, or environment values in the app journal.
- Do not restore `sleep`, `ttyskeepawake`, or other power keys unless the implementation actually mutates them and journals their original values.
- Recovery must be idempotent across repeated launches and repeated Stop requests.
- Never dispatch an app-owned mutation from an in-memory-only intent, and never clear a pending intent from command exit status alone.

## Implementation Routing
- Required skills: coding-feature-execute, coding-proof-author, coding-feature-quality
