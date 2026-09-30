extends Node
# ============================================================================================
# THE UNDERDARK: surfaces (ZondaCoopSync v5.0, feature module "surfaces", loaded LAST)
#
# How every surface takes the lantern (lighting design 2026-09-25, "the lantern on every surface").
# The map's own cave rock is tuned by underdark.gd (ROCK_SHEEN, rock_normal, sheen_spec); this
# module does everything else: props, creatures, crystals, glass, iron, wood, the lights' specular,
# and two new pieces of glossy / refractive geometry (ice sheen decals, water inside the falls).
# All of it is local to each player's machine: nothing is synced, every player runs the same pass.
#
# Rules it keeps: NORMAL PIXELS keeps the game's pixels and palette (colours never change: the only
# albedo edits are the metal swap below and the refraction share, both computed so the rendered lit
# diffuse stays identical; raw metallic changes ("mr") are ULTRA HD only); no one-pixel specks at
# 640x360 (roughness floors, SOFT normal maps, wide lobes); emission never touched; no class_name;
# CC0 only (the only new textures are procedural or the mod's own gfx/ maps).
#
# Refraction (crystal, spar crystal, glass, water): the material draws in the transparent pass with
# render_priority -1, so billboards and spray behind or inside it depth-test against it as they did
# when it was opaque; its albedo is raised by 1 / alpha (opaque sources) so the lit colour is
# unchanged and the refraction only adds transmitted light; a crystal that cast a shadow gets a
# shadow-only twin (Godot gives alpha-pass surfaces no shadow pass).
#
# The sheen is set as a RATIO: each class has a roughness r and a sheen ratio S0 = how much brighter
# the lantern's face-on highlight is than the lit surface around it. metallic_specular is solved
# from it and the albedo (_solve), so dark and bright surfaces read equally glossy.
#
# Lifecycle: setup(map) (reads the one-shot dev flag surfaces.flag), _ready: queue every
# GeometryInstance3D and Light3D under the map, build the ice decals and water columns, follow F4
# (gfx.mode_changed) and nodes added later (SceneTree.node_added, 2 frames' grace so a
# material_override set right after add_child is seen). _process drains PER_FRAME nodes a frame,
# scrolls the water, and once a second follows the game's "reduced pixelization" setting.
# on_exit(): disconnects. perf.flag "off" skips every feature module (a free A/B).
# While loaded (and not "off") it asks gfx.gd for the screen-space roughness limiter in NORMAL
# PIXELS too (np_limiter_use); the campaign's NORMAL PIXELS keeps the game's limiter-off look.
#
# Ownership: a material the pass tunes carries meta zonda_surf = <class>, zonda_alb0 (original
# albedo), zonda_m0 (original effective metallic), zonda_n0 (original normal map). A tagged material
# is never reclassified; _apply() writes every field it owns from the profile and those originals,
# so re-applying (F4) never compounds. A cached game resource (resource_path set: Wall_04.tres,
# Wood_01.tres, Monster.tres, sub-resources of the game's .glb scenes...) is duplicated once and the
# copy put back in the same slot; nothing shared with the campaign is ever edited. The map's rock
# materials (tag "rock_own") are skipped.
#
# Light policy ("lower only", light_specular = min(current, target)): lanterns (zonda_keep under a
# ZondaLantern) untouched (lantern.gd / remote_player.gd own them); other zonda_keep lights (idol
# glows) 0.35; DirectionalLight3D 0.0; fills (meta zonda_no_shadow: L.lights, crystal glows, Nest
# lamps, teammates' personal lights) 0.15; every other flame or warm source 0.35. Visual only.
#
# Owner options (consts below): O1 spider / crawler eye shine (ULTRA HD only), O5 Kenney nature
# metallic 1 -> 0 (on; NORMAL PIXELS keeps today's lit brightness through the swap, ULTRA HD gets
# the brighter look pending the owner's review). O2, O3, O4, O6, O7 are OFF and not built (they would touch emission or
# are untested paths). O8 (dress rocks wear the ULTRA photos) needs look_ultra.gd to take the dress
# materials, which it does not yet: no effect here.
#
# Dev test: maps/underdark/surfaces.flag (one shot, deleted when read), comma separated words:
#   ""      NORMAL PIXELS run           "ultra"  ULTRA HD run          "both"  NP then ULTRA HD
#   "off"   classify and count only, change nothing (the performance baseline; it writes
#           user://surf_base.json, which a later normal run compares GPU time and load time against)
#   "f4"    add the F4 round-trip check  any other word: a label prefix filter for the spots
# Log tag [SURF]; ends with "[SURF] RESULT pass" (or "fail: ...") and "[SURF] done".
# Harness: run_test.sh surfaces "surfaces.flag" "" "\[SURF\] done" 900  (FLAGTXT=the words)
# ============================================================================================

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const PER_FRAME := 300                 # nodes classified per frame
const SETTLE_FRAMES := 2               # a node added at runtime waits this long (its material may come after add_child)
const EMBER_SCENE := "res://Treasure_Pickup.tscn"
const EMBER_SCRIPT := "res://treasure_pickup.gd"

# ---- owner options (design section 6)
const O1_EYE_SHINE_NP := false         # a red 1-2 px eye dot at 640x360 is by definition a one-pixel highlight
const O1_EYE_SHINE_UHD := true
const O2_RODS_LIT := false             # not built (it would add emission)
const O3_HARRIERS_LIT := false         # not built (silhouettes by design)
const O4_FLAMES_UNSHADED := false      # not built (it would touch emission)
const O5_KENNEY_UNMETAL := false       # owner test 09-25: the un-metalled Fungal plants burned white under the lantern: keep the shipped look
const O6_GRAVEYARD_RELIEF := false     # not built (untested detail-layer path)
const O7_CAGE_PULSE := false           # not built
const O8_DRESS_PHOTOS := true          # needs look_ultra.gd to take the dress materials: no effect in this build

# mean linear luminance of the game's albedo textures (measured offline from the game's files)
const TEX_LUM := {"res://Art/Textures/Wall_04.png": 0.147, "res://Art/Textures/Rock.png": 0.125,
		"res://Art/Textures/Wood_Colorized.png": 0.036, "res://Art/Ancient_Kiln_BaseColor.png": 0.029,
		"res://Art/Centipede_Paint_BaseColor.png": 0.013, "res://Art/Monster_Redesign_Base.png": 0.047,
		"res://Art/Corpse_Painting_BaseColor.png": 0.107}
const KILN_ALB := ["res://Art/Ancient_Kiln_BaseColor.png", "res://Art/Ancient_Kiln_Deco_Ancient_Kiln_BaseColor.png",
		"res://Art/Broken_Kiln_Ancient_Kiln_BaseColor.png"]
const MONSTER_RES := ["res://Art/Monster.tres", "res://Art/Monster_Redesign.tres"]
const MONSTER_ALB := ["res://Art/Centipede_Paint_BaseColor.png", "res://Art/Monster_Redesign_Base.png"]
# Poly Haven files (maps/underdark/ext/ph/<file>.glb) by class
const PH_ROCK := ["boulder_01", "namaqualand_boulder_02", "namaqualand_boulder_03", "namaqualand_boulder_04",
		"namaqualand_boulder_05", "namaqualand_boulder_06", "namaqualand_boulders_01", "namaqualand_rocks_01",
		"namaqualand_stones_01", "rock_07", "rock_09", "rock_moss_set_01", "single_root", "dead_tree_trunk_02",
		"tree_stump_01", "tree_stump_02"]
const PH_WOOD := ["barrel_01", "barrel_02", "wine_barrel_01", "wooden_barrels_01", "wooden_bucket_01",
		"wooden_bucket_02", "wooden_crate_02", "wooden_ladder", "wooden_stool_02", "wooden_table_02",
		"old_military_crate", "wicker_basket_01", "wooden_lantern_01"]
const PH_WET := ["wooden_bucket_02", "wine_barrel_01", "wooden_barrels_01"]      # plus any wood in the Drowned (4)
const PH_METAL := ["brass_candleholders", "brass_goblets", "lantern_01", "lantern_chandelier_01", "treasure_chest",
		"rusted_spade_01", "picke_dirty_01", "wooden_axe_02", "metal_jug"]
const PH_CERAMIC := {"antique_ceramic_vase_01": "ph_vase", "ceramic_pot": "ph_pot", "marble_bust_01": "ph_marble",
		"gothic_statue": "ph_statue", "bull_head": "ph_statue", "horse_head": "ph_statue", "planter_pot_clay": "ph_clay"}
const QUAT_STONE_PREFIX := ["Arch_", "Brick", "BridgeSection", "Column_", "Curve_", "Floor_", "Rail_", "Stairs",
		"Statue_", "Support_", "Wall", "Window_"]
const QUAT_STONE_NAMES := ["Main", "Main2", "Highlights", "Black", "Stone"]
const QUAT_BY_NAME := {"Bone": "quat_skull", "Metal": "quat_metal", "DarkMetal": "quat_metal", "Metal_Light": "quat_metal",
		"Gold": "quat_metal", "Wood": "quat_wood", "DarkWood": "quat_wood", "Bark": "quat_wood", "Candle": "quat_wax",
		"Green": "quat_leaf", "Leaf_Texture": "quat_leaf", "Pages": "quat_book"}

var map: Node = null
var _ultra := false
var _off := false                      # surfaces.flag "off": classify and count only
var _prof: Dictionary = {}             # class -> {"np": {...}, "uhd": {...}}
var _queue: Array = []                 # [node, ready process frame]
var _qi := 0
var _init_n := 0                       # entries queued by _ready still at or ahead of _qi (the first sweep)
var _init_wait := 0                    # frames since the first sweep's entries were through while runtime traffic kept the queue busy
var _owned: Dictionary = {}            # material instance id -> [material, class]
var _dups: Dictionary = {}             # "kind|source instance id" -> copy
var _slots: Dictionary = {}            # class -> slots (node surfaces) it was seen in
var _other: Dictionary = {}            # "resource_name@rel" -> slots, unclassified
var _skips := 0
var _n_geo := 0
var _n_light := 0
var _lights := {"fill": 0, "warm": 0, "dir": 0, "kept": 0, "glow": 0}
var _comp: Dictionary = {}             # material instance id -> true: albedo-compensated by the metal swap
var _sweep_us := 0
var _sweep_frames := 0
var _sweep_done := false
var _scripts: Dictionary = {}          # map inner-class script instance id -> "egg" / "spar" / "frag" / "gate" / "fall"
var _flask_ids: Dictionary = {}
var _flask_n := -1
var _rock_ids: Dictionary = {}
var _m_bar: StandardMaterial3D = null
var _m_ruin: StandardMaterial3D = null
var _m_cprop: StandardMaterial3D = null
var _m_crystal: StandardMaterial3D = null
var _bar_thin: StandardMaterial3D = null
var _eyes: Array = []                  # [MeshInstance3D, rig material, {surface: eye material}]
var _eye_seen: Dictionary = {}
var _ice: Array = []                   # Decal
var _ice_orm: Array = []               # [NORMAL PIXELS ORM, ULTRA HD ORM]
var _water: Array = []                 # [StandardMaterial3D, uv scroll per second]
var _water_mats: Dictionary = {}       # rounded fall height -> material
var _n_water := 0
var _white: ImageTexture = null
var _pix := -2
var _pix_t := 0.0
var _gfx_connected := false
var _added_connected := false
var _lim_on := false                   # this map holds gfx's NORMAL PIXELS roughness limiter on
var _proxies: Array = []               # [shadow-only twin, the refractive material it stands in for]
var _proxy_mat: StandardMaterial3D = null


