import Darwin
import Foundation

enum LiveObserverSocket {
    static let maximumMessageBytes = 64 * 1_024

    static func makeListener(at url: URL) throws -> Int32 {
        try requireSocketPath(url.path)
        var info = stat()
        guard Darwin.lstat(url.path, &info) != 0, errno == ENOENT else {
            throw ReadinessHarnessError.unsafeArtifact("observer socket path already exists")
        }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw socketError("create observer socket") }
        do {
            try configureNoSIGPIPE(descriptor)
            var address = try unixAddress(url.path)
            let length = socketAddressLength(path: url.path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, length)
                }
            }
            guard result == 0, Darwin.chmod(url.path, 0o600) == 0,
                  Darwin.listen(descriptor, 2) == 0 else {
                throw socketError("bind observer socket")
            }
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    static func accept(listener: Int32, deadlineMilliseconds: Int64) throws -> Int32 {
        let remaining = max(0, deadlineMilliseconds - LiveControllerSystem.millisecondsSinceEpoch())
        var pollDescriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let timeout = Int32(min(remaining, Int64(Int32.max)))
        guard Darwin.poll(&pollDescriptor, 1, timeout) == 1 else {
            throw ReadinessHarnessError.liveInterrupted("observer attach deadline elapsed")
        }
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else { throw socketError("accept observer session") }
        do {
            try configureNoSIGPIPE(descriptor)
            try configureIOTimeout(descriptor)
            return descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    static func acceptPending(listener: Int32) throws -> Int32? {
        var pollDescriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        let status = Darwin.poll(&pollDescriptor, 1, 0)
        guard status >= 0 else { throw socketError("inspect observer backlog") }
        guard status == 1, pollDescriptor.revents & Int16(POLLIN) != 0 else { return nil }
        let descriptor = Darwin.accept(listener, nil, nil)
        guard descriptor >= 0 else { throw socketError("reject observer session") }
        return descriptor
    }

    static func connect(at url: URL, timeoutMilliseconds: Int = 10_000) throws -> Int32 {
        try requireSocketPath(url.path)
        let deadline = LiveControllerSystem.millisecondsSinceEpoch() + Int64(timeoutMilliseconds)
        while true {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw socketError("create observer connection") }
            do {
                try configureNoSIGPIPE(descriptor)
                var address = try unixAddress(url.path)
                let result = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(
                            descriptor,
                            $0,
                            socketAddressLength(path: url.path)
                        )
                    }
                }
                if result == 0 { return descriptor }
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
            _ = Darwin.close(descriptor)
            guard LiveControllerSystem.millisecondsSinceEpoch() < deadline else {
                throw socketError("connect to observer")
            }
            usleep(25_000)
        }
    }

    static func writeJSON<Value: Encodable>(_ value: Value, to descriptor: Int32) throws {
        var data = try LiveProofCanonicalJSON.encode(value)
        guard data.count < maximumMessageBytes else {
            throw ReadinessHarnessError.liveInterrupted("observer message exceeds size bound")
        }
        data.append(10)
        try writeAll(data, descriptor: descriptor)
    }

    static func readJSON<Value: Decodable>(_ type: Value.Type, from descriptor: Int32) throws
        -> Value {
        let data = try readMessageData(from: descriptor)
        return try LiveProofCanonicalJSON.decode(type, from: data)
    }

    static func readMessageData(from descriptor: Int32) throws -> Data {
        try readLine(from: descriptor)
    }

    static func peerIdentity(descriptor: Int32) throws -> (uid: uid_t, pid: Int32) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(descriptor, &uid, &gid) == 0 else {
            throw socketError("identify observer peer")
        }
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout.size(ofValue: pid))
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              pid > 0 else {
            throw socketError("identify observer peer process")
        }
        return (uid, pid)
    }

    private static func readLine(from descriptor: Int32) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while data.count < maximumMessageBytes {
            let count = Darwin.read(descriptor, &byte, 1)
            guard count == 1 else {
                throw ReadinessHarnessError.liveInterrupted("observer message ended early")
            }
            if byte == 10 { return data }
            data.append(byte)
        }
        throw ReadinessHarnessError.liveInterrupted("observer message exceeds size bound")
    }

    private static func writeAll(_ data: Data, descriptor: Int32) throws {
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    data.count - offset
                )
                guard count > 0 else {
                    throw ReadinessHarnessError.liveInterrupted("observer message write failed")
                }
                offset += count
            }
        }
    }

    private static func unixAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count <= capacity else {
            throw ReadinessHarnessError.invalidArguments("output path is too long for observer socket")
        }
        withUnsafeMutablePointer(to: &address.sun_path) {
            $0.withMemoryRebound(to: UInt8.self, capacity: capacity) {
                $0.initialize(repeating: 0, count: capacity)
                for (index, byte) in bytes.enumerated() { $0[index] = byte }
            }
        }
        address.sun_len = UInt8(socketAddressLength(path: path))
        return address
    }

    private static func socketAddressLength(path: String) -> socklen_t {
        socklen_t(MemoryLayout<sa_family_t>.size + path.utf8.count + 1)
    }

    private static func requireSocketPath(_ path: String) throws {
        let address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count + 1 <= capacity else {
            throw ReadinessHarnessError.invalidArguments("output path is too long for observer socket")
        }
    }

    private static func configureNoSIGPIPE(_ descriptor: Int32) throws {
        var enabled: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &enabled,
            socklen_t(MemoryLayout.size(ofValue: enabled))
        ) == 0 else {
            throw socketError("configure observer socket")
        }
    }

    private static func configureIOTimeout(_ descriptor: Int32) throws {
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        let length = socklen_t(MemoryLayout.size(ofValue: timeout))
        guard setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, length) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, length) == 0 else {
            throw socketError("configure observer socket timeout")
        }
    }

    private static func socketError(_ operation: String) -> ReadinessHarnessError {
        .liveInterrupted("\(operation) failed: errno \(errno)")
    }
}
