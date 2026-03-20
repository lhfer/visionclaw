import RealityKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.shrimpxr.app", category: "Bubble3D")

/// Speech bubble using ViewAttachmentComponent (visionOS 26+)
@MainActor
final class ShrimpBubble3D {

    let root: Entity

    @Observable
    final class BubbleState {
        var text: String = ""
        var statusText: String = ""
        var isVisible: Bool = false
        var isTyping: Bool = false
        var icon: String = ""
        var borderStyle: BubbleBorder = .normal
        var transcriptText: String = ""
    }

    enum BubbleBorder {
        case normal
        case pulsing
        case sparkling
        case error
    }

    let state = BubbleState()
    private var typewriterTimer: Timer?
    private var hideTimer: Timer?
    private var currentFullText: String = ""
    private var displayedCount: Int = 0

    init() {
        root = Entity()
        root.name = "Bubble"

        // Position/scale managed by BubblePositionComponent in ShrimpAnimationSystem
        root.position = .zero
        root.scale = .one

        root.components.set(BillboardComponent())
        root.components.set(BubblePositionComponent())

        let attachment = ViewAttachmentComponent(rootView:
            BubbleSwiftUIView(state: state)
        )
        root.components.set(attachment)

        logger.info("Bubble3D initialized")
    }

    // MARK: - API

    func showText(_ text: String) {
        guard !text.isEmpty else { return }
        logger.info("showText: \(text.prefix(60))...")
        hideTimer?.invalidate()
        typewriterTimer?.invalidate()
        currentFullText = text
        displayedCount = 0
        state.statusText = ""
        state.transcriptText = ""
        state.icon = ""
        state.borderStyle = .normal
        state.isTyping = true
        state.isVisible = true
        startTypewriter()
    }

    func showStatus(_ text: String, icon: String = "", border: BubbleBorder = .normal) {
        hideTimer?.invalidate()
        typewriterTimer?.invalidate()
        typewriterTimer = nil
        currentFullText = ""
        state.text = ""
        state.transcriptText = ""
        state.statusText = text
        state.icon = icon
        state.borderStyle = border
        state.isTyping = false
        state.isVisible = true
    }

    func showListeningTranscript(_ transcript: String) {
        state.transcriptText = transcript
    }

    func hide() {
        typewriterTimer?.invalidate()
        typewriterTimer = nil
        hideTimer?.invalidate()
        hideTimer = nil
        state.isVisible = false
        state.transcriptText = ""
        state.icon = ""
        state.borderStyle = .normal
    }

    // MARK: - Typewriter (adaptive speed for Chinese/English/punctuation)

    private func startTypewriter() {
        let chars = Array(currentFullText)
        let total = chars.count
        displayedCount = 0

        func scheduleNext() {
            guard displayedCount < total else {
                typewriterTimer = nil
                state.isTyping = false
                // Chinese reading: ~3 chars/sec → 0.35s per char
                let readTime = max(20.0, Double(total) * 0.35)
                hideTimer = Timer.scheduledTimer(withTimeInterval: readTime, repeats: false) { [weak self] _ in
                    Task { @MainActor in self?.hide() }
                }
                return
            }

            let char = chars[displayedCount]
            let delay: TimeInterval
            if char.isPunctuation || char == "，" || char == "。" || char == "！" || char == "？" {
                delay = 0.08  // Pause on punctuation
            } else if char.isASCII {
                delay = 0.025  // Fast for English/numbers
            } else {
                delay = 0.05   // Medium for Chinese characters
            }

            typewriterTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.displayedCount += 1
                    self.state.text = String(chars.prefix(self.displayedCount))
                    scheduleNext()
                }
            }
        }

        scheduleNext()
    }

    // MARK: - State

    func handleState(_ shrimpState: ShrimpState, response: String) {
        switch shrimpState {
        case .listening:
            showStatus("我在听...", icon: "🎤", border: .pulsing)
        case .sendingCommand:
            showStatus("发送中...", icon: "✨", border: .sparkling)
        case .thinking:
            showStatus("思考中 ···", icon: "💭", border: .normal)
        case .working, .longTask:
            showStatus("回复中 ···", icon: "⚙️", border: .normal)
        case .waitingResult:
            showStatus("等待中 ···", icon: "⏳", border: .normal)
        case .success:
            state.icon = "✓"
            state.borderStyle = .normal
            if !response.isEmpty { showText(response) }
        case .error:
            state.borderStyle = .error
            state.icon = "⚠️"
            showText(response.isEmpty ? "出错了!" : response)
        case .idle:
            if typewriterTimer == nil && hideTimer == nil { hide() }
        default:
            break
        }
    }
}

// MARK: - SwiftUI Bubble View

struct BubbleSwiftUIView: View {
    @Bindable var state: ShrimpBubble3D.BubbleState

    var body: some View {
        Group {
            if state.isVisible {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        if !state.statusText.isEmpty {
                            HStack(spacing: 6) {
                                if !state.icon.isEmpty {
                                    Text(state.icon)
                                        .font(.system(size: 14))
                                } else {
                                    TypingIndicator()
                                }
                                Text(state.statusText)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !state.transcriptText.isEmpty {
                            Text(state.transcriptText)
                                .font(.system(size: 14, weight: .regular, design: .rounded))
                                .foregroundStyle(.primary.opacity(0.7))
                                .italic()
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if !state.text.isEmpty {
                            ScrollView {
                                Text(state.text)
                                    .font(.system(size: 15, weight: .regular, design: .rounded))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .frame(maxHeight: 300)
                        }

                        if state.isTyping {
                            TypingIndicator()
                                .padding(.top, 2)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(width: 420, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 20)
                                    .strokeBorder(borderColor, lineWidth: borderWidth)
                                    .opacity(state.borderStyle == .normal ? 0 : 1)
                            )
                    )
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 2)

                    // Tail pointing toward character
                    BubbleTail()
                        .fill(.ultraThinMaterial)
                        .frame(width: 16, height: 10)
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: state.isVisible)
    }

    private var borderColor: Color {
        switch state.borderStyle {
        case .normal:    return .clear
        case .pulsing:   return .blue
        case .sparkling: return .yellow
        case .error:     return .red
        }
    }

    private var borderWidth: CGFloat {
        switch state.borderStyle {
        case .normal:    return 0
        case .pulsing:   return 2
        case .sparkling: return 2
        case .error:     return 2.5
        }
    }
}

struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX - rect.width / 2, y: 0))
            p.addLine(to: CGPoint(x: rect.midX + rect.width / 2, y: 0))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.height))
            p.closeSubpath()
        }
    }
}

struct TypingIndicator: View {
    @State private var phase: Int = 0
    @State private var animTimer: Timer?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(.primary.opacity(phase == i ? 0.8 : 0.2))
                    .frame(width: 5, height: 5)
            }
        }
        .onAppear {
            animTimer?.invalidate()
            animTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                Task { @MainActor in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        phase = (phase + 1) % 3
                    }
                }
            }
        }
        .onDisappear {
            animTimer?.invalidate()
            animTimer = nil
        }
    }
}
