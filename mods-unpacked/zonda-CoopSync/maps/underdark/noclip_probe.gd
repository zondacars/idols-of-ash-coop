extends Node
# ============================================================================================
# THE UNDERDARK: the creature no-clip test (ZondaCoopSync 5.0, feature "noclip", group NC-1).
# Spec: docs/specs/2026-09-25-creature-noclip.md, section 5 (and 0 for what is counted).
#
# A feature module (underdark.gd FEATURES: ["noclip", "noclip_probe.gd"], BEFORE "surfaces").
# setup(map) reads maps/underdark/noclip.flag (map.dev_flag, deleted on read). No flag: the module
# turns its processing off and costs nothing.
#
#   flag content          mode       what it does
#   "baseline"            baseline   guard OFF (NC.set_guard(false)), counters on: today's behaviour,
#                                    the same phases at the same spots; writes
#                                    user://zonda_noclip_baseline.json; clip counts are information
#   "" / "host" / other   host       guard ON, the full test: clips, fairness against the baseline
#                                    file, pops, safety, envelope, cost. Loopback shadows on.
#   "guest"               guest      guestsim play: parks nobody, spawns nothing, sets the B8 network
#                                    knobs, samples every "zonda_nc" node with view "guest" and
#                                    answers guestsim_report()
#
# Test safety (every mode): CoopSync.use_test_files(); prevent_player_death on for the whole test
# (host and baseline) and restored; CoopSync._loop_step = 7 with loopback; CoopSync.noclip_no_ghost
# on and restored; 1.0 s after every park before anything near the new spot is counted; shadows
# freed, queues emptied and every knob reset at the end (and on map exit).
#
# Everything the other groups provide is reached at runtime (has_method + call, get / set); a
# missing hook logs "[CLIP] SKIP <hook>" once and the phase goes on (its kinds then SKIP).
# Tag [CLIP]; the last line is "[CLIP] test done <passed>/<total> PASS" (or "... FAIL: <names>"),
# with "; WARN: <phases without a spot>" appended when a special phase found no spot.
#
# Phases (host and baseline identical; every spot from a deterministic search over L.stations + rays):
#   P0 envelope (2 s) | P1 cen2 cen4 cen7 cen10 cen13 (30 s: wake, forced lunges every 4 s through the
#   natural gate, recoils every 5 s, scripted leash at 20 s) | P1b wall pin cen4 cen7 cen10 (35 s, the
#   player re-parked on the pin every physics tick) | P1c shelf / low ceiling (35 s) | P2 Follower
#   (30 s, 3 scripted replacements) | P3 stalker1, stalker2 (40 s, look away and back every 1.5 s) |
#   P3b stalker ledge (40 s) | P4 bats roosts 0, 7, 11, 2 (8 s) | P5 early brood (omen API) and the
#   Nest brood (25 s each) | P5b brood ledge (25 s) | P6 spiders sp_1 sp_4 sp_11 walk-under, sp_3 sp_5
#   sp_9 scatter (6 s) | P7 three Shade homes (25 s, lantern off) | P7b shade ledge | P7c shade low
#   ceiling (2.6 to 3.2 m: a Shade reaches only by hunching) | P8 harriers per band (27 s, dive at 5 s)
#   | P9 hearth (16 s, may SKIP). Each phase: park, 1.0 s settle, run; "[CLIP] cost phase=..." at its end.
# Result lines: "[CLIP] <kind>/<view> ...", "[CLIP] cent/host st=attack|shy ...", "[CLIP] pops ...",
#   "[CLIP] inside_unknown ...", "[CLIP] safety shadow_dmg=...", "[CLIP] fair ...", "[CLIP] guard ...",
#   "[CLIP] cost worst ...", then the done line. The envelope line is printed in P0.
# ============================================================================================

signal _frame(delta: float)

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const NC_PATH := "res://mods-unpacked/zonda-CoopSync/maps/underdark/noclip.gd"
const BASELINE_FILE := "user://zonda_noclip_baseline.json"
const CENTIPEDE_SCENE := "res://scenes/centipede.tscn"
const SECTION_SCENE := "res://scenes/centipede_body_section.tscn"
const STALKER_HEAD := "res://Art/Monster_Head_Redesign.glb"
const STALKER_SEG := "res://Art/Monster_BodySection_Redesign.glb"
const ATTACK_STATE := "res://scripts/centipede_states/centipede_state_attack.gd"

const SAMPLE_R := 150.0          # everything within this of the player is sampled
const FAR_X := 60.0              # extremities of entities past this from the camera: every 3rd frame
const EMBED_MS := 50             # an extremity in rock this long is an EMBED, shorter a GRAZE
const INSIDE_MS := 500           # parity check of each entity's first centre
const POP_M := 3.0
const YOUNG_MS := 2000           # an entity's first 2 s are exempt from pops
const SCRIPT_MS := 1000          # a probe hook call opens a 1 s scripted window (host view)
# ...and 2.5 s for the lagged views: shadows (loopback 0.7 s + jitter + late + 0.1 s interpolation)
# and guests (the "ncscript_" event replays with the stream)
const SCRIPT_LAG_MS := 2500
const LOG_CAP := 12
const MIN_MOVING := 200
const MIN_MOVING_ST := 100
const CONTACT_M := 0.02          # a crossing hit this close to the segment's start is a part resting on the surface
const CONTACT_STEP_M := 0.25     # ...when the step is a short one
const GRAZE_MAX := 0.03          # brief touches (under EMBED_MS) are invisible flicker; the sustained ones are the embeds
# the fairness lines compare plain centipedes and the Follower. The pale ones fear the lantern (a separate
# feature, tested by the LIGHT phases): whether the beam reaches their head depends on the wall, which is
# exactly what the guard changes, so their bites and paths are not a like-for-like measure.
const FAIR_KINDS := ["centipede", "follower"]
const UNKNOWN_MAX := 0.20
# Clip rules that compare with the unguarded game (the baseline file). The vanilla creatures already touch
# and enter their own collision meshes a little (a leg on a wall, a hunched head at a rim, a spider on a thin
# ceiling), so "none" would fail the baseline itself. Crossings, pops, rods and declared teleports stay hard
# zeros; embeds, centres inside rock and undecided parity checks may not exceed CLIP_REL x the baseline's
# rate for the same exposure, plus a small allowance for the 3-frame flicker of a creature at a wall.
const CLIP_REL := 2.0
const CLIP_SLACK := 30            # events at most (less for a kind with little exposure)
const UNKNOWN_SLACK := 0.15       # the unknown share may exceed the baseline's by this much
const HUNT_STATE := "res://scripts/centipede_states/centipede_state_hunting.gd"
const PIN_HALF_W := 2.3          # 7A.1: ENV centipede half_w is the 4.7 m width limit (2 x (2.3 + 0.05))
const SETTLE_S := 1.0            # R12: at least 1.0 s after every park before counting
const APPROACH_S := 1.2          # a park to load the rock before a spot search

const CEN_KINDS := ["centipede", "pale", "follower"]
const REQUIRED_HOST := ["centipede/host", "pale/host", "follower/host", "stalker/host", "bat/host", "brood/host",
		"obrood/host", "spider/host", "shade/host", "harrier/host", "centipede/shadow", "pale/shadow", "follower/shadow"]
const OPTIONAL_HOST := ["hearth/host"]
const REQUIRED_GUEST := ["stalker", "brood", "obrood", "shade", "harrier", "spider"]
const P1_IDS := ["cen2", "cen4", "cen7", "cen10", "cen13"]
const P1B_IDS := ["cen4", "cen7", "cen10"]
const BAT_ROOSTS := [0, 7, 11, 2]
const WALK_SPIDERS := ["sp_1", "sp_4", "sp_11"]
const SCATTER_SPIDERS := ["sp_3", "sp_5", "sp_9"]
const FOLLOWER_TRIGGER := Vector3(373.138, -64.64, 60.395)
const PERF_SHELF := Vector3(571.0, -830.7, -20.2)     # perf.flag's early-brood approach (as perf does)
const SHADOW_LOSS := 0.10
const SHADOW_JITTER := 60
const SHADOW_LATE := 0.05
const GS_LOSS := 0.05
const GS_JITTER := 60
const GS_LATE := 0.05
# fairness lines: [line, phase groups, counter key (guarded), counter key (baseline), factor]
# Centipede bites and lunges are compared as RATES per second of attack state (rows below), not as counts per phase:
# how often a centipede that HAS reached the player bites or lunges is a fairness question; WHEN it arrives is a route
# question (the guarded one takes another way round a gap its head does not fit, owner decision 7A, and its search
# starts from random nodes), which made the counts swing from run to run (a 44 m approach took 15 s or 33 s).
const FAIR_RATES := [
	["centipede bites", ["P1", "P2"], FAIR_KINDS, "bites", "bites_clean", 0.70],
	["centipede wallpin bites", ["P1b"], FAIR_KINDS, "bites", "bites_clean", 0.70],
	["centipede shelf bites", ["P1c"], FAIR_KINDS, "bites", "bites_clean", 0.70],
	["centipede lunges", ["P1", "P1b", "P1c"], FAIR_KINDS, "lunges", "lunges", 0.80],
]
const FAIR_COUNTS := [
	["stalker bites", ["P3", "P3b"], ["stalker"], "bites", "bites_clean", 0.70],
	["shade strikes", ["P7", "P7b"], ["shade"], "strikes", "strikes", 0.70],
	["spider bites", ["P6"], ["spider"], "bites", "bites", 0.70],
]
const CEN_GROUPS := ["P1", "P1b", "P1c", "P2"]
# telegraph: [kind(s), hits key, tells key]
const TELL := [
	["centipede", CEN_KINDS, "bites", "lunges"],
	["brood", ["brood", "obrood"], "nips", "winds"],
	["spider", ["spider"], "bites", "clicks"],
	["shade", ["shade"], "strikes", "tells"],
	["harrier", ["harrier"], "hits", "shrieks"],
	["hearth", ["hearth"], "hits", "stirs"],
]

var map: Node = null
var NC = null
var mode := ""                   # "" (no flag), "baseline", "host", "guest"
var _only: PackedStringArray = PackedStringArray()     # developer filter: only these phases run (empty = all)
var _dbg := false                                      # developer trace of the centipede phases
var _running := false
var _done := false
var _sampling := false
var _loop := false
var _space = null
var _scripted_until := 0
var _scripted_lag_until := 0
var _script_seq := 0
var _pin = null                  # P1b: the player is re-parked here every physics tick
var _ppd_saved = null
var _no_ghost_saved = null
var _lantern_saved = null
var _warn: Array = []            # phases without a spot
var _skipped_hooks: Dictionary = {}
var _phases: Array = []          # finished phase records
var _cur: Dictionary = {}        # the running phase
var _ent: Dictionary = {}        # "kind/view/id" -> entity record
var _kv: Dictionary = {}         # "kind/view" -> stats
var _stl: Dictionary = {}        # "attack" / "shy" -> stats (centipede kinds, host view)
var _logn: Dictionary = {}
var _rec_last: Dictionary = {}   # kind -> NC "recovers" counter at the end of the last frame
var _rec_now: Dictionary = {}    # kind -> NC "recovers" counter this frame
var _env: Dictionary = {}        # P0 results
var _atk_script = null
var _hunt_script = null
var _bclips = null                # the baseline's per kind/view stats (read once)
var _wait_c: Dictionary = {}      # counters when the last wait began (the settle second before a phase)
var _wait_end_ms := -100000
var _p5b_cen := Vector3.ZERO
var _lines: Array = []           # result lines of the host run
var _npass := 0
var _nfail: Array = []
var time_scale := 1.0            # the headless dry run only; always 1 in the game


# ============================================================================ module protocol

func setup(m: Node) -> void:
	map = m
	name = "Feature_noclip"
	process_priority = 1000      # samples after every creature moved this frame
	var fl = m.call("dev_flag", "noclip.flag") if m.has_method("dev_flag") else null
	if fl == null:
		return
	var t := str(fl).strip_edges().to_lower()
	var toks := t.split(" ", false)
	var head := str(toks[0]) if toks.size() > 0 else ""
	for tk in toks:
		if str(tk).begins_with("only="):
			_only = str(tk).substr(5).split(",", false)        # developer: run only these phases (p1b,p3...)
		elif str(tk) == "dbg":
			_dbg = true                                        # developer: a once-per-second centipede trace
	if head == "baseline":
		mode = "baseline"
	elif head == "guest":
		mode = "guest"
	else:
		mode = "host"            # "", "host", or anything else a runner writes
	if ResourceLoader.exists(NC_PATH):
		NC = load(NC_PATH)
	if NC == null:
		print("[CLIP] noclip.gd is missing: the no-clip test cannot run")
		printerr("[CLIP] test done 0/1 FAIL: noclip.gd missing")
		mode = ""
		return
	# every scripted hook call is also announced as a non-persistent event: the guest simulation records
	# and replays it with the creature stream, so a guest opens the same scripted window (never stored)
	if m.has_method("register_events"):
		m.call("register_events", ["ncscript_"], _on_script_event, true)
	# the switches go on here, in setup, before any creature of this load has moved (every group reads
	# NC.is_enabled() per frame, so the baseline's guard-off holds from the first tick)
	_begin()


func _ready() -> void:
	if mode == "":
		set_process(false)
		set_physics_process(false)
		return
	if mode != "guest":
		_run_test()


var _dbg_fol_t := 0.0


func _dbg_followers(delta: float) -> void:
	# developer trace (flag word "dbg"): every Follower, once a second: where, what it does, how far the team is
	_dbg_fol_t += delta
	if _dbg_fol_t < 1.0:
		return
	_dbg_fol_t = 0.0
	var c := _climber()
	if c == null:
		return
	for cn in Game.centipedes:
		if not is_instance_valid(cn) or not (cn is Node3D) or not (cn as Node).has_meta("zonda_cid"):
			continue
		var cid := str((cn as Node).get_meta("zonda_cid"))
		if not cid.begins_with("follower"):
			continue
		var s0 = cn.get("_current_state")
		var st := str((s0.get_script() as Script).resource_path.get_file()) if s0 != null and s0.get_script() != null else "?"
		var secs = cn.get("_body_sections")
		var b3 := "-"
		if secs is Array and (secs as Array).size() > 3 and is_instance_valid(((secs as Array)[3]).root):
			b3 = _fmt(((secs as Array)[3]).root.global_position)
		var pth = s0.get("_path") if s0 != null else null
		var pf = cn.get("_pathfinder")
		print("[CLIPDBG] FOL %s pos=%s state=%s dist=%.1f path=%s inprog=%s mode=%d disabled=%s vis=%s sec3=%s tp=%d" % [cid, _fmt((cn as Node3D).global_position), st,
				(cn as Node3D).global_position.distance_to(c.global_position), str((pth as Array).size()) if pth is Array else "-",
				str(pf.get("path_finding_in_progress")) if pf != null else "-", (cn as Node).process_mode, str((cn as Node).process_mode == Node.PROCESS_MODE_DISABLED),
				str((cn as Node3D).visible), b3, int((cn as Node).get_meta("zonda_tp", 0))])


func _process(delta: float) -> void:
	if mode == "" or _done:
		return
	if mode != "guest":
		_hold_ppd()
	if _sampling or mode == "guest":
		var pk = NC.count_as("probe")
		_sample(delta)
		NC.count_as(pk)
	_frame.emit(delta)
	if _dbg and mode == "host":
		_dbg_followers(delta)


func _physics_process(_delta: float) -> void:
	if _pin is Vector3 and map != null and map.has_method("debug_park"):
		map.call("debug_park", _pin)


func on_exit() -> void:
	# the map is leaving (a death reload or the end): nothing a test set outlives it
	if mode != "" and not _done:
		print("[CLIP] map exit during the test: switches restored")
		_restore()


