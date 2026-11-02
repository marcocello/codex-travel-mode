import Darwin
import Foundation

public enum LiveObservedSystemQuery: Equatable, Sendable {
    case pmset
    case battery
    case lid
    case platformIdentity
    case hardwareModel
    case codexProcesses
    case wifiPower(device: String)
    case wifiSSID(device: String)
    case interface(device: String)
    case defaultRoute
    case remoteRoute(address: String)
    case processStart(pid: Int32)
    case helperRegistration
    case helperJournalAuthorization
    case helperJournalPresence

    public var command: LiveObservedCommand {
        switch self {
        case .pmset:
            LiveObservedCommand(executable: "/usr/bin/pmset", arguments: ["-g"])
        case .battery:
            LiveObservedCommand(executable: "/usr/bin/pmset", arguments: ["-g", "batt"])
        case .lid:
            LiveObservedCommand(
                executable: "/usr/sbin/ioreg",
                arguments: ["-r", "-k", "AppleClamshellState", "-d", "4"]
            )
        case .platformIdentity:
            LiveObservedCommand(
                executable: "/usr/sbin/ioreg",
                arguments: ["-rd1", "-c", "IOPlatformExpertDevice"]
            )
        case .hardwareModel:
            LiveObservedCommand(executable: "/usr/sbin/sysctl", arguments: ["-n", "hw.model"])
        case .codexProcesses:
            LiveObservedCommand(executable: "/usr/bin/pgrep", arguments: ["-x", "Codex"])
        case .wifiPower(let device):
            LiveObservedCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-getairportpower", device]
            )
        case .wifiSSID(let device):
            LiveObservedCommand(
                executable: "/usr/sbin/networksetup",
                arguments: ["-getairportnetwork", device]
            )
        case .interface(let device):
            LiveObservedCommand(executable: "/sbin/ifconfig", arguments: [device])
        case .defaultRoute:
            LiveObservedCommand(executable: "/sbin/route", arguments: ["-n", "get", "default"])
        case .remoteRoute(let address):
            LiveObservedCommand(executable: "/sbin/route", arguments: ["-n", "get", address])
        case .processStart(let pid):
            LiveObservedCommand(
                executable: "/bin/ps",
                arguments: ["-p", String(pid), "-o", "lstart="]
            )
        case .helperRegistration:
            LiveObservedCommand(
                executable: "/bin/launchctl",
                arguments: [
                    "print",
                    "system/\(LiveObservedHelperRegistrationReader.serviceName)",
                ]
            )
        case .helperJournalAuthorization:
            LiveObservedCommand(
                executable: "/usr/bin/sudo",
                arguments: [
                    "-n", "-l", "--", "/usr/bin/test", "-e",
                    LiveObservedHelperJournalReader.path,
                ]
            )
        case .helperJournalPresence:
            LiveObservedCommand(
                executable: "/usr/bin/sudo",
                arguments: [
                    "-n", "--", "/usr/bin/test", "-e",
                    LiveObservedHelperJournalReader.path,
                ]
            )
        }
    }
}

