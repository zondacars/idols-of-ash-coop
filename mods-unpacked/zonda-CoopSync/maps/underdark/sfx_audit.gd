extends Node
# ============================================================================================
# THE UNDERDARK: the centipede sound audit (ZondaCoopSync 5.0, feature "sfxaudit"). Developer test.
#
# The centipede has a voice for every stage of a hunt, and the mod changed the code around most of them
# (the states, the no-clip guard, the pale skin, the co-op puppets). This walks ONE hunt the way the player
# hears it and checks every cue, with the game's own code doing the triggering:
#   FAR       the idle loop; the hunting cry (state hunting, more than 60 m away); the wander roar (250 m+)
#   CLOSING   the body sections' footsteps; the close-range snarl (within 26 m and closing, every 7-12 s)
#   LUNGE     the attack snarl the moment a lunge starts
#   BITING    the jaw chomp on every snap; the player's "was bit" sting on every hit
#   PALE      the light-fear hiss (a forced recoil) and the pale voice pitch
#   CO-OP     the counters the host streams (cry, roar, hiss) and what a guest's puppet plays for each
# The far cues are random draws in the game (0.5 % and 0.05 % per tick). The test calls the state's own
# physics_tick with delta 0 (nothing moves) thousands of times a frame, so the real code path is drawn
# from at once instead of waiting minutes. Nothing is played by the test itself, except the co-op counter
# check, which calls the puppet's own entry points (coop_note_cries, coop_note_hiss).
# A cue is HEARD when its sound player starts (playing flips on, or its position jumps back to the start),
# its stream is loaded, its bus chain is live, and the distance model leaves it above the level named in
# the line at the moment it starts.
#
# Flag: maps/underdark/sfxaudit.flag (any text). Solo, or with loopback.flag (the co-op code paths).
# Tag [SFXA]; the last line is "[SFXA] test done <passed>/<total> PASS" (or "... FAIL: <names>").
# ============================================================================================

const HUNT_STATE := "res://scripts/centipede_states/centipede_state_hunting.gd"
const BASE_STATE := "res://scripts/centipede_states/centipede_state_base.gd"
const NORMAL_ID := "cen10"            # normal skin, biome 5 (the wall-pin test's centipede: it comes when called)
const PALE_ID := "cen13"              # pale skin, biome 7
const CUE_PROPS := {"idle_sfx": "idle", "hunting_sfx": "cry", "roar_wander_sfx": "roar", "attack_sfx": "snarl", "chomp_sfx": "chomp"}
const FAR_DB := -60.0                 # a far cue must still reach this level (dB re the stream) where it starts
const NEAR_DB := -40.0                # a cue that starts within 30 m
const FAR_MIN_M := 270.0
const APPROACH_M := 45.0
const VOICE_RANGE_M := 26.0           # ext/centipede.gd COOP_VOICE_RANGE
const OVERALL_MS := 600000

var map: Node = null
var active := false
var _running := false
var _done := false
var _t0 := 0
var _hunt_script = null
var _base_script = null
var _recs: Array = []                # sound players being watched
var _rec_keys: Dictionary = {}
var _watched: Dictionary = {}        # centipede id -> node
var _events: Array = []              # every cue that started
var _steps: Dictionary = {}          # centipede id -> {section index: count}
var _checks: Array = []              # [ok, text]
var _idle_frames := 0
var _idle_total := 0
var _bit_rec: Dictionary = {}
var _bit_events: Array = []          # ms of each "was bit" sting
var _dmg_events: Array = []          # ms of each damaging bite (last_dealt_damage_time changed)
var _dmg_seen: Dictionary = {}       # centipede id -> the last value seen
var _state_seen: Dictionary = {}     # centipede id -> the state name at the last frame
var _attack_enters: Array = []       # [ms, centipede id]
var _ppd_saved = null
var _no_ghost_saved = null
var _pin = null
var _scan_t := 0.0
var _trace_ms := 0


func setup(m: Node) -> void:
	map = m
	var fl = m.call("dev_flag", "sfxaudit.flag") if m.has_method("dev_flag") else null
	if fl == null:
		return
	active = true
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")


func _ready() -> void:
	if not active:
		set_process(false)
		set_physics_process(false)
		return
	process_priority = 1000
	_run()


func on_exit() -> void:
	if active and not _done:
		print("[SFXA] map exit during the test")
		_restore()


# ============================================================================ the run

func _run() -> void:
	_t0 = Time.get_ticks_msec()
	var w0 := Time.get_ticks_msec()
	while true:
		await get_tree().process_frame
		var an = map.call("load_announced") if map.has_method("load_announced") else true
		var sp = CoopSync.call("save_prompt_open") if CoopSync.has_method("save_prompt_open") else false
		if (_climber() != null and an is bool and an and not (sp is bool and sp)) or Time.get_ticks_msec() - w0 > 90000:
			break
	_running = true
	_no_ghost_saved = CoopSync.get("noclip_no_ghost")
	if _no_ghost_saved != null:
		CoopSync.set("noclip_no_ghost", true)         # the loopback Ghost is nobody's prey here
	_t0 = Time.get_ticks_msec()
	print("[SFXA] test start (%s)" % ("co-op session" if CoopSync.in_session() else "solo"))
	if ResourceLoader.exists(HUNT_STATE):
		_hunt_script = load(HUNT_STATE)
	if ResourceLoader.exists(BASE_STATE):
		_base_script = load(BASE_STATE)
	await _wait(3.0)
	await _phase_near_start()
	await _phase_far()
	await _phase_close()
	await _phase_pale()
	await _phase_counters()
	await _phase_puppet_attack()
	_finish()


