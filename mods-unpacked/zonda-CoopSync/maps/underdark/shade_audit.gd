extends Node
# ============================================================================================
# THE UNDERDARK: the Shade surface audit (ZondaCoopSync 5.0, feature "shadeaudit"). Developer test.
# "Make sure the shade is perfect on all surfaces."
#
# A. WALKER AUDIT. The Shade moves with one floor walk (shades.gd _nc_walk = NC.walk_step with the Shade's
#    profile). For every Shade, every station of its band within 55 m of its home, and 6 jittered floor spots
#    round each station (whatever floor is there: rock, slopes, ledges, bone, planks, shelves), the walk is
#    asked for 8 headings at two step lengths (a stalk step and a rush step). Every step it ACCEPTS is checked
#    by independent rays and shape queries:
#      feet   the floor under the new position is within 0.10 m under / 0.20 m over the feet (never buried or
#             floating)
#      body   HARD: the core (shins to shoulders: r 0.13, 0.45 m up to 2.4 m, or 0.65 m under low rock; the feet
#             themselves rest on the floor, so a slope beside them is contact, not clipping) touches no rock. SOFT
#             (counted, not failed): the arms hang 0.17 to either side of the torso, so r 0.22 from 0.5 to 1.9 m
#             brushing rock is a graze
#      head   HARD: a ball (r 0.08, the model's own) where the pose puts the head (over the feet upright, ahead of
#             them hunched under low rock) touches no rock. SOFT: the same with r 0.15
#      path   the L-shaped path the walk proved (rise or advance, then the rest) is clear at mid body height
# B. BOXED-IN REPORT. From every home, 16 headings x a 6 m and a 14 m walkable line (the same rule the Shade
#    test uses to place the player): a Shade with no walkable line has nowhere to hunt from.
# C. REACHABLE-POSITION AUDIT. A breadth-first walk from the home through the Shade's own rules (the walk and the
#    zone / checkpoint / part / squeeze rules after it): every position it can ever stand in gets the feet, body
#    and head checks of A, and the report says how much floor it can reach and how many of its route stations
#    (the corridor it patrols) it can get within 3 m of.
#
# Flag: maps/underdark/shadeaudit.flag (any text). Nothing wakes (the Shades are held asleep).
# Tag [SHADEA]; last line "[SHADEA] test done <passed>/<total> PASS".
# ============================================================================================

const OVERALL_MS := 1500000
const STATION_R := 55.0
const SPOTS_PER_STATION := 6
const HEADINGS := 8
const STEPS := [0.25, 0.9]
const FEET_UNDER := 0.10
const FEET_OVER := 0.20
const MAX_BAD_FRAC := 0.002            # feet noise allowed (finite ray resolution on rough floor)
const BFS_STEPS := [0.5, 1.5]
const BFS_HEADINGS := 16
const BFS_CAP := 5200                  # positions per Shade (breadth first: the cap decides how far the audit looks, not the Shade)
const BFS_MAX_FLAT := 30.0             # m from the home
const BFS_CELL := 0.5

var map: Node = null
var active := false
var _running := false
var _done := false
var _t0 := 0
var _checks: Array = []
var _sh = null                         # the shades module
var _NC = null
var _space = null
var _ppd_saved = null
var _hold_saved = null
var _rng := RandomNumberGenerator.new()


func setup(m: Node) -> void:
	map = m
	var fl = m.call("dev_flag", "shadeaudit.flag") if m.has_method("dev_flag") else null
	if fl == null:
		return
	active = true
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")


func _ready() -> void:
	if not active:
		set_process(false)
		return
	_run()


func on_exit() -> void:
	if active and not _done:
		print("[SHADEA] map exit during the test")
		_restore()


