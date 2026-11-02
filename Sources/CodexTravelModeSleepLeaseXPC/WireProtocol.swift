import CodexTravelModeSleepLease
import Foundation

@objc(CodexTravelModeSleepLeaseXPCBinding)
public final class SleepOverrideLeaseXPCBinding: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let sessionID: String
    public let requestID: String
    public let leaseID: String
    public let generation: String

    public init(binding: SleepOverrideLeaseTransportBinding) {
        sessionID = binding.sessionID
        requestID = binding.requestID
        leaseID = binding.leaseID
        generation = binding.generation
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let sessionID = coder.decodeObject(of: NSString.self, forKey: "sessionID") as String?,
              let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID") as String?,
              let leaseID = coder.decodeObject(of: NSString.self, forKey: "leaseID") as String?,
              let generation = coder.decodeObject(of: NSString.self, forKey: "generation") as String? else {
            return nil
        }
        self.sessionID = sessionID
        self.requestID = requestID
        self.leaseID = leaseID
        self.generation = generation
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(sessionID as NSString, forKey: "sessionID")
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(leaseID as NSString, forKey: "leaseID")
        coder.encode(generation as NSString, forKey: "generation")
    }

    public var transportValue: SleepOverrideLeaseTransportBinding {
        SleepOverrideLeaseTransportBinding(
            sessionID: sessionID,
            requestID: requestID,
            leaseID: leaseID,
            generation: generation
        )
    }
}

@objc(CodexTravelModeSleepLeaseXPCReply)
public final class SleepOverrideLeaseXPCReply: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool { true }

    public let outcome: String
    public let phase: String?
    public let binding: SleepOverrideLeaseXPCBinding?
    public let failureCode: String?
    public let detail: String?

    public init(reply: SleepOverrideLeaseTransportReply) {
        outcome = reply.outcome.rawValue
        phase = reply.phase?.rawValue
        binding = reply.binding.map(SleepOverrideLeaseXPCBinding.init(binding:))
        failureCode = reply.failureCode?.rawValue
        detail = reply.detail
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let outcome = coder.decodeObject(of: NSString.self, forKey: "outcome") as String? else {
            return nil
        }
        self.outcome = outcome
        phase = coder.decodeObject(of: NSString.self, forKey: "phase") as String?
        binding = coder.decodeObject(
            of: SleepOverrideLeaseXPCBinding.self,
            forKey: "binding"
        )
        failureCode = coder.decodeObject(of: NSString.self, forKey: "failureCode") as String?
        detail = coder.decodeObject(of: NSString.self, forKey: "detail") as String?
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(outcome as NSString, forKey: "outcome")
        coder.encode(phase as NSString?, forKey: "phase")
        coder.encode(binding, forKey: "binding")
        coder.encode(failureCode as NSString?, forKey: "failureCode")
        coder.encode(detail as NSString?, forKey: "detail")
    }

    public func transportValue() throws -> SleepOverrideLeaseTransportReply {
        guard let outcome = SleepOverrideLeaseTransportOutcome(rawValue: outcome) else {
            throw SleepOverrideLeaseTransportError.invalidResponse(
                "The helper returned an unknown outcome."
            )
        }
        let decodedPhase: SleepOverrideLeasePhase?
        if let phase {
            guard let value = SleepOverrideLeasePhase(rawValue: phase) else {
                throw SleepOverrideLeaseTransportError.invalidResponse(
                    "The helper returned an unknown lease phase."
                )
            }
            decodedPhase = value
        } else {
            decodedPhase = nil
        }
        let decodedFailure: SleepOverrideLeaseTransportFailureCode?
        if let failureCode {
            guard let value = SleepOverrideLeaseTransportFailureCode(rawValue: failureCode) else {
                throw SleepOverrideLeaseTransportError.invalidResponse(
                    "The helper returned an unknown failure code."
                )
            }
            decodedFailure = value
        } else {
            decodedFailure = nil
        }
        return SleepOverrideLeaseTransportReply(
            outcome: outcome,
            phase: decodedPhase,
            binding: binding?.transportValue,
            failureCode: decodedFailure,
            detail: detail
        )
    }
}

@objc(CodexTravelModeSleepLeaseXPCProtocol)
public protocol SleepOverrideLeaseXPCProtocol: NSObjectProtocol {
    @objc(acquireWithSessionID:requestID:reply:)
    func acquire(
        sessionID: String,
        requestID: String,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    )

    @objc(resolveWithSessionID:requestID:reply:)
    func resolve(
        sessionID: String,
        requestID: String,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    )

    @objc(statusWithBinding:reply:)
    func status(
        binding: SleepOverrideLeaseXPCBinding,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    )

    @objc(releaseWithBinding:reply:)
    func release(
        binding: SleepOverrideLeaseXPCBinding,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    )

    @objc(acknowledgeReleaseWithBinding:reply:)
    func acknowledgeRelease(
        binding: SleepOverrideLeaseXPCBinding,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    )

    @objc(retryCleanupWithBinding:reply:)
    func retryCleanup(
        binding: SleepOverrideLeaseXPCBinding,
        reply: @escaping (SleepOverrideLeaseXPCReply) -> Void
    )
}

public enum SleepOverrideLeaseXPCInterface {
    public static func make() -> NSXPCInterface {
        let interface = NSXPCInterface(with: SleepOverrideLeaseXPCProtocol.self)
        let replyClasses = NSSet(
            objects: SleepOverrideLeaseXPCReply.self,
            SleepOverrideLeaseXPCBinding.self
        ) as! Set<AnyHashable>
        let bindingClasses = NSSet(
            object: SleepOverrideLeaseXPCBinding.self
        ) as! Set<AnyHashable>

        let acquire = NSSelectorFromString("acquireWithSessionID:requestID:reply:")
        let resolve = NSSelectorFromString("resolveWithSessionID:requestID:reply:")
        let status = NSSelectorFromString("statusWithBinding:reply:")
        let release = NSSelectorFromString("releaseWithBinding:reply:")
        let acknowledge = NSSelectorFromString("acknowledgeReleaseWithBinding:reply:")
        let retry = NSSelectorFromString("retryCleanupWithBinding:reply:")

        for selector in [acquire, resolve, status, release, acknowledge, retry] {
            interface.setClasses(replyClasses, for: selector, argumentIndex: 0, ofReply: true)
        }
        for selector in [status, release, acknowledge, retry] {
            interface.setClasses(bindingClasses, for: selector, argumentIndex: 0, ofReply: false)
        }
        return interface
    }
}

extension SleepOverrideLeaseTransportReply {
    static func serverFailure(_ error: Error) -> Self {
        guard let error = error as? SleepOverrideLeaseError else {
            return .failure(.rejected, detail: error.localizedDescription)
        }
        switch error {
        case .helperUnavailable:
            return .failure(.helperUnavailable, detail: error.localizedDescription)
        case .unauthenticated:
            return .failure(.unauthenticated, detail: error.localizedDescription)
        case .interruptedAfterPossibleDispatch:
            return .failure(.interrupted, detail: error.localizedDescription)
        case .cleanupRequired(let detail):
            return .failure(.cleanupRequired, detail: detail)
        case .invalidReceipt:
            return .failure(.invalidReceipt, detail: error.localizedDescription)
        case .rejected(let detail):
            return .failure(.rejected, detail: detail)
        case .invalidResponse(let detail):
            return .failure(.invalidResponse, detail: detail)
        }
    }
}
