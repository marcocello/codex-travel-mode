import CryptoKit
import Darwin
import Foundation

enum LiveControllerSystem {
    static let socketName = ".observer.sock"
    static let sidecarName = ".arming-sidecar"
    static let receiptName = "arming-receipt.json"
    static let consumedName = ".arming-consumed"

    static func millisecondsSinceEpoch(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    static func processStartIdentity(pid: Int32) throws -> String {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let read = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard read == size else {
            throw ReadinessHarnessError.readinessBlocked("could not identify process start")
        }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    static func executableURL(pid: Int32 = getpid()) throws -> URL {
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &path, UInt32(path.count))
        guard count > 0 else {
            throw ReadinessHarnessError.readinessBlocked("could not resolve executable")
        }
        return URL(
            fileURLWithPath: String(decoding: path.prefix(Int(count)), as: UTF8.self)
        ).standardizedFileURL
    }

    static func sha256File(_ url: URL, maximumBytes: UInt64? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var total: UInt64 = 0
        while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty {
            total += UInt64(chunk.count)
            if let maximumBytes, total > maximumBytes {
                throw ReadinessHarnessError.unsafeArtifact(
                    "\(url.lastPathComponent) exceeds its size bound"
                )
            }
            digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func boundExecutableDigest(_ url: URL, runID: String) throws -> String {
        ReadinessDigest.salted(
            Data(try sha256File(url).utf8),
            salt: Data(runID.utf8)
        )
    }

    static func requireOwnedPrivateDirectory(_ url: URL) throws {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o777 == 0o700,
              info.st_uid == geteuid() else {
            throw ReadinessHarnessError.unsafeArtifact(
                "output must be an owned mode-0700 directory"
            )
        }
    }

    static func writeExclusive(_ data: Data, to url: URL, finalMode: mode_t = 0o600) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw ReadinessHarnessError.unsafeArtifact(
                "could not exclusively create \(url.lastPathComponent)"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        try writeAll(data, descriptor: descriptor, label: url.lastPathComponent)
        guard Darwin.fsync(descriptor) == 0, Darwin.fchmod(descriptor, finalMode) == 0 else {
            throw ReadinessHarnessError.unsafeArtifact(
                "could not secure \(url.lastPathComponent)"
            )
        }
    }

    static func zeroize(_ data: inout Data) {
        _ = data.withUnsafeMutableBytes { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
        }
        data.removeAll(keepingCapacity: false)
    }

    static func syncDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw ReadinessHarnessError.unsafeArtifact(
                "could not open output directory for synchronization"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw ReadinessHarnessError.unsafeArtifact(
                "could not synchronize output directory"
            )
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32, label: String) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard written > 0 else {
                    throw ReadinessHarnessError.unsafeArtifact("could not write \(label)")
                }
                offset += written
            }
        }
    }
}

public struct ControllingTTYIO: LiveControllerTTYIO {
    public init() {}

    public func displayArmingChallenge(_ challenge: Data) throws {
        let descriptor = try openTTY()
        defer { _ = Darwin.close(descriptor) }
        let prefix = Data("Arming challenge (shown once; keep private): ".utf8)
        try write(prefix + challenge + Data("\n".utf8), to: descriptor)
    }

    public func readArmingChallenge() throws -> Data {
        let descriptor = try openTTY()
        defer { _ = Darwin.close(descriptor) }
        try write(Data("Enter arming challenge: ".utf8), to: descriptor)
        var bytes = Data()
        var byte: UInt8 = 0
        while bytes.count <= 128 {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count == 1 else {
                throw ReadinessHarnessError.receiptRejected("controlling TTY input ended")
            }
            if byte == 10 || byte == 13 { break }
            bytes.append(byte)
        }
        guard !bytes.isEmpty, bytes.count <= 128 else {
            throw ReadinessHarnessError.receiptRejected("arming challenge is invalid")
        }
        return bytes
    }

    private func openTTY() throws -> Int32 {
        let descriptor = Darwin.open("/dev/tty", O_RDWR | O_NOFOLLOW)
        guard descriptor >= 0, isatty(descriptor) == 1 else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw ReadinessHarnessError.receiptRejected(
                "live arming requires a controlling TTY"
            )
        }
        return descriptor
    }

    private func write(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard count > 0 else {
                    throw ReadinessHarnessError.receiptRejected(
                        "could not access controlling TTY"
                    )
                }
                offset += count
            }
        }
    }
}