func setup(m: Node) -> void:
	map = m
	var t = null
	if map != null and map.has_method("dev_flag"):
		t = map.call("dev_flag", "surfaces.flag")
	if t != null:
		# TEST SAFETY (1A.2): a test never touches the real save or trophies
		if CoopSync.has_method("use_test_files"):
			CoopSync.call("use_test_files")
		_arm_test(str(t))


func _ready() -> void:
	if map == null:
		map = get_parent()
	_prof = _build_profiles()
	_ultra = _is_ultra()
	_read_map_members()
	var gfx = CoopSync.gfx
	if is_instance_valid(gfx) and gfx.has_signal("mode_changed") and not gfx.is_connected("mode_changed", _on_mode):
		gfx.connect("mode_changed", _on_mode)
		_gfx_connected = true
	if not get_tree().node_added.is_connected(_on_added):
		get_tree().node_added.connect(_on_added)
		_added_connected = true
	for n in map.find_children("*", "GeometryInstance3D", true, false):
		_queue.append([n, 0])
	for n in map.find_children("*", "Light3D", true, false):
		_queue.append([n, 0])
	_init_n = _queue.size()
	if not _off:
		_build_ice()
		_build_falls()
		# NORMAL PIXELS runs the roughness limiter only while this map is loaded (gfx.gd)
		if is_instance_valid(gfx) and gfx.has_method("np_limiter_use"):
			gfx.call("np_limiter_use", true)
			_lim_on = true
	if _t_on:
		_run_test.call_deferred()


func on_exit() -> void:
	_disconnect()


func _exit_tree() -> void:
	_disconnect()
	_test_restore()


func _disconnect() -> void:
	var gfx = CoopSync.gfx
	if is_instance_valid(gfx) and gfx.has_signal("mode_changed") and gfx.is_connected("mode_changed", _on_mode):
		gfx.disconnect("mode_changed", _on_mode)
	if _lim_on:
		_lim_on = false
		if is_instance_valid(gfx) and gfx.has_method("np_limiter_use"):
			gfx.call("np_limiter_use", false)
	# on_exit runs from the map's _exit_tree, after this child already left the tree: get_tree() there
	# would print an engine error (and our own _exit_tree has disconnected already)
	if is_inside_tree() and get_tree().node_added.is_connected(_on_added):
		get_tree().node_added.disconnect(_on_added)


func _is_ultra() -> bool:
	var gfx = CoopSync.gfx
	if not is_instance_valid(gfx):
		return false
	if gfx.has_method("is_ultra"):
		return bool(gfx.call("is_ultra"))
	return int(gfx.get("mode")) == 3


func _read_map_members() -> void:
	_m_bar = map.get("_mat_bar") as StandardMaterial3D
	_m_ruin = map.get("_mat_ruin") as StandardMaterial3D
	_m_cprop = map.get("_mat_crystal_prop") as StandardMaterial3D
	_m_crystal = map.get("_mat_crystal") as StandardMaterial3D
	for key in ["_wall_mat", "_floor_mat", "_dress_mat"]:
		var arr = map.get(key)
		if arr is Array:
			for m in arr:
				if m is Material:
					_rock_ids[(m as Material).get_instance_id()] = true
	var sc = map.get_script()
	if sc is Script:
		var K: Dictionary = (sc as Script).get_script_constant_map()
		for pair in [["EggCluster", "egg"], ["CrystalSpar", "spar"], ["Fragment", "frag"], ["Gate", "gate"], ["Waterfall", "fall"]]:
			var s = K.get(pair[0])
			if s is Script:
				_scripts[(s as Script).get_instance_id()] = pair[1]


func _on_added(n: Node) -> void:
	if not (n is GeometryInstance3D or n is Light3D) or n.has_meta("zonda_proxy"):
		return
	if map == null or not map.is_ancestor_of(n):
		return
	_queue.append([n, Engine.get_process_frames() + SETTLE_FRAMES])


func _on_mode(_m: int) -> void:
	var u := _is_ultra()
	if u == _ultra:
		return
	_ultra = u
	_reapply_all()


func _process(delta: float) -> void:
	if _qi < _queue.size():
		var t0 := Time.get_ticks_usec()
		var budget := PER_FRAME
		var now := Engine.get_process_frames()
		while budget > 0 and _qi < _queue.size():
			var e: Array = _queue[_qi]
			if int(e[1]) > now:
				break
			_qi += 1
			budget -= 1
			var n = e[0]
			if not is_instance_valid(n) or not (n as Node).is_inside_tree():
				continue
			if n is Light3D:
				_do_light(n)
			elif n is GeometryInstance3D:
				_do_geo(n)
		var drained := _qi >= _queue.size()
		if not _sweep_done:
			_sweep_us += Time.get_ticks_usec() - t0
			_sweep_frames += 1
			if _qi >= _init_n:
				_init_wait += 1
			# done when the queue drains, or 120 frames after the map's own nodes are through if
			# runtime traffic (a node added every frame or two) keeps it from ever draining
			if drained or _init_wait > 120:
				_sweep_done = true
				_log_sweep(false)
		# compact: a drained queue is cleared, a long processed head is dropped (runtime traffic that
		# never lets it drain must not grow it without bound)
		if drained or _qi > 512:
			_queue = [] if drained else _queue.slice(_qi)
			_init_n = maxi(0, _init_n - _qi)
			_qi = 0
	# the water runs down its column
	for w in _water:
		var wm := w[0] as StandardMaterial3D
		var o := wm.uv1_offset
		o.y = fposmod(o.y - float(w[1]) * delta, 1.0)
		wm.uv1_offset = o
	# the game's "reduced pixelization" setting, followed once a second (the map re-reads it too)
	_pix_t -= delta
	if _pix_t <= 0.0:
		_pix_t = 1.0
		var p := int(map.get("_pix_mode")) if map != null and map.get("_pix_mode") != null else 0
		if p != _pix:
			var first := _pix == -2
			_pix = p
			if not first:
				_reapply_all()
	if _hold_on:
		_hold()


func _physics_process(_delta: float) -> void:
	if _hold_on:
		_hold()


# ------------------------------------------------------------------ the sweep

func _do_geo(g: GeometryInstance3D) -> void:
	if g.has_meta("zonda_proxy"):
		return                                   # our own shadow-only twin
	var ctx := _context(g)
	if bool(ctx.get("skip", false)):
		return
	_n_geo += 1
	if g.material_override != null:
		var m0: Material = g.material_override
		var m1 := _slot(g, -1, m0, ctx)
		if m1 != m0:
			g.material_override = m1
		_shadow_proxy(g, m1)
		return                                   # an override hides every surface material
	if not (g is MeshInstance3D):
		return
	var mi := g as MeshInstance3D
	if mi.mesh == null:
		return
	var n := mi.mesh.get_surface_count()
	var glass := 0
	for si in n:
		var m: Material = mi.get_surface_override_material(si)
		if m == null:
			m = mi.mesh.surface_get_material(si)
		if m == null:
			continue
		var m2 := _slot(mi, si, m, ctx)
		if m2 != m:
			mi.set_surface_override_material(si, m2)
		if m2 is StandardMaterial3D and str(m2.get_meta("zonda_surf", "")) == "glass":
			glass += 1
	if glass > 0 and glass == n and not _off:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # a pane throws no shadow


func _shadow_proxy(g: GeometryInstance3D, m: Material) -> void:
	# Godot draws a refractive surface in the transparent pass only, which has no shadow pass: the
	# crystal props (and icicles) stopped throwing the lantern's shadow. A shadow-only twin with the
	# same mesh keeps it exactly as before (the same one shadow draw per crystal the opaque build paid).
	if _off or not (g is MeshInstance3D) or g.has_meta("zonda_proxied"):
		return
	if g.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
		return
	if not (m is StandardMaterial3D) or not (m as StandardMaterial3D).refraction_enabled:
		return
	var mi := g as MeshInstance3D
	if mi.mesh == null:
		return
	if _proxy_mat == null:
		_proxy_mat = StandardMaterial3D.new()     # plain opaque: Godot's shared shadow shader
	var p := MeshInstance3D.new()
	p.name = "ZondaShadow"
	p.set_meta("zonda_proxy", true)
	p.mesh = mi.mesh
	p.material_override = _proxy_mat
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	p.visibility_range_begin = mi.visibility_range_begin
	p.visibility_range_end = mi.visibility_range_end
	mi.set_meta("zonda_proxied", true)
	mi.add_child(p)
	_proxies.append([p, m])


const GHOST_FOLIAGE := "res://Art/Foliage_Ghost_CustomBlending.tres"
var _ghost_dup: ShaderMaterial = null


func _slot(node: GeometryInstance3D, _si: int, m: Material, ctx: Dictionary) -> Material:
	# the material this slot should hold: m itself (tuned in place, or left alone) or a copy
	if m is ShaderMaterial and m.resource_path == GHOST_FOLIAGE and not _off:
		# the game's ghost foliage is ADDITIVE: the flame's highlight was added on top as white (09-25
		# test, the Fungal plants). A map-local copy without the highlight; its glow and diffuse stay.
		if _ghost_dup == null:
			_ghost_dup = (m as ShaderMaterial).duplicate()
			_ghost_dup.set_shader_parameter("specular", 0.0)
			_ghost_dup.set_meta("zonda_surf", "ghost_foliage")
		_slots["ghost_foliage"] = int(_slots.get("ghost_foliage", 0)) + 1
		return _ghost_dup
	if not (m is StandardMaterial3D):
		return m
	var sm := _split(node, m as StandardMaterial3D, ctx)
	if sm.has_meta("zonda_surf"):
		var c0 := str(sm.get_meta("zonda_surf"))
		if c0 != "rock_own":
			_slots[c0] = int(_slots.get(c0, 0)) + 1
			if c0 == "rig" and node is MeshInstance3D:
				_eye_check(node as MeshInstance3D, sm)
		return sm
	if _rock_ids.has(sm.get_instance_id()):
		return sm
	if sm.resource_path != "" and _dups.has("res|%d" % sm.get_instance_id()):
		# a shared game resource already copied and tuned: this slot just takes the copy
		var cd: StandardMaterial3D = _dups["res|%d" % sm.get_instance_id()]
		var c1 := str(cd.get_meta("zonda_surf", ""))
		_slots[c1] = int(_slots.get(c1, 0)) + 1
		if c1 == "rig" and node is MeshInstance3D:
			_eye_check(node as MeshInstance3D, cd)
		return cd
	var cls := _classify(sm, node, ctx)
	if cls == "skip":
		_skips += 1
		return sm
	if cls == "":
		var key := "%s@%s" % [sm.resource_name if sm.resource_name != "" else "?", str(sm.get_meta("zonda_rel", ctx.get("rel", sm.resource_path)))]
		_other[key] = int(_other.get(key, 0)) + 1
		return sm
	_slots[cls] = int(_slots.get(cls, 0)) + 1
	if _off:
		_owned[sm.get_instance_id()] = [sm, cls]     # counted only
		return sm
	var out := sm
	if sm.resource_path != "":
		out = _dup("res", sm)
	_own(out, cls)
	_apply(out, cls)
	if cls == "rig" and node is MeshInstance3D:
		_eye_check(node as MeshInstance3D, out)
	return out


