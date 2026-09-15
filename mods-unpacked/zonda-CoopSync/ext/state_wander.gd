extends "res://scripts/centipede_states/centipede_state_wander.gd"


func safe_get_distance_to_climber(default_distance: float = 999.9) -> float:
	if is_instance_valid(_centipede) and _centipede.is_inside_tree():
		return CoopSync.target_player_distance(_centipede, default_distance)
	return default_distance


func try_to_transition_to_hunting() -> void:
	if not is_instance_valid(_centipede):
		return
	var target: Node3D = CoopSync.target_player_for(_centipede)
	if target == null:
		return
	if Game.is_in_normal_campaign():
		if CoopSync.lowest_player_y() < -250.0 + 854.536:
			_centipede.set_state(centipede_state_hunting.new())
	elif target.global_position.distance_to(_centipede.global_position) < 500.0:
		_centipede.set_state(centipede_state_hunting.new())
