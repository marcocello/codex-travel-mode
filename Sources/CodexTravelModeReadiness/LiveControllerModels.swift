import Foundation

struct LiveControllerObserverArguments: Equatable, Sendable {
    let outputURL: URL
    let runID: String
    let controllerHash: String
    let expiresAtMilliseconds: Int64

    static func parse(_ arguments: [String]) throws -> Self? {
        guard arguments.contains("--observer") else { return nil }
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            index += 1
            if option == "--observer" { continue }
            guard ["--output", "--run-id", "--controller-hash", "--expires-at-milliseconds"]
                .contains(option),
                  index < arguments.count,
                  values[option] == nil else {
                throw ReadinessHarnessError.invalidArguments("invalid observer arguments")
            }
            values[option] = arguments[index]
            index += 1
        }
        guard let output = values["--output"], output.hasPrefix("/"),
              let runID = values["--run-id"],
              UUID(uuidString: runID)?.uuidString.lowercased() == runID,
              let controllerHash = values["--controller-hash"],
              controllerHash.count == 64,
              let expiration = values["--expires-at-milliseconds"],
              let expiresAtMilliseconds = Int64(expiration) else {
            throw ReadinessHarnessError.invalidArguments("invalid observer arguments")
        }
        return Self(
            outputURL: URL(fileURLWithPath: output).standardizedFileURL,
            runID: runID,
            controllerHash: controllerHash,
            expiresAtMilliseconds: expiresAtMilliseconds
        )
    }
}

struct LiveObserverHandshakeRequest: Codable, Sendable {
    let schema: String
    let handshake: LiveProofHandshakePayload
    let expiresAtMilliseconds: Int64?
    let receipt: LiveProofArmingReceipt?

    enum CodingKeys: String, CodingKey {
        case schema
        case handshake
        case expiresAtMilliseconds = "expires_at_milliseconds"
        case receipt
    }
}

struct LiveObserverHandshakeResponse: Codable, Sendable {
    let observer: LiveProofProcessIdentity
    let observerPublicKey: String
    let signedHandshake: LiveProofSignedPayload

    enum CodingKeys: String, CodingKey {
        case observer
        case observerPublicKey = "observer_public_key"
        case signedHandshake = "signed_handshake"
    }
}

struct LiveObserverBindingRequest: Codable, Sendable {
    let schema: String
    let requestSequence: Int
    let receipt: LiveProofArmingReceipt

    enum CodingKeys: String, CodingKey {
        case schema
        case requestSequence = "request_sequence"
        case receipt
    }
}

struct LiveObserverPreflightContext: Codable, Sendable {
    let schema: String
    let requestSequence: Int
    let providerConfiguration: Data
    let appBundlePath: String
    let helperExecutablePath: String

    enum CodingKeys: String, CodingKey {
        case schema
        case requestSequence = "request_sequence"
        case providerConfiguration = "provider_configuration"
        case appBundlePath = "app_bundle_path"
        case helperExecutablePath = "helper_executable_path"
    }
}

struct LiveObserverPreflightBindingFacts: Codable, Equatable, Sendable {
    let schema: String
    let requestSequence: Int
    let machineDigest: String
    let baselineDigest: String
    let appIdentityDigest: String
    let helperIdentityDigest: String
    let providerOrigin: String
    let targetSSIDDigest: String
    let wifiDeviceDigest: String

    enum CodingKeys: String, CodingKey {
        case schema
        case requestSequence = "request_sequence"
        case machineDigest = "machine_digest"
        case baselineDigest = "baseline_digest"
        case appIdentityDigest = "app_identity_digest"
        case helperIdentityDigest = "helper_identity_digest"
        case providerOrigin = "provider_origin"
        case targetSSIDDigest = "target_ssid_digest"
        case wifiDeviceDigest = "wifi_device_digest"
    }
}

struct LiveObserverAcknowledgement: Codable, Sendable {
    let schema: String
    let requestSequence: Int
    let action: String
    let disposition: String

    enum CodingKeys: String, CodingKey {
        case schema
        case requestSequence = "request_sequence"
        case action
        case disposition
    }
}

public enum LiveObserverProviderAction: String, Codable, Sendable {
    case capability
    case submit
    case readback
}

struct LiveObserverProviderRequest: Codable, Sendable {
    let schema: String
    let requestSequence: Int
    let action: LiveObserverProviderAction
    let submit: LiveProviderHeartbeatSubmit?
    let runID: String?
    let scenario: ReadinessScenario?

