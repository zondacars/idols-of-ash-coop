extends "res://scripts/centipede_states/centipede_state_attack.gd"


func safe_get_distance_to_climber(default_distance: float = 999.9) -> float:
	if is_instance_valid(_centipede) and _centipede.is_inside_tree():
		return CoopSync.target_player_distance(_centipede, default_distance)
	return default_distance


func physics_tick(delta: float):
	if not is_instance_valid(_centipede):
		return

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