func _over() -> bool:
	return _done or Time.get_ticks_msec() - _t0 > OVERALL_MS


func _wait(secs: float) -> void:
	var t_end := Time.get_ticks_msec() + int(secs * 1000.0)
	while Time.get_ticks_msec() < t_end and not _over():
		await get_tree().process_frame


func _now() -> float:
	return float(Time.get_ticks_msec() - _t0) / 1000.0


# ---------------------------------------------------------------------------- phase 1: wake, static checks

func _phase_near_start() -> void:
	var cn = await _spawn_near(NORMAL_ID)
	if cn == null:
		_check(false, "wake %s (a centipede to listen to)" % NORMAL_ID)
		return
	_watch(cn, NORMAL_ID)
	await _wait(1.5)
	_node_checks(cn, NORMAL_ID)
	_kick(cn)


func _spawn_near(id: String) -> Variant:
	var sp = _spawn_of(id)
	var at: Vector3 = _nearest_station(sp) + Vector3.UP if sp != null else Vector3.ZERO
	if sp != null:
		_park(at)
		await _wait(1.2)
	if map.has_method("noclip_test_wake"):
		map.call("noclip_test_wake", id)
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < 4000:
		var c = _group_cent(id)
		if c != null:
			return c
		await get_tree().process_frame
	return null


func _node_checks(cn: Node, id: String) -> void:
	var bad := 0
	for prop in CUE_PROPS.keys():
		var pl = cn.get(str(prop))
		if not (pl is AudioStreamPlayer3D):
			_check(false, "%s %s: the sound player exists" % [id, str(prop)])
			continue
		var p := pl as AudioStreamPlayer3D
		var stream: AudioStream = p.stream
		var why := ""
		var slen := _stream_len(stream)
		if stream == null:
			why = "no stream"
		elif slen < (0.01 if str(prop) == "chomp_sfx" else 0.05) and str(prop) != "idle_sfx":
			why = "stream shorter than %s s" % ("0.01" if str(prop) == "chomp_sfx" else "0.05")   # the game's teeth are 0.02 s clicks on purpose
		if why == "":
			why = _bus_problem(str(p.bus))
		if why == "" and p.volume_db < -40.0:
			why = "volume %.0f dB" % p.volume_db
		print("[SFXA] node %s %s: stream=%s len=%.2f s vol=%.1f dB bus=%s unit=%.1f max_dist=%.0f att=%d max_db=%.1f pitch=%.2f cone=%s" % [
			id, str(prop), str(stream.resource_path.get_file()) if stream != null and stream.resource_path != "" else (str(stream.get_class()) if stream != null else "none"),
			slen, p.volume_db, str(p.bus), p.unit_size, p.max_distance, int(p.attenuation_model), p.max_db, p.pitch_scale,
			str(p.emission_angle_enabled)])
		print("[SFXA] streams %s %s: %s" % [id, str(prop), _describe_streams(stream)])
		_check(why == "", "%s %s: stream loaded, bus live%s" % [id, str(prop), ("" if why == "" else " (" + why + ")")])
		if why != "":
			bad += 1
	var secs = cn.get("_body_sections")
	var with_stream := 0
	var total := 0
	if secs is Array:
		for sec in secs:
			total += 1
			var fp = sec.get("footstep_tap_sfx") if sec is Object else null
			if fp is AudioStreamPlayer3D and (fp as AudioStreamPlayer3D).stream != null and _bus_problem(str((fp as AudioStreamPlayer3D).bus)) == "":
				with_stream += 1
	_check(total >= 10 and with_stream == total, "%s footsteps: every body section has a loaded, live tap player (%d of %d)" % [id, with_stream, total])


func _wav_peak(w: AudioStreamWAV) -> float:
	# the loudest sample of a PCM wav, 0..1 (-1 for a format that is not read here)
	var d := w.data
	if w.format == AudioStreamWAV.FORMAT_16_BITS:
		var pk := 0
		var n := d.size() / 2
		var step := maxi(1, n / 4000)
		var i := 0
		while i < n:
			var v := d.decode_s16(i * 2)
			pk = maxi(pk, absi(v))
			i += step
		return float(pk) / 32768.0
	if w.format == AudioStreamWAV.FORMAT_8_BITS:
		var pk8 := 0
		for i in d.size():
			pk8 = maxi(pk8, absi(int(d[i]) - 0 if int(d[i]) < 128 else 256 - int(d[i])))
		return float(pk8) / 128.0
	return -1.0


func _describe_streams(stream: AudioStream) -> String:
	var out: Array = []
	var list: Array = []
	if stream is AudioStreamRandomizer:
		var r := stream as AudioStreamRandomizer
		for i in r.streams_count:
			list.append(r.get_stream(i))
	else:
		list.append(stream)
	for st in list:
		if st == null:
			out.append("null")
			continue
		var t := "%s %.2fs" % [(st as Resource).resource_path.get_file() if (st as Resource).resource_path != "" else (st as Object).get_class(), (st as AudioStream).get_length()]
		if st is AudioStreamWAV:
			var w := st as AudioStreamWAV
			t += " fmt=%d rate=%d bytes=%d peak=%.2f" % [int(w.format), w.mix_rate, w.data.size(), _wav_peak(w)]
		out.append(t)
	return "; ".join(PackedStringArray(out))