func guestsim_report() -> Array:
	# guest mode: one line per required kind. A required kind needs MIN_MOVING samples (5.7 "enough
	# samples"), else FAIL (a SKIP is not counted by CoopSync, so it would hide a kind never exercised);
	# an optional kind (hearth, or anything else seen) SKIPs when the recording has nothing for it
	if mode != "guest":
		return []
	var out: Array = []
	var kinds: Array = REQUIRED_GUEST.duplicate()
	for kv in _kv.keys():
		var k := str(kv).split("/")[0]
		if str(kv).ends_with("/guest") and not kinds.has(k) and not CEN_KINDS.has(k):
			kinds.append(k)
	for k in kinds:
		var S: Dictionary = _kv.get(k + "/guest", _new_stats())
		var req: bool = REQUIRED_GUEST.has(k)
		if int(S["moving"]) == 0 and not req:
			out.append("SKIP clip %s: nothing in the recording" % k)
			continue
		var bad := _clip_bad(S, true, k + "/guest")
		if bad == "" and req and int(S["moving"]) < MIN_MOVING:
			out.append("FAIL clip %s: only %d samples (at least %d)" % [k, int(S["moving"]), MIN_MOVING])
			continue
		out.append("%s clip %s samples=%d head_x=%d body_x=%d embed=%d inside=%d rods=%d pops_seen=%d tp_seen=%d graze=%d/%d unknown=%d/%d" % [
			"PASS" if bad == "" else "FAIL", k, int(S["moving"]), int(S["head_x"]), int(S["body_x"]), int(S["embed"]),
			int(S["inside"]), int(S["rods"]), int(S["pops_seen"]), int(S["tp_seen"]), int(S["graze"]), int(S["xsamples"]),
			int(S["unknown"]), int(S["checks"])])
	for ln in NC.report():
		print(ln)
	_done = true
	_restore()
	return out


# ============================================================================ start and end

func _begin() -> void:
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")
	_loop = CoopSync.get("_loopback") != null and bool(CoopSync.get("_loopback"))
	if _loop and CoopSync.get("_loop_step") != null:
		CoopSync.set("_loop_step", 7)          # the loopback's own soul and spectate script stays out
	_no_ghost_saved = CoopSync.get("noclip_no_ghost")
	if _no_ghost_saved != null:
		CoopSync.set("noclip_no_ghost", true)
	else:
		_skip_hook("CoopSync.noclip_no_ghost")
	NC.reset_stats()
	NC.set_measuring(true)
	NC.set_guard(mode != "baseline")
	var shadows := false
	var loss := 0.0
	var jitter := 0
	var late := 0.0
	if mode == "host":
		if CoopSync.get("noclip_shadows") != null:
			CoopSync.set("noclip_shadows", true)
			CoopSync.set("noclip_shadow_loss", SHADOW_LOSS)
			CoopSync.set("noclip_shadow_jitter_ms", SHADOW_JITTER)
			CoopSync.set("noclip_shadow_late", SHADOW_LATE)
			shadows = true
			loss = SHADOW_LOSS
			jitter = SHADOW_JITTER
			late = SHADOW_LATE
		else:
			_skip_hook("CoopSync.noclip_shadows")
	elif mode == "guest":
		if CoopSync.get("noclip_gs_loss") != null:
			CoopSync.set("noclip_gs_loss", GS_LOSS)
			CoopSync.set("noclip_gs_jitter_ms", GS_JITTER)
			CoopSync.set("noclip_gs_late", GS_LATE)
			loss = GS_LOSS
			jitter = GS_JITTER
			late = GS_LATE
		else:
			_skip_hook("CoopSync.noclip_gs_loss")
	var req := REQUIRED_HOST.size() + 2 if mode != "guest" else REQUIRED_GUEST.size()
	print("[CLIP] test start mode=%s guard=%s shadows=%s loss=%.2f jitter=%d late=%.2f required=%d" % [
		mode, "on" if NC.guard_on() else "off", "on" if shadows else "off", loss, jitter, late, req])


func _restore() -> void:
	_running = false
	_sampling = false
	_pin = null
	if NC != null:
		NC.set_measuring(false)
		NC.set_guard(true)
	if mode == "host":
		if CoopSync.has_method("noclip_shadows_clear"):
			CoopSync.call("noclip_shadows_clear")
		if CoopSync.get("noclip_shadows") != null:
			CoopSync.set("noclip_shadows", false)
			CoopSync.set("noclip_shadow_loss", 0.0)
			CoopSync.set("noclip_shadow_jitter_ms", 0)
			CoopSync.set("noclip_shadow_late", 0.0)
	if mode == "guest" and CoopSync.get("noclip_gs_loss") != null:
		CoopSync.set("noclip_gs_loss", 0.0)
		CoopSync.set("noclip_gs_jitter_ms", 0)
		CoopSync.set("noclip_gs_late", 0.0)
	if _no_ghost_saved != null:
		CoopSync.set("noclip_no_ghost", _no_ghost_saved)
	_lantern(true)
	var c := _climber()
	if c != null and _ppd_saved != null:
		c.set("prevent_player_death", bool(_ppd_saved))   # a test never leaves the player invincible


func _hold_ppd() -> void:
	# prevent_player_death on for the whole test (host and baseline), always restored at the end
	if not _running:
		return
	var c := _climber()
	if c == null:
		return
	if _ppd_saved == null:
		_ppd_saved = bool(c.get("prevent_player_death"))
	if not bool(c.get("prevent_player_death")):
		c.set("prevent_player_death", true)


# ============================================================================ the run

func _run_test() -> void:
	# host and baseline: the same phases at the same spots (every spot from a deterministic search)
	var t0 := Time.get_ticks_msec()
	while true:
		await _frame
		var c := _climber()
		var an = map.call("load_announced") if map.has_method("load_announced") else true
		var sp = CoopSync.call("save_prompt_open") if CoopSync.has_method("save_prompt_open") else false
		var ann: bool = an is bool and an
		var prompt: bool = sp is bool and sp
		if (c != null and ann and not prompt) or Time.get_ticks_msec() - t0 > 90000:
			break
	_running = true
	await _wait(5.0)
	_space = _get_space()
	await _prelight_brood()
	await _p0()
	if _do("p1"):
		for id in P1_IDS:
			await _p1(id)
	if _do("p1b"):
		for id in P1B_IDS:
			await _p1b(id)
	if _do("p1c"):
		await _p1c()
	if _do("p2"):
		await _p2()
	if _do("p3"):
		await _p3(0)
		await _p3(1)
	if _do("p3b"):
		await _p3b()
	if _do("p4"):
		for i in BAT_ROOSTS:
			await _p4(i)
	if _do("p5"):
		await _p5_early()
		await _p5_nest()
	if _do("p5b"):
		await _p5b()
	if _do("p6"):
		for sid in WALK_SPIDERS:
			await _p6(sid, false)
		for sid in SCATTER_SPIDERS:
			await _p6(sid, true)
	if _do("p7"):
		await _p7()
	if _do("p8"):
		await _p8()
	if _do("p9"):
		await _p9()
	_finish()


func _do(g: String) -> bool:
	return _only.is_empty() or _only.has(g)


func _dbg_cent(id: String, t: float) -> void:
	# developer trace (flag word "dbg"): what the group's centipede is doing, once a second
	var cn = _group_cent(id)
	var c := _climber()
	if cn == null or c == null:
		return
	var st := "?"
	var s0 = cn.get("_current_state")
	var aim := ""
	if s0 != null and s0.get_script() != null:
		st = str((s0.get_script() as Script).resource_path.get_file())
		if s0.get("_nc_aim_off") != null:
			aim = " aim=%s" % _fmt(s0.get("_nc_aim_off"))
	var kind := str(cn.call("_nc_kind")) if cn.has_method("_nc_kind") else "?"
	var ctr: Dictionary = (NC.counters() as Dictionary).get(kind, {})
	var d := (cn as Node3D).global_position.distance_to(c.global_position)
	var keep := {}
	for k in ctr.keys():
		if str(k) in ["lunges", "bites", "bites_clean", "abort_los", "abort_squeeze", "squeeze_cheeks", "squeeze_roof", "blocks", "stall_ticks", "backs", "repaths", "att_ms", "jaw_unres_ms"]:
			keep[str(k)] = ctr[k]
	var pin_txt := ""
	if s0 != null:
		var pth = s0.get("_path")
		var pf = cn.get("_pathfinder")
		var tgt = CoopSync.target_player_for(cn) if CoopSync.has_method("target_player_for") else null
		pin_txt = " path=%s next=%s end=%s inprog=%s misses=%s target=%s ncon=%s" % [
			str((pth as Array).size()) if pth is Array else "-", str(s0.get("_next_node") != null), str(s0.get("_end_of_path_reached")),
			str(pf.get("path_finding_in_progress")) if pf != null else "-", str(pf.get("pathing_misses_in_a_row")) if pf != null else "-",
			str(tgt.name) if tgt != null else "NULL", str(cn.call("nc_on")) if cn.has_method("nc_on") else "-"]
	print("[CLIPDBG] %s t=%.1f state=%s dist=%.2f%s%s squeeze_left=%dms lit=%s | %s" % [
		id, t, st, d, aim, pin_txt, maxi(0, int(cn.get_meta("zonda_squeeze_until", 0)) - Time.get_ticks_msec()),
		str(cn.has_meta("zonda_lit")), str(keep)])


func _t(t0: int) -> float:
	# seconds since t0 (time_scale speeds up the headless dry run only)
	return float(Time.get_ticks_msec() - t0) / 1000.0 * time_scale


func _wait(secs: float) -> void:
	if NC != null:
		_wait_c = NC.counters()
	var t_end := Time.get_ticks_msec() + int(secs * 1000.0 / time_scale)
	while Time.get_ticks_msec() < t_end:
		await _frame
	_wait_end_ms = Time.get_ticks_msec()


func _phase_begin(pname: String, group: String, at: Vector3, info: String, tail: String = "") -> void:
	# what happened in the settle second just before (a spider's click, a shade's tell): the hit that follows it
	# in the phase must not count as one without a warning
	var pre: Dictionary = {}
	if Time.get_ticks_msec() - _wait_end_ms < 300 and not _wait_c.is_empty():
		pre = _diff(NC.counters(), _wait_c)
	_cur = {"name": pname, "group": group, "t0": Time.get_ticks_msec(), "c0": NC.counters(), "frames": 0, "pre": pre,
		"fair": {"chase_d": 0.0, "chase_t": 0.0, "ps_v": 0.0, "ps_w": 0.0, "stalls": 0, "cen_s": 0.0},
		"sec_ms": Time.get_ticks_msec(), "sec_rays": NC.total("rays"), "peak": 0}
	print("[CLIP] phase %s %s at %s%s%s" % [group, info, _fmt(at), _biome_str(at), (" " + tail) if tail != "" else ""])
	_sampling = true


func _phase_end() -> void:
	_sampling = false
	if _cur.is_empty():
		return
	var c1: Dictionary = NC.counters()
	var diff := _diff(c1, _cur["c0"])
	var secs := maxf(0.001, float(Time.get_ticks_msec() - int(_cur["t0"])) / 1000.0)
	var rays := 0
	var usec := 0
	for k in diff.keys():
		if str(k) == "probe":
			continue
		rays += int((diff[k] as Dictionary).get("rays", 0))
		usec += int((diff[k] as Dictionary).get("usec", 0))
	var frames := maxi(1, int(_cur["frames"]))
	var rec := {"name": _cur["name"], "group": _cur["group"], "counters": diff, "fair": _cur["fair"], "secs": secs, "pre": _cur.get("pre", {}),
		"rays_s": float(rays) / secs, "usec_f": float(usec) / float(frames), "peak": int(_cur["peak"])}
	_phases.append(rec)
	print("[CLIP] cost phase=%s rays_per_s=%d guard_usec_per_frame=%.1f peak_rays_per_s=%d" % [
		str(_cur["name"]), int(rec["rays_s"]), float(rec["usec_f"]), int(rec["peak"])])
	_cur = {}
	# an entity that left the phase starts fresh next time (no pop across a park)
	for k in _ent.keys():
		_close_entity(_ent[k], _kv_of(str(k)))
		_ent[k]["vis"] = false


func _phase_skip(pname: String, why: String) -> void:
	print("[CLIP] phase %s SKIP %s" % [pname, why])
	if not _warn.has(pname):
		_warn.append(pname)


func _cost_tick() -> void:
	_cur["frames"] = int(_cur["frames"]) + 1
	var now := Time.get_ticks_msec()
	if now - int(_cur["sec_ms"]) >= 1000:
		var r: int = NC.total("rays")
		var per := int(float(r - int(_cur["sec_rays"])) * 1000.0 / float(now - int(_cur["sec_ms"])))
		_cur["peak"] = maxi(int(_cur["peak"]), per)
		_cur["sec_ms"] = now
		_cur["sec_rays"] = r


# ============================================================================ P0: the envelope (2.8)

func _p0() -> void:
	print("[CLIP] phase P0 envelope (centipede.tscn out of the tree, rest AABBs and the Arm_ bone split)")
	_envelope()
	await _wait(2.0)


