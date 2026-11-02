# Reliable iPhone hotspot configuration

## Summary

Let the user discover or enter the intended hotspot and save one coherent, crash-recoverable SSID/device/credential revision without private macOS tools, fabricated defaults, or partial Keychain/settings state.

## Desired Behavior

- Production discovery uses public CoreWLAN interfaces vended by one long-lived `CWWiFiClient`. It reads remembered profiles from `CWConfiguration.networkProfiles` and performs the blocking visible-network scan on a serialized non-`MainActor` boundary.
- A user-initiated refresh may request When-In-Use location authorization. The packaged app contains the required location usage descriptions and keeps `not_determined`, `denied`, `restricted`, `services_disabled`, `no_wifi_interface`, `provider_failed`, and `completed` outcomes distinct.
- Discovery returns a snapshot containing remembered networks, visible networks, and visible-scan status. Remembered networks remain selectable when visible scanning is denied or fails.
- A scan that returns one or more network objects but no readable SSIDs maps deterministically to `denied`, never an `empty` success. Nil, undecodable, and zero-length SSIDs are excluded.
- Discovery loading is visible, the UI remains responsive, and only one provider scan runs at a time. A refresh generation prevents an older completion from replacing newer results or a manual edit.
- SSIDs are exact, case-sensitive identifiers. A supported manual or provider SSID is 1 through 32 UTF-8 bytes; it is never trimmed, normalized, or case-folded. The saved SSID appears first, remembered networks retain provider order, visible networks use deterministic UTF-8 byte order, and only exact duplicates are removed.
- A fresh installation has no fabricated SSID and no automatic selection. The user explicitly chooses a discovered value or enters a manual value.
- The editor is a draft. Discovery, selection, manual SSID, password, and Wi-Fi device drafts never change the active configuration until Save commits a validated revision.
- Manual SSID entry and Save remain usable when scanning is empty, denied, unsupported, or failed. Provider error strings, authorization messages, and missing-executable text never become selectable networks.
- A valid committed selection remains visible and Start-eligible when it is absent from discovery or a later refresh fails.
- Only a validated committed `HotspotConfigurationRevision` is Start-eligible. Start snapshots that committed revision and its credential reference; unsaved edits and later discovery cannot change a preparing or active session.
- Save and Start are mutually exclusive. A second Save is rejected while one is in flight, and discovery/edit/save controls are locked while the authoritative session lifecycle is Preparing, Active, Restoring, or Cleanup Required.
- Popover dismissal does not cancel a Save. Normal Quit waits for the current save operation to reach a coherent boundary; forced process death is reconciled on the next launch.
- After a successful Save, the password draft is cleared. Passwords are preserved exactly and are never trimmed, logged, displayed after save, or persisted outside the Keychain boundary.
- A blank password may retain the current immutable credential reference only when the draft SSID exactly matches the committed SSID. This path stages no new credential and may commit a new non-secret revision for a changed Wi-Fi device. A fresh configuration or changed SSID requires a nonempty password and a new credential reference.

## Committed Revision Contract

- The active pointer is one schema-versioned record containing `schema_version`, `revision_id`, exact `ssid`, nullable `wifi_device`, and an opaque immutable `credential_reference`. A nonempty Wi-Fi device must match `[A-Za-z0-9][A-Za-z0-9._-]{0,31}`; a missing device is a coherent saved hotspot but is not Start-eligible.
- The active pointer and save journal live below the app's Application Support configuration directory. Each record is written by atomic replacement and accepted only after decode plus canonical read-back verification.
- The save journal is schema-versioned and records the prior pointer, candidate pointer, and one of `prepared`, `credential_staged`, `pointer_committed`, or `cleanup_pending` before the corresponding irreversible boundary.
- A credential-updating Save persists `prepared`, stages a new Keychain credential under an immutable generated reference, reads it back exactly, persists `credential_staged`, atomically commits and verifies the active pointer, then cleans credentials that are proven unreferenced. An exact same-SSID blank-password Save records reuse of the active credential reference and advances directly from `prepared` to pointer commit.
- If pointer commit reports failure, Save reads the active pointer. An exact candidate pointer means the new revision committed; any other valid pointer means the prior revision remains active and the candidate credential is unreferenced.
- Startup recovery uses the same pointer comparison. It resolves to either the prior coherent revision or the fully committed candidate, never a partial pair.
- Recovery may delete only a credential reference that differs from the active pointer and is named by the durable save journal. Cleanup failure retains `cleanup_pending` for retry and never invalidates the coherent active revision. Start remains allowed when that active revision validates, but another Save must first retry cleanup and is rejected while `cleanup_pending` remains so the only orphan record cannot be overwritten.
- Keychain not-found, inaccessible/locked, denied, corrupt data, stage failure, verification failure, and deletion failure remain typed failures. Activation validates that the active credential reference exists and returns a nonempty exact password before Start proceeds.
- Keychain reads are allowed only for migration, save verification, startup or Start eligibility validation, and actual association. Rendering and discovery refresh perform zero secret reads.
- On first launch after upgrade, an existing explicit legacy `fallbackHotspotSSID` plus readable legacy `fallbackHotspotPassword` is migrated through the same transaction. A syntactically valid legacy `wifiDevice` is copied; a missing or invalid device becomes null and leaves the migrated hotspot saved but Start disabled until public discovery supplies a valid device and the user saves. Incomplete or unreadable SSID/credential state is left intact, creates no new active revision, and requires the user to resave.

