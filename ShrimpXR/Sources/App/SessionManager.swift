import SwiftUI
import Combine
import os

private let logger = Logger(subsystem: "com.shrimpxr.app", category: "Session")

@MainActor
final class SessionManager: ObservableObject {

    @Published var connectionStatus: ConnectionStatus = .disconnected
    @Published var shrimpState: ShrimpState = .idle
    @Published var lastResponse: String = ""
    @Published var isListening: Bool = false
    @Published var isImmersiveOpen: Bool = false
    @Published var isShrimpLoading: Bool = false
    @Published var relocateRequestId: Int = 0
    @Published var statusMessage: String = ""

    let network = NetworkManager()
    let speech = SpeechManager()

    private var cancellables = Set<AnyCancellable>()
    private var timeoutTask: Task<Void, Never>?
    private var inactivityTimer: Timer?
    private let sleepTimeout: TimeInterval = 120

    init() {
        isImmersiveOpen = false
        isShrimpLoading = false
        setupBindings()
    }

    private func setupBindings() {
        network.$connectionStatus
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectionStatus)

        network.onStateUpdate = { [weak self] state in
            Task { @MainActor in self?.handleOpenClawState(state) }
        }

        network.onTaskResult = { [weak self] result in
            Task { @MainActor in self?.handleTaskResult(result) }
        }

        network.onSendError = { [weak self] errorMsg in
            Task { @MainActor in self?.handleSendError(errorMsg) }
        }

        network.onReconnectProgress = { [weak self] attempt, total in
            Task { @MainActor in
                self?.statusMessage = "重连中 (\(attempt)/\(total))..."
            }
        }

