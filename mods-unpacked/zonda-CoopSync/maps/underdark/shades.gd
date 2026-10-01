extends Node
# ============================================================================================
# THE UNDERDARK: the Shades (ZondaCoopSync 5.0, feature module "shades", owner B5)
#
# Tall (3.1 m), thin, wet-black figures in three dark stretches of the rift. They move only in
# the dark, in jerky bursts, and stand a few steps past where your light ends (the lit edge is
# light k 0.2, 0.8 x the glow radius). A beam on one freezes it with a hiss, then it slides back
# out of the light. When a player's lantern goes off or runs dry, a Shade within 22 m standing in
# the dark SHRIEKS for 1.1 s (it straightens, spreads its arms, two pinprick eyes open), then
# rushes. Light stops it dead, on the victim's own screen too (the map's cbite_ "nl" rule). If it
# reaches you in the dark: arms up with a gargle (0.35 s), 20 HP, then it slinks home for 6 s.
#
# Loaded by underdark.gd (FEATURES): setup(map) BEFORE add_child. Every call into another
# builder's file is made at runtime (has_method / call / get), so this file parses whatever
# state they are in:
#   map (underdark.gd): register_stream("sh"), register_bites("sh_"), register_threats,
#       creature_bit, hint_once, debug_park, debug_shot, set_light_mode, coop_map_event, soft_dot
#   CoopSync.light_field (light.gd): light_at, player_lit, player_dry, player_dry_ms,
#       away_from_light, local_lit, static_k, stats
#   Without a LightField the Shades never wake (logged once): nothing can hunt unfairly.
#
# PUBLIC API
#   homes() -> Array             [{"id": "sh_<n>", "band": String, "pos": Vector3}], id order
#   awake_count() -> int         Shades not DORMANT (var shades_awake too, refreshed at 10 Hz)
#   threat_positions() -> Array  chest points of the awake Shades (the heartbeat only)
#   bite_origin(id) -> Vector3, play_bite(id), bite_opts(id) -> Dictionary
#                                the map's bite routing for "sh_<n>" ({"heavy": true, "push": -1,
#                                "r": 2.2, "nl": true}: 40 damage, the game halves it to 20 HP)
#   run_test_phase(done: Callable)   lightfear.flag phase 1 (light.gd calls it through call());
#                                it ends with done.call(passed, total)
#   guestsim_report() -> Array   the 2.11 lines; on_session_ended(); on_exit()
#   noclip_points() -> Array     the no-clip probe's sample (spec 5.2), group "zonda_nc"
#   noclip_test_homes() -> Array one home per band [{"id", "band", "pos": Vector3, "floored"}]
#
# HOMES come from layout DATA only (no rays, no randomness), so a late joiner or a new
# authority derives the same list: main-route shelf or terrace stations of the band's biome
# inside the band's depth, at least 30 m from any checkpoint, 10 m from any flask, with
# light_field.static_k(station + 1.2 m up) < 0.1, picked middle-out in route order (the middle
# candidate first, then alternately one later and one earlier) at least 28 m apart, then numbered
# sh_1..sh_11 in band order and route order. On the v5.0 layout: stations 64, 65, 70 /
# 132, 135, 138, 141 / 174, 182, 189, 191 (TEST_HOMES, asserted by the dev test).
# A station can sit just off the edge of its shelf, metres above the rock under it (sh_3, sh_4,
# sh_6 and sh_10 float 4.7 to 10.7 m on v5.0), so once a player has been within 120 m of a home
# for 0.5 s (its rock is solid then) every machine moves that home onto the nearest floor at the
# station's height within 4 m, else onto the floor straight below (_snap_home: both-sided rays in
# a fixed order, so every machine gets the same spot). The pick of stations stays data only.
#
# SYNC: no persistent events. The authority runs the brains (10 Hz, in _physics_process) and the
# movement (_physics_process) and streams cx "sh": per Shade [] while DORMANT, else
# PackedFloat32Array([st, x, y, z, yaw]), nothing at all while every Shade is DORMANT. A state
# change runs the sounds, eyes and pose on every machine. Guests lerp to the stream and HOLD
# still in STALK, TELL or RUSH while their own light is on the Shade (light_field.local_lit).
# A reload rebuilds every Shade at home; there is nothing to save.
#
# NO-CLIP (5.0 creature no-clip spec, group NC-5; every change sits behind noclip.gd's
# is_enabled(), loaded at runtime, with the code above as the other branch):
#   G1 the floor walk is NC.walk_step with SHADE_PROF (probes start in proven air, an L-shaped
#      path, 2.5 m of headroom). Under lower rock (2.5 to 3.2 m) the Shade CROUCHES (knees, up to
#      0.35 m) and then bends at the hip (at most 60 degrees) instead of refusing; a step whose
#      hunched lean would push the head into rock ahead is refused. G2 the per-tick move is
#      NC.l_step (rise then advance, advance then drop). G3 _rush_reach: the same walk, 250 rays
#      at most, cached 0.5 s per target. G4 homes need 2.5 m of headroom; a home with no floor
#      stays asleep (home_ok), a Shade still standing on a floating station moves with its home
#      only while nobody sees it. G5 TELL and STRIKE arms shrink to the free rock around them.
#      G6 teleports are counted (tp) and streamed; guests render 120 ms back between two samples,
#      walk rises and drops as L steps, and snap on a new tp or a gap over 3 m.
#   7A Shades cannot enter rock lower than their envelope (2.5 m), stay in their band's zone,
#      and (the map's part_of(p) / in_squeeze(p), NC-3) never step into a squeeze or another
#      part, nor hunt a player in another part.
#   G7 test points: the module joins "zonda_nc": noclip_points(), noclip_test_homes(); counters
#      tells, strikes, rush_refused (NC.note, both branches).
# ============================================================================================

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const S306002 := "res://sfx/soundsnap/monster_idle/306002-Creature-Oxbow-Breaths-Wet-Deep_1.wav"
const S306004 := "res://sfx/soundsnap/monster_idle/306004-Creature-Oxbow-Breaths-Wet-Fast.wav"
const S_SNARL2 := "res://sfx/soundsnap/monster_attack/306011-Creature-Oxbow-Snarls-Breaths-Aggressive_2.wav"
const S_SNARL4 := "res://sfx/soundsnap/monster_attack/306013-Creature-Oxbow-Snarls-Breaths-Aggressive_4.wav"

# [name, biome, depth fraction top, depth fraction bottom, Shades]
const BANDS := [["ossuary_low", 1, 0.72, 0.98, 3], ["fungal_low", 2, 0.67, 0.97, 4], ["drowned_high", 4, 0.02, 0.42, 4]]
const TEST_HOMES := [64, 65, 70, 132, 135, 138, 141, 174, 182, 189, 191]
const HOME_CP_MIN := 30.0
const HOME_FLASK_MIN := 10.0
const HOME_K_MAX := 0.1
const HOME_SPACING := 28.0
const HOME_SNAP_R := 120.0         # a home drops onto its rock once a player is this close...
const HOME_SNAP_DWELL := 0.5       # ...for this long (the rock near a teleport turns solid first)
const HOME_SNAP_RING := 4.0        # the nearest floor at station height this far out...
const HOME_SNAP_MAX := 12.0        # ...else the floor straight below, at most this far down
const HOME_SNAP_HEAD := 2.0        # a floor spot needs this much headroom free of rock
const HOME_SNAP_HEAD_NC := 2.5     # ...with the no-clip guard on (G4: the hunch minimum)
# no-clip (G1): the floor walk's profile (room_from is set per call) and the hunch
const NC_PATH := "res://mods-unpacked/zonda-CoopSync/maps/underdark/noclip.gd"
const SHADE_PROF := {"kind": "shade", "probes": [0.45, 1.4, 2.4], "lead": 0.3, "step_up": 2.2, "max_drop": 2.5, "head": 2.5,
		"room_max": 3.4, "tall": 3.0, "min_ny": 0.5}
const ROOM_MAX := 3.4
const UPRIGHT_TOP := 3.04          # hip 1.5 + torso, neck and head 1.54: the head top standing
const HIP_H := 1.5
const UPPER_LEN := 1.54
const CROUCH_MAX := 0.35           # the knees take the first 0.35 m of a hunch
const HUNCH_MAX_COS := 0.5         # then the hip bends forward, at most 60 degrees
const FRONT_RAY := 1.9
const RR_CAP := 250                # _rush_reach: rays per call at most (G3)
# the volume the model fills, checked with shapes at every new spot (the walk's probes are thin rays: a pillar or a
# lip a hand's breadth beside the centre line slipped past them)
const BODY_R := 0.14               # the torso is 0.14 wide (the shoulders sit at 0.17, the arms are thin and swing)
const BODY_BOT := 0.45             # feet and shins rest on the floor: a slope or a pebble down there is contact, not clipping
const BODY_TOP := 2.4              # the upright torso and shoulders reach this high over the feet
const BODY_STEP := 0.14            # the L path is checked every 0.14 m: the capsules overlap, so nothing wider than 0.24 m slips between two
const HEAD_R := 0.12               # the head is 0.08 wide (0.092 across): a little over it
const RENDER_MS := 120             # guests draw the host this far back (G6)
const GUEST_SNAP := 3.0

const DORMANT := 0
const STALK := 1
const FROZEN := 2
const RIM := 3
const TELL := 4
const RUSH := 5
const STRIKE := 6
const RETREAT := 7
const NAMES := ["DORMANT", "STALK", "FROZEN", "RIM", "TELL", "RUSH", "STRIKE", "RETREAT"]

const BRAIN_DT := 0.1
const WAKE_R := 70.0
const SLEEP_R := 85.0
const STALK_R := 45.0
const STALK_SPEED := 2.6
const HOME_SPEED := 1.5
const BURST_MOVE := 0.4
const BURST_PAUSE := 0.25
const STANDOFF := 3.5            # how close it creeps to an unlit player it may not rush yet
const RIM_MIN := 0.6
const LIT_STEP_K := 0.2          # it never steps where its chest would be this lit
const FREEZE_K := 0.25           # chest or head this lit: FROZEN
const EDGE_OUT_K := 0.15         # EDGE ends below this: RIM
const FROZEN_HOLD := 0.6
const EDGE_SPEED := 1.1
const EDGE_MAX_S := 6.0
const HISS_CD_MS := 2500
const HISS_TEAM_MS := 400
const TELL_S := 1.1
const TELL_R := 22.0
const TELL_CP_R := 20.0
const STRUCK_GAP_MS := 6000
const RUSH_COOL_MS := 5000         # no new TELL at a player a teammate's light just saved
const RUSH_FAIL_MS := 8000         # no new TELL at a player a rush could not reach
const REACH_DY := 2.0              # a player this far off its strike height needs a walkable rush line
const REACH_CACHE_MS := 500
const DRY_GRACE_MS := 2500
const UNLIT_GRACE_MS := 4000
const RUSH_SPEED := 11.0
const RUSH_MAX := 3.0
const STRIKE_R := 1.8
const STRIKE_HIT_R := 2.2
const STRIKE_WIND := 0.35
const STRIKE_DMG := 40.0
const RETREAT_S := 6.0
const RETREAT_SPEED := 4.0
const STEP_UP := 2.2
const MAX_DROP := 2.5
const ZONE_R := 14.0
const CP_KEEP_OUT := 18.0
const STUCK_S := 8.0
const STUCK_NOBODY_R := 25.0
const VIS_RANGE := 110.0
const CHEST := 1.6
const HEAD := 2.9
const STALE_MS := 1500
const HINT_GAP_MS := 6500

const PLAN_MOVED := 0
const PLAN_BLOCKED := 1
const PLAN_LIT := 2

# pose per state: [torso hunch, neck, arm forward, arm spread, elbow] (radians)
const POSE := [
	[-0.35, -0.55, 0.05, 0.06, 0.1],
	[-0.25, -0.35, 0.12, 0.08, 0.2],
	[0.1, 0.3, 1.35, 0.35, 1.2],
	[-0.2, -0.25, 0.08, 0.1, 0.15],
	[0.08, 0.4, 0.2, 1.35, 0.1],
	[-0.6, -0.1, 1.1, 0.25, 0.3],
	[-0.05, -0.15, 2.7, 0.2, 0.3],
	[-0.45, -0.5, -0.2, 0.05, 0.1],
]

var map: Node = null
var shades: Array = []
var bands: Array = []              # {"name", "biome", "n", "top", "bot", "route": [Vector3]}
var shades_awake := 0
var _cps: Array = []
var _flask_pos: Array = []
var _home_info: Array = []         # per Shade {"band", "station", "pos", "k", "cp"}
var _inert_logged := false
var _warned: Dictionary = {}
var _brain_t := 0.0
var _hint_t := 0.0
var _hints: Dictionary = {}        # hint key -> ms shown (this machine)
var _hint_last_ms := -100000
var _locks: Dictionary = {}        # player key -> Shade index (one rusher per player)
var _struck: Dictionary = {}       # player key -> ms of the last strike
var _rush_cool: Dictionary = {}    # player key -> ms until which no Shade TELLs at them
var _snap_t := 0.0
var _grace_start: Dictionary = {}  # player key -> ms they first became an unlit TELL candidate
var _grace_done: Dictionary = {}   # player key -> true once the 4 s hint grace is used
var _team_hiss_ms := -100000
var _rx_ms := -100000
var _was_auth := true
var _mat_body: StandardMaterial3D = null
var _mat_eye: StandardMaterial3D = null
var _meshes: Dictionary = {}
var _dot: Texture2D = null
# dev test
var _test_only := ""
var _test_hold := false
var _testing := false
var _tlog: Array = []              # [ms, id, state or -1 for EDGE]
var _tp := 0
var _tn := 0
var _tfails: Array = []
# guest simulation (2.11)
var _force_local_lit := -1         # the hold self-test only: -1 real, 0 dark, 1 lit
var _gs_pkts := 0
var _gs_last: Dictionary = {}      # Shade index -> Vector3 of the last sh packet
var _gs_hold_frames := 0
var _gs_hold_moves := 0
# no-clip
var _test_no_ghost := false        # the lightfear test with loopback: the Ghost is no target
var _nc_f := -1
var _nc_c = null
var _rr_rays := 0                  # _rush_reach's ray estimate for the current call
var _part_logged := false


class Shade extends Node3D:
	var idx := 0
	var id := ""
	var band := 0
	var home := Vector3.ZERO
	var floored := false             # the home is on its rock (see the header)
	var snap_dwell := 0.0
	var reach_key := ""              # _rush_reach, cached for 0.5 s per player
	var reach_ms := -100000
	var reach_ok := false
	var key := 0
	var st := 0
	var st_t := 0.0
	var sim := Vector3.ZERO
	var goal := Vector3.ZERO
	var goal_speed := 0.0
	var yaw := 0.0
	var target: Node3D = null
	var tkey := ""
	var grace_hold := false
	var edge := false
	var edge_t := 0.0
	var burst_t := 0.0
	var moving := false
	var strike_done := false
	var hiss_ms := -100000
	var hiss_n := 0
	var stuck_t := 0.0
	var stuck_ref := Vector3.ZERO
	var k_now := 0.0
	# guests
	var rp_pos := Vector3.ZERO
	var rp_yaw := 0.0
	var held := false
	var lit_t := 0.0
	var hold_pos := Vector3.ZERO
	# the look
	var root: Node3D = null
	var hip: Node3D = null
	var torso: Node3D = null
	var neck: Node3D = null
	var head: Node3D = null
	var thighs: Array = []
	var knees: Array = []
	var shoulders: Array = []
	var elbows: Array = []
	var eyes: Array = []
	var voice: AudioStreamPlayer3D = null
	var amb: AudioStreamPlayer3D = null
	var fx: AudioStreamPlayer3D = null
	var vis_yaw := 0.0
	var prev_pos := Vector3.ZERO
	var spd := 0.0
	var was_moving := false
	var walk_ph := 0.0
	var lurch := 0.0
	var twitch := 0.0
	var twitch_t := 2.0
	var fx_t := 0.0
	var whisper_t := 5.0
	var breath_t := 3.0
	var crack_t := 6.0
	# no-clip
	var home_ok := true              # G4: false when no floor with headroom was found for the home
	# P7's pick: false when the snap found no floor with the hunch headroom (2.5 m), guard on or off
	var test_ok := true
	var home_move := false          # the home snapped while it stood seen on the old station
	var home_room := 3.4             # headroom at the home floor point
	var part := -1                   # 7A: the map part its home is in (-1 unknown)
	var part_known := false
	var via := Vector3.ZERO          # G1/G2: the corner of the planned L step
	var via_for := Vector3.INF       # the goal that via belongs to
	var room := 3.4                  # headroom where it stands (the tall probe starts below it)
	var room_to := 3.4               # min(headroom at the goal, a low lip on the way): the hunch
	var room_goal := 3.4
	var room_vis := 3.4              # the drawn hunch's room
	var crouch_d := 0.0              # how far the hip is lowered now
	var crouch_a := 0.0              # the knee angle applied to the legs last frame
	var pause_t := 0.0               # every heading refused: no planning for 0.5 s
	var tp := 0                      # G6: teleports so far (streamed)
	var arm_side_k := 1.0            # G5
	var arm_up_k := 1.0
	var front_free := 9.0            # rock ahead of the upper body (the lean never reaches it)
	var front_t := 0.0
	var front_at := Vector3.INF
	var front_yaw := 0.0
	var tips: Array = []             # the middle finger pivot of each hand
	# guests (G6)
	var buf: Array = []              # [arrival ms, pos, yaw, tp, room], newest last, 4 at most
	var shown_tp := -1
	var g_room := 3.4
	var was_held := false
	var glide_to := Vector3.INF
	var glide_ok := true


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
	# fairness and guard counters (a no-op unless the no-clip probe is measuring)
	var NC = _nc()
	if NC != null:
		NC.call("note", "shade", key, n)