func _split(node: GeometryInstance3D, sm: StandardMaterial3D, ctx: Dictionary) -> StandardMaterial3D:
	# a map-local material shared by two classes gets a second copy for the second one
	if _off:
		return sm
	var own := str(sm.get_meta("zonda_surf", ""))
	if own == "ph_wet" or own == "spar_crystal" or own == "iron_thin":
		return sm                              # already a split copy (a node taken out and put back)
	if sm == _m_bar and _thin(node):
		if _bar_thin == null:
			_bar_thin = _m_bar.duplicate()
			_own(_bar_thin, "iron_thin")
			_apply(_bar_thin, "iron_thin")
		return _bar_thin
	if ctx.has("spar") and _mesh_index(node, ctx["spar"]) == 1:
		var k := "spar|%d" % (ctx["spar"] as Node).get_instance_id()
		if not _dups.has(k):
			var c: StandardMaterial3D = sm.duplicate()
			_own(c, "spar_crystal")
			_apply(c, "spar_crystal")
			_dups[k] = c
		return _dups[k]
	# wood in the Drowned is wet whatever the file (all placements of one model share a material,
	# so the Drowned ones get their own copy). Only what would be plain ph_wood: a wooden lantern's
	# glass panes, candles and flame keep their own class.
	var rel := str(sm.get_meta("zonda_rel", ""))
	if rel.begins_with("ext/ph/"):
		var f := rel.get_file().get_basename()
		if PH_WOOD.has(f) and not PH_WET.has(f) and _biome(node) == 4 and _classify(sm, node, ctx) == "ph_wood":
			var k2 := "wet|%d" % sm.get_instance_id()
			if not _dups.has(k2):
				var c2: StandardMaterial3D = sm.duplicate()
				_own(c2, "ph_wet")
				_apply(c2, "ph_wet")
				_dups[k2] = c2
			return _dups[k2]
	return sm


func _context(n: Node) -> Dictionary:
	# one walk up to the map: exclusions and the map object this node belongs to
	var ctx := {}
	var climber = Game.climber
	if map != null and map.get("_flasks") is Array and (map.get("_flasks") as Array).size() != _flask_n:
		_flask_ids.clear()
		for f in map.get("_flasks"):
			if is_instance_valid(f):
				_flask_ids[(f as Object).get_instance_id()] = true
		_flask_n = (map.get("_flasks") as Array).size()
	var a: Node = n
	while a != null and a != map:
		if a == climber:
			ctx["skip"] = true
			return ctx
		var nm := String(a.name)
		if nm.begins_with("CoopRemote_") or nm == "ZondaLantern" or nm == "ZondaHeldIdol":
			ctx["skip"] = true
			return ctx
		if a.scene_file_path == EMBER_SCENE:
			ctx["skip"] = true
			return ctx
		var s = a.get_script()
		if s != null:
			if (s as Script).resource_path == EMBER_SCRIPT:
				ctx["skip"] = true
				return ctx
			var k = _scripts.get((s as Script).get_instance_id())
			if k != null and not ctx.has(k):
				ctx[k] = a
		if _flask_ids.has(a.get_instance_id()):
			ctx["flask"] = a
		if a.has_meta("zonda_painted"):
			ctx["painted"] = true
		if not ctx.has("rel") and a.has_meta("zonda_rel"):
			ctx["rel"] = str(a.get_meta("zonda_rel"))
		a = a.get_parent()
	if a == null:
		ctx["skip"] = true                    # not under the map
	return ctx


func _classify(sm: StandardMaterial3D, node: Node, ctx: Dictionary) -> String:
	# first match wins (design 5.2); "skip" = never ours, "" = unclassified (logged)
	if sm.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED or sm.blend_mode != BaseMaterial3D.BLEND_MODE_MIX:
		return "skip"
	if sm.billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED or sm.specular_mode == BaseMaterial3D.SPECULAR_DISABLED:
		return "skip"
	var rp := sm.resource_path
	if rp == "res://materials/centipede_body.tres" or rp.get_file().begins_with("Knight"):
		return "skip"
	var rn := sm.resource_name
	var rel := str(sm.get_meta("zonda_rel", ctx.get("rel", "")))
	if rn == "brass_candleholders_flame" or (rel.begins_with("ext/quat/") and (rn == "Fire" or rn == "Light")):
		return "skip"                         # painted flames (O4 off)
	var glass := rel.begins_with("ext/") and rn.ends_with("_glass")
	if sm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED and not glass:
		# cut-out foliage, fungus, cards (09-25 test: the Fungal plants were skipped, kept the engine's
		# default shine and burned white under the lantern): matte, never a mirror of the flame
		return "cutout"
	# 1. map and module members
	if sm == _m_ruin:
		return "ruin"
	if sm == _m_bar:
		return "iron"
	if sm == _m_cprop:
		return "crystal"
	if sm == _m_crystal:
		return "icicle"
	var pale = map.get("_pale_mat")
	if pale != null and sm == pale:
		return "pale"
	if map.has_method("feature"):
		var sh = map.call("feature", "shades")
		if sh != null and sh.get("_mat_body") == sm:
			return "shade"
		var he = map.call("feature", "hearth")
		if he != null and he.get("_maw_mat") == sm:
			return "maw"
	# 2. what the node belongs to
	if ctx.has("egg"):
		return "eggs"
	if ctx.has("spar"):
		return "spar_deck" if _mesh_index(node, ctx["spar"]) == 0 else "spar_crystal"
	if ctx.has("frag"):
		return "fragment"
	if ctx.has("gate") and node == (ctx["gate"] as Node).get("door"):
		return "gate"
	if ctx.has("flask"):
		return "flask"
	if bool(ctx.get("painted", false)):
		return "pale"
	# 3. external models by file
	if rel.begins_with("ext/"):
		return _classify_ext(sm, rel, rn, glass)
	# 4. the game's own textures
	var ap := sm.albedo_texture.resource_path if sm.albedo_texture != null else ""
	if ap == "res://Art/Textures/Wall_04.png":
		return "stone_w04"
	if ap == "res://Art/Textures/Rock.png":
		return "rock01"
	if ap == "res://Art/Textures/Wood_Colorized.png" or rp == "res://Art/Textures/Wood_01.tres":
		return "wood01"
	if MONSTER_RES.has(rp) or MONSTER_ALB.has(ap):
		return "monster_bone"
	if ap == "res://Art/Corpse_Painting_BaseColor.png":
		return "corpse"
	if ap == "res://Art/Rope.png" or ap == "res://Art/Rope_Fallen_Rope.png":
		return "rope"
	if ap == "res://Art/Tent_BaseColor.png":
		return "tent"
	if KILN_ALB.has(ap):
		return "kiln"
	# 5. the creature rig material (creatures.gd Kit.make_rig)
	if sm.albedo_texture == null and is_equal_approx(sm.roughness, 0.92) and is_equal_approx(sm.metallic_specular, 0.15):
		return "rig"
	return ""


func _classify_ext(sm: StandardMaterial3D, rel: String, rn: String, glass: bool) -> String:
	var file := rel.get_file().get_basename()
	if glass:
		return "glass"
	if rel.begins_with("ext/ph/"):
		if rn.contains("candles"):
			return "ph_wax"
		if PH_ROCK.has(file):
			return "ph_rock"
		if PH_CERAMIC.has(file):
			return str(PH_CERAMIC[file])
		if PH_METAL.has(file):
			return "ph_metal"
		if file == "wooden_crate_01":
			return "ph_crate"
		if PH_WOOD.has(file):
			return "ph_wet" if PH_WET.has(file) else "ph_wood"
		if sm.metallic_texture != null:
			return "ph_metal"
		return ""
	if rel.begins_with("ext/nature/"):
		if file.begins_with("mushroom"):
			return "kenney_mush"
		if file.begins_with("bed"):
			return "kenney_bed"
		if file.begins_with("canoe"):
			return "kenney_canoe"
		return "kenney_nature"
	if rel.begins_with("ext/graveyard/") or rel.begins_with("ext/dungeon/"):
		if file.begins_with("coffin") or file.contains("wood") or file.begins_with("bench") or file.begins_with("fence"):
			return "kenney_wood"
		return "kenney_stone"
	if rel.begins_with("ext/quat/"):
		if sm.albedo_texture == null and QUAT_STONE_NAMES.has(rn):
			for pre in QUAT_STONE_PREFIX:
				if file.begins_with(pre):
					return "quat_stone"
		if QUAT_BY_NAME.has(rn):
			return str(QUAT_BY_NAME[rn])
		if rn.begins_with("Pot_"):
			return "quat_pot"
		if rn.begins_with("Book"):
			return "quat_book"
		return "quat_wood"                     # anything else on a Quaternius prop: plain matte
	return ""


func _thin(node: Node) -> bool:
	if not (node is MeshInstance3D):
		return false
	var cm := (node as MeshInstance3D).mesh as CylinderMesh
	return cm != null and cm.top_radius <= 0.15


func _mesh_index(node: Node, parent: Node) -> int:
	# index of node among parent's direct MeshInstance3D children (-1 if it is not one)
	var i := 0
	for c in parent.get_children():
		if c is MeshInstance3D:
			if c == node:
				return i
			i += 1
	return -1


func _biome(node: Node) -> int:
	if node is Node3D and map.has_method("biome_at"):
		return int(map.call("biome_at", (node as Node3D).global_position))
	return -1


func _dup(kind: String, src: StandardMaterial3D) -> StandardMaterial3D:
	# one copy per shared source, reused by every slot that held it
	var k := "%s|%d" % [kind, src.get_instance_id()]
	if not _dups.has(k):
		_dups[k] = src.duplicate()
	return _dups[k]


# ------------------------------------------------------------------ profiles (design section 2B)
# keys: r roughness; S0 sheen ratio (solved into metallic_specular) or s (metallic_specular given);
# m metallic via the colour-safe swap (albedo compensated), mr metallic set raw (it changes the
# rendered diffuse, so ULTRA HD only; mr wins over an inherited m); neither = the material's own
# metallic; mtex_off drops the metallic mask; n [gfx normal file, scale] (NP SOFT / UHD full); no =
# keep the model's own normal map at this scale; tri world-triplanar uv scale; uvw uv1_world_triplanar;
# ref [refraction scale, albedo alpha, keep_lit] (keep_lit: an opaque source whose albedo is raised by
# 1 / alpha so its lit colour stays; render_priority -1 always); rim [rim, tint] (rim_keep leaves the
# rim alone); cc [clearcoat, clearcoat roughness]; cull; filter "game" (NEAREST_WITH_MIPMAPS, or linear
# under reduced pixelization) or "linear".
# No key = that feature off: roughness_texture is always null (no roughness maps on owned surfaces).

func _pr(np: Dictionary, uhd_over: Dictionary) -> Dictionary:
	var u := np.duplicate(true)
	for k in uhd_over.keys():
		u[k] = uhd_over[k]
	return {"np": np, "uhd": u}


