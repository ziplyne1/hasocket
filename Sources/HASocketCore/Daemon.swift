// Non-UI runtime for `hasocket serve`: owns the HA websocket connection and
// the IPC socket that other `hasocket <command>` invocations talk to.
import Foundation

public final class Daemon: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: EntitySnapshot] = [:]
    private var restClient: HARestClient?

    private var wsClient: HAWebSocketClient?
    private var ipcServer: IPCServer?

    /// Called on a private background queue whenever the HA websocket
    /// connection state changes - hop off it yourself if needed.
    public var onStateChange: (@Sendable (HAConnectionState) -> Void)?
    /// Called on a private background queue with a timestamped log line.
    public var onLog: (@Sendable (String) -> Void)?

    public init() {}

    public func start(config: HAConfig, watchedEntityIDs: [String]) {
        let rest = HARestClient(config: config)
        restClient = rest

        // The websocket subscription only reports *changes* - prime with a
        // live REST fetch so entities that haven't changed since launch
        // aren't stuck showing nothing.
        for entityID in watchedEntityIDs {
            do {
                let (status, data) = try rest.request("GET", "/api/states/\(entityID)")
                guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    log("priming \(entityID) failed: HA returned \(status)")
                    continue
                }
                let attrs = (obj["attributes"] as? [String: Any]) ?? [:]
                let snap = EntitySnapshot(
                    entityID: entityID,
                    state: obj["state"] as? String ?? "unknown",
                    attributes: attrs.mapValues { JSONValue(any: $0) }
                )
                lock.lock(); snapshots[entityID] = snap; lock.unlock()
            } catch {
                log("priming \(entityID) failed: \(error)")
            }
        }

        let client = HAWebSocketClient(config: config, entities: watchedEntityIDs)
        client.onStateChange = { [weak self] state in
            switch state {
            case .connected: self?.log("connected to Home Assistant")
            case .connecting: self?.log("connecting...")
            case .disconnected: self?.log("disconnected")
            }
            self?.onStateChange?(state)
        }
        client.onLog = { [weak self] message in self?.log(message) }
        client.onEntityUpdate = { [weak self] entityID, state in
            guard let self else { return }
            let attrs = (state["attributes"] as? [String: Any]) ?? [:]
            let snap = EntitySnapshot(
                entityID: entityID,
                state: state["state"] as? String ?? "unknown",
                attributes: attrs.mapValues { JSONValue(any: $0) }
            )
            self.lock.lock(); self.snapshots[entityID] = snap; self.lock.unlock()
            self.log("\(entityID) -> \(snap.state)")
        }
        client.start()
        wsClient = client

        let server = IPCServer()
        server.onRequest = { [weak self] request in self?.handle(request) ?? .error("hasocket is shutting down") }
        do {
            try server.start()
            ipcServer = server
            log("listening on \(IPCSocket.path)")
        } catch {
            log("IPC server failed to start: \(error)")
        }
    }

    public func stop() {
        wsClient?.stop(); wsClient = nil
        ipcServer?.stop(); ipcServer = nil
        restClient = nil
    }

    private func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)"
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        onLog?(line)
    }

    private func handle(_ request: IPCRequest) -> IPCResponse {
        switch request {
        case .ping:
            return .pong

        case .list:
            lock.lock(); let all = Array(snapshots.values); lock.unlock()
            return .list(all)

        case .get(let entityID):
            // Only watched entities get pushed live updates over the
            // websocket, so a cached value for anything else (or even a
            // watched entity that just hasn't changed) can't be trusted as
            // current - always fetch live, falling back to cache only if HA
            // can't be reached right now.
            guard let restClient else {
                lock.lock(); let cached = snapshots[entityID]; lock.unlock()
                if let cached { return .entity(cached) }
                return .error("hasocket isn't connected to Home Assistant")
            }
            do {
                let (status, data) = try restClient.request("GET", "/api/states/\(entityID)")
                guard status == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return .error("Home Assistant returned \(status) for \(entityID)")
                }
                let attrs = (obj["attributes"] as? [String: Any]) ?? [:]
                let snap = EntitySnapshot(
                    entityID: entityID,
                    state: obj["state"] as? String ?? "unknown",
                    attributes: attrs.mapValues { JSONValue(any: $0) }
                )
                lock.lock(); snapshots[entityID] = snap; lock.unlock()
                return .entity(snap)
            } catch {
                lock.lock(); let cached = snapshots[entityID]; lock.unlock()
                if let cached { return .entity(cached) }
                return .error("\(error)")
            }

        case .call(let domain, let service, let entityID, let data):
            guard let restClient else { return .error("hasocket isn't connected to Home Assistant") }
            var body = data.asAnyDict
            if let entityID { body["entity_id"] = entityID }
            do {
                let (status, respData) = try restClient.request("POST", "/api/services/\(domain)/\(service)", body: body)
                guard (200...299).contains(status) else {
                    return .error("Home Assistant returned \(status): \(String(data: respData, encoding: .utf8) ?? "")")
                }
                return .ok
            } catch {
                return .error("\(error)")
            }
        }
    }
}