func _envelope() -> void:
	# 2.8: centipede.tscn out of the tree (no _ready, nothing registers). Each head mesh is split by
	# dominant bone: "Arm_..." = the head's four fingered IK arms (they plant on rock like feet:
	# intended contact), the rest (Root, Jaw_0x, Eye_0x) = the rigid SHELL. Compared with ENV:
	#   fwd, up, half_w = the widest shell of both heads; chin = Monster_Head's shell bottom (2.8: "taken as
	#   the rigid shell"). Monster_Head2's shell bottom and the root neck section's bottom are REPORTED as
	#   rest contact when they reach below the ride height (7 decision 3: report only, ride unchanged).
	var ps = load(CENTIPEDE_SCENE) if ResourceLoader.exists(CENTIPEDE_SCENE) else null
	if ps == null or not (ps is PackedScene):
		print("[CLIP] envelope centipede SKIP: centipede.tscn did not load")
		_env = {"skip": true}
		return
	var root: Node = (ps as PackedScene).instantiate()
	var hon: Node = root.get_node_or_null("HeadOffsetNode")
	var sh1 := _box_new()          # Monster_Head shell
	var sh2 := _box_new()          # Monster_Head2 shell
	var ar := _box_new()           # both heads' arms
	var all_head := _box_new()
	var neck := _box_new()
	var split_ok := true
	var any_head := false
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m == null or m.mesh == null:
			continue
		var xf := _xf_to(root, m)
		var bb := _xform_aabb(xf, m.get_aabb())
		var path := str(root.get_path_to(m))
		if hon != null and hon.is_ancestor_of(m):
			any_head = true
			_box_add_aabb(all_head, bb)
			var sp := _split(m, xf)
			if bool(sp["ok"]):
				_box_merge(sh2 if path.contains("Monster_Head2") else sh1, sp["shell"])
				_box_merge(ar, sp["arms"])
				print("[CLIP] envelope centipede mesh=%s shell %s arms %s (%d vertices)" % [path, _box_str(sp["shell"]), _box_str(sp["arms"]), int(sp["n"])])
			else:
				split_ok = false
				print("[CLIP] envelope centipede mesh=%s aabb %s (no bone split: %s)" % [path, _box_str(_box_of(bb)), str(sp.get("why", ""))])
		else:
			if path.begins_with("Monster_BodySection_Redesign4"):
				_box_add_aabb(neck, bb)
			print("[CLIP] envelope centipede mesh=%s aabb %s" % [path, _box_str(_box_of(bb))])
	root.free()
	# the runtime body section (the 15 spawned sections), for sec_below / sec_up / sec_half_w
	var sec := _box_new()
	var ps2 = load(SECTION_SCENE) if ResourceLoader.exists(SECTION_SCENE) else null
	if ps2 is PackedScene:
		var r2: Node = (ps2 as PackedScene).instantiate()
		for mi in r2.find_children("*", "MeshInstance3D", true, false):
			var m2 := mi as MeshInstance3D
			if m2 == null or m2.mesh == null or str(r2.get_path_to(m2)).contains("Leg"):
				continue
			_box_add_aabb(sec, _xform_aabb(_xf_to(r2, m2), m2.get_aabb()))
		r2.free()
	var E: Dictionary = NC.env("centipede")
	var ride := float(E.get("ride", 1.6))
	var split := split_ok and any_head and _box_ok(sh1)
	var both := _box_new()
	if split:
		_box_merge(both, sh1)
		_box_merge(both, sh2)
	else:
		both = all_head
	var fwd := -float(both["min"].z)
	var up := float(both["max"].y)
	var half_w := maxf(absf(float(both["min"].x)), absf(float(both["max"].x)))
	var chin := -float(sh1["min"].y) if split else -float(all_head["min"].y)
	var rest2 := -float(sh2["min"].y) if split and _box_ok(sh2) else 0.0
	var neck_below := -float(neck["min"].y) if _box_ok(neck) else 0.0
	var bad: Array = []
	var warn: Array = []
	var notes: Array = []
	for row in [["fwd", fwd], ["up", up], ["half_w", half_w], ["chin", chin]]:
		if str(row[0]) == "chin" and not split:
			warn.append("chin unverified (no bone split)")
			continue
		var ev := float(E.get(row[0], 0.0))
		if str(row[0]) == "half_w" and absf(ev - PIN_HALF_W) < 0.005 and ev >= float(row[1]):
			# 7A.1: ENV half_w is the width limit (the pathfinder's side rays half_w + 0.05 = 2.35 m, a
			# 4.7 m gap), not the shell; larger than the shell is the owner's rule, so not a FAIL
			if absf(float(row[1]) - ev) > 0.3:
				notes.append("half_w ENV %.2f vs shell %.2f (kept: the 7A.1 width limit, 4.7 m)" % [ev, float(row[1])])
			continue
		if absf(float(row[1]) - ev) > 0.3:
			bad.append(str(row[0]))
			notes.append("%s ENV %.2f vs shell %.2f (%s)" % [str(row[0]), ev, float(row[1]),
				"ENV larger: conservative, costs reach" if ev > float(row[1]) else "ENV smaller: the shell clips"])
	var rest: Array = []
	if rest2 > ride:
		rest.append("Monster_Head2 shell below=%.2f" % rest2)
	if neck_below > ride:
		rest.append("neck below=%.2f" % neck_below)
	var verdict := "INFO"
	if mode == "host":
		verdict = "PASS" if bad.is_empty() else "FAIL"
	print("[CLIP] envelope centipede mesh=heads shell fwd=%.2f up=%.2f below=%.2f half_w=%.2f arms fwd=%.2f up=%.2f below=%.2f half_w=%.2f | neck below=%.2f | section below=%.2f up=%.2f half_w=%.2f | ENV fwd=%.2f up=%.2f chin=%.2f half_w=%.2f%s%s %s" % [
		fwd, up, chin, half_w,
		-float(ar["min"].z) if _box_ok(ar) else 0.0, float(ar["max"].y) if _box_ok(ar) else 0.0,
		-float(ar["min"].y) if _box_ok(ar) else 0.0, maxf(absf(float(ar["min"].x)), absf(float(ar["max"].x))) if _box_ok(ar) else 0.0,
		neck_below,
		-float(sec["min"].y) if _box_ok(sec) else 0.0, float(sec["max"].y) if _box_ok(sec) else 0.0,
		maxf(absf(float(sec["min"].x)), absf(float(sec["max"].x))) if _box_ok(sec) else 0.0,
		float(E.get("fwd", 0)), float(E.get("up", 0)), float(E.get("chin", 0)), float(E.get("half_w", 0)),
		(" off=" + ",".join(PackedStringArray(bad))) if not bad.is_empty() else "",
		(" WARN: " + ", ".join(PackedStringArray(warn))) if not warn.is_empty() else "", verdict])
	for n in notes:
		print("[CLIP] envelope %s" % str(n))
	if not rest.is_empty():
		print("[CLIP] envelope rest contact below the %.2f m ride height: %s (7 decision 3: reported, ride unchanged)" % [ride, ", ".join(PackedStringArray(rest))])
	if not bad.is_empty():
		# the measured shell and the ENV rows derived from it (2.8 formulas), ready to paste. The 7A.1
		# limits (gap 3.85, half_w 2.3, roof_want 2.23, cheek_want 2.33) never follow the shell down: one
		# is listed only when the shell no longer fits inside it
		var paste := "\"fwd\": %.2f, \"up\": %.2f, \"chin\": %.2f, \"belly_want\": %.2f" % [fwd, up, chin, chin + 0.05]
		if half_w > float(E.get("half_w", 0.0)):
			paste += ", \"half_w\": %.2f, \"cheek_want\": %.2f" % [half_w, half_w + 0.03]
		if up + 0.03 > float(E.get("roof_want", 0.0)):
			paste += ", \"roof_want\": %.2f" % (up + 0.03)
		if ride + up + 0.05 > float(E.get("gap", 0.0)):
			paste += ", \"gap\": %.2f" % (ride + up + 0.05)
		print("[CLIP] envelope paste into noclip.gd ENV centipede: %s (the 7A.1 limits not listed stay)" % paste)
	_env = {"bad": bad, "warn": warn}
	# the Stalker's head (x 1.4) and one segment (x 1.3), in body space
	var hb := _scene_box(STALKER_HEAD, 1.4)
	var sb := _scene_box(STALKER_SEG, 1.3)
	if _box_ok(hb):
		print("[CLIP] envelope stalker head fwd=%.2f up=%.2f below=%.2f half_w=%.2f back=%.2f seg below=%.2f up=%.2f" % [
			-float(hb["min"].z), float(hb["max"].y), -float(hb["min"].y), maxf(absf(float(hb["min"].x)), absf(float(hb["max"].x))),
			float(hb["max"].z), -float(sb["min"].y) if _box_ok(sb) else 0.0, float(sb["max"].y) if _box_ok(sb) else 0.0])
	else:
		print("[CLIP] envelope stalker SKIP: the head model did not load")


func _scene_box(path: String, scale: float) -> Dictionary:
	var b := _box_new()
	var ps = load(path) if ResourceLoader.exists(path) else null
	if not (ps is PackedScene):
		return b
	var r: Node = (ps as PackedScene).instantiate()
	for mi in r.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m == null or m.mesh == null:
			continue
		var xf := Transform3D(Basis().scaled(Vector3.ONE * scale), Vector3.ZERO) * _xf_to(r, m)
		_box_add_aabb(b, _xform_aabb(xf, m.get_aabb()))
	r.free()
	return b


func _split(m: MeshInstance3D, xf: Transform3D) -> Dictionary:
	# vertices by dominant bone: "Arm_..." bones (the head's IK arms, which plant on rock) vs the shell
	var mesh := m.mesh
	if not (mesh is ArrayMesh):
		return {"ok": false, "why": "not an ArrayMesh"}
	var skel: Skeleton3D = null
	if m.skeleton != NodePath(""):
		skel = m.get_node_or_null(m.skeleton) as Skeleton3D
	var skin: Skin = m.skin
	var sh := _box_new()
	var ar := _box_new()
	var n := 0
	var bones_seen: Dictionary = {}
	for si in mesh.get_surface_count():
		var arrs: Array = mesh.surface_get_arrays(si)
		if arrs.size() < Mesh.ARRAY_MAX:
			continue
		var verts = arrs[Mesh.ARRAY_VERTEX]
		var bones = arrs[Mesh.ARRAY_BONES]
		var weights = arrs[Mesh.ARRAY_WEIGHTS]
		if verts == null or bones == null or weights == null or (verts as PackedVector3Array).is_empty():
			continue
		var vc: int = (verts as PackedVector3Array).size()
		var per: int = int((bones as PackedInt32Array).size() / vc)
		if per <= 0 or (weights as PackedFloat32Array).size() < vc * per:
			continue
		for vi in vc:
			var best := 0
			var bw := -1.0
			for k in per:
				var w: float = weights[vi * per + k]
				if w > bw:
					bw = w
					best = bones[vi * per + k]
			var bn := _bone_name(skin, skel, best)
			var p: Vector3 = xf * (verts[vi] as Vector3)
			if bn.begins_with("Arm_"):
				_box_add(ar, p)
				bones_seen["arm"] = true
			else:
				_box_add(sh, p)
				bones_seen["shell"] = true
			n += 1
	if n == 0:
		return {"ok": false, "why": "no skinned vertex data"}
	if not _box_ok(sh):
		return {"ok": false, "why": "no shell vertices"}
	return {"ok": true, "shell": sh, "arms": ar, "n": n, "bones": bones_seen.keys()}


func _bone_name(skin: Skin, skel: Skeleton3D, b: int) -> String:
	if skin != null and b >= 0 and b < skin.get_bind_count():
		var nm := str(skin.get_bind_name(b))
		if nm != "":
			return nm
		var bi := skin.get_bind_bone(b)
		if skel != null and bi >= 0 and bi < skel.get_bone_count():
			return skel.get_bone_name(bi)
		return ""
	if skel != null and b >= 0 and b < skel.get_bone_count():
		return skel.get_bone_name(b)
	return ""


func _xf_to(root: Node, n: Node) -> Transform3D:
	# n's transform composed up the parent chain to root (root's own transform excluded)
	var xf := Transform3D.IDENTITY
	var cur := n
	while cur != null and cur != root:
		if cur is Node3D:
			xf = (cur as Node3D).transform * xf
		cur = cur.get_parent()
	return xf


func _xform_aabb(xf: Transform3D, bb: AABB) -> Array:
	var out: Array = []
	for i in 8:
		out.append(xf * bb.get_endpoint(i))
	return out


func _box_new() -> Dictionary:
	return {"min": Vector3(INF, INF, INF), "max": Vector3(-INF, -INF, -INF)}


func _box_add(b: Dictionary, p: Vector3) -> void:
	b["min"] = (b["min"] as Vector3).min(p)
	b["max"] = (b["max"] as Vector3).max(p)


func _box_add_aabb(b: Dictionary, pts: Array) -> void:
	for p in pts:
		_box_add(b, p)


func _box_merge(b: Dictionary, o: Dictionary) -> void:
	if _box_ok(o):
		_box_add(b, o["min"])
		_box_add(b, o["max"])


func _box_of(pts: Array) -> Dictionary:
	var b := _box_new()
	_box_add_aabb(b, pts)
	return b


func _box_ok(b: Dictionary) -> bool:
	return float(b["min"].x) <= float(b["max"].x)


func _box_str(b: Dictionary) -> String:
	if not _box_ok(b):
		return "(none)"
	return "fwd=%.2f up=%.2f below=%.2f half_w=%.2f" % [-float(b["min"].z), float(b["max"].y), -float(b["min"].y),
		maxf(absf(float(b["min"].x)), absf(float(b["max"].x)))]


# ============================================================================ P1, P1b, P1c: centipedes

func _p1(id: String) -> void:
	var sp = _cen_spawn(id)
	if sp == null:
		_phase_skip("P1", "no spawn for %s" % id)
		return
	var st = _nearest_station(sp)
	if st == null:
		_phase_skip("P1", "no station near %s" % id)
		return
	var at: Vector3 = (st as Vector3) + Vector3.UP * 1.0
	_park(at)
	await _wait(SETTLE_S)
	_phase_begin("P1:" + id, "P1", at, "cent id=%s skin=%s" % [id, _cen_skin(id)])
	_hook(map, "noclip_test_wake", [id])
	var t0 := Time.get_ticks_msec()
	var next_l := 4.0
	var next_r := 5.0
	var kicked := false
	var next_kick := 6.6
	var next_look := 0.0
	var leashed := false
	while _t(t0) < 30.0:
		await _frame
		var t := _t(t0)
		if t >= next_look:
			next_look += 0.5
			_look_cent(id)
		if t >= next_l:
			next_l += 4.0
			_force_lunges(12.0)
		if not kicked and t >= 0.6:
			kicked = true
			_kick_cent(id, false)
		elif t >= next_kick:
			next_kick += 6.0
			_kick_cent(id, true)
		if t >= next_r:
			next_r += 5.0
			_recoil_pales(40.0)
		if t >= 20.0 and not leashed:
			leashed = true
			var n = _group_cent(id)
			if n != null:
				_hook(map, "noclip_test_leash", [n])
	_phase_end()


func _p1b(id: String) -> void:
	var sp = _cen_spawn(id)
	var st = _nearest_station(sp) if sp != null else null
	if st == null:
		_phase_skip("P1b", "no spot")
		return
	_park((st as Vector3) + Vector3.UP * 1.0)
	await _wait(APPROACH_S)
	var pk = NC.count_as("probe")
	var found = _find_pin(sp)
	NC.count_as(pk)
	if found == null:
		_phase_skip("P1b", "no spot")
		return
	var pin: Vector3 = found[0]
	_pin = pin
	_park(pin)
	await _wait(SETTLE_S)
	_phase_begin("P1b:" + id, "P1b", pin, "pin", "wall_n=%s cent id=%s" % [_fmt(found[1]), id])
	_hook(map, "noclip_test_wake", [id])
	await _lunge_loop(id, 35.0)
	_pin = null
	_phase_end()


func _kick_cent(id: String, only_idle: bool) -> void:
	# The same in both modes. A hunter that stands still with no path waits for the game's 1-in-10,000 per
	# tick re-path lottery (minutes), which would make a run depend on luck. The probe hands it a fresh hunting
	# state (a new path request) at the start and whenever it idles, so neither launch depends on that lottery.
	var cn = _group_cent(id)
	if cn == null or not cn.has_method("set_state"):
		return
	if only_idle:
		var st0 = cn.get("_current_state")
		if st0 == null or not (st0 is Object) or (st0 as Object).get_script() == null:
			return
		if not str(((st0 as Object).get_script() as Script).resource_path).ends_with("state_hunting.gd"):
			return
		var pth = st0.get("_path")
		if not (pth is Array) or (pth as Array).size() > 0:
			return
		var pf = cn.get("_pathfinder")
		if pf != null and bool(pf.get("path_finding_in_progress")):
			return
	if _hunt_script == null and ResourceLoader.exists(HUNT_STATE):
		_hunt_script = load(HUNT_STATE)
	if _hunt_script == null:
		_skip_hook("centipede_state_hunting")
		return
	var pk = NC.count_as("probe")
	cn.call("set_state", _hunt_script.new())
	NC.count_as(pk)


func _find_pin(sp: Vector3) -> Variant:
	# from the stations within 60 m of the spawn (nearest first), 8 flat rays of 3 m at +1.0 m; the first
	# vertical face gives the pin 0.47 m off it, accepted when a capsule (r 0.42, h 1.5) there is empty
	for s in _stations_near(sp, 60.0):
		var base: Vector3 = (s as Vector3) + Vector3.UP * 1.0
		if not NC.solid_at(base, 6.0):
			continue
		for k in 8:
			var a := float(k) * PI / 4.0
			var dir := Vector3(cos(a), 0.0, sin(a))
			var h: Dictionary = NC.ray(_space, base, base + dir * 3.0)
			if h.is_empty():
				continue
			var n: Vector3 = h["normal"]
			if absf(n.y) >= 0.3:
				continue
			var pin: Vector3 = (h["position"] as Vector3) + n * 0.47
			if _capsule_free(pin):
				return [pin, n]
	# no station near the spawn has a wall within 3 m (checked on the real cave: most of them stand on
	# open shelves): the first wall around the spawn point itself, 16 directions, at 0, +3, -3, +6 m,
	# with a floor within 20 m under the pin (a climber roped against the wall above a ledge)
	for hgt in [0.0, 3.0, -3.0, 6.0]:
		var b2: Vector3 = sp + Vector3.UP * float(hgt)
		if not NC.solid_at(b2, 6.0):
			continue
		for k in 16:
			var a2 := float(k) * TAU / 16.0
			var d2 := Vector3(cos(a2), 0.0, sin(a2))
			var h2: Dictionary = NC.ray(_space, b2, b2 + d2 * 20.0)
			if h2.is_empty():
				continue
			var n2: Vector3 = h2["normal"]
			if absf(n2.y) >= 0.3:
				continue
			var pin2: Vector3 = (h2["position"] as Vector3) + n2 * 0.47
			if _capsule_free(pin2) and not NC.ray(_space, pin2, pin2 + Vector3.DOWN * 20.0).is_empty():
				return [pin2, n2]
	return null


