import Foundation

public enum LiveEvidenceError: Error, Equatable, Sendable {
    case invalidBinding(String)
    case invalidEvent(String)
    case capacityExceeded
    case incompleteEvidence(String)
    case unsafeArtifact(String)
}

public struct LiveEvidencePreflightInput: Sendable {
    public let machineIdentity: Data
    public let baselineBytes: Data
    public let appIdentityBytes: Data
    public let helperIdentityBytes: Data
    public let priorSSID: Data
    public let targetSSID: Data
    public let providerOrigin: String
    public let providerPublicKey: String
    public let outputDirectoryPath: Data
    public let observerUID: Data
    public let preflightPeerUID: Data
    public let directoryMode: UInt16
    public let socketMode: UInt16
    public let capability: LiveOracleProviderCapability

    public init(
        machineIdentity: Data,
        baselineBytes: Data,
        appIdentityBytes: Data,
        helperIdentityBytes: Data,
        priorSSID: Data,
        targetSSID: Data,
        providerOrigin: String,
        providerPublicKey: String,
        outputDirectoryPath: Data,
        observerUID: Data,
        preflightPeerUID: Data,
        directoryMode: UInt16 = 0o700,
        socketMode: UInt16 = 0o600,
        capability: LiveOracleProviderCapability
    ) {
        self.machineIdentity = machineIdentity
        self.baselineBytes = baselineBytes
        self.appIdentityBytes = appIdentityBytes
        self.helperIdentityBytes = helperIdentityBytes
        self.priorSSID = priorSSID
        self.targetSSID = targetSSID
        self.providerOrigin = providerOrigin
        self.providerPublicKey = providerPublicKey
        self.outputDirectoryPath = outputDirectoryPath
        self.observerUID = observerUID
        self.preflightPeerUID = preflightPeerUID
        self.directoryMode = directoryMode
        self.socketMode = socketMode
        self.capability = capability
    }
}

public struct LiveEvidenceSystemObservation: Sendable {
    public let powerSource: LiveOraclePowerSource
    public let batteryPercent: Int
    public let lidClosed: Bool
    public let sleepDisabled: Int
    public let wifiPower: Bool
    public let selectedWiFiDevice: Data
    public let ssid: Data?
    public let usableAddresses: [Data]
    public let routeRemoteAddress: Data?
    public let routeDevice: Data?
    public let appRunning: Bool
    public let appJournal: LiveOracleJournalState
    public let helperJournal: LiveOracleJournalState
    public let helperJournalAuthorizationCode: Int
    public let appIdentityBytes: Data
    public let helperIdentityBytes: Data

    public init(
        powerSource: LiveOraclePowerSource,
        batteryPercent: Int,
        lidClosed: Bool,
        sleepDisabled: Int,
        wifiPower: Bool,
        selectedWiFiDevice: Data,
        ssid: Data?,
        usableAddresses: [Data],
        routeRemoteAddress: Data?,
        routeDevice: Data?,
        appRunning: Bool,
        appJournal: LiveOracleJournalState,
        helperJournal: LiveOracleJournalState,
        helperJournalAuthorizationCode: Int,
        appIdentityBytes: Data,
        helperIdentityBytes: Data
    ) {
        self.powerSource = powerSource
        self.batteryPercent = batteryPercent
        self.lidClosed = lidClosed
        self.sleepDisabled = sleepDisabled
        self.wifiPower = wifiPower
        self.selectedWiFiDevice = selectedWiFiDevice
        self.ssid = ssid
        self.usableAddresses = usableAddresses
        self.routeRemoteAddress = routeRemoteAddress
        self.routeDevice = routeDevice
        self.appRunning = appRunning
        self.appJournal = appJournal
        self.helperJournal = helperJournal
        self.helperJournalAuthorizationCode = helperJournalAuthorizationCode
        self.appIdentityBytes = appIdentityBytes
        self.helperIdentityBytes = helperIdentityBytes
    }
}

public struct LiveEvidenceObserverEventInput: Sendable {
    public let requestSequence: Int
    public let phase: LiveProofHandshakePhase
    public let unixMilliseconds: Int64
    public let monotonicNanoseconds: UInt64
    public let scenario: ReadinessScenario?
    public let kind: LiveOracleObserverEventKind
    public let baselineBytes: Data?
    public let observation: LiveEvidenceSystemObservation?
    public let process: LiveProofProcessIdentity?
    public let failureCode: LiveEvidenceFailureCode?

