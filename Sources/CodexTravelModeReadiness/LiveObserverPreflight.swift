import CodexTravelModeCore
import Darwin
import Foundation

struct LiveObserverPreparedPreflight: Sendable {
    let facts: LiveObserverPreflightBindingFacts
    let configuration: LiveProofProviderConfiguration
    let appBundleURL: URL
    let helperExecutableURL: URL
    let wifiDevice: String
    let targetSSIDDigest: String
    let observed: LiveObservedPreflightFacts
    let capability: LiveProviderCapabilityObservation
    let evidenceInput: LiveEvidencePreflightInput
    let evidenceObservation: LiveEvidenceSystemObservation
}

protocol LiveObserverPreflightInspecting: Sendable {
    func inspect(
        context: LiveObserverPreflightContext,
        runID: String,
        outputURL: URL
    ) throws -> LiveObserverPreparedPreflight
}

struct ProductionLiveObserverPreflightInspector:
    LiveObserverPreflightInspecting, Sendable {
    func inspect(
        context: LiveObserverPreflightContext,
        runID: String,
        outputURL: URL
    ) throws -> LiveObserverPreparedPreflight {
        let foundation = try validatedFoundation(context: context, runID: runID)
        let runtime = try validatedRuntime(foundation)
        let evidence = try makeEvidence(
            foundation: foundation,
            runtime: runtime,
            outputURL: outputURL
        )
        let facts = try makeFacts(
            context: context,
            foundation: foundation,
            runtime: runtime
        )
        try LivePlatformExactProcessInspector(resolver: foundation.processResolver)
            .requireNoAppProcess(bundleURL: foundation.appURL)
        return LiveObserverPreparedPreflight(
            facts: facts,
            configuration: foundation.configuration,
            appBundleURL: foundation.appURL,
            helperExecutableURL: foundation.helperURL,
            wifiDevice: foundation.wifiDevice,
            targetSSIDDigest: facts.targetSSIDDigest,
            observed: runtime.observed,
            capability: runtime.capability,
            evidenceInput: evidence.input,
            evidenceObservation: evidence.observation
        )
    }

    private func validatedFoundation(
        context: LiveObserverPreflightContext,
        runID: String
    ) throws -> LiveObserverPreflightFoundation {
        guard context.schema == "codex-travel-mode-observer-preflight-context/v1",
              context.requestSequence == 1,
              context.appBundlePath.hasPrefix("/"),
              context.helperExecutablePath.hasPrefix("/") else {
            throw ReadinessHarnessError.receiptRejected("invalid preflight context")
        }
        let configuration = try LiveProofProviderConfiguration.decodeCanonical(
            context.providerConfiguration
        )
        let appURL = URL(fileURLWithPath: context.appBundlePath).standardizedFileURL
        let helperURL = URL(
            fileURLWithPath: context.helperExecutablePath
        ).standardizedFileURL
        let processResolver = LivePlatformProcessResolver()
        try LivePlatformExactProcessInspector(resolver: processResolver)
            .requireNoAppProcess(bundleURL: appURL)
        let codeInspector = LivePlatformSecCodeIdentityInspector(
            processResolver: processResolver
        )
        let signing = try LiveObservedProductionCodeSigningValidator(
            inspector: codeInspector
        ).validate(
            appBundleURL: appURL,
            embeddedHelperURL: helperURL
        )
        let appIdentity = signing.app
        let runner = LiveObservedFixedCommandRunner()
        let prerequisites = LiveObservedReadinessPrerequisiteProbe(runner: runner)
        let portableMac = try prerequisites.portableMacIdentity()
        guard try prerequisites.isCodexRunning() else {
            throw ReadinessHarnessError.readinessBlocked(
                "Codex must remain running for the live proof"
            )
        }
        guard let active = try FileHotspotConfigurationStore().loadActive(),
              let wifiDevice = active.wifiDevice else {
            throw ReadinessHarnessError.readinessBlocked(
                "a committed hotspot target and Wi-Fi device are required"
            )
        }
        return LiveObserverPreflightFoundation(
            runID: runID,
            configuration: configuration,
            appURL: appURL,
            helperURL: helperURL,
            processResolver: processResolver,
            appIdentity: appIdentity,
            runner: runner,
            portableMac: portableMac,
            active: active,
            wifiDevice: wifiDevice,
            salt: Data(runID.utf8)
        )
    }

    private func validatedRuntime(
        _ foundation: LiveObserverPreflightFoundation
    ) throws -> LiveObserverPreflightRuntime {
        let probe = LiveObservedSystemProbe(redactionSalt: foundation.salt)
        let observed = try probe.preflight(
            wifiDevice: foundation.wifiDevice,
            appProcessAbsent: true
        )
        guard observed.battery.source == .battery,
              observed.battery.percent >= 20,
              !observed.lidClosed,
              !observed.sleepDisabled,
              observed.wifiPowered,
              !observed.usableAddresses.isEmpty,
              observed.defaultRouteDevice == foundation.wifiDevice else {
            throw ReadinessHarnessError.readinessBlocked(
                "preflight requires battery power >=20%, open lid, normal sleep, "
                    + "powered Wi-Fi, and a usable selected default interface"
            )
        }
        guard try KeychainPasswordStore().passwordExists(
            account: foundation.active.credentialReference
        ) else {
            throw ReadinessHarnessError.readinessBlocked(
                "the committed hotspot credential is unavailable"
            )
        }
        try LivePlatformAccessibilityReadiness(
            reader: LivePlatformAccessibilityTrustReader()
        ).requireTrusted()
        let registeredHelperPID = try LiveObservedHelperRegistrationReader(
            runner: foundation.runner
        ).runningPID()
        let codeInspector = LivePlatformSecCodeIdentityInspector(
            processResolver: foundation.processResolver
        )
        _ = try LiveObservedHelperIdentityValidator(inspector: codeInspector).validate(
            runningPID: registeredHelperPID,
            embeddedHelperURL: foundation.helperURL,
            appTeamIdentifier: foundation.appIdentity.teamIdentifier
        )
        let provider = ProductionLiveObserverProviderCommandPerformer(
            configuration: foundation.configuration
        )
        guard case .capability(let capability) =
            try provider.performObserved(.capability) else {
            throw ReadinessHarnessError.providerFailed(
                "provider capability observation was unavailable"
            )
        }
        let appHash = try LiveControllerSystem.sha256File(
            foundation.appIdentity.executableURL
        )
        let helperHash = try LiveControllerSystem.sha256File(foundation.helperURL)
        let priorSSID = try LiveObservedSystemParsers.ssid(
            try successfulOutput(
                .wifiSSID(device: foundation.wifiDevice),
                runner: foundation.runner
            )
        )
        guard !foundation.active.hasExactSSID(priorSSID) else {
            throw ReadinessHarnessError.readinessBlocked(
                "the prior Wi-Fi network must differ from the committed hotspot target"
            )
        }
        let rawAddresses = try LiveObservedSystemParsers.usableInterfaceAddresses(
            try successfulOutput(
                .interface(device: foundation.wifiDevice),
                runner: foundation.runner
            ),
            device: foundation.wifiDevice
        )
        let helperJournal = try LiveObservedHelperJournalReader(
            runner: foundation.runner
        ).observe()
        let appJournal = LivePlatformAppJournalReader().presence()
        guard helperJournal == .absent, appJournal == .absent else {
            throw ReadinessHarnessError.readinessBlocked(
                "preflight requires both app and helper journals to be absent"
            )
        }
        return LiveObserverPreflightRuntime(
            observed: observed,
            capability: capability,
            appHash: appHash,
            helperHash: helperHash,
            priorSSID: priorSSID,
            rawAddresses: rawAddresses,
            appJournal: appJournal
        )
    }

    private func makeEvidence(
        foundation: LiveObserverPreflightFoundation,
        runtime: LiveObserverPreflightRuntime,
        outputURL: URL
    ) throws -> (
        input: LiveEvidencePreflightInput,
        observation: LiveEvidenceSystemObservation
    ) {
        let oracleCapability = LiveOracleProviderCapability(
            capabilityPath: runtime.capability.capability.capabilityPath,
            submitPath: runtime.capability.capability.submitPath,
            readbackPath: runtime.capability.capability.readbackPath,
            serverUnixMilliseconds: runtime.capability.capability.serverUnixMilliseconds,
            clockOffsetMilliseconds: runtime.capability.serverMinusLocalMilliseconds,
            maximumClockSkewSeconds:
                runtime.capability.capability.maximumClockSkewSeconds
        )
        let identityBytes = Data(runtime.appHash.utf8)
        let helperIdentityBytes = Data(runtime.helperHash.utf8)
        let canonicalObservedBytes = try LiveProofCanonicalJSON.encode(runtime.observed)
        let evidenceInput = LiveEvidencePreflightInput(
            machineIdentity: Data(foundation.portableMac.platformUUID.utf8),
            baselineBytes: canonicalObservedBytes,
            appIdentityBytes: identityBytes,
            helperIdentityBytes: helperIdentityBytes,
            priorSSID: Data(runtime.priorSSID.utf8),
            targetSSID: Data(foundation.active.ssid.utf8),
            providerOrigin: foundation.configuration.origin,
            providerPublicKey: foundation.configuration.publicKey,
            outputDirectoryPath: Data(outputURL.path.utf8),
            observerUID: Data(String(geteuid()).utf8),
            preflightPeerUID: Data(String(geteuid()).utf8),
            capability: oracleCapability
        )
        let evidenceObservation = LiveEvidenceSystemObservation(
            powerSource: runtime.observed.battery.source == .battery ? .battery : .ac,
            batteryPercent: runtime.observed.battery.percent,
            lidClosed: runtime.observed.lidClosed,
            sleepDisabled: runtime.observed.sleepDisabled ? 1 : 0,
            wifiPower: runtime.observed.wifiPowered,
            selectedWiFiDevice: Data(foundation.wifiDevice.utf8),
            ssid: Data(runtime.priorSSID.utf8),
            usableAddresses: runtime.rawAddresses.map(\.rawBytes),
            routeRemoteAddress: nil,
            routeDevice: Data(runtime.observed.defaultRouteDevice.utf8),
            appRunning: false,
            appJournal: journalState(runtime.appJournal),
            helperJournal: .absent,
            helperJournalAuthorizationCode: 0,
            appIdentityBytes: identityBytes,
            helperIdentityBytes: helperIdentityBytes
        )
        return (evidenceInput, evidenceObservation)
    }

    private func makeFacts(
        context: LiveObserverPreflightContext,
        foundation: LiveObserverPreflightFoundation,
        runtime: LiveObserverPreflightRuntime
    ) throws -> LiveObserverPreflightBindingFacts {
        let canonicalObservedBytes = try LiveProofCanonicalJSON.encode(runtime.observed)
        let facts = LiveObserverPreflightBindingFacts(
            schema: "codex-travel-mode-observer-preflight-binding-facts/v1",
            requestSequence: context.requestSequence,
            machineDigest: ReadinessDigest.salted(
                Data(foundation.portableMac.platformUUID.utf8),
                salt: foundation.salt
            ),
            baselineDigest: ReadinessDigest.salted(
                canonicalObservedBytes,
                salt: foundation.salt
            ),
            appIdentityDigest: try LiveControllerSystem.boundExecutableDigest(
                foundation.appIdentity.executableURL,
                runID: foundation.runID
            ),
            helperIdentityDigest: try LiveControllerSystem.boundExecutableDigest(
                foundation.helperURL,
                runID: foundation.runID
            ),
            providerOrigin: foundation.configuration.origin,
            targetSSIDDigest: ReadinessDigest.salted(
                Data(foundation.active.ssid.utf8),
                salt: foundation.salt
            ),
            wifiDeviceDigest: ReadinessDigest.salted(
                Data(foundation.wifiDevice.utf8),
                salt: foundation.salt
            )
        )
        return facts
    }

    private func successfulOutput(
        _ query: LiveObservedSystemQuery,
        runner: LiveObservedFixedCommandRunner
    ) throws -> String {
        let result = try runner.run(query.command)
        guard result.exitStatus == 0 else {
            throw ReadinessHarnessError.readinessBlocked(
                "observer preflight system readback failed"
            )
        }
        return result.standardOutput
    }

    private func journalState(
        _ presence: LivePlatformJournalPresence
    ) -> LiveOracleJournalState {
        switch presence {
        case .present: .present
        case .absent: .absent
        case .indeterminate: .indeterminate
        }
    }
}

