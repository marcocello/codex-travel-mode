import Darwin
import Foundation

public enum ReadinessFixedCommand: Equatable, Sendable {
    public static let helperJournalPath =
        "/Library/Application Support/com.codex.travelmode/SleepOverrideLease/active-lease.json"

    case pmsetGeneral
    case battery
    case lid
    case platformIdentity
    case hardwareModel
    case wifiPower(device: String)
    case wifiSSID(device: String)
    case interface(device: String)
    case defaultRoute
    case providerRoute(host: String)
    case codexProcesses
    case codeSignVerify(path: String)
    case codeSignDetails(path: String)
    case codeSignRequirement(path: String)
    case helperRegistration
    case helperJournalAuthorization
    case helperJournalPresence
    case processStart(pid: Int32)

    public var executable: String {
        switch self {
        case .pmsetGeneral, .battery: "/usr/bin/pmset"
        case .lid, .platformIdentity: "/usr/sbin/ioreg"
        case .hardwareModel: "/usr/sbin/sysctl"
        case .wifiPower, .wifiSSID: "/usr/sbin/networksetup"
        case .interface: "/sbin/ifconfig"
        case .defaultRoute, .providerRoute: "/sbin/route"
        case .codexProcesses: "/usr/bin/pgrep"
        case .codeSignVerify, .codeSignDetails, .codeSignRequirement: "/usr/bin/codesign"
        case .helperRegistration: "/bin/launchctl"
        case .helperJournalAuthorization, .helperJournalPresence: "/usr/bin/sudo"
        case .processStart: "/bin/ps"
        }
    }

    public var arguments: [String] {
        switch self {
        case .pmsetGeneral: ["-g"]
        case .battery: ["-g", "batt"]
        case .lid: ["-r", "-k", "AppleClamshellState", "-d", "4"]
        case .platformIdentity: ["-rd1", "-c", "IOPlatformExpertDevice"]
        case .hardwareModel: ["-n", "hw.model"]
        case .wifiPower(let device): ["-getairportpower", device]
        case .wifiSSID(let device): ["-getairportnetwork", device]
        case .interface(let device): [device]
        case .defaultRoute: ["-n", "get", "default"]
        case .providerRoute(let host): ["-n", "get", host]
        case .codexProcesses: ["-x", "Codex"]
        case .codeSignVerify(let path): ["--verify", "--strict", "--verbose=4", path]
        case .codeSignDetails(let path): ["-d", "--verbose=4", path]
        case .codeSignRequirement(let path): ["-d", "-r-", path]
        case .helperRegistration: ["print", "system/com.codex.travelmode.sleep-helper"]
        case .helperJournalAuthorization:
            ["-n", "-l", "--", "/usr/bin/test", "-e", Self.helperJournalPath]
        case .helperJournalPresence:
            ["-n", "--", "/usr/bin/test", "-e", Self.helperJournalPath]
        case .processStart(let pid): ["-p", String(pid), "-o", "lstart="]
        }
    }

    public var isReadOnly: Bool {
        switch self {
        case .pmsetGeneral, .battery, .lid, .platformIdentity, .hardwareModel,
             .wifiPower, .wifiSSID, .interface, .defaultRoute, .providerRoute,
             .codexProcesses, .codeSignVerify, .codeSignDetails, .codeSignRequirement,
             .helperRegistration, .helperJournalAuthorization, .helperJournalPresence,
             .processStart:
            true
        }
    }
}

public struct ReadinessCommandOutput: Equatable, Sendable {
    public var command: ReadinessFixedCommand
    public var standardOutput: String
    public var standardError: String
    public var exitStatus: Int32
    public var elapsedMilliseconds: Int
}

public protocol ReadinessCommandProviding: Sendable {
    func run(_ command: ReadinessFixedCommand) throws -> ReadinessCommandOutput
    func records() -> [ReadinessCommandRecord]
}

public final class FixedReadOnlyCommandProvider: ReadinessCommandProviding, @unchecked Sendable {
    private let salt: Data
    private let lock = NSLock()
    private var capturedRecords: [ReadinessCommandRecord] = []

    public init(redactionSalt: Data) {
        salt = redactionSalt
    }

    public func run(_ command: ReadinessFixedCommand) throws -> ReadinessCommandOutput {
        guard command.isReadOnly, FileManager.default.isExecutableFile(atPath: command.executable) else {
            throw ReadinessHarnessError.commandFailed("fixed command is unavailable")
        }
        try validate(command)
        let started = DispatchTime.now().uptimeNanoseconds
        let raw = try execute(command)
        let elapsed = Int((DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        let output = ReadinessCommandOutput(
            command: command,
            standardOutput: raw.0,
            standardError: raw.1,
            exitStatus: raw.2,
            elapsedMilliseconds: elapsed
        )
        appendRecord(for: output)
        return output
    }

    public func records() -> [ReadinessCommandRecord] {
        lock.withLock { capturedRecords }
    }

    private func execute(_ command: ReadinessFixedCommand) throws -> (String, String, Int32) {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        do { try process.run() } catch {
            throw ReadinessHarnessError.commandFailed("could not launch \(command.executable)")
        }
        let deadline = Date().addingTimeInterval(15)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        while process.isRunning { usleep(10_000) }
        let stdout = boundedString(outputPipe.fileHandleForReading.readDataToEndOfFile())
        let stderr = boundedString(errorPipe.fileHandleForReading.readDataToEndOfFile())
        return (stdout, stderr, process.terminationStatus)
    }

    private func appendRecord(for output: ReadinessCommandOutput) {
        lock.withLock {
            capturedRecords.append(
                ReadinessCommandRecord(
                    sequence: capturedRecords.count + 1,
                    wallTime: ReadinessClock.wallTime(),
                    executable: output.command.executable,
                    arguments: evidenceArguments(output.command.arguments),
                    exitStatus: output.exitStatus,
                    standardOutputDigest: digest(output.standardOutput),
                    standardErrorDigest: digest(output.standardError),
                    elapsedMilliseconds: output.elapsedMilliseconds
                )
            )
        }
    }

    private func validate(_ command: ReadinessFixedCommand) throws {
        for argument in command.arguments where argument.contains("\n") || argument.contains("\r") {
            throw ReadinessHarnessError.commandFailed("control character in fixed command")
        }
        switch command {
        case .wifiPower(let device), .wifiSSID(let device), .interface(let device):
            try validateOpaqueToken(device, label: "network device")
        case .providerRoute(let host):
            try validateOpaqueToken(host, label: "provider host")
        case .codeSignVerify(let path), .codeSignDetails(let path),
             .codeSignRequirement(let path):
            guard path.hasPrefix("/") else {
                throw ReadinessHarnessError.commandFailed("code identity path must be absolute")
            }
        case .processStart(let pid):
            guard pid > 1 else {
                throw ReadinessHarnessError.commandFailed("process identity PID is unsafe")
            }
        default:
            break
        }
    }

    private func validateOpaqueToken(_ value: String, label: String) throws {
        guard !value.isEmpty, !value.hasPrefix("-"), value.utf8.count <= 255 else {
            throw ReadinessHarnessError.commandFailed("\(label) is invalid")
        }
    }

    private func boundedString(_ data: Data) -> String {
        String(decoding: data.prefix(128 * 1_024), as: UTF8.self)
    }

    private func digest(_ string: String) -> String {
        ReadinessDigest.salted(Data(string.utf8), salt: salt)
    }

    private func evidenceArguments(_ arguments: [String]) -> [String] {
        arguments.map { argument in
            guard argument.hasPrefix("/Users/") else { return argument }
            return "<local-path:\(digest(argument))>"
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}
