// Raw-socket WebSocket client for Home Assistant's websocket API. Holds a
// persistent, auto-reconnecting connection and pushes state-change events
// for a fixed set of entities. Ported near-verbatim from HomeBar's proven
// HAWebSocketClient (itself ported from hasocket's original `__watch` daemon).
import Darwin
import Foundation

public enum HAConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
}

final class HAWebSocketClient: @unchecked Sendable {
    private let config: HAConfig
    private let entities: [String]

    /// Called on a private background queue - hop off it yourself if needed.
    var onStateChange: (@Sendable (HAConnectionState) -> Void)?
    var onEntityUpdate: (@Sendable (_ entityID: String, _ state: [String: Any]) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    private var thread: Thread?
    private let stopFlag = NSLock()
    private var stopped = false
    private var activeFD: Int32 = -1

    init(config: HAConfig, entities: [String]) {
        self.config = config
        self.entities = entities
    }

    func start() {
        guard thread == nil else { return }
        stopped = false
        let t = Thread { [weak self] in self?.run() }
        t.name = "hasocket.HAWebSocketClient"
        t.stackSize = 512 * 1024
        thread = t
        t.start()
    }

    /// Sets the stop flag *and* closes the live socket (if any) so a blocked
    /// `read()` wakes up immediately instead of sitting on its ~25s timeout.
    func stop() {
        stopFlag.lock()
        stopped = true
        let fd = activeFD
        stopFlag.unlock()
        if fd >= 0 { close(fd) }
    }

    private func isStopped() -> Bool {
        stopFlag.lock()
        defer { stopFlag.unlock() }
        return stopped
    }

    private func log(_ s: String) { onLog?(s) }

    private func run() {
        signal(SIGPIPE, SIG_IGN)

        guard let base = URL(string: config.baseURL), let host = base.host else {
            log("invalid base_url: \(config.baseURL)")
            return
        }
        guard base.scheme != "https" else {
            log("wss (TLS) isn't supported yet")
            return
        }
        let port = UInt16(base.port ?? 80)
        let path = base.path + "/api/websocket"

        var reconnectDelay: Double = 2
        while !isStopped() {
            runConnection(host: host, port: port, path: path)
            if isStopped() { break }
            log("disconnected, retrying in \(Int(reconnectDelay))s")
            Thread.sleep(forTimeInterval: reconnectDelay)
            reconnectDelay = min(reconnectDelay * 2, 60)
        }
        onStateChange?(.disconnected)
    }

    private func runConnection(host: String, port: UInt16, path: String) {
        onStateChange?(.connecting)
        log("connecting to \(host):\(port)\(path)")
        var fd: Int32 = -1
        do {
            fd = try posixConnect(host: host, port: port)
            try wsHandshake(fd: fd, host: host, path: path)
        } catch {
            log("connect failed: \(error)")
            if fd >= 0 { close(fd) }
            return
        }
        stopFlag.lock(); activeFD = fd; stopFlag.unlock()
        defer {
            close(fd)
            stopFlag.lock()
            if activeFD == fd { activeFD = -1 }
            stopFlag.unlock()
        }

        var msgId = 1
        var lastPing = Date().timeIntervalSince1970

        func send(_ obj: [String: Any]) throws {
            guard let data = try? JSONSerialization.data(withJSONObject: obj), let str = String(data: data, encoding: .utf8) else { return }
            try wsSendText(fd: fd, str)
        }

        while !isStopped() {
            let text: String?
            do {
                text = try wsReadMessage(fd: fd)
            } catch let e as WSError where e.message == "read timeout" {
                let now = Date().timeIntervalSince1970
                if now - lastPing > 20 {
                    lastPing = now
                    do { try send(["id": 999_999, "type": "ping"]) } catch { log("ping failed: \(error)"); return }
                }
                continue
            } catch {
                log("connection error: \(error)")
                return
            }
            guard let text = text, let data = text.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("connection closed by server")
                return
            }

            switch obj["type"] as? String {
            case "auth_required":
                do { try send(["type": "auth", "access_token": config.token]) } catch { log("auth send failed: \(error)"); return }
            case "auth_invalid":
                log("HA rejected the access token")
                return
            case "auth_ok":
                log("authenticated, subscribing to \(entities.count) entities")
                onStateChange?(.connected)
                do {
                    if !entities.isEmpty {
                        try send(["id": msgId, "type": "subscribe_trigger", "trigger": ["platform": "state", "entity_id": entities]])
                    }
                } catch { log("subscribe failed: \(error)"); return }
                msgId += 1
                lastPing = Date().timeIntervalSince1970
            case "event":
                if let event = obj["event"] as? [String: Any],
                   let variables = event["variables"] as? [String: Any],
                   let trigger = variables["trigger"] as? [String: Any],
                   let entityId = trigger["entity_id"] as? String,
                   let toState = trigger["to_state"] as? [String: Any] {
                    onEntityUpdate?(entityId, toState)
                }
            default:
                break
            }
        }
    }
}
