extends "res://scripts/centipede_states/centipede_state_follow_path.gd"

# CoopShy (ZondaCoopSync v5.0, light-fear A): a pale centipede caught in a lantern beam.
#
# ext/centipede.gd enters it when the fear heat reaches 1.0 (a beam held on the head, see
# _coop_light_fear there). Set holder / eye / beam_dir BEFORE set_state(), or call restart() on
# the running one (a new hit restarts the recoil). Three phases:
#   RECOIL  0.5 s: snap-turn away from the beam holder H and move the head directly at 9 m/s
#           (the way CoopAttack moves global_position), no pathing.
#   BACKOFF up to 4 s (held while the beam stays on it, 8 s at most): move directly at 6 m/s
#           toward a point 18 m from H along the beam axis. Each step is taken only when a
#           layer-1 ray down from the new point + 2 m finds rock within 4 m and two layer-1 rays
#           along the step (head height and 0.5 m up) hit nothing; else it stops there and
#           BACKOFF ends early (RECOIL just stops against the rock).
#   CIRCLE  up to 10 s: path to the flank point H - F * 12 + S * 6 + 2 m up (F = H's flat facing,
#           S = the side it is already on). A ray down from the flank + 2 m must find rock within
#           5 m, else the flank is the nearest main-route station behind H within 30 m of H, else
#           CIRCLE is skipped. Moves at 0.9 x the hunting speed. Within 5 m, or at the timeout,
#           it goes back to hunting (set_state(centipede_state_hunting.new()), which the swap in
#           ext/centipede.gd turns into CoopHunting).
# The game's pathfinder only calls back a centipede_state_follow_path, and drops a request made
# while it is still busy (centipede_3d_pathfinder.gd find_new_path_to_position), so CIRCLE waits
# for it to be free first, like CoopHunting does. A path still in flight for the old hunting
# state lands on that old state and is simply dropped.
# Debug / tests: the centipede's meta "zonda_shy" = {"phase", "flank": [x,y,z], "src": "rock" |
# "station" | "", "circle_ms", "path_ms", "abort_ms"} (src "" = CIRCLE skipped, no flank found; abort_ms > 0 =
# no flank path within CIRCLE_PATH_S, it went back to hunting at once).
# v5.0 creature no-clip (spec 3.A A4), only while the no-clip helper is on (else today's code):
#   the snap-turn keeps the centipede's own up (only on a floor: on a wall or a ceiling it skips
#   RECOIL and BACKOFF and circles at once; the hiss and the rear-up still play); the direct steps
#   find their floor along the centipede's own up with Rule N normals and lift only along a clear
#   line; the facing keeps its own up; a flank point found to be inside rock falls back to a station;
#   coop_blocked(why) is the guard's repair call (RECOIL: nothing, BACKOFF: circle, CIRCLE: the
#   centipede's own ladder, since CIRCLE is a path state).

const RECOIL := 0
const BACKOFF := 1
const CIRCLE := 2
const RECOIL_S := 0.5
const RECOIL_SPEED := 9.0
const BACKOFF_S := 4.0
const BACKOFF_MAX_S := 8.0
const BACKOFF_SPEED := 6.0
const BACKOFF_DIST := 18.0
const CIRCLE_S := 10.0
const CIRCLE_PATH_S := 4.0         # no path to the flank by then: it cannot be reached quickly, back to hunting
const CIRCLE_NEAR := 5.0
const CIRCLE_SPEED_K := 0.9
const FLANK_BACK := 12.0
const FLANK_SIDE := 6.0
const FLANK_UP := 2.0
const FLANK_FLOOR := 5.0
const STATION_R := 30.0

var holder: Node3D = null          # the beam holder H (the node beam_at returned)
var eye := Vector3.ZERO            # H's lantern when the beam hit (used when H is gone)
var beam_dir := Vector3.ZERO       # the beam's direction when it hit
var phase := RECOIL
var phase_t := 0.0
var flank := Vector3.ZERO
var flank_src := ""
var circle_ms := 0
var path_ms := 0
var _away := Vector3.ZERO
var _back_to := Vector3.ZERO
var _back_left := BACKOFF_S
var _asking := false


static func hiss_step(last: int, n: int) -> Array:
	# the hiss counter rule shared by puppets and tests: [new last, play now?]. -1 = not seen yet,
	# so the first value only seeds the counter; a change afterwards plays one hiss.
	if n < 0:
		return [last, false]
	return [n, last >= 0 and n != last]