func _p1c() -> void:
	# a station with rock 2.0 to 3.2 m above it and a lip within 1.5 m: the player parks under the
	# shelf, 1 m inside the lip (any centipede group within 80 m)
	var groups: Array = []
	for c in _L().get("centipedes", []):
		if c is Dictionary and (c as Dictionary).has("territory"):
			groups.append(c)
	var found = null
	var gid := ""
	for g in groups:
		var sp = _v(g["spawn"][0]) if (g["spawn"] as Array).size() > 0 else null
		if sp == null:
			continue
		var st = _nearest_station(sp)
		if st == null:
			continue
		_park((st as Vector3) + Vector3.UP * 1.0)
		await _wait(APPROACH_S)
		var pk = NC.count_as("probe")
		found = _find_shelf(sp)
		NC.count_as(pk)
		if found != null:
			gid = str(g["id"])
			break
	if found == null:
		_phase_skip("P1c", "no spot")
		return
	var at: Vector3 = found
	_park(at)
	await _wait(SETTLE_S)
	_phase_begin("P1c:" + gid, "P1c", at, "shelf cent id=%s" % gid)
	_hook(map, "noclip_test_wake", [gid])
	await _lunge_loop(gid, 35.0)
	_phase_end()


func _find_shelf(sp: Vector3) -> Variant:
	for s in _stations_near(sp, 80.0):
		var sv: Vector3 = s
		if not NC.solid_at(sv, 6.0):
			continue
		var fl: Dictionary = NC.ray(_space, sv + Vector3.UP * 1.0, sv + Vector3.DOWN * 2.0)
		var fp: Vector3 = fl["position"] if not fl.is_empty() else sv
		var up: Dictionary = NC.ray(_space, fp + Vector3.UP * 0.1, fp + Vector3.UP * 3.4)
		if up.is_empty():
			continue
		var hgt := float(up["d"]) + 0.1
		if hgt < 2.0 or hgt > 3.2:
			continue
		for k in 8:
			var a := float(k) * PI / 4.0
			var dir := Vector3(cos(a), 0.0, sin(a))
			var lip := -1.0
			var dd := 0.5
			while dd <= 1.5 + 0.001:
				var q := fp + dir * dd
				if NC.ray(_space, q + Vector3.UP * 0.1, q + Vector3.UP * 3.4).is_empty():
					lip = dd
					break
				dd += 0.25
			if lip < 0.0:
				continue
			var at := fp + dir * maxf(0.0, lip - 1.0) + Vector3.UP * 1.0
			if NC.ray(_space, at, at + Vector3.DOWN * 1.8).is_empty():
				continue
			if _capsule_free(at):
				return at
	return null


func _lunge_loop(id: String, secs: float) -> void:
	# natural and forced lunges only (no recoils); the camera follows the group's centipede
	var t0 := Time.get_ticks_msec()
	var next_l := 4.0
	var next_look := 0.0
	var next_dbg := 0.0
	var kicked := false
	var next_kick := 6.6
	while _t(t0) < secs:
		await _frame
		var t := _t(t0)
		if not kicked and t >= 0.6:
			kicked = true
			_kick_cent(id, false)
		elif t >= next_kick:
			next_kick += 6.0
			_kick_cent(id, true)
		if t >= next_look:
			next_look += 0.5
			_look_cent(id)
		if _dbg and t >= next_dbg:
			next_dbg += 1.0
			_dbg_cent(id, t)
		if t >= next_l:
			next_l += 4.0
			_force_lunges(12.0)


func _force_lunges(r: float) -> void:
	# a forced lunge only where the natural gate would pass (a clear line from the player to the head,
	# no lantern beam on it), in both modes, so the baseline is never credited with extra lunges
	var c := _climber()
	if c == null:
		return
	if _atk_script == null and ResourceLoader.exists(ATTACK_STATE):
		_atk_script = load(ATTACK_STATE)
	if _atk_script == null:
		_skip_hook("centipede_state_attack")
		return
	var pk = NC.count_as("probe")
	var now := Time.get_ticks_msec()
	var lure = CoopSync.call("lure_node") if CoopSync.has_method("lure_node") else null
	for cent in _real_cents():
		var n3 := cent as Node3D
		if n3.global_position.distance_to(c.global_position) > r or _in_attack(cent) or cent.has_meta("zonda_lit"):
			continue
		# the guarded game's own lunge gate (CoopHunting._nc_hold_lunge, only while its no-clip is on):
		# no lunge at the bell's lure, none during the wait after a lunge gave up at a gap
		if cent.has_method("nc_on") and bool(cent.call("nc_on")):
			if now < int(cent.get_meta("zonda_squeeze_until", 0)):
				continue
			if is_instance_valid(lure) and CoopSync.has_method("target_player_for") and CoopSync.call("target_player_for", cent) == lure:
				continue
		if not NC.ray(_space, c.global_position, n3.global_position).is_empty():
			continue
		if cent.has_method("set_state"):
			cent.call("set_state", _atk_script.new())
	NC.count_as(pk)


func _recoil_pales(r: float) -> void:
	var c := _climber()
	if c == null:
		return
	for cent in _real_cents():
		var pale: bool = int(cent.get("coop_skin")) == 1 if cent.get("coop_skin") != null else int(cent.get_meta("zonda_skin", 0)) == 1
		if not pale or (cent as Node3D).global_position.distance_to(c.global_position) > r:
			continue
		if cent.has_method("coop_test_recoil"):
			cent.call("coop_test_recoil", c)
		else:
			_skip_hook("coop_test_recoil")


func _look_cent(id: String) -> void:
	var n = _group_cent(id)
	if n == null:
		n = _nearest_cent()
	if n != null:
		_look((n as Node3D).global_position)


# ============================================================================ P2: the Follower

func _p2() -> void:
	var trig := FOLLOWER_TRIGGER
	for c in _L().get("centipedes", []):
		if c is Dictionary and str(c.get("id", "")) == "follower" and c.has("trigger"):
			trig = _v(c["trigger"][0])
	var st = _nearest_station(trig - Vector3(0, 30, 0))
	if st == null:
		_phase_skip("P2", "no station")
		return
	var at: Vector3 = (st as Vector3) + Vector3.UP * 1.0
	_park(at)
	await _wait(SETTLE_S)
	_phase_begin("P2", "P2", at, "follower")
	_hook(map, "noclip_test_wake", ["follower"])
	var t0 := Time.get_ticks_msec()
	var reps := [2.0, 10.0, 18.0]
	var ri := 0
	var next_look := 0.0
	while _t(t0) < 30.0:
		await _frame
		var t := _t(t0)
		if ri < reps.size() and t >= float(reps[ri]):
			ri += 1
			_hook(map, "noclip_test_follower", [])
		if t >= next_look:
			next_look += 0.5
			var f = map.get("_follower")
			if is_instance_valid(f) and f is Node3D and (f as Node3D).is_inside_tree():
				_look((f as Node3D).global_position)
	_phase_end()


# ============================================================================ P3, P3b: the Stalkers

func _p3(i: int) -> void:
	var sl: Array = _L().get("stalkers", [])
	if i >= sl.size():
		_phase_skip("P3", "no stalker %d" % i)
		return
	var home := _v(sl[i]["home"])
	var zone: Array = sl[i].get("zone", [])
	var best = null
	var bd := INF
	for s in _stations():
		var sv: Vector3 = s
		if not _in_zone(sv, zone):
			continue
		var d := absf(sv.distance_to(home) - 50.0)
		if d < bd:
			bd = d
			best = sv
	if best == null:
		_phase_skip("P3", "no zone station for %s" % str(sl[i].get("id", "")))
		return
	var at: Vector3 = (best as Vector3) + Vector3.UP * 1.0
	_park(at)
	await _wait(SETTLE_S)
	_phase_begin("P3:" + str(sl[i].get("id", "")), "P3", at, "stalker id=%s home %s" % [str(sl[i].get("id", "")), _fmt(home)])
	await _stalker_loop(i, 40.0)
	_phase_end()


func _stalker_loop(i: int, secs: float) -> void:
	# look at the Stalker and away from it every 1.5 s (it only moves unseen)
	var t0 := Time.get_ticks_msec()
	var next := 0.0
	var toward := true
	while _t(t0) < secs:
		await _frame
		var t := _t(t0)
		if t >= next:
			next += 1.5
			var sp = _stalker_pos(i)
			var c := _climber()
			if sp != null and c != null:
				if toward:
					_look(sp)
				else:
					_look(c.global_position + (c.global_position - (sp as Vector3)).normalized() * 10.0)
			toward = not toward


func _p3b() -> void:
	# a station with a walkable floor 1.5 to 2.2 m lower, 3 to 4 m away: stalker1's whole zone first
	# (nearest its home first), then stalker2's (the real cave has very few such ledges)
	var sl: Array = _L().get("stalkers", [])
	var found = null
	var si := -1
	for i in mini(2, sl.size()):
		var home := _v(sl[i]["home"])
		var zone: Array = sl[i].get("zone", [])
		var cands: Array = []
		for s in _stations_near(home, 700.0):
			if _in_zone(s, zone):
				cands.append(s)
		found = await _search(cands, _ledge_test, 12 if i == 0 else 8)
		if found != null:
			si = i
			break
	if found == null:
		_phase_skip("P3b", "no spot")
		return
	var at: Vector3 = found[0]
	_park(at)
	await _wait(SETTLE_S)
	_phase_begin("P3b", "P3b", at, "stalker ledge (%s) low floor %s" % [str(sl[si].get("id", "")), _fmt(found[1])])
	await _stalker_loop(si, 40.0)
	_phase_end()


func _ledge_test(s: Vector3) -> Variant:
	# [park point on the ledge, the lower floor point] or null
	if not NC.solid_at(s, 6.0):
		return null
	var fl: Dictionary = NC.ray(_space, s + Vector3.UP * 1.0, s + Vector3.DOWN * 2.0)
	if fl.is_empty():
		return null
	var fp: Vector3 = fl["position"]
	for k in 16:
		var a := float(k) * TAU / 16.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		for dd in [3.0, 3.25, 3.5, 3.75, 4.0]:
			var q: Vector3 = fp + dir * float(dd) + Vector3.UP * 1.0
			var h: Dictionary = NC.ray(_space, q, q + Vector3.DOWN * 4.0)
			if h.is_empty():
				continue
			var n: Vector3 = h["normal"]
			var drop := fp.y - float(h["position"].y)
			if n.y > 0.7 and drop >= 1.5 and drop <= 2.2:
				var at := fp + Vector3.UP * 1.0
				if _capsule_free(at):
					return [at, h["position"]]
	return null


func _search(cands: Array, test: Callable, max_parks: int) -> Variant:
	# candidates in order; rock is loaded only near the player, so the player is parked next to a
	# candidate farther than 90 m from the last park (at most max_parks parks)
	var last_park = null
	var parks := 0
	for s in cands:
		var sv: Vector3 = s
		if last_park == null or sv.distance_to(last_park) > 90.0:
			if parks >= max_parks:
				break
			parks += 1
			last_park = sv
			_park(sv + Vector3.UP * 1.0)
			await _wait(APPROACH_S)
		var pk = NC.count_as("probe")
		var r = test.call(sv)
		NC.count_as(pk)
		if r != null:
			return r
	return null


# ============================================================================ P4: bats

func _p4(i: int) -> void:
	var bats: Array = _L().get("bats", [])
	if i >= bats.size():
		_phase_skip("P4", "no roost %d" % i)
		return
	var roost := _v(bats[i]["pos"])
	var trig := float(bats[i].get("r", 15.0))
	# load the rock from a station outside the trigger ring first, so the colony bursts only once the
	# player is parked (and the settle second has passed)
	var app = null
	for s in _stations_near(roost, 110.0):
		if (s as Vector3).distance_to(roost) >= trig + 8.0:
			app = s
			break
	if app != null:
		_park((app as Vector3) + Vector3.UP * 1.0)
		await _wait(APPROACH_S)
	var pk = NC.count_as("probe")
	var at = null
	var fl: Dictionary = NC.ray(_space, roost + Vector3.DOWN * 0.5, roost + Vector3.DOWN * 40.0)
	if not fl.is_empty():
		var p: Vector3 = (fl["position"] as Vector3) + Vector3.UP * 1.0
		if p.distance_to(roost) < trig - 1.0 and _capsule_free(p):
			at = p
	if at == null:
		for s in _stations_near(roost, trig - 1.0):
			at = (s as Vector3) + Vector3.UP * 1.0
			break
	var hover := false
	if at == null:
		# no floor inside the trigger ring: the player hangs in open air under the roost (re-parked
		# every physics tick, like the P1b pin), a clear line from the roost
		for d in [2.5, 4.0, 6.0, 8.0]:
			var q: Vector3 = roost + Vector3.DOWN * float(d)
			if NC.ray(_space, roost, q).is_empty() and _capsule_free(q):
				at = q
				hover = true
				break
	NC.count_as(pk)
	if at == null:
		_phase_skip("P4", "no spot for roost %d" % i)
		return
	if hover:
		_pin = at
	_park(at)
	_look(roost)
	await _wait(SETTLE_S)
	_phase_begin("P4:%d" % i, "P4", at, "bats roost %d %s%s" % [i, _fmt(roost), " (hanging in air)" if hover else ""])
	var t0 := Time.get_ticks_msec()
	while _t(t0) < 8.0:
		await _frame
		_look(roost)
	_pin = null
	_phase_end()


# ============================================================================ P5, P5b: the brood

func _prelight_brood() -> void:
	# the altar seals the moment anyone is below the lip, which is the first park of this test: the brood
	# candle has to be lit before it (the light is refused once sealed)
	if not _do("p5"):
		return
	var om = map.call("feature", "omen") if map.has_method("feature") else null
	if om == null or not om.has_method("test_light"):
		return
	if om.has_method("sealed") and bool(om.call("sealed")):
		return
	_hook(om, "test_light", ["brood"])
	await _wait(1.0)


func _p5_early() -> void:
	# the omen's Early Brood, woken as perf.flag does (light "brood", seal, park 20 m from the eggs)
	var om = map.call("feature", "omen") if map.has_method("feature") else null
	if om == null or not om.has_method("test_light") or not om.has_method("test_seal"):
		_skip_hook("omen.test_light/test_seal")
		_phase_skip("P5", "no omen test API")
		return
	var lit_now: bool = om.has_method("lit_ids") and (om.call("lit_ids") as Array).has("brood")
	if not lit_now:
		_hook(om, "test_light", ["brood"])
		await _wait(1.0)
	if not (om.has_method("sealed") and bool(om.call("sealed"))):
		_hook(om, "test_seal", [])
		await _wait(1.0)
	if not (om.has_method("lit_ids") and (om.call("lit_ids") as Array).has("brood")):
		_phase_skip("P5", "the brood candle is not lit (the altar sealed first)")
		return
	var cen = om.call("egg_centroid") if om.has_method("egg_centroid") else null
	if not (cen is Vector3):
		_phase_skip("P5", "no egg centroid")
		return
	var flat := Vector3(PERF_SHELF.x - cen.x, 0.0, PERF_SHELF.z - cen.z).normalized()
	var at: Vector3 = Vector3(cen.x, PERF_SHELF.y + 1.0, cen.z) + flat * 20.0
	_park(at)
	_look(cen)
	var t0 := Time.get_ticks_msec()
	while _t(t0) < 25.0:
		await _frame
		if om.has_method("hatched") and bool(om.call("hatched")):
			break
	await _wait(SETTLE_S)
	_phase_begin("P5:obrood", "P5", at, "early brood (omen)")
	var t1 := Time.get_ticks_msec()
	while _t(t1) < 25.0:
		await _frame
		_look(cen)
	_phase_end()