func _process(_delta: float) -> void:
	if not active or _done or not _running:
		return
	var c := _climber()
	if c != null:
		if _ppd_saved == null:
			_ppd_saved = bool(c.get("prevent_player_death"))
		if not bool(c.get("prevent_player_death")):
			c.set("prevent_player_death", true)
	if _sh != null:
		_sh.set("_test_hold", true)              # every Shade asleep


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
	_rng.seed = 5150
	_sh = map.call("feature", "shades") if map.has_method("feature") else null
	if _sh == null or not is_instance_valid(_sh):
		_check(false, "the shades module is loaded")
		_finish()
		return
	_NC = _sh.call("_ncx")
	if _NC == null:
		_check(false, "the no-clip helper is on (the Shade walk is the guarded one)")
		_finish()
		return
	_hold_saved = _sh.get("_test_hold")
	_sh.set("_test_hold", true)
	await _wait(4.0)
	var shades: Array = _sh.get("shades")
	print("[SHADEA] %d Shades" % shades.size())
	var tot_acc := 0
	var tot_ref := 0
	var tot_bad := 0
	var tot_hard := 0
	var tot_soft := 0
	var boxed: Array = []
	var cramped: Array = []
	for i in shades.size():
		if _over():
			break
		var s = shades[i]
		var res: Dictionary = await _audit_shade(s)
		var lines: Array = await _boxed_in(s)
		var reach: Dictionary = await _reach(s)
		var bf: Dictionary = await _bfs(s)
		for k in ["acc", "ref", "air", "buried", "inside", "head", "cut", "arm", "head_soft"]:
			res[k] = int(res[k]) + int(bf[k])
		for smp in bf["samples"]:
			(res["samples"] as Array).append(smp)
		tot_acc += int(res["acc"])
		tot_ref += int(res["ref"])
		tot_bad += int(res["air"]) + int(res["buried"])
		tot_hard += int(res["inside"]) + int(res["head"]) + int(res["cut"])
		tot_soft += int(res["arm"]) + int(res["head_soft"])
		print("[SHADEA] %s band=%s floors=%d steps accepted=%d refused=%d | feet air=%d buried=%d | HARD body in rock=%d head in rock=%d path cut=%d | soft arm graze=%d head graze=%d | walkable lines 6 m %d/16, 14 m %d/16" % [
			str(s.get("id")), str(_sh.get("bands")[int(s.get("band"))]["name"]), int(res["floors"]), int(res["acc"]), int(res["ref"]),
			int(res["air"]), int(res["buried"]), int(res["inside"]), int(res["head"]), int(res["cut"]), int(res["arm"]), int(res["head_soft"]), int(lines[0]), int(lines[1])])
		print("[SHADEA] %s straight lines from home: longest %d m, median %d m, of 16 headings stopped by the walk %d, by the zone/checkpoint/part rules %d, went the full 14 m %d" % [
			str(s.get("id")), int(reach["max"]), int(reach["median"]), int(reach["walk"]), int(reach["rules"]), int(reach["full"])])
		print("[SHADEA] %s REACHABLE floor: %d positions (about %.0f m2)%s, farthest %.1f m from home, route stations within 14 m of home: %d, of them reached within 3 m: %d | steps the body volume refused: legs and torso %d (%s), head %d" % [
			str(s.get("id")), int(bf["cells"]), float(bf["cells"]) * BFS_CELL * BFS_CELL, " (capped)" if bool(bf["capped"]) else "", float(bf["far"]), int(bf["near"]), int(bf["hit"]), int(bf["ref_cap"]), str(bf["ref_split"]), int(bf["ref_head"])])
		for dl in bf["det"]:
			print("[SHADEA]   %s" % str(dl))
		for smp in res["samples"]:
			print("[SHADEA]   bad step %s" % str(smp))
		if int(lines[0]) == 0:
			boxed.append(str(s.get("id")))
		if float(bf["far"]) < 6.0:
			cramped.append("%s (%.1f m)" % [str(s.get("id")), float(bf["far"])])
		_check(int(res["inside"]) + int(res["head"]) + int(res["cut"]) == 0, "%s: no step it can take puts its body or head in rock or cuts through it (%d steps)" % [str(s.get("id")), int(res["acc"])])
		_check(int(bf["near_any"]) == 0 or int(bf["hit_any"]) >= 1, "%s: it can walk to within 3 m of a route station of its band (%d of %d within 30 m of home reached)" % [str(s.get("id")), int(bf["hit_any"]), int(bf["near_any"])])
		var frac := float(int(res["air"]) + int(res["buried"])) / float(maxi(1, int(res["acc"])))
		_check(frac <= MAX_BAD_FRAC, "%s: feet stay on the floor (%d of %d steps off it, %.2f %%)" % [str(s.get("id")), int(res["air"]) + int(res["buried"]), int(res["acc"]), frac * 100.0])
	print("[SHADEA] summary: %d accepted steps (%d refused), %d feet off the floor, %d hard in rock, %d soft grazes (arms and head brushing); no walkable 6 m straight line from home: %s; reachable floor under 6 m from home: %s" % [
		tot_acc, tot_ref, tot_bad, tot_hard, tot_soft, ", ".join(PackedStringArray(boxed)) if not boxed.is_empty() else "none",
		", ".join(PackedStringArray(cramped)) if not cramped.is_empty() else "none"])
	_check(tot_acc >= 3000, "enough steps were checked (%d)" % tot_acc)
	_finish()


