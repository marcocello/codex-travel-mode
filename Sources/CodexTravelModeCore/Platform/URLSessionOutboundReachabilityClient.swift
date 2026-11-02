import Foundation

public final class URLSessionOutboundReachabilityClient: OutboundReachabilityChecking,
    @unchecked Sendable
{
    public static let defaultEndpoint = URL(
        string: "https://captive.apple.com/hotspot-detect.html"
    )!

    private let endpoint: URL
    private let protocolClasses: [AnyClass]?

    public init(endpoint: URL = URLSessionOutboundReachabilityClient.defaultEndpoint) {
        self.endpoint = endpoint
        protocolClasses = nil
    }

    init(testEndpoint endpoint: URL, protocolClasses: [AnyClass]) {
        self.endpoint = endpoint
        self.protocolClasses = protocolClasses
    }

    public func check(timeout: Duration, nonce: String) async -> ReachabilityResult {
        let timeoutInterval = reachabilityTimeInterval(timeout)
        guard timeoutInterval > 0 else {
            return .failed(.timedOut)
        }
        guard !Task.isCancelled else {
            return .failed(.cancelled)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = timeoutInterval
        configuration.timeoutIntervalForResource = timeoutInterval
        configuration.waitsForConnectivity = false
        if let protocolClasses {
            configuration.protocolClasses = protocolClasses
        }

        let delegate = DirectResponseSessionDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }

        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeoutInterval
        )
        request.httpMethod = "GET"
        request.httpBody = nil
        request.httpShouldHandleCookies = false
        request.setValue(nonce, forHTTPHeaderField: "X-Codex-Travel-Probe-Nonce")

        do {
            let (_, response) = try await session.data(for: request)
            guard !Task.isCancelled else {
                return .failed(.cancelled)
            }
            guard let response = response as? HTTPURLResponse else {
                return .failed(.nonHTTPResponse)
            }
            guard (200..<300).contains(response.statusCode) else {
                return .failed(.rejectedStatus(response.statusCode))
            }
            return .reachable(statusCode: response.statusCode)
        } catch is CancellationError {
            return .failed(.cancelled)
        } catch let error as URLError {
            if Task.isCancelled || error.code == .cancelled {
                return .failed(.cancelled)
            }
            if error.code == .timedOut {
                return .failed(.timedOut)
            }
            return .failed(.transport)
        } catch {
            return Task.isCancelled ? .failed(.cancelled) : .failed(.transport)
        }
    }
}

private final class DirectResponseSessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private func reachabilityTimeInterval(_ duration: Duration) -> TimeInterval {
    let components = duration.components
    let seconds = Double(components.seconds)
    let fraction = Double(components.attoseconds) / 1_000_000_000_000_000_000
    return max(0, seconds + fraction)
}
