import Darwin
import Foundation

public struct LiveOracleFile: Equatable, Sendable {
    public let data: Data
    public let metadata: LiveOracleFileMetadata

    public init(data: Data, metadata: LiveOracleFileMetadata) {
        self.data = data
        self.metadata = metadata
    }
}

public protocol LiveOracleFileAccess: Sendable {
    func directoryMetadata(at directory: URL) throws -> LiveOracleFileMetadata
    func names(in directory: URL) throws -> Set<String>
    func read(name: String, in directory: URL) throws -> LiveOracleFile
    func writeOracleReport(_ data: Data, in directory: URL) throws
}

public protocol LiveOracleIdentityProviding: Sendable {
    func currentIdentity() throws -> LiveProofProcessIdentity
}

public struct POSIXLiveOracleIdentityProvider: LiveOracleIdentityProviding {
    public init() {}

    public func currentIdentity() throws -> LiveProofProcessIdentity {
        let pid = getpid()
        return try LiveProofProcessIdentity(
            pid: pid,
            startIdentity: LiveControllerSystem.processStartIdentity(pid: pid),
            executableSHA256: LiveControllerSystem.sha256File(
                LiveControllerSystem.executableURL(pid: pid)
            )
        )
    }
}

public struct POSIXLiveOracleFileAccess: LiveOracleFileAccess {
    public static let maximumArtifactBytes = 16 * 1_024 * 1_024

    public init() {}

    public func directoryMetadata(at directory: URL) throws -> LiveOracleFileMetadata {
        var information = stat()
        guard Darwin.lstat(directory.path, &information) == 0 else {
            throw LiveOracleViolation("unsafe_evidence_directory")
        }
        return metadata(information)
    }

    public func names(in directory: URL) throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.allSatisfy(Self.isSafeName) else {
            throw LiveOracleViolation("unsafe_artifact_name")
        }
        return Set(names)
    }

    public func read(name: String, in directory: URL) throws -> LiveOracleFile {
        guard Self.isSafeName(name) else {
            throw LiveOracleViolation("unsafe_artifact_name")
        }
        let url = directory.appendingPathComponent(name, isDirectory: false)
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LiveOracleViolation("artifact_unreadable")
        }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_size > 0,
              before.st_size <= Self.maximumArtifactBytes else {
            throw LiveOracleViolation("unsafe_artifact_file")
        }
        let data = try readAll(descriptor: descriptor, byteCount: Int(before.st_size))
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0,
              stable(before, after) else {
            throw LiveOracleViolation("artifact_changed_during_read")
        }
        return LiveOracleFile(data: data, metadata: metadata(after))
    }

    public func writeOracleReport(_ data: Data, in directory: URL) throws {
        guard !data.isEmpty, data.count <= Self.maximumArtifactBytes else {
            throw LiveOracleViolation("oracle_report_size_invalid")
        }
        let url = directory.appendingPathComponent("oracle-report.json", isDirectory: false)
        let descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o400)
        )
        guard descriptor >= 0 else {
            throw LiveOracleViolation("oracle_report_already_exists")
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, 0o400) == 0 else {
            throw LiveOracleViolation("oracle_report_mode_failed")
        }
        try writeAll(data, descriptor: descriptor)
        guard Darwin.fsync(descriptor) == 0 else {
            throw LiveOracleViolation("oracle_report_sync_failed")
        }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_mode & 0o777 == 0o400,
              information.st_uid == geteuid(),
              information.st_size == data.count else {
            throw LiveOracleViolation("oracle_report_readback_failed")
        }
        try syncDirectory(directory)
    }

    private func readAll(descriptor: Int32, byteCount: Int) throws -> Data {
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
            guard count > 0 else {
                throw LiveOracleViolation("artifact_short_read")
            }
            offset += count
        }
        return data
    }

    private func writeAll(_ data: Data, descriptor: Int32) throws {
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
                    throw LiveOracleViolation("oracle_report_write_failed")
                }
                offset += count
            }
        }
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LiveOracleViolation("unsafe_evidence_directory")
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw LiveOracleViolation("oracle_directory_sync_failed")
        }
    }

    private func metadata(_ information: stat) -> LiveOracleFileMetadata {
        LiveOracleFileMetadata(
            byteCount: information.st_size,
            mode: UInt16(information.st_mode & 0o777),
            ownerUID: information.st_uid,
            isRegularFile: information.st_mode & S_IFMT == S_IFREG
        )
    }

    private func stable(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mode == rhs.st_mode
            && lhs.st_uid == rhs.st_uid
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }

    private static func isSafeName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".."
            && !name.contains("/") && !name.contains("\0")
    }
}

struct LiveOracleViolation: Error, Equatable, Sendable {
    let code: String

    init(_ code: String) {
        self.code = code
    }
}
