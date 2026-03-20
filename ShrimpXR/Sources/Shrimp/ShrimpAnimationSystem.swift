import RealityKit

/// Component that links an entity to its animation controller
struct ShrimpComponent: Component {
    let controller: ShrimpAnimationController

    @MainActor
    init(controller: ShrimpAnimationController) {
        self.controller = controller
    }
}

/// Component for dynamic bubble positioning — keeps bubble at constant world-space
/// size and tracks the character's head joint, regardless of parent scale changes.
struct BubblePositionComponent: Component {
    /// Mixamo head joint entity name (colon → underscore in USDZ)
    var headJointName: String = "mixamorig_Head"
    /// Fallback head position in model-local units if joint not found
    var fallbackHeadY: Float = 70
    /// Desired world-space offset above the head (meters)
    var worldOffsetAboveHead: Float = 0.04
    /// Target bubble world-space scale
    var targetWorldScale: Float = 0.7
    /// Min/max clamps to keep text readable
    var minWorldScale: Float = 0.4
    var maxWorldScale: Float = 1.2
}

/// RealityKit System — runs at render loop cadence (90fps on Vision Pro)
/// Handles: idle variation timer, lip sync, bubble head-tracking + counter-scaling
struct ShrimpAnimationSystem: System {
    static let query = EntityQuery(where: .has(ShrimpComponent.self))
    static let bubbleQuery = EntityQuery(where: .has(BubblePositionComponent.self))

    init(scene: Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)

        // Animation controllers
        for entity in context.entities(matching: Self.query, updatingSystemWhen: .rendering) {
            guard let comp = entity.components[ShrimpComponent.self] else { continue }
            comp.controller.updatePerFrame(deltaTime: dt)
        }

        // Bubble positioning — keep world-space size constant, track head joint
        for entity in context.entities(matching: Self.bubbleQuery, updatingSystemWhen: .rendering) {
            guard let config = entity.components[BubblePositionComponent.self],
                  let parent = entity.parent else { continue }

            let parentScale = parent.scale.x // uniform scale
            guard parentScale > 0 else { continue }

            // 1. Scale: maintain constant world-space size
            let clampedWorldScale = min(config.maxWorldScale, max(config.minWorldScale, config.targetWorldScale))
            entity.scale = SIMD3<Float>(repeating: clampedWorldScale / parentScale)

            // 2. Position: track head joint (findEntity is cheap for ~50 nodes)
            var headLocalPos = SIMD3<Float>(0, config.fallbackHeadY, 0)
            if let headJoint = parent.findEntity(named: config.headJointName) {
                headLocalPos = headJoint.position(relativeTo: parent)
            }

            // Convert world-space offset to parent-local space
            let localOffset = config.worldOffsetAboveHead / parentScale
            entity.position = headLocalPos + SIMD3<Float>(0, localOffset, 0)
        }
    }
}
