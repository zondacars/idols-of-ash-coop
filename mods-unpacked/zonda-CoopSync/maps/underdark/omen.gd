extends Node
# ============================================================================================
# THE OMEN ALTAR (THE UNDERDARK feature "omen", ZondaCoopSync v5.0)
#
# A ring of 8 skull pillars in THE MOUTH camp. Each skull holds a cold candle; lighting one
# (E, then E again within 8 s) makes the descent harder for the whole team, all the way down.
# The altar seals at THE RIFT (or when anyone drops below the lip), and the omens carried to the
# bottom decide the trophy (BONE CHARM, GRAVE CANDLE, EMBER EYES, THE FULL DARK).
#
# Loaded by underdark.gd (_load_features): setup(map) BEFORE add_child.
#
# Sync (contract R3/R4/R17):
#   omenreq_<id>  {act: "light"|"snuff", by}           non-persistent request, anyone may send
#   omenno_<id>   {to: sid, why}                       non-persistent refusal to the requester
#   omenset_<seq> {seq, lit: [ids], act, id, by, req}  persistent, written by the authority only
#   omen_seal     {lit, who: [sids], by, seq}          persistent, final, wins over every omenset
#   omen_hatch    {group, by}                          persistent, the authority only
# The lit set is always DERIVED from every stored key (the seal if stored, else the highest seq),
# so replay order never matters. Every machine applies every effect itself from that set.
#
# Public API:
#   const OMENS                      [{id, name, short, prompt, banner, explain, needs}]
#   tier_name(tier) -> String        omen_active(id) -> bool     lit_ids() -> Array
#   sealed() -> bool                 who() -> Array (the sids at the seal)
#   hatched() -> bool                egg_centroid(group = "") -> Vector3 (or null)
#   test API: test_light(id), test_snuff(id), test_seal(who: Array = [])
#   module hooks: hud_line, on_finish, finish_suffix, end_rows, on_session_ended, loop_ghost,
#   guestsim_report(pass = null), on_exit
# Dev test: maps/underdark/omen.flag ("" or "late"), marker user://zonda_omen_test.txt.
#   Solo: the forced death reloads the map and the test goes on after the reload (the marker).
#   In a session (loopback.flag) a death does NOT reload: ext/climber.gd respawns you beside a
#   teammate. The test then checks the omens on that same load ("respawn ..." lines: set 8, sealed,
#   no actionables, no new banner, eggs hidden, no second hatch, fires dark, burn_mult 2.0, bells
#   cracked, and the stored events still derive the sealed set), then runs the trophy steps.
#   OWNER DECISION 7A.6 (2026-09-25): no omen flame on the lantern cage at any tier; the charm
#   checks now assert that (the trophy stays on the end card and in the saved record).
# ============================================================================================

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const SKULL_SCRIPT := "res://mods-unpacked/zonda-CoopSync/maps/underdark/omen_skull.gd"
const SFX_RUMBLE := "res://sfx/soundsnap/304185-Chair-Rumble-Contact-Resonant-Distorted-Crisp-High.wav"
const SFX_EGGS := "res://sfx/MonsterIdeas/Teeth_02.wav"

const OMENS := [
	{"id": "hearth", "name": "THE COLD HEARTH", "short": "Hearth", "needs": "",
		"prompt": "light the candle: every fire in the rift goes out",
		"banner": "Every fire in the rift goes out.",
		"explain": "Every camp fire in the rift goes out, all the way down."},
	{"id": "thirst", "name": "THE THIRSTY FLAME", "short": "Thirst", "needs": "",
		"prompt": "light the candle: your lanterns drink twice as fast",
		"banner": "Every lantern drinks its oil twice as fast.",
		"explain": "Every lantern drinks its oil twice as fast."},
	{"id": "brood", "name": "THE EARLY BROOD", "short": "Brood", "needs": "eggs",
		"prompt": "light the candle: something hatches early",
		"banner": "Something has laid its eggs on the way down.",
		"explain": "A clutch of eggs waits on a shelf far below, and it hatches as you pass."},
	{"id": "follower", "name": "THE PATIENT ONE", "short": "Follower", "needs": "",
		"prompt": "light the candle: what follows you stays closer",
		"banner": "What follows you stays closer, and no bell will turn it.",
		"explain": "What follows you stays closer, and no bell will turn it."},
	{"id": "bells", "name": "THE CRACKED BELL", "short": "Bells", "needs": "",
		"prompt": "light the candle: the bells turn nothing",
		"banner": "The bells are cracked. Nothing turns toward them.",
		"explain": "The bells are cracked. Ringing one turns nothing away from you."},
	{"id": "bones", "name": "BRITTLE BONES", "short": "Bones", "needs": "",
		"prompt": "light the candle: hard landings hurt more",
		"banner": "Every hard landing hurts more.",
		"explain": "Every hard landing hurts more. A long fall still kills, as always."},
	{"id": "shrines", "name": "THE HOLLOW SHRINE", "short": "Shrines", "needs": "",
		"prompt": "light the candle: the fires barely heal",
		"banner": "The checkpoint fires barely heal you.",
		"explain": "A checkpoint fire heals you 20 instead of 60."},
	{"id": "silk", "name": "HUNGRY SILK", "short": "Silk", "needs": "",
		"prompt": "light the candle: the wall spiders wake hungry",
		"banner": "The wall spiders strike from further away and rest less.",
		"explain": "The wall spiders notice you from further away and are back sooner."},
]
const TIER_NAMES := ["", "BONE CHARM", "GRAVE CANDLE", "EMBER EYES", "THE FULL DARK"]
const LORE := "An altar of skulls, each with a cold candle. Light one and the dark takes something from all of you, all the way down. The more you carry, the finer what waits at the bottom."
const EGG_LORE := "Eggs, far from any nest. Something laid them on its way down."

# placement (wave 1, computed at runtime; L["omen_altar"] wins when the wave 2 layout has it)
const ALTAR_CENTRE := Vector3(2.0, 0.0, -8.0)
const SPAWN := Vector3(-30.0, 2.6, 6.0)
const RING_R := 3.4
const RAY_TOP := 6.0
const RAY_BOTTOM := -12.0
const PILLAR_TOP := 1.17          # pillar-small.glb (0.756 m) x1.55
const SKULL_TOP := 0.24           # Skull.glb (0.447 m) x0.55
const ALTAR_SIZE := Vector3(2.7, 1.27, 1.7)   # altar-stone.glb x2.6

# rules
const PRESS_WINDOW_MS := 8000
const CAP := 24
const REQ_TIMEOUT_MS := 2500
const SEAL_Y := -70.0
const HATCH_R := 30.0
const HATCH_DY := 8.0
const BONE := Color(0.78, 0.72, 0.62)
const BLOOD := Color(0.62, 0.08, 0.06)

# Early Brood eggs on THE SHELF III (wave 1): the six floor points B2 computed offline with GEN's
# Field.floor_below (two SHELF III stations; 60% of the walk, 0 / +-5 / +-10 m along it, pushed
# 10-16 m away from Rift.center(y); floor within 3 m), valid for this exact layout.json.
const SHELF_EGGS := {"md5": "b52e68d50856d5515696627ecce4adfb", "pos": [
	[394.24, -830.85, -33.75], [387.5, -830.85, -34.95], [386.0, -830.85, -33.23],
	[380.76, -830.85, -36.16], [377.51, -830.85, -35.41], [374.26, -830.85, -34.67]]}
const SHELF_A := Vector3(571.032, -830.749, -20.249)      # THE SHELF III, arrival
const SHELF_B := Vector3(277.194, -830.749, -33.758)      # THE SHELF III, exit corner

# dev test
const TEST_MARK := "user://zonda_omen_test.txt"
const TEST_COS := "user://zonda_omen_test_cos.cfg"

var map = null
var altar: Altar = null
var obrood: Node3D = null

# the state, derived from every stored key (R17)
var _lit: Array = []                # omen ids in lighting order
var _sealed := false
var _seal: Dictionary = {}
var _seq := 0
var _changes := 0
var _lit_by: Dictionary = {}        # id -> the name that lit it last
var _applied: Array = []            # the set whose effects this machine has applied
var _seal_applied := false
var _offer: Array = []              # ids whose needs are met (decided at load)
var _defaults: Dictionary = {}
var _seal_y := SEAL_Y               # anyone below it seals the altar (L.omen_altar.seal_y in wave 2)

# eggs
var _egg_groups: Dictionary = {}    # group -> {"pts": [Vector3], "n": int, "s": float}
var _egg_source := ""
var _egg_nodes: Dictionary = {}     # group -> [EggCluster]
var _egg_snapped: Dictionary = {}   # group -> true once snapped for looks
var _eggs_on := false
var _eggs_hidden := false
var _hatch_group := ""
var _egg_text: Area3D = null
var _lore: Area3D = null

# local input and requests
var _armed_id := ""
var _armed_act := ""
var _armed_until := 0
var _pending_ms := 0
var _last_refusal := ""

# timers
var _setup_ms := 0
var _seal_t := 0.0
var _hatch_t := 0.0
var _snap_t := 0.5
var _look_t := 0.0
var _thirst_t := 0.0

# trophy and counters
var _trophy: Dictionary = {}
var _banners := 0                   # omen banners shown in this map load (the reload test counts them)
var _test_trophy_ok := false

# guest simulation bookkeeping (2.11)
var _gs_b2_n := -1
var _gs_hatch_live := false

# dev test
var _test := ""                     # "" off, "run", "reload", "late"
var _test_loop := false
var _t := 0.0
var _step := 0
var _step_at := 0.0
var _pass := 0
var _fail: Array = []
var _vals: Dictionary = {}


# ------------------------------------------------------------------ setup

