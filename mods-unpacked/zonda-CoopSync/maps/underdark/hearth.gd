extends Node
# ============================================================================================
# THE UNDERDARK: the False Hearth (ZondaCoopSync 5.0, feature module "hearth", owner B5)
#
# In the Sunken Village and the Crystal Veins, off the walked line, a camp: the same small fire,
# warm glow, a bedroll, an oil flask and an ember. It is bait. The glow is a bulb on a thread that
# swells with a wet breath every 5.6 s, something drips into the fire and it hisses, and a lantern
# pointed straight up shows a pale head the size of a house in the rock above. Step within 3.4 m
# of the camp and a chain rattles overhead (STIR 1.2 s: the lure yanks up, stones patter, the fire
# gutters out), then the head drops (30 HP and a 3 m shove within 3.0 m), holds, snatches at the
# nearest one it hit (25 HP within 1.6 m of its jaws) and rises. Afterwards it is REVEALED for the
# run: the fire dead, the lure dim red, the head 4 m lower; inside 3.0 m it strikes again after a
# 0.9 s rattle, at most every 10 s.
#
# INERT IN WAVE 1 (owner decision 4): it reads L["hearths"] (written by the wave 2 generator).
# Without it this module logs "[Underdark] hearths: 0" and builds nothing, except for the dev test
# (hearth.flag "synth") and a guest simulation replaying that test, which build one synthetic
# hearth on a station.
#
# L["hearths"] entries (wave 2): {"id": "fh<N>", "pos": [x, y, z] (the camp's floor centre C),
#   "biome": 5 or 6, "ceil": y of the rock above C (optional: found with an up-ray when a player
#   is within 120 m), "yaw": optional}
#
# Every call into another builder's file is made at runtime (has_method / call / get):
#   map: register_events, register_stream("fh"), register_bites("fh"), register_threats,
#        add_fire_parts, set_fire_lit, add_light, place_bedroll, register_flask, ext_instance,
#        soft_dot, dev_flag, debug_park, debug_shot
#   CoopSync.light_field: add_flame (the bait fire counts as real fire light while it burns)
#
# SYNC
#   hearth_<fhN>  persistent {by}, written by the AUTHORITY at its first live stir. Live apply
#                 (every machine) only records revealed = true: the attack already playing ends in
#                 state 5 by itself. A REPLAY (reload, late join, continue) calls set_revealed().
#   fhstir_<fhN>  non-persistent {} at every stir (authority); guests start the rattle on it.
#   cx "fh"       [[st, y_jaw], ...] at 10 Hz, only while a hearth is in states 1-4.
#   bites         "fh<N>" through register_bites("fh", self) and this module's signal "bit":
#                 bite_opts = {"heavy": true, "push": 14 (snap) or 10 (snatch), "r": 3.0 or 1.6}.
#   The synthetic test hearth adds {"syn", "c", "ceil", "biome"} to both events so a guest (or the
#   guest simulation) builds the same camp from the data.
#
# PUBLIC API: threat_positions(), bite_origin(id), play_bite(id), bite_opts(id),
#   guestsim_report(), on_session_ended(), on_exit(); var hearths (FalseHearth nodes).
#   No-clip test (group "zonda_nc"): noclip_points(), noclip_test_synth() -> bool (synchronous:
#   only stations whose rock is loaded now), noclip_test_synth_park() (awaitable: parks the player
#   at candidates like hearth.flag), noclip_test_spot() -> [park point, look at] or [].
# FalseHearth (inner class, top_level Node3D in world coords): setup(e, mod), state_packet(),
#   remote_state(a), remote_stir(), set_revealed(), threat_positions(), bite_origin(id),
#   play_bite(id), bite_opts(id).
#
# NO-CLIP (5.0 creature no-clip spec, group NC-5; every change sits behind noclip.gd's
# is_enabled(), loaded at runtime, with the code above as the other branch):
#   H1 the ceiling: a missed up-ray is "try again" (no more c.y + 30 guess) until a player has been
#      within 120 m for 0.5 s; then 8 up rays on a 2.5 m ring must hit within 1.5 m of the centre's
#      ceiling (a layout "ceil" also needs 12-34 m), else "[HEARTH] <id> refused: the ceiling is
#      not a chimney" (it stays a plain camp and never strikes).
#   H2 the snatch swings its jaws at most minf(2.5, free - 1.8) toward its target (rays at jaw
#      height, +3 m and +6 m at the start of HOLD), 0 within 5 m of a wall.
#   H3 guests take the host's lunge from the "fh" packet [st, y_jaw, lx, lz].
#   H4 the neck: as many sections as the ceiling height needs, entering a dark unshaded ring at the
#      ceiling (no light, R10).
#   H5 test points (jaw counted, neck column whitelisted); counters stirs, hits.
# ============================================================================================

signal bit(who: Node3D, damage: float, id: String)

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const MARK := "user://zonda_hearth_test.txt"
const HEAD_RIG := "res://Art/RiggedMeshes/Monster_Head.glb"
const HEAD_STATIC := "res://Art/Monster_Head_Redesign.glb"
const SEG := "res://Art/Monster_BodySection_Redesign.glb"
const EMBER := "res://Treasure_Pickup.tscn"
const S306002 := "res://sfx/soundsnap/monster_idle/306002-Creature-Oxbow-Breaths-Wet-Deep_1.wav"
const RATTLE := "res://sfx/MonsterIdeas/Rattle_Search_Sound.wav"
const SCRAPE := "res://sfx/soundsnap/478116-METLMvmt-Vice_Grip_Large_Aluminium_Scrap_Screw_Drag_05-SSPRK-GgtPrps.wav"
const CHOMP := ["res://sfx/MonsterIdeas/Chomp_01.wav", "res://sfx/MonsterIdeas/Chomp_02.wav",
		"res://sfx/MonsterIdeas/Chomp_03.wav", "res://sfx/MonsterIdeas/Chomp_04.wav", "res://sfx/MonsterIdeas/Chomp_05.wav"]
const TEETH := ["res://sfx/MonsterIdeas/Teeth_01.wav", "res://sfx/MonsterIdeas/Teeth_02.wav",
		"res://sfx/MonsterIdeas/Teeth_03.wav", "res://sfx/MonsterIdeas/Teeth_04.wav"]

const LURE := 0
const STIR := 1
const DROP := 2
const HOLD := 3
const RISE := 4
const REVEALED := 5
const NAMES := ["LURE", "STIR", "DROP", "HOLD", "RISE", "REVEALED"]

const TRIG_R := 3.4
const TRIG_R_REV := 3.0
const TRIG_DY_LO := -1.0
const TRIG_DY_HI := 3.0
const STIR_S := 1.2
const STIR_S_REV := 0.9
const JAW_FLOOR := 1.2
const SNAP_R := 3.0
const BITE_DY_LO := -1.5
const BITE_DY_HI := 3.5
const SNAP_DMG := 60.0
const SNAP_PUSH := 14.0
const HOLD_S := 1.6
const SNATCH_AT := 0.7
const SNATCH_R := 1.6
const SNATCH_DMG := 50.0
const SNATCH_PUSH := 10.0
# the snatch swings its jaws at most LUNGE_MAX off the centre, and only at a player the SNAP hit
# (walking out on the rattle costs nothing)
const LUNGE_MAX := 2.5
const LUNGE_S := 0.5
const RISE_S := 2.2
const REARM_MS := 10000
const REST_DORMANT := 2.0         # jaw tip below the rock while it waits
const REST_REVEALED := 6.0
const LURE_Y := 5.5
const BREATH_S := 5.6
const INHALE_S := 2.4
const VIS_R := 110.0
const GLOW_VILLAGE := Color(0.8, 0.75, 0.9)
const GLOW_CRYSTAL := Color(0.5, 0.75, 1.0)
const MAW_LAYER := 1 << 18
const HEAD_SCALE := 2.6
const HEAD_TIP_Z := 3.445         # the mouth end of Monster_Head, local -Z, at scale 1
const HEAD_BACK_Z := 1.073
const SEG_SCALE := 2.4
const SEG_STEP := 4.3
# no-clip
const NC_PATH := "res://mods-unpacked/zonda-CoopSync/maps/underdark/noclip.gd"
const CEIL_NEAR_R := 120.0        # H1: the ceiling is looked for once a player is this close...
const CEIL_DWELL := 0.5           # ...for this long (their rock is collidable by then)
const CHIMNEY_R := 2.5            # 8 up rays on this ring...
const CHIMNEY_DY := 1.5           # ...must hit within this of the centre's ceiling
const CEIL_MIN := 12.0
const CEIL_MAX := 34.0
const WALL_R := 5.0               # H2: rock this close to the camp centre: no lunge at all
const LUNGE_CLEAR := 1.8          # the head's half-width off the rock at the end of a lunge

var map: Node = null
var hearths: Array = []
var _warned: Dictionary = {}
var _dot: Texture2D = null
var _maw_mat: StandardMaterial3D = null
var _was_auth := true
var _test := ""                   # "synth" / "real" while hearth.flag runs, "after" after its reload
var _mark: Dictionary = {}
var _tp := 0
var _tn := 0
var _tfails: Array = []
var _gs_live := -1                # guest simulation (2.11): -1 not seen, 0 fail, 1 pass
var _gs_stir := -1
var _gs_late := -1
var _test_ghost_off := false      # hearth.flag with loopback: the Ghost is no player outside the t=20 attack
var _nc_f := -1
var _nc_c = null
var _ring_mat: StandardMaterial3D = null


class FalseHearth extends Node3D:
	var mod = null
	var idx := 0
	var id := "fh1"
	var c := Vector3.ZERO
	var biome := 5
	var yaw := 0.0
	var ceil_y := 0.0
	var ceil_known := false
	var syn := -1
	var st := 0
	var st_t := 0.0
	var state_ms := 0
	var revealed := false
	var reached5 := false
	var set_revealed_calls := 0
	var stir_n := 0
	var y_jaw := 0.0
	var rp_y := 0.0
	var rx_ms := 0
	var y_from := 0.0
	var drop_s := 0.5
	var stir_s := 1.2
	var rearm_ms := 0
	var scan_t := 0.0
	var lunge := Vector3.ZERO
	var lunge_tgt: Node3D = null
	var snap_hit: Array = []      # the players this drop's SNAP hit (authority only)
	var snatched := false
	var bite_at := Vector3.ZERO
	var bite_push := 14.0
	var bite_r := 3.0
	var hist: Array = []          # [ms, state]
	var built := false
	var fire = null               # the map's add_fire_parts() Dictionary
	var flame_id := -1
	var flask: Node3D = null
	var ember: Node3D = null
	var glow: OmniLight3D = null
	var maw: Node3D = null
	var skel: Skeleton3D = null
	var jaw_bones: Array = []     # [bone index, rest Quaternion]
	var mandibles: Array = []     # fallback head: [pivot, base angle, sign]
	var jaw_open := 0.0
	var jaw_want := 0.0
	var jaw_shown := -1.0
	var bulb: Node3D = null
	var bulb_mat: StandardMaterial3D = null
	var halo_mat: StandardMaterial3D = null
	var stalk: MeshInstance3D = null
	var lure_up := 0.0
	var lure_up_want := 0.0
	var breath_t := 0.0
	var last_ph := 0.0
	var sway_t := 0.0
	var drip_t := 5.0
	var hiss_due := -1.0
	var dip_t := 0.0
	var dip_base := -1.0
	var sfx_chain: AudioStreamPlayer3D = null
	var sfx_rattle: AudioStreamPlayer3D = null
	var sfx_jaw: AudioStreamPlayer3D = null
	var sfx_lure: AudioStreamPlayer3D = null
	var sfx_fire: AudioStreamPlayer3D = null
	var sfx_rock: AudioStreamPlayer3D = null
	# no-clip
	var ceil_data := false        # the ceiling came with the data ("ceil"), not from a ray
	var checked := false          # H1: the chimney check ran (with the guard on)
	var refused := false          # ...and failed: a plain camp that never strikes
	var near_t := 0.0             # how long a player has been within 120 m
	var wall_near := false        # H2: rock within 5 m of the centre (no lunge)
	var lunge_max := 2.5          # H2: this hold's lunge
	var rp_lunge := Vector3.ZERO  # H3: the host's lunge (guests)
	var has_rp_lunge := false
	var neck_built := false
	var segs: Array = []
	var neck_ring: MeshInstance3D = null

	func setup(e: Dictionary, m) -> bool:
		mod = m
		var p = e.get("pos", e.get("c", e.get("center", null)))
		if not (p is Array) or (p as Array).size() < 3:
			return false
		c = Vector3(float(p[0]), float(p[1]), float(p[2]))
		id = str(e.get("id", "fh%d" % (idx + 1)))
		biome = int(e.get("biome", 5))
		yaw = float(e.get("yaw", 0.0))
		syn = int(e.get("syn", -1))
		if e.has("ceil"):
			ceil_y = float(e["ceil"])
			ceil_known = true
			ceil_data = true
		top_level = true
		return true

	func _ready() -> void:
		if mod != null:
			mod.call("_build", self)

	func jaw_tip() -> Vector3:
		return Vector3(c.x + lunge.x, y_jaw, c.z + lunge.z)

	func state_packet() -> Array:
		# H3: the lunge xz rides along, so guests swing at the host's victim (a build before 5.0
		# reads the first two)
		return [st, snappedf(y_jaw, 0.01), snappedf(lunge.x, 0.01), snappedf(lunge.z, 0.01)]

	func remote_state(a: Array) -> void:
		if mod != null:
			mod.call("_h_remote_state", self, a)

	func remote_stir() -> void:
		if mod != null:
			mod.call("_h_remote_stir", self)

	func set_revealed() -> void:
		if mod != null:
			mod.call("_h_set_revealed", self)

	func threat_positions() -> Array:
		if st >= 1 and st <= 4:
			return [jaw_tip()]
		return []

	func bite_origin(_id: String) -> Vector3:
		return bite_at

	func play_bite(_id: String) -> void:
		if mod != null:
			mod.call("_h_play_bite", self)

	func bite_opts(_id: String) -> Dictionary:
		return {"heavy": true, "push": bite_push, "r": bite_r}


