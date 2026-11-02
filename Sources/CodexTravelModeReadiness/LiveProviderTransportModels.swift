import Foundation

public enum LiveProviderTransportError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case responseTooLarge
    case redirectRejected
    case clockSkew(Int64)
    case missingTaskMetrics
    case observationMismatch(String)
}

public struct LiveProviderCapability: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-heartbeat-capability/v1"
    public static let heartbeatProtocol = "codex-travel-mode-heartbeat/v1"

    public let schema: String
    public let protocolName: String
    public let capabilityPath: String
    public let submitPath: String
    public let readbackPath: String
    public let serverUnixMilliseconds: Int64
    public let maximumClockSkewSeconds: Int

    enum CodingKeys: String, CodingKey {
        case schema
        case protocolName = "protocol"
        case capabilityPath = "capability_path"
        case submitPath = "submit_path"
        case readbackPath = "readback_path"
        case serverUnixMilliseconds = "server_unix_milliseconds"
        case maximumClockSkewSeconds = "maximum_clock_skew_seconds"
    }

    public init(
        capabilityPath: String,
        submitPath: String,
        readbackPath: String,
        serverUnixMilliseconds: Int64,
        maximumClockSkewSeconds: Int
    ) throws {
        guard serverUnixMilliseconds >= 0, (0...30).contains(maximumClockSkewSeconds) else {
            throw LiveProviderTransportError.invalidResponse("invalid capability time")
        }
        schema = Self.schema
        protocolName = Self.heartbeatProtocol
        self.capabilityPath = capabilityPath
        self.submitPath = submitPath
        self.readbackPath = readbackPath
        self.serverUnixMilliseconds = serverUnixMilliseconds
        self.maximumClockSkewSeconds = maximumClockSkewSeconds
    }

    public static func decodeStrict(
        _ data: Data,
        configuration: LiveProofProviderConfiguration
    ) throws -> Self {
        try LiveProofCanonicalJSON.requireObjectKeys(
            data,
            required: [
                "schema", "protocol", "capability_path", "submit_path", "readback_path",
                "server_unix_milliseconds", "maximum_clock_skew_seconds",
            ]
        )
        let decoded = try LiveProofCanonicalJSON.decode(Self.self, from: data)
        guard decoded.schema == schema, decoded.protocolName == heartbeatProtocol else {
            throw LiveProviderTransportError.invalidResponse("unsupported capability schema")
        }
        let validated = try Self(
            capabilityPath: decoded.capabilityPath,
            submitPath: decoded.submitPath,
            readbackPath: decoded.readbackPath,
            serverUnixMilliseconds: decoded.serverUnixMilliseconds,
            maximumClockSkewSeconds: decoded.maximumClockSkewSeconds
        )
        guard validated.capabilityPath == configuration.capabilityPath,
              validated.submitPath == configuration.submitPath,
              validated.readbackPath == configuration.readbackPath else {
            throw LiveProviderTransportError.invalidResponse("capability paths changed")
        }
        return validated
    }
}

public struct LiveProviderCapabilityObservation: Equatable, Sendable {
    public let capability: LiveProviderCapability
    public let requestStartedUnixMilliseconds: Int64
    public let responseEndedUnixMilliseconds: Int64
    public let serverMinusLocalMilliseconds: Int64

    public init(
        capability: LiveProviderCapability,
        requestStartedUnixMilliseconds: Int64,
        responseEndedUnixMilliseconds: Int64
    ) throws {
        guard requestStartedUnixMilliseconds >= 0,
              responseEndedUnixMilliseconds >= requestStartedUnixMilliseconds else {
            throw LiveProviderTransportError.invalidResponse("invalid capability timing")
        }
        let midpoint = requestStartedUnixMilliseconds
            + (responseEndedUnixMilliseconds - requestStartedUnixMilliseconds) / 2
        let skew = capability.serverUnixMilliseconds - midpoint
        let allowed = Int64(min(capability.maximumClockSkewSeconds, 30)) * 1_000
        guard skew.magnitude <= UInt64(allowed) else {
            throw LiveProviderTransportError.clockSkew(skew)
        }
        self.capability = capability
        self.requestStartedUnixMilliseconds = requestStartedUnixMilliseconds
        self.responseEndedUnixMilliseconds = responseEndedUnixMilliseconds
        serverMinusLocalMilliseconds = skew
    }
}

public struct LiveProviderHeartbeatSubmit: Codable, Equatable, Sendable {
    public static let schema = "codex-travel-mode-heartbeat-submit/v1"

    public let schema: String
    public let runID: String
    public let scenario: ReadinessScenario
    public let sequence: Int
    public let nonce: String
    public let unixMilliseconds: Int64