func setup(m) -> void:
	map = m
	_setup_ms = Time.get_ticks_msec()
	_capture_defaults()
	_load_eggs()
	for o in OMENS:
		if _needs_met(o):
			_offer.append(str(o["id"]))
	map.register_events(["omenreq_", "omenno_"], _on_request, true)
	map.register_events(["omenset_", "omen_seal", "omen_hatch"], _on_state_event, false)
	if _offer.has("brood"):
		_build_obrood()
	_build_altar()
	_build_eggs()
	_lore = map.add_text(altar.centre + Vector3(0, 1.0, 0), 7.0, LORE)
	_setup_test()


func _capture_defaults() -> void:
	_defaults = {
		"bruise_from": float(map.get("_bruise_from")), "bruise_per": float(map.get("_bruise_per")),
		"cp_heal": float(map.get("cp_heal")),
		"fol_far": float(map.get("fol_far")), "fol_stall": float(map.get("fol_stall")),
		"fol_stall_d": float(map.get("fol_stall_d")), "fol_min": float(map.get("fol_min")),
		"fol_max": float(map.get("fol_max")), "fol_aim": float(map.get("fol_aim")),
		"rest_s": 25.0, "trigger_r": 6.0,
	}
	for sp in map.get("_spiders"):
		if is_instance_valid(sp):
			var r = sp.get("rest_s")
			var t = sp.get("trigger_r")
			if r != null:
				_defaults["rest_s"] = float(r)
			if t != null:
				_defaults["trigger_r"] = float(t)
			break


func _needs_met(o: Dictionary) -> bool:
	if str(o.get("needs", "")) == "eggs":
		for g in _egg_groups.keys():
			if (_egg_groups[g]["pts"] as Array).size() >= 4:
				return true
		return false
	return true


# ------------------------------------------------------------------ public API

func tier_name(tier: int) -> String:
	return TIER_NAMES[clampi(tier, 0, TIER_NAMES.size() - 1)]


static func tier_for(n: int) -> int:
	# the same table as CoopSync.omen_tier_for: 0 / 1-2 / 3-5 / 6-7 / 8
	if n <= 0:
		return 0
	if n <= 2:
		return 1
	if n <= 5:
		return 2
	if n <= 7:
		return 3
	return 4


func omen_active(id: String) -> bool:
	return _lit.has(id)


func lit_ids() -> Array:
	return _lit.duplicate()


func sealed() -> bool:
	return _sealed


func who() -> Array:
	return _str_list(_seal.get("who", []))


func hatched() -> bool:
	return _hatch_group != ""


func egg_centroid(group: String = ""):
	var g := group
	if g == "" or not _egg_groups.has(g):
		if _egg_groups.is_empty():
			return null
		g = str(_egg_groups.keys()[0])
	var pts: Array = _egg_groups[g]["pts"]
	if pts.is_empty():
		return null
	var c := Vector3.ZERO
	for p in pts:
		c += p
	return c / float(pts.size())


func test_light(id: String) -> void:
	_request("light", id)


func test_snuff(id: String) -> void:
	_request("snuff", id)


func test_seal(who_list: Array = []) -> void:
	# the authority seals now (a test); an empty list means the real session
	if not CoopSync.map_is_authority() or _sealed:
		return
	_write_seal(who_list if not who_list.is_empty() else _session_ids(), CoopSync.local_name)


static func _omen(id: String) -> Dictionary:
	for o in OMENS:
		if str(o["id"]) == id:
			return o
	return {}


# ------------------------------------------------------------------ Steam ids (R1) through B1's
# CoopSync helpers when they exist, with the same rules otherwise (1A.1)

func _my_sid() -> String:
	if CoopSync.has_method("my_sid"):
		return str(CoopSync.call("my_sid"))
	var i: int = CoopSync.my_id()
	return str(i) if i != 0 else "local"


func _sid(v) -> String:
	if CoopSync.has_method("sid"):
		return str(CoopSync.call("sid", v))
	if v is String:
		return v
	if v is int:
		return str(v)
	return ""


func _is_me(v) -> bool:
	var s := _sid(v)
	return s != "" and s == _my_sid()


func _host_sid() -> String:
	if CoopSync.has_method("host_sid"):
		return str(CoopSync.call("host_sid"))
	if CoopSync.in_session():
		return str(CoopSync.get("_host_steam_id"))
	return _my_sid()


func _session_ids() -> Array:
	if CoopSync.has_method("session_ids"):
		var a = CoopSync.call("session_ids")
		if a is Array:
			return _str_list(a)
	var out: Array = [_my_sid()]
	for rp in CoopSync.remote_players():
		out.append(str(rp.get("peer_id")))
	return out


static func _str_list(a) -> Array:
	var out: Array = []
	if a is Array:
		for x in a:
			out.append(str(x))
	return out


static func _ids(a) -> Array:
	# known omen ids only, as Strings, no repeats, in order
	var out: Array = []
	if not (a is Array):
		return out
	for x in a:
		var s := str(x)
		if not out.has(s) and not _omen(s).is_empty():
			out.append(s)
	return out


func _banner(text: String, secs: float) -> void:
	_banners += 1
	CoopSync.show_banner(text, secs)


func _scene() -> String:
	return str(map.get("scene_file_path"))


# ------------------------------------------------------------------ requests (R4)

func _on_press(id: String) -> void:
	# the local player pressed E on a skull (omen_skull.gd -> Altar.on_press)
	if _sealed:
		return
	var o := _omen(id)
	if o.is_empty():
		return
	var lit := _lit.has(id)
	if lit and not _host_or_solo():
		_banner("Lit by %s. Only the host can snuff it." % str(_lit_by.get(id, "a teammate")), 4.0)
		return
	if not lit and not _offer.has(id):
		_banner("This candle will not take.", 3.0)
		return
	var act := "snuff" if lit else "light"
	var now := Time.get_ticks_msec()
	if _armed_id == id and _armed_act == act and now < _armed_until:
		_armed_id = ""
		_request(act, id)
		return
	_armed_id = id
	_armed_act = act
	_armed_until = now + PRESS_WINDOW_MS
	if act == "light":
		_banner("%s. %s Press E again to light it. The whole team carries it." % [str(o["name"]), str(o["explain"])], 6.0)
	else:
		_banner("Press E again to snuff %s." % str(o["name"]), 5.0)


func _host_or_solo() -> bool:
	return not CoopSync.in_session() or CoopSync.is_host


func _request(act: String, id: String) -> void:
	if not CoopSync.map_is_authority():
		_pending_ms = Time.get_ticks_msec()
	CoopSync.map_event("omenreq_" + id, {"act": act, "by": CoopSync.local_name}, false)


func _on_request(key: String, data: Dictionary, _replay: bool) -> void:
	if key.begins_with("omenno_"):
		if _is_me(data.get("to", "")):
			_pending_ms = 0
			_refusal_banner(str(data.get("why", "")))
		return
	# only the authority decides; everyone else waits for the omenset it writes
	if not CoopSync.map_is_authority():
		return
	var id := key.substr(8)
	var act := str(data.get("act", ""))
	var from := _sid(data.get("_from", _my_sid()))
	var why := _refuse_why(id, act, from)
	if why != "":
		_last_refusal = "%s %s %s" % [act, from, why]
		print("[OMEN] refused %s from %s" % [act, from])
		print("[OMEN] (why: %s)" % why)
		if from == _my_sid():
			_refusal_banner(why)
		else:
			CoopSync.map_event("omenno_" + id, {"to": from, "why": why}, false)
		return
	var lit := _lit.duplicate()
	if act == "light":
		lit.append(id)
	else:
		lit.erase(id)
	var seq := _seq + 1
	CoopSync.map_event("omenset_%d" % seq, {"seq": seq, "lit": lit, "act": act, "id": id,
			"by": str(data.get("by", "")), "req": from})


func _refuse_why(id: String, act: String, from: String) -> String:
	if _sealed:
		return "sealed"
	if _omen(id).is_empty() or not _offer.has(id):
		return "unknown"
	if act == "light":
		if _lit.has(id):
			return "lit"
	elif act == "snuff":
		if not _lit.has(id):
			return "unlit"
		if CoopSync.in_session() and from != _host_sid():
			return "host"
	else:
		return "act"
	if _changes >= CAP:
		return "cap"
	return ""


func _refusal_banner(why: String) -> void:
	if why == "cap":
		_banner("The altar will not change again.", 5.0)
	elif why == "host":
		_banner("Only the host can snuff a candle.", 4.0)
	elif why == "sealed":
		_banner("The altar is sealed.", 3.0)


# ------------------------------------------------------------------ state (R17)

func _on_state_event(key: String, data: Dictionary, replay: bool) -> void:
	if key == "omen_hatch":
		_on_hatch(data, replay)
		return
	var was_sealed := _sealed
	var before := _lit.duplicate()
	_derive()
	if key.begins_with("omenset_"):
		if _is_me(data.get("req", "")):
			_pending_ms = 0
		var seq := int(data.get("seq", 0))
		print("[OMEN] set seq=%d lit=%s%s" % [seq, ",".join(_ids(data.get("lit", []))), " (replay)" if replay else ""])
		# live, and only when this is the newest set and it changed something here
		if not replay and not _sealed and seq == _seq and before != _lit:
			var o := _omen(str(data.get("id", "")))
			var by := str(data.get("by", ""))
			if by == "":
				by = "Someone"
			if not o.is_empty():
				var pos := altar.skull_pos(str(o["id"])) if altar != null else Vector3.ZERO
				if str(data.get("act", "")) == "light":
					_banner("%s lit %s. %s" % [by, str(o["name"]), str(o["banner"])], 6.0)
					_play_kind("omen_light", pos, func(): Game.audio.play_dark_transition2())
				else:
					_banner("%s snuffed %s." % [by, str(o["name"])], 6.0)
					_play_kind("omen_snuff", pos, Callable())
	elif key == "omen_seal" and not was_sealed:
		print("[OMEN] sealed lit=%d who=[%s]%s" % [_lit.size(), ",".join(who()), " (replay)" if replay else ""])
	_refresh(replay)