func enter():
	super()
	_begin_recoil()


func restart(h: Node3D, e: Vector3, d: Vector3) -> void:
	holder = h
	eye = e
	beam_dir = d
	_begin_recoil()


func _ok() -> bool:
	return is_instance_valid(_centipede) and _centipede.is_inside_tree() and _centipede._current_state == self


func _nc_on() -> bool:
	return is_instance_valid(_centipede) and _centipede.has_method("nc_on") and bool(_centipede.call("nc_on"))


func _nc_ray(space, a: Vector3, b: Vector3) -> Dictionary:
	var NC = _centipede.call("nc") if is_instance_valid(_centipede) and _centipede.has_method("nc") else null
	if NC == null:
		return {}
	var r = NC.call("ray", space, a, b)
	return r if r is Dictionary else {}


func coop_blocked(why: String) -> void:
	# the no-clip guard's repair call while this state moves the head directly (the refused step)
	if phase == BACKOFF:
		_begin_circle()
	# RECOIL: nothing (it just stops against the rock); CIRCLE: the centipede runs its own ladder


func _holder_pos() -> Vector3:
	if is_instance_valid(holder) and holder.is_inside_tree():
		return holder.global_position
	return eye


func _holder_facing() -> Vector3:
	# H's flat facing now (the LightField knows every lantern's view), else the beam when it hit
	var f := Vector3.ZERO
	var lf = CoopSync.get("light_field")
	if is_instance_valid(holder) and lf != null and is_instance_valid(lf) and lf.has_method("facing_of"):
		var v = lf.facing_of(holder)
		if v is Vector3:
			f = v
	if f.length() < 0.1:
		f = Vector3(beam_dir.x, 0.0, beam_dir.z)
	if f.length() < 0.1:
		f = _holder_pos() - _centipede.global_position
		f.y = 0.0
	if f.length() < 0.1:
		return Vector3.FORWARD
	return f.normalized()


func _note(extra: Dictionary) -> void:
	var d: Dictionary = _centipede.get_meta("zonda_shy", {})
	d["phase"] = phase
	for k in extra.keys():
		d[k] = extra[k]
	_centipede.set_meta("zonda_shy", d)


func _begin_recoil() -> void:
	if not is_instance_valid(_centipede):
		return
	phase = RECOIL
	phase_t = 0.0
	_path.clear()
	_next_node = null
	_end_of_path_reached = true
	var away: Vector3 = _centipede.global_position - _holder_pos()
	away.y = 0.0
	if away.length() < 0.1:
		away = Vector3(beam_dir.x, 0.0, beam_dir.z)
	if away.length() < 0.1:
		away = _centipede.global_basis.z
		away.y = 0.0
	if away.length() < 0.1:
		away = Vector3.BACK
	_away = away.normalized()
	if _nc_on():
		# no-clip A4: only on a floor, and it keeps its own up (a snap to world up on a wall or a
		# ceiling would lay the 7.6 m head into the rock); on a wall or a ceiling it circles at once
		var up_c: Vector3 = _centipede.global_basis.y.normalized()
		if up_c.dot(Vector3.UP) <= 0.7:
			_note({"phase": RECOIL})
			_begin_circle()
			return
		var flat := _away - up_c * _away.dot(up_c)
		if flat.length() > 0.05:
			_centipede.global_basis = Basis.looking_at(flat.normalized(), up_c)
		_note({"phase": RECOIL})
		return
	# the snap-turn: it whips its head away from the light
	_centipede.global_basis = Basis.looking_at(_away, Vector3.UP)
	_note({"phase": RECOIL})


func _begin_backoff() -> void:
	phase = BACKOFF
	phase_t = 0.0
	_back_left = BACKOFF_S
	var hp := _holder_pos()
	var ax := Vector3(beam_dir.x, 0.0, beam_dir.z)
	if ax.length() < 0.1:
		ax = _centipede.global_position - hp
		ax.y = 0.0
	if ax.length() < 0.1:
		ax = _away
	_back_to = hp + ax.normalized() * BACKOFF_DIST
	_back_to.y = _centipede.global_position.y
	_note({"phase": BACKOFF})


func _begin_circle() -> void:
	phase = CIRCLE
	phase_t = 0.0
	circle_ms = Time.get_ticks_msec()
	path_ms = 0
	flank = _flank_point()
	_note({"phase": CIRCLE, "flank": [flank.x, flank.y, flank.z], "src": flank_src, "circle_ms": circle_ms, "path_ms": 0, "abort_ms": 0})
	if flank_src == "":
		_to_hunting()
		return
	_end_of_path_reached = true
	_ask_path()


