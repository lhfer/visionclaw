import RealityKit
import Foundation
import os

private let logger = Logger(subsystem: "com.shrimpxr.app", category: "Anim")

/// Clip-based animation controller. Never freezes — always plays something.
/// Does NOT block on clip loading. Falls back to entity.availableAnimations if needed.
@MainActor
final class ShrimpAnimationController {

    private var clips: [String: AnimationResource] = [:]
    private var entity: Entity?
    private var modelEntity: ModelEntity?
    private var isDragging: Bool = false

    private(set) var currentState: ShrimpState = .idle
    private var chainTask: Task<Void, Never>?
    private var currentClipName: String = "(none)"

    private let idleVariants = ["Idle", "Breathing Idle", "Happy Idle"]
    private var idleTimer: Float = 0
    private var nextIdleSwitch: Float = 10

    var mouthOpenTarget: Float = 0

    // MARK: - Setup

    func setup(entity: Entity) {
        self.entity = entity
        logger.info("[Setup] Entity received")

        entity.visit { e in
            if let model = e as? ModelEntity, self.modelEntity == nil {
                self.modelEntity = model
            }
        }

        // Load embedded clips synchronously — these are available immediately
        for animation in entity.availableAnimations {
            let name = animation.name ?? animation.definition.name
            clips[name] = animation
        }
        logger.info("[Setup] Embedded clips: \(self.clips.count) [\(Array(self.clips.keys).sorted().joined(separator: ", "))]")

        // Play an initial animation immediately with whatever we have
        playAnyAvailable(reason: "initial pose")

        // Load external animation files in background
        Task {
            await loadAnimationFiles()
            logger.info("[Setup] All clips loaded: \(self.clips.count) [\(Array(self.clips.keys).sorted().joined(separator: ", "))]")

            // Now that we have all clips, play welcome
            playClip("Salute", loop: false, transition: 0.3, reason: "welcome greeting")
            chainTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                playRandomIdle(reason: "after welcome")
                resetIdleTimer()
            }
        }
    }

    private func loadAnimationFiles() async {
        let animNames = [
            "Breathing_Idle", "Casting_Spell", "Dancing", "Defeat",
            "Focus", "Happy_Idle", "Running", "Salute",
            "Sleeping", "Standing_Up", "Start_Walking", "Victory",
            "Walking", "Walking_Turn_180", "Working"
        ]

        for name in animNames {
            guard let url = Bundle.main.url(forResource: name, withExtension: "usdz", subdirectory: "animations") else {
                guard let url2 = Bundle.main.url(forResource: name, withExtension: "usdz") else {
                    logger.warning("[Load] File not found: \(name)")
                    continue
                }
                await loadClipsFrom(url: url2, expectedName: name)
                continue
            }
            await loadClipsFrom(url: url, expectedName: name)
        }
    }

    private func loadClipsFrom(url: URL, expectedName: String) async {
        do {
            let animEntity = try await Entity(contentsOf: url)
            for anim in animEntity.availableAnimations {
                let displayName = expectedName.replacingOccurrences(of: "_", with: " ")
                clips[displayName] = anim
            }
        } catch {
            logger.warning("[Load] Failed: \(expectedName) — \(error.localizedDescription)")
        }
    }

    // MARK: - State Transitions (NEVER blocks, NEVER freezes)

    func transition(to newState: ShrimpState) {
        guard newState != currentState else {
            logger.debug("[Transition] Already in \(newState.rawValue), skipping")
            return
        }

        let oldState = currentState
        currentState = newState

        if chainTask != nil {
            chainTask?.cancel()
            chainTask = nil
            logger.info("[Chain] Cancelled '\(self.currentClipName)' — state: \(oldState.rawValue) → \(newState.rawValue)")
        }

        logger.info("[State] \(oldState.rawValue) → \(newState.rawValue)")

        // Wake up ceremony
        if oldState == .sleeping && newState != .sleeping {
            playClip("Standing Up", loop: false, transition: 0.5, reason: "wake up")
            chainTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                playClip("Salute", loop: false, transition: 0.3, reason: "wake up greeting")
                try? await Task.sleep(for: .seconds(2.0))
                guard !Task.isCancelled, currentState == newState else { return }
                applyState(newState)
            }
            return
        }

        applyState(newState)
    }

    private func applyState(_ state: ShrimpState) {
        logger.info("[Apply] \(state.rawValue)")

        switch state {
        case .idle:
            if !isDragging { playRandomIdle(reason: "state→idle") }
            resetIdleTimer()

        case .attentive:
            playClip("Focus", loop: true, transition: 0.3, reason: "state→attentive")

        case .listening:
            playClip("Focus", loop: true, transition: 0.3, reason: "state→listening")

        case .sendingCommand:
            playClip("Casting Spell", loop: false, transition: 0.25, reason: "state→sendingCommand")
            chainTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled, currentState == .sendingCommand else { return }
                playClip("Breathing Idle", loop: true, transition: 0.3, reason: "CastingSpell done")
            }

        case .waitingResult:
            playClip("Breathing Idle", loop: true, transition: 0.4, reason: "state→waitingResult")

        case .thinking:
            playClip("Walking", loop: true, transition: 0.4, reason: "state→thinking")

        case .working:
            playClip("Working", loop: true, transition: 0.3, reason: "state→working")

        case .longTask:
            playClip("Working", loop: true, transition: 0.5, reason: "state→longTask")

        case .success:
            playClip("Victory", loop: false, transition: 0.2, reason: "state→success")
            chainTask = Task {
                try? await Task.sleep(for: .seconds(4.5))
                guard !Task.isCancelled, currentState == .success else { return }
                playClip("Dancing", loop: true, transition: 0.4, reason: "Victory→Dancing")
            }

        case .error:
            playClip("Defeat", loop: false, transition: 0.3, reason: "state→error")
            chainTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled, currentState == .error else { return }
                playClip("Breathing Idle", loop: true, transition: 0.4, reason: "Defeat done")
            }

        case .waitingInput:
            playClip("Salute", loop: false, transition: 0.3, reason: "state→waitingInput")
            chainTask = Task {
                try? await Task.sleep(for: .seconds(2.8))
                guard !Task.isCancelled, currentState == .waitingInput else { return }
                playClip("Breathing Idle", loop: true, transition: 0.4, reason: "Salute done")
            }

        case .sleeping:
            playClip("Sleeping", loop: true, transition: 0.8, reason: "state→sleeping")
        }
    }

    // MARK: - Drag Override

    func playWalkingOverride() {
        guard !isDragging else { return }
        isDragging = true
        chainTask?.cancel()
        playClip("Walking", loop: true, transition: 0.2, reason: "drag started")
    }

    func stopWalkingOverride() {
        guard isDragging else { return }
        isDragging = false
        applyState(currentState)
    }

    // MARK: - Per-Frame

    func updatePerFrame(deltaTime: Float) {
        // Note: Do NOT modify entity.position or entity.orientation here.
        // The animation system controls these. Fighting it causes freezing/jitter.
        // Character facing direction is controlled by the root wrapper entity via gestures.

        if currentState == .idle && !isDragging {
            idleTimer -= deltaTime
            if idleTimer <= 0 {
                if Float.random(in: 0...1) < 0.05 {
                    let easter = ["Salute", "Dancing"].randomElement()!
                    playClip(easter, loop: false, transition: 0.4, reason: "idle easter egg")
                    chainTask = Task {
                        try? await Task.sleep(for: .seconds(4))
                        guard !Task.isCancelled, currentState == .idle else { return }
                        playRandomIdle(reason: "easter egg done")
                    }
                } else {
                    playRandomIdle(reason: "idle timer")
                }
                resetIdleTimer()
            }
        }
    }

    // MARK: - Playback (NEVER fails silently)

    private func playClip(_ name: String, loop: Bool, transition: TimeInterval, reason: String = "") {
        guard let entity else {
            logger.error("[Play] ✘ entity is nil! Cannot play '\(name)' (\(reason))")
            return
        }

        if let clip = clips[name] {
            let resource = loop ? clip.repeat() : clip
            entity.playAnimation(resource, transitionDuration: transition)
            currentClipName = name
            logger.info("[Play] ▶ '\(name)' (\(loop ? "loop" : "once"), \(transition)s) — \(reason)")
        } else {
            logger.warning("[Play] ✘ '\(name)' not found (\(reason)). Trying fallback...")
            playAnyAvailable(reason: "fallback for missing '\(name)'")
        }
    }

    /// Guaranteed to play SOMETHING. Last resort uses entity.availableAnimations directly.
    private func playAnyAvailable(reason: String) {
        guard let entity else {
            logger.error("[Play] ✘ entity is nil! Cannot play anything (\(reason))")
            return
        }

        // Try clips dict first
        if let (name, clip) = clips.first {
            entity.playAnimation(clip.repeat(), transitionDuration: 0.3)
            currentClipName = name + " (fallback)"
            logger.info("[Play] ▶ '\(name)' (fallback, loop) — \(reason)")
            return
        }

        // Last resort: entity's own embedded animations
        if let embedded = entity.availableAnimations.first {
            entity.playAnimation(embedded.repeat(), transitionDuration: 0.3)
            currentClipName = "(embedded fallback)"
            logger.info("[Play] ▶ embedded animation (fallback) — \(reason)")
            return
        }

        logger.error("[Play] ✘ NO ANIMATIONS AVAILABLE AT ALL — \(reason)")
    }

    private func playRandomIdle(reason: String = "") {
        let variant = idleVariants.randomElement() ?? "Idle"
        playClip(variant, loop: true, transition: 0.6, reason: reason.isEmpty ? "random idle" : reason)
    }

    private func resetIdleTimer() {
        nextIdleSwitch = Float.random(in: 8...15)
        idleTimer = nextIdleSwitch
    }
}

// MARK: - Entity visitor
extension Entity {
    func visit(_ block: (Entity) -> Void) {
        block(self)
        for child in children {
            child.visit(block)
        }
    }
}
