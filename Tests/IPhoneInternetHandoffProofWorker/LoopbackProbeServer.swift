import Darwin
import Foundation

final class LoopbackProbeServer: @unchecked Sendable {
    private let trace: TraceRecorder
    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "codex-travel-mode.proof.loopback")
    private var listeningFD: Int32 = -1
    private var running = false
    private(set) var port: UInt16 = 0

    init(trace: TraceRecorder) throws {
        self.trace = trace
        try start()
    }

    deinit {
        stop()
    }

    func url(path: String = "/probe") -> URL {
        URL(string: "http://127.0.0.1:\(port)\(path)")!
    }

    func stop() {
        let fd: Int32 = stateLock.withLock {
            guard running else { return -1 }
            running = false
            let value = listeningFD
            listeningFD = -1
            return value
        }
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }

    private func start() throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(errno) }
        var reuse: Int32 = 1
        let reuseSize = socklen_t(MemoryLayout<Int32>.size)
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, reuseSize)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindCode = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindCode == 0 else {
            Darwin.close(fd)
            throw ServerError.bind(errno)
        }
        guard Darwin.listen(fd, 32) == 0 else {
            Darwin.close(fd)
            throw ServerError.listen(errno)
        }

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameCode = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameCode == 0 else {
            Darwin.close(fd)
            throw ServerError.address(errno)
        }

        stateLock.withLock {
            listeningFD = fd
            running = true
            port = UInt16(bigEndian: resolved.sin_port)
        }
        queue.async { [weak self] in
            self?.acceptLoop(fd: fd)
        }
    }

    private func acceptLoop(fd: Int32) {
        while stateLock.withLock({ running && listeningFD == fd }) {
            let client = Darwin.accept(fd, nil, nil)
            if client < 0 {
                if !stateLock.withLock({ running }) { return }
                continue
            }
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        var noSignal: Int32 = 1
        let noSignalSize = socklen_t(MemoryLayout<Int32>.size)
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, noSignalSize)
        }
        guard let request = readRequest(client) else { return }
        let responseCode = request.path == "/reject" ? 503 : 204
        let receiptID = UUID().uuidString
        trace.recordHTTPReceipt(
            receiptID: receiptID,
            method: request.method,
            path: request.path,
            nonce: request.headers["x-codex-travel-probe-nonce"],
            headerNames: Array(request.headers.keys),
            body: request.body,
            responseCode: responseCode
        )
        if request.path == "/slow" {
            usleep(500_000)
        }
        let reason = responseCode == 204 ? "No Content" : "Service Unavailable"
        let response = "HTTP/1.1 \(responseCode) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\nX-Probe-Receipt-ID: \(receiptID)\r\n\r\n"
        response.withCString { pointer in
            _ = Darwin.send(client, pointer, strlen(pointer), 0)
        }
    }

    private func readRequest(_ client: Int32) -> ParsedRequest? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil, data.count < 64 * 1024 {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
        }
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        let bodyStart = headerRange.upperBound
        let bodyLength = Int(headers["content-length"] ?? "0") ?? 0
        while data.count - bodyStart < bodyLength, data.count < 128 * 1024 {
            let count = Darwin.recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        let bodyEnd = min(data.count, bodyStart + bodyLength)
        return ParsedRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: Data(data[bodyStart..<bodyEnd])
        )
    }
}

private struct ParsedRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private enum ServerError: Error {
    case socket(Int32)
    case bind(Int32)
    case listen(Int32)
    case address(Int32)
}
