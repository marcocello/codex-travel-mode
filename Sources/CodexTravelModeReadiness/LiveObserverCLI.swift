import Foundation

/// Observer-only process entry point used by the distinct sibling executable.
///
/// This intentionally accepts only the hidden observer argument grammar. Public
/// preflight/live arguments remain owned by `ReadinessCLI`.
public enum ReadinessObserverCLI {
    public static func run(arguments: [String]) async -> Int32 {
        do {
            guard let parsed = try LiveControllerObserverArguments.parse(arguments) else {
                throw ReadinessHarnessError.invalidArguments(
                    "the observer entry requires --observer arguments"
                )
            }
            try LiveObserverService(arguments: parsed).run()
            return 0
        } catch {
            try? FileHandle.standardError.write(
                contentsOf: Data((error.localizedDescription + "\n").utf8)
            )
            return 1
        }
    }
}
