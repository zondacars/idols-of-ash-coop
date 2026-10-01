extends Node

# ============================================================================================
# THE IDOL WANTS A HOST (ZondaCoopSync 5.0, feature module "idol", builder B3, contract 3.3)
#
# One player holds the idol at a time. Whoever holds it is hunted by the Nest (the pins), grows
# heavy (heartbeat, a dimmer and redder lantern, breaths, then a burn that telegraphs) and can
# push it into a living friend's hands by holding G within 3 m. The friend cannot refuse.
#
# IDOL ON THE GROUND (v5.1, owner design 2026-09-30): no cling any more (a friend can pass it straight
# back). TAP G throws it where you look (about 15 m; a throw into the pit comes back up on the ledge
# next to the thrower, so it can never be lost). Anyone who walks over a thrown idol picks it up,
# the thrower too (after 2 s, or once they stepped away). On the ground it weeps softly and the Nest
# keeps hunting the LAST THROWER; after 15 s nobody picked it up it glows red and SCREAMS, and from
# then on the Nest goes for the idol itself (a decoy pin) until someone picks it up.
#   idolthrow_<n> non-persistent  {n, giver, giver_by, from, pos, pit, fly, at}   holder -> authority
#   idolgrab_<n>  non-persistent  {n, to, to_by, at}                             walker -> authority
#   idolpass_<n> gains ground:true (id "", pos, from, pit, fly) for a throw, pickup:true + thrower
#                for a pickup. passes() counts hand passes and pickups by someone else than the
#                thrower (a throw to a friend is one pass once it is caught).
#
# LOADED BY THE MAP (underdark.gd _load_features, contract 2.2): s.new(), setup(map), add_child.
# Everything this file calls in other builders' files is made at runtime (1A.1): has_method +
# call, get / set. A missing hook is warned about once and the feature degrades.
#
# PUBLIC API
#   func setup(m: Node) -> void              registers the events, reads idolhost.flag
#   func holder_node() -> Node3D             Game.climber when I hold it and am alive (not
#                                            spectating, not mid-respawn); else the teammate's
#                                            remote_player node when alive, in this scene and
#                                            fresh (CoopSync.remote_players()); else null
#   func holder_sid() -> String              "" before the idol is taken
#   func holder_name() -> String
#   func passes() -> int                     COUNTED from the stored events every call (R17): the
#                                            idolpass_* entries with confirm false and orphan false
#   func weight() -> float                   W, seconds of weight (this PC's holder only, else draining)
#   func _test_hold_g(secs: float) -> void   tests: hold G for secs through the normal hold logic
#   func loop_ghost(key, data) -> void       loopback only (the map's coop_loop_ghost calls it,
#                                            deferred or direct): the Ghost answers an idolreq_<n>
#                                            addressed to "777" with an idolacc_<n> {_from "777"},
#                                            once per request (a repeat of the same n + "at" within
#                                            3 s is ignored, so a doubled route cannot answer twice)
#   var last_refusal / last_recv_refusal     {n, why} of the last idolno the authority / this PC as
#                                            the receiver sent (tests read them)
#   optional module methods the map calls: on_idol_taken, hud_idol, carrier_name, end_rows,
#   on_session_ended, loop_ghost, guestsim_report, on_exit
#
# HOLDING G (5.0 acceptance fix): while G stays held, "no friend in reach" and "it still clings"
#   only WAIT, with their banner; the 0.6 s push starts (or resumes, after a dropout under 0.25 s)
#   as soon as a friend is in reach and the idol lets go. Before, one frame out of reach ended the
#   hold, so a shove from a bite (15 m/s) in the middle of the push, or walking up to a friend with
#   G already held, never sent a request. Loopback only (the Ghost stands 3.5 m ahead of where you
#   were 0.7 s ago): receiver reach 6.0 m and host reach 7.5 m, the real 4.5 / 6.0 plus the same
#   1.5 m allowance PASS_REACH_LOOP adds. A real session is unchanged.
#
# EVENTS (contract 4; ids are Strings, R1)
#   idolreq_<n>   non-persistent, repeatable  {n, to, giver, giver_by, at}       giver -> receiver
#                 ("at": the giver's send msec, optional; only the loopback dedupe reads it)
#   idolacc_<n>   non-persistent, repeatable  {n, giver, giver_by, to, to_by}    receiver -> authority
#   idolno_<n>    non-persistent, repeatable  {n, to: giver, why}                why: cling|far|stale|dead|done
#   idolpass_<n>  persistent, once            {n, id, by, giver, giver_by, orphan, confirm}
#                 written by the authority only. n 1 is the authority's confirm of the "idol"
#                 touch (it settles two touches within network latency); real passes start at 2.
#                 The holder is the payload with the highest n (or the "idol" event if none).
#
# EVERY 0.25 s: CoopSync.hunt_pins["idol"] = holder_node(), CoopSync.idol_holder_sid, and (the
# authority) the orphan rule: a holder that is invalid for 4 s (and 12 s after the map loaded)
# passes to the living player nearest where the idol was last seen.
#
# THE WEIGHT (holder's PC only, never saved, never touches movement, rope or velocity)
#   builds 1.0 W/s with a living teammate (0.6 alone) while a hunter is within 70 m, drains
#   1.0 W/s when not holding, cap 60, reset on a co-op respawn and on every load.
#   heart_floor = clamp((W - 6) / 24), CoopSync.idol_weight = W / 40 in % (0..98), heavy banner
#   and breaths from W 12, a burn tick every 2 s from W 20 (0.6 s telegraph: idol_burn + the
#   lantern flare), take_damage(2 x min(2 + 0.3 (W - 20), 7)); with no living teammate a tick
#   that would take health below 35 is skipped. No burn while prevent_player_death (tests excepted).
#
# DEV TEST: maps/underdark/idolhost.flag ("" with loopback.flag, "solo", "race"), user marker
#   user://zonda_idolhost.txt across the reload. Tag [IDOLHOST], last line "test done N/N PASS".
#   The tester stands in the Nest and is bitten (and shoved) all through the weight phase, so the
#   pass to the Ghost holds G for up to 2.5 s and, when a hold ends without a pass, holds again
#   (like a player would) for up to 20 s: "[IDOLHOST] pass1 try N ended: ..." names each reason.
#   The Ghost's pass-backs retry the same way when only reach ("far") turned them down.
# ============================================================================================

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const MOD_DIR := "res://mods-unpacked/zonda-CoopSync/"
const TAG := "[IDOLHOST]"
const GHOST_SID := "777"

const PASS_REACH := 3.0
const PASS_REACH_LOOP := 4.5
const PASS_HOLD := 0.6
const G_LOST_GRACE := 0.25         # a friend out of reach this long restarts the 0.6 s push
const CLING_S := 0.0                # v5.1: no cling, a friend can pass it straight back
const THROW_TAP_S := 0.3            # G let go sooner than this = a throw; held longer = a hand-over
const THROW_SPEED := 13.5           # m/s forward along the view; with the lift, about 15 m on flat rock
const THROW_LIFT := 3.5             # m/s upward added to the throw
const THROW_GRAV := 9.8
const THROW_MAX_T := 4.0
const THROW_PIT_DROP := 30.0        # falling this far below the hand = the pit
const GRAB_R := 1.7                 # walk within this (flat) of a thrown idol to pick it up
const GRAB_DY := 2.4
const GRAB_HOST_REACH := 4.5        # the authority's check (lag allowance)
const GRAB_HOST_REACH_LOOP := 6.5
const GRAB_RESEND_MS := 800
const THROWER_GRAB_S := 2.0         # the thrower's own pickup is armed after this, or once 1 m clear
const WEEP_S := 15.0                # weeping this long, then the glow and the scream
const SCREAM_EVERY := 9.0           # it screams again this often while it lies there
const SFX_WEEP := ["idol_weep_403911.ogg", "idol_weep_359154.ogg"]
const SFX_SOB := "idol_sob_172738_1.ogg"
const SFX_SCREAM := ["idol_scream_333832_1.ogg", "idol_scream_469141_1.ogg"]
const OFFER_TIMEOUT := 2.5
const RECV_REACH := 4.5
const HOST_REACH := 6.0
const RECV_REACH_LOOP := 6.0       # loopback only: the Ghost lags 0.7 s, 3.5 m ahead
const HOST_REACH_LOOP := 7.5
const LOOP_DEDUPE_MS := 3000
const ORPHAN_S := 4.0
const ORPHAN_GRACE_S := 12.0
const SCENT_STINT_S := 12.0
const SCENT_GAP_S := 20.0
const W_CAP := 60.0
const W_HEAVY := 12.0
const W_BURN := 20.0
const HUNT_RANGE := 70.0
const BURN_EVERY := 2.0
const BURN_TELL := 0.6
const BURN_FLOOR := 35.0
const INTRO_DELAY := 6.5
const HELD_LAYER := 1 << 19
const GLOW_COLOR := Color(1.0, 0.1, 0.06)
const SFX_STING := "res://sfx/soundsnap/1144706.audio-Cinematic_Series_Designed_Trailer_Transition_Horror_01.wav"
const SFX_BREATH := "res://sfx/soundsnap/463323-HUMAN_BREATH_Female-Deep_Opened_Mouth_Normal_Speed_Breath-B.wav"
const SFX_BURN_FALLBACK := "res://sfx/soundsnap/monster_idle/306004-Creature-Oxbow-Breaths-Wet-Fast.wav"
const TEST_MARK := "user://zonda_idolhost.txt"

var map: Node = null
# replicated state, derived from ALL stored events whenever one arrives (R17)
var _seq := 0
var _holder_sid := ""
var _holder_by := ""
var _stint_ms := 0                 # this machine's own apply of the last holder change
var _last_scent_ms := -1000000
var _load_ms := 0
# giver side
var _pending: Dictionary = {}      # {n, to, to_by, ms}
# v5.1 the idol on the ground (from the stored events; every PC builds its own copy)
var _ground := false
var _ground_n := 0
var _ground_pos := Vector3.ZERO
var _ground_from := Vector3.ZERO
var _ground_pit := false
var _ground_fly := 0.0
var _ground_thrower := ""
var _ground_thrower_by := ""
var _ground_ms := 0                 # this PC: when it lands (the flight ends)
var _ground_node: Node3D = null     # the idol lying there (model, glow, sounds); the Nest's decoy after the scream
var _ground_glow: OmniLight3D = null
var _weep: AudioStreamPlayer3D = null
var _cry: AudioStreamPlayer3D = null
var _screamed := false
var _scream_t := 0.0
var _sob_t := 6.0
var _grab_sent_ms := -100000
var _grab_armed := false
var _throw_sent_ms := -100000
var _g_press_ms := 0
var _g_was_held := false
var _last_floor := Vector3.ZERO
var _has_last_floor := false
var _floor_t := 0.0
var throw_log: Array = []           # tests: [n, pos, pit, dist] per throw this PC sent
var scream_log: Array = []          # tests: msec per scream
var _g_held := false
var _g_done := false
var _g_t := 0.0
var _g_lost := 0.0                 # seconds the friend being pushed to has been out of reach
var _g_to := ""                    # the friend the push is going to (a new one restarts it)
var _g_msg_ms := -100000
var _test_hold := 0.0
var last_g_msg := ""
# authority side
var _orphan_since := -1
var _last_pos := Vector3.ZERO
var _has_last_pos := false
var _tick := 0.0
# the weight
var _w := 0.0
var _hunted := false
var _hunt_t := 0.0
var _hunt_d := INF
var _mates := 0
var _heavy_told := false
var _burn_told := false
var _breath_t := 3.0
var _burn_gap := 0.0
var _tick_left := -1.0
var _tell_until_ms := 0            # the burn telegraph's IdolGlow flare lasts until then
var _saw_dead := false
var _intro_left := -1.0
# nodes
var _sfx_breath: AudioStreamPlayer = null
var _sfx_burn: AudioStreamPlayer = null
var _glow: OmniLight3D = null
var _events_ok := false
var _warned: Dictionary = {}
var _cleaned := false
# test switches and logs (read by the dev test)
var _test_burn := false
var _test_force_hunted := false
var burn_log: Array = []           # [ms, damage] per burn tick
var tell_log: Array = []           # ms per burn telegraph
var scent_log: Array = []          # [n, ran] per real pass
var floor_skips := 0
var last_refusal: Dictionary = {}  # {n, why} of the last idolno the authority sent
var last_recv_refusal: Dictionary = {}   # {n, why} of the last idolno this PC sent as the receiver
var loop_answers := 0
var _loop_seen: Dictionary = {}    # "n:at" -> msec, the loopback requests the Ghost already answered


# ---------------------------------------------------------------- setup

func setup(m: Node) -> void:
	map = m
	_load_ms = Time.get_ticks_msec()
	if map != null and map.has_method("register_events"):
		map.call("register_events", ["idolreq_", "idolacc_", "idolno_", "idolthrow_", "idolgrab_"], Callable(self, "_on_net_event"), true)
		map.call("register_events", ["idolpass_"], Callable(self, "_on_pass_event"), false)
		_events_ok = true
	else:
		_warn("register_events", "the map has no register_events: the idol cannot be passed")
	_sfx_breath = AudioStreamPlayer.new()
	_sfx_breath.stream = load(SFX_BREATH)
	_sfx_breath.pitch_scale = 0.5
	_sfx_breath.volume_db = -14.0
	_sfx_breath.bus = &"MainBus" if AudioServer.get_bus_index("MainBus") >= 0 else &"Master"
	add_child(_sfx_breath)
	# the demon bus exists before a teammate first needs it (remote_player also ensures it)
	var vs = load(MOD_DIR + "voice.gd")
	if vs is Script:
		vs.call("ensure_demon_bus")
	_setup_test()


func _ready() -> void:
	set_process_unhandled_input(true)


