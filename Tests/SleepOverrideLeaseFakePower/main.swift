import Darwin
import Foundation
import SleepOverrideLeaseProofSupport

private struct FakePowerArguments {
    var stateURL: URL
    var traceURL: URL
    var controlURL: URL
    var operation: String
    var requestedValue: Bool?

    init(_ arguments: [String]) throws {
        guard arguments.count == 8 || arguments.count == 9,
              arguments[1] == "--state",
              arguments[3] == "--trace",
              arguments[5] == "--control" else {
            throw ProofLeaseSupportError.invalidArguments(Self.usage)
        }
        stateURL = URL(fileURLWithPath: arguments[2])
        traceURL = URL(fileURLWithPath: arguments[4])
        controlURL = URL(fileURLWithPath: arguments[6])
        operation = arguments[7]
        if operation == "read", arguments.count == 8 {
            requestedValue = nil
        } else if operation == "write", arguments.count == 9 {
            guard let value = Self.parseBoolean(arguments[8]) else {
                throw ProofLeaseSupportError.invalidArguments(Self.usage)
            }
            requestedValue = value
        } else {
            throw ProofLeaseSupportError.invalidArguments(Self.usage)
        }
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private static let usage = "Usage: sleep-override-lease-fake-power --state PATH --trace PATH --control PATH read|write [true|false]"
}

private enum FakePowerFailure: LocalizedError {
    case injectedRead
    case injectedWrite

    var errorDescription: String? {
        switch self {
        case .injectedRead: "Injected SleepDisabled read failure."
        case .injectedWrite: "Injected SleepDisabled write failure."
        }
    }
}

private func withExclusiveLock<Result>(at url: URL, operation: () throws -> Result) throws -> Result {
    let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
        throw ProofLeaseSupportError.socket("Could not open fake-power lock file.")
    }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX) == 0 else {
        throw ProofLeaseSupportError.socket("Could not lock fake-power state.")
    }
    defer { flock(descriptor, LOCK_UN) }
    return try operation()
}

private func readJSON<Value: Decodable>(_ type: Value.Type, at url: URL) throws -> Value {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
}

private func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
    let data = try JSONEncoder().encode(value)
    try data.write(to: url, options: .atomic)
}

private func loadControl(at url: URL) throws -> ProofPowerControl {
    guard FileManager.default.fileExists(atPath: url.path) else {
        let control = ProofPowerControl()
        try writeJSON(control, to: url)
        return control
    }
    return try readJSON(ProofPowerControl.self, at: url)
}

private func traceCount(at url: URL) throws -> Int {
    guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
    let data = try Data(contentsOf: url)
    return data.split(separator: 0x0A).filter { !$0.isEmpty }.count
}

private func appendTrace(_ entry: ProofPowerTraceEntry, to url: URL) throws {
    var data = try JSONEncoder().encode(entry)
    data.append(0x0A)
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
    try handle.synchronize()
}

private func execute(_ arguments: FakePowerArguments) throws {
    let lockURL = arguments.stateURL.appendingPathExtension("lock")
    try withExclusiveLock(at: lockURL) {
        var state = try readJSON(ProofPowerState.self, at: arguments.stateURL)
        var control = try loadControl(at: arguments.controlURL)
        let sequence = try traceCount(at: arguments.traceURL) + 1
        let result = evaluate(arguments, state: &state, control: &control)
        try writeJSON(control, to: arguments.controlURL)
        if result.persistState {
            try writeJSON(state, to: arguments.stateURL)
        }
        let entry = ProofPowerTraceEntry(
            sequence: sequence,
            operation: arguments.operation,
            arguments: fixedOperationArguments(arguments),
            requestedValue: arguments.requestedValue,
            observedValue: state.sleepDisabled,
            succeeded: result.error == nil
        )
        try appendTrace(entry, to: arguments.traceURL)
        if let error = result.error { throw error }
        if arguments.operation == "read" {
            print(state.sleepDisabled ? "true" : "false")
        }
    }
}

private func evaluate(
    _ arguments: FakePowerArguments,
    state: inout ProofPowerState,
    control: inout ProofPowerControl
) -> (persistState: Bool, error: Error?) {
    if arguments.operation == "read", control.failReadsRemaining > 0 {
        control.failReadsRemaining -= 1
        return (false, FakePowerFailure.injectedRead)
    }
    if arguments.operation == "write", control.failWritesRemaining > 0 {
        control.failWritesRemaining -= 1
        return (false, FakePowerFailure.injectedWrite)
    }
    guard arguments.operation == "write", let requested = arguments.requestedValue else {
        return (false, nil)
    }
    if control.ignoreWritesRemaining > 0 {
        control.ignoreWritesRemaining -= 1
        return (false, nil)
    }
    state.sleepDisabled = requested
    return (true, nil)
}

private func fixedOperationArguments(_ arguments: FakePowerArguments) -> [String] {
    if let value = arguments.requestedValue {
        return ["write", String(value)]
    }
    return ["read"]
}

do {
    try execute(FakePowerArguments(CommandLine.arguments))
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(2)
}