## Scope

- Public Wi-Fi discovery and permission-state mapping.
- Hotspot selection and manual entry.
- Draft versus committed configuration state.
- Revisioned settings/Keychain save, recovery, migration, and lifecycle locking.

## Non-Goals

- Joining the hotspot, verifying internet, changing Wi-Fi power, or restoring a travel session.
- Automatically identifying an iPhone from SSID wording.
- Proving live RF visibility, a real location prompt, or a real Keychain prompt; supervised readiness owns those live edges.

## Scenarios

- Remembered `Office` and visible `Office`, `office`, and `Example iPhone` produce exact deterministic options with only the byte-identical duplicate removed and no implicit selection.
- Location authorization is not determined, denied, restricted, or disabled: the matching actionable state appears, remembered values remain selectable, and manual entry remains enabled.
- CoreWLAN has no interface or throws: a typed unavailable/failure state appears and raw error text is not an option.
- A saved iPhone is temporarily invisible or refresh later fails: the committed selection and Start eligibility remain.
- Manual save after denied discovery commits the exact SSID/password pair even without a Wi-Fi interface; reopen shows the SSID and an empty password field, while Start becomes valid only after the revision also contains a syntactically valid Wi-Fi device.
- Keychain staging or verification fails: the prior revision remains active; a fresh store remains without an active revision.
- Pointer persistence fails after credential staging: read-back resolves whether the candidate committed, and any proven orphan is cleaned immediately or during launch recovery.
- The process dies before credential staging, after verified staging, after pointer commit, or during old-credential cleanup: recovery yields exactly one coherent active revision.
- Save races Start, a second Save, a stale refresh completion, or each non-Off lifecycle: only the serialized allowed operation changes state.

## External Contract

- `HotspotDiscovering` returns a typed snapshot including the public interface name, remembered networks, visible networks, and scan status, never a bare list synthesized from command output.
- `TravelModeAppState` exposes a typed discovery/UI state, exact draft fields, committed configuration state, save-in-flight state, and authoritative configuration lock.
- `TravelSettingsStoring` loads and validates only the active revision, stages credentials by opaque reference, recovers an interrupted save, and returns typed save/recovery outcomes.
- `TravelModeEngine` receives a committed runtime snapshot and an exact password provider; it never reads draft state.

## Resolution Rules

- The active pointer is the commit point and sole owner of Start eligibility.
- An unsaved draft disables Start rather than silently running either the draft or a surprising prior value.
- A saved explicit SSID takes precedence in presentation but refresh never rewrites either the saved value or the manual draft.
- A later refresh result is applied only if its generation is current.
- Failed orphan cleanup is retryable maintenance, not permission to roll back or discard the active revision.

## Acceptance Criteria

1. Public typed discovery and authorization: production has no private `airport` reference, uses serialized CoreWLAN discovery off `MainActor`, and distinguishes every frozen discovery state while retaining remembered partial results.
2. Exact selection and draft isolation: exact-byte ordering/de-duplication, manual entry, no fabricated default, no silent normalization, and an unsaved draft can never affect Start or runtime.
3. Coherent save: revision-specific Keychain staging, exact verification, atomic pointer read-back, and prior-state retention pass for fresh and replacement saves.
4. Crash recovery: real process death at each durable boundary resolves to the prior or candidate coherent revision and never deletes an active credential.
5. Secret confinement and migration: passwords remain exact and Keychain-only, render/refresh perform zero reads, failure categories remain typed, and complete legacy state migrates without silent loss.
6. Concurrency and lifecycle lock: loading generations, double Save, Save/Start, Quit/save, and every non-Off lifecycle serialize without partial state or stale UI overwrite.
7. Native UI behavior: loading, results, empty, permission, unavailable, manual, error, saved, and locked states are observable in the built proof app; a valid committed configuration remains Start-eligible after discovery failure.

## Constraints

- Do not invoke, embed, or parse the private `airport` executable or Apple80211 private framework paths.
- Do not persist passwords in UserDefaults, files, traces, screenshots, logs, or committed configuration records.
- Do not use multi-key UserDefaults writes as the active transaction boundary.
- Reuse the session coordinator's authoritative lifecycle for configuration locking.

## Implementation Routing

- Required skills: coding-research, coding-feature-execute, coding-proof-author, coding-feature-quality