        network.onReconnectFailed = { [weak self] in
            Task { @MainActor in
                self?.statusMessage = "连接断开，请手动重连"
            }
        }
    }

    // MARK: - Inactivity

    private func resetInactivityTimer() {
        guard !shrimpState.isActive else { return }
        inactivityTimer?.invalidate()
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: sleepTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.shrimpState == .idle else { return }
                self.shrimpState = .sleeping
            }
        }
    }

    // MARK: - Listening (Manual: tap to start, tap to stop+send)

    func startListening() {
        guard !isListening else { return }
        speech.stopSpeaking()
        logger.info("[Listen] Start")

        isListening = true
        shrimpState = .listening
        statusMessage = ""

        speech.startListening { [weak self] transcript in
            Task { @MainActor in self?.handleUserSpeech(transcript) }
        }
    }

    /// User presses "stop" — finalize transcript and send
    func stopAndSendListening() {
        guard isListening else { return }
        logger.info("[Listen] Stop+Send")
        isListening = false
        speech.stopAndFinalize()
        // handleUserSpeech will be called by the callback if transcript is non-empty
        // If empty, just go back to idle
        if shrimpState == .listening {
            // Will be changed by handleUserSpeech if transcript exists
            // Give it a moment, then check
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                if shrimpState == .listening {
                    shrimpState = .idle
                    resetInactivityTimer()
                }
            }
        }
    }

    /// User presses "cancel" — stop without sending
    func cancelListening() {
        logger.info("[Listen] Cancel")
        isListening = false
        speech.stopListening()
        if shrimpState == .listening {
            shrimpState = .idle
        }
        resetInactivityTimer()
    }

    // MARK: - Interrupt

    func interruptReply() {
        speech.stopSpeaking()
        timeoutTask?.cancel()
        timeoutTask = nil
        shrimpState = .idle
        lastResponse = ""
        statusMessage = ""
        resetInactivityTimer()
    }

    // MARK: - Wake Up

    func wakeUp() {
        shrimpState = .idle
        statusMessage = "我回来了！"
        resetInactivityTimer()
        Task {
            try? await Task.sleep(for: .seconds(3))
            if statusMessage == "我回来了！" { statusMessage = "" }
        }
    }

    func showWelcome() {
        statusMessage = "点我说话！"
        Task {
            try? await Task.sleep(for: .seconds(3))
            if statusMessage == "点我说话！" { statusMessage = "" }
        }
    }

    func relocateShrimp() {
        relocateRequestId += 1
    }

    func showNotConnectedHint() {
        statusMessage = "未连接，请先连接 Mac Mini"
        Task {
            try? await Task.sleep(for: .seconds(3))
            if statusMessage == "未连接，请先连接 Mac Mini" { statusMessage = "" }
        }
    }

    // MARK: - Send Message

    func sendTestMessage(_ text: String) {
        shrimpState = .sendingCommand
        statusMessage = ""

        timeoutTask?.cancel()
        timeoutTask = Task {
            network.sendTask(text)
            shrimpState = .waitingResult

            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            if [.waitingResult, .sendingCommand].contains(shrimpState) {
                statusMessage = "仍在处理中..."
            }

            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            if [.waitingResult, .working, .thinking].contains(shrimpState) {
                statusMessage = "等待时间较长..."
            }

            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            if [.waitingResult, .working, .thinking, .sendingCommand].contains(shrimpState) {
                shrimpState = .error
                lastResponse = "连接超时，请重试"
                statusMessage = ""
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if shrimpState == .error {
                    shrimpState = .idle
                    lastResponse = ""
                    resetInactivityTimer()
                }
            }
        }
    }

    // MARK: - Connection

    func connect() {
        shrimpState = .idle
        lastResponse = ""
        statusMessage = ""
        network.startDiscovery()
    }

    func disconnect() {
        timeoutTask?.cancel()
        timeoutTask = nil
        inactivityTimer?.invalidate()
        inactivityTimer = nil
        isListening = false
        speech.stopListening()
        speech.stopSpeaking()
        network.disconnect()
        shrimpState = .idle
        lastResponse = ""
        statusMessage = ""
    }

    // MARK: - Handlers

    private func handleUserSpeech(_ transcript: String) {
        guard !transcript.isEmpty else {
            logger.info("[Speech] Empty, ignoring")
            return
        }
        logger.info("[Speech] Sending: '\(transcript)'")
        isListening = false
        shrimpState = .sendingCommand
        statusMessage = ""

        timeoutTask?.cancel()
        timeoutTask = Task {
            network.sendTask(transcript)
            shrimpState = .waitingResult

            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            if [.waitingResult, .sendingCommand].contains(shrimpState) {
                statusMessage = "仍在处理中..."
            }

            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            if [.waitingResult, .working, .thinking].contains(shrimpState) {
                statusMessage = "等待时间较长..."
            }

            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            if [.waitingResult, .working, .thinking].contains(shrimpState) {
                shrimpState = .error
                lastResponse = "连接超时，请重试"
                statusMessage = ""
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                if shrimpState == .error {
                    shrimpState = .idle
                    lastResponse = ""
                    resetInactivityTimer()
                }
            }
        }
    }

    private func handleOpenClawState(_ state: OpenClawStatus) {
        logger.info("[OpenClaw] \(state.rawValue)")
        statusMessage = ""
        switch state {
        case .idle:       shrimpState = .idle; resetInactivityTimer()
        case .thinking:   shrimpState = .thinking
        case .working:    shrimpState = .working
        case .longTask:   shrimpState = .longTask
        case .waitingInput: shrimpState = .waitingInput
        case .error:      shrimpState = .error
        }
    }

    private func handleTaskResult(_ result: TaskResult) {
        logger.info("[Result] success=\(result.success) text='\(result.text.prefix(60))'")
        lastResponse = result.text
        shrimpState = result.success ? .success : .error
        statusMessage = ""
        speech.speak(result.text)

        timeoutTask?.cancel()
        timeoutTask = Task {
            let readTime = max(8.0, Double(result.text.count) * 0.35)
            try? await Task.sleep(for: .seconds(readTime))
            guard !Task.isCancelled else { return }
            if shrimpState == .success || shrimpState == .error {
                shrimpState = .idle
                resetInactivityTimer()
            }
        }
    }

    private func handleSendError(_ errorMsg: String) {
        logger.error("[Send] Error: \(errorMsg)")
        shrimpState = .error
        lastResponse = "发送失败，请重试"
        statusMessage = ""
        timeoutTask?.cancel()
        timeoutTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            if shrimpState == .error {
                shrimpState = .idle
                lastResponse = ""
                resetInactivityTimer()
            }
        }
    }
}