# ============================================================================ no-clip helper (runtime)

static var _nc_script = null
static var _nc_tried := false


static func _nc():
	# noclip.gd (NC-1), loaded once at runtime: a missing helper means today's behaviour
	if not _nc_tried:
		_nc_tried = true
		if ResourceLoader.exists(NC_PATH) or FileAccess.file_exists(NC_PATH):
			_nc_script = load(NC_PATH)
		if _nc_script == null:
			push_warning("[CLIP] noclip.gd missing: creatures move as before")
	return _nc_script


static func _note(key: String, n: int = 1) -> void:
	var NC = _nc()
	if NC != null:
		NC.call("note", "hearth", key, n)


func _ncx():
	# the helper while the guard is on, else null (cached per frame)
	var f := Engine.get_process_frames()
	if f != _nc_f:
		_nc_f = f
		_nc_c = null
		var NC = _nc()
		if NC != null and bool(NC.call("is_enabled")):
			_nc_c = NC
	return _nc_c


# ============================================================================ setup

func setup(m: Node) -> void:
	map = m
	_was_auth = CoopSync.map_is_authority()
	add_to_group("zonda_nc")           # the no-clip probe samples noclip_points() (H5)
	var L = m.get("L")
	var list: Array = []
	if L is Dictionary:
		var hl = (L as Dictionary).get("hearths", [])
		if hl is Array:
			list = hl
	for i in list.size():
		if list[i] is Dictionary:
			_add_hearth(list[i])
	print("[Underdark] hearths: %d" % hearths.size())
	if map.has_method("register_events"):
		map.call("register_events", ["hearth_"], _on_hearth_event, false)
		map.call("register_events", ["fhstir_"], _on_stir_event, true)
	else:
		_warn("register_events", "[HEARTH] the map has no register_events: hearths cannot sync")
	if map.has_method("register_stream"):
		map.call("register_stream", "fh", _send_fh, _recv_fh)
	if map.has_method("register_bites"):
		map.call("register_bites", "fh", self)
	if map.has_method("register_threats"):
		map.call("register_threats", self)
	# the dev test: hearth.flag, or its second half after the death reload (the marker)
	var fl = null
	if map.has_method("dev_flag"):
		fl = map.call("dev_flag", "hearth.flag")
	elif FileAccess.file_exists(DIR + "hearth.flag"):
		fl = FileAccess.get_file_as_string(DIR + "hearth.flag").strip_edges()
		DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/maps/underdark/hearth.flag")
	if fl != null:
		if CoopSync.has_method("use_test_files"):
			CoopSync.call("use_test_files")
		var txt := str(fl).strip_edges().to_lower()
		_test = "synth" if (txt == "synth" or txt == "" or txt == "1" or hearths.is_empty()) else "real"
		print("[HEARTH] test: hearth.flag \"%s\" -> %s" % [txt, _test])
		DirAccess.remove_absolute(MARK)
		_run_synth.call_deferred()
	elif FileAccess.file_exists(MARK):
		# read once and gone (a crash or a quit before the second half ends must never turn a
		# later real load into a test), and only when written in the last 180 s
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(MARK))
		DirAccess.remove_absolute(MARK)
		var fresh: bool = parsed is Dictionary and Time.get_unix_time_from_system() - float((parsed as Dictionary).get("t", 0.0)) < 180.0
		if fresh and str((parsed as Dictionary).get("phase", "")) == "reload":
			_mark = parsed
			_test = "after"
			if CoopSync.has_method("use_test_files"):
				CoopSync.call("use_test_files")
			# built now, before the map replays the stored events (a frame later)
			if _by_id(str(_mark.get("id", "fh1"))) == null:
				_add_hearth({"id": str(_mark.get("id", "fh1")), "pos": _mark.get("c", [0, 0, 0]), "ceil": float(_mark.get("ceil", 0.0)), "biome": int(_mark.get("biome", 5)), "syn": int(_mark.get("syn", -1))})
			_run_after.call_deferred()
		elif parsed is Dictionary:
			print("[HEARTH] stale test marker ignored and removed")


func _add_hearth(e: Dictionary):
	var h := FalseHearth.new()
	h.idx = hearths.size()
	if not h.setup(e, self):
		h.free()
		push_warning("[HEARTH] a hearths entry has no pos: skipped")
		return null
	if _by_id(h.id) != null:
		h.free()
		return null
	h.name = "FalseHearth_" + h.id
	hearths.append(h)
	add_child(h)
	return h


func _build(h: FalseHearth) -> void:
	# the camp kit around the floor centre C, the maw in the rock above and the lure
	if h.built:
		return
	h.built = true
	var fire_pos := h.c + Vector3(2.5, 0.0, 1.0)
	if map != null and map.has_method("add_fire_parts"):
		var e = map.call("add_fire_parts", fire_pos, 0.45)
		if e is Dictionary:
			h.fire = e
			if not (e as Dictionary).has("lit"):
				e["lit"] = true
	else:
		_warn("add_fire_parts", "[HEARTH] the map has no add_fire_parts: the camp has no fire")
	var lf = CoopSync.get("light_field")
	if h.fire is Dictionary and lf != null and is_instance_valid(lf) and lf.has_method("add_flame"):
		var fd: Dictionary = h.fire
		h.flame_id = int(lf.call("add_flame", fire_pos, 2.9, func(): return bool(fd.get("lit", false))))
	if map != null and map.has_method("place_bedroll"):
		var bp := h.c + Vector3(1.0, 0.0, -0.6)
		var to := fire_pos - bp
		map.call("place_bedroll", bp, atan2(-to.x, -to.z))
	_place_flask(h)
	var eps = load(EMBER) if ResourceLoader.exists(EMBER) else null
	if eps is PackedScene:
		var em := (eps as PackedScene).instantiate() as Node3D
		if em != null:
			em.position = h.c + Vector3(-0.3, 1.3, 0.8)
			h.add_child(em)
			h.ember = em
	var col: Color = GLOW_CRYSTAL if h.biome == 6 else GLOW_VILLAGE
	if map != null and map.has_method("add_light"):
		var l = map.call("add_light", h.c + Vector3(0.0, LURE_Y, 0.0), col, 0.95, 34.0)
		if l is OmniLight3D:
			h.glow = l
	if h.glow == null:
		h.glow = OmniLight3D.new()
		h.glow.light_color = col
		h.glow.light_energy = 0.95
		h.glow.omni_range = 34.0
		h.glow.shadow_enabled = false
		h.glow.position = h.c + Vector3(0.0, LURE_Y, 0.0)
		h.add_child(h.glow)
	h.glow.light_cull_mask = ~MAW_LAYER      # the lure never lights the head it hangs from
	_build_maw(h)
	_build_lure(h)
	h.sfx_chain = _player(h, 45.0)
	h.sfx_rattle = _player(h, 45.0)
	h.sfx_jaw = _player(h, 45.0)
	h.sfx_lure = _player(h, 30.0)
	h.sfx_fire = _player(h, 24.0)
	h.sfx_fire.position = fire_pos + Vector3.UP * 0.3
	h.sfx_rock = _player(h, 60.0)
	if h.ceil_known:
		h.y_jaw = _rest_y(h)             # the neck sections follow at the first physics tick
	h.breath_t = randf() * BREATH_S
	h.drip_t = randf_range(4.0, 9.0)


func _place_flask(h: FalseHearth) -> void:
	# a per-player 45% flask (oil_fhN), skipped when this player already took it
	var fid := "oil_" + h.id
	var OF = load(DIR + "oil_flask.gd")
	if OF == null:
		return
	var taken = OF.call("taken_ids")
	if taken is Dictionary and (taken as Dictionary).has(fid):
		return
	var p := h.c + Vector3(0.9, 0.0, -0.9)
	var d := {"id": fid, "pos": [p.x, p.y, p.z], "biome": h.biome, "map": map}
	if map != null and map.has_method("ext_instance"):
		var mdl = map.call("ext_instance", "ext/ph/metal_jug.glb", 0.5)
		if mdl is Node3D:
			d["model"] = mdl
	var f = OF.new()
	f.call("setup", d)
	h.add_child(f)
	h.flask = f
	if map != null and map.has_method("register_flask"):
		map.call("register_flask", f)


func _build_maw(h: FalseHearth) -> void:
	# the rigged Monster_Head x2.6 pointing down (its mouth end on the pivot), four body sections
	# x2.4 stacked up into the rock; dim bone colour, no emission, all on render layer 19
	h.maw = Node3D.new()
	h.maw.name = "Maw"
	h.add_child(h.maw)
	h.maw.position = Vector3(h.c.x, h.y_jaw, h.c.z)
	h.maw.rotation.y = h.yaw
	h.maw.visible = h.ceil_known
	var head_ps = load(HEAD_RIG) if ResourceLoader.exists(HEAD_RIG) else null
	var rigged := head_ps is PackedScene
	if not rigged:
		head_ps = load(HEAD_STATIC) if ResourceLoader.exists(HEAD_STATIC) else null
	if head_ps is PackedScene:
		var head := (head_ps as PackedScene).instantiate() as Node3D
		if head != null:
			head.scale = Vector3.ONE * HEAD_SCALE
			head.rotation = Vector3(-PI * 0.5, 0.0, 0.0)          # local -Z (the mouth) points down
			head.position = Vector3(0.0, HEAD_TIP_Z * HEAD_SCALE, 0.0)
			h.maw.add_child(head)
			if rigged:
				var sks := head.find_children("*", "Skeleton3D", true, false)
				if not sks.is_empty():
					h.skel = sks[0] as Skeleton3D
					for bn in ["Jaw_01", "Jaw_02", "Jaw_03"]:
						var bi := h.skel.find_bone(bn)
						if bi >= 0:
							h.jaw_bones.append([bi, h.skel.get_bone_rest(bi).basis.get_rotation_quaternion()])
	if h.jaw_bones.is_empty():
		# the static head: three mandibles around the mouth that open and snap
		var mm := CylinderMesh.new()
		mm.top_radius = 0.02
		mm.bottom_radius = 0.18
		mm.height = 2.4
		mm.radial_segments = 6
		mm.rings = 1
		for i in 3:
			var piv := Node3D.new()
			var a := float(i) * TAU / 3.0
			piv.position = Vector3(cos(a) * 0.9, 0.6, sin(a) * 0.9)
			piv.rotation.y = -a
			h.maw.add_child(piv)
			var mi := MeshInstance3D.new()
			mi.mesh = mm
			mi.position = Vector3(0.0, -1.0, 0.0)
			mi.rotation.x = PI
			piv.add_child(mi)
			h.mandibles.append(piv)
	# the neck sections come once the ceiling is known (_build_neck: H4 sizes them to it)
	for g in h.maw.find_children("*", "GeometryInstance3D", true, false):
		var gi := g as GeometryInstance3D
		gi.material_override = _maw_material()
		gi.layers = MAW_LAYER
		gi.visibility_range_end = VIS_R + 30.0