func _stream_len(stream: AudioStream) -> float:
	# an AudioStreamRandomizer has no length of its own: the length of the longest stream it can pick (some
	# of the game's chomps are a 0.02 s tick on purpose, layered with longer ones)
	if stream == null:
		return 0.0
	if stream is AudioStreamRandomizer:
		var r := stream as AudioStreamRandomizer
		if r.streams_count <= 0:
			return 0.0
		var hi := 0.0
		for i in r.streams_count:
			var st = r.get_stream(i)
			hi = maxf(hi, (st as AudioStream).get_length() if st is AudioStream else 0.0)
		return hi
	return stream.get_length()


func _bus_problem(bus_name: String) -> String:
	# "" = the bus and every bus it sends to are live
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return "no bus '%s'" % bus_name
	var guard := 0
	while idx >= 0 and guard < 8:
		if AudioServer.is_bus_mute(idx):
			return "bus '%s' is muted" % AudioServer.get_bus_name(idx)
		if AudioServer.get_bus_volume_db(idx) < -40.0:
			return "bus '%s' at %.0f dB" % [AudioServer.get_bus_name(idx), AudioServer.get_bus_volume_db(idx)]
		var send := str(AudioServer.get_bus_send(idx))
		if send == "":
			break
		idx = AudioServer.get_bus_index(send)
		guard += 1
	return ""


# ---------------------------------------------------------------------------- phase 2: far

func _phase_far() -> void:
	var cn = _watched.get(NORMAL_ID)
	if cn == null or _over():
		return
	# ---- part 1: the hunting cry where the centipede is awake. The map puts a territorial centipede to sleep
	# (no processing, no idle loop) when nobody is within 190 m, so the far cues the player can really hear from it
	# are the ones between 60 m and 190 m; the roar (250 m and more) is drawn in part 2.
	var from: Vector3 = (cn as Node3D).global_position
	var mid = _station_in_biome(cn, 62.0, 188.0, 85.0)
	if mid == null:
		mid = _station_at(from, 62.0, 188.0, 85.0)
	if mid == null:
		_check(false, "a station 62-188 m from %s (for the far cry)" % NORMAL_ID)
	else:
		var cry0 := int(cn.get_meta("zonda_cry", 0))
		var cry_n0 := _count(NORMAL_ID, "cry")
		_park((mid as Vector3) + Vector3.UP)
		await _wait(3.0)                       # the map wakes it on its 2 s tick (an awake hunter may cry by itself meanwhile)
		_kick(cn)
		var cl := _climber()
		var d0 := (cn as Node3D).global_position.distance_to(cl.global_position) if cl != null else -1.0
		print("[SFXA] far phase 1: %s is %.0f m away, awake=%s" % [NORMAL_ID, d0, str((cn as Node).process_mode != Node.PROCESS_MODE_DISABLED)])
		_check((cn as Node).process_mode != Node.PROCESS_MODE_DISABLED, "far: it is awake at %.0f m (the map sleeps it past 190 m)" % d0)
		for frame in 60:
			if _over() or _count(NORMAL_ID, "cry") > cry_n0:
				break
			var st = cn.get("_current_state")
			if not _is_hunting(st):
				_kick(cn)
				await get_tree().process_frame
				continue
			for i in 1500:
				st = cn.get("_current_state")
				if not _is_hunting(st):
					break
				st.call("physics_tick", 0.0)
			await get_tree().process_frame
		await _wait(0.6)
		var cry_ev := _last_event(NORMAL_ID, "cry")
		_check(_count(NORMAL_ID, "cry") > cry_n0, "far: the hunting cry plays (state hunting, more than 60 m)")
		if cry_ev != null:
			_check(float(cry_ev["d"]) > 60.0 and str(cry_ev["st"]).contains("hunting"), "far: the cry came from the hunting state at %.0f m" % float(cry_ev["d"]))
			_check(float(cry_ev["db"]) >= FAR_DB, "far: the cry is audible where it starts (%.1f dB at %.0f m, needs %.0f)" % [float(cry_ev["db"]), float(cry_ev["d"]), FAR_DB])
		_check(int(cn.get_meta("zonda_cry", 0)) > cry0, "far: the host counts the cry for the guests (zonda_cry %d -> %d)" % [cry0, int(cn.get_meta("zonda_cry", 0))])
		# the roar's counter, through the centipede's own physics tick (awake here): the sound is started directly
		# because its draw needs 250 m; what is checked is that the host counts it for the guests by itself
		var roar0 := int(cn.get_meta("zonda_roar", 0))
		var rp = cn.get("roar_wander_sfx")
		if rp is AudioStreamPlayer3D:
			(rp as AudioStreamPlayer3D).stop()
			await get_tree().process_frame
			(rp as AudioStreamPlayer3D).play()
			await _wait(0.6)
			_check(int(cn.get_meta("zonda_roar", 0)) == roar0 + 1, "far: the host counts a roar for the guests by itself (zonda_roar %d -> %d)" % [roar0, int(cn.get_meta("zonda_roar", 0))])
	# ---- part 2: the roar's own draw, 250 m and more away (the game's base state code, drawn many times a frame)
	from = (cn as Node3D).global_position
	var far = _station_at(from, FAR_MIN_M, 360.0, FAR_MIN_M + 30.0)
	if far == null:
		_check(false, "a station %.0f m or more from %s (for the far roar)" % [FAR_MIN_M, NORMAL_ID])
		return
	_park((far as Vector3) + Vector3.UP)
	await _wait(1.5)
	if _base_script != null:
		_base_script.set("roar_wander_sfx_last_played_ms", -999999)      # the 120 s gap between two roars
	(cn.get("roar_wander_sfx") as AudioStreamPlayer3D).stop()
	await get_tree().process_frame
	var cl2 := _climber()
	var d := (cn as Node3D).global_position.distance_to(cl2.global_position) if cl2 != null else -1.0
	print("[SFXA] far phase 2: %s is %.0f m away, drawing the roar" % [NORMAL_ID, d])
	var roar_n0 := _count(NORMAL_ID, "roar")
	for frame in 60:
		if _over() or _count(NORMAL_ID, "roar") > roar_n0:
			break
		var st2 = cn.get("_current_state")
		if not _is_hunting(st2):
			_kick(cn)
			await get_tree().process_frame
			continue
		for i in 1500:
			st2 = cn.get("_current_state")
			if not _is_hunting(st2):
				break
			st2.call("physics_tick", 0.0)
		await get_tree().process_frame
	await _wait(0.6)
	var roar_ev := _last_event(NORMAL_ID, "roar")
	_check(_count(NORMAL_ID, "roar") > roar_n0, "far: the wander roar plays (more than 250 m)")
	if roar_ev != null:
		_check(float(roar_ev["d"]) > 250.0, "far: the roar came from %.0f m" % float(roar_ev["d"]))
		_check(float(roar_ev["db"]) >= FAR_DB, "far: the roar is audible where it starts (%.1f dB at %.0f m, needs %.0f)" % [float(roar_ev["db"]), float(roar_ev["d"]), FAR_DB])


