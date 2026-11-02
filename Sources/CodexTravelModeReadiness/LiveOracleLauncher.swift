import Darwin
import Foundation

public protocol LiveOracleLaunching: Sendable {
    func evaluate(
        evidenceDirectory: URL,
        runID: String,
        controller: LiveProofProcessIdentity,
        observer: LiveProofProcessIdentity
    ) throws
}

public struct SiblingLiveOracleLauncher: LiveOracleLaunching, Sendable {
    public init() {}

    public func evaluate(
        evidenceDirectory: URL,
        runID: String,
        controller: LiveProofProcessIdentity,
        observer: LiveProofProcessIdentity
    ) throws {
        let controllerURL = try LiveControllerSystem.executableURL()
        let oracleURL = controllerURL.deletingLastPathComponent()
            .appendingPathComponent("codex-travel-mode-readiness-oracle")
            .standardizedFileURL
        var info = stat()
        guard Darwin.lstat(oracleURL.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o111 != 0,
              info.st_uid == geteuid() else {
            throw ReadinessHarnessError.readinessBlocked(
                "the sibling readiness oracle executable is unavailable or unsafe"
            )
        }
        let oracleHash = try LiveControllerSystem.sha256File(oracleURL)
        guard oracleHash != controller.executableSHA256,
              oracleHash != observer.executableSHA256 else {
            throw ReadinessHarnessError.readinessBlocked(
                "oracle executable identity is not independent"
            )
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = oracleURL
        process.arguments = [
            "--evidence-directory", evidenceDirectory.path,
            "--expected-owner-uid", String(geteuid()),
            "--controller-pid", String(controller.pid),
            "--controller-start", controller.startIdentity,
            "--controller-hash", controller.executableSHA256,
            "--observer-pid", String(observer.pid),
            "--observer-start", observer.startIdentity,
            "--observer-hash", observer.executableSHA256,
        ]
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let oracle = try LiveProofProcessIdentity(
            pid: process.processIdentifier,
            startIdentity: LiveControllerSystem.processStartIdentity(
                pid: process.processIdentifier
            ),
            executableSHA256: LiveControllerSystem.sha256File(
                LiveControllerSystem.executableURL(pid: process.processIdentifier)
            )
        )
        guard oracle.executableSHA256 == oracleHash,
              oracle.pid != controller.pid, oracle.pid != observer.pid,
              oracle.startIdentity != controller.startIdentity,
              oracle.startIdentity != observer.startIdentity else {
            process.terminate()
            throw ReadinessHarnessError.liveInterrupted(
                "launched oracle identity did not match its sibling executable"
            )
        }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            usleep(100_000)
        }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        guard !process.isRunning else {
            throw ReadinessHarnessError.liveInterrupted("oracle did not terminate")
        }
        let bytes = try output.fileHandleForReading.readToEnd() ?? Data()
        guard bytes.count <= 64 * 1_024, process.terminationStatus == 0 else {
            throw ReadinessHarnessError.liveInterrupted(
                "independent oracle rejected the live evidence"
            )
        }
        let reportFile = try POSIXLiveOracleFileAccess().read(
            name: "oracle-report.json",
            in: evidenceDirectory
        )
        let report = try LiveProofCanonicalJSON.decode(
            LiveOracleReport.self,
            from: reportFile.data
        )
        guard reportFile.metadata.mode == 0o400,
              reportFile.metadata.ownerUID == geteuid(),
              reportFile.metadata.isRegularFile,
              try LiveProofCanonicalJSON.encode(report) == reportFile.data,
              report.runID == runID,
              report.oracle == oracle,
              report.verdict == .accept,
              report.issueCodes.isEmpty else {
            throw ReadinessHarnessError.liveInterrupted(
                "independent oracle report did not authorize acceptance"
            )
        }
    }
}