func _ncx():
	# the helper while the guard is on (THE UNDERDARK live, guard switch on), else null; cached
	# per frame
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
	var L = m.get("L")
	if not (L is Dictionary):
		push_warning("[SHADE] the map has no layout: no Shades")
		return
	_derive(L)
	_build_materials()
	for i in _home_info.size():
		var hi: Dictionary = _home_info[i]
		var s := Shade.new()
		s.idx = i
		s.id = "sh_%d" % (i + 1)
		s.band = int(hi["band"])
		s.home = hi["pos"]
		s.key = 7700 + i
		s.sim = s.home
		s.goal = s.home
		s.via = s.home
		s.rp_pos = s.home
		s.stuck_ref = s.home
		s.prev_pos = s.home
		s.position = s.home
		s.yaw = float(i) * 2.39
		s.vis_yaw = s.yaw
		s.top_level = true
		s.name = "Shade_" + s.id
		s.whisper_t = randf_range(3.0, 7.0)
		add_child(s)
		_build_rig(s)
		shades.append(s)
	_register()
	add_to_group("zonda_nc")           # the no-clip probe samples noclip_points() (G7)
	var parts: Array = []
	for bi in bands.size():
		parts.append("%s %d" % [str(bands[bi]["name"]), _band_count(bi)])
	print("[Underdark] shades: %d (%s)" % [shades.size(), ", ".join(parts)])


func _register() -> void:
	if map == null:
		return
	if map.has_method("register_stream"):
		map.call("register_stream", "sh", _send_sh, _recv_sh)
	else:
		_warn("register_stream", "[SHADE] the map has no register_stream: guests will not see the Shades move")
	if map.has_method("register_bites"):
		map.call("register_bites", "sh_", self)
	else:
		_warn("register_bites", "[SHADE] the map has no register_bites: teammates cannot be bitten")
	if map.has_method("register_threats"):
		map.call("register_threats", self)


func _derive(L: Dictionary) -> void:
	# the homes, zones and band limits, from layout data only (see the header)
	_cps.clear()
	for c in L.get("checkpoints", []):
		if c is Dictionary and (c as Dictionary).has("pos"):
			_cps.append(_v(c["pos"]))
	_flask_pos.clear()
	for o in L.get("oil", []):
		if o is Dictionary and (o as Dictionary).has("pos"):
			_flask_pos.append(_v(o["pos"]))
	var lf = _lf()
	var use_lf: bool = lf != null and lf.has_method("static_k")
	var flames: Array = []
	if not use_lf:
		flames = _data_flames(L)
		print("[SHADE] no LightField static_k at setup: homes use the layout flame data (%d flames)" % flames.size())
	var stations: Array = L.get("stations", [])
	var strata: Array = L.get("strata", [])
	for bi in BANDS.size():
		var B: Array = BANDS[bi]
		var band := {"name": str(B[0]), "biome": int(B[1]), "n": int(B[4]), "top": 0.0, "bot": 0.0, "route": []}
		bands.append(band)
		var top := 0.0
		var bot := 0.0
		var found := false
		for sd in strata:
			if sd is Dictionary and int((sd as Dictionary).get("biome", -1)) == int(B[1]):
				top = float(sd["top"])
				bot = float(sd["bottom"])
				found = true
				break
		if not found:
			push_warning("[SHADE] no stratum for biome %d: band %s has no Shades" % [int(B[1]), str(B[0])])
			continue
		var h := top - bot
		var y_top := top - float(B[2]) * h
		var y_bot := top - float(B[3]) * h
		band["top"] = y_top
		band["bot"] = y_bot
		var route: Array = band["route"]
		var cands: Array = []
		for i in stations.size():
			var sd = stations[i]
			if not (sd is Dictionary) or not (sd as Dictionary).has("pos"):
				continue
			var kind := str(sd.get("kind", ""))
			if kind == "hard" or int(sd.get("biome", -1)) != int(B[1]):
				continue
			var p := _v(sd["pos"])
			if p.y > y_top or p.y < y_bot:
				continue
			route.append(p)
			if kind != "shelf" and kind != "terrace":
				continue
			var cpd := _min_dist(p, _cps)
			if cpd < HOME_CP_MIN or _min_dist(p, _flask_pos) < HOME_FLASK_MIN:
				continue
			var k := _home_k(lf, use_lf, flames, p + Vector3.UP * 1.2)
			if k >= HOME_K_MAX:
				continue
			cands.append([i, p, k, cpd])
		var picked: Array = []
		var m := cands.size()
		if m > 0:
			var mid := floori((m - 1) / 2.0)
			var order: Array = [mid]
			for j in range(1, m):
				if mid + j < m:
					order.append(mid + j)
				if mid - j >= 0:
					order.append(mid - j)
			# v5.1 (the home re-pick): with the generator's room per station (L.home_room, walkable m2),
			# the roomiest homes first, so no Shade lives in a pocket it can only ambush from
			var rooms = L.get("home_room", null)
			if rooms is Dictionary and not (rooms as Dictionary).is_empty():
				order.sort_custom(func(a, b): return int(rooms.get(str(int(cands[a][0])), 0)) > int(rooms.get(str(int(cands[b][0])), 0)))
			for oi in order:
				var c: Array = cands[oi]
				var ok := true
				for q in picked:
					if (c[1] as Vector3).distance_to(q[1]) < HOME_SPACING:
						ok = false
						break
				if ok:
					picked.append(c)
				if picked.size() >= int(B[4]):
					break
		picked.sort_custom(func(a, b): return int(a[0]) < int(b[0]))
		for c in picked:
			_home_info.append({"band": bi, "station": int(c[0]), "pos": c[1], "k": float(c[2]), "cp": float(c[3])})


func _home_k(lf, use_lf: bool, flames: Array, p: Vector3) -> float:
	if use_lf:
		return float(lf.call("static_k", p))
	var best := 0.0
	for f in flames:
		var d: float = p.distance_to(f[0])
		if d < float(f[1]):
			best = maxf(best, 1.0 - d / float(f[1]))
	return best


func _data_flames(L: Dictionary) -> Array:
	# the LightField's flame table (contract 2.3) from layout data, used only when the LightField
	# is not there at setup: fires, bells, torch props, dying-light torches, the altar, warm lamps
	var out: Array = []
	for f in L.get("fires", []):
		if f is Dictionary and (f as Dictionary).has("pos"):
			out.append([_v(f["pos"]), clampf(6.5 * float(f.get("scale", 1.0)), 1.2, 7.0)])
	for b in L.get("bells", []):
		if b is Dictionary and (b as Dictionary).has("pos"):
			out.append([_v(b["pos"]), 7.0])
	for p in L.get("props", []):
		if p is Dictionary and str(p.get("scene", "")).contains("Torch") and (p as Dictionary).has("pos"):
			out.append([_v(p["pos"]), 5.0])
	for dl in L.get("dying_lights", []):
		if dl is Dictionary:
			for lp in dl.get("lights", []):
				out.append([_v(lp), 7.0])
	for a in L.get("altar", []):
		if a is Dictionary and (a as Dictionary).has("pos"):
			out.append([_v(a["pos"]), 8.0])
	for l in L.get("lights", []):
		if not (l is Dictionary) or not (l as Dictionary).has("pos"):
			continue
		var col = l.get("color", [0, 0, 0])
		var r := float(l.get("range", 0.0))
		var warm := false
		if col is Array and (col as Array).size() >= 3:
			warm = float(col[0]) >= 0.95 and float(col[1]) >= 0.4 and float(col[1]) <= 0.8 and float(col[2]) <= 0.45 and r <= 26.0
		if warm or str(l.get("kind", "")) == "lamp":
			out.append([_v(l["pos"]), 0.5 * r])
	return out


func _band_count(bi: int) -> int:
	var n := 0
	for hi in _home_info:
		if int(hi["band"]) == bi:
			n += 1
	return n


# ============================================================================ public API

func homes() -> Array:
	var out: Array = []
	for s in shades:
		out.append({"id": s.id, "band": str(bands[s.band]["name"]), "pos": s.home})
	return out


func awake_count() -> int:
	var n := 0
	for s in shades:
		if s.st != DORMANT:
			n += 1
	return n


func threat_positions() -> Array:
	var out: Array = []
	for s in shades:
		if s.st != DORMANT:
			out.append(s.position + Vector3.UP * CHEST)
	return out


func bite_origin(id: String) -> Vector3:
	var s = _by_id(id)
	if s == null:
		return Vector3.ZERO
	return s.sim if CoopSync.map_is_authority() else s.position


func play_bite(id: String) -> void:
	# guests: the host already struck; show the slam of the arms here
	var s = _by_id(id)
	if s == null or CoopSync.map_is_authority():
		return
	if s.st != STRIKE:
		_remote_state(s, STRIKE)
	s.fx_t = STRIKE_WIND


func bite_opts(_id: String) -> Dictionary:
	# 40 damage (the game halves it to 20 HP), heavy, the default 0.45 m nudge; the victim drops it
	# more than 3.2 m from "at" on their own screen, or while their own lantern is (or was in the
	# last 0.3 s) lit
	return {"heavy": true, "push": -1.0, "r": STRIKE_HIT_R, "nl": true}


func on_session_ended() -> void:
	# only a machine that was a guest takes over (the old host already runs the true positions)
	if CoopSync.map_is_authority() and not _was_auth:
		_take_over()
		_was_auth = true


func on_exit() -> void:
	_testing = false


# ============================================================================ no-clip test (G7)

func noclip_points() -> Array:
	# (a guest's teleport counter is the host's streamed one plus this machine's own: the guest also snaps a
	# dormant Shade's home onto its floor when nobody sees it, and that is a declared teleport too)
	# one entry per Shade for the no-clip probe (spec 5.2): centre = the chest (1.6 m, lowered
	# with the crouch), extremities = feet (+0.1), the head top as drawn (hunched), and in TELL
	# and STRIKE both finger tips. A Shade past VIS_RANGE of this camera is not drawn (its meshes
	# end there) and reports vis = false.
	var out: Array = []
	var auth: bool = CoopSync.map_is_authority()
	var view := "host" if auth else "guest"
	var lis := _listener()
	for s in shades:
		if not s.is_inside_tree():
			continue
		var base: Vector3 = s.global_position
		var xs: Array = [base + Vector3.UP * 0.1]
		var xn: Array = ["feet"]
		if is_instance_valid(s.head):
			xs.append(s.head.global_transform * Vector3(0.0, 0.34, 0.0))
			xn.append("head")
		if s.st == TELL or s.st == STRIKE:
			for t in s.tips:
				if is_instance_valid(t):
					xs.append((t as Node3D).global_transform * Vector3(0.0, -0.3, 0.0))
					xn.append("hand")
		var xc: Array = []
		var xg: Array = []
		for _i in xs.size():
			xc.append(0)
			xg.append(false)
		out.append({"kind": "shade", "id": s.id, "view": view,
				"c": [base + Vector3.UP * (CHEST - s.crouch_d)], "cn": ["chest"], "seg": [-1], "sp": 0.0,
				"x": xs, "xn": xn, "xc": xc, "xg": xg,
				"vis": s.is_visible_in_tree() and base.distance_to(lis) <= VIS_RANGE, "wl": false,
				"tp": s.tp if auth else s.shown_tp + s.tp, "st": str(NAMES[clampi(s.st, 0, NAMES.size() - 1)]),
				"fx": {"room": minf(s.room, s.room_to) if auth else s.g_room, "crouch": s.crouch_d}})
	return out


func noclip_test_homes() -> Array:
	# P7: one home per band (the first Shade of each band, in id order, whose home is not known
	# to lack a floor with the hunch headroom: test_ok, the same 2.5 m rays in the baseline and the
	# guarded launch, never home_ok, which only the guard sets), so both launches pick the same homes:
	# [{"id": "sh_<n>", "band": String, "pos": Vector3 (its station, layout data: the same spot on
	# every launch, whatever headroom rule snapped the home), "floored": bool}]
	var out: Array = []
	for bi in bands.size():
		for s in shades:
			if s.band == bi and s.test_ok:
				var st_pos: Vector3 = _home_info[s.idx]["pos"] if s.idx < _home_info.size() else s.home
				out.append({"id": s.id, "band": str(bands[bi]["name"]), "pos": st_pos, "floored": s.floored})
				break
	return out


# ============================================================================ authority brain

func _physics_process(delta: float) -> void:
	if shades.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var auth: bool = CoopSync.map_is_authority()
	if auth != _was_auth:
		_was_auth = auth
		if auth:
			_take_over()
	_snap_t += delta
	if _snap_t >= 0.25:
		_snap_homes(_snap_t)
		_snap_t = 0.0
	if auth:
		_brain_t += delta
		if _brain_t >= BRAIN_DT:
			var dt := _brain_t
			_brain_t = 0.0
			_brain(dt)
		for s in shades:
			_move(s, delta)
	CoopSync.perf_add(Time.get_ticks_usec() - t0)


func _take_over() -> void:
	# a new authority (the host left): every Shade goes on from the host's last streamed position
	var NC = _ncx()
	for s in shades:
		s.sim = s.rp_pos
		s.position = s.rp_pos
		s.prev_pos = s.rp_pos
		s.goal = s.sim
		s.via = s.sim
		s.buf.clear()
		s.pause_t = 0.0
		if NC != null:
			# the walk needs the headroom where it stands (the host's floor point; measured here)
			var w3: World3D = (s as Node3D).get_world_3d()
			s.room = _room_at(w3.direct_space_state, s.sim) if w3 != null else HOME_SNAP_HEAD_NC
			s.room_to = s.room
			s.room_goal = s.room
		s.target = null
		s.tkey = ""
		s.stuck_t = 0.0
		s.stuck_ref = s.sim
		s.held = false
		if s.st != DORMANT:
			s.st = STALK
			s.st_t = 0.0
			s.moving = false
		for e in s.eyes:
			(e as Node3D).visible = false
	_locks.clear()


func _brain(dt: float) -> void:
	var lf = _lf()
	if lf == null:
		if not _inert_logged:
			_inert_logged = true
			print("[SHADE] no LightField (light.gd): the Shades stay asleep")
		for s in shades:
			if s.st != DORMANT:
				_set_state(s, DORMANT)
		shades_awake = 0
		return
	var now := Time.get_ticks_msec()
	var players: Array = []
	for p in CoopSync.alive_player_nodes():
		if is_instance_valid(p) and (p as Node3D).is_inside_tree():
			if _test_no_ghost and _is_ghost(p):
				continue                     # the loopback Ghost: see _run_test
			players.append(p)
	_wake(players)
	var nc: bool = _ncx() != null
	var n := 0
	for s in shades:
		if s.st != DORMANT:
			n += 1
			# 7A: a Shade hunts only in its own part of the map (players past a squeeze are not
			# its prey), when the map tells parts apart
			_think(s, dt, _in_part(s, players) if nc else players, now, lf)
	shades_awake = n