func _station_in_biome(cn, dmin: float, dmax: float, want: float) -> Variant:
	var b := int(map.call("biome_at", (cn as Node3D).global_position)) if map.has_method("biome_at") else -1
	var best = null
	var bd := INF
	for st in _L().get("stations", []):
		if st is Dictionary and (st as Dictionary).has("pos") and str(st.get("kind", "")) != "hard" and int(st.get("biome", -2)) == b:
			var p := _v(st["pos"])
			var d := p.distance_to((cn as Node3D).global_position)
			if d >= dmin and d <= dmax and absf(d - want) < bd:
				bd = absf(d - want)
				best = p
	return best


func _is_hunting(st) -> bool:
	return st != null and st is Object and (st as Object).get_script() != null and str(((st as Object).get_script() as Script).resource_path).ends_with("state_hunting.gd")


func _kick(cn: Node) -> void:
	if _hunt_script != null and cn != null and is_instance_valid(cn) and cn.has_method("set_state"):
		cn.call("set_state", _hunt_script.new())


# ---------------------------------------------------------------------------- phase 3: closing in, the lunge, the bites

func _phase_close() -> void:
	var cn = _watched.get(NORMAL_ID)
	if cn == null or _over():
		return
	var cands := _stations_around((cn as Node3D).global_position, APPROACH_M, 30.0, 60.0)
	var arrived := false
	var attempt := 0
	for st in cands:
		if attempt >= 3 or _over():
			break
		attempt += 1
		_pin = (st as Vector3) + Vector3.UP
		_park(_pin)
		_kick(cn)
		var cl1 := _climber()
		var d0 := (cn as Node3D).global_position.distance_to(cl1.global_position) if cl1 != null else -1.0
		print("[SFXA] close phase attempt %d: player parked %.0f m from %s" % [attempt, d0, NORMAL_ID])
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 75000 and not _over():
			await get_tree().process_frame
			_look_at(cn)
			var cl2 := _climber()
			if cl2 == null or not is_instance_valid(cn):
				continue
			var d := (cn as Node3D).global_position.distance_to(cl2.global_position)
			if Time.get_ticks_msec() - _trace_ms >= 500 and d < 70.0:
				_trace_ms = Time.get_ticks_msec()
				var tgt := -1.0
				if CoopSync.has_method("target_player_distance"):
					tgt = float(CoopSync.call("target_player_distance", cn, -1.0))
				print("[SFXA] trace t=%.1f d=%.1f m target=%.1f m voice_cd=%.1f closing=%s cry=%s snarl=%s chomp=%s visible=%s state=%s" % [
					_now(), d, tgt, float(cn.get("_coop_voice_cd")), str(cn.get("_coop_voice_closing")), str((cn.get("hunting_sfx") as AudioStreamPlayer3D).playing),
					str((cn.get("attack_sfx") as AudioStreamPlayer3D).playing), str((cn.get("chomp_sfx") as AudioStreamPlayer3D).playing), str((cn as Node3D).visible), _state_name(cn)])
			if d < 12.0:
				arrived = true
				break
		if arrived:
			break
	_check(arrived, "closing: the centipede came to the player (%d attempts)" % attempt)
	if not arrived:
		_pin = null
		return
	# the bites: stand still until enough snaps and hits, at most 45 s
	var b0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - b0 < 45000 and not _over():
		await get_tree().process_frame
		_look_at(cn)
		if int(cn.get_meta("zonda_snaps", 0)) >= 6 and _dmg_events.size() >= 3:
			break
	await _wait(1.0)
	_pin = null
	_close_checks(cn)


