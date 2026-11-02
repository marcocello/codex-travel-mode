import CryptoKit
import Darwin
import Foundation

public struct LiveProofArmingMaterial: Equatable, Sendable {
    public let receipt: LiveProofArmingReceipt
    public let sidecarSecret: Data
}

public enum LiveProofArming {
    public static let lifetimeMilliseconds: Int64 = 5 * 60 * 1_000
    public static let sidecarByteCount = 32

    public static func issue(
        binding: LiveProofArmingBinding,
        confirmedChallenge: Data,
        nowUnixMilliseconds: Int64
    ) throws -> LiveProofArmingMaterial {
        guard !confirmedChallenge.isEmpty, nowUnixMilliseconds >= 0,
              nowUnixMilliseconds <= Int64.max - lifetimeMilliseconds else {
            throw LiveProofError.invalidValue("invalid arming time or challenge")
        }
        let secret = try ReadinessDigest.randomBytes(count: sidecarByteCount)
        let challengeSHA256 = ReadinessDigest.sha256Hex(confirmedChallenge)
        let expires = nowUnixMilliseconds + lifetimeMilliseconds
        let unsigned = LiveProofUnsignedArmingReceipt(
            issuedAtUnixMilliseconds: nowUnixMilliseconds,
            expiresAtUnixMilliseconds: expires,
            challengeSHA256: challengeSHA256,
            binding: binding
        )
        let code = try authenticationCode(for: unsigned, secret: secret)
        let receipt = LiveProofArmingReceipt(
            issuedAtUnixMilliseconds: nowUnixMilliseconds,
            expiresAtUnixMilliseconds: expires,
            challengeSHA256: challengeSHA256,
            binding: binding,
            authenticationCode: code
        )
        return LiveProofArmingMaterial(receipt: receipt, sidecarSecret: secret)
    }

    public static func verify(
        receipt: LiveProofArmingReceipt,
        sidecarSecret: Data,
        nowUnixMilliseconds: Int64
    ) throws {
        guard sidecarSecret.count == sidecarByteCount,
              receipt.schema == LiveProofArmingReceipt.schema,
              receipt.issuedAtUnixMilliseconds >= 0,
              receipt.issuedAtUnixMilliseconds <= Int64.max - lifetimeMilliseconds,
              receipt.expiresAtUnixMilliseconds
                == receipt.issuedAtUnixMilliseconds + lifetimeMilliseconds,
              nowUnixMilliseconds >= receipt.issuedAtUnixMilliseconds,
              LiveProofValidation.isSHA256Hex(receipt.challengeSHA256),
              (try? LiveProofBase64URL.decode(
                  receipt.authenticationCode,
                  exactByteCount: 32
              )) != nil else {
            throw LiveProofError.authenticationFailed
        }
        _ = try LiveProofArmingBinding(
            runID: receipt.binding.runID,
            machineDigest: receipt.binding.machineDigest,
            baselineDigest: receipt.binding.baselineDigest,
            controllerSHA256: receipt.binding.controllerSHA256,
            observer: LiveProofProcessIdentity(
                pid: receipt.binding.observer.pid,
                startIdentity: receipt.binding.observer.startIdentity,
                executableSHA256: receipt.binding.observer.executableSHA256
            ),
            observerPublicKey: receipt.binding.observerPublicKey,
            appIdentityDigest: receipt.binding.appIdentityDigest,
            helperIdentityDigest: receipt.binding.helperIdentityDigest,
            providerOrigin: receipt.binding.providerOrigin,
            outputDirectoryDigest: receipt.binding.outputDirectoryDigest,
            targetSSIDDigest: receipt.binding.targetSSIDDigest,
            wifiDeviceDigest: receipt.binding.wifiDeviceDigest
        )
        guard nowUnixMilliseconds <= receipt.expiresAtUnixMilliseconds else {
            throw LiveProofError.expiredReceipt
        }
        let expected = try authenticationCode(
            for: LiveProofUnsignedArmingReceipt(receipt),
            secret: sidecarSecret
        )
        guard constantTimeEqual(expected, receipt.authenticationCode) else {
            throw LiveProofError.authenticationFailed
        }
    }

    public static func challengeMatches(
        _ challenge: Data,
        receipt: LiveProofArmingReceipt
    ) -> Bool {
        constantTimeEqual(ReadinessDigest.sha256Hex(challenge), receipt.challengeSHA256)
    }