func _build_profiles() -> Dictionary:
	var P := {}
	var cd := BaseMaterial3D.CULL_DISABLED
	# S2 / S3 game stone on Wall_04 and Rock
	P["stone_w04"] = _pr({"r": 0.84, "S0": 0.25, "m": 0.0, "n": ["Wall_04_n.png", 0.6], "filter": "game"},
			{"r": 0.76, "S0": 0.30, "n": ["Wall_04_n.png", 1.0]})
	P["rock01"] = _pr({"r": 0.84, "S0": 0.25, "m": 0.0, "n": ["Rock_n.png", 0.6], "filter": "game"},
			{"r": 0.76, "S0": 0.30, "n": ["Rock_n.png", 1.0]})
	# S4 village ruins, S5 puzzle gate doors (their texture rides with the sliding door)
	P["ruin"] = _pr({"r": 0.84, "S0": 0.30, "m": 0.0, "n": ["Wall_04_n.png", 0.6], "filter": "game"},
			{"r": 0.76, "n": ["Wall_04_n.png", 1.0]})
	P["gate"] = _pr({"r": 0.84, "S0": 0.30, "m": 0.0, "n": ["Wall_04_n.png", 0.6], "filter": "game", "uvw": false},
			{"r": 0.76, "n": ["Wall_04_n.png", 1.0]})
	# S6 / S7 iron: large (a warm rust-tinted band), thin (a soft sheen, never a 1 px line). NORMAL
	# PIXELS keeps the bars' own metallic 0.2 (0.3 would take 12% of their diffuse)
	P["iron"] = _pr({"r": 0.55, "s": 0.4}, {"mr": 0.45, "r": 0.45})
	P["iron_thin"] = _pr({"r": 0.75, "s": 0.35}, {"mr": 0.3, "r": 0.6})
	# S9 crystal props, S13 icicles (dormant), S10 / S11 the spars
	P["crystal"] = _pr({"ref": [0.015, 0.65, true], "r": 0.62, "s": 0.12, "rim": [0.25, 0.5], "mr": 0.0},
			{"ref": [0.025, 0.65, true], "r": 0.52, "s": 0.15})     # 09-25 test: 0.45 / 0.35 burned the lantern hotspot white
	P["icicle"] = P["crystal"]
	P["spar_deck"] = _pr({"r": 0.5, "s": 0.4}, {"r": 0.35, "s": 0.45})
	P["spar_crystal"] = _pr({"ref": [0.015, 0.65, true], "r": 0.62, "s": 0.12}, {"ref": [0.025, 0.65, true], "r": 0.52, "s": 0.15})
	# S12 gold idol fragments: ULTRA HD turns the gold into a gold-tinted highlight as it spins;
	# NORMAL PIXELS keeps its metallic 0 (0.8 would take 80% of its pale gold diffuse)
	P["fragment"] = _pr({"r": 0.45, "s": 0.5}, {"mr": 0.9, "r": 0.3})
	# S14 Nest eggs: a broad wet sheen over a third of each egg
	P["eggs"] = _pr({"r": 0.8, "S0": 1.2}, {"r": 0.65, "S0": 1.6})     # 09-25 test: specks at 2.0
	# S15-S17, S22, S24 Poly Haven (their own normal maps at 0.6 in NORMAL PIXELS). The metal factor
	# changes (hoops, brass) are ULTRA HD only: in NORMAL PIXELS they would change the diffuse colour
	P["ph_rock"] = _pr({"no": 0.6, "r": 0.82, "S0": 0.30, "m": 0.0}, {"no": 1.0, "r": 0.72, "S0": 0.35})
	P["ph_wood"] = _pr({"no": 0.6, "r": 0.85, "S0": 0.20}, {"no": 1.0, "r": 0.75, "S0": 0.30, "mr": 0.5})
	P["ph_wet"] = _pr({"no": 0.6, "r": 0.7, "S0": 0.5}, {"no": 1.0, "r": 0.6, "S0": 0.6, "mr": 0.5})
	P["ph_crate"] = _pr({"no": 0.6, "r": 0.85, "S0": 0.20, "m": 0.0, "mtex_off": true}, {"no": 1.0, "r": 0.75, "S0": 0.30})
	P["ph_metal"] = _pr({"no": 0.6, "r": 0.58, "s": 0.5}, {"no": 1.0, "mr": 0.8, "r": 0.42})
	P["ph_wax"] = _pr({"no": 0.6, "r": 0.6, "S0": 0.5}, {"no": 1.0, "r": 0.5})
	P["glass"] = _pr({"no": 0.6, "mr": 0.0, "mtex_off": true, "ref": [0.01, 0.3], "r": 0.55, "s": 0.5, "cull": cd},
			{"no": 1.0, "ref": [0.02, 0.3], "r": 0.3})
	P["ph_vase"] = _pr({"no": 0.6, "r": 0.6, "S0": 0.8}, {"no": 1.0, "r": 0.5, "cc": [0.25, 1.0]})
	P["ph_pot"] = _pr({"no": 0.6, "r": 0.65, "S0": 0.6, "m": 0.0, "mtex_off": true}, {"no": 1.0, "r": 0.55})
	P["ph_marble"] = _pr({"no": 0.6, "r": 0.6, "S0": 0.6}, {"no": 1.0, "r": 0.5, "cc": [0.12, 1.0]})
	P["ph_statue"] = _pr({"no": 0.6, "r": 0.85, "S0": 0.25}, {"no": 1.0, "r": 0.75})
	P["ph_clay"] = _pr({"no": 0.6, "r": 0.9, "S0": 0.1}, {"no": 1.0, "r": 0.8})
	# S25 oil flasks: a broad dull oily sheen the lantern finds without a speck
	P["flask"] = _pr({"no": 0.6, "r": 0.85, "S0": 1.0}, {"no": 1.0, "r": 0.7})     # 09-25 test: 4.8 specks/10k at 2.0
	# S26 Kenney nature (O5: metallic 1.0 -> 0). NORMAL PIXELS uses the colour-safe swap: a full metal
	# at roughness 1 renders a quarter of Lambert face-on, so the albedo goes to a quarter (linear) and
	# the lit colour stays while the props gain a diffuse shape, SSIL and a sheen. ULTRA HD sets it raw
	# (the brighter look the design proposed, pending the owner's review).
	var km := {"m": 0.0} if O5_KENNEY_UNMETAL else {}
	var ku := {"mr": 0.0} if O5_KENNEY_UNMETAL else {}
	P["kenney_mush"] = _pr(_merge(km, {"r": 0.7, "S0": 0.5}), _merge(ku, {"r": 0.55, "S0": 0.6}))
	P["kenney_bed"] = _pr(_merge(km, {"r": 0.95, "S0": 0.05}), ku)
	P["kenney_canoe"] = _pr(_merge(km, {"r": 0.82, "S0": 0.2}), ku)
	P["kenney_nature"] = _pr(_merge(km, {"r": 0.85, "S0": 0.2}), ku)
	if not O5_KENNEY_UNMETAL:
		# still fully metal: any sheen on a metal is a mirror of the flame (the Fungal plants burned
		# white in the 09-25 test), so these keep exactly their shipped material
		for k in ["kenney_mush", "kenney_bed", "kenney_canoe", "kenney_nature"]:
			P[k] = _pr({}, {})
	# S27 Kenney graveyard and dungeon (UV1 is the colour atlas: no relief)
	P["kenney_stone"] = _pr({"r": 0.82, "S0": 0.3}, {"r": 0.72})
	P["kenney_wood"] = _pr({"r": 0.88, "S0": 0.15}, {"r": 0.78})
	# S28 Quaternius stonework: untextured, so world-triplanar relief is colour-safe
	P["quat_stone"] = _pr({"tri": 0.11, "n": ["Rock_n.png", 0.5], "filter": "game", "r": 0.84, "S0": 0.3},
			{"n": ["Rock_n.png", 0.8], "filter": "linear", "r": 0.76, "S0": 0.35})
	# S29 Quaternius props (iron kept dielectric: a clean lantern-coloured glint)
	P["quat_skull"] = _pr({"r": 0.7, "S0": 0.4}, {"r": 0.6})
	P["quat_metal"] = _pr({"r": 0.55, "S0": 3.0}, {"r": 0.45})
	P["quat_wood"] = _pr({"r": 0.88, "S0": 0.15}, {"r": 0.78})
	P["quat_wax"] = _pr({"r": 0.6, "S0": 0.5}, {"r": 0.5})
	P["quat_pot"] = _pr({"r": 0.65, "S0": 0.6}, {"r": 0.55})
	P["quat_leaf"] = _pr({"r": 0.9, "S0": 0.1}, {"r": 0.8})
	P["quat_book"] = _pr({"r": 0.95, "S0": 0.05}, {"r": 0.85})
	# S30-S32 the game's wrap-lit props and creatures (wrap kept; roughness >= 0.8 keeps the terminator soft)
	P["monster_bone"] = _pr({"r": 0.85, "S0": 0.3, "filter": "game"}, {"r": 0.75, "S0": 0.4})     # 09-25 test: glints on bone floors
	P["pale"] = _pr({"m": 0.0, "r": 0.8, "S0": 0.4}, {"r": 0.7, "S0": 0.5})
	P["corpse"] = _pr({"r": 0.88, "S0": 0.15, "filter": "game"}, {})
	P["rope"] = _pr({"r": 0.95, "S0": 0.05, "filter": "game"}, {})
	P["tent"] = _pr({"r": 0.95, "S0": 0.05, "filter": "game"}, {})
	# S33 game wood, S34 kilns (their shipped gfx/ maps, soft in NORMAL PIXELS)
	P["wood01"] = _pr({"n": ["Wood_Colorized_n.png", 0.5], "r": 0.85, "S0": 0.25, "filter": "game"},
			{"n": ["Wood_Colorized_n.png", 1.0], "r": 0.78, "S0": 0.30})
	P["kiln"] = _pr({"n": ["Ancient_Kiln_BaseColor_n.png", 0.4], "r": 0.86, "S0": 0.2, "filter": "game"},     # 09-25 test: 2.2 specks/10k
			{"n": ["Ancient_Kiln_BaseColor_n.png", 1.0], "r": 0.72, "S0": 0.35})
	# S35 wall spiders and brood crawlers (wet chitin), O1 eyes. One material covers the thin legs:
	# R1's thin-geometry floor (0.65 in NORMAL PIXELS)
	P["rig"] = _pr({"r": 0.65, "S0": 0.8}, {"r": 0.5, "S0": 1.0})
	P["eye"] = _pr({"r": 0.45, "s": 1.0}, {})
	# S36 Shades (a limb glint was ~50 x white: 1-3 px limbs), S37 the false hearth's maw
	P["shade"] = _pr({"r": 0.65, "s": 0.45, "rim_keep": true}, {"r": 0.4, "s": 0.6})
	P["maw"] = _pr({"r": 0.62, "S0": 0.8, "rim": [0.3, 0.3]}, {"r": 0.55, "cc": [0.15, 1.0]})
	# S19 the water inside the falls (our own material)
	P["water"] = _pr({"ref": [0.02, 0.3], "r": 0.55, "s": 0.5, "wn": 0.4}, {"ref": [0.03, 0.3], "r": 0.4})
	# see-through cut-outs (plants, fungus, cards): fully matte, any accidental metal swapped out
	# colour-safe, their own relief kept
	P["cutout"] = _pr({"r": 1.0, "s": 0.0, "m": 0.0, "keep_n": true}, {"r": 0.95, "s": 0.05, "m": 0.0, "keep_n": true})
	return P


static func _merge(a: Dictionary, b: Dictionary) -> Dictionary:
	var o := a.duplicate(true)
	for k in b.keys():
		o[k] = b[k]
	return o


func _profile(cls: String) -> Dictionary:
	var e = _prof.get(cls)
	if not (e is Dictionary):
		return {}
	return (e as Dictionary).get("uhd" if _ultra else "np", {})


# ------------------------------------------------------------------ applying a profile

func _own(m: StandardMaterial3D, cls: String) -> void:
	m.set_meta("zonda_surf", cls)
	if not m.has_meta("zonda_alb0"):
		m.set_meta("zonda_alb0", m.albedo_color)
		m.set_meta("zonda_m0", _eff_metal(m))
		m.set_meta("zonda_mf0", m.metallic)          # the raw factor, put back where a mode has no metal key
		m.set_meta("zonda_r0", m.roughness)
		m.set_meta("zonda_rp0", m.render_priority)
		if m.normal_enabled and m.normal_texture != null:
			m.set_meta("zonda_n0", m.normal_texture)
	_owned[m.get_instance_id()] = [m, cls]


