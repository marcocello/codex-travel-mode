import Darwin
import Foundation

public final class ProofUnixSocket: @unchecked Sendable {
    private let descriptorLock = NSLock()
    private var descriptor: Int32
    private let requestQueue = DispatchQueue(label: "com.codex.travelmode.proof-socket")

    public init(connectingTo path: String) throws {
        descriptor = try connectProofSocket(path: path)
    }

    public init(acceptedDescriptor: Int32) {
        descriptor = acceptedDescriptor
    }

    deinit {
        close()
    }

    public func request(_ request: ProofLeaseRequest) async throws -> ProofLeaseResponse {
        try await withCheckedThrowingContinuation { continuation in
            requestQueue.async { [self] in
                do {
                    let descriptor = try currentDescriptor()
                    try writeProofFrame(request, to: descriptor)
                    guard let response = try readProofFrame(
                        ProofLeaseResponse.self,
                        from: descriptor
                    ) else {
                        throw ProofLeaseSupportError.connectionClosed
                    }
                    guard response.correlationID == request.correlationID else {
                        throw ProofLeaseSupportError.malformedResponse(
                            "The proof helper returned another request's correlation ID."
                        )
                    }
                    continuation.resume(returning: response)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() {
        descriptorLock.lock()
        let closing = descriptor
        descriptor = -1
        descriptorLock.unlock()
        guard closing >= 0 else { return }
        Darwin.shutdown(closing, SHUT_RDWR)
        Darwin.close(closing)
    }

    public func rawDescriptor() throws -> Int32 {
        try currentDescriptor()
    }

    public func configureRequestTimeout(seconds: Int) throws {
        guard seconds > 0 else {
            throw ProofLeaseSupportError.invalidArguments(
                "The proof socket timeout must be positive."
            )
        }
        let descriptor = try currentDescriptor()
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let size = socklen_t(MemoryLayout<timeval>.size)
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0 else {
            throw socketError("setsockopt(SO_RCVTIMEO)")
        }
        guard setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0 else {
            throw socketError("setsockopt(SO_SNDTIMEO)")
        }
    }

    private func currentDescriptor() throws -> Int32 {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        guard descriptor >= 0 else {
            throw ProofLeaseSupportError.connectionClosed
        }
        return descriptor
    }
}

public final class ProofSocketEOFMonitor: @unchecked Sendable {
    private let socket: ProofUnixSocket
    private let queue = DispatchQueue(label: "com.codex.travelmode.proof-eof-monitor")
    private let callbackLock = NSLock()
    private var didNotify = false

    public init(socket: ProofUnixSocket, onEOF: @escaping @Sendable () -> Void) throws {
        self.socket = socket
        let descriptor = Darwin.dup(try socket.rawDescriptor())
        guard descriptor >= 0 else {
            throw ProofLeaseSupportError.socket(
                "Could not duplicate the proof monitor socket: \(String(cString: strerror(errno)))"
            )
        }
        queue.async { [weak self] in
            defer { Darwin.close(descriptor) }
            var byte: UInt8 = 0
            let count = Darwin.recv(descriptor, &byte, 1, 0)
            guard count <= 0 else { return }
            self?.notifyOnce(onEOF)
        }
    }

    public func cancel() {
        socket.close()
    }

    private func notifyOnce(_ callback: @Sendable () -> Void) {
        callbackLock.lock()
        guard !didNotify else {
            callbackLock.unlock()
            return
        }
        didNotify = true
        callbackLock.unlock()
        callback()
    }
}

public struct ProofUnixListener: Sendable {
    public let descriptor: Int32
    public let path: String

    public init(path: String) throws {
        self.path = path
        descriptor = try createProofListener(path: path)
    }

    public func acceptConnection() throws -> Int32 {
        let accepted = Darwin.accept(descriptor, nil, nil)
        guard accepted >= 0 else {
            throw socketError("accept")
        }
        do {
            try suppressBrokenPipeSignal(accepted)
        } catch {
            Darwin.close(accepted)
            throw error
        }
        return accepted
    }

    public func close() {
        Darwin.close(descriptor)
        unlink(path)
    }
}

public func readProofFrame<Value: Decodable>(
    _ type: Value.Type,
    from descriptor: Int32
) throws -> Value? {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(512)
    while bytes.count <= 1_048_576 {
        var byte: UInt8 = 0
        let count = Darwin.recv(descriptor, &byte, 1, 0)
        if count == 0 {
            return bytes.isEmpty ? nil : try decodeProofFrame(type, bytes: bytes)
        }
        if count < 0 {
            if errno == EINTR { continue }
            throw socketError("recv")
        }
        if byte == 0x0A {
            return try decodeProofFrame(type, bytes: bytes)
        }
        bytes.append(byte)
    }
    throw ProofLeaseSupportError.malformedResponse("Proof frame exceeded 1 MiB.")
}

public func writeProofFrame<Value: Encodable>(
    _ value: Value,
    to descriptor: Int32
) throws {
    var data = try JSONEncoder().encode(value)
    data.append(0x0A)
    try data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let sent = Darwin.send(
                descriptor,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset,
                0
            )
            if sent < 0 {
                if errno == EINTR { continue }
                throw socketError("send")
            }
            offset += sent
        }
    }
}

private func decodeProofFrame<Value: Decodable>(
    _ type: Value.Type,
    bytes: [UInt8]
) throws -> Value {
    do {
        return try JSONDecoder().decode(type, from: Data(bytes))
    } catch {
        throw ProofLeaseSupportError.malformedResponse(
            "Could not decode proof frame: \(error.localizedDescription)"
        )
    }
}

private func connectProofSocket(path: String) throws -> Int32 {
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw socketError("socket") }
    do {
        try suppressBrokenPipeSignal(descriptor)
        var address = try proofSocketAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, proofSocketAddressLength(path: path))
            }
        }
        guard result == 0 else { throw socketError("connect") }
        return descriptor
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

private func createProofListener(path: String) throws -> Int32 {
    unlink(path)
    let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw socketError("socket") }
    do {
        var address = try proofSocketAddress(path: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, proofSocketAddressLength(path: path))
            }
        }
        guard result == 0 else { throw socketError("bind") }
        guard Darwin.listen(descriptor, 16) == 0 else { throw socketError("listen") }
        return descriptor
    } catch {
        Darwin.close(descriptor)
        throw error
    }
}

private func suppressBrokenPipeSignal(_ descriptor: Int32) throws {
    var enabled: Int32 = 1
    let result = setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
    )
    guard result == 0 else { throw socketError("setsockopt(SO_NOSIGPIPE)") }
}

private func proofSocketAddress(path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8CString)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard bytes.count <= capacity else {
        throw ProofLeaseSupportError.socket("Unix socket path is too long: \(path)")
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(proofSocketAddressLength(path: path))
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
            for (index, byte) in bytes.enumerated() {
                destination[index] = byte
            }
        }
    }
    return address
}

private func proofSocketAddressLength(path: String) -> socklen_t {
    let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) ?? 0
    return socklen_t(offset + path.utf8.count + 1)
}

private func socketError(_ operation: String) -> ProofLeaseSupportError {
    let detail = String(cString: strerror(errno))
    return .socket("Unix socket \(operation) failed: \(detail)")
}
