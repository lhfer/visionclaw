import Foundation
import Network
import Combine
import os

private let logger = Logger(subsystem: "com.shrimpxr.app", category: "Network")

/// Discovers Mac Mini via Bonjour, connects via WebSocket, relays to OpenClaw
@MainActor
final class NetworkManager: ObservableObject {

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var openclawReachable: Bool = false

    /// Callbacks
    var onStateUpdate: ((OpenClawStatus) -> Void)?
    var onTaskResult: ((TaskResult) -> Void)?
    var onSendError: ((String) -> Void)?
    var onReconnectProgress: ((_ attempt: Int, _ total: Int) -> Void)?
    var onReconnectFailed: (() -> Void)?

    // MARK: - Private
    private var browser: NWBrowser?
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var resolvedHost: String?
    private var resolvedPort: Int?
    private let serviceType = "_shrimpxr._tcp"
    private let serviceDomain = "local."
    private var reconnectTask: Task<Void, Never>?
    private var isReconnecting = false
    private let maxReconnectAttempts = 5

    // MARK: - Discovery

    func startDiscovery() {
        connectionStatus = .discovering
        logger.info("Starting Bonjour discovery...")

        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: serviceType, domain: serviceDomain), using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    logger.info("Bonjour browser ready")
                case .failed(let error):
                    logger.error("Bonjour browser failed: \(error)")
                    self?.connectionStatus = .disconnected
                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                if let result = results.first {
                    self?.resolveAndConnect(result: result)
                }
            }
        }

        browser.start(queue: .main)
        self.browser = browser

        // Fallback: try direct connection after timeout
        Task {
            try? await Task.sleep(for: .seconds(3))
            if connectionStatus == .discovering || connectionStatus == .disconnected {
                logger.info("Bonjour timeout, trying direct connection to Mac Mini")
                connect(to: "192.168.50.61", port: 8765)
            }
        }
    }

    private func resolveAndConnect(result: NWBrowser.Result) {
        let endpoint = result.endpoint
        if case .service(let name, _, _, _) = endpoint {
            logger.info("Found service: \(name), using direct IP")
            connect(to: "192.168.50.61", port: 8765)
        }
    }

    // MARK: - WebSocket Connection

    func connect(to host: String, port: Int) {
        let urlString = "ws://\(host):\(port)"
        guard let url = URL(string: urlString) else { return }

        connectionStatus = .connecting
        resolvedHost = host
        resolvedPort = port

        logger.info("Connecting to \(urlString)...")

        urlSession = URLSession(configuration: .default)
        webSocket = urlSession?.webSocketTask(with: url)
        webSocket?.resume()

        sendHandshake()
        receiveLoop()
    }

    /// Send a handshake to verify connection is alive
    private func sendHandshake() {
        let handshake: [String: Any] = [
            "type": "ping",
            "client": "ShrimpXR"
        ]
        sendJSON(handshake)

        // Handshake timeout = connection failed (not "connected anyway")
        Task {
            try? await Task.sleep(for: .seconds(3))
            if connectionStatus == .connecting {
                logger.warning("Handshake timeout — connection failed")
                connectionStatus = .disconnected
                scheduleReconnect()
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        isReconnecting = false
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        browser?.cancel()
        browser = nil
        connectionStatus = .disconnected
        openclawReachable = false
        logger.info("Disconnected")
    }

    // MARK: - Auto Reconnect (limited attempts with user feedback)

    private func scheduleReconnect() {
        guard !isReconnecting, let host = resolvedHost, let port = resolvedPort else { return }
        isReconnecting = true
        connectionStatus = .disconnected
        openclawReachable = false

        reconnectTask = Task {
            for attempt in 1...maxReconnectAttempts {
                onReconnectProgress?(attempt, maxReconnectAttempts)
                logger.info("Reconnect attempt \(attempt)/\(·self.maxReconnectAttempts)...")

                let delay = min(Double(attempt) * 2, 10)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }

                connect(to: host, port: port)
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }

                if connectionStatus.isConnected {
                    logger.info("Reconnected!")
                    isReconnecting = false
                    return
                }
            }
            logger.error("Reconnect failed after \(self.maxReconnectAttempts) attempts")
            isReconnecting = false
            onReconnectFailed?()
        }
    }

    // MARK: - Send

    func sendTask(_ text: String) {
        let message: [String: Any] = [
            "type": "task",
            "content": text,
            "timestamp": ISO8601DateFormatter().string(from: Date())
        ]
        sendJSON(message)
    }

    func checkOpenClawStatus() {
        let check: [String: Any] = ["type": "status_check"]
        sendJSON(check)
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let string = String(data: data, encoding: .utf8) else { return }
        webSocket?.send(.string(string)) { [weak self] error in
            if let error {
                logger.error("Send error: \(error.localizedDescription)")
                Task { @MainActor in
                    self?.onSendError?(error.localizedDescription)
                    self?.handleDisconnect()
                }
            }
        }
    }

    // MARK: - Receive

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        self?.handleMessage(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self?.handleMessage(text)
                        }
                    @unknown default:
                        break
                    }
                    self?.receiveLoop()

                case .failure(let error):
                    logger.error("Receive error: \(error.localizedDescription)")
                    self?.handleDisconnect()
                }
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else { return }

        switch type {
        case "pong":
            logger.info("Connection verified (pong received)")
            connectionStatus = .connected(hostName: resolvedHost ?? "unknown")
            openclawReachable = true
            isReconnecting = false
            startKeepAlive()

        case "status":
            if let statusStr = json["status"] as? String,
               let status = OpenClawStatus(rawValue: statusStr) {
                openclawReachable = true
                onStateUpdate?(status)
            }

        case "result":
            if let resultData = try? JSONSerialization.data(withJSONObject: json),
               let result = try? JSONDecoder().decode(TaskResult.self, from: resultData) {
                onTaskResult?(result)
            }

        case "status_check_result":
            openclawReachable = json["openclaw_available"] as? Bool ?? false
            logger.info("OpenClaw reachable: \(self.openclawReachable)")

        default:
            logger.debug("Unknown message type: \(type)")
        }
    }

    // MARK: - Keepalive

    private func startKeepAlive() {
        sendPing()
    }

    private func sendPing() {
        webSocket?.sendPing { [weak self] error in
            if let error {
                logger.warning("Ping failed: \(error.localizedDescription)")
                Task { @MainActor in
                    self?.handleDisconnect()
                }
                return
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                self?.sendPing()
            }
        }
    }

    private func handleDisconnect() {
        guard connectionStatus.isConnected || connectionStatus == .connecting else { return }
        connectionStatus = .disconnected
        openclawReachable = false
        logger.warning("Connection lost, scheduling reconnect...")
        scheduleReconnect()
    }
}