func _eff_metal(m: StandardMaterial3D) -> float:
	# metallic as rendered on average: a glTF metal mask scales the factor by its mean
	if m.metallic_texture != null:
		return m.metallic * float(m.metallic_texture.get_meta("zonda_mean_b", 1.0))
	return m.metallic


func _apply(m: StandardMaterial3D, cls: String) -> void:
	var p := _profile(cls)
	if p.is_empty():
		return
	var r := float(p.get("r", m.roughness))
	m.roughness_texture = null
	m.roughness = r
	# metal: a raw value (mr, ULTRA HD only; it wins over an m inherited from NORMAL PIXELS), the
	# colour-safe swap (m), or neither: the material's own metallic and colour back if we changed them
	var a0: Color = m.get_meta("zonda_alb0", m.albedo_color)
	var base := a0                             # the albedo this mode's metal step leaves (never compounded)
	if p.has("mr"):
		_set_metal(m, float(p["mr"]), false, bool(p.get("mtex_off", false)))
		base = m.albedo_color
	elif p.has("m"):
		_set_metal(m, float(p["m"]), true, bool(p.get("mtex_off", false)))
		base = m.albedo_color
	elif m.has_meta("zonda_mset"):
		m.remove_meta("zonda_mset")
		m.metallic = float(m.get_meta("zonda_mf0", m.metallic))
		m.albedo_color = Color(a0.r, a0.g, a0.b, m.albedo_color.a)
		base = m.albedo_color
	# relief
	var nf = p.get("n")
	if nf is Array:
		var t := _gfx_normal(str(nf[0]))
		m.normal_enabled = t != null
		m.normal_texture = t
		m.normal_scale = float(nf[1])
	elif p.has("no"):
		var t0: Texture2D = m.get_meta("zonda_n0") if m.has_meta("zonda_n0") else null
		m.normal_enabled = t0 != null
		m.normal_texture = t0
		m.normal_scale = float(p["no"])
	elif not p.has("wn") and not p.has("keep_n"):
		m.normal_enabled = false
		m.normal_texture = null
	if p.has("tri"):
		var s := float(p["tri"])
		m.uv1_triplanar = true
		m.uv1_world_triplanar = true
		m.uv1_scale = Vector3(s, s, s)
	if p.has("uvw"):
		m.uv1_world_triplanar = bool(p["uvw"])
	# refraction: real, where it is physically right (crystal, glass, water). Godot's refraction draws
	# ALBEDO x alpha lit plus (1 - alpha) of the screen behind, in the transparent pass with depth
	# writes forced on. render_priority -1 draws it first there, so alpha billboards behind or inside
	# it (spar tip glints, waterfall spray) depth-test against it as they did against the opaque
	# crystal instead of being painted over; keep_lit raises an opaque source's albedo by 1 / alpha
	# (linear) so its lit colour is exactly what it was and the refraction only adds transmitted light.
	var rf = p.get("ref")
	if rf is Array:
		var ra := float(rf[1])
		m.refraction_enabled = true
		m.refraction_scale = float(rf[0])
		m.refraction_texture = _white_tex()
		m.refraction_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
		m.render_priority = -1
		var c := Color(base.r, base.g, base.b, 1.0)
		if (rf as Array).size() > 2 and bool(rf[2]) and ra > 0.01:
			var l := c.srgb_to_linear()
			c = Color(l.r / ra, l.g / ra, l.b / ra, 1.0).linear_to_srgb()
		c.a = ra
		m.albedo_color = c
	else:
		if m.refraction_enabled:
			m.render_priority = int(m.get_meta("zonda_rp0", 0))
			m.albedo_color = Color(base.r, base.g, base.b, a0.a)
		m.refraction_enabled = false
	if not bool(p.get("rim_keep", false)):
		var rim = p.get("rim")
		m.rim_enabled = rim is Array
		if rim is Array:
			m.rim = float(rim[0])
			m.rim_tint = float(rim[1])
	var cc = p.get("cc")
	m.clearcoat_enabled = cc is Array
	if cc is Array:
		m.clearcoat = float(cc[0])
		m.clearcoat_roughness = float(cc[1])
	if p.has("cull"):
		m.cull_mode = int(p["cull"])
	var fl := str(p.get("filter", ""))
	if fl == "game":
		m.texture_filter = _game_filter()
	elif fl == "linear":
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	if p.has("s"):
		m.metallic_specular = float(p["s"])
	elif p.has("S0"):
		m.metallic_specular = _solve(m, r, float(p["S0"]))


func _set_metal(m: StandardMaterial3D, m_new: float, comp: bool, tex_off: bool) -> void:
	# design 1.4: where a stone or wood is metallic only by accident, the swap keeps
	# albedo x (1 - metallic) (the rendered diffuse and ambient) the same by darkening albedo_color.
	# Always computed from the originals, so it never compounds.
	# A full metal (m0 1, the Kenney nature data bug) has no diffuse to keep; at roughness 1 under a
	# light at the eye it renders F0 / (4 pi) face-on, a quarter of Lambert's A / pi, so the swap
	# takes the albedo to a quarter (linear): the lit colour face-on stays what it was.
	var m0 := float(m.get_meta("zonda_m0", m.metallic))
	var a0: Color = m.get_meta("zonda_alb0", m.albedo_color)
	var k := 1.0
	var out := Color(a0.r, a0.g, a0.b, m.albedo_color.a)
	if comp and m_new < m0 and m0 < 0.999:
		k = pow((1.0 - m0) / (1.0 - m_new), 1.0 / 2.2)
		out = Color(a0.r * k, a0.g * k, a0.b * k, m.albedo_color.a)
	elif comp and m_new < m0 and float(m.get_meta("zonda_r0", 0.0)) >= 0.999:
		var l := Color(a0.r, a0.g, a0.b, 1.0).srgb_to_linear()
		var q := 0.25 / maxf(0.05, 1.0 - m_new)
		out = Color(l.r * q, l.g * q, l.b * q, 1.0).linear_to_srgb()
		out.a = m.albedo_color.a
		k = q
	if tex_off:
		m.metallic_texture = null
	m.metallic = m_new
	m.albedo_color = out
	m.set_meta("zonda_mset", true)
	if k < 0.9999:
		_comp[m.get_instance_id()] = true


func _albedo_lum(m: StandardMaterial3D) -> float:
	var t := 1.0
	if m.albedo_texture != null:
		t = float(m.albedo_texture.get_meta("zonda_lum", TEX_LUM.get(m.albedo_texture.resource_path, 0.1)))
	var c := m.albedo_color.srgb_to_linear()
	return t * (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b)


func _solve(m: StandardMaterial3D, r: float, s0: float) -> float:
	# metallic_specular so the lantern's face-on highlight is s0 x the lit diffuse (design 1.2)
	var a := _albedo_lum(m) * (1.0 - _eff_metal(m))
	if m.diffuse_mode == BaseMaterial3D.DIFFUSE_LAMBERT_WRAP:
		a /= 1.0 + r                          # wrap lighting: face-on diffuse is 1 / (1 + r) of Lambert
	return clampf(sqrt(maxf(0.0, s0 * a * pow(r, 4.0) / 0.04)), 0.0, 1.0)


func _gfx_normal(file: String) -> Texture2D:
	# the map's cached gfx/ normal maps: SOFT in NORMAL PIXELS, full in ULTRA HD
	if map != null and map.has_method("rock_normal"):
		return map.call("rock_normal", file, not _ultra)
	return null


func _game_filter() -> int:
	var p := int(map.get("_pix_mode")) if map != null and map.get("_pix_mode") != null else 0
	if p == 1:
		return BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	return BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS


func _white_tex() -> ImageTexture:
	# explicit refraction mask: full strength everywhere (red channel)
	if _white == null:
		var b := PackedByteArray()
		b.resize(4 * 4 * 3)
		b.fill(255)
		_white = ImageTexture.create_from_image(Image.create_from_data(4, 4, false, Image.FORMAT_RGB8, b))
	return _white


func _reapply_all() -> void:
	if _off:
		return
	for e in _owned.values():
		var m = e[0]
		if is_instance_valid(m) and not (m as StandardMaterial3D).has_meta("zonda_water"):
			_apply(m, str(e[1]))
	for d in _ice:
		if is_instance_valid(d) and _ice_orm.size() == 2:
			(d as Decal).texture_orm = _ice_orm[1 if _ultra else 0]
	for w in _water:
		_apply(w[0], "water")
	# a shadow twin only while its surface refracts (an opaque one casts its own shadow again)
	for pe in _proxies:
		if is_instance_valid(pe[0]) and is_instance_valid(pe[1]):
			(pe[0] as Node3D).visible = (pe[1] as BaseMaterial3D).refraction_enabled
	_apply_eyes()


# ------------------------------------------------------------------ O1: spider and crawler eye shine

func _eye_check(mi: MeshInstance3D, rig_mat: StandardMaterial3D) -> void:
	if _off or _eye_seen.has(mi.get_instance_id()) or mi.mesh == null:
		return
	_eye_seen[mi.get_instance_id()] = true
	var eyes := {}
	for si in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_material(si) as StandardMaterial3D
		if src == null:
			continue
		var c := src.albedo_color
		if c.r > 0.2 and c.r > 3.0 * c.g and c.r > 3.0 * c.b:
			var e := StandardMaterial3D.new()
			e.albedo_color = c                     # their own red
			_own(e, "eye")
			_apply(e, "eye")
			eyes[si] = e
	if eyes.is_empty():
		return
	_eyes.append([mi, rig_mat, eyes])
	_apply_eyes()


func _apply_eyes() -> void:
	var on := O1_EYE_SHINE_UHD if _ultra else O1_EYE_SHINE_NP
	for e in _eyes:
		var mi = e[0]
		if not is_instance_valid(mi) or (mi as MeshInstance3D).mesh == null:
			continue
		var m := mi as MeshInstance3D
		var eyes: Dictionary = e[2]
		if on:
			for si in m.mesh.get_surface_count():
				m.set_surface_override_material(si, eyes[si] if eyes.has(si) else e[1])
			m.material_override = null
		else:
			m.material_override = e[1]
			for si in m.mesh.get_surface_count():
				m.set_surface_override_material(si, null)


# ------------------------------------------------------------------ lights

func _do_light(l: Light3D) -> void:
	_n_light += 1
	var want := 0.35                          # flames and warm sources
	var kind := "warm"
	if l.has_meta("zonda_keep"):
		if _under_lantern(l):
			_lights["kept"] = int(_lights["kept"]) + 1
			return                            # lanterns: lantern.gd / remote_player.gd own them
		kind = "glow"                         # idol glows and the like: never above a flame
	elif l is DirectionalLight3D:
		want = 0.0                            # a fixed direction would put one uniform sheen on every wet wall
		kind = "dir"
	elif l.has_meta("zonda_no_shadow"):
		want = 0.15                           # fills: the lantern owns the sheen (and the cyan specks go)
		kind = "fill"
	_lights[kind] = int(_lights[kind]) + 1
	if not _off:
		l.light_specular = minf(l.light_specular, want)


func _under_lantern(n: Node) -> bool:
	var a := n.get_parent()
	for i in 4:
		if a == null:
			return false
		if String(a.name) == "ZondaLantern":
			return true
		a = a.get_parent()
	return false


