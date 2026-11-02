import Foundation

public enum SleepOverridePowerBackendError: LocalizedError, Equatable, Sendable {
    case launchFailed(String)
    case commandFailed(exitCode: Int32, detail: String)
    case invalidReadback(String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let detail):
            "The fixed pmset operation could not start: \(detail)"
        case .commandFailed(let exitCode, let detail):
            "The fixed pmset operation failed with exit code \(exitCode): \(detail)"
        case .invalidReadback(let detail):
            "The fixed pmset read-back was invalid: \(detail)"
        }
    }
}

public actor FixedPmsetSleepOverridePowerBackend: SleepOverridePowerBackend {
    private static let executableURL = URL(fileURLWithPath: "/usr/bin/pmset")

    public init() {}

    public func readSleepDisabled() async throws -> Bool {
        let output = try runFixedPmset(arguments: ["-g"])
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == "SleepDisabled" else { continue }
            if fields[1] == "0" { return false }
            if fields[1] == "1" { return true }
            throw SleepOverridePowerBackendError.invalidReadback(String(line))
        }
        throw SleepOverridePowerBackendError.invalidReadback(
            "pmset did not report the system-wide SleepDisabled value."
        )
    }

    public func setSleepDisabled(_ enabled: Bool) async throws {
        _ = try runFixedPmset(
            arguments: ["-a", "disablesleep", enabled ? "1" : "0"]
        )
    }

    private func runFixedPmset(arguments: [String]) throws -> String {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = Self.executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError
        do {
            try process.run()
        } catch {
            throw SleepOverridePowerBackendError.launchFailed(error.localizedDescription)
        }
        process.waitUntilExit()
        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        let detail = String(decoding: errorData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            throw SleepOverridePowerBackendError.commandFailed(
                exitCode: process.terminationStatus,
                detail: detail
            )
        }
        return output
    }
}
