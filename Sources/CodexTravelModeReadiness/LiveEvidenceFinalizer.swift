import Darwin
import Foundation

public enum LiveEvidenceFinalizer {
    public static let maximumArtifactBytes = 16 * 1_024 * 1_024
    public static let defaultLiveSocketName = ".observer.sock"

    @discardableResult
    public static func finalizeObserver(
        directory: URL,
        recorder: LiveObserverEvidenceRecorder,
        liveSocketName: String? = ".observer.sock"
    ) throws -> LiveEvidenceObserverFinalizationResult {
        let directory = directory.standardizedFileURL
        let directoryFD = try openPrivateDirectory(directory)
        defer { _ = Darwin.close(directoryFD) }
        var initialNames: Set<String> = ["arming-receipt.json", ".arming-consumed"]
        if let liveSocketName {
            try validateName(liveSocketName)
            initialNames.insert(liveSocketName)
            try validateLiveSocket(named: liveSocketName, directoryFD: directoryFD)
        }
        try requireContents(directoryFD: directoryFD, expected: initialNames)

        let receiptBytes = try reopenAndRead(
            named: "arming-receipt.json",
            directoryFD: directoryFD,
            expectedMode: 0o600
        )
        let receipt: LiveProofArmingReceipt = try decodeCanonical(receiptBytes)
        try validateConsumptionMarker(
            receiptBytes: receiptBytes,
            directoryFD: directoryFD
        )
        let observer = try recorder.snapshotArtifacts()
        try validateObserverBinding(
            receipt: receipt,
            recorder: recorder,
            observer: observer
        )

        let artifacts: [(String, Data)] = [
            (
                "preflight-readback.json",
                try LiveProofCanonicalJSON.encode(observer.preflight)
            ),
            (
                "provider-transport-events.json",
                try LiveProofCanonicalJSON.encode(observer.transport)
            ),
            (
                "provider-receipts.json",
                try LiveProofCanonicalJSON.encode(observer.receipts)
            ),
            (
                "observer-events.json",
                try LiveProofCanonicalJSON.encode(observer.events)
            ),
        ]
        var observerOwnedEntries: [LiveOracleManifestEntry] = []
        for artifact in artifacts {
            try writeExclusive(artifact.1, named: artifact.0, directoryFD: directoryFD)
            observerOwnedEntries.append(try sealAndDescribe(
                named: artifact.0,
                role: .observer,
                author: recorder.observer,
                directoryFD: directoryFD
            ))
        }
        let signedSeal = try recorder.signedSeal(
            observerOwnedFiles: observerOwnedEntries
        )
        let sealBytes = try LiveProofCanonicalJSON.encode(signedSeal)
        try writeExclusive(
            sealBytes,
            named: "observer-seal.json",
            directoryFD: directoryFD
        )
        let sealEntry = try sealAndDescribe(
            named: "observer-seal.json",
            role: .observer,
            author: recorder.observer,
            directoryFD: directoryFD
        )
        guard Darwin.fsync(directoryFD) == 0 else {
            throw posixError("could not synchronize observer evidence")
        }
        let expected = initialNames.union(artifacts.map { $0.0 }).union(
            ["observer-seal.json"]
        )
        try requireContents(directoryFD: directoryFD, expected: expected)
        try verifyEntries(observerOwnedEntries + [sealEntry], directoryFD: directoryFD)
        return LiveEvidenceObserverFinalizationResult(
            observerOwnedEntries: observerOwnedEntries.sorted { $0.name < $1.name },
            observerSealEntry: sealEntry,
            signedObserverSeal: signedSeal
        )
    }

    @discardableResult
    public static func finalizeController(
        directory: URL,
        receipt: LiveProofArmingReceipt,
        recorder: LiveControllerEvidenceRecorder
    ) throws -> LiveEvidenceFinalizationResult {
        try finalizeController(
            directory: directory,
            receipt: receipt,
            expectedPreflightController: nil,
            recorder: recorder
        )
    }

