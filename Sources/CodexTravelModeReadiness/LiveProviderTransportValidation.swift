import Foundation

public enum LiveProviderAcceptanceValidator {
    public static func validate(
        receipts: [LiveProofProviderReceipt],
        submits: [LiveProviderSubmitObservation],
        snapshots: [LiveObservedRuntimeNetworkSnapshot],
        capability: LiveProviderCapabilityObservation,
        providerPublicKey: String,
        expectedTargetSSIDDigest: String,
        closedWindow: ClosedRange<Int64>
    ) throws {
        guard receipts.count >= 3, receipts.count == submits.count,
              LiveProofValidation.isSHA256Hex(expectedTargetSSIDDigest),
              let firstSubmit = submits.first else {
            throw LiveProviderTransportError.observationMismatch(
                "at least three matching submits and receipts are required"
            )
        }
        let expectedNonces = submits.map(\.submit.nonce)
        try LiveProofProviderReceipt.requireExactSequence(
            receipts,
            runID: firstSubmit.submit.runID,
            scenario: firstSubmit.submit.scenario,
            expectedNonces: expectedNonces
        )
        try validateSubmitSequence(submits, first: firstSubmit.submit)
        try validateReceiptTimes(
            receipts,
            offset: capability.serverMinusLocalMilliseconds,
            window: closedWindow
        )
        for receipt in receipts {
            try receipt.verify(publicKeyBase64URL: providerPublicKey)
            try validatePublicSource(receipt)
        }
        for submit in submits {
            try validateAdjacency(
                submit,
                snapshots: snapshots,
                targetSSIDDigest: expectedTargetSSIDDigest
            )
        }
    }

    private static func validateSubmitSequence(
        _ submits: [LiveProviderSubmitObservation],
        first: LiveProviderHeartbeatSubmit
    ) throws {
        for (index, observation) in submits.enumerated() {
            let submit = observation.submit
            guard submit.sequence == index + 1,
                  submit.runID == first.runID,
                  submit.scenario == first.scenario,
                  observation.dispatchedAtUnixMilliseconds
                    <= observation.completedAtUnixMilliseconds else {
                throw LiveProviderTransportError.observationMismatch(
                    "submit sequence or timing changed"
                )
            }
        }
    }

    private static func validatePublicSource(
        _ receipt: LiveProofProviderReceipt
    ) throws {
        let family: LiveObservedAddressFamily =
            receipt.sourceFamily == .ipv4 ? .ipv4 : .ipv6
        let bytes = try LiveProofBase64URL.decode(
            receipt.sourceAddress,
            exactByteCount: family == .ipv4 ? 4 : 16
        )
        let source = try LiveObservedIPAddress(family: family, rawBytes: bytes)
        guard source.isPubliclyRoutable else {
            throw LiveProviderTransportError.observationMismatch(
                "provider source address is not public"
            )
        }
    }

    private static func validateReceiptTimes(
        _ receipts: [LiveProofProviderReceipt],
        offset: Int64,
        window: ClosedRange<Int64>
    ) throws {
        guard let first = receipts.first, let last = receipts.last,
              last.serverReceiveUnixMilliseconds - first.serverReceiveUnixMilliseconds
                >= 10_000 else {
            throw LiveProviderTransportError.observationMismatch(
                "provider receipts do not span ten seconds"
            )
        }
        for receipt in receipts {
            let conversion = receipt.serverReceiveUnixMilliseconds
                .subtractingReportingOverflow(offset)
            guard !conversion.overflow, window.contains(conversion.partialValue) else {
                throw LiveProviderTransportError.observationMismatch(
                    "receipt falls outside the adjusted closed window"
                )
            }
        }
    }

    private static func validateAdjacency(
        _ observation: LiveProviderSubmitObservation,
        snapshots: [LiveObservedRuntimeNetworkSnapshot],
        targetSSIDDigest: String
    ) throws {
        guard let metric = observation.taskMetrics.last,
              let localText = metric.localAddress,
              let remoteText = metric.remoteAddress else {
            throw LiveProviderTransportError.missingTaskMetrics
        }
        let local = try LiveObservedIPAddress(localText)
        let remote = try LiveObservedIPAddress(remoteText)
        guard remote.isPubliclyRoutable else {
            throw LiveProviderTransportError.observationMismatch(
                "TaskMetrics remote address is not public"
            )
        }
        let before = snapshots
            .filter {
                $0.capturedAtUnixMilliseconds <= observation.dispatchedAtUnixMilliseconds
                    && observation.dispatchedAtUnixMilliseconds
                        - $0.capturedAtUnixMilliseconds <= 2_000
            }
            .max { $0.capturedAtUnixMilliseconds < $1.capturedAtUnixMilliseconds }
        let after = snapshots
            .filter {
                $0.capturedAtUnixMilliseconds >= observation.completedAtUnixMilliseconds
                    && $0.capturedAtUnixMilliseconds
                        - observation.completedAtUnixMilliseconds <= 2_000
            }
            .min { $0.capturedAtUnixMilliseconds < $1.capturedAtUnixMilliseconds }
        guard let before, let after else {
            throw LiveProviderTransportError.observationMismatch(
                "submit lacks adjacent observer snapshots"
            )
        }
        try validateSnapshot(
            before,
            local: local,
            remote: remote,
            targetSSIDDigest: targetSSIDDigest
        )
        try validateSnapshot(
            after,
            local: local,
            remote: remote,
            targetSSIDDigest: targetSSIDDigest
        )
    }

    private static func validateSnapshot(
        _ snapshot: LiveObservedRuntimeNetworkSnapshot,
        local: LiveObservedIPAddress,
        remote: LiveObservedIPAddress,
        targetSSIDDigest: String
    ) throws {
        let localMatches = snapshot.interfaceAddresses.contains {
            $0.family == local.family && $0.rawBytes == local.rawBytes && $0.isUsable
        }
        guard snapshot.sleepDisabled, snapshot.lidClosed,
              snapshot.battery.source == .battery, snapshot.wifiPowered,
              snapshot.ssidDigest == targetSSIDDigest,
              snapshot.routeDevice == snapshot.wifiDevice,
              snapshot.routedRemoteAddress.family == remote.family,
              snapshot.routedRemoteAddress.rawBytes == remote.rawBytes,
              localMatches else {
            throw LiveProviderTransportError.observationMismatch(
                "adjacent observer snapshot does not bind provider transport"
            )
        }
    }
}
