"""
ShrimpBoy model optimization pipeline:
1. Enhance mouthOpen shape key (make jaw actually open)
2. Decimate to ~50k faces (protect face + hands via vertex group)
3. Transfer shape keys to decimated mesh via Surface Deform
4. Validate & export USDZ

Run: /Applications/Blender.app/Contents/MacOS/Blender --background \
     "/Users/xiaoli/Downloads/虾男动画完整版/虾男动作库_master.blend" \
     --python optimize_and_export.py
"""

import bpy
import os
from mathutils import Vector

MESH_NAME = "ShrimpBoy_Mesh"
RIG_NAME = "ShrimpBoy_Rig"
TARGET_FACES = 50000
OUTPUT_BLEND = "/Users/xiaoli/Projects/ShrimpXR/ShrimpXR/Resources/虾男_optimized.blend"
OUTPUT_USDZ = "/Users/xiaoli/Projects/ShrimpXR/ShrimpXR/Resources/shrimpboy.usdz"

# Coordinate system: Y=up, Z=left-right, X=front-back
# Character ~100 units tall. Head bone at Y=69.68.
# Left hand at Z=-32.7, Right hand at Z=+32.7


def get_bone_mesh_pos(rig, mesh_obj, bone_name):
    """Get bone head position in mesh local space."""
    bone = rig.data.bones[bone_name]
    world_pos = rig.matrix_world @ bone.head_local
    return mesh_obj.matrix_world.inverted() @ world_pos


# ─── Step 1: Enhance mouthOpen ──────────────────────────────────────────────

def enhance_mouth_open():
    print("\n=== Step 1: Enhance mouthOpen Shape Key ===")

    mesh_obj = bpy.data.objects[MESH_NAME]
    basis = mesh_obj.data.shape_keys.key_blocks["Basis"]
    mouth_sk = mesh_obj.data.shape_keys.key_blocks["mouthOpen"]

    # Mouth region: X~10.3, Y~76.8, Z~1.3 (mesh local coords)
    mouth_cx, mouth_cy = 10.3, 76.8

    # First amplify existing deltas by 2.5x
    amplified = 0
    for i in range(len(basis.data)):
        delta = mouth_sk.data[i].co - basis.data[i].co
        if delta.length > 0.0001:
            mouth_sk.data[i].co = basis.data[i].co + delta * 2.5
            amplified += 1
    print(f"  Amplified {amplified} existing vertices by 2.5x")

    # Add jaw-drop effect to mouth region vertices
    jaw_added = 0
    for i in range(len(basis.data)):
        co = basis.data[i].co
        # Check if in mouth region (cylindrical check around mouth center)
        dx = abs(co.x - mouth_cx)
        dy_from_center = co.y - mouth_cy
        if dx > 1.5 or abs(dy_from_center) > 2.0:
            continue

        dist_xz = ((co.x - mouth_cx) ** 2 + (co.z - 1.3) ** 2) ** 0.5
        falloff = max(0.0, 1.0 - dist_xz / 1.5)
        if falloff < 0.01:
            continue

        current_delta = mouth_sk.data[i].co - basis.data[i].co

        if dy_from_center < 0:
            # Below center → jaw drop (move down in Y)
            drop_strength = min(1.0, abs(dy_from_center) / 2.0)
            drop = drop_strength * falloff * 2.5
            if drop > 0.01:
                mouth_sk.data[i].co.y = basis.data[i].co.y + current_delta.y - drop
                mouth_sk.data[i].co.z = basis.data[i].co.z + current_delta.z - drop * 0.15
                jaw_added += 1
        else:
            # Above center → slight upward lift
            lift_strength = min(1.0, dy_from_center / 1.5)
            lift = lift_strength * falloff * 0.8
            if lift > 0.01:
                mouth_sk.data[i].co.y = basis.data[i].co.y + current_delta.y + lift
                jaw_added += 1

    print(f"  Added jaw-drop/lip-lift to {jaw_added} additional vertices")

    # Verify
    affected = sum(1 for i in range(len(basis.data))
                   if (mouth_sk.data[i].co - basis.data[i].co).length > 0.0001)
    max_d = max((mouth_sk.data[i].co - basis.data[i].co).length
                for i in range(len(basis.data)))
    print(f"  Result: {affected} affected verts, max delta = {max_d:.3f}")


