extends "res://scripts/centipede_states/centipede_state_attack.gd"

# CoopAttack: the game's lunge, aimed by CoopSync's targeting.
# v5.0 creature no-clip (spec 3.A A3), only while the no-clip helper is on (Rule K; today's lunge
# otherwise): the lunge LOCKS the player it started on (enter), and its 12 m exit follows that player;
# every 0.1 s two lines from the head (to the capsule centre and to the eye, +0.77 m) keep it going
# unless BOTH are blocked; it heads for a point off the player's own surface instead of 1.6 m straight
# up: five 1.8 m rays from the capsule centre (+X, -X, +Z, -Z, -Y) give a surface normal sum (plus a
# little up), and the aim sits up to 1.6 m out along it (less under a shelf). On open floor that is
# exactly the old point; for a climber hanging on a wall it is 1.6 m out from the wall, tilted up,
# where the head rides, so the pivot never drives into the wall behind the player. The telegraph
# (the snarl in enter), the speed rule, the twitch buffer and the bite are unchanged. A lunge that
# the guard keeps refusing for 0.3 s ends (ext/centipede.gd), and at a gap narrower than the head it
# holds at the opening and gives up (owner decision 7A).

const NC_AIM_DIRS := [Vector3.RIGHT, Vector3.LEFT, Vector3.BACK, Vector3.FORWARD, Vector3.DOWN]
const NC_AIM_PROBE := 1.8
const NC_AIM_RAY := 2.6
const NC_AIM_REACH := 1.6
const NC_EYE := 0.77

var _lock: Node3D = null              # the player this lunge started on
var _nc_t := 0.0
var _nc_aim_off := Vector3(0.0, NC_AIM_REACH, 0.0)


func enter():
	super()                              # the snarl: the telegraph is unchanged
	if is_instance_valid(_centipede) and _centipede.is_inside_tree():
		var t = CoopSync.target_player_for(_centipede)
		_lock = t if t is Node3D else null
	_nc_t = 0.0
	_nc_aim_off = Vector3(0.0, NC_AIM_REACH, 0.0)
	_nc_note("lunges")


func _nc_on() -> bool:
	return is_instance_valid(_centipede) and _centipede.has_method("nc_on") and bool(_centipede.call("nc_on"))


func _nc_note(key: String) -> void:
	if not is_instance_valid(_centipede) or not _centipede.has_method("nc"):
		return
	var NC = _centipede.call("nc")
	if NC != null:
		NC.call("note", str(_centipede.call("_nc_kind")), key, 1)


func safe_get_distance_to_climber(default_distance: float = 999.9) -> float:
	if is_instance_valid(_centipede) and _centipede.is_inside_tree():
		if _nc_on() and is_instance_valid(_lock) and _lock.is_inside_tree():
			return _centipede.global_position.distance_to(_lock.global_position)
		return CoopSync.target_player_distance(_centipede, default_distance)
	return default_distance


func physics_tick(delta: float):
	if not is_instance_valid(_centipede):
		return
	if _nc_on():
		_nc_physics_tick(delta)
		return

	if not _centipede.roar_wander_sfx.playing and randf() < 0.0005 and safe_get_distance_to_climber() > 250.0:
		if Time.get_ticks_msec() > centipede_state_base.roar_wander_sfx_last_played_ms + 120000:
			centipede_state_base.roar_wander_sfx_last_played_ms = Time.get_ticks_msec()
			_centipede.roar_wander_sfx.play()      # counted for the guests by ext/centipede.gd _coop_roar_watch

	if Time.get_ticks_msec() > twitchy_movement_buffer_added_ms + 250:
		twitchy_movement_buffer_added_ms = Time.get_ticks_msec() + randi_range(0, 150)
		twitchy_movement_buffer += 1.5
		if randf() < 0.1:
			var stamina_used_for_extra_movement: float = clamp(0.2, 0.0, _centipede.stamina)
			_centipede.stamina -= stamina_used_for_extra_movement
			twitchy_movement_buffer += stamina_used_for_extra_movement * lerpf(16.0, 32.0, math_helpers.clamp01(Game.difficulty * 1.0))

	var target: Node3D = CoopSync.target_player_for(_centipede)
	if target == null:
		_centipede.set_state(centipede_state_hunting.new())
		return

	if safe_get_distance_to_climber() > 12.0 or (randf() < 0.01 and randf() > _centipede.stamina * 50.0):
		_centipede.set_state(centipede_state_hunting.new())
		return

	if movement_cancellation_last_centipede_dealt_damage_time != _centipede.last_dealt_damage_time:
		movement_cancellation_last_centipede_dealt_damage_time = _centipede.last_dealt_damage_time
		twitchy_movement_buffer *= 0.1

	var tpos: Vector3 = target.global_position
	var dir_to_player: Vector3 = _centipede.global_position.direction_to(tpos + _centipede._pathfinder.follow_path_height * Vector3.UP)
	var distance_can_move: float = min(18.0 * delta, twitchy_movement_buffer)
	distance_can_move = distance_can_move * lerpf(0.7, 1.0, _centipede.stamina)
	twitchy_movement_buffer -= distance_can_move
	_centipede.global_position += dir_to_player * distance_can_move

	if tpos.distance_squared_to(_centipede.global_position) > 0.0001:
		var rot: Quaternion = _centipede.global_transform.looking_at(tpos, _centipede.basis.y).basis.get_rotation_quaternion()
		_centipede.global_rotation = _centipede.global_basis.get_rotation_quaternion().slerp(rot, 40.0 * distance_can_move * delta).get_euler()
	_centipede.global_rotation += math_helpers.createRandomUnitVector3D() * 5.0 * delta


