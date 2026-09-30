extends Node
# ============================================================================================
# THE UNDERDARK: the Void Harriers (ZondaCoopSync 5.0, feature "harriers", owner B6)
#
# Pale bat-winged things wheel far out over the open rift in three bands. One picks a player who
# stands unhooked on a foothold near a drop, glides in, hangs about 18 m up and SHRIEKS (an echo
# off the far wall 0.35 s later), folds and stoops. At 0.9 s it commits with a click-screech; at
# 1.5 s it rakes through and flings its victim about 4 m toward the drop. Counterplay: hook in
# (5 HP and a sway), step back from the edge (it aborts at the commit), dodge 2.2 m, or walk back
# against the shove. The first dive per band per run pulls up 5 m short (the teaching feint).
#
# Loaded by the map (underdark.gd _load_features): setup(map) BEFORE add_child. It reaches the map
# only through the 2.2 API (register_events / register_stream / register_threats, dev_flag,
# enclosed, debug_park, debug_look, debug_shot) and through rift.gd (loaded at runtime).
#
# Module API (the map calls these when present):
#   setup(map)                   registers "hdive_" + "hstrike_" (repeatable), "hfeint_" (persistent),
#                                the "hv" cx stream and the harriers as heartbeat threats
#   threat_positions() -> Array  harriers in APPROACH or DIVE (heartbeat only, never far-rock centres)
#   on_session_ended()           a dive in progress drops back to CIRCLE with no strike
#   guestsim_report() -> Array   "PASS hdive flew the 1.5 s curve", "PASS harriers visible n=<k>" (or SKIP),
#                                "PASS harrier guest no-clip: ..." (v5.0 no-clip, SKIP while the guard is off)
#   on_exit()
#   harriers() -> Array          the five Harrier nodes (hv1..hv5)
#
# v5.0 NO-CLIP (spec 2026-09-25-creature-noclip.md 3.I, group NC-6). Every behaviour change below runs only
# while noclip.gd says is_enabled() (Rule K: THE UNDERDARK live and the guard on); otherwise today's code.
# noclip.gd is loaded at runtime (never preloaded). What the guard adds:
#   I0 wake() re-seeds the mover with NC.place; I1 NC.move every physics tick (free_off: far from every
#   player the harriers fly on data, plus a wall-radius rule), clearance probes (wings 2.1, head 2.3,
#   belly 1.0), refused moves by state; I2 a real dive ends 2.3 m short of the aim, a swept nose ray each
#   dive frame (host and guest), and at IMPACT a harrier stopped short or behind rock PULLS UP (no hit
#   test); I3 the hang point F needs a clear 2.4 m sphere (pushed 3 to 8 m voidward); I4 the approach
#   re-rays to F every 0.25 s; I5 the stoop line (3 rays) is checked at the shriek, whenever the aim moves
#   1 m and at the commit; I6 the rake picks a clear 24 m line; I7 circling casts the 3D step plus both
#   wingtips; I8 guests interpolate host samples 120 ms behind (no extrapolation but 0.1 s in CIRCLE) and
#   only glide along clear rays.
# No-clip API (the probe, noclip_probe.gd, calls these at runtime):
#   noclip_points() -> Array      one entry per harrier (kind "harrier", view "host" / "guest"): centre,
#                                 head (+2.2 along the drawn forward), wingtips (+-2.0 x the fold)
#   noclip_test_spot(i) -> Array  [park position, look point] of an exposed edge in band i, or []
#   noclip_test_dive(p) -> bool   arms a real (non-feint) dive of p's band at p, through the natural gate
# Counters (NC.note, kind "harrier", both Rule K branches): shrieks, impacts, hits, giveups, nc_aborts,
# nc_pullups.
#
# Harrier (inner class, Node3D, top_level, world coords):
#   setup(band: Dictionary, idx: int, mod)       idx 0..4 = hv1..hv5
#   signal dived(who: String, from: Vector3, aim: Vector3, feint: bool, id: String)   authority, at the shriek
#   signal struck(who: String, dir: Vector2, at: Vector3, id: String)                 authority, per victim
#   state_packet() -> Array      [x, y, z, yaw, st] (PackedFloat32Array); st 0 CIRCLE, 1 APPROACH,
#                                2 FOLD/DIVE, 3 RAKE, 4 IDLE
#   remote_state(a)              guests: follow the stream
#   remote_dive(from, aim, feint)  guests: fly the same 1.5 s dive curve locally
#   threat_positions() -> Array  its body while it approaches or dives
#   debug_ready()                tests: clear its cooldown
#
# Events: hdive_<hvN> {who: sid, from: [3], aim: [3], feint}  (non-persistent, at the shriek)
#         hstrike_<hvN> {who: sid, dir: [2], at: [3], aim: [3]} (non-persistent, per victim; the victim
#                                                               judges it on its own screen, the 2.2 m
#                                                               dodge against the committed aim)
#         hfeint_<band> {}                                     (persistent, authority only; not SAVE progress)
# Stream: cx "hv" = 5 entries, [] for an idle or far (> 250 m) harrier; not sent when all are [].
#         Guests idle every harrier (not mid-dive) after HV_STALE_MS with no "hv" packet.
# Assets: MOD/maps/underdark/ext/mon/harrier.glb (Kit.make_rig "harrier"), sfx kinds harrier_shriek,
#         harrier_wing, harrier_dive; res://sfx/soundsnap/205785-EFX_EXT_Rope_Swing_Creaks.wav (hooked).
# Dev test: maps/underdark/harrier.flag, tag [HARRIER] (see _test_step).
# ============================================================================================

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const SFX_HOOKED := "res://sfx/soundsnap/205785-EFX_EXT_Rope_Swing_Creaks.wav"
const SFX_CLICK := "res://sfx/soundsnap/creature_footsteps/243425-metal_hit_small-carpet_knife01.wav"
const HEAD := "res://Art/Monster_Head_Redesign.glb"
const PALE := Color(0.10, 0.095, 0.085)

const BANDS := [
	{"name": "mouth", "top": -170.0, "bottom": -400.0, "ids": ["hv1"]},
	{"name": "drowned", "top": -1880.0, "bottom": -2590.0, "ids": ["hv2", "hv3"]},
	{"name": "foundry", "top": -3600.0, "bottom": -4100.0, "ids": ["hv4", "hv5"]},
]

# flight
const CIRCLE_K := 0.55            # circle radius, x Rift.radius(y)
const SMALL_K := 0.25             # near a slab: circle radius around the terrace's open point, x R(y_top)
const CIRCLE_V := 13.0
const ALT_ABOVE := 22.0           # over the lowest living player in the band
const ALT_EASE := 3.0             # m/s
const CLIMB_V := 10.0             # m/s back up after a rake
const SLAB_PAD := 8.5             # wanted altitudes stay outside [bottom - 8, y_top + 8]
const SLAB_NEAR := 20.0           # within this of a slab the circle becomes the small one
const WAKE_PAD := 80.0            # awake while a living player is within the band +- this
const BOB_V := 0.8                # thermal bob, peak m/s (2.0 in the Foundry)
const AVOID_RAY := 12.0
const AVOID_TURN := 0.349         # 20 deg toward the axis per hit
# the dive
const APPROACH_V := 20.0
const APPROACH_GIVEUP := 6.0
const HANG_S := 0.25
const FOLD_S := 0.25
const COMMIT_S := 0.9
const IMPACT_S := 1.5
const RUSH_S := 0.7               # the dive rush starts 0.8 s before impact
const STOOP_UP := 18.0
const STOOP_OUT := 3.0
const TRACK_V := 4.0              # the aim follows the target this fast until the commit
const CHEST := 0.3
const HIT_R := 2.2
const HIT_DY_LO := -1.2
const HIT_DY_HI := 2.5
const FEINT_SHORT := 5.0
const RAKE_S := 1.2
const RAKE_V := 20.0
# targeting and cooldowns
const TARGET_R := 110.0
const CAMP_R := 15.0
const PERSONAL_CD := 40.0
const HARRIER_CD := 45.0
const HARRIER_CD_RAND := 8.0
const BAND_GAP := 25.0
const BAND_GAP_SOLO := 35.0
const LOAD_GRACE := 12.0
const THINK_S := 0.5
# the strike (victim side)
const STRIKE_DMG := 20.0          # the game halves it: 10 HP
const STRIKE_DMG_HOOKED := 10.0   # 5 HP
const STRIKE_PUSH := 20.0         # horizontal only: about 4.2 m of slide at 120 Hz physics
const STRIKE_AT_R := 3.0
const DODGE_PAD := 0.5            # victim side: out of HIT_R (and the dy band) + this from the aim = dodged
const JUST_HOOKED_S := 0.5
const STREAM_FAR := 250.0
const HV_STALE_MS := 1000         # guests: no "hv" packet this long = every band asleep on the host
const FLOOR_NY := 0.6             # tests: a floor hit this flat or flatter is one a knight can stand on
const FEINT_TEXT := "It pulled up. Next time it will not. Hook in, or step back from the edge."
# v5.0 no-clip (3.I). The body envelope is noclip.gd ENV "harrier" (4.42 m long, 4.0 m span).
const NC_PATH := DIR + "noclip.gd"
const NC_OFF := 0                 # noclip.gd tiers (frozen API 2.1)
const NC_NEAR := 2
const NC_FULL := 3
const HALF_LEN := 2.2             # centre to the nose
const HALF_SPAN := 2.0            # centre to a wingtip, wings open
const BELLY := 1.0
const HANG_R := 2.4               # I3: the hang point needs a clear sphere this big
const HANG_OUT_MAX := 8.0         # I3: F is pushed voidward from STOOP_OUT up to this, 1 m at a time
const DIVE_END := 2.3             # I2: a real dive ends this far short of the aim, back along the stoop
const NOSE := 2.4                 # I2: the nose ray each dive frame
const PULLUP_D := 3.8             # I2: at IMPACT farther than this from the aim (DIVE_END + 1.5) = a pull-up
const PITCH_UP_S := 0.2           # I2: the pull-out starts this long before IMPACT
const STOOP_SIDE := 1.2           # I5: side rays of the stoop line (the folded wings reach 0.9 m) + margin
const RAKE_LOOK := 24.0           # I6
const RAKE_MARGIN := 3.0          # I6: slab margin while raking
const WALL_PAD := 15.0            # OFF tier: never farther than Rift.radius(y) - this from the axis
const APP_RAY_S := 0.25           # I4
const HOLD_S := 0.5               # I7: the vertical change is held this long after an avoid hit
const REACT_S := 0.25             # I1: a refused CIRCLE move reacts at most this often
const G_DELAY_MS := 120           # I8: guests draw the host's samples this far behind the newest
const G_SNAP := 3.0               # I8: past this error a guest glides (clear ray) or snaps
const G_GLIDE_V := 60.0           # I8: the fastest catch-up glide (m/s)
const G_EXTRA_S := 0.1            # I8: extrapolation cap, CIRCLE only (and 1 m)
const STREAM_DT := 0.1            # the "hv" stream period (underdark.gd _stream_creatures)
const NC_TEST_S := 20.0           # noclip_test_dive: the band stays armed this long
# the Drowned test foothold that the real-game harrier runs validated (A-HARRIER 2026-09-24: exposed 2-3,
# targetable); noclip_test_spot ranks it first while it is still a layout station
const NC_KNOWN_SPOTS := [[1, Vector3(294.354, -2225.613, 50.299)]]

var map: Node = null
var Rift = null                   # rift.gd (loaded at runtime, 1A.1)
var _kit = null                   # creatures.gd Kit (loaded at runtime, 1A.1)
var _mon: Dictionary = {}         # ext/mon/manifest.json "harrier"
var _hv: Array = []               # Harrier nodes, hv1..hv5
var _band_hv: Array = [[], [], []]
var _band_terr: Array = [[], [], []]
var _band_awake: Array = [false, false, false]
var _band_low: Array = [null, null, null]
var _band_gap_until: Array = [0.0, 0.0, 0.0]
var _feinted: Dictionary = {}     # band name -> true (hfeint_ stored)
var _feint_pending: Dictionary = {}
var _personal_cd: Dictionary = {} # sid -> clock when it may be dived again
var _clock := 0.0
var _grace_until := LOAD_GRACE
var _think_t := 0.0
var _wake_t := 0.0
var _hv_rx_ms := -100000          # guests: when the last "hv" packet arrived
var _cp_pos: Array = []           # checkpoint positions (Vector3)
var _streams: Dictionary = {}
var _sfx_man: Dictionary = {}
var _sfx_read := false
var _echo: AudioStreamPlayer3D = null
var _hook_player: AudioStreamPlayer = null
var _pale_mat: StandardMaterial3D = null
var _att_was := false
var _att_since := -100.0          # module clock when the local climber last became Attached
var _ok := false
# guest simulation (2.11) bookkeeping
var _gs_dives: Array = []         # durations of remote dive curves flown (s)
var _gs_visible := 0
# tests (harrier.flag)
var _test := false
var _test_loop := false
var _no_dive := false
var _skip_local := false
var _stale_local = null           # Vector3: the host's hit test sees the local player here (P4)
var _park_clock := -100.0         # R12: nothing is measured or targeted for 1 s after a test teleport
# v5.0 no-clip
static var _nc_script = null      # noclip.gd, loaded once at runtime (null: today's behaviour)
static var _nc_tried := false
var _nc_frame := -1
var _nc_on_cache := false
var _nc_sphere: PhysicsShapeQueryParameters3D = null
var _nc_f_note: Dictionary = {}   # sid -> clock until which an I3 refusal is not counted again
var _nc_test: Dictionary = {}     # noclip_test_dive: {"bi", "at", "until"}
var _nc_test_why := ""            # why the armed band has not started yet (the local player)
var _gs_nc_n := 0                 # guests: drawn harrier steps ray-checked (self-check)
var _gs_nc_x := 0                 # ... that went through rock
var _gs_nc_snaps := 0             # guests: declared snaps (a streamed teleport, or no clear glide)
var _tp := 0
var _tt := 0.0
var _tclock := 0.0
var _res_pass: Array = []
var _res_fail: Array = []
var _res_skip: Array = []
var _t_shriek := -1.0             # module clock at the last shriek aimed at me (tests)
var _dive_h = null
var _dive_feint := false
var _dive_who := ""
var _strikes_on_me := 0
var _strike_t := -1.0
var _strike_pos := Vector3.ZERO
var _strike_hp := 0.0
var _strike_lost := 0.0
var _last_skip := ""
var _aborts := 0
var _loop_dive := false
var _loop_strike := false
var _sv: Dictionary = {}          # survey
var _spot := Vector3.ZERO         # the drowned test foothold (floor point)
var _retreat := Vector3.ZERO
var _camp := Vector3.ZERO
var _camp_exp := -1
var _camp_cp := -1
var _slab_bad := 0
var _slab_frames := 0
var _phase_hp := 0.0
var _p_mark := 0


# ============================================================================ setup

func setup(m: Node) -> void:
	map = m
	name = "Feature_harriers"
	process_priority = 5
	Rift = load(DIR + "rift.gd")
	if Rift == null:
		push_warning("[HARRIER] rift.gd did not load: harriers disabled")
		return
	var L = m.get("L")
	if L is Dictionary:
		Rift.use_layout(L)
		for c in L.get("checkpoints", []):
			if c is Dictionary and c.has("pos"):
				_cp_pos.append(_v(c["pos"]))
	var C = load(DIR + "creatures.gd")
	if C != null:
		_kit = C.get("Kit")
	if _kit == null or not _kit.has_method("make_rig"):
		push_warning("[HARRIER] creatures.gd Kit.make_rig not found: harriers use their own fallback model")
		_kit = null
	_mon = _read_json(DIR + "ext/mon/manifest.json").get("harrier", {})
	for bi in BANDS.size():
		var b: Dictionary = BANDS[bi]
		for t in Rift.terraces():
			if float(t["bottom"]) < float(b["top"]) + 30.0 and float(t["y_top"]) > float(b["bottom"]) - 30.0:
				_band_terr[bi].append(t)
	var ok := true
	if m.has_method("register_events"):
		m.call("register_events", ["hdive_", "hstrike_"], _on_event, true)
		m.call("register_events", ["hfeint_"], _on_event, false)
	else:
		push_warning("[HARRIER] map has no register_events: harriers disabled")
		ok = false
	if m.has_method("register_stream"):
		m.call("register_stream", "hv", _send_hv, _recv_hv)
	if m.has_method("register_threats"):
		m.call("register_threats", self)
	_ok = ok
	var fl = m.call("dev_flag", "harrier.flag") if m.has_method("dev_flag") else null
	if fl != null:
		_test = true
		if CoopSync.has_method("use_test_files"):
			CoopSync.call("use_test_files")
		_test_loop = bool(CoopSync.get("_loopback"))
		if _test_loop:
			CoopSync.set("_loop_step", 7)       # the loopback's own soul/spectate script stays out
		_no_dive = true
		print("[HARRIER] test: harrier.flag read (loopback=%s)" % str(_test_loop))