func _over() -> bool:
	return _done or Time.get_ticks_msec() - _t0 > OVERALL_MS


func _wait(secs: float) -> void:
	var t_end := Time.get_ticks_msec() + int(secs * 1000.0)
	while Time.get_ticks_msec() < t_end and not _over():
		await get_tree().process_frame


# ---------------------------------------------------------------------------- A: the walker audit for one Shade

func _audit_shade(s) -> Dictionary:
	var out := _new_out()
	var home: Vector3 = s.get("home")
	var c := _climber()
	if c != null and map.has_method("debug_park"):
		map.call("debug_park", home + Vector3.UP * 1.0)
	await _wait(1.8)
	_space = map.get_world_3d().direct_space_state
	var bands: Array = _sh.get("bands")
	var route: Array = bands[int(s.get("band"))]["route"]
	var spots: Array = []
	for q in route:
		if (q as Vector3).distance_to(home) > STATION_R:
			continue
		spots.append(q)
		for k in SPOTS_PER_STATION:
			var a := _rng.randf() * TAU
			var r := _rng.randf_range(2.0, 11.0)
			spots.append((q as Vector3) + Vector3(cos(a) * r, 0.0, sin(a) * r))
	var room0 := float(s.get("room"))
	var n := 0
	for p in spots:
		if _over():
			break
		var f = _floor_at(p)
		if f == null:
			continue
		var ff: Vector3 = f
		if not bool(_sh.call("_headroom", _space, ff)):
			continue
		if _core_hit(ff, float(_sh.call("_room_at", _space, ff))):
			continue                                  # the spot itself has rock in the body: nobody stands here
		out["floors"] = int(out["floors"]) + 1
		var room := float(_sh.call("_room_at", _space, ff))
		s.set("room", room)
		for h in HEADINGS:
			var ang := float(h) * TAU / float(HEADINGS)
			var dir := Vector3(sin(ang), 0.0, cos(ang))
			for dist in STEPS:
				var r = _sh.call("_nc_walk", _NC, _space, s, ff, dir, float(dist), true)
				if not (r is Dictionary):
					out["ref"] = int(out["ref"]) + 1
					continue
				out["acc"] = int(out["acc"]) + 1
				_check_step(s, ff, r, out)
		n += 1
		if n % 4 == 0:
			await get_tree().process_frame
	s.set("room", room0)
	return out


func _new_out() -> Dictionary:
	return {"floors": 0, "acc": 0, "ref": 0, "air": 0, "buried": 0, "inside": 0, "head": 0, "cut": 0, "arm": 0, "head_soft": 0, "samples": []}


func _floor_at(p: Vector3) -> Variant:
	var hit: Dictionary = _NC.call("ray", _space, Vector3(p.x, p.y + 3.0, p.z), Vector3(p.x, p.y - 6.0, p.z))
	if hit.is_empty():
		return null
	if float((hit["normal"] as Vector3).y) < 0.5:
		return null
	return hit["position"]