    public init(
        requestSequence: Int,
        phase: LiveProofHandshakePhase,
        unixMilliseconds: Int64,
        monotonicNanoseconds: UInt64,
        scenario: ReadinessScenario?,
        kind: LiveOracleObserverEventKind,
        baselineBytes: Data? = nil,
        observation: LiveEvidenceSystemObservation? = nil,
        process: LiveProofProcessIdentity? = nil,
        failureCode: LiveEvidenceFailureCode? = nil
    ) {
        self.requestSequence = requestSequence
        self.phase = phase
        self.unixMilliseconds = unixMilliseconds
        self.monotonicNanoseconds = monotonicNanoseconds
        self.scenario = scenario
        self.kind = kind
        self.baselineBytes = baselineBytes
        self.observation = observation
        self.process = process
        self.failureCode = failureCode
    }
}

public enum LiveEvidenceFailureCode: String, Sendable {
    case observerInterrupted = "observer_interrupted"
    case controllerInterrupted = "controller_interrupted"
    case attachRejected = "attach_rejected"
    case systemObservationUnavailable = "system_observation_unavailable"
    case providerTransportFailed = "provider_transport_failed"
    case cleanupRequired = "cleanup_required"
    case safetyTerminationUsed = "safety_termination_used"
    case directRescueUsed = "direct_rescue_used"
}

public struct LiveEvidenceProviderTransportInput: Sendable {
    public let scenario: ReadinessScenario
    public let sequence: Int
    public let nonce: String
    public let dispatchUnixMilliseconds: Int64
    public let completionUnixMilliseconds: Int64
    public let localAddress: Data
    public let remoteAddress: Data
    public let beforeObserverEventSequence: Int
    public let afterObserverEventSequence: Int

    public init(
        scenario: ReadinessScenario,
        sequence: Int,
        nonce: String,
        dispatchUnixMilliseconds: Int64,
        completionUnixMilliseconds: Int64,
        localAddress: Data,
        remoteAddress: Data,
        beforeObserverEventSequence: Int,
        afterObserverEventSequence: Int
    ) {
        self.scenario = scenario
        self.sequence = sequence
        self.nonce = nonce
        self.dispatchUnixMilliseconds = dispatchUnixMilliseconds
        self.completionUnixMilliseconds = completionUnixMilliseconds
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.beforeObserverEventSequence = beforeObserverEventSequence
        self.afterObserverEventSequence = afterObserverEventSequence
    }
}

public struct LiveEvidenceObserverArtifacts: Sendable {
    public let preflight: LiveOraclePreflightReadback
    public let transport: LiveOracleProviderTransportArtifact
    public let receipts: LiveOracleProviderReceiptsArtifact
    public let events: LiveOracleObserverEventsArtifact
}

public struct LiveEvidenceControllerArtifacts: Sendable {
    public let command: LiveOracleControllerArtifact
    public let operatorEvents: LiveOracleControllerArtifact
    public let cleanup: LiveOracleControllerArtifact
}

public struct LiveEvidenceFinalizationResult: Sendable {
    public let manifest: LiveOracleSealManifest
    public let signedObserverSeal: LiveProofSignedPayload

    public init(
        manifest: LiveOracleSealManifest,
        signedObserverSeal: LiveProofSignedPayload
    ) {
        self.manifest = manifest
        self.signedObserverSeal = signedObserverSeal
    }
}

public struct LiveEvidenceObserverFinalizationResult: Sendable {
    public let observerOwnedEntries: [LiveOracleManifestEntry]
    public let observerSealEntry: LiveOracleManifestEntry
    public let signedObserverSeal: LiveProofSignedPayload

    public init(
        observerOwnedEntries: [LiveOracleManifestEntry],
        observerSealEntry: LiveOracleManifestEntry,
        signedObserverSeal: LiveProofSignedPayload
    ) {
        self.observerOwnedEntries = observerOwnedEntries
        self.observerSealEntry = observerSealEntry
        self.signedObserverSeal = signedObserverSeal
    }
}