func _ready() -> void:
	if not _ok:
		set_process(false)
		set_physics_process(false)
		return
	_pale_mat = StandardMaterial3D.new()
	_pale_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_pale_mat.albedo_color = PALE
	_pale_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_echo = AudioStreamPlayer3D.new()
	_echo.max_distance = 260.0
	_echo.unit_size = 14.0
	add_child(_echo)
	_hook_player = AudioStreamPlayer.new()
	add_child(_hook_player)
	var n := 0
	for bi in BANDS.size():
		var b: Dictionary = BANDS[bi]
		var ids: Array = b["ids"]
		for i in ids.size():
			var h := Harrier.new()
			h.setup(b, n, self)
			h.band_i = bi
			h.band_idx = i
			add_child(h)
			h.dived.connect(_on_dived)
			h.struck.connect(_on_struck)
			_hv.append(h)
			_band_hv[bi].append(h)
			n += 1
	var parts: Array = []
	for bi in BANDS.size():
		var tn: Array = []
		for t in _band_terr[bi]:
			tn.append(str(t["name"]))
		parts.append("%s %d (%s)" % [str(BANDS[bi]["name"]), _band_hv[bi].size(), ", ".join(tn) if not tn.is_empty() else "no terrace"])
	print("[HARRIER] %d harriers: %s; model %s" % [_hv.size(), "; ".join(parts), "fallback" if _hv.is_empty() or bool(_hv[0].fallback) else "harrier.glb"])
	add_to_group("zonda_nc")                     # the no-clip probe samples noclip_points()


func harriers() -> Array:
	return _hv


# ============================================================================ per frame

func _process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	_clock += delta
	_wake_t -= delta
	if _wake_t <= 0.0:
		_wake_t = 0.25
		_update_wake()
	if not CoopSync.map_is_authority() and Time.get_ticks_msec() - _hv_rx_ms > HV_STALE_MS:
		# the host sends no "hv" at all while every band sleeps (and the map drops an all-[] packet),
		# so remote_idle() never runs: the last-seen harriers settle here instead of hovering on
		for h in _hv:
			if not h.rdive and (h.st != Harrier.IDLE or h.visible):
				h.remote_stale()
	if CoopSync.map_is_authority():
		_think_t -= delta
		if _think_t <= 0.0:
			_think_t = THINK_S
			_nc_test_tick()
			for bi in BANDS.size():
				if _band_awake[bi]:
					if not _nc_test.is_empty() and int(_nc_test["bi"]) == bi and _clock < float(_nc_test["at"]):
						continue                     # noclip_test_dive moved the player: rock loads first
					_think_band(bi)
	if _test:
		_tclock += delta
		_test_step(delta)
	var us := Time.get_ticks_usec() - t0
	if us > 200 and CoopSync.has_method("perf_add"):
		CoopSync.call("perf_add", us)


func _physics_process(_delta: float) -> void:
	# the local climber's rope state, for the victim-side "just hooked" rule
	var c = Game.climber
	if is_instance_valid(c) and c.is_inside_tree():
		var att: bool = c.activeClimberState is ClimberState_Attached
		if att and not _att_was:
			_att_since = _clock
		_att_was = att
	if _test and _tp == 31 and not _hv.is_empty():
		# P-SLAB: every frame, no harrier of the drowned band is inside a slab
		for h in _band_hv[1]:
			if h.st != Harrier.IDLE:
				_slab_frames += 1
				if Rift.in_terrace(h.pos, 0.0):
					_slab_bad += 1
					if _slab_bad == 1:
						print("[HARRIER] P-SLAB %s INSIDE a slab at %s" % [h.id, str(h.pos)])


func _update_wake() -> void:
	# a band is awake while a living player is within it +- 80 m; the others idle (4 Hz, stream []).
	# Also caches each band's lowest living player (the harriers' altitude rule reads it per frame).
	var ys: Array = []
	for p in _players():
		ys.append((p as Node3D).global_position.y)
	for bi in BANDS.size():
		var b: Dictionary = BANDS[bi]
		var on := false
		var low = null
		for y in ys:
			if float(y) < float(b["top"]) + WAKE_PAD and float(y) > float(b["bottom"]) - WAKE_PAD:
				on = true
				if low == null or float(y) < float(low):
					low = float(y)
		_band_low[bi] = low
		if not CoopSync.map_is_authority():
			continue
		if on != _band_awake[bi]:
			_band_awake[bi] = on
			for h in _band_hv[bi]:
				if on:
					h.wake()
				else:
					h.sleep()
		elif not on:
			for h in _band_hv[bi]:
				if h.st != Harrier.IDLE or h.rdive:
					h.sleep()                  # left flying by the old host (this machine took over)


# ============================================================================ flight rules (pure)

func lowest_in_band(bi: int):
	# the lowest living player within the band +- 80 m (4 Hz cache), or null
	return _band_low[bi]


func snap_alt(bi: int, w: float, player_y: float) -> float:
	# clamp to the band, then out of every slab [bottom - 8, y_top + 8], on the lowest player's side
	var b: Dictionary = BANDS[bi]
	w = clampf(w, float(b["bottom"]) + 6.0, float(b["top"]) - 6.0)
	for t in _band_terr[bi]:
		var yt: float = t["y_top"]
		var yb: float = t["bottom"]
		if w > yb - SLAB_PAD and w < yt + SLAB_PAD:
			w = yt + SLAB_PAD if player_y > (yt + yb) * 0.5 else yb - SLAB_PAD
	return w


func near_slab(bi: int, y: float) -> Dictionary:
	# the terrace whose slab is within SLAB_NEAR of altitude y (y outside the slab), or {}
	for t in _band_terr[bi]:
		var yt: float = t["y_top"]
		var yb: float = t["bottom"]
		if y < yt + SLAB_NEAR and y > yb - SLAB_NEAR:
			return t
	return {}


func circle_of(bi: int, y: float) -> Array:
	# [centre (Vector2 x, z), radius]: the 0.55 R ring, or near a slab the 0.25 R ring round its open point
	var t := near_slab(bi, y)
	if not t.is_empty():
		var op: Vector3 = Rift.open_point(t)
		return [Vector2(op.x, op.z), SMALL_K * float(t["R"])]
	return [Rift.center(y), CIRCLE_K * float(Rift.radius(y))]


func circle_point(bi: int, y: float, theta: float) -> Vector3:
	var cr: Array = circle_of(bi, y)
	var c: Vector2 = cr[0]
	var r: float = cr[1]
	return Vector3(c.x + cos(theta) * r, y, c.y + sin(theta) * r)


func crossing(bi: int, y_from: float, y_to: float) -> Dictionary:
	# the terrace whose slab lies between two altitudes (the harrier must cross at its open point), or {}
	for t in _band_terr[bi]:
		var mid: float = (float(t["y_top"]) + float(t["bottom"])) * 0.5
		if (y_from > mid) != (y_to > mid):
			return t
	return {}


# ============================================================================ targeting (authority)

func _players() -> Array:
	var out: Array = []
	for p in CoopSync.alive_player_nodes():
		if is_instance_valid(p) and (p as Node).is_inside_tree():
			out.append(p)
	return out


func _sid_of(p: Node) -> String:
	if p == Game.climber:
		return my_sid()
	var pid = p.get("peer_id")
	if pid == null:
		return ""
	if CoopSync.has_method("sid"):
		return str(CoopSync.call("sid", pid))
	return str(pid)


func my_sid() -> String:
	if CoopSync.has_method("my_sid"):
		return str(CoopSync.call("my_sid"))
	var id := CoopSync.my_id()
	return str(id) if id != 0 else "local"


func _is_me(v) -> bool:
	if CoopSync.has_method("is_me"):
		return bool(CoopSync.call("is_me", v))
	return str(v) == my_sid()


func _space() -> PhysicsDirectSpaceState3D:
	if map is Node3D and (map as Node3D).is_inside_tree():
		var w := (map as Node3D).get_world_3d()
		if w != null:
			return w.direct_space_state
	return null


