import Foundation
import Security

public enum LiveProviderURLSessionPolicy {
    public static let timeout: TimeInterval = 5
    public static let maximumResponseBytes = 64 * 1_024

    public static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.connectionProxyDictionary = [:]
        configuration.waitsForConnectivity = false
        return configuration
    }
}

public struct LiveProviderURLSessionTransport: LiveProviderHTTPTransporting {
    public init() {}

    public func send(_ request: URLRequest) async throws -> LiveProviderHTTPResponse {
        try await LiveProviderURLSessionOperation().start(request)
    }
}

private final class LiveProviderURLSessionOperation: NSObject, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LiveProviderHTTPResponse, Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var metrics: [LiveProviderTaskMetric] = []
    private var redirected = false

    func start(_ request: URLRequest) async throws -> LiveProviderHTTPResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            let session = URLSession(
                configuration: LiveProviderURLSessionPolicy.makeConfiguration(),
                delegate: self,
                delegateQueue: nil
            )
            self.session = session
            lock.unlock()
            session.dataTask(with: request).resume()
        }
    }

    private func finish(_ result: Result<LiveProviderHTTPResponse, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let session = self.session
        self.session = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }

    private func metric(_ transaction: URLSessionTaskTransactionMetrics)
        -> LiveProviderTaskMetric {
        LiveProviderTaskMetric(
            localAddress: transaction.localAddress,
            remoteAddress: transaction.remoteAddress,
            fetchStartedUnixMilliseconds: milliseconds(transaction.fetchStartDate),
            responseEndedUnixMilliseconds: milliseconds(transaction.responseEndDate)
        )
    }

    private func milliseconds(_ date: Date?) -> Int64? {
        date.map { Int64(($0.timeIntervalSince1970 * 1_000).rounded(.down)) }
    }
}

extension LiveProviderURLSessionOperation: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(LiveProviderTransportError.invalidResponse("non-HTTP response")))
            return
        }
        if response.expectedContentLength > LiveProviderURLSessionPolicy.maximumResponseBytes {
            completionHandler(.cancel)
            finish(.failure(LiveProviderTransportError.responseTooLarge))
            return
        }
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let tooLarge = self.data.count + data.count
            > LiveProviderURLSessionPolicy.maximumResponseBytes
        if !tooLarge { self.data.append(data) }
        lock.unlock()
        if tooLarge {
            dataTask.cancel()
            finish(.failure(LiveProviderTransportError.responseTooLarge))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        redirected = true
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        self.metrics = metrics.transactionMetrics.map(metric)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let response = self.response
        let data = self.data
        let metrics = self.metrics
        let redirected = self.redirected
        lock.unlock()
        if error != nil {
            finish(.failure(LiveProviderTransportError.invalidResponse("transport failed")))
            return
        }
        guard let response, let finalURL = response.url else {
            finish(.failure(LiveProviderTransportError.invalidResponse("missing HTTP response")))
            return
        }
        finish(.success(LiveProviderHTTPResponse(
            data: data,
            statusCode: response.statusCode,
            finalURL: finalURL,
            redirectAttempted: redirected,
            taskMetrics: metrics
        )))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod
            == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

public struct LiveProviderKeychainBearerReader: LiveProviderBearerTokenReading {
    public init() {}

    public func readToken(service: String, account: String) throws -> Data? {
        guard !service.isEmpty, !account.isEmpty else {
            throw LiveProviderTransportError.invalidConfiguration(
                "Keychain reference is incomplete"
            )
        }
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw LiveProviderTransportError.invalidConfiguration(
                "Keychain bearer token is unavailable"
            )
        }
        return data
    }
}

public struct LiveProviderClient: Sendable {
    private let configuration: LiveProofProviderConfiguration
    private let transport: any LiveProviderHTTPTransporting
    private let bearerReader: any LiveProviderBearerTokenReading
    private let clock: any LiveProviderClock

    public init(
        configuration: LiveProofProviderConfiguration,
        transport: any LiveProviderHTTPTransporting,
        bearerReader: any LiveProviderBearerTokenReading,
        clock: any LiveProviderClock = LiveProviderSystemClock()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.bearerReader = bearerReader
        self.clock = clock
    }

    public func capability() async throws -> LiveProviderCapabilityObservation {
        let request = try makeRequest(path: configuration.capabilityPath)
        let started = clock.nowUnixMilliseconds()
        let response = try await checkedResponse(request)
        let ended = clock.nowUnixMilliseconds()
        let capability = try LiveProviderCapability.decodeStrict(
            response.data,
            configuration: configuration
        )
        return try LiveProviderCapabilityObservation(
            capability: capability,
            requestStartedUnixMilliseconds: started,
            responseEndedUnixMilliseconds: ended
        )
    }

    public func submit(
        _ submit: LiveProviderHeartbeatSubmit
    ) async throws -> LiveProviderSubmitObservation {
        var request = try makeRequest(path: configuration.submitPath)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try LiveProofCanonicalJSON.encode(submit)
        let started = clock.nowUnixMilliseconds()
        let response = try await checkedResponse(request)
        let ended = clock.nowUnixMilliseconds()
        guard !response.taskMetrics.isEmpty else {
            throw LiveProviderTransportError.missingTaskMetrics
        }
        return LiveProviderSubmitObservation(
            submit: submit,
            dispatchedAtUnixMilliseconds: started,
            completedAtUnixMilliseconds: ended,
            taskMetrics: response.taskMetrics
        )
    }

    public func readback(
        runID: String,
        scenario: ReadinessScenario
    ) async throws -> LiveProviderHeartbeatReadback {
        guard LiveProofValidation.isCanonicalRunID(runID) else {
            throw LiveProviderTransportError.invalidConfiguration("run ID is not canonical")
        }
        let items = [
            URLQueryItem(name: "run_id", value: runID),
            URLQueryItem(name: "scenario", value: scenario.rawValue),
        ]
        let request = try makeRequest(path: configuration.readbackPath, queryItems: items)
        return try LiveProviderHeartbeatReadback.decodeStrict(
            try await checkedResponse(request).data
        )
    }

    private func makeRequest(
        path: String,
        queryItems: [URLQueryItem] = []
    ) throws -> URLRequest {
        guard var components = URLComponents(string: configuration.origin) else {
            throw LiveProviderTransportError.invalidConfiguration("provider origin is invalid")
        }
        components.percentEncodedPath = path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else {
            throw LiveProviderTransportError.invalidConfiguration("provider URL is invalid")
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: LiveProviderURLSessionPolicy.timeout
        )
        request.httpMethod = "GET"
        if let keychain = configuration.keychain {
            guard let data = try bearerReader.readToken(
                service: keychain.service,
                account: keychain.account
            ), let token = String(data: data, encoding: .utf8),
                  !token.isEmpty, !token.contains("\r"), !token.contains("\n") else {
                throw LiveProviderTransportError.invalidConfiguration(
                    "Keychain bearer token is missing or invalid UTF-8"
                )
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func checkedResponse(
        _ request: URLRequest
    ) async throws -> LiveProviderHTTPResponse {
        let response = try await transport.send(request)
        guard !response.redirectAttempted else {
            throw LiveProviderTransportError.redirectRejected
        }
        guard response.data.count <= LiveProviderURLSessionPolicy.maximumResponseBytes,
              (200...299).contains(response.statusCode),
              response.finalURL == request.url else {
            throw LiveProviderTransportError.invalidResponse("HTTP response was rejected")
        }
        return response
    }
}