    public static func writeSidecar(_ secret: Data, to url: URL) throws {
        guard secret.count == sidecarByteCount else {
            throw LiveProofError.invalidValue("sidecar secret must contain 32 bytes")
        }
        try requireSameSecureParent(url, url)
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw LiveProofError.fileOperation("could not create arming sidecar: errno \(errno)")
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw LiveProofError.fileOperation("could not secure arming sidecar: errno \(errno)")
        }
        try writeAll(secret, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw LiveProofError.fileOperation("could not sync arming sidecar: errno \(errno)")
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    public static func consume(
        receipt: LiveProofArmingReceipt,
        sidecarURL: URL,
        markerURL: URL,
        nowUnixMilliseconds: Int64
    ) throws {
        try requireSameSecureParent(sidecarURL, markerURL)
        guard sidecarURL.standardizedFileURL != markerURL.standardizedFileURL else {
            throw LiveProofError.unsafeFile("sidecar and marker paths must differ")
        }
        try rejectExistingMarker(markerURL)
        var secret: Data
        do {
            secret = try readSidecar(sidecarURL)
        } catch {
            if markerExists(markerURL) { throw LiveProofError.receiptAlreadyConsumed }
            throw error
        }
        defer { secret.resetBytes(in: 0..<secret.count) }
        try verify(
            receipt: receipt,
            sidecarSecret: secret,
            nowUnixMilliseconds: nowUnixMilliseconds
        )
        try createConsumptionMarker(receipt: receipt, at: markerURL)
        try syncDirectory(markerURL.deletingLastPathComponent())
        guard Darwin.unlink(sidecarURL.path) == 0 else {
            throw LiveProofError.fileOperation("could not unlink consumed sidecar: errno \(errno)")
        }
        try syncDirectory(markerURL.deletingLastPathComponent())
    }

    private static func authenticationCode(
        for unsigned: LiveProofUnsignedArmingReceipt,
        secret: Data
    ) throws -> String {
        let bytes = try LiveProofCanonicalJSON.encode(unsigned)
        let code = HMAC<SHA256>.authenticationCode(
            for: bytes,
            using: SymmetricKey(data: secret)
        )
        return LiveProofBase64URL.encode(Data(code))
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = left.count ^ right.count
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            difference |= Int(a ^ b)
        }
        return difference == 0
    }

    private static func readSidecar(_ url: URL) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LiveProofError.unsafeFile("arming sidecar is unavailable")
        }
        defer { _ = Darwin.close(descriptor) }
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600,
              info.st_uid == geteuid(),
              info.st_size == sidecarByteCount else {
            throw LiveProofError.unsafeFile("arming sidecar is not an owned mode-0600 file")
        }
        var data = Data(count: sidecarByteCount)
        let readCount = data.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, sidecarByteCount)
        }
        guard readCount == sidecarByteCount else {
            throw LiveProofError.fileOperation("could not read complete arming sidecar")
        }
        return data
    }

    private static func createConsumptionMarker(
        receipt: LiveProofArmingReceipt,
        at url: URL
    ) throws {
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            if errno == EEXIST { throw LiveProofError.receiptAlreadyConsumed }
            throw LiveProofError.fileOperation("could not create consumption marker: errno \(errno)")
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw LiveProofError.fileOperation("could not secure consumption marker: errno \(errno)")
        }
        let marker = Data(ReadinessDigest.sha256Hex(
            try LiveProofCanonicalJSON.encode(receipt)
        ).utf8)
        try writeAll(marker, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw LiveProofError.fileOperation("could not sync consumption marker: errno \(errno)")
        }
    }

    private static func rejectExistingMarker(_ url: URL) throws {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 {
            throw LiveProofError.receiptAlreadyConsumed
        }
        guard errno == ENOENT else {
            throw LiveProofError.fileOperation("could not inspect consumption marker: errno \(errno)")
        }
    }

    private static func markerExists(_ url: URL) -> Bool {
        var info = stat()
        return Darwin.lstat(url.path, &info) == 0
    }

    private static func requireSameSecureParent(_ lhs: URL, _ rhs: URL) throws {
        let left = lhs.deletingLastPathComponent().standardizedFileURL
        let right = rhs.deletingLastPathComponent().standardizedFileURL
        guard left == right else {
            throw LiveProofError.unsafeFile("arming artifacts must share one directory")
        }
        var info = stat()
        guard Darwin.lstat(left.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700,
              info.st_uid == geteuid() else {
            throw LiveProofError.unsafeFile("arming directory must be owned mode-0700")
        }
    }

    private static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LiveProofError.unsafeFile("could not open arming directory")
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw LiveProofError.fileOperation("could not sync arming directory: errno \(errno)")
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard count > 0 else {
                    throw LiveProofError.fileOperation("short artifact write: errno \(errno)")
                }
                offset += count
            }
        }
    }
}

private struct LiveProofUnsignedArmingReceipt: Codable {
    let schema: String
    let issuedAtUnixMilliseconds: Int64
    let expiresAtUnixMilliseconds: Int64
    let challengeSHA256: String
    let binding: LiveProofArmingBinding

    enum CodingKeys: String, CodingKey {
        case schema
        case issuedAtUnixMilliseconds = "issued_at_unix_milliseconds"
        case expiresAtUnixMilliseconds = "expires_at_unix_milliseconds"
        case challengeSHA256 = "challenge_sha256"
        case binding
    }

    init(
        issuedAtUnixMilliseconds: Int64,
        expiresAtUnixMilliseconds: Int64,
        challengeSHA256: String,
        binding: LiveProofArmingBinding
    ) {
        schema = LiveProofArmingReceipt.schema
        self.issuedAtUnixMilliseconds = issuedAtUnixMilliseconds
        self.expiresAtUnixMilliseconds = expiresAtUnixMilliseconds
        self.challengeSHA256 = challengeSHA256
        self.binding = binding
    }

    init(_ receipt: LiveProofArmingReceipt) {
        self.init(
            issuedAtUnixMilliseconds: receipt.issuedAtUnixMilliseconds,
            expiresAtUnixMilliseconds: receipt.expiresAtUnixMilliseconds,
            challengeSHA256: receipt.challengeSHA256,
            binding: receipt.binding
        )
    }
}