func _wake(players: Array) -> void:
	# a Shade wakes when a living player is within 70 m, sleeps past 85 m; per band at most
	# min(n, 1 + living players) are awake, the nearest ones. No-clip (G4): a Shade whose home is
	# not on its rock yet (or has no floor, or it still stands on the old floating station) never
	# wakes: no standing in mid-air, no drop in view.
	var nc: bool = _ncx() != null
	for bi in bands.size():
		var cap := mini(int(bands[bi]["n"]), 1 + players.size())
		var ranked: Array = []
		for s in shades:
			if s.band != bi:
				continue
			if _test_hold or (_test_only != "" and s.id != _test_only):
				if s.st != DORMANT:
					_set_state(s, DORMANT)
				continue
			var d := _nearest_dist(s.sim, players)
			var lim: float = SLEEP_R if s.st != DORMANT else WAKE_R
			if nc and s.st == DORMANT and (not s.floored or not s.home_ok or s.home_move):
				continue
			if d <= lim:
				ranked.append([d, s])
			elif s.st != DORMANT:
				_set_state(s, DORMANT)
			elif d > VIS_RANGE and s.sim.distance_to(s.home) > 0.5:
				_reset_home(s)           # nobody can see it: back to its home, quietly
		ranked.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
		for j in ranked.size():
			var s: Shade = ranked[j][1]
			if j < cap:
				if s.st == DORMANT:
					_set_state(s, STALK)
			elif s.st != DORMANT:
				_set_state(s, DORMANT)


func _think(s: Shade, dt: float, players: Array, now: int, lf) -> void:
	s.st_t += dt
	s.pause_t = maxf(0.0, s.pause_t - dt)
	var kc := _k(lf, s.sim + Vector3.UP * CHEST, s.key, 0.3)
	var kh := _k(lf, s.sim + Vector3.UP * HEAD, s.key, 0.2)
	var k := maxf(kc, kh)
	s.k_now = k
	if s.st != FROZEN and k >= FREEZE_K:
		if (s.st == TELL or s.st == RUSH or s.st == STRIKE) and s.target != null and not _target_lit(s.target, lf):
			_rush_cool[_pkey(s.target)] = now + RUSH_COOL_MS    # a teammate's light (or a fire) saved them
		_set_state(s, FROZEN)            # light stops it dead
		return
	match s.st:
		STALK:
			_think_stalk(s, dt, players, now, lf)
		RIM:
			_think_rim(s, players, now, lf)
		FROZEN:
			_think_frozen(s, dt, players, lf, k)
		TELL:
			_think_tell(s, players, lf)
		RUSH:
			_think_rush(s, players, lf)
		STRIKE:
			_think_strike(s, players, now, lf)
		RETREAT:
			_think_retreat(s, lf)
	_stuck_check(s, dt, players)


func _think_stalk(s: Shade, dt: float, players: Array, now: int, lf) -> void:
	var tp = _tell_target(s, players, now, lf)
	if tp != null:
		_begin_tell(s, tp)
		return
	var tgt = _nearest(s.sim, players, STALK_R)
	s.target = tgt
	if tgt == null:
		# nobody near: back home at a walk
		if s.sim.distance_to(s.home) < 1.5:
			s.goal = s.sim
			return
		if _plan_around(s, _flat(s.home - s.sim), HOME_SPEED, true, lf) == PLAN_LIT:
			_set_state(s, RIM)
		return
	if s.grace_hold or (not _target_lit(tgt, lf) and _flat_dist(s.sim, tgt) <= STANDOFF):
		_face(s, tgt)
		_set_state(s, RIM)
		return
	s.burst_t -= dt
	if s.burst_t <= 0.0:
		s.moving = not s.moving
		s.burst_t = BURST_MOVE if s.moving else BURST_PAUSE
	if not s.moving:
		s.goal = s.sim
		_face(s, tgt)
		return
	if _ncx() != null and _under_ledge(s, tgt):
		s.goal = s.sim                   # 2.6: it waits under the ledge and faces them
		_face(s, tgt)
		return
	if _plan_around(s, _flat(_pos(tgt) - s.sim), STALK_SPEED, true, lf) == PLAN_LIT:
		_face(s, tgt)
		_set_state(s, RIM)


func _think_rim(s: Shade, players: Array, now: int, lf) -> void:
	var tp = _tell_target(s, players, now, lf)
	if tp != null:
		_begin_tell(s, tp)
		return
	s.goal = s.sim
	var tgt = _nearest(s.sim, players, STALK_R)
	s.target = tgt
	if tgt == null:
		if s.st_t >= RIM_MIN:
			_set_state(s, STALK)         # nobody left: home
		return
	_face(s, tgt)
	if s.st_t < RIM_MIN or s.grace_hold:
		return
	if not _target_lit(tgt, lf) and _flat_dist(s.sim, tgt) <= STANDOFF + 0.5:
		return
	# the light moved on: follow while the next step is dark
	var dir := _flat(_pos(tgt) - s.sim)
	if dir.length() > 0.01 and _k(lf, s.sim + dir.normalized() * 0.35 + Vector3.UP * CHEST, s.key, 0.3) < LIT_STEP_K:
		_set_state(s, STALK)


func _think_frozen(s: Shade, dt: float, players: Array, lf, k: float) -> void:
	s.goal = s.sim
	if not s.edge:
		if s.st_t >= FROZEN_HOLD:
			s.edge = true
			s.edge_t = 0.0
			if _testing:
				_tlog.append([Time.get_ticks_msec(), s.id, -1])
				print("[SHADE] %s EDGE" % s.id)
		return
	s.edge_t += dt
	if k < EDGE_OUT_K or s.edge_t > EDGE_MAX_S:
		_set_state(s, RIM)
		return
	# slide out of the light, backing away from it
	var away := Vector3.ZERO
	if lf != null and lf.has_method("away_from_light"):
		var a = lf.call("away_from_light", s.sim + Vector3.UP * CHEST)
		if a is Vector3:
			away = _flat(a)
	if away.length() < 0.01:
		# right on a beam axis: out sideways (the side is fixed per Shade, so it never dithers)
		var near = _nearest(s.sim, players, 60.0)
		if near != null:
			var from := _flat(s.sim - _pos(near))
			if from.length() > 0.01:
				away = from.normalized().cross(Vector3.UP) * (1.0 if s.idx % 2 == 0 else -1.0)
	if away.length() < 0.01:
		return
	away = away.normalized()
	var moved := false
	for ang in [0.0, 0.7, -0.7, 1.4, -1.4]:
		if _plan(s, away.rotated(Vector3.UP, float(ang)), EDGE_SPEED, false, lf, 99.0) == PLAN_MOVED:
			s.yaw = atan2(away.x, away.z)   # it keeps facing the light it backs out of
			moved = true
			break
	if not moved and _ncx() != null:
		s.pause_t = 0.5                  # 2.6 refusal pause


func _think_tell(s: Shade, players: Array, lf) -> void:
	s.goal = s.sim
	var t = s.target
	if t == null or not players.has(t) or _target_lit(t, lf) or _flat_dist(s.sim, t) > TELL_R + 4.0:
		_set_state(s, RIM)               # the lantern came back on (or they are gone): no rush
		return
	_face(s, t)
	if s.st_t >= TELL_S:
		_set_state(s, RUSH)


func _think_rush(s: Shade, players: Array, lf) -> void:
	var t = s.target
	if t == null or not players.has(t):
		_set_state(s, STALK)
		return
	if _target_lit(t, lf):
		_set_state(s, FROZEN)            # a lantern relit in its face stops it dead
		return
	if s.st_t >= RUSH_MAX or not _floor_under(t):
		# it could not reach them (a rope, a ledge, rock in the way): no new shriek at them for 8 s,
		# so a TELL always promises a rush that can land
		_rush_cool[_pkey(t)] = Time.get_ticks_msec() + RUSH_FAIL_MS
		_set_state(s, STALK)
		return
	var d := _flat_dist(s.sim, t)
	var dy := absf(_pos(t).y - (s.sim.y + 0.8))
	if d <= STRIKE_R and dy < 2.0:
		_face(s, t)
		_set_state(s, STRIKE)
		return
	var nc: bool = _ncx() != null
	if nc and _under_ledge(s, t):
		s.goal = s.sim                   # 2.6: under a ledge it cannot climb: it waits and faces
		_face(s, t)
		return
	if nc and s.pause_t > 0.0:
		return                           # 2.6: every heading was refused a moment ago
	var dir := _flat(_pos(t) - s.sim)
	var r := _plan(s, dir, RUSH_SPEED, false, lf, maxf(0.2, d - 1.2))
	if r != PLAN_MOVED:
		var moved := false
		for ang in [0.6, -0.6]:
			if _plan(s, dir.rotated(Vector3.UP, float(ang)), RUSH_SPEED, false, lf, maxf(0.2, d - 1.2)) == PLAN_MOVED:
				moved = true
				break
		if not moved:
			_note("rush_refused")
			if nc:
				s.pause_t = 0.5              # 2.6 refusal pause


func _think_strike(s: Shade, players: Array, now: int, lf) -> void:
	s.goal = s.sim
	var t = s.target
	if t == null or not players.has(t):
		_set_state(s, RETREAT)
		return
	if _target_lit(t, lf):
		_set_state(s, FROZEN)
		return
	_face(s, t)
	if s.st_t < STRIKE_WIND or s.strike_done:
		return
	s.strike_done = true
	var d := _flat_dist(s.sim, t)
	var dy := absf(_pos(t).y - (s.sim.y + 0.8))
	if d <= STRIKE_HIT_R and dy < 2.2:
		_struck[_pkey(t)] = now
		_bite(s, t)
	elif _testing:
		print("[SHADE] %s strike missed (%.2f m)" % [s.id, d])
	_set_state(s, RETREAT)


func _think_retreat(s: Shade, lf) -> void:
	if s.st_t >= RETREAT_S:
		_set_state(s, STALK)
		return
	if s.sim.distance_to(s.home) < 1.0:
		s.goal = s.sim
		return
	_plan_around(s, _flat(s.home - s.sim), RETREAT_SPEED, false, lf)


func _begin_tell(s: Shade, p) -> void:
	s.target = p
	s.tkey = _pkey(p)
	_locks[s.tkey] = s.idx
	_set_state(s, TELL)


func _tell_target(s: Shade, players: Array, now: int, lf):
	# the nearest player this Shade may shriek at now (null if none), and s.grace_hold while the
	# nearest candidate is inside the once-per-load 4 s "lantern off" grace
	s.grace_hold = false
	var best = null
	var bd := TELL_R
	for p in players:
		var pp := _pos(p)
		var d := pp.distance_to(s.sim + Vector3.UP * 0.8)
		if d > TELL_R:
			continue
		if _near_cp(pp, TELL_CP_R):
			continue
		var key := _pkey(p)
		if now - int(_struck.get(key, -100000)) < STRUCK_GAP_MS:
			continue
		if _locks.has(key) and int(_locks[key]) != s.idx:
			continue
		if _target_lit(p, lf):
			continue
		if now < int(_rush_cool.get(key, 0)):
			continue                     # a rush at them was just stopped by other light, or failed
		if not _floor_under(p):
			continue                     # on a rope or over a drop: no rush could follow
		if absf(pp.y - (s.sim.y + 0.8)) >= REACH_DY:
			if s.reach_key != key or now - s.reach_ms >= REACH_CACHE_MS:
				s.reach_key = key
				s.reach_ms = now
				s.reach_ok = _rush_reach(s, pp)
			if not s.reach_ok:
				continue                 # on a ledge above or below with no way there: no shriek
		if _player_dry(p, lf):
			if _player_dry_ms(p, lf) < DRY_GRACE_MS:
				continue
		elif not _grace_done.has(key):
			if not _grace_start.has(key):
				_grace_start[key] = now
				if _testing:
					print("[SHADE] unlit grace starts for %s" % key)
			if now - int(_grace_start[key]) < UNLIT_GRACE_MS:
				s.grace_hold = true
				continue
			_grace_done[key] = true
		if d < bd:
			bd = d
			best = p
	return best


func _bite(s: Shade, t: Node3D) -> void:
	_note("strikes")                     # the no-clip probe's fairness count (both branches)
	if _testing:
		print("[SHADE] %s STRIKE hits %s" % [s.id, str(t.name)])
	if map != null and map.has_method("creature_bit"):
		map.call("creature_bit", t, STRIKE_DMG, s.id)
		return
	_warn("creature_bit", "[SHADE] the map has no creature_bit: only the local player can be bitten")
	var c = Game.climber
	if t == c and is_instance_valid(c) and not c.get("coop_spectating"):
		c.take_damage(STRIKE_DMG)
		var away: Vector3 = c.global_position - s.sim
		away.y = 0.0
		if away.length() > 0.05:
			c.additional_velocity_next_frame += away.normalized() * 1.2


func _stuck_check(s: Shade, dt: float, players: Array) -> void:
	var wants := s.st == RETREAT or s.st == RUSH or (s.st == STALK and (s.target != null or s.sim.distance_to(s.home) > 1.5))
	if not wants or s.sim.distance_to(s.stuck_ref) > 0.5:
		s.stuck_t = 0.0
		s.stuck_ref = s.sim
		return
	s.stuck_t += dt
	if s.stuck_t >= STUCK_S and _nearest_dist(s.sim, players) > STUCK_NOBODY_R:
		var NC = _ncx()
		if NC != null and bool(NC.call("seen_by_any", [s.sim + Vector3.UP * 1.6, s.sim + Vector3.UP * 2.8, s.home + Vector3.UP * 1.6])):
			return                       # goal 3: never a teleport anyone could see; it waits
		_reset_home(s)
		_set_state(s, STALK)


func _set_state(s: Shade, n: int) -> void:
	if s.st == n:
		return
	var old := s.st
	s.st = n
	s.st_t = 0.0
	s.goal = s.sim
	s.edge = false
	s.strike_done = false
	if n == TELL:
		_note("tells")                   # the telegraph (the no-clip probe: strikes <= tells)
	if n == STALK:
		s.moving = false
		s.burst_t = 0.0
	if n != TELL and n != RUSH and n != STRIKE:
		_release(s)
	if n == DORMANT:
		s.target = null
	_enter_fx(s, n)
	if _testing:
		_tlog.append([Time.get_ticks_msec(), s.id, n])
		print("[SHADE] %s %s -> %s" % [s.id, NAMES[old], NAMES[n]])


func _release(s: Shade) -> void:
	if s.tkey != "" and _locks.has(s.tkey) and int(_locks[s.tkey]) == s.idx:
		_locks.erase(s.tkey)
	s.tkey = ""


func _reset_home(s: Shade) -> void:
	# a teleport home (callers make sure nobody sees it, except the dev tests): counted, so guests
	# snap instead of gliding through rock (G6)
	if s.sim.distance_to(s.home) > 0.01 or s.position.distance_to(s.home) > 0.01:
		s.tp += 1
		_note("tps")
	s.sim = s.home
	s.goal = s.home
	s.via = s.home
	s.rp_pos = s.home
	s.position = s.home
	s.prev_pos = s.home
	s.stuck_t = 0.0
	s.stuck_ref = s.home
	s.home_move = false
	s.room = s.home_room
	s.room_to = s.home_room
	s.room_goal = s.home_room
	s.pause_t = 0.0


func _snap_homes(dt: float) -> void:
	# every machine, 4 times a second until every home is on its rock: a home whose station a
	# player has been within 120 m of for 0.5 s moves onto its floor (_snap_home)
	var players: Array = []
	var any := false
	for s in shades:
		if not s.floored or s.home_move:
			any = true
			break
	if not any:
		return
	for p in CoopSync.alive_player_nodes():
		if is_instance_valid(p) and (p as Node3D).is_inside_tree():
			players.append(p)
	var NC = _ncx()
	for s in shades:
		if s.home_move:
			# its home moved onto the rock while someone could see it on the old station: it goes
			# there as soon as nobody can see either spot (G4, goal 3)
			var old: Vector3 = s.position
			if NC == null or not bool(NC.call("seen_by_any", [old + Vector3.UP * 1.6, old + Vector3.UP * 2.8, s.home + Vector3.UP * 1.6, s.home + Vector3.UP * 2.8])):
				if s.st == DORMANT:
					_reset_home(s)           # an awake one (a guest's streamed view) is not moved
				s.home_move = false
			continue
		if s.floored:
			continue
		if players.is_empty() or _nearest_dist(s.home, players) > HOME_SNAP_R:
			s.snap_dwell = 0.0
			continue
		s.snap_dwell += dt
		if s.snap_dwell >= HOME_SNAP_DWELL:
			_snap_home(s)