func _to_hunting() -> void:
	if _ok():
		_centipede.set_state(centipede_state_hunting.new())


func _flank_point() -> Vector3:
	# behind the beam holder, on the side the centipede is already on
	var hp := _holder_pos()
	var f := _holder_facing()
	var rgt := f.cross(Vector3.UP)
	if rgt.length() < 0.01:
		rgt = Vector3.RIGHT
	rgt = rgt.normalized()
	var side := 1.0 if (_centipede.global_position - hp).dot(rgt) >= 0.0 else -1.0
	var p := hp - f * FLANK_BACK + rgt * side * FLANK_SIDE + Vector3.UP * FLANK_UP
	var space := _centipede.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 2.0, p + Vector3.DOWN * (FLANK_FLOOR - 2.0), 1)
	if not space.intersect_ray(q).is_empty() and not _nc_flank_in_rock(space, p):
		flank_src = "rock"
		return p
	# over the void: the nearest main-route station behind H instead
	var map = _centipede.get_parent()
	var L = map.get("L") if map != null else null
	var best := Vector3.ZERO
	var bd := 1e9
	if L is Dictionary:
		for s in (L as Dictionary).get("stations", []):
			if not (s is Dictionary) or str(s.get("kind", "")) == "hard":
				continue
			var sp = s.get("pos", null)
			if not (sp is Array) or (sp as Array).size() < 3:
				continue
			var v := Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
			var d := v.distance_to(hp)
			if d > STATION_R or (v - hp).dot(f) >= 0.0:
				continue
			if d < bd:
				bd = d
				best = v
	if bd < 1e8:
		flank_src = "station"
		return best + Vector3.UP * 1.0
	flank_src = ""
	return p


func _nc_flank_in_rock(space, p: Vector3) -> bool:
	# no-clip A4: a flank point the two-anchor parity test finds inside rock counts as no floor
	if not _nc_on():
		return false
	var NC = _centipede.call("nc")
	if NC == null:
		return false
	return int(NC.call("inside2", space, p)) == 1


func _ask_path() -> void:
	# the pathfinder silently drops a request while it is busy: wait for it, like CoopHunting
	if _asking:
		return
	_asking = true
	while _ok() and phase == CIRCLE:
		if not _centipede._pathfinder.path_finding_in_progress:
			_centipede._pathfinder.find_new_path_to_position(flank, self)
			break
		await _centipede.get_tree().physics_frame
	_asking = false


func new_path_completed(new_path: Array[centipede_3d_pathfinder.path_node], path_target_position: Vector3):
	super(new_path, path_target_position)
	if phase == CIRCLE and path_ms == 0 and is_instance_valid(_centipede):
		path_ms = Time.get_ticks_msec()
		_note({"path_ms": path_ms})


func reached_end_of_path():
	super()
	if phase == CIRCLE and _ok() and _centipede.global_position.distance_to(flank) > CIRCLE_NEAR:
		_ask_path()


func _step_direct(dir: Vector3, dist: float) -> bool:
	# move the head straight, but only onto rock and never into it: two mask-1 rays along the step
	# (head height and 0.5 m above, 0.3 m past the new point) must be clear, so the head stops at a
	# ledge face instead of lerping up through it; then a ray down from the new point + 2 m must hit
	# within 4 m, and the head keeps the path height above that floor
	var c := _centipede
	var np: Vector3 = c.global_position + dir * dist
	var space := c.get_world_3d().direct_space_state
	if _nc_on():
		return _nc_step_direct(space, dir, dist)
	var ahead: Vector3 = np + dir * 0.3
	var up := Vector3.UP * 0.5
	if not space.intersect_ray(PhysicsRayQueryParameters3D.create(c.global_position, ahead, 1)).is_empty():
		return false
	if not space.intersect_ray(PhysicsRayQueryParameters3D.create(c.global_position + up, ahead + up, 1)).is_empty():
		return false
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(np + Vector3.UP * 2.0, np + Vector3.DOWN * 2.0, 1))
	if hit.is_empty():
		return false
	var h: float = c._pathfinder.follow_path_height
	np.y = lerpf(np.y, float(hit["position"].y) + h, 0.35)
	c.global_position = np
	return true