func _derive() -> void:
	_derive_from(CoopSync.map_events_for(_scene()))
	var h = CoopSync.map_events_for(_scene()).get("omen_hatch")
	if h is Dictionary and _hatch_group == "":
		_hatch_group = str((h as Dictionary).get("group", "shelf"))


func _derive_from(ev: Dictionary) -> void:
	# pure: the lit set from the stored keys. The seal wins; else the highest omenset seq.
	var best := -1
	var best_lit: Array = []
	var sets: Array = []
	for k in ev.keys():
		var ks := str(k)
		if not ks.begins_with("omenset_"):
			continue
		var d = ev[k]
		if not (d is Dictionary):
			continue
		var s := int((d as Dictionary).get("seq", int(ks.substr(8))))
		sets.append([s, d])
		if s > best:
			best = s
			best_lit = _ids((d as Dictionary).get("lit", []))
	sets.sort_custom(func(a, b): return int(a[0]) < int(b[0]))
	var by := {}
	for e in sets:
		var d2: Dictionary = e[1]
		if str(d2.get("act", "")) == "light":
			by[str(d2.get("id", ""))] = str(d2.get("by", ""))
	_changes = sets.size()
	_seq = maxi(best, 0)
	_lit_by = by
	var seal = ev.get("omen_seal")
	if seal is Dictionary:
		_sealed = true
		_seal = seal
		_lit = _ids((seal as Dictionary).get("lit", []))
		_seq = maxi(_seq, int((seal as Dictionary).get("seq", 0)))
	else:
		_sealed = false
		_seal = {}
		_lit = best_lit


func _refresh(quiet: bool) -> void:
	# apply what changed between the set this machine shows and the derived one
	for o in OMENS:
		var id := str(o["id"])
		var on := _lit.has(id)
		if on != _applied.has(id):
			_apply_effect(id, on, quiet)
	_applied = _lit.duplicate()
	if altar != null:
		altar.set_lit(_lit, quiet)
	if _sealed and not _seal_applied:
		_apply_seal(quiet)
	_refresh_prompts()


func _apply_effect(id: String, on: bool, quiet: bool) -> void:
	var secs := 0.0 if quiet else 1.2
	match id:
		"hearth":
			for e in map.fire_nodes:
				map.set_fire_lit(e, not on, secs)
			if on:
				map.clear_foundry_heat()
			else:
				map.refresh_foundry_heat()
		"thirst":
			_set_burn(2.0 if on else 1.0)
		"brood":
			_show_eggs(on and _hatch_group == "")
		"follower":
			for k in ["fol_far", "fol_stall", "fol_stall_d", "fol_min", "fol_max", "fol_aim"]:
				map.set(k, float(_defaults[k]))
			if on:
				map.set("fol_far", 130.0)
				map.set("fol_stall", 18.0)
				map.set("fol_stall_d", 40.0)
				map.set("fol_min", 50.0)
				map.set("fol_max", 95.0)
				map.set("fol_aim", 70.0)
			map.set("follower_no_lure", on)
			var f = map.get("_follower")
			if is_instance_valid(f):
				if on:
					(f as Node).set_meta("zonda_no_lure", true)
				elif not bool(map.get("_idol_taken")) and (f as Node).has_meta("zonda_no_lure"):
					(f as Node).remove_meta("zonda_no_lure")
		"bells":
			var bells = map.get("_bells")
			if bells is Dictionary:
				for b in (bells as Dictionary).values():
					if is_instance_valid(b):
						b.set("cracked", on)
		"bones":
			map.set("_bruise_from", 16.0 if on else float(_defaults["bruise_from"]))
			map.set("_bruise_per", 5.5 if on else float(_defaults["bruise_per"]))
		"shrines":
			map.set("cp_heal", 20.0 if on else float(_defaults["cp_heal"]))
		"silk":
			for sp in map.get("_spiders"):
				if is_instance_valid(sp):
					sp.set("rest_s", 9.0 if on else float(_defaults["rest_s"]))
					sp.set("trigger_r", 8.0 if on else float(_defaults["trigger_r"]))


func _set_burn(k: float) -> void:
	var ln = CoopSync.lantern
	if is_instance_valid(ln) and "burn_mult" in ln:
		ln.set("burn_mult", k)


func _apply_seal(quiet: bool) -> void:
	_seal_applied = true
	_armed_id = ""
	if altar != null:
		altar.seal(quiet)
	if _lit.has("hearth"):
		# for good: their lights and flickers go
		for e in map.fire_nodes:
			map.set_fire_lit(e, false, 0.0)
			map.free_fire_light(e)
		map.clear_foundry_heat()
	if is_instance_valid(_lore):
		_lore.queue_free()
	_lore = null
	if not quiet:
		var n := _lit.size()
		if n == 0:
			_banner("The altar seals. You go down with no omens.", 7.0)
		elif n == 1:
			_banner("The altar seals behind you. 1 omen goes down with you.", 7.0)
		else:
			_banner("The altar seals behind you. %d omens go down with you." % n, 7.0)


func _write_seal(who_list: Array, by: String) -> void:
	CoopSync.map_event("omen_seal", {"lit": _lit.duplicate(), "who": _str_list(who_list), "by": by, "seq": _seq})


func _refresh_prompts() -> void:
	if altar == null or _sealed:
		return
	var host := _host_or_solo()
	for o in OMENS:
		var id := str(o["id"])
		var txt := str(o["prompt"])
		if _lit.has(id):
			if host:
				txt = "snuff the candle"
			else:
				txt = "lit by %s. Only the host can snuff it." % str(_lit_by.get(id, "a teammate"))
		elif not _offer.has(id):
			txt = "this candle will not take"
		altar.set_prompt(id, txt)


# ------------------------------------------------------------------ per frame

func _process(delta: float) -> void:
	if map == null or not is_instance_valid(map):
		return
	var now := Time.get_ticks_msec()
	if _pending_ms > 0 and now - _pending_ms > REQ_TIMEOUT_MS:
		_pending_ms = 0
		_banner("The altar did not answer.", 3.0)
	if _armed_id != "" and now > _armed_until:
		_armed_id = ""
	_seal_t -= delta
	if _seal_t <= 0.0:
		_seal_t = 0.5
		_seal_check()
	if _lit.has("brood") and _hatch_group == "":
		_hatch_t -= delta
		if _hatch_t <= 0.0:
			_hatch_t = 0.25
			_hatch_check()
	_snap_t -= delta
	if _snap_t <= 0.0:
		_snap_t = 0.5
		if altar != null and not altar.snapped:
			altar.try_snap()
		_snap_eggs()
	_look_t -= delta
	if _look_t <= 0.0:
		_look_t = 1.0
		_refresh_prompts()
	if _lit.has("thirst"):
		_thirst_t -= delta
		if _thirst_t <= 0.0:
			_thirst_t = 1.0
			_set_burn(2.0)               # a lantern rebuilt by a level change starts at 1.0 again
	if _test != "":
		_t += delta
		_test_step()


func _seal_check() -> void:
	# the authority seals at THE RIFT checkpoint, when anyone drops below the lip, or when the
	# Follower wakes. It also covers a load past checkpoint 0 with no seal stored (a crash).
	if _sealed or not CoopSync.map_is_authority():
		return
	if Time.get_ticks_msec() - _setup_ms < 1500 or not bool(map.call("load_announced")):
		return                               # let the stored events replay first
	if CoopSync.has_method("save_prompt_open") and bool(CoopSync.call("save_prompt_open")):
		return
	var go: bool = CoopSync.map_checkpoint_for(_scene()) >= 0 or CoopSync.map_event_done("cent_follower")
	if not go:
		for p in CoopSync.alive_player_nodes():
			if is_instance_valid(p) and (p as Node3D).global_position.y < _seal_y:
				go = true
				break
	if go:
		_write_seal(_session_ids(), CoopSync.local_name)


# ------------------------------------------------------------------ the altar

func _build_altar() -> void:
	var centre := ALTAR_CENTRE
	var face := SPAWN - ALTAR_CENTRE
	var ids: Array = []
	for o in OMENS:
		ids.append(str(o["id"]))
	var la = map.L.get("omen_altar", null)
	var skulls_at: Dictionary = {}
	if la is Dictionary and (la as Dictionary).has("pos"):
		# wave 2: the generator's placement wins
		_seal_y = float(la.get("seal_y", SEAL_Y))
		var p = la["pos"]
		centre = Vector3(float(p[0]), float(p[1]), float(p[2]))
		var yaw := float(la.get("yaw", 0.0))
		face = Vector3(-sin(yaw), 0.0, -cos(yaw))
		for s in la.get("skulls", []):
			if s is Dictionary and s.has("pos"):
				var q = s["pos"]
				skulls_at[str(s.get("id", ""))] = Vector3(float(q[0]), float(q[1]), float(q[2]))
	altar = Altar.new()
	altar.name = "OmenAltar"
	add_child(altar)
	altar.build(map, self, centre, face, ids, skulls_at, la is Dictionary and (la as Dictionary).has("pos"))


# ------------------------------------------------------------------ the Early Brood