func _snap_home(s: Shade) -> bool:
	# a home's station can sit just off the edge of its shelf, metres above the rock below it,
	# where every step is a drop the floor walk refuses. The home moves to the nearest floor at
	# the station's height (-1.0 to +0.5 m) within 4 m (rings every 0.5 m, 16 directions in a
	# fixed order, so every machine picks the same spot), else to the floor straight below it
	# (at most 12 m). Both-sided rays; a spot needs 2 m of headroom (2.5 m with the no-clip guard,
	# which also marks a home with no such floor home_ok = false: it never wakes). A Shade still
	# standing on the old home moves with it (no-clip: only while nobody sees either spot). False:
	# no rock loaded around it yet, try again later.
	if s.floored:
		return true
	var w3 := s.get_world_3d()
	if w3 == null:
		return false
	var space := w3.direct_space_state
	var old := s.home
	var NC = _ncx()
	if NC != null and not bool(NC.call("solid_at", old, 8.0)):
		return false                     # its rock is not collidable yet: try again later
	var fr: Array = _home_floor(space, old, _head_top())
	var f = fr[0]
	if f == null and not bool(fr[1]):
		return false
	# P7 (noclip_test_homes) picks homes by the hunch headroom rule in every launch: the guarded one
	# has just run it; the baseline (guard off, 2.3 m above) runs it once more, for the pick only
	if NC != null:
		s.test_ok = f != null
	elif _nc() != null:
		s.test_ok = _home_floor(space, old, HOME_SNAP_HEAD_NC)[0] != null
	s.floored = true
	if f == null:
		if NC != null:
			# G4: no floor with headroom: it stays asleep (it could only float and refuse every step)
			s.home_ok = false
			print("[SHADE] %s home has no floor: it stays asleep" % s.id)
			return true
		print("[SHADE] %s home kept at its station (no floor with headroom beside or under it)" % s.id)
		return true
	var fv: Vector3 = f
	if NC != null:
		s.home_room = _room_at(space, fv)
	if fv.distance_to(old) < 0.05:
		if s.sim.distance_to(fv) < 0.05:
			s.room = s.home_room
			s.room_to = s.home_room
			s.room_goal = s.home_room
		return true
	s.home = fv
	var here: Vector3 = s.sim if CoopSync.map_is_authority() else s.rp_pos
	if here.distance_to(old) < 0.6 and s.position.distance_to(old) < 0.6:
		if NC != null and bool(NC.call("seen_by_any", [old + Vector3.UP * 1.6, old + Vector3.UP * 2.8, fv + Vector3.UP * 1.6, fv + Vector3.UP * 2.8])):
			s.home_move = true           # someone could see it drop: it moves once nobody can
		else:
			_reset_home(s)               # counts a teleport (G6)
	if fv.distance_to(old) >= 0.5:
		print("[SHADE] %s home on the floor %.1f m out and %.1f m down from its station" % [s.id, Vector2(fv.x - old.x, fv.z - old.z).length(), old.y - fv.y])
	return true


func _headroom(space: PhysicsDirectSpaceState3D, f: Vector3) -> bool:
	# no rock in the 2 m over a floor point (from 0.3 m up; a hit under rock means the ray started
	# inside it). No-clip: up to 2.5 m above the floor, the hunch minimum the walk also asks for
	return _free_to(space, f, _head_top())


func _head_top() -> float:
	# how high over a floor point the headroom ray reaches (see _headroom)
	return HOME_SNAP_HEAD_NC if _ncx() != null else 0.3 + HOME_SNAP_HEAD


func _free_to(space: PhysicsDirectSpaceState3D, f: Vector3, top: float) -> bool:
	return _ray(space, f + Vector3.UP * 0.3, f + Vector3.UP * top).is_empty()


func _home_floor(space: PhysicsDirectSpaceState3D, old: Vector3, top: float) -> Array:
	# _snap_home's search: [the floor point or null, whether any rock was hit (false: not loaded yet)].
	# The nearest floor at the station's height (-1.0 to +0.5 m) within 4 m (rings every 0.5 m, 16
	# directions in a fixed order), else the floor straight below (at most 12 m); either needs no rock
	# from 0.3 m up to top over it
	var any_hit := false
	var r := 0.0
	while r <= HOME_SNAP_RING + 0.01:
		var nd := 1 if r < 0.01 else 16
		for a in nd:
			var p0 := old + Vector3(sin(a * TAU / 16.0), 0.0, cos(a * TAU / 16.0)) * r
			var hit := _ray(space, p0 + Vector3.UP * 1.0, p0 + Vector3.DOWN * 1.5)
			if hit.is_empty():
				continue
			any_hit = true
			var q: Vector3 = hit["position"]
			if q.y - old.y >= -1.0 and q.y - old.y <= 0.5 and _free_to(space, q, top):
				return [q, true]
		r += 0.5
	var hd := _ray(space, old + Vector3.UP * 0.5, old + Vector3.DOWN * HOME_SNAP_MAX)
	if not hd.is_empty() and _free_to(space, hd["position"], top):
		return [hd["position"], true]
	return [null, any_hit or not hd.is_empty()]


func _room_at(space: PhysicsDirectSpaceState3D, f: Vector3) -> float:
	# the headroom over a floor point, measured up to ROOM_MAX (the walk's room_from)
	var hit := _ray(space, f + Vector3.UP * 0.1, f + Vector3.UP * ROOM_MAX)
	if hit.is_empty():
		return ROOM_MAX
	return clampf(float((hit["position"] as Vector3).y) - f.y, 0.1, ROOM_MAX)


# ============================================================================ movement

func _move(s: Shade, delta: float) -> void:
	# per physics tick: toward the step the brain planned (it arrives within one brain tick)
	if s.st == DORMANT:
		return
	var NC = _ncx()
	if NC != null:
		# G2: the L path the walk proved (rise then advance, advance then drop), never the
		# diagonal through a lip; via belongs to the goal it was planned for
		if s.via_for != s.goal and s.via_for != Vector3.INF:
			s.room = minf(s.room, s.room_to)     # a step left half-walked: only the lower room is sure
			s.via_for = Vector3.INF
		var via: Vector3 = s.via if s.via_for == s.goal else s.goal
		if s.sim.distance_to(s.goal) > 0.0005:
			var step: float = s.goal_speed * delta
			if s.sim.distance_to(via) <= step + 0.01:
				s.via = s.goal               # the corner is reached this tick: straight on after it
			s.sim = NC.call("l_step", s.sim, via, s.goal, step)
			if s.sim.distance_to(s.goal) <= 0.0005 and s.via_for == s.goal:
				s.room = s.room_goal         # arrived: the headroom here is the goal's
				s.room_to = s.room_goal
		s.position = s.sim
		return
	var to := s.goal - s.sim
	var d := to.length()
	if d > 0.0005:
		var step := s.goal_speed * delta
		s.sim = s.goal if d <= step else s.sim + to / d * step
	s.position = s.sim


func _plan(s: Shade, dir: Vector3, speed: float, avoid_light: bool, lf, max_step: float) -> int:
	# the Stalker's floor walk: a chest probe, a 2.2 m step up, a floor ray from just over the
	# step-up to 45 m down (_floor_y). It refuses drops over 2.5 m, leaving its zone, entering the
	# 18 m checkpoint radius, and (avoid_light) any step that puts its chest in light k >= 0.2.
	dir.y = 0.0
	if dir.length() < 0.001:
		s.goal = s.sim
		return PLAN_BLOCKED
	dir = dir.normalized()
	var w3 := s.get_world_3d()
	if w3 == null:
		return PLAN_BLOCKED
	var space := w3.direct_space_state
	var dist := minf(speed * BRAIN_DT, max_step)
	var chest := Vector3.UP * CHEST
	var NC = _ncx()
	if NC != null:
		# G1: the floor walk every walker shares (probes from proven air, an L path, 2.5 m of
		# headroom, a hunch under lower rock); the zone, checkpoint, part and light rules after it
		if s.pause_t > 0.0:
			return PLAN_BLOCKED          # 2.6: every heading was refused a moment ago
		var r = _nc_walk(NC, space, s, s.sim, dir, dist, true)
		if r == null:
			return PLAN_BLOCKED
		var np2: Vector3 = r["pos"]
		if not _step_ok(s, s.sim, np2):
			return PLAN_BLOCKED
		if avoid_light and _k(lf, np2 + chest, s.key, 0.3) >= LIT_STEP_K:
			return PLAN_LIT
		var via2: Vector3 = r["via"]
		s.goal = np2
		s.via = via2
		s.via_for = np2
		s.room_goal = float(r.get("room", ROOM_MAX))
		s.room_to = minf(s.room_goal, float(r.get("low_t", INF)))
		s.goal_speed = maxf(speed, ((via2 - s.sim).length() + (np2 - via2).length()) / BRAIN_DT)
		s.yaw = atan2(-dir.x, -dir.z)
		return PLAN_MOVED
	var want := s.sim + dir * dist
	if not _ray(space, s.sim + chest, want + chest).is_empty():
		var up := want + Vector3.UP * STEP_UP
		if not _ray(space, s.sim + chest, up + chest).is_empty():
			return PLAN_BLOCKED
	var fy := _floor_y(space, Vector3(want.x, s.sim.y, want.z), s.sim.y)
	if fy < -1e8 or fy < s.sim.y - MAX_DROP or fy > s.sim.y + STEP_UP + 0.2:
		return PLAN_BLOCKED
	var np := Vector3(want.x, fy, want.z)
	if not _in_zone(s.band, np) and _in_zone(s.band, s.sim):
		return PLAN_BLOCKED
	if _near_cp(np, CP_KEEP_OUT) and not (_near_cp(s.sim, CP_KEEP_OUT) and _min_dist(np, _cps) > _min_dist(s.sim, _cps)):
		return PLAN_BLOCKED
	if avoid_light and _k(lf, np + chest, s.key, 0.3) >= LIT_STEP_K:
		return PLAN_LIT
	s.goal = np
	s.goal_speed = maxf(speed, (np - s.sim).length() / BRAIN_DT)
	s.yaw = atan2(-dir.x, -dir.z)
	return PLAN_MOVED


func _plan_around(s: Shade, dir: Vector3, speed: float, avoid_light: bool, lf) -> int:
	# straight on, else a step to either side (like the Brood): light straight ahead is the edge
	# it stops at, not an obstacle to walk round
	if s.pause_t > 0.0 and _ncx() != null:
		return PLAN_BLOCKED              # 2.6: every heading was refused a moment ago
	var r := _plan(s, dir, speed, avoid_light, lf, 99.0)
	if r != PLAN_BLOCKED:
		return r
	for ang in [0.8, -0.8, 1.6, -1.6]:
		r = _plan(s, dir.rotated(Vector3.UP, float(ang)), speed * 0.8, avoid_light, lf, 99.0)
		if r == PLAN_MOVED:
			return r
	if _ncx() != null:
		s.pause_t = 0.5                  # 2.6: all five refused: no planning for 0.5 s
	return PLAN_BLOCKED


func _floor_y(space: PhysicsDirectSpaceState3D, p: Vector3, ref_y: float) -> float:
	# one both-sided ray from just over the step-up height: the first surface below that is the
	# floor (the old first pass from 8 m up only ever returned this, or sent it here after hitting
	# a ledge or overhang above, which a both-sided ray now hits far more often)
	var top := Vector3(p.x, ref_y + STEP_UP + 0.2, p.z)
	var hit := _ray(space, top, p + Vector3.DOWN * 45.0)
	if hit.is_empty():
		return -1e9
	return float((hit["position"] as Vector3).y)


func _floor_under(t: Node3D) -> bool:
	# RUSH only while there is floor under the target within 3 m below its feet
	var w3 := t.get_world_3d()
	if w3 == null:
		return true
	var p := t.global_position
	return not _ray(w3.direct_space_state, p + Vector3.UP * 0.2, p + Vector3.DOWN * 3.8).is_empty()


func _rush_reach(s: Shade, pp: Vector3) -> bool:
	# a player well above or below it: the rush _think_rush would run at them (RUSH-sized steps
	# straight at them, else 0.6 rad to either side, for at most RUSH_MAX) must reach strike reach
	# and height under the floor walk's rules (a slope it can run, not a cliff or a ledge), or it
	# does not shriek. Pure: rays only, the Shade itself is not touched.
	var w3 := s.get_world_3d()
	if w3 == null:
		return false
	var space := w3.direct_space_state
	var cur := s.sim
	# no-clip (G3): the same walk as the rush, capped at RR_CAP rays per call (side steps
	# included), then "cannot reach"; _tell_target caches the answer 0.5 s per player
	_rr_rays = 0
	var nc: bool = _ncx() != null
	for _tick in roundi(RUSH_MAX / BRAIN_DT):
		var flat := _flat(pp - cur)
		var fd := flat.length()
		if fd <= STRIKE_R and absf(pp.y - (cur.y + 0.8)) < 2.0:
			return true
		if fd < 0.01:
			return false
		var dir := flat / fd
		var dist := minf(RUSH_SPEED * BRAIN_DT, maxf(0.2, fd - 1.2))
		var np = _walk_step(space, s.band, cur, dir, dist, s)
		for ang in [0.6, -0.6]:
			if np == null:
				np = _walk_step(space, s.band, cur, dir.rotated(Vector3.UP, float(ang)), dist, s)
		if np == null:
			return false
		if nc and _rr_rays > RR_CAP:
			return false
		cur = np
	return false


func _walk_step(space: PhysicsDirectSpaceState3D, band: int, cur: Vector3, dir: Vector3, dist: float, s = null):
	# one step of the floor walk (_plan's chest probe, step-up, drop, zone and checkpoint rules,
	# without the light rule): the new floor point, or null. No-clip: NC.walk_step (G1), with
	# the zone, checkpoint and part rules after it; _rr_rays counts the rays it cast (an estimate)
	var NC = _ncx()
	if NC != null and s != null:
		if _rr_rays > RR_CAP:
			return null
		var r = _nc_walk(NC, space, s, cur, dir, dist, false)
		if r == null:
			return null
		var np2: Vector3 = r["pos"]
		if not _step_ok(s, cur, np2):
			return null
		return np2
	var want := cur + dir * dist
	var chest := Vector3.UP * CHEST
	if not _ray(space, cur + chest, want + chest).is_empty():
		if not _ray(space, cur + chest, want + Vector3.UP * STEP_UP + chest).is_empty():
			return null
	var fy := _floor_y(space, Vector3(want.x, cur.y, want.z), cur.y)
	if fy < -1e8 or fy < cur.y - MAX_DROP or fy > cur.y + STEP_UP + 0.2:
		return null
	var np := Vector3(want.x, fy, want.z)
	if not _in_zone(band, np) and _in_zone(band, cur):
		return null
	if _near_cp(np, CP_KEEP_OUT) and not (_near_cp(cur, CP_KEEP_OUT) and _min_dist(np, _cps) > _min_dist(cur, _cps)):
		return null
	return np


# ---------------------------------------------------------------------------- no-clip walk

func _nc_walk(NC, space: PhysicsDirectSpaceState3D, s: Shade, from: Vector3, dir: Vector3, dist: float, tall: bool):
	# G1: one NC.walk_step with SHADE_PROF (tall: the hunch probe, from the headroom it stands
	# in); the result Dictionary, or null when refused. The spot's hunch leans the head up to
	# about 1 m ahead of the feet, so a spot where that lean would reach rock is refused too (one
	# more ray, only where it hunches). Adds its rays to _rr_rays (an estimate: 5 flat, 7 with a
	# rise or a drop, +1 for the lean).
	var prof: Dictionary = SHADE_PROF.duplicate()
	if tall:
		prof["room_from"] = s.room
	else:
		prof.erase("tall")
	var r = NC.call("walk_step", space, from, dir, dist, prof)
	if not (r is Dictionary) or not bool((r as Dictionary).get("ok", false)):
		_rr_rays += 5
		return null
	var rd: Dictionary = r
	var np: Vector3 = rd.get("pos", from)
	var via: Vector3 = rd.get("via", from)
	_rr_rays += 7 if via.distance_to(from) > 0.01 else 5
	var room_goal := float(rd.get("room", ROOM_MAX))
	var low_t := float(rd.get("low_t", INF))
	var room_to := room_goal
	if low_t < 90.0:
		# a lip over the way: the tall probe hit it, the 2.4 m probe did not, so it is somewhere
		# between: the full hunch (head top 2.35 m) passes under it
		room_to = minf(room_goal, minf(low_t, HOME_SNAP_HEAD_NC))
	rd["low_t"] = room_to if room_to < room_goal else INF
	var hp := _hunch_pose(room_to)
	if hp.y > 0.05:
		var top := HIP_H - hp.x + UPPER_LEN * cos(hp.y)
		var reach := UPPER_LEN * sin(hp.y) + 0.2
		var a := np + Vector3.UP * maxf(0.5, top - 0.1)
		_rr_rays += 1
		var hit = NC.call("ray", space, a, a + dir * reach)
		if hit is Dictionary and not (hit as Dictionary).is_empty():
			return null
	if _body_blocked(space, from, via, np, dir, room_to):
		_rr_rays += 1
		_note("body_refused")
		return null
	return rd


