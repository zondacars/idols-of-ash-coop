extends Node
# ============================================================================================
# THE UNDERDARK: "the creatures that fear the light come for you when the lantern is off" (ZondaCoopSync
# 5.0, feature "darkaudit"). Developer test. The lantern is OFF for the whole test (held off every frame).
#   1. the pale centipede (cen13): it hunts, lunges and bites, and it never recoils (no hiss, never the shy state)
#   2. the wall spider (sp_1): stand under it: it clicks, drops and bites, and it never scatters
# (The Shades, the third light-fearing creature, have their own test: lightfear.flag 1, "lantern off: TELL, RUSH,
# STRIKE for 20 HP".)
# Flag: maps/underdark/darkaudit.flag (any text), solo. Tag [DARK]; last line "[DARK] test done <passed>/<total> PASS".
# ============================================================================================

const HUNT_STATE := "res://scripts/centipede_states/centipede_state_hunting.gd"
const PALE_ID := "cen13"
const SPIDER_ID := "sp_1"
const OVERALL_MS := 300000

var map: Node = null
var active := false
var _running := false
var _done := false
var _t0 := 0
var _checks: Array = []
var _ppd_saved = null
var _user_saved = null
var _user_taken := false
var _pin = null
var _hunt_script = null
var _spider_bites := 0
var _spider_bit_ms := 0


func setup(m: Node) -> void:
	map = m
	var fl = m.call("dev_flag", "darkaudit.flag") if m.has_method("dev_flag") else null
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
		print("[DARK] map exit during the test")
		_restore()


func _process(_delta: float) -> void:
	if not active or _done or not _running:
		return
	# prevent_player_death on, the lantern held off
	var c := _climber()
	if c != null:
		if _ppd_saved == null:
			_ppd_saved = bool(c.get("prevent_player_death"))
		if not bool(c.get("prevent_player_death")):
			c.set("prevent_player_death", true)
	var ln = CoopSync.get("lantern")
	if is_instance_valid(ln):
		if not _user_taken:
			_user_taken = true
			_user_saved = ln.get("user")
		if int(ln.get("user")) != 0:
			ln.set("user", 0)


func _physics_process(_delta: float) -> void:
	if _pin is Vector3 and map != null and map.has_method("debug_park"):
		map.call("debug_park", _pin)


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
	_t0 = Time.get_ticks_msec()
	if ResourceLoader.exists(HUNT_STATE):
		_hunt_script = load(HUNT_STATE)
	await _wait(3.0)
	_check(_lantern_off(), "the lantern is off (wanted() false, no lit lantern in the light field)")
	await _pale()
	await _spider()
	_finish()


func _over() -> bool:
	return _done or Time.get_ticks_msec() - _t0 > OVERALL_MS


func _wait(secs: float) -> void:
	var t_end := Time.get_ticks_msec() + int(secs * 1000.0)
	while Time.get_ticks_msec() < t_end and not _over():
		await get_tree().process_frame


func _lantern_off() -> bool:
	var ln = CoopSync.get("lantern")
	if not is_instance_valid(ln) or bool(ln.call("wanted")):
		return false
	var lf = CoopSync.get("light_field")
	var c := _climber()
	if is_instance_valid(lf) and lf.has_method("player_lit") and c != null:
		return not bool(lf.call("player_lit", c))
	return true


# ---------------------------------------------------------------------------- 1. the pale centipede

