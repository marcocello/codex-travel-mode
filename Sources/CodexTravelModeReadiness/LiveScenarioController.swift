import Darwin
import Foundation

public protocol LiveScenarioOperatorIO: Sendable {
    func confirm(_ instruction: String) throws
    func confirm(_ instruction: String, timeoutSeconds: Int) throws
}

public extension LiveScenarioOperatorIO {
    func confirm(_ instruction: String, timeoutSeconds: Int) throws {
        try confirm(instruction)
    }
}

public struct ControllingTTYScenarioOperatorIO: LiveScenarioOperatorIO {
    public init() {}

    public func confirm(_ instruction: String) throws {
        try confirm(instruction, timeoutSeconds: Int.max)
    }

    public func confirm(_ instruction: String, timeoutSeconds: Int) throws {
        let descriptor = Darwin.open("/dev/tty", O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0, isatty(descriptor) == 1 else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ReadinessHarnessError.liveInterrupted(
                "manual scenarios require a controlling TTY"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        let prompt = Data(("\(instruction)\nPress Return when complete: ").utf8)
        _ = prompt.withUnsafeBytes {
            Darwin.write(descriptor, $0.baseAddress, prompt.count)
        }
        var byte: UInt8 = 0
        let deadline = timeoutSeconds == Int.max
            ? nil
            : Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while true {
            if let deadline {
                let remaining = max(0, deadline.timeIntervalSinceNow)
                var descriptorPoll = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN),
                    revents: 0
                )
                let result = Darwin.poll(
                    &descriptorPoll,
                    1,
                    Int32((remaining * 1_000).rounded(.up))
                )
                guard result > 0 else {
                    throw ReadinessHarnessError.liveInterrupted(
                        "operator cleanup confirmation timed out"
                    )
                }
            }
            guard Darwin.read(descriptor, &byte, 1) == 1 else { break }
            if byte == 10 || byte == 13 { return }
        }
        throw ReadinessHarnessError.liveInterrupted("operator confirmation ended")
    }
}

protocol LiveControllerEvidenceProviding: Sendable {
    var controllerEvidenceRecorder: LiveControllerEvidenceRecorder? { get }
}