static var _body_cap: CapsuleShape3D = null
static var _head_ball: SphereShape3D = null
static var _shape_q: PhysicsShapeQueryParameters3D = null
var body_stats := {"cap": 0, "head": 0, "cap_dest": 0, "cap_vert": 0, "cap_flat": 0}      # which volume refused (developer report)


func _rock_touched(space: PhysicsDirectSpaceState3D, shape: Shape3D, at: Vector3) -> bool:
	# one shape query: does the volume touch the cave (static bodies on the world layer)
	if _shape_q == null:
		_shape_q = PhysicsShapeQueryParameters3D.new()
		_shape_q.collision_mask = 1
		_shape_q.collide_with_areas = false
	_shape_q.shape = shape
	_shape_q.transform = Transform3D(Basis(), at)
	for r in space.intersect_shape(_shape_q, 4):
		if (r as Dictionary).get("collider") is StaticBody3D:
			return true
	return false


func _body_blocked(space: PhysicsDirectSpaceState3D, from: Vector3, via: Vector3, np: Vector3, dir: Vector3, room: float) -> bool:
	# the legs and torso (a capsule from the shins to the shoulders, lowered under low rock: the head top stays 0.15 m
	# under it, so the shoulders sit about 0.65 m under it) at the new spot and every 0.5 m of the L path getting there,
	# and the head (a ball where the pose puts it: over the feet upright, ahead of them hunched)
	if _body_cap == null:
		_body_cap = CapsuleShape3D.new()
		_head_ball = SphereShape3D.new()
		_head_ball.radius = HEAD_R
	var top := minf(BODY_TOP, room - 0.65)
	var h := maxf(top - BODY_BOT, 2.0 * BODY_R + 0.05)
	_body_cap.radius = BODY_R
	_body_cap.height = h
	var lift := Vector3.UP * (BODY_BOT + h * 0.5)
	var pts: Array = []
	for seg in [[from, via], [via, np]]:
		var a: Vector3 = seg[0]
		var b: Vector3 = seg[1]
		var n := int(ceil(a.distance_to(b) / BODY_STEP))
		var kind := "cap_vert" if Vector2(a.x - b.x, a.z - b.z).length() < 0.01 else "cap_flat"
		for i in range(1, n + 1):
			pts.append([a.lerp(b, float(i) / float(n)), kind])
	if pts.is_empty() or ((pts[pts.size() - 1] as Array)[0] as Vector3).distance_to(np) > 0.01:
		pts.append([np, "cap_dest"])
	for pk in pts:
		if _rock_touched(space, _body_cap, ((pk as Array)[0] as Vector3) + lift):
			body_stats["cap"] = int(body_stats["cap"]) + 1
			body_stats[str((pk as Array)[1])] = int(body_stats[str((pk as Array)[1])]) + 1
			return true
	var hp := _hunch_pose(room)
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length() > 0.001:
		flat = flat.normalized()
	var head_top := HIP_H - hp.x + UPPER_LEN * cos(hp.y)
	var head_c := np + Vector3.UP * (head_top - 0.1) + flat * (UPPER_LEN * sin(hp.y) * 0.9)
	if _rock_touched(space, _head_ball, head_c):
		body_stats["head"] = int(body_stats["head"]) + 1
		return true
	return false


func _step_ok(s: Shade, from: Vector3, np: Vector3) -> bool:
	# the rules after the floor walk (unchanged from the old walk): never out of its zone, never
	# into a checkpoint's 18 m (unless it steps out of one); 7A: never into another part
	if not _in_zone(s.band, np) and _in_zone(s.band, from):
		return false
	if _near_cp(np, CP_KEEP_OUT) and not (_near_cp(from, CP_KEEP_OUT) and _min_dist(np, _cps) > _min_dist(from, _cps)):
		return false
	var hp := _home_part(s)
	if hp >= 0:
		var pn := _part_of(np)
		if pn >= 0 and pn != hp:
			return false
		# a squeeze (the boundary layer, a passage's own region, the Burrows) is no place for a big
		# creature: it may come up to the opening, never into it (unless it already stands in one)
		if map.has_method("in_squeeze") and bool(map.call("in_squeeze", np)) and not bool(map.call("in_squeeze", from)):
			return false
	return true


func _hunch_pose(room: float) -> Vector2:
	# how the Shade fits under rock `room` above its feet: x = how far the knees lower the hip
	# (at most 0.35 m), y = the forward bend at the hip (radians, at most 60 degrees) that keeps
	# the head top 0.15 m under the rock. Standing it is 3.04 m tall; (0, 0) when that fits.
	var lim := room - 0.15
	var need := UPRIGHT_TOP - lim
	if need <= 0.0:
		return Vector2.ZERO
	var cd := minf(need, CROUCH_MAX)
	var hip := HIP_H - cd
	var c := clampf((lim - hip) / UPPER_LEN, HUNCH_MAX_COS, 1.0)
	return Vector2(cd, acos(c))


func _under_ledge(s: Shade, t) -> bool:
	# 2.6: a target more than the step-up above its feet and within 2 m: no planning, it waits
	var q := _pos(t)
	return q.y - 0.8 - s.sim.y > STEP_UP and Vector2(q.x - s.sim.x, q.z - s.sim.z).length() < 2.0


func _part_of(p: Vector3) -> int:
	# 7A: the map part (a stretch between two squeezes) p is in, -1 when the map does not tell
	# (underdark.gd part_of(p): 0 at the top, +1 past each boundary; called at runtime)
	if map == null or not map.has_method("part_of"):
		return -1
	return int(map.call("part_of", p))


func _home_part(s: Shade) -> int:
	if not s.part_known and map != null and map.has_method("part_of"):
		s.part_known = true
		s.part = _part_of(s.home)
		if not _part_logged:
			_part_logged = true
			print("[SHADE] the map tells parts apart: each Shade stays in its own part")
	return s.part


func _in_part(s: Shade, players: Array) -> Array:
	# 7A: the players in this Shade's part of the map (all of them when the map does not tell)
	var hp := _home_part(s)
	if hp < 0:
		return players
	var out: Array = []
	for p in players:
		var pp := _part_of(_pos(p))
		if pp < 0 or pp == hp:
			out.append(p)
	return out


func _is_ghost(p) -> bool:
	# the loopback Ghost (a mirror of this player, 0.7 s late, 3.5 m ahead of where it looks)
	if p == Game.climber or not (p is Object):
		return false
	var lid = CoopSync.get("LOOP_ID")
	var pid = (p as Object).get("peer_id")
	return pid != null and int(pid) == (int(lid) if lid != null else 777)


func _in_zone(bi: int, p: Vector3) -> bool:
	if bi < 0 or bi >= bands.size():
		return false
	var r2 := ZONE_R * ZONE_R
	for q in bands[bi]["route"]:
		if p.distance_squared_to(q) < r2:
			return true
	return false


func _in_any_zone(p: Vector3) -> bool:
	for bi in bands.size():
		if p.y <= float(bands[bi]["top"]) + ZONE_R and p.y >= float(bands[bi]["bot"]) - ZONE_R and _in_zone(bi, p):
			return true
	return false


func _near_cp(p: Vector3, r: float) -> bool:
	var r2 := r * r
	for q in _cps:
		if p.distance_squared_to(q) < r2:
			return true
	return false


# ============================================================================ light helpers

func _lf():
	var lf = CoopSync.get("light_field")
	if lf != null and is_instance_valid(lf) and (lf as Object).has_method("light_at"):
		return lf
	return null


func _k(lf, p: Vector3, key: int, radius: float) -> float:
	if lf == null:
		return 0.0
	var d = lf.call("light_at", p, key, radius)
	if d is Dictionary:
		return float((d as Dictionary).get("k", 0.0))
	return 0.0


func _target_lit(p, lf) -> bool:
	# that player's OWN lantern is on and not dry (the LightField's player_lit). For this
	# machine's player it is read from the lantern itself (CoopSync.lantern_on: wanted and not
	# dry, the same rule), so a switch counts the same frame, not a LightField tick later.
	if p == Game.climber:
		return bool(CoopSync.lantern_on)
	if lf != null and lf.has_method("player_lit"):
		return bool(lf.call("player_lit", p))
	return false


func _player_dry(p, lf) -> bool:
	# this machine's player: read from the lantern itself, so the few frames before the
	# LightField notices never make a dry lantern look switched off (which has no grace)
	if p == Game.climber:
		var ln = CoopSync.lantern
		return is_instance_valid(ln) and ln.has_method("is_dry") and bool(ln.call("is_dry"))
	if lf != null and lf.has_method("player_dry"):
		return bool(lf.call("player_dry", p))
	return false


func _player_dry_ms(p, lf) -> int:
	# 0 until the LightField has seen it run dry: the 2.5 s grace never starts early
	if lf != null and lf.has_method("player_dry_ms"):
		return int(lf.call("player_dry_ms", p))
	return 0


func _local_lit(lf, p: Vector3) -> bool:
	if _force_local_lit >= 0:
		return _force_local_lit == 1
	if lf != null and lf.has_method("local_lit"):
		return bool(lf.call("local_lit", p))
	return false


# ============================================================================ sync

func _send_sh():
	var any := false
	var out: Array = []
	for s in shades:
		if s.st == DORMANT:
			out.append([])
		else:
			any = true
			# e[5] the teleport count (G6: guests snap on a new one), e[6] the room its hunch
			# follows; a build before 5.0 reads e[0..4] only
			out.append(PackedFloat32Array([float(s.st), s.sim.x, s.sim.y, s.sim.z, s.yaw, float(s.tp), minf(s.room, s.room_to)]))
	return out if any else null


func _recv_sh(v) -> void:
	if CoopSync.map_is_authority() or not (v is Array):
		return
	var now := Time.get_ticks_msec()
	_rx_ms = now
	var play := str(CoopSync.get("guestsim")) == "play"
	if play:
		_gs_pkts += 1
		_gs_last.clear()
	var arr: Array = v
	for i in mini(arr.size(), shades.size()):
		var s: Shade = shades[i]
		var e = arr[i]
		if e == null or typeof(e) < TYPE_ARRAY or e.size() < 5:
			if s.st != DORMANT:
				_remote_state(s, DORMANT)
			continue
		var p := Vector3(float(e[1]), float(e[2]), float(e[3]))
		s.rp_pos = p
		s.rp_yaw = float(e[4])
		if play:
			_gs_last[i] = p
		# G6: every sample is kept with its arrival time (4 at most) for the 120 ms render delay
		var tpn := 0
		if e.size() >= 6:
			tpn = int(e[5])
		elif not s.buf.is_empty():
			tpn = int(s.buf[s.buf.size() - 1][3])
		var rm := ROOM_MAX
		if e.size() >= 7:
			rm = float(e[6])
		if s.st == DORMANT:
			s.buf.clear()                # a fresh wake: no gliding in from an old sample
		s.buf.append([now, p, s.rp_yaw, tpn, rm])
		while s.buf.size() > 4:
			s.buf.pop_front()
		if s.st == DORMANT and s.position.distance_to(p) > 12.0:
			s.position = p               # first sight far from where this screen had it
			s.prev_pos = p
		var n := int(e[0])
		if n != s.st:
			_remote_state(s, n)


func _remote_state(s: Shade, n: int) -> void:
	if s.st == n or n < 0 or n >= NAMES.size():
		return
	s.st = n
	s.st_t = 0.0
	s.held = false
	_enter_fx(s, n)


func _guest_move(s: Shade, delta: float, lf) -> void:
	var NC = _ncx()
	if NC != null:
		_guest_move_nc(NC, s, delta, lf)
		return
	if s.st == DORMANT:
		s.position = s.position.lerp(s.rp_pos, clampf(delta * 4.0, 0.0, 1.0))
		return
	s.lit_t -= delta
	if s.lit_t <= 0.0:
		s.lit_t = 0.1
		var was := s.held
		s.held = false
		if s.st == STALK or s.st == TELL or s.st == RUSH:
			s.held = _local_lit(lf, s.position + Vector3.UP * CHEST)
		if s.held and not was:
			s.hold_pos = s.position
	if s.held:
		# this player's own light is on it: it holds still on this screen (the host stops it a
		# packet later)
		if str(CoopSync.get("guestsim")) == "play":
			_gs_hold_frames += 1
			if s.position.distance_to(s.hold_pos) > 0.001:
				_gs_hold_moves += 1
		return
	s.position = s.position.lerp(s.rp_pos, clampf(delta * 10.0, 0.0, 1.0))
	s.yaw = s.rp_yaw


func _guest_move_nc(NC, s: Shade, delta: float, lf) -> void:
	# G6: the host's samples drawn 120 ms back, between the two around that moment (never
	# extrapolated); rises and drops walked as L steps (rise first, drop last) like the host's
	# walk; a snap on a new teleport count or a gap over 3 m; after a hold, and for the DORMANT
	# settle, a glide only along a clear chest-height line, else a snap
	var tg := _render_target(s, Time.get_ticks_msec())
	if tg.is_empty():
		s.g_room = s.home_room if s.position.distance_to(s.home) < 0.6 else ROOM_MAX
		if s.st == DORMANT:
			s.position = s.position.lerp(s.rp_pos, clampf(delta * 4.0, 0.0, 1.0))
		return
	var tpos: Vector3 = tg["pos"]
	s.g_room = float(tg["room"])
	if s.st == DORMANT:
		s.held = false
		s.was_held = false
		if s.position.distance_to(s.home) < 0.6:
			s.g_room = minf(s.g_room, s.home_room)   # asleep at home: its own measured headroom
		var gd := s.position.distance_to(tpos)
		if gd > 0.005:
			if s.glide_to != tpos:
				s.glide_to = tpos
				s.glide_ok = _clear_line(NC, s, s.position, tpos)
			if s.glide_ok and int(tg["tp"]) == s.shown_tp:
				_l_walk(NC, s, tpos, maxf(gd * 4.0, 1.0) * delta)
			else:
				s.position = tpos
		s.shown_tp = int(tg["tp"])
		return
	s.lit_t -= delta
	if s.lit_t <= 0.0:
		s.lit_t = 0.1
		var was := s.held
		s.held = false
		if s.st == STALK or s.st == TELL or s.st == RUSH:
			s.held = _local_lit(lf, s.position + Vector3.UP * CHEST)
		if s.held and not was:
			s.hold_pos = s.position
	if s.held:
		# this player's own light is on it: it holds still on this screen (the host stops it a
		# packet later)
		s.was_held = true
		if str(CoopSync.get("guestsim")) == "play":
			_gs_hold_frames += 1
			if s.position.distance_to(s.hold_pos) > 0.001:
				_gs_hold_moves += 1
		return
	var cur := s.position
	var gap := cur.distance_to(tpos)
	var snap: bool = int(tg["tp"]) != s.shown_tp or gap > GUEST_SNAP
	if not snap and s.was_held and gap > 0.3:
		snap = not _clear_line(NC, s, cur, tpos)
	s.was_held = false
	s.shown_tp = int(tg["tp"])
	s.yaw = float(tg["yaw"])
	if snap:
		s.position = tpos
		return
	_l_walk(NC, s, tpos, (maxf(float(tg["spd"]) * 1.5, 1.5) + maxf(0.0, gap - 0.4) * 6.0) * delta)


func _l_walk(NC, s: Shade, tpos: Vector3, step: float) -> void:
	# toward tpos as the host's walk moves: up a rise first, then over its lip; over an edge
	# first, then down (the walk's own 0.15 m rule)
	var cur := s.position
	var d := tpos - cur
	var via := tpos
	if d.y > 0.15:
		via = Vector3(cur.x, tpos.y, cur.z)
	elif d.y < -0.15:
		via = Vector3(tpos.x, cur.y, tpos.z)
	s.position = NC.call("l_step", cur, via, tpos, step)


func _l_lerp(a: Vector3, b: Vector3, k: float) -> Vector3:
	# the point a fraction k along the host walk's L path from a to b (rise then advance,
	# advance then drop), not the diagonal through a lip
	var dy := b.y - a.y
	if absf(dy) <= 0.15:
		return a.lerp(b, k)
	var corner := Vector3(a.x, b.y, a.z) if dy > 0.0 else Vector3(b.x, a.y, b.z)
	var l1 := a.distance_to(corner)
	var l2 := corner.distance_to(b)
	var s := k * (l1 + l2)
	if s <= l1:
		return a.lerp(corner, s / l1) if l1 > 0.00001 else corner
	return corner.lerp(b, (s - l1) / l2) if l2 > 0.00001 else b


