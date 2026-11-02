import Darwin
import Foundation

@main
enum IPhoneInternetHandoffProofWorker {
    static func main() async {
        do {
            let outputURL = try outputURL(arguments: CommandLine.arguments)
            let scenarios = try await runAllScenarios()
            let artifact = ProofArtifact(
                schemaVersion: 1,
                workerPID: getpid(),
                scenarios: scenarios
            )
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(artifact)
            if data.range(of: Data(proofPassword.utf8)) != nil {
                throw WorkerError.credentialLeak
            }
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: outputURL, options: .atomic)
            print(outputURL.path)
        } catch {
            FileHandle.standardError.write(Data("iphone handoff proof worker failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func outputURL(arguments: [String]) throws -> URL {
        if let index = arguments.firstIndex(of: "--output"), arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1])
        }
        if let path = ProcessInfo.processInfo.environment["PROOF_ARTIFACT_PATH"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        throw WorkerError.missingOutput
    }
}

private enum WorkerError: Error {
    case missingOutput
    case credentialLeak
}
