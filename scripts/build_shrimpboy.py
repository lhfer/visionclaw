"""
Build ShrimpBoy: use FBX mesh (with weights) + Color.jpg texture + all animations.
"""
import bpy
import os
import glob

MODEL_DIR = "/Users/xiaoli/Downloads/3d卡通螃蟹帽人物模型"
MAIN_FBX = os.path.join(MODEL_DIR, "Neutral Idle.fbx")
TEX_FILE = os.path.join(MODEL_DIR, "Color.jpg")
OUTPUT_BLEND = "/Users/xiaoli/Projects/ShrimpXR/ShrimpXR/Resources/shrimpboy.blend"
OUTPUT_USDZ = "/Users/xiaoli/Projects/ShrimpXR/ShrimpXR/Resources/shrimpboy.usdz"

# Animation name mapping: fbx filename → clean name
ANIM_NAMES = {
    "Neutral Idle": "Idle",
    "Breathing Idle": "Breathing Idle",
    "Happy Idle": "Happy Idle",
    "Walking": "Walking",
    "Start Walking": "Start Walking",
    "Walking Turn 180": "Walking Turn 180",
    "Running": "Running",
    "Focus": "Focus",
    "Casting Spell": "Casting Spell",
    "Defeat": "Defeat",
    "Victory": "Victory",
    "Salute": "Salute",
    "Hip Hop Dancing": "Dancing",
    "Sleeping Idle": "Sleeping",
    "Standing Up": "Standing Up",
    "Male Dynamic Pose": "Dynamic Pose",
    "work": "Working",
}


