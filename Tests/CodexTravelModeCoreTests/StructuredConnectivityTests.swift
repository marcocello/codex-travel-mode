@testable import CodexTravelModeCore
import Foundation
import XCTest

final class StructuredConnectivityTests: XCTestCase {
    func testExactUTF8SSIDIdentityDoesNotApplyUnicodeNormalization() throws {
        let composed = try XCTUnwrap(ExactUTF8String("Caf\u{00e9}"))
        let decomposed = try XCTUnwrap(ExactUTF8String("Cafe\u{0301}"))

        XCTAssertEqual(composed.stringValue, "Caf\u{00e9}")
        XCTAssertNotEqual(composed, decomposed)
        XCTAssertNotEqual(composed.utf8Bytes, decomposed.utf8Bytes)
    }

    func testIPAddressUsabilityExcludesNonUnicastAndLinkLocalAddresses() throws {
        let unusable = [
            "0.0.0.0", "127.0.0.1", "169.254.3.4", "224.0.0.1", "255.255.255.255",
            "::", "::1", "fe80::1", "ff02::1"
        ]
        for value in unusable {
            XCTAssertFalse(try XCTUnwrap(IPAddress(value)).isUsable, value)
        }

        XCTAssertTrue(try XCTUnwrap(IPAddress("10.1.2.3")).isUsable)
        XCTAssertTrue(try XCTUnwrap(IPAddress("2001:db8::1234")).isUsable)
        XCTAssertNil(IPAddress("999.1.2.3"))
        XCTAssertNil(IPAddress("not-an-address"))
    }

    func testConnectivityProviderReadsIndependentTypedFieldsWithOneBoundPerCall() async throws {
        let runner = ConnectivityRunner(outputs: [
            "-getairportpower en0": ShellCommandOutput(
                exitCode: 0,
                standardOutput: "Wi-Fi Power (en0): On\n",
                standardError: ""
            ),
            "-getairportnetwork en0": ShellCommandOutput(
                exitCode: 0,
                standardOutput: "Current Wi-Fi Network: Cafe\u{0301}\n",
                standardError: ""
            ),
            "en0": ShellCommandOutput(
                exitCode: 0,
                standardOutput: """
                en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST>
                    inet 10.0.0.12 netmask 0xffffff00 broadcast 10.0.0.255
                    inet6 fe80::1234%en0 prefixlen 64 secured scopeid 0x6
                    inet6 2001:db8::12 prefixlen 64 autoconf secured
                """,
                standardError: ""
            ),
            "-n get default": ShellCommandOutput(
                exitCode: 0,
                standardOutput: "interface: en0\n",
                standardError: ""
            )
        ])
        let gateway = LocalTravelCommandGateway(runner: runner)
        let timeout = Duration.milliseconds(275)

        let observation = await gateway.readConnectivity(device: "en0", timeout: timeout)

        XCTAssertEqual(observation.power, .value(true))
        XCTAssertEqual(
            observation.ssid,
            .value(ExactUTF8String("Cafe\u{0301}"))
        )
        XCTAssertEqual(observation.addresses.value?.map(\.rawValue), [
            "10.0.0.12", "fe80::1234", "2001:db8::12"
        ])
        XCTAssertEqual(observation.hasUsableAddress, true)
        XCTAssertEqual(observation.defaultRouteInterface, .value("en0"))
        let calls = await runner.calls
        XCTAssertEqual(calls.count, 4)
        XCTAssertTrue(calls.allSatisfy { $0.timeout == timeout })
    }

    func testConnectivityProviderDoesNotCollapseFailuresIntoDisconnection() async {
        let runner = ConnectivityRunner(outputs: [
            "-getairportpower en0": ShellCommandOutput(
                exitCode: 124,
                standardOutput: "",
                standardError: "timed out"
            ),
            "-getairportnetwork en0": ShellCommandOutput(
                exitCode: 0,
                standardOutput: "You are not associated with an AirPort network.\n",
                standardError: ""
            ),
            "en0": ShellCommandOutput(
                exitCode: 0,
                standardOutput: "inet definitely-not-an-address\n",
                standardError: ""
            ),
            "-n get default": ShellCommandOutput(
                exitCode: 9,
                standardOutput: "",
                standardError: "permission denied"
            )
        ])
        let gateway = LocalTravelCommandGateway(runner: runner)

        let observation = await gateway.readConnectivity(
            device: "en0",
            timeout: .seconds(1)
        )

        XCTAssertEqual(observation.power.failure?.category, .timedOut)
        XCTAssertEqual(observation.ssid, .value(nil))
        XCTAssertEqual(observation.addresses.failure?.category, .malformedOutput)
        XCTAssertEqual(
            observation.defaultRouteInterface.failure?.category,
            .commandFailed
        )
        XCTAssertNil(observation.hasUsableAddress)
    }

