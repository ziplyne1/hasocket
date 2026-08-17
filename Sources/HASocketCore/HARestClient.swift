// Minimal HTTP/1.1 client over a raw POSIX socket, for HA's REST API - used
// for one-shot state fetches and service calls. State streaming goes over
// the websocket in HAWebSocketClient.
import Darwin
import Foundation

struct HARestClient {
    private let config: HAConfig

    init(config: HAConfig) {
        self.config = config
    }

    func request(_ method: String, _ path: String, body: [String: Any]? = nil) throws -> (status: Int, data: Data) {
        guard let base = URL(string: config.baseURL), let host = base.host else {
            throw WSError(message: "invalid base_url: \(config.baseURL)")
        }
        guard base.scheme != "https" else {
            throw WSError(message: "https isn't supported by this client yet")
        }
        let port = UInt16(base.port ?? 80)

        let fd = try posixConnect(host: host, port: port)
        defer { close(fd) }

        var bodyData = Data()
        if let body = body {
            bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        }
        var req = "\(method) \(base.path + path) HTTP/1.1\r\n"
        req += "Host: \(host)\r\n"
        req += "Authorization: Bearer \(config.token)\r\n"
        req += "Content-Type: application/json\r\n"
        req += "Content-Length: \(bodyData.count)\r\n"
        req += "Connection: close\r\n\r\n"

        var reqBytes = Array(req.utf8)
        reqBytes += Array(bodyData)
        let sent = reqBytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        guard sent == reqBytes.count else { throw WSError(message: "failed writing HTTP request") }

        var header: [UInt8] = []
        while header.count < 4 || header.suffix(4) != [13, 10, 13, 10] {
            header += try readExact(fd, 1)
            if header.count > 65536 { throw WSError(message: "response headers too large") }
        }
        let headerStr = String(bytes: header, encoding: .utf8) ?? ""
        let lines = headerStr.components(separatedBy: "\r\n")

        let statusParts = (lines.first ?? "").split(separator: " ")
        let status = statusParts.count > 1 ? (Int(statusParts[1]) ?? 0) : 0

        var contentLength = 0
        for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
            let value = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "0"
            contentLength = Int(value) ?? 0
        }

        let bodyBytes = contentLength > 0 ? try readExact(fd, contentLength) : []
        return (status, Data(bodyBytes))
    }
}