func _check_step(s, from: Vector3, r: Dictionary, out: Dictionary) -> void:
	var pos: Vector3 = r.get("pos", from)
	var via: Vector3 = r.get("via", from)
	var where := "%s from %s to %s" % [str(s.get("id")), _fmt(from), _fmt(pos)]
	# feet on the floor
	var fh: Dictionary = _NC.call("ray", _space, pos + Vector3.UP * 0.6, pos + Vector3.DOWN * 1.2)
	if fh.is_empty():
		out["air"] = int(out["air"]) + 1
		_note(out, "no floor under the feet, " + where)
	else:
		var gap := pos.y - float((fh["position"] as Vector3).y)
		if gap > FEET_OVER:
			out["air"] = int(out["air"]) + 1
			_note(out, "feet %.2f m over the floor, %s" % [gap, where])
		elif gap < -FEET_UNDER:
			out["buried"] = int(out["buried"]) + 1
			_note(out, "feet %.2f m in the floor, %s" % [-gap, where])
	# the body and the head
	var room_at := float(_sh.call("_room_at", _space, pos))
	room_at = minf(room_at, float(r.get("low_t", INF)))
	if _core_hit(pos, room_at):
		out["inside"] = int(out["inside"]) + 1
		_note(out, "body in rock (contact %.2f m up, %.2f m to the side), %s" % [_hit_rel.y, Vector2(_hit_rel.x, _hit_rel.z).length(), where])
	elif _shape_hit(pos + Vector3.UP * 1.2, 0.22, 1.4, false):
		out["arm"] = int(out["arm"]) + 1
	var hc := _head_center(pos, from, room_at)
	if _shape_hit(hc, 0.08, 0.0, true):
		out["head"] = int(out["head"]) + 1
		_hit_rel = _hit_rel - pos
		_note(out, "head in rock (room %.2f m, contact %.2f m up, %.2f m to the side), %s" % [room_at, _hit_rel.y, Vector2(_hit_rel.x, _hit_rel.z).length(), where])
	elif _shape_hit(hc, 0.15, 0.0, true):
		out["head_soft"] = int(out["head_soft"]) + 1
	# the L path the walk proved: a thin ray at mid body height, and the core body (r 0.115: the walk's own r 0.14 samples
	# every 0.14 m leave no gap that wide) swept along it every 0.2 m
	var mid := Vector3.UP * 0.9
	var cut := not (_NC.call("ray", _space, from + mid, via + mid) as Dictionary).is_empty() or not (_NC.call("ray", _space, via + mid, pos + mid) as Dictionary).is_empty()
	if not cut:
		for seg in [[from, via], [via, pos]]:
			var a: Vector3 = seg[0]
			var b: Vector3 = seg[1]
			var n := int(ceil(a.distance_to(b) / 0.2))
			for i in range(1, n):
				if _core_hit(a.lerp(b, float(i) / float(n)), room_at, 0.115):
					cut = true
					break
			if cut:
				break
	if cut:
		out["cut"] = int(out["cut"]) + 1
		_note(out, "path through rock (rise %.2f m), %s" % [pos.y - from.y, where])


var _hit_rel := Vector3.ZERO           # the last contact point relative to the feet (x, z sideways, y up)


func _core_hit(feet: Vector3, room: float, radius: float = 0.13) -> bool:
	# shins, pelvis and torso: r 0.13 from 0.45 m to 2.4 m over the feet (0.65 m under the rock when it is low)
	var top := minf(2.4, room - 0.65)
	var h := maxf(top - 0.45, 0.4)
	var hit := _shape_hit(feet + Vector3.UP * (0.45 + h * 0.5), radius, h, false)
	if hit:
		_hit_rel = _hit_rel - feet
	return hit


func _head_center(pos: Vector3, from: Vector3, room: float) -> Vector3:
	# where the pose puts the head (the same hunch the Shade draws): the step's direction is the way it faces
	var hp: Vector2 = _sh.call("_hunch_pose", room)
	var top := 1.5 - hp.x + 1.54 * cos(hp.y)
	var flat := Vector3(pos.x - from.x, 0.0, pos.z - from.z)
	if flat.length() > 0.001:
		flat = flat.normalized()
	return pos + Vector3.UP * (top - 0.1) + flat * (1.54 * sin(hp.y) * 0.9)


func _shape_hit(p: Vector3, radius: float, height: float, sphere: bool) -> bool:
	var q := PhysicsShapeQueryParameters3D.new()
	if not sphere:
		var cap := CapsuleShape3D.new()
		cap.radius = radius
		cap.height = maxf(height, 2.0 * radius + 0.001)
		q.shape = cap
	else:
		var ball := SphereShape3D.new()
		ball.radius = radius
		q.shape = ball
	q.transform = Transform3D(Basis(), p)
	q.collision_mask = 1
	q.collide_with_areas = false
	var static_hit := false
	for r in _space.intersect_shape(q, 8):
		if (r as Dictionary).get("collider") is StaticBody3D:
			static_hit = true
			break
	if not static_hit:
		return false
	var ri: Dictionary = _space.get_rest_info(q)
	_hit_rel = ri.get("point", p) if not ri.is_empty() else p
	return true


func _note(out: Dictionary, text: String) -> void:
	var kind := text.substr(0, 8)
	var l: Array = out["samples"]
	var n := 0
	for x in l:
		if str(x).begins_with(kind):
			n += 1
	if n < 3:
		l.append(text)