func _clear(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
	return space.intersect_ray(PhysicsRayQueryParameters3D.create(a, b, 1)).is_empty()


func _segment_clear_of_slabs(a: Vector3, b: Vector3) -> bool:
	var n := maxi(1, int(ceil(a.distance_to(b) / 10.0)))
	for i in n + 1:
		if Rift.in_terrace(a.lerp(b, float(i) / float(n)), 2.0):
			return false
	return true


func stoop_point(p: Vector3) -> Vector3:
	return p + Vector3.UP * STOOP_UP + Rift.void_dir(p) * STOOP_OUT


func _hang_point(space: PhysicsDirectSpaceState3D, pp: Vector3, sid: String = ""):
	# the hang point F over a player at pp (Vector3), or null. Guard off: today's rule (F 18 m up and
	# 3 m out, out of every slab, a clear ray from the player). Guard on (I3): F must also hold a clear
	# 2.4 m sphere; it is pushed voidward 1 m at a time up to 8 m, else the player is not a target.
	var F := stoop_point(pp)
	var old_ok: bool = not Rift.in_terrace(F, 4.0) and _clear(space, pp + Vector3.UP, F)
	if not nc_on():
		return F if old_ok else null
	var F2 = _nc_hang(space, pp)
	if F2 == null and old_ok and sid != "" and _clock >= float(_nc_f_note.get(sid, -1.0)):
		_nc_f_note[sid] = _clock + 30.0
		nc_note("nc_aborts")
		print("[HARRIER] %s is not a target: rock within %.1f m of every hang point %.0f-%.0f m out" % [sid, HANG_R, STOOP_OUT, HANG_OUT_MAX])
	return F2


func _nc_hang(space: PhysicsDirectSpaceState3D, pp: Vector3):
	var vd: Vector3 = Rift.void_dir(pp)
	var k := STOOP_OUT
	while k <= HANG_OUT_MAX + 0.01:
		var F: Vector3 = pp + Vector3.UP * STOOP_UP + vd * k
		if not Rift.in_terrace(F, 4.0) and _clear(space, pp + Vector3.UP, F) and _sphere_clear(space, F, HANG_R):
			return F
		k += 1.0
	return null


func _sphere_clear(space: PhysicsDirectSpaceState3D, p: Vector3, r: float) -> bool:
	# F is in open air (a clear ray reached it), so the sphere starts clear of the hollow cave trimesh
	if space == null:
		return true
	if _nc_sphere == null:
		_nc_sphere = PhysicsShapeQueryParameters3D.new()
		_nc_sphere.shape = SphereShape3D.new()
		_nc_sphere.collision_mask = 1
		_nc_sphere.collide_with_areas = false
		_nc_sphere.collide_with_bodies = true
	(_nc_sphere.shape as SphereShape3D).radius = r
	_nc_sphere.transform = Transform3D(Basis.IDENTITY, p)
	return space.intersect_shape(_nc_sphere, 1).is_empty()


# ---------------------------------------------------------------- v5.0 no-clip helpers (runtime noclip.gd)

static func _nc():
	if not _nc_tried:
		_nc_tried = true
		if ResourceLoader.exists(NC_PATH):
			_nc_script = load(NC_PATH)
		if _nc_script == null:
			push_warning("[CLIP] noclip.gd missing: creatures move as before")
	return _nc_script


func nc_script():
	return _nc()


func nc_on() -> bool:
	# Rule K: every no-clip behaviour change runs only while this is true (cached per physics frame)
	var f := Engine.get_physics_frames()
	if f != _nc_frame:
		_nc_frame = f
		var NC = _nc()
		_nc_on_cache = NC != null and bool(NC.call("is_enabled"))
	return _nc_on_cache


func nc_note(key: String, n: int = 1) -> void:
	# fairness and guard counters: both Rule K branches call this; noclip.gd counts only while measuring
	var NC = _nc()
	if NC != null:
		NC.call("note", "harrier", key, n)


func nc_solid(p: Vector3, r: float = 6.0) -> bool:
	var NC = _nc()
	if NC == null:
		return true
	return bool(NC.call("solid_at", p, r))


func nc_ray(space, a: Vector3, b: Vector3) -> Dictionary:
	# {} when clear, else {"position", "normal" (faces a), "d"}: the helper's both-sided ray
	var NC = _nc()
	if NC != null:
		return NC.call("ray", space, a, b)
	if space == null:
		return {}
	var q := PhysicsRayQueryParameters3D.create(a, b, 1)
	q.hit_back_faces = true
	var h: Dictionary = (space as PhysicsDirectSpaceState3D).intersect_ray(q)
	if h.is_empty():
		return {}
	var n: Vector3 = h["normal"]
	if n.dot(b - a) > 0.0:
		n = -n
	return {"position": h["position"], "normal": n, "d": a.distance_to(h["position"])}


func _near_camp(p: Vector3) -> bool:
	for q in _cp_pos:
		if (q as Vector3).distance_to(p) <= CAMP_R:
			return true
	return false


func _standing(p: Node) -> bool:
	if p == Game.climber:
		return p.is_on_floor() and not (p.activeClimberState is ClimberState_Attached)
	var og = p.get("on_ground")                 # remote_player.on_ground (B3); older builds: assume standing
	return (bool(og) if og != null else true) and not bool(p.get("attached"))


func _enclosed(p: Vector3) -> bool:
	if map != null and map.has_method("enclosed"):
		return bool(map.call("enclosed", p))
	return false


func _think_band(bi: int) -> void:
	if _no_dive or _clock < _grace_until or _clock < float(_band_gap_until[bi]):
		return
	if _test and _clock - _park_clock < 1.0:
		return                                   # a test teleport: collision and LOD catch up first
	for h in _band_hv[bi]:
		if h.busy():
			return
	var space := _space()
	if space == null:
		return
	var cache := {}                              # player -> [ok, exposed, F] (rays shared by harriers)
	var armed := not _nc_test.is_empty() and int(_nc_test["bi"]) == bi
	if armed:
		_nc_test_why = "no harrier circling and ready"
	for h in _band_hv[bi]:
		if h.st != Harrier.CIRCLE or _clock < h.ready_at:
			continue
		var best = null
		var best_exp := -1
		var best_d := 1e9
		for p in _players():
			if _skip_local and p == Game.climber:
				continue
			var mine: bool = armed and p == Game.climber
			var pp: Vector3 = (p as Node3D).global_position
			var b: Dictionary = BANDS[bi]
			if pp.y > float(b["top"]) or pp.y < float(b["bottom"]):
				if mine:
					_nc_test_why = "out of the band"
				continue
			var d := pp.distance_to(h.pos)
			if d > TARGET_R:
				if mine:
					_nc_test_why = "%s %.0f m away" % [h.id, d]
				continue
			var sid := _sid_of(p)
			if sid == "" or _clock < float(_personal_cd.get(sid, -1.0)):
				continue
			if p == Game.climber and Time.get_ticks_msec() < int(p.get("_coop_invuln_until_ms") if p.get("_coop_invuln_until_ms") != null else 0):
				continue
			if _near_camp(pp) or not _standing(p):
				if mine:
					_nc_test_why = "near a camp" if _near_camp(pp) else "not standing"
				continue
			if not cache.has(p):
				var ent: Array = [false, 0, Vector3.ZERO]
				if not _enclosed(pp):
					var ex: int = Rift.edge_exposed(space, pp)
					if ex >= 1:
						var F = _hang_point(space, pp, sid)
						if F is Vector3:
							ent = [true, ex, F]
						elif mine:
							_nc_test_why = "no hang point"
					elif mine:
						_nc_test_why = "not exposed"
				elif mine:
					_nc_test_why = "enclosed"
				cache[p] = ent
			var e: Array = cache[p]
			if not bool(e[0]):
				continue
			var F2: Vector3 = e[2]
			if not _clear(space, h.pos, F2) or not _segment_clear_of_slabs(h.pos, F2):
				if mine:
					_nc_test_why = "%s: no clear approach line" % h.id
				continue
			var ex2: int = e[1]
			if ex2 > best_exp or (ex2 == best_exp and d < best_d):
				best = [p, sid, F2, ex2]
				best_exp = ex2
				best_d = d
		if best != null:
			h.start_approach(best[0], str(best[1]), best[2])
			print("[HARRIER] %s APPROACH -> %s, exposed %d, %.0f m" % [h.id, str(best[1]), int(best[3]), best_d])
			return


func band_feint(bi: int) -> bool:
	# the first dive per band per run is a feint (until hfeint_<band> is stored)
	var bn := str(BANDS[bi]["name"])
	return not _feinted.has(bn) and not _feint_pending.has(bn)


func dive_ended(h, bi: int, feint: bool, aborted: bool) -> void:
	# authority: the approach or dive is over (impact, feint, abort or give-up): cooldowns
	h.ready_at = _clock + HARRIER_CD + randf_range(-HARRIER_CD_RAND, HARRIER_CD_RAND)
	var solo: bool = CoopSync.alive_player_count() <= 1
	_band_gap_until[bi] = _clock + (BAND_GAP_SOLO if solo else BAND_GAP)
	var bn := str(BANDS[bi]["name"])
	if feint and aborted:
		_feint_pending.erase(bn)


func target_state(h) -> String:
	# authority, at the commit: "" = still a fair target, else why it aborts
	var p = h.tgt
	if not is_instance_valid(p) or not (p as Node).is_inside_tree():
		return "gone"
	if not _players().has(p):
		return "down"
	var pp: Vector3 = (p as Node3D).global_position
	var space := _space()
	if space != null and Rift.edge_exposed(space, pp) == 0:
		return "not exposed"
	if _enclosed(pp):
		return "enclosed"
	return ""


func hit_test(h) -> void:
	# authority, at IMPACT: everyone within 2.2 m (flat) of the committed point, dy -1.2..+2.5
	var hits := 0
	for p in _players():
		var pp: Vector3 = (p as Node3D).global_position
		if p == Game.climber and _stale_local is Vector3:
			pp = _stale_local                    # P4: the host's view is late (as it is for a guest)
		var d: Vector3 = pp - h.aim
		if Vector2(d.x, d.z).length() <= HIT_R and d.y >= HIT_DY_LO and d.y <= HIT_DY_HI:
			var sid := _sid_of(p)
			if sid == "":
				continue
			var vd: Vector3 = Rift.void_dir(pp)
			h.struck.emit(sid, Vector2(vd.x, vd.z), pp, h.id)
			hits += 1
			nc_note("hits")
	print("[HARRIER] %s IMPACT t=%.2f hits=%d" % [h.id, h.dive_t, hits])


func on_feint(h) -> void:
	# authority: the teaching feint pulled up; stored so the band never feints again this run
	var bn := str(BANDS[h.band_i]["name"])
	print("[HARRIER] %s FEINT: pulled up %.0f m short" % [h.id, FEINT_SHORT])
	_feint_pending.erase(bn)
	CoopSync.map_event("hfeint_" + bn, {}, true)


func _on_dived(who: String, from: Vector3, aim: Vector3, feint: bool, id: String) -> void:
	# authority, at the shriek
	_personal_cd[who] = _clock + PERSONAL_CD
	if feint:
		for h in _hv:
			if h.id == id:
				_feint_pending[str(BANDS[h.band_i]["name"])] = true
	if _test and _is_me(who) or (_test and _test_loop):
		_t_shriek = _clock
		for h in _hv:
			if h.id == id:
				_dive_h = h
		_dive_feint = feint
		_dive_who = who
	CoopSync.map_event("hdive_" + id, {"who": who, "from": [from.x, from.y, from.z], "aim": [aim.x, aim.y, aim.z], "feint": feint}, false)


func _on_struck(who: String, dir: Vector2, at: Vector3, id: String) -> void:
	var d := {"who": who, "dir": [dir.x, dir.y], "at": [at.x, at.y, at.z]}
	for h in _hv:
		if h.id == id:
			d["aim"] = [h.aim.x, h.aim.y, h.aim.z]   # the committed point: the victim judges the dodge on it
	CoopSync.map_event("hstrike_" + id, d, false)


# ============================================================================ events

func _on_event(key: String, data: Dictionary, replay: bool) -> void:
	if key.begins_with("hfeint_"):
		var bn := key.substr(7)
		_feinted[bn] = true
		_feint_pending.erase(bn)
		if not replay:
			var n := 0
			for k in CoopSync.map_events().keys():
				if str(k).begins_with("hfeint_"):
					n += 1
			if n <= 1:
				CoopSync.show_banner(FEINT_TEXT, 6.0)
		return
	var hid := key.substr(key.find("_") + 1)
	var h = null
	for x in _hv:
		if x.id == hid:
			h = x
	if key.begins_with("hdive_"):
		var who := str(data.get("who", ""))
		if _test and _test_loop and who == "777":
			_loop_dive = true
			print("[HARRIER] loopback %s who=%s feint=%s" % [key, who, str(data.get("feint", false))])
		if h != null and not CoopSync.map_is_authority():
			h.remote_dive(_v(data.get("from", [])), _v(data.get("aim", [])), bool(data.get("feint", false)))
	elif key.begins_with("hstrike_"):
		var who2 = data.get("who", "")
		if _test and _test_loop and str(who2) == "777":
			_loop_strike = true
			print("[HARRIER] loopback %s who=%s at=%s" % [key, str(who2), str(data.get("at", []))])
		if _is_me(who2):
			_victim_strike(key, data)


func _victim_strike(key: String, data: Dictionary) -> void:
	# THIS player's own machine is the only judge of the counterplay
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var why := ""
	var me: Vector3 = c.global_position
	var at := _v(data.get("at", []))
	var space := _space()
	if c.get("coop_spectating"):
		why = "spectating"
	elif Time.get_ticks_msec() < int(c.get("_coop_invuln_until_ms") if c.get("_coop_invuln_until_ms") != null else 0):
		why = "invulnerable"
	elif space != null and Rift.edge_exposed(space, me) == 0:
		why = "not exposed"                      # stepped back from the edge (checked before the distance
	elif c.activeClimberState is ClimberState_Attached and _clock - _att_since < JUST_HOOKED_S:
		why = "just hooked"                      # so the log names the counterplay that saved them)
	elif data.has("aim") and _dodged(me, _v(data["aim"])):
		why = "dodged"                           # out of the 2.2 m circle on THIS screen (the host's view is late)
	elif me.distance_to(at) > STRIKE_AT_R:
		why = "far from the strike"
	if why != "":
		_last_skip = why
		print("[HARRIER] strike skipped: %s (%s)" % [why, key])
		return
	var hooked: bool = c.activeClimberState is ClimberState_Attached
	var hp0: float = c.health
	c.take_damage(STRIKE_DMG_HOOKED if hooked else STRIKE_DMG)
	var dv = data.get("dir", [])
	var dir := Vector3.ZERO
	if (dv is Array or dv is PackedFloat32Array) and dv.size() >= 2:
		dir = Vector3(float(dv[0]), 0.0, float(dv[1]))
	if dir.length() > 0.01:
		c.additional_velocity_next_frame += dir.normalized() * STRIKE_PUSH
	if hooked:
		var s := _game_stream(SFX_HOOKED)
		if s != null and _hook_player != null:
			_hook_player.stream = s
			_hook_player.volume_db = -4.0
			_hook_player.bus = _bus()
			_hook_player.play()
	if Game.audio:
		Game.audio.play_player_was_bit()
	_strikes_on_me += 1
	_strike_t = _clock
	_strike_pos = me
	_strike_hp = hp0
	_strike_lost = hp0 - float(c.health)
	print("[HARRIER] struck by %s: hooked=%s hp %.0f -> %.0f" % [key.substr(8), str(hooked), hp0, float(c.health)])


func _dodged(me: Vector3, aim: Vector3) -> bool:
	# the host's hit test (2.2 m flat, dy -1.2..+2.5 of the committed aim) redone on the victim's own
	# screen, with DODGE_PAD of slack: a dodge made in the host's last view of this player still counts
	var d := me - aim
	return Vector2(d.x, d.z).length() > HIT_R + DODGE_PAD or d.y < HIT_DY_LO - DODGE_PAD or d.y > HIT_DY_HI + DODGE_PAD


# ============================================================================ stream (cx "hv")

func _send_hv():
	var out: Array = []
	var any := false
	var ps: Array = []
	for p in _players():
		ps.append((p as Node3D).global_position)
	for h in _hv:
		var near := false
		if h.st != Harrier.IDLE:
			for q in ps:
				if (q as Vector3).distance_to(h.pos) < STREAM_FAR:
					near = true
					break
		if near:
			out.append(h.state_packet())
			any = true
		else:
			out.append([])
	return out if any else null


func _recv_hv(a) -> void:
	if not (a is Array):
		return
	_hv_rx_ms = Time.get_ticks_msec()
	for i in mini((a as Array).size(), _hv.size()):
		var e = a[i]
		if (e is Array or e is PackedFloat32Array or e is PackedFloat64Array) and e.size() >= 5:
			_hv[i].remote_state(e)
		else:
			_hv[i].remote_idle()


func threat_positions() -> Array:
	var out: Array = []
	for h in _hv:
		out.append_array(h.threat_positions())
	return out


# ============================================================================ hooks from the map

func on_session_ended() -> void:
	for h in _hv:
		h.drop_dive()


func on_exit() -> void:
	_hv.clear()


func guestsim_report() -> Array:
	var out: Array = []
	if _gs_dives.is_empty():
		out.append("SKIP no hdive_ in the recording")
	else:
		var d: float = _gs_dives[0]
		if absf(d - IMPACT_S) <= 0.05:
			out.append("PASS hdive flew the 1.5 s curve (%.2f s, %d dives)" % [d, _gs_dives.size()])
		else:
			out.append("FAIL hdive curve took %.2f s" % d)
	if _gs_visible <= 0:
		out.append("SKIP no hv packet in the recording")
	else:
		var n := 0
		for h in _hv:
			if h.seen:
				n += 1
		out.append("PASS harriers visible n=%d" % n)
		# v5.0 no-clip, guest side: every drawn step of a shown harrier within 150 m, ray-tested where
		# the rock is loaded (a declared snap is a teleport, never a step)
		if _gs_nc_n <= 0:
			out.append("SKIP harrier guest no-clip (the guard is off, or no loaded rock near a shown harrier)")
		elif _gs_nc_x == 0:
			out.append("PASS harrier guest no-clip: %d steps ray-checked, 0 through rock (%d declared snaps)" % [_gs_nc_n, _gs_nc_snaps])
		else:
			out.append("FAIL harrier guest no-clip: %d of %d steps went through rock" % [_gs_nc_x, _gs_nc_n])
	return out


# ============================================================================ no-clip probe API (v5.0)

func noclip_points() -> Array:
	# spec 5.2: one entry per harrier in the tree (view "host" on the authority, else "guest")
	var out: Array = []
	var view := "host" if CoopSync.map_is_authority() else "guest"
	for h in _hv:
		if is_instance_valid(h) and h.is_inside_tree() and h.body != null:
			out.append(h.nc_points(view))
	return out


func _band_of(y: float) -> int:
	for bi in BANDS.size():
		if y < float(BANDS[bi]["top"]) and y > float(BANDS[bi]["bottom"]):
			return bi
	return -1


func _nc_spot_good(space: PhysicsDirectSpaceState3D, pc: Vector3) -> bool:
	# a standing spot (capsule centre pc) a harrier may dive at: exposed, open, not a camp, and a hang
	# point by the guard-independent v4.9.1 rule (_hang_point's guard-off branch: F out of every slab,
	# a clear ray from the player). The same in both launches, so baseline and host pick the same spot,
	# and never pre-filtered by I3's clear sphere: at a wall-side ledge the guarded launch's shrieks
	# and hits show what I3 to I5 cost (goals 2d and 5)
	if Rift.edge_exposed(space, pc) < 1 or _enclosed(pc) or _near_camp(pc):
		return false
	var F := stoop_point(pc)
	return not Rift.in_terrace(F, 4.0) and _clear(space, pc + Vector3.UP, F)


func _nc_spot_cands(bi: int) -> Array:
	# band stations ranked from data alone (the rock far from the player has no collision): the known
	# validated spot first, then the ledges that stick out farthest from the rift wall, footholds first
	var b: Dictionary = BANDS[bi]
	var rows: Array = []
	var L = map.get("L") if map != null else null
	if not (L is Dictionary):
		return []
	for s in L.get("stations", []):
		if not (s is Dictionary):
			continue
		var kind := str(s.get("kind", ""))
		if not (kind in ["foothold", "shelf", "hard", "gantry"]):
			continue
		var p := _v(s.get("pos", []))
		if p.y > float(b["top"]) - 25.0 or p.y < float(b["bottom"]) + 10.0:
			continue
		var camp := false
		for q in _cp_pos:
			if (q as Vector3).distance_to(p) <= CAMP_R + 5.0:
				camp = true
		if camp or Rift.in_terrace(p, 2.0) or Rift.in_terrace(stoop_point(p), 4.0):
			continue
		var c: Vector2 = Rift.center(p.y)
		var out_of_wall: float = float(Rift.radius(p.y)) - Vector2(p.x - c.x, p.z - c.y).length()
		var sc := out_of_wall + (5.0 if kind == "foothold" else 0.0)
		for k in NC_KNOWN_SPOTS:
			if int(k[0]) == bi and (k[1] as Vector3).distance_to(p) < 0.5:
				sc += 1000.0
		rows.append([sc, p])
	rows.sort_custom(_nc_rank_cmp)
	var out: Array = []
	for r in rows:
		out.append(r[1])
	return out


func _nc_rank_cmp(x: Array, y: Array) -> bool:
	# score descending, then position (a fixed order, the same in every launch)
	if float(x[0]) != float(y[0]):
		return float(x[0]) > float(y[0])
	var a: Vector3 = x[1]
	var b: Vector3 = y[1]
	if a.x != b.x:
		return a.x < b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z


func _nc_spot_out(bi: int, f: Vector3, how: String) -> Array:
	# [where to park (the capsule centre, 1 m over the floor point), where to look: out over the void,
	# 48 deg up, so the approach, the hang and the stoop are all in view]
	var pc := f + Vector3.UP * 1.0
	var look: Vector3 = pc + Rift.void_dir(pc) * 16.0 + Vector3.UP * 18.0
	print("[HARRIER] noclip test spot band %s: %s (%s)" % [str(BANDS[bi]["name"]), str(f), how])
	return [pc, look]


func noclip_test_spot(i: int) -> Array:
	# [park position, look point] of an exposed edge in band i, or []. Checked with rays where the rock
	# is loaded now; otherwise the best-ranked station from data (noclip_test_dive re-checks it after
	# the park and moves the player to the best spot within 110 m if it is not one). "Good" is the
	# guard-independent _nc_spot_good, so a spot the guard (I3) refuses is still tested
	if not _ok or Rift == null or map == null or i < 0 or i >= BANDS.size():
		return []
	var cands := _nc_spot_cands(i)
	if cands.is_empty():
		print("[HARRIER] noclip test spot band %s: no candidate station" % str(BANDS[i]["name"]))
		return []
	var space := _space()
	if space != null:
		for s in cands:
			var sp: Vector3 = s
			if not nc_solid(sp, 12.0):
				continue
			var fw = _walk_floor(space, sp + Vector3.UP * 2.0, sp + Vector3.DOWN * 3.0)
			if fw == null or absf((fw as Vector3).y - sp.y) > 1.0:
				continue
			if _nc_spot_good(space, (fw as Vector3) + Vector3.UP * 1.0):
				return _nc_spot_out(i, fw, "rays")
	return _nc_spot_out(i, cands[0], "data")


func _nc_spot_near(space: PhysicsDirectSpaceState3D, bi: int, pp: Vector3):
	# the most exposed targetable floor point under a band station within 110 m of pp (rock loaded)
	var best = null
	var best_sc := -1e9
	for s in _band_stations(bi):
		var sp: Vector3 = s
		if sp.distance_to(pp) > TARGET_R or not nc_solid(sp, 8.0):
			continue
		var fw = _walk_floor(space, sp + Vector3.UP * 2.0, sp + Vector3.DOWN * 3.0)
		if fw == null or absf((fw as Vector3).y - sp.y) > 1.0:
			continue
		var pc: Vector3 = (fw as Vector3) + Vector3.UP * 1.0
		if not _nc_spot_good(space, pc):
			continue
		var sc := float(Rift.edge_exposed(space, pc)) * 1000.0 - sp.distance_to(pp)
		if sc > best_sc:
			best_sc = sc
			best = fw
	return best


func noclip_test_dive(p: Node3D) -> bool:
	# the probe's P8: a real dive of p's band at p, through the natural targeting gate (so the baseline
	# launch is never credited with a dive the game would not start). Host only. If p does not stand on
	# a targetable spot, the player is moved to the best one within 110 m first (a scripted park). The
	# band's cooldowns stay clear for 20 s, its first-dive feint is marked done in this module only (no
	# hfeint_ event), and a harrier out of range is put on its circle at the spot's bearing (scripted).
	if not _ok or Rift == null or not CoopSync.map_is_authority() or not is_instance_valid(p) or not p.is_inside_tree():
		return false
	var pp: Vector3 = p.global_position
	var bi := _band_of(pp.y)
	if bi < 0:
		print("[HARRIER] noclip test dive: %s is in no harrier band" % str(pp))
		return false
	var space := _space()
	if space == null:
		return false
	var moved := false
	if not _nc_spot_good(space, pp):
		var f = _nc_spot_near(space, bi, pp)
		if f == null:
			print("[HARRIER] noclip test dive: no targetable spot within %.0f m of %s" % [TARGET_R, str(pp)])
			return false
		pp = (f as Vector3) + Vector3.UP * 1.0
		_park(pp)
		moved = true
		print("[HARRIER] noclip test dive: moved to %s (exposed %d)" % [str(f), Rift.edge_exposed(space, pp)])
	if not _band_awake[bi]:
		_band_awake[bi] = true
		for h0 in _band_hv[bi]:
			h0.wake()
	_feinted[str(BANDS[bi]["name"])] = true
	var near = null
	var nd := 1e9
	for h1 in _band_hv[bi]:
		if h1.st == Harrier.CIRCLE and h1.pos.distance_to(pp) < nd:
			nd = h1.pos.distance_to(pp)
			near = h1
	if near != null and nd > TARGET_R - 20.0:
		var w := snap_alt(bi, pp.y + ALT_ABOVE, pp.y)
		var cr: Array = circle_of(bi, w)
		var c: Vector2 = cr[0]
		var q := circle_point(bi, w, atan2(pp.z - c.y, pp.x - c.x))
		print("[HARRIER] noclip test dive: %s put on its circle at the spot's bearing (%.0f m -> %.0f m)" % [near.id, nd, q.distance_to(pp)])
		near.nc_test_place(q)
	_nc_test = {"bi": bi, "at": _clock + (1.2 if moved else 0.0), "until": _clock + NC_TEST_S}
	_nc_test_why = ""
	_nc_test_ready(bi)
	print("[HARRIER] noclip test dive armed: band %s, spot %s" % [str(BANDS[bi]["name"]), str(pp)])
	return true


func _nc_test_ready(bi: int) -> void:
	for h in _band_hv[bi]:
		h.debug_ready()
	_band_gap_until[bi] = 0.0
	_grace_until = 0.0
	_personal_cd.clear()


func _nc_test_tick() -> void:
	# while noclip_test_dive's band is armed: its cooldowns stay clear until a harrier is on its way
	if _nc_test.is_empty():
		return
	var bi := int(_nc_test["bi"])
	for h in _band_hv[bi]:
		if h.st == Harrier.APPROACH or h.st == Harrier.DIVE:
			print("[HARRIER] noclip test dive: %s is on its way" % h.id)
			_nc_test = {}
			return
	if _clock > float(_nc_test["until"]):
		print("[HARRIER] noclip test dive: no approach in %.0f s (%s)" % [NC_TEST_S, _nc_test_why if _nc_test_why != "" else "band asleep"])
		_nc_test = {}
		return
	_nc_test_ready(bi)


# ============================================================================ sound helpers

func _bus() -> StringName:
	if AudioServer.get_bus_index("ZondaCave") >= 0:
		return &"ZondaCave"
	if AudioServer.get_bus_index("MainBus") >= 0:
		return &"MainBus"
	return &"Master"


func _game_stream(path: String) -> AudioStream:
	if _streams.has(path):
		return _streams[path]
	var s: AudioStream = null
	if ResourceLoader.exists(path):
		s = load(path) as AudioStream
	_streams[path] = s
	return s


func oneshot(kind: String) -> Array:
	# [AudioStream (a randomizer over the manifest's files) or null, mean manifest db]
	var key := "os:" + kind
	if _streams.has(key):
		return _streams[key]
	if not _sfx_read:
		_sfx_read = true
		_sfx_man = _read_json(DIR + "sfx/manifest.json")
	var out: Array = [null, 0.0]
	var ones = _sfx_man.get("oneshots", {})
	if ones is Dictionary and (ones as Dictionary).get(kind, []) is Array:
		var r := AudioStreamRandomizer.new()
		r.random_pitch = 1.0
		var n := 0
		var db := 0.0
		for e in (ones as Dictionary)[kind]:
			if not (e is Dictionary):
				continue
			var f := str(e.get("file", ""))
			var s: AudioStream = null
			if f.begins_with("res://"):
				s = _game_stream(f)
			elif FileAccess.file_exists(DIR + "sfx/" + f):
				var bytes := FileAccess.get_file_as_bytes(DIR + "sfx/" + f)
				if not bytes.is_empty():
					s = AudioStreamOggVorbis.load_from_buffer(bytes)
			if s == null:
				continue
			r.add_stream(-1, s)
			db += float(e.get("db", 0.0))
			n += 1
		if n > 0:
			out = [r, db / float(n)]
	_streams[key] = out
	return out


func play_at(p: AudioStreamPlayer3D, kind: String, db: float, pitch: float) -> void:
	if p == null or not p.is_inside_tree():
		return
	var os := oneshot(kind)
	if os[0] == null:
		return
	p.stream = os[0]
	p.volume_db = float(os[1]) + db
	p.pitch_scale = pitch
	p.bus = _bus()
	p.play()


func echo(from_pos: Vector3, pitch: float) -> void:
	# the shriek's echo off the far wall: from the rift's axis at that depth
	if _echo == null or not _echo.is_inside_tree():
		return
	var c: Vector2 = Rift.center(from_pos.y)
	_echo.global_position = Vector3(c.x, from_pos.y, c.y)
	play_at(_echo, "harrier_shriek", -9.0, pitch * 0.96)


func listener() -> Vector3:
	var vp := get_viewport()
	if vp != null:
		var cam := vp.get_camera_3d()
		if cam != null and cam.is_inside_tree():
			return cam.global_position
	return Vector3(1e9, 1e9, 1e9)


# ============================================================================ model helpers

func make_model(h) -> void:
	# Kit.make_rig("harrier", 1.3, pale) (creatures.gd, at runtime), repainted unshaded pale and
	# centred on the flying body; its own two wing quads and the game's centipede head otherwise
	var holder := Node3D.new()
	holder.rotation.x = deg_to_rad(-80.0)       # the Bat is modelled upright: glide head-first
	h.model = holder
	h.pose.add_child(holder)
	var rig = null
	if _kit != null:
		rig = _kit.call("make_rig", "harrier", 1.3, PALE)
	if rig != null and not bool(rig.get("fallback")):
		var root: Node3D = rig.get("root")
		holder.add_child(root)
		var cm = _mon.get("center_m", null)
		if cm is Array and (cm as Array).size() >= 3 and root.get_child_count() > 0:
			(root.get_child(0) as Node3D).position = -Vector3(float(cm[0]), float(cm[1]), float(cm[2]))
		h.rig = rig
		h.fallback = false
	else:
		if rig != null:
			var r0: Node3D = rig.get("root")
			if r0 != null:
				r0.free()
		h.fallback = true
		_fallback_model(h, holder)
	for g in holder.find_children("*", "GeometryInstance3D", true, false):
		var gi := g as GeometryInstance3D
		gi.material_override = _pale_mat
		gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		gi.visibility_range_end = 260.0          # they wheel far out over the rift
		gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED


func _fallback_model(h, holder: Node3D) -> void:
	# upright like the Bat (holder pitches it head-first): a head and two hinged wing quads, 4 m across
	var ps: PackedScene = null
	if ResourceLoader.exists(HEAD):
		ps = load(HEAD) as PackedScene
	if ps != null:
		var head := ps.instantiate() as Node3D
		if head != null:
			var w := Node3D.new()
			w.add_child(head)
			var box := _aabb(w)
			var s := 1.1 / maxf(box.size.y, 0.01)
			w.scale = Vector3.ONE * s
			var ctr := box.get_center()
			w.position = -ctr * s + Vector3(0, 0.4, 0)
			holder.add_child(w)
	else:
		var cap := CapsuleMesh.new()
		cap.radius = 0.35
		cap.height = 1.6
		var body := MeshInstance3D.new()
		body.mesh = cap
		holder.add_child(body)
	var q := QuadMesh.new()
	q.size = Vector2(1.9, 1.0)
	for side in [1.0, -1.0]:
		var hinge := Node3D.new()
		hinge.position = Vector3(0.15 * side, 0.3, 0.0)
		holder.add_child(hinge)
		var wing := MeshInstance3D.new()
		wing.mesh = q
		wing.position = Vector3(0.95 * side, 0.0, 0.25)
		wing.rotation.y = PI * 0.5 * (1.0 - side)
		hinge.add_child(wing)
		h.wings.append(hinge)


func _aabb(root: Node3D) -> AABB:
	var box := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var m := n as MeshInstance3D
		if m.mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var node: Node = m
		while node != null and node != root:
			if node is Node3D:
				xf = (node as Node3D).transform * xf
			node = node.get_parent()
		var b: AABB = xf * m.mesh.get_aabb()
		box = b if first else box.merge(b)
		first = false
	return box


static func _v(a) -> Vector3:
	if a is Vector3:
		return a
	if (a is Array or a is PackedFloat32Array or a is PackedFloat64Array) and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	return d if d is Dictionary else {}


# ============================================================================ the harrier

class Harrier extends Node3D:
	signal dived(who: String, from: Vector3, aim: Vector3, feint: bool, id: String)
	signal struck(who: String, dir: Vector2, at: Vector3, id: String)

	const CIRCLE := 0
	const APPROACH := 1
	const DIVE := 2
	const RAKE := 3
	const IDLE := 4

	var mod = null
	var band: Dictionary = {}
	var band_i := 0
	var band_idx := 0
	var idx := 0
	var id := "hv1"
	var st := IDLE
	var st_t := 0.0
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var yaw := 0.0
	var theta := 0.0
	var ready_at := 0.0
	var seen := false
	# the dive
	var tgt: Node3D = null
	var tgt_sid := ""
	var from := Vector3.ZERO
	var aim := Vector3.ZERO
	var feint := false
	var dive_t := 0.0
	var hanging := false
	var committed := false
	var aborted := false
	var rake_dir := Vector3.UP
	var climb_back := false
	# guests
	var rp_pos := Vector3.ZERO
	var rp_vel := Vector3.ZERO
	var rp_ms := 0
	var rp_idle_t := 0.0
	var rdive := false
	var rdive_ms := 0
	# visuals and sound
	var body: Node3D
	var pose: Node3D
	var model: Node3D
	var rig = null
	var fallback := false
	var wings: Array = []
	var fold_k := 0.0
	var pitch := 0.0
	var sfx_voice: AudioStreamPlayer3D
	var sfx_wing: AudioStreamPlayer3D
	var sfx_rush: AudioStreamPlayer3D
	var wing_t := 0.0
	var chitter_t := 0.0
	var echo_t := -1.0
	var echo_pitch := 1.0
	var rushing := false
	var clicked := false
	var flap_ph := 0.0
	var lod_t := 0.0
	var near := true
	# flight
	var bob_ph := 0.0
	var bob_w := 0.1
	var bob_amp := 7.0
	var avoid_t := 0.0
	var avoid_hits := 0
	var avoid_turn := 0.0
	var avoid_climb := 0.0
	# v5.0 no-clip (3.I): authority
	var nc = null                    # noclip.gd mover state (NC.state "harrier", lead 2.2)
	var tp := 0                      # teleports outside the mover state (wake, test placements); streamed
	var nc_tick := 0
	var nc_probe_i := 0
	var nc_react_t := 0.0
	var nc_rec_t := 0.0
	var app_ray_t := 0.0
	var avoid_hold_t := 0.0
	var stoop_aim := Vector3.ZERO     # I5: the aim the stoop line was last checked for
	var vis_yaw := 0.0                # the drawn yaw (eased; the pull-out turns it toward the void)
	# v5.0 no-clip: guests (I8)
	var g_buf: Array = []             # [ms, pos, st, yaw] host samples by arrival, newest last (4)
	var g_off := Vector3.ZERO         # drawn position - interpolated host position (decays)
	var g_resync := false             # after a local dive: take the offset from where it ended
	var g_rtp := 0                    # the streamed teleport counter
	var g_have_tp := false
	var g_tp := 0                     # declared local snaps
	var g_prev := Vector3.INF         # the self-check's last drawn position (INF: skip one step)

	func setup(b: Dictionary, i: int, m) -> void:
		band = b
		idx = i
		mod = m
		id = "hv%d" % (i + 1)
		name = "Harrier_" + id
		top_level = true
		var period := randf_range(40.0, 70.0)
		bob_w = TAU / period
		var bv := 2.0 if str(b.get("name", "")) == "foundry" else 0.8
		bob_amp = bv / bob_w
		bob_ph = randf() * TAU
		chitter_t = randf_range(14.0, 28.0)

	func _ready() -> void:
		body = Node3D.new()
		add_child(body)
		pose = Node3D.new()
		body.add_child(pose)
		mod.make_model(self)
		if rig != null:
			# the first flying frame, so a far (inactive) harrier never shows the upright bind pose
			rig.call("play", "idle", 0.0)
			var ap = rig.get("anim")
			if ap is AnimationPlayer:
				(ap as AnimationPlayer).advance(0.0)
		sfx_voice = AudioStreamPlayer3D.new()
		sfx_voice.max_distance = 170.0
		sfx_voice.unit_size = 12.0
		body.add_child(sfx_voice)
		sfx_wing = AudioStreamPlayer3D.new()
		sfx_wing.max_distance = 90.0
		sfx_wing.unit_size = 6.0
		body.add_child(sfx_wing)
		sfx_rush = AudioStreamPlayer3D.new()
		sfx_rush.max_distance = 90.0
		sfx_rush.unit_size = 8.0
		body.add_child(sfx_rush)
		visible = false
		global_position = pos

	func spawn_angle() -> float:
		return float(band_i) * 2.1 + float(band_idx) * PI

	# ---------------------------------------------------------------- state changes

	func wake() -> void:
		if st != IDLE:
			return
		var low = mod.lowest_in_band(band_i)
		var py: float = float(low) if low != null else float(band["top"]) - 40.0
		var w: float = mod.snap_alt(band_i, py + ALT_ABOVE, py)
		theta = spawn_angle()
		pos = mod.circle_point(band_i, w, theta)
		tp += 1
		if mod.nc_on():
			pos = _nc_seed(pos)                # I0: a wake is a spawn: the guard re-seeds here
		vel = Vector3.ZERO
		vis_yaw = yaw
		_enter(CIRCLE)
		visible = true
		seen = true
		global_position = pos

	func nc_test_place(p: Vector3) -> void:
		# noclip_test_dive: a scripted move onto the circle (declared: tp counts it)
		pos = p
		tp += 1
		if mod.nc_on():
			pos = _nc_seed(pos)
		vel = Vector3.ZERO
		global_position = pos                  # _fly reads its bearing on the circle from pos

	func _nc_seed(p: Vector3) -> Vector3:
		var NC = mod.nc_script()
		var space = mod._space()
		if NC == null or space == null:
			return p
		if not (nc is Dictionary):
			nc = NC.call("state", "harrier", p, {"lead": HALF_LEN})
		return NC.call("place", space, nc, p)

	func tp_count() -> int:
		return tp + (int(nc.get("tp", 0)) if nc is Dictionary else 0)

	func sleep() -> void:
		drop_dive()
		_enter(IDLE)
		visible = false

	func _enter(s: int) -> void:
		st = s
		st_t = 0.0
		if s != DIVE:
			rushing = false
			clicked = false
		if s == CIRCLE:
			tgt = null
			hanging = false

	func busy() -> bool:
		return st == APPROACH or st == DIVE or (st == RAKE and not climb_back)

	func debug_ready() -> void:
		ready_at = 0.0

	func start_approach(p: Node3D, sid: String, f: Vector3) -> void:
		tgt = p
		tgt_sid = sid
		from = f
		hanging = false
		if mod.nc_on():
			app_ray_t = APP_RAY_S               # the think just checked the line to F
			avoid_turn = 0.0                    # the circle's avoidance never bends the approach
			avoid_hits = 0
			avoid_hold_t = 0.0
		_enter(APPROACH)

	func drop_dive() -> void:
		# the session ended (or the band slept): no strike, back to the circle
		if st == APPROACH or st == DIVE or st == RAKE:
			if CoopSync.map_is_authority() and (st == APPROACH or st == DIVE):
				mod.dive_ended(self, band_i, feint, true)
			_enter(CIRCLE)
		rdive = false
		fold_k = 0.0

	# ---------------------------------------------------------------- the stream

	func state_packet():
		# [x, y, z, yaw, st, tp] as a PackedFloat32Array (R15: 4 bytes a float; receivers only index it).
		# tp (v5.0, guard on only) counts teleports: a guest snaps, never glides, when it changes. Readers
		# only index, and a 5-float packet is read as "tp unchanged".
		if mod.nc_on():
			return PackedFloat32Array([pos.x, pos.y, pos.z, yaw, float(st), float(tp_count())])
		return PackedFloat32Array([pos.x, pos.y, pos.z, yaw, float(st)])

	func remote_state(a) -> void:
		if mod.nc_on():
			_g_state(a)
			return
		var p := Vector3(float(a[0]), float(a[1]), float(a[2]))
		var now := Time.get_ticks_msec()
		if rp_ms > 0 and now > rp_ms:
			rp_vel = (p - rp_pos) / (float(now - rp_ms) / 1000.0)
			if rp_vel.length() > 60.0:
				rp_vel = Vector3.ZERO
		rp_pos = p
		rp_ms = now
		rp_idle_t = 0.0
		var s := int(a[4])
		if not seen or not visible:
			pos = p
			global_position = p
		seen = true
		visible = true
		mod._gs_visible += 1
		if not rdive:
			yaw = float(a[3])
			if s != st:
				_enter(s)

	func remote_idle() -> void:
		rp_idle_t += 0.1
		if rp_idle_t > 0.5 and not rdive:
			_enter(IDLE)
			visible = false
			_g_clear_buf()

	func remote_stale() -> void:
		# guests: no "hv" packet at all for HV_STALE_MS (every band asleep on the host): settle out of
		# sight; the next packet shows it again at its streamed position
		_enter(IDLE)
		visible = false
		rp_ms = 0
		rp_vel = Vector3.ZERO
		rp_idle_t = 0.0
		fold_k = 0.0
		_g_clear_buf()

	func remote_dive(f: Vector3, a: Vector3, fe: bool) -> void:
		if mod.nc_on() and seen and visible and (pos.distance_to(f) > G_SNAP or not _g_step_ok(pos, f)):
			_g_declare()                         # the hang point is not a short clear step away: a snap
		from = f
		aim = a
		feint = fe
		dive_t = 0.0
		committed = false
		rdive = true
		rdive_ms = Time.get_ticks_msec()
		pos = f
		visible = true
		seen = true
		_enter(DIVE)
		_shriek_sounds()

	func threat_positions() -> Array:
		if st == APPROACH or st == DIVE:
			return [pos]
		return []

	# ---------------------------------------------------------------- per frame

	func _physics_process(delta: float) -> void:
		if st == IDLE and not rdive:
			return
		st_t += delta
		if rdive:
			_dive_step(delta, false)               # a guest flies the host's stoop locally
		elif CoopSync.map_is_authority():
			var st0 := st
			match st:
				CIRCLE:
					_fly(delta)
				APPROACH:
					_approach(delta)
				DIVE:
					_dive_step(delta, true)
				RAKE:
					_rake(delta)
			if st != IDLE and mod.nc_on():
				_nc_guard(delta, st0)              # I1: the swept move, posture probes, refusals
		elif rp_ms > 0:
			_follow(delta)                         # guests: the host's stream (nothing before the first packet)
		global_position = pos
		if visible and not CoopSync.map_is_authority() and mod.nc_on():
			_g_selfcheck()

	# ---------------------------------------------------------------- no-clip guard (authority, v5.0)

	func _nc_guard(delta: float, st0: int) -> void:
		var NC = mod.nc_script()
		var space = mod._space()
		if NC == null or space == null:
			return
		if not (nc is Dictionary):
			# first guarded tick (a host that took over, or a harrier woken before the guard came on)
			nc = NC.call("state", "harrier", pos, {"lead": HALF_LEN})
			pos = NC.call("place", space, nc, pos)
			return
		nc_react_t -= delta
		var want := pos
		pos = NC.call("move", space, nc, want, {"free_off": true})
		if bool(nc.get("blocked", false)) and pos.distance_to(want) > 0.001:
			# a dive only clamps; the impact rule (I2) decides whether it strikes
			_nc_refused(DIVE if st0 == DIVE else st, nc.get("n", Vector3.UP))
		# posture: one clearance probe per tick while approaching or raking under 60 m of a player (where
		# the rock is), else every 4th tick; none in the dive (the nose ray and the stoop line cover it)
		nc_tick += 1
		var tier := int(nc.get("tier", NC_FULL))
		if st != DIVE and st != IDLE and tier >= NC_NEAR:
			var every := 1 if (tier == NC_FULL and (st == APPROACH or st == RAKE)) else 4
			if nc_tick % every == 0:
				pos = _nc_probe(NC, space)
		if bool(nc.get("need_rec", false)):
			_nc_need_rec(NC, space, delta)

	func _nc_refused(react: int, n) -> void:
		match react:
			CIRCLE:
				if nc_react_t > 0.0:
					return
				nc_react_t = REACT_S
				avoid_climb = minf(avoid_climb + 10.0, 30.0)
				var nf := Vector3.ZERO
				if n is Vector3:
					nf = Vector3((n as Vector3).x, 0.0, (n as Vector3).z)
				if nf.length() > 0.2:
					nf = nf.normalized()
					var vf := Vector3(vel.x, 0.0, vel.z)
					if vf.length() > 0.1:
						var side := signf(vf.cross(nf).y)
						avoid_turn = (side if side != 0.0 else 1.0) * AVOID_TURN * 2.0
					var into := vel.dot(nf)
					if into < 0.0:
						vel -= nf * into               # drop the part of the flight that goes into the rock
				avoid_hits = 0
			APPROACH:
				print("[HARRIER] %s gave up the approach: rock ahead" % id)
				mod.nc_note("giveups")
				mod.dive_ended(self, band_i, false, true)
				_enter(CIRCLE)
			RAKE:
				climb_back = true
				_enter(CIRCLE)
			_:
				pass

	func _nc_probe(NC, space) -> Vector3:
		# round robin: right wing, left wing (2.1 along the flat right axis), head (2.3 along the heading),
		# belly (1.0 down); a hit pushes the body back as a swept move from the last good point
		var k := nc_probe_i % 4
		nc_probe_i += 1
		var right: Vector3 = Basis(Vector3.UP, yaw).x
		var dir: Vector3 = Vector3.DOWN
		var want := BELLY
		if k == 0:
			dir = right
			want = HALF_SPAN + 0.1
		elif k == 1:
			dir = -right
			want = HALF_SPAN + 0.1
		elif k == 2:
			dir = _heading()
			want = HALF_LEN + 0.1
		return NC.call("clearance", space, nc, pos, dir, want)

	func _nc_need_rec(NC, space, delta: float) -> void:
		# a self-audit found the unverified seed in rock: the helper holds the mover until it recovers
		# (only in CIRCLE, and only where nobody sees it); a flight in progress gives up first
		match st:
			APPROACH:
				print("[HARRIER] %s gave up the approach: its seed point is in rock" % id)
				mod.nc_note("giveups")
				mod.dive_ended(self, band_i, false, true)
				_enter(CIRCLE)
			DIVE:
				aborted = true
				print("[HARRIER] %s ABORT: its seed point is in rock" % id)
				mod.nc_note("nc_aborts")
				mod.dive_ended(self, band_i, feint, true)
				_enter(CIRCLE)
			RAKE:
				climb_back = true
				_enter(CIRCLE)
			CIRCLE:
				nc_rec_t -= delta
				if nc_rec_t > 0.0:
					return
				nc_rec_t = 0.5
				var r = NC.call("try_recover", space, nc, [pos, pos + _heading() * HALF_LEN])
				if r is Vector3:
					pos = r
					vel = Vector3.ZERO
					print("[HARRIER] %s recovered to %s (unseen)" % [id, str(r)])

	func _heading() -> Vector3:
		if st == DIVE:
			var e := curve_end() - from
			if e.length() > 0.01:
				return e.normalized()
		if vel.length() > 1.0:
			return vel.normalized()
		return -Basis(Vector3.UP, yaw).z

	func _wall_clamp(p: Vector3) -> Vector3:
		# OFF tier (no rock collision near): never farther than Rift.radius(y) - 15 m from the axis
		var c: Vector2 = mod.Rift.center(p.y)
		var d := Vector2(p.x - c.x, p.z - c.y)
		var rmax := maxf(8.0, float(mod.Rift.radius(p.y)) - WALL_PAD)
		if d.length() > rmax:
			d = d.normalized() * rmax
			p.x = c.x + d.x
			p.z = c.y + d.y
		return p

	# ---------------------------------------------------------------- no-clip test points (v5.0)

	func nc_points(view: String) -> Dictionary:
		# spec 5.2: centre; head 2.2 m along the DRAWN forward (the stoop pitch included); wingtips 2.0 m
		# along the drawn right axis, times the fold (0.45 in the dive)
		var c := global_position
		var fwd := -body.global_basis.z
		var right := body.global_basis.x
		fwd = fwd.normalized() if fwd.length() > 0.0001 else Vector3.FORWARD
		right = right.normalized() if right.length() > 0.0001 else Vector3.RIGHT
		var span := HALF_SPAN * (model.scale.x if model != null else 1.0)
		var tpn: int = tp_count() if view == "host" else g_rtp + g_tp
		var names := ["circle", "approach", "dive", "rake", "idle"]
		return {"kind": "harrier", "id": id, "view": view, "c": [c], "cn": ["centre"], "seg": [-1], "sp": 0.0,
				"x": [c + fwd * HALF_LEN, c + right * span, c - right * span], "xn": ["head", "wing", "wing"],
				"xc": [0, 0, 0], "xg": [false, false, false], "vis": is_visible_in_tree(), "wl": false,
				"tp": tpn, "st": str(names[clampi(st, 0, 4)]), "fx": {}}

	# ---------------------------------------------------------------- guests, v5.0 (I8)

	func _g_state(a) -> void:
		# a host sample: kept by arrival time (at least 50 ms after the previous, so a late bunch still
		# spreads out); rp_vel over the fixed stream period, zero on a state change and in APPROACH
		var p := Vector3(float(a[0]), float(a[1]), float(a[2]))
		var ya := float(a[3])
		var s := int(a[4])
		var ptp: int = int(a[5]) if a.size() > 5 else g_rtp
		var now := Time.get_ticks_msec()
		var shown := seen and visible
		rp_vel = Vector3.ZERO
		if not g_buf.is_empty():
			var last: Array = g_buf[g_buf.size() - 1]
			if s == int(last[2]) and s != APPROACH:
				rp_vel = (p - (last[1] as Vector3)) / STREAM_DT
				if rp_vel.length() > 60.0:
					rp_vel = Vector3.ZERO
		var t := now
		if not g_buf.is_empty():
			t = maxi(now, int(g_buf[g_buf.size() - 1][0]) + 50)
		var tp_moved := g_have_tp and ptp != g_rtp
		g_rtp = ptp
		g_have_tp = true
		if not shown or tp_moved:
			# first sight, shown again, or a streamed teleport: straight to the sample
			g_buf = [[t, p, s, ya]]
			g_off = Vector3.ZERO
			g_prev = Vector3.INF
			if not rdive:
				pos = p
				global_position = p
				yaw = ya
				vis_yaw = ya
			if tp_moved and shown:
				mod._gs_nc_snaps += 1
		else:
			g_buf.append([t, p, s, ya])
			while g_buf.size() > 4:
				g_buf.pop_front()
		rp_pos = p
		rp_ms = now
		rp_idle_t = 0.0
		seen = true
		visible = true
		mod._gs_visible += 1
		if not rdive and s != st:
			_enter(s)

	func _g_clear_buf() -> void:
		g_buf.clear()
		g_off = Vector3.ZERO
		g_prev = Vector3.INF

	func _g_declare() -> void:
		g_tp += 1
		g_prev = Vector3.INF
		mod._gs_nc_snaps += 1

	func _g_target():
		# [position, yaw] of the host samples at now - 120 ms: interpolated, never extrapolated except in
		# CIRCLE (at most 0.1 s and 1 m); null before the first sample
		if g_buf.is_empty():
			return null
		var rt := Time.get_ticks_msec() - G_DELAY_MS
		var n := g_buf.size()
		var last: Array = g_buf[n - 1]
		if rt >= int(last[0]):
			var pl: Vector3 = last[1]
			if int(last[2]) == CIRCLE:
				var off: Vector3 = rp_vel * minf(float(rt - int(last[0])) / 1000.0, G_EXTRA_S)
				if off.length() > 1.0:
					off = off.normalized()
				pl += off
			return [pl, float(last[3])]
		var first: Array = g_buf[0]
		if rt <= int(first[0]):
			return [first[1], float(first[3])]
		for i in range(n - 1, 0, -1):
			var a0: Array = g_buf[i - 1]
			var b0: Array = g_buf[i]
			if rt >= int(a0[0]):
				var k := clampf(float(rt - int(a0[0])) / maxf(1.0, float(int(b0[0]) - int(a0[0]))), 0.0, 1.0)
				return [(a0[1] as Vector3).lerp(b0[1], k), lerp_angle(float(a0[3]), float(b0[3]), k)]
		return [first[1], float(first[3])]

	func _g_step_ok(a: Vector3, b: Vector3) -> bool:
		# a drawn step: clear, or not testable (rock not loaded there: nothing solid to pass through)
		if a.distance_to(b) < 0.001:
			return true
		if not mod.nc_solid(a, 4.0) or not mod.nc_solid(b, 4.0):
			return true
		var space = mod._space()
		return space == null or mod.nc_ray(space, a, b).is_empty()

	func _g_glide_ok(a: Vector3, b: Vector3) -> bool:
		# a catch-up glide: only along a clear ray, and never across rock that is not loaded (2.5)
		if not mod.nc_solid(a, 4.0) or not mod.nc_solid(b, 4.0):
			return false
		var space = mod._space()
		return space == null or mod.nc_ray(space, a, b).is_empty()

	func _g_follow(delta: float) -> void:
		var tg = _g_target()
		if tg == null:
			return
		var tpos: Vector3 = tg[0]
		yaw = float(tg[1])
		if g_resync:
			g_resync = false
			g_off = pos - tpos                  # the local dive ended here: carry on from where it is
		var e := g_off.length()
		if e > G_SNAP:
			if _g_glide_ok(pos, tpos):
				g_off = g_off.move_toward(Vector3.ZERO, clampf(e * 10.0, 20.0, G_GLIDE_V) * delta)
			else:
				g_off = Vector3.ZERO
				pos = tpos
				_g_declare()
				return
		else:
			g_off *= exp(-12.0 * delta)
			if g_off.length() < 0.01:
				g_off = Vector3.ZERO
		var np := tpos + g_off
		# never faster than 60 m/s on screen: a target that jumps (lost packets, then a new one) becomes a
		# short catch-up; the rest stays in the offset, which a later tick glides or snaps as above
		var mv := np - pos
		var cap := G_GLIDE_V * delta
		if mv.length() > cap:
			np = pos + mv / mv.length() * cap
			g_off = np - tpos
		if not _g_step_ok(pos, np):
			g_off = Vector3.ZERO
			np = tpos
			if not _g_step_ok(pos, np):
				_g_declare()
		pos = np

	func _g_selfcheck() -> void:
		# guests (guard on): every drawn step of a shown harrier within 150 m of the camera is ray-tested
		# where the rock is loaded; guestsim_report() counts steps that went through rock (must be 0)
		if g_prev == Vector3.INF or mod.listener().distance_to(pos) > 150.0:
			g_prev = pos
			return
		if g_prev.distance_to(pos) < 0.001:
			return
		if mod.nc_solid(g_prev, 4.0) and mod.nc_solid(pos, 4.0):
			var space = mod._space()
			if space != null:
				mod._gs_nc_n += 1
				if not mod.nc_ray(space, g_prev, pos).is_empty():
					mod._gs_nc_x += 1
					if mod._gs_nc_x <= 5:
						print("[HARRIER] guest %s went through rock %s -> %s (st %d, rdive %s)" % [id, str(g_prev), str(pos), st, str(rdive)])
		g_prev = pos

	func _process(delta: float) -> void:
		if not visible:
			return
		_visual(delta)
		_sounds(delta)

	# ---------------------------------------------------------------- flight (authority)

	func _want() -> float:
		var low = mod.lowest_in_band(band_i)
		var py: float = float(low) if low != null else pos.y - ALT_ABOVE
		var bob := bob_amp * sin(mod._clock * bob_w + bob_ph)
		return mod.snap_alt(band_i, py + ALT_ABOVE + bob + avoid_climb, py)

	func _fly(delta: float) -> void:
		var w := _want()
		var target: Vector3
		var speed := CIRCLE_V
		var t: Dictionary = mod.crossing(band_i, pos.y, w)
		var ease_v := CLIMB_V if climb_back else ALT_EASE
		if not t.is_empty():
			# crossing a slab's depth: fly to its open point first, change altitude only there
			var op: Vector3 = mod.Rift.open_point(t)
			var hd := Vector2(op.x - pos.x, op.z - pos.z).length()
			var yt: float = t["y_top"]
			var yb: float = t["bottom"]
			var wy := w
			if hd > 6.0:
				wy = maxf(w, yt + SLAB_PAD) if pos.y > (yt + yb) * 0.5 else minf(w, yb - SLAB_PAD)
			target = Vector3(op.x, wy, op.z)
			w = wy
		else:
			var cr: Array = mod.circle_of(band_i, pos.y)
			var c: Vector2 = cr[0]
			var r: float = maxf(8.0, float(cr[1]) - absf(avoid_turn) * 30.0)
			var here := atan2(pos.z - c.y, pos.x - c.x)
			var dist := Vector2(pos.x - c.x, pos.z - c.y).length()
			if absf(dist - r) < 25.0:
				theta = here + 0.35                # glide on round the ring
			else:
				theta = here + 0.15
			target = Vector3(c.x + cos(theta) * r, pos.y, c.y + sin(theta) * r)
		var flat := Vector3(target.x - pos.x, 0.0, target.z - pos.z)
		var want_v := Vector3.ZERO
		if flat.length() > 0.05:
			want_v = flat.normalized() * minf(speed, flat.length() * 2.0 + 2.0)
		var ny := move_toward(pos.y, w, ease_v * delta)
		if mod.nc_on():
			# I7: the full 3D step and both wingtips; a hit also holds the altitude change for 0.5 s
			want_v = _nc_avoid(delta, want_v, AVOID_RAY, Vector3(vel.x, (ny - pos.y) / maxf(delta, 0.0001), vel.z), true)
			if avoid_hold_t > 0.0:
				avoid_hold_t -= delta
				ny = pos.y
		else:
			want_v = _avoid(delta, want_v)
		vel = vel.move_toward(want_v, 18.0 * delta)
		if climb_back and absf(ny - w) < 2.0:
			climb_back = false
		_move(Vector3(pos.x + vel.x * delta, ny, pos.z + vel.z * delta), 8.0, delta)
		avoid_climb = move_toward(avoid_climb, 0.0, delta)

	func _approach(delta: float) -> void:
		if not hanging:
			var to := from - pos
			if st_t > APPROACH_GIVEUP or not is_instance_valid(tgt):
				print("[HARRIER] %s gave up the approach" % id)
				mod.nc_note("giveups")
				mod.dive_ended(self, band_i, false, true)
				_enter(CIRCLE)
				return
			var guard: bool = mod.nc_on()
			if guard:
				# I4: the line to the hang point is re-rayed every 0.25 s; rock on it = give up
				app_ray_t -= delta
				if app_ray_t <= 0.0:
					app_ray_t = APP_RAY_S
					var space = mod._space()
					if space != null and not mod._clear(space, pos, from):
						print("[HARRIER] %s gave up the approach: rock on the line to its hang point" % id)
						mod.nc_note("nc_aborts")
						mod.nc_note("giveups")
						mod.dive_ended(self, band_i, false, true)
						_enter(CIRCLE)
						return
			if to.length() < 1.5:
				hanging = true
				st_t = 0.0
				vel = Vector3.ZERO
				pos = from
				return
			var want_v := to.normalized() * APPROACH_V
			if guard:
				# the avoidance looks only at the stretch before the hang point's clear sphere
				want_v = _nc_avoid(delta, want_v, maxf(0.0, to.length() - 3.0), vel, false)
			vel = vel.move_toward(want_v, 30.0 * delta)
			_move(pos + vel * delta, 8.0, delta)
			return
		# hang 0.25 s at F, then the shriek
		pos = pos.lerp(from, clampf(delta * 8.0, 0.0, 1.0))
		if st_t < HANG_S:
			return
		var why: String = mod.target_state(self)
		if why != "":
			print("[HARRIER] %s no shriek: target %s" % [id, why])
			mod.dive_ended(self, band_i, false, true)
			_enter(CIRCLE)
			return
		feint = mod.band_feint(band_i)
		aim = tgt.global_position + Vector3.UP * CHEST
		if mod.nc_on() and not _nc_stoop_clear():
			# I5: rock on the stoop line: no shriek (a telegraph is never wasted on a dive that cannot land)
			print("[HARRIER] %s no shriek: rock on the stoop line" % id)
			mod.nc_note("nc_aborts")
			mod.dive_ended(self, band_i, false, true)
			_enter(CIRCLE)
			return
		stoop_aim = aim
		dive_t = 0.0
		committed = false
		aborted = false
		_enter(DIVE)
		print("[HARRIER] %s SHRIEK -> %s feint=%s" % [id, tgt_sid, str(feint)])
		mod.nc_note("shrieks")
		_shriek_sounds()
		dived.emit(tgt_sid, from, aim, feint, id)

	func curve_end() -> Vector3:
		# where the stoop ends: the aim; the feint 5 m short; with the guard on (I2) a real dive ends
		# 2.3 m short of the aim, back along the stoop (the nose then reaches the aim, the body stays in air)
		var back := from - aim
		if feint:
			if back.length() > 0.01:
				return aim + back.normalized() * FEINT_SHORT
			return aim
		if back.length() > 0.01 and mod.nc_on():
			return aim + back.normalized() * DIVE_END
		return aim

	func curve(t: float) -> Vector3:
		# the 1.5 s stoop: hang while it folds (0.25 s), then an ease-in dive to about 26 m/s
		var end := curve_end()
		if t <= FOLD_S:
			return from
		var u := clampf((t - FOLD_S) / (IMPACT_S - FOLD_S), 0.0, 1.0)
		return from.lerp(end, pow(u, 1.8))

	func _dive_step(delta: float, authority: bool) -> void:
		dive_t += delta
		if authority and dive_t < COMMIT_S and is_instance_valid(tgt) and tgt.is_inside_tree():
			var want: Vector3 = tgt.global_position + Vector3.UP * CHEST
			aim = aim.move_toward(want, TRACK_V * delta)
			if mod.nc_on() and aim.distance_to(stoop_aim) > 1.0:
				stoop_aim = aim                    # I5: the aim moved 1 m: the stoop line again
				if not _nc_stoop_clear():
					_nc_abort_dive("rock on the stoop line")
					return
		if dive_t >= COMMIT_S - 0.001 and not committed:
			committed = true
			if authority:
				var why: String = mod.target_state(self)
				if why != "":
					aborted = true
					print("[HARRIER] %s ABORT at the commit: target %s" % [id, why])
					mod._aborts += 1
					mod.dive_ended(self, band_i, feint, true)
					_start_rake(true)
					return
				if mod.nc_on() and not _nc_stoop_clear():
					_nc_abort_dive("rock on the stoop line at the commit")
					return
				print("[HARRIER] %s COMMIT" % id)
			_commit_sounds()
		var p := curve(minf(dive_t, IMPACT_S))
		if Rift_in(p, 0.0):
			p = pos                                # never into a slab, even mid-stoop
		if mod.nc_on():
			p = _nc_nose(p)                        # I2: the nose stays 2.4 m off the rock (host and guest)
		if dive_t > FOLD_S:
			var d := p - pos
			if d.length() > 0.001:
				yaw = atan2(-d.x, -d.z)
		pos = p
		if dive_t >= IMPACT_S - 0.001:
			if authority:
				if feint:
					mod.on_feint(self)
				elif mod.nc_on() and _nc_pull_up():
					# I2: stopped short, or rock between it and the aim: a pull-up, never a hit through rock
					aborted = true
					print("[HARRIER] %s PULL-UP at the impact: %.1f m from the aim" % [id, pos.distance_to(aim)])
					mod.nc_note("nc_pullups")
					mod.dive_ended(self, band_i, feint, true)
					_start_rake(true)
					return
				else:
					mod.hit_test(self)
					mod.nc_note("impacts")
				mod.dive_ended(self, band_i, feint, false)
				_start_rake(feint)
			else:
				if rdive:
					# the curve's own clock (physics steps) and the wall clock since hdive_ arrived
					mod._gs_dives.append(dive_t)
					print("[HARRIER] %s remote dive flew %.2f s (wall %.2f s), ends %.2f m from the aim" % [id, dive_t, float(Time.get_ticks_msec() - rdive_ms) / 1000.0, pos.distance_to(aim)])
				rdive = false
				_start_rake(feint)
				rp_pos = pos
				rp_vel = rake_dir * RAKE_V
				g_resync = true                    # I8: the stream takes over from where the dive ended

	func _nc_abort_dive(why: String) -> void:
		aborted = true
		print("[HARRIER] %s ABORT: %s" % [id, why])
		mod._aborts += 1
		mod.nc_note("nc_aborts")
		mod.dive_ended(self, band_i, feint, true)
		_start_rake(true)

	func _nc_stoop_clear() -> bool:
		# I5: three parallel rays from the hang point to the stoop's end, centre and 1.2 m to each side
		var space = mod._space()
		if space == null:
			return true
		var end := curve_end()
		var d := end - from
		if d.length() < 0.5:
			return true
		var side := d.cross(Vector3.UP)
		if side.length() < 0.01:
			side = Basis(Vector3.UP, yaw).x
		side = side.normalized()
		for o in [0.0, STOOP_SIDE, -STOOP_SIDE]:
			var off: Vector3 = side * float(o)
			if not mod._clear(space, from + off, end + off):
				return false
		return true

	func _nc_nose(p: Vector3) -> Vector3:
		# I2, swept: one ray from the last drawn point (air) past the new one; the new point may come no
		# closer than 2.4 m to the first rock on that line, and never goes back (a guest never ray-tests
		# rock that is not loaded)
		var d := p - pos
		var dl := d.length()
		if dl < 0.0001:
			return p
		var space = mod._space()
		if space == null or not mod.nc_solid(pos, 6.0):
			return p
		var dir := d / dl
		var hit: Dictionary = mod.nc_ray(space, pos, p + dir * NOSE)
		if hit.is_empty():
			return p
		return pos + dir * clampf(float(hit.get("d", 0.0)) - NOSE, 0.0, dl)

	func _nc_pull_up() -> bool:
		if pos.distance_to(aim) > PULLUP_D:
			return true
		var space = mod._space()
		return space != null and not mod.nc_ray(space, pos, aim).is_empty()

	func _start_rake(pull_up: bool) -> void:
		var vd: Vector3 = mod.Rift.void_dir(pos)
		rake_dir = (vd + Vector3.UP * (1.6 if pull_up else 1.0)).normalized()
		if mod.nc_on():
			if CoopSync.map_is_authority():
				rake_dir = _nc_rake_dir(rake_dir, vd)   # I6
			var fl := Vector3(rake_dir.x, 0.0, rake_dir.z)
			if fl.length() > 0.05:
				yaw = atan2(-fl.x, -fl.z)          # it rakes out facing the void, never nose into the wall
		vel = rake_dir * RAKE_V
		_enter(RAKE)

	func _nc_rake_dir(d0: Vector3, vd: Vector3) -> Vector3:
		# I6: both wingtips need 24 m clear along the rake; else turn it toward UP (30, 60 deg), then
		# toward the void; with none clear, the line with the most room
		var space = mod._space()
		if space == null:
			return d0
		var vup: Vector3 = (vd + Vector3.UP * 0.3).normalized() if vd.length() > 0.01 else Vector3.UP
		var cands: Array = [d0, _toward(d0, Vector3.UP, 30.0), _toward(d0, Vector3.UP, 60.0), _toward(d0, vup, 60.0)]
		var best: Vector3 = d0
		var best_free := -1.0
		for i in cands.size():
			var dc: Vector3 = cands[i]
			var free := _rake_free(space, dc)
			if free >= RAKE_LOOK:
				if i > 0:
					print("[HARRIER] %s rake turned (try %d)" % [id, i + 1])
				return dc
			if free > best_free:
				best_free = free
				best = dc
		print("[HARRIER] %s rake: no clear 24 m line, the best has %.1f m" % [id, best_free])
		return best

	func _rake_free(space, d: Vector3) -> float:
		var right := d.cross(Vector3.UP)
		if right.length() < 0.1:
			right = Basis(Vector3.UP, yaw).x
		right = right.normalized()
		var free := RAKE_LOOK
		for o in [HALF_SPAN, -HALF_SPAN]:
			var a: Vector3 = pos + right * float(o)
			var h: Dictionary = mod.nc_ray(space, a, a + d * RAKE_LOOK)
			if not h.is_empty():
				free = minf(free, float(h.get("d", 0.0)))
		return free

	static func _toward(a: Vector3, b: Vector3, deg: float) -> Vector3:
		# a turned toward b by at most deg degrees
		var ang := a.angle_to(b)
		var ax := a.cross(b)
		if ang < 0.001 or ax.length() < 0.0001:
			return a
		return a.rotated(ax.normalized(), minf(deg_to_rad(deg), ang)).normalized()

	func _rake(delta: float) -> void:
		if st_t >= RAKE_S:
			climb_back = true
			_enter(CIRCLE)
			return
		_move(pos + rake_dir * RAKE_V * delta, RAKE_MARGIN if mod.nc_on() else 0.0, delta)

	func _move(next: Vector3, margin: float, delta: float) -> void:
		# the per-frame terrace guard: never step into a slab (+ margin); turn toward its open point
		if Rift_in(next, margin):
			var t := _terrace_at(next, margin)
			if not t.is_empty():
				var op: Vector3 = mod.Rift.open_point(t)
				var flat := Vector3(op.x - pos.x, 0.0, op.z - pos.z)
				if flat.length() > 0.01:
					next = pos + flat.normalized() * maxf(vel.length(), CIRCLE_V) * delta
					vel = flat.normalized() * vel.length()
				else:
					next = pos
			if Rift_in(next, 0.0):
				next = pos
		if (st == CIRCLE or st == RAKE) and nc is Dictionary and int(nc.get("tier", NC_FULL)) == NC_OFF and mod.nc_on():
			# OFF tier: no rock collision near (far from every player): fly on data, off the wall
			next = _wall_clamp(next)
			if Rift_in(next, 0.0):
				next = pos
		var d := next - pos
		if Vector2(d.x, d.z).length() > 0.001:
			yaw = lerp_angle(yaw, atan2(-d.x, -d.z), clampf(delta * 4.0, 0.0, 1.0))
		pos = next

	func Rift_in(p: Vector3, margin: float) -> bool:
		return bool(mod.Rift.in_terrace(p, margin))

	func _terrace_at(p: Vector3, margin: float) -> Dictionary:
		for t in mod.Rift.terraces():
			var yt: float = t["y_top"]
			if p.y < yt + margin and p.y > float(t["bottom"]) - margin and float(mod.Rift.terrace_side(t, p)) > -margin:
				return t
		return {}

	func _avoid(delta: float, want_v: Vector3) -> Vector3:
		# near rock (which has collision): a 12 m ray along the velocity every 0.25 s; a hit turns
		# 20 deg toward the axis, three in a row also climb 10 m
		avoid_t -= delta
		if avoid_t <= 0.0:
			avoid_t = 0.25
			var space: PhysicsDirectSpaceState3D = mod._space()
			var dirv := vel if vel.length() > 1.0 else want_v
			if space != null and dirv.length() > 0.5:
				var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(pos, pos + dirv.normalized() * AVOID_RAY, 1))
				if hit.is_empty():
					avoid_hits = 0
					avoid_turn = move_toward(avoid_turn, 0.0, AVOID_TURN)
				else:
					avoid_hits += 1
					var c: Vector2 = mod.Rift.center(pos.y)
					var to_axis := Vector3(c.x - pos.x, 0.0, c.y - pos.z)
					var side := signf(dirv.cross(to_axis).y)
					avoid_turn = side * AVOID_TURN * float(mini(avoid_hits, 3))
					if avoid_hits >= 3:
						avoid_climb = minf(avoid_climb + 10.0, 30.0)
						avoid_hits = 0
		if absf(avoid_turn) > 0.001 and want_v.length() > 0.01:
			want_v = want_v.rotated(Vector3.UP, avoid_turn)
		return want_v

	func _nc_avoid(delta: float, want_v: Vector3, ray_len: float, dir3: Vector3, hold: bool) -> Vector3:
		# I7 (guard on): every 0.25 s, three rays of ray_len along the full 3D step, from the centre and
		# both wingtips; a hit turns the flight away from the flat part of the hit normal (toward the
		# rift's axis when that is flat), holds the altitude change for 0.5 s (hold), and three hits in
		# a row also climb 10 m
		avoid_t -= delta
		if avoid_t <= 0.0:
			avoid_t = 0.25
			var space = mod._space()
			var dirv: Vector3 = dir3 if dir3.length() > 1.0 else want_v
			if space == null or dirv.length() <= 0.5 or ray_len <= 0.5:
				avoid_hits = 0
				avoid_turn = move_toward(avoid_turn, 0.0, AVOID_TURN)
			else:
				var dn := dirv.normalized()
				var right := dn.cross(Vector3.UP)
				if right.length() < 0.1:
					right = Basis(Vector3.UP, yaw).x
				right = right.normalized()
				var hit: Dictionary = {}
				for o in [0.0, HALF_SPAN, -HALF_SPAN]:
					var a: Vector3 = pos + right * float(o)
					var h: Dictionary = mod.nc_ray(space, a, a + dn * ray_len)
					if not h.is_empty() and (hit.is_empty() or float(h.get("d", 0.0)) < float(hit.get("d", 0.0))):
						hit = h
				if hit.is_empty():
					avoid_hits = 0
					avoid_turn = move_toward(avoid_turn, 0.0, AVOID_TURN)
				else:
					avoid_hits += 1
					var n: Vector3 = hit.get("normal", Vector3.UP)
					var nf := Vector3(n.x, 0.0, n.z)
					var vf := Vector3(dn.x, 0.0, dn.z)
					var side := 0.0
					if nf.length() > 0.2 and vf.length() > 0.05:
						side = signf(vf.cross(nf.normalized()).y)
					if side == 0.0:
						var c: Vector2 = mod.Rift.center(pos.y)
						side = signf(dirv.cross(Vector3(c.x - pos.x, 0.0, c.y - pos.z)).y)
					if side == 0.0:
						side = 1.0
					avoid_turn = side * AVOID_TURN * float(mini(avoid_hits, 3))
					if hold:
						avoid_hold_t = HOLD_S
					if avoid_hits >= 3:
						avoid_climb = minf(avoid_climb + 10.0, 30.0)
						avoid_hits = 0
		if absf(avoid_turn) > 0.001 and want_v.length() > 0.01:
			want_v = want_v.rotated(Vector3.UP, avoid_turn)
		return want_v

	# ---------------------------------------------------------------- guests

	func _follow(delta: float) -> void:
		if mod.nc_on():
			_g_follow(delta)                       # I8: host samples 120 ms behind, glides only on clear rays
			return
		var age := minf(float(Time.get_ticks_msec() - rp_ms) / 1000.0, 0.2)
		var target := rp_pos + rp_vel * age
		pos = pos.lerp(target, clampf(delta * 10.0, 0.0, 1.0))

	# ---------------------------------------------------------------- look

	func _visual(delta: float) -> void:
		lod_t -= delta
		if lod_t <= 0.0:
			lod_t = 0.5
			near = mod.listener().distance_to(pos) < 110.0
			if rig != null:
				rig.call("set_active", near)
		var fold_want := 1.0 if st == DIVE else 0.0
		fold_k = move_toward(fold_k, fold_want, delta / FOLD_S)
		var p_want := -deg_to_rad(70.0) * fold_k
		var y_want := yaw
		if st == RAKE:
			p_want = deg_to_rad(35.0)
		elif st != DIVE:
			var vy := vel.y if CoopSync.map_is_authority() else rp_vel.y
			p_want = clampf(vy / 20.0, -0.4, 0.4)
		elif mod.nc_on() and dive_t > IMPACT_S - PITCH_UP_S:
			# I2: the pull-out starts 0.2 s before the impact, turning toward the void it rakes out into
			var u := clampf((dive_t - (IMPACT_S - PITCH_UP_S)) / PITCH_UP_S, 0.0, 1.0)
			p_want = lerpf(p_want, deg_to_rad(35.0), u)
			var vd: Vector3 = mod.Rift.void_dir(pos)
			if vd.length() > 0.01:
				y_want = lerp_angle(yaw, atan2(-vd.x, -vd.z), u)
		pitch = lerpf(pitch, p_want, clampf(delta * 8.0, 0.0, 1.0))
		if mod.nc_on():
			vis_yaw = lerp_angle(vis_yaw, y_want, clampf(delta * 12.0, 0.0, 1.0))
		else:
			vis_yaw = yaw
		body.rotation = Vector3(pitch, vis_yaw, 0.0)
		if model != null:
			model.scale = Vector3(lerpf(1.0, 0.45, fold_k), 1.0, 1.0)
		if not near:
			return
		if rig != null:
			if st == DIVE:
				rig.call("set_speed", 0.0)          # the flapping stops
			elif st == APPROACH:
				rig.call("play", "walk")
				rig.call("set_speed", 1.7)
			elif st == RAKE:
				rig.call("play", "attack", 0.1)
				rig.call("set_speed", 1.2)
			else:
				rig.call("play", "idle")
				rig.call("set_speed", 1.0)
		else:
			var rate := 0.0 if st == DIVE else (9.0 if st == APPROACH else 5.5)
			flap_ph += delta * rate
			for i in wings.size():
				var wg: Node3D = wings[i]
				var sgn := 1.0 if i == 0 else -1.0
				wg.rotation.z = sgn * (sin(flap_ph) * 0.6 * (1.0 - fold_k) + 0.9 * fold_k)

	# ---------------------------------------------------------------- sound

	func _shriek_sounds() -> void:
		echo_pitch = randf_range(0.92, 1.08)
		mod.play_at(sfx_voice, "harrier_shriek", 0.0, echo_pitch)
		echo_t = 0.35

	func _commit_sounds() -> void:
		if clicked:
			return
		clicked = true
		mod.play_at(sfx_voice, "harrier_shriek", -3.0, 1.45)
		var s: AudioStream = mod._game_stream(SFX_CLICK)
		if s != null and sfx_wing.is_inside_tree():
			sfx_wing.stream = s
			sfx_wing.volume_db = 2.0
			sfx_wing.pitch_scale = 1.8
			sfx_wing.bus = mod._bus()
			sfx_wing.play()

	func _sounds(delta: float) -> void:
		if echo_t > 0.0:
			echo_t -= delta
			if echo_t <= 0.0:
				mod.echo(pos, echo_pitch)
		var lis: Vector3 = mod.listener()
		var d := lis.distance_to(pos)
		if st == DIVE:
			if dive_t >= RUSH_S and dive_t < IMPACT_S:
				if not rushing:
					rushing = true
					mod.play_at(sfx_rush, "harrier_dive", 0.0, 1.0)
				sfx_rush.pitch_scale = lerpf(1.0, 1.5, clampf((dive_t - RUSH_S) / (IMPACT_S - RUSH_S), 0.0, 1.0))
			return                                 # silent wings from the fold
		wing_t -= delta
		if wing_t <= 0.0:
			wing_t = randf_range(0.5, 0.8)
			if d < 90.0:
				mod.play_at(sfx_wing, "harrier_wing", -6.0, randf_range(0.9, 1.1))
		chitter_t -= delta
		if chitter_t <= 0.0:
			chitter_t = randf_range(14.0, 28.0)
			if d < 120.0:
				mod.play_at(sfx_voice, "harrier_shriek", -14.0, 1.4)