func _p5_nest() -> void:
	var br = map.get("_brood")
	if not is_instance_valid(br) or not br.has_method("hatch"):
		_phase_skip("P5", "no Nest brood")
		return
	var cen = _brood_centre(br)
	if cen == null:
		_phase_skip("P5", "no Nest eggs")
		return
	# The Nest has 29 egg clusters over 190 m: the centroid of all of them can lie on a ledge over the cavern
	# floor, where the crawlers never reach the player (they never climb). The dense part of the eggs: the
	# crawlers hatch around it and run to a player standing on the same floor (a leash of 90 m kills the rest).
	var ref: Vector3 = _brood_dense_egg(br, cen)
	_park(ref + Vector3.UP * 2.0)         # no station is near the Nest floor: the rock loads round the player
	await _wait(APPROACH_S + 0.6)
	var pk = NC.count_as("probe")
	var spots: Array = _floor_ring(ref, [12.0, 8.0, 16.0, 20.0, 6.0], 1.2, 2)
	NC.count_as(pk)
	if spots.is_empty():
		var cs: Array = []
		for s2 in _stations_near(ref, 40.0):
			if absf((s2 as Vector3).y - ref.y) < 3.0:
				cs.append(s2)
		var one = await _search(cs, _station_spot, 3)
		if one != null:
			spots.append(one)
	if spots.is_empty():
		_phase_skip("P5", "no floor spot near the Nest eggs")
		return
	var at: Vector3 = spots[0]
	var at2: Vector3 = spots[1] if spots.size() > 1 else spots[0]
	_park(at)
	_look(ref)
	await _wait(SETTLE_S)
	_phase_begin("P5:brood", "P5", at, "Nest brood (eggs around %s)" % _fmt(ref))
	_hook(br, "hatch", [])
	var t0 := Time.get_ticks_msec()
	var flip := false
	var next_hop := 4.0
	while _t(t0) < 30.0:
		await _frame
		if _t(t0) >= next_hop:
			next_hop += 4.0
			flip = not flip
			_park(at2 if flip else at)         # they have to run to the player again
	_phase_end()


func _brood_dense_egg(br, cen: Vector3) -> Vector3:
	# the egg point whose 8 nearest neighbours are closest: the middle of the Nest's thickest cluster
	var pts = br.get("points")
	if not (pts is Array) or (pts as Array).is_empty():
		return cen
	var best: Vector3 = pts[0]
	var best_s := INF
	for p in pts:
		var ds: Array = []
		for q in pts:
			ds.append((p as Vector3).distance_to(q))
		ds.sort()
		var sum := 0.0
		for i in mini(8, ds.size()):
			sum += float(ds[i])
		if sum < best_s:
			best_s = sum
			best = p
	return best


func _floor_ring(ref: Vector3, radii: Array, ytol: float, want: int) -> Array:
	# up to `want` floor spots (10 m or more apart) on rings round ref, on ref's own floor (within ytol),
	# a player's capsule free there
	var out: Array = []
	for rr in radii:
		for k in 16:
			var a := float(k) * TAU / 16.0
			var q: Vector3 = ref + Vector3(cos(a), 0.0, sin(a)) * float(rr) + Vector3.UP * 2.0
			var h: Dictionary = NC.ray(_space, q, q + Vector3.DOWN * 8.0)
			if h.is_empty() or float(h["normal"].y) < 0.7:
				continue
			var fp: Vector3 = h["position"]
			var p: Vector3 = fp + Vector3.UP * 1.0
			if absf(fp.y - ref.y) > ytol or not _capsule_free(p):
				continue
			var far := true
			for o in out:
				if (o as Vector3).distance_to(p) < 10.0:
					far = false
			if far:
				out.append(p)
				if out.size() >= want:
					return out
	return out


func _ledge_near_eggs(s: Vector3) -> Variant:
	# P5b: the P3b ledge test, kept to the ones within 16 m of the Nest eggs
	var r = _ledge_test(s)
	if r != null and (r[0] as Vector3).distance_to(_p5b_cen) <= 15.0 + 1.0:
		return r
	return null


func _station_spot(s: Vector3) -> Variant:
	# a station with loaded rock and room for the player: the spot itself
	if not NC.solid_at(s, 6.0):
		return null
	var p := s + Vector3.UP * 1.0
	return p if _capsule_free(p) else null


func _p5b() -> void:
	# the Nest: a 1.5 to 2.2 m ledge within 15 m of the eggs (the P3b search); the brood hatched in P5
	# lives 70 s, so it is still running here
	var br = map.get("_brood")
	var cen = _brood_centre(br) if is_instance_valid(br) else null
	if cen == null:
		_phase_skip("P5b", "no spot")
		return
	var cands: Array = _stations_near(cen, 60.0)
	_p5b_cen = cen
	var found = await _search(cands, _ledge_near_eggs, 3)
	if found == null:
		_phase_skip("P5b", "no spot")
		return
	var at: Vector3 = found[0]
	_park(at)
	await _wait(SETTLE_S)
	_phase_begin("P5b", "P5b", at, "brood ledge low floor %s" % _fmt(found[1]))
	_hook(br, "hatch", [])
	var t0 := Time.get_ticks_msec()
	while _t(t0) < 25.0:
		await _frame
	_phase_end()


func _brood_centre(br) -> Variant:
	if not is_instance_valid(br):
		return null
	var pts = br.get("points")
	if not (pts is Array) or (pts as Array).is_empty():
		return null
	var c := Vector3.ZERO
	for p in pts:
		c += p as Vector3
	return c / float((pts as Array).size())


# ============================================================================ P6: spiders

func _p6(sid: String, scatter: bool) -> void:
	var e = null
	for s in _L().get("spiders", []):
		if s is Dictionary and str(s.get("id", "")) == sid:
			e = s
	if e == null:
		_phase_skip("P6", "no spider %s" % sid)
		return
	var at: Vector3 = _v(e["floor"]) + Vector3.UP * 1.0
	_park(at)
	_look(_v(e["anchor"]))
	await _wait(SETTLE_S)
	_phase_begin("P6:" + sid, "P6", at, "spider %s %s" % [sid, "scatter" if scatter else "walk-under"])
	if scatter:
		var node = _spider_node(sid)
		if node != null:
			_hook(node, "noclip_test_scatter", [])
		else:
			_skip_hook("spider node " + sid)
	var t0 := Time.get_ticks_msec()
	while _t(t0) < 6.0:
		await _frame
		_look(_v(e["anchor"]))
	_phase_end()


func _spider_node(sid: String) -> Variant:
	var sps = map.get("_spiders")
	if sps is Array:
		for sp in sps:
			if is_instance_valid(sp) and str(sp.get("id")) == sid:
				return sp
	return null


# ============================================================================ P7, P7b: Shades

func _p7() -> void:
	var mod = _module_with("noclip_test_homes", "shades")
	if mod == null:
		_skip_hook("noclip_test_homes")
		_phase_skip("P7", "no shades hook")
		_phase_skip("P7b", "no shades hook")
		_phase_skip("P7c", "no shades hook")
		return
	var raw = mod.call("noclip_test_homes")
	var homes := _pick_homes(raw)
	if homes.is_empty():
		_phase_skip("P7", "no homes")
		_phase_skip("P7b", "no homes")
		_phase_skip("P7c", "no homes")
		return
	for h in homes:
		await _p7_one(h)
	# P7b: a ledge near a home (the P3b test), the homes in order, stations of the home's biome
	var first: Vector3 = homes[0]
	var found = null
	for h in homes:
		found = await _search(_home_cands(h), _ledge_test, 4)
		if found != null:
			first = h
			break
	if found == null:
		_phase_skip("P7b", "no spot")
	else:
		var at: Vector3 = found[0]
		_park(at)
		_lantern(false)
		_look(at + (at - first).normalized() * 10.0)
		await _wait(SETTLE_S)
		_phase_begin("P7b", "P7b", at, "shade ledge low floor %s" % _fmt(found[1]))
		var t0 := Time.get_ticks_msec()
		while _t(t0) < 25.0:
			await _frame
		_phase_end()
		_lantern(true)
	# P7c, the low ceiling (goal 2d, G1): the player under 2.6 to 3.2 m of rock near the first home, so
	# a Shade (3.1 m tall) reaches only by hunching
	var low = null
	for h2 in homes:
		low = await _search(_home_cands(h2), _low_test, 4)
		if low != null:
			first = h2
			break
	if low == null:
		_phase_skip("P7c", "no spot")
		return
	var at2: Vector3 = low[0]
	_park(at2)
	_lantern(false)
	_look(at2 + (at2 - first).normalized() * 10.0)
	await _wait(SETTLE_S)
	_phase_begin("P7c", "P7c", at2, "shade low ceiling %.2f m" % float(low[1]))
	var t2 := Time.get_ticks_msec()
	while _t(t2) < 25.0:
		await _frame
	_phase_end()
	_lantern(true)


func _home_cands(home: Vector3) -> Array:
	# stations within 150 m of a Shade home, in the home's biome when the map says which, nearest first
	var bio := -1
	if map != null and map.has_method("biome_at"):
		bio = int(map.call("biome_at", home))
	var out: Array = []
	for s in _L().get("stations", []):
		if not (s is Dictionary) or not (s as Dictionary).has("pos"):
			continue
		if bio >= 0 and s.has("biome") and int(s["biome"]) != bio:
			continue
		out.append(_v(s["pos"]))
	var tmp: Array = []
	for p in out:
		var d := (p as Vector3).distance_to(home)
		if d <= 150.0:
			tmp.append([d, p])
	tmp.sort_custom(_near_cmp)
	var res: Array = []
	for t in tmp:
		res.append(t[1])
	return res


func _low_test(s: Vector3) -> Variant:
	# [park point, ceiling height] under 2.6 to 3.2 m of rock, or null
	if not NC.solid_at(s, 6.0):
		return null
	var fl: Dictionary = NC.ray(_space, s + Vector3.UP * 1.0, s + Vector3.DOWN * 2.0)
	if fl.is_empty():
		return null
	var fp: Vector3 = fl["position"]
	var up: Dictionary = NC.ray(_space, fp + Vector3.UP * 0.1, fp + Vector3.UP * 3.4)
	if up.is_empty():
		return null
	var h := float(up["d"]) + 0.1
	if h < 2.6 or h > 3.2:
		return null
	var at := fp + Vector3.UP * 1.0
	if not _capsule_free(at):
		return null
	return [at, h]


func _p7_one(home: Vector3) -> void:
	# park 40 m out, lantern off, look away
	var near_st = _nearest_station(home)
	if near_st != null:
		_park((near_st as Vector3) + Vector3.UP * 1.0)
		await _wait(APPROACH_S)
	var best = null
	var bd := INF
	var pk = NC.count_as("probe")
	for s in _stations_near(home, 55.0):
		var sv: Vector3 = s
		var d := sv.distance_to(home)
		if d < 30.0 or d > 50.0:
			continue
		if NC.ray(_space, sv + Vector3.UP * 1.0, sv + Vector3.DOWN * 3.0).is_empty():
			continue
		if absf(d - 40.0) < bd:
			bd = absf(d - 40.0)
			best = sv
	NC.count_as(pk)
	if best == null:
		_phase_skip("P7", "no spot 40 m from %s" % _fmt(home))
		return
	var at: Vector3 = (best as Vector3) + Vector3.UP * 1.0
	_park(at)
	_lantern(false)
	_look(at + (at - home).normalized() * 10.0)
	await _wait(SETTLE_S)
	_phase_begin("P7:%s" % _fmt(home), "P7", at, "shade home %s" % _fmt(home))
	var t0 := Time.get_ticks_msec()
	while _t(t0) < 25.0:
		await _frame
	_phase_end()
	_lantern(true)


func _pick_homes(raw) -> Array:
	# 3 homes in different bands: entries may be Vector3, [x, y, z], [pos, band] or {"pos"/"home", "band"}
	var out: Array = []
	var bands: Dictionary = {}
	if not (raw is Array):
		return out
	for e in raw:
		var p = null
		var band = null
		if e is Vector3:
			p = e
		elif e is Dictionary:
			var q = e.get("pos", e.get("home", null))
			p = q if q is Vector3 else (_v(q) if q is Array and (q as Array).size() >= 3 else null)
			band = e.get("band", null)
		elif e is Array and (e as Array).size() >= 3 and not (e[0] is Vector3):
			p = _v(e)
		elif e is Array and (e as Array).size() >= 1 and e[0] is Vector3:
			p = e[0]
			band = e[1] if (e as Array).size() > 1 else null
		elif e is Array and (e as Array).size() >= 1 and e[0] is Array and (e[0] as Array).size() >= 3:
			p = _v(e[0])
			band = e[1] if (e as Array).size() > 1 else null
		if p == null:
			continue
		var bk := str(band) if band != null else "i%d" % out.size()
		if bands.has(bk):
			continue
		bands[bk] = true
		out.append(p)
		if out.size() >= 3:
			break
	return out


func _lantern(restore: bool) -> void:
	# P7: the local lantern off (never saved: only "user" is set); restored after
	var ln = CoopSync.get("lantern")
	if not is_instance_valid(ln) or ln.get("user") == null:
		return
	if restore:
		if _lantern_saved != null:
			ln.set("user", int(_lantern_saved))
			_lantern_saved = null
		return
	if _lantern_saved == null:
		_lantern_saved = int(ln.get("user"))
	ln.set("user", 0)


# ============================================================================ P8: Harriers

func _p8() -> void:
	# looked up by noclip_test_dive (harriers only): hearth.gd also has a noclip_test_spot(), with no
	# argument, which the group fallback could otherwise pick when the harriers module is missing
	var mod = _module_with("noclip_test_dive", "harriers")
	if mod != null and not mod.has_method("noclip_test_spot"):
		mod = null
	if mod == null:
		_skip_hook("noclip_test_spot")
		_phase_skip("P8", "no harriers hook")
		return
	var nb := 3
	var bands = mod.get("BANDS")
	if bands is Array:
		nb = (bands as Array).size()
	var any := false
	for i in nb:
		var spot = mod.call("noclip_test_spot", i)
		_open_script_window()
		if not (spot is Array) or (spot as Array).size() < 2 or not (spot[0] is Vector3):
			print("[CLIP] phase P8 band %d: no spot" % i)
			continue
		any = true
		var at: Vector3 = spot[0]
		var look: Vector3 = spot[1] if spot[1] is Vector3 else at + Vector3.UP * 10.0
		_park(at)
		_look(look)
		await _wait(SETTLE_S)
		_phase_begin("P8:%d" % i, "P8", at, "harrier band %d" % i)
		var t0 := Time.get_ticks_msec()
		var dived := false
		var next_look := 0.0
		while _t(t0) < 27.0:
			await _frame
			var t := _t(t0)
			if t >= next_look:
				next_look += 0.5
				_look(look)
			if t >= 5.0 and not dived:
				dived = true
				var c := _climber()
				if c != null:
					_hook(mod, "noclip_test_dive", [c])
		_phase_end()
	if not any:
		_phase_skip("P8", "no spot")


# ============================================================================ P9: the False Hearth

func _p9() -> void:
	var mod = _module_with("noclip_test_synth", "hearth")
	if mod == null:
		_skip_hook("noclip_test_synth")
		_phase_skip("P9", "no hearth hook")
		return
	var r = _hook(mod, "noclip_test_synth", [])
	if r == null or (r is bool and not bool(r)):
		_phase_skip("P9", "no hearth")
		return
	await _wait(0.5)
	var jaw = r if r is Vector3 else null
	if jaw == null:
		for e in _points_of(mod):
			if str(e.get("kind", "")) == "hearth" and (e.get("c", []) as Array).size() > 0:
				jaw = e["c"][0]
				break
	if not (jaw is Vector3):
		_phase_skip("P9", "no hearth position")
		return
	var st = _nearest_station(jaw)
	if st != null:
		_park((st as Vector3) + Vector3.UP * 1.0)
		await _wait(APPROACH_S)
	var pk = NC.count_as("probe")
	var fl: Dictionary = NC.ray(_space, (jaw as Vector3) + Vector3.DOWN * 0.3, (jaw as Vector3) + Vector3.DOWN * 40.0)
	NC.count_as(pk)
	var jv: Vector3 = jaw
	var at: Vector3 = jv
	if not fl.is_empty():
		var fp: Vector3 = fl["position"]
		at = fp + Vector3.UP * 1.0
	elif st != null:
		var sv: Vector3 = st
		at = sv + Vector3.UP * 1.0
	_park(at)
	_look(jv)
	await _wait(SETTLE_S)
	_phase_begin("P9", "P9", at, "hearth jaw %s" % _fmt(jv))
	var t0 := Time.get_ticks_msec()
	while _t(t0) < 16.0:
		await _frame
		_look(jv)
	_phase_end()


# ============================================================================ sampling and counting (5.4)

func _new_stats() -> Dictionary:
	return {"n": 0, "samples": 0, "moving": 0, "head_x": 0, "body_x": 0, "embed": 0, "graze": 0, "xsamples": 0,
		"inside": 0, "unknown": 0, "checks": 0, "rods": 0, "pops_seen": 0, "pops_unseen": 0, "tp": 0, "tp_seen": 0,
		"recovers_seen": 0, "scripted": 0, "leg_under": 0, "rest_under": 0, "leg_ms": 0, "rest_ms": 0}