func _render_target(s: Shade, now: int) -> Dictionary:
	# the host's position RENDER_MS ago between the two samples around that moment (the newest
	# when it is later than all of them: no extrapolation), along the walk's L path. Across a
	# teleport (two samples with different counts) it holds the older one until the newer one's
	# time comes.
	var b: Array = s.buf
	var n := b.size()
	if n == 0:
		return {}
	var spd := 0.0
	if n >= 2:
		var dt := float(int(b[n - 1][0]) - int(b[n - 2][0]))
		if dt > 1.0 and int(b[n - 1][3]) == int(b[n - 2][3]):
			spd = (b[n - 1][1] as Vector3).distance_to(b[n - 2][1]) / (dt / 1000.0)
	var rt := now - RENDER_MS
	var pick: Array = b[n - 1]
	if n >= 2 and rt < int(b[n - 1][0]):
		pick = b[0]
		for i in range(n - 1):
			var a: Array = b[i]
			var c: Array = b[i + 1]
			if rt >= int(a[0]) and rt <= int(c[0]):
				if int(a[3]) != int(c[3]):
					pick = a
					break
				var span := maxi(1, int(c[0]) - int(a[0]))
				var k := clampf(float(rt - int(a[0])) / float(span), 0.0, 1.0)
				return {"pos": _l_lerp(a[1], c[1], k), "yaw": lerp_angle(float(a[2]), float(c[2]), k),
						"tp": int(a[3]), "room": minf(float(a[4]), float(c[4])), "spd": spd}
	return {"pos": pick[1], "yaw": float(pick[2]), "tp": int(pick[3]), "room": float(pick[4]), "spd": spd}


func _clear_line(NC, s: Shade, a: Vector3, b: Vector3) -> bool:
	# a glide along a chest-height line with no rock on it (guests never ray unloaded rock: a
	# line there counts as blocked, so it snaps)
	var w3 := s.get_world_3d()
	if w3 == null:
		return false
	if not bool(NC.call("solid_at", a, 4.0)) or not bool(NC.call("solid_at", b, 4.0)):
		return false
	var hit = NC.call("ray", w3.direct_space_state, a + Vector3.UP * 1.6, b + Vector3.UP * 1.6)
	return hit is Dictionary and (hit as Dictionary).is_empty()


# ============================================================================ look and sound

func _process(delta: float) -> void:
	if shades.is_empty():
		return
	var t0 := Time.get_ticks_usec()
	var auth: bool = CoopSync.map_is_authority()
	var now := Time.get_ticks_msec()
	var lf = _lf()
	if not auth and now - _rx_ms > STALE_MS:
		for s in shades:
			if s.st != DORMANT:
				_remote_state(s, DORMANT)    # the host stopped streaming: they settle
	var lis := _listener()
	for s in shades:
		if not auth:
			_guest_move(s, delta, lf)
		_visual(s, delta, lis)
	_hint_t -= delta
	if _hint_t <= 0.0:
		_hint_t = 0.25
		_hint_check(lf)
	CoopSync.perf_add(Time.get_ticks_usec() - t0)


func _enter_fx(s: Shade, n: int) -> void:
	# every machine: what a state change looks and sounds like here
	var now := Time.get_ticks_msec()
	s.fx_t = 0.0
	var eyes_on := n == TELL or n == RUSH or n == STRIKE
	for e in s.eyes:
		(e as Node3D).visible = eyes_on
	if n == TELL or n == STRIKE:
		_arm_room(s)
	var d := s.position.distance_to(_listener())
	match n:
		FROZEN:
			if now - s.hiss_ms >= HISS_CD_MS and now - _team_hiss_ms >= HISS_TEAM_MS:
				s.hiss_ms = now
				_team_hiss_ms = now
				s.hiss_n += 1
				if _testing:
					print("[SHADE] %s hiss" % s.id)
				if d < 34.0:
					_kind(s.voice, "shade_hiss", -2.0, 1.0, 30.0, S_SNARL4, -9.0, 1.6)
		TELL:
			_kind(s.voice, "shade_shriek", 0.0, 1.0, 60.0, S_SNARL2, -2.0, 0.72)
			if d < 20.0:
				_kind(s.fx, "shade_crack", -6.0, 1.0, 18.0, "", 0.0, 1.0)
		RUSH:
			if d < 20.0:
				_kind(s.fx, "shade_crack", -6.0, 1.15, 18.0, "", 0.0, 1.0)
		STRIKE:
			_kind(s.voice, "shade_gargle", 0.0, 1.0, 30.0, S306004, -2.0, 0.8)
		RIM:
			s.breath_t = randf_range(4.0, 7.0)
			if d < 20.0 and not s.amb.playing:
				_play(s.amb, _game_stream(S306002), -4.0, 0.55, 22.0)


func _arm_room(s: Shade) -> void:
	# G5 (every machine, at the start of TELL and STRIKE): the arms spread and rise only as far
	# as the rock around the chest lets them (2 side rays of 2.0 m, 1 up ray of 4.2 m). The
	# shriek and gargle timings do not change (R9).
	s.arm_side_k = 1.0
	s.arm_up_k = 1.0
	var NC = _ncx()
	if NC == null:
		return
	var w3 := s.get_world_3d()
	if w3 == null:
		return
	var sp := w3.direct_space_state
	var ch := s.position + Vector3.UP * (CHEST - s.crouch_d)
	var right := Vector3(cos(s.yaw), 0.0, -sin(s.yaw))
	var side := 2.0
	for sd in [1.0, -1.0]:
		side = minf(side, _ray_free(NC, sp, ch, right * float(sd), 2.0))
	var up := _ray_free(NC, sp, ch, Vector3.UP, 4.2)
	s.arm_side_k = clampf((side - 0.2) / 1.9, 0.3, 1.0)
	s.arm_up_k = clampf((up - 1.2) / 3.0, 0.3, 1.0)


func _ray_free(NC, sp: PhysicsDirectSpaceState3D, a: Vector3, dir: Vector3, length_m: float) -> float:
	# the free distance along one no-clip ray (Rule N ray, both faces), length_m when clear
	var hit = NC.call("ray", sp, a, a + dir * length_m)
	if not (hit is Dictionary) or (hit as Dictionary).is_empty():
		return length_m
	var h: Dictionary = hit
	if h.has("d"):
		return float(h["d"])
	return a.distance_to(h.get("position", a + dir * length_m))


func _front_check(NC, s: Shade, delta: float) -> void:
	# the rock ahead of the upper body (drawn machines, 2 Hz or when it moved or turned): the
	# forward lean of any pose (and the hunch) never reaches it
	s.front_t -= delta
	var turned := absf(angle_difference(s.vis_yaw, s.front_yaw)) > 0.12
	if s.front_t > 0.0 and s.position.distance_to(s.front_at) < 0.15 and not turned:
		return
	s.front_t = 0.5
	s.front_at = s.position
	s.front_yaw = s.vis_yaw
	var w3 := s.get_world_3d()
	if w3 == null:
		return
	var fwd := Vector3(-sin(s.vis_yaw), 0.0, -cos(s.vis_yaw))
	s.front_free = _ray_free(NC, w3.direct_space_state, s.position + Vector3.UP * (HIP_H - s.crouch_d + 1.1), fwd, FRONT_RAY)


func _visual(s: Shade, delta: float, lis: Vector3) -> void:
	var dl := s.position.distance_to(lis)
	if dl > VIS_RANGE:
		s.prev_pos = s.position
		return
	var mv := s.position - s.prev_pos
	mv.y = 0.0
	s.prev_pos = s.position
	var sp := mv.length() / maxf(delta, 0.0001)
	s.spd = lerpf(s.spd, sp, clampf(delta * 8.0, 0.0, 1.0))
	if sp > 0.8 and not s.was_moving:
		# the start of a burst: a lurch and, now and then, a crack of bone
		s.was_moving = true
		s.lurch = 1.0
		if s.st == STALK and dl < 18.0 and randf() < 0.35:
			_kind(s.fx, "shade_crack", -6.0, randf_range(0.9, 1.1), 18.0, "", 0.0, 1.0)
	elif sp < 0.2:
		s.was_moving = false
	s.fx_t += delta
	s.vis_yaw = lerp_angle(s.vis_yaw, s.yaw, clampf(delta * 9.0, 0.0, 1.0))
	s.root.rotation.y = s.vis_yaw
	var P: Array = POSE[clampi(s.st, 0, POSE.size() - 1)]
	var hunch := float(P[0]) - 0.25 * s.lurch
	var neck := float(P[1])
	var arm_x := float(P[2])
	var spread := float(P[3])
	var elbow := float(P[4])
	if s.st == TELL or s.st == STRIKE:
		spread *= s.arm_side_k          # G5: only as wide and as high as the rock around lets it
		arm_x *= s.arm_up_k
	if s.st == STRIKE and s.fx_t > STRIKE_WIND:
		arm_x = 0.5                     # the slam
		elbow = 0.1
		hunch = -0.45
	# no-clip: under rock lower than its 3.04 m it crouches, then bends at the hip (G1), and no
	# pose leans its head into rock ahead of it
	var NC = _ncx()
	var lean_max := PI
	var room_hunch := 0.0
	if NC != null:
		var room_t: float = minf(s.room, s.room_to) if CoopSync.map_is_authority() else s.g_room
		if room_t < s.room_vis:
			s.room_vis = room_t          # down at once: the head never waits inside the rock
		else:
			s.room_vis = lerpf(s.room_vis, room_t, clampf(delta * 8.0, 0.0, 1.0))
		var hp := _hunch_pose(s.room_vis)
		s.crouch_d = hp.x
		room_hunch = hp.y
		_front_check(NC, s, delta)
		if s.front_free < UPPER_LEN + 0.15:
			lean_max = asin(clampf((s.front_free - 0.15) / UPPER_LEN, 0.0, 1.0))
		if room_hunch > 0.001:
			hunch = minf(hunch, -room_hunch)
			neck = minf(neck, 0.0)
		if lean_max < PI:
			hunch = maxf(hunch, -lean_max)
			neck = maxf(neck, 0.0)
	else:
		s.crouch_d = 0.0
	s.lurch = maxf(0.0, s.lurch - delta * 4.0)
	var fast: bool = s.st == TELL or s.st == STRIKE or s.st == FROZEN
	var kk := clampf(delta * (14.0 if fast else 7.0), 0.0, 1.0)
	s.torso.rotation.x = lerpf(s.torso.rotation.x, hunch, kk)
	s.neck.rotation.x = lerpf(s.neck.rotation.x, neck, kk)
	if NC != null:
		# the limits hold at once, whatever the easing (the hunch and the lean clamp)
		var lo := -lean_max
		var hi := -room_hunch if room_hunch > 0.001 else 10.0
		s.torso.rotation.x = clampf(s.torso.rotation.x, lo, maxf(lo, hi))
		if room_hunch > 0.001:
			s.neck.rotation.x = minf(s.neck.rotation.x, 0.0)
		if lean_max < PI:
			s.neck.rotation.x = maxf(s.neck.rotation.x, 0.0)
	s.hip.position.y = HIP_H - s.crouch_d
	var ca := acos(clampf((HIP_H - s.crouch_d) / HIP_H, -1.0, 1.0)) if s.crouch_d > 0.001 else 0.0
	s.twitch_t -= delta
	if s.twitch_t <= 0.0:
		s.twitch_t = randf_range(1.5, 4.0)
		if s.st == RIM or s.st == STALK or s.st == DORMANT:
			s.twitch = randf_range(-0.5, 0.5)
	s.twitch = move_toward(s.twitch, 0.0, delta * 0.8)
	s.head.rotation.z = lerpf(s.head.rotation.z, 0.3 + s.twitch, clampf(delta * 20.0, 0.0, 1.0))
	var walking: bool = s.st == STALK or s.st == RETREAT or s.st == RUSH
	s.walk_ph += delta * (2.0 + s.spd * 1.6)
	var amp := clampf(s.spd / 5.0, 0.0, 1.0) * (0.75 if s.st == RUSH else 0.4)
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var ph := s.walk_ph + (PI if i == 1 else 0.0)
		var swing := sin(ph) * 0.25 * clampf(s.spd / 3.0, 0.0, 1.0) if walking and s.st != RUSH else 0.0
		var sh: Node3D = s.shoulders[i]
		sh.rotation.x = lerpf(sh.rotation.x, arm_x - swing, kk)
		sh.rotation.z = lerpf(sh.rotation.z, side * spread, kk)
		var el: Node3D = s.elbows[i]
		el.rotation.x = lerpf(el.rotation.x, elbow, kk)
		# the crouch (no-clip hunch): thigh forward by ca, shin back by 2 ca, so the foot stays
		# under the lowered hip; the walk swing eases on top of it
		var th: Node3D = s.thighs[i]
		th.rotation.x = lerpf(th.rotation.x - s.crouch_a, sin(ph) * amp, clampf(delta * 12.0, 0.0, 1.0)) + ca
		var kn: Node3D = s.knees[i]
		kn.rotation.x = lerpf(kn.rotation.x + 2.0 * s.crouch_a, -maxf(0.0, sin(ph + 1.3)) * amp * 1.5, clampf(delta * 12.0, 0.0, 1.0)) - 2.0 * ca
	s.crouch_a = ca
	if s.st == FROZEN and not s.edge:
		s.root.position = Vector3(randf_range(-0.012, 0.012), 0.0, randf_range(-0.012, 0.012))   # a fine tremble
	else:
		s.root.position = Vector3.ZERO
	# what it sounds like near you
	if s.st == STALK or s.st == RIM:
		s.whisper_t -= delta
		if s.whisper_t <= 0.0:
			s.whisper_t = randf_range(4.0, 7.0)
			if dl < 22.0:
				_kind(s.amb, "shade_whisper", -8.0, 0.8, 26.0, "", 0.0, 1.0)
	if s.st == RIM:
		s.breath_t -= delta
		if s.breath_t <= 0.0:
			s.breath_t = randf_range(5.0, 8.0)
			if dl < 20.0 and not s.amb.playing:
				_play(s.amb, _game_stream(S306002), -4.0, 0.55, 22.0)
		s.crack_t -= delta
		if s.crack_t <= 0.0:
			s.crack_t = randf_range(6.0, 12.0)
			if dl < 18.0 and randf() < 0.5:
				_kind(s.fx, "shade_crack", -6.0, randf_range(0.85, 1.1), 18.0, "", 0.0, 1.0)


func _hint_check(lf) -> void:
	# first-time hints on THIS player's own machine (hint_once shows each once per map load)
	if lf == null:
		return
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree() or c.get("coop_spectating") or float(c.health) <= 0.0:
		return
	var p: Vector3 = c.global_position
	var near := 1e9
	for s in shades:
		if s.st != DORMANT:
			near = minf(near, s.position.distance_to(p))
	var ln = CoopSync.lantern
	var dry: bool = is_instance_valid(ln) and ln.has_method("is_dry") and bool(ln.call("is_dry"))
	var off: bool = not bool(CoopSync.lantern_on) and not dry
	if off and (near < WAKE_R or _in_any_zone(p)):
		_hint("shade_unlit", "Your lantern is off. Tall things hunt the unlit. Press L to light it.")
	elif dry and near < 30.0:
		_hint("shade_dry", "They are coming. Get into a teammate's light or find oil.")
	elif near < 30.0:
		_hint("shade_first", "Tall things stand where your light ends. They only move in the dark.")


func _hint(key: String, text: String) -> void:
	if _hints.has(key):
		return
	var now := Time.get_ticks_msec()
	if now - _hint_last_ms < HINT_GAP_MS:
		return                           # one hint at a time, so none of them is overwritten
	_hints[key] = now
	_hint_last_ms = now
	if map != null and map.has_method("hint_once"):
		map.call("hint_once", key, text, 6.0)
	else:
		CoopSync.show_banner(text, 6.0)
	print("[SHADE] hint %s" % key)


# ============================================================================ the rig

func _build_materials() -> void:
	_mat_body = StandardMaterial3D.new()
	_mat_body.albedo_color = Color(0.02, 0.018, 0.022)
	_mat_body.roughness = 0.3
	_mat_body.metallic_specular = 0.7
	_mat_body.rim_enabled = true
	_mat_body.rim = 0.4
	_mat_eye = StandardMaterial3D.new()
	_mat_eye.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_eye.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	_mat_eye.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_eye.albedo_color = Color(0.09, 0.08, 0.06, 1.0)
	_mat_eye.albedo_texture = _dot_tex()
	_mat_eye.disable_fog = true
	_mat_eye.disable_receive_shadows = true


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


func _capsule(r: float, h: float) -> CapsuleMesh:
	var key := "%.3f_%.3f" % [r, h]
	if _meshes.has(key):
		return _meshes[key]
	var cm := CapsuleMesh.new()
	cm.radius = r
	cm.height = maxf(h, 2.0 * r + 0.001)
	cm.radial_segments = 8
	cm.rings = 2
	_meshes[key] = cm
	return cm