    enum CodingKeys: String, CodingKey {
        case schema
        case runID = "run_id"
        case scenario
        case sequence
        case nonce
        case unixMilliseconds = "unix_milliseconds"
    }

    public init(
        runID: String,
        scenario: ReadinessScenario,
        sequence: Int,
        nonce: String,
        unixMilliseconds: Int64
    ) throws {
        guard LiveProofValidation.isCanonicalRunID(runID),
              sequence > 0, unixMilliseconds >= 0 else {
            throw LiveProviderTransportError.invalidConfiguration("invalid heartbeat submit")
        }
        _ = try LiveProofBase64URL.decode(nonce, exactByteCount: 32)
        schema = Self.schema
        self.runID = runID
        self.scenario = scenario
        self.sequence = sequence
        self.nonce = nonce
        self.unixMilliseconds = unixMilliseconds
    }

    public static func fresh(
        runID: String,
        scenario: ReadinessScenario,
        sequence: Int,
        unixMilliseconds: Int64
    ) throws -> Self {
        try Self(
            runID: runID,
            scenario: scenario,
            sequence: sequence,
            nonce: LiveProofBase64URL.encode(
                ReadinessDigest.randomBytes(count: 32)
            ),
            unixMilliseconds: unixMilliseconds
        )
    }
}

public struct LiveProviderHeartbeatReadback: Equatable, Sendable {
    public static let schema = "codex-travel-mode-heartbeat-readback/v1"
    public let receipts: [LiveProofProviderReceipt]

    public init(receipts: [LiveProofProviderReceipt]) {
        self.receipts = receipts
    }

    public static func decodeStrict(_ data: Data) throws -> Self {
        try LiveProofCanonicalJSON.requireObjectKeys(
            data,
            required: ["schema", "receipts"]
        )
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              dictionary["schema"] as? String == schema,
              let rawReceipts = dictionary["receipts"] as? [[String: Any]] else {
            throw LiveProviderTransportError.invalidResponse("invalid readback schema")
        }
        let receipts = try rawReceipts.map { raw -> LiveProofProviderReceipt in
            let bytes = try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys])
            return try LiveProofProviderReceipt.decodeStrict(bytes)
        }
        return Self(receipts: receipts)
    }
}

public struct LiveProviderTaskMetric: Equatable, Sendable {
    public let localAddress: String?
    public let remoteAddress: String?
    public let fetchStartedUnixMilliseconds: Int64?
    public let responseEndedUnixMilliseconds: Int64?

    public init(
        localAddress: String?,
        remoteAddress: String?,
        fetchStartedUnixMilliseconds: Int64?,
        responseEndedUnixMilliseconds: Int64?
    ) {
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.fetchStartedUnixMilliseconds = fetchStartedUnixMilliseconds
        self.responseEndedUnixMilliseconds = responseEndedUnixMilliseconds
    }
}

public struct LiveProviderHTTPResponse: Equatable, Sendable {
    public let data: Data
    public let statusCode: Int
    public let finalURL: URL
    public let redirectAttempted: Bool
    public let taskMetrics: [LiveProviderTaskMetric]

    public init(
        data: Data,
        statusCode: Int,
        finalURL: URL,
        redirectAttempted: Bool = false,
        taskMetrics: [LiveProviderTaskMetric] = []
    ) {
        self.data = data
        self.statusCode = statusCode
        self.finalURL = finalURL
        self.redirectAttempted = redirectAttempted
        self.taskMetrics = taskMetrics
    }
}

public protocol LiveProviderHTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> LiveProviderHTTPResponse
}

public protocol LiveProviderBearerTokenReading: Sendable {
    func readToken(service: String, account: String) throws -> Data?
}

public protocol LiveProviderClock: Sendable {
    func nowUnixMilliseconds() -> Int64
}

public struct LiveProviderSystemClock: LiveProviderClock {
    public init() {}

    public func nowUnixMilliseconds() -> Int64 {
        Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
    }
}

public struct LiveProviderSubmitObservation: Equatable, Sendable {
    public let submit: LiveProviderHeartbeatSubmit
    public let dispatchedAtUnixMilliseconds: Int64
    public let completedAtUnixMilliseconds: Int64
    public let taskMetrics: [LiveProviderTaskMetric]

    public init(
        submit: LiveProviderHeartbeatSubmit,
        dispatchedAtUnixMilliseconds: Int64,
        completedAtUnixMilliseconds: Int64,
        taskMetrics: [LiveProviderTaskMetric]
    ) {
        self.submit = submit
        self.dispatchedAtUnixMilliseconds = dispatchedAtUnixMilliseconds
        self.completedAtUnixMilliseconds = completedAtUnixMilliseconds
        self.taskMetrics = taskMetrics
    }
}
