import Darwin
import Foundation

public final class LiveController: @unchecked Sendable {
    private let tty: any LiveControllerTTYIO
    private let actionPerformer: any LiveControllerActionPerforming
    private let oracleLauncher: any LiveOracleLaunching

    public init(
        tty: any LiveControllerTTYIO,
        actionPerformer: any LiveControllerActionPerforming,
        oracleLauncher: any LiveOracleLaunching = SiblingLiveOracleLauncher()
    ) {
        self.tty = tty
        self.actionPerformer = actionPerformer
        self.oracleLauncher = oracleLauncher
    }

    public func run(arguments: ReadinessArguments) async throws {
        switch arguments.mode {
        case .preflight:
            try preflight(arguments)
        case .live:
            try await live(arguments)
        }
    }

    private func preflight(_ arguments: ReadinessArguments) throws {
        guard let appURL = arguments.appBundleURL,
              let providerURL = arguments.heartbeatConfigurationURL else {
            throw ReadinessHarnessError.invalidArguments("preflight inputs are missing")
        }
        let writer = try ReadinessSecureArtifactWriter(
            outputURL: arguments.outputURL,
            allowExistingEmptyDirectory: true
        )
        let input = try inspectPreflightInput(
            appURL: appURL,
            providerURL: providerURL,
            outputURL: arguments.outputURL
        )
        let runID = UUID().uuidString.lowercased()
        let issuedAt = LiveControllerSystem.millisecondsSinceEpoch()
        let expiresAt = issuedAt + LiveProofArming.lifetimeMilliseconds
        try launchObserver(
            outputURL: arguments.outputURL,
            runID: runID,
            controllerHash: input.controllerHash,
            expiresAtMilliseconds: expiresAt
        )
        let session = try LiveObserverClient.beginPreflight(
            socketURL: arguments.outputURL.appendingPathComponent(
                LiveControllerSystem.socketName
            ),
            runID: runID,
            controllerHash: input.controllerHash,
            expiresAtMilliseconds: expiresAt
        )
        let observerFacts = try session.prepare(
            providerConfiguration: input.providerConfiguration,
            appBundleURL: input.appBundleURL,
            helperExecutableURL: input.helperExecutableURL
        )
        let binding = try makeBinding(
            input: input,
            runID: runID,
            observer: session.observer,
            observerPublicKey: session.observerPublicKey,
            facts: observerFacts
        )
        var challenge = try ReadinessDigest.randomBytes(count: 32)
        defer { LiveControllerSystem.zeroize(&challenge) }
        let material = try LiveProofArming.issue(
            binding: binding,
            confirmedChallenge: challenge,
            nowUnixMilliseconds: issuedAt
        )
        var sidecar = material.sidecarSecret
        defer { LiveControllerSystem.zeroize(&sidecar) }
        try LiveProofArming.writeSidecar(
            sidecar,
            to: arguments.outputURL.appendingPathComponent(
                LiveControllerSystem.sidecarName
            )
        )
        try writer.writeNew(
            data: try LiveProofCanonicalJSON.encode(material.receipt),
            named: LiveControllerSystem.receiptName
        )
        try session.arm(receipt: material.receipt)
        let renderedChallenge = Data(LiveProofBase64URL.encode(challenge).utf8)
        try tty.displayArmingChallenge(renderedChallenge)
        Self.emitStatus("Preflight armed for five minutes; observer is waiting.")
    }