    @discardableResult
    public static func finalizeController(
        directory: URL,
        receipt: LiveProofArmingReceipt,
        preflightController: LiveProofProcessIdentity,
        recorder: LiveControllerEvidenceRecorder
    ) throws -> LiveEvidenceFinalizationResult {
        try finalizeController(
            directory: directory,
            receipt: receipt,
            expectedPreflightController: preflightController,
            recorder: recorder
        )
    }

    private static func finalizeController(
        directory: URL,
        receipt: LiveProofArmingReceipt,
        expectedPreflightController: LiveProofProcessIdentity?,
        recorder: LiveControllerEvidenceRecorder
    ) throws -> LiveEvidenceFinalizationResult {
        let directory = directory.standardizedFileURL
        let directoryFD = try openPrivateDirectory(directory)
        defer { _ = Darwin.close(directoryFD) }
        let observerNames: Set<String> = [
            "preflight-readback.json", "provider-transport-events.json",
            "provider-receipts.json", "observer-events.json", "observer-seal.json",
        ]
        try requireContents(
            directoryFD: directoryFD,
            expected: observerNames.union(["arming-receipt.json", ".arming-consumed"])
        )

        let receiptBytes = try reopenAndRead(
            named: "arming-receipt.json",
            directoryFD: directoryFD,
            expectedMode: 0o600
        )
        let decodedReceipt: LiveProofArmingReceipt = try decodeCanonical(receiptBytes)
        guard receiptBytes == (try LiveProofCanonicalJSON.encode(receipt)),
              decodedReceipt == receipt else {
            throw LiveEvidenceError.invalidBinding("arming receipt bytes are not canonical")
        }
        try validateConsumptionMarker(
            receiptBytes: receiptBytes,
            directoryFD: directoryFD
        )
        let observer = try readObserverArtifacts(directoryFD: directoryFD)
        let verifiedObserver = try validateSealedObserverArtifacts(
            receipt: receipt,
            expectedPreflightController: expectedPreflightController,
            liveController: recorder.controller,
            artifacts: observer,
            directoryFD: directoryFD
        )
        let preflightController = verifiedObserver.preflightController
        guard recorder.runID == receipt.binding.runID,
              recorder.controller.executableSHA256 == receipt.binding.controllerSHA256 else {
            throw LiveEvidenceError.invalidBinding("live controller binding is inconsistent")
        }

        let controller = recorder.snapshotArtifacts()
        let controllerArtifacts: [(String, Data)] = [
            (
                "command-events.json",
                try LiveProofCanonicalJSON.encode(controller.command)
            ),
            (
                "operator-events.json",
                try LiveProofCanonicalJSON.encode(controller.operatorEvents)
            ),
            (
                "cleanup-events.json",
                try LiveProofCanonicalJSON.encode(controller.cleanup)
            ),
        ]
        var entries = verifiedObserver.entries
        for artifact in controllerArtifacts {
            try writeExclusive(artifact.1, named: artifact.0, directoryFD: directoryFD)
            entries.append(try sealAndDescribe(
                named: artifact.0,
                role: .controller,
                author: recorder.controller,
                directoryFD: directoryFD
            ))
        }
        entries.append(try sealAndDescribe(
            named: "arming-receipt.json",
            role: .controller,
            author: preflightController,
            directoryFD: directoryFD,
            expectedBytes: receiptBytes
        ))

        let manifest = LiveOracleSealManifest(
            runID: receipt.binding.runID,
            author: recorder.controller,
            entries: entries
        )
        let manifestBytes = try LiveProofCanonicalJSON.encode(manifest)
        try writeExclusive(
            manifestBytes,
            named: "seal-manifest.json",
            directoryFD: directoryFD
        )
        _ = try sealAndDescribe(
            named: "seal-manifest.json",
            role: .controller,
            author: recorder.controller,
            directoryFD: directoryFD,
            expectedBytes: manifestBytes
        )
        guard Darwin.fsync(directoryFD) == 0 else {
            throw posixError("could not synchronize controller evidence")
        }
        try requireContents(
            directoryFD: directoryFD,
            expected: LiveTravelModeOracle.rawArtifactNames.union([".arming-consumed"])
        )
        try verifyEntries(manifest.entries, directoryFD: directoryFD)
        let manifestReadback = try reopenAndRead(
            named: "seal-manifest.json",
            directoryFD: directoryFD,
            expectedMode: 0o400
        )
        guard manifestReadback == manifestBytes,
              try decodeCanonical(manifestReadback) as LiveOracleSealManifest == manifest else {
            throw LiveEvidenceError.unsafeArtifact("manifest changed after sealing")
        }
        return LiveEvidenceFinalizationResult(
            manifest: manifest,
            signedObserverSeal: observer.signedSeal
        )
    }

