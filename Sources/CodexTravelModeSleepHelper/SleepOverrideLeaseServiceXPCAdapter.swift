import CodexTravelModeSleepLease
import CodexTravelModeSleepLeaseXPC

struct SleepOverrideLeaseServiceXPCAdapter: SleepOverrideLeaseXPCServiceHandling, Sendable {
    let service: SleepOverrideLeaseService

    func acquire(
        sessionID: String,
        requestID: String,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        try await service.acquire(
            sessionID: sessionID,
            requestID: requestID,
            context: context
        )
    }

    func resolve(
        sessionID: String,
        requestID: String,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseResolution {
        try await service.resolve(
            sessionID: sessionID,
            requestID: requestID,
            context: context
        )
    }

    func status(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        try await service.status(binding: binding, context: context)
    }

    func release(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        try await service.release(binding: binding, context: context)
    }

    func acknowledgeRelease(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws {
        try await service.acknowledgeRelease(binding: binding, context: context)
    }

    func retryCleanup(
        binding: SleepOverrideLeaseBinding,
        context: SleepOverrideLeaseCallContext
    ) async throws -> SleepOverrideLeaseReceipt {
        try await service.retryCleanup(binding: binding, context: context)
    }

    func connectionEnded(id: SleepOverrideLeaseConnectionID) async {
        await service.connectionInvalidated(id: id)
    }
}
