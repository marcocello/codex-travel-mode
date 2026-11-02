import CodexTravelModeReadiness
import Darwin
import Foundation

@main
enum ObserverMain {
    static func main() async {
        let exitCode = await ReadinessObserverCLI.run(
            arguments: Array(CommandLine.arguments.dropFirst())
        )
        Darwin.exit(exitCode)
    }
}
