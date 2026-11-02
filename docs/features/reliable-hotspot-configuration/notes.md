# Architecture research

## 2026-07-17 public macOS Wi-Fi boundary

Apple documents CoreWLAN as the public framework for querying Wi-Fi interfaces and choosing networks. Production discovery will retain one `CWWiFiClient.shared()` instance, obtain `CWInterface` objects from that client, read remembered profiles from `CWConfiguration.networkProfiles`, and call the throwing broadcast scan off `MainActor` because Apple documents that `scanForNetworks` blocks for the duration of the scan. Sources: [Core WLAN](https://developer.apple.com/documentation/corewlan), [CWWiFiClient](https://developer.apple.com/documentation/corewlan/cwwificlient), [CWInterface](https://developer.apple.com/documentation/corewlan/cwinterface), [scanForNetworks](https://developer.apple.com/documentation/corewlan/cwinterface/scanfornetworks(withssid:)), and [networkProfiles](https://developer.apple.com/documentation/corewlan/cwconfiguration/networkprofiles).

Wi-Fi identifiers can be privacy-sensitive. Apple requires a usage description before requesting location authorization and describes `notDetermined`, authorized, denied, and restricted handling through `CLLocationManager`. The built app will request authorization only after a user-initiated refresh, keep permission and provider failures typed, and include both the When-In-Use and macOS location usage descriptions. Source: [Requesting authorization to use location services](https://developer.apple.com/documentation/corelocation/requesting-authorization-to-use-location-services).

Repo implication: the private Apple80211 `airport` executable, command-error parsing, and the `iPhone` default are removed. Public discovery returns remembered networks and visible-scan status separately, so useful remembered values survive denied or failed scanning.

# Contract revision

## 2026-07-17 quality and proof repair

The initial feature direction was correct but not implementation-safe. It did not define the permission/no-interface/nil-SSID states, allowed draft fields to alias Start/runtime settings, left the durable save record and ambiguous commit outcome unspecified, and treated screenshots plus driver-authored PASS booleans as primary evidence.

The repaired contract freezes exact case-sensitive SSID identity, a draft/committed split, one schema-versioned active pointer, a write-ahead save journal, revision-specific Keychain staging and read-back, authoritative pointer resolution after uncertain commits, cleanup of only proven-unreferenced credentials, complete legacy migration, serialized refresh/save/start/quit behavior, and locks for every non-Off session lifecycle. Passwords are exact values and are never trimmed.

The proof is now a native rendered-UI plus real subprocess recovery proof. A separate PID is killed at each production transaction boundary; a new PID must recover the same temporary production store. The oracle consumes raw revisions, redacted provider operations, process IDs/signals, control snapshots, and realistic PNGs. It rejects producer-authored verdict/check fields and scans all captured artifacts for a password sentinel outside the excluded fake-Keychain vault.

This contract repair is intentionally broader than replacing one scanner call: without the draft boundary and durable configuration transaction, a failed save or unsaved edit could still make Start use an SSID whose credential belongs to a different revision.

## Proof-first failing baseline

After the contract and runner were strengthened, the primary proof failed immediately against the current production tree with `Private Wi-Fi discovery path is still referenced by production sources.` The source guard found the Apple80211 private `airport` path in `LocalTravelCommandGateway`; the missing native proof assets and transactional configuration scenarios remain red behind that first failure. Implementation starts from this executable contract failure.

## 2026-07-17 implementation and adversarial audit

Production discovery now uses the public CoreWLAN/Core Location boundary and returns Data-backed `WiFiSSID` values. A later audit found that ordinary Swift `String` equality treats canonically equivalent Unicode spellings as equal, which was too weak for the frozen exact-byte contract. The implementation therefore keeps UTF-8 identity through option IDs, UI selection, draft comparison, blank-password credential reuse, revision equality, pointer read-back, and password verification. Composed and decomposed SSID/password regressions prevent silent normalization.

The settings boundary now treats the active revision as the only committed configuration. Incomplete legacy values are exposed only as an editable draft. Start reserves lifecycle ownership before its first suspension, loads the active revision and that exact credential reference once, and keeps the SSID/device/password runtime snapshot in memory until Stop or recovery. Save, Start, Quit, refresh generations, unknown/non-Off lifecycle state, double Save, cleanup-pending retry, and both Quit race directions are covered by focused regressions.

Ambiguous pointer writes distinguish an authoritative non-candidate read-back from an unavailable read-back. The unavailable case leaves the staged journal intact for a new process to resolve, avoiding deletion of a credential whose pointer may actually have committed. Cleanup failure reloads an already committed candidate for Start while preserving the cleanup journal and retrying it before a later Save.

Keychain not-found, locked/unavailable, denied, corrupt, stage, exact-verification, and deletion outcomes stay typed through active loading and legacy migration. Legacy access failures preserve the legacy defaults and credential rather than converting them to a missing configuration.

The final proof package compiles the production SwiftUI menu into an isolated native proof app, renders the loading, discovery, manual, saved, and lifecycle states, and records exact option bytes plus decoded PNGs. A separate packaged worker uses the production file transaction with a durable redacted credential boundary. The outer driver injects declared provider/persistence faults, sends real `SIGKILL` signals at four journal boundaries, launches distinct recovery PIDs, merges only raw observations into `provider-readback.json`, and leaves all plaintext proof credentials below the excluded `private` vault roots.

The first full-repository gate exposed two older proof fixtures that still provided only the legacy settings API. Production correctly refused to start because no authoritative active revision existed. The fixtures now return stable active revisions through the current settings-store contract; the lease process suite and the transactional production-wiring scenario pass without weakening active-pointer authority.

## 2026-07-17 evaluator repair loop

The first independent evaluation rejected the otherwise green proof. The crash driver backgrounded a Bash function and recorded that wrapper PID, while the checkpoint marker came from a different Swift worker PID; the oracle did not compare them. The native UI proof also derived enabled states from proof-only formulas and captured only two of the required rendered states, and the primary artifact omitted the claimed double-Save, Save/Start, and Quit/save races.

The repaired proof must launch the Swift worker directly, require the checkpoint marker and every pre-crash operation to carry that exact PID, reap that same child after `SIGKILL`, and verify it is gone before recovery. It must read enabled state and visible text from the actual rendered production controls across every required UI state, and it must include raw primary-artifact race scenarios for the three serialization boundaries. The feature contract is unchanged; this is an explicit proof-strengthening repair after a false-green evaluator result.

The UI repair activates the proof app's own AX tree in-process, which exposes the lazily created SwiftUI accessibility elements without a system permission prompt. The artifact now records real roles, labels, protected values, identifiers, enabled state, frames, source classes, and visible messages from the rendered production view, backed by nine state-specific screenshots. New gated scenarios exercise double Save, Save-first/Start, Save-first/Quit, and Quit-first mutation rejection through real `TravelModeAppState` calls. The crash driver now launches and reaps the Swift worker directly and cross-checks its PID against both checkpoint and operation trace before recovery begins.
