import CodexTravelModeReadiness
import Darwin
import Foundation

@main
enum OracleMain {
    static func main() {
        let code = OracleCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        Darwin.exit(code)
    }
}

private enum OracleCLI {
    static func run(arguments: [String]) -> Int32 {
        do {
            let input = try OracleArguments.parse(arguments)
            let oracle = try POSIXLiveOracleIdentityProvider().currentIdentity()
            try input.requireDistinct(from: oracle)
            let fileAccess = POSIXLiveOracleFileAccess()
            try input.requireEvidenceRoleBindings(fileAccess: fileAccess)
            let report = try LiveTravelModeOracle.run(
                request: LiveOracleRequest(
                    evidenceDirectory: input.evidenceDirectory,
                    oracle: oracle,
                    expectedOwnerUID: input.expectedOwnerUID
                ),
                fileAccess: fileAccess
            )
            emit(report)
            return report.verdict == .accept ? 0 : 1
        } catch let error as OracleCLIError {
            emitReject(error.issueCode)
            return error.exitCode
        } catch {
            emitReject("oracle_execution_failed")
            return 1
        }
    }

    private static func emit(_ report: LiveOracleReport) {
        writeLine("verdict:\(report.verdict.rawValue)")
        for code in report.issueCodes { writeLine("issue:\(code)") }
    }

    private static func emitReject(_ issue: String) {
        writeLine("verdict:reject")
        writeLine("issue:\(issue)")
    }

    private static func writeLine(_ value: String) {
        try? FileHandle.standardOutput.write(contentsOf: Data((value + "\n").utf8))
    }
}

private struct OracleArguments {
    let evidenceDirectory: URL
    let expectedOwnerUID: UInt32
    let controller: LiveProofProcessIdentity
    let observer: LiveProofProcessIdentity

    static func parse(_ arguments: [String]) throws -> Self {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            guard Self.options.contains(option), values[option] == nil,
                  index < arguments.count else {
                throw OracleCLIError.invalidArguments
            }
            values[option] = arguments[index]
            index += 1
        }
        guard values.count == options.count,
              let directory = values["--evidence-directory"],
              directory.hasPrefix("/"),
              let owner = values["--expected-owner-uid"].flatMap(canonicalUInt32),
              let controller = try identity(prefix: "controller", values: values),
              let observer = try identity(prefix: "observer", values: values) else {
            throw OracleCLIError.invalidArguments
        }
        return Self(
            evidenceDirectory: URL(fileURLWithPath: directory).standardizedFileURL,
            expectedOwnerUID: owner,
            controller: controller,
            observer: observer
        )
    }

    func requireDistinct(from oracle: LiveProofProcessIdentity) throws {
        let identities = [controller, observer, oracle]
        guard Set(identities.map(\.pid)).count == identities.count,
              Set(identities.map(\.startIdentity)).count == identities.count,
              Set(identities.map(\.executableSHA256)).count == identities.count else {
            throw OracleCLIError.roleIdentityNotDistinct
        }
    }

    func requireEvidenceRoleBindings(
        fileAccess: any LiveOracleFileAccess
    ) throws {
        guard let preflight = try? decode(
            "preflight-readback.json",
            as: LiveOraclePreflightReadback.self,
            fileAccess: fileAccess
        ), let command = try? decode(
            "command-events.json",
            as: LiveOracleControllerArtifact.self,
            fileAccess: fileAccess
        ) else {
            return
        }
        guard preflight.producer == observer, command.producer == controller else {
            throw OracleCLIError.expectedRoleIdentityMismatch
        }
    }

    private static func identity(
        prefix: String,
        values: [String: String]
    ) throws -> LiveProofProcessIdentity? {
        guard let rawPID = values["--\(prefix)-pid"],
              let pid = canonicalInt32(rawPID), pid > 0,
              let hash = values["--\(prefix)-hash"],
              LiveProofValidation.isSHA256Hex(hash),
              let start = values["--\(prefix)-start"], (1...256).contains(start.utf8.count),
              !start.contains("\n"), !start.contains("\r") else {
            return nil
        }
        return try LiveProofProcessIdentity(
            pid: pid,
            startIdentity: start,
            executableSHA256: hash
        )
    }

    private func decode<Value: Decodable>(
        _ name: String,
        as type: Value.Type,
        fileAccess: any LiveOracleFileAccess
    ) throws -> Value {
        let file = try fileAccess.read(name: name, in: evidenceDirectory)
        return try LiveProofCanonicalJSON.decode(type, from: file.data)
    }

    private static func canonicalUInt32(_ value: String) -> UInt32? {
        guard let parsed = UInt32(value), String(parsed) == value else { return nil }
        return parsed
    }

    private static func canonicalInt32(_ value: String) -> Int32? {
        guard let parsed = Int32(value), String(parsed) == value else { return nil }
        return parsed
    }

    private static let options: Set<String> = [
        "--evidence-directory",
        "--expected-owner-uid",
        "--controller-pid",
        "--controller-hash",
        "--controller-start",
        "--observer-pid",
        "--observer-hash",
        "--observer-start",
    ]
}

private enum OracleCLIError: Error {
    case invalidArguments
    case roleIdentityNotDistinct
    case expectedRoleIdentityMismatch

    var issueCode: String {
        switch self {
        case .invalidArguments: "invalid_arguments"
        case .roleIdentityNotDistinct: "role_identity_not_distinct"
        case .expectedRoleIdentityMismatch: "expected_role_identity_mismatch"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .invalidArguments: 64
        case .roleIdentityNotDistinct, .expectedRoleIdentityMismatch: 1
        }
    }
}