func _fmt(p: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [p.x, p.y, p.z]


# ---------------------------------------------------------------------------- B: the boxed-in report

func _reach(s) -> Dictionary:
	# 16 headings from the home, 1 m steps through the Shade's own walk (tall = false, then the zone / checkpoint /
	# part / squeeze rules, exactly what _walk_step does): how far it gets and what stops it
	var home: Vector3 = s.get("home")
	var room0 := float(s.get("room"))
	var lens: Array = []
	var walk := 0
	var rules := 0
	var full := 0
	for k in 16:
		var a := float(k) * TAU / 16.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		var cur := home
		var n := 0
		while n < 14:
			s.set("room", float(_sh.call("_room_at", _space, cur)))
			var r = _sh.call("_nc_walk", _NC, _space, s, cur, dir, 1.0, false)
			if not (r is Dictionary):
				walk += 1
				break
			var np: Vector3 = (r as Dictionary).get("pos", cur)
			if not bool(_sh.call("_step_ok", s, cur, np)):
				rules += 1
				break
			cur = np
			n += 1
		if n >= 14:
			full += 1
		lens.append(n)
		if k % 4 == 3:
			await get_tree().process_frame
	s.set("room", room0)
	lens.sort()
	return {"max": lens[lens.size() - 1], "median": lens[lens.size() / 2], "walk": walk, "rules": rules, "full": full}


func _cell(p: Vector3) -> Vector3i:
	return Vector3i(roundi(p.x / BFS_CELL), roundi(p.y / 0.5), roundi(p.z / BFS_CELL))


func _bfs(s) -> Dictionary:
	# C: every position the Shade can reach from its home by its own rules, each checked once
	var out := _new_out()
	out["cells"] = 0
	out["far"] = 0.0
	out["near"] = 0
	out["hit"] = 0
	out["capped"] = false
	var home: Vector3 = s.get("home")
	var room0 := float(s.get("room"))
	var seen := {}
	var q: Array = [home]
	seen[_cell(home)] = true
	var qi := 0
	var pumped := 0
	var bs0: Dictionary = (_sh.get("body_stats") as Dictionary).duplicate()
	while qi < q.size() and not _over():
		if q.size() >= BFS_CAP:
			out["capped"] = true
			break
		var cur: Vector3 = q[qi]
		qi += 1
		s.set("room", float(_sh.call("_room_at", _space, cur)))
		for h in BFS_HEADINGS:
			var ang := float(h) * TAU / float(BFS_HEADINGS)
			var dir := Vector3(sin(ang), 0.0, cos(ang))
			for dist in BFS_STEPS:
				var r = _sh.call("_nc_walk", _NC, _space, s, cur, dir, float(dist), true)
				if not (r is Dictionary):
					out["ref"] = int(out["ref"]) + 1
					continue
				var np: Vector3 = (r as Dictionary).get("pos", cur)
				if not bool(_sh.call("_step_ok", s, cur, np)):
					out["ref"] = int(out["ref"]) + 1
					continue
				out["acc"] = int(out["acc"]) + 1
				var key := _cell(np)
				if seen.has(key):
					continue
				seen[key] = true
				if Vector2(np.x - home.x, np.z - home.z).length() > BFS_MAX_FLAT:
					continue
				_check_step(s, cur, r, out)
				q.append(np)
		pumped += 1
		if pumped % 3 == 0:
			await get_tree().process_frame
	s.set("room", room0)
	var bs1: Dictionary = _sh.get("body_stats")
	out["ref_cap"] = int(bs1["cap"]) - int(bs0["cap"])
	out["ref_head"] = int(bs1["head"]) - int(bs0["head"])
	out["ref_split"] = "up or down part of the step %d, along part %d, end spot %d" % [int(bs1["cap_vert"]) - int(bs0["cap_vert"]), int(bs1["cap_flat"]) - int(bs0["cap_flat"]), int(bs1["cap_dest"]) - int(bs0["cap_dest"])]
	out["cells"] = q.size()
	var far := 0.0
	for p in q:
		far = maxf(far, Vector2((p as Vector3).x - home.x, (p as Vector3).z - home.z).length())
	out["far"] = far
	var bands: Array = _sh.get("bands")
	var route: Array = bands[int(s.get("band"))]["route"]
	var det: Array = []
	out["near_any"] = 0
	out["hit_any"] = 0
	for st in route:
		var dh := (st as Vector3).distance_to(home)
		if dh > 30.0:
			continue
		out["near_any"] = int(out["near_any"]) + 1
		if dh <= 14.0:
			out["near"] = int(out["near"]) + 1
		var best := 1e9
		var best_dy := 0.0
		for p in q:
			var d := (p as Vector3).distance_to(st)
			if d < best:
				best = d
				best_dy = (st as Vector3).y - (p as Vector3).y
		if best <= 3.0:
			out["hit_any"] = int(out["hit_any"]) + 1
			if dh <= 14.0:
				out["hit"] = int(out["hit"]) + 1
		if dh <= 14.0 or best <= 3.0:
			det.append("station %.1f m from home: nearest reachable floor %.1f m from it (it is %.1f m higher)" % [dh, best, best_dy])
		if best > 3.0 and dh <= 14.0:
			det.append(_why_not(s, q, st))
	out["det"] = det
	return out


func _why_not(s, q: Array, st: Vector3) -> String:
	# a route station the Shade cannot get near: from the reachable floor nearest to it, what refuses each way toward it
	var pn: Vector3 = q[0]
	var bd := 1e9
	for p in q:
		var d := (p as Vector3).distance_to(st)
		if d < bd:
			bd = d
			pn = p
	var prof := {"kind": "shade", "probes": [0.45, 1.4, 2.4], "lead": 0.3, "step_up": 2.2, "max_drop": 2.5, "head": 2.5, "room_max": 3.4, "min_ny": 0.5}
	var tally := {}
	var toward := Vector3(st.x - pn.x, 0.0, st.z - pn.z)
	if toward.length() < 0.01:
		return "   the nearest reachable floor is right under the station"
	toward = toward.normalized()
	for k in 9:
		var ang := float(k - 4) * 0.35
		var dir := toward.rotated(Vector3.UP, ang)
		for dist in [0.5, 1.0]:
			var r: Dictionary = _NC.call("walk_step", _space, pn, dir, float(dist), prof)
			var why := "ok"
			if not bool(r.get("ok", false)):
				why = str(r.get("why", "?"))
			else:
				s.set("room", float(_sh.call("_room_at", _space, pn)))
				var w = _sh.call("_nc_walk", _NC, _space, s, pn, dir, float(dist), true)
				if not (w is Dictionary):
					why = "walk ok, refused after it (hunch lean, body or head volume)"
				elif not bool(_sh.call("_step_ok", s, pn, (w as Dictionary).get("pos", pn))):
					why = "walk ok, zone / checkpoint / part / squeeze rule"
			tally[why] = int(tally.get(why, 0)) + 1
	var parts: Array = []
	for kk in tally.keys():
		parts.append("%s x%d" % [str(kk), int(tally[kk])])
	return "   from the reachable floor nearest to that station (%.1f m off, it is %.1f m %s), the 18 steps toward it are refused by: %s" % [bd, absf(st.y - pn.y), "lower" if st.y < pn.y else "higher", ", ".join(PackedStringArray(parts))]


func _boxed_in(s) -> Array:
	var n6 := 0
	var n14 := 0
	for k in 16:
		var a := float(k) * TAU / 16.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		if _sh.call("_walk_line", _space, s, dir, 6.0, false) != null:
			n6 += 1
		if _sh.call("_walk_line", _space, s, dir, 14.0, false) != null:
			n14 += 1
		if k % 4 == 3:
			await get_tree().process_frame
	return [n6, n14]


# ============================================================================ the end

func _check(ok: bool, text: String) -> void:
	_checks.append([ok, text])
	print("[SHADEA] %s %s" % ["PASS" if ok else "FAIL", text])


func _finish() -> void:
	if _done:
		return
	if _over():
		_check(false, "the audit finished inside %d s" % (OVERALL_MS / 1000))
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
		printerr("[SHADEA] test done %d/%d PASS" % [p, _checks.size()])
	else:
		printerr("[SHADEA] test done %d/%d FAIL: %s" % [p, _checks.size(), ", ".join(PackedStringArray(fails))])


func _restore() -> void:
	if _sh != null and is_instance_valid(_sh) and _hold_saved != null:
		_sh.set("_test_hold", _hold_saved)
	var c := _climber()
	if c != null and _ppd_saved != null:
		c.set("prevent_player_death", bool(_ppd_saved))


func _climber() -> Node3D:
	var c = Game.get("climber")
	if is_instance_valid(c) and c is Node3D and (c as Node3D).is_inside_tree():
		return c
	return null