def main():
    print("=" * 60)
    print("Building ShrimpBoy")
    print("=" * 60)

    # Step 1: Import main FBX (has mesh + rig + weights)
    print("\n=== Step 1: Import base model ===")
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.fbx(filepath=MAIN_FBX)

    mesh_obj = None
    rig_obj = None
    for obj in bpy.data.objects:
        if obj.type == 'MESH':
            mesh_obj = obj
        elif obj.type == 'ARMATURE':
            rig_obj = obj

    mesh_obj.name = "ShrimpBoy_Mesh"
    rig_obj.name = "ShrimpBoy_Rig"

    # Scale up from cm to m (Mixamo uses cm)
    rig_obj.scale = (100, 100, 100)
    bpy.context.view_layer.objects.active = rig_obj
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)

    print(f"  Mesh: {len(mesh_obj.data.vertices)} verts, {len(mesh_obj.data.polygons)} faces")
    print(f"  Vertex groups: {len(mesh_obj.vertex_groups)}")
    print(f"  Dimensions: {mesh_obj.dimensions.x:.2f} x {mesh_obj.dimensions.y:.2f} x {mesh_obj.dimensions.z:.2f}")

    # Rename first action
    if bpy.data.actions:
        first_action = bpy.data.actions[0]
        first_action.name = "Idle"
        print(f"  Renamed first action to: Idle")

    # Step 2: Add material with texture
    print("\n=== Step 2: Add material ===")
    mat = bpy.data.materials.new(name="ShrimpBoy_Material")
    mat.use_nodes = True
    tree = mat.node_tree
    tree.nodes.clear()

    # Create nodes
    bsdf = tree.nodes.new('ShaderNodeBsdfPrincipled')
    bsdf.location = (0, 0)
    output = tree.nodes.new('ShaderNodeOutputMaterial')
    output.location = (300, 0)
    tree.links.new(bsdf.outputs['BSDF'], output.inputs['Surface'])

    if os.path.exists(TEX_FILE):
        tex_node = tree.nodes.new('ShaderNodeTexImage')
        tex_node.location = (-300, 0)
        tex_node.image = bpy.data.images.load(TEX_FILE)
        tree.links.new(tex_node.outputs['Color'], bsdf.inputs['Base Color'])
        print(f"  Texture loaded: {TEX_FILE}")

    mesh_obj.data.materials.clear()
    mesh_obj.data.materials.append(mat)

    # Step 3: Import all other FBX animations
    print("\n=== Step 3: Import animations ===")
    fbx_files = sorted(glob.glob(os.path.join(MODEL_DIR, "*.fbx")))

    for fbx_path in fbx_files:
        fname = os.path.splitext(os.path.basename(fbx_path))[0]
        if fname == "Neutral Idle":
            continue  # already imported

        existing_actions = set(bpy.data.actions.keys())
        existing_objects = set(bpy.data.objects.keys())

        bpy.ops.import_scene.fbx(filepath=fbx_path)

        # Find and rename new action
        new_actions = [bpy.data.actions[n] for n in bpy.data.actions.keys() if n not in existing_actions]
        clean_name = ANIM_NAMES.get(fname, fname)
        for action in new_actions:
            action.name = clean_name
            print(f"  {fname} → {clean_name} ({action.frame_range[0]:.0f}-{action.frame_range[1]:.0f})")

        # Delete imported objects (we only want the action data)
        for obj_name in list(bpy.data.objects.keys()):
            if obj_name not in existing_objects:
                bpy.data.objects.remove(bpy.data.objects[obj_name], do_unlink=True)

    print(f"  Total actions: {len(bpy.data.actions)}")

    # Step 4: Create mouthOpen shape key
    print("\n=== Step 4: Create mouthOpen ===")
    head_bone = rig_obj.data.bones.get("mixamorig:Head")
    jaw_bone = rig_obj.data.bones.get("mixamorig:Jaw")

    # Add basis
    basis = mesh_obj.shape_key_add(name="Basis", from_mix=False)
    mouth_sk = mesh_obj.shape_key_add(name="mouthOpen", from_mix=False)

    # Find mouth area using head bone
    if head_bone:
        head_pos = rig_obj.matrix_world @ head_bone.head_local
        head_local = mesh_obj.matrix_world.inverted() @ head_pos

        print(f"  Head bone local pos: {head_local}")

        # The model is now scaled to ~1m tall
        # Scan for vertices near the front-lower part of the head
        mouth_affected = 0
        for i, v in enumerate(mesh_obj.data.vertices):
            co = v.co
            # Distance from head center
            dx = co.x - head_local.x
            dy = co.y - head_local.y
            dz = co.z - head_local.z

            # Mouth is at the front (positive X or Z depending on orientation),
            # below head center, and within a small radius
            # Let's detect the orientation first
            dist_to_head = ((dx**2 + dy**2 + dz**2) ** 0.5)
            if dist_to_head > 15:  # only near head
                continue

            # Lower part of head (below bone head position)
            if dy > 2 or dy < -10:  # only in the lower face region
                continue

            # Front-facing (check which axis is "forward")
            # For Mixamo models facing -Z, front vertices have smaller Z
            front_dist = dz  # negative Z = front

            if front_dist > 0:  # not front-facing
                continue

            # Compute falloff based on distance
            horiz_dist = (dx**2 + dz**2) ** 0.5
            if horiz_dist > 8:
                continue

            falloff = max(0, 1.0 - horiz_dist / 8.0)
            vert_falloff = max(0, 1.0 - abs(dy) / 10.0)
            total_falloff = falloff * vert_falloff

            if total_falloff < 0.05:
                continue

            drop = 1.5 * total_falloff
            if dy < 0:
                # Below center: jaw drops down
                mouth_sk.data[i].co.y = co.y - drop
                mouth_affected += 1
            elif dy < 2:
                # Near center/slightly above: slight lift
                mouth_sk.data[i].co.y = co.y + drop * 0.2
                mouth_affected += 1

        print(f"  mouthOpen: {mouth_affected} vertices affected")

        # Verify max displacement
        max_d = max((mouth_sk.data[i].co - basis.data[i].co).length
                    for i in range(len(basis.data)))
        print(f"  Max displacement: {max_d:.4f}")

    # Step 5: Validate & Export
    print("\n=== Step 5: Export ===")

    # List all actions
    for a in sorted(bpy.data.actions, key=lambda x: x.name):
        fs, fe = a.frame_range
        print(f"  Action: {a.name} ({int(fs)}-{int(fe)}, {(fe-fs)/24:.1f}s)")

    # Save blend
    bpy.ops.wm.save_as_mainfile(filepath=OUTPUT_BLEND)
    print(f"  Blend: {OUTPUT_BLEND}")

    # Export USDZ
    bpy.ops.object.select_all(action='DESELECT')
    mesh_obj.select_set(True)
    rig_obj.select_set(True)
    bpy.context.view_layer.objects.active = rig_obj

    bpy.ops.wm.usd_export(
        filepath=OUTPUT_USDZ,
        selected_objects_only=True,
        export_animation=True,
        export_shapekeys=True,
        export_armatures=True,
        export_materials=True,
        generate_preview_surface=True,
    )

    size_mb = os.path.getsize(OUTPUT_USDZ) / 1024 / 1024
    print(f"  USDZ: {size_mb:.1f} MB {'PASS' if size_mb < 15 else 'WARN'}")

    print("\n" + "=" * 60)
    print("Done!")
    print("=" * 60)


if __name__ == "__main__":
    main()
