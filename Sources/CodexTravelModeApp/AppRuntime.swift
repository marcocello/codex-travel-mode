import CodexTravelModeCore
import CodexTravelModeSleepLeaseXPC

@MainActor
final class AppRuntime {
    static let shared = AppRuntime()
    let appState: TravelModeAppState

    private init() {
        let rawGateway = LocalTravelCommandGateway()
        let sleepLeaseClient = TransportSleepOverrideLeaseClient(
            transport: MachServiceSleepOverrideLeaseTransport()
        )
        let sessionCoordinator = TravelSessionCoordinator(
            journalStore: FileTravelSessionJournalStore(),
            system: GatewayTravelSessionSystemController(gateway: rawGateway),
            leaseClient: sleepLeaseClient
        )
        let gateway = TransactionalTravelCommandGateway(
            rawGateway: rawGateway,
            sessionManager: sessionCoordinator
        )
        let internetEngine = TravelInternetHandoffEngine(
            connectivityProvider: rawGateway,
            reachabilityChecker: URLSessionOutboundReachabilityClient(),
            sessionManager: sessionCoordinator
        )
        let internetCoordinator = TravelInternetHandoffCoordinator(
            lidProvider: rawGateway,
            engine: internetEngine
        )
        appState = TravelModeAppState(
            gateway: gateway,
            engine: .production(),
            sessionManager: sessionCoordinator,
            internetHandoffCoordinator: internetCoordinator
        )
    }
}
