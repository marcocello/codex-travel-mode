import CryptoKit
import Darwin
import Foundation
import Security

public enum ReadinessDigest {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func salted(_ value: Data, salt: Data) -> String {
        var input = Data()
        input.append(salt)
        input.append(value)
        return sha256Hex(input)
    }

    public static func randomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ReadinessHarnessError.unsafeArtifact("secure random generation failed")
        }
        return data
    }
}

public final class ReadinessSecureArtifactWriter: @unchecked Sendable {
    public static let maximumJSONBytes = 4 * 1_024 * 1_024
    public static let maximumLogBytes = 64 * 1_024
    public let outputURL: URL

    public init(outputURL: URL, allowExistingEmptyDirectory: Bool) throws {
        self.outputURL = outputURL.standardizedFileURL
        try Self.prepareDirectory(
            self.outputURL,
            allowExistingEmptyDirectory: allowExistingEmptyDirectory
        )
    }

    public func writeNewJSON<Value: Encodable>(_ value: Value, named name: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumJSONBytes else {
            throw ReadinessHarnessError.unsafeArtifact("\(name) exceeds the JSON size limit")
        }
        try writeNew(data: data, named: name)
    }

    public func writeNew(data: Data, named name: String) throws {
        guard !name.contains("/"), !name.isEmpty else {
            throw ReadinessHarnessError.unsafeArtifact("invalid artifact name")
        }
        let url = outputURL.appendingPathComponent(name, isDirectory: false)
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixFailure("create", url: url) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw posixFailure("chmod", url: url) }
        try writeAll(data, descriptor: descriptor, url: url)
        guard Darwin.fsync(descriptor) == 0 else { throw posixFailure("fsync", url: url) }
    }

    public func appendLog(_ line: String) throws {
        let safe = line.replacingOccurrences(of: "\n", with: " ").prefix(512) + "\n"
        let url = outputURL.appendingPathComponent("system-proof.log")
        let flags = O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW
        let descriptor = Darwin.open(url.path, flags, 0o600)
        guard descriptor >= 0 else { throw posixFailure("open log", url: url) }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else { throw posixFailure("chmod log", url: url) }
        let current = Darwin.lseek(descriptor, 0, SEEK_END)
        let data = Data(safe.utf8)
        guard current >= 0, current + off_t(data.count) <= Self.maximumLogBytes else {
            throw ReadinessHarnessError.unsafeArtifact("system-proof.log exceeds its bound")
        }
        try writeAll(data, descriptor: descriptor, url: url)
        guard Darwin.fsync(descriptor) == 0 else { throw posixFailure("fsync log", url: url) }
    }

    private static func prepareDirectory(
        _ url: URL,
        allowExistingEmptyDirectory: Bool
    ) throws {
        var info = stat()
        if Darwin.lstat(url.path, &info) == 0 {
            guard allowExistingEmptyDirectory, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_mode & 0o777 == 0o700, info.st_uid == geteuid() else {
                throw ReadinessHarnessError.unsafeArtifact("output directory already exists or is unsafe")
            }
            let contents = try FileManager.default.contentsOfDirectory(atPath: url.path)
            guard contents.isEmpty else {
                throw ReadinessHarnessError.unsafeArtifact("output directory is not empty")
            }
            return
        }
        guard errno == ENOENT, Darwin.mkdir(url.path, 0o700) == 0 else {
            throw ReadinessHarnessError.unsafeArtifact("could not create private output directory")
        }
    }

    private func writeAll(_ data: Data, descriptor: Int32, url: URL) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), data.count - offset)
                guard count > 0 else { throw posixFailure("write", url: url) }
                offset += count
            }
        }
    }

    private func posixFailure(_ operation: String, url: URL) -> ReadinessHarnessError {
        .unsafeArtifact("\(operation) failed for \(url.lastPathComponent): errno \(errno)")
    }
}

public enum ReadinessFileSecurity {
    public static func requirePrivateRegularFile(_ url: URL) throws {
        var info = stat()
        guard Darwin.lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o777 == 0o600,
              info.st_uid == geteuid(),
              info.st_size > 0,
              info.st_size <= 64 * 1_024 else {
            throw ReadinessHarnessError.unsafeArtifact(
                "\(url.lastPathComponent) must be an owned regular mode-0600 file under 64 KiB"
            )
        }
    }
}

public enum ReadinessClock {
    public static func wallTime(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    public static func monotonicNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }
}