func _nc_physics_tick(delta: float) -> void:
	# the no-clip lunge: the lock, the line-of-sight pair and the surface aim; the rest is the old lunge
	if not _centipede.roar_wander_sfx.playing and randf() < 0.0005 and safe_get_distance_to_climber() > 250.0:
		if Time.get_ticks_msec() > centipede_state_base.roar_wander_sfx_last_played_ms + 120000:
			centipede_state_base.roar_wander_sfx_last_played_ms = Time.get_ticks_msec()
			_centipede.roar_wander_sfx.play()

	if Time.get_ticks_msec() > twitchy_movement_buffer_added_ms + 250:
		twitchy_movement_buffer_added_ms = Time.get_ticks_msec() + randi_range(0, 150)
		twitchy_movement_buffer += 1.5
		if randf() < 0.1:
			var stamina_used_for_extra_movement: float = clamp(0.2, 0.0, _centipede.stamina)
			_centipede.stamina -= stamina_used_for_extra_movement
			twitchy_movement_buffer += stamina_used_for_extra_movement * lerpf(16.0, 32.0, math_helpers.clamp01(Game.difficulty * 1.0))

	var target: Node3D = _lock
	if not is_instance_valid(target) or not target.is_inside_tree() or not CoopSync.alive_player_nodes().has(target):
		_centipede.set_state(centipede_state_hunting.new())
		return

	if safe_get_distance_to_climber() > 12.0 or (randf() < 0.01 and randf() > _centipede.stamina * 50.0):
		_centipede.set_state(centipede_state_hunting.new())
		return

	if movement_cancellation_last_centipede_dealt_damage_time != _centipede.last_dealt_damage_time:
		movement_cancellation_last_centipede_dealt_damage_time = _centipede.last_dealt_damage_time
		twitchy_movement_buffer *= 0.1

	var tpos: Vector3 = target.global_position
	_nc_t -= delta
	if _nc_t <= 0.0:
		_nc_t = 0.1
		var NC = _centipede.call("nc")
		var space: PhysicsDirectSpaceState3D = _centipede.get_world_3d().direct_space_state if _centipede.get_world_3d() else null
		if NC != null and space != null:
			var head := _centipede.global_position
			var b1 := _nc_blocked(NC, space, head, tpos)
			var b2 := _nc_blocked(NC, space, head, tpos + Vector3.UP * NC_EYE)
			if b1 and b2:
				_nc_note("abort_los")
				_centipede.set_state(centipede_state_hunting.new())
				return
			_nc_aim_off = _nc_aim_offset(NC, space, tpos)

	var aim: Vector3 = tpos + _nc_aim_off
	var dir_to_aim: Vector3 = _centipede.global_position.direction_to(aim)
	var distance_can_move: float = min(18.0 * delta, twitchy_movement_buffer)
	distance_can_move = distance_can_move * lerpf(0.7, 1.0, _centipede.stamina)
	twitchy_movement_buffer -= distance_can_move
	_centipede.global_position += dir_to_aim * distance_can_move

	if tpos.distance_squared_to(_centipede.global_position) > 0.0001:
		var rot: Quaternion = _centipede.global_transform.looking_at(tpos, _centipede.basis.y).basis.get_rotation_quaternion()
		_centipede.global_rotation = _centipede.global_basis.get_rotation_quaternion().slerp(rot, 40.0 * distance_can_move * delta).get_euler()
	_centipede.global_rotation += math_helpers.createRandomUnitVector3D() * 5.0 * delta


static func _nc_blocked(NC, space, a: Vector3, b: Vector3) -> bool:
	var r = NC.call("ray", space, a, b)
	return r is Dictionary and not (r as Dictionary).is_empty()


func _nc_aim_offset(NC, space, lock: Vector3) -> Vector3:
	# the aim, relative to the lock's capsule centre (applied to the lock's position every tick)
	var hits: Array = []
	for dv in NC_AIM_DIRS:
		var r = NC.call("ray", space, lock, lock + (dv as Vector3) * NC_AIM_PROBE)
		if r is Dictionary and not (r as Dictionary).is_empty():
			hits.append([float(r.get("d", NC_AIM_PROBE)), r.get("normal", -(dv as Vector3))])
	var dir := nc_aim_dir(hits)
	var r2 = NC.call("ray", space, lock, lock + dir * NC_AIM_RAY)
	var hd := -1.0
	if r2 is Dictionary and not (r2 as Dictionary).is_empty():
		hd = float(r2.get("d", NC_AIM_RAY))
	return dir * nc_aim_reach(hd)


static func nc_aim_dir(hits: Array) -> Vector3:
	# hits: [distance, Rule N normal (facing the lock)] of each of the five probe rays that hit.
	# nsum = UP * 0.5 + sum(n * (1.8 - d) / 1.8): the nearer the rock, the harder it pushes the aim away
	var nsum := Vector3.UP * 0.5
	for h in hits:
		var n: Vector3 = h[1]
		nsum += n * ((NC_AIM_PROBE - float(h[0])) / NC_AIM_PROBE)
	if nsum.length() < 0.001:
		return Vector3.UP
	return nsum.normalized()


static func nc_aim_reach(hit_d: float) -> float:
	# how far out along the aim direction: 1.6 m, or 1 m short of the rock it meets (at least 0.4 m)
	if hit_d < 0.0:
		return NC_AIM_REACH
	return clampf(hit_d - 1.0, 0.4, NC_AIM_REACH)