func _geo(parent: Node3D, mesh: Mesh, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = _mat_body
	mi.position = pos
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	mi.visibility_range_end = VIS_RANGE
	parent.add_child(mi)
	return mi


func _pivot(parent: Node3D, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.position = pos
	parent.add_child(n)
	return n


func _build_rig(s: Shade) -> void:
	# a pivot rig facing -Z: legs 2 x 0.75, torso 0.95 hunched 0.25 rad, neck 0.25, tilted head
	# 0.16 x 0.34, arms 0.8 + 0.85 with three 0.3 m fingers. No lights, no emission.
	s.root = _pivot(s, Vector3.ZERO)
	s.root.rotation.y = s.vis_yaw
	s.hip = _pivot(s.root, Vector3(0.0, 1.5, 0.0))
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var th := _pivot(s.hip, Vector3(0.09 * side, 0.0, 0.0))
		_geo(th, _capsule(0.045, 0.75), Vector3(0.0, -0.375, 0.0))
		var kn := _pivot(th, Vector3(0.0, -0.75, 0.0))
		_geo(kn, _capsule(0.04, 0.75), Vector3(0.0, -0.375, 0.0))
		s.thighs.append(th)
		s.knees.append(kn)
	s.torso = _pivot(s.hip, Vector3.ZERO)
	s.torso.rotation.x = -0.25
	if not _meshes.has("torso"):
		var cy := CylinderMesh.new()
		cy.top_radius = 0.14
		cy.bottom_radius = 0.11
		cy.height = 0.95
		cy.radial_segments = 8
		cy.rings = 1
		_meshes["torso"] = cy
	_geo(s.torso, _meshes["torso"], Vector3(0.0, 0.475, 0.0))
	_geo(s.torso, _capsule(0.1, 0.3), Vector3(0.0, 0.02, 0.0))          # the pelvis
	s.neck = _pivot(s.torso, Vector3(0.0, 0.95, 0.0))
	s.neck.rotation.x = -0.35
	_geo(s.neck, _capsule(0.04, 0.25), Vector3(0.0, 0.125, 0.0))
	s.head = _pivot(s.neck, Vector3(0.0, 0.25, 0.0))
	s.head.rotation.z = 0.3
	var hm := _geo(s.head, _capsule(0.08, 0.34), Vector3(0.0, 0.17, 0.0))
	hm.scale = Vector3(1.0, 1.0, 1.15)
	if not _meshes.has("eye"):
		var q := QuadMesh.new()
		q.size = Vector2(0.05, 0.05)
		_meshes["eye"] = q
	for i in 2:
		var e := MeshInstance3D.new()
		e.mesh = _meshes["eye"]
		e.material_override = _mat_eye
		e.position = Vector3(-0.032 if i == 0 else 0.032, 0.21, -0.085)
		e.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		e.visibility_range_end = VIS_RANGE
		e.visible = false
		s.head.add_child(e)
		s.eyes.append(e)
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var shp := _pivot(s.torso, Vector3(0.17 * side, 0.88, 0.0))
		_geo(shp, _capsule(0.035, 0.8), Vector3(0.0, -0.4, 0.0))
		var el := _pivot(shp, Vector3(0.0, -0.8, 0.0))
		_geo(el, _capsule(0.03, 0.85), Vector3(0.0, -0.425, 0.0))
		var hand := _pivot(el, Vector3(0.0, -0.85, 0.0))
		for f in 3:
			var fp := _pivot(hand, Vector3(float(f - 1) * 0.02, 0.0, 0.0))
			fp.rotation.z = float(f - 1) * 0.25 * side
			fp.rotation.x = 0.15
			_geo(fp, _capsule(0.012, 0.3), Vector3(0.0, -0.15, 0.0))
			if f == 1:
				s.tips.append(fp)        # the middle finger: its tip is the hand's no-clip point
		s.shoulders.append(shp)
		s.elbows.append(el)
	s.voice = _player(s, Vector3(0.0, 2.6, 0.0), 30.0)
	s.amb = _player(s, Vector3(0.0, 2.4, 0.0), 26.0)
	s.fx = _player(s, Vector3(0.0, 1.4, 0.0), 18.0)


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


static func _file_stream(file: String) -> AudioStream:
	# a manifest entry: a game path (res://sfx/...), or a file under maps/underdark/sfx/
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
	# [AudioStream or null, mean db] for a manifest "oneshots" kind
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


static func _kind(p: AudioStreamPlayer3D, kind: String, db: float, pitch: float, max_d: float, fb: String, fb_db: float, fb_pitch: float) -> void:
	# a manifest kind (its mean file db + db), else the game-file fallback, else silence
	var os := _oneshot(kind)
	var st: AudioStream = os[0]
	if st != null:
		_play(p, st, float(os[1]) + db, pitch, max_d)
	elif fb != "":
		_play(p, _game_stream(fb), fb_db, fb_pitch, max_d)


func _player(parent: Node3D, pos: Vector3, max_d: float) -> AudioStreamPlayer3D:
	var p := AudioStreamPlayer3D.new()
	p.position = pos
	p.max_distance = max_d
	p.unit_size = 6.0
	p.bus = _bus()
	parent.add_child(p)
	return p


# ============================================================================ small helpers

func _v(a) -> Vector3:
	if a is Vector3:
		return a
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)


func _pos(p) -> Vector3:
	return (p as Node3D).global_position


func _flat_dist(a: Vector3, p) -> float:
	var q := _pos(p)
	return Vector2(q.x - a.x, q.z - a.z).length()


func _min_dist(p: Vector3, list: Array) -> float:
	var best := 1e9
	for q in list:
		best = minf(best, p.distance_to(q))
	return best


func _nearest(p: Vector3, players: Array, r: float):
	var best = null
	var bd := r
	for pl in players:
		var d := _pos(pl).distance_to(p)
		if d <= bd:
			bd = d
			best = pl
	return best


func _nearest_dist(p: Vector3, players: Array) -> float:
	var best := 1e9
	for pl in players:
		best = minf(best, _pos(pl).distance_to(p))
	return best


func _face(s: Shade, t) -> void:
	var d := _flat(_pos(t) - s.sim)
	if d.length() > 0.1:
		s.yaw = atan2(-d.x, -d.z)


func _pkey(p) -> String:
	if p == Game.climber:
		return "local"
	var pid = (p as Object).get("peer_id")
	if pid != null:
		return str(pid)
	return str((p as Object).get_instance_id())


func _by_id(id: String):
	for s in shades:
		if s.id == id:
			return s
	return null


func _ray(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> Dictionary:
	# both-sided: the cave collision is double-sided (underdark.gd backface_collision) because its
	# winding is not consistent, so a back-culled ray falls through real floors and walls
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


func _my_sid() -> String:
	if CoopSync.has_method("my_sid"):
		return str(CoopSync.call("my_sid"))
	return str(CoopSync.my_id())


# ============================================================================ guest simulation

func guestsim_report() -> Array:
	var out: Array = []
	if _gs_pkts == 0:
		out.append("SKIP shades: no sh packets in the recording")
	else:
		var n := 0
		var ok := 0
		var worst := 0.0
		for i in _gs_last.keys():
			var s: Shade = shades[int(i)]
			var d: float = s.position.distance_to(_gs_last[i])
			n += 1
			worst = maxf(worst, d)
			if s.visible and s.is_visible_in_tree() and d <= 1.0:
				ok += 1
		if n == 0:
			out.append("SKIP shades: the last sh packet had no awake Shade")
		elif ok == n:
			out.append("PASS shades visible n=%d within 1.0 m of the last sh packet" % n)
		else:
			out.append("FAIL shades visible %d/%d within 1.0 m of the last sh packet (worst %.2f m)" % [ok, n, worst])
	if _gs_hold_frames > 0:
		if _gs_hold_moves == 0:
			out.append("PASS hold while local_lit (%d held frames, none moved)" % _gs_hold_frames)
		else:
			out.append("FAIL hold while local_lit: moved in %d of %d held frames" % [_gs_hold_moves, _gs_hold_frames])
	elif shades.is_empty():
		out.append("SKIP hold while local_lit: no Shades")
	else:
		out.append(("PASS" if _hold_selftest() else "FAIL") + " hold while local_lit (no hold in the recording: checked on sh_1 here)")
	return out


func _hold_selftest() -> bool:
	# the guest HOLD rule on a real Shade: lit, a stream 2 m away does not move it; dark, it does
	var s: Shade = shades[0]
	var p0 := s.position
	var rp0 := s.rp_pos
	var st0 := s.st
	var buf0: Array = s.buf.duplicate()
	var tp0 := s.shown_tp
	s.st = STALK
	s.rp_pos = p0 + Vector3(2.0, 0.0, 0.0)
	# the no-clip guest path draws from the sample buffer: one sample 2 m away, older than the
	# render delay, with the teleport count this screen already shows (a move, not a snap)
	s.buf = [[Time.get_ticks_msec() - RENDER_MS - 80, s.rp_pos, s.yaw, s.shown_tp, ROOM_MAX]]
	s.lit_t = 0.0
	s.held = false
	s.was_held = false
	_force_local_lit = 1
	for i in 5:
		_guest_move(s, 0.05, null)
	var held_ok := s.position.distance_to(p0) < 0.001
	_force_local_lit = 0
	s.lit_t = 0.0
	for i in 5:
		_guest_move(s, 0.05, null)
	var moved_ok := s.position.distance_to(p0) > 0.3
	_force_local_lit = -1
	s.position = p0
	s.rp_pos = rp0
	s.st = st0
	s.held = false
	s.was_held = false
	s.buf = buf0
	s.shown_tp = tp0
	return held_ok and moved_ok


# ============================================================================ dev test
# lightfear.flag phase 1 (light.gd reads the flag and calls run_test_phase through call()).
# Every step parks the player 8 to 14 m from sh_4 (only it is awake during the test; the next
# Shade with a walkable line that long when sh_4's home has none: 14 m when it can walk that far, else 13, 12, 10 or 8) and
# faces AWAY from it, so only the glow counts, unless the step aims.

func run_test_phase(done: Callable) -> void:
	_run_test(done)


func _run_test(done: Callable) -> void:
	_tp = 0
	_tn = 0
	_tfails.clear()
	_tlog.clear()
	_testing = true
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")
	var loop: bool = CoopSync.get("_loopback") == true
	if loop:
		CoopSync.set("_loop_step", 7)
		# the Ghost mirrors this player 0.7 s late, 3.5 m ahead of the view: its lantern goes on
		# 0.7 s after mine, so every relight left it an unlit, graced-out target the Shade shrieked
		# at (A-SHADE-loop "RIM at 13.39 m"). This phase measures MY lantern: the Ghost is no target
		# (its lantern still counts in the LightField: "lanterns = 2")
		_test_no_ghost = true
		print("[SHADE] loopback: the Ghost is not a Shade target during this phase")
	print("[SHADE] phase 1: the Shades")
	var c = Game.climber
	var t_wait := Time.get_ticks_msec()
	while not (is_instance_valid(c) and (c as Node).is_inside_tree()) and Time.get_ticks_msec() - t_wait < 20000:
		await get_tree().process_frame     # called before the level is up: wait for the knight
		if not is_inside_tree():
			return
		c = Game.climber
	var ln = CoopSync.lantern
	var lf = _lf()
	if not is_instance_valid(c) or not is_instance_valid(ln) or shades.is_empty() or lf == null:
		_check("setup (climber, lantern, Shades, LightField)", false, "climber=%s lantern=%s shades=%d lightfield=%s" % [str(is_instance_valid(c)), str(is_instance_valid(ln)), shades.size(), str(lf != null)])
		_test_end(done, null, null, -1)
		return
	var orig_user = ln.get("user")
	var orig_oil = ln.get("oil")
	var orig_mode := int(map.get("_bright_i")) if map.get("_bright_i") != null else 0
	c.prevent_player_death = true
	# ---- 1. homes
	var counts: Array = []
	for bi in bands.size():
		counts.append("%s %d" % [str(bands[bi]["name"]), _band_count(bi)])
	print("[SHADE] %d shades: %s" % [shades.size(), ", ".join(counts)])
	var got: Array = []
	for i in shades.size():
		var hi: Dictionary = _home_info[i]
		got.append(int(hi["station"]))
		print("[SHADE] home %s %s station %d at %s static_k=%.3f checkpoint %.1f m" % [shades[i].id, str(bands[int(hi["band"])]["name"]), int(hi["station"]), str(hi["pos"]), float(hi["k"]), float(hi["cp"])])
	var want_s: Array = []
	for x in TEST_HOMES:
		want_s.append(str(x))
	var got_s: Array = []
	for x in got:
		got_s.append(str(x))
	var rooms_t = (map.get("L") as Dictionary).get("home_room", null) if map != null and map.get("L") is Dictionary else null
	if rooms_t is Dictionary and not (rooms_t as Dictionary).is_empty():
		# v5.1: homes are re-picked by room: every Shade must have at least 80 m2 to roam where the band allows it
		var small: Array = []
		for x2 in got:
			if int(rooms_t.get(str(x2), 0)) < 80:
				small.append("%d (%d m2)" % [x2, int(rooms_t.get(str(x2), 0))])
		print("[SHADE] home rooms: %s" % ", ".join(PackedStringArray(got.map(func(x3): return "%d:%d" % [x3, int(rooms_t.get(str(x3), 0))]))))
		_check("homes are roomy", small.size() <= 1, "" if small.size() <= 1 else "small: " + ", ".join(PackedStringArray(small)))
	else:
		_check("homes = " + ",".join(want_s), got == TEST_HOMES, "" if got == TEST_HOMES else "got " + ",".join(got_s))
	# sh_4 first; if its home has no walkable 8 to 14 m line on this layout (on v5.0 it sits on a narrow
	# shelf lip over a drop), the next Shade that has one: a level line first, then any line
	var first = _by_id("sh_4")
	if first == null:
		first = shades[mini(3, shades.size() - 1)]
	var order: Array = [first]
	for s2 in shades:
		if s2 != first:
			order.append(s2)
	var sh = first
	var spot = null
	for flat in [true, false]:
		for cand in order:
			sh = cand
			_test_only = sh.id
			spot = await _test_spot(sh, c, flat)
			if not is_inside_tree():
				return
			if spot != null:
				break
			print("[SHADE] no %s floor spot 8-14 m from %s: trying the next Shade" % ["level walkable" if flat else "walkable", sh.id])
		if spot != null:
			break
	if spot == null:
		_check("a floor spot 8-14 m from a Shade home", false)
		_test_end(done, orig_user, orig_oil, orig_mode)
		return
	if sh != first:
		print("[SHADE] the test uses %s (not %s)" % [sh.id, first.id])
	print("[SHADE] test spot %s, %.1f m from %s" % [str(spot), _flat((spot as Vector3) - sh.home).length(), sh.id])
	# ---- 2. NORMAL mode first (the unlit grace is once per load)
	_test_hold = true                    # nothing wakes until the knight stands on the spot
	ln.set("user", -1)                   # so set_light_mode never saves the player's L choice
	if map.has_method("set_light_mode"):
		map.call("set_light_mode", 1)
	ln.set("oil", 1.0)
	await _wait(0.2)
	if bool(ln.call("wanted")):
		ln.set("user", 0)
	_reset_shade(sh)
	_park(c, spot, sh.home)
	await get_tree().physics_frame
	# the grace and the hint are once per load: this test starts them from here
	_grace_start.erase("local")
	_grace_done.erase("local")
	_hints.erase("shade_unlit")
	_hint_last_ms = -100000
	_test_hold = false
	var h2 := float(c.health)
	var woke: bool = await _until(func(): return sh.st != DORMANT, 3.0)
	var t_wake := Time.get_ticks_msec()
	await _wait(4.0)
	if not is_inside_tree():
		return
	var tell2 := _tlog_first(sh.id, TELL, t_wake - 50)
	var hint_ms := int(_hints.get("shade_unlit", -1))
	_check("normal mode: the lantern-off hint within 1 s of waking it", woke and hint_ms >= 0 and hint_ms <= t_wake + 1000, "hint at %+.2f s" % ((hint_ms - t_wake) / 1000.0) if hint_ms >= 0 else "no hint")
	_check("normal mode: no TELL and no damage in the first 4.0 s", woke and (tell2 < 0 or tell2 >= t_wake + 4000) and float(c.health) >= h2 - 0.01, ("TELL at %+.2f s" % ((tell2 - t_wake) / 1000.0) if tell2 >= 0 else "no TELL") + ", health %.1f -> %.1f" % [h2, float(c.health)])
	ln.set("user", -1)
	if map.has_method("set_light_mode"):
		map.call("set_light_mode", 0)
	ln.set("user", 1)
	# ---- 3. the rim at full oil
	await _wait(0.5)
	_reset_shade(sh)
	ln.set("oil", 1.0)
	_park(c, spot, sh.home)
	var t3 := Time.get_ticks_msec()
	var rim3: bool = await _until(func(): return sh.st == RIM, 16.0)
	await _wait(1.0)
	if not is_inside_tree():
		return
	var d3 := _flat_dist(sh.sim, c)
	var stalk3 := _tlog_first(sh.id, STALK, t3)
	var tell3 := _tlog_first(sh.id, TELL, t3)
	_check("full oil: STALK then RIM stops 4.5-6.0 m away, never TELL", rim3 and sh.st == RIM and stalk3 >= 0 and tell3 < 0 and d3 >= 4.5 and d3 <= 6.0, "RIM at %.2f m" % d3)
	_aim(c, sh.sim + Vector3.UP * CHEST, 0.61)       # 35 degrees off: the beam misses it
	await get_tree().process_frame
	await get_tree().process_frame
	if map.has_method("debug_shot"):
		map.call("debug_shot", "user://underdark_shade_rim.png")
	_face_away(c, sh)
	await _wait(0.6)
	# ---- 4. aim at it
	await _until(func(): return sh.st == RIM and sh.st_t > 0.4, 6.0)
	var hiss0: int = sh.hiss_n
	var t4 := Time.get_ticks_msec()
	_aim(c, sh.sim + Vector3.UP * CHEST, 0.0)
	var froze4: bool = await _until(func(): return sh.st == FROZEN, 1.5)
	var tf4 := _tlog_first(sh.id, FROZEN, t4)
	_check("aimed: FROZEN plus a hiss within 0.3 s", froze4 and tf4 >= 0 and tf4 - t4 <= 300 and sh.hiss_n > hiss0, "%.2f s, hisses %d" % [(tf4 - t4) / 1000.0, sh.hiss_n - hiss0])
	var edged: bool = await _until(func(): return sh.st == FROZEN and sh.edge, 1.5)
	_check("aimed: then EDGE", edged)
	var out4: bool = await _until(func(): return sh.st == RIM, 8.0)
	print("[SHADE] out of the beam: %s, %s at %.2f m" % [str(out4), NAMES[sh.st], _flat_dist(sh.sim, c)])
	_face_away(c, sh)
	await _until(func(): return sh.st == RIM and sh.st_t > 0.5, 8.0)
	if not is_inside_tree():
		return
	# ---- 5. lantern off: TELL at once, RUSH 1.1 s later
	var t5 := Time.get_ticks_msec()
	ln.set("user", 0)
	await _until(func(): return sh.st == TELL, 1.5)
	var tt5 := _tlog_first(sh.id, TELL, t5)
	_check("lantern off: TELL within 0.3 s (the grace is used up)", tt5 >= 0 and tt5 - t5 <= 300, "%.2f s" % ((tt5 - t5) / 1000.0) if tt5 >= 0 else "no TELL")
	await _until(func(): return sh.st == RUSH, 2.5)
	var tr5 := _tlog_first(sh.id, RUSH, t5)
	_check("TELL 1.1 s, then RUSH", tt5 >= 0 and tr5 >= 0 and absf((tr5 - tt5) / 1000.0 - TELL_S) <= 0.15, "%.2f s" % ((tr5 - tt5) / 1000.0) if tr5 >= 0 and tt5 >= 0 else "no RUSH")
	# ---- 6. lantern on 0.5 s into the RUSH: FROZEN, no strike
	var h6 := float(c.health)
	if tr5 >= 0:
		await _wait(maxf(0.0, 0.5 - (Time.get_ticks_msec() - tr5) / 1000.0))
	ln.set("user", 1)
	var t6 := Time.get_ticks_msec()
	var froze6: bool = await _until(func(): return sh.st == FROZEN, 1.0)
	await _wait(1.5)
	if not is_inside_tree():
		return
	_check("lantern on 0.5 s into the RUSH: FROZEN, no strike", froze6 and float(c.health) >= h6 - 0.01, "FROZEN %.2f s after, health %.1f -> %.1f" % [(_tlog_first(sh.id, FROZEN, t6) - t6) / 1000.0, h6, float(c.health)])
	# ---- 7. off again: the strike, then the retreat
	await _until(func(): return sh.st == RIM and sh.st_t > 0.3, 8.0)
	var h7 := float(c.health)
	var t7 := Time.get_ticks_msec()
	ln.set("user", 0)
	var hit7: bool = await _until(func(): return float(c.health) < h7 - 0.5, 7.0)
	await _wait(0.1)
	var drop7 := h7 - float(c.health)
	var expect7 := 20.0 * _dmg_mult()
	_check("lantern off again: STRIKE for 20 +-1 HP", hit7 and absf(drop7 - expect7) <= 1.0, "%.1f HP (expected %.1f at this damage setting)" % [drop7, expect7])
	var ret7: bool = await _until(func(): return sh.st == RETREAT, 1.0)
	var tret := _tlog_first(sh.id, RETREAT, t7)
	if tret >= 0:
		await _until(func(): return Time.get_ticks_msec() - tret >= 5500, 7.0)
	ln.set("user", 1)                    # relit 5.5 s in: it is home by then, out of the glow
	await _until(func(): return sh.st != RETREAT, 2.0)
	var tend := _tlog_next(sh.id, tret) if tret >= 0 else -1
	_check("then RETREAT for 6 s", ret7 and tret >= 0 and tend >= 0 and absf((tend - tret) / 1000.0 - RETREAT_S) <= 0.3, "%.2f s" % ((tend - tret) / 1000.0) if tend >= 0 and tret >= 0 else "no retreat")
	# ---- 8. oil 0.05: the rim moves in
	await _wait(0.5)
	_reset_shade(sh)
	ln.set("oil", 0.05)
	ln.set("user", 1)
	_park(c, spot, sh.home)
	var rim8: bool = await _until(func(): return sh.st == RIM, 16.0)
	await _wait(1.0)
	if not is_inside_tree():
		return
	var d8 := _flat_dist(sh.sim, c)
	_check("oil 0.05, lantern on: the rim is 2.5-3.8 m", rim8 and sh.st == RIM and d8 >= 2.5 and d8 <= 3.8, "RIM at %.2f m" % d8)
	# ---- 9. oil 0: no TELL for 2.5 s, then TELL
	var t9 := Time.get_ticks_msec()
	ln.set("oil", 0.0)
	await _until(func(): return sh.st == TELL, 4.0)
	var tt9 := _tlog_first(sh.id, TELL, t9)
	_check("dry: no TELL for 2.5 s, then TELL", tt9 >= t9 + DRY_GRACE_MS and tt9 <= t9 + 3400, "TELL at %.2f s" % ((tt9 - t9) / 1000.0) if tt9 >= 0 else "no TELL")
	print("[SHADE] dry hint shown: %s" % str(_hints.has("shade_dry")))
	ln.set("oil", 1.0)
	ln.set("user", 1)
	await _wait(1.0)
	if not is_inside_tree():
		return
	# ---- 10. loopback: two lanterns, and the sh stream round-trips
	if loop:
		var stt = lf.call("stats") if lf.has_method("stats") else {}
		var nl := int((stt as Dictionary).get("lanterns", -1)) if stt is Dictionary else -1
		_check("loopback: lanterns = 2", nl == 2, str(stt))
		_check("loopback: the sh stream round-trips", _roundtrip_ok())
	else:
		print("[SHADE] SKIP loopback steps (no loopback.flag)")
	# ---- 11. the victim-side light rule
	ln.set("user", 1)
	await _wait(0.5)
	var h11 := float(c.health)
	var cp: Vector3 = c.global_position
	if map.has_method("coop_map_event"):
		map.call("coop_map_event", "cbite_sh_1", {"who": _my_sid(), "dmg": STRIKE_DMG, "at": [cp.x, cp.y, cp.z], "r": STRIKE_HIT_R, "nl": true}, false)
	await _wait(0.4)
	_check("nl bite ignored", float(c.health) >= h11 - 0.01, "health %.1f -> %.1f" % [h11, float(c.health)])
	_test_end(done, orig_user, orig_oil, orig_mode)


func _test_end(done: Callable, orig_user, orig_oil, orig_mode: int) -> void:
	var c = Game.climber
	var ln = CoopSync.lantern
	var sh = _by_id(_test_only)
	_test_only = ""
	_test_hold = false
	_test_no_ghost = false
	if sh != null:
		_reset_shade(sh)
	if is_instance_valid(ln):
		if orig_mode >= 0 and map != null and map.has_method("set_light_mode") and orig_mode != int(map.get("_bright_i")):
			ln.set("user", -1)
			map.call("set_light_mode", orig_mode)
		if orig_user != null:
			ln.set("user", orig_user)
		if orig_oil != null:
			ln.set("oil", orig_oil)
	if is_instance_valid(c):
		c.prevent_player_death = false   # a test never leaves the player invincible
	_testing = false
	if _tfails.is_empty():
		print("[SHADE] phase done %d/%d PASS" % [_tp, _tn])
	else:
		print("[SHADE] phase done %d/%d FAIL: %s" % [_tp, _tn, ", ".join(_tfails)])
	if done.is_valid():
		done.call(_tp, _tn)


func _check(what: String, ok: bool, detail: String = "") -> void:
	_tn += 1
	if ok:
		_tp += 1
	else:
		_tfails.append(what)
	print("[SHADE] %s %s%s" % ["PASS" if ok else "FAIL", what, ("   (" + detail + ")") if detail != "" else ""])


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _until(cond: Callable, timeout: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not bool(cond.call()):
		if Time.get_ticks_msec() - t0 > int(timeout * 1000.0) or not is_inside_tree():
			return false
		await get_tree().process_frame
	return true


func _tlog_first(id: String, st: int, since: int) -> int:
	for e in _tlog:
		if int(e[0]) >= since and str(e[1]) == id and int(e[2]) == st:
			return int(e[0])
	return -1


func _tlog_next(id: String, after: int) -> int:
	# the first state change of that Shade after `after` (EDGE notes are not state changes)
	for e in _tlog:
		if int(e[0]) > after and str(e[1]) == id and int(e[2]) >= 0:
			return int(e[0])
	return -1


func _reset_shade(s: Shade) -> void:
	_set_state(s, DORMANT)
	_reset_home(s)
	s.yaw = 0.0
	_struck.clear()
	_rush_cool.clear()
	_locks.clear()


func _park(c, pos: Vector3, face_from: Vector3) -> void:
	if map != null and map.has_method("debug_park"):
		map.call("debug_park", pos + Vector3.UP * 1.0)
	else:
		c.set_climber_state(c.defaultClimberState)
		c.velocity = Vector3.ZERO
		c.health = c.healthMax
		c.teleport_to_location(pos + Vector3.UP * 1.0)
	var d := _flat(pos - face_from)
	if d.length() > 0.1:
		_look(c, d.normalized(), 0.0)


func _face_away(c, s: Shade) -> void:
	var d := _flat(c.global_position - s.sim)
	if d.length() > 0.1:
		_look(c, d.normalized(), 0.0)


func _aim(c, at: Vector3, off_yaw: float) -> void:
	var cam = c.get("Camera")
	var eye: Vector3 = (cam as Node3D).global_position if cam is Node3D else c.global_position + Vector3.UP * 0.77
	var d := (at - eye).normalized()
	if off_yaw != 0.0:
		d = d.rotated(Vector3.UP, off_yaw)
	_look(c, d, 1.0)


func _look(c, d: Vector3, pitch_k: float) -> void:
	# the view angles live on PlayerCamera.CameraAngles and the Camera node (not
	# set_camera_rotation: that also turns the PlayerCamera node, so the view turns twice for a
	# second while it eases back)
	var ang := Vector3(asin(clampf(d.y, -0.999, 0.999)) * pitch_k, atan2(-d.x, -d.z), 0.0)
	var pc = c.get("PlayerCamera")
	if pc is Node3D:
		pc.set("CameraAngles", ang)
		(pc as Node3D).rotation = Vector3.ZERO
	var cam = c.get("Camera")
	if cam is Node3D:
		(cam as Node3D).rotation = ang
	c.global_rotation = Vector3.ZERO


func _dmg_mult() -> float:
	var bs = Game.get("active_balance_settings")
	if bs is Object and is_instance_valid(bs):
		var m = (bs as Object).get("damage_multiplier")
		if m != null:
			return float(m) * 0.01
	return 1.0


func _test_spot(sh: Shade, c, flat: bool):
	# a floor point 8 to 14 m from the home (the longest of 14, 13, 12, 10, 8 m that a Shade can walk to; the no-clip walk
	# keeps some Shades in a pocket): the player first stands on
	# the home itself (every Shade held asleep) so the collision is there, then down rays. flat:
	# the whole line within 1.5 m of the home's height (the rim distances assume level ground)
	_test_hold = true
	_reset_shade(sh)
	_park(c, sh.home, sh.home + Vector3.FORWARD)
	await _wait(1.2)
	if not is_inside_tree():
		_test_hold = false
		return null
	if not sh.floored and _snap_home(sh):
		_reset_home(sh)                  # the home is on its rock now (it floated over it before)
	if not sh.home_ok:
		_test_hold = false
		return null                      # no-clip G4: a home with no floor never wakes
	if sh.home_move:
		_reset_home(sh)                  # the test's own reset (scripted, like _reset_shade)
	var w3 := (c as Node3D).get_world_3d()
	var found = null
	if w3 != null:
		var space := w3.direct_space_state
		for want in [14.0, 13.0, 12.0, 10.0, 8.0]:
			var dirs: Array = []
			for q in bands[sh.band]["route"]:
				var dq := _flat((q as Vector3) - sh.home)
				if dq.length() > 6.0:
					dirs.append([absf(dq.length() - want), dq.normalized()])
			dirs.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
			for i in 12:
				dirs.append([100.0 + i, Vector3(sin(i * TAU / 12.0), 0.0, cos(i * TAU / 12.0))])
			for e in dirs:
				var p = _walk_line(space, sh, e[1], want, flat)
				if p != null:
					found = p
					break
			if found != null:
				break
	_test_hold = false
	return found


func _walk_line(space: PhysicsDirectSpaceState3D, sh: Shade, dir: Vector3, dist: float, flat: bool):
	# every metre from the home along dir: floor within 2 m of the last one (flat: and within 1.5 m
	# of the home's height), inside the zone, clear of checkpoints and with no rock at chest height
	# in between
	var last := sh.home
	var n := int(dist)
	var nc: bool = _ncx() != null
	_rr_rays = 0                         # _walk_step stops at RR_CAP rays: a fresh count for every line
	for i in range(1, n + 1):
		var q := sh.home + dir * float(i)
		var hit := _ray(space, Vector3(q.x, last.y + 3.0, q.z), Vector3(q.x, last.y - 6.0, q.z))
		if hit.is_empty():
			return null
		var f: Vector3 = hit["position"]
		if absf(f.y - last.y) > 2.0 or not _in_zone(sh.band, f) or _near_cp(f, CP_KEEP_OUT):
			return null
		if flat and absf(f.y - sh.home.y) > 1.5:
			return null
		if not _ray(space, last + Vector3.UP * CHEST, f + Vector3.UP * CHEST).is_empty():
			return null
		if nc and not _headroom(space, f):
			return null                  # no-clip: the Shade needs 2.5 m of headroom to walk there
		if nc and _walk_step(space, sh.band, last, dir, 1.0, sh) == null:
			return null                  # the Shade's own walk (hunch, parts, squeezes) refuses this metre
		last = f
	return last


func _roundtrip_ok() -> bool:
	# the sh packet through the same encoding the net uses, decoded like a guest does
	var v = _send_sh()
	if v == null:
		print("[SHADE] round trip: every Shade is asleep, nothing to send")
		return false
	var back = bytes_to_var(var_to_bytes({"t": "maps", "d": {"cx": {"sh": v}}}))
	var arr = back["d"]["cx"]["sh"]
	if not (arr is Array) or (arr as Array).size() != shades.size():
		return false
	for i in shades.size():
		var s: Shade = shades[i]
		var e = arr[i]
		if s.st == DORMANT:
			if e.size() != 0:
				return false
			continue
		if e.size() < 5 or int(e[0]) != s.st:
			return false
		if Vector3(float(e[1]), float(e[2]), float(e[3])).distance_to(s.sim) > 0.01:
			return false
	print("[SHADE] round trip: %d entries, %d awake" % [shades.size(), awake_count()])
	return true