    private func live(_ arguments: ReadinessArguments) async throws {
        guard let receiptURL = arguments.receiptURL,
              let appURL = arguments.appBundleURL else {
            throw ReadinessHarnessError.invalidArguments("live app or receipt is missing")
        }
        try LiveControllerSystem.requireOwnedPrivateDirectory(arguments.outputURL)
        try requireReceiptLocation(receiptURL, outputURL: arguments.outputURL)
        try ReadinessFileSecurity.requirePrivateRegularFile(receiptURL)
        let receiptData = try Data(contentsOf: receiptURL, options: .mappedIfSafe)
        let receipt = try LiveProofCanonicalJSON.decode(
            LiveProofArmingReceipt.self,
            from: receiptData
        )
        guard try LiveProofCanonicalJSON.encode(receipt) == receiptData else {
            throw ReadinessHarnessError.receiptRejected("receipt is not canonical JSON")
        }
        try validateLocalBinding(receipt, outputURL: arguments.outputURL)
        try validateLiveAppBinding(appURL, receipt: receipt)
        var enteredChallenge = try tty.readArmingChallenge()
        defer { LiveControllerSystem.zeroize(&enteredChallenge) }
        guard let entered = String(data: enteredChallenge, encoding: .utf8) else {
            throw ReadinessHarnessError.receiptRejected("arming challenge is invalid")
        }
        var decodedChallenge: Data
        do {
            decodedChallenge = try LiveProofBase64URL.decode(entered, exactByteCount: 32)
        } catch {
            throw ReadinessHarnessError.receiptRejected("arming challenge is invalid")
        }
        defer { LiveControllerSystem.zeroize(&decodedChallenge) }
        guard LiveProofArming.challengeMatches(decodedChallenge, receipt: receipt) else {
            throw ReadinessHarnessError.receiptRejected("arming challenge did not match")
        }
        let observer = try LiveObserverClient.beginLive(
            socketURL: arguments.outputURL.appendingPathComponent(
                LiveControllerSystem.socketName
            ),
            receipt: receipt
        )
        do {
            try await actionPerformer.performLive(arguments: arguments, observer: observer)
        } catch {
            try? observer.finish(disposition: "aborted", detailCode: "controller_error")
            _ = try finalizeControllerEvidence(
                outputURL: arguments.outputURL,
                receipt: receipt
            )
            throw error
        }
        try observer.finish(disposition: "completed", detailCode: "controller_completed")
        let recorder = try finalizeControllerEvidence(
            outputURL: arguments.outputURL,
            receipt: receipt
        )
        try oracleLauncher.evaluate(
            evidenceDirectory: arguments.outputURL,
            runID: receipt.binding.runID,
            controller: recorder.controller,
            observer: receipt.binding.observer
        )
    }

    private func finalizeControllerEvidence(
        outputURL: URL,
        receipt: LiveProofArmingReceipt
    ) throws -> LiveControllerEvidenceRecorder {
        guard let recorder = (
            actionPerformer as? any LiveControllerEvidenceProviding
        )?.controllerEvidenceRecorder else {
            throw ReadinessHarnessError.liveInterrupted(
                "controller evidence recorder is unavailable"
            )
        }
        try waitForObserverFinalization(outputURL: outputURL)
        _ = try LiveEvidenceFinalizer.finalizeController(
            directory: outputURL,
            receipt: receipt,
            recorder: recorder
        )
        return recorder
    }