func _close_checks(cn: Node) -> void:
	var idn := NORMAL_ID
	# the idle loop
	var idle_frac := float(_idle_frames) / float(maxi(1, _idle_total))
	_check(idle_frac >= 0.95, "idle: the loop plays whenever it is awake (%.0f %% of %d frames)" % [idle_frac * 100.0, _idle_total])
	# footsteps
	var per: Dictionary = _steps.get(idn, {})
	var n := 0
	for k in per.keys():
		n += int(per[k])
	_check(n >= 12 and per.size() >= 5, "closing: footsteps tap as the body walks (%d taps over %d of its sections)" % [n, per.size()])
	# the close-range snarl: a snarl in the hunting state within the voice range, before the first lunge
	var first_lunge := 1e12
	for a in _attack_enters:
		if str(a[1]) == idn:
			first_lunge = minf(first_lunge, float(a[0]))
			break
	var close_snarl = null
	for e in _events:
		if str(e["id"]) == idn and str(e["cue"]) == "snarl" and str(e["st"]).contains("hunting") and float(e["d"]) <= VOICE_RANGE_M + 0.5 and float(e["d"]) >= 15.0 and float(e["ms"]) < first_lunge:
			close_snarl = e
			break
	_check(close_snarl != null, "closing: the close-range snarl plays while it is still 15 to %.0f m away" % VOICE_RANGE_M)
	if close_snarl != null:
		_check(float(close_snarl["db"]) >= NEAR_DB, "closing: the close-range snarl is audible (%.1f dB at %.0f m, needs %.0f)" % [float(close_snarl["db"]), float(close_snarl["d"]), NEAR_DB])
	# the lunge: every entry into the attack state has its snarl within 0.4 s
	var entries := 0
	var matched := 0
	for a in _attack_enters:
		if str(a[1]) != idn:
			continue
		entries += 1
		for e in _events:
			if str(e["id"]) == idn and str(e["cue"]) == "snarl" and float(e["ms"]) >= float(a[0]) - 60.0 and float(e["ms"]) <= float(a[0]) + 400.0:
				matched += 1
				break
	_check(entries >= 1 and matched == entries, "lunge: every lunge starts with its snarl (%d of %d)" % [matched, entries])
	# the chomps against the snaps
	var snaps := int(cn.get_meta("zonda_snaps", 0))
	var chomps := _count(idn, "chomp")
	_check(snaps >= 3, "bite: the jaws snapped %d times" % snaps)
	_check(snaps >= 3 and chomps >= snaps, "bite: every snap crunches (%d chomps for %d snaps)" % [chomps, snaps])
	var worst := 0.0
	var worst_set := false
	for e in _events:
		if str(e["id"]) == idn and str(e["cue"]) == "chomp":
			if not worst_set or float(e["db"]) < worst:
				worst = float(e["db"])
				worst_set = true
	_check(worst_set and worst >= NEAR_DB, "bite: the chomp is audible (worst %.1f dB, needs %.0f)" % [worst, NEAR_DB])
	# the "was bit" sting against the damaging bites
	var hits := _dmg_events.size()
	var stings := 0
	for h in _dmg_events:
		for b in _bit_events:
			if float(b) >= float(h) - 60.0 and float(b) <= float(h) + 300.0:
				stings += 1
				break
	_check(hits >= 1, "bite: the centipede hurt the player %d times" % hits)
	_check(hits >= 1 and stings == hits, "bite: every hit has the player's 'was bit' sting (%d of %d)" % [stings, hits])


# ---------------------------------------------------------------------------- phase 4: the pale one

func _phase_pale() -> void:
	if _over():
		return
	_pin = null
	var cp = await _spawn_near(PALE_ID)
	if cp == null:
		_check(false, "wake %s (the pale centipede)" % PALE_ID)
		return
	_watch(cp, PALE_ID)
	await _wait(1.5)
	var pitch_ok := true
	var pitches: Array = []
	for prop in CUE_PROPS.keys():
		var pl = cp.get(str(prop))
		if pl is AudioStreamPlayer3D:
			pitches.append("%s %.2f" % [str(CUE_PROPS[prop]), (pl as AudioStreamPlayer3D).pitch_scale])
			if absf((pl as AudioStreamPlayer3D).pitch_scale - 0.72) > 0.01:
				pitch_ok = false
	_check(int(cp.get("coop_skin")) == 1 and pitch_ok, "pale: the pale voice is pitched down (%s)" % ", ".join(PackedStringArray(pitches)))
	_node_checks(cp, PALE_ID)
	for i in 2:
		if _over():
			break
		var h0 := int(cp.get_meta("zonda_hiss", 0))
		var n0 := _count(PALE_ID, "hiss")
		if cp.has_method("coop_test_recoil") and _climber() != null:
			cp.call("coop_test_recoil", _climber())
		await _wait(0.8)
		_check(int(cp.get_meta("zonda_hiss", 0)) == h0 + 1, "pale: the recoil counts a hiss for the guests (zonda_hiss %d -> %d)" % [h0, int(cp.get_meta("zonda_hiss", 0))])
		_check(_count(PALE_ID, "hiss") == n0 + 1, "pale: the hiss plays (recoil %d)" % (i + 1))
		var ev := _last_event(PALE_ID, "hiss")
		if ev != null:
			_check(float(ev["db"]) >= NEAR_DB, "pale: the hiss is audible (%.1f dB at %.0f m, needs %.0f)" % [float(ev["db"]), float(ev["d"]), NEAR_DB])
		await _wait(2.5)


# ---------------------------------------------------------------------------- phase 5: what a guest's puppet does with the counters