# ─── Step 2: Decimate ───────────────────────────────────────────────────────

def decimate_mesh():
    print("\n=== Step 2: Decimate mesh ===")

    orig = bpy.data.objects[MESH_NAME]
    rig = bpy.data.objects[RIG_NAME]
    orig_faces = len(orig.data.polygons)
    print(f"  Original: {len(orig.data.vertices)} verts, {orig_faces} faces")

    # Create soft-protection vertex group: face/hands get partial weight
    # so they keep MORE detail but still get reduced
    head_pos = get_bone_mesh_pos(rig, orig, "mixamorig:Head")
    head_top = get_bone_mesh_pos(rig, orig, "mixamorig:HeadTop_End")
    lhand_pos = get_bone_mesh_pos(rig, orig, "mixamorig:LeftHand")
    rhand_pos = get_bone_mesh_pos(rig, orig, "mixamorig:RightHand")
    face_center = (head_pos + head_top) * 0.5

    if "DecimateProtect" in orig.vertex_groups:
        orig.vertex_groups.remove(orig.vertex_groups["DecimateProtect"])
    vg = orig.vertex_groups.new(name="DecimateProtect")

    head_radius = 12.0
    hand_radius = 7.0

    for v in orig.data.vertices:
        # Compute protection weight (0 = full decimation, 1 = full protection)
        w = 0.0
        d_head = (v.co - face_center).length
        if d_head < head_radius:
            w = max(w, 0.7 * (1.0 - d_head / head_radius))

        d_lh = (v.co - lhand_pos).length
        if d_lh < hand_radius:
            w = max(w, 0.5 * (1.0 - d_lh / hand_radius))

        d_rh = (v.co - rhand_pos).length
        if d_rh < hand_radius:
            w = max(w, 0.5 * (1.0 - d_rh / hand_radius))

        vg.add([v.index], w, 'REPLACE')

    print("  Created soft-protection vertex group (face/hands partially protected)")

    # Duplicate mesh
    bpy.ops.object.select_all(action='DESELECT')
    orig.select_set(True)
    bpy.context.view_layer.objects.active = orig
    bpy.ops.object.duplicate()
    low = bpy.context.active_object
    low.name = "ShrimpBoy_Low"

    # Remove ALL modifiers from the copy (especially Armature)
    for mod in list(low.modifiers):
        low.modifiers.remove(mod)
    print("  Removed all modifiers from copy")

    # Remove shape keys from copy
    if low.data.shape_keys:
        low.shape_key_clear()
    print("  Removed shape keys from copy")

    # Apply Decimate with vertex group for soft protection
    ratio = TARGET_FACES / orig_faces
    print(f"  Decimate ratio: {ratio:.6f}")
    mod = low.modifiers.new(name="Decimate", type='DECIMATE')
    mod.decimate_type = 'COLLAPSE'
    mod.ratio = ratio
    mod.vertex_group = "DecimateProtect"
    mod.invert_vertex_group = True  # higher weight = less decimation
    bpy.context.view_layer.objects.active = low
    bpy.ops.object.modifier_apply(modifier="Decimate")

    print(f"  After decimate: {len(low.data.vertices)} verts, {len(low.data.polygons)} faces")
    return low


# ─── Step 3: Transfer Shape Keys via Surface Deform ─────────────────────────

