extends RefCounted

# ============================================================================================
# LanternLook (ZondaCoopSync 5.0, builder B3): how a caged lantern looks. Static functions only,
# shared by your own first-person lantern (lantern.gd) and a teammate's knight (remote_player.gd).
# The cage itself is remote_player.build_cage_lantern(): a "Flame" MeshInstance3D (the glowing
# sphere) and, on your own lantern, a "Fire" CPUParticles3D (the licks above it).
#
# Other builders' files load this script at runtime and never preload it (contract 1A.1):
#   var LL = load("res://mods-unpacked/zonda-CoopSync/lantern_look.gd")
#   if LL != null: LL.callv("tint_cage_lantern", [root, light, spot, cursed])
#
# API
#   static func tint_cage_lantern(root: Node3D, light: OmniLight3D, spot: SpotLight3D, cursed: bool) -> void
#       cursed (you carry the idol): omni (1.0, 0.18, 0.10), spot (1.0, 0.22, 0.12), flame albedo
#       (0.55, 0.05, 0.02), fire ramp (0.6, 0.08, 0.02, 0.6) -> (0.25, 0, 0, 0), and meta
#       "zonda_energy_k" = 1.15 on root, light and spot (the callers multiply their per-frame
#       light energy by it). Normal: (1.0, 0.72, 0.42) / (1.0, 0.76, 0.48) / (0.5, 0.3, 0.1) /
#       (0.55, 0.3, 0.08, 0.6) -> (0.25, 0.04, 0.0, 0.0), energy k 1.0. Any argument may be null.
#   static func set_charm(root: Node3D, tier: int) -> void
#       The omen trophy charm (contract 3.2 TROPHY, cut down by OWNER DECISION 7A.6 of 2026-09-25)
#       as the child "ZondaOmenCharm" of the cage root. Rebuilt only when the tier changes; tier 0
#       removes it (and so does any tier while CAGE_SKULL is false). All unshaded, no lights, no
#       shadows, no particles (R10), and NO FLAME AND NO GLOW AT ANY TIER: the owner removed the
#       trophy candle (tier II) from the lantern cage, and the glowing eye sockets (tier III) went
#       with it. The trophy itself stays on the end card and in the saved record (omen.gd,
#       coop_sync.gd). Its one child, the same at every tier:
#         "Skull"     tier I+: a bone skull (cranium r 0.028, jaw 0.034 x 0.016 x 0.03, albedo
#                     (0.30, 0.28, 0.24), two black sockets r 0.007) on a 0.05 m chain, centre at
#                     y -0.175, under the bottom ring
#       Tier IV only adds the red name outline, on a teammate's knight (remote_player.gd). The skull
#       faces the viewer: +Z on your own first-person lantern (its root is a child of the
#       Camera3D), -Z (the knight's forward) on a teammate's knight. The idol's red tint
#       (tint_cage_lantern) is a different thing and is unchanged.
#   static func charm_tier(root: Node3D) -> int       the tier the charm on root shows (0 = none)
#   static func charm_parts(root: Node3D) -> int      how many parts it has (1 at every tier, 0 = none)
#   const CAGE_SKULL := false                         false (7A.6, the shipped value): no charm on the
#                                                     cage at all, so set_charm only removes one;
#                                                     true brings the plain skull back (one line)
# ============================================================================================

const CHARM_NAME := "ZondaOmenCharm"
const ENERGY_META := "zonda_energy_k"
const CURSED_ENERGY_K := 1.15

const CURSED_OMNI := Color(1.0, 0.18, 0.10)
const CURSED_SPOT := Color(1.0, 0.22, 0.12)
const CURSED_FLAME := Color(0.55, 0.05, 0.02)
const CURSED_RAMP0 := Color(0.6, 0.08, 0.02, 0.6)
const CURSED_RAMP1 := Color(0.25, 0.0, 0.0, 0.0)
const NORMAL_OMNI := Color(1.0, 0.72, 0.42)
const NORMAL_SPOT := Color(1.0, 0.76, 0.48)
const NORMAL_FLAME := Color(0.5, 0.3, 0.1)
const NORMAL_RAMP0 := Color(0.55, 0.3, 0.08, 0.6)
const NORMAL_RAMP1 := Color(0.25, 0.04, 0.0, 0.0)

const BONE := Color(0.30, 0.28, 0.24)
const IRON := Color(0.05, 0.04, 0.035)
# OWNER DECISION 7A.6: the trophy stays on the end card and in the saved record ONLY, so nothing of
# it goes on the cage: no candle, no ember-eye glow and no skull either. While this is false,
# set_charm only ever removes a charm (the Charm class below is kept for a later owner call).
const CAGE_SKULL := false