# ============================================================================ dev test (harrier.flag)
# Authority, solo (or loopback). Every step logs [HARRIER]; the last line is
# "[HARRIER] test done N/N PASS" (or "... FAIL: <names>"). SKIP lines do not count.
#   P-SLAB math: 72 angles x every 5 m of each band's altitudes, plus every transit point: never
#               Rift.in_terrace(p, 0)                                       -> "PASS no slab crossing"
#   survey:     each band's footholds parked near and probed (exposed footholds per band)
#   loopback:   dives at the Ghost: hdive_ and hstrike_ go out with who "777" (then the test ends)
#   P-SLAB fly: 20 s above THE SHELF V, then 60 s on the first main-route station 20-40 m below
#               its top: the drowned harriers are never inside a slab       -> "PASS never inside slab"
#   P0 FEINT:   on the most exposed Drowned foothold: no hstrike_, hfeint_drowned stored
#   P1 UNHOOKED FOLD->IMPACT 1.50 +-0.05 s, >= 3.5 m of slide in 1.0 s; shots
#               underdark_harrier_fold.png and underdark_harrier_strike.png
#   P2 HOOKED:  throw (ClimberState_Throw) at the shriek; < 0.6 m, still attached 2 s later, 5 HP
#   P3 RETREAT: 6 m toward the wall at FOLD + 0.5 s: ABORT, no strike
#   P4 LATE STEP-BACK: 6 m toward the wall at COMMIT + 0.2 s; the host's view stays at the old spot
#               for its hit test (as a guest's would): "strike skipped: not exposed", no damage
#   P5 CAMP:    an exposed spot within 15 m of a Drowned checkpoint, 60 s: no dive

