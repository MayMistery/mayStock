import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One OKX channel subscription.
public struct OKXChannelArg: Hashable, Sendable, Codable {
    public let channel: String
    public let instId: String
    public init(channel: String, instId: String) {
        self.channel = channel
        self.instId = instId
    }
}

public enum OKXConnectionState: String, Sendable {
    case idle, connecting, connected, degraded
}

/// Events surfaced to the owner of a client.
public enum OKXWSEvent: Sendable {
    case state(OKXConnectionState)
    case message(OKXWSMessage)
}

/// Reconnecting OKX v5 WebSocket client (actor).
///
/// Protocol rules implemented here, per OKX docs:
/// - The *client* must send the text `"ping"` when idle for <30s; the server
///   answers `"pong"`. Connections silent for >30s are dropped server-side.
/// - Subscriptions are replayed automatically after every reconnect.
public actor OKXWSClient {
    public let url: URL
    public private(set) var state: OKXConnectionState = .idle

    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var subscriptions: Set<OKXChannelArg> = []
    private var handler: (@Sendable (OKXWSEvent) -> Void)?
    private var lastMessageAt = Date.distantPast
    private var lastPingAt = Date.distantPast
    private var reconnectAttempt = 0
    private var generation = 0 // invalidates stale receive loops

    public init(url: URL) {
        self.url = url
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    /// Register the single event handler (called off-actor; hop as needed).
    public func setHandler(_ handler: @escaping @Sendable (OKXWSEvent) -> Void) {
        self.handler = handler
    }

    // MARK: Lifecycle

    public func connect() {
        guard state == .idle || state == .degraded else { return }
        openSocket()
    }

    public func disconnect() {
        generation += 1
        keepaliveTask?.cancel()
        keepaliveTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setState(.idle)
    }

    public func subscribe(_ args: [OKXChannelArg]) {
        let fresh = args.filter { !subscriptions.contains($0) }
        subscriptions.formUnion(args)
        guard !fresh.isEmpty else { return }
        if state == .connected || state == .connecting {
            sendOp("subscribe", args: fresh)
        } else {
            connect()
        }
    }

    public func unsubscribe(_ args: [OKXChannelArg]) {
        let present = args.filter { subscriptions.contains($0) }
        subscriptions.subtract(args)
        guard !present.isEmpty, task != nil else { return }
        sendOp("unsubscribe", args: present)
    }

    // MARK: Internals

    private func setState(_ new: OKXConnectionState) {
        guard new != state else { return }
        state = new
        handler?(.state(new))
    }

    private func openSocket() {
        generation += 1
        let gen = generation
        setState(.connecting)

        let socket = session.webSocketTask(with: url)
        task = socket
        socket.resume()

        lastMessageAt = Date()
        lastPingAt = .distantPast

        if !subscriptions.isEmpty {
            sendOp("subscribe", args: Array(subscriptions))
        }

        receiveTask = Task { [weak self] in
            await self?.receiveLoop(socket: socket, generation: gen)
        }
        startKeepalive(generation: gen)
    }

    private func receiveLoop(socket: URLSessionWebSocketTask, generation gen: Int) async {
        while !Task.isCancelled {
            do {
                let message = try await receiveOne(socket)
                guard gen == generation else { return }
                noteTraffic()
                let text: String
                switch message {
                case .string(let s): text = s
                case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                @unknown default: continue
                }
                guard let decoded = try? OKXWireDecoder.decode(text) else { continue }
                switch decoded {
                case .pong, .ignored:
                    continue
                case .subscribed:
                    setState(.connected)
                    handler?(.message(decoded))
                default:
                    setState(.connected)
                    handler?(.message(decoded))
                }
            } catch {
                guard gen == generation else { return }
                scheduleReconnect()
                return
            }
        }
    }

    private nonisolated func receiveOne(
        _ socket: URLSessionWebSocketTask
    ) async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { continuation in
            socket.receive { result in
                continuation.resume(with: result)
            }
        }
    }

    private func noteTraffic() {
        lastMessageAt = Date()
        reconnectAttempt = 0
    }

    private func startKeepalive(generation gen: Int) {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self else { return }
                let alive = await self.keepaliveTick(generation: gen)
                if !alive { return }
            }
        }
    }

    /// Returns false when this keepalive loop is stale and should end.
    private func keepaliveTick(generation gen: Int) -> Bool {
        guard gen == generation, let task else { return false }
        let idle = Date().timeIntervalSince(lastMessageAt)
        if idle > 30 {
            scheduleReconnect()
            return false
        }
        if idle > 15, Date().timeIntervalSince(lastPingAt) > 15 {
            lastPingAt = Date()
            task.send(.string("ping")) { _ in }
        }
        return true
    }

    private func sendOp(_ op: String, args: [OKXChannelArg]) {
        struct Frame: Encodable {
            let op: String
            let args: [OKXChannelArg]
        }
        guard let task,
              let data = try? JSONEncoder().encode(Frame(op: op, args: args)),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func scheduleReconnect() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        task?.cancel(with: .abnormalClosure, reason: nil)
        task = nil
        setState(.degraded)

        reconnectAttempt = min(reconnectAttempt + 1, 8)
        let base = min(30.0, 0.5 * pow(2.0, Double(reconnectAttempt)))
        let jitter = Double.random(in: 0...(base * 0.3))
        let delay = base + jitter

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.reconnectIfNeeded()
        }
    }

    private func reconnectIfNeeded() {
        guard state == .degraded else { return }
        openSocket()
    }
}