private struct LiveObserverPreflightFoundation: Sendable {
    let runID: String
    let configuration: LiveProofProviderConfiguration
    let appURL: URL
    let helperURL: URL
    let processResolver: LivePlatformProcessResolver
    let appIdentity: LiveObservedCodeIdentity
    let runner: LiveObservedFixedCommandRunner
    let portableMac: LiveObservedPortableMacIdentity
    let active: HotspotConfigurationRevision
    let wifiDevice: String
    let salt: Data
}

private struct LiveObserverPreflightRuntime: Sendable {
    let observed: LiveObservedPreflightFacts
    let capability: LiveProviderCapabilityObservation
    let appHash: String
    let helperHash: String
    let priorSSID: String
    let rawAddresses: [LiveObservedIPAddress]
    let appJournal: LivePlatformJournalPresence
}

final class ProductionLiveObserverProviderCommandPerformer:
    LiveObserverProviderObservationPerforming, @unchecked Sendable {
    private let client: LiveProviderClient
    private let transport: LiveObserverMetricCapturingTransport
    private let lock = NSLock()
    private var pinnedRemoteAddress: String?

    init(configuration: LiveProofProviderConfiguration) {
        let transport = LiveObserverMetricCapturingTransport()
        self.transport = transport
        client = LiveProviderClient(
            configuration: configuration,
            transport: transport,
            bearerReader: LiveProviderKeychainBearerReader()
        )
    }

    func perform(_ command: LiveObserverProviderCommand) throws {
        _ = try performObserved(command)
    }

    func performObserved(
        _ command: LiveObserverProviderCommand
    ) throws -> LiveObserverProviderObservation {
        let box = LiveObserverAsyncResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                let result: LiveObserverProviderObservation
                switch command {
                case .capability:
                    result = .capability(try await client.capability())
                case .submit(let submit):
                    result = .submit(try await client.submit(submit))
                case .readback(let runID, let scenario):
                    result = .readback(
                        try await client.readback(runID: runID, scenario: scenario)
                    )
                }
                box.store(.success(result))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        let result = try box.take().get()
        if case .submit(let submit) = result {
            let observed = try Self.canonicalRemote(submit.taskMetrics)
            let expected = lock.withLock { pinnedRemoteAddress }
            guard observed == expected else {
                throw ReadinessHarnessError.providerFailed(
                    "provider connection switched after the pinned capability"
                )
            }
            lock.withLock { pinnedRemoteAddress = nil }
        }
        return result
    }

    func pinCapabilityRemoteAddress() throws -> String {
        guard case .capability = try performObserved(.capability) else {
            throw ReadinessHarnessError.providerFailed(
                "provider capability pin failed"
            )
        }
        let remote = try Self.canonicalRemote(transport.latestTaskMetrics())
        lock.withLock { pinnedRemoteAddress = remote }
        return remote
    }

    private static func canonicalRemote(
        _ metrics: [LiveProviderTaskMetric]
    ) throws -> String {
        let values = Set(try metrics.compactMap { metric -> String? in
            guard let address = metric.remoteAddress else { return nil }
            return try LiveObservedIPAddress(address).canonicalText
        })
        guard values.count == 1, let value = values.first else {
            throw ReadinessHarnessError.providerFailed(
                "provider remote TaskMetrics are missing or ambiguous"
            )
        }
        return value
    }
}