func _build_neck(h: FalseHearth) -> void:
	# body sections x2.4 stacked up from the back of the head into the rock. Today: four. No-clip
	# (H4): as many as reach from the head, dropped to the floor, up past the ceiling (1 to 8),
	# entering a dark unshaded ring at the ceiling so the column never shows a cut end (no light,
	# R10); the ring follows the lunge.
	if h.neck_built or not h.ceil_known or h.maw == null:
		return
	h.neck_built = true
	var y0 := HEAD_TIP_Z * HEAD_SCALE + HEAD_BACK_Z * HEAD_SCALE + 1.5
	var n := 4
	var nc: bool = _ncx() != null
	if nc:
		n = clampi(ceili((h.ceil_y - h.c.y - JAW_FLOOR - y0 + 1.0) / SEG_STEP), 1, 8)
	var seg_ps = load(SEG) if ResourceLoader.exists(SEG) else null
	if seg_ps is PackedScene:
		for i in n:
			var sg := (seg_ps as PackedScene).instantiate() as Node3D
			if sg == null:
				continue
			sg.scale = Vector3.ONE * SEG_SCALE
			sg.rotation = Vector3(-PI * 0.5, float(i) * 0.35, 0.0)
			sg.position = Vector3(0.0, y0 + float(i) * SEG_STEP, 0.0)
			h.maw.add_child(sg)
			h.segs.append(sg)
			for g in sg.find_children("*", "GeometryInstance3D", true, false):
				var gi := g as GeometryInstance3D
				gi.material_override = _maw_material()
				gi.layers = MAW_LAYER
				gi.visibility_range_end = VIS_R + 30.0
			if sg is GeometryInstance3D:
				(sg as GeometryInstance3D).material_override = _maw_material()
				(sg as GeometryInstance3D).layers = MAW_LAYER
	if nc:
		var tm := TorusMesh.new()
		tm.inner_radius = 2.2
		tm.outer_radius = 4.4
		tm.rings = 24
		tm.ring_segments = 8
		if _ring_mat == null:
			_ring_mat = StandardMaterial3D.new()
			_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			_ring_mat.albedo_color = Color(0.0, 0.0, 0.0)
			_ring_mat.disable_receive_shadows = true
		h.neck_ring = MeshInstance3D.new()
		h.neck_ring.name = "NeckRing"
		h.neck_ring.mesh = tm
		h.neck_ring.material_override = _ring_mat
		h.neck_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		h.neck_ring.layers = MAW_LAYER
		h.neck_ring.visibility_range_end = VIS_R + 30.0
		h.neck_ring.scale = Vector3(1.0, 0.3, 1.0)
		h.neck_ring.position = Vector3(h.c.x, h.ceil_y - 0.05, h.c.z)
		h.add_child(h.neck_ring)


func _build_lure(h: FalseHearth) -> void:
	# one unshaded bulb with a soft-dot halo on a dark stalk, plus the glow light (R10 exception)
	h.bulb = Node3D.new()
	h.bulb.name = "Lure"
	h.add_child(h.bulb)
	h.bulb.position = h.c + Vector3(0.0, LURE_Y, 0.0)
	var sm := SphereMesh.new()
	sm.radius = 0.16
	sm.height = 0.32
	sm.radial_segments = 10
	sm.rings = 6
	h.bulb_mat = StandardMaterial3D.new()
	h.bulb_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	h.bulb_mat.albedo_color = Color(0.30, 0.18, 0.06)
	var bm := MeshInstance3D.new()
	bm.mesh = sm
	bm.material_override = h.bulb_mat
	bm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	bm.visibility_range_end = VIS_R + 30.0
	h.bulb.add_child(bm)
	var q := QuadMesh.new()
	q.size = Vector2(1.2, 1.2)
	h.halo_mat = StandardMaterial3D.new()
	h.halo_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	h.halo_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	h.halo_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	h.halo_mat.albedo_texture = _dot_tex()
	h.halo_mat.albedo_color = Color(0.30, 0.18, 0.06, 0.5)
	h.halo_mat.disable_receive_shadows = true
	var hm := MeshInstance3D.new()
	hm.mesh = q
	hm.material_override = h.halo_mat
	hm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	hm.visibility_range_end = VIS_R + 30.0
	h.bulb.add_child(hm)
	var cm := CylinderMesh.new()
	cm.top_radius = 0.025
	cm.bottom_radius = 0.025
	cm.height = 1.0
	cm.radial_segments = 5
	cm.rings = 1
	var smat := StandardMaterial3D.new()
	smat.albedo_color = Color(0.05, 0.045, 0.04)
	smat.roughness = 1.0
	h.stalk = MeshInstance3D.new()
	h.stalk.mesh = cm
	h.stalk.material_override = smat
	h.stalk.layers = MAW_LAYER
	h.stalk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	h.stalk.visibility_range_end = VIS_R + 30.0
	h.stalk.visible = false
	h.add_child(h.stalk)


func _maw_material() -> StandardMaterial3D:
	if _maw_mat == null:
		_maw_mat = StandardMaterial3D.new()
		_maw_mat.albedo_color = Color(0.30, 0.28, 0.25)
		_maw_mat.roughness = 0.9
		_maw_mat.metallic = 0.0
	return _maw_mat


# ============================================================================ public API

func threat_positions() -> Array:
	var out: Array = []
	for h in hearths:
		out.append_array(h.threat_positions())
	return out


func bite_origin(id: String) -> Vector3:
	var h = _by_id(id)
	return h.bite_at if h != null else Vector3.ZERO


func play_bite(id: String) -> void:
	var h = _by_id(id)
	if h != null:
		_h_play_bite(h)


func bite_opts(id: String) -> Dictionary:
	var h = _by_id(id)
	if h == null:
		return {"heavy": true}
	return h.bite_opts(id)


func on_session_ended() -> void:
	# a guest that becomes the authority goes on from the state this screen shows
	if CoopSync.map_is_authority() and not _was_auth:
		_was_auth = true
		for h in hearths:
			h.y_from = h.y_jaw
			h.scan_t = 0.0
			if h.st == REVEALED:
				h.rearm_ms = Time.get_ticks_msec() + REARM_MS


func on_exit() -> void:
	var lf = CoopSync.get("light_field")
	for h in hearths:
		if h.flame_id >= 0 and lf != null and is_instance_valid(lf) and lf.has_method("remove_flame"):
			lf.call("remove_flame", h.flame_id)


# ============================================================================ no-clip test (H5)

func noclip_points() -> Array:
	# the no-clip probe's sample (spec 5.2): per hearth the jaw tip (counted), and the neck
	# column where it enters the ceiling (intended contact: whitelisted)
	var out: Array = []
	var view := "host" if CoopSync.map_is_authority() else "guest"
	for h in hearths:
		if not h.built or not h.ceil_known or h.maw == null or not h.is_inside_tree():
			continue
		var vis: bool = h.maw.is_visible_in_tree() and not h.refused
		var stn := str(NAMES[clampi(h.st, 0, NAMES.size() - 1)])
		out.append({"kind": "hearth", "id": h.id, "view": view, "c": [h.jaw_tip()], "cn": ["jaw"], "seg": [-1],
				"sp": 0.0, "x": [], "xn": [], "xc": [], "xg": [], "vis": vis, "wl": false, "tp": 0, "st": stn,
				"fx": {"lunge_max": h.lunge_max, "refused": h.refused}})
		out.append({"kind": "hearth", "id": h.id + ":neck", "view": view,
				"c": [Vector3(h.c.x + h.lunge.x, h.ceil_y, h.c.z + h.lunge.z)], "cn": ["column"], "seg": [-1],
				"sp": 0.0, "x": [], "xn": [], "xc": [], "xg": [], "vis": vis, "wl": true, "tp": 0, "st": stn, "fx": {}})
	return out


func noclip_test_synth() -> bool:
	# P9 (the probe calls it without await): a hearth to test. True at once when one exists (the
	# layout's, or one built before); else the same synthetic hearth hearth.flag builds, at the
	# first candidate station whose rock is collidable right now (host only; no parking, no
	# waiting). False when none is: P9 may SKIP. noclip_test_synth_park() is the awaitable
	# variant that parks the player at the candidates (1 s each) like hearth.flag.
	if not hearths.is_empty():
		return true
	if not CoopSync.map_is_authority():
		return false
	var found := _synth_now()
	if found.is_empty():
		print("[HEARTH] noclip synth: no candidate station has its rock loaded here")
		return false
	return _synth_build(found)


func noclip_test_synth_park() -> bool:
	# the awaitable variant: await feat.call("noclip_test_synth_park")
	if not hearths.is_empty():
		return true
	if not CoopSync.map_is_authority():
		return false
	var c = Game.climber
	if not is_instance_valid(c) or not (c as Node).is_inside_tree():
		return false
	var found: Dictionary = await _synth_search(c)
	if not is_inside_tree() or found.is_empty():
		print("[HEARTH] noclip synth: no station passed")
		return false
	return _synth_build(found)


func _synth_build(found: Dictionary) -> bool:
	var h = _add_hearth(found)
	if h == null:
		return false
	print("[HEARTH] noclip synth at station %d  (C %s, rock %.1f m up)" % [int(found["syn"]), str(h.c), h.ceil_y - h.c.y])
	return true


func _synth_now() -> Dictionary:
	# _synth_search without parking: only stations whose rock is collidable now
	var L = map.get("L") if map != null else null
	if not (L is Dictionary):
		return {}
	var NC = _ncx()
	var c = Game.climber
	var here: Vector3 = (c as Node3D).global_position if is_instance_valid(c) and (c as Node).is_inside_tree() else Vector3(1e9, 1e9, 1e9)
	var cps: Array = []
	for cp in (L as Dictionary).get("checkpoints", []):
		if cp is Dictionary and (cp as Dictionary).has("pos"):
			cps.append(_v(cp["pos"]))
	var stations: Array = (L as Dictionary).get("stations", [])
	for i in stations.size():
		var sd = stations[i]
		if not (sd is Dictionary) or not (sd as Dictionary).has("pos"):
			continue
		var b := int(sd.get("biome", -1))
		var kind := str(sd.get("kind", ""))
		if (b != 5 and b != 6) or (kind != "shelf" and kind != "terrace"):
			continue
		var sp := _v(sd["pos"])
		var cpd := 1e9
		for q in cps:
			cpd = minf(cpd, sp.distance_to(q))
		if cpd < 25.0 or not _hazard_clear(sp, L):
			continue
		var loaded: bool = bool(NC.call("solid_at", sp, 30.0)) if NC != null else sp.distance_to(here) < 100.0
		if not loaded:
			continue
		var r := _synth_check(sp)
		if not r.is_empty():
			r["syn"] = i
			r["biome"] = b
			r["id"] = "fh1"
			return r
	return {}


func noclip_test_spot() -> Array:
	# [where to stand inside the trigger ring (1.5 m out, on the floor), where to look (the jaw at
	# rest)] for the first hearth, or [] when there is none
	if hearths.is_empty():
		return []
	var h = hearths[0]
	var rd := _ring_dir(h.c)
	var at := _floor_at(h.c + rd * 1.5, h.c.y)
	return [at, Vector3(h.c.x, h.y_jaw, h.c.z)]


# ============================================================================ events and stream

func _on_hearth_event(key: String, data: Dictionary, replay: bool) -> void:
	var id := key.substr(7)
	var h = _by_id(id)
	if h == null:
		h = _ensure_synth(id, data)
	if h == null:
		return
	var play := str(CoopSync.get("guestsim")) == "play"
	if replay:
		h.set_revealed()
		if play:
			_gs_late = 1 if h.st == REVEALED else 0
	else:
		var before: int = h.set_revealed_calls
		h.revealed = true            # state only: the attack already playing ends in 5 by itself
		if play:
			_gs_live = 1 if h.set_revealed_calls == before else 0
	if _test != "" or play:
		print("[HEARTH] %s revealed (%s)" % [id, "replay" if replay else "live"])