func _load_eggs() -> void:
	_egg_groups.clear()
	var lo = map.L.get("omen_eggs", null)
	if lo is Array and not (lo as Array).is_empty():
		for e in lo:
			if not (e is Dictionary) or not (e as Dictionary).has("pos"):
				continue
			var g := str(e.get("group", "shelf"))
			if not _egg_groups.has(g):
				_egg_groups[g] = {"pts": [], "n": int(e.get("n", 5)), "s": float(e.get("s", 0.6))}
			var p = e["pos"]
			(_egg_groups[g]["pts"] as Array).append(Vector3(float(p[0]), float(p[1]), float(p[2])))
		_egg_source = "layout"
	else:
		var pts: Array = []
		if FileAccess.get_md5(DIR + "layout.json") == str(SHELF_EGGS["md5"]):
			for p2 in SHELF_EGGS["pos"]:
				pts.append(Vector3(float(p2[0]), float(p2[1]), float(p2[2])))
			_egg_source = "table"
		else:
			# a changed layout without omen_eggs: 6 points on the line between the two SHELF III
			# stations, at station height (floor there by construction)
			var a := SHELF_A
			var b := SHELF_B
			var st: Array = []
			for s in map.L.get("stations", []):
				if s is Dictionary and str(s.get("label", "")) == "THE SHELF III":
					st.append(s["pos"])
			if st.size() >= 2:
				a = Vector3(float(st[0][0]), float(st[0][1]), float(st[0][2]))
				b = Vector3(float(st[1][0]), float(st[1][1]), float(st[1][2]))
			for i in 6:
				pts.append(a.lerp(b, 0.45 + 0.06 * float(i)))
			_egg_source = "fallback"
		_egg_groups["shelf"] = {"pts": pts, "n": 5, "s": 0.6}
	for g2 in _egg_groups.keys():
		print("[OMEN] eggs %s n=%d source=%s" % [g2, (_egg_groups[g2]["pts"] as Array).size(), _egg_source])


func _build_eggs() -> void:
	for g in _egg_groups.keys():
		var nodes: Array = []
		for p in _egg_groups[g]["pts"]:
			var eg = map.make_egg_cluster(p, int(_egg_groups[g]["n"]), float(_egg_groups[g]["s"]))
			if eg == null:
				continue
			eg.visible = false
			eg.set_process(false)
			add_child(eg)
			nodes.append(eg)
		_egg_nodes[g] = nodes


func _show_eggs(on: bool) -> void:
	_eggs_on = on
	for g in _egg_nodes.keys():
		for eg in _egg_nodes[g]:
			if is_instance_valid(eg):
				eg.visible = on
				eg.set_process(on)
	if on and _egg_text == null:
		_egg_text = map.add_text(SHELF_A + Vector3(0, 1.0, 0), 10.0, EGG_LORE)
	elif not on and is_instance_valid(_egg_text):
		_egg_text.queue_free()
		_egg_text = null


func _hide_eggs() -> void:
	_eggs_hidden = true
	_show_eggs(false)


func _snap_eggs() -> void:
	# for looks only (within +-1.5 m of the data y) once the local player is within 150 m: the
	# trigger and the offer never depend on a ray
	if not _eggs_on:
		return
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	for g in _egg_nodes.keys():
		if _egg_snapped.has(g):
			continue
		var cen = egg_centroid(str(g))
		if not (cen is Vector3) or (c.global_position as Vector3).distance_to(cen) > 150.0:
			continue
		var space: PhysicsDirectSpaceState3D = (map as Node3D).get_world_3d().direct_space_state
		for eg in _egg_nodes[g]:
			if not is_instance_valid(eg):
				continue
			var p: Vector3 = eg.position
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.5, p + Vector3.DOWN * 1.5, 1))
			if not hit.is_empty():
				eg.position = Vector3(p.x, (hit["position"] as Vector3).y, p.z)
		_egg_snapped[g] = true


func _build_obrood() -> void:
	var g := str(_egg_groups.keys()[0])
	for k in _egg_groups.keys():
		if (_egg_groups[k]["pts"] as Array).size() >= 4:
			g = str(k)
			break
	obrood = map.new_brood({"points": (_egg_groups[g]["pts"] as Array).duplicate(), "count": 10,
			"tag": "obrood", "hunts_idol": false})
	if obrood == null:
		return
	obrood.name = "EarlyBrood"
	add_child(obrood)
	map.register_bites("obrood:", obrood)
	map.register_threats(obrood)
	map.register_stream("b2", _b2_send, _b2_recv)


func _b2_send():
	if is_instance_valid(obrood) and obrood.is_hatched() and float(obrood.get("clock")) < 80.0:
		return obrood.state_packet()
	return null


func _b2_recv(v) -> void:
	if not is_instance_valid(obrood) or not (v is Array):
		return
	obrood.remote_state(v)
	if _gs_b2_n < 0 and obrood.is_hatched():
		var cr = obrood.get("crawlers")
		_gs_b2_n = (cr as Array).size() if cr is Array else 0


func _hatch_check() -> void:
	# the authority, from every alive player's position on its own view (R4)
	if not CoopSync.map_is_authority() or not _offer.has("brood"):
		return
	if CoopSync.map_event_done("omen_hatch"):
		return
	for g in _egg_groups.keys():
		var cen = egg_centroid(str(g))
		if not (cen is Vector3) or (_egg_groups[g]["pts"] as Array).size() < 4:
			continue
		for p in CoopSync.alive_player_nodes():
			if not is_instance_valid(p):
				continue
			var q: Vector3 = (p as Node3D).global_position
			if Vector2(q.x - cen.x, q.z - cen.z).length() < HATCH_R and absf(q.y - cen.y) < HATCH_DY:
				var by := CoopSync.local_name if p == Game.climber else str(p.get("player_name"))
				CoopSync.map_event("omen_hatch", {"group": str(g), "by": by})
				return


func _on_hatch(data: Dictionary, replay: bool) -> void:
	var first := _hatch_group == ""
	_hatch_group = str(data.get("group", "shelf"))
	_hide_eggs()
	if is_instance_valid(_egg_text):
		_egg_text.queue_free()
	_egg_text = null
	if replay or not first:
		return            # a replay only hides the eggs: never hatch, never set Brood.hatched
	_gs_hatch_live = true
	var cen = egg_centroid(_hatch_group)
	print("[OMEN] hatch group=%s by=%s" % [_hatch_group, str(data.get("by", ""))])
	if cen is Vector3:
		_egg_burst(cen)
	if CoopSync.map_is_authority() and is_instance_valid(obrood):
		if _egg_groups.has(_hatch_group):
			obrood.set("points", (_egg_groups[_hatch_group]["pts"] as Array).duplicate())
		obrood.hatch()


func _egg_burst(at: Vector3) -> void:
	# the clutch splits: a wet crunch and a scatter of claws (the guests' crawlers come with b2)
	var p := AudioStreamPlayer3D.new()
	p.stream = load(SFX_EGGS)
	p.volume_db = 2.0
	p.pitch_scale = 0.8
	p.max_distance = 60.0
	p.bus = &"ZondaCave" if AudioServer.get_bus_index("ZondaCave") >= 0 else &"MainBus"
	p.position = at + Vector3.UP * 0.5
	(map as Node).add_child(p)
	p.play()
	p.finished.connect(p.queue_free)
	_play_kind("brood_skitter", at, Callable())


func _play_kind(kind: String, pos: Vector3, fallback: Callable) -> void:
	# a manifest oneshot through the soundscape when the kind exists (B6), else the fallback
	var ss = map.get("_ss")
	var has := false
	if is_instance_valid(ss):
		var man = ss.get("manifest")
		if man is Dictionary:
			var one = (man as Dictionary).get("oneshots", {})
			has = one is Dictionary and (one as Dictionary).has(kind) and not ((one as Dictionary)[kind] as Array).is_empty()
	if has and ss.has_method("play_oneshot"):
		ss.call("play_oneshot", kind, pos)
	elif fallback.is_valid():
		fallback.call()


# ------------------------------------------------------------------ module hooks

func hud_line() -> String:
	if not _sealed:
		return "ALTAR OPEN   %d of %d lit   it seals at THE RIFT" % [_lit.size(), _offer.size()]
	if _lit.is_empty():
		return ""
	var names: PackedStringArray = []
	for id in _lit:
		names.append(str(_omen(str(id)).get("short", id)))
	return "OMENS %d   %s" % [_lit.size(), "  ".join(names)]


func on_finish(_by: String, _data: Dictionary) -> void:
	if is_instance_valid(obrood):
		obrood.clear()
	_trophy = {}
	var n := _lit.size() if _sealed else 0
	if n == 0:
		return
	if not who().has(_my_sid()):
		_trophy = {"none": "late"}
		print("[OMEN] trophy none: not at the seal")
		return
	var c = Game.climber
	var blocked: bool = bool(map.get("_debug_tour")) or (is_instance_valid(c) and bool(c.get("prevent_player_death")))
	if blocked and not _test_trophy_ok:
		_trophy = {"none": "test"}
		print("[OMEN] trophy none: a test run")
		return
	if not CoopSync.has_method("omen_grant"):
		_trophy = {"tier": tier_for(n), "best": n, "new": false, "nogrant": true}
		push_warning("[OMEN] CoopSync.omen_grant() is missing: the trophy was not stored")
		return
	var r = CoopSync.call("omen_grant", "underdark", n)
	if r is Dictionary:
		_trophy = r
	else:
		_trophy = {"tier": tier_for(n), "best": n, "new": false}
	var tier := int(_trophy.get("tier", tier_for(n)))
	print("[OMEN] trophy tier %d %s new=%s best=%d" % [tier, tier_name(tier), str(bool(_trophy.get("new", false))), int(_trophy.get("best", n))])


func finish_suffix() -> String:
	var n := _lit.size() if _sealed else 0
	if n == 0:
		return ""
	return ", under 1 omen" if n == 1 else ", under %d omens" % n