func _phase_counters() -> void:
	var cn = _watched.get(NORMAL_ID)
	if cn == null or _over():
		return
	if not (cn.has_method("coop_note_cries") and cn.has_method("coop_note_hiss")):
		_check(false, "co-op: the puppet entry points coop_note_cries / coop_note_hiss exist")
		return
	# these are the calls the map's 4 Hz "cr" stream makes on a guest's puppet. The first value only seeds
	# the counter (no cry on join); every change afterwards plays that sound once.
	_silence(NORMAL_ID)
	var cid := "audit:0"
	var c0 := _count(NORMAL_ID, "cry")
	var r0 := _count(NORMAL_ID, "roar")
	var keep_cry = cn.get_meta("zonda_cry_cid", null)
	var keep_hiss = cn.get_meta("zonda_hiss_cid", null)
	cn.call("coop_note_cries", cid, 500, 500)
	await _wait(0.4)
	_check(_count(NORMAL_ID, "cry") == c0 and _count(NORMAL_ID, "roar") == r0, "co-op: the first counters only seed (nothing plays on join)")
	cn.call("coop_note_cries", cid, 501, 500)
	await _wait(0.4)
	_check(_count(NORMAL_ID, "cry") == c0 + 1, "co-op: a changed cry counter plays the hunting cry")
	cn.call("coop_note_cries", cid, 501, 501)
	await _wait(0.4)
	_check(_count(NORMAL_ID, "roar") == r0 + 1, "co-op: a changed roar counter plays the wander roar")
	var h0 := _count(NORMAL_ID, "hiss")
	cn.call("coop_note_hiss", cid, 40)
	await _wait(0.4)
	_check(_count(NORMAL_ID, "hiss") == h0, "co-op: the first hiss counter only seeds")
	cn.call("coop_note_hiss", cid, 41)
	await _wait(0.6)
	_check(_count(NORMAL_ID, "hiss") == h0 + 1, "co-op: a changed hiss counter plays the hiss")
	# put the metas back so the real centipede is as it was
	if keep_cry == null:
		cn.remove_meta("zonda_cry_cid")
	else:
		cn.set_meta("zonda_cry_cid", keep_cry)
	if keep_hiss == null:
		cn.remove_meta("zonda_hiss_cid")
	else:
		cn.set_meta("zonda_hiss_cid", keep_hiss)


func _phase_puppet_attack() -> void:
	# the host streams "attacking" with every centipede state; a guest's puppet starts the lunge snarl when
	# that flag turns on (ext/centipede.gd coop_apply_state). This is the last step: it leaves the centipede
	# in the puppet's attack pose, which is fine, the audit ends here.
	var cn = _watched.get(NORMAL_ID)
	if cn == null or _over() or not cn.has_method("coop_apply_state"):
		_check(false, "co-op: coop_apply_state (the puppet's state entry point) exists")
		return
	_silence(NORMAL_ID)
	var n0 := _count(NORMAL_ID, "snarl")
	var pkt: Array = [(cn as Node3D).global_position, (cn as Node3D).global_basis.get_rotation_quaternion(), true, float(cn.get("stamina")), int(cn.get("coop_skin"))]
	cn.call("coop_apply_state", pkt, Time.get_ticks_msec())
	await _wait(0.5)
	_check(_count(NORMAL_ID, "snarl") == n0 + 1, "co-op: a puppet told 'attacking' starts the lunge snarl")


func _silence(id: String) -> void:
	# stop the cue players so a new start is a clean edge (test scaffolding only)
	for r in _recs:
		if str(r["id"]) == id and str(r["cue"]) != "idle" and is_instance_valid(r["pl"]):
			(r["pl"] as Node).call("stop")
			r["playing"] = false
			r["pos"] = 0.0


# ============================================================================ watching the sound players

func _watch(cn: Node, id: String) -> void:
	_watched[id] = cn
	_state_seen[id] = ""
	for prop in CUE_PROPS.keys():
		var pl = cn.get(str(prop))
		if pl is AudioStreamPlayer3D:
			_add_rec(pl, cn, id, str(CUE_PROPS[prop]), -1)
	_dmg_seen[id] = int(cn.get("last_dealt_damage_time"))
	var gp = Game.get("audio")
	if gp != null and _bit_rec.is_empty():
		var pb = gp.get("player_bit")
		if pb is AudioStreamPlayer:
			_bit_rec = {"pl": pb, "playing": bool((pb as AudioStreamPlayer).playing), "pos": 0.0}
	_scan_extra()


func _add_rec(pl: Node, cn: Node, id: String, cue: String, sec: int) -> void:
	var key := "%d" % pl.get_instance_id()
	if _rec_keys.has(key):
		return
	_rec_keys[key] = true
	# a hiss player is made on the first hiss and is already playing when first seen: it starts as "not playing"
	_recs.append({"pl": pl, "cent": cn, "id": id, "cue": cue, "sec": sec, "playing": bool(pl.get("playing")) and cue != "hiss", "pos": 0.0})


func _scan_extra() -> void:
	# the footstep taps appear as the body builds; the hiss player is made on the first hiss
	for id in _watched.keys():
		var cn = _watched[id]
		if not is_instance_valid(cn):
			continue
		var secs = cn.get("_body_sections")
		if secs is Array:
			var i := 0
			for sec in secs:
				if sec is Object:
					var fp = sec.get("footstep_tap_sfx")
					if fp is AudioStreamPlayer3D:
						_add_rec(fp, cn, str(id), "step", i)
				i += 1
		var hp = cn.get("_coop_hiss_sfx")
		if hp is AudioStreamPlayer3D and is_instance_valid(hp):
			_add_rec(hp, cn, str(id), "hiss", -1)