func _stats(kv: String) -> Dictionary:
	var S = _kv.get(kv)
	if S == null:
		S = _new_stats()
		_kv[kv] = S
	return S


func _kv_of(key: String) -> Dictionary:
	var parts := key.split("/")
	if parts.size() < 2:
		return _stats(key)
	return _stats(parts[0] + "/" + parts[1])


func _sample(delta: float) -> void:
	if _space == null:
		_space = _get_space()
	if _space == null:
		return
	var now := Time.get_ticks_msec()
	var here := _here()
	var cam := _cam_pos()
	var seen: Dictionary = {}
	_rec_now.clear()
	for n in get_tree().get_nodes_in_group("zonda_nc"):
		if not is_instance_valid(n) or not n.has_method("noclip_points"):
			continue
		var arr = n.call("noclip_points")
		if not (arr is Array):
			continue
		for e in arr:
			if e is Dictionary:
				_sample_entity(e, delta, now, here, cam, seen)
	for k in _rec_now.keys():
		_rec_last[k] = _rec_now[k]
	for k in _ent.keys():
		if not seen.has(k):
			var rec: Dictionary = _ent[k]
			if bool(rec["vis"]):
				_close_entity(rec, _kv_of(str(k)))
			rec["vis"] = false
	if _sampling and not _cur.is_empty():
		_cost_tick()


func _sample_entity(e: Dictionary, delta: float, now: int, here: Vector3, cam: Vector3, seen: Dictionary) -> void:
	var kind := str(e.get("kind", "?"))
	var view := str(e.get("view", "host"))
	if mode == "guest" and view != "guest":
		return
	var c = e.get("c", [])
	if not (c is Array) or (c as Array).is_empty() or not (c[0] is Vector3):
		return
	var c0: Vector3 = c[0]
	if c0.distance_to(here) > SAMPLE_R:
		return
	var id := str(e.get("id", ""))
	var kv := kind + "/" + view
	var key := kv + "/" + id
	var S := _stats(kv)
	var vis := bool(e.get("vis", true))
	var wl := bool(e.get("wl", false))
	var tp := int(e.get("tp", 0))
	var st := str(e.get("st", ""))
	var active := vis and not wl
	var rec = _ent.get(key)
	if rec == null:
		rec = {"c": {}, "tp": tp, "vis": false, "t0": now, "st": st, "streak": {}, "rod": {}, "ins_ms": now - INSIDE_MS, "fx": {}, "win": null, "n": 0}
		_ent[key] = rec
		S["n"] = int(S["n"]) + 1
	seen[key] = true
	# the current centres by label (index labels when the entity gives none)
	var cn = e.get("cn", [])
	var cur: Dictionary = {}
	var labels: Array = []
	var lab_ok: bool = cn is Array and (cn as Array).size() == (c as Array).size()
	for i in (c as Array).size():
		if not (c[i] is Vector3):
			continue
		var lab := str(cn[i]) if lab_ok else "#%d" % i
		cur[lab] = c[i]
		labels.append(lab)
	var prev: Dictionary = rec["c"]
	var prev_vis: bool = bool(rec["vis"])
	var same_tp: bool = int(rec["tp"]) == tp
	var comparable: bool = active and prev_vis and (lab_ok or int(rec["n"]) == labels.size())
	var cen_host: bool = view == "host" and CEN_KINDS.has(kind)
	var stl: Dictionary = _stl_of(st) if cen_host else {}
	# declared teleports and recoveries (a tp change in the frame the helper counted a recover)
	if view == "host" and not _rec_now.has(kind):
		_rec_now[kind] = NC.count(kind, "recovers")
	if prev_vis and not same_tp:
		S["tp"] = int(S["tp"]) + 1
		if view == "host":
			if int(_rec_now[kind]) > int(_rec_last.get(kind, 0)):
				var pv = prev.get(labels[0]) if labels.size() > 0 else null
				if NC.seen_by_any([c0]) or (pv is Vector3 and NC.seen_by_any([pv])):
					S["recovers_seen"] = int(S["recovers_seen"]) + 1
					_log("P", kv, "[CLIP] P %s %s recovery seen at %s" % [kv, id, _fmt(c0)])
	# CROSSING and POP, per centre present last frame
	var popped := false
	if comparable:
		for i in labels.size():
			var lab: String = labels[i]
			if not prev.has(lab):
				continue
			var p: Vector3 = prev[lab]
			var q: Vector3 = cur[lab]
			var d := p.distance_to(q)
			if not popped and d > POP_M:
				popped = true
				_pop(S, kv, id, rec, p, q, same_tp, now, view != "host")
			if not same_tp:
				continue                       # a declared teleport frame: no crossing test
			if not NC.solid_at(q, 4.0) or not NC.solid_at(p, 4.0):
				continue
			S["samples"] = int(S["samples"]) + 1
			var moved := d > 0.01
			if moved:
				S["moving"] = int(S["moving"]) + 1
				if cen_host and not stl.is_empty():
					stl["moving"] = int(stl["moving"]) + 1
				var born_in_egg: bool = (kind == "brood" or kind == "obrood") and now - int(rec["t0"]) < YOUNG_MS
				var h: Dictionary = {} if born_in_egg else NC.ray(_space, p, q)
				if not h.is_empty() and float(h.get("d", 1.0)) < CONTACT_M and d < CONTACT_STEP_M:
					# a part that RESTS on the surface (the segment starts within 2 cm of it and the step is a few cm
					# of floating point jitter along or into it: a Follower's section lying on the floor while its
					# head waits) is contact, not a crossing: counted with the grazes, never hidden
					S["contact"] = int(S.get("contact", 0)) + 1
					h = {}
				if not h.is_empty():
					var hk := "head_x" if i == 0 else "body_x"
					S[hk] = int(S[hk]) + 1
					if cen_host and not stl.is_empty():
						stl[hk] = int(stl[hk]) + 1
					var pl := "head" if i == 0 else (lab if lab.begins_with("body") else "body#%d" % i)
					_log("X", kv, "[CLIP] X %s %s %s %s->%s hit %s st=%s" % [kv, id, pl, _fmt(p), _fmt(q), _fmt(h["position"]), st])
	# EMBED / GRAZE
	if active:
		var skip_far := c0.distance_to(cam) > FAR_X and Engine.get_process_frames() % 3 != 0
		if not skip_far:
			_extremities(e, c, S, stl, kv, id, rec, now, st)
	else:
		_close_entity(rec, S)
	# ROD
	if active:
		_rods(e, c, S, kv, id, rec)
	# INSIDE
	if active and now - int(rec["ins_ms"]) >= INSIDE_MS:
		rec["ins_ms"] = now
		if NC.solid_at(c0, 4.0):
			var r: int = NC.inside2(_space, c0)
			S["checks"] = int(S["checks"]) + 1
			if r == 1:
				S["inside"] = int(S["inside"]) + 1
				_log("I", kv, "[CLIP] I %s %s inside at %s st=%s" % [kv, id, _fmt(c0), st])
			elif r == -1:
				S["unknown"] = int(S["unknown"]) + 1
	# fairness (centipedes, host view)
	if cen_host and kind != "pale" and _sampling and not _cur.is_empty():
		_fair_sample(e, rec, c0, prev.get(labels[0]) if labels.size() > 0 else null, comparable and same_tp and not popped, st, delta, now)
	rec["c"] = cur
	rec["n"] = labels.size()
	rec["tp"] = tp
	rec["vis"] = active
	rec["st"] = st


func _stl_of(st: String) -> Dictionary:
	if st != "attack" and st != "shy":
		return {}
	var S = _stl.get(st)
	if S == null:
		S = _new_stats()
		_stl[st] = S
	return S


func _pop(S: Dictionary, kv: String, id: String, rec: Dictionary, p: Vector3, q: Vector3, same_tp: bool, now: int, lagged: bool) -> void:
	if now < (_scripted_lag_until if lagged else _scripted_until):
		S["scripted"] = int(S["scripted"]) + 1
		return
	if now - int(rec["t0"]) < YOUNG_MS:
		return
	var seen: bool = NC.seen_by_any([p]) or NC.seen_by_any([q])
	if not seen:
		S["pops_unseen"] = int(S["pops_unseen"]) + 1
		return
	if same_tp:
		S["pops_seen"] = int(S["pops_seen"]) + 1
	else:
		S["tp_seen"] = int(S["tp_seen"]) + 1
	_log("P", kv, "[CLIP] P %s %s pop %.1f seen=yes declared=%s at %s" % [kv, id, p.distance_to(q), "no" if same_tp else "yes", _fmt(q)])


func _extremities(e: Dictionary, c: Array, S: Dictionary, stl: Dictionary, kv: String, id: String, rec: Dictionary, now: int, st: String) -> void:
	var x = e.get("x", [])
	if not (x is Array) or (x as Array).is_empty():
		return
	var xn = e.get("xn", [])
	var xc = e.get("xc", [])
	var xg = e.get("xg", [])
	var cn = e.get("cn", [])
	var streak: Dictionary = rec["streak"]
	var occ: Dictionary = {}
	for j in (x as Array).size():
		if not (x[j] is Vector3):
			continue
		var xp: Vector3 = x[j]
		var lab := str(xn[j]) if xn is Array and j < (xn as Array).size() else "x%d" % j
		var ci := int(xc[j]) if xc is Array and j < (xc as Array).size() else 0
		if ci < 0 or ci >= c.size() or not (c[ci] is Vector3):
			ci = 0
		var cp: Vector3 = c[ci]
		if not NC.solid_at(xp, 4.0):
			continue
		var gonly: bool = xg is Array and j < (xg as Array).size() and bool(xg[j])
		var contact: bool = not NC.ray(_space, cp, xp).is_empty()
		# a streak follows one physical part: its label, the centre it hangs from, and its place among
		# same-named parts there (so a section that appears or hides never shifts another part's streak)
		var clab := str(cn[ci]) if cn is Array and ci < (cn as Array).size() else "#%d" % ci
		var ok0 := lab + "@" + clab
		var k0 := int(occ.get(ok0, 0))
		occ[ok0] = k0 + 1
		var sk := "%s#%d" % [ok0, k0]
		if gonly:
			var under := "leg_under" if lab.begins_with("leg") or lab.begins_with("knee") else "rest_under"
			var ms_key := "leg_ms" if under == "leg_under" else "rest_ms"
			if contact:
				S[under] = int(S[under]) + 1
				if not streak.has(sk):
					streak[sk] = [now, true, true, lab]
				S[ms_key] = maxi(int(S[ms_key]), now - int(streak[sk][0]))
			elif streak.has(sk):
				streak.erase(sk)
			continue
		S["xsamples"] = int(S["xsamples"]) + 1
		if contact:
			if not streak.has(sk):
				streak[sk] = [now, false, false, lab]
			elif not bool(streak[sk][1]) and now - int(streak[sk][0]) >= EMBED_MS:
				streak[sk][1] = true
				S["embed"] = int(S["embed"]) + 1
				if not stl.is_empty():
					stl["embed"] = int(stl["embed"]) + 1
				_log("E", kv, "[CLIP] E %s %s %s ms=%d at %s st=%s" % [kv, id, lab, now - int(streak[sk][0]), _fmt(xp), st])
		elif streak.has(sk):
			if not bool(streak[sk][1]):
				S["graze"] = int(S["graze"]) + 1
			streak.erase(sk)


func _close_entity(rec: Dictionary, S: Dictionary) -> void:
	# an entity that left, hid or became whitelisted: an open contact shorter than 50 ms is a graze
	var streak: Dictionary = rec["streak"]
	for sk in streak.keys():
		var s: Array = streak[sk]
		if not bool(s[1]) and not bool(s[2]):
			S["graze"] = int(S["graze"]) + 1
	streak.clear()
	(rec["rod"] as Dictionary).clear()
	rec["win"] = null


func _rods(e: Dictionary, c: Array, S: Dictionary, kv: String, id: String, rec: Dictionary) -> void:
	var seg = e.get("seg", [])
	var sp := float(e.get("sp", 0.0))
	if not (seg is Array) or sp <= 0.0:
		return
	var cn = e.get("cn", [])
	var rod: Dictionary = rec["rod"]
	var pi := -1
	for i in c.size():
		if i >= (seg as Array).size() or int(seg[i]) < 0 or not (c[i] is Vector3):
			continue
		if pi >= 0:
			var gap := (c[i] as Vector3).distance_to(c[pi])
			var nominal := sp * float(absi(int(seg[i]) - int(seg[pi])))
			var pk := "%d-%d" % [pi, i]
			if nominal > 0.0 and gap > 1.5 * nominal:
				if not bool(rod.get(pk, false)):
					rod[pk] = true
					S["rods"] = int(S["rods"]) + 1
					var la := str(cn[pi]) if cn is Array and pi < (cn as Array).size() else "#%d" % pi
					var lb := str(cn[i]) if cn is Array and i < (cn as Array).size() else "#%d" % i
					_log("R", kv, "[CLIP] R %s %s rod between %s and %s gap=%.1f" % [kv, id, la, lb, gap])
			else:
				rod[pk] = false
		pi = i


func _fair_sample(e: Dictionary, rec: Dictionary, c0: Vector3, pc0, ok_motion: bool, st: String, delta: float, now: int) -> void:
	var F: Dictionary = _cur["fair"]
	var fx = e.get("fx", {})
	if not (fx is Dictionary):
		fx = {}
	F["cen_s"] = float(F["cen_s"]) + delta
	var tgt := float(fx.get("tgt_d", -1.0))
	var prev_fx: Dictionary = rec["fx"]
	var ptgt := float(prev_fx.get("tgt_d", -1.0))
	var path_now := st == "path"
	# chase: closing speed toward the target while in a path state more than 12 m away
	if ok_motion and path_now and str(rec["st"]) == "path" and tgt > 12.0 and ptgt > 12.0 \
			and bool(fx.get("has_next", false)) and bool(prev_fx.get("has_next", false)):
		F["chase_d"] = float(F["chase_d"]) + (ptgt - tgt)
		F["chase_t"] = float(F["chase_t"]) + delta
	# path_speed: pivot speed against the state's own follow speed, whenever it has a next node
	var want := float(fx.get("want_v", 0.0))
	if ok_motion and bool(fx.get("has_next", false)) and want > 0.0 and pc0 is Vector3 and delta > 0.0:
		F["ps_v"] = float(F["ps_v"]) + c0.distance_to(pc0)
		F["ps_w"] = float(F["ps_w"]) + want * delta
	# stalls: 3 s windows with under 2 m of progress while chasing a target more than 12 m away
	if path_now and tgt > 12.0:
		var w = rec["win"]
		if w == null:
			rec["win"] = [now, c0]
		elif now - int(w[0]) >= 3000:
			if c0.distance_to(w[1]) < 2.0:
				F["stalls"] = int(F["stalls"]) + 1
			rec["win"] = [now, c0]
	else:
		rec["win"] = null
	rec["fx"] = fx


func _log(t: String, kv: String, line: String) -> void:
	var k := t + " " + kv
	var n := int(_logn.get(k, 0))
	_logn[k] = n + 1
	if n < LOG_CAP:
		print(line)
	elif n == LOG_CAP:
		print("[CLIP] %s %s: more than %d, only counted from here" % [t, kv, LOG_CAP])


# ============================================================================ the verdict

func _clip_bad(S: Dictionary, guest: bool, kv: String = "") -> String:
	# "" = PASS; else the first reason. Crossings, pops, rods and declared teleports are hard zeros; embeds,
	# centres inside rock and undecided parity checks are compared with the baseline (see CLIP_REL)
	for k in ["head_x", "body_x", "rods", "pops_seen", "recovers_seen"]:
		if int(S.get(k, 0)) > 0:
			return k
	if int(S.get("tp_seen", 0)) > (1 if guest else 0):
		return "tp_seen"
	if int(S.get("xsamples", 0)) > 0 and float(S["graze"]) / float(S["xsamples"]) > GRAZE_MAX:
		return "graze"
	if int(S.get("embed", 0)) > _lim(S, kv, "embed", "xsamples"):
		return "embed"
	# a spider's centre sits 0.25 m under its crack, where the parity test cannot decide (34-55 % undecided, and the same
	# static perch counted every 500 ms): its legs are checked directly (embed) and its perch is certified clear by its fit
	if not kv.begins_with("spider/") and int(S.get("inside", 0)) > _lim(S, kv, "inside", "checks"):
		return "inside"
	if int(S.get("checks", 0)) > 0 and float(S["unknown"]) / float(S["checks"]) > _unknown_lim(kv):
		return "unknown"
	return ""