public final class ProductionLiveScenarioActionPerformer:
    LiveControllerActionPerforming, LiveControllerEvidenceProviding,
    @unchecked Sendable {
    private let operatorIO: any LiveScenarioOperatorIO
    private let lock = NSLock()
    private var recorder: LiveControllerEvidenceRecorder?

    var controllerEvidenceRecorder: LiveControllerEvidenceRecorder? {
        lock.lock()
        defer { lock.unlock() }
        return recorder
    }

    public init(
        operatorIO: any LiveScenarioOperatorIO = ControllingTTYScenarioOperatorIO()
    ) {
        self.operatorIO = operatorIO
    }

    public func performLive(
        arguments: ReadinessArguments,
        observer: LiveObserverClientSession
    ) async throws {
        guard let appURL = arguments.appBundleURL,
              let executableURL = Bundle(url: appURL)?.executableURL else {
            throw ReadinessHarnessError.liveInterrupted("bound app is unavailable")
        }
        let identity = try LiveProofProcessIdentity(
            pid: getpid(),
            startIdentity: LiveControllerSystem.processStartIdentity(pid: getpid()),
            executableSHA256: try LiveControllerSystem.sha256File(
                LiveControllerSystem.executableURL()
            )
        )
        let recorder = try LiveControllerEvidenceRecorder(
            runID: observer.runID,
            controller: identity,
            redactionSalt: Data(observer.runID.utf8)
        )
        lock.withLock { self.recorder = recorder }
        for scenario in arguments.scenarios {
            do {
                try await runScenario(
                    scenario,
                    appURL: appURL,
                    executableURL: executableURL,
                    closedSeconds: arguments.closedLidSeconds,
                    observer: observer,
                    recorder: recorder
                )
            } catch {
                try? requestManualSafetyCleanup(
                    scenario: scenario,
                    recorder: recorder
                )
                throw error
            }
        }
    }

    private func requestManualSafetyCleanup(
        scenario: ReadinessScenario,
        recorder: LiveControllerEvidenceRecorder
    ) throws {
        try LiveScenarioFailureCleanup.run(
            scenario: scenario,
            recorder: recorder,
            operatorIO: operatorIO
        )
    }

    private func runScenario(
        _ scenario: ReadinessScenario,
        appURL: URL,
        executableURL: URL,
        closedSeconds: Int,
        observer: LiveObserverClientSession,
        recorder: LiveControllerEvidenceRecorder
    ) async throws {
        let resolver = LivePlatformProcessResolver()
        let inspector = LivePlatformExactProcessInspector(resolver: resolver)
        try observer.requestObservation(
            scenario: scenario,
            kind: .scenarioBaseline
        )
        try recordCommand(recorder, scenario, .appLaunchRequest)
        try launchFresh(appURL)
        let process = try await waitForOneProcess(
            inspector: inspector,
            appURL: appURL
        )
        try validateRunningAppIdentity(
            process,
            appURL: appURL,
            processResolver: resolver
        )
        try operatorIO.confirm(
            "Open the exact app menu and refresh networks, but do not press Start."
        )
        try observer.validateProductionUI(scenario: scenario)
        try confirm(recorder, scenario, .start, "In the app, manually choose Start.")
        try confirm(
            recorder,
            scenario,
            .lidClose,
            "Prepare to physically close the lid. Confirm, then close it immediately."
        )
        let start = LiveControllerSystem.millisecondsSinceEpoch()
        let interval = 6
        for sequence in 1...3 {
            let due = start + Int64((sequence - 1) * interval * 1_000)
            while LiveControllerSystem.millisecondsSinceEpoch() < due {
                try await Task.sleep(for: .milliseconds(100))
            }
            let submit = try LiveProviderHeartbeatSubmit.fresh(
                runID: observer.runID,
                scenario: scenario,
                sequence: sequence,
                unixMilliseconds: LiveControllerSystem.millisecondsSinceEpoch()
            )
            try recordCommand(
                recorder,
                scenario,
                .heartbeatSubmitRequest,
                heartbeatSequence: sequence,
                nonce: submit.nonce
            )
            try observer.submitHeartbeat(submit)
        }
        let openAt = start + Int64(closedSeconds * 1_000)
        while LiveControllerSystem.millisecondsSinceEpoch() < openAt {
            try await Task.sleep(for: .milliseconds(100))
        }
        try confirm(
            recorder,
            scenario,
            .lidOpen,
            "Physically open the lid and wait for the app UI to become responsive."
        )
        try recordCommand(recorder, scenario, .heartbeatReadbackRequest)
        try observer.requestReadback(runID: observer.runID, scenario: scenario)
        switch scenario {
        case .stop:
            try confirm(recorder, scenario, .stopRestore, "Manually choose Stop.")
            try observer.requestObservation(
                scenario: scenario,
                kind: .mandatoryCleanup
            )
            try confirm(recorder, scenario, .quit, "Manually quit the app.")
            try await waitForNoProcess(inspector: inspector, appURL: appURL)
        case .quit:
            try confirm(recorder, scenario, .quit, "Manually quit the app.")
            try observer.requestObservation(
                scenario: scenario,
                kind: .mandatoryCleanup
            )
            try await waitForNoProcess(inspector: inspector, appURL: appURL)
            try observer.requestObservation(
                scenario: scenario,
                kind: .processExit,
                process: try proofIdentity(process)
            )
        case .ownerDeath:
            let exact = try inspector.requireOneAppProcess(bundleURL: appURL)
            guard exact == process,
                  exact.executableURL == executableURL.standardizedFileURL else {
                throw ReadinessHarnessError.liveInterrupted(
                    "owner-death app identity changed before SIGKILL"
                )
            }
            let proofIdentity = try LiveProofProcessIdentity(
                pid: exact.pid,
                startIdentity: exact.startIdentity,
                executableSHA256: try LiveControllerSystem.sha256File(exact.executableURL)
            )
            try recordCommand(
                recorder,
                scenario,
                .ownerDeathSIGKILLRequest,
                process: proofIdentity,
                signal: SIGKILL
            )
            guard Darwin.kill(exact.pid, SIGKILL) == 0 else {
                throw ReadinessHarnessError.liveInterrupted("exact owner SIGKILL failed")
            }
            try await waitForNoProcess(inspector: inspector, appURL: appURL)
            try observer.requestObservation(
                scenario: scenario,
                kind: .processExit,
                process: proofIdentity
            )
            try observer.requestObservation(
                scenario: scenario,
                kind: .ownerDeathHelperStage
            )
            try confirm(
                recorder,
                scenario,
                .relaunch,
                "Manually relaunch the same app and wait for startup recovery."
            )
            let relaunched = try await waitForOneProcess(
                inspector: inspector,
                appURL: appURL
            )
            try validateRunningAppIdentity(
                relaunched,
                appURL: appURL,
                processResolver: resolver
            )
            try operatorIO.confirm(
                "Open the relaunched app menu and refresh networks, but do not press Start."
            )
            try observer.validateProductionUI(scenario: scenario)
            try observer.requestObservation(
                scenario: scenario,
                kind: .ownerDeathRelaunchedCleanup
            )
            try confirm(recorder, scenario, .quit, "Manually quit the relaunched app.")
            try await waitForNoProcess(inspector: inspector, appURL: appURL)
        }
        try observer.requestObservation(
            scenario: scenario,
            kind: .scenarioFinal
        )
    }

    private func proofIdentity(
        _ process: LivePlatformResolvedProcess
    ) throws -> LiveProofProcessIdentity {
        try LiveProofProcessIdentity(
            pid: process.pid,
            startIdentity: process.startIdentity,
            executableSHA256: LiveControllerSystem.sha256File(process.executableURL)
        )
    }

    private func validateRunningAppIdentity(
        _ process: LivePlatformResolvedProcess,
        appURL: URL,
        processResolver: LivePlatformProcessResolver
    ) throws {
        let inspector = LivePlatformSecCodeIdentityInspector(
            processResolver: processResolver
        )
        let embedded = try inspector.embeddedIdentity(at: appURL)
        let running = try inspector.runningIdentity(pid: process.pid)
        guard running.pid == process.pid,
              running.processStartIdentity == process.startIdentity,
              running.executableURL == process.executableURL,
              running.identifier == embedded.identifier,
              running.teamIdentifier == embedded.teamIdentifier,
              running.cdHash == embedded.cdHash,
              try inspector.requirementMatches(
                  subject: .runningProcess(pid: process.pid),
                  requirement: embedded.designatedRequirement
              ) else {
            throw ReadinessHarnessError.liveInterrupted(
                "fresh app process signing identity changed"
            )
        }
    }

    private func launchFresh(_ appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-a", appURL.path]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReadinessHarnessError.liveInterrupted("fresh app launch failed")
        }
    }

    private func waitForOneProcess(
        inspector: LivePlatformExactProcessInspector,
        appURL: URL
    ) async throws -> LivePlatformResolvedProcess {
        for _ in 0..<100 {
            if let process = try? inspector.requireOneAppProcess(bundleURL: appURL) {
                return process
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ReadinessHarnessError.liveInterrupted("fresh app process did not appear")
    }

    private func waitForNoProcess(
        inspector: LivePlatformExactProcessInspector,
        appURL: URL
    ) async throws {
        for _ in 0..<100 {
            if (try? inspector.requireNoAppProcess(bundleURL: appURL)) != nil { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ReadinessHarnessError.liveInterrupted("app did not exit after operator action")
    }

    private func confirm(
        _ recorder: LiveControllerEvidenceRecorder,
        _ scenario: ReadinessScenario,
        _ kind: LiveOracleControllerEventKind,
        _ instruction: String
    ) throws {
        try operatorIO.confirm(instruction)
        try recorder.appendOperatorEvent(
            unixMilliseconds: LiveControllerSystem.millisecondsSinceEpoch(),
            monotonicNanoseconds: ReadinessClock.monotonicNanoseconds(),
            scenario: scenario,
            kind: kind
        )
    }

    private func recordCommand(
        _ recorder: LiveControllerEvidenceRecorder,
        _ scenario: ReadinessScenario,
        _ kind: LiveOracleControllerEventKind,
        heartbeatSequence: Int? = nil,
        nonce: String? = nil,
        process: LiveProofProcessIdentity? = nil,
        signal: Int32? = nil
    ) throws {
        try recorder.appendCommand(
            unixMilliseconds: LiveControllerSystem.millisecondsSinceEpoch(),
            monotonicNanoseconds: ReadinessClock.monotonicNanoseconds(),
            scenario: scenario,
            kind: kind,
            heartbeatSequence: heartbeatSequence,
            nonce: nonce,
            process: process,
            signal: signal
        )
    }

}

enum LiveScenarioFailureCleanup {
    static let stepTimeoutSeconds = 30

    static func run(
        scenario: ReadinessScenario,
        recorder: LiveControllerEvidenceRecorder,
        operatorIO: any LiveScenarioOperatorIO
    ) throws {
        try record(recorder, scenario, .cleanupEntered)
        try operatorIO.confirm(
            "A live check failed. Physically open the lid, then confirm.",
            timeoutSeconds: stepTimeoutSeconds
        )
        try record(recorder, scenario, .productionStopRequested)
        try operatorIO.confirm(
            "If the app is running, manually choose production Stop.",
            timeoutSeconds: stepTimeoutSeconds
        )
        try record(recorder, scenario, .productionQuitRequested)
        try operatorIO.confirm(
            "Manually quit the app. Do not use direct network or sleep rescue commands.",
            timeoutSeconds: stepTimeoutSeconds
        )
    }

    private static func record(
        _ recorder: LiveControllerEvidenceRecorder,
        _ scenario: ReadinessScenario,
        _ kind: LiveOracleControllerEventKind
    ) throws {
        try recorder.appendCleanupRequest(
            unixMilliseconds: LiveControllerSystem.millisecondsSinceEpoch(),
            monotonicNanoseconds: ReadinessClock.monotonicNanoseconds(),
            scenario: scenario,
            kind: kind
        )
    }
}
