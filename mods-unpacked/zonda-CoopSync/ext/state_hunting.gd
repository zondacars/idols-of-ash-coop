extends "res://scripts/centipede_states/centipede_state_follow_path.gd"

static var coop_hunting_sfx_last_played_ms: int = -999


func enter():
	super()
	await _centipede.get_tree().process_frame
	await _centipede.get_tree().process_frame
	reached_end_of_path()


func safe_get_distance_to_climber(default_distance: float = 999.9) -> float:
	if is_instance_valid(_centipede) and _centipede.is_inside_tree():
		return CoopSync.target_player_distance(_centipede, default_distance)
	return default_distance


func physics_tick(delta: float) -> void:
	super(delta)

	var dist_to_target: float = safe_get_distance_to_climber()
	if is_instance_valid(_centipede) and _centipede.get_world_3d():
		_centipede.stamina += delta * Game.active_balance_settings.centipede_stamina_regen_rate
		_centipede.stamina = math_helpers.clamp01(_centipede.stamina)

		var target: Node3D = CoopSync.target_player_for(_centipede)

		if target and randf() < 0.005 and _centipede.nearest_lore_point_location_in_range_of_player.length_squared() > 1.0:
			if _centipede.nearest_lore_point_location_in_range_of_player.distance_squared_to(_centipede.global_position) < _centipede.lore_point_outer_range * _centipede.lore_point_outer_range:
				_centipede.set_state(centipede_state_wander_around_lore_point.new())
				return

		if not _centipede.hunting_sfx.playing and randf() < 0.005 and dist_to_target > 60.0:
			if Time.get_ticks_msec() > coop_hunting_sfx_last_played_ms + 2000:
				coop_hunting_sfx_last_played_ms = Time.get_ticks_msec()
				_centipede.hunting_sfx.play()
				# a counter the host streams with the creature, so every guest hears this cry too
				_centipede.set_meta("zonda_cry", int(_centipede.get_meta("zonda_cry", 0)) + 1)

		if target and _path.size() > 0 and Time.get_ticks_msec() > _last_ms_new_path + 15000:
			if _path_target_position.distance_to(target.global_position) > 10.0:
				_path.clear()
				reached_end_of_path()

		if target and (dist_to_target < 4.0 or (dist_to_target < lerpf(7.0, 9.0, _centipede.stamina) and randf() < _centipede.stamina * _centipede.stamina)):
			var los_ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(target.global_position, _centipede.global_position, 1)
			var los_results: Dictionary = _centipede.get_world_3d().direct_space_state.intersect_ray(los_ray)
			if los_results.size() == 0:
				_centipede.set_state(centipede_state_attack.new())
				return


func reached_end_of_path():
	super()

	while is_instance_valid(_centipede) and _centipede._current_state == self:
		if not _centipede._pathfinder.path_finding_in_progress:
			var target: Node3D = CoopSync.target_player_for(_centipede)
			if target == null:
				break
			var claw: Node3D = null
			if Game.centipede_should_go_after_claw():
				claw = CoopSync.target_attached_claw_node(_centipede)
			if claw:
				_centipede._pathfinder.find_new_path_to_node(claw, self)
			else:
				_centipede._pathfinder.find_new_path_to_node(target, self)
			break
		elif _centipede.is_inside_tree():
			await _centipede.get_tree().physics_frame


func get_path_follow_speed() -> float:
	var min_speed = Game.active_balance_settings.centipede_movement_speed_close
	var max_speed = Game.active_balance_settings.centipede_movement_speed_far
	var stamina_speed_multiplier = 1.0
	if is_instance_valid(_centipede):
		stamina_speed_multiplier = lerp(0.7, 1.0, _centipede.stamina)
	return lerpf(min_speed, max_speed, math_helpers.clamp01(safe_get_distance_to_climber() * 0.002)) * stamina_speed_multiplier