func _warn(key: String, text: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning("%s %s" % [TAG, text])


# ---------------------------------------------------------------- small helpers

static func _b(v) -> bool:
	return v != null and bool(v)


func _sid(v) -> String:
	var s := ""
	if CoopSync.has_method("sid"):
		s = str(CoopSync.call("sid", v))
	elif v is String:
		s = v
	elif v is int:
		s = str(v)
	return "" if s == "0" else s


func _my_sid() -> String:
	if CoopSync.has_method("my_sid"):
		return str(CoopSync.call("my_sid"))
	var id := int(CoopSync.my_id())
	return str(id) if id != 0 else "local"


func _is_me(v) -> bool:
	var s := _sid(v)
	return s != "" and s == _my_sid()


func _name_of(s: String) -> String:
	if s == "":
		return "Nobody"
	if _is_me(s):
		return CoopSync.local_name
	if CoopSync.has_method("name_of"):
		return str(CoopSync.call("name_of", s))
	var pn = CoopSync.get("_peer_names")
	if pn is Dictionary and pn.has(int(s)):
		return str(pn[int(s)])
	return "A teammate"


func _events() -> Dictionary:
	if map == null:
		return {}
	var ev = CoopSync.map_events_for(str(map.get("scene_file_path")))
	return ev if ev is Dictionary else {}


func _taken() -> bool:
	if map == null:
		return false
	if map.has_method("idol_is_taken"):
		return _b(map.call("idol_is_taken"))
	return _b(map.get("_idol_taken"))


func _finished() -> bool:
	if map == null:
		return false
	if map.has_method("is_finished"):
		return _b(map.call("is_finished"))
	return _b(map.get("_finished"))


func _ss():
	var s = map.get("_ss") if map != null else null
	return s if is_instance_valid(s) and s is Node else null


func _brood():
	var b = map.get("_brood") if map != null else null
	return b if is_instance_valid(b) and b is Node else null


static func _local_alive(c) -> bool:
	return c != null and is_instance_valid(c) and c.is_inside_tree() and not _b(c.get("coop_spectating")) \
			and float(c.get("health")) > 0.0 and not _b(c.get("_coop_respawning"))


func _carrying() -> bool:
	return _holder_sid != "" and _is_me(_holder_sid) and _taken() and not _finished()


func _node_for_sid(s: String) -> Node3D:
	if s == "":
		return null
	if _is_me(s):
		var c = Game.climber
		return c if _local_alive(c) else null
	for rp in CoopSync.remote_players():
		if is_instance_valid(rp) and str(rp.peer_id) == s:
			return rp
	return null


func _stint_s() -> float:
	return float(Time.get_ticks_msec() - _stint_ms) / 1000.0


# ---------------------------------------------------------------- public API

func holder_node() -> Node3D:
	if _holder_sid == "" or not _taken():
		return null
	return _node_for_sid(_holder_sid)


func holder_sid() -> String:
	return _holder_sid


func holder_name() -> String:
	if _holder_sid == "":
		return ""
	if _is_me(_holder_sid):
		return CoopSync.local_name
	if _holder_by != "":
		return _holder_by
	return _name_of(_holder_sid)


func passes() -> int:
	return int(_derive_state(_events())["passes"])


func weight() -> float:
	return _w


func _test_hold_g(secs: float) -> void:
	_test_hold = maxf(secs, 0.05)
	_g_held = true
	_g_done = false
	_g_t = 0.0
	_g_lost = 0.0
	_g_to = ""
	_g_press_ms = Time.get_ticks_msec()


# ---------------------------------------------------------------- replicated state (R17)

func _derive_state(ev: Dictionary) -> Dictionary:
	# the holder is the idolpass payload with the highest n, else the "idol" event; passes are
	# counted, never incremented, so replay order and duplicates never matter
	var best_n := 0
	var best = null
	var count := 0
	for k in ev.keys():
		var ks := str(k)
		if not ks.begins_with("idolpass_"):
			continue
		var d = ev[k]
		if not (d is Dictionary):
			continue
		var n := int(d.get("n", ks.substr(9).to_int()))
		if n > best_n:
			best_n = n
			best = d
		if _counts_as_pass(d):
			count += 1
	var holder := ""
	var by := ""
	var ground := false
	if best != null:
		holder = _sid(best.get("id", ""))
		by = str(best.get("by", ""))
		ground = _b(best.get("ground", false))
	elif ev.get("idol") is Dictionary:
		var idd: Dictionary = ev["idol"]
		by = str(idd.get("by", ""))
		holder = _sid(idd.get("id", ""))
		if holder == "" and by == CoopSync.local_name:
			holder = _my_sid()                 # a pre-5.0 "idol" without a usable id: by name
	return {"seq": best_n, "holder": "" if ground else holder, "by": by, "passes": count,
			"ground": ground, "best": best if best != null else {}}


static func _counts_as_pass(d: Dictionary) -> bool:
	# a hand pass, or a thrown idol caught by someone else than the thrower (v5.1)
	if _b(d.get("confirm", false)) or _b(d.get("orphan", false)) or _b(d.get("ground", false)):
		return false
	if _b(d.get("pickup", false)):
		var th := str(d.get("thrower", ""))
		return th != "" and th != str(d.get("id", ""))
	return true


static func _v3(a, fallback: Vector3 = Vector3.ZERO) -> Vector3:
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	if a is Vector3:
		return a
	return fallback


static func _arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]


func _has_pass_stored() -> bool:
	for k in _events().keys():
		if str(k).begins_with("idolpass_"):
			return true
	return false


func _refresh(extra_key: String = "", extra_data = null) -> void:
	var ev := _events()
	if extra_key != "" and extra_data is Dictionary and not ev.has(extra_key):
		ev = ev.duplicate()
		ev[extra_key] = extra_data
	var st := _derive_state(ev)
	_seq = int(st["seq"])
	_holder_by = str(st["by"])
	_set_ground(bool(st["ground"]), st["best"] if st["best"] is Dictionary else {}, _seq)
	var h := str(st["holder"])
	if h != _holder_sid:
		_holder_sid = h
		_stint_ms = Time.get_ticks_msec()
		_orphan_since = -1
		var hn := _node_for_sid(h)
		if hn != null:
			_last_pos = hn.global_position     # the idol is where its new holder stands
			_has_last_pos = true
		if _is_me(h):
			_heavy_told = false
			_burn_told = false
			_burn_gap = 0.0
			_tick_left = -1.0
	_apply_mine()


func _apply_mine() -> void:
	# the map shows the idol in your hand while _idol_mine; the holder decides it
	if map == null or not _taken():
		return
	var want := _holder_sid != "" and _is_me(_holder_sid)
	if _b(map.get("_idol_mine")) == want:
		return
	if map.has_method("set_idol_mine"):
		map.call("set_idol_mine", want)
	else:
		_warn("set_idol_mine", "the map has no set_idol_mine: setting _idol_mine directly")
		map.set("_idol_mine", want)
		if not want:
			CoopSync.idol_carrier = false
			var held = map.get("_held_idol")
			if is_instance_valid(held) and held is Node:
				held.queue_free()


# ---------------------------------------------------------------- map hooks

func on_idol_taken(data: Dictionary, replay: bool) -> void:
	_refresh("idol", data)
	# the authority confirms the first touch (live and on replay: a crash between the two writes,
	# or a guest that became the authority). Guests never write it.
	if CoopSync.map_is_authority() and not _has_pass_stored():
		call_deferred("_write_confirm")
	if not replay:
		_intro_left = INTRO_DELAY


func _write_confirm() -> void:
	if not CoopSync.map_is_authority() or not _taken() or _has_pass_stored():
		return
	var d = _events().get("idol", {})
	if not (d is Dictionary):
		d = {}
	var id := _sid(d.get("id", ""))
	var by := str(d.get("by", ""))
	if id == "":
		id = _my_sid()
	if by == "":
		by = _name_of(id)
	print("%s confirm idolpass_1 holder=%s" % [TAG, id])
	CoopSync.map_event("idolpass_1", {"n": 1, "id": id, "by": by, "giver": "", "giver_by": "",
			"orphan": false, "confirm": true}, true)


func hud_idol() -> String:
	if not _taken():
		return ""
	if _ground:
		return "   idol: on the ground (screaming)" if _screamed else "   idol: on the ground"
	if _holder_sid == "":
		return ""
	if not _is_me(_holder_sid):
		return "   idol: %s" % holder_name()
	var s := "   idol: you"
	if _finished():
		return s
	if _w >= W_BURN:
		s += " (burning)"
	elif _w >= W_HEAVY:
		s += " (heavy)"
	return s


func carrier_name() -> String:
	if not _taken():
		return ""
	if _ground:
		return _ground_thrower_by
	return holder_name()


func on_ground() -> bool:
	# v5.1: the idol lies where it was thrown (nobody holds it)
	return _ground and _taken() and not _finished()


func prey_node() -> Node3D:
	# v5.1: what the Nest hunts: the holder; with the idol on the ground the last thrower, and
	# after the scream the idol itself (a decoy node with meta "zonda_pin_decoy")
	if not _taken() or _finished():
		return null
	if not _ground:
		return holder_node()
	if _screamed and is_instance_valid(_ground_node) and _ground_node.is_inside_tree():
		return _ground_node
	return _node_for_sid(_ground_thrower)


func end_rows() -> Array:
	if not _taken():
		return []
	# the carrier already has its own row on the map's card ("Idol carried by", from carrier_name())
	var col := Color(0.92, 0.88, 0.8)
	var n := passes()
	return [
		["Idol passed   %d %s" % [n, "time" if n == 1 else "times"], 11, col],
	]


func on_session_ended() -> void:
	_pending = {}
	_orphan_since = -1
	# a guest that is now the authority: confirm a touch nobody confirmed, and the orphan rule
	# (below) hands an idol whose holder left to the nearest living player
	if CoopSync.map_is_authority() and _taken() and not _has_pass_stored():
		call_deferred("_write_confirm")


func loop_ghost(key: String, data: Dictionary) -> void:
	# loopback only: the Ghost answers an idolreq addressed to it, like a receiver would
	if not key.begins_with("idolreq_") or str(data.get("to", "")) != GHOST_SID:
		return
	var n := int(data.get("n", key.substr(8).to_int()))
	# one answer per request: a retry reuses n with a new "at", a doubled route repeats both
	var now := Time.get_ticks_msec()
	var rk := "%d:%s" % [n, str(data.get("at", ""))]
	for k in _loop_seen.keys():
		if now - int(_loop_seen[k]) > LOOP_DEDUPE_MS:
			_loop_seen.erase(k)
	if _loop_seen.has(rk):
		print("%s loop: idolreq_%d already answered, ignored" % [TAG, n])
		return
	_loop_seen[rk] = now
	loop_answers += 1
	print("%s loop: the Ghost takes idolreq_%d" % [TAG, n])
	var d := {"n": n, "giver": str(data.get("giver", "")), "giver_by": str(data.get("giver_by", "")),
			"to": GHOST_SID, "to_by": "Ghost", "_from": GHOST_SID}
	if CoopSync.has_method("_apply_map_event") and map != null:
		CoopSync.call("_apply_map_event", str(map.get("scene_file_path")), "idolacc_%d" % n, d, false, false)


func on_exit() -> void:
	_cleanup()


func _exit_tree() -> void:
	_cleanup()


func _cleanup() -> void:
	if _cleaned:
		return
	_cleaned = true
	CoopSync.set("idol_holder_sid", "")
	CoopSync.set("idol_weight", 0)
	var pins = CoopSync.get("hunt_pins")
	if pins is Dictionary:
		pins.erase("idol")
	var ss = _ss()
	if ss != null:
		ss.set("heart_floor", 0.0)
	_free_ground_node()


func guestsim_report() -> Array:
	var ev := _events()
	var out: Array = []
	if not ev.has("idol"):
		out.append("SKIP no idol in the recording")
	else:
		# what the stored events say, worked out here on its own, against the live state
		var best_n := 0
		var exp_holder := ""
		var exp_passes := 0
		for k in ev.keys():
			var ks := str(k)
			if ks.begins_with("idolpass_") and ev[k] is Dictionary:
				var d: Dictionary = ev[k]
				var n := int(d.get("n", ks.substr(9).to_int()))
				if n > best_n:
					best_n = n
					exp_holder = _sid(d.get("id", ""))
				if not _b(d.get("confirm", false)) and not _b(d.get("orphan", false)):
					exp_passes += 1
		if best_n == 0 and ev["idol"] is Dictionary:
			exp_holder = _sid(ev["idol"].get("id", ""))
		var mine := _b(map.get("_idol_mine")) if map != null else false
		var ok := _holder_sid == exp_holder and mine == _is_me(exp_holder) and passes() == exp_passes and _seq == best_n
		out.append("%s holder=%s mine=%s passes=%d" % ["PASS" if ok else "FAIL", _holder_sid, str(mine), passes()])
	# the touch race, through the same state code the live game uses: my own "idol", then the
	# authority's confirm naming the Ghost
	var syn := {"idol": {"by": CoopSync.local_name, "id": _my_sid()},
			"idolpass_1": {"n": 1, "id": GHOST_SID, "by": "Ghost", "giver": "", "giver_by": "", "orphan": false, "confirm": true}}
	var st := _derive_state(syn)
	var conv := str(st["holder"]) == GHOST_SID and not _is_me(st["holder"]) and int(st["passes"]) == 0
	out.append(("PASS confirm converges" if conv else "FAIL confirm converges holder=%s passes=%d" % [str(st["holder"]), int(st["passes"])]))
	return out


# ---------------------------------------------------------------- events

func _on_net_event(key: String, data: Dictionary, replay: bool) -> void:
	if replay:
		return                               # never stored, so never replayed; just in case
	if key.begins_with("idolreq_"):
		_on_req(data)
	elif key.begins_with("idolthrow_"):
		_on_throw(data)
	elif key.begins_with("idolgrab_"):
		_on_grab(data)
	elif key.begins_with("idolacc_"):
		_on_acc(data)
	elif key.begins_with("idolno_"):
		_on_no(data)