func end_rows() -> Array:
	var n := _lit.size() if _sealed else 0
	if n == 0:
		return []
	var shorts: PackedStringArray = []
	for id in _lit:
		shorts.append(str(_omen(str(id)).get("short", id)))
	var rows: Array = [["Omens carried   %d / %d   (%s)" % [n, OMENS.size(), ", ".join(shorts)], 11, BONE]]
	if _trophy.has("none"):
		if str(_trophy["none"]) == "late":
			rows.append(["Trophy   none: you joined after the altar sealed", 11, BONE])
		return rows
	if _trophy.is_empty():
		return rows
	var tier := int(_trophy.get("tier", tier_for(n)))
	var txt := "Trophy   %s" % tier_name(tier)
	if not _trophy.has("nogrant"):
		if bool(_trophy.get("new", false)):
			txt += "  (new)"
		else:
			txt += "  (you already have %s)" % tier_name(tier_for(int(_trophy.get("best", n))))
	rows.append([txt, 11, BLOOD if tier >= 4 else BONE])
	return rows


func on_session_ended() -> void:
	# the host left: this machine may be the authority now, and may snuff and seal
	_pending_ms = 0
	_refresh_prompts()


func loop_ghost(_key: String, _data: Dictionary) -> void:
	pass                                 # the Ghost never sends omen requests of its own


func on_exit() -> void:
	_armed_id = ""


func guestsim_report(_pass = null) -> Array:
	# 2.11. Called on the live pass and again on the fresh map after the late-join mapsync (CoopSync
	# keeps the "late join" line from the second call only). The optional argument lets a caller
	# name the pass; every line is always returned, so either calling style works.
	var out: Array = []
	if _gs_b2_n < 0:
		out.append("SKIP obrood built (no b2 packet in the recording)")
	elif _gs_b2_n == 10:
		out.append("PASS obrood built n=10 from b2")
	else:
		out.append("FAIL obrood built n=%d from b2" % _gs_b2_n)
	if not _gs_hatch_live:
		out.append("SKIP eggs hidden (no live omen_hatch in the recording)")
	elif _eggs_hidden:
		out.append("PASS eggs hidden")
	else:
		out.append("FAIL eggs hidden")
	var stored_hatch := CoopSync.map_event_done("omen_hatch")
	if not stored_hatch and _lit.is_empty():
		out.append("SKIP late join (no omens in the recording)")
	else:
		var eggs_ok: bool = not stored_hatch or _eggs_hidden
		var crawlers := 0
		if is_instance_valid(obrood):
			crawlers = (obrood.threat_positions() as Array).size()
		var dark := 0
		for e in map.fire_nodes:
			if not bool(e.get("lit", true)):
				dark += 1
		var fires_ok: bool = not _lit.has("hearth") or dark == map.fire_nodes.size()
		var line := "late join: eggs hidden, 0 crawlers, fires dark"
		if eggs_ok and crawlers == 0 and fires_ok:
			out.append("PASS " + line)
		else:
			out.append("FAIL %s (eggs_ok=%s crawlers=%d fires dark %d/%d)" % [line, str(eggs_ok), crawlers, dark, map.fire_nodes.size()])
	return out


# ------------------------------------------------------------------ dev test (omen.flag)

func _setup_test() -> void:
	var flag = map.dev_flag("omen.flag")
	if flag != null:
		_test = "late" if str(flag).to_lower() == "late" else "run"
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_MARK))
	elif FileAccess.file_exists(TEST_MARK):
		# the same test after its death reload (the marker is honoured for 3 minutes only)
		var d = JSON.parse_string(FileAccess.get_file_as_string(TEST_MARK))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_MARK))
		if d is Dictionary and Time.get_unix_time_from_system() - float(d.get("t", 0.0)) < 180.0:
			_test = "reload"
			_pass = int(d.get("pass", 0))
			_fail = _str_list(d.get("fail", []))
	if _test == "":
		return
	map.call("_use_test_files")          # 1A.2: the test save folder and cosmetics file
	_test_loop = bool(CoopSync.get("_loopback"))
	if _test_loop:
		CoopSync.set("_loop_step", 7)     # the loopback's own soul and spectate script stays out
	print("[OMEN] test %s%s" % [_test, " (loopback)" if _test_loop else ""])


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("[OMEN] PASS %s %s" % [name, detail])
	else:
		_fail.append(name)
		print("[OMEN] FAIL %s %s" % [name, detail])


func _at(secs: float) -> bool:
	# the step's wait is over: next step
	if _t - _step_at < secs:
		return false
	_step_at = _t
	_step += 1
	return true


func _test_step() -> void:
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	if _test == "run":
		_test_run(c)
	elif _test == "reload":
		_test_reload(c)
	elif _test == "late":
		_test_late(c)


func _fires_dark() -> int:
	var n := 0
	for e in map.fire_nodes:
		if not bool(e.get("lit", true)):
			n += 1
	return n


func _bells_cracked() -> int:
	var n := 0
	var bells = map.get("_bells")
	if bells is Dictionary:
		for b in (bells as Dictionary).values():
			if is_instance_valid(b) and bool(b.get("cracked")):
				n += 1
	return n


func _test_run(c) -> void:
	match _step:
		0:
			if _t < 3.0:
				return
			_step_at = _t
			_step = 1
			c.prevent_player_death = true
			var n := (_egg_groups.get("shelf", {"pts": []})["pts"] as Array).size()
			_check("eggs", _egg_source == "table" and n >= 4, "shelf n=%d source=%s" % [n, _egg_source])
			map.debug_park(altar.centre + altar.fwd * 9.0 + Vector3.UP * 1.0)
		1:
			if _at(1.2):
				map.debug_look(altar.centre + Vector3.UP * 1.2)
				map.debug_shot("user://underdark_omen_altar_0.png")
				test_light("hearth")
		2:
			if _at(0.5):
				test_light("thirst")
		3:
			if _at(0.5):
				test_light("bells")
		4:
			if _at(1.5):
				_check("set seq=3", _seq == 3 and _lit == ["hearth", "thirst", "bells"], "seq=%d lit=%s" % [_seq, ",".join(_lit)])
				map.debug_shot("user://underdark_omen_altar_1.png")
				_check("mouth fire out", _fires_dark() == map.fire_nodes.size(), "%d/%d dark" % [_fires_dark(), map.fire_nodes.size()])
				test_snuff("bells")
		5:
			if _at(1.0):
				_check("snuff seq=4", _seq == 4 and not _lit.has("bells"), "seq=%d lit=%s" % [_seq, ",".join(_lit)])
				test_light("bells")
		6:
			if _at(1.0):
				_check("relight seq=5", _seq == 5 and _lit == ["hearth", "thirst", "bells"], "seq=%d lit=%s" % [_seq, ",".join(_lit)])
				if _test_loop:
					map.coop_map_event("omenreq_silk", {"act": "light", "_from": "777", "by": "Ghost"}, false)
				else:
					_step = 8
		7:
			if _at(1.0):
				_check("ghost lights silk seq=6", _seq == 6 and _lit.has("silk"), "seq=%d lit=%s" % [_seq, ",".join(_lit)])
				_last_refusal = ""
				map.coop_map_event("omenreq_silk", {"act": "snuff", "_from": "777", "by": "Ghost"}, false)
		8:
			if _at(1.0):
				if _test_loop:
					_check("refused snuff from 777", _last_refusal.begins_with("snuff 777") and _lit.has("silk"), _last_refusal)
				for o in OMENS:
					if not _lit.has(str(o["id"])):
						test_light(str(o["id"]))
		9:
			if _at(1.0):
				_check("all 8 lit", _lit.size() == 8, "lit=%s" % ",".join(_lit))
				print("[OMEN] hud: %s" % hud_line())
				var cp0 := Vector3.ZERO
				for k in map.L.get("checkpoints", []):
					if int(k["id"]) == 0:
						cp0 = Vector3(float(k["pos"][0]), float(k["pos"][1]), float(k["pos"][2]))
				map.debug_park(cp0 + Vector3.UP * 0.3)
		10:
			if _at(2.5):
				_check("sealed", _sealed and _lit.size() == 8 and who().has(_my_sid()), "lit=%d who=[%s]" % [_lit.size(), ",".join(who())])
				_check("0 actionables", altar.area_count() == 0, "%d" % altar.area_count())
				_check("hearth", _fires_dark() == map.fire_nodes.size() and (map.get("_foundry_fires") as Array).is_empty(),
						"fires %d/%d dark, foundry %d" % [_fires_dark(), map.fire_nodes.size(), (map.get("_foundry_fires") as Array).size()])
				_check("bells cracked", _bells_cracked() == 2, "%d/2" % _bells_cracked())
				_check("bones", is_equal_approx(float(map.get("_bruise_from")), 16.0) and is_equal_approx(float(map.get("_bruise_per")), 5.5) and is_equal_approx(float(map.get("_lethal_fall")), 38.0),
						"%.1f / %.1f / %.1f" % [float(map.get("_bruise_from")), float(map.get("_bruise_per")), float(map.get("_lethal_fall"))])
				_check("shrines", is_equal_approx(float(map.get("cp_heal")), 20.0), "cp_heal %.0f" % float(map.get("cp_heal")))
				var ok_s := 0
				var sps = map.get("_spiders")
				for sp in sps:
					if is_instance_valid(sp) and sp.get("rest_s") != null and is_equal_approx(float(sp.get("rest_s")), 9.0) and is_equal_approx(float(sp.get("trigger_r")), 8.0):
						ok_s += 1
				_check("silk", ok_s == (sps as Array).size() and ok_s > 0, "%d/%d spiders at 9 / 8" % [ok_s, (sps as Array).size()])
				var fol_ok: bool = is_equal_approx(float(map.get("fol_far")), 130.0) and is_equal_approx(float(map.get("fol_stall")), 18.0) and is_equal_approx(float(map.get("fol_stall_d")), 40.0) and is_equal_approx(float(map.get("fol_min")), 50.0) and is_equal_approx(float(map.get("fol_max")), 95.0) and is_equal_approx(float(map.get("fol_aim")), 70.0) and bool(map.get("follower_no_lure"))
				_check("follower knobs", fol_ok, "")
				CoopSync.map_event("bell_bell1", {}, false)
		11:
			if _at(0.6):
				_check("bell no lure", not CoopSync.lure_active(), "")
				# THIRST: 5 s of forced lit burn with the tour guard off (lantern.gd never burns for an invincible knight)
				var ln = CoopSync.lantern
				_vals["user"] = ln.get("user")
				ln.set("user", 1)
				c.prevent_player_death = false
				_vals["oil0"] = float(ln.get("oil"))
		12:
			if _at(5.0):
				var ln2 = CoopSync.lantern
				var d_oil: float = float(_vals["oil0"]) - float(ln2.get("oil"))
				_check("thirst", absf(d_oil - 0.0139) <= 0.002 and is_equal_approx(float(ln2.get("burn_mult") if ln2.get("burn_mult") != null else 0.0), 2.0),
						"delta oil %.4f over 5 s, burn_mult %s" % [d_oil, str(ln2.get("burn_mult"))])
				ln2.set("user", _vals["user"])
				c.prevent_player_death = true
				if not bool(map.get("_spawned_cents").has("follower")):
					CoopSync.map_event("cent_follower", {"id": "follower"})
		13:
			if _at(1.5):
				var f = map.get("_follower")
				_check("follower no lure", is_instance_valid(f) and (f as Node).has_meta("zonda_no_lure"), "")
				map.debug_park(SHELF_A + Vector3.UP * 1.0)
		14:
			if _at(1.2):
				var cen = egg_centroid("shelf")
				if cen is Vector3:
					var dir := Vector3(SHELF_A.x - cen.x, 0.0, SHELF_A.z - cen.z).normalized()
					map.debug_park(Vector3(cen.x, SHELF_A.y + 1.0, cen.z) + dir * 25.0)
		15:
			if _hatch_group != "" or _t - _step_at > 8.0:
				_check("hatch", _hatch_group != "", "group=%s" % _hatch_group)
				_step_at = _t
				_step = 16
		16:
			if _at(4.0):
				var n_alive := (obrood.threat_positions() as Array).size() if is_instance_valid(obrood) else 0
				_check("brood 10 crawlers", n_alive == 10, "%d alive" % n_alive)
				var cen2 = egg_centroid("shelf")
				if cen2 is Vector3:
					map.debug_look(cen2)
				map.debug_shot("user://underdark_omen_brood.png")
		17:
			if _at(0.5):
				if CoopSync.in_session():
					_coop_death(c)                   # step 18 waits for the co-op respawn
					return
				var f2 := FileAccess.open(TEST_MARK, FileAccess.WRITE)
				if f2 != null:
					f2.store_string(JSON.stringify({"t": Time.get_unix_time_from_system(), "pass": _pass, "fail": _fail}))
					f2.close()
				print("[OMEN] dying for the reload check (%d passed so far)" % _pass)
				c.prevent_player_death = false
				c.health = 0.0
				c.took_lethal_damage()
				_test = ""
		18:
			_coop_respawn_wait(c)