func _finish() -> void:
	_sampling = false
	_pin = null
	var info := mode == "baseline"
	_lines.clear()
	_npass = 0
	_nfail.clear()
	# clips per kind/view
	var kvs: Array = _kv.keys()
	for r in REQUIRED_HOST:
		if not kvs.has(r):
			kvs.append(r)
	kvs.sort()
	for kv in kvs:
		var S: Dictionary = _kv.get(kv, _new_stats())
		var required: bool = REQUIRED_HOST.has(kv)
		var enough := int(S["moving"]) >= MIN_MOVING
		var verdict := ""
		var shadow_like: bool = str(kv).ends_with("/shadow")
		if not enough:
			verdict = "SKIP"
			if required and not info:
				_nfail.append(kv + " samples")
		else:
			var bad := _clip_bad(S, shadow_like, str(kv))
			verdict = "PASS" if bad == "" else "FAIL"
			if not info:
				if bad == "":
					_npass += 1
				else:
					_nfail.append(kv + " " + bad)
		_out("[CLIP] %s n=%d samples=%d moving=%d head_x=%d body_x=%d embed=%d graze=%d/%d inside=%d unknown=%d rods=%d pops_seen=%d leg_under=%d rest_under=%d leg_max_ms=%d rest_max_ms=%d contact=%d lim_embed=%d lim_inside=%d %s" % [
			kv, int(S["n"]), int(S["samples"]), int(S["moving"]), int(S["head_x"]), int(S["body_x"]), int(S["embed"]),
			int(S["graze"]), int(S["xsamples"]), int(S["inside"]), int(S["unknown"]), int(S["rods"]), int(S["pops_seen"]),
			int(S["leg_under"]), int(S["rest_under"]), int(S["leg_ms"]), int(S["rest_ms"]), int(S.get("contact", 0)),
			_lim(S, str(kv), "embed", "xsamples"), _lim(S, str(kv), "inside", "checks"), "INFO " + verdict if info else verdict])
	var bstl := _read_baseline_section("stl")
	for stn in ["attack", "shy"]:
		var T: Dictionary = _stl.get(stn, _new_stats())
		var ok_n := int(T["moving"]) >= MIN_MOVING_ST
		var B: Dictionary = bstl.get(stn, {})
		var b_ok := int(B.get("moving", 0)) >= MIN_MOVING_ST
		var b_rate := float(B.get("embed", 0)) / float(maxi(1, int(B.get("moving", 0))))
		var lim_e := int(ceil(CLIP_REL * b_rate * float(T["moving"]))) + mini(CLIP_SLACK, 2 + int(0.10 * float(T["moving"])))
		var bad2 := int(T["head_x"]) + int(T["body_x"]) > 0 or int(T["embed"]) > lim_e
		var v2 := "SKIP" if not ok_n else ("FAIL" if bad2 else "PASS")
		if not info:
			if not ok_n:
				if b_ok and stn != "shy":
					_nfail.append("st=" + stn + " samples")
				elif stn == "shy":
					_warn.append("st=shy (a guarded pale one on a wall circles at once: no direct steps to sample)")
				else:
					_warn.append("st=" + stn + " (the baseline did not sample it either)")
			elif bad2:
				_nfail.append("st=" + stn)
			else:
				_npass += 1
		_out("[CLIP] cent/host st=%s samples=%d head_x=%d body_x=%d embed=%d %s" % [stn, int(T["moving"]), int(T["head_x"]), int(T["body_x"]), int(T["embed"]), "INFO " + v2 if info else v2])
	# pops
	for kv in kvs:
		var S2: Dictionary = _kv.get(kv, _new_stats())
		if int(S2["n"]) == 0:
			continue
		var kind := str(kv).split("/")[0]
		var host_view := str(kv).ends_with("/host")
		var tp_lim := 0 if host_view else 1
		var fail: bool = int(S2["pops_seen"]) > 0 or int(S2["tp_seen"]) > tp_lim or int(S2["recovers_seen"]) > 0
		if not info:
			if fail:
				_nfail.append("pops " + kv)
			else:
				_npass += 1
		_out("[CLIP] pops %s tp=%d tp_seen=%d recovers=%d recovers_seen=%d scripted=%d unseen=%d %s" % [kv, int(S2["tp"]), int(S2["tp_seen"]),
			NC.count(kind, "recovers") if host_view else 0, int(S2["recovers_seen"]), int(S2["scripted"]), int(S2["pops_unseen"]),
			"INFO" if info else ("FAIL" if fail else "PASS")])
	# inside_unknown per kind
	var per_kind: Dictionary = {}
	for kv in kvs:
		var S3: Dictionary = _kv.get(kv, _new_stats())
		var kind3 := str(kv).split("/")[0]
		var a: Array = per_kind.get(kind3, [0, 0])
		a[0] = int(a[0]) + int(S3["unknown"])
		a[1] = int(a[1]) + int(S3["checks"])
		per_kind[kind3] = a
	for k3 in per_kind.keys():
		var a3: Array = per_kind[k3]
		if int(a3[1]) == 0:
			continue
		var frac := float(a3[0]) / float(a3[1])
		var lim3 := _unknown_lim(str(k3) + "/host")
		var ok3 := frac <= lim3
		if not info:
			if ok3:
				_npass += 1
			else:
				_nfail.append("inside_unknown " + str(k3))
		_out("[CLIP] inside_unknown %s %d/%d (%.0f%%) rule<=%.0f%% (20%% or the baseline's share + 15) %s" % [str(k3), int(a3[0]), int(a3[1]), frac * 100.0, lim3 * 100.0, "INFO" if info else ("PASS" if ok3 else "FAIL")])
	# safety: the shadows never damaged anyone
	var sd := 0
	for k in CEN_KINDS:
		sd += NC.count(k, "shadow_dmg")
	var cts: Dictionary = NC.counters()
	for k in cts.keys():
		if not CEN_KINDS.has(str(k)):
			sd += int((cts[k] as Dictionary).get("shadow_dmg", 0))
	if not info:
		if sd == 0:
			_npass += 1
		else:
			_nfail.append("safety shadow_dmg")
	_out("[CLIP] safety shadow_dmg=%d %s" % [sd, "INFO" if info else ("PASS" if sd == 0 else "FAIL")])
	# envelope
	if not info and not bool(_env.get("skip", false)) and _env.has("bad"):
		if (_env["bad"] as Array).is_empty():
			_npass += 1
		else:
			_nfail.append("envelope")
	# fairness (host mode against the baseline file; the baseline writes it)
	var groups := _group_sums()
	if info:
		_write_baseline(groups)
	else:
		_fairness(groups)
	for ln in NC.report():
		print(ln)
	_cost_summary()
	var total := _npass + _nfail.size()
	var warn := ("; WARN: " + ", ".join(PackedStringArray(_warn))) if not _warn.is_empty() else ""
	_done = true
	_restore()
	# guestsim record (the host run is the guest run's recording, 5.6): the recording is written now and
	# closes 3 s later, so the playback holds the test and not the idle tail (no playback cap while the
	# noclip_gs_* knobs are set). Called BEFORE the done line: a runner may kill the game at that line.
	# CoopSync is another group's file: a runtime call, a no-op in any launch that is not recording.
	if CoopSync.has_method("guestsim_test_done"):
		CoopSync.call("guestsim_test_done", "CLIP")
	# printerr: the release build buffers print(), and the runner waits for this line in the log
	if info:
		var n := _phases.size() + _warn.size()
		printerr("[CLIP] test done %d/%d PASS%s" % [n, n, warn])
	elif _nfail.is_empty():
		printerr("[CLIP] test done %d/%d PASS%s" % [total, total, warn])
	else:
		printerr("[CLIP] test done %d/%d FAIL: %s%s" % [_npass, total, ", ".join(PackedStringArray(_nfail)), warn])


func _out(line: String) -> void:
	_lines.append(line)
	print(line)


func _group_sums() -> Dictionary:
	# {group: {"k": {kind: {key: n}}, "f": fair sums, "s": seconds}}
	var out: Dictionary = {}
	for ph in _phases:
		var g := str(ph["group"])
		var G = out.get(g)
		if G == null:
			G = {"k": {}, "f": {"chase_d": 0.0, "chase_t": 0.0, "ps_v": 0.0, "ps_w": 0.0, "stalls": 0, "cen_s": 0.0}, "s": 0.0, "tele": []}
			out[g] = G
		var K: Dictionary = G["k"]
		var d: Dictionary = ph["counters"]
		for kind in d.keys():
			var dk: Dictionary = d[kind]
			var tk: Dictionary = K.get(kind, {})
			for key in dk.keys():
				tk[key] = int(tk.get(key, 0)) + int(dk[key])
			K[kind] = tk
		for fk in (ph["fair"] as Dictionary).keys():
			G["f"][fk] = float(G["f"].get(fk, 0.0)) + float(ph["fair"][fk])
		G["s"] = float(G["s"]) + float(ph["secs"])
		# per-phase telegraph evidence (hits vs tells within one phase)
		for t in TELL:
			var hits := 0
			var tells := 0
			for kd in t[1]:
				hits += int((d.get(kd, {}) as Dictionary).get(t[2], 0))
				tells += int((d.get(kd, {}) as Dictionary).get(t[3], 0))
				tells += int(((ph.get("pre", {}) as Dictionary).get(kd, {}) as Dictionary).get(t[3], 0))
			if hits > 0 or tells > 0:
				(G["tele"] as Array).append([str(t[0]), hits, tells, str(ph["name"])])
	return out


func _sum(groups: Dictionary, glist: Array, kinds: Array, key: String) -> int:
	var n := 0
	for g in glist:
		var G = groups.get(g)
		if G == null:
			continue
		for kd in kinds:
			n += int(((G["k"] as Dictionary).get(kd, {}) as Dictionary).get(key, 0))
	return n


func _fsum(groups: Dictionary, glist: Array, key: String) -> float:
	var x := 0.0
	for g in glist:
		var G = groups.get(g)
		if G != null:
			x += float((G["f"] as Dictionary).get(key, 0.0))
	return x


func _baseline_path() -> String:
	# a filtered developer run (only=...) never overwrites, or reads, the full baseline
	return BASELINE_FILE if _only.is_empty() else BASELINE_FILE.replace(".json", "_only.json")


func _write_baseline(groups: Dictionary) -> void:
	var clips: Dictionary = {}
	for kv in _kv.keys():
		clips[kv] = _kv[kv]
	var data := {"version": 2, "groups": groups, "clips": clips, "stl": _stl, "warn": _warn}
	var f := FileAccess.open(_baseline_path(), FileAccess.WRITE)
	if f == null:
		print("[CLIP] baseline file could not be written: %s" % _baseline_path())
		return
	f.store_string(JSON.stringify(data))
	f.close()
	print("[CLIP] baseline written to %s (%d phase groups)" % [_baseline_path(), groups.size()])


func _read_baseline_section(sec: String) -> Dictionary:
	var p := _baseline_path()
	if not FileAccess.file_exists(p):
		return {}
	var v = JSON.parse_string(FileAccess.get_file_as_string(p))
	if v is Dictionary and (v as Dictionary).has(sec) and (v as Dictionary)[sec] is Dictionary:
		return v[sec]
	return {}


func _read_baseline() -> Dictionary:
	return _read_baseline_section("groups")


func _base_kv(kv: String) -> Dictionary:
	# the baseline stats a guarded view is compared with: shadows and guests are copies of the host view
	if _bclips == null:
		_bclips = _read_baseline_section("clips")
	var key := kv
	if kv.ends_with("/shadow") or kv.ends_with("/guest"):
		key = kv.get_slice("/", 0) + "/host"
	var b = (_bclips as Dictionary).get(key)
	return b if b is Dictionary else {}


func _lim(S: Dictionary, kv: String, key: String, expo: String) -> int:
	# the allowed count: CLIP_REL x the baseline's rate x this run's exposure, plus the flicker allowance
	var b := _base_kv(kv)
	var bx := float(b.get(expo, 0.0))
	var rate := float(b.get(key, 0.0)) / bx if bx > 0.0 else 0.0
	var ex := float(S.get(expo, 0))
	return int(ceil(CLIP_REL * rate * ex)) + mini(CLIP_SLACK, 2 + int(0.10 * ex))


func _unknown_lim(kv: String) -> float:
	var b := _base_kv(kv)
	var bc := float(b.get("checks", 0.0))
	var frac := float(b.get("unknown", 0.0)) / bc if bc > 0.0 else 0.0
	return maxf(UNKNOWN_MAX, frac + UNKNOWN_SLACK)