func _on_stir_event(key: String, data: Dictionary, _replay: bool) -> void:
	var id := key.substr(7)
	var h = _by_id(id)
	if h == null:
		h = _ensure_synth(id, data)
	if h == null or CoopSync.map_is_authority():
		return
	h.remote_stir()


func _ensure_synth(id: String, data: Dictionary):
	# a synthetic test hearth this machine has not built yet: its data rides in the events
	if not data.has("syn") or not data.has("c") or not data.has("ceil"):
		return null
	print("[HEARTH] building the synthetic %s from the event data (station %d)" % [id, int(data["syn"])])
	return _add_hearth({"id": id, "pos": data["c"], "ceil": float(data["ceil"]), "biome": int(data.get("biome", 5)), "syn": int(data["syn"])})


func _send_fh():
	var any := false
	var out: Array = []
	for h in hearths:
		if h.st >= STIR and h.st <= RISE:
			any = true
		out.append(h.state_packet())
	return out if any else null


func _recv_fh(v) -> void:
	if CoopSync.map_is_authority() or not (v is Array):
		return
	var arr: Array = v
	for i in mini(arr.size(), hearths.size()):
		var e = arr[i]
		if e is Array and (e as Array).size() >= 2:
			hearths[i].remote_state(e)


func _h_remote_state(h: FalseHearth, a: Array) -> void:
	if CoopSync.map_is_authority() or a.size() < 2:
		return
	var n := int(a[0])
	h.rp_y = float(a[1])
	h.rx_ms = Time.get_ticks_msec()
	if a.size() >= 4:
		h.rp_lunge = Vector3(float(a[2]), 0.0, float(a[3]))     # H3
		h.has_rp_lunge = true
	if n == h.st or n < 0 or n > REVEALED:
		return
	if n == STIR or n == LURE or n == REVEALED:
		return                       # the rattle starts on fhstir_, the rest ends by itself
	_h_set(h, n)


func _h_remote_stir(h: FalseHearth) -> void:
	if h.st != LURE and h.st != REVEALED:
		return
	if h.refused:
		# the host found a chimney where this screen did not (rock not fully loaded here): the
		# host decides, so show it
		h.refused = false
		if is_instance_valid(h.glow):
			h.glow.visible = true
	h.checked = true
	h.stir_s = STIR_S_REV if h.st == REVEALED else STIR_S
	h.rx_ms = Time.get_ticks_msec()
	_h_set(h, STIR)
	if str(CoopSync.get("guestsim")) == "play":
		_gs_stir = 1


func _h_play_bite(h: FalseHearth) -> void:
	if CoopSync.map_is_authority():
		return
	_play(h.sfx_jaw, _rand_stream("hearth_teeth", TEETH), 2.0, 0.6, 45.0)


# ============================================================================ the attack (authority)

func _physics_process(delta: float) -> void:
	if hearths.is_empty():
		return
	var auth: bool = CoopSync.map_is_authority()
	if auth != _was_auth:
		if auth:
			on_session_ended()
		_was_auth = auth
	var NC = _ncx()
	for h in hearths:
		if not h.built:
			continue
		if not h.ceil_known:
			h.scan_t -= delta
			if h.scan_t <= 0.0:
				h.scan_t = 0.5
				_find_ceil(h, false)
			continue
		if not h.neck_built:
			_build_neck(h)
		if NC != null and not h.checked:
			# H1: a layout (or synthetic) "ceil" is checked once its rock is collidable; until
			# then (and forever when refused) the hearth never stirs
			h.scan_t -= delta
			if h.scan_t <= 0.0:
				h.scan_t = 0.5
				_check_chimney(NC, h)
		if auth:
			if h.refused or (NC != null and not h.checked):
				continue
			_h_tick(h, delta)
		else:
			_h_guest_tick(h, delta)


func _h_tick(h: FalseHearth, delta: float) -> void:
	h.st_t += delta
	match h.st:
		LURE, REVEALED:
			h.scan_t -= delta
			if h.scan_t > 0.0:
				return
			h.scan_t = 0.1
			if h.st == REVEALED and Time.get_ticks_msec() < h.rearm_ms:
				return
			var r := TRIG_R_REV if h.st == REVEALED else TRIG_R
			for p in _players():
				var q: Vector3 = (p as Node3D).global_position
				var dy := q.y - h.c.y
				if Vector2(q.x - h.c.x, q.z - h.c.z).length() <= r and dy >= TRIG_DY_LO and dy <= TRIG_DY_HI:
					_h_stir(h)
					return
		STIR:
			if h.st_t >= h.stir_s:
				_h_set(h, DROP)
		DROP:
			var k := clampf(h.st_t / h.drop_s, 0.0, 1.0)
			h.y_jaw = lerpf(h.y_from, h.c.y + JAW_FLOOR, k * k)          # ease-in: it falls
			if k >= 1.0:
				h.y_jaw = h.c.y + JAW_FLOOR
				_h_set(h, HOLD)
				_h_snap(h)
		HOLD:
			_h_lunge(h, delta)
			if not h.snatched and h.st_t >= SNATCH_AT:
				h.snatched = true
				_h_snatch(h)
			if h.st_t >= HOLD_S:
				_h_set(h, RISE)
		RISE:
			var k2 := clampf(h.st_t / RISE_S, 0.0, 1.0)
			h.y_jaw = lerpf(h.y_from, _rest_y(h), smoothstep(0.0, 1.0, k2))
			h.lunge = h.lunge.lerp(Vector3.ZERO, clampf(delta * 3.0, 0.0, 1.0))
			if k2 >= 1.0:
				_h_rest(h)


func _h_stir(h: FalseHearth) -> void:
	var was_rev := h.st == REVEALED
	h.stir_s = STIR_S_REV if was_rev else STIR_S
	_note("stirs")                       # the telegraph (the no-clip probe: hits <= stirs)
	_h_set(h, STIR)
	var d := _syn_data(h)
	CoopSync.map_event("fhstir_" + h.id, d, false)          # guests start the rattle on it
	if not was_rev and not CoopSync.map_event_done("hearth_" + h.id):
		var d2 := _syn_data(h)
		d2["by"] = CoopSync.local_name
		CoopSync.map_event("hearth_" + h.id, d2)            # persistent: revealed for the run


func _syn_data(h: FalseHearth) -> Dictionary:
	if h.syn < 0:
		return {}
	return {"syn": h.syn, "c": [h.c.x, h.c.y, h.c.z], "ceil": h.ceil_y, "biome": h.biome}


func _h_snap(h: FalseHearth) -> void:
	# the drop lands: 60 damage (30 HP) and a 14 shove (about 3 m) at everyone within 3.0 m of C
	h.bite_at = h.c
	h.bite_push = SNAP_PUSH
	h.bite_r = SNAP_R
	h.snap_hit.clear()
	for p in _players():
		var q: Vector3 = (p as Node3D).global_position
		var dy := q.y - h.c.y
		if Vector2(q.x - h.c.x, q.z - h.c.z).length() <= SNAP_R and dy >= BITE_DY_LO and dy <= BITE_DY_HI:
			if _test != "":
				print("[HEARTH] %s SNAP hits %s" % [h.id, str((p as Node).name)])
			h.snap_hit.append(p)
			_note("hits")
			bit.emit(p, SNAP_DMG, h.id)


func _h_snatch(h: FalseHearth) -> void:
	# 0.7 s into the hold the jaws snatch: 50 damage (25 HP) within 1.6 m of the jaw tip, only at
	# a player the SNAP hit (standing still costs 55 HP, walking out on the rattle costs nothing)
	var tip := h.jaw_tip()
	h.bite_at = Vector3(tip.x, h.c.y, tip.z)
	h.bite_push = SNATCH_PUSH
	h.bite_r = SNATCH_R
	h.jaw_want = deg_to_rad(12.0)
	_play(h.sfx_jaw, _rand_stream("hearth_chomp", CHOMP), 2.0, 0.6, 45.0)
	for p in _players():
		if not h.snap_hit.has(p):
			continue
		var q: Vector3 = (p as Node3D).global_position
		var dy := q.y - h.c.y
		if Vector2(q.x - tip.x, q.z - tip.z).length() <= SNATCH_R and dy >= BITE_DY_LO and dy <= BITE_DY_HI:
			if _test != "":
				print("[HEARTH] %s SNATCH hits %s" % [h.id, str((p as Node).name)])
			_note("hits")
			bit.emit(p, SNATCH_DMG, h.id)


func _h_lunge(h: FalseHearth, delta: float) -> void:
	# in the first 0.5 s of the hold the head swings its jaws toward the player it picked
	if h.st_t > LUNGE_S or not is_instance_valid(h.lunge_tgt) or not h.lunge_tgt.is_inside_tree():
		return
	var q := h.lunge_tgt.global_position
	var off := Vector3(q.x - h.c.x, 0.0, q.z - h.c.z)
	var lim: float = h.lunge_max if _ncx() != null else LUNGE_MAX     # H2: this hold's room
	if off.length() > lim:
		off = off.normalized() * lim if lim > 0.001 else Vector3.ZERO
	h.lunge = h.lunge.lerp(off, clampf(delta * 8.0, 0.0, 1.0))


func _lunge_room(h: FalseHearth) -> float:
	# H2, once at the start of HOLD: the jaws swing at most minf(2.5, free - 1.8) toward the
	# target, where free is the rock-free distance that way at jaw height, +3 m and +6 m (the
	# head is wide); 0 when the camp centre is within 5 m of a wall (_check_chimney)
	var NC = _ncx()
	if NC == null:
		return LUNGE_MAX
	if h.wall_near or not is_instance_valid(h.lunge_tgt):
		return 0.0
	var q := h.lunge_tgt.global_position
	var dir := Vector3(q.x - h.c.x, 0.0, q.z - h.c.z)
	if dir.length() < 0.05:
		return LUNGE_MAX
	dir = dir.normalized()
	var w3 := h.get_world_3d()
	if w3 == null:
		return LUNGE_MAX
	var free := LUNGE_MAX + LUNGE_CLEAR
	var jaw := Vector3(h.c.x, h.c.y + JAW_FLOOR, h.c.z)
	for dh in [0.0, 3.0, 6.0]:
		var a: Vector3 = jaw + Vector3.UP * float(dh)
		var hit = NC.call("ray", w3.direct_space_state, a, a + dir * (LUNGE_MAX + LUNGE_CLEAR))
		if hit is Dictionary and not (hit as Dictionary).is_empty():
			var hd: Dictionary = hit
			free = minf(free, float(hd["d"]) if hd.has("d") else a.distance_to(hd.get("position", a)))
	return clampf(minf(LUNGE_MAX, free - LUNGE_CLEAR), 0.0, LUNGE_MAX)


func _pick_lunge(h: FalseHearth) -> Node3D:
	# the nearest player inside the SNAP ring as the head lands (on the authority HOLD starts in
	# the same tick as _h_snap, so this is always one of its victims): nobody who walked out on
	# the rattle, or never came in, is swung at
	var best: Node3D = null
	var bd := SNAP_R
	for p in _players():
		var q: Vector3 = (p as Node3D).global_position
		var dy := q.y - h.c.y
		var d := Vector2(q.x - h.c.x, q.z - h.c.z).length()
		if d <= bd and dy >= BITE_DY_LO and dy <= BITE_DY_HI:
			bd = d
			best = p
	return best


func _h_rest(h: FalseHearth) -> void:
	h.rearm_ms = Time.get_ticks_msec() + REARM_MS
	h.lunge = Vector3.ZERO
	h.lunge_tgt = null
	h.snap_hit.clear()
	h.rp_lunge = Vector3.ZERO
	h.has_rp_lunge = false
	if h.revealed:
		h.reached5 = true
		_h_set(h, REVEALED)
	else:
		_h_set(h, LURE)