func _test_reload(c) -> void:
	match _step:
		0:
			if _t < 3.0:
				return
			_step_at = _t
			_step = 1
			c.prevent_player_death = true
			_persist_checks("reload", false)
			_trophy_begin()
		1:
			if _at(1.5):
				map.debug_shot("user://underdark_omen_card.png")
				var card = map.get("_end_card")
				if is_instance_valid(card):
					card.visible = false             # the first-person shots show the lantern, not the card
				var charm := _find_charm()
				# OWNER DECISION 7A.6: the trophy is on the end card and in the saved record; the cage
				# may carry the plain skull, never a flame or glowing sockets
				_check("charm no flame (tier IV)", _charm_flameless(charm), _charm_desc(charm))
		2:
			if _at(1.0):
				map.debug_shot("user://underdark_omen_charm.png")
				if _test_loop:
					var rp = CoopSync.get("_peers").get(777) if CoopSync.get("_peers") is Dictionary else null
					if is_instance_valid(rp):
						map.debug_look((rp as Node3D).global_position + Vector3.UP * 1.2)
		3:
			if _at(0.8):
				if _test_loop:
					map.debug_shot("user://loopback_omen.png")
				DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_COS))
				if CoopSync.has_method("omen_grant"):
					CoopSync.call("omen_grant", "underdark", 3)
				_check("omen_tier 2", int(CoopSync.get("omen_tier") if CoopSync.get("omen_tier") != null else -1) == 2, str(CoopSync.get("omen_tier")))
		4:
			if _at(1.5):
				var charm2 := _find_charm()
				_check("charm no flame (tier II)", _charm_flameless(charm2), _charm_desc(charm2))
				map.debug_shot("user://underdark_omen_charm_t2.png")
		5:
			if _at(0.5):
				_order_check()
				_step = 6
		6:
			_cleanup()
			_done()


func _persist_checks(tag: String, respawn: bool) -> void:
	# the omens after a death. Solo: the map reloaded and replayed every stored event. A session: the
	# player respawned beside a teammate on the SAME load, and the stored events must still derive
	# the sealed set (what a reload, a late joiner or a saved run would replay).
	_check(tag + " set 8", _lit.size() == 8, "lit=%s" % ",".join(_lit))
	_check(tag + " sealed", _sealed and _seal_applied, "")
	_check(tag + " 0 actionables", altar.area_count() == 0, "%d" % altar.area_count())
	var b0 := int(_vals.get("banners0", 0)) if respawn else 0
	_check(tag + " no banner", _banners == b0, "%d new omen banners" % (_banners - b0))
	_check(tag + " eggs hidden", _eggs_hidden and not _eggs_on, "")
	var alive := (obrood.threat_positions() as Array).size() if is_instance_valid(obrood) else 0
	if respawn:
		# the Early Brood that hatched before the death lives on (the same load): it never hatches twice
		var n0 := int(_vals.get("crawlers0", 0))
		_check(tag + " no second hatch", _hatch_group == str(_vals.get("hatch0", "")) and alive <= n0,
				"group=%s, %d crawlers (%d before the death)" % [_hatch_group, alive, n0])
		var before := _lit.duplicate()
		_derive()
		_check(tag + " stored events hold", _sealed and _lit == before and CoopSync.map_event_done("omen_seal"),
				"derived lit=%d sealed=%s" % [_lit.size(), str(_sealed)])
	else:
		_check(tag + " no crawlers", alive == 0 and not (is_instance_valid(obrood) and obrood.is_hatched()), "%d" % alive)
	_check(tag + " fires dark", _fires_dark() == map.fire_nodes.size(), "%d/%d" % [_fires_dark(), map.fire_nodes.size()])
	var bm = CoopSync.lantern.get("burn_mult") if is_instance_valid(CoopSync.lantern) else null
	_check(tag + " burn_mult 2.0", bm != null and is_equal_approx(float(bm), 2.0), str(bm))
	_check(tag + " bells cracked", _bells_cracked() == 2, "%d/2" % _bells_cracked())


func _trophy_begin() -> void:
	# the trophy, into the omen test's own cosmetics file (1A.2). Sets _step 6 when it cannot run.
	_vals["omen_file"] = CoopSync.get("omen_file")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_COS))
	CoopSync.set("omen_file", TEST_COS)
	if str(CoopSync.get("omen_file")) != TEST_COS:
		_check("trophy file", false, "CoopSync.omen_file is missing: the trophy step is skipped")
		_step = 6
		return
	var ln = CoopSync.lantern
	_vals["user"] = ln.get("user")
	ln.set("user", 1)                    # lit, so the cage is in the shots
	_test_trophy_ok = true
	map.call("_finish", "test", {"secs": 100})
	var tier := int(_trophy.get("tier", -1))
	_check("trophy", tier == 4 and bool(_trophy.get("new", false)) and int(_trophy.get("best", -1)) == 8,
			"tier %d %s new=%s best=%d" % [tier, tier_name(maxi(tier, 0)), str(_trophy.get("new")), int(_trophy.get("best", -1))])
	var cf := ConfigFile.new()
	var err := cf.load(TEST_COS)
	_check("trophy cfg", err == OK and int(cf.get_value("omen", "underdark_best", -1)) == 8 and not cf.has_section("relics"),
			"err=%d underdark_best=%s relics=%s" % [err, str(cf.get_value("omen", "underdark_best", null)), str(cf.has_section("relics"))])
	_check("omen_tier 4", int(CoopSync.get("omen_tier") if CoopSync.get("omen_tier") != null else -1) == 4, str(CoopSync.get("omen_tier")))


func _coop_death(c) -> void:
	# a session (the loopback is one): a death respawns you beside a teammate (ext/climber.gd
	# coop_respawn) and the map does NOT reload, so the omens are checked on this same load (step 18).
	# The marker is written too: if everyone were down, the map would reload and the reload branch
	# would pick the test up instead (_cleanup deletes the marker at the end either way).
	_vals["banners0"] = _banners
	_vals["crawlers0"] = (obrood.threat_positions() as Array).size() if is_instance_valid(obrood) else 0
	_vals["hatch0"] = _hatch_group
	_vals["pos0"] = (c as Node3D).global_position
	_vals["revived"] = false
	var f2 := FileAccess.open(TEST_MARK, FileAccess.WRITE)
	if f2 != null:
		f2.store_string(JSON.stringify({"t": Time.get_unix_time_from_system(), "pass": _pass, "fail": _fail}))
		f2.close()
	var left = CoopSync.get("respawns_left")
	print("[OMEN] dying for the co-op respawn check (%d passed so far, respawns left %s)" % [_pass, str(left)])
	c.prevent_player_death = false
	c.health = 0.0
	c.took_lethal_damage()