func _on_req(data: Dictionary) -> void:
	# the receiver: the idol cannot be refused, this only checks it CAN be taken
	if not _is_me(data.get("to", "")):
		return
	var n := int(data.get("n", 0))
	var giver := _sid(data.get("giver", ""))
	var why := ""
	var c = Game.climber
	var inv = c.get("_coop_invuln_until_ms") if c != null and is_instance_valid(c) else null
	var invuln: bool = inv != null and Time.get_ticks_msec() < int(inv)
	if not _local_alive(c) or invuln:
		why = "dead"
	elif _finished():
		why = "done"
	elif n != _seq + 1 or giver != _holder_sid or _ground:
		why = "stale"
	else:
		var gn := _node_for_sid(giver)
		var reach := RECV_REACH_LOOP if _b(CoopSync.get("_loopback")) else RECV_REACH
		if gn == null or _flat_dist(gn.global_position, c.global_position, 2.5) > reach:
			why = "far"
	if why == "":
		CoopSync.map_event("idolacc_%d" % n, {"n": n, "giver": giver, "giver_by": str(data.get("giver_by", "")),
				"to": _my_sid(), "to_by": CoopSync.local_name}, false)
	else:
		last_recv_refusal = {"n": n, "why": why}
		print("%s cannot take idolreq_%d: %s" % [TAG, n, why])
		CoopSync.map_event("idolno_%d" % n, {"n": n, "to": giver, "why": why}, false)


func _on_acc(data: Dictionary) -> void:
	# the authority: validate and write the persistent result
	if not CoopSync.map_is_authority():
		return
	var n := int(data.get("n", 0))
	var to := _sid(data.get("to", ""))
	var from := str(data.get("_from", _my_sid()))
	var giver := _sid(data.get("giver", ""))
	var why := ""
	if _finished():
		why = "done"
	elif n != _seq + 1 or from != to or giver != _holder_sid or to == "" or to == giver or _ground:
		why = "stale"
	else:
		var rn := _node_for_sid(to)
		var gn := _node_for_sid(giver)
		var reach := HOST_REACH_LOOP if _b(CoopSync.get("_loopback")) else HOST_REACH
		if rn == null:
			why = "dead"
		elif gn == null or gn.global_position.distance_to(rn.global_position) > reach:
			why = "far"
		elif _stint_s() < CLING_S:
			why = "cling"
	if why != "":
		last_refusal = {"n": n, "why": why}
		print("%s refused pass n=%d from %s to %s: %s (stint %.1f s)" % [TAG, n, giver, to, why, _stint_s()])
		CoopSync.map_event("idolno_%d" % n, {"n": n, "to": giver, "why": why}, false)
		return
	CoopSync.map_event("idolpass_%d" % n, {"n": n, "id": to, "by": str(data.get("to_by", "")), "giver": giver,
			"giver_by": str(data.get("giver_by", "")), "orphan": false, "confirm": false}, true)


func _on_no(data: Dictionary) -> void:
	if not _is_me(data.get("to", "")):
		return
	var n := int(data.get("n", 0))
	if _pending.is_empty() or int(_pending.get("n", -1)) != n:
		return
	var who := str(_pending.get("to_by", "Your friend"))
	_pending = {}
	print("%s idolreq_%d refused: %s" % [TAG, n, str(data.get("why", ""))])
	CoopSync.show_banner("%s could not take the idol." % who, 3.0)


func _on_pass_event(key: String, data: Dictionary, replay: bool) -> void:
	var n := int(data.get("n", key.substr(9).to_int()))
	var before_seq := _seq
	var before := _holder_sid
	var before_name := holder_name()
	var stint := _stint_s()
	_refresh(key, data)
	if not _pending.is_empty() and n >= int(_pending.get("n", 0)):
		_pending = {}
	if replay or n <= before_seq or n != _seq:
		return                               # the end state only (replay, stale or superseded)
	var me_before := before != "" and _is_me(before)
	var me_now := _is_me(_holder_sid)
	if _b(data.get("confirm", false)):
		if me_before and not me_now:
			CoopSync.show_banner("%s got to the idol first." % holder_name(), 4.0)
		return
	if _b(data.get("ground", false)):
		_announce_throw(data, me_before)
		return
	if _b(data.get("pickup", false)):
		_announce_pickup(data, me_now)
		return
	if _holder_sid == before:
		return
	var new_name := holder_name()
	if _b(data.get("orphan", false)):
		print("%s orphan pass n=%d: %s -> %s" % [TAG, n, before, _holder_sid])
		CoopSync.show_banner("The idol leaves %s and finds a new host: %s." % [before_name, "you" if me_now else new_name], 5.0)
		if me_now and Game.audio != null:
			Game.audio.play_dark_transition2()
		return
	var giver := _sid(data.get("giver", ""))
	var giver_by := str(data.get("giver_by", ""))
	if giver_by == "":
		giver_by = _name_of(giver)
	print("%s pass n=%d: %s -> %s (stint %.1f s)" % [TAG, n, giver, _holder_sid, stint])
	if _is_me(giver):
		CoopSync.show_banner("%s has the idol now. It hunts them." % new_name, 5.0)
	elif me_now:
		CoopSync.show_banner("%s pushed the idol into your hands. Everything in the Nest hunts you now." % giver_by, 5.0)
		if Game.audio != null:
			Game.audio.play_dark_transition2()
	else:
		CoopSync.show_banner("%s passed the idol to %s." % [giver_by, new_name], 4.0)
	_play_sting(_node_for_sid(giver), _node_for_sid(_holder_sid))
	var br = _brood()
	if br != null and br.has_method("scent_hiss"):
		br.call("scent_hiss")
	# the Nest loses the scent for a second, but only after a real stint and not too often:
	# passing back and forth every 6 s can never freeze it
	var ran := false
	if CoopSync.map_is_authority() and stint >= SCENT_STINT_S and Time.get_ticks_msec() - _last_scent_ms >= int(SCENT_GAP_S * 1000.0):
		ran = true
		_last_scent_ms = Time.get_ticks_msec()
		if br != null and br.has_method("lose_scent"):
			br.call("lose_scent", 1.0)
		elif br != null:
			_warn("lose_scent", "the brood has no lose_scent")
	scent_log.append([n, ran])


func _play_sting(a: Node3D, b: Node3D) -> void:
	var pos := Vector3.ZERO
	if a != null and b != null:
		pos = (a.global_position + b.global_position) * 0.5
	elif a != null:
		pos = a.global_position
	elif b != null:
		pos = b.global_position
	else:
		return
	var st = load(SFX_STING)
	if not (st is AudioStream):
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = st
	p.volume_db = -10.0
	p.pitch_scale = 0.85
	p.max_distance = 40.0
	p.unit_size = 8.0
	p.bus = &"ZondaCave" if AudioServer.get_bus_index("ZondaCave") >= 0 else &"MainBus"
	p.position = pos
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()


# ---------------------------------------------------------------- per frame

func _unhandled_input(event: InputEvent) -> void:
	# G while you carry passes the idol and never pours oil (lantern.gd has the same guard)
	if not (event is InputEventKey) or event.echo:
		return
	var k := event as InputEventKey
	if k.keycode != KEY_G and k.physical_keycode != KEY_G:
		return
	if not _carrying():
		return
	if k.pressed:
		if not _g_held:
			_g_held = true
			_g_done = false
			_g_t = 0.0
			_g_lost = 0.0
			_g_to = ""
			_g_press_ms = Time.get_ticks_msec()
	else:
		_g_held = false
	get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _holder_sid == "" and _w <= 0.0 and _intro_left < 0.0 and not _taken() and not _ground:
		return                                   # nothing to do before the idol is taken
	var t0 := Time.get_ticks_usec()
	var now := Time.get_ticks_msec()
	var c = Game.climber
	var alive := _local_alive(c)
	_mates = CoopSync.remote_players().size()
	_update_intro(delta)
	_update_g(delta, c, alive)
	_update_floor(delta, c, alive)
	_update_ground(delta, now)
	_update_grab(c, alive, now)
	_update_pending(now)
	_update_weight(delta, c, alive)
	_update_burn(delta, c, alive)
	_update_glow(now)
	_tick -= delta
	if _tick <= 0.0:
		_tick = 0.25
		_update_pins()
		_check_orphan(now)
	CoopSync.perf_add(Time.get_ticks_usec() - t0)


func _update_intro(delta: float) -> void:
	if _intro_left < 0.0:
		return
	_intro_left -= delta
	if _intro_left > 0.0:
		return
	_intro_left = -1.0
	if _finished():
		return
	if _mates > 0:
		CoopSync.show_banner("The idol wants a host. Whoever holds it is hunted. Hold G next to a friend to pass it, tap G to throw it.", 7.0)
	else:
		CoopSync.show_banner("The idol wants a host. Everything in the Nest hunts you. Get it out. Tap G to throw it.", 6.0)


func _g_banner(text: String) -> void:
	last_g_msg = text
	var now := Time.get_ticks_msec()
	if now - _g_msg_ms > 1500:
		_g_msg_ms = now
		CoopSync.show_banner(text, 2.5)


func _update_g(delta: float, c, alive: bool) -> void:
	if not _carrying():
		_g_held = false
		_g_was_held = false
		_g_t = 0.0
		_g_lost = 0.0
		_g_to = ""
		_test_hold = 0.0
		return
	if _test_hold > 0.0:
		_test_hold -= delta
		if _test_hold <= 0.0:
			_g_held = false
	elif _g_held:
		var down := Input.is_physical_key_pressed(KEY_G) or Input.is_key_pressed(KEY_G)
		if not down or not DisplayServer.window_is_focused():
			_g_held = false                  # a missed key-up (focus moved away) never keeps it held
	# v5.1: G let go within 0.3 s (and nothing else started) is a throw
	if _g_was_held and not _g_held and not _g_done:
		if float(Time.get_ticks_msec() - _g_press_ms) < THROW_TAP_S * 1000.0 and alive and _pending.is_empty():
			_g_done = true
			_throw(c)
	_g_was_held = _g_held
	if not _g_held or _g_done:
		_g_t = 0.0
		_g_lost = 0.0
		_g_to = ""
		return
	if not alive or not _pending.is_empty():
		_g_done = true
		return
	if float(Time.get_ticks_msec() - _g_press_ms) < THROW_TAP_S * 1000.0:
		return                               # still a tap: the throw or the hand-over decides on release
	if _mates <= 0:
		_g_done = true
		_g_banner("There is no one to take it. Get it out, or tap G to throw it.")
		return
	# While G stays held, being out of reach or inside the cling only waits: the push starts as
	# soon as a friend is in reach and the idol lets go. A shove (a bite throws you about 15 m/s),
	# a stumble or walking up with G already held no longer ends the hold without a request.
	var rp = _nearest_mate(c)
	if rp == null:
		_g_lost += delta
		if _g_lost > G_LOST_GRACE or _g_to == "":
			_g_t = 0.0
			_g_to = ""
			_g_banner("Stand next to a friend (3 m) and hold G to pass the idol.")
		return
	_g_lost = 0.0
	var to := str(rp.peer_id)
	if to != _g_to:
		_g_to = to
		_g_t = 0.0                           # a different friend in reach: the push starts over
	_g_t += delta
	CoopSync.show_banner("Pushing the idol into %s's hands...  keep holding G" % str(rp.player_name), 0.3)
	if _g_t >= PASS_HOLD:
		_g_done = true
		_send_request(rp)


func _nearest_mate(c):
	var ln = CoopSync.lantern
	if is_instance_valid(ln) and ln.has_method("_nearest_teammate"):
		return ln.call("_nearest_teammate", c)
	var reach := PASS_REACH_LOOP if _b(CoopSync.get("_loopback")) else PASS_REACH
	var best = null
	for r in CoopSync.remote_players():
		var d := _flat_dist(r.global_position, c.global_position, 2.0)
		if d <= reach:
			reach = d
			best = r
	return best


static func _flat_dist(a: Vector3, b: Vector3, max_dy: float) -> float:
	# side by side: the flat distance, with up to max_dy of height ignored (a remote knight's
	# origin sits 0.78 m above its feet)
	var d := a - b
	if absf(d.y) > max_dy:
		return INF
	return Vector2(d.x, d.z).length()


func _send_request(rp) -> void:
	var n := _seq + 1
	var to := str(rp.peer_id)
	var now := Time.get_ticks_msec()
	_pending = {"n": n, "to": to, "to_by": str(rp.player_name), "ms": now}
	print("%s request idolreq_%d to %s" % [TAG, n, to])
	CoopSync.map_event("idolreq_%d" % n, {"n": n, "to": to, "giver": _my_sid(), "giver_by": CoopSync.local_name,
			"at": now}, false)


func _update_pending(now: int) -> void:
	if _pending.is_empty():
		return
	if now - int(_pending.get("ms", now)) > int(OFFER_TIMEOUT * 1000.0):
		var who := str(_pending.get("to_by", "Your friend"))
		print("%s idolreq_%d timed out" % [TAG, int(_pending.get("n", 0))])
		_pending = {}
		CoopSync.show_banner("%s could not take the idol." % who, 3.0)