func _process(delta: float) -> void:
	if not active or _done:
		return
	_hold_ppd()
	_scan_t -= delta
	if _scan_t <= 0.0:
		_scan_t = 0.5
		_scan_extra()
	for r in _recs:
		_poll(r)
	_poll_bit()
	for id in _watched.keys():
		var cn = _watched[id]
		if not is_instance_valid(cn):
			continue
		var hp = cn.get("_coop_hiss_sfx")
		if hp is AudioStreamPlayer3D and is_instance_valid(hp):
			_add_rec(hp, cn, str(id), "hiss", -1)
		# idle loop
		if _running:
			var ip = cn.get("idle_sfx")
			if ip is AudioStreamPlayer3D and (cn as Node).process_mode != Node.PROCESS_MODE_DISABLED and (cn as Node3D).visible:
				_idle_total += 1
				if (ip as AudioStreamPlayer3D).playing:
					_idle_frames += 1
		# damaging bites
		var ldt := int(cn.get("last_dealt_damage_time"))
		if ldt != int(_dmg_seen.get(id, ldt)):
			_dmg_seen[id] = ldt
			_dmg_events.append(float(Time.get_ticks_msec()))
		# entries into the attack state
		var sname := _state_name(cn)
		if sname != str(_state_seen.get(id, "")):
			if sname.contains("attack") and not str(_state_seen.get(id, "")).contains("attack"):
				_attack_enters.append([float(Time.get_ticks_msec()), id])
			_state_seen[id] = sname


func _physics_process(_delta: float) -> void:
	if _pin is Vector3 and map != null and map.has_method("debug_park"):
		map.call("debug_park", _pin)


func _poll(r: Dictionary) -> void:
	var pl = r["pl"]
	if not is_instance_valid(pl):
		return
	var p: bool = bool(pl.get("playing"))
	var pos := float(pl.call("get_playback_position")) if p else 0.0
	if p and (not bool(r["playing"]) or pos + 0.01 < float(r["pos"])):
		_on_cue(r)
	r["playing"] = p
	r["pos"] = pos


func _poll_bit() -> void:
	if _bit_rec.is_empty():
		return
	var pl = _bit_rec["pl"]
	if not is_instance_valid(pl):
		return
	var p: bool = (pl as AudioStreamPlayer).playing
	var pos := (pl as AudioStreamPlayer).get_playback_position() if p else 0.0
	if p and (not bool(_bit_rec["playing"]) or pos + 0.01 < float(_bit_rec["pos"])):
		_bit_events.append(float(Time.get_ticks_msec()))
		print("[SFXA] cue was_bit t=%.1f" % _now())
	_bit_rec["playing"] = p
	_bit_rec["pos"] = pos


func _on_cue(r: Dictionary) -> void:
	var cn = r["cent"]
	var c := _climber()
	var d := -1.0
	if is_instance_valid(cn) and c != null:
		d = (cn as Node3D).global_position.distance_to(c.global_position)
	var cue := str(r["cue"])
	var pl = r["pl"]
	var db := _eff_db(pl, d) if pl is AudioStreamPlayer3D else 0.0
	var st := _state_name(cn) if is_instance_valid(cn) else "?"
	var e := {"ms": float(Time.get_ticks_msec()), "t": _now(), "id": str(r["id"]), "cue": cue, "d": d, "st": st, "db": db}
	_events.append(e)
	if cue == "step":
		var per: Dictionary = _steps.get(str(r["id"]), {})
		per[int(r["sec"])] = int(per.get(int(r["sec"]), 0)) + 1
		_steps[str(r["id"])] = per
		return
	var tgt := -1.0
	if is_instance_valid(cn) and CoopSync.has_method("target_player_distance"):
		tgt = float(CoopSync.call("target_player_distance", cn, -1.0))
	print("[SFXA] cue %s %s t=%.1f d=%.1f m target=%.1f m state=%s level=%.1f dB" % [cue, str(r["id"]), float(e["t"]), d, tgt, st, db])


func _eff_db(pl: AudioStreamPlayer3D, d: float) -> float:
	# Godot's own distance model for this player: volume + attenuation (capped at max_db); silent beyond max_distance
	if d < 0.0:
		return -999.0
	if pl.max_distance > 0.0 and d > pl.max_distance:
		return -999.0
	var u := maxf(pl.unit_size, 0.01)
	var att := 0.0
	match pl.attenuation_model:
		AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE:
			att = linear_to_db(1.0 / (d / u + 0.00001))
		AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE:
			var q := d / u
			att = linear_to_db(1.0 / (q * q + 0.00001))
		AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC:
			att = -20.0 * log(d / u + 0.00001)
		_:
			att = 0.0
	return pl.volume_db + minf(att, pl.max_db)


func _state_name(cn) -> String:
	if not is_instance_valid(cn):
		return "?"
	var s = cn.get("_current_state")
	if s == null or not (s is Object) or (s as Object).get_script() == null:
		return "none"
	return str(((s as Object).get_script() as Script).resource_path.get_file()).trim_suffix(".gd")


func _count(id: String, cue: String) -> int:
	var n := 0
	for e in _events:
		if str(e["id"]) == id and str(e["cue"]) == cue:
			n += 1
	return n