func _coop_respawn_wait(c) -> void:
	# step 18: back on your feet beside the teammate (coop_respawn: 1.5 s of black, then the teleport),
	# or, out of respawns, spectating: then the checkpoint revive brings you back on this load
	var waited := _t - _step_at
	var spect := bool(c.get("coop_spectating"))
	if spect and not bool(_vals.get("revived", false)) and c.has_method("coop_revive_at_checkpoint"):
		_vals["revived"] = true
		c.call("coop_revive_at_checkpoint")
	var back: bool = not spect and not bool(c.get("_coop_respawning")) and float(c.get("health")) > 0.0
	if not ((back and waited >= 2.5) or waited >= 15.0):
		return
	c.prevent_player_death = true
	var p0: Vector3 = _vals.get("pos0", Vector3.ZERO)
	var p1: Vector3 = (c as Node3D).global_position
	print("[OMEN] co-op respawn at (%.1f, %.1f, %.1f), %.1f m from the death, after %.1f s" % [p1.x, p1.y, p1.z, p1.distance_to(p0), waited])
	_check("coop respawn", back, "back=%s spectating=%s revived=%s" % [str(back), str(spect), str(_vals.get("revived", false))])
	_persist_checks("respawn", true)
	_test = "reload"                     # the trophy steps (reload steps 1 to 6), on this same load
	_step = 1
	_step_at = _t
	_trophy_begin()


func _charm_flameless(ch: Node) -> bool:
	# OWNER DECISION 7A.6: no candle, no flame and no glowing sockets on the lantern cage, at any
	# tier (no charm at all passes too)
	if ch == null:
		return true
	if ch.find_child("Candle", true, false) != null or ch.find_child("EmberEyes", true, false) != null:
		return false
	for mi in ch.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		var mats: Array = [m.material_override]
		if m.mesh != null:
			for si in m.mesh.get_surface_count():
				mats.append(m.get_surface_override_material(si))
				mats.append(m.mesh.surface_get_material(si))
		for mat in mats:
			if mat is BaseMaterial3D and (mat as BaseMaterial3D).billboard_mode != BaseMaterial3D.BILLBOARD_DISABLED:
				return false
	return true


func _charm_desc(ch: Node) -> String:
	if ch == null:
		return "no charm on the cage, omen_tier %s" % str(CoopSync.get("omen_tier"))
	var names: PackedStringArray = []
	for k in ch.get_children():
		names.append(str(k.name))
	return "%d parts (%s), omen_tier %s" % [ch.get_child_count(), ", ".join(names), str(CoopSync.get("omen_tier"))]


func _test_late(c) -> void:
	match _step:
		0:
			if _t < 3.0:
				return
			_step_at = _t
			_step = 1
			c.prevent_player_death = true
			test_light("hearth")
		1:
			if _at(0.5):
				test_light("thirst")
		2:
			if _at(0.5):
				test_light("bells")
		3:
			if _at(1.5):
				test_seal(["424242"])
		4:
			if _at(1.5):
				_check("late seal", _sealed and not who().has(_my_sid()) and _lit.size() == 3, "who=[%s] lit=%d" % [",".join(who()), _lit.size()])
				_vals["omen_file"] = CoopSync.get("omen_file")
				DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_COS))
				CoopSync.set("omen_file", TEST_COS)
				_test_trophy_ok = true
				map.call("_finish", "test", {"secs": 100})
		5:
			if _at(1.0):
				var txt := ""
				for r in end_rows():
					txt += str(r[0]) + " | "
				_check("late card row", txt.contains("none: you joined after the altar sealed"), txt)
				_check("late no grant", _trophy.get("none", "") == "late" and not FileAccess.file_exists(TEST_COS), str(_trophy))
				map.debug_shot("user://underdark_omen_late_card.png")
				_cleanup()
				_done()


func _order_check() -> void:
	# R17: a stored seal wins over a lower omenset, whichever order they come back in
	var real_lit := _lit.duplicate()
	_derive_from({"omenset_3": {"seq": 3, "lit": ["silk"], "act": "light", "id": "silk", "by": "x", "req": "x"},
			"omen_seal": {"lit": ["hearth", "thirst"], "who": [], "by": "x", "seq": 2}})
	var pure_ok := _lit == ["hearth", "thirst"]
	_derive()
	if CoopSync.has_method("_apply_map_event"):
		CoopSync.call("_apply_map_event", _scene(), "omenset_0", {"seq": 0, "lit": ["silk"], "act": "light", "id": "silk", "by": "x", "req": "x"}, true, true)
	_check("seal wins", pure_ok and _lit == real_lit and _sealed, "pure=%s live lit=%d" % [str(pure_ok), _lit.size()])


func _find_charm() -> Node:
	# the first-person cage lives under the camera (lantern.gd's _root), not under the lantern node
	var ln = CoopSync.lantern
	if is_instance_valid(ln):
		var r = ln.get("_root")
		if r is Node and is_instance_valid(r):
			var n := (r as Node).find_child("ZondaOmenCharm", true, false)
			if n != null:
				return n
	var c = Game.climber
	if is_instance_valid(c):
		return (c as Node).find_child("ZondaOmenCharm", true, false)
	return null


func _cleanup() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_COS))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_MARK))
	if _vals.has("omen_file") and _vals["omen_file"] != null:
		CoopSync.set("omen_file", _vals["omen_file"])
	if _vals.has("user") and is_instance_valid(CoopSync.lantern):
		CoopSync.lantern.set("user", _vals["user"])
	_test_trophy_ok = false
	var c = Game.climber
	if is_instance_valid(c):
		c.prevent_player_death = false          # a test never leaves the player invincible


func _done() -> void:
	var total := _pass + _fail.size()
	if _fail.is_empty():
		print("[OMEN] test done %d/%d PASS" % [_pass, total])
	else:
		print("[OMEN] test done %d/%d FAIL: %s" % [_pass, total, ", ".join(_fail)])
	_test = ""
	# guestsim record (A-GUEST-omen): the recording holds this test and closes 3 s after its done
	# line (CoopSync, another group's file: a runtime call; a no-op in any other launch)
	if CoopSync.has_method("guestsim_test_done"):
		CoopSync.call("guestsim_test_done", "OMEN")


# ============================================================================ the altar