func _update_weight(delta: float, c, alive: bool) -> void:
	var carrying := _carrying()
	if c != null and is_instance_valid(c):
		# a co-op respawn (health seen at 0, then above 0) starts the weight again; an invincible
		# player (prevent_player_death, the tests) never dies, so a burst of bites to 0 is no respawn
		if float(c.get("health")) <= 0.0 and not _b(c.get("prevent_player_death")):
			_saw_dead = true
		elif _saw_dead:
			_saw_dead = false
			_w = 0.0
			_burn_gap = 0.0
			_tick_left = -1.0
	if carrying and alive:
		_hunt_t -= delta
		if _hunt_t <= 0.0:
			_hunt_t = 0.25
			_hunt_d = _nearest_hunter(c.global_position)
			_hunted = _test_force_hunted or _hunt_d <= HUNT_RANGE
		if _hunted:
			_w = minf(W_CAP, _w + (1.0 if _mates > 0 else 0.6) * delta)
	else:
		_hunted = false
		_w = maxf(0.0, _w - delta)
	CoopSync.set("idol_weight", int(clampf(_w / 40.0 * 100.0, 0.0, 98.0)) if carrying else 0)
	var ss = _ss()
	if ss != null:
		ss.set("heart_floor", clampf((_w - 6.0) / 24.0, 0.0, 1.0))
	if carrying and alive and _w >= W_HEAVY:
		if not _heavy_told:
			_heavy_told = true
			if _mates > 0:
				CoopSync.show_banner("The idol grows heavy. Pass it on: stand next to a friend and hold G.", 5.0)
			else:
				CoopSync.show_banner("The idol grows heavy. Get it out of here.", 5.0)
		_breath_t -= delta
		if _breath_t <= 0.0:
			_breath_t = randf_range(7.0, 10.0)
			if is_instance_valid(_sfx_breath) and _sfx_breath.stream != null and _sfx_breath.is_inside_tree():
				_sfx_breath.play()
	else:
		_breath_t = minf(_breath_t, 2.0)


func _burn_damage(w: float) -> float:
	# what take_damage is given (the game halves it)
	return 2.0 * minf(2.0 + 0.3 * maxf(w - W_BURN, 0.0), 7.0)


func _floor_blocks(c, dmg: float) -> bool:
	# with no living teammate (solo, or the last one alive) the idol never burns you below 35
	if _mates > 0:
		return false
	var loss := dmg * 0.5
	var bs = Game.get("active_balance_settings")
	if bs != null and bs.get("damage_multiplier") != null:
		loss *= float(bs.get("damage_multiplier")) * 0.01
	return float(c.get("health")) - loss < BURN_FLOOR


func _update_burn(delta: float, c, alive: bool) -> void:
	var allowed := _carrying() and alive and (not _b(c.get("prevent_player_death")) or _test_burn)
	if not allowed:
		_tick_left = -1.0
		_tell_until_ms = 0
		_burn_gap = 0.0
		return
	if _tick_left >= 0.0:
		_tick_left -= delta
		if _tick_left <= 0.0:
			_tick_left = -1.0
			_burn_gap = BURN_EVERY - BURN_TELL
			_burn_tick(c)
		return
	var rate := ((1.0 if _mates > 0 else 0.6) if _hunted else 0.0)
	if _w + rate * BURN_TELL < W_BURN:
		_burn_gap = 0.0
		return
	_burn_gap -= delta
	if _burn_gap > 0.0:
		return
	if _floor_blocks(c, _burn_damage(_w + rate * BURN_TELL)):
		floor_skips += 1
		_burn_gap = BURN_EVERY
		return
	# the telegraph, 0.6 s before the tick (R9): a sizzle, the idol's own red glow flares (seen with
	# the lantern off or dry too) and the lantern flares
	_tick_left = BURN_TELL
	_tell_until_ms = Time.get_ticks_msec() + int(BURN_TELL * 1000.0)
	tell_log.append(Time.get_ticks_msec())
	_play_burn_tell(c.global_position)
	var ln = CoopSync.lantern
	if is_instance_valid(ln) and ln.has_method("curse_flare"):
		ln.call("curse_flare")


func _burn_tick(c) -> void:
	var dmg := _burn_damage(_w)
	if _floor_blocks(c, dmg):
		floor_skips += 1
		return
	c.take_damage(dmg)
	burn_log.append([Time.get_ticks_msec(), dmg, _w])
	if not _burn_told:
		_burn_told = true
		CoopSync.show_banner("The idol burns you. Pass it on." if _mates > 0 else "The idol burns you. Get it out.", 4.0)


func _play_burn_tell(pos: Vector3) -> void:
	var ss = _ss()
	if ss != null and ss.has_method("has_oneshot") and ss.has_oneshot("idol_burn"):
		ss.play_oneshot("idol_burn", pos)
		return
	# the kind is not installed: the documented game-file fallback (contract 2.10)
	if _sfx_burn == null:
		_sfx_burn = AudioStreamPlayer.new()
		_sfx_burn.stream = load(SFX_BURN_FALLBACK)
		_sfx_burn.pitch_scale = 0.6
		_sfx_burn.volume_db = -6.0
		_sfx_burn.bus = &"ZondaCave" if AudioServer.get_bus_index("ZondaCave") >= 0 else &"MainBus"
		add_child(_sfx_burn)
	if _sfx_burn.stream != null and _sfx_burn.is_inside_tree():
		_sfx_burn.play()


func _update_glow(now: int) -> void:
	# the idol in your own hand glows red and pulses with your heartbeat
	if not _carrying() or map == null:
		return
	var held = map.get("_held_idol")
	if not is_instance_valid(held) or not (held is Node3D):
		return
	if _glow == null or not is_instance_valid(_glow) or _glow.get_parent() != held:
		_glow = held.get_node_or_null("IdolGlow") as OmniLight3D
		if _glow == null:
			_glow = OmniLight3D.new()
			_glow.name = "IdolGlow"
			_glow.light_color = GLOW_COLOR
			_glow.light_energy = 0.35
			_glow.omni_range = 4.0
			_glow.shadow_enabled = false
			_glow.light_cull_mask = ~HELD_LAYER
			_glow.set_meta("zonda_no_shadow", true)
			_glow.set_meta("zonda_keep", true)
			_glow.set_meta("zonda_not_real_light", true)
			held.add_child(_glow)
	var beat := -100000
	var ss = _ss()
	if ss != null and ss.get("last_beat_ms") != null:
		beat = int(ss.get("last_beat_ms"))
	var e := 0.35 * (0.8 + 0.2 * exp(-float(now - beat) / 180.0))
	var rng := 4.0
	if now < _tell_until_ms:
		# the burn telegraph (R9): the glow swells to about 1.0 over the 0.6 s wind-up, then drops
		# back to the heartbeat pulse at the tick
		var k := clampf(1.0 - float(_tell_until_ms - now) / (BURN_TELL * 1000.0), 0.0, 1.0)
		var f := 0.6 + 0.4 * k
		e = lerpf(e, 1.0, f)
		rng = 4.0 + 2.0 * f
	_glow.light_energy = e
	_glow.omni_range = rng


func _update_pins() -> void:
	var taken := _taken()
	var hn: Node3D = prey_node() if (taken and not _finished()) else null
	var pins = CoopSync.get("hunt_pins")
	if pins is Dictionary:
		if hn != null:
			pins["idol"] = hn
		else:
			pins.erase("idol")
	CoopSync.set("idol_holder_sid", _holder_sid if taken else "")
	if hn != null and not _ground:
		_last_pos = hn.global_position
		_has_last_pos = true


func _check_orphan(now: int) -> void:
	# the authority moves an idol whose holder is spectating, has left or has gone stale
	if not CoopSync.map_is_authority() or not _taken() or _finished() or _ground:
		_orphan_since = -1
		return
	if holder_node() != null:
		_orphan_since = -1
		return
	if _orphan_since < 0:
		_orphan_since = now
	if now - _orphan_since < int(ORPHAN_S * 1000.0) or now - _load_ms < int(ORPHAN_GRACE_S * 1000.0):
		return
	var from := _last_pos
	if not _has_last_pos and _local_alive(Game.climber):
		from = Game.climber.global_position
	var best_sid := ""
	var best_name := ""
	var bd := INF
	var c = Game.climber
	if _local_alive(c):
		bd = from.distance_to(c.global_position)
		best_sid = _my_sid()
		best_name = CoopSync.local_name
	for rp in CoopSync.remote_players():
		if not is_instance_valid(rp) or str(rp.peer_id) == _holder_sid:
			continue
		var d: float = from.distance_to(rp.global_position)
		if d < bd:
			bd = d
			best_sid = str(rp.peer_id)
			best_name = str(rp.player_name)
	if best_sid == "" or best_sid == _holder_sid:
		return
	var n := _seq + 1
	_orphan_since = -1
	print("%s orphan: %s is gone, idolpass_%d -> %s" % [TAG, _holder_sid, n, best_sid])
	CoopSync.map_event("idolpass_%d" % n, {"n": n, "id": best_sid, "by": best_name, "giver": _holder_sid,
			"giver_by": holder_name(), "orphan": true, "confirm": false}, true)


func _nearest_hunter(p: Vector3) -> float:
	# the weight builds only while something that hunts the idol is within 70 m
	var best := INF
	var groups = map.get("hunt_pin_groups") if map != null else null
	if CoopSync.map_is_authority():
		for cent in Game.centipedes:
			if not is_instance_valid(cent) or not (cent is Node3D) or not cent.is_inside_tree():
				continue
			if _b(cent.get("coop_puppet")) or not _pinned(cent, groups):
				continue
			if not cent.visible or cent.process_mode == Node.PROCESS_MODE_DISABLED:
				continue
			best = minf(best, p.distance_to(cent.global_position))
	else:
		var by_cid = CoopSync.get("_puppet_by_cid")
		if by_cid is Dictionary:
			for cid in by_cid.keys():
				if not _in_groups(str(cid).get_slice(":", 0), groups):
					continue
				var pup = by_cid[cid]
				if is_instance_valid(pup) and pup is Node3D and pup.visible:
					best = minf(best, p.distance_to(pup.global_position))
	var br = _brood()
	if br != null and br.has_method("threat_positions"):
		for q in br.call("threat_positions"):
			if q is Vector3:
				best = minf(best, p.distance_to(q))
	return best


func _pinned(cent: Node, groups) -> bool:
	if str(cent.get_meta("zonda_hunt_pin", "")) == "idol":
		return true
	return cent.has_meta("zonda_cid") and _in_groups(str(cent.get_meta("zonda_cid")).get_slice(":", 0), groups)


static func _in_groups(prefix: String, groups) -> bool:
	if groups is Dictionary:
		return (groups as Dictionary).has(prefix)
	if groups is Array:
		return (groups as Array).has(prefix)
	return false


# ---------------------------------------------------------------- v5.1 throw, ground, pickup

func _space():
	var c = Game.climber
	if c != null and is_instance_valid(c) and c.is_inside_tree():
		return c.get_world_3d().direct_space_state
	if map != null and map is Node3D and (map as Node3D).is_inside_tree():
		return (map as Node3D).get_world_3d().direct_space_state
	return null


func _ray(space, a: Vector3, b: Vector3, skip: Array = []) -> Dictionary:
	if space == null:
		return {}
	var q := PhysicsRayQueryParameters3D.create(a, b, 1, skip)
	return space.intersect_ray(q)


func _floor_under(space, p: Vector3, up: float, down: float, skip: Array = []) -> Dictionary:
	# a walkable floor under p (normal pointing up), or {}
	var hit := _ray(space, p + Vector3.UP * up, p + Vector3.DOWN * down, skip)
	if hit.is_empty() or (hit["normal"] as Vector3).y < 0.55:
		return {}
	return hit


func _update_floor(delta: float, c, alive: bool) -> void:
	# the last spot this PC stood on solid floor: where a throw into the pit comes back up
	if not alive or not _carrying():
		return
	_floor_t -= delta
	if _floor_t > 0.0:
		return
	_floor_t = 0.2
	var space = _space()
	var hit := _floor_under(space, c.global_position, 0.3, 2.6, [c.get_rid()])
	if not hit.is_empty():
		_last_floor = hit["position"]
		_has_last_floor = true


func _plan_throw(c) -> Dictionary:
	# the arc from the eye along the view: 13.5 m/s forward + 3.5 m/s up, rock stops it. A wall or
	# ceiling hit drops it to the floor below; no floor within 30 m under the hand = the pit
	var space = _space()
	var cam = c.get("Camera")
	var eye: Vector3 = (cam as Node3D).global_position if cam is Node3D else c.global_position + Vector3.UP * 1.5
	var fwd: Vector3 = -(cam as Node3D).global_transform.basis.z if cam is Node3D else -c.global_transform.basis.z
	fwd = fwd.normalized()
	var skip := [c.get_rid()]
	var p := eye + fwd * 0.5
	var vel := fwd * THROW_SPEED + Vector3.UP * THROW_LIFT
	var t := 0.0
	var dt := 1.0 / 30.0
	var rest = null
	while t < THROW_MAX_T:
		var q := p + vel * dt
		vel.y -= THROW_GRAV * dt
		t += dt
		var hit := _ray(space, p, q, skip)
		if not hit.is_empty():
			var hp: Vector3 = hit["position"]
			var hn: Vector3 = hit["normal"]
			if hn.y >= 0.55:
				rest = hp
			else:
				var f := _floor_under(space, hp + hn * 0.35, 0.2, THROW_PIT_DROP + (hp.y - eye.y) + 2.0, skip)
				if not f.is_empty() and (f["position"] as Vector3).y > eye.y - THROW_PIT_DROP:
					rest = f["position"]
					t += 0.3
			break
		p = q
		if p.y < eye.y - THROW_PIT_DROP:
			break
	if rest != null:
		return {"pos": rest, "from": eye, "pit": false, "fly": clampf(t, 0.25, 2.2)}
	# the pit gives it back: the ledge next to the thrower (in front if there is floor, else at the
	# feet, else the last floor this PC stood on)
	var flat := Vector3(fwd.x, 0.0, fwd.z)
	flat = flat.normalized() if flat.length() > 0.01 else Vector3.FORWARD
	var ledge = null
	for k in [1.6, 0.9, 0.0]:
		var f2 := _floor_under(space, c.global_position + flat * k, 1.2, 3.2, skip)
		if not f2.is_empty():
			ledge = f2["position"]
			break
	if ledge == null:
		ledge = _last_floor if _has_last_floor else c.global_position
	return {"pos": ledge, "from": eye, "pit": true, "fly": 1.2}