# ------------------------------------------------------------------ new glossy / refractive geometry

func _build_ice() -> void:
	# S18: the ice shelves were invisible. A decal per shelf flattens the rock relief under it into a
	# smooth sheet (flat normal) with a lower roughness (ORM); albedo_mix 0: colours untouched, the
	# albedo texture's alpha only masks it (soft 30% edge). A decal cannot change metallic_specular:
	# the floor keeps the value solved for its own roughness (Crystal Veins r 0.72, S0 0.55), so the
	# ice's sheen ratio is S0 x (0.72 / r_ice)^4: r 0.62 gives ~1.0 in NORMAL PIXELS (0.55 would be 1.6,
	# a clipped white disc), r 0.55 ~1.6 in ULTRA HD (filmic). Decals are not drawn in the
	# normal-roughness prepass, so SSR does not see the ice (the sheen is the lantern's alone).
	var ice: Array = map.get("L").get("ice", []) if map.get("L") is Dictionary else []
	if ice.is_empty():
		return
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.7, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 0)])
	var mask := GradientTexture2D.new()
	mask.gradient = g
	mask.fill = GradientTexture2D.FILL_RADIAL
	mask.fill_from = Vector2(0.5, 0.5)
	mask.fill_to = Vector2(0.5, 0.0)
	mask.width = 64
	mask.height = 64
	_ice_orm = [_solid_tex(255, 158, 0), _solid_tex(255, 140, 0)]    # AO 1, roughness 0.62 / 0.55, metal 0
	var flat := _solid_tex(128, 128, 255)
	for e in ice:
		if not (e is Dictionary) or not (e as Dictionary).has("pos"):
			continue
		var p: Array = e["pos"]
		var r := float(e.get("r", 4.5))
		var d := Decal.new()
		d.name = "ZondaIce"
		d.size = Vector3(2.0 * r, 3.0, 2.0 * r)
		d.texture_albedo = mask
		d.texture_normal = flat
		d.texture_orm = _ice_orm[1 if _ultra else 0]
		d.albedo_mix = 0.0
		d.normal_fade = 0.5
		d.cull_mask = 1
		d.distance_fade_enabled = true
		d.distance_fade_begin = 90.0
		d.distance_fade_length = 20.0
		d.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
		map.add_child(d)
		_ice.append(d)


func _solid_tex(r: int, g: int, b: int) -> ImageTexture:
	var d := PackedByteArray()
	for i in 16:
		d.append(r)
		d.append(g)
		d.append(b)
	return ImageTexture.create_from_image(Image.create_from_data(4, 4, false, Image.FORMAT_RGB8, d))


func _build_falls() -> void:
	# S19: a lit, refractive water core inside every waterfall. A cylinder under a head lamp gives a
	# vertical glint stripe and lens-like refraction; the billboard spray around it stays unshaded.
	# Refraction writes depth and reads a screen copy of the opaque scene only, so the core is thin
	# (r 0.6 inside the spray's +-2.2 m box: about 6% of it, not the 52% an r 1.8 column swallowed)
	# and drawn before the spray (render_priority -1, _apply): spray in front of it or beside it
	# always draws, spray behind it hides behind the water, and nothing pops as the sort changes.
	for n in map.get_children():
		var s = n.get_script()
		if s == null or _scripts.get((s as Script).get_instance_id()) != "fall":
			continue
		var top = n.get("top")
		var h := float(n.get("height")) if n.get("height") != null else 30.0
		if not (top is Vector3) or h <= 0.5:
			continue
		var hk := int(round(h))
		if not _water_mats.has(hk):
			_water_mats[hk] = _water_material(h)
		var cm := CylinderMesh.new()
		cm.top_radius = 0.6
		cm.bottom_radius = 0.6
		cm.height = h + 2.0
		cm.cap_top = false
		cm.cap_bottom = false
		cm.radial_segments = 16
		cm.rings = 4
		var mi := MeshInstance3D.new()
		mi.name = "ZondaWater"
		mi.mesh = cm
		mi.material_override = _water_mats[hk]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = 200.0
		mi.position = (top as Vector3) - Vector3(0.0, h * 0.5, 0.0)
		(n as Node).add_child(mi)
		_n_water += 1


func _water_material(h: float) -> StandardMaterial3D:
	var fn := FastNoiseLite.new()
	fn.frequency = 0.04
	fn.fractal_octaves = 2
	var nt := NoiseTexture2D.new()
	nt.width = 64
	nt.height = 128
	nt.seamless = true
	nt.as_normal_map = true
	nt.bump_strength = 4.0
	nt.generate_mipmaps = true
	nt.noise = fn
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.09, 0.12, 0.13, 0.3)        # the spray particles' own tint
	m.cull_mode = BaseMaterial3D.CULL_BACK
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	m.normal_enabled = true
	m.normal_texture = nt
	m.normal_scale = 0.4
	m.uv1_scale = Vector3(1.0, h / 4.0, 1.0)             # one repeat round the thin core: ripples about the size they were on r 1.8
	m.set_meta("zonda_water", true)
	_own(m, "water")
	_apply(m, "water")
	# one texture repeat spans (h + 2) / (h / 4) metres down the column; the water falls ~2.4 m/s
	var rep := (h + 2.0) / maxf(0.1, h / 4.0)
	_water.append([m, 2.4 / rep])
	return m


# ------------------------------------------------------------------ logging

func _log_sweep(detail: bool) -> void:
	var slots := 0
	for k in _slots.keys():
		slots += int(_slots[k])
	var classes := {}
	for e in _owned.values():
		classes[str(e[1])] = true
	print("[SURF] sweep: %d geometry, %d lights, %d materials in %d classes, %d copies of game resources, %d albedo-compensated, %d ms over %d frames%s" % [
		_n_geo, _n_light, _owned.size(), classes.size(), _dups.size(), _comp.size(), int(_sweep_us / 1000), _sweep_frames,
		" (off: counted only, nothing changed)" if _off else ""])
	print("[SURF] built: %d ice decals, %d water columns, %d refraction shadow twins, %d eye-shine rigs (eyes %s in this mode)" % [
		_ice.size(), _n_water, _proxies.size(), _eyes.size(), "on" if (O1_EYE_SHINE_UHD if _ultra else O1_EYE_SHINE_NP) else "off"])
	if not detail:
		return
	var mats := {}
	for e in _owned.values():
		mats[str(e[1])] = int(mats.get(str(e[1]), 0)) + 1
	var names: Array = _slots.keys()
	names.sort()
	for k in names:
		print("[SURF] class %s: %d materials, %d slots" % [k, int(mats.get(k, 0)), int(_slots[k])])
	var oth: Array = _other.keys()
	oth.sort_custom(func(a, b): return int(_other[a]) > int(_other[b]))
	var parts: Array = []
	for i in mini(20, oth.size()):
		parts.append("%s x%d" % [oth[i], int(_other[oth[i]])])
	print("[SURF] unclassified (%d kinds, %d skipped as unshaded/additive/billboard/transparent): %s" % [oth.size(), _skips, ", ".join(parts)])
	print("[SURF] lights: %d fills -> 0.15, %d warm -> 0.35, %d glows -> 0.35, %d directional -> 0.0, %d kept (lanterns)" % [
		int(_lights["fill"]), int(_lights["warm"]), int(_lights["glow"]), int(_lights["dir"]), int(_lights["kept"])])


# ============================================================================ dev test (5.9)

var _t_on := false
var _t_modes: Array = ["np"]
var _t_f4 := false
var _t_filter: Array = []
var _t_saved: Dictionary = {}
var _t_restored := true
var _t_fails: Array = []
var _hold_on := false
var _hold_pos := Vector3.ZERO
var _hold_look := Vector3.ZERO
var _eye_off := Vector3(0, 1.5, 0)
var _t_base: Dictionary = {}
var _t_new_base: Dictionary = {}
var _t_gpu_sum: Dictionary = {}       # mode -> [sum, n] over all spots, for the mean gate

const ROCK_STOPS := ["along THE MOUTH 81 m", "along OSSUARY 447 m", "along FUNGAL HOLLOW 1085 m",
		"along ROOTWORKS 1583 m", "along DROWNED GALLERIES 1864 m", "along SUNKEN VILLAGE 2750 m",
		"along CRYSTAL VEINS 3155 m", "along THE FOUNDRY 3833 m", "The Nest", "burrows 58 m", "The Ribs", "Root 1"]
const OBJECT_STOPS := [["spar 1 deck", "glossy"], ["spar 1 under", "glossy"], ["nest eggs", "glossy"], ["rod 2 close", "obj"]]
# [label, scene substring, kind]; kind: rock >= 3% sheen gain, glossy >= 8%, obj > 0
const PROP_SPOTS := [["wooden_lantern", "ext/ph/wooden_lantern_01", "glossy"], ["brass_candleholders", "ext/ph/brass_candleholders", "glossy"],
		["namaqualand_boulder", "ext/ph/namaqualand_boulder", "rock"], ["ceramic_pot", "ext/ph/ceramic_pot", "glossy"],
		["wooden_bucket_02", "ext/ph/wooden_bucket_02", "glossy"], ["mushroom_red", "ext/nature/mushroom_red", "glossy"],
		["quat_skull", "ext/quat/Skull", "rock"], ["quat_column", "ext/quat/Column_Round", "rock"],
		["gravestone", "ext/graveyard/gravestone", "rock"], ["monster_bone", "Monster_BodySection", "rock"],
		["stone_04", "Stone_04", "rock"], ["rock_01", "Rock_01", "rock"], ["village_building", "Village_Building", "rock"]]
const CLIP_OK := ["crystal", "wooden_lantern", "fragment", "The Ribs"]     # a flash there is intended


func _arm_test(txt: String) -> void:
	_t_on = true
	_t_modes = ["np"]
	for w0 in txt.split(","):
		var w := w0.strip_edges()
		if w == "" or w == "1" or w == "x":
			continue
		if w == "ultra":
			_t_modes = ["uhd"]
		elif w == "both":
			_t_modes = ["np", "uhd"]
		elif w == "off":
			_off = true
		elif w == "f4":
			_t_f4 = true
		else:
			_t_filter.append(w)
	print("[SURF] test armed: modes %s%s%s%s" % [str(_t_modes), " OFF (baseline)" if _off else "", " +f4" if _t_f4 else "",
		(" spots " + str(_t_filter)) if not _t_filter.is_empty() else ""])


func _cl() -> Node3D:
	var c = Game.climber
	if is_instance_valid(c) and (c as Node).is_inside_tree():
		return c
	return null


func _cam() -> Node3D:
	var c := _cl()
	if c == null:
		return null
	var cam = c.get("Camera")
	return cam if cam is Node3D else null


func _wait(secs: float) -> void:
	await get_tree().create_timer(secs, true, false, true).timeout


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _test_ready() -> bool:
	if _cl() == null or _cam() == null or not _sweep_done:
		return false
	if map.has_method("load_announced") and not bool(map.call("load_announced")):
		return false
	if CoopSync.has_method("save_prompt_open") and bool(CoopSync.call("save_prompt_open")):
		return false
	return true