    private struct ObserverArtifacts {
        let preflight: LiveOraclePreflightReadback
        let transport: LiveOracleProviderTransportArtifact
        let receipts: LiveOracleProviderReceiptsArtifact
        let events: LiveOracleObserverEventsArtifact
        let signedSeal: LiveProofSignedPayload
    }

    private static func readObserverArtifacts(directoryFD: Int32) throws
        -> ObserverArtifacts
    {
        ObserverArtifacts(
            preflight: try readCanonical(
                "preflight-readback.json",
                as: LiveOraclePreflightReadback.self,
                directoryFD: directoryFD
            ),
            transport: try readCanonical(
                "provider-transport-events.json",
                as: LiveOracleProviderTransportArtifact.self,
                directoryFD: directoryFD
            ),
            receipts: try readCanonical(
                "provider-receipts.json",
                as: LiveOracleProviderReceiptsArtifact.self,
                directoryFD: directoryFD
            ),
            events: try readCanonical(
                "observer-events.json",
                as: LiveOracleObserverEventsArtifact.self,
                directoryFD: directoryFD
            ),
            signedSeal: try readCanonical(
                "observer-seal.json",
                as: LiveProofSignedPayload.self,
                directoryFD: directoryFD
            )
        )
    }

    private static func validateObserverBinding(
        receipt: LiveProofArmingReceipt,
        recorder: LiveObserverEvidenceRecorder,
        observer: LiveEvidenceObserverArtifacts
    ) throws {
        let binding = receipt.binding
        guard recorder.runID == binding.runID,
              recorder.observer == binding.observer,
              recorder.observerPublicKey == binding.observerPublicKey,
              observer.preflight.runID == binding.runID,
              observer.preflight.producer == binding.observer,
              observer.preflight.observerPublicKey == binding.observerPublicKey,
              observer.preflight.machineDigest == binding.machineDigest,
              observer.preflight.baselineDigest == binding.baselineDigest,
              observer.preflight.appIdentityDigest == binding.appIdentityDigest,
              observer.preflight.helperIdentityDigest == binding.helperIdentityDigest,
              observer.preflight.providerOrigin == binding.providerOrigin,
              observer.preflight.targetSSIDDigest == binding.targetSSIDDigest,
              observer.preflight.outputDirectoryDigest == binding.outputDirectoryDigest,
              observer.transport.producer == binding.observer,
              observer.receipts.producer == binding.observer,
              observer.events.producer == binding.observer else {
            throw LiveEvidenceError.invalidBinding("observer binding is inconsistent")
        }
        let handshakes = try verifiedHandshakes(observer.events)
        guard handshakes.count == 2,
              handshakes[0].phase == .preflight,
              handshakes[1].phase == .live,
              handshakes.allSatisfy({
                  $0.runID == binding.runID
                      && $0.controllerSHA256 == binding.controllerSHA256
              }) else {
            throw LiveEvidenceError.invalidBinding("observer sessions are incomplete")
        }
    }

