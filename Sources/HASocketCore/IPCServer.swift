// Unix-domain-socket IPC server. Runs inside `hasocket serve`; every other
// `hasocket <command>` invocation is a client (see IPCClient). One accepted
// connection handles exactly one newline-delimited JSON request, then closes
// - simplest thing that works for a CLI that just wants a quick answer.
import Darwin
import Foundation

final class IPCServer: @unchecked Sendable {
    var onRequest: (@Sendable (IPCRequest) -> IPCResponse)?

    private var listenFD: Int32 = -1
    private var thread: Thread?
    private let lock = NSLock()
    private var stopped = false

    init() {}

    func start() throws {
        unlink(IPCSocket.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = IPCSocket.path
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ptr.pointee)) { cptr in
                path.withCString { src in
                    _ = strcpy(cptr, src)
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bindResult == 0 else { close(fd); throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { close(fd); throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        listenFD = fd
        let t = Thread { [weak self] in self?.acceptLoop() }
        t.name = "hasocket.IPCServer"
        thread = t
        t.start()
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(IPCSocket.path)
    }

    private func isStopped() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func acceptLoop() {
        while !isStopped() {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if isStopped() { return }
                continue
            }
            let t = Thread { [weak self] in self?.handle(clientFD: clientFD) }
            t.start()
        }
    }

    private func handle(clientFD: Int32) {
        defer { close(clientFD) }
        guard let line = Self.readLine(clientFD), let data = line.data(using: .utf8) else { return }

        let response: IPCResponse
        do {
            let request = try JSONDecoder().decode(IPCRequest.self, from: data)
            response = onRequest?(request) ?? .error("no handler registered")
        } catch {
            response = .error("bad request: \(error)")
        }

        guard let outData = try? JSONEncoder().encode(response) else { return }
        var out = outData
        out.append(0x0A)
        out.withUnsafeBytes { _ = write(clientFD, $0.baseAddress, $0.count) }
    }

    private static func readLine(_ fd: Int32) -> String? {
        var bytes: [UInt8] = []
        var buf = [UInt8](repeating: 0, count: 1)
        while true {
            let n = read(fd, &buf, 1)
            if n <= 0 { return bytes.isEmpty ? nil : String(bytes: bytes, encoding: .utf8) }
            if buf[0] == 0x0A { return String(bytes: bytes, encoding: .utf8) }
            bytes.append(buf[0])
            if bytes.count > 1_000_000 { return nil }
        }
    }
}