func _throw(c) -> void:
	if not _carrying() or not _local_alive(c) or _finished():
		return
	var now := Time.get_ticks_msec()
	if now - _throw_sent_ms < 1000:
		return
	_throw_sent_ms = now
	var plan := _plan_throw(c)
	var n := _seq + 1
	var pos: Vector3 = plan["pos"]
	throw_log.append([n, pos, bool(plan["pit"]), (pos - c.global_position).length()])
	print("%s throw idolthrow_%d to %s pit=%s (%.1f m)" % [TAG, n, str(pos), str(plan["pit"]), (pos - c.global_position).length()])
	CoopSync.map_event("idolthrow_%d" % n, {"n": n, "giver": _my_sid(), "giver_by": CoopSync.local_name,
			"from": _arr(plan["from"]), "pos": _arr(pos), "pit": bool(plan["pit"]), "fly": float(plan["fly"]), "at": now}, false)


func _on_throw(data: Dictionary) -> void:
	# the authority writes the idol onto the ground
	if not CoopSync.map_is_authority():
		return
	var n := int(data.get("n", 0))
	var giver := _sid(data.get("giver", ""))
	var from := str(data.get("_from", _my_sid()))
	var why := ""
	if _finished():
		why = "done"
	elif n != _seq + 1 or giver != _holder_sid or giver == "" or from != giver or _ground:
		why = "stale"
	if why != "":
		last_refusal = {"n": n, "why": why}
		print("%s refused throw n=%d from %s: %s" % [TAG, n, giver, why])
		CoopSync.map_event("idolno_%d" % n, {"n": n, "to": giver, "why": why}, false)
		return
	CoopSync.map_event("idolpass_%d" % n, {"n": n, "id": "", "by": "", "giver": giver,
			"giver_by": str(data.get("giver_by", "")), "ground": true, "pos": data.get("pos", []),
			"from": data.get("from", []), "pit": _b(data.get("pit", false)), "fly": float(data.get("fly", 0.6)),
			"orphan": false, "confirm": false}, true)


func _update_grab(c, alive: bool, now: int) -> void:
	# walking over a thrown idol picks it up (the authority decides a race)
	if not _ground or not alive or _finished() or now < _ground_ms:
		return
	var d: Vector3 = c.global_position - _ground_pos
	var flat := Vector2(d.x, d.z).length()
	if _is_me(_ground_thrower) and not _grab_armed:
		if now - _ground_ms >= int(THROWER_GRAB_S * 1000.0) or flat > GRAB_R + 1.0:
			_grab_armed = true
		else:
			return
	if flat > GRAB_R or d.y > GRAB_DY or d.y < -GRAB_DY:
		return
	if now - _grab_sent_ms < GRAB_RESEND_MS:
		return
	_grab_sent_ms = now
	var n := _seq + 1
	print("%s grab idolgrab_%d (%.1f m)" % [TAG, n, flat])
	CoopSync.map_event("idolgrab_%d" % n, {"n": n, "to": _my_sid(), "to_by": CoopSync.local_name, "at": now}, false)


func _on_grab(data: Dictionary) -> void:
	if not CoopSync.map_is_authority():
		return
	var n := int(data.get("n", 0))
	var to := _sid(data.get("to", ""))
	var from := str(data.get("_from", _my_sid()))
	var why := ""
	if _finished():
		why = "done"
	elif n != _seq + 1 or not _ground or to == "" or from != to:
		why = "stale"
	else:
		var rn := _node_for_sid(to)
		var reach := GRAB_HOST_REACH_LOOP if _b(CoopSync.get("_loopback")) else GRAB_HOST_REACH
		if rn == null:
			why = "dead"
		elif rn.global_position.distance_to(_ground_pos) > reach + GRAB_DY:
			why = "far"
	if why != "":
		print("%s refused grab n=%d by %s: %s" % [TAG, n, to, why])
		return
	CoopSync.map_event("idolpass_%d" % n, {"n": n, "id": to, "by": str(data.get("to_by", "")), "giver": "",
			"giver_by": "", "pickup": true, "thrower": _ground_thrower, "screamed": _screamed,
			"orphan": false, "confirm": false}, true)


func _announce_throw(data: Dictionary, me_before: bool) -> void:
	var who := str(data.get("giver_by", ""))
	if who == "":
		who = _name_of(_sid(data.get("giver", "")))
	var pit := _b(data.get("pit", false))
	print("%s thrown n=%d by %s pit=%s" % [TAG, int(data.get("n", 0)), who, str(pit)])
	if me_before:
		if pit:
			CoopSync.show_banner("The pit will not keep it. The idol crawls back up beside you.", 4.0)
		else:
			CoopSync.show_banner("You threw the idol. It weeps where it lies. The Nest still hunts you.", 4.0)
	else:
		CoopSync.show_banner("%s threw the idol%s. Walk over it to pick it up." % [who, " (the pit gave it back)" if pit else ""], 4.0)


func _announce_pickup(data: Dictionary, me_now: bool) -> void:
	var who := holder_name()
	var screamed := _b(data.get("screamed", false))
	print("%s picked up n=%d by %s (thrower %s, screamed %s)" % [TAG, int(data.get("n", 0)), _holder_sid, str(data.get("thrower", "")), str(screamed)])
	if me_now:
		CoopSync.show_banner("You picked up the idol%s. Everything in the Nest hunts you now." % (" and it falls silent" if screamed else ""), 4.0)
		if Game.audio != null and not _is_me(str(data.get("thrower", ""))):
			Game.audio.play_dark_transition2()
	else:
		CoopSync.show_banner("%s picked up the idol." % who, 3.0)


func _set_ground(on: bool, d: Dictionary, n: int) -> void:
	if not on:
		if _ground:
			_ground = false
			_ground_n = 0
			_screamed = false
			_free_ground_node()
		return
	if _ground and _ground_n == n:
		return
	_ground = true
	_ground_n = n
	_ground_pos = _v3(d.get("pos", []))
	_ground_from = _v3(d.get("from", []), _ground_pos + Vector3.UP * 1.5)
	_ground_pit = _b(d.get("pit", false))
	_ground_fly = clampf(float(d.get("fly", 0.6)), 0.0, 2.5)
	if Time.get_ticks_msec() - _load_ms < 5000:
		_ground_fly = 0.0                        # a reload or a late join: it already lies there
	_ground_thrower = _sid(d.get("giver", ""))
	_ground_thrower_by = str(d.get("giver_by", ""))
	_ground_ms = Time.get_ticks_msec() + int(_ground_fly * 1000.0)
	_screamed = false
	_scream_t = 0.0
	_sob_t = randf_range(4.0, 7.0)
	_grab_armed = false
	_grab_sent_ms = -100000
	_orphan_since = -1
	_make_ground_node()


func _free_ground_node() -> void:
	if is_instance_valid(_ground_node):
		_ground_node.queue_free()
	_ground_node = null
	_ground_glow = null
	_weep = null
	_cry = null


func _sfx_stream(file: String, loop: bool) -> AudioStream:
	var ss = _ss()
	if ss != null and ss.has_method("_stream"):
		var st = ss.call("_stream", file, loop)
		if st is AudioStream:
			return st
	var full := DIR + "sfx/" + file
	if not FileAccess.file_exists(full):
		_warn("sfx " + file, "missing sound " + full)
		return null
	var ogg := AudioStreamOggVorbis.load_from_buffer(FileAccess.get_file_as_bytes(full))
	if ogg != null:
		ogg.loop = loop
	return ogg


func _make_ground_node() -> void:
	_free_ground_node()
	var root := Node3D.new()
	root.name = "IdolOnGround"
	root.set_meta("zonda_pin_decoy", true)       # CoopSync lets a pinned hunter go for it (v5.1)
	root.set_meta("zonda_keep", true)
	var ps = load("res://Art/Praxthos.glb")
	if ps is PackedScene:
		var model: Node3D = (ps as PackedScene).instantiate()
		for co in model.find_children("*", "CollisionObject3D", true, false):
			co.queue_free()
		for mi in model.find_children("*", "MeshInstance3D", true, false):
			var m3 := mi as MeshInstance3D
			if m3.mesh == null:
				continue
			for si in m3.mesh.get_surface_count():
				var src: Material = m3.get_active_material(si)
				if src is BaseMaterial3D:
					var dm: BaseMaterial3D = src.duplicate()
					dm.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_DISABLED
					dm.proximity_fade_enabled = false
					m3.set_surface_override_material(si, dm)
		var ab := AABB()
		var first := true
		for gi in model.find_children("*", "VisualInstance3D", true, false):
			var tr := Transform3D.IDENTITY
			var nd: Node = gi
			while nd != null and nd != model:
				if nd is Node3D:
					tr = (nd as Node3D).transform * tr
				nd = nd.get_parent()
			var box: AABB = tr * (gi as VisualInstance3D).get_aabb()
			if first:
				ab = box
				first = false
			else:
				ab = ab.merge(box)
		var h: float = maxf(ab.size.y, maxf(ab.size.x, ab.size.z))
		model.scale = Vector3.ONE * (0.5 / h if h > 0.001 else 0.3)
		model.position = Vector3(0.0, -ab.position.y * model.scale.y, 0.0)
		model.name = "Model"
		root.add_child(model)
	_ground_glow = OmniLight3D.new()
	_ground_glow.name = "IdolScreamGlow"
	_ground_glow.light_color = GLOW_COLOR
	_ground_glow.light_energy = 0.0
	_ground_glow.omni_range = 9.0
	_ground_glow.shadow_enabled = false
	_ground_glow.position = Vector3(0.0, 0.5, 0.0)
	_ground_glow.set_meta("zonda_no_shadow", true)
	_ground_glow.set_meta("zonda_keep", true)
	_ground_glow.set_meta("zonda_not_real_light", true)
	root.add_child(_ground_glow)
	var bus := &"ZondaCave" if AudioServer.get_bus_index("ZondaCave") >= 0 else &"MainBus"
	_weep = AudioStreamPlayer3D.new()
	_weep.name = "Weep"
	_weep.stream = _sfx_stream(SFX_WEEP[randi() % SFX_WEEP.size()], true)
	_weep.volume_db = -4.0
	_weep.unit_size = 3.0
	_weep.max_distance = 32.0
	_weep.bus = bus
	_weep.position = Vector3(0.0, 0.4, 0.0)
	root.add_child(_weep)
	_cry = AudioStreamPlayer3D.new()
	_cry.name = "Cry"
	_cry.volume_db = 0.0
	_cry.unit_size = 4.0
	_cry.max_distance = 45.0
	_cry.bus = bus
	_cry.position = Vector3(0.0, 0.4, 0.0)
	root.add_child(_cry)
	var parent: Node = map if map != null else self
	parent.add_child(root)
	root.global_position = _ground_from if _ground_fly > 0.0 else _ground_pos
	_ground_node = root


func _update_ground(delta: float, now: int) -> void:
	if not _ground:
		return
	if not is_instance_valid(_ground_node):
		_make_ground_node()
		if not is_instance_valid(_ground_node):
			return
	if _finished():
		_free_ground_node()
		return
	var left := float(_ground_ms - now) / 1000.0
	if left > 0.0 and _ground_fly > 0.0:
		# in flight: a simple arc from the hand to where it lands, tumbling
		var k := clampf(1.0 - left / _ground_fly, 0.0, 1.0)
		var peak := maxf(1.2, _ground_from.distance_to(_ground_pos) * 0.12)
		var p := _ground_from.lerp(_ground_pos, k) + Vector3.UP * (4.0 * peak * k * (1.0 - k))
		if _ground_pit:
			p = _ground_from.lerp(_ground_pos, k) + Vector3.UP * (sin(k * PI) * 2.0)
		_ground_node.global_position = p
		_ground_node.rotate_x(delta * 9.0)
		return
	_ground_node.global_position = _ground_pos
	_ground_node.rotation = Vector3(0.0, _ground_node.rotation.y + delta * 0.15, 0.0)
	var lying := float(now - _ground_ms) / 1000.0
	if not _screamed:
		if is_instance_valid(_weep) and _weep.stream != null and not _weep.playing and _weep.is_inside_tree():
			_weep.play()
		_sob_t -= delta
		if _sob_t <= 0.0:
			_sob_t = randf_range(5.0, 8.0)
			_play_cry(SFX_SOB, -3.0, randf_range(0.9, 1.05), 4.0, 45.0)
		if lying >= WEEP_S:
			_scream()
	else:
		_scream_t -= delta
		if _scream_t <= 0.0:
			_scream_t = SCREAM_EVERY
			_play_cry(SFX_SCREAM[randi() % SFX_SCREAM.size()], 3.0, randf_range(0.85, 1.0), 20.0, 260.0)
			scream_log.append(now)
		# the glow: a red pulse, brightest at each scream
		var since := SCREAM_EVERY - _scream_t
		var pulse := 0.5 + 0.5 * sin(float(now) / 180.0)
		if is_instance_valid(_ground_glow):
			_ground_glow.light_energy = 1.1 + 0.6 * pulse + 2.5 * exp(-since * 1.5)
			_ground_glow.omni_range = 8.0 + 3.0 * exp(-since * 1.5)


func _scream() -> void:
	_screamed = true
	_scream_t = 0.0                           # the first scream plays on this frame's check
	if is_instance_valid(_weep):
		_weep.stop()
	print("%s the idol screams (n=%d, %.1f s on the ground)" % [TAG, _ground_n, float(Time.get_ticks_msec() - _ground_ms) / 1000.0])
	CoopSync.show_banner("The idol SCREAMS. The Nest is coming for it.", 4.0)
	var ln = CoopSync.lantern
	if is_instance_valid(ln) and ln.has_method("curse_flare"):
		ln.call("curse_flare")
	_update_pins()