    private static func validateSealedObserverArtifacts(
        receipt: LiveProofArmingReceipt,
        expectedPreflightController: LiveProofProcessIdentity?,
        liveController: LiveProofProcessIdentity,
        artifacts: ObserverArtifacts,
        directoryFD: Int32
    ) throws -> (
        entries: [LiveOracleManifestEntry],
        preflightController: LiveProofProcessIdentity
    ) {
        let binding = receipt.binding
        guard artifacts.preflight.runID == binding.runID,
              artifacts.preflight.producer == binding.observer,
              artifacts.preflight.observerPublicKey == binding.observerPublicKey,
              artifacts.preflight.machineDigest == binding.machineDigest,
              artifacts.preflight.baselineDigest == binding.baselineDigest,
              artifacts.preflight.appIdentityDigest == binding.appIdentityDigest,
              artifacts.preflight.helperIdentityDigest == binding.helperIdentityDigest,
              artifacts.preflight.providerOrigin == binding.providerOrigin,
              artifacts.preflight.targetSSIDDigest == binding.targetSSIDDigest,
              artifacts.preflight.outputDirectoryDigest == binding.outputDirectoryDigest,
              artifacts.transport.producer == binding.observer,
              artifacts.receipts.producer == binding.observer,
              artifacts.events.producer == binding.observer else {
            throw LiveEvidenceError.invalidBinding("sealed observer binding is inconsistent")
        }
        let handshakes = try verifiedHandshakes(artifacts.events)
        guard handshakes.count == 2,
              handshakes[0].phase == .preflight,
              handshakes[1].phase == .live,
              expectedPreflightController.map({ $0 == handshakes[0].client }) ?? true,
              handshakes[1].client == liveController,
              handshakes.allSatisfy({
                  $0.runID == binding.runID
                      && $0.controllerSHA256 == binding.controllerSHA256
              }) else {
            throw LiveEvidenceError.invalidBinding("controller sessions are not exact")
        }
        let sealBytes = try LiveProofSignatureVerifier.verify(
            artifacts.signedSeal,
            domain: .seal,
            publicKeyBase64URL: binding.observerPublicKey
        )
        let seal: LiveOracleObserverSealPayload = try decodeCanonical(sealBytes)
        guard let finalEnvelope = artifacts.events.events.last,
              seal.runID == binding.runID,
              seal.observer == binding.observer,
              seal.observerPublicKey == binding.observerPublicKey,
              seal.eventCount == artifacts.events.events.count,
              seal.finalEnvelopeSHA256
                == (try LiveProofEphemeralSigner.envelopeSHA256(finalEnvelope)) else {
            throw LiveEvidenceError.invalidBinding("observer seal binding is inconsistent")
        }
        let expectedObserverNames: Set<String> = [
            "preflight-readback.json", "provider-transport-events.json",
            "provider-receipts.json", "observer-events.json",
        ]
        guard Set(seal.observerOwnedFiles.map(\.name)) == expectedObserverNames else {
            throw LiveEvidenceError.incompleteEvidence("observer seal file set is incomplete")
        }
        for entry in seal.observerOwnedFiles {
            let actual = try describeExisting(
                named: entry.name,
                role: .observer,
                author: binding.observer,
                directoryFD: directoryFD
            )
            guard entry == actual else {
                throw LiveEvidenceError.unsafeArtifact(
                    "\(entry.name) changed after observer sealing"
                )
            }
        }
        let sealEntry = try describeExisting(
            named: "observer-seal.json",
            role: .observer,
            author: binding.observer,
            directoryFD: directoryFD
        )
        return (
            entries: seal.observerOwnedFiles + [sealEntry],
            preflightController: handshakes[0].client
        )
    }

