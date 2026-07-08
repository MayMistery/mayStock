import Foundation
import Observation

@Observable
@MainActor
final class OKXWebSocketService {
    enum ConnectionState: Sendable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    private(set) var state: ConnectionState = .disconnected
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var retryCount = 0
    private let maxRetries = 5
    private var subscribedChannels: [[String: String]] = []

    var onMessage: (@MainActor @Sendable (OKXMessage) -> Void)?

    private let endpoint = URL(string: "wss://ws.okx.com:8443/ws/v5/public")!

    func connect() {
        guard case .disconnected = state else { return }
        state = .connecting
        retryCount = 0
        establishConnection()
    }

    func disconnect() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        state = .disconnected
    }

    func subscribe(channel: String, instId: String) {
        let arg = ["channel": channel, "instId": instId]
        subscribedChannels.append(arg)
        sendSubscription(args: [arg])
    }

    func unsubscribe(channel: String, instId: String) {
        let arg = ["channel": channel, "instId": instId]
        subscribedChannels.removeAll { $0 == arg }
        let msg: [String: Any] = ["op": "unsubscribe", "args": [arg]]
        sendJSON(msg)
    }

    private func establishConnection() {
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config)
        webSocketTask = session?.webSocketTask(with: endpoint)
        webSocketTask?.resume()
        state = .connected
        receiveMessage()

        if !subscribedChannels.isEmpty {
            sendSubscription(args: subscribedChannels)
        }
    }

    private func sendSubscription(args: [[String: String]]) {
        let msg: [String: Any] = ["op": "subscribe", "args": args]
        sendJSON(msg)
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        webSocketTask?.send(.string(text)) { _ in }
    }

    private func sendPong() {
        webSocketTask?.send(.string("pong")) { _ in }
    }

    private func receiveMessage() {
        guard let task = webSocketTask else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self.handleText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleText(text)
                        }
                    @unknown default:
                        break
                    }
                    self.receiveMessage()
                case .failure:
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleText(_ text: String) {
        guard let parsed = try? OKXMessageParser.parse(text) else { return }
        if case .ping = parsed {
            sendPong()
            return
        }
        onMessage?(parsed)
    }

    private func handleDisconnect() {
        state = .disconnected
        guard retryCount < maxRetries else {
            state = .error("Max retries exceeded")
            return
        }
        retryCount += 1
        let delay = pow(2.0, Double(retryCount))
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.establishConnection()
        }
    }
}
