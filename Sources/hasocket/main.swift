// hasocket - a standalone binary that holds a persistent websocket
// connection to Home Assistant and exposes it over a local Unix domain
// socket. Run `hasocket serve` in one terminal to hold the connection open;
// run `hasocket status/list/get/call` from any other terminal to query it.
import Darwin
import Foundation
import HASocketCore

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

let USAGE = """
usage:
  hasocket serve [--entities e1,e2,...]           hold the HA websocket connection open; run this first
  hasocket status                                 check hasocket is running & connected
  hasocket list                                   list all cached entity states
  hasocket get <entity_id>                        print state + attributes for one entity
  hasocket call <domain.service> [entity_id] [k=v...]  call a HA service

  add --json to `list`/`get` for machine-readable output

  config read from ~/.config/hasocket/config.json ({"base_url": ..., "token": ...})
  serve's default watch list read from ~/.config/hasocket/watch.json (a JSON array of entity IDs)
"""

func parseValue(_ s: String) -> JSONValue {
    switch s {
    case "true": return .bool(true)
    case "false": return .bool(false)
    default:
        if let d = Double(s) { return .double(d) }
        return .string(s)
    }
}

func printAttributes(_ attrs: [String: JSONValue]) {
    guard !attrs.isEmpty else { return }
    if let data = try? JSONSerialization.data(withJSONObject: attrs.asAnyDict, options: [.prettyPrinted, .sortedKeys]) {
        print(String(data: data, encoding: .utf8) ?? "")
    }
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { die(USAGE) }
args.removeFirst()

switch command {
case "serve":
    guard let config = HAConfigStore.load() else {
        die("no config at \(HAConfigStore.configPath.path) - expected {\"base_url\": ..., \"token\": ...}")
    }

    var entities = HAConfigStore.loadWatchedEntities()
    if let entitiesArg = args.first(where: { $0.hasPrefix("--entities=") }) {
        entities = entitiesArg.dropFirst("--entities=".count).split(separator: ",").map(String.init)
    }

    let daemon = Daemon()

    // Unlink is enough on the happy path (start() unlinks stale sockets too),
    // but tearing down cleanly on Ctrl+C/kill also removes the socket file
    // immediately instead of leaving a dead one lying around until the next
    // `serve` starts.
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    for source in [sigSource, sigTermSource] {
        source.setEventHandler {
            FileHandle.standardError.write("\nshutting down\n".data(using: .utf8)!)
            daemon.stop()
            exit(0)
        }
        source.resume()
    }

    print("hasocket serving \(entities.count) watched entities on \(IPCSocket.path) (Ctrl+C to stop)")
    daemon.start(config: config, watchedEntityIDs: entities)
    dispatchMain()

case "status":
    switch try? IPCClient.send(.ping) {
    case .pong: print("ok")
    case .some: die("unexpected response")
    case .none: die(IPCClientError.notRunning.description)
    }

case "list":
    let json = args.contains("--json")
    do {
        guard case .list(let entities) = try IPCClient.send(.list) else { die("unexpected response") }
        if json {
            let payload = entities.map { ["entity_id": $0.entityID, "state": $0.state] }
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                print(String(data: data, encoding: .utf8) ?? "[]")
            }
        } else {
            for e in entities.sorted(by: { $0.entityID < $1.entityID }) {
                print("\(e.entityID): \(e.state)")
            }
        }
    } catch let e as IPCClientError {
        die(e.description)
    }

case "get":
    guard let entity = args.first else { die("usage: hasocket get <entity_id>") }
    let json = args.contains("--json")
    do {
        guard case .entity(let snap) = try IPCClient.send(.get(entityID: entity)) else { die("no such entity: \(entity)") }
        if json {
            let payload: [String: Any] = ["entity_id": snap.entityID, "state": snap.state, "attributes": snap.attributes.asAnyDict]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                print(String(data: data, encoding: .utf8) ?? "{}")
            }
        } else {
            print("state: \(snap.state)")
            printAttributes(snap.attributes)
        }
    } catch let e as IPCClientError {
        die(e.description)
    }

case "call":
    guard let serviceArg = args.first else { die("usage: hasocket call <domain.service> [entity_id] [k=v...]") }
    let parts = serviceArg.split(separator: ".", maxSplits: 1)
    guard parts.count == 2 else { die("service must be domain.service, e.g. light.turn_on") }

    var entityID: String?
    var data: [String: JSONValue] = [:]
    for a in args.dropFirst() {
        if let eq = a.firstIndex(of: "=") {
            data[String(a[a.startIndex..<eq])] = parseValue(String(a[a.index(after: eq)...]))
        } else {
            entityID = a
        }
    }
    do {
        switch try IPCClient.send(.call(domain: String(parts[0]), service: String(parts[1]), entityID: entityID, data: data)) {
        case .ok: print("ok")
        case .error(let msg): die(msg)
        default: die("unexpected response")
        }
    } catch let e as IPCClientError {
        die(e.description)
    }

default:
    die(USAGE)
}
