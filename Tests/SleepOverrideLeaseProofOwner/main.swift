import CodexTravelModeSleepLease
import CodexTravelModeSleepLeaseXPC
import Foundation
import SleepOverrideLeaseProofSupport

private struct OwnerArguments {
    var scenario: String
    var socketPath: String
    var credential: String
    var sessionID: String
    var requestID: String
    var artifactURL: URL
    var markerURL: URL?
    var bindingURL: URL?

    init(_ arguments: [String]) throws {
        let values = try Self.parse(arguments)
        guard let scenario = values["--scenario"],
              let socketPath = values["--socket"],
              let credential = values["--credential"],
              let sessionID = values["--session"],
              let requestID = values["--request"],
              let artifact = values["--artifact"] else {
            throw ProofLeaseSupportError.invalidArguments(Self.usage)
        }
        self.scenario = scenario
        self.socketPath = socketPath
        self.credential = credential
        self.sessionID = sessionID
        self.requestID = requestID
        artifactURL = URL(fileURLWithPath: artifact)
        markerURL = values["--marker"].map(URL.init(fileURLWithPath:))
        bindingURL = values["--binding"].map(URL.init(fileURLWithPath:))
    }

    private static func parse(_ arguments: [String]) throws -> [String: String] {
        var values: [String: String] = [:]
        var index = 1
        while index < arguments.count {
            guard index + 1 < arguments.count, arguments[index].hasPrefix("--") else {
                throw ProofLeaseSupportError.invalidArguments(usage)
            }
            values[arguments[index]] = arguments[index + 1]
            index += 2
        }
        return values
    }

    private static let usage = "Usage: sleep-override-lease-proof-owner --scenario NAME --socket PATH --credential TOKEN --session ID --request ID --artifact PATH [--marker PATH] [--binding PATH]"
}

private enum OwnerScenarioError: LocalizedError {
    case unsupported(String)
    case missingBinding

    var errorDescription: String? {
        switch self {
        case .unsupported(let scenario): "Unsupported owner scenario: \(scenario)"
        case .missingBinding: "This owner scenario requires --binding."
        }
    }
}

@main
private enum SleepOverrideLeaseProofOwnerMain {
    static func main() async {
        do {
            let arguments = try OwnerArguments(CommandLine.arguments)
            let transport = try await ProofSocketLeaseTransport(
                socketPath: arguments.socketPath,
                credential: arguments.credential
            )
            let client = TransportSleepOverrideLeaseClient(transport: transport)
            try await run(arguments, client: client)
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    private static func run(
        _ arguments: OwnerArguments,
        client: TransportSleepOverrideLeaseClient
    ) async throws {
        switch arguments.scenario {
        case "acquire-and-hold":
            try await acquireAndHold(arguments, client: client)
        case "roundtrip":
            try await roundTrip(arguments, client: client)
        case "resolve":
            try await resolve(arguments, client: client)
        case "status":
            try await status(arguments, client: client)
        case "release":
            try await release(arguments, client: client)
        case "acknowledge":
            try await acknowledge(arguments, client: client)
        default:
            throw OwnerScenarioError.unsupported(arguments.scenario)
        }
    }

    private static func acquireAndHold(
        _ arguments: OwnerArguments,
        client: TransportSleepOverrideLeaseClient
    ) async throws {
        let receipt = try await client.acquire(
            sessionID: arguments.sessionID,
            requestID: arguments.requestID
        )
        try writeArtifact(ProofOwnerArtifact(receipt: receipt), arguments: arguments)
        while true {
            try await Task.sleep(for: .seconds(30))
        }
    }

    private static func roundTrip(
        _ arguments: OwnerArguments,
        client: TransportSleepOverrideLeaseClient
    ) async throws {
        let first = try await client.acquire(
            sessionID: arguments.sessionID,
            requestID: arguments.requestID
        )
        let second = try await client.acquire(
            sessionID: arguments.sessionID,
            requestID: arguments.requestID
        )
        _ = try await client.status(binding: first.binding)
        let released = try await client.release(binding: first.binding)
        let releasedAgain = try await client.release(binding: first.binding)
        try writeArtifact(
            ProofOwnerArtifact(receipt: released, secondReceipt: releasedAgain),
            arguments: arguments
        )
        guard first == second else {
            throw SleepOverrideLeaseError.invalidReceipt
        }
    }

    private static func resolve(
        _ arguments: OwnerArguments,
        client: TransportSleepOverrideLeaseClient
    ) async throws {
        let resolution = try await client.resolve(
            sessionID: arguments.sessionID,
            requestID: arguments.requestID
        )
        switch resolution {
        case .authoritativeNotFound:
            try writeArtifact(
                ProofOwnerArtifact(resolution: "authoritative_not_found"),
                arguments: arguments
            )
        case .found(let receipt):
            try writeArtifact(
                ProofOwnerArtifact(receipt: receipt, resolution: receipt.phase.rawValue),
                arguments: arguments
            )
        }
    }

    private static func status(
        _ arguments: OwnerArguments,
        client: TransportSleepOverrideLeaseClient
    ) async throws {
        let receipt = try await client.status(binding: try loadBinding(arguments))
        try writeArtifact(ProofOwnerArtifact(receipt: receipt), arguments: arguments)
    }

    private static func release(
        _ arguments: OwnerArguments,
        client: TransportSleepOverrideLeaseClient
    ) async throws {
        let receipt = try await client.release(binding: try loadBinding(arguments))
        try writeArtifact(ProofOwnerArtifact(receipt: receipt), arguments: arguments)
    }

    private static func acknowledge(
        _ arguments: OwnerArguments,
        client: TransportSleepOverrideLeaseClient
    ) async throws {
        try await client.acknowledgeRelease(binding: try loadBinding(arguments))
        try writeArtifact(ProofOwnerArtifact(resolution: "acknowledged"), arguments: arguments)
    }

    private static func loadBinding(
        _ arguments: OwnerArguments
    ) throws -> SleepOverrideLeaseBinding {
        guard let bindingURL = arguments.bindingURL else {
            throw OwnerScenarioError.missingBinding
        }
        return try JSONDecoder().decode(
            SleepOverrideLeaseBinding.self,
            from: Data(contentsOf: bindingURL)
        )
    }

    private static func writeArtifact(
        _ artifact: ProofOwnerArtifact,
        arguments: OwnerArguments
    ) throws {
        try JSONEncoder().encode(artifact).write(to: arguments.artifactURL, options: .atomic)
        if let markerURL = arguments.markerURL {
            try Data("ready\n".utf8).write(to: markerURL, options: .atomic)
        }
    }
}
