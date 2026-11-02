import ApplicationServices
import CodexTravelModeCore
import Foundation

public protocol LivePlatformAXSemanticReading: Sendable {
    func semanticValues(appPID: Int32) throws -> [String: String]
}

public struct LivePlatformSystemAXSemanticReader:
    LivePlatformAXSemanticReading, @unchecked Sendable {
    public static let maximumDepth = 12
    public static let maximumNodes = 512
    public static let maximumChildrenPerNode = 128

    public init() {}

    public func semanticValues(appPID: Int32) throws -> [String: String] {
        guard appPID > 0 else {
            throw LivePlatformReadinessError.uiReadback("invalid Accessibility app PID")
        }
        let root = AXUIElementCreateApplication(appPID)
        var pending = [AXPendingElement(element: root, depth: 0)]
        var index = 0
        var values: [String: String] = [:]
        while index < pending.count {
            guard index < Self.maximumNodes else {
                throw LivePlatformReadinessError.uiReadback(
                    "Accessibility traversal exceeded its node bound"
                )
            }
            let current = pending[index]
            index += 1
            try requirePID(current.element, expected: appPID)
            try appendSemanticValue(from: current.element, to: &values)
            guard current.depth < Self.maximumDepth else { continue }
            let children = try children(of: current.element)
            guard children.count <= Self.maximumChildrenPerNode,
                  pending.count + children.count <= Self.maximumNodes else {
                throw LivePlatformReadinessError.uiReadback(
                    "Accessibility traversal exceeded its child bound"
                )
            }
            pending.append(contentsOf: children.map {
                AXPendingElement(element: $0, depth: current.depth + 1)
            })
        }
        return values
    }

    private func requirePID(_ element: AXUIElement, expected: Int32) throws {
        var actual: pid_t = 0
        guard AXUIElementGetPid(element, &actual) == .success, actual == expected else {
            throw LivePlatformReadinessError.uiReadback(
                "Accessibility element escaped the exact app process"
            )
        }
    }

    private func appendSemanticValue(
        from element: AXUIElement,
        to values: inout [String: String]
    ) throws {
        guard let identifier = try stringAttribute(
            kAXIdentifierAttribute as CFString,
            from: element
        ), !identifier.isEmpty,
        let value = try stringAttribute(kAXValueAttribute as CFString, from: element) else {
            return
        }
        guard values.updateValue(value, forKey: identifier) == nil else {
            throw LivePlatformReadinessError.uiReadback(
                "Accessibility identifier is duplicated"
            )
        }
    }

    private func stringAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) throws -> String? {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &raw)
        if error == .noValue || error == .attributeUnsupported { return nil }
        guard error == .success else {
            throw LivePlatformReadinessError.uiReadback(
                "Accessibility attribute read failed with \(error.rawValue)"
            )
        }
        return raw as? String
    }

    private func children(of element: AXUIElement) throws -> [AXUIElement] {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &raw
        )
        if error == .noValue || error == .attributeUnsupported { return [] }
        guard error == .success, let children = raw as? [AXUIElement] else {
            throw LivePlatformReadinessError.uiReadback(
                "Accessibility children are malformed"
            )
        }
        return children
    }
}

public struct LivePlatformProductionUIAXReader:
    LivePlatformProductionUIReading, Sendable {
    private let semanticReader: any LivePlatformAXSemanticReading
    private let processResolver: any LivePlatformProcessResolving
    private let clock: any LiveProviderClock

    public init(
        semanticReader: any LivePlatformAXSemanticReading =
            LivePlatformSystemAXSemanticReader(),
        processResolver: any LivePlatformProcessResolving =
            LivePlatformProcessResolver(),
        clock: any LiveProviderClock = LiveProviderSystemClock()
    ) {
        self.semanticReader = semanticReader
        self.processResolver = processResolver
        self.clock = clock
    }

    public func readback(
        app: LivePlatformResolvedProcess
    ) async throws -> LivePlatformProductionUIReadback {
        try requireCurrent(app)
        let values = try semanticReader.semanticValues(appPID: app.pid)
        try requireCurrent(app)
        return try LivePlatformProductionUIReadback(
            observedAtUnixMilliseconds: clock.nowUnixMilliseconds(),
            appPID: app.pid,
            appStartIdentity: app.startIdentity,
            locationAuthorization: try location(values),
            committedTargetSSID: try required(
                TravelModeStatusAccessibility.committedHotspot,
                values
            ),
            wifiDevice: try required(TravelModeStatusAccessibility.wifiDevice, values),
            targetVisible: try boolean(
                TravelModeStatusAccessibility.targetVisible,
                values
            ),
            savedCredentialPresent: try boolean(
                TravelModeStatusAccessibility.savedCredential,
                values
            ),
            codexRunning: try boolean(
                TravelModeStatusAccessibility.codexRunning,
                values
            )
        )
    }

    private func requireCurrent(_ app: LivePlatformResolvedProcess) throws {
        guard try processResolver.process(pid: app.pid) == app else {
            throw LivePlatformReadinessError.processNotFound(
                "production app process identity changed during UI readback"
            )
        }
    }

    private func location(
        _ values: [String: String]
    ) throws -> LivePlatformLocationAuthorization {
        switch try required(TravelModeStatusAccessibility.locationAuthorization, values) {
        case "completed": return .authorized
        case "denied": return .denied
        case "restricted": return .restricted
        case "not_determined": return .notDetermined
        case "services_disabled": return .servicesDisabled
        default:
            throw LivePlatformReadinessError.uiReadback(
                "production Location status is unavailable"
            )
        }
    }

    private func boolean(_ identifier: String, _ values: [String: String]) throws -> Bool {
        switch try required(identifier, values) {
        case "true": return true
        case "false": return false
        default:
            throw LivePlatformReadinessError.uiReadback(
                "production UI Boolean is malformed"
            )
        }
    }

    private func required(_ identifier: String, _ values: [String: String]) throws -> String {
        guard let value = values[identifier], !value.isEmpty, value != "Not selected" else {
            throw LivePlatformReadinessError.uiReadback(
                "production UI value is missing"
            )
        }
        return value
    }
}

private struct AXPendingElement {
    let element: AXUIElement
    let depth: Int
}