func _last_event(id: String, cue: String) -> Variant:
	for i in range(_events.size() - 1, -1, -1):
		var e: Dictionary = _events[i]
		if str(e["id"]) == id and str(e["cue"]) == cue:
			return e
	return null


# ============================================================================ the end

func _check(ok: bool, text: String) -> void:
	_checks.append([ok, text])
	print("[SFXA] %s %s" % ["PASS" if ok else "FAIL", text])


func _finish() -> void:
	if _done:
		return
	# a summary per cue
	for id in _watched.keys():
		for cue in ["idle", "cry", "roar", "snarl", "chomp", "hiss", "step"]:
			var n := 0
			var dmin := 1e9
			var dmax := -1.0
			var lo := 1e9
			for e in _events:
				if str(e["id"]) == str(id) and str(e["cue"]) == cue:
					n += 1
					dmin = minf(dmin, float(e["d"]))
					dmax = maxf(dmax, float(e["d"]))
					lo = minf(lo, float(e["db"]))
			if n > 0:
				print("[SFXA] summary %s %s: %d starts, %.0f-%.0f m, quietest %.1f dB" % [str(id), cue, n, dmin, dmax, lo])
	print("[SFXA] summary was_bit: %d stings for %d damaging bites" % [_bit_events.size(), _dmg_events.size()])
	var over := _over() and not _done
	if over:
		_check(false, "the audit finished inside %d s (it ran out of time)" % (OVERALL_MS / 1000))
	_done = true
	_restore()
	var p := 0
	var fails: Array = []
	for c in _checks:
		if bool(c[0]):
			p += 1
		else:
			fails.append(str(c[1]).substr(0, 60))
	if fails.is_empty():
		printerr("[SFXA] test done %d/%d PASS" % [p, _checks.size()])
	else:
		printerr("[SFXA] test done %d/%d FAIL: %s" % [p, _checks.size(), ", ".join(PackedStringArray(fails))])


func _restore() -> void:
	_pin = null
	if _no_ghost_saved != null:
		CoopSync.set("noclip_no_ghost", _no_ghost_saved)
	var c := _climber()
	if c != null and _ppd_saved != null:
		c.set("prevent_player_death", bool(_ppd_saved))


func _hold_ppd() -> void:
	if not _running:
		return
	var c := _climber()
	if c == null:
		return
	if _ppd_saved == null:
		_ppd_saved = bool(c.get("prevent_player_death"))
	if not bool(c.get("prevent_player_death")):
		c.set("prevent_player_death", true)


# ============================================================================ world helpers

func _climber() -> Node3D:
	var c = Game.get("climber")
	if is_instance_valid(c) and c is Node3D and (c as Node3D).is_inside_tree():
		return c
	return null


func _L() -> Dictionary:
	var L = map.get("L") if map != null else null
	return L if L is Dictionary else {}


func _v(a) -> Vector3:
	if a is Vector3:
		return a
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _park(p: Vector3) -> void:
	if map != null and map.has_method("debug_park"):
		map.call("debug_park", p)


func _look_at(cn) -> void:
	if map != null and is_instance_valid(cn) and map.has_method("debug_look"):
		map.call("debug_look", (cn as Node3D).global_position)


func _spawn_of(id: String) -> Variant:
	for c in _L().get("centipedes", []):
		if c is Dictionary and str(c.get("id", "")) == id:
			var sp: Array = c.get("spawn", [])
			if not sp.is_empty():
				return _v(sp[0])
	return null


func _stations() -> Array:
	var out: Array = []
	for s in _L().get("stations", []):
		if s is Dictionary and (s as Dictionary).has("pos") and str(s.get("kind", "")) != "hard":
			out.append(_v(s["pos"]))
	return out


func _nearest_station(p: Vector3) -> Vector3:
	var best := p
	var bd := INF
	for s in _stations():
		var d := (s as Vector3).distance_to(p)
		if d < bd:
			bd = d
			best = s
	return best


func _station_at(from: Vector3, dmin: float, dmax: float, want: float) -> Variant:
	# the station between dmin and dmax from `from` whose distance is closest to want
	var best = null
	var bd := INF
	for s in _stations():
		var d := (s as Vector3).distance_to(from)
		if d >= dmin and d <= dmax and absf(d - want) < bd:
			bd = absf(d - want)
			best = s
	return best


func _stations_around(from: Vector3, want: float, dmin: float, dmax: float) -> Array:
	# stations dmin..dmax from `from`, the ones nearest `want` first (a deterministic order)
	var tmp: Array = []
	for s in _stations():
		var d := (s as Vector3).distance_to(from)
		if d >= dmin and d <= dmax:
			tmp.append([absf(d - want), s])
	tmp.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var out: Array = []
	for t in tmp:
		out.append(t[1])
	return out


func _real_cents() -> Array:
	var out: Array = []
	var list = Game.get("centipedes")
	if not (list is Array):
		return out
	for cent in list:
		if not is_instance_valid(cent) or not (cent is Node3D) or not (cent as Node).is_inside_tree():
			continue
		if bool(cent.get("coop_puppet")) or cent.has_meta("zonda_shadow"):
			continue
		out.append(cent)
	return out


func _group_cent(id: String) -> Variant:
	for cent in _real_cents():
		if str(cent.get_meta("zonda_cid", "")).begins_with(id + ":"):
			return cent
	return null