    func testLidProviderDistinguishesAuthoritativeMalformedAndTimedOutReadings() async {
        let closed = LocalTravelCommandGateway(
            runner: ConnectivityRunner(singleOutput: ShellCommandOutput(
                exitCode: 0,
                standardOutput: #"\"AppleClamshellState\" = Yes"#,
                standardError: ""
            ))
        )
        let malformed = LocalTravelCommandGateway(
            runner: ConnectivityRunner(singleOutput: ShellCommandOutput(
                exitCode: 0,
                standardOutput: #"\"AppleClamshellCausesSleep\" = Yes"#,
                standardError: ""
            ))
        )
        let timedOut = LocalTravelCommandGateway(
            runner: ConnectivityRunner(singleOutput: ShellCommandOutput(
                exitCode: 124,
                standardOutput: "",
                standardError: "timed out"
            ))
        )

        let closedReading = await closed.readLidState(timeout: .seconds(1))
        let malformedReading = await malformed.readLidState(timeout: .seconds(1))
        let timedOutReading = await timedOut.readLidState(timeout: .seconds(1))

        XCTAssertEqual(closedReading, .value(.closed))
        XCTAssertEqual(
            malformedReading.failure?.category,
            .malformedOutput
        )
        XCTAssertEqual(
            timedOutReading.failure?.category,
            .timedOut
        )
    }

    func testReachabilityUsesPrivateDirectGETAndAcceptsOnly2xx() async throws {
        ProbeURLProtocol.reset()
        let success = URLSessionOutboundReachabilityClient(
            testEndpoint: try XCTUnwrap(URL(string: "https://probe.test/success")),
            protocolClasses: [ProbeURLProtocol.self]
        )

        let successResult = await success.check(timeout: .seconds(1), nonce: "nonce-123")

        XCTAssertEqual(successResult, .reachable(statusCode: 204))
        let request = try XCTUnwrap(ProbeURLProtocol.lastRequest())
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "X-Codex-Travel-Probe-Nonce"),
            "nonce-123"
        )
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)

        let rejected = URLSessionOutboundReachabilityClient(
            testEndpoint: try XCTUnwrap(URL(string: "https://probe.test/rejected")),
            protocolClasses: [ProbeURLProtocol.self]
        )
        let rejectedResult = await rejected.check(timeout: .seconds(1), nonce: "nonce-456")
        XCTAssertEqual(rejectedResult, .failed(.rejectedStatus(302)))
    }

    func testReachabilityHonorsCancellation() async throws {
        let client = URLSessionOutboundReachabilityClient(
            testEndpoint: try XCTUnwrap(URL(string: "https://probe.test/pending")),
            protocolClasses: [ProbeURLProtocol.self]
        )
        let task = Task {
            await client.check(timeout: .seconds(5), nonce: "cancel-me")
        }

        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        let result = await task.value
        XCTAssertEqual(result, .failed(.cancelled))
    }

    func testReachabilityRejectsAnExpiredBudgetWithoutStartingARequest() async throws {
        ProbeURLProtocol.reset()
        let client = URLSessionOutboundReachabilityClient(
            testEndpoint: try XCTUnwrap(URL(string: "https://probe.test/success")),
            protocolClasses: [ProbeURLProtocol.self]
        )

        let result = await client.check(timeout: .zero, nonce: "expired")

        XCTAssertEqual(result, .failed(.timedOut))
        XCTAssertNil(ProbeURLProtocol.lastRequest())
    }
}

private actor ConnectivityRunner: ShellCommandRunning {
    struct Call: Sendable {
        let arguments: [String]
        let timeout: Duration?
    }

    private let outputs: [String: ShellCommandOutput]
    private let singleOutput: ShellCommandOutput?
    private(set) var calls: [Call] = []

    init(outputs: [String: ShellCommandOutput]) {
        self.outputs = outputs
        singleOutput = nil
    }

    init(singleOutput: ShellCommandOutput) {
        outputs = [:]
        self.singleOutput = singleOutput
    }

    func run(_ executableURL: URL, arguments: [String]) async -> ShellCommandOutput {
        calls.append(Call(arguments: arguments, timeout: nil))
        return output(arguments)
    }

    func run(
        _ executableURL: URL,
        arguments: [String],
        timeout: Duration
    ) async -> ShellCommandOutput {
        calls.append(Call(arguments: arguments, timeout: timeout))
        return output(arguments)
    }

    private func output(_ arguments: [String]) -> ShellCommandOutput {
        if let singleOutput {
            return singleOutput
        }
        return outputs[arguments.joined(separator: " ")] ?? ShellCommandOutput(
            exitCode: 127,
            standardOutput: "",
            standardError: "No fixture for \(arguments)."
        )
    }
}

private final class ProbeURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var capturedRequest: URLRequest?

    static func reset() {
        lock.withLock { capturedRequest = nil }
    }

    static func lastRequest() -> URLRequest? {
        lock.withLock { capturedRequest }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "probe.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.capturedRequest = request }
        guard request.url?.path != "/pending" else {
            return
        }
        let status = request.url?.path == "/success" ? 204 : 302
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: status == 302 ? ["Location": "https://probe.test/success"] : [:]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
