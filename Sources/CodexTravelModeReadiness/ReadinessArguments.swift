import Foundation

public enum ReadinessMode: String, Sendable {
    case preflight
    case live
}

public struct ReadinessArguments: Equatable, Sendable {
    public var mode: ReadinessMode
    public var appBundleURL: URL?
    public var heartbeatConfigurationURL: URL?
    public var receiptURL: URL?
    public var outputURL: URL
    public var scenarios: [ReadinessScenario]
    public var closedLidSeconds: Int

    public static let usage = """
    Usage:
      scripts/run_live_travel_mode_proof --preflight --app ABSOLUTE_APP --heartbeat-config MODE_0600_JSON --output NEW_DIRECTORY
      scripts/run_live_travel_mode_proof --live --app SAME_ABSOLUTE_APP --receipt ARMING_RECEIPT --output SAME_DIRECTORY [--scenario stop|quit|owner-death] [--closed-lid-seconds 30...90]
    """

    public static func parse(_ arguments: [String]) throws -> Self {
        var parser = ReadinessArgumentCursor(arguments)
        let parsed = try parser.parse()
        try parsed.validate()
        return parsed
    }

    private func validate() throws {
        guard outputURL.path.hasPrefix("/") else {
            throw ReadinessHarnessError.invalidArguments("--output must be absolute")
        }
        guard (30...90).contains(closedLidSeconds) else {
            throw ReadinessHarnessError.invalidArguments("--closed-lid-seconds must be 30...90")
        }
        switch mode {
        case .preflight:
            guard let appBundleURL, let heartbeatConfigurationURL,
                  appBundleURL.path.hasPrefix("/"), heartbeatConfigurationURL.path.hasPrefix("/") else {
                throw ReadinessHarnessError.invalidArguments(
                    "preflight requires absolute --app and --heartbeat-config paths"
                )
            }
            guard receiptURL == nil else {
                throw ReadinessHarnessError.invalidArguments("preflight does not accept --receipt")
            }
        case .live:
            guard let receiptURL, receiptURL.path.hasPrefix("/"),
                  let appBundleURL, appBundleURL.path.hasPrefix("/") else {
                throw ReadinessHarnessError.invalidArguments(
                    "live requires absolute --app and --receipt paths"
                )
            }
            guard heartbeatConfigurationURL == nil else {
                throw ReadinessHarnessError.invalidArguments(
                    "live uses the provider configuration retained by the observer"
                )
            }
        }
    }
}

private struct ReadinessArgumentCursor {
    private var arguments: [String]
    private var index = 0
    private var mode: ReadinessMode?
    private var app: URL?
    private var heartbeat: URL?
    private var receipt: URL?
    private var output: URL?
    private var scenarios: [ReadinessScenario] = []
    private var closedLidSeconds = 60

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func parse() throws -> ReadinessArguments {
        while index < arguments.count {
            try consume(arguments[index])
        }
        let selectedMode = mode ?? .preflight
        guard let output else {
            throw ReadinessHarnessError.invalidArguments("--output is required")
        }
        return ReadinessArguments(
            mode: selectedMode,
            appBundleURL: app,
            heartbeatConfigurationURL: heartbeat,
            receiptURL: receipt,
            outputURL: output,
            scenarios: scenarios.isEmpty ? ReadinessScenario.allCases : scenarios,
            closedLidSeconds: closedLidSeconds
        )
    }

    private mutating func consume(_ argument: String) throws {
        index += 1
        switch argument {
        case "--preflight": try setMode(.preflight)
        case "--live": try setMode(.live)
        case "--app": app = try absoluteURL(value(after: argument))
        case "--heartbeat-config": heartbeat = try absoluteURL(value(after: argument))
        case "--receipt": receipt = try absoluteURL(value(after: argument))
        case "--output": output = try absoluteURL(value(after: argument))
        case "--scenario": scenarios.append(try scenario(value(after: argument)))
        case "--closed-lid-seconds": closedLidSeconds = try integer(value(after: argument))
        case "--help", "-h": throw ReadinessHarnessError.helpRequested
        default: throw ReadinessHarnessError.invalidArguments("unknown argument: \(argument)")
        }
    }

    private mutating func value(after option: String) throws -> String {
        guard index < arguments.count else {
            throw ReadinessHarnessError.invalidArguments("missing value after \(option)")
        }
        defer { index += 1 }
        return arguments[index]
    }

    private mutating func setMode(_ requested: ReadinessMode) throws {
        guard mode == nil || mode == requested else {
            throw ReadinessHarnessError.invalidArguments("choose exactly one mode")
        }
        mode = requested
    }

    private func absoluteURL(_ value: String) throws -> URL {
        guard value.hasPrefix("/") else {
            throw ReadinessHarnessError.invalidArguments("path must be absolute")
        }
        return URL(fileURLWithPath: value).standardizedFileURL
    }

    private func integer(_ value: String) throws -> Int {
        guard let parsed = Int(value) else {
            throw ReadinessHarnessError.invalidArguments("invalid integer: \(value)")
        }
        return parsed
    }

    private func scenario(_ value: String) throws -> ReadinessScenario {
        let normalized = value == "owner-death" ? "owner_death" : value
        guard let parsed = ReadinessScenario(rawValue: normalized), !scenarios.contains(parsed) else {
            throw ReadinessHarnessError.invalidArguments("invalid or duplicate scenario: \(value)")
        }
        return parsed
    }
}

public enum ReadinessHarnessError: LocalizedError, Equatable, Sendable {
    case helpRequested
    case invalidArguments(String)
    case readinessBlocked(String)
    case unsafeArtifact(String)
    case commandFailed(String)
    case providerFailed(String)
    case receiptRejected(String)
    case liveInterrupted(String)

    public var errorDescription: String? {
        switch self {
        case .helpRequested: ReadinessArguments.usage
        case .invalidArguments(let detail): "Invalid arguments: \(detail)"
        case .readinessBlocked(let detail): "Readiness blocked: \(detail)"
        case .unsafeArtifact(let detail): "Unsafe evidence artifact: \(detail)"
        case .commandFailed(let detail): "Read-only system query failed: \(detail)"
        case .providerFailed(let detail): "Heartbeat provider rejected: \(detail)"
        case .receiptRejected(let detail): "Arming receipt rejected: \(detail)"
        case .liveInterrupted(let detail): "Live scenario interrupted: \(detail)"
        }
    }
}
