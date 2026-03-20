import Foundation
import Speech
import AVFoundation
import os

private let logger = Logger(subsystem: "com.shrimpxr.app", category: "Speech")

/// Simple speech manager — manual start/stop, no auto-detection.
/// User presses button to start, presses again to stop and send.
@MainActor
final class SpeechManager: ObservableObject {

    @Published var isRecognizing: Bool = false
    @Published var currentTranscript: String = ""

    enum ListeningError {
        case recognizerUnavailable
        case audioFormatInvalid
        case permissionDenied
        case engineStartFailed(Error)
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var onResultCallback: ((String) -> Void)?

    // MARK: - Authorization

    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
        return speechStatus == .authorized
    }

    // MARK: - Start Listening (manual — keeps going until stopAndFinalize is called)

    /// Starts listening — audio setup wrapped in Task to avoid blocking main thread.
    func startListening(onResult: @escaping (String) -> Void) {
        guard !isRecognizing else { return }
        self.onResultCallback = onResult
        isRecognizing = true
        currentTranscript = ""
        logger.info("[Listen] Starting...")

        // Use nonisolated helper to set up audio off main actor
        Task {
            let setup = await Self.setupAudio()
            guard let (engine, request, recognizer) = setup else {
                isRecognizing = false
                logger.warning("[Listen] Audio setup failed")
                return
            }

            self.audioEngine = engine
            self.recognitionRequest = request

            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.isRecognizing else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        if !text.isEmpty {
                            self.currentTranscript = text
                        }
                    }
                    if let error {
                        logger.error("[Listen] Error: \(error.localizedDescription)")
                    }
                }
            }
            logger.info("[Listen] Started (manual mode)")
        }
    }

    /// Sets up audio engine on a nonisolated context to avoid blocking MainActor.
    nonisolated static func setupAudio() async -> (AVAudioEngine, SFSpeechAudioBufferRecognitionRequest, SFSpeechRecognizer)? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else {
            return nil
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            return nil
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)

        guard format.sampleRate > 0 && format.channelCount > 0 else {
            return nil
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            return nil
        }

        return (engine, request, recognizer)
    }

    // MARK: - Stop and send transcript

    func stopAndFinalize() {
        guard isRecognizing else { return }
        let transcript = currentTranscript
        let callback = onResultCallback
        logger.info("[Listen] Manual stop. Transcript: '\(transcript)'")

        stopListening()

        if !transcript.isEmpty {
            callback?(transcript)
        }
    }

    func stopListening() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)

        audioEngine = nil
        recognitionRequest = nil
        recognitionTask = nil
        onResultCallback = nil
        isRecognizing = false

        // Release audio session
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        logger.info("[Listen] Stopped")
    }

    // MARK: - TTS

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.1
        utterance.volume = 0.9
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