func _pale() -> void:
	var sp = _spawn_of(PALE_ID)
	if sp == null:
		_check(false, "%s has a spawn in the layout" % PALE_ID)
		return
	var st := _nearest_station(sp)
	_park(st + Vector3.UP)
	await _wait(1.5)
	if map.has_method("noclip_test_wake"):
		map.call("noclip_test_wake", PALE_ID)
	var cn = null
	var t := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t < 4000 and cn == null:
		await get_tree().process_frame
		cn = _group_cent(PALE_ID)
	if cn == null:
		_check(false, "wake %s (the pale centipede)" % PALE_ID)
		return
	await _wait(1.0)
	if _hunt_script != null and cn.has_method("set_state"):
		cn.call("set_state", _hunt_script.new())
	_pin = st + Vector3.UP
	var hiss0 := int(cn.get_meta("zonda_hiss", 0))
	var dmg0 := int(cn.get("last_dealt_damage_time"))
	var hits := 0
	var attack := false
	var shy := false
	var came := false
	var d_min := 1e9
	var t0 := Time.get_ticks_msec()
	var last_dmg := dmg0
	print("[DARK] pale centipede %s: lantern off, waiting for it at %s" % [PALE_ID, str(_pin)])
	while Time.get_ticks_msec() - t0 < 90000 and not _over():
		await get_tree().process_frame
		if not is_instance_valid(cn):
			break
		var sname := _state_name(cn)
		if sname.contains("attack"):
			attack = true
		if sname.contains("shy"):
			shy = true
		var c := _climber()
		if c != null:
			d_min = minf(d_min, (cn as Node3D).global_position.distance_to(c.global_position))
			if d_min < 12.0:
				came = true
		var ldt := int(cn.get("last_dealt_damage_time"))
		if ldt != last_dmg:
			last_dmg = ldt
			hits += 1
		if hits >= 3:
			break
	_pin = null
	print("[DARK] pale centipede: closest %.1f m, attack=%s, hits=%d, shy=%s, hiss %d -> %d" % [d_min, str(attack), hits, str(shy), hiss0, int(cn.get_meta("zonda_hiss", 0))])
	_check(came, "pale centipede: it came to the player with the lantern off (closest %.1f m)" % d_min)
	_check(attack, "pale centipede: it lunged at the player")
	_check(hits >= 1, "pale centipede: it bit the player (%d hits)" % hits)
	_check(not shy and int(cn.get_meta("zonda_hiss", 0)) == hiss0, "pale centipede: it never recoiled (no shy state, no hiss)")


# ---------------------------------------------------------------------------- 2. the wall spider

func _spider() -> void:
	if _over():
		return
	var sp = null
	var sps = map.get("_spiders")
	if sps is Array:
		for s in sps:
			if is_instance_valid(s) and str(s.get("id")) == SPIDER_ID:
				sp = s
	if sp == null:
		_check(false, "%s exists" % SPIDER_ID)
		return
	var fl: Vector3 = sp.get("floor_pt")
	var at := fl + Vector3.UP
	# the spider clicks the moment someone stands under it: everything is recorded from before the park
	var c := _climber()
	var hp0 := float(c.get("health")) if c != null else 0.0
	var seen: Array = []
	var t0 := Time.get_ticks_msec()
	# the bite itself is the spider's own signal. The health compare is unreliable here: the map's test park
	# (run every physics tick to hold the player still) puts health back to full, so a bite that lands before
	# the park in the same tick leaves no frame-to-frame drop. So the bite counts as dealt when the game's own
	# record of the last damage (last_damage_taken_ms, set inside take_damage) lands on the moment of the
	# bite signal, or when a frame-to-frame health drop shows it
	_spider_bites = 0
	_spider_bit_ms = 0
	if sp.has_signal("bit") and not sp.is_connected("bit", _on_spider_bit):
		sp.connect("bit", _on_spider_bit)
	var drop := 0.0
	var hurt := false
	var hp_prev := hp0
	print("[DARK] wall spider %s: lantern off, standing under it (hp %.0f, state %d)" % [SPIDER_ID, hp0, int(sp.get("st"))])
	_pin = at
	_park(at)
	while Time.get_ticks_msec() - t0 < 25000 and not _over():
		await get_tree().process_frame
		var st := int(sp.get("st"))
		if not seen.has(st):
			seen.append(st)
		var cc := _climber()
		if cc != null:
			var hp_now := float(cc.get("health"))
			if hp_now < hp_prev:
				drop += hp_prev - hp_now
			hp_prev = hp_now
			if _spider_bit_ms > 0 and absi(int(cc.get("last_damage_taken_ms")) - _spider_bit_ms) <= 100:
				hurt = true
		if seen.has(4):                       # CLIMB: the drop and the bite are over
			break
	await _wait(0.5)
	_pin = null
	if sp.has_signal("bit") and sp.is_connected("bit", _on_spider_bit):
		sp.disconnect("bit", _on_spider_bit)
	var c2 := _climber()
	var hp1 := float(c2.get("health")) if c2 != null else 0.0
	if c2 != null and _spider_bit_ms > 0 and absi(int(c2.get("last_damage_taken_ms")) - _spider_bit_ms) <= 100:
		hurt = true
	print("[DARK] wall spider states %s, bites %d, health lost %.0f, damage dealt %s (hp %.0f -> %.0f)" % [str(seen), _spider_bites, drop, str(hurt), hp0, hp1])
	_check(seen.has(1), "wall spider: it clicked at the player (states %s)" % str(seen))
	_check(seen.has(2) and seen.has(3), "wall spider: it dropped and hung over the player")
	_check(not seen.has(6), "wall spider: it did not scatter")
	_check(_spider_bites >= 1 and (hurt or drop >= 1.0), "wall spider: it bit the player (%d bites, %.0f health lost, damage dealt %s)" % [_spider_bites, drop, str(hurt)])


