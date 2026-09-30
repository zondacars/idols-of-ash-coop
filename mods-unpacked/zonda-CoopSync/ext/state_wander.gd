extends "res://scripts/centipede_states/centipede_state_wander.gd"

# CoopWander: the game's wander, aimed by CoopSync's targeting. v5.0 light-fear A adds the SULK:
# while the centipede's meta "zonda_sulk_until" (ms) lies ahead, it never turns to hunting and
# every wander leg heads for its home (meta "zonda_home", else where it started). Each path
# request also waits for the pathfinder to be free (a request made while it is busy is dropped
# without a callback, and the wander would then stand still).
# v5.0 creature no-clip A11: while meta "zonda_leash_until" (ms, set by the map when a leash or a
# Burrows return could not teleport it home unseen) lies ahead, every wander leg heads home too; it
# never blocks hunting or light-fear (the sulk does, the leash does not).


func safe_get_distance_to_climber(default_distance: float = 999.9) -> float:
	if is_instance_valid(_centipede) and _centipede.is_inside_tree():
		return CoopSync.target_player_distance(_centipede, default_distance)
	return default_distance


func _sulking() -> bool:
	return is_instance_valid(_centipede) and Time.get_ticks_msec() < int(_centipede.get_meta("zonda_sulk_until", 0))


func _home() -> Vector3:
	var h = _centipede.get_meta("zonda_home", null)
	if h is Vector3:
		return h
	return _centipede.original_global_position


func try_to_transition_to_hunting() -> void:
	if not is_instance_valid(_centipede):
		return
	if _sulking():
		return                          # driven off by the light: it slinks home first
	var target: Node3D = CoopSync.target_player_for(_centipede)
	if target == null:
		return
	if Game.is_in_normal_campaign():
		if CoopSync.lowest_player_y() < -250.0 + 854.536:
			_centipede.set_state(centipede_state_hunting.new())
	elif target.global_position.distance_to(_centipede.global_position) < 500.0:
		_centipede.set_state(centipede_state_hunting.new())


func _leashed() -> bool:
	# v5.0 no-clip A11: the map could not teleport this one home unseen (meta "zonda_leash_until", ms,
	# set by underdark.gd _nc_cent_home), so it walks home. Read ONLY here: light-fear and hunting stay on.
	return is_instance_valid(_centipede) and Time.get_ticks_msec() < int(_centipede.get_meta("zonda_leash_until", 0))


func find_new_wander_position() -> Vector3:
	if _sulking():
		var home := _home()
		if home != Vector3.ZERO and home.distance_to(_centipede.global_position) > 6.0:
			return home
		return Vector3.ZERO             # home already: wait there until the sulk ends
	if _leashed():
		var home2 := _home()
		if home2 != Vector3.ZERO and home2.distance_to(_centipede.global_position) > 6.0:
			return home2
	return super()


func reached_end_of_path():
	# the game's wander loop, but a new path is only asked for once the pathfinder is free
	_end_of_path_reached = true
	if not is_instance_valid(_centipede) or not _centipede.is_inside_tree():
		return
	await _centipede.get_tree().physics_frame
	while is_instance_valid(_centipede) and _centipede.is_inside_tree() and _centipede._current_state == self:
		if not _centipede._pathfinder.path_finding_in_progress:
			var wander_pos: Vector3 = find_new_wander_position()
			if wander_pos != Vector3.ZERO:
				_centipede._pathfinder.find_new_path_to_position(wander_pos, self)
				break
		await _centipede.get_tree().physics_frame