static func tint_cage_lantern(root: Node3D, light: OmniLight3D, spot: SpotLight3D, cursed: bool) -> void:
	var k := CURSED_ENERGY_K if cursed else 1.0
	if is_instance_valid(light):
		light.light_color = CURSED_OMNI if cursed else NORMAL_OMNI
		light.set_meta(ENERGY_META, k)
	if is_instance_valid(spot):
		spot.light_color = CURSED_SPOT if cursed else NORMAL_SPOT
		spot.set_meta(ENERGY_META, k)
	if not is_instance_valid(root):
		return
	root.set_meta(ENERGY_META, k)
	root.set_meta("zonda_cursed", cursed)
	var flame := root.get_node_or_null("Flame")
	if flame is MeshInstance3D:
		var m = (flame as MeshInstance3D).material_override
		if m is StandardMaterial3D:
			(m as StandardMaterial3D).albedo_color = CURSED_FLAME if cursed else NORMAL_FLAME
	var fire := root.get_node_or_null("Fire")
	if fire is CPUParticles3D:
		var g = (fire as CPUParticles3D).color_ramp
		if g is Gradient and (g as Gradient).get_point_count() >= 2:
			var gr := g as Gradient
			gr.set_color(0, CURSED_RAMP0 if cursed else NORMAL_RAMP0)
			gr.set_color(gr.get_point_count() - 1, CURSED_RAMP1 if cursed else NORMAL_RAMP1)


static func set_charm(root: Node3D, tier: int) -> void:
	if not is_instance_valid(root):
		return
	tier = clampi(tier, 0, 4)
	if not CAGE_SKULL:
		tier = 0
	var old := root.get_node_or_null(CHARM_NAME)
	if old != null:
		if int(old.get_meta("zonda_charm_tier", -1)) == tier:
			return
		root.remove_child(old)                # frees the name at once for the new charm
		old.queue_free()
	if tier <= 0:
		return
	var ch := Charm.new()
	ch.name = CHARM_NAME
	ch.set_meta("zonda_charm_tier", tier)
	ch.build(tier)
	root.add_child(ch)


static func charm_tier(root: Node3D) -> int:
	if not is_instance_valid(root):
		return 0
	var ch := root.get_node_or_null(CHARM_NAME)
	if ch == null or ch.is_queued_for_deletion():
		return 0
	return int(ch.get_meta("zonda_charm_tier", 0))


static func charm_parts(root: Node3D) -> int:
	if not is_instance_valid(root):
		return 0
	var ch := root.get_node_or_null(CHARM_NAME)
	if ch == null or ch.is_queued_for_deletion():
		return 0
	return ch.get_child_count()


# ---------------------------------------------------------------- the charm node

class Charm extends Node3D:
	# builds the plain bone skull (every tier looks the same since owner decision 7A.6: no candle,
	# no flame, no glowing sockets). Nothing animates, so it never processes.
	var tier := 0
	var _face: Array = []                            # the parts that turn toward the viewer

	func build(t: int) -> void:
		tier = t
		var fz := -1.0                                # built facing -Z (a knight's forward); see _enter_tree
		var bone := LanternLookMats.make(BONE)
		# ---- Skull (tier I+): a 0.05 m chain from the bottom ring, the skull centred at y -0.175
		var skull := Node3D.new()
		skull.name = "Skull"
		add_child(skull)
		_face.append(skull)
		var chain := CylinderMesh.new()
		chain.top_radius = 0.0025
		chain.bottom_radius = 0.0025
		chain.height = 0.05
		chain.radial_segments = 4
		LanternLookMats.mesh(skull, chain, LanternLookMats.make(IRON), Vector3(0.0, -0.125, 0.0))
		LanternLookMats.mesh(skull, LanternLookMats.sphere(0.028, 0.05), bone, Vector3(0.0, -0.175, 0.0))
		var jaw := BoxMesh.new()
		jaw.size = Vector3(0.034, 0.016, 0.03)
		LanternLookMats.mesh(skull, jaw, bone, Vector3(0.0, -0.197, 0.006 * fz))
		# the sockets stay black at every tier (the tier III ember glow was removed with the candle)
		var black := LanternLookMats.make(Color(0.0, 0.0, 0.0))
		for p in [Vector3(-0.0105, -0.171, 0.0225 * fz), Vector3(0.0105, -0.171, 0.0225 * fz)]:
			LanternLookMats.mesh(skull, LanternLookMats.sphere(0.007, 0.014), black, p)
		set_process(false)

	func _enter_tree() -> void:
		# the skull looks at whoever sees it: toward the camera on your own first-person lantern
		# (its cage root is a child of the Camera3D), the knight's forward on a teammate's. Decided
		# here, not in build(), because a caller may add the charm before it adds the cage.
		var root := get_parent()
		var first_person := root != null and root.get_parent() is Camera3D
		for n in _face:
			if is_instance_valid(n):
				(n as Node3D).rotation.y = PI if first_person else 0.0

	func _ready() -> void:
		set_process(false)


class LanternLookMats:
	# small mesh and material helpers for Charm.build (all unshaded, no shadows)
	static func make(c: Color) -> StandardMaterial3D:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = c
		return m

	static func mesh(parent: Node3D, m: Mesh, mat: Material, pos: Vector3) -> MeshInstance3D:
		var mi := MeshInstance3D.new()
		mi.mesh = m
		mi.material_override = mat
		mi.position = pos
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
		return mi

	static func sphere(r: float, h: float) -> SphereMesh:
		var s := SphereMesh.new()
		s.radius = r
		s.height = h
		s.radial_segments = 8
		s.rings = 4
		return s