func _h_guest_tick(h: FalseHearth, delta: float) -> void:
	h.st_t += delta
	if h.st < STIR or h.st > RISE:
		return
	if h.rx_ms > 0 and h.st >= DROP:
		h.y_jaw = lerpf(h.y_jaw, h.rp_y, clampf(delta * 14.0, 0.0, 1.0))
	if h.has_rp_lunge and _ncx() != null:
		# H3: the host's lunge from the packet (it picked the victim and cleared the rock)
		if h.st == HOLD or h.st == RISE:
			h.lunge = h.lunge.lerp(h.rp_lunge, clampf(delta * 14.0, 0.0, 1.0))
	elif h.st == HOLD:
		_h_lunge(h, delta)
	elif h.st == RISE:
		h.lunge = h.lunge.lerp(Vector3.ZERO, clampf(delta * 3.0, 0.0, 1.0))
	var quiet := Time.get_ticks_msec() - maxi(h.rx_ms, h.state_ms)
	if quiet > 1500:
		_h_rest(h)                   # the host stopped streaming: the attack is over here too


func _h_set(h: FalseHearth, n: int) -> void:
	# every machine: a state change and what it looks and sounds like here
	var old := h.st
	h.st = n
	h.st_t = 0.0
	h.state_ms = Time.get_ticks_msec()
	h.hist.append([h.state_ms, n])
	if _test != "" and h.hist.size() < 400:
		print("[HEARTH] %s %s -> %s" % [h.id, NAMES[old], NAMES[n]])
	match n:
		STIR:
			h.stir_n += 1
			h.jaw_want = deg_to_rad(35.0)
			h.lure_up_want = 2.0
			_kind(h.sfx_chain, "chain_creak", 0.0, 1.0, 45.0)
			_play(h.sfx_rattle, _game_stream(RATTLE), 0.0, 1.0, 45.0)
			_kind(h.sfx_rock, "rockfall", -10.0, 1.0, 60.0)          # sound only: no grit (R10)
			if h.fire is Dictionary and bool((h.fire as Dictionary).get("lit", false)) and map != null and map.has_method("set_fire_lit"):
				map.call("set_fire_lit", h.fire, false, 0.8)
		DROP:
			h.y_from = h.y_jaw
			h.drop_s = clampf((h.ceil_y - h.c.y) / 40.0, 0.35, 0.65)
			_play(h.sfx_jaw, _game_stream(SCRAPE), 0.0, 1.0, 45.0)
		HOLD:
			h.snatched = false
			h.jaw_want = 0.0
			var auth: bool = CoopSync.map_is_authority()
			if auth or not h.has_rp_lunge or _ncx() == null:
				h.lunge_tgt = _pick_lunge(h)
			else:
				h.lunge_tgt = null       # H3: a guest swings where the host's packet says
			h.lunge_max = _lunge_room(h) if auth else LUNGE_MAX
			_play(h.sfx_jaw, _rand_stream("hearth_chomp", CHOMP), 2.0, 0.6, 45.0)
			_play(h.sfx_rattle, _rand_stream("hearth_teeth", TEETH), 0.0, 0.6, 40.0)
		RISE:
			h.y_from = h.y_jaw
			h.jaw_want = deg_to_rad(8.0)
			h.lure_up_want = 0.0
		LURE, REVEALED:
			h.jaw_want = 0.0
			h.lure_up_want = 0.0
	_h_look(h)


func _h_set_revealed(h: FalseHearth) -> void:
	# the quiet end state (a replay): fire out, lure dim red, head at rest, no sound
	h.set_revealed_calls += 1
	h.revealed = true
	h.reached5 = true
	if h.fire is Dictionary and map != null and map.has_method("set_fire_lit"):
		map.call("set_fire_lit", h.fire, false, 0.05)
	h.st = REVEALED
	h.st_t = 0.0
	h.state_ms = Time.get_ticks_msec()
	h.hist.append([h.state_ms, REVEALED])
	h.lunge = Vector3.ZERO
	h.lunge_tgt = null
	h.jaw_want = 0.0
	h.jaw_open = 0.0
	h.lure_up = 0.0
	h.lure_up_want = 0.0
	if h.ceil_known:
		h.y_jaw = _rest_y(h)
	_h_look(h)


func _h_look(h: FalseHearth) -> void:
	# the lure: warm while it baits, gone while it strikes, dim red once it is known
	if h.bulb_mat == null:
		return
	if h.refused:
		h.bulb.visible = false           # H1: a refused hearth is a plain camp
		if is_instance_valid(h.glow):
			h.glow.visible = false
			h.glow.light_energy = 0.0
		return
	var striking := h.st >= DROP and h.st <= RISE
	h.bulb.visible = not striking
	if h.st == REVEALED:
		h.bulb_mat.albedo_color = Color(0.22, 0.03, 0.02)
		h.halo_mat.albedo_color = Color(0.22, 0.03, 0.02, 0.35)
		if is_instance_valid(h.glow):
			h.glow.light_color = Color(0.6, 0.1, 0.07)
	else:
		h.bulb_mat.albedo_color = Color(0.30, 0.18, 0.06)
		h.halo_mat.albedo_color = Color(0.30, 0.18, 0.06, 0.5)
		if is_instance_valid(h.glow):
			h.glow.light_color = GLOW_CRYSTAL if h.biome == 6 else GLOW_VILLAGE


func _rest_y(h: FalseHearth) -> float:
	return h.ceil_y - (REST_REVEALED if h.revealed else REST_DORMANT)


func _find_ceil(h: FalseHearth, force: bool) -> void:
	# a layout entry without "ceil": one up-ray once a player is close enough for rock collision.
	# No-clip (H1): close enough for 0.5 s, and a miss is "try again", never a guess; the chimney
	# ring check follows at once
	var NC = _ncx()
	var near := force or _near_dwell(h, NC != null)
	if not near:
		return
	var w3 := h.get_world_3d()
	if w3 == null:
		return
	var hit := _ray(w3.direct_space_state, h.c + Vector3.UP * 1.6, h.c + Vector3.UP * 60.0)
	if hit.is_empty() and NC != null:
		return                           # H1: no rock found yet: look again in 0.5 s
	h.ceil_y = float((hit["position"] as Vector3).y) if not hit.is_empty() else h.c.y + 30.0
	h.ceil_known = true
	h.y_jaw = _rest_y(h)
	h.maw.visible = true
	print("[HEARTH] %s ceiling %.1f m above the camp" % [h.id, h.ceil_y - h.c.y])
	if NC != null:
		_check_chimney(NC, h)


func _near_dwell(h: FalseHearth, dwell: bool) -> bool:
	# a player within 120 m of the camp (dwell: for 0.5 s; the scan runs every 0.5 s, so the
	# second scan in a row that finds one)
	var near := false
	for p in CoopSync.alive_player_nodes():
		if is_instance_valid(p) and (p as Node3D).global_position.distance_to(h.c) < CEIL_NEAR_R:
			near = true
			break
	if not near:
		h.near_t = 0.0
		return false
	if not dwell:
		return true
	h.near_t += 0.5
	return h.near_t > 0.75


func _check_chimney(NC, h: FalseHearth) -> void:
	# H1, once, when the rock around the camp is collidable: 8 up rays on a 2.5 m ring must hit
	# within 1.5 m of the centre's ceiling (a layout "ceil" must also be 12-34 m up), else the
	# hearth is refused (a plain camp: no stir, no maw). Also H2's wall test: 4 flat rays of 5 m
	# at jaw height; rock there means no lunge at all.
	if h.checked:
		return
	if h.near_t <= 0.75 and not _near_dwell(h, true):
		return
	if not bool(NC.call("solid_at", h.c, 6.0)) or not bool(NC.call("solid_at", Vector3(h.c.x, h.ceil_y, h.c.z), 6.0)):
		return                           # not collidable yet: the next scan
	var w3 := h.get_world_3d()
	if w3 == null:
		return
	var space := w3.direct_space_state
	var why := ""
	var up := h.ceil_y - h.c.y
	if h.ceil_data and (up < CEIL_MIN or up > CEIL_MAX):
		why = "ceiling %.1f m up (12-34 m)" % up
	if why == "" and not _chimney_ok(space, h.c, h.ceil_y):
		why = "the ceiling is not a chimney"
	h.wall_near = _wall_near(space, h.c)
	h.checked = true
	if why != "":
		h.refused = true
		print("[HEARTH] %s refused: %s" % [h.id, why])
		if h.maw != null:
			h.maw.visible = false        # at once (its meshes draw to 140 m, past the visual range)
		if h.stalk != null:
			h.stalk.visible = false
		if is_instance_valid(h.neck_ring):
			h.neck_ring.visible = false
		_h_look(h)
	elif _test != "":
		print("[HEARTH] %s chimney ok (%.1f m up, wall within 5 m: %s)" % [h.id, up, str(h.wall_near)])


func _chimney_ok(space: PhysicsDirectSpaceState3D, c: Vector3, ceil_y: float) -> bool:
	for a in 8:
		var p := c + Vector3(sin(a * TAU / 8.0), 0.0, cos(a * TAU / 8.0)) * CHIMNEY_R + Vector3.UP * 1.6
		var hit := _ray(space, p, Vector3(p.x, ceil_y + CHIMNEY_DY + 0.5, p.z))
		if hit.is_empty() or absf(float((hit["position"] as Vector3).y) - ceil_y) > CHIMNEY_DY:
			return false
	return true


func _wall_near(space: PhysicsDirectSpaceState3D, c: Vector3) -> bool:
	var a := c + Vector3.UP * JAW_FLOOR
	for i in 4:
		var d := Vector3(sin(i * TAU / 4.0), 0.0, cos(i * TAU / 4.0))
		if not _ray(space, a, a + d * WALL_R).is_empty():
			return true
	return false


func _players() -> Array:
	# the alive players in the tree (hearth.flag with loopback, outside its t=20 attack: not the
	# Ghost, whose mirrored view can swing it into the ring on its own)
	var out: Array = []
	for p in CoopSync.alive_player_nodes():
		if not is_instance_valid(p) or not (p as Node3D).is_inside_tree():
			continue
		if _test_ghost_off and p != Game.climber and p.get("peer_id") != null and int(p.get("peer_id")) == _loop_id():
			continue
		out.append(p)
	return out


func _loop_id() -> int:
	var lid = CoopSync.get("LOOP_ID")
	return int(lid) if lid != null else 777


# ============================================================================ the look (every machine)

func _process(delta: float) -> void:
	if hearths.is_empty():
		return
	var lis := _listener()
	for h in hearths:
		if h.built:
			_h_visual(h, delta, lis)


func _h_visual(h: FalseHearth, delta: float, lis: Vector3) -> void:
	if lis.distance_to(h.c) > VIS_R:
		return
	if h.refused:
		# H1: not a chimney: a plain camp (the fire and the kit stay, no head, no lure)
		h.maw.visible = false
		h.bulb.visible = false
		h.stalk.visible = false
		if is_instance_valid(h.glow):
			h.glow.visible = false
			h.glow.light_energy = 0.0
		if is_instance_valid(h.neck_ring):
			h.neck_ring.visible = false
		_h_drip(h, delta, lis)
		return
	if (h.st == LURE or h.st == REVEALED) and h.ceil_known:
		h.y_jaw = lerpf(h.y_jaw, _rest_y(h), clampf(delta * 1.5, 0.0, 1.0))
	h.maw.visible = h.ceil_known
	h.maw.position = Vector3(h.c.x + h.lunge.x, h.y_jaw, h.c.z + h.lunge.z)
	if is_instance_valid(h.neck_ring):
		h.neck_ring.visible = h.ceil_known
		h.neck_ring.position = Vector3(h.c.x + h.lunge.x, h.ceil_y - 0.05, h.c.z + h.lunge.z)
	h.jaw_open = move_toward(h.jaw_open, h.jaw_want, delta * (3.0 if h.jaw_want > h.jaw_open else 9.0))
	if absf(h.jaw_open - h.jaw_shown) > 0.002:
		h.jaw_shown = h.jaw_open
		for jb in h.jaw_bones:
			h.skel.set_bone_pose_rotation(int(jb[0]), (jb[1] as Quaternion) * Quaternion(Vector3.RIGHT, -h.jaw_open))
		for piv in h.mandibles:
			(piv as Node3D).rotation.z = -h.jaw_open
	# the lure: a 5.6 s breath (inhale 2.4 s, exhale 3.2 s), swaying, drifting toward the nearest
	h.breath_t += delta
	var ph := fmod(h.breath_t, BREATH_S)
	if ph < h.last_ph and h.st == LURE and lis.distance_to(h.c) < 30.0:
		_play(h.sfx_lure, _game_stream(S306002), -6.0, 0.55, 26.0)
	h.last_ph = ph
	var k: float = ph / INHALE_S if ph < INHALE_S else 1.0 - (ph - INHALE_S) / (BREATH_S - INHALE_S)
	k = smoothstep(0.0, 1.0, k)
	h.lure_up = move_toward(h.lure_up, h.lure_up_want, delta * (5.0 if h.lure_up_want > h.lure_up else 1.5))
	var drift := Vector3.ZERO
	var tgt := _nearest_body(h.c, 26.0)
	if tgt != Vector3.INF:
		var dv := Vector3(tgt.x - h.c.x, 0.0, tgt.z - h.c.z)
		if dv.length() > 0.1:
			drift = dv.normalized() * 0.3 * k
	h.sway_t += delta
	var sway := Vector3(sin(h.sway_t * 1.1) * 0.12, 0.0, cos(h.sway_t * 0.83) * 0.1)
	var rev := h.st == REVEALED
	var bp := h.c + Vector3(0.0, LURE_Y + (0.1 if rev else 0.25) * k + h.lure_up, 0.0) + drift + sway
	h.bulb.position = bp
	var top := h.maw.position
	var dd := top - bp
	var ln := dd.length()
	h.stalk.visible = h.ceil_known and h.bulb.visible and ln > 0.1
	if h.stalk.visible:
		h.stalk.transform = Transform3D(Basis(Quaternion(Vector3.UP, dd / ln)) * Basis.from_scale(Vector3(1.0, ln, 1.0)), bp + dd * 0.5)
	if is_instance_valid(h.glow):
		h.glow.position = bp
		var striking := h.st >= DROP and h.st <= RISE
		if striking:
			h.glow.light_energy = move_toward(h.glow.light_energy, 0.0, delta * 3.0)
		elif rev:
			h.glow.light_energy = lerpf(0.22, 0.34, k)
		else:
			h.glow.light_energy = lerpf(0.80, 1.35, k)
	_h_drip(h, delta, lis)