func _play_cry(file: String, db: float, pitch: float, unit: float, maxd: float) -> void:
	if not is_instance_valid(_cry) or not _cry.is_inside_tree():
		return
	var st := _sfx_stream(file, false)
	if st == null:
		return
	_cry.stop()
	_cry.stream = st
	_cry.volume_db = db
	_cry.pitch_scale = pitch
	_cry.unit_size = unit
	_cry.max_distance = maxd
	_cry.play()


# ---------------------------------------------------------------- dev test

func _setup_test() -> void:
	var flag = null
	if map != null and map.has_method("dev_flag"):
		flag = map.call("dev_flag", "idolhost.flag")
	elif FileAccess.file_exists(DIR + "idolhost.flag"):
		flag = FileAccess.get_file_as_string(DIR + "idolhost.flag").strip_edges()
		DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/maps/underdark/idolhost.flag")
	var marker := _read_marker()
	if flag == null and marker.is_empty():
		return
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")
	var t := IdolTest.new()
	t.name = "IdolTest"
	t.h = self
	t.map = map
	if not marker.is_empty():
		t.replay_phase = true
		t.saved = marker
		t.variant = str(marker.get("variant", ""))
	else:
		t.variant = str(flag).strip_edges().to_lower()
	_test_burn = true
	print("%s test on: variant '%s'%s" % [TAG, t.variant, " (after the reload)" if t.replay_phase else ""])
	add_child(t)


func _read_marker() -> Dictionary:
	if not FileAccess.file_exists(TEST_MARK):
		return {}
	var d = JSON.parse_string(FileAccess.get_file_as_string(TEST_MARK))
	DirAccess.remove_absolute(TEST_MARK)       # read once: a crash can never leave it armed
	if not (d is Dictionary):
		return {}
	if absf(Time.get_unix_time_from_system() - float(d.get("at", 0.0))) > 600.0:
		return {}                                # a stale marker from an old run
	return d