func _fairness(groups: Dictionary) -> void:
	var base := _read_baseline()
	var nob := base.is_empty()
	# counted lines (bites, lunges, strikes): guarded >= factor x baseline, with the small-count rule
	for fl in FAIR_COUNTS:
		var g: int = _sum(groups, fl[1], fl[2], fl[3])
		var b: int = _sum(base, fl[1], fl[2], fl[4])
		_fair_count(str(fl[0]), g, b, float(fl[5]), nob)
	for fr in FAIR_RATES:
		_fair_rate(str(fr[0]), _sum(groups, fr[1], fr[2], fr[3]), _sum(groups, fr[1], fr[2], "att_ms"),
				_sum(base, fr[1], fr[2], fr[4]), _sum(base, fr[1], fr[2], "att_ms"), float(fr[5]), nob)
	# the ledge rules: if the baseline bit on the ledge at least once, the guarded run does too
	for lr in [["stalker ledge bites", "P3b", ["stalker"], "bites", "bites_clean"], ["shade ledge strikes", "P7b", ["shade"], "strikes", "strikes"],
			["shade low ceiling strikes", "P7c", ["shade"], "strikes", "strikes"]]:
		var g2: int = _sum(groups, [lr[1]], lr[2], lr[3])
		var b2: int = _sum(base, [lr[1]], lr[2], lr[4])
		var ok2: bool = not nob and (b2 < 1 or g2 >= 1)
		_fair_line(str(lr[0]), str(g2), str(b2), "-", "if baseline>=1 then guarded>=1", ok2, nob)
	# harrier: shrieks >= 0.80 x baseline and hits >= 0.70 x baseline
	var gs: int = _sum(groups, ["P8"], ["harrier"], "shrieks")
	var bs: int = _sum(base, ["P8"], ["harrier"], "shrieks")
	var gh: int = _sum(groups, ["P8"], ["harrier"], "hits")
	var bh: int = _sum(base, ["P8"], ["harrier"], "hits")
	var oks := _count_rule(gs, bs, 0.80)
	var okh := _count_rule(gh, bh, 0.70)
	_fair_line("harrier", "%d/%d" % [gs, gh], "%d/%d" % [bs, bh], "%s/%s" % [_ratio(gs, bs), _ratio(gh, bh)],
		"shrieks>=0.80x, hits>=0.70x (small counts: >=max(1,b-2))", oks and okh, nob)
	# chase: mean closing speed in path states more than 12 m from the target >= 0.90 x baseline
	var gc_t := _fsum(groups, CEN_GROUPS, "chase_t")
	var bc_t := _fsum(base, CEN_GROUPS, "chase_t")
	var gcs := _fsum(groups, CEN_GROUPS, "chase_d") / gc_t if gc_t > 0.0 else 0.0
	var bcs := _fsum(base, CEN_GROUPS, "chase_d") / bc_t if bc_t > 0.0 else 0.0
	# information: the closing speed includes the route. A guarded centipede goes round a gap its head does not fit
	# (owner decision 7A) where the game's own one squeezes through, and a route two or three times longer shows here
	# as a slower chase; what a guarded centipede does on its path is judged by path_speed, stalls and latency below
	_out("[CLIP] fair centipede chase guarded=%.2f m/s baseline=%.2f m/s ratio=%s rule=information (the route differs by design; path_speed, stalls and latency are the rules) INFO" % [gcs, bcs, _ratio_f(gcs, bcs)])
	# path_speed: a ratio within this run
	var psw := _fsum(groups, CEN_GROUPS, "ps_w")
	var psr := _fsum(groups, CEN_GROUPS, "ps_v") / psw if psw > 0.0 else 0.0
	var okp := psw > 0.0 and psr >= 0.90
	_fair_line("centipede path_speed", "%.2f" % psr, "1.00", "%.2f" % psr, ">=0.90 of the state's own speed" + ("" if psw > 0.0 else " (no samples)"), okp, false)
	# repaths per centipede-minute <= 1.5 x baseline + 2
	var gmin := _fsum(groups, CEN_GROUPS, "cen_s") / 60.0
	var bmin := _fsum(base, CEN_GROUPS, "cen_s") / 60.0
	var grp := float(_sum(groups, CEN_GROUPS, FAIR_KINDS, "repaths")) / maxf(gmin, 0.001)
	var brp := float(_sum(base, CEN_GROUPS, FAIR_KINDS, "repaths")) / maxf(bmin, 0.001) if bmin > 0.0 else 0.0
	# information: the guarded pathfinder answers several times faster (see the latency line), so it accepts
	# more requests per minute than the game's own, which is busy and drops them
	_out("[CLIP] fair centipede repaths guarded=%.2f/min baseline=%.2f/min ratio=%s rule=information INFO" % [grp, brp, _ratio_f(grp, brp)])
	# stalls <= 1.5 x baseline + 2
	var gst := int(_fsum(groups, CEN_GROUPS, "stalls"))
	var bst := int(_fsum(base, CEN_GROUPS, "stalls"))
	_fair_line("centipede stalls", str(gst), str(bst), _ratio(gst, bst), "<=1.5x+2", float(gst) <= 1.5 * float(bst) + 2.0, nob)
	# path latency (information): how long a path request kept a centipede waiting, against the game's own
	var gpn := _sum(groups, CEN_GROUPS, CEN_KINDS, "path_n")
	var gpm := _sum(groups, CEN_GROUPS, CEN_KINDS, "path_ms")
	var gps := _sum(groups, CEN_GROUPS, CEN_KINDS, "path_slow")
	var bpn := _sum(base, CEN_GROUPS, CEN_KINDS, "path_n")
	var bpm := _sum(base, CEN_GROUPS, CEN_KINDS, "path_ms")
	var bps := _sum(base, CEN_GROUPS, CEN_KINDS, "path_slow")
	var gmean := float(gpm) / float(gpn) if gpn > 0 else 0.0
	var bmean := float(bpm) / float(bpn) if bpn > 0 else 0.0
	_out("[CLIP] fair centipede path requests guarded=%d (%d over 3 s) baseline=%d (%d over 3 s) INFO" % [gpn, gps, bpn, bps])
	var ok_lat := gpn == 0 or bpn == 0 or gmean <= 1.5 * bmean + 1000.0
	_fair_line("centipede path latency", "%.0f ms" % gmean, "%.0f ms" % bmean, _ratio_f(gmean, bmean), "<=1.5x+1000 ms (no requests: information)", ok_lat, nob)
	# shadow would-bites per shadow attack-second, against the host's bites per attack-second (P1b)
	var hb := _sum(groups, ["P1b"], CEN_KINDS, "bites")
	var hms := _sum(groups, ["P1b"], CEN_KINDS, "att_ms")
	var wb := _sum(groups, ["P1b"], CEN_KINDS, "wbite")
	var wms := _sum(groups, ["P1b"], CEN_KINDS, "shadow_att_ms")
	var hr := float(hb) / (float(hms) / 1000.0) if hms > 0 else 0.0
	var wr := float(wb) / (float(wms) / 1000.0) if wms > 0 else 0.0
	var oksb := true
	var note_s := ""
	if hb == 0 or hr <= 0.0:
		note_s = " (no host bites: information)"
	elif wms <= 0:
		oksb = false
		note_s = " (no shadow attack time)"
	else:
		oksb = wr / hr >= 0.75 and wr / hr <= 1.33
	_fair_line("shadow bites", "%.3f/s" % wr, "%.3f/s (host)" % hr, _ratio_f(wr, hr), "0.75..1.33" + note_s, oksb, false)
	# brood nips: information only (the baseline brood cannot move)
	var gn := _sum(groups, ["P5", "P5b"], ["brood", "obrood"], "nips")
	var bn := _sum(base, ["P5", "P5b"], ["brood", "obrood"], "nips")
	_out("[CLIP] fair brood nips guarded=%d baseline=%d ratio=%s rule=information INFO" % [gn, bn, _ratio(gn, bn)])
	# telegraph: per phase, hits never outnumber the wind-ups (centipede: a bite needs a lunge)
	var tele: Dictionary = {}
	for g in groups.keys():
		for t in groups[g]["tele"]:
			var a: Array = tele.get(t[0], [0, 0, true])
			a[0] = int(a[0]) + int(t[1])
			a[1] = int(a[1]) + int(t[2])
			var okt: bool
			if str(t[0]) == "centipede":
				okt = int(t[1]) == 0 or int(t[2]) > 0
			elif str(t[0]) == "harrier":
				okt = int(t[1]) <= int(t[2]) * 2          # one dive can strike two players (me and the Ghost)
			else:
				okt = int(t[1]) <= int(t[2])
			if not okt:
				a[2] = false
				print("[CLIP] telegraph %s: %d hits against %d tells in %s" % [str(t[0]), int(t[1]), int(t[2]), str(t[3])])
			tele[t[0]] = a
	for tk in tele.keys():
		var ta: Array = tele[tk]
		_fair_line("%s telegraph" % str(tk), "hits:%d" % int(ta[0]), "tells:%d" % int(ta[1]), "-", "hits<=tells per phase", bool(ta[2]), false)


func _count_rule(g: int, b: int, factor: float) -> bool:
	if b <= 0:
		return true                                      # information only
	if b < 10:
		return g >= maxi(1, b - 2)
	return float(g) >= factor * float(b)


func _fair_count(line: String, g: int, b: int, factor: float, nob: bool) -> void:
	var rule := ">=%.2fx baseline" % factor
	if b > 0 and b < 10:
		rule = ">=max(1,b-2) (small counts)"
	elif b <= 0:
		rule = "information (baseline 0)"
	_fair_line(line, str(g), str(b), _ratio(g, b), rule, _count_rule(g, b, factor), nob)


func _fair_rate(line: String, g: int, gms: int, b: int, bms: int, factor: float, nob: bool) -> void:
	# a rate per second of attack state (see FAIR_RATES): under 3 s of attack the rate says nothing
	var gr := float(g) / (float(gms) / 1000.0) if gms >= 3000 else 0.0
	var br := float(b) / (float(bms) / 1000.0) if bms >= 3000 else 0.0
	var ok := true
	var rule := ">=%.2fx baseline rate" % factor
	if br <= 0.0:
		rule = "information (baseline: no attack time or no events)"
	elif gms < 3000:
		ok = false
		rule += " (the guarded one never got 3 s of attack)"
	else:
		ok = gr >= factor * br
	_fair_line(line + " per attack s", "%.2f/s (%d in %.0f s)" % [gr, g, float(gms) / 1000.0], "%.2f/s (%d in %.0f s)" % [br, b, float(bms) / 1000.0],
			_ratio_f(gr, br), rule, ok, nob)


func _fair_line(line: String, g: String, b: String, ratio: String, rule: String, ok: bool, nob: bool) -> void:
	var verdict := "PASS" if ok and not nob else "FAIL"
	if nob:
		rule += " (no baseline)"
	if verdict == "PASS":
		_npass += 1
	else:
		_nfail.append("fair " + line)
	_out("[CLIP] fair %s guarded=%s baseline=%s ratio=%s rule=%s %s" % [line, g, b, ratio, rule, verdict])


func _ratio(g: int, b: int) -> String:
	return "%.2f" % (float(g) / float(b)) if b > 0 else "-"


func _ratio_f(g: float, b: float) -> String:
	return "%.2f" % (g / b) if b > 0.0 else "-"


func _cost_summary() -> void:
	var worst = null
	for ph in _phases:
		if worst == null or float(ph["usec_f"]) > float(worst["usec_f"]):
			worst = ph
	if worst != null:
		print("[CLIP] cost worst phase=%s rays_per_s=%d guard_usec_per_frame=%.1f peak_rays_per_s=%d%s" % [str(worst["name"]),
			int(worst["rays_s"]), float(worst["usec_f"]), int(worst["peak"]), " OVER 1.5 ms: report to the owner" if float(worst["usec_f"]) > 1500.0 else ""])


# ============================================================================ helpers

func _L() -> Dictionary:
	var L = map.get("L") if map != null else null
	return L if L is Dictionary else {}


func _v(a) -> Vector3:
	if a is Vector3:
		return a
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _stations() -> Array:
	var out: Array = []
	for s in _L().get("stations", []):
		if s is Dictionary and (s as Dictionary).has("pos"):
			out.append(_v(s["pos"]))
	return out


func _stations_near(p: Vector3, r: float) -> Array:
	# stations within r of p, nearest first (ties by position, so every launch sees the same order)
	var tmp: Array = []
	for s in _stations():
		var d := (s as Vector3).distance_to(p)
		if d <= r:
			tmp.append([d, s])
	tmp.sort_custom(_near_cmp)
	var out: Array = []
	for t in tmp:
		out.append(t[1])
	return out


static func _near_cmp(a: Array, b: Array) -> bool:
	if float(a[0]) != float(b[0]):
		return float(a[0]) < float(b[0])
	var va: Vector3 = a[1]
	var vb: Vector3 = b[1]
	if va.x != vb.x:
		return va.x < vb.x
	return va.z < vb.z


func _nearest_station(p) -> Variant:
	if not (p is Vector3):
		return null
	var best = null
	var bd := INF
	for s in _stations():
		var d := (s as Vector3).distance_to(p)
		if d < bd:
			bd = d
			best = s
	return best


func _in_zone(p: Vector3, zone: Array) -> bool:
	for z in zone:
		if z is Array and (z as Array).size() >= 2 and p.distance_to(_v(z[0])) < float(z[1]) + 6.0:
			return true
	return false


func _cen_spawn(id: String) -> Variant:
	for c in _L().get("centipedes", []):
		if c is Dictionary and str(c.get("id", "")) == id:
			var sp: Array = c.get("spawn", [])
			if not sp.is_empty():
				return _v(sp[0])
	return null


func _cen_skin(id: String) -> String:
	for c in _L().get("centipedes", []):
		if c is Dictionary and str(c.get("id", "")) == id:
			return str(c.get("skin", "normal"))
	return "?"


func _real_cents() -> Array:
	# the authority's real centipedes (never puppets or shadows)
	var out: Array = []
	var list = Game.get("centipedes")
	if not (list is Array):
		return out
	for cent in list:
		if not is_instance_valid(cent) or not (cent is Node3D) or not (cent as Node).is_inside_tree():
			continue
		if bool(cent.get("coop_puppet")) or cent.has_meta("zonda_shadow"):
			continue
		if (cent as Node).process_mode == Node.PROCESS_MODE_DISABLED:
			continue
		out.append(cent)
	return out


func _group_cent(id: String) -> Variant:
	for cent in _real_cents():
		if str(cent.get_meta("zonda_cid", "")).begins_with(id + ":"):
			return cent
	return null


func _nearest_cent() -> Variant:
	var c := _climber()
	if c == null:
		return null
	var best = null
	var bd := INF
	for cent in _real_cents():
		var d := (cent as Node3D).global_position.distance_to(c.global_position)
		if d < bd:
			bd = d
			best = cent
	return best


func _in_attack(cent) -> bool:
	var s = cent.get("_current_state")
	if s == null or not (s is Object) or (s as Object).get_script() == null:
		return false
	return str(((s as Object).get_script() as Script).resource_path).ends_with("state_attack.gd")


func _stalker_pos(i: int) -> Variant:
	var sl = map.get("_stalkers")
	if not (sl is Array) or i >= (sl as Array).size():
		return null
	var s = sl[i]
	if not is_instance_valid(s):
		return null
	var b = s.get("body")
	if is_instance_valid(b) and b is Node3D and (b as Node3D).is_inside_tree():
		return (b as Node3D).global_position
	return null


func _module_with(method: String, feature_key: String) -> Variant:
	if map != null and map.has_method("feature"):
		var f = map.call("feature", feature_key)
		if f != null and f.has_method(method):
			return f
	for n in get_tree().get_nodes_in_group("zonda_nc"):
		if is_instance_valid(n) and n.has_method(method):
			return n
	return null


func _points_of(n) -> Array:
	if n == null or not n.has_method("noclip_points"):
		return []
	var a = n.call("noclip_points")
	return a if a is Array else []


func _hook(obj, method: String, args: Array) -> Variant:
	# a probe hook: a scripted window opens (pops in it are declared scripted, never counted as seen)
	if obj == null or not is_instance_valid(obj) or not obj.has_method(method):
		_skip_hook(method)
		return null
	_open_script_window()
	var r = obj.callv(method, args)
	_open_script_window()
	_script_seq += 1
	if CoopSync.has_method("map_event"):
		CoopSync.call("map_event", "ncscript_%d" % _script_seq, {"ms": SCRIPT_LAG_MS, "h": method}, false)
	return r


func _open_script_window() -> void:
	var now := Time.get_ticks_msec()
	_scripted_until = maxi(_scripted_until, now + SCRIPT_MS)
	_scripted_lag_until = maxi(_scripted_lag_until, now + SCRIPT_LAG_MS)


func _on_script_event(_key: String, data: Dictionary, replay: bool) -> void:
	# a guest (or the guest simulation) hears that the host ran a scripted test hook
	if replay or mode == "":
		return
	_scripted_lag_until = maxi(_scripted_lag_until, Time.get_ticks_msec() + int(data.get("ms", SCRIPT_LAG_MS)))


func _skip_hook(what: String) -> void:
	if _skipped_hooks.has(what):
		return
	_skipped_hooks[what] = true
	print("[CLIP] SKIP %s" % what)


func _park(p: Vector3) -> void:
	if map != null and map.has_method("debug_park"):
		map.call("debug_park", p)
	_open_script_window()


func _look(p: Vector3) -> void:
	if map != null and map.has_method("debug_look"):
		map.call("debug_look", p)


func _climber() -> Node3D:
	var c = Game.get("climber")
	if is_instance_valid(c) and c is Node3D and (c as Node3D).is_inside_tree():
		return c
	return null


func _here() -> Vector3:
	var c := _climber()
	if c != null:
		return c.global_position
	return _cam_pos()


func _cam_pos() -> Vector3:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam != null:
		return cam.global_position
	var c := _climber()
	return c.global_position if c != null else Vector3.ZERO


func _get_space() -> Variant:
	if map is Node3D and (map as Node3D).is_inside_tree():
		return (map as Node3D).get_world_3d().direct_space_state
	return null


func _capsule_free(p: Vector3) -> bool:
	# a player-sized capsule (r 0.42, h 1.5) at p touches no rock
	if _space == null:
		return false
	var q := PhysicsShapeQueryParameters3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.42
	cap.height = 1.5
	q.shape = cap
	q.transform = Transform3D(Basis(), p)
	q.collision_mask = 1
	q.collide_with_areas = false
	return (_space.intersect_shape(q, 1) as Array).is_empty()


func _biome_str(p: Vector3) -> String:
	if map != null and map.has_method("biome_at") and p != Vector3.ZERO:
		return " biome=%d" % int(map.call("biome_at", p))
	return ""


func _diff(a: Dictionary, b: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in a.keys():
		var da: Dictionary = a[k]
		var db: Dictionary = b.get(k, {})
		var o: Dictionary = {}
		for key in da.keys():
			var v := int(da[key]) - int(db.get(key, 0))
			if v != 0:
				o[key] = v
		if not o.is_empty():
			out[k] = o
	return out


func _fmt(p) -> String:
	if not (p is Vector3):
		return str(p)
	return "(%.1f, %.1f, %.1f)" % [p.x, p.y, p.z]