func _h_drip(h: FalseHearth, delta: float, lis: Vector3) -> void:
	# every 4-9 s something drips into the bait fire and it hisses (local and cosmetic)
	if h.dip_t > 0.0:
		h.dip_t -= delta
		if h.dip_t <= 0.0:
			_fire_dip(h, false)
	if h.hiss_due >= 0.0:
		h.hiss_due -= delta
		if h.hiss_due < 0.0:
			_kind(h.sfx_fire, "fire_hiss", -8.0, 1.0, 24.0)
			_fire_dip(h, true)
	if not (h.fire is Dictionary) or not bool((h.fire as Dictionary).get("lit", false)):
		return
	h.drip_t -= delta
	if h.drip_t > 0.0:
		return
	h.drip_t = randf_range(4.0, 9.0)
	if lis.distance_to(h.c) > 30.0:
		return
	_kind(h.sfx_fire, "drip", 0.0, randf_range(0.9, 1.1), 24.0)
	h.hiss_due = 0.2


func _fire_dip(h: FalseHearth, down: bool) -> void:
	if not (h.fire is Dictionary):
		return
	var fl = (h.fire as Dictionary).get("flicker", null)
	if not (fl is Object) or not is_instance_valid(fl) or not ("base" in fl):
		return
	if down:
		if not bool((h.fire as Dictionary).get("lit", false)):
			return
		h.dip_base = float(fl.get("base"))
		fl.set("base", h.dip_base * 0.6)
		h.dip_t = 0.3
	elif h.dip_base >= 0.0:
		if bool((h.fire as Dictionary).get("lit", false)):
			fl.set("base", h.dip_base)
		h.dip_base = -1.0


func _nearest_body(p: Vector3, r: float) -> Vector3:
	var best := Vector3.INF
	var bd := r
	var c = Game.climber
	var list: Array = CoopSync.remote_players()
	if is_instance_valid(c) and (c as Node).is_inside_tree():
		list = list + [c]
	for n in list:
		if not is_instance_valid(n):
			continue
		var q: Vector3 = (n as Node3D).global_position
		var d := q.distance_to(p)
		if d < bd:
			bd = d
			best = q
	return best


# ============================================================================ sound kit (own)

static var _snd_cache: Dictionary = {}
static var _snd_man: Dictionary = {}
static var _snd_read := false


static func _bus() -> StringName:
	if AudioServer.get_bus_index("ZondaCave") >= 0:
		return &"ZondaCave"
	if AudioServer.get_bus_index("MainBus") >= 0:
		return &"MainBus"
	return &"Master"


static func _game_stream(path: String) -> AudioStream:
	if _snd_cache.has(path):
		return _snd_cache[path]
	var s: AudioStream = null
	if ResourceLoader.exists(path):
		s = load(path) as AudioStream
	_snd_cache[path] = s
	return s


static func _rand_stream(key: String, paths: Array) -> AudioStream:
	if _snd_cache.has(key):
		return _snd_cache[key]
	var r := AudioStreamRandomizer.new()
	r.random_pitch = 1.12
	var n := 0
	for p in paths:
		var s := _game_stream(str(p))
		if s != null:
			r.add_stream(-1, s)
			n += 1
	var out: AudioStream = r if n > 0 else null
	_snd_cache[key] = out
	return out


static func _file_stream(file: String) -> AudioStream:
	if file.begins_with("res://sfx/") or file.begins_with("res://Art/"):
		return _game_stream(file)
	var path := file if file.begins_with("res://") else DIR + "sfx/" + file
	if _snd_cache.has(path):
		return _snd_cache[path]
	var s: AudioStream = null
	if FileAccess.file_exists(path):
		var bytes := FileAccess.get_file_as_bytes(path)
		if not bytes.is_empty():
			var ext := path.get_extension().to_lower()
			if ext == "ogg":
				s = AudioStreamOggVorbis.load_from_buffer(bytes)
			elif ext == "wav":
				s = AudioStreamWAV.load_from_buffer(bytes)
	_snd_cache[path] = s
	return s


static func _oneshot(kind: String) -> Array:
	var key := "oneshot:" + kind
	if _snd_cache.has(key):
		return _snd_cache[key]
	if not _snd_read:
		_snd_read = true
		var mp := DIR + "sfx/manifest.json"
		if FileAccess.file_exists(mp):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(mp))
			if parsed is Dictionary:
				_snd_man = parsed
	var out: Array = [null, 0.0]
	var ones = _snd_man.get("oneshots", {})
	if ones is Dictionary:
		var list = (ones as Dictionary).get(kind, [])
		if list is Array:
			var r := AudioStreamRandomizer.new()
			r.random_pitch = 1.08
			var n := 0
			var db_sum := 0.0
			for e in list:
				if not (e is Dictionary):
					continue
				var st := _file_stream(str(e.get("file", "")))
				if st == null:
					continue
				r.add_stream(-1, st)
				db_sum += float(e.get("db", 0.0))
				n += 1
			if n > 0:
				out = [r, db_sum / float(n)]
	_snd_cache[key] = out
	return out


static func _play(p: AudioStreamPlayer3D, stream: AudioStream, db: float, pitch: float, max_d: float) -> void:
	if p == null or stream == null or not p.is_inside_tree():
		return
	p.stream = stream
	p.volume_db = db
	p.pitch_scale = pitch
	p.max_distance = max_d
	p.bus = _bus()
	p.play()


static func _kind(p: AudioStreamPlayer3D, kind: String, db: float, pitch: float, max_d: float) -> void:
	# a manifest kind at its mean file db + db; a missing kind stays silent
	var os := _oneshot(kind)
	var st: AudioStream = os[0]
	if st != null:
		_play(p, st, float(os[1]) + db, pitch, max_d)


