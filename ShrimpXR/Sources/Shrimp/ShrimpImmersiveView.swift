import SwiftUI
import RealityKit
import ARKit
import os

private let logger = Logger(subsystem: "com.shrimpxr.app", category: "ImmersiveView")

struct ShrimpImmersiveView: View {
    @EnvironmentObject var session: SessionManager
    @State private var shrimp: ShrimpEntity?
    @State private var bubble: ShrimpBubble3D?
    @State private var baseScale: Float = 0.002
    @State private var dragStartTransform: Transform?
    @State private var rotationStartOrientation: simd_quatf?
    @State private var isDragging: Bool = false

    var body: some View {
        RealityView { content in
            logger.info("RealityView loading...")
            session.isShrimpLoading = true

            do {
                let entity = try await ShrimpEntity.load()
                entity.placeAtFixedPosition(in: content)
                self.shrimp = entity

                let bubble3D = ShrimpBubble3D()
                entity.model.addChild(bubble3D.root)
                self.bubble = bubble3D

                session.isShrimpLoading = false
                session.showWelcome()
                logger.info("ShrimpBoy ready")
            } catch {
                logger.error("Load failed: \(error.localizedDescription)")
                session.isShrimpLoading = false
                session.statusMessage = "加载失败: \(error.localizedDescription)"
            }
        }
        // Tap = toggle listening (start / stop+send)
        .gesture(tapGesture)
        // Long press = force upright
        .gesture(longPressGesture)
        // Drag
        .simultaneousGesture(dragGesture)
        // Scale
        .simultaneousGesture(scaleGesture)
        // Rotate
        .simultaneousGesture(rotateGesture)
        // State sync
        .onChange(of: session.shrimpState) { _, newState in
            shrimp?.controller.transition(to: newState)
            bubble?.handleState(newState, response: session.lastResponse)
        }
        .onChange(of: session.lastResponse) { _, newResponse in
            if !newResponse.isEmpty {
                bubble?.showText(newResponse)
            }
        }
        .onChange(of: session.statusMessage) { _, message in
            if message.isEmpty {
                if session.shrimpState == .idle { bubble?.hide() }
            } else {
                bubble?.showStatus(message, icon: "⚠️", border: .normal)
            }
        }
        .onChange(of: session.speech.currentTranscript) { _, transcript in
            if session.shrimpState == .listening && !transcript.isEmpty {
                bubble?.showListeningTranscript(transcript)
            }
        }
        .onChange(of: session.relocateRequestId) { _, _ in
            shrimp?.relocateAndStandUp()
        }
    }

    // MARK: - Tap: toggle listening

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .targetedToAnyEntity()
            .onEnded { _ in
                guard !isDragging else { return }
                logger.info("Tap: \(session.shrimpState.rawValue)")

                switch session.shrimpState {
                case .idle, .attentive:
                    // Start listening
                    if session.connectionStatus.isConnected {
                        session.startListening()
                    } else {
                        session.showNotConnectedHint()
                    }
                case .listening:
                    // Stop listening + send transcript
                    session.stopAndSendListening()
                case .sleeping:
                    session.wakeUp()
                case .working, .success, .thinking, .longTask:
                    session.interruptReply()
                default:
                    break
                }
            }
    }

    // MARK: - Long Press = Stand Upright

    private var longPressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .targetedToAnyEntity()
            .onEnded { _ in
                shrimp?.forceUpright()
                bubble?.showStatus("已站直！", icon: "✅", border: .normal)
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    bubble?.hide()
                }
            }
    }

    // MARK: - Drag

    private var dragGesture: some Gesture {
        DragGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard let root = shrimp?.root else { return }
                if dragStartTransform == nil {
                    dragStartTransform = root.transform
                    isDragging = true
                    if session.shrimpState == .idle {
                        shrimp?.controller.playWalkingOverride()
                    }
                }
                guard let startTransform = dragStartTransform,
                      let parent = root.parent else { return }
                let translation = value.convert(value.translation3D, from: .local, to: parent)
                root.position = startTransform.translation + SIMD3<Float>(
                    Float(translation.x), Float(translation.y), Float(translation.z)
                )
            }
            .onEnded { _ in
                dragStartTransform = nil
                isDragging = false
                shrimp?.controller.stopWalkingOverride()
            }
    }

    // MARK: - Scale (on model, not root)

    private var scaleGesture: some Gesture {
        MagnifyGesture()
            .targetedToAnyEntity()
            .onChanged { value in
                guard let model = shrimp?.model else { return }
                let rawScale = baseScale * Float(value.magnification)
                let clamped = max(Float(0.001), min(Float(0.006), rawScale))
                model.scale = SIMD3<Float>(repeating: clamped)
            }
            .onEnded { value in
                let rawScale = baseScale * Float(value.magnification)
                baseScale = max(Float(0.001), min(Float(0.006), rawScale))
            }
    }

    // MARK: - Rotate (Y only, on root)

    private var rotateGesture: some Gesture {
        RotateGesture3D(constrainedToAxis: .y)
            .targetedToAnyEntity()
            .onChanged { value in
                guard let root = shrimp?.root else { return }
                if rotationStartOrientation == nil {
                    rotationStartOrientation = root.orientation
                }
                guard let startOrientation = rotationStartOrientation else { return }
                let angle = Float(value.rotation.angle.radians)
                let axis = value.rotation.axis
                if abs(axis.y) > 0.5 {
                    let yRot = simd_quatf(angle: axis.y > 0 ? angle : -angle, axis: [0, 1, 0])
                    root.orientation = startOrientation * yRot
                }
            }
            .onEnded { _ in
                rotationStartOrientation = nil
                shrimp?.forceUpright()
            }
    }
}
