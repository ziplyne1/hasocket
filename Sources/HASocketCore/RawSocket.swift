// Raw POSIX socket helpers shared by the websocket client and the plain
// HTTP REST client. Deliberately not URLSession/Network.framework - a bare,
// non-Terminal-descended process on this machine could never get outbound
// LAN connections to work through those APIs (see hasocket's history), while
// raw BSD sockets connect fine from any process. Kept even though hasocket
// is meant to be started from a terminal for now, so it stays safe to
// auto-start later without hitting that bug again.
import Darwin
import Foundation

struct WSError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func posixConnect(host: String, port: UInt16) throws -> Int32 {
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                          ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else {
        throw WSError(message: "DNS lookup failed for \(host)")
    }
    defer { freeaddrinfo(res) }

    var lastErrno: Int32 = 0
    var p: UnsafeMutablePointer<addrinfo>? = first
    while let addr = p {
        let fd = socket(addr.pointee.ai_family, addr.pointee.ai_socktype, addr.pointee.ai_protocol)
        if fd >= 0 {
            if connect(fd, addr.pointee.ai_addr, addr.pointee.ai_addrlen) == 0 {
                var timeout = timeval(tv_sec: 25, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                return fd
            }
            lastErrno = errno
            close(fd)
        } else {
            lastErrno = errno
        }
        p = addr.pointee.ai_next
    }
    throw WSError(message: "could not connect to \(host):\(port) (errno \(lastErrno): \(String(cString: strerror(lastErrno))))")
}

func readExact(_ fd: Int32, _ count: Int) throws -> [UInt8] {
    guard count > 0 else { return [] }
    var buf = [UInt8](repeating: 0, count: count)
    var total = 0
    var timedOut = false
    buf.withUnsafeMutableBufferPointer { ptr in
        while total < count {
            let n = read(fd, ptr.baseAddress!.advanced(by: total), count - total)
            if n > 0 { total += n; continue }
            if n < 0, (errno == EAGAIN || errno == EWOULDBLOCK) { timedOut = true }
            break
        }
    }
    if timedOut { throw WSError(message: "read timeout") }
    guard total == count else { throw WSError(message: "connection closed") }
    return buf
}

// MARK: - WebSocket framing

func wsHandshake(fd: Int32, host: String, path: String) throws {
    let key = Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    let req = "GET \(path) HTTP/1.1\r\nHost: \(host)\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(key)\r\nSec-WebSocket-Version: 13\r\n\r\n"
    let reqBytes = Array(req.utf8)
    let sent = reqBytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    guard sent == reqBytes.count else { throw WSError(message: "failed writing handshake") }

    var header: [UInt8] = []
    while header.count < 4 || header.suffix(4) != [13, 10, 13, 10] {
        header += try readExact(fd, 1)
        if header.count > 8192 { throw WSError(message: "handshake response too large") }
    }
    let status = String(bytes: header, encoding: .utf8) ?? ""
    guard status.contains(" 101 ") else { throw WSError(message: "handshake rejected: \(status.split(separator: "\r").first ?? "")") }
}

func wsSendText(fd: Int32, _ text: String) throws {
    var payload = Array(text.utf8)
    var frame: [UInt8] = [0x81]
    let len = payload.count
    if len < 126 {
        frame.append(0x80 | UInt8(len))
    } else if len < 65536 {
        frame.append(0x80 | 126)
        frame.append(UInt8((len >> 8) & 0xff))
        frame.append(UInt8(len & 0xff))
    } else {
        frame.append(0x80 | 127)
        for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((len >> shift) & 0xff)) }
    }
    let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
    frame += mask
    for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
    frame += payload
    let sent = frame.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    guard sent == frame.count else { throw WSError(message: "failed writing frame") }
}

func wsReadMessage(fd: Int32) throws -> String? {
    var payload: [UInt8] = []
    while true {
        let header = try readExact(fd, 2)
        let opcode = header[0] & 0x0f
        let fin = (header[0] & 0x80) != 0
        var len = Int(header[1] & 0x7f)
        if len == 126 {
            let ext = try readExact(fd, 2)
            len = Int(ext[0]) << 8 | Int(ext[1])
        } else if len == 127 {
            let ext = try readExact(fd, 8)
            len = ext.reduce(0) { ($0 << 8) | Int($1) }
        }
        let framePayload = try readExact(fd, len)

        switch opcode {
        case 0x8:
            return nil
        case 0x9:
            var pong: [UInt8] = [0x8A, 0x80]
            let mask = (0..<4).map { _ in UInt8.random(in: 0...255) }
            pong += mask
            var body = framePayload
            for i in 0..<body.count { body[i] ^= mask[i % 4] }
            pong[1] = 0x80 | UInt8(body.count)
            pong += body
            _ = pong.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
            continue
        case 0xA:
            continue
        default:
            payload += framePayload
            if fin { return String(bytes: payload, encoding: .utf8) }
        }
    }
}
