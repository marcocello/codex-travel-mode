import CodexTravelModeReadiness
import Foundation

@main
enum ReadinessMain {
    static func main() async {
        let exitCode = await ReadinessCLI.run(arguments: Array(CommandLine.arguments.dropFirst()))
        Foundation.exit(exitCode)
    }
}