class IdolTest extends Node:
	# timeline in 3.3 "Dev test"; every check prints one PASS or FAIL line
	var h = null
	var map = null
	var variant := ""
	var replay_phase := false
	var saved: Dictionary = {}
	var t := 0.0
	var phase := 0
	var n_pass := 0
	var n_total := 0
	var fails: Array = []
	var checks: Dictionary = {}
	var log_t := 0.0
	var t_idol := -1.0
	var req_t := -1.0
	var shim_forced := false
	const PASS1_HOLD := 2.5          # one hold of G: waits while the Ghost is out of reach
	const PASS1_WINDOW := 20.0       # holds again until a pass lands, for this long
	const BACK_GAP := 0.4            # the Ghost's pass-back retries at most this often
	var tries := 0
	var try_t := -1.0
	var sent_t := -1.0               # when the current request was first seen pending
	var sent_ans := 0                # loop_answers at that moment (the shim is per request)
	var cling_tries := 0
	var pass2_tries := 0
	var p1 := -1.0
	var w_p1 := 0.0
	var snap0: Array = []
	var snap1: Array = []
	var mv0 := -1.0
	var count0 := 0
	var cling_t := -1.0
	var pass2_t := -1.0
	var p2 := -1.0
	var orphan_t := -1.0
	var sizzles0 := 0
	var old_user = null
	var min_hp := 1000.0
	var floor_t := -1.0
	var end_t := -1.0
	# v5.1 "throw"
	var th_t := -1.0
	var th_plan: Dictionary = {}
	var th_yaw := 0.0
	var th_d0 := -1.0
	var th_scream_t := -1.0
	var th_stations: Array = []
	var th_si := 0
	var th_pit_yaw := 0.0
	var th_pit_found := false

	func ok(key: String, cond: bool, text: String) -> void:
		if checks.has(key):
			return
		checks[key] = true
		n_total += 1
		if cond:
			n_pass += 1
			print("%s PASS %s" % [TAG, text])
		else:
			fails.append(key)
			print("%s FAIL %s" % [TAG, text])

	func me() -> String:
		return h._my_sid()

	func mine() -> bool:
		return h._b(map.get("_idol_mine"))

	func ghost():
		var peers = CoopSync.get("_peers")
		if peers is Dictionary:
			var g = peers.get(777)
			if is_instance_valid(g):
				return g
		return null

	func scene() -> String:
		return str(map.get("scene_file_path"))

	func crawlers() -> Array:
		var br = h._brood()
		if br != null and br.has_method("threat_positions"):
			return br.call("threat_positions")
		return []

	static func moved(a: Array, b: Array) -> float:
		var s := 0.0
		for i in mini(a.size(), b.size()):
			if a[i] is Vector3 and b[i] is Vector3:
				s += (a[i] as Vector3).distance_to(b[i])
		return s

	func park(pos: Vector3) -> void:
		var c = Game.climber
		if map.has_method("debug_park"):
			map.call("debug_park", pos)
		elif map.has_method("_debug_park"):
			map.call("_debug_park", c, pos)
		else:
			c.teleport_to_location(pos)

	func take_idol() -> void:
		CoopSync.map_event("idol", {"by": CoopSync.local_name, "id": me()})

	func _try_pass1() -> void:
		tries += 1
		try_t = t
		h.last_g_msg = ""
		h._test_hold_g(PASS1_HOLD)

	func _why_no_pass() -> String:
		# what the last hold saw: its banner, the refusals, and where the Ghost's knight stands
		var gs := "ghost missing"
		var g = ghost()
		var c = Game.climber
		if g != null and is_instance_valid(c):
			var d: Vector3 = (g as Node3D).global_position - (c as Node3D).global_position
			gs = "ghost flat %.1f m dy %.1f m" % [Vector2(d.x, d.z).length(), d.y]
		var hold: String = str(h.last_g_msg)
		if hold == "":
			hold = "(no banner) done=%s" % str(h._g_done)
		return "hold='%s' refusal=%s recv_refusal=%s mates=%d stint=%.1f s %s" % [hold, str(h.last_refusal),
				str(h.last_recv_refusal), int(h._mates), h._stint_s(), gs]

	func _retryable(n: int) -> bool:
		# the Ghost's pass-back n was turned down only for reach (my receiver check "far" or "dead",
		# or the authority's "far"): a shove moved me, so the Ghost may try again
		var r: Dictionary = h.last_recv_refusal
		if int(r.get("n", -1)) == n and str(r.get("why", "")) in ["far", "dead"]:
			return true
		var a: Dictionary = h.last_refusal
		return int(a.get("n", -1)) == n and str(a.get("why", "")) == "far"

	func _process(delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		t += delta
		if end_t >= 0.0:
			return
		if replay_phase:
			_replay_check()
			return
		if t_idol >= 0.0 and t - t_idol >= 1.0:
			log_t -= delta
			if log_t <= 0.0:
				log_t = 2.0
				_log_state(c)
		if min_hp > float(c.health) and floor_t >= 0.0:
			min_hp = float(c.health)
		if t_idol >= 0.0 and float(c.health) < 50.0 and (variant != "solo"):
			# the Nest nips an invincible tester down to 0, which would count as "not alive" and
			# hand the idol on by the orphan rule mid-test: top it up (burns are measured from
			# what take_damage is given, not from health)
			c.health = c.healthMax
		match variant:
			"solo":
				_solo(c)
			"race":
				_race(c)
			"throw":
				_throwtest(c)
			_:
				_main(c)

	func _begin(c) -> void:
		# common start: test files, no loopback script, invincible, lantern on
		if h._b(CoopSync.get("_loopback")):
			CoopSync.set("_loop_step", 7)
		c.prevent_player_death = true
		var ln = CoopSync.lantern
		if is_instance_valid(ln) and ln.get("user") != null:
			old_user = ln.get("user")
			ln.set("user", 1)                  # the Ghost mirrors a lit lantern (not saved)
		var ap = map.get("_altar_pos")
		if ap is Vector3:
			park(ap + Vector3(-9.0, 1.6, 0.0))
			if c.get("PlayerCamera") != null and c.PlayerCamera.has_method("set_camera_rotation"):
				c.PlayerCamera.set_camera_rotation(Vector3(0.0, deg_to_rad(-90.0), 0.0))

	func _log_state(c) -> void:
		var hn = h.holder_node()
		var tn := "none"
		if hn != null:
			tn = CoopSync.local_name if hn == Game.climber else str(hn.get("player_name"))
		var bt := "?"
		if map.has_method("idol_prey"):
			var pr = map.call("idol_prey")
			bt = "none" if pr == null else (CoopSync.local_name if pr == Game.climber else str(pr.get("player_name")))
		var br = h._brood()
		if br != null and br.get("last_prey_name") != null:
			bt += "/" + str(br.get("last_prey_name"))
		var cl: Array = []
		for cent in Game.centipedes:
			if is_instance_valid(cent) and cent is Node3D and cent.is_inside_tree() and h._pinned(cent, map.get("hunt_pin_groups")):
				var tg = CoopSync.call("target_player_for", cent) if CoopSync.has_method("target_player_for") else null
				var tgn := "none"
				if tg != null:
					tgn = CoopSync.local_name if tg == Game.climber else str(tg.get("player_name"))
				cl.append("%s>%s" % [str(cent.get_meta("zonda_cid", "?")), tgn])
		print("%s hunt t=%.0f target=%s brood_target=%s cen16=[%s]" % [TAG, t, tn, bt, ", ".join(PackedStringArray(cl))])
		var dim = CoopSync.lantern.get("curse_dim") if is_instance_valid(CoopSync.lantern) else null
		var ss = h._ss()
		var heart := float(ss.get("heart_floor")) if ss != null and ss.get("heart_floor") != null else -1.0
		print("%s w=%.1f hunted=%s hunter_d=%.0f heart=%.2f dim=%s health=%.0f seq=%d holder=%s" % [TAG, h._w, str(h._hunted),
				h._hunt_d if h._hunt_d < 1e8 else -1.0, heart, ("%.2f" % float(dim)) if dim != null else "?", float(c.health), h._seq, h._holder_sid])

	# ---- the loopback timeline
	func _main(c) -> void:
		if phase == 0:
			if t < 2.0:
				return
			if not h._b(CoopSync.get("_loopback")):
				print("%s this variant needs loopback.flag (use \"solo\" or \"race\" without it)" % TAG)
				ok("loopback", false, "loopback: not running")
				_finish(c)
				return
			_begin(c)
			take_idol()
			t_idol = t
			phase = 1
		elif phase == 1:
			if h._seq >= 1 or t - t_idol > 1.0:
				ok("confirm", h._seq == 1 and h._holder_sid == me() and h.passes() == 0,
						"confirm idolpass_1 holder=%s passes=%d (%.2f s)" % [h._holder_sid, h.passes(), t - t_idol])
				phase = 2
		elif phase == 2:
			# the burn curve (4, 5.2, 6.4) assumes the weight grew without a pause: a hunter that lost
			# the tester for a second (it happens, the Nest is busy) shifted the 2nd tick. Gate forced, as in solo
			h._test_force_hunted = true
			_weight_checks()
			# pass once three burns have landed (the stint is 20 s or more by then), or give up at 70 s
			if (h.burn_log.size() >= 3 and t - t_idol >= 14.0) or t - t_idol > 70.0:
				if h.burn_log.size() < 3:
					ok("burn", false, "burn: only %d ticks in 70 s (w=%.1f, hunted=%s)" % [h.burn_log.size(), h._w, str(h._hunted)])
				req_t = t
				h._test_force_hunted = false
				_try_pass1()
				phase = 3
		elif phase == 3:
			var pend: bool = not h._pending.is_empty()
			if not pend:
				sent_t = -1.0
			elif sent_t < 0.0:
				sent_t = t
				sent_ans = h.loop_answers
			if pend and not shim_forced and h.loop_answers == sent_ans and t - sent_t > 2.2:
				shim_forced = true
				var pn := int(h._pending.get("n", 0))
				ok("loop shim", false, "loop shim: coop_loop_ghost never answered idolreq_%d, the test answers for the Ghost" % pn)
				h.loop_ghost("idolreq_%d" % pn, {"n": pn, "to": GHOST_SID, "giver": me(), "giver_by": CoopSync.local_name,
						"at": int(h._pending.get("ms", 0))})
			if h._seq >= 2:
				ok("pass1", h._holder_sid == GHOST_SID and not mine() and not CoopSync.idol_carrier and h._seq == 2 and h.passes() == 1,
						"pass1 holder=%s mine=%s carrier_flag=%s seq=%d passes=%d (try %d, %.1f s)" % [h._holder_sid, str(mine()),
						str(CoopSync.idol_carrier), h._seq, h.passes(), tries, t - req_t])
				p1 = t
				w_p1 = h._w
				snap0 = crawlers()
				count0 = snap0.size()
				CoopSync.set("loop_ghost_weight", 60)     # the Ghost streams 61: sizzle and dim on its knight
				var g = ghost()
				sizzles0 = int(g.get("stat_sizzles")) if g != null and g.get("stat_sizzles") != null else 0
				phase = 4
			elif t - req_t > PASS1_WINDOW and not pend:
				ok("pass1", false, "pass1: no idolpass_2 after %d tries in %.0f s (seq=%d holder=%s pending=%s %s)" % [tries,
						t - req_t, h._seq, h._holder_sid, str(h._pending), _why_no_pass()])
				_finish(c)
			elif not pend and (h._g_done or not h._g_held) and t - try_t >= 0.5:
				# that hold ended with no pass (a bite shoved me out of reach, or the answer was a
				# refusal or timed out): hold G again, as a player would
				print("%s pass1 try %d ended: %s" % [TAG, tries, _why_no_pass()])
				_try_pass1()
		elif phase == 4:
			_after_pass1(c)
		elif phase == 5:
			_after_orphan(c)
		elif phase == 6:
			if t - orphan_t > 1.0:
				_review_grep()
				_write_marker_and_reload(c)

	func _weight_checks() -> void:
		var ss = h._ss()
		if h._w >= 16.0 and not checks.has("heart"):
			var hf := float(ss.get("heart_floor")) if ss != null and ss.get("heart_floor") != null else -1.0
			ok("heart", hf > 0.3, "heart floor=%.2f at w=%.1f" % [hf, h._w])
		if h._w >= 19.0 and not checks.has("dim"):
			var cd = CoopSync.lantern.get("curse_dim") if is_instance_valid(CoopSync.lantern) else null
			ok("dim", cd != null and float(cd) < 0.8, "dim curse_dim=%s at w=%.1f" % [str(cd), h._w])
		if h.burn_log.size() >= 1 and not checks.has("telegraph"):
			var tick_ms: int = int(h.burn_log[0][0])
			var tell_ms := -1
			for m in h.tell_log:
				if int(m) <= tick_ms:
					tell_ms = int(m)
			var gap := float(tick_ms - tell_ms) / 1000.0
			ok("telegraph", tell_ms >= 0 and gap >= 0.55 and gap <= 0.65, "telegraph %.2f s between the sizzle and the burn" % gap)
		if h.burn_log.size() >= 3 and not checks.has("burn"):
			# v5.1: the law, not a fixed curve. The weight grows 1.0/s with a living teammate and 0.6/s
			# without, and the loopback Ghost's count flickers, so (4, 5.2, 6.4) was luck. Each tick must be
			# _burn_damage(w at that tick) (2 x (2 + 0.3 (w - 20)), capped), the first about 4, and rising.
			var got: Array = []
			var good := true
			var prev := 0.0
			for i in 3:
				var d := float(h.burn_log[i][1])
				var wi := float(h.burn_log[i][2])
				got.append("%.2f at w %.1f" % [d, wi])
				if absf(d - h._burn_damage(wi)) > 0.05 or d < prev:
					good = false
				prev = d
			if absf(float(h.burn_log[0][1]) - 4.0) > 0.3:
				good = false
			ok("burn", good, "burn (%s) = 2 x (2 + 0.3 (w - 20)), first ~4, rising" % ", ".join(PackedStringArray(got)))

	func _after_pass1(c) -> void:
		var dt := t - p1
		var g = ghost()
		# the pins follow the new holder
		if not checks.has("hunt"):
			var pins = CoopSync.get("hunt_pins")
			var pin_ok: bool = g != null and pins is Dictionary and pins.get("idol") == g
			var prey_ok := true
			if map.has_method("idol_prey"):
				prey_ok = map.call("idol_prey") == g
			var cents_ok := true
			if CoopSync.has_method("target_player_for"):
				for cent in Game.centipedes:
					if is_instance_valid(cent) and cent is Node3D and cent.is_inside_tree() and cent.visible \
							and cent.process_mode != Node.PROCESS_MODE_DISABLED and h._pinned(cent, map.get("hunt_pin_groups")):
						if CoopSync.call("target_player_for", cent) != g:
							cents_ok = false
			if pin_ok and prey_ok and cents_ok:
				ok("hunt", true, "hunt ghost (%.1f s)" % dt)
			elif dt > 1.5:
				ok("hunt", false, "hunt ghost: pin=%s prey=%s pinned centipedes=%s" % [str(pin_ok), str(prey_ok), str(cents_ok)])
		# the scent: still for 0.9 s, then moving again
		if dt >= 0.9 and mv0 < 0.0:
			snap1 = crawlers()
			mv0 = moved(snap0, snap1)
		if dt >= 1.9 and mv0 >= 0.0 and not checks.has("scent"):
			var mv1 := moved(snap1, crawlers())
			# "still" = under 1.5 m summed over all the crawlers (a crawler still being born, or settling onto its floor,
			# shifts a few cm); "moving again" = more than 3 m summed
			ok("scent", count0 > 0 and mv0 < 1.5 and mv1 > 3.0, "scent %d crawlers moved %.2f m in 0.9 s, then %.2f m in 1.0 s" % [count0, mv0, mv1])
		if dt >= 2.0 and not checks.has("leash"):
			var n := crawlers().size()
			ok("leash", count0 > 0 and n >= count0, "leash %d -> %d crawlers alive" % [count0, n])
		# the Ghost's marks
		if dt >= 1.0 and g != null:
			var v = g.get("_voice")
			if not checks.has("voice demon"):
				var pl = v.get("_player") if v != null else null
				var good: bool = v != null and str(v.get("bus_override")) == "ZondaDemon" and pl != null and str(pl.bus) == "ZondaDemon" \
						and AudioServer.get_bus_index("ZondaDemon") >= 0
				if good:
					ok("voice demon", true, "voice demon (bus %s, %d effects, frames out %d)" % [str(pl.bus),
							AudioServer.get_bus_effect_count(AudioServer.get_bus_index("ZondaDemon")), int(v.get("stat_frames_out"))])
				elif dt > 4.0:
					ok("voice demon", false, "voice demon: override=%s bus=%s idol_level=%s" % [str(v.get("bus_override")) if v != null else "?",
							str(pl.bus) if pl != null else "?", str(g.get("idol_level"))])
			if not checks.has("lantern red"):
				var ll = g.get("_lantern_light")
				if ll is OmniLight3D and (ll as OmniLight3D).light_color.g < 0.3:
					ok("lantern red", true, "lantern red %s" % str((ll as OmniLight3D).light_color))
				elif dt > 4.0:
					ok("lantern red", false, "lantern red: light=%s idol_level=%s" % [str(ll.light_color) if ll is OmniLight3D else "none", str(g.get("idol_level"))])
			if not checks.has("ghost sizzle"):
				var sz := int(g.get("stat_sizzles")) if g.get("stat_sizzles") != null else 0
				if sz > sizzles0:
					ok("ghost sizzle", true, "ghost sizzle at 60%% weight (%d)" % (sz - sizzles0))
				elif dt > 4.5:
					ok("ghost sizzle", false, "ghost sizzle: none (idol_level=%s)" % str(g.get("idol_level")))
		elif dt > 4.5 and g == null:
			for k in ["voice demon", "lantern red", "ghost sizzle"]:
				ok(k, false, "%s: the Ghost's knight is missing" % k)
		if dt >= 3.0 and not checks.has("drain"):
			ok("drain", h._w <= w_p1 - 2.0, "drain w %.1f -> %.1f in 3 s" % [w_p1, h._w])
		# v5.1: no cling, the Ghost passes it straight back after 3 s and it goes through
		if dt >= 3.0 and pass2_t < 0.0:
			pass2_t = t
			h.last_refusal = {}
			h.last_recv_refusal = {}
			_ghost_passes_back()
		if pass2_t >= 0.0 and p2 < 0.0:
			if h._seq >= 3:
				p2 = t
				ok("pass2", h._holder_sid == me() and mine() and h._seq == 3 and h.passes() == 2,
						"pass2 holder=%s seq=%d passes=%d mine=%s (try %d)" % ["me" if h._holder_sid == me() else h._holder_sid, h._seq,
						h.passes(), str(mine()), pass2_tries + 1])
				ok("no cling", t - p1 < 6.0 and str(h.last_refusal.get("why", "")) != "cling",
						"no cling: passed straight back %.1f s after the first pass (refusal %s)" % [t - p1, str(h.last_refusal)])
				CoopSync.set("loop_ghost_weight", 0)
			elif _retryable(h._seq + 1) and pass2_tries < 6:
				if t - pass2_t >= BACK_GAP:
					pass2_tries += 1
					print("%s pass2 try %d: the last pass-back was turned down for reach (%s)" % [TAG, pass2_tries + 1, _why_no_pass()])
					pass2_t = t
					h.last_refusal = {}
					h.last_recv_refusal = {}
					_ghost_passes_back()
			elif t - pass2_t > 2.0:
				p2 = t
				ok("pass2", false, "pass2: seq=%d holder=%s refusal=%s recv=%s" % [h._seq, h._holder_sid, str(h.last_refusal),
						str(h.last_recv_refusal)])
		if p2 >= 0.0:
			if not checks.has("scent limited") and t - p2 >= 0.3:
				var r2 := false
				var r3 := true
				for e in h.scent_log:
					if int(e[0]) == 2:
						r2 = bool(e[1])
					elif int(e[0]) == 3:
						r3 = bool(e[1])
				ok("scent limited", r2 and not r3, "scent limited (scent loss after pass 2: %s, after pass 3: %s)" % [str(r2), str(r3)])
			if not checks.has("voice normal") and t - p2 >= 1.0:
				var v2 = g.get("_voice") if g != null else null
				var pl2 = v2.get("_player") if v2 != null else null
				if v2 != null and str(v2.get("bus_override")) == "" and pl2 != null and str(pl2.bus) != "ZondaDemon":
					ok("voice normal", true, "voice normal (bus %s)" % str(pl2.bus))
				elif t - p2 > 4.0:
					ok("voice normal", false, "voice normal: override=%s" % (str(v2.get("bus_override")) if v2 != null else "no Ghost voice"))
			# a holder who is gone: the orphan rule
			if t - p2 >= 4.0 and checks.has("voice normal"):
				orphan_t = t
				print("%s fake idolpass_%d to 424242 (a holder who left)" % [TAG, h._seq + 1])
				CoopSync.map_event("idolpass_%d" % (h._seq + 1), {"n": h._seq + 1, "id": "424242", "by": "Nobody",
						"giver": me(), "giver_by": CoopSync.local_name, "orphan": true, "confirm": false}, true)
				phase = 5

	func _ghost_passes_back() -> void:
		var n: int = h._seq + 1
		print("%s the Ghost passes back: idolreq_%d (stint %.1f s)" % [TAG, n, h._stint_s()])
		CoopSync.call("_apply_map_event", scene(), "idolreq_%d" % n, {"n": n, "to": me(), "giver": GHOST_SID,
				"giver_by": "Ghost", "_from": GHOST_SID}, false, false)

	func _after_orphan(c) -> void:
		var el := t - orphan_t
		if el >= 0.6 and not checks.has("stale"):
			ok("stale", h._holder_sid == "424242" and h.holder_node() == null, "holder_node null while stale (holder %s)" % h._holder_sid)
		if h._seq >= 5 and not checks.has("orphan"):
			var hn = h.holder_node()
			ok("orphan", el <= 4.6 and h._holder_sid != "424242" and hn != null and h.passes() == 2,
					"orphan -> %s in %.1f s (passes %d)" % [h.holder_name(), el, h.passes()])
			orphan_t = t
			phase = 6
		elif el > 6.0 and not checks.has("orphan"):
			ok("orphan", false, "orphan: none after 6 s (seq %d holder %s)" % [h._seq, h._holder_sid])
			orphan_t = t
			phase = 6

	func _write_marker_and_reload(c) -> void:
		var d := {"at": Time.get_unix_time_from_system(), "variant": variant, "pass": n_pass, "total": n_total,
				"fails": fails, "seq": h._seq, "holder": h._holder_sid, "mine": mine(), "passes": h.passes(),
				"user": old_user}
		var f := FileAccess.open(TEST_MARK, FileAccess.WRITE)
		if f == null:
			ok("replay", false, "replay: could not write %s" % TEST_MARK)
			_finish(c)
			return
		f.store_string(JSON.stringify(d))
		f.close()
		print("%s reloading the map (seq %d holder %s passes %d)" % [TAG, h._seq, h._holder_sid, h.passes()])
		end_t = t
		map.get_tree().reload_current_scene()

	func _replay_check() -> void:
		if t < 3.0:
			return
		n_pass = int(saved.get("pass", 0))
		n_total = int(saved.get("total", 0))
		fails = saved.get("fails", []) if saved.get("fails", []) is Array else []
		old_user = saved.get("user", null)
		var good: bool = h._seq == int(saved.get("seq", -1)) and h._holder_sid == str(saved.get("holder", "")) \
				and mine() == bool(saved.get("mine", false)) and h.passes() == int(saved.get("passes", -1)) and h.passes() == 2
		ok("replay", good, "replay seq=%d holder=%s mine=%s passes=%d (saved %d %s %s %d)" % [h._seq, h._holder_sid, str(mine()),
				h.passes(), int(saved.get("seq", -1)), str(saved.get("holder", "")), str(saved.get("mine", false)), int(saved.get("passes", -1))])
		_finish(Game.climber)

	# ---- "solo": no one to pass to, and the burn floor
	func _solo(c) -> void:
		if phase == 0:
			if t < 2.0:
				return
			_begin(c)
			take_idol()
			t_idol = t
			phase = 1
		elif phase == 1:
			if h._seq >= 1 or t - t_idol > 1.0:
				ok("confirm", h._seq == 1 and h._holder_sid == me() and h.passes() == 0,
						"confirm idolpass_1 holder=%s passes=%d" % [h._holder_sid, h.passes()])
				phase = 2
		elif phase == 2:
			if t - t_idol >= 3.0:
				h.last_g_msg = ""
				h._test_hold_g(0.7)
				req_t = t
				phase = 3
		elif phase == 3:
			if t - req_t >= 1.0:
				ok("solo banner", h.last_g_msg == "There is no one to take it. Get it out, or tap G to throw it.", "solo no-pass banner '%s'" % h.last_g_msg)
				# away from the Nest (nothing may bite here), the gate forced open and the weight
				# pre-loaded so 70 s holds about 30 burn ticks: the floor must hold every one
				var sp = c.get("original_global_position_in_level")
				if sp is Vector3:
					park(sp + Vector3(0.0, 0.6, 0.0))
				h._test_force_hunted = true
				h._w = 14.0
				print("%s solo: parked at the spawn, hunter gate forced, weight 14" % TAG)
				floor_t = t
				min_hp = float(c.health)
				phase = 4
		elif phase == 4:
			if t - floor_t >= 70.0:
				ok("floor", min_hp >= BURN_FLOOR and h.burn_log.size() >= 3 and h.floor_skips >= 1,
						"floor min health %.0f over 70 s (%d burns, %d skipped by the floor)" % [min_hp, h.burn_log.size(), h.floor_skips])
				_review_grep()
				_finish(c)

	# ---- "throw" (v5.1): tap G throws, the ground idol weeps, then screams and calls the Nest
	func _look_yaw(c, yaw: float, pitch: float = 0.0) -> void:
		if map.has_method("debug_look"):
			var eye: Vector3 = c.global_position + Vector3.UP * 1.5
			var dir := Vector3(-sin(yaw), tan(pitch), -cos(yaw))
			map.call("debug_look", eye + dir * 10.0)
		elif c.get("PlayerCamera") != null:
			c.PlayerCamera.set_camera_rotation(Vector3(pitch, yaw, 0.0))

	func _nearest_hunter_to(p: Vector3) -> float:
		var best := INF
		for cent in Game.centipedes:
			if is_instance_valid(cent) and cent is Node3D and cent.is_inside_tree() and h._pinned(cent, map.get("hunt_pin_groups")):
				best = minf(best, p.distance_to((cent as Node3D).global_position))
		for q in crawlers():
			if q is Vector3:
				best = minf(best, p.distance_to(q))
		return best

	func _throwtest(c) -> void:
		if phase == 0:
			if t < 2.0:
				return
			_begin(c)
			take_idol()
			t_idol = t
			phase = 1
		elif phase == 1:
			if h._seq >= 1 or t - t_idol > 1.0:
				ok("confirm", h._seq == 1 and h._holder_sid == me() and h.passes() == 0,
						"confirm idolpass_1 holder=%s passes=%d" % [h._holder_sid, h.passes()])
				th_t = t
				th_yaw = 0.0
				th_plan = {}
				_look_yaw(c, 0.0)
				phase = 2
		elif phase == 2:
			# the range: plan a throw on 8 headings (level view), keep the longest one on rock
			if t - th_t < 0.25:
				return
			var k := int(round(th_yaw / (PI / 4.0)))
			var plan: Dictionary = h._plan_throw(c)
			var dist: float = (plan["pos"] as Vector3).distance_to(c.global_position)
			print("%s plan heading %d: %.1f m pit=%s" % [TAG, k, dist, str(plan["pit"])])
			if not bool(plan["pit"]) and (th_plan.is_empty() or dist > float(th_plan["dist"])):
				th_plan = plan.duplicate()
				th_plan["dist"] = dist
				th_plan["yaw"] = th_yaw
			th_yaw += PI / 4.0
			if k >= 7:
				var best := float(th_plan.get("dist", 0.0))
				ok("range", best >= 11.0 and best <= 19.0, "throw range %.1f m on the longest open heading (want about 15)" % best)
				_look_yaw(c, float(th_plan.get("yaw", 0.0)))
				th_t = t
				phase = 3
			else:
				_look_yaw(c, th_yaw)
				th_t = t
		elif phase == 3:
			if t - th_t < 0.4:
				return
			th_plan = h._plan_throw(c)
			h._test_hold_g(0.1)                     # a tap: the throw
			th_t = t
			phase = 4
		elif phase == 4:
			if h._seq >= 2 or t - th_t > 3.0:
				var gp: Vector3 = h._ground_pos
				var sent: Vector3 = h.throw_log[-1][1] if not h.throw_log.is_empty() else Vector3(INF, INF, INF)
				var dist_sent := float(h.throw_log[-1][3]) if not h.throw_log.is_empty() else -1.0
				ok("throw", h._seq == 2 and h._ground and h._holder_sid == "" and not mine() and h.passes() == 0 \
						and gp.distance_to(sent) < 0.05 and dist_sent > 3.0,
						"throw seq=%d ground=%s holder='%s' mine=%s passes=%d lies %.2f m from where it was thrown, %.1f m from the thrower (%.1f s)" % [h._seq,
						str(h._ground), h._holder_sid, str(mine()), h.passes(), gp.distance_to(sent), dist_sent, t - th_t])
				th_t = t
				phase = 5
		elif phase == 5:
			if t - th_t < 1.0:
				return
			if not checks.has("hunt thrower"):
				var pins = CoopSync.get("hunt_pins")
				var pr = map.call("idol_prey") if map.has_method("idol_prey") else null
				ok("hunt thrower", pins is Dictionary and pins.get("idol") == Game.climber and pr == Game.climber,
						"the Nest hunts the thrower while it weeps (pin=%s prey=%s)" % [str(pins.get("idol") if pins is Dictionary else null), str(pr)])
			if t - th_t >= float(h._ground_fly) + 0.5 and not checks.has("weep"):
				var wp = h._weep
				ok("weep", is_instance_valid(wp) and wp.playing and wp.stream != null and not h._screamed,
						"it weeps on the ground (playing=%s)" % str(wp.playing if is_instance_valid(wp) else null))
			if h._screamed:
				th_scream_t = t
				var lying := float(Time.get_ticks_msec() - h._ground_ms) / 1000.0
				ok("scream time", lying >= WEEP_S - 0.1 and lying <= WEEP_S + 0.6, "it screamed after %.1f s on the ground" % lying)
				th_d0 = _nearest_hunter_to(h._ground_pos)
				phase = 6
			elif t - th_t > WEEP_S + 5.0:
				ok("scream time", false, "no scream %.0f s after the throw" % (t - th_t))
				_finish(c)
		elif phase == 6:
			var el := t - th_scream_t
			if el >= 1.0 and not checks.has("scream"):
				var gl = h._ground_glow
				var pins2 = CoopSync.get("hunt_pins")
				var decoy = h._ground_node
				var pr2 = map.call("idol_prey") if map.has_method("idol_prey") else null
				var cents_ok := true
				var n_pinned := 0
				for cent in Game.centipedes:
					if is_instance_valid(cent) and cent is Node3D and cent.is_inside_tree() and cent.visible \
							and cent.process_mode != Node.PROCESS_MODE_DISABLED and h._pinned(cent, map.get("hunt_pin_groups")) \
							and cent.has_meta("zonda_hunt_pin"):
						n_pinned += 1
						if CoopSync.call("target_player_for", cent) != decoy:
							cents_ok = false
				ok("scream", h.scream_log.size() >= 1 and is_instance_valid(gl) and gl.light_energy > 1.0 \
						and pins2 is Dictionary and pins2.get("idol") == decoy and pr2 == decoy and cents_ok,
						"the scream calls the Nest (screams %d, glow %.2f, pin=decoy %s, prey=decoy %s, %d pinned hunters on it %s)" % [
						h.scream_log.size(), gl.light_energy if is_instance_valid(gl) else -1.0,
						str(pins2 is Dictionary and pins2.get("idol") == decoy), str(pr2 == decoy), n_pinned, str(cents_ok)])
			if el >= 1.5 and not checks.has("brood prey"):
				var br = h._brood()
				var lp := str(br.get("last_prey_name")) if br != null and br.get("last_prey_name") != null else "?"
				ok("brood prey", br == null or lp == "IdolOnGround", "the brood goes for the idol (last prey '%s')" % lp)
			if el >= 9.5 and not checks.has("screams again"):
				ok("screams again", h.scream_log.size() >= 2, "it screams again while it lies there (%d screams)" % h.scream_log.size())
			if el >= 10.0 and not checks.has("converge"):
				var d1 := _nearest_hunter_to(h._ground_pos)
				ok("converge", d1 < 1e8 and (d1 <= th_d0 + 0.5 or d1 < 8.0), "the Nest closes on the idol: nearest %.1f m -> %.1f m in 9 s" % [th_d0, d1])
				# walk over it
				park(h._ground_pos + Vector3.UP * 1.0)
				th_t = t
				phase = 7
		elif phase == 7:
			if h._seq >= 3:
				ok("pickup", h._seq == 3 and not h._ground and h._holder_sid == me() and mine() and h.passes() == 0 \
						and not is_instance_valid(h._ground_node),
						"walked over it: holder=%s mine=%s passes=%d ground idol gone=%s (%.1f s)" % ["me" if h._holder_sid == me() else h._holder_sid,
						str(mine()), h.passes(), str(not is_instance_valid(h._ground_node)), t - th_t])
				th_t = t
				var st = map.get("L")
				th_stations = []
				if st is Dictionary:
					for s in st.get("stations", []):
						if s is Dictionary and int(s.get("biome", -1)) <= 2:
							th_stations.append(s["pos"])
				th_si = 0
				phase = 8
			elif t - th_t > 4.0:
				ok("pickup", false, "no pickup 4 s after walking onto it (seq %d, dist %.1f)" % [h._seq,
						Game.climber.global_position.distance_to(h._ground_pos)])
				_finish(c)
		elif phase == 8:
			# find a ledge where a throw goes into the pit: stations in the upper rift, 8 headings each
			if t - th_t < 0.6:
				return
			if th_si >= mini(th_stations.size(), 40):
				ok("pit", false, "no station with a throw into the pit found")
				_review_grep()
				_finish(c)
				return
			var sp = th_stations[(th_si * 7) % th_stations.size()]
			th_si += 1
			var spos := Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
			park(spos + Vector3.UP * 1.2)
			th_t = t
			phase = 9
		elif phase == 9:
			if t - th_t < 0.8:
				return
			th_yaw = 0.0
			_look_yaw(c, th_yaw, -0.15)
			th_t = t
			phase = 13
		elif phase == 13:
			if t - th_t < 0.25:
				return
			var plan2: Dictionary = h._plan_throw(c)
			if bool(plan2["pit"]):
				th_pit_yaw = th_yaw
				print("%s pit found at station %d heading %.0f deg" % [TAG, th_si, rad_to_deg(th_yaw)])
				th_t = t
				phase = 10
			elif th_yaw >= 7.0 * PI / 4.0 - 0.01:
				th_t = t
				phase = 8
			else:
				th_yaw += PI / 4.0
				_look_yaw(c, th_yaw, -0.15)
				th_t = t
		elif phase == 10:
			if t - th_t < 0.1:
				return
			th_plan = h._plan_throw(c)
			if not bool(th_plan["pit"]):
				th_t = t
				phase = 8                            # shoved off the spot: look for another
				return
			h._test_hold_g(0.1)
			th_t = t
			phase = 11
		elif phase == 11:
			if h._seq >= 4 or t - th_t > 3.0:
				var gp2: Vector3 = h._ground_pos
				var near := gp2.distance_to(Game.climber.global_position)
				ok("pit", h._seq == 4 and h._ground and h._ground_pit and near < 3.5,
						"a throw into the pit comes back beside the thrower (pit=%s, %.1f m from the thrower)" % [str(h._ground_pit), near])
				th_t = t
				phase = 12
		elif phase == 12:
			# standing next to it: the thrower picks it up again after 2 s
			if h._seq >= 5:
				ok("pit pickup", h._holder_sid == me() and mine() and t - th_t >= THROWER_GRAB_S - 0.3,
						"the thrower picks it up again after %.1f s" % (t - th_t))
				_review_grep()
				_finish(c)
			elif t - th_t > 6.0:
				ok("pit pickup", false, "no pickup 6 s after the pit throw (dist %.1f)" % Game.climber.global_position.distance_to(h._ground_pos))
				_review_grep()
				_finish(c)

	# ---- "race": a remote touch stored first, then mine
	func _race(c) -> void:
		if phase == 0:
			if t < 2.0:
				return
			_begin(c)
			CoopSync.call("_apply_map_event", scene(), "idol", {"by": "Ghost", "id": GHOST_SID}, true, false)
			if map.has_method("_on_idol_touch"):
				map.call("_on_idol_touch", c)
			else:
				take_idol()
			t_idol = t
			phase = 1
		elif phase == 1:
			if h._seq >= 1 or t - t_idol > 1.0:
				var ev: Dictionary = CoopSync.map_events_for(scene())
				var p1d = ev.get("idolpass_1", {})
				var idd = ev.get("idol", {})
				var stored_ok: bool = p1d is Dictionary and h._b(p1d.get("confirm", false)) and str(p1d.get("id", "")) == GHOST_SID \
						and idd is Dictionary and h._sid(idd.get("id", "")) == GHOST_SID
				ok("race confirm", h._holder_sid == GHOST_SID and not mine() and h._seq == 1 and stored_ok,
						"confirm holder=%s mine=%s (%.2f s, stored first touch kept: %s)" % [h._holder_sid, str(mine()), t - t_idol, str(stored_ok)])
				_review_grep()
				_finish(c)

	func _review_grep() -> void:
		# no idol code writes velocity, the shove channel, the rope or the climber state (R8)
		var src := FileAccess.get_file_as_string(DIR + "idol_host.gd")
		var bad: Array = []
		for pat in ["." + "velocity", "additional_" + "velocity", "." + "Rope", "set_climber" + "_state", "Climber" + "State"]:
			if src.contains(pat):
				bad.append(pat)
		ok("review", src != "" and bad.is_empty(), "review grep: no velocity, rope or climber state writes%s" % ("" if bad.is_empty() else " (found %s)" % str(bad)))

	func _finish(c) -> void:
		end_t = t
		h._test_burn = false
		h._test_force_hunted = false
		CoopSync.set("loop_ghost_weight", 0)
		if is_instance_valid(c):
			c.prevent_player_death = false          # a test never leaves the player invincible
		var ln = CoopSync.lantern
		if is_instance_valid(ln) and old_user != null:
			ln.set("user", int(old_user))
		if FileAccess.file_exists(TEST_MARK):
			DirAccess.remove_absolute(TEST_MARK)
		if fails.is_empty():
			print("%s test done %d/%d PASS" % [TAG, n_pass, n_total])
		else:
			print("%s test done %d/%d FAIL: %s" % [TAG, n_pass, n_total, ", ".join(PackedStringArray(fails))])
