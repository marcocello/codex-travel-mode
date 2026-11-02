import CodexTravelModeSleepLease
import Foundation

public struct ProofPowerBackend: SleepOverridePowerBackend, Sendable {
    public let executableURL: URL
    public let stateURL: URL
    public let traceURL: URL
    public let controlURL: URL

    public init(
        executableURL: URL,
        stateURL: URL,
        traceURL: URL,
        controlURL: URL
    ) {
        self.executableURL = executableURL
        self.stateURL = stateURL
        self.traceURL = traceURL
        self.controlURL = controlURL
    }

    public func readSleepDisabled() async throws -> Bool {
        let output = try run(arguments: fixedArguments(operation: "read"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch output {
        case "true": return true
        case "false": return false
        default:
            throw SleepOverrideLeaseError.invalidResponse(
                "Fake power read returned an invalid value: \(output)"
            )
        }
    }

    public func setSleepDisabled(_ enabled: Bool) async throws {
        _ = try run(arguments: fixedArguments(operation: "write") + [String(enabled)])
    }

    private func fixedArguments(operation: String) -> [String] {
        [
            "--state", stateURL.path,
            "--trace", traceURL.path,
            "--control", controlURL.path,
            operation
        ]
    }

    private func run(arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SleepOverrideLeaseError.rejected(
                detail.isEmpty ? "The fixed fake power operation failed." : detail
            )
        }
        return String(decoding: outputData, as: UTF8.self)
    }
}

public actor ProofDeterministicLeaseClock: SleepOverrideLeaseClock {
    private struct Sleeper {
        var deadline: Date
        var continuation: CheckedContinuation<Void, Error>
    }

    private var current: Date
    private var sleepers: [UUID: Sleeper] = [:]
    private let traceURL: URL

    public init(
        initial: Date = Date(timeIntervalSince1970: 1_700_000_000),
        traceURL: URL
    ) {
        current = initial
        self.traceURL = traceURL
    }

    public func now() -> Date {
        current
    }

    public func sleep(for duration: Duration) async throws {
        let id = UUID()
        let deadline = current.addingTimeInterval(duration.timeInterval)
        try appendClockTrace(milliseconds: duration.milliseconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelSleeper(id: id) }
        }
    }

    public func advance(milliseconds: Int) {
        current = current.addingTimeInterval(Double(milliseconds) / 1_000)
        let ready = sleepers.filter { $0.value.deadline <= current }
        for (id, sleeper) in ready {
            sleepers.removeValue(forKey: id)
            sleeper.continuation.resume()
        }
    }

    public func scheduledSleeperCount() -> Int {
        sleepers.count
    }

    private func cancelSleeper(id: UUID) {
        sleepers.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
    }

    private func appendClockTrace(milliseconds: Int) throws {
        let line = "\(milliseconds)\n"
        if !FileManager.default.fileExists(atPath: traceURL.path) {
            FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: traceURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line.utf8))
        try handle.synchronize()
    }
}

public actor ProofLeaseTransitionGate: SleepOverrideLeaseTransitionObserving {
    private let selectedPoint: SleepOverrideLeaseTransitionPoint?
    private let markerURL: URL?
    private let gateURL: URL?
    private let traceURL: URL

    public init(
        selectedPoint: SleepOverrideLeaseTransitionPoint?,
        markerURL: URL?,
        gateURL: URL?,
        traceURL: URL
    ) {
        self.selectedPoint = selectedPoint
        self.markerURL = markerURL
        self.gateURL = gateURL
        self.traceURL = traceURL
    }

    public func observe(_ transition: SleepOverrideLeaseTransition) async {
        try? appendTransition(transition)
        guard transition.point == selectedPoint, let markerURL else { return }
        try? JSONEncoder().encode(transitionArtifact(transition))
            .write(to: markerURL, options: .atomic)
        guard let gateURL else {
            try? await Task.sleep(for: .seconds(30))
            return
        }
        while !FileManager.default.fileExists(atPath: gateURL.path), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func appendTransition(_ transition: SleepOverrideLeaseTransition) throws {
        var data = try JSONEncoder().encode(transitionArtifact(transition))
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: traceURL.path) {
            FileManager.default.createFile(atPath: traceURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: traceURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    private func transitionArtifact(
        _ transition: SleepOverrideLeaseTransition
    ) -> ProofLeaseTransitionArtifact {
        ProofLeaseTransitionArtifact(
            point: transition.point,
            binding: transition.binding,
            revision: transition.revision
        )
    }
}

public struct ProofLeaseTransitionArtifact: Codable, Equatable, Sendable {
    public var point: SleepOverrideLeaseTransitionPoint
    public var binding: SleepOverrideLeaseBinding
    public var revision: UInt64

    public init(
        point: SleepOverrideLeaseTransitionPoint,
        binding: SleepOverrideLeaseBinding,
        revision: UInt64
    ) {
        self.point = point
        self.binding = binding
        self.revision = revision
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let components = self.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    var milliseconds: Int {
        Int((timeInterval * 1_000).rounded())
    }
}