    private func waitForObserverFinalization(outputURL: URL) throws {
        let socketURL = outputURL.appendingPathComponent(LiveControllerSystem.socketName)
        let sealURL = outputURL.appendingPathComponent("observer-seal.json")
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: socketURL.path),
               FileManager.default.fileExists(atPath: sealURL.path) {
                return
            }
            usleep(10_000)
        }
        throw ReadinessHarnessError.liveInterrupted(
            "observer did not seal and exit within its deadline"
        )
    }

    private func inspectPreflightInput(
        appURL: URL,
        providerURL: URL,
        outputURL: URL
    ) throws -> LiveControllerPreflightInput {
        var appInfo = stat()
        guard Darwin.lstat(appURL.path, &appInfo) == 0,
              appInfo.st_mode & S_IFMT == S_IFDIR else {
            throw ReadinessHarnessError.readinessBlocked("app bundle is unavailable")
        }
        try ReadinessFileSecurity.requirePrivateRegularFile(providerURL)
        let providerData = try Data(contentsOf: providerURL, options: .mappedIfSafe)
        let executableURL = try LiveControllerSystem.executableURL()
        let controllerHash = try LiveControllerSystem.sha256File(executableURL)
        let helperURL = appURL
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent("codex-travel-mode-sleep-helper")
        guard FileManager.default.isReadableFile(atPath: helperURL.path) else {
            throw ReadinessHarnessError.readinessBlocked(
                "embedded sleep helper is unavailable"
            )
        }
        return LiveControllerPreflightInput(
            appBundleURL: appURL,
            helperExecutableURL: helperURL,
            providerConfiguration: providerData,
            controllerHash: controllerHash,
            outputURL: outputURL
        )
    }

    private func makeBinding(
        input: LiveControllerPreflightInput,
        runID: String,
        observer: LiveProofProcessIdentity,
        observerPublicKey: String,
        facts: LiveObserverPreflightBindingFacts
    ) throws -> LiveProofArmingBinding {
        let salt = Data(runID.utf8)
        let outputDigest = ReadinessDigest.salted(Data(input.outputURL.path.utf8), salt: salt)
        return try LiveProofArmingBinding(
            runID: runID,
            machineDigest: facts.machineDigest,
            baselineDigest: facts.baselineDigest,
            controllerSHA256: input.controllerHash,
            observer: observer,
            observerPublicKey: observerPublicKey,
            appIdentityDigest: facts.appIdentityDigest,
            helperIdentityDigest: facts.helperIdentityDigest,
            providerOrigin: facts.providerOrigin,
            outputDirectoryDigest: outputDigest,
            targetSSIDDigest: facts.targetSSIDDigest,
            wifiDeviceDigest: facts.wifiDeviceDigest
        )
    }

    private func launchObserver(
        outputURL: URL,
        runID: String,
        controllerHash: String,
        expiresAtMilliseconds: Int64
    ) throws {
        let controllerURL = try LiveControllerSystem.executableURL()
        let observerURL = controllerURL.deletingLastPathComponent()
            .appendingPathComponent("codex-travel-mode-readiness-observer")
            .standardizedFileURL
        var observerInfo = stat()
        guard Darwin.lstat(observerURL.path, &observerInfo) == 0,
              observerInfo.st_mode & S_IFMT == S_IFREG,
              observerInfo.st_mode & 0o111 != 0,
              observerInfo.st_uid == geteuid() else {
            throw ReadinessHarnessError.readinessBlocked(
                "the sibling readiness observer executable is unavailable or unsafe"
            )
        }
        let observerHash = try LiveControllerSystem.sha256File(observerURL)
        guard observerHash != controllerHash else {
            throw ReadinessHarnessError.readinessBlocked(
                "the observer executable must be distinct from the controller"
            )
        }
        let process = Process()
        process.executableURL = observerURL
        process.arguments = [
            "--observer",
            "--output", outputURL.path,
            "--run-id", runID,
            "--controller-hash", controllerHash,
            "--expires-at-milliseconds", String(expiresAtMilliseconds),
        ]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw ReadinessHarnessError.readinessBlocked("could not launch observer process")
        }
    }

    private func validateLocalBinding(
        _ receipt: LiveProofArmingReceipt,
        outputURL: URL
    ) throws {
        let binding = receipt.binding
        let controllerHash = try LiveControllerSystem.sha256File(
            LiveControllerSystem.executableURL()
        )
        let outputDigest = ReadinessDigest.salted(
            Data(outputURL.path.utf8),
            salt: Data(binding.runID.utf8)
        )
        guard binding.controllerSHA256 == controllerHash,
              binding.outputDirectoryDigest == outputDigest,
              binding.targetSSIDDigest != nil,
              binding.wifiDeviceDigest != nil else {
            throw ReadinessHarnessError.receiptRejected(
                "receipt is bound to a different controller or output directory"
            )
        }
    }

    private func requireReceiptLocation(_ receiptURL: URL, outputURL: URL) throws {
        let exact = outputURL.appendingPathComponent(LiveControllerSystem.receiptName)
            .standardizedFileURL
        guard receiptURL.standardizedFileURL == exact else {
            throw ReadinessHarnessError.receiptRejected(
                "receipt must be the arming receipt inside the output directory"
            )
        }
    }

    private func validateLiveAppBinding(
        _ appURL: URL,
        receipt: LiveProofArmingReceipt
    ) throws {
        guard let executableURL = Bundle(url: appURL)?.executableURL else {
            throw ReadinessHarnessError.receiptRejected(
                "the live app bundle has no executable"
            )
        }
        let helperURL = appURL
            .appendingPathComponent("Contents/Resources")
            .appendingPathComponent("codex-travel-mode-sleep-helper")
        let appDigest = try LiveControllerSystem.boundExecutableDigest(
            executableURL,
            runID: receipt.binding.runID
        )
        let helperDigest = try LiveControllerSystem.boundExecutableDigest(
            helperURL,
            runID: receipt.binding.runID
        )
        guard appDigest == receipt.binding.appIdentityDigest,
              helperDigest == receipt.binding.helperIdentityDigest else {
            throw ReadinessHarnessError.receiptRejected(
                "the live app or embedded helper differs from preflight"
            )
        }
    }

    private static func emitStatus(_ message: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((message + "\n").utf8))
    }
}

private struct LiveControllerPreflightInput {
    let appBundleURL: URL
    let helperExecutableURL: URL
    let providerConfiguration: Data
    let controllerHash: String
    let outputURL: URL
}