func _run_test() -> void:
	while is_inside_tree() and not _test_ready():
		await _frames(1)
	if not is_inside_tree():
		return
	await _wait(3.0)                          # the load banner goes
	if not is_inside_tree():
		return
	_log_sweep(true)
	print("[SURF] load: map built in %d ms (external model mipmaps %d ms), sweep %d ms over %d frames" % [
		int(map.get("built_ms")) if map.get("built_ms") != null else -1, int(map.get("ext_mip_ms")) if map.get("ext_mip_ms") != null else -1,
		int(_sweep_us / 1000), _sweep_frames])
	_t_base = _read_base()
	_test_prepare()
	var spots := _spots()
	print("[SURF] %d spots" % spots.size())
	var orig_ultra := _is_ultra()
	for mode in _t_modes:
		if not is_inside_tree():
			return
		await _set_gfx(mode == "uhd")
		var i := 0
		for sp in spots:
			i += 1
			if not is_inside_tree():
				return
			await _shoot(sp, i, str(mode))
		var gs: Array = _t_gpu_sum.get(mode, [0.0, 0])
		var bm: Dictionary = _t_base.get(mode, {})
		if int(gs[1]) > 0 and not _off and bm.has("_mean"):
			var mean := float(gs[0]) / float(gs[1])
			var lim := float(bm["_mean"]) * 1.03
			print("[SURF] %s GPU mean over spots %.2f ms (off run %.2f ms)" % [_mode_name(str(mode)), mean, float(bm["_mean"])])
			if mean > lim:
				_t_fails.append("%s mean gpu %.2f > %.2f" % [mode, mean, lim])
		if _off and int(gs[1]) > 0:
			var nb: Dictionary = _t_new_base.get(mode, {})
			nb["_mean"] = float(gs[0]) / float(gs[1])
			_t_new_base[mode] = nb
	if _t_f4 and is_inside_tree():
		await _f4_check()
	if is_inside_tree():
		await _set_gfx(orig_ultra)
	# map load against the off run
	var load_ms := (int(map.get("built_ms")) if map.get("built_ms") != null else 0) + int(_sweep_us / 1000)
	if _off:
		_t_new_base["load_ms"] = load_ms
		_write_base()
	elif _t_base.has("load_ms"):
		print("[SURF] load %d ms (off run %d ms)" % [load_ms, int(_t_base["load_ms"])])
		if load_ms > int(_t_base["load_ms"]) + 1500:
			_t_fails.append("load %d ms > off run + 1500" % load_ms)
	else:
		print("[SURF] no off-run baseline (user://surf_base.json): GPU and load gates skipped; run surfaces.flag 'off' first")
	if _t_fails.is_empty():
		print("[SURF] RESULT pass")
	else:
		for f in _t_fails:
			print("[SURF] RESULT fail: %s" % f)
	_test_restore()
	print("[SURF] done")


func _mode_name(mode: String) -> String:
	return "ULTRA HD" if mode == "uhd" else "NORMAL PIXELS"


func _test_prepare() -> void:
	_t_restored = false
	var c := _cl()
	var ln = CoopSync.lantern
	_t_saved["bright"] = int(map.get("_bright_i")) if map.get("_bright_i") != null else 0
	if is_instance_valid(ln):
		# recorded BEFORE set_light_mode: _set_bright resets the lantern's user choice (and saves it)
		_t_saved["user"] = ln.get("user")
		_t_saved["default_on"] = ln.get("default_on")
		_t_saved["oil"] = ln.get("oil")
	if map.has_method("set_light_mode"):
		map.call("set_light_mode", 0)
	if is_instance_valid(ln):
		ln.set("user", 1)
		if bool(ln.get("oil_enabled")):
			ln.set("oil", 1.0)
		ln.set("test_hold_f", 0.8)
		ln.set("test_spec_k", 1.0)
	var we = map.get("_weather")
	if we != null:
		_t_saved["weather"] = bool(we.get("enabled"))
		we.set("enabled", false)
	if c != null:
		_t_saved["ppd"] = bool(c.get("prevent_player_death"))
		c.set("prevent_player_death", true)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	# where the camera sits relative to the climber (to put the camera itself on a spot)
	var cam := _cam()
	if c != null and cam != null:
		_eye_off = cam.global_position - c.global_position


func _test_restore() -> void:
	if _t_restored:
		return
	_t_restored = true
	_hold_on = false
	var ln = CoopSync.lantern
	if map != null and is_instance_valid(map) and map.has_method("set_light_mode") and _t_saved.has("bright"):
		map.call("set_light_mode", int(_t_saved["bright"]))
	if is_instance_valid(ln):
		ln.set("test_hold_f", -1.0)
		ln.set("test_spec_k", 1.0)
		if _t_saved.has("user"):
			ln.set("user", int(_t_saved["user"]))
			ln.set("default_on", bool(_t_saved["default_on"]))
			if ln.has_method("_save"):
				ln.call("_save")
		if _t_saved.has("oil") and bool(ln.get("oil_enabled")):
			ln.set("oil", float(_t_saved["oil"]))
	if map != null and is_instance_valid(map):
		var we = map.get("_weather")
		if we != null and _t_saved.has("weather"):
			we.set("enabled", bool(_t_saved["weather"]))
	var c := _cl()
	if c != null and _t_saved.has("ppd"):
		c.set("prevent_player_death", bool(_t_saved["ppd"]))
	if is_inside_tree():
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), false)


func _set_gfx(ultra: bool) -> void:
	if _is_ultra() == ultra:
		return
	var gfx = CoopSync.gfx
	if not is_instance_valid(gfx) or not gfx.has_method("set_mode"):
		print("[SURF] no gfx.set_mode: staying in %s" % ("ULTRA HD" if _is_ultra() else "NORMAL PIXELS"))
		return
	gfx.call("set_mode", 3 if ultra else 0)
	await _wait(4.0)                          # gfx rescans, look_ultra dresses the rock, FSR settles


# ---- spots

func _spots() -> Array:
	var out: Array = []
	var L = map.get("L")
	if not (L is Dictionary):
		return out
	var tour: Array = (L as Dictionary).get("tour", [])
	for lb in ROCK_STOPS:
		var s = _tour_stop(tour, lb)
		if s != null:
			out.append({"label": lb, "kind": "rock", "stand": map.call("_v", s["pos"]), "target": map.call("_v", s["look"])})
	for pair in OBJECT_STOPS:
		var s2 = _tour_stop(tour, pair[0])
		if s2 != null:
			out.append({"label": pair[0], "kind": pair[1], "stand": map.call("_v", s2["pos"]), "target": map.call("_v", s2["look"])})
	var objs := [["crystal", "crystals", "glossy"], ["ice", "ice", "glossy"], ["falls", "falls", "glossy"], ["kiln", "kilns", "rock"],
			["fragment", "fragments", "glossy"], ["oil", "oil", "glossy"]]
	for o in objs:
		var arr: Array = (L as Dictionary).get(o[1], [])
		if not arr.is_empty() and arr[0] is Dictionary and (arr[0] as Dictionary).has("pos"):
			var t: Vector3 = map.call("_v", arr[0]["pos"]) + Vector3(0, 0.4, 0)
			if o[0] == "falls":
				t = map.call("_v", arr[0]["pos"]) - Vector3(0, 3.0, 0)      # the column under its top, not the lip
			out.append({"label": o[0], "kind": o[2], "target": t})
	var gates: Array = (L as Dictionary).get("gates", [])
	if not gates.is_empty() and (gates[0] as Dictionary).has("front"):
		out.append({"label": "gate", "kind": "rock", "stand": map.call("_v", gates[0]["front"]), "target": map.call("_v", gates[0]["pos"])})
	for kind in ["iron", "wood"]:
		for p in (L as Dictionary).get("platforms", []):
			if str(p.get("kind", "")) == kind:
				out.append({"label": "platform_" + kind, "kind": "glossy" if kind == "iron" else "rock", "target": map.call("_v", p["pos"]) + Vector3(0, 0.4, 0)})
				break
	var spiders: Array = (L as Dictionary).get("spiders", [])
	if not spiders.is_empty() and (spiders[0] as Dictionary).has("anchor"):
		out.append({"label": "spider", "kind": "glossy", "target": map.call("_v", spiders[0]["anchor"])})
	# a Shade up close (the design's worst speck source: 1 to 3 px limbs). Aimed at its chest when the
	# spot is shot (its home snaps onto the rock once a player is near; the lantern freezes it)
	var shm = map.call("feature", "shades") if map.has_method("feature") else null
	if shm != null and shm.get("shades") is Array and not (shm.get("shades") as Array).is_empty():
		var s0 = (shm.get("shades") as Array)[0]
		if s0 is Node3D:
			out.append({"label": "shade", "kind": "obj", "target": (s0 as Node3D).global_position + Vector3(0, 1.6, 0), "node": s0})
	var props: Array = (L as Dictionary).get("props", [])
	for ps in PROP_SPOTS:
		for p in props:
			if str(p.get("scene", "")).contains(ps[1]):
				out.append({"label": ps[0], "kind": ps[2], "target": map.call("_v", p["pos"]) + Vector3(0, 0.4, 0)})
				break
	if not _t_filter.is_empty():
		var keep: Array = []
		for s3 in out:
			for f in _t_filter:
				if str(s3["label"]).begins_with(str(f)):
					keep.append(s3)
					break
		out = keep
	return out


func _tour_stop(tour: Array, label: String):
	for s in tour:
		if s is Dictionary and str(s.get("label", "")) == label and s.has("pos") and s.has("look"):
			return s
	return null


func _cam_spot(t: Vector3):
	# 8 directions x 3 distances around the target; the first camera point with a clear line to it
	var w := get_viewport().get_world_3d()
	if w == null:
		return null
	var space := w.direct_space_state
	for d in [3.0, 2.0, 4.5]:
		for k in 8:
			var a := TAU * float(k) / 8.0
			var p := t + Vector3(cos(a) * d, 1.2, sin(a) * d)
			var q := PhysicsRayQueryParameters3D.create(t + Vector3(0, 0.6, 0), p, 1)
			if space.intersect_ray(q).is_empty():
				# and the climber's body under the camera is not buried in rock
				var q2 := PhysicsRayQueryParameters3D.create(p, p - _eye_off, 1)
				if space.intersect_ray(q2).is_empty():
					return p
	return null


func _hold() -> void:
	var c := _cl()
	if c == null:
		return
	c.velocity = Vector3.ZERO
	if "AirVelocity" in c:
		c.set("AirVelocity", Vector3.ZERO)
	c.global_position = _hold_pos
	var cam := _cam()
	if cam == null:
		return
	var dir := _hold_look - cam.global_position
	if dir.length() < 0.01:
		return
	dir = dir.normalized()
	var ang := Vector3(asin(clampf(dir.y, -0.999, 0.999)), atan2(-dir.x, -dir.z), 0.0)
	var pc = c.get("PlayerCamera")
	if pc != null and pc.has_method("set_camera_rotation"):
		pc.call("set_camera_rotation", ang)
	c.global_rotation = Vector3.ZERO


