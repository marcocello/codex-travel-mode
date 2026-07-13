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
}

public final class ProcessShellCommandRunner: ShellCommandRunning, @unchecked Sendable {
    public init() {}

    public func run(_ executableURL: URL, arguments: [String]) async -> ShellCommandOutput {
        await Task.detached {
            let process = Process()
            let standardOutput = Pipe()
            let standardError = Pipe()

            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = standardOutput
            process.standardError = standardError

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return ShellCommandOutput(
                    exitCode: 1,
                    standardOutput: "",
                    standardError: error.localizedDescription
                )
            }

            return ShellCommandOutput(
                exitCode: process.terminationStatus,
                standardOutput: dataString(from: standardOutput),
                standardError: dataString(from: standardError)
            )
        }.value
    }
}

private func dataString(from pipe: Pipe) -> String {
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8) ?? ""
}