def transfer_shape_keys(low_obj):
    print("\n=== Step 3: Transfer Shape Keys (Surface Deform) ===")

    orig = bpy.data.objects[MESH_NAME]
    rig = bpy.data.objects[RIG_NAME]

    if not orig.data.shape_keys:
        print("  ERROR: No shape keys on original!")
        return

    sk_names = [kb.name for kb in orig.data.shape_keys.key_blocks if kb.name != "Basis"]
    print(f"  Shape keys to transfer: {sk_names}")

    # CRITICAL: Set rig to rest pose and disable Armature modifier on original
    # so Surface Deform only captures shape key changes
    rig.data.pose_position = 'REST'
    orig_arm_mod = None
    for mod in orig.modifiers:
        if mod.type == 'ARMATURE':
            orig_arm_mod = mod
            mod.show_viewport = False
            mod.show_render = False
            break
    bpy.context.view_layer.update()
    print("  Set rig to REST pose, disabled Armature modifier on original")

    # Reset all shape key values on original
    for kb in orig.data.shape_keys.key_blocks:
        kb.value = 0.0
    bpy.context.view_layer.update()

    # Ensure low_obj has NO modifiers
    for mod in list(low_obj.modifiers):
        low_obj.modifiers.remove(mod)

    # Add Surface Deform on low-poly targeting the original
    bpy.ops.object.select_all(action='DESELECT')
    low_obj.select_set(True)
    bpy.context.view_layer.objects.active = low_obj

    sd_mod = low_obj.modifiers.new(name="SurfaceDeform", type='SURFACE_DEFORM')
    sd_mod.target = orig
    sd_mod.falloff = 4.0

    print("  Binding Surface Deform...")
    result = bpy.ops.object.surfacedeform_bind(modifier="SurfaceDeform")
    if 'FINISHED' not in result:
        print(f"  WARNING: Bind failed ({result}), retrying with falloff=16")
        sd_mod.falloff = 16.0
        result = bpy.ops.object.surfacedeform_bind(modifier="SurfaceDeform")
    print(f"  Bind: {result}")

    # Create Basis on low-poly
    low_obj.shape_key_add(name="Basis", from_mix=False)

    # Transfer each shape key
    for sk_name in sk_names:
        # Activate this shape key on original
        for kb in orig.data.shape_keys.key_blocks:
            kb.value = 1.0 if kb.name == sk_name else 0.0

        # Force update
        bpy.context.view_layer.update()
        dg = bpy.context.evaluated_depsgraph_get()
        dg.update()

        # Apply Surface Deform as shape key
        bpy.context.view_layer.objects.active = low_obj
        bpy.ops.object.modifier_apply_as_shapekey(
            keep_modifier=True, modifier="SurfaceDeform"
        )

        # Rename
        new_sk = low_obj.data.shape_keys.key_blocks[-1]
        new_sk.name = sk_name
        new_sk.value = 0.0

        # Validate
        basis_data = low_obj.data.shape_keys.key_blocks["Basis"]
        max_d = 0
        affected = 0
        for i in range(len(basis_data.data)):
            d = (new_sk.data[i].co - basis_data.data[i].co).length
            if d > 0.0001:
                affected += 1
                max_d = max(max_d, d)
        print(f"  {sk_name}: affected={affected}, max_delta={max_d:.3f}")

    # Cleanup: reset original, re-enable armature
    for kb in orig.data.shape_keys.key_blocks:
        kb.value = 0.0
    if orig_arm_mod:
        orig_arm_mod.show_viewport = True
        orig_arm_mod.show_render = True
    rig.data.pose_position = 'POSE'

    # Remove Surface Deform from low-poly
    low_obj.modifiers.remove(low_obj.modifiers["SurfaceDeform"])
    print("  Done transferring shape keys")


# ─── Step 4: Finalize ───────────────────────────────────────────────────────

def finalize(low_obj):
    print("\n=== Step 4: Finalize ===")

    orig = bpy.data.objects[MESH_NAME]
    rig = bpy.data.objects[RIG_NAME]

    # Transfer vertex groups (armature weights) via Data Transfer
    bpy.ops.object.select_all(action='DESELECT')
    low_obj.select_set(True)
    orig.select_set(True)
    bpy.context.view_layer.objects.active = low_obj

    dt_mod = low_obj.modifiers.new(name="DataTransfer", type='DATA_TRANSFER')
    dt_mod.object = orig
    dt_mod.use_vert_data = True
    dt_mod.data_types_verts = {'VGROUP_WEIGHTS'}
    dt_mod.vert_mapping = 'POLYINTERP_NEAREST'
    bpy.ops.object.modifier_apply(modifier="DataTransfer")
    print("  Transferred vertex groups")

    # Add Armature modifier
    arm_mod = low_obj.modifiers.new(name="Armature", type='ARMATURE')
    arm_mod.object = rig
    print("  Added Armature modifier")

    # Parent to rig
    low_obj.parent = rig
    low_obj.matrix_parent_inverse = orig.matrix_parent_inverse.copy()

    # Copy materials
    low_obj.data.materials.clear()
    for mat in orig.data.materials:
        low_obj.data.materials.append(mat)
    print(f"  Copied {len(orig.data.materials)} materials")

    # Swap names
    orig.name = "ShrimpBoy_Mesh_HiPoly"
    orig.hide_set(True)
    orig.hide_render = True
    low_obj.name = MESH_NAME
    print("  Swapped names, hid original")