public final class LiveObservedFixedCommandRunner:
    LiveObservedCommandRunning, @unchecked Sendable {
    public static let maximumOutputBytes = 128 * 1_024
    public static let timeout: TimeInterval = 5

    public init() {}

    public func run(_ command: LiveObservedCommand) throws -> LiveObservedCommandResult {
        guard Self.isAllowed(command),
              FileManager.default.isExecutableFile(atPath: command.executable) else {
            throw LiveObservedSystemError.indeterminate("command is outside the read-only set")
        }
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        let output = LiveObservedPipeCollector(limit: Self.maximumOutputBytes)
        let errors = LiveObservedPipeCollector(limit: Self.maximumOutputBytes)
        output.start(reading: outputPipe.fileHandleForReading)
        errors.start(reading: errorPipe.fileHandleForReading)
        do {
            try process.run()
        } catch {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            throw error
        }
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(Self.timeout)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            waitForExit(process, until: Date().addingTimeInterval(0.5))
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            waitForExit(process, until: Date().addingTimeInterval(1))
        }
        if process.isRunning {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            throw LiveObservedSystemError.indeterminate("read-only command timed out")
        }
        let stdout = try output.finish()
        let stderr = try errors.finish()
        return LiveObservedCommandResult(
            exitStatus: process.terminationStatus,
            standardOutput: String(decoding: stdout, as: UTF8.self),
            standardError: String(decoding: stderr, as: UTF8.self)
        )
    }

    public static func isAllowed(_ command: LiveObservedCommand) -> Bool {
        if [
            LiveObservedSystemQuery.pmset.command,
            LiveObservedSystemQuery.battery.command,
            LiveObservedSystemQuery.lid.command,
            LiveObservedSystemQuery.platformIdentity.command,
            LiveObservedSystemQuery.hardwareModel.command,
            LiveObservedSystemQuery.codexProcesses.command,
            LiveObservedSystemQuery.defaultRoute.command,
            LiveObservedSystemQuery.helperRegistration.command,
            LiveObservedSystemQuery.helperJournalAuthorization.command,
            LiveObservedSystemQuery.helperJournalPresence.command,
        ].contains(command) { return true }
        return allowedDynamic(command)
    }

    private static func allowedDynamic(_ command: LiveObservedCommand) -> Bool {
        if command.executable == "/usr/sbin/networksetup", command.arguments.count == 2 {
            return ["-getairportpower", "-getairportnetwork"].contains(command.arguments[0])
                && validDevice(command.arguments[1])
        }
        if command.executable == "/sbin/ifconfig", command.arguments.count == 1 {
            return validDevice(command.arguments[0])
        }
        if command.executable == "/sbin/route",
           command.arguments.count == 3, command.arguments[0...1] == ["-n", "get"] {
            return (try? LiveObservedIPAddress(command.arguments[2])) != nil
        }
        if command.executable == "/bin/ps", command.arguments.count == 4,
           command.arguments[0] == "-p", Int32(command.arguments[1]).map({ $0 > 0 }) == true {
            return command.arguments[2...3] == ["-o", "lstart="]
        }
        return false
    }

    private static func validDevice(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (65...90).contains(first) || (97...122).contains(first),
              (1...16).contains(value.utf8.count) else { return false }
        return value.utf8.dropFirst().allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        }
    }

    private func waitForExit(_ process: Process, until deadline: Date) {
        while process.isRunning, Date() < deadline { usleep(10_000) }
    }
}

public struct LiveObservedSystemProbe: Sendable {
    private let runner: any LiveObservedCommandRunning
    private let redactionSalt: Data
    private let clock: any LiveProviderClock

    public init(
        runner: any LiveObservedCommandRunning = LiveObservedFixedCommandRunner(),
        redactionSalt: Data,
        clock: any LiveProviderClock = LiveProviderSystemClock()
    ) {
        self.runner = runner
        self.redactionSalt = redactionSalt
        self.clock = clock
    }

    public func preflight(
        wifiDevice: String,
        appProcessAbsent: Bool
    ) throws -> LiveObservedPreflightFacts {
        let sleep = try output(.pmset)
        let battery = try output(.battery)
        let lid = try output(.lid)
        let power = try output(.wifiPower(device: wifiDevice))
        let ssid = try LiveObservedSystemParsers.ssid(output(.wifiSSID(device: wifiDevice)))
        let addresses = try LiveObservedSystemParsers.usableInterfaceAddresses(
            output(.interface(device: wifiDevice)),
            device: wifiDevice
        )
        return try LiveObservedPreflightFacts(
            capturedAtUnixMilliseconds: clock.nowUnixMilliseconds(),
            sleepDisabled: LiveObservedSystemParsers.sleepDisabled(sleep),
            battery: LiveObservedSystemParsers.battery(battery),
            lidClosed: LiveObservedSystemParsers.lidClosed(lid),
            wifiDevice: wifiDevice,
            wifiPowered: LiveObservedSystemParsers.wifiPower(power, device: wifiDevice),
            ssidDigest: ReadinessDigest.salted(Data(ssid.utf8), salt: redactionSalt),
            usableAddresses: addresses.map {
                LiveObservedAddressFact(address: $0, redactionSalt: redactionSalt)
            },
            defaultRouteDevice: LiveObservedSystemParsers.routeDevice(output(.defaultRoute)),
            appProcessAbsent: appProcessAbsent
        )
    }