func _shoot(sp: Dictionary, idx: int, mode: String) -> void:
	var label := str(sp["label"])
	var target: Vector3 = sp["target"]
	if sp.has("node") and is_instance_valid(sp["node"]) and (sp["node"] as Node).is_inside_tree():
		target = (sp["node"] as Node3D).global_position + Vector3(0, 1.6, 0)
	var stand: Vector3
	if sp.has("stand"):
		stand = sp["stand"]
	else:
		var cp = _cam_spot(target)
		if cp == null:
			print("[SURF] spot %s skipped: no clear view" % label)
			return
		stand = (cp as Vector3) - _eye_off
	if map.has_method("debug_park"):
		map.call("debug_park", stand)
	_hold_pos = stand
	_hold_look = target
	_hold_on = true
	await _wait(1.2)
	if not is_inside_tree():
		return
	var rid := get_viewport().get_viewport_rid()
	var gpu := 0.0
	var fps := 0.0
	for i in 30:
		await _frames(1)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(rid)
		fps += Engine.get_frames_per_second()
	gpu /= 30.0
	fps /= 30.0
	var gs: Array = _t_gpu_sum.get(mode, [0.0, 0])
	_t_gpu_sum[mode] = [float(gs[0]) + gpu, int(gs[1]) + 1]
	var tag := "%02d_%s_%s" % [idx, label.replace(" ", "_").replace(",", ""), mode]
	var ln = CoopSync.lantern
	if _off:
		var nb: Dictionary = _t_new_base.get(mode, {})
		nb[label] = gpu
		_t_new_base[mode] = nb
		print("[SURF] spot %02d %s %s (off): gpu %.2f ms fps %d" % [idx, label, _mode_name(mode), gpu, int(fps)])
		_hold_on = false
		return
	var a := _grab()
	if label.begins_with("fragment") and mode == "np":
		_dump_near(12.0)
	if is_instance_valid(ln):
		ln.set("test_spec_k", 0.0)
	# ULTRA HD: FSR 2.2's temporal history (and its locks on thin bright features) carries A's
	# highlights into the next frames; B waits until they are gone or the gates read too low
	await _frames(16 if mode == "uhd" else 3)
	var b := _grab()
	if is_instance_valid(ln):
		ln.set("test_spec_k", 1.0)
	_hold_on = false
	if a == null or b == null:
		print("[SURF] spot %02d %s: no frame captured" % [idx, label])
		return
	a.save_png("user://surf_%s.png" % tag)
	b.save_png("user://surf_%s_b.png" % tag)
	var ma := _metric(a)
	var mb := _metric(b)
	var px := float(a.get_width() * a.get_height())
	var d_s := int(ma["specks"]) - int(mb["specks"])
	var d_h := int(ma["hot"]) - int(mb["hot"])
	var d_c := int(ma["cyan"]) - int(mb["cyan"])
	var per10k := float(d_s) * 10000.0 / px
	var gain := (float(ma["mean_c"]) / maxf(0.001, float(mb["mean_c"]))) - 1.0
	var clip := float(ma["clip_c"])
	print("[SURF] spot %02d %s %s: specks A %d B %d d %+d (%.1f/10k) hot %+d cyan %d gain %+d%% clip %.1f%% gpu %.2f ms fps %d" % [
		idx, label, _mode_name(mode), int(ma["specks"]), int(mb["specks"]), d_s, per10k, d_h, d_c, int(round(gain * 100.0)), clip * 100.0, gpu, int(fps)])
	# gates (design section 3 and 5.9)
	var who := "%s %s" % [label, mode]
	if per10k > 1.0:
		_t_fails.append("%s speck delta %.1f/10k" % [who, per10k])
	if float(d_h) * 10000.0 / px > 0.3:
		_t_fails.append("%s hot delta %d" % [who, d_h])
	if d_c > 0:
		_t_fails.append("%s cyan delta %d" % [who, d_c])
	var need := 0.0
	if str(sp["kind"]) == "rock":
		need = 0.03
	elif str(sp["kind"]) == "glossy":
		need = 0.08
	if gain <= 0.0 or gain < need:
		_t_fails.append("%s sheen gain %+d%% (needs %s)" % [who, int(round(gain * 100.0)), "> 0" if need == 0.0 else "%d%%" % int(need * 100.0)])
	if clip > 0.15 and not CLIP_OK.has(label):
		_t_fails.append("%s centre clip %.1f%%" % [who, clip * 100.0])
	var bm: Dictionary = _t_base.get(mode, {})
	if bm.has(label):
		var lim := float(bm[label]) * (1.05 if mode == "uhd" else 1.03)
		if gpu > lim + 0.05:
			_t_fails.append("%s gpu %.2f ms > off run %.2f" % [who, gpu, float(bm[label])])


func _grab() -> Image:
	var tex := get_viewport().get_texture()
	if tex == null:
		return null
	var img := tex.get_image()
	if img == null or img.is_empty():
		return null
	if img.get_width() > 960:
		img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	return img


func _metric(img: Image) -> Dictionary:
	# the design's speck metric (section 3): luma Y; a speck is Y - median3x3 >= 40, Y >= 1.5 x med + 8,
	# and at most 2 of its 8 neighbours within 20 of it (a bright blob of 1 to 3 px); hot = a channel at
	# 255; cyan = hot with G and B >= 250 and R <= 200. Also the centre 160x90 window's mean Y and the
	# share of its pixels with a channel at 255.
	var w := img.get_width()
	var h := img.get_height()
	var d := img.get_data()
	var y := PackedFloat32Array()
	y.resize(w * h)
	for i in w * h:
		y[i] = 0.299 * d[i * 3] + 0.587 * d[i * 3 + 1] + 0.114 * d[i * 3 + 2]
	var specks := 0
	var hot := 0
	var cyan := 0
	var nb := [-w - 1, -w, -w + 1, -1, 1, w - 1, w, w + 1]
	for yy in range(1, h - 1):
		var row := yy * w
		for xx in range(1, w - 1):
			var i := row + xx
			var v := y[i]
			if v < 40.0:
				continue
			var near := 0
			for o in nb:
				if y[i + int(o)] >= v - 20.0:
					near += 1
					if near > 2:
						break
			if near > 2:
				continue
			var nine := [v, y[i - w - 1], y[i - w], y[i - w + 1], y[i - 1], y[i + 1], y[i + w - 1], y[i + w], y[i + w + 1]]
			nine.sort()
			var med: float = nine[4]
			if v - med < 40.0 or v < 1.5 * med + 8.0:
				continue
			specks += 1
			var r0 := int(d[i * 3])
			var g0 := int(d[i * 3 + 1])
			var b0 := int(d[i * 3 + 2])
			if r0 == 255 or g0 == 255 or b0 == 255:
				hot += 1
				if g0 >= 250 and b0 >= 250 and r0 <= 200:
					cyan += 1
	var cw := mini(160, w)
	var ch := mini(90, h)
	var x0 := (w - cw) / 2
	var y0 := (h - ch) / 2
	var sum := 0.0
	var clip := 0
	for yy in range(y0, y0 + ch):
		for xx in range(x0, x0 + cw):
			var i := yy * w + xx
			sum += y[i]
			if d[i * 3] == 255 or d[i * 3 + 1] == 255 or d[i * 3 + 2] == 255:
				clip += 1
	var n := float(cw * ch)
	return {"specks": specks, "hot": hot, "cyan": cyan, "mean_c": sum / n, "clip_c": float(clip) / n}


# ---- F4 round trip

func _f4_check() -> void:
	# NORMAL PIXELS -> ULTRA HD -> NORMAL PIXELS; then the rock and every owned material must be back
	# on its NORMAL PIXELS values
	await _set_gfx(false)
	await _set_gfx(true)
	await _set_gfx(false)
	if not is_inside_tree():
		return
	var consts: Dictionary = (map.get_script() as Script).get_script_constant_map()
	var sheen: Array = consts.get("ROCK_SHEEN", [])
	var walls := 0
	var walls_ok := 0
	for key in ["_wall_mat", "_floor_mat"]:
		var arr: Array = map.get(key)
		for i in mini(10, arr.size()):
			walls += 1
			var m := arr[i] as StandardMaterial3D
			var ok := m.normal_enabled and m.normal_texture != null and m.normal_texture.has_meta("zonda_own") and m.roughness_texture == null
			if ok and i < sheen.size():
				ok = is_equal_approx(m.roughness, float(sheen[i][0]))
			if ok:
				walls_ok += 1
			else:
				print("[SURF] F4: %s[%d] not restored (normal %s, roughness %.2f)" % [key, i, str(m.normal_enabled), m.roughness])
	var owned := 0
	var owned_ok := 0
	for e in _owned.values():
		var m2 = e[0]
		if not is_instance_valid(m2):
			continue
		owned += 1
		if _matches(m2, str(e[1])):
			owned_ok += 1
		elif owned - owned_ok <= 5:
			print("[SURF] F4: %s (%s) differs from its NORMAL PIXELS profile" % [str(e[1]), (m2 as Resource).resource_name])
	print("[SURF] F4 round trip: walls %d/%d ok, owned %d/%d ok" % [walls_ok, walls, owned_ok, owned])
	if walls_ok != walls or owned_ok != owned:
		_t_fails.append("F4 round trip (walls %d/%d, owned %d/%d)" % [walls_ok, walls, owned_ok, owned])


func _matches(m: StandardMaterial3D, cls: String) -> bool:
	var p := _profile(cls)
	if p.is_empty():
		return true
	if m.roughness_texture != null or not is_equal_approx(m.roughness, float(p.get("r", m.roughness))):
		return false
	var s := float(p["s"]) if p.has("s") else (_solve(m, m.roughness, float(p["S0"])) if p.has("S0") else m.metallic_specular)
	if absf(m.metallic_specular - s) > 0.002:
		return false
	if m.refraction_enabled != p.has("ref"):
		return false
	if m.clearcoat_enabled != p.has("cc"):
		return false
	var nf = p.get("n")
	if nf is Array:
		if m.normal_texture == null or m.normal_texture != _gfx_normal(str(nf[0])):
			return false
	elif not p.has("no") and not p.has("wn") and m.normal_enabled:
		return false
	return true


# ---- the off-run baseline (GPU per spot, load time)

func _read_base() -> Dictionary:
	if _off or not FileAccess.file_exists("user://surf_base.json"):
		return {}
	var v = JSON.parse_string(FileAccess.get_file_as_string("user://surf_base.json"))
	return v if v is Dictionary else {}


func _write_base() -> void:
	var f := FileAccess.open("user://surf_base.json", FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_t_new_base))
		f.close()
		print("[SURF] baseline written: user://surf_base.json")


func _dump_near(radius: float) -> void:
	# developer only (surfaces test): what the camera is looking at, material by material
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var seen := {}
	for g in map.find_children("*", "GeometryInstance3D", true, false):
		var gi := g as GeometryInstance3D
		if not gi.is_visible_in_tree() or gi.global_position.distance_to(cam.global_position) > radius:
			continue
		var mats: Array = []
		if gi.material_override != null:
			mats.append(gi.material_override)
		if gi is MeshInstance3D and (gi as MeshInstance3D).mesh != null:
			var mi := gi as MeshInstance3D
			for i in mi.mesh.get_surface_count():
				var m: Material = mi.get_surface_override_material(i)
				if m == null:
					m = mi.mesh.surface_get_material(i)
				if m != null:
					mats.append(m)
		for m in mats:
			var key := "%s|%s" % [gi.name, (m as Material).get_instance_id()]
			if seen.has(key):
				continue
			seen[key] = true
			var info := "%s %s res='%s' path='%s' surf='%s' rel='%s'" % [gi.get_class(), m.get_class(), m.resource_name, m.resource_path, str(m.get_meta("zonda_surf", "")), str(m.get_meta("zonda_rel", ""))]
			if m is BaseMaterial3D:
				var b := m as BaseMaterial3D
				info += " shade=%d blend=%d bb=%d spec=%d transp=%d metal=%.2f rough=%.2f mspec=%.2f emis=%s" % [b.shading_mode, b.blend_mode, b.billboard_mode, b.specular_mode, b.transparency, b.metallic, b.roughness, b.metallic_specular, str(b.emission_enabled)]
			print("[SURF] near %s @%.1f m: %s" % [gi.name, gi.global_position.distance_to(cam.global_position), info])