class Altar extends Node3D:
	var map = null
	var mod = null
	var centre := Vector3.ZERO
	var fwd := Vector3.FORWARD          # flat, toward the spawn
	var from_layout := false
	var snapped := false
	var sealed_now := false
	var lit: Array = []
	var pillars: Array = []             # per skull: Dictionary (see build)
	var stone: Node3D = null
	var stone_body: StaticBody3D = null
	var glow: OmniLight3D = null
	var _flare := 0.0
	var _grind: AudioStreamPlayer3D = null

	func build(m, owner_mod, c: Vector3, face: Vector3, ids: Array, skulls_at: Dictionary, layout: bool) -> void:
		map = m
		mod = owner_mod
		centre = Vector3(c.x, 0.0 if not layout else c.y, c.z)
		from_layout = layout
		var f := Vector3(face.x, 0.0, face.z)
		fwd = f.normalized() if f.length() > 0.01 else Vector3.FORWARD
		var yaw := atan2(fwd.x, fwd.z)
		stone = map.ext_instance("ext/graveyard/altar-stone.glb", 0.45)
		if stone == null:
			stone = _box_mesh(ALTAR_SIZE, Color(0.3, 0.29, 0.27))
		else:
			stone.scale = Vector3.ONE * 2.6
		stone.rotation.y = yaw
		add_child(stone)
		stone_body = map.add_box_body(centre + Vector3(0, ALTAR_SIZE.y * 0.5, 0), ALTAR_SIZE, yaw)
		glow = map.add_light(centre + Vector3(0, 1.8, 0), Color(1.0, 0.62, 0.3), 0.25, 7.0, true)
		var skull_script = load(SKULL_SCRIPT)
		var dot: Texture2D = map.soft_dot()
		for i in ids.size():
			var id := str(ids[i])
			var dir := fwd.rotated(Vector3.UP, deg_to_rad(22.5 + 45.0 * float(i)))
			var at: Vector3 = centre + dir * RING_R
			if skulls_at.has(id):
				var sp: Vector3 = skulls_at[id]
				dir = Vector3(sp.x - centre.x, 0.0, sp.z - centre.z).normalized()
				at = Vector3(sp.x, sp.y - PILLAR_TOP, sp.z)
			var e := {"id": id, "dir": dir, "base": at}
			var pil = map.ext_instance("ext/graveyard/pillar-small.glb", 0.45)
			if pil == null:
				pil = _box_mesh(Vector3(0.28, PILLAR_TOP, 0.28), Color(0.3, 0.29, 0.27), true)
			else:
				pil.scale = Vector3.ONE * 1.55
			add_child(pil)
			e["pillar"] = pil
			e["body"] = map.add_box_body(at + Vector3(0, PILLAR_TOP * 0.5, 0), Vector3(0.3, PILLAR_TOP, 0.3), atan2(dir.x, dir.z))
			var sk = map.ext_instance("ext/quat/Skull.glb", 0.35)
			if sk == null:
				sk = _sphere_mesh(0.13, Color(0.34, 0.32, 0.28))
			else:
				sk.scale = Vector3.ONE * 0.55
			sk.rotation.y = atan2(dir.x, dir.z)             # the face (+Z in the model) looks out
			add_child(sk)
			e["skull"] = sk
			var cd = map.ext_instance("ext/graveyard/candle.glb", 0.3)
			if cd == null:
				cd = _box_mesh(Vector3(0.1, 0.24, 0.1), Color(0.3, 0.28, 0.24), true)
			else:
				cd.scale = Vector3.ONE * 1.3
			add_child(cd)
			e["candle"] = cd
			var lt: OmniLight3D = map.add_light(at, Color(1.0, 0.62, 0.3), 0.0, 2.4, true)
			var fl := CandleFlame.new()
			fl.build(dot, lt)
			add_child(fl)
			e["flame"] = fl
			e["fid"] = -1
			var a := Area3D.new()
			a.collision_layer = 1
			a.collision_mask = 0
			a.monitoring = false
			a.monitorable = true
			var cs := CollisionShape3D.new()
			var sph := SphereShape3D.new()
			sph.radius = 0.5
			cs.shape = sph
			a.add_child(cs)
			if skull_script != null:
				a.set_script(skull_script)
				a.set("altar", self)
				a.set("omen_id", id)
				a.set("displayed_action_text", "")
			add_child(a)
			e["area"] = a
			pillars.append(e)
		_place(null)

	func _box_mesh(size: Vector3, col: Color, base_at_zero: bool = false) -> Node3D:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = size
		mi.mesh = bm
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = 1.0
		mi.material_override = m
		var h := Node3D.new()
		mi.position = Vector3(0, size.y * 0.5, 0)
		h.add_child(mi)
		return h

	func _sphere_mesh(r: float, col: Color) -> Node3D:
		var mi := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = r
		sm.height = r * 2.0
		mi.mesh = sm
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = 1.0
		mi.material_override = m
		var h := Node3D.new()
		mi.position = Vector3(0, r, 0)
		h.add_child(mi)
		return h

	func _place(ys) -> void:
		# ys: null (the unsnapped heights) or [altar y, pillar 0 y, ... pillar 7 y]
		var cy: float = centre.y if ys == null else float(ys[0])
		stone.position = Vector3(centre.x, cy, centre.z)
		if is_instance_valid(stone_body):
			stone_body.position = Vector3(centre.x, cy + ALTAR_SIZE.y * 0.5, centre.z)
		if is_instance_valid(glow):
			glow.position = Vector3(centre.x, cy + 1.8, centre.z)
		for i in pillars.size():
			var e: Dictionary = pillars[i]
			var b: Vector3 = e["base"]
			var y: float = b.y if ys == null else float(ys[i + 1])
			var base := Vector3(b.x, y, b.z)
			e["at"] = base
			(e["pillar"] as Node3D).position = base
			if is_instance_valid(e["body"]):
				(e["body"] as Node3D).position = base + Vector3(0, PILLAR_TOP * 0.5, 0)
			(e["skull"] as Node3D).position = base + Vector3(0, PILLAR_TOP, 0)
			(e["candle"] as Node3D).position = base + Vector3(0, PILLAR_TOP + SKULL_TOP - 0.02, 0)
			var flame_at := base + Vector3(0, PILLAR_TOP + SKULL_TOP + 0.3, 0)
			(e["flame"] as Node3D).position = flame_at
			var lt = (e["flame"] as CandleFlame).light
			if is_instance_valid(lt):
				lt.position = flame_at + Vector3(0, 0.1, 0)
			# the prompt sphere sits low on the pillar: the climber's ActionableFinder looks about
			# 0.77 m under the gaze line, so looking at the skull from arm's reach finds it
			if is_instance_valid(e["area"]):
				(e["area"] as Node3D).position = base + Vector3(0, 0.55, 0) + (e["dir"] as Vector3) * 0.15
			if int(e["fid"]) >= 0:
				_flame_field(e, false)
				_flame_field(e, true)

	func try_snap() -> bool:
		# a down ray per piece from +6 m to -12 m, once the local player is near enough for the
		# rock to have collision; no hit: 0.0 (layout y in wave 2)
		if snapped:
			return true
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return false
		if (c.global_position as Vector3).distance_to(centre) > 120.0:
			return false
		var space := get_world_3d().direct_space_state
		var ys: Array = [_floor_at(space, centre)]
		for e in pillars:
			ys.append(_floor_at(space, e["base"]))
		_place(ys)
		snapped = true
		return true

	func _floor_at(space: PhysicsDirectSpaceState3D, p: Vector3) -> float:
		var top := p.y + RAY_TOP if from_layout else RAY_TOP
		var bot := p.y + RAY_BOTTOM if from_layout else RAY_BOTTOM
		var q := PhysicsRayQueryParameters3D.create(Vector3(p.x, top, p.z), Vector3(p.x, bot, p.z), 1)
		# our own altar and pillar boxes are on layer 1 too: skip them
		var ex: Array[RID] = []
		if is_instance_valid(stone_body):
			ex.append(stone_body.get_rid())
		for e in pillars:
			if is_instance_valid(e["body"]):
				ex.append((e["body"] as StaticBody3D).get_rid())
		q.exclude = ex
		var hit := space.intersect_ray(q)
		if hit.is_empty():
			return p.y if from_layout else 0.0
		return (hit["position"] as Vector3).y

	func skull_pos(id: String) -> Vector3:
		for e in pillars:
			if str(e["id"]) == id:
				return (e["skull"] as Node3D).position
		return centre

	func set_prompt(id: String, text: String) -> void:
		for e in pillars:
			if str(e["id"]) == id and is_instance_valid(e["area"]):
				if str((e["area"] as Node).get("displayed_action_text")) != text:
					(e["area"] as Node).set("displayed_action_text", text)

	func set_lit(ids: Array, quiet: bool) -> void:
		lit = ids.duplicate()
		for e in pillars:
			var on: bool = lit.has(str(e["id"]))
			var fl: CandleFlame = e["flame"]
			if on:
				fl.on(quiet)
			else:
				fl.off(quiet)
			_flame_field(e, on)
		if is_instance_valid(glow):
			glow.light_energy = 0.25 + 0.10 * float(lit.size())

	func _flame_field(e: Dictionary, on: bool) -> void:
		# the LightField (B4) counts a lit candle as a small flame (r 2 m)
		var lf = CoopSync.get("light_field")
		var ok: bool = lf != null and is_instance_valid(lf)
		if on and int(e["fid"]) < 0 and ok and lf.has_method("add_flame"):
			e["fid"] = int(lf.call("add_flame", (e["flame"] as Node3D).position, 2.0, Callable()))
		elif not on and int(e["fid"]) >= 0:
			if ok and lf.has_method("remove_flame"):
				lf.call("remove_flame", int(e["fid"]))
			e["fid"] = -1

	func seal(quiet: bool) -> void:
		if sealed_now:
			return
		sealed_now = true
		for e in pillars:
			if is_instance_valid(e["area"]):
				(e["area"] as Node).queue_free()
			e["area"] = null
			if not quiet and lit.has(str(e["id"])):
				(e["flame"] as CandleFlame).do_flare()
		if not quiet:
			_flare = 1.0
			_grind = AudioStreamPlayer3D.new()
			_grind.stream = load(SFX_RUMBLE)
			_grind.volume_db = 2.0
			_grind.pitch_scale = 0.6
			_grind.max_distance = 80.0
			_grind.bus = &"ZondaCave" if AudioServer.get_bus_index("ZondaCave") >= 0 else &"MainBus"
			_grind.position = centre + Vector3.UP
			add_child(_grind)
			_grind.play()

	func area_count() -> int:
		var n := 0
		for e in pillars:
			if e["area"] != null and is_instance_valid(e["area"]) and not (e["area"] as Node).is_queued_for_deletion():
				n += 1
		return n

	func on_press(id: String) -> void:
		if mod != null and is_instance_valid(mod):
			mod.call("_on_press", id)

	func _process(delta: float) -> void:
		if _flare > 0.0:
			_flare = maxf(0.0, _flare - delta * 1.2)
			if is_instance_valid(glow):
				glow.light_energy = (0.25 + 0.10 * float(lit.size())) * (1.0 + 2.0 * _flare)


# ============================================================================ a candle flame

class CandleFlame extends Node3D:
	# ONE soft-dot billboard with a scale flicker (R10: never particles), a small light, and the
	# on / off fades over 0.6 s. The light is a map light (it joins the 64-light budget).
	var mi: MeshInstance3D
	var light: OmniLight3D = null
	var k := 0.0
	var target := 0.0
	var t := 0.0
	var flare := 0.0
	var _near := true
	var _near_t := 0.0

	func build(dot: Texture2D, l: OmniLight3D) -> void:
		light = l
		mi = MeshInstance3D.new()
		var q := QuadMesh.new()
		q.size = Vector2(0.05, 0.08)
		mi.mesh = q
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_texture = dot
		m.albedo_color = Color(1.0, 0.62, 0.3, 0.85)
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = 70.0
		mi.visible = false
		add_child(mi)
		t = randf() * 10.0
		if is_instance_valid(light):
			light.light_energy = 0.0

	func on(quiet: bool) -> void:
		target = 1.0
		if quiet:
			k = 1.0

	func off(quiet: bool) -> void:
		target = 0.0
		if quiet:
			k = 0.0

	func do_flare() -> void:
		flare = 1.0

	func _process(delta: float) -> void:
		k = move_toward(k, target, delta / 0.6)
		flare = maxf(0.0, flare - delta * 1.5)
		_near_t -= delta
		if _near_t <= 0.0:
			_near_t = 0.5
			var cam := get_viewport().get_camera_3d()
			_near = cam != null and cam.global_position.distance_to(global_position) < 80.0
		var vis := k > 0.001
		if mi.visible != vis:
			mi.visible = vis
		if is_instance_valid(light):
			light.light_energy = 0.18 * k * (0.9 + 0.1 * sin(t * 9.0)) * (1.0 + 2.0 * flare)
		if not vis or not _near:
			return
		t += delta
		var f := 0.95 + 0.1 * sin(t * 11.3) + 0.05 * sin(t * 23.9)      # 0.8 .. 1.1
		mi.scale = Vector3.ONE * maxf(0.05, k * f * (1.0 + 0.8 * flare))