func _nc_step_direct(space, dir: Vector3, dist: float) -> bool:
	# no-clip A4: the same step, with the floor found along the centipede's OWN up (so a crawler on a
	# slope or a wall finds its own surface, not the rock under or over it) and Rule N normals; the
	# height fix is its own short move, taken only along a clear line. The guard (ext/centipede.gd)
	# sweeps the final position.
	var c := _centipede
	var up_c: Vector3 = c.global_basis.y.normalized()
	var np: Vector3 = c.global_position + dir * dist
	var ahead: Vector3 = np + dir * 0.3
	if not _nc_ray(space, c.global_position, ahead).is_empty():
		return false
	if not _nc_ray(space, c.global_position + up_c * 0.5, ahead + up_c * 0.5).is_empty():
		return false
	var hit := _nc_ray(space, np + up_c * 0.3, np - up_c * 2.5)
	if hit.is_empty():
		return false
	var hp: Vector3 = hit.get("position", np)
	var hn: Vector3 = hit.get("normal", up_c)
	if (hp - np).dot(up_c) >= 0.0 or hn.dot(up_c) <= 0.5:
		return false                     # not a floor under it along its own up
	var h: float = c._pathfinder.follow_path_height
	var above: float = (np - hp).dot(up_c)
	var np2: Vector3 = np + up_c * (h - above) * 0.35
	if _nc_ray(space, np, np2).is_empty():
		np = np2
	c.global_position = np
	return true


func _face(dir: Vector3, delta: float) -> void:
	if dir.length() < 0.01:
		return
	if _nc_on():
		# keep its own up (A4): a world-up facing would roll a crawler on a slope into the rock
		var up_c: Vector3 = _centipede.global_basis.y.normalized()
		var flat := dir - up_c * dir.dot(up_c)
		if flat.length() < 0.01:
			return
		var want2 := Basis.looking_at(flat.normalized(), up_c).get_rotation_quaternion()
		var cur2: Quaternion = _centipede.global_basis.get_rotation_quaternion()
		_centipede.global_rotation = cur2.slerp(want2, clampf(10.0 * delta, 0.0, 1.0)).get_euler()
		return
	var want := Basis.looking_at(dir.normalized(), Vector3.UP).get_rotation_quaternion()
	var cur: Quaternion = _centipede.global_basis.get_rotation_quaternion()
	_centipede.global_rotation = cur.slerp(want, clampf(10.0 * delta, 0.0, 1.0)).get_euler()


func physics_tick(delta: float):
	if not _ok():
		return
	phase_t += delta
	if phase == RECOIL:
		_step_direct(_away, RECOIL_SPEED * delta)
		if phase_t >= RECOIL_S:
			_begin_backoff()
		return
	if phase == BACKOFF:
		var lit: bool = _centipede.has_meta("zonda_lit")
		if not lit:
			_back_left -= delta
		var to := _back_to - _centipede.global_position
		to.y = 0.0
		var arrived := to.length() <= 0.8
		if not arrived:
			var d := to.normalized()
			if not _step_direct(d, minf(BACKOFF_SPEED * delta, to.length())):
				_begin_circle()              # the rock ends: no further back this way
				return
			_face(d, delta)
		if phase_t >= BACKOFF_MAX_S or _back_left <= 0.0 or (arrived and not lit):
			_begin_circle()
		return
	# CIRCLE: follow the path round to the flank
	super(delta)
	if not _ok():
		return
	if path_ms == 0 and phase_t >= CIRCLE_PATH_S and _nc_on():
		_note({"abort_ms": Time.get_ticks_msec()})
		_to_hunting()                    # (leaving the state cancels the flank search: hunting is not held up by it)
		return
	if _centipede.global_position.distance_to(flank) <= CIRCLE_NEAR or phase_t >= CIRCLE_S:
		_to_hunting()


func get_path_follow_speed() -> float:
	# 0.9 x CoopHunting's speed
	var min_speed = Game.active_balance_settings.centipede_movement_speed_close
	var max_speed = Game.active_balance_settings.centipede_movement_speed_far
	var stamina_speed_multiplier = 1.0
	var d := 999.9
	if is_instance_valid(_centipede):
		stamina_speed_multiplier = lerp(0.7, 1.0, _centipede.stamina)
		if _centipede.is_inside_tree():
			d = CoopSync.target_player_distance(_centipede, 999.9)
	return CIRCLE_SPEED_K * lerpf(min_speed, max_speed, math_helpers.clamp01(d * 0.002)) * stamina_speed_multiplier
