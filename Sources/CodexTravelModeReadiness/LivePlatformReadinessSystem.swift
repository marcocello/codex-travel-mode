import ApplicationServices
import Darwin
import Foundation
import ServiceManagement

public struct LivePlatformProcessResolver: LivePlatformProcessResolving, Sendable {
    public init() {}

    public func process(pid: Int32) throws -> LivePlatformResolvedProcess {
        guard pid > 0, let executable = executableURL(pid: pid) else {
            throw LivePlatformReadinessError.processNotFound("PID \(pid)")
        }
        return try LivePlatformResolvedProcess(
            pid: pid,
            startIdentity: startIdentity(pid: pid),
            executableURL: executable
        )
    }

    public func processes(executableURL: URL) throws -> [LivePlatformResolvedProcess] {
        let expected = executableURL.standardizedFileURL
        return try allPIDs().compactMap { pid in
            guard self.executableURL(pid: pid) == expected else { return nil }
            return try process(pid: pid)
        }
    }

    private func allPIDs() throws -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else {
            throw LivePlatformReadinessError.processNotFound("process table unavailable")
        }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let bytes = Int32(pids.count * MemoryLayout<pid_t>.size)
        let count = proc_listallpids(&pids, bytes)
        guard count >= 0 else {
            throw LivePlatformReadinessError.processNotFound("process table unavailable")
        }
        return pids.prefix(Int(count)).filter { $0 > 0 }
    }

    private func executableURL(pid: Int32) -> URL? {
        var path = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &path, UInt32(path.count))
        guard count > 0 else { return nil }
        return URL(
            fileURLWithPath: String(decoding: path.prefix(Int(count)), as: UTF8.self)
        ).standardizedFileURL
    }

    private func startIdentity(pid: Int32) throws -> String {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected) == expected else {
            throw LivePlatformReadinessError.processNotFound("PID start is unavailable")
        }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }
}

public struct LivePlatformExactProcessInspector: Sendable {
    private let resolver: any LivePlatformProcessResolving
    private let bundleResolver: any LivePlatformBundleExecutableResolving

    public init(
        resolver: any LivePlatformProcessResolving,
        bundleResolver: any LivePlatformBundleExecutableResolving =
            LivePlatformBundleExecutableResolver()
    ) {
        self.resolver = resolver
        self.bundleResolver = bundleResolver
    }

    public func requireOneAppProcess(bundleURL: URL) throws -> LivePlatformResolvedProcess {
        try requireOne(
            executableURL: bundleResolver.executableURL(bundleURL: bundleURL)
        )
    }

    public func requireNoAppProcess(bundleURL: URL) throws {
        let executable = try bundleResolver.executableURL(bundleURL: bundleURL)
        let processes = try resolver.processes(executableURL: executable)
        guard processes.isEmpty else {
            throw LivePlatformReadinessError.processAmbiguous(
                path: executable.path,
                count: processes.count
            )
        }
    }

    public func requireOne(executableURL: URL) throws -> LivePlatformResolvedProcess {
        let matches = try resolver.processes(executableURL: executableURL)
        guard matches.count == 1, let process = matches.first else {
            if matches.isEmpty {
                throw LivePlatformReadinessError.processNotFound(executableURL.path)
            }
            throw LivePlatformReadinessError.processAmbiguous(
                path: executableURL.path,
                count: matches.count
            )
        }
        return process
    }
}

@available(macOS 13.0, *)
public struct LivePlatformSMAppServiceStatusReader:
    LivePlatformServiceStatusReading, Sendable {
    public init() {}

    public func helperStatus(plistName: String) -> LivePlatformServiceStatus {
        switch SMAppService.daemon(plistName: plistName).status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .unknown
        }
    }
}

public struct LivePlatformHelperRegistrationInspector: Sendable {
    public static let plistName = "com.codex.travelmode.sleep-helper.plist"
    private let statusReader: any LivePlatformServiceStatusReading
    private let processInspector: LivePlatformExactProcessInspector

    public init(
        statusReader: any LivePlatformServiceStatusReading,
        processResolver: any LivePlatformProcessResolving
    ) {
        self.statusReader = statusReader
        processInspector = LivePlatformExactProcessInspector(resolver: processResolver)
    }

    public func inspect(
        embeddedHelperExecutableURL: URL
    ) throws -> LivePlatformHelperRegistration {
        let status = statusReader.helperStatus(plistName: Self.plistName)
        guard status == .enabled else {
            throw LivePlatformReadinessError.serviceNotEnabled(status.rawValue)
        }
        return LivePlatformHelperRegistration(
            status: status,
            process: try processInspector.requireOne(
                executableURL: embeddedHelperExecutableURL.standardizedFileURL
            )
        )
    }
}

public struct LivePlatformPOSIXFilePresenceInspector:
    LivePlatformFilePresenceInspecting, Sendable {
    public init() {}

    public func ownedRegularFilePresence(at url: URL) -> LivePlatformJournalPresence {
        var info = stat()
        if Darwin.lstat(url.path, &info) != 0 {
            return errno == ENOENT ? .absent : .indeterminate
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid() else {
            return .indeterminate
        }
        return .present
    }
}

public struct LivePlatformAppJournalReader: Sendable {
    public static var defaultURL: URL {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupport
            .appendingPathComponent("CodexTravelMode", isDirectory: true)
            .appendingPathComponent("travel-session-journal.json")
    }

    private let inspector: any LivePlatformFilePresenceInspecting
    private let journalURL: URL

    public init(
        inspector: any LivePlatformFilePresenceInspecting =
            LivePlatformPOSIXFilePresenceInspector(),
        journalURL: URL = Self.defaultURL
    ) {
        self.inspector = inspector
        self.journalURL = journalURL.standardizedFileURL
    }

    public func presence() -> LivePlatformJournalPresence {
        inspector.ownedRegularFilePresence(at: journalURL)
    }
}

public struct LivePlatformAccessibilityTrustReader:
    LivePlatformAccessibilityTrustReading, Sendable {
    public init() {}
    public func isProcessTrusted() -> Bool { AXIsProcessTrusted() }
}

public struct LivePlatformAccessibilityReadiness: Sendable {
    private let reader: any LivePlatformAccessibilityTrustReading

    public init(reader: any LivePlatformAccessibilityTrustReading) {
        self.reader = reader
    }

    public func requireTrusted() throws {
        guard reader.isProcessTrusted() else {
            throw LivePlatformReadinessError.uiReadback(
                "harness Accessibility trust is not granted"
            )
        }
    }
}