func _tpass(n: String) -> void:
	_res_pass.append(n)
	print("[HARRIER] PASS " + n)


func _tfail(n: String) -> void:
	_res_fail.append(n)
	print("[HARRIER] FAIL " + n)


func _tskip(n: String) -> void:
	_res_skip.append(n)
	print("[HARRIER] SKIP " + n)


func _next(p: int) -> void:
	_tp = p
	_tt = 0.0


func _climber():
	var c = Game.climber
	if is_instance_valid(c) and c.is_inside_tree():
		return c
	return null


func _park(p: Vector3) -> void:
	_park_clock = _clock
	if map != null and map.has_method("debug_park"):
		map.call("debug_park", p)


func _look(p: Vector3) -> void:
	if map != null and map.has_method("debug_look"):
		map.call("debug_look", p)


func _shot(path: String) -> void:
	if map != null and map.has_method("debug_shot"):
		map.call("debug_shot", path)


func _test_ready(bi: int) -> void:
	for h in _band_hv[bi]:
		h.debug_ready()
	_band_gap_until[bi] = 0.0
	_personal_cd.clear()
	_grace_until = 0.0
	_t_shriek = -1.0
	_dive_h = null
	_strike_t = -1.0
	_last_skip = ""


func _since_shriek() -> float:
	if _t_shriek < 0.0:
		return -1.0
	return _clock - _t_shriek