func _player(h: FalseHearth, max_d: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.max_distance = max_d
	p.unit_size = 6.0
	p.bus = _bus()
	p.position = h.c + Vector3.UP * 6.0
	h.add_child(p)
	return p


# ============================================================================ helpers

func _by_id(id: String):
	for h in hearths:
		if h.id == id:
			return h
	return null


func _dot_tex() -> Texture2D:
	if _dot != null:
		return _dot
	if map != null and map.has_method("soft_dot"):
		var t = map.call("soft_dot")
		if t is Texture2D:
			_dot = t
			return _dot
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(0.5, 0.0)
	gt.width = 32
	gt.height = 32
	_dot = gt
	return _dot


func _ray(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> Dictionary:
	# both-sided: the cave collision is double-sided (underdark.gd backface_collision) because its
	# winding is not consistent, so a back-culled ray falls through real floors and rock
	var q := PhysicsRayQueryParameters3D.create(a, b, 1)
	q.hit_back_faces = true
	return space.intersect_ray(q)


func _listener() -> Vector3:
	var vp := get_viewport()
	if vp != null:
		var cam := vp.get_camera_3d()
		if cam != null and cam.is_inside_tree():
			return cam.global_position
	return Vector3(1e9, 1e9, 1e9)


func _warn(key: String, text: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(text)
	print(text)


func _v(a) -> Vector3:
	if a is Vector3:
		return a
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


# ============================================================================ guest simulation

func guestsim_report() -> Array:
	var out: Array = []
	if hearths.is_empty():
		out.append("SKIP hearth: no hearth (no L.hearths and no synthetic hearth in the recording)")
		return out
	if _gs_live < 0:
		out.append("SKIP live hearth_ stored state only: no live hearth_ in the recording")
	else:
		out.append(("PASS" if _gs_live == 1 else "FAIL") + " live hearth_ stored state only (no set_revealed)")
	if _gs_stir < 0:
		out.append("SKIP fhstir_ started the rattle: no fhstir_ in the recording")
	else:
		out.append(("PASS" if _gs_stir == 1 else "FAIL") + " fhstir_ started the rattle")
	if _gs_late < 0 and map != null:
		# the late-join pass replays hearth_ through the map; if its once-gate kept it from this
		# module, apply the stored event here the same way a late joiner's mapsync does
		var ev: Dictionary = CoopSync.map_events_for(str(map.get("scene_file_path")))
		for k in ev.keys():
			if str(k).begins_with("hearth_"):
				var d = ev[k]
				_on_hearth_event(str(k), d if d is Dictionary else {}, true)
				if _gs_late >= 0:
					out.append(("PASS" if _gs_late == 1 else "FAIL") + " late join: revealed (the stored %s applied as a replay here)" % str(k))
				return out
	if _gs_late < 0:
		out.append("SKIP late join: revealed (no stored hearth_)")
	else:
		out.append(("PASS" if _gs_late == 1 else "FAIL") + " late join: revealed")
	return out


# ============================================================================ dev test (hearth.flag)

func _run_synth() -> void:
	# t = 0 when the test hearth is built. t=5: 6 m away, the lure period; t=20: at the centre, the
	# attack; t=40: after the re-arm, 1.0 m out then 4.8 m out at STIR + 0.9 s; t=55: the stored
	# event, then die and check the reload (solo only)
	await get_tree().create_timer(3.0).timeout
	if not is_inside_tree():
		return
	_tp = 0
	_tn = 0
	_tfails.clear()
	var loop: bool = CoopSync.get("_loopback") == true
	if loop:
		CoopSync.set("_loop_step", 7)
	await _ready_to_test()
	if not is_inside_tree():
		return
	var c = Game.climber
	if not is_instance_valid(c):
		_check("a climber to test with", false)
		_hearth_end()
		return
	c.prevent_player_death = true
	var h = null
	var ring_dir := Vector3.FORWARD
	if _test == "real" and not hearths.is_empty():
		h = hearths[0]
		print("[HEARTH] test on the real hearth %s at %s" % [h.id, str(h.c)])
		_park(c, _nearest_station(h.c), h.c)
		await _wait(1.2)
		ring_dir = _ring_dir(h.c)
		if not h.ceil_known:
			_find_ceil(h, true)
	else:
		var found: Dictionary = await _synth_search(c)
		if not is_inside_tree():
			return
		if found.is_empty():
			_check("synth spot (biome 5-6 station, rock 12-34 m up, floor ring 6 m)", false)
			_hearth_end()
			return
		ring_dir = found["ring_dir"]
		var fc := _v(found["pos"])
		# off the camp before it exists (loopback: facing away, the Ghost stands 3.5 m ahead)
		_park(c, _floor_at(fc + ring_dir * 6.0, fc.y), fc + ring_dir * 12.0 if loop else fc)
		await _wait(0.5)
		h = _add_hearth(found)
		print("[HEARTH] synth at station %d  (C %s, rock %.1f m up)" % [int(found["syn"]), str(h.c), h.ceil_y - h.c.y])
	if h == null:
		_check("the test hearth", false)
		_hearth_end()
		return
	if loop:
		# A-HEARTH-loop: the Ghost stands 3.5 m ahead of wherever my view points, 0.7 s late, so
		# any drift of the view swings it round me, into the ring on its own (it did: the re-armed
		# hearth struck the Ghost alone during the wait at 6 m, before I stepped in). The steps
		# measure MY distance to the camp; the Ghost takes part only in the t=20 attack, where
		# its cbite_ is checked
		_test_ghost_off = true
		print("[HEARTH] loopback: the Ghost takes part in the t=20 attack only")
	var t0 := Time.get_ticks_msec()
	# ---- t=5: 6 m away, no checkpoint banner, the lure period
	await _until_ms(t0 + 5000)
	var p6 := _floor_at(h.c + ring_dir * 6.0, h.c.y)
	_park(c, p6, h.c + ring_dir * 12.0 if loop else h.c)      # loopback: face away (the Ghost stands 3.5 m ahead)
	await _wait(1.0)
	var bl = CoopSync.get("_banner_label")
	var cp_banner := false
	var ys: Array = []
	var ts: Array = []
	var ts0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - ts0 < 12000 and is_inside_tree():
		ys.append(h.bulb.position.y)
		ts.append(Time.get_ticks_msec())
		if bl is Label and (bl as Label).visible and (bl as Label).text.contains("Checkpoint"):
			cp_banner = true
		await get_tree().process_frame
	var per := _period(ts, ys)
	_check("6 m out: no checkpoint banner", not cp_banner)
	_check("6 m out: the lure period 5.6 +-0.3 s", absf(per - BREATH_S) <= 0.3, "%.2f s over 12 s" % per)
	_check("6 m out: it did not stir", h.stir_n == 0)
	# ---- t=20: at the centre (loopback: 1.0 m out facing it, so the Ghost stands within 3.0 m)
	await _until_ms(t0 + 20000)
	if is_instance_valid(h.ember):
		h.ember.queue_free()             # it heals 25 on touch: not part of this measurement
		print("[HEARTH] the camp's ember removed for the damage measurement")
	# 0.3 m off the centre: a player exactly on C has no direction to be shoved in
	var pc: Vector3 = _floor_at(h.c - ring_dir * 1.0, h.c.y) if loop else _floor_at(h.c + ring_dir * 0.3, h.c.y)
	_test_ghost_off = false
	_park(c, pc, h.c + ring_dir * 3.0 if loop else h.c - ring_dir)
	var hp0 := float(c.health)
	var at20 := Time.get_ticks_msec()
	var t_stir := -1
	var t_snap := -1
	var hp_snap := -1.0
	var hp_snatch := -1.0
	var shot_stir := false
	var shot_snap := false
	var park_p: Vector3 = c.global_position
	var slide := 0.0
	var min_y: float = park_p.y
	var cbite_ok := false
	var cbite_seen := false
	while Time.get_ticks_msec() - at20 < 12000 and is_inside_tree():
		var now := Time.get_ticks_msec()
		if t_stir < 0:
			t_stir = _hist_first(h, STIR, at20)
		if t_snap < 0:
			t_snap = _hist_first(h, HOLD, at20)
		if t_stir >= 0 and not shot_stir:
			if now - t_stir >= 450:
				_look_at(c, h.jaw_tip())         # a lantern pointed up: the head in the rock
			if now - t_stir >= 600:
				shot_stir = true
				_shot("user://underdark_hearth_stir.png")
		if t_snap >= 0:
			if not shot_snap:
				_look_at(c, h.jaw_tip() + Vector3.UP * 3.0)     # the frame after, so it renders first
				if now - t_snap >= 120:
					shot_snap = true
					_shot("user://underdark_hearth_snap.png")
			var cp: Vector3 = c.global_position
			slide = maxf(slide, Vector2(cp.x - park_p.x, cp.z - park_p.z).length())
			min_y = minf(min_y, cp.y)
			if hp_snap < 0.0 and now - t_snap >= 150:
				hp_snap = float(c.health)
			if hp_snatch < 0.0 and now - t_snap >= int((SNATCH_AT + 0.15) * 1000.0):
				hp_snatch = float(c.health)
		if loop:
			var ck := _scan_loop_cbite("cbite_" + h.id)
			if ck >= 0:
				cbite_seen = true
				if ck == 1:
					cbite_ok = true
		if t_snap >= 0 and h.st == REVEALED:
			break
		await get_tree().process_frame
	var mult := _dmg_mult()
	var bite1 := hp0 - hp_snap
	var bite2 := hp_snap - hp_snatch
	_check("the attack: SNAP - STIR >= 1.55 s", t_stir >= 0 and t_snap >= 0 and t_snap - t_stir >= 1550, "%.2f s" % ((t_snap - t_stir) / 1000.0) if t_snap >= 0 and t_stir >= 0 else "stir %d snap %d" % [t_stir, t_snap])
	_check("the attack: bite 30 HP", hp_snap >= 0.0 and absf(bite1 - 30.0 * mult) <= 1.0, "%.1f HP (expected %.1f)" % [bite1, 30.0 * mult])
	_check("the attack: snatch 25 HP", hp_snatch >= 0.0 and absf(bite2 - 25.0 * mult) <= 1.0, "%.1f HP (expected %.1f)" % [bite2, 25.0 * mult])
	_check("the attack: alive from full health", float(c.health) > 0.0 and hp0 >= float(c.get("healthMax")) - 0.01, "health %.1f" % float(c.health))
	_check("the attack: slide >= 2.5 m with no fall", slide >= 2.5 and min_y >= park_p.y - 2.0, "slide %.2f m, lowest %.2f m" % [slide, min_y - park_p.y])
	_check("the attack: it ends REVEALED through RISE", h.st == REVEALED and h.reached5 and h.set_revealed_calls == 0)
	if loop:
		_check("loopback: cbite_%s went out to 777 with push, at and r" % h.id, cbite_ok, "seen=%s" % str(cbite_seen))
		_test_ghost_off = true           # out again for the re-arm step (see above)
	# wait for the re-arm well away from it
	_park(c, _floor_at(h.c + ring_dir * 6.0, h.c.y), h.c + ring_dir * 12.0)
	# ---- t=40: after the re-arm, 1.0 m out, then 4.8 m out at STIR + 0.9 s
	await _until_ms(maxi(t0 + 40000, h.rearm_ms + 200))
	var p1 := _floor_at(h.c + ring_dir * 1.0, h.c.y)
	var p48 := _floor_at(h.c + ring_dir * 4.8, h.c.y)
	_park(c, p1, h.c + ring_dir * 3.0 if loop else h.c)
	var at40 := Time.get_ticks_msec()
	var hp40 := float(c.health)
	var stirred: bool = await _until(func(): return _hist_first(h, STIR, at40) >= 0, 3.0)
	var ts40 := _hist_first(h, STIR, at40)
	if ts40 >= 0:
		await _until_ms(ts40 + 900)
	_park(c, p48, h.c + ring_dir * 12.0)
	var hp48 := float(c.health)
	var cb40 := false
	var t48 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t48 < 6000 and is_inside_tree():
		if loop and _scan_loop_cbite("cbite_" + h.id) >= 0:
			cb40 = true
		if h.st == REVEALED and Time.get_ticks_msec() - t48 > 500:
			break
		await get_tree().process_frame
	_check("re-armed: it stirs again (0.9 s rattle) within 3.0 m", stirred and ts40 >= 0 and h.stir_n >= 2, "" if stirred else "no stir after %.1f s at 1.0 m (stirs %d, %s)" % [(Time.get_ticks_msec() - at40) / 1000.0, h.stir_n, NAMES[h.st]])
	_check("stepped out 4.8 m at STIR + 0.9 s: no bite", float(c.health) >= hp48 - 0.01 and float(c.health) >= hp40 - 0.01 and not cb40, "health %.1f -> %.1f" % [hp40, float(c.health)])
	_test_ghost_off = false
	# ---- t=55: the stored event, the live apply, then die and reload
	await _until_ms(t0 + 55000)
	var scene: String = str(map.get("scene_file_path"))
	_check("map_events_for has hearth_%s" % h.id, CoopSync.map_events_for(scene).has("hearth_" + h.id))
	_check("live apply state-only", h.set_revealed_calls == 0 and h.reached5 and h.revealed, "set_revealed calls %d, reached 5 through RISE %s" % [h.set_revealed_calls, str(h.reached5)])
	var gsim := str(CoopSync.get("guestsim"))
	if loop or gsim == "record" or gsim == "play":
		print("[HEARTH] SKIP the death reload (%s)" % ("loopback" if loop else "guestsim " + gsim))
		_hearth_end()
		return
	# take the camp's flask (as the pickup does), write the marker and die
	var OF = load(DIR + "oil_flask.gd")
	var took := false
	if OF != null:
		var tk = OF.call("taken_ids")
		if tk is Dictionary:
			(tk as Dictionary)["oil_" + h.id] = true
			took = true
	var mk := {"phase": "reload", "t": Time.get_unix_time_from_system(), "tp": _tp, "tn": _tn, "fails": _tfails,
			"id": h.id, "syn": h.syn, "c": [h.c.x, h.c.y, h.c.z], "ceil": h.ceil_y, "biome": h.biome, "took": took}
	var f := FileAccess.open(MARK, FileAccess.WRITE)
	if f == null:
		_check("write the reload marker", false)
		_hearth_end()
		return
	f.store_string(JSON.stringify(mk))
	f.close()
	print("[HEARTH] marker written, dying for the reload (flask taken: %s)" % str(took))
	c.prevent_player_death = false
	c.health = 0.0
	c.took_lethal_damage()


func _run_after() -> void:
	# the second half of hearth.flag, after the death reload
	await get_tree().create_timer(4.0).timeout
	if not is_inside_tree():
		return
	await _ready_to_test()
	if not is_inside_tree():
		return
	_tp = int(_mark.get("tp", 0))
	_tn = int(_mark.get("tn", 0))
	_tfails = (_mark.get("fails", []) as Array).duplicate() if _mark.get("fails", []) is Array else []
	var h = _by_id(str(_mark.get("id", "fh1")))
	if h == null:
		_check("after the reload: the test hearth rebuilt", false)
		DirAccess.remove_absolute(MARK)
		_hearth_end()
		return
	print("[HEARTH] after the reload: %s %s, set_revealed calls %d" % [h.id, NAMES[h.st], h.set_revealed_calls])
	_check("after the reload: state 5", h.st == REVEALED and h.revealed)
	var n0: int = h.stir_n
	await get_tree().create_timer(3.0).timeout
	if not is_inside_tree():
		return
	_check("after the reload: no rattle", h.stir_n == n0 and h.st == REVEALED)
	var took := bool(_mark.get("took", false))
	var OF = load(DIR + "oil_flask.gd")
	var still := false
	if OF != null:
		var tk = OF.call("taken_ids")
		still = tk is Dictionary and (tk as Dictionary).has("oil_" + h.id)
	_check("after the reload: oil_%s still taken" % h.id, (not took) or (still and h.flask == null), "took %s, taken now %s, flask placed %s" % [str(took), str(still), str(h.flask != null)])
	DirAccess.remove_absolute(MARK)
	_hearth_end()


func _ready_to_test() -> void:
	# like light.gd: a knight in the tree, the map announced, no saved-run panel open (timers and
	# frames keep running while that panel pauses the game). At most 30 s.
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 30000 and is_inside_tree():
		var c = Game.climber
		var ok: bool = is_instance_valid(c) and (c as Node).is_inside_tree()
		if ok and map != null and map.has_method("load_announced"):
			ok = map.call("load_announced") == true
		if ok and CoopSync.has_method("save_prompt_open"):
			ok = CoopSync.call("save_prompt_open") != true
		if ok:
			return
		await get_tree().process_frame


func _hearth_end() -> void:
	_test_ghost_off = false
	var c = Game.climber
	if is_instance_valid(c):
		c.prevent_player_death = false   # a test never leaves the player invincible
	if _tfails.is_empty():
		print("[HEARTH] test done %d/%d PASS" % [_tp, _tn])
	else:
		print("[HEARTH] test done %d/%d FAIL: %s" % [_tp, _tn, ", ".join(_tfails)])
	_test = ""


func _check(what: String, ok: bool, detail: String = "") -> void:
	_tn += 1
	if ok:
		_tp += 1
	else:
		_tfails.append(what)
	print("[HEARTH] %s %s%s" % ["PASS" if ok else "FAIL", what, ("   (" + detail + ")") if detail != "" else ""])


func _synth_search(c) -> Dictionary:
	# the first biome 5 or 6 shelf or terrace station (25 m or more from a checkpoint) whose
	# up-ray from floor +1.6 hits rock 12-34 m up and whose floor holds on a 6 m ring (8
	# directions, no drop over 2 m). Checked with rays after parking there (1 s for collision).
	var L = map.get("L")
	var stations: Array = (L as Dictionary).get("stations", []) if L is Dictionary else []
	var cps: Array = []
	for cp in (L as Dictionary).get("checkpoints", []):
		if cp is Dictionary and (cp as Dictionary).has("pos"):
			cps.append(_v(cp["pos"]))
	var parked := Vector3(1e9, 1e9, 1e9)
	var tried := 0
	for i in stations.size():
		var sd = stations[i]
		if not (sd is Dictionary) or not (sd as Dictionary).has("pos"):
			continue
		var b := int(sd.get("biome", -1))
		var kind := str(sd.get("kind", ""))
		if (b != 5 and b != 6) or (kind != "shelf" and kind != "terrace"):
			continue
		var sp := _v(sd["pos"])
		var cpd := 1e9
		for q in cps:
			cpd = minf(cpd, sp.distance_to(q))
		if cpd < 25.0 or not _hazard_clear(sp, L):
			continue
		if sp.distance_to(parked) > 100.0:
			_park(c, sp, sp + Vector3.FORWARD)
			parked = sp
			await _wait(1.0)
			if not is_inside_tree():
				return {}
		tried += 1
		var r := _synth_check(sp)
		if not r.is_empty():
			r["syn"] = i
			r["biome"] = b
			r["id"] = "fh1"
			print("[HEARTH] synth search: %d stations checked" % tried)
			return r
	print("[HEARTH] synth search: %d stations checked, none passed" % tried)
	return {}


func _hazard_clear(sp: Vector3, L: Dictionary) -> bool:
	# the synthetic camp must not sit on a trap or a creature trigger: the test parks the player
	# on it and measures every hit point (layout data only)
	for e in L.get("centipedes", []):
		if e is Dictionary and e.get("trigger", null) is Array and (e["trigger"] as Array).size() >= 2:
			if sp.distance_to(_v(e["trigger"][0])) < float(e["trigger"][1]) + 25.0:
				return false
	var wh = L.get("waking_husk", null)
	if wh is Dictionary and (wh as Dictionary).has("trigger"):
		if sp.distance_to(_v(wh["trigger"])) < float(wh.get("r", 6.0)) + 15.0:
			return false
	for e in L.get("droppers", []):
		if e is Dictionary and e.get("trip", null) is Array and (e["trip"] as Array).size() >= 2:
			if sp.distance_to(_v(e["trip"][0])) < float(e["trip"][1]) + 8.0:
				return false
	for key in ["crumbles", "vents", "spikes", "ice", "falls", "platforms"]:
		for e in L.get(key, []):
			if e is Dictionary and (e as Dictionary).has("pos"):
				if sp.distance_to(_v(e["pos"])) < float(e.get("r", 0.0)) + 10.0:
					return false
	for e in L.get("spiders", []):
		if e is Dictionary and (e as Dictionary).has("anchor"):
			var a := _v(e["anchor"])
			if Vector2(sp.x - a.x, sp.z - a.z).length() < 14.0 and absf(sp.y - a.y) < 30.0:
				return false
	return true


func _synth_check(sp: Vector3) -> Dictionary:
	var w3 := (map as Node3D).get_world_3d() if map is Node3D else null
	if w3 == null:
		return {}
	var space := w3.direct_space_state
	var down := _ray(space, sp + Vector3.UP * 2.0, sp + Vector3.DOWN * 4.0)
	if down.is_empty():
		return {}
	var f: Vector3 = down["position"]
	var up := _ray(space, f + Vector3.UP * 1.6, f + Vector3.UP * 41.6)
	if up.is_empty():
		return {}
	var ceil_y := float((up["position"] as Vector3).y)
	var head := ceil_y - f.y
	if head < 12.0 or head > 34.0:
		return {}
	var best_dir := Vector3.ZERO
	for a in 8:
		var dir := Vector3(sin(a * TAU / 8.0), 0.0, cos(a * TAU / 8.0))
		for rr in [1.5, 3.0, 4.5, 6.0]:
			var q: Vector3 = f + dir * float(rr)
			var hit := _ray(space, q + Vector3.UP * 2.5, q + Vector3.DOWN * 4.0)
			if hit.is_empty():
				return {}
			var hy := float((hit["position"] as Vector3).y)
			if hy < f.y - 2.0 or hy > f.y + 2.5:
				return {}
		if best_dir == Vector3.ZERO:
			best_dir = dir
	if _ncx() != null:
		# no-clip: the spot must pass the hearth's own H1 chimney check, and have no rock within
		# 5 m (H2: else it could never lunge, and the test's snatch needs one)
		if not _chimney_ok(space, f, ceil_y) or _wall_near(space, f):
			return {}
		# and the full 2.5 m lunge both ways along the test's line (H2's three rays)
		var jaw := f + Vector3.UP * JAW_FLOOR
		for sgn in [1.0, -1.0]:
			for dh in [0.0, 3.0, 6.0]:
				var a: Vector3 = jaw + Vector3.UP * float(dh)
				if not _ray(space, a, a + best_dir * float(sgn) * (LUNGE_MAX + LUNGE_CLEAR)).is_empty():
					return {}
	return {"pos": [f.x, f.y, f.z], "ceil": ceil_y, "ring_dir": best_dir}


func _nearest_station(p: Vector3) -> Vector3:
	var L = map.get("L")
	var best := p + Vector3(0.0, 0.0, 8.0)
	var bd := 1e9
	if L is Dictionary:
		for sd in (L as Dictionary).get("stations", []):
			if sd is Dictionary and (sd as Dictionary).has("pos") and str(sd.get("kind", "")) != "hard":
				var q := _v(sd["pos"])
				if q.distance_to(p) < bd:
					bd = q.distance_to(p)
					best = q
	return best


func _ring_dir(p: Vector3) -> Vector3:
	var w3 := (map as Node3D).get_world_3d() if map is Node3D else null
	if w3 == null:
		return Vector3.FORWARD
	for a in 8:
		var dir := Vector3(sin(a * TAU / 8.0), 0.0, cos(a * TAU / 8.0))
		var q := p + dir * 6.0
		var hit := _ray(w3.direct_space_state, q + Vector3.UP * 2.5, q + Vector3.DOWN * 4.0)
		if not hit.is_empty() and absf(float((hit["position"] as Vector3).y) - p.y) < 2.0:
			return dir
	return Vector3.FORWARD


func _floor_at(p: Vector3, ref_y: float) -> Vector3:
	var w3 := (map as Node3D).get_world_3d() if map is Node3D else null
	if w3 == null:
		return p
	var hit := _ray(w3.direct_space_state, Vector3(p.x, ref_y + 2.5, p.z), Vector3(p.x, ref_y - 4.0, p.z))
	return hit["position"] if not hit.is_empty() else Vector3(p.x, ref_y, p.z)


func _period(ts: Array, ys: Array) -> float:
	# the lure's breath period from its height: the mean time between two highest points or two
	# lowest points (each an extreme over a full +-1.2 s window)
	if ts.size() < 3:
		return -1.0
	var ext: Array = []                  # [ms, is_top]
	for i in ys.size():
		var y: float = ys[i]
		var t: int = ts[i]
		if t - int(ts[0]) < 1200 or int(ts[-1]) - t < 1200:
			continue
		for want_top in [true, false]:
			var ok := true
			for j in range(i - 1, -1, -1):
				if t - int(ts[j]) > 1200:
					break
				if (float(ys[j]) > y) if want_top else (float(ys[j]) < y):
					ok = false
					break
			if ok:
				for j in range(i + 1, ys.size()):
					if int(ts[j]) - t > 1200:
						break
					if (float(ys[j]) >= y) if want_top else (float(ys[j]) <= y):
						ok = false
						break
			if ok:
				var dup := false
				for e in ext:
					if bool(e[1]) == want_top and t - int(e[0]) < 2000:
						dup = true
				if not dup:
					ext.append([t, want_top])
	var sum := 0.0
	var n := 0
	for kind in [true, false]:
		var last := -1
		for e in ext:
			if bool(e[1]) == kind:
				if last >= 0:
					sum += float(int(e[0]) - last)
					n += 1
				last = int(e[0])
	if n == 0:
		return -1.0
	return sum / float(n) / 1000.0


func _hist_first(h: FalseHearth, st: int, since: int) -> int:
	for e in h.hist:
		if int(e[0]) >= since and int(e[1]) == st:
			return int(e[0])
	return -1


func _scan_loop_cbite(key: String) -> int:
	# loopback: the cbite_ the map sent to the Ghost (777), still in the loop queue (0.7 s)
	# -1 none, 0 without push / at / r, 1 complete
	var qu = CoopSync.get("_loop_queue")
	if not (qu is Array):
		return -1
	var res := -1
	for e in qu:
		if not (e is Array) or (e as Array).size() < 2 or not (e[1] is Dictionary):
			continue
		var m: Dictionary = e[1]
		if str(m.get("t", "")) != "mapev" or str(m.get("k", "")) != key:
			continue
		var d = m.get("d", {})
		if not (d is Dictionary) or str((d as Dictionary).get("who", "")) != "777":
			continue
		res = 1 if ((d as Dictionary).has("push") and (d as Dictionary).has("at") and (d as Dictionary).has("r")) else maxi(res, 0)
	return res


func _park(c, pos: Vector3, look_at_p: Vector3) -> void:
	if map != null and map.has_method("debug_park"):
		map.call("debug_park", pos + Vector3.UP * 1.0)
	else:
		c.set_climber_state(c.defaultClimberState)
		c.velocity = Vector3.ZERO
		c.health = c.healthMax
		c.teleport_to_location(pos + Vector3.UP * 1.0)
	var d := look_at_p - pos
	d.y = 0.0
	if d.length() > 0.1:
		_set_view(c, Vector3(0.0, atan2(-d.x, -d.z), 0.0))


func _look_at(c, target: Vector3) -> void:
	var cam = c.get("Camera")
	var eye: Vector3 = (cam as Node3D).global_position if cam is Node3D else (c as Node3D).global_position + Vector3.UP * 0.77
	var d := target - eye
	if d.length() < 0.1:
		return
	d = d.normalized()
	_set_view(c, Vector3(asin(clampf(d.y, -0.999, 0.999)), atan2(-d.x, -d.z), 0.0))


func _set_view(c, ang: Vector3) -> void:
	# PlayerCamera.CameraAngles and the Camera node (set_camera_rotation would also turn the
	# PlayerCamera node, so the view would turn twice for a second)
	var pc = c.get("PlayerCamera")
	if pc is Node3D:
		pc.set("CameraAngles", ang)
		(pc as Node3D).rotation = Vector3.ZERO
	var cam = c.get("Camera")
	if cam is Node3D:
		(cam as Node3D).rotation = ang
	c.global_rotation = Vector3.ZERO


func _shot(path: String) -> void:
	if map != null and map.has_method("debug_shot"):
		map.call("debug_shot", path)


func _dmg_mult() -> float:
	var bs = Game.get("active_balance_settings")
	if bs is Object and is_instance_valid(bs):
		var m = (bs as Object).get("damage_multiplier")
		if m != null:
			return float(m) * 0.01
	return 1.0


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _until_ms(ms: int) -> void:
	while Time.get_ticks_msec() < ms and is_inside_tree():
		await get_tree().process_frame


func _until(cond: Callable, timeout: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not bool(cond.call()):
		if Time.get_ticks_msec() - t0 > int(timeout * 1000.0) or not is_inside_tree():
			return false
		await get_tree().process_frame
	return true