func _on_spider_bit(_who: Node3D, _damage: float, _id: String) -> void:
	_spider_bites += 1
	_spider_bit_ms = Time.get_ticks_msec()


# ============================================================================ the end

func _check(ok: bool, text: String) -> void:
	_checks.append([ok, text])
	print("[DARK] %s %s" % ["PASS" if ok else "FAIL", text])


func _finish() -> void:
	if _done:
		return
	if _over():
		_check(false, "the test finished inside %d s" % (OVERALL_MS / 1000))
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
		printerr("[DARK] test done %d/%d PASS" % [p, _checks.size()])
	else:
		printerr("[DARK] test done %d/%d FAIL: %s" % [p, _checks.size(), ", ".join(PackedStringArray(fails))])


func _restore() -> void:
	_pin = null
	var ln = CoopSync.get("lantern")
	if is_instance_valid(ln) and _user_taken and _user_saved != null:
		ln.set("user", _user_saved)
	var c := _climber()
	if c != null and _ppd_saved != null:
		c.set("prevent_player_death", bool(_ppd_saved))


# ============================================================================ helpers

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


func _spawn_of(id: String) -> Variant:
	for c in _L().get("centipedes", []):
		if c is Dictionary and str(c.get("id", "")) == id:
			var sp: Array = c.get("spawn", [])
			if not sp.is_empty():
				return _v(sp[0])
	return null


func _nearest_station(p: Vector3) -> Vector3:
	var best := p
	var bd := INF
	for s in _L().get("stations", []):
		if s is Dictionary and (s as Dictionary).has("pos") and str(s.get("kind", "")) != "hard":
			var q := _v(s["pos"])
			var d := q.distance_to(p)
			if d < bd:
				bd = d
				best = q
	return best


func _group_cent(id: String) -> Variant:
	var list = Game.get("centipedes")
	if not (list is Array):
		return null
	for cent in list:
		if not is_instance_valid(cent) or not (cent is Node3D) or not (cent as Node).is_inside_tree():
			continue
		if bool(cent.get("coop_puppet")) or cent.has_meta("zonda_shadow"):
			continue
		if str(cent.get_meta("zonda_cid", "")).begins_with(id + ":"):
			return cent
	return null


func _state_name(cn) -> String:
	if not is_instance_valid(cn):
		return "?"
	var s = cn.get("_current_state")
	if s == null or not (s is Object) or (s as Object).get_script() == null:
		return "none"
	return str(((s as Object).get_script() as Script).resource_path.get_file()).trim_suffix(".gd")