func slab_math() -> Array:
	# P-SLAB (pure): [bad count, samples, first bad point]
	var bad := 0
	var n := 0
	var first = null
	for bi in BANDS.size():
		var b: Dictionary = BANDS[bi]
		var y := float(b["bottom"])
		while y <= float(b["top"]):
			for side in [1.0, -1.0]:
				# the lowest player just above / below this altitude's slab midpoint
				var w := snap_alt(bi, y, y + side * 30.0)
				for k in 72:
					var q := circle_point(bi, w, TAU * float(k) / 72.0)
					n += 1
					if Rift.in_terrace(q, 0.0):
						bad += 1
						if first == null:
							first = q
			y += 5.0
		for t in _band_terr[bi]:
			var op: Vector3 = Rift.open_point(t)
			var yy: float = float(t["y_top"]) + SLAB_PAD
			while yy >= float(t["bottom"]) - SLAB_PAD:
				var q2 := Vector3(op.x, yy, op.z)
				n += 1
				if Rift.in_terrace(q2, 0.0):
					bad += 1
					if first == null:
						first = q2
				yy -= 5.0
			# the flat legs from any ring point to the open point, at the snapped altitude of each side
			for wy in [float(t["y_top"]) + SLAB_PAD, float(t["bottom"]) - SLAB_PAD]:
				for k in 72:
					var a := circle_point(bi, wy, TAU * float(k) / 72.0)
					var tgt := Vector3(op.x, wy, op.z)
					var m := maxi(1, int(a.distance_to(tgt) / 5.0))
					for j in m + 1:
						var q3 := a.lerp(tgt, float(j) / float(m))
						n += 1
						if Rift.in_terrace(q3, 0.0):
							bad += 1
							if first == null:
								first = q3
	return [bad, n, first]


