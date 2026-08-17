// Unix-domain-socket IPC client - what every `hasocket <command>` invocation
// uses to reach a running `hasocket serve` in another terminal. Blocking,
// single-shot: connect, send one line, read one line, disconnect.
import Darwin
import Foundation

public enum IPCClientError: Error, CustomStringConvertible {
    case notRunning
    case protocolError(String)

    public var description: String {
        switch self {
        case .notRunning: return "hasocket isn't running (no socket at \(IPCSocket.path) - start it with `hasocket serve` in another terminal)"
        case .protocolError(let m): return m
        }
    }
}

public enum IPCClient {
    public static func send(_ request: IPCRequest, timeout: TimeInterval = 5) throws -> IPCResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCClientError.notRunning }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = IPCSocket.path
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ptr.pointee)) { cptr in
                path.withCString { src in _ = strcpy(cptr, src) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard connectResult == 0 else { throw IPCClientError.notRunning }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        let sent = payload.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard sent == payload.count else { throw IPCClientError.protocolError("failed writing request") }

        var bytes: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 1)
        while true {
            let n = read(fd, &buf, 1)
            if n <= 0 { throw IPCClientError.protocolError("connection closed before a full response arrived") }
            if buf[0] == 0x0A { break }
            bytes.append(buf[0])
        }

        do {
            return try JSONDecoder().decode(IPCResponse.self, from: Data(bytes))
        } catch {
            throw IPCClientError.protocolError("bad response: \(error)")
        }
    }
}
