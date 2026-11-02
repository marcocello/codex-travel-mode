import CodexTravelModeSleepLease
import CodexTravelModeSleepLeaseXPC
import Darwin
import Foundation

@main
struct CodexTravelModeSleepHelper {
    static func main() async {
        guard geteuid() == 0 else {
            terminate("The sleep helper must run as root.")
        }

        let service = SleepOverrideLeaseService(
            store: FileSleepOverrideLeaseStateStore(),
            powerBackend: FixedPmsetSleepOverridePowerBackend()
        )
        do {
            try await service.reconcileOnStartup()
            let adapter = SleepOverrideLeaseServiceXPCAdapter(service: service)
            let host = try SleepOverrideLeaseMachServiceHost(service: adapter)
            host.run()
        } catch {
            terminate("The sleep helper could not start: \(error.localizedDescription)")
        }
    }

    private static func terminate(_ message: String) -> Never {
        if let data = "\(message)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        Darwin.exit(EX_CONFIG)
    }
}