func _band_stations(bi: int) -> Array:
	var b: Dictionary = BANDS[bi]
	var out: Array = []
	var L = map.get("L")
	if not (L is Dictionary):
		return out
	for s in L.get("stations", []):
		if not (s is Dictionary):
			continue
		var kind := str(s.get("kind", ""))
		if not (kind in ["foothold", "shelf", "terrace", "hard", "gantry"]):
			continue
		var p := _v(s.get("pos", []))
		if p.y < float(b["top"]) and p.y > float(b["bottom"]):
			out.append(p)
	return out


func _test_step(delta: float) -> void:
	_tt += delta
	var c = _climber()
	if c == null:
		return
	match _tp:
		0:
			if _tclock > 3.0:
				for bi in BANDS.size():
					print("[HARRIER] band %s: %d harriers, y %.0f..%.0f, terraces %d" % [str(BANDS[bi]["name"]), _band_hv[bi].size(), float(BANDS[bi]["bottom"]), float(BANDS[bi]["top"]), _band_terr[bi].size()])
				print("[HARRIER] rift terraces %d (%s)" % [Rift.terraces().size(), str(Rift.status())])
				var r: Array = slab_math()
				if int(r[0]) == 0:
					_tpass("no slab crossing (%d samples)" % int(r[1]))
				else:
					_tfail("no slab crossing: %d of %d samples inside, first %s" % [int(r[0]), int(r[1]), str(r[2])])
				c.prevent_player_death = true
				# the survey: park near each cluster of footholds, probe the ones within 110 m
				_sv = {"parks": [], "i": 0, "res": {}}
				for bi in BANDS.size():
					var seeds: Array = []
					for p in _band_stations(bi):
						var covered := false
						for s0 in seeds:
							if (s0 as Vector3).distance_to(p) < 100.0:
								covered = true
						if not covered:
							seeds.append(p)
					for s1 in seeds:
						_sv["parks"].append([bi, s1])
				print("[HARRIER] survey: %d parks" % (_sv["parks"] as Array).size())
				_next(1)
		1:
			var parks: Array = _sv["parks"]
			var i: int = _sv["i"]
			if i >= parks.size():
				_survey_done()
				return
			if _p_mark == 0:
				_p_mark = 1
				_park((parks[i][1] as Vector3) + Vector3.UP * 1.0)
			elif _tt > 1.2:
				_survey_here(int(parks[i][0]), parks[i][1])
				_sv["i"] = i + 1
				_p_mark = 0
				_tt = 0.0
		2:
			# the camp survey: park at the checkpoint, probe spots toward the void within 15 m
			if _p_mark == 0:
				_p_mark = 1
				_park(_cp_pos[_camp_cp] + Vector3.UP * 1.0)
			elif _tt > 1.2:
				_camp_survey()
				_p_mark = 0
				_next(3 if not _test_loop else 50)
		3:
			# P-SLAB flight, part 1: stand on THE SHELF V so the drowned harriers settle above it,
			# then 60 s below its top: they must cross its depth at the open point (checked per frame
			# in _physics_process while _tp == 31)
			var top := _terrace_station("THE SHELF V")
			print("[HARRIER] P-SLAB: 20 s on THE SHELF V at %s" % str(top))
			_park(top + Vector3.UP * 1.0)
			_slab_bad = 0
			_slab_frames = 0
			_p_mark = 0
			_next(31)
		31:
			if _p_mark == 0 and _tt > 20.0:
				_p_mark = 1
				var below := _slab_station()
				print("[HARRIER] P-SLAB: 60 s at %s (below THE SHELF V's top)" % str(below))
				_park(below + Vector3.UP * 1.0)
			elif _p_mark == 1 and _tt > 80.0:
				_p_mark = 0
				var h2 = _band_hv[1][0] if not _band_hv[1].is_empty() else null
				print("[HARRIER] P-SLAB: %d harrier frames checked, hv2 at %s" % [_slab_frames, str(h2.pos) if h2 != null else "?"])
				if _slab_bad == 0 and _slab_frames > 0:
					_tpass("never inside slab")
				else:
					_tfail("never inside slab (%d frames inside of %d)" % [_slab_bad, _slab_frames])
				_next(10)
		10:
			_phase_start("P0", false)
			_next(11)
		11:
			var s := _since_shriek()
			if s < 0.0:
				if _tt > 120.0:
					_tfail("P0 feint: no dive in 120 s")
					_next(20)
				return
			if s > 3.5:
				var stored: bool = CoopSync.map_events().has("hfeint_drowned")
				if _dive_feint and _strikes_on_me == 0 and stored:
					_tpass("P0 feint: no hstrike_, hfeint_drowned stored")
				else:
					_tfail("P0 feint: feint=%s strikes=%d hfeint_drowned=%s" % [str(_dive_feint), _strikes_on_me, str(stored)])
				_next(20)
		20:
			_phase_start("P1", true)
			_next(21)
		21:
			var s := _since_shriek()
			if s < 0.0:
				if _tt > 120.0:
					_tfail("P1 unhooked: no dive in 120 s")
					_next(30)
				return
			if _p_mark == 0:
				_p_mark = 1
				if _dive_h != null:
					_look(_dive_h.pos)                # face it, so the shots show the fold
			elif _p_mark == 1 and s > 0.2:
				_p_mark = 2
				_shot("user://underdark_harrier_fold.png")
			elif _p_mark == 2 and _strike_t >= 0.0 and _clock - _strike_t > 0.1:
				_p_mark = 3
				_shot("user://underdark_harrier_strike.png")
			elif _p_mark == 3 and _strike_t >= 0.0 and _clock - _strike_t >= 1.0:
				_p_mark = 4
				var dt := _strike_t - _t_shriek
				var dp: Vector3 = c.global_position - _strike_pos
				var slide := Vector2(dp.x, dp.z).length()
				print("[HARRIER] P1: FOLD->IMPACT %.2f s, slide %.2f m in 1.0 s, hp %.0f -> %.0f" % [dt, slide, _strike_hp, float(c.health)])
				if absf(dt - IMPACT_S) <= 0.05 and slide >= 3.5:
					_tpass("P1 unhooked: %.2f s, %.1f m" % [dt, slide])
				else:
					_tfail("P1 unhooked: %.2f s, %.1f m" % [dt, slide])
				_next(30)
			elif s > 4.0 and _p_mark < 4 and _strike_t < 0.0:
				_tfail("P1 unhooked: no strike landed (skipped: %s)" % _last_skip)
				_p_mark = 0
				_next(30)
		30:
			_p_mark = 0
			_phase_start("P2", true)
			_next(32)
		32:
			var s := _since_shriek()
			if s < 0.0:
				if _tt > 120.0:
					_tfail("P2 hooked: no dive in 120 s")
					_next(40)
				return
			if _p_mark == 0:
				_p_mark = 1
				_look(c.global_position + Rift.void_dir(c.global_position) * 0.6 + Vector3.DOWN * 3.0)
				c.set_climber_state(ClimberState_Throw.new())
				print("[HARRIER] P2: hook thrown at the shriek")
			elif _p_mark == 1:
				if c.activeClimberState is ClimberState_Attached:
					_p_mark = 2
					_phase_hp = float(c.health)
					print("[HARRIER] P2: attached %.2f s after the shriek" % s)
				elif s > 0.9:
					_tskip("P2 hooked: the hook never attached")
					_p_mark = 5                        # let this dive land and rake out before P3 re-parks
			elif _p_mark == 5:
				if s > IMPACT_S + RAKE_S + 0.5:
					_next(40)
			elif _p_mark == 2 and _strike_t >= 0.0 and _clock - _strike_t >= 1.0:
				_p_mark = 3
				var dp2: Vector3 = c.global_position - _strike_pos
				_sv["p2_disp"] = dp2.length()
				_sv["p2_lost"] = _strike_lost
			elif _p_mark == 3 and _strike_t >= 0.0 and _clock - _strike_t >= 3.0:
				var still: bool = c.activeClimberState is ClimberState_Attached
				var disp: float = _sv.get("p2_disp", 99.0)
				var lost: float = _sv.get("p2_lost", -1.0)
				print("[HARRIER] P2: moved %.2f m, attached 2 s later=%s, lost %.1f HP" % [disp, str(still), lost])
				if disp < 0.6 and still and absf(lost - 5.0) <= 0.6:
					_tpass("P2 hooked: %.2f m, 5 HP" % disp)
				else:
					_tfail("P2 hooked: %.2f m, attached=%s, %.1f HP" % [disp, str(still), lost])
				_next(40)
			elif s > 4.0 and _p_mark == 2 and _strike_t < 0.0:
				_tfail("P2 hooked: no strike landed (skipped: %s)" % _last_skip)
				_next(40)
		40:
			_p_mark = 0
			_aborts = 0
			_phase_start("P3", true)
			_next(41)
		41:
			var s := _since_shriek()
			if s < 0.0:
				if _tt > 120.0:
					_tfail("P3 retreat: no dive in 120 s")
					_next(45)
				return
			if _p_mark == 0 and s >= FOLD_S + 0.5:
				_p_mark = 1
				_park(_retreat + Vector3.UP * 1.0)
				print("[HARRIER] P3: stepped back %.1f m at %.2f s" % [_retreat.distance_to(_spot), s])
			elif _p_mark == 1 and s > 3.0:
				if _aborts > 0 and _strikes_on_me == 0:
					_tpass("P3 retreat: ABORT, no strike")
				else:
					_tfail("P3 retreat: aborts=%d strikes=%d" % [_aborts, _strikes_on_me])
				_next(45)
		45:
			_p_mark = 0
			_phase_start("P4", true)
			_next(46)
		46:
			var s := _since_shriek()
			if s < 0.0:
				if _tt > 120.0:
					_tfail("P4 late step-back: no dive in 120 s")
					_next(55)
				return
			if _p_mark == 0 and s >= COMMIT_S + 0.2:
				_p_mark = 1
				_stale_local = c.global_position       # the host's (late) view of this player
				_park(_retreat + Vector3.UP * 1.0)
				_phase_hp = float(c.health)
				print("[HARRIER] P4: stepped back at %.2f s (after the commit)" % s)
			elif _p_mark == 1 and s > 3.0:
				_stale_local = null
				var lost := _phase_hp - float(c.health)
				if _last_skip == "not exposed" and _strikes_on_me == 0 and lost <= 0.01:
					_tpass("P4 late step-back: strike skipped: not exposed, no damage")
				else:
					_tfail("P4 late step-back: skipped '%s', strikes %d, lost %.1f" % [_last_skip, _strikes_on_me, lost])
				_next(55)
		55:
			# P5: an exposed spot within 15 m of a checkpoint, 60 s: never dived
			if _camp_cp < 0:
				_next(90)                          # no drowned checkpoint: skipped at the survey
				return
			_test_ready(1)
			_no_dive = false
			_strikes_on_me = 0
			_park(_camp + Vector3.UP * 1.0)
			print("[HARRIER] P5: camp spot %s, %.1f m from checkpoint %d, exposed %d" % [str(_camp), _camp.distance_to(_cp_pos[_camp_cp]) if _camp_cp >= 0 else -1.0, _camp_cp, _camp_exp])
			_next(56)
		56:
			if _t_shriek >= 0.0 and _is_me(_dive_who):
				_tfail("P5 camp: dived at a camp")
				_next(90)
			elif _tt > 60.0:
				_tpass("P5 camp: no dive in 60 s (exposed %d)" % _camp_exp)
				_next(90)
		50:
			# loopback: the Ghost (777) stands 3.5 m ahead of where I look; I face the void and am
			# left out of the targeting, so the dives go at the Ghost
			_test_ready(1)
			_no_dive = false
			_skip_local = true
			_park(_spot + Vector3.UP * 1.0)
			_p_mark = 0
			_next(51)
		51:
			if _p_mark == 0 and _tt > 1.0:
				_p_mark = 1
				_look(_spot + Vector3.UP * 1.6 + Rift.void_dir(_spot) * 10.0)
			if _loop_dive and _loop_strike:
				_tpass("loopback: hdive_ and hstrike_ went out with who 777")
				_next(90)
			elif _t_shriek >= 0.0 and _since_shriek() > 3.0 and not _loop_strike:
				_test_ready(1)                     # the band's first dive feints: let it dive again
			elif _tt > 150.0:
				if _loop_dive:
					_tfail("loopback: hdive_ went out with who 777 but no hstrike_")
				else:
					_tfail("loopback: no dive at the Ghost in 150 s")
				_next(90)
		90:
			var gs_done: bool = CoopSync.has_method("guestsim_test_done")
			if str(CoopSync.get("guestsim")) == "record" and _tt < (3.5 if gs_done else 11.0):
				# guestsim record: CoopSync's guestsim_test_done writes the recording at once and closes
				# it 3 s later with the trailing packets (the last dive's), whatever the write interval
				# (30 s past 3,000 entries). The done line waits for that close: a harness may stop the
				# game at it. Without the hook, the old wait for the 10 s write
				if _p_mark != 90:
					_p_mark = 90
					if gs_done:
						CoopSync.call("guestsim_test_done", "HARRIER")
					print("[HARRIER] guestsim record: %.1f s more so the recording holds the last dive" % (3.5 if gs_done else 11.0))
				return
			c.prevent_player_death = false            # a test never leaves the player invincible
			_no_dive = false
			_skip_local = false
			_stale_local = null
			var n := _res_pass.size() + _res_fail.size()
			# printerr: the release build buffers print(), and the runner waits for this line in the log
			if _res_fail.is_empty():
				printerr("[HARRIER] test done %d/%d PASS" % [_res_pass.size(), n])
			else:
				var names: Array = []
				for f in _res_fail:
					names.append(str(f).split(":")[0])
				printerr("[HARRIER] test done %d/%d FAIL: %s" % [_res_pass.size(), n, ", ".join(names)])
			_test = false


