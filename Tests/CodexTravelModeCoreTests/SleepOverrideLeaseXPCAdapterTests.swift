import CodexTravelModeSleepLease
@testable import CodexTravelModeSleepLeaseXPC
import Foundation
import XCTest

final class SleepOverrideLeaseXPCAdapterTests: XCTestCase {
    func testReciprocalRequirementsPinIdentifierAndTeam() throws {
        let teamIdentifier = "ABCDE12345"

        let app = try SleepOverrideLeaseCodeSigningRequirements.appRequirement(
            teamIdentifier: teamIdentifier
        )
        let helper = try SleepOverrideLeaseCodeSigningRequirements.helperRequirement(
            teamIdentifier: teamIdentifier
        )

        XCTAssertTrue(app.contains("identifier \"com.codex.travelmode\""))
        XCTAssertTrue(helper.contains("identifier \"com.codex.travelmode.sleep-helper\""))
        XCTAssertTrue(app.contains("subject.OU] = \"ABCDE12345\""))
        XCTAssertTrue(helper.contains("subject.OU] = \"ABCDE12345\""))
        XCTAssertThrowsError(
            try SleepOverrideLeaseCodeSigningRequirements.appRequirement(
                teamIdentifier: "BAD\" or true"
            )
        )
    }

    func testTransportClientRejectsReceiptForAnotherBinding() async throws {
        let transport = FixedSleepOverrideLeaseTransport(
            reply: .receipt(
                SleepOverrideLeaseReceipt(
                    phase: .active,
                    binding: SleepOverrideLeaseBinding(
                        sessionID: "other-session",
                        requestID: "request",
                        leaseID: "lease",
                        generation: "generation"
                    )
                )
            )
        )
        let client = TransportSleepOverrideLeaseClient(transport: transport)

        do {
            _ = try await client.acquire(sessionID: "session", requestID: "request")
            XCTFail("A receipt for another session was accepted.")
        } catch let error as SleepOverrideLeaseError {
            XCTAssertEqual(error, .invalidReceipt)
        }
    }

    func testTransportClientMapsOnlyExplicitNotFoundToAuthoritativeNotFound() async throws {
        let notFoundClient = TransportSleepOverrideLeaseClient(
            transport: FixedSleepOverrideLeaseTransport(reply: .authoritativeNotFound)
        )
        let unavailableClient = TransportSleepOverrideLeaseClient(
            transport: FixedSleepOverrideLeaseTransport(
                error: .helperUnavailable(.definitelyNotSent)
            )
        )

        let resolution = try await notFoundClient.resolve(
            sessionID: "session",
            requestID: "request"
        )
        XCTAssertEqual(resolution, .authoritativeNotFound)

        do {
            _ = try await unavailableClient.resolve(sessionID: "session", requestID: "request")
            XCTFail("Transport unavailability was mapped to not-found.")
        } catch let error as SleepOverrideLeaseError {
            XCTAssertEqual(error, .helperUnavailable(.definitelyNotSent))
        }
    }

    func testAnonymousXPCInvalidationEndsServerConnectionExactlyOnce() async throws {
        let ended = expectation(description: "server observed connection invalidation")
        let recorder = ConnectionEndRecorder(expectation: ended)
        let service = RecordingSleepOverrideLeaseService(recorder: recorder)
        let listener = NSXPCListener.anonymous()
        let delegate = SleepOverrideLeaseXPCListenerDelegate(
            service: service,
            contextProvider: AnonymousConnectionContextProvider()
        )
        listener.delegate = delegate
        listener.activate()
        defer { listener.invalidate() }

        let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
        connection.remoteObjectInterface = SleepOverrideLeaseXPCInterface.make()
        connection.activate()

        let response = try await resolveOverAnonymousConnection(connection)
        XCTAssertEqual(try response.transportValue().outcome, .authoritativeNotFound)

        connection.invalidate()
        connection.invalidate()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(recorder.count, 1)
    }