    private static func verifiedHandshakes(
        _ events: LiveOracleObserverEventsArtifact
    ) throws -> [LiveProofHandshakePayload] {
        try events.handshakes.map {
            let bytes = try LiveProofSignatureVerifier.verify(
                $0,
                domain: .handshake,
                publicKeyBase64URL: events.observerPublicKey
            )
            return try decodeCanonical(bytes)
        }
    }

    private static func validateConsumptionMarker(
        receiptBytes: Data,
        directoryFD: Int32
    ) throws {
        let marker = try reopenAndRead(
            named: ".arming-consumed",
            directoryFD: directoryFD,
            expectedMode: 0o600
        )
        guard marker == Data(ReadinessDigest.sha256Hex(receiptBytes).utf8) else {
            throw LiveEvidenceError.invalidBinding("arming receipt was not consumed exactly once")
        }
    }

    private static func openPrivateDirectory(_ directory: URL) throws -> Int32 {
        let descriptor = Darwin.open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw LiveEvidenceError.unsafeArtifact("evidence directory cannot be opened safely")
        }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_mode & 0o777 == 0o700,
              information.st_uid == geteuid() else {
            _ = Darwin.close(descriptor)
            throw LiveEvidenceError.unsafeArtifact("evidence directory is not private")
        }
        return descriptor
    }

    private static func requireContents(
        directoryFD: Int32,
        expected: Set<String>
    ) throws {
        let scanFD = Darwin.openat(
            directoryFD,
            ".",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard scanFD >= 0, let stream = Darwin.fdopendir(scanFD) else {
            if scanFD >= 0 { _ = Darwin.close(scanFD) }
            throw posixError("could not enumerate evidence directory")
        }
        defer { _ = Darwin.closedir(stream) }
        var names = Set<String>()
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                names.insert(name)
            }
        }
        guard names == expected else {
            throw LiveEvidenceError.unsafeArtifact("evidence directory has unexpected contents")
        }
    }

    private static func validateLiveSocket(named name: String, directoryFD: Int32) throws {
        var information = stat()
        guard Darwin.fstatat(
            directoryFD,
            name,
            &information,
            AT_SYMLINK_NOFOLLOW
        ) == 0,
            information.st_mode & S_IFMT == S_IFSOCK,
            information.st_mode & 0o777 == 0o600,
            information.st_uid == geteuid() else {
            throw LiveEvidenceError.unsafeArtifact("live observer socket is unsafe")
        }
    }

    private static func writeExclusive(
        _ data: Data,
        named name: String,
        directoryFD: Int32
    ) throws {
        try validateArtifact(data: data, name: name)
        let descriptor = Darwin.openat(
            directoryFD,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw posixError("could not create \(name)") }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw LiveEvidenceError.unsafeArtifact("\(name) is not a private regular file")
        }
        try writeAll(data, descriptor: descriptor, name: name)
        guard Darwin.fsync(descriptor) == 0 else {
            throw posixError("could not synchronize \(name)")
        }
    }

    private static func sealAndDescribe(
        named name: String,
        role: LiveOracleArtifactRole,
        author: LiveProofProcessIdentity,
        directoryFD: Int32,
        expectedBytes: Data? = nil
    ) throws -> LiveOracleManifestEntry {
        let descriptor = Darwin.openat(
            directoryFD,
            name,
            O_RDWR | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw posixError("could not open \(name) for sealing")
        }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == geteuid(),
              information.st_size > 0,
              information.st_size <= maximumArtifactBytes,
              Darwin.fchmod(descriptor, 0o400) == 0,
              Darwin.fsync(descriptor) == 0 else {
            throw LiveEvidenceError.unsafeArtifact("\(name) could not be sealed")
        }
        let entry = try describeExisting(
            named: name,
            role: role,
            author: author,
            directoryFD: directoryFD
        )
        if let expectedBytes {
            let readback = try reopenAndRead(
                named: name,
                directoryFD: directoryFD,
                expectedMode: 0o400
            )
            guard readback == expectedBytes else {
                throw LiveEvidenceError.unsafeArtifact("\(name) changed before sealing")
            }
        }
        return entry
    }

    private static func describeExisting(
        named name: String,
        role: LiveOracleArtifactRole,
        author: LiveProofProcessIdentity,
        directoryFD: Int32
    ) throws -> LiveOracleManifestEntry {
        let data = try reopenAndRead(
            named: name,
            directoryFD: directoryFD,
            expectedMode: 0o400
        )
        return LiveOracleManifestEntry(
            name: name,
            role: role,
            author: author,
            byteCount: Int64(data.count),
            sha256: ReadinessDigest.sha256Hex(data)
        )
    }

    private static func readCanonical<Value: Codable>(
        _ name: String,
        as type: Value.Type,
        directoryFD: Int32
    ) throws -> Value {
        try decodeCanonical(reopenAndRead(
            named: name,
            directoryFD: directoryFD,
            expectedMode: 0o400
        ))
    }

    private static func decodeCanonical<Value: Codable>(_ data: Data) throws -> Value {
        let value = try LiveProofCanonicalJSON.decode(Value.self, from: data)
        guard try LiveProofCanonicalJSON.encode(value) == data else {
            throw LiveEvidenceError.unsafeArtifact("artifact is not canonical JSON")
        }
        return value
    }

    private static func reopenAndRead(
        named name: String,
        directoryFD: Int32,
        expectedMode: UInt16
    ) throws -> Data {
        try validateName(name)
        let descriptor = Darwin.openat(
            directoryFD,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else { throw posixError("could not reopen \(name)") }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_mode & 0o777 == expectedMode,
              before.st_uid == geteuid(),
              before.st_size > 0,
              before.st_size <= maximumArtifactBytes else {
            throw LiveEvidenceError.unsafeArtifact("\(name) metadata is unsafe")
        }
        let data = try readAll(
            descriptor: descriptor,
            byteCount: Int(before.st_size),
            name: name
        )
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mode == after.st_mode,
              before.st_uid == after.st_uid,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else {
            throw LiveEvidenceError.unsafeArtifact("\(name) changed during readback")
        }
        return data
    }

    private static func verifyEntries(
        _ entries: [LiveOracleManifestEntry],
        directoryFD: Int32
    ) throws {
        for entry in entries {
            let bytes = try reopenAndRead(
                named: entry.name,
                directoryFD: directoryFD,
                expectedMode: entry.mode
            )
            guard entry.mode == 0o400,
                  entry.byteCount == bytes.count,
                  entry.sha256 == ReadinessDigest.sha256Hex(bytes) else {
                throw LiveEvidenceError.unsafeArtifact(
                    "\(entry.name) does not match its sealed entry"
                )
            }
        }
    }

    private static func validateArtifact(data: Data, name: String) throws {
        try validateName(name)
        guard !data.isEmpty, data.count <= maximumArtifactBytes else {
            throw LiveEvidenceError.unsafeArtifact("artifact size is unsafe")
        }
    }

    private static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else {
            throw LiveEvidenceError.unsafeArtifact("artifact name is unsafe")
        }
    }

    private static func writeAll(
        _ data: Data,
        descriptor: Int32,
        name: String
    ) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard count > 0 else { throw posixError("short write for \(name)") }
                offset += count
            }
        }
    }

    private static func readAll(
        descriptor: Int32,
        byteCount: Int,
        name: String
    ) throws -> Data {
        var data = Data(count: byteCount)
        var offset = 0
        while offset < byteCount {
            let count = data.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    byteCount - offset
                )
            }
            guard count > 0 else { throw posixError("short read for \(name)") }
            offset += count
        }
        return data
    }

    private static func posixError(_ operation: String) -> LiveEvidenceError {
        LiveEvidenceError.unsafeArtifact("\(operation) (errno \(errno))")
    }
}