func _phase_start(tag: String, _keep_feinted: bool) -> void:
	_test_ready(1)
	_no_dive = false
	_skip_local = false
	_strikes_on_me = 0
	_p_mark = 0
	var ln = CoopSync.lantern
	if is_instance_valid(ln) and "oil" in ln:
		ln.set("oil", 1.0)                       # a full lamp: the Drowned band's Shades leave a lit player be
	_park(_spot + Vector3.UP * 1.0)
	print("[HARRIER] %s: standing on the drowned test foothold %s (feinted=%s)" % [tag, str(_spot), str(_feinted.has("drowned"))])


func _terrace_station(nm: String) -> Vector3:
	var L = map.get("L")
	var best := Vector3.ZERO
	if L is Dictionary:
		for s in L.get("stations", []):
			if s is Dictionary and str(s.get("kind", "")) == "terrace" and str(s.get("label", "")) == nm:
				return _v(s["pos"])
	return best


func _slab_station() -> Vector3:
	# the first main-route station 20-40 m below THE SHELF V's top
	var yt := -2162.751
	for t in _band_terr[1]:
		yt = float(t["y_top"])
	var L = map.get("L")
	if L is Dictionary:
		for s in L.get("stations", []):
			if not (s is Dictionary) or str(s.get("kind", "")) == "hard":
				continue
			var p := _v(s.get("pos", []))
			if p.y <= yt - 20.0 and p.y >= yt - 40.0:
				return p
	return _spot


func _survey_here(bi: int, seed: Vector3) -> void:
	var space := _space()
	if space == null:
		return
	var res: Dictionary = _sv["res"]
	for p in _band_stations(bi):
		if (p as Vector3).distance_to(seed) > 110.0 or res.has(p):
			continue
		# a standing spot needs rock under it: a "foothold" station can be a wall hold in mid-air
		# (the knight parked there falls to the terrace below, where nothing is exposed). The spot
		# becomes that floor point (walkable, within 1 m of the station).
		var fw = _walk_floor(space, (p as Vector3) + Vector3.UP * 2.0, (p as Vector3) + Vector3.DOWN * 3.0)
		if fw == null or absf((fw as Vector3).y - (p as Vector3).y) > 1.0:
			res[p] = [bi, -1, false, null, p]      # -1: no walkable floor within 1 m
			continue
		var f: Vector3 = fw
		var pc: Vector3 = f + Vector3.UP * 1.0
		var ex: int = Rift.edge_exposed(space, pc)
		var ok := ex >= 1 and not _enclosed(pc) and not _near_camp(pc)
		if ok:
			ok = _hang_point(space, pc) is Vector3    # the targeting's own rule (v5.0: the I3 sphere)
		var rt = null
		if ok and bi == 1:
			rt = _retreat_from(space, f)
		res[p] = [bi, ex, ok, rt, f]


func _spot_score(p: Vector3, ex: int) -> float:
	# most exposed first; then a spot below THE SHELF V whose wanted altitude (p + 22 m) needs no
	# snap, near where P-SLAB leaves the drowned harriers, and well inside the band
	var sc := float(ex) * 1000.0
	var yb := -2179.5
	for t in _band_terr[1]:
		yb = float(t["bottom"])
	var want_y := yb - SLAB_PAD - ALT_ABOVE - 20.0
	if p.y + 1.0 + ALT_ABOVE > yb - SLAB_PAD or p.y < float(BANDS[1]["bottom"]) + 40.0:
		sc -= 500.0
	return sc - absf(p.y - want_y)


func _retreat_from(space: PhysicsDirectSpaceState3D, p: Vector3):
	# a walkable floor point 6 m (or 5, 4) toward the wall, straight back or 1.5 m to either side,
	# with no exposed probe and no wall in between. The hit must face up: a steep hit is the side of
	# the rock, and a knight parked there slides off into the void (real-map run: 3 of 3 fell 19 m).
	var vd: Vector3 = Rift.void_dir(p)
	var side := vd.cross(Vector3.UP).normalized()
	for k in [6.0, 5.0, 4.0]:
		for off in [0.0, -1.5, 1.5]:
			var q: Vector3 = p - vd * float(k) + side * float(off)
			var f = _walk_floor(space, q + Vector3.UP * 2.5, q + Vector3.DOWN * 3.0)
			if f == null or absf((f as Vector3).y - p.y) > 1.5:
				continue
			if not _clear(space, p + Vector3.UP * 1.0, (f as Vector3) + Vector3.UP * 1.0):
				continue
			if Rift.edge_exposed(space, (f as Vector3) + Vector3.UP * 1.0) == 0:
				return f
	return null


func _walk_floor(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3):
	# tests: the first rock hit from a down to b (both-sided, the cave collision is double-sided) when
	# a knight can stand on it (normal.y >= FLOOR_NY), else null
	var q := PhysicsRayQueryParameters3D.create(a, b, 1)
	q.hit_back_faces = true
	var hit := space.intersect_ray(q)
	if hit.is_empty() or (hit["normal"] as Vector3).y < FLOOR_NY:
		return null
	return hit["position"]


func _survey_done() -> void:
	var res: Dictionary = _sv["res"]
	var best = null
	var best_ex := -1
	var best_sc := -1e9
	for bi in BANDS.size():
		var n := 0
		var nf := 0
		var ne := 0
		var n3 := 0
		var nok := 0
		for p in res.keys():
			var r: Array = res[p]
			if int(r[0]) != bi:
				continue
			n += 1
			if int(r[1]) < 0:
				nf += 1
			if int(r[1]) >= 1:
				ne += 1
			if int(r[1]) >= 3:
				n3 += 1
			if bool(r[2]):
				nok += 1
			if bi == 1 and bool(r[2]) and r[3] != null:
				var fp: Vector3 = r[4]
				var sc := _spot_score(fp, int(r[1]))
				if best == null or sc > best_sc:
					best_sc = sc
					best_ex = int(r[1])
					best = p
		print("[HARRIER] band %s: %d footholds probed (%d with no floor), %d exposed (%d fully), %d targetable" % [str(BANDS[bi]["name"]), n, nf, ne, n3, nok])
	if best == null:
		_tfail("survey: no targetable drowned foothold with a way back from the edge")
		_next(90)
		return
	_spot = res[best][4]                         # the floor point under the station
	_retreat = res[best][3]
	print("[HARRIER] test foothold %s exposed %d, retreat %s (%.1f m)" % [str(_spot), best_ex, str(_retreat), _spot.distance_to(_retreat)])
	# the camp for P5: the drowned checkpoint nearest the test foothold
	var bd := 1e9
	for i in _cp_pos.size():
		var q: Vector3 = _cp_pos[i]
		if q.y < float(BANDS[1]["top"]) and q.y > float(BANDS[1]["bottom"]) and q.distance_to(_spot) < bd:
			bd = q.distance_to(_spot)
			_camp_cp = i
	if _camp_cp < 0:
		_tskip("P5 camp: no checkpoint in the drowned band")
		_next(3 if not _test_loop else 50)
		return
	_next(2)


func _camp_survey() -> void:
	var space := _space()
	var cp: Vector3 = _cp_pos[_camp_cp]
	_camp = cp
	_camp_exp = 0
	if space == null:
		return
	var vd: Vector3 = Rift.void_dir(cp)
	var side := vd.cross(Vector3.UP).normalized()
	for off in [0.0, 3.0, -3.0, 6.0, -6.0]:
		for k in [2.0, 4.0, 6.0, 8.0, 10.0, 12.0]:
			var q: Vector3 = cp + vd * float(k) + side * float(off)
			if Vector2(q.x - cp.x, q.z - cp.z).length() > 13.0:
				continue
			var fw = _walk_floor(space, q + Vector3.UP * 3.0, q + Vector3.DOWN * 6.0)
			if fw == null:
				continue
			var f: Vector3 = fw
			var ex: int = Rift.edge_exposed(space, f + Vector3.UP * 1.0)
			if ex > _camp_exp:
				_camp_exp = ex
				_camp = f
	print("[HARRIER] camp survey: checkpoint %d at %s, best spot %s exposed %d" % [_camp_cp, str(cp), str(_camp), _camp_exp])