# ─── Step 5: Validate ───────────────────────────────────────────────────────

def validate():
    print("\n=== Step 5: Validate ===")

    mesh_obj = bpy.data.objects[MESH_NAME]

    faces = len(mesh_obj.data.polygons)
    verts = len(mesh_obj.data.vertices)
    print(f"  Faces: {faces} {'PASS' if faces < 60000 else 'FAIL'} (target < 60k)")
    print(f"  Vertices: {verts}")

    if mesh_obj.data.shape_keys:
        basis = mesh_obj.data.shape_keys.key_blocks["Basis"]
        for kb in mesh_obj.data.shape_keys.key_blocks:
            if kb.name == "Basis":
                continue
            affected = sum(1 for i in range(len(basis.data))
                          if (kb.data[i].co - basis.data[i].co).length > 0.0001)
            max_d = max((kb.data[i].co - basis.data[i].co).length
                       for i in range(len(basis.data)))
            ok = affected > 0 and max_d < 20
            print(f"    {kb.name}: affected={affected}, max_delta={max_d:.3f} {'PASS' if ok else 'FAIL'}")
    else:
        print("  FAIL: No shape keys!")

    actions = len(bpy.data.actions)
    print(f"  Actions: {actions} {'PASS' if actions == 28 else 'FAIL'}")

    has_arm = any(m.type == 'ARMATURE' for m in mesh_obj.modifiers)
    print(f"  Armature modifier: {'PASS' if has_arm else 'FAIL'}")

    bone_vgs = sum(1 for vg in mesh_obj.vertex_groups if vg.name.startswith("mixamorig:"))
    print(f"  Bone vertex groups: {bone_vgs}")


# ─── Step 6: Export ──────────────────────────────────────────────────────────

def export():
    print("\n=== Step 6: Export ===")

    mesh_obj = bpy.data.objects[MESH_NAME]
    rig = bpy.data.objects[RIG_NAME]

    # Hide high-poly
    if "ShrimpBoy_Mesh_HiPoly" in bpy.data.objects:
        hi = bpy.data.objects["ShrimpBoy_Mesh_HiPoly"]
        hi.hide_set(True)
        hi.hide_render = True
        hi.select_set(False)

    bpy.ops.object.select_all(action='DESELECT')
    mesh_obj.select_set(True)
    rig.select_set(True)
    bpy.context.view_layer.objects.active = rig

    bpy.ops.wm.usd_export(
        filepath=OUTPUT_USDZ,
        selected_objects_only=True,
        export_animation=True,
        export_shapekeys=True,
        export_armatures=True,
        export_materials=True,
        export_textures_mode='NEW',
        generate_preview_surface=True,
    )

    size_mb = os.path.getsize(OUTPUT_USDZ) / 1024 / 1024
    print(f"  USDZ: {OUTPUT_USDZ} ({size_mb:.1f} MB) {'PASS' if size_mb < 10 else 'FAIL'}")

    bpy.ops.wm.save_as_mainfile(filepath=OUTPUT_BLEND)
    print(f"  Blend: {OUTPUT_BLEND}")


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    print("=" * 60)
    print("ShrimpBoy Optimization Pipeline")
    print("=" * 60)

    enhance_mouth_open()
    low_obj = decimate_mesh()
    transfer_shape_keys(low_obj)
    finalize(low_obj)
    validate()
    export()

    print("\n" + "=" * 60)
    print("Done!")
    print("=" * 60)


if __name__ == "__main__":
    main()
