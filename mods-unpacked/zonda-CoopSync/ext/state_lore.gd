extends "res://scripts/centipede_states/centipede_state_wander.gd"


func safe_get_distance_to_climber(default_distance: float = 999.9) -> float:
	if is_instance_valid(_centipede) and _centipede.is_inside_tree():
		return CoopSync.target_player_distance(_centipede, default_distance)
	return default_distance


func try_to_transition_to_hunting() -> void:
	pass


func physics_tick(delta: float):
	super(delta)
	if is_instance_valid(_centipede) and randf() < 0.002:
		var target: Node3D = CoopSync.target_player_for(_centipede)
		if target and not Centipede.is_location_in_lore_point_range(target.global_position):
			_centipede.set_state(centipede_state_wander.new())


func find_new_wander_position() -> Vector3:
	for try in 5:
		var to_position = _centipede.global_position + math_helpers.createRandomUnitVector3D() * 400.0
		var los_ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(_centipede.global_position, to_position, 1)
		var los_results: Dictionary = _centipede.get_world_3d().direct_space_state.intersect_ray(los_ray)
		if los_results.size() > 0:
			var ray_hit_position = los_results["position"]
			if ray_hit_position.distance_to(_centipede.global_position) > 40.0:
				if _centipede.nearest_lore_point_location_in_range_of_player.length_squared() > 1.0:
					var distance_to_lore_point: float = _centipede.nearest_lore_point_location_in_range_of_player.distance_squared_to(ray_hit_position)
					if distance_to_lore_point > _centipede.lore_point_inner_range * _centipede.lore_point_inner_range:
						if distance_to_lore_point < _centipede.lore_point_outer_range * _centipede.lore_point_outer_range:
							return ray_hit_position
				else:
					return ray_hit_position
	return Vector3.ZERO


func get_path_follow_speed() -> float:
	return 7.0