    func testConfirmedRoundTripRearmsRecoverableInterruptionEvent() async {
        let hub = SleepOverrideLeaseProtectionEventHub()
        let stream = hub.stream()
        let collected = Task { () -> [SleepOverrideLeaseProtectionEvent] in
            var events: [SleepOverrideLeaseProtectionEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }

        hub.emit(.helperInterrupted)
        hub.emit(.helperInterrupted)
        hub.markRequestRoundTripCompleted()
        hub.emit(.helperInterrupted)
        hub.finish(with: .connectionInvalidated)

        let events = await collected.value
        XCTAssertEqual(
            events,
            [.helperInterrupted, .helperInterrupted, .connectionInvalidated]
        )
    }
}

private func resolveOverAnonymousConnection(
    _ connection: NSXPCConnection
) async throws -> SleepOverrideLeaseXPCReply {
    try await withCheckedThrowingContinuation { continuation in
        let gate = TestReplyGate(continuation)
        let remote = connection.remoteObjectProxyWithErrorHandler { error in
            gate.resume(throwing: error)
        }
        guard let service = remote as? any SleepOverrideLeaseXPCProtocol else {
            gate.resume(throwing: TestAdapterError.invalidProxy)
            return
        }
        service.resolve(sessionID: "session", requestID: "request") { reply in
            gate.resume(returning: reply)
        }
    }
}

private enum TestAdapterError: Error {
    case invalidProxy
    case unimplemented
}

private final class TestReplyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SleepOverrideLeaseXPCReply, Error>?

    init(_ continuation: CheckedContinuation<SleepOverrideLeaseXPCReply, Error>) {
        self.continuation = continuation
    }

    func resume(returning reply: SleepOverrideLeaseXPCReply) {
        take()?.resume(returning: reply)
    }

    func resume(throwing error: Error) {
        take()?.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<SleepOverrideLeaseXPCReply, Error>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

private struct AnonymousConnectionContextProvider:
    SleepOverrideLeaseXPCConnectionContextProviding,
    Sendable {
    func context(for connection: NSXPCConnection) throws -> SleepOverrideLeaseCallContext {
        SleepOverrideLeaseCallContext(
            principal: SleepOverrideLeaseCallerPrincipal(
                bundleIdentifier: "anonymous-adapter",
                teamIdentifier: "ABCDE12345",
                effectiveUserID: connection.effectiveUserIdentifier
            ),
            connectionID: SleepOverrideLeaseConnectionID()
        )
    }
}

private final class ConnectionEndRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let expectation: XCTestExpectation
    private var recordedCount = 0

    init(expectation: XCTestExpectation) {
        self.expectation = expectation
    }

    var count: Int {
        lock.withLock { recordedCount }
    }

    func record() {
        lock.withLock { recordedCount += 1 }
        expectation.fulfill()
    }
}

private actor RecordingSleepOverrideLeaseService: SleepOverrideLeaseXPCServiceHandling {
    let recorder: ConnectionEndRecorder

    init(recorder: ConnectionEndRecorder) {
        self.recorder = recorder
    }

    func acquire(
        sessionID: String,
        requestID: String,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        throw TestAdapterError.unimplemented
    }

    func resolve(
        sessionID: String,
        requestID: String,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseResolution {
        .authoritativeNotFound
    }

    func status(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        throw TestAdapterError.unimplemented
    }

    func release(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        throw TestAdapterError.unimplemented
    }

    func acknowledgeRelease(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws {
        throw TestAdapterError.unimplemented
    }

    func retryCleanup(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        throw TestAdapterError.unimplemented
    }

    func connectionEnded(id: SleepOverrideLeaseConnectionID) async {
        recorder.record()
    }
}

private struct FixedSleepOverrideLeaseTransport: SleepOverrideLeaseTransport {
    let reply: SleepOverrideLeaseTransportReply?
    let error: SleepOverrideLeaseTransportError?

    init(
        reply: SleepOverrideLeaseTransportReply? = nil,
        error: SleepOverrideLeaseTransportError? = nil
    ) {
        self.reply = reply
        self.error = error
    }

    func acquire(
        _ request: SleepOverrideLeaseAcquireRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try result()
    }

    func resolve(
        _ request: SleepOverrideLeaseAcquireRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try result()
    }

    func status(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try result()
    }

    func release(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try result()
    }

    func acknowledgeRelease(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try result()
    }

    func retryCleanup(
        _ request: SleepOverrideLeaseBindingRequest
    ) async throws -> SleepOverrideLeaseTransportReply {
        try result()
    }

    func protectionEvents() -> AsyncStream<SleepOverrideLeaseProtectionEvent> {
        AsyncStream { continuation in continuation.finish() }
    }

    private func result() throws -> SleepOverrideLeaseTransportReply {
        if let error {
            throw error
        }
        guard let reply else {
            throw SleepOverrideLeaseTransportError.invalidResponse("Missing fixed reply.")
        }
        return reply
    }
}
