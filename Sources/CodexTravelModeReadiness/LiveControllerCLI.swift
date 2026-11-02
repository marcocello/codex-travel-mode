import Foundation

public enum ReadinessCLI {
    public static func run(arguments: [String]) async -> Int32 {
        do {
            if let observerArguments = try LiveControllerObserverArguments.parse(arguments) {
                try LiveObserverService(arguments: observerArguments).run()
                return 0
            }
            let parsed = try ReadinessArguments.parse(arguments)
            let controller = LiveController(
                tty: ControllingTTYIO(),
                actionPerformer: ProductionLiveScenarioActionPerformer()
            )
            try await controller.run(arguments: parsed)
            return 0
        } catch ReadinessHarnessError.helpRequested {
            emit(ReadinessArguments.usage, standardError: false)
            return 0
        } catch {
            emit(error.localizedDescription, standardError: true)
            return 1
        }
    }

    private static func emit(_ message: String, standardError: Bool) {
        let handle = standardError ? FileHandle.standardError : FileHandle.standardOutput
        try? handle.write(contentsOf: Data((message + "\n").utf8))
    }
}