    enum CodingKeys: String, CodingKey {
        case schema
        case requestSequence = "request_sequence"
        case action
        case submit
        case runID = "run_id"
        case scenario
    }
}

struct LiveObserverFinishRequest: Codable, Sendable {
    let schema: String
    let requestSequence: Int
    let disposition: String
    let detailCode: String

    enum CodingKeys: String, CodingKey {
        case schema
        case requestSequence = "request_sequence"
        case disposition
        case detailCode = "detail_code"
    }
}

struct LiveObserverObservationRequest: Codable, Sendable {
    let schema: String
    let requestSequence: Int
    let scenario: ReadinessScenario
    let kind: LiveOracleObserverEventKind
    let process: LiveProofProcessIdentity?

    enum CodingKeys: String, CodingKey {
        case schema
        case requestSequence = "request_sequence"
        case scenario
        case kind
        case process
    }
}

struct LiveObserverUIValidationRequest: Codable, Sendable {
    let schema: String
    let requestSequence: Int
    let scenario: ReadinessScenario
}

public protocol LiveObserverProductionUIValidating: Sendable {
    func validate(
        app: LivePlatformResolvedProcess,
        expectedTargetSSID: String,
        expectedWiFiDevice: String
    ) throws
}

public struct UnavailableLiveObserverProductionUIValidator:
    LiveObserverProductionUIValidating {
    public init() {}

    public func validate(
        app: LivePlatformResolvedProcess,
        expectedTargetSSID: String,
        expectedWiFiDevice: String
    ) throws {
        throw ReadinessHarnessError.readinessBlocked(
            "the production Accessibility UI reader is not configured"
        )
    }
}

public struct ProductionLiveObserverUIValidator:
    LiveObserverProductionUIValidating, Sendable {
    public init() {}

    public func validate(
        app: LivePlatformResolvedProcess,
        expectedTargetSSID: String,
        expectedWiFiDevice: String
    ) throws {
        let box = LiveObserverUIValidationResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                _ = try await LivePlatformProductionUIValidator(
                    reader: LivePlatformProductionUIAXReader()
                ).validate(
                    app: app,
                    expectedTargetSSID: expectedTargetSSID,
                    expectedWiFiDevice: expectedWiFiDevice
                )
                box.store(.success(()))
            } catch {
                box.store(.failure(error))
            }
            semaphore.signal()
        }
        semaphore.wait()
        try box.take().get()
    }
}

private final class LiveObserverUIValidationResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?

    func store(_ result: Result<Void, Error>) {
        lock.withLock { self.result = result }
    }

    func take() -> Result<Void, Error> {
        lock.withLock {
            result ?? .failure(
                ReadinessHarnessError.liveInterrupted(
                    "production UI validation did not complete"
                )
            )
        }
    }
}

public enum LiveObserverProviderCommand: Sendable {
    case capability
    case submit(LiveProviderHeartbeatSubmit)
    case readback(runID: String, scenario: ReadinessScenario)
}

public protocol LiveObserverProviderCommandPerforming: Sendable {
    func perform(_ command: LiveObserverProviderCommand) throws
}

enum LiveObserverProviderObservation: Sendable {
    case capability(LiveProviderCapabilityObservation)
    case submit(LiveProviderSubmitObservation)
    case readback(LiveProviderHeartbeatReadback)
}

protocol LiveObserverProviderObservationPerforming:
    LiveObserverProviderCommandPerforming {
    func performObserved(
        _ command: LiveObserverProviderCommand
    ) throws -> LiveObserverProviderObservation
}

public struct UnavailableLiveObserverProviderCommandPerformer:
    LiveObserverProviderCommandPerforming {
    public init() {}

    public func perform(_ command: LiveObserverProviderCommand) throws {
        throw ReadinessHarnessError.readinessBlocked(
            "the observer provider transport adapter is not configured"
        )
    }
}

public protocol LiveControllerTTYIO: Sendable {
    func displayArmingChallenge(_ challenge: Data) throws
    func readArmingChallenge() throws -> Data
}

public protocol LiveControllerActionPerforming: Sendable {
    func performLive(
        arguments: ReadinessArguments,
        observer: LiveObserverClientSession
    ) async throws
}

public struct UnavailableLiveControllerActionPerformer: LiveControllerActionPerforming {
    public init() {}

    public func performLive(
        arguments: ReadinessArguments,
        observer: LiveObserverClientSession
    ) async throws {
        throw ReadinessHarnessError.readinessBlocked(
            "the production live-action adapter is not configured"
        )
    }
}
