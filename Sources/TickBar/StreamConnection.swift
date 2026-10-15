import Foundation

/// One Binance WebSocket connection with dynamic SUBSCRIBE/UNSUBSCRIBE,
/// a heartbeat stream for liveness, and reconnect with backoff.
@MainActor
final class StreamConnection {
    let url: URL
    let heartbeat: String
    var onEvent: ([String: Any]) -> Void = { _ in }
    var onReconnect: () -> Void = {}

    private(set) var lastMessage: Date?
    private(set) var connectedAt: Date?
    private var task: URLSessionWebSocketTask?
    private var streams: Set<String> = []
    private var generation = 0
    private var backoff: TimeInterval = 1
    private var nextID = 1
    private let session = URLSession(configuration: .default)

    init(url: String, heartbeat: String) {
        self.url = URL(string: url)!
        self.heartbeat = heartbeat
    }

    func setStreams(_ new: Set<String>) {
        let wanted = new.union([heartbeat])
        let add = wanted.subtracting(streams)
        let remove = streams.subtracting(wanted)
        streams = wanted
        guard task != nil else { return }
        if !add.isEmpty { send("SUBSCRIBE", Array(add)) }
        if !remove.isEmpty { send("UNSUBSCRIBE", Array(remove)) }
    }

    func connect() {
        generation += 1
        let gen = generation
        task?.cancel(with: .goingAway, reason: nil)
        let t = session.webSocketTask(with: url)
        t.maximumMessageSize = 4 << 20
        task = t
        connectedAt = Date()
        lastMessage = nil
        if streams.isEmpty { streams = [heartbeat] }
        t.resume()
        // Binance caps a SUBSCRIBE at 200 streams per message.
        let all = Array(streams)
        stride(from: 0, to: all.count, by: 200).forEach { send("SUBSCRIBE", Array(all[$0..<min($0 + 200, all.count)])) }
        receive(gen)
    }

    /// Forces a fresh connection (used by the stale watchdog and on wake from sleep).
    func reconnect() {
        connect()
        onReconnect()
    }

    private func send(_ method: String, _ params: [String]) {
        nextID += 1
        let body: [String: Any] = ["method": method, "params": params, "id": nextID]
        guard let data = try? JSONSerialization.data(withJSONObject: body),
              let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    private func receive(_ gen: Int) {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let msg):
                    self.backoff = 1
                    self.lastMessage = Date()
                    let data: Data?
                    switch msg {
                    case .string(let s): data = s.data(using: .utf8)
                    case .data(let d): data = d
                    @unknown default: data = nil
                    }
                    if let data, let obj = try? JSONSerialization.jsonObject(with: data) {
                        if let e = obj as? [String: Any] {
                            if let inner = e["data"] as? [String: Any] { self.onEvent(inner) } else { self.onEvent(e) }
                        } else if let arr = obj as? [[String: Any]] {
                            arr.forEach(self.onEvent)
                        }
                    }
                    self.receive(gen)
                case .failure:
                    let delay = self.backoff
                    self.backoff = min(self.backoff * 2, 30)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, gen == self.generation else { return }
                        self.reconnect()
                    }
                }
            }
        }
    }
}