    public func runtime(
        wifiDevice: String,
        providerRemoteAddress: String
    ) throws -> LiveObservedRuntimeNetworkSnapshot {
        let remote = try LiveObservedIPAddress(providerRemoteAddress)
        let ssid = try LiveObservedSystemParsers.ssid(output(.wifiSSID(device: wifiDevice)))
        return try LiveObservedRuntimeNetworkSnapshot(
            capturedAtUnixMilliseconds: clock.nowUnixMilliseconds(),
            sleepDisabled: LiveObservedSystemParsers.sleepDisabled(output(.pmset)),
            lidClosed: LiveObservedSystemParsers.lidClosed(output(.lid)),
            battery: LiveObservedSystemParsers.battery(output(.battery)),
            ssidDigest: ReadinessDigest.salted(Data(ssid.utf8), salt: redactionSalt),
            wifiDevice: wifiDevice,
            wifiPowered: LiveObservedSystemParsers.wifiPower(
                output(.wifiPower(device: wifiDevice)),
                device: wifiDevice
            ),
            interfaceAddresses: LiveObservedSystemParsers.usableInterfaceAddresses(
                output(.interface(device: wifiDevice)),
                device: wifiDevice
            ),
            routedRemoteAddress: remote,
            routeDevice: LiveObservedSystemParsers.routeDevice(
                output(.remoteRoute(address: remote.canonicalText))
            )
        )
    }

    public func processStartIdentity(pid: Int32) throws -> String {
        try LiveObservedSystemParsers.processStartIdentity(
            output(.processStart(pid: pid))
        )
    }

    private func output(_ query: LiveObservedSystemQuery) throws -> String {
        let result = try runner.run(query.command)
        guard result.exitStatus == 0 else {
            throw LiveObservedSystemError.indeterminate(
                "\(query.command.executable) exited \(result.exitStatus)"
            )
        }
        return result.standardOutput
    }
}

public struct LiveObservedPortableMacIdentity: Equatable, Sendable {
    public let platformUUID: String
    public let hardwareModel: String

    public init(platformUUID: String, hardwareModel: String) {
        self.platformUUID = platformUUID
        self.hardwareModel = hardwareModel
    }
}

public struct LiveObservedReadinessPrerequisiteProbe: Sendable {
    private let runner: any LiveObservedCommandRunning

    public init(runner: any LiveObservedCommandRunning = LiveObservedFixedCommandRunner()) {
        self.runner = runner
    }

    public func portableMacIdentity() throws -> LiveObservedPortableMacIdentity {
        let platform = try successful(.platformIdentity)
        let model = try successful(.hardwareModel)
        _ = try LiveObservedSystemParsers.battery(successful(.battery))
        _ = try LiveObservedSystemParsers.lidClosed(successful(.lid))
        return LiveObservedPortableMacIdentity(
            platformUUID: try LiveObservedSystemParsers.platformUUID(platform),
            hardwareModel: try LiveObservedSystemParsers.hardwareModel(model)
        )
    }

    public func codexProcessPIDs() throws -> [Int32] {
        let result = try runner.run(LiveObservedSystemQuery.codexProcesses.command)
        guard result.standardError.isEmpty else {
            throw LiveObservedSystemError.indeterminate("Codex process query emitted diagnostics")
        }
        switch result.exitStatus {
        case 0:
            return try LiveObservedSystemParsers.processPIDs(result.standardOutput)
        case 1 where result.standardOutput.isEmpty:
            return []
        default:
            throw LiveObservedSystemError.indeterminate(
                "Codex process query exited \(result.exitStatus)"
            )
        }
    }

    public func isCodexRunning() throws -> Bool {
        try !codexProcessPIDs().isEmpty
    }

    private func successful(_ query: LiveObservedSystemQuery) throws -> String {
        let result = try runner.run(query.command)
        guard result.exitStatus == 0, result.standardError.isEmpty else {
            throw LiveObservedSystemError.indeterminate(
                "\(query.command.executable) did not return a clean result"
            )
        }
        return result.standardOutput
    }
}

private final class LiveObservedPipeCollector: @unchecked Sendable {
    private let limit: Int
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()
    private var exceeded = false

    init(limit: Int) {
        self.limit = limit
    }

    func start(reading handle: FileHandle) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { self.group.leave() }
            while let chunk = try? handle.read(upToCount: 16 * 1_024), !chunk.isEmpty {
                self.lock.lock()
                if self.data.count + chunk.count <= self.limit {
                    self.data.append(chunk)
                } else {
                    self.exceeded = true
                }
                self.lock.unlock()
            }
        }
    }

    func finish() throws -> Data {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        guard !exceeded else {
            throw LiveObservedSystemError.indeterminate("read-only output exceeded its bound")
        }
        return data
    }
}
