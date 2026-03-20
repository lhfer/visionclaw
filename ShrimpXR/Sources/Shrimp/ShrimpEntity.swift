import RealityKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.shrimpxr.app", category: "Entity")

enum ShrimpLoadError: Error {
    case modelNotFound(String)
}

@MainActor
final class ShrimpEntity {

    /// Outermost entity: handles position/rotation/scale. Safe to rotate.
    let root: Entity
    /// Animated model entity. Orientation is always identity — never rotate this.
    let model: Entity
    let controller: ShrimpAnimationController

    private var anchorEntity: AnchorEntity?

    private init(root: Entity, model: Entity, controller: ShrimpAnimationController) {
        self.root = root
        self.model = model
        self.controller = controller
    }

    static func load(named fileName: String = "shrimpboy") async throws -> ShrimpEntity {
        logger.info("Loading model '\(fileName)'...")

        guard let url = Bundle.main.url(forResource: fileName, withExtension: "usdz") else {
            throw ShrimpLoadError.modelNotFound(fileName)
        }
        let modelEntity = try await Entity(contentsOf: url)
        logger.info("Model loaded (\(modelEntity.availableAnimations.count) embedded animations)")

        // Scale: model is ~100 Mixamo cm units. 0.002 → ~20cm world height.
        modelEntity.scale = SIMD3<Float>(repeating: 0.002)
        // Model orientation stays identity — animations require this.

        // Wrapper entity: handles facing direction + user gestures.
        // Rotate 180° on Y so character faces the user (model's front is -Z).
        let root = Entity()
        root.name = "ShrimpRoot"
        // No forced rotation — model's native orientation faces user in visionOS.
        root.addChild(modelEntity)

        // Animation controller — plays on modelEntity (identity orientation)
        let controller = ShrimpAnimationController()
        controller.setup(entity: modelEntity)

        // Gesture input + collision on MODEL entity (must be on the entity with geometry)
        modelEntity.components.set(InputTargetComponent(allowedInputTypes: .all))

        let bounds = modelEntity.visualBounds(relativeTo: modelEntity)
        modelEntity.components.set(
            CollisionComponent(shapes: [.generateBox(size: bounds.extents)])
        )

        modelEntity.components.set(HoverEffectComponent())
        root.components.set(GroundingShadowComponent(castsShadow: true))
        root.components.set(ShrimpComponent(controller: controller))

        logger.info("ShrimpBoy ready")
        return ShrimpEntity(root: root, model: modelEntity, controller: controller)
    }

    /// Place in front of user. Y=0 is floor. Typical desk ≈ 0.7m.
    func placeAtFixedPosition(in content: RealityViewContent) {
        let position = SIMD3<Float>(0, 0.8, -0.8)
        let anchor = AnchorEntity(world: position)
        anchor.addChild(root)
        content.add(anchor)
        self.anchorEntity = anchor
        logger.info("Placed at \(position)")
    }

    func relocateAndStandUp() {
        guard let anchor = anchorEntity else { return }
        anchor.position = SIMD3<Float>(0, 0.8, -0.8)
        root.position = .zero
        root.orientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) // identity
        logger.info("Relocated")
    }

    func forceUpright() {
        let forward = root.orientation.act(SIMD3<Float>(0, 0, 1))
        let yAngle = atan2(forward.x, forward.z)
        root.orientation = simd_quatf(angle: yAngle, axis: [0, 1, 0])
    }
}