private final class LiveObserverMetricCapturingTransport:
    NSObject, LiveProviderHTTPTransporting, URLSessionDataDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private var active: LiveObserverURLSessionRequestState?
    private var lastMetrics: [LiveProviderTaskMetric] = []
    private var session: URLSession!

    override init() {
        super.init()
        session = URLSession(
            configuration: LiveProviderURLSessionPolicy.makeConfiguration(),
            delegate: self,
            delegateQueue: nil
        )
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> LiveProviderHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            let state = LiveObserverURLSessionRequestState(
                continuation: continuation
            )
            let accepted = lock.withLock { () -> Bool in
                guard active == nil else { return false }
                active = state
                return true
            }
            guard accepted else {
                continuation.resume(throwing: LiveProviderTransportError.invalidResponse(
                    "observer provider session received concurrent work"
                ))
                return
            }
            session.dataTask(with: request).resume()
        }
    }

    func latestTaskMetrics() -> [LiveProviderTaskMetric] {
        lock.withLock { lastMetrics }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse,
              response.expectedContentLength
                <= LiveProviderURLSessionPolicy.maximumResponseBytes else {
            completionHandler(.cancel)
            finish(.failure(LiveProviderTransportError.invalidResponse(
                "observer provider returned an invalid HTTP response"
            )))
            return
        }
        lock.withLock { active?.response = response }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let tooLarge = lock.withLock { () -> Bool in
            guard let active else { return true }
            if active.data.count + data.count
                > LiveProviderURLSessionPolicy.maximumResponseBytes {
                return true
            }
            active.data.append(data)
            return false
        }
        if tooLarge {
            dataTask.cancel()
            finish(.failure(LiveProviderTransportError.responseTooLarge))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.withLock { active?.redirected = true }
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let values = metrics.transactionMetrics.map {
            LiveProviderTaskMetric(
                localAddress: $0.localAddress,
                remoteAddress: $0.remoteAddress,
                fetchStartedUnixMilliseconds: milliseconds($0.fetchStartDate),
                responseEndedUnixMilliseconds: milliseconds($0.responseEndDate)
            )
        }
        lock.withLock { active?.metrics = values }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard error == nil else {
            finish(.failure(LiveProviderTransportError.invalidResponse(
                "observer provider transport failed"
            )))
            return
        }
        let response = lock.withLock { () -> LiveProviderHTTPResponse? in
            guard let active, let response = active.response,
                  let finalURL = response.url else { return nil }
            return LiveProviderHTTPResponse(
                data: active.data,
                statusCode: response.statusCode,
                finalURL: finalURL,
                redirectAttempted: active.redirected,
                taskMetrics: active.metrics
            )
        }
        guard let response else {
            finish(.failure(LiveProviderTransportError.invalidResponse(
                "observer provider response was incomplete"
            )))
            return
        }
        finish(.success(response))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod
            == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func finish(_ result: Result<LiveProviderHTTPResponse, Error>) {
        let continuation = lock.withLock {
            let continuation = active?.continuation
            if case .success(let response) = result {
                lastMetrics = response.taskMetrics
            }
            active = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func milliseconds(_ date: Date?) -> Int64? {
        date.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) }
    }
}

private final class LiveObserverURLSessionRequestState {
    let continuation: CheckedContinuation<LiveProviderHTTPResponse, Error>
    var response: HTTPURLResponse?
    var data = Data()
    var metrics: [LiveProviderTaskMetric] = []
    var redirected = false

    init(continuation: CheckedContinuation<LiveProviderHTTPResponse, Error>) {
        self.continuation = continuation
    }
}

private final class LiveObserverAsyncResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<LiveObserverProviderObservation, Error>?

    func store(_ result: Result<LiveObserverProviderObservation, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func take() -> Result<LiveObserverProviderObservation, Error> {
        lock.lock()
        defer { lock.unlock() }
        return result ?? .failure(
            ReadinessHarnessError.providerFailed("provider operation did not complete")
        )
    }
}
