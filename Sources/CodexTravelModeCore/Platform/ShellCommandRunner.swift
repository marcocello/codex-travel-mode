import Darwin
import Foundation

public struct ShellCommandOutput: Equatable, Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol ShellCommandRunning: Sendable {
    func run(_ executableURL: URL, arguments: [String]) async -> ShellCommandOutput
    func run(
        _ executableURL: URL,
        arguments: [String],
        timeout: Duration
    ) async -> ShellCommandOutput
}

public extension ShellCommandRunning {
    func run(
        _ executableURL: URL,
        arguments: [String],
        timeout: Duration
    ) async -> ShellCommandOutput {
        await run(executableURL, arguments: arguments)
    }
}

public final class ProcessShellCommandRunner: ShellCommandRunning, @unchecked Sendable {
    public init() {}

    public func run(_ executableURL: URL, arguments: [String]) async -> ShellCommandOutput {
        await execute(executableURL, arguments: arguments, timeout: nil)
    }

    public func run(
        _ executableURL: URL,
        arguments: [String],
        timeout: Duration
    ) async -> ShellCommandOutput {
        await execute(executableURL, arguments: arguments, timeout: timeout)
    }

    private func execute(
        _ executableURL: URL,
        arguments: [String],
        timeout: Duration?
    ) async -> ShellCommandOutput {
        let state = ProcessExecutionState()
        let worker = Task.detached {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()

            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = standardOutput
            process.standardError = standardError

            do {
                guard try state.launch(process) else {
                    return cancelledCommandOutput()
                }
            } catch {
                return ShellCommandOutput(
                    exitCode: 1,
                    standardOutput: "",
                    standardError: error.localizedDescription
                )
            }

            switch waitForExit(process, timeout: timeout, state: state) {
            case .cancelled:
                return cancelledCommandOutput()
            case .timedOut:
                return ShellCommandOutput(
                    exitCode: 124,
                    standardOutput: "",
                    standardError: "Command timed out and was terminated."
                )
            case .completed:
                return ShellCommandOutput(
                    exitCode: process.terminationStatus,
                    standardOutput: dataString(from: standardOutput),
                    standardError: dataString(from: standardError)
                )
            }
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            state.cancel()
        }
    }
}

private enum ProcessExitReason {
    case completed
    case timedOut
    case cancelled
}

private final class ProcessExecutionState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var terminationRequested = false

    func launch(_ process: Process) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        try process.run()
        self.process = process
        return true
    }

    func cancel() {
        let process = lock.withLock { () -> Process? in
            cancelled = true
            guard !terminationRequested else { return nil }
            terminationRequested = true
            return self.process
        }
        if let process, process.isRunning {
            process.terminate()
        }
    }

    func isCancelled() -> Bool {
        lock.withLock { cancelled }
    }

    func terminateForTimeout(_ process: Process) -> ProcessExitReason {
        let shouldTerminate = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            guard !terminationRequested else { return false }
            terminationRequested = true
            return true
        }
        if shouldTerminate {
            terminateProcess(process)
        }
        return isCancelled() ? .cancelled : .timedOut
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}

private func waitForExit(
    _ process: Process,
    timeout: Duration?,
    state: ProcessExecutionState
) -> ProcessExitReason {
    let deadline = timeout.map { Date().addingTimeInterval(timeInterval($0)) }
    while process.isRunning {
        if state.isCancelled() {
            terminateProcess(process)
            return .cancelled
        }
        if let deadline, Date() >= deadline {
            return state.terminateForTimeout(process)
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return state.isCancelled() ? .cancelled : .completed
}

private func terminateProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let graceDeadline = Date().addingTimeInterval(0.25)
    while process.isRunning, Date() < graceDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
    let killDeadline = Date().addingTimeInterval(1)
    while process.isRunning, Date() < killDeadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
}

private func cancelledCommandOutput() -> ShellCommandOutput {
    ShellCommandOutput(
        exitCode: 130,
        standardOutput: "",
        standardError: "Command was cancelled and terminated."
    )
}

private func timeInterval(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    let seconds = Double(components.seconds)
    let fractional = Double(components.attoseconds) / 1_000_000_000_000_000_000
    return max(0, seconds + fractional)
}

private func dataString(from pipe: Pipe) -> String {
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}
