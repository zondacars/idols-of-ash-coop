extends "res://scripts/climber.gd"

const RESPAWN_GRACE_MS := 3000
const SPECTATE_ALONE_S := 3.0      # nobody left alive (or the session ended) for this long: restart

var coop_remote_death := false
var coop_spectating := false
var _coop_spec_index := 0
var _coop_invuln_until_ms := 0
var _coop_respawning := false
var _coop_has_ground := false
var _coop_last_ground_pos: Vector3
var _coop_saved_layer := -1
var _coop_saved_mask := -1
var _coop_alone_t := 0.0
var _coop_reviving := false
var _coop_spec_target_id := 0
const COOP_CAM_EYE := 0.768        # the Camera above the body origin (climber.tscn)
const COOP_CAM_PAD := 0.35         # how far the spectator camera stays off a wall it backs into


func heal(amt: float) -> void:
	print("[CoopSync] heal +%.0f (health %.0f -> %.0f)" % [amt, health, minf(health + amt, healthMax)])
	super(amt)


func take_damage(damage: float) -> void:
	if coop_spectating or _coop_respawning or Time.get_ticks_msec() < _coop_invuln_until_ms:
		return
	super(damage)


func took_lethal_damage() -> void:
	if prevent_player_death or SceneLoader.is_transitioning():
		return
	if not CoopSync.in_session():
		super()
		return
	if coop_remote_death:
		coop_remote_death = false
		super()
		return
	if _coop_respawning or coop_spectating:
		return
	if CoopSync.respawns_left > 0:
		CoopSync.respawns_left -= 1
		coop_respawn()
	elif CoopSync.any_teammate_alive():
		coop_enter_spectator()
	else:
		CoopSync.broadcast_death()
		super()


func coop_respawn() -> void:
	_coop_respawning = true
	Game.audio.play_player_damaged_sfx_lethal()
	hud.set_to_black()
	CoopSync.show_banner("You died. Respawning...  (%d respawn left this run)" % CoopSync.respawns_left, 3.0)
	await get_tree().create_timer(1.5).timeout
	if not is_inside_tree():
		return
	var spot: Vector3 = CoopSync.respawn_point_for(self)
	set_climber_state(defaultClimberState)
	velocity = Vector3.ZERO
	AirVelocity = Vector3.ZERO
	additional_velocity_next_frame = Vector3.ZERO
	teleport_to_location(spot)
	health = healthMax
	recent_damage_buffer = 0.0
	lethalDamageHandled = false
	_coop_invuln_until_ms = Time.get_ticks_msec() + RESPAWN_GRACE_MS
	_coop_respawning = false
	cut_from_black()


func coop_enter_spectator() -> void:
	coop_spectating = true
	lethalDamageHandled = false
	health = 0.0
	set_climber_state(defaultClimberState)
	velocity = Vector3.ZERO
	AirVelocity = Vector3.ZERO
	additional_velocity_next_frame = Vector3.ZERO
	LastVelocity = Vector3.ZERO
	PlayerCamera.rotation = Vector3.ZERO
	PlayerCamera.DutchAngleOffset = 0.0
	grapple_claw_is_enabled = false
	if _coop_saved_layer < 0:
		_coop_saved_layer = collision_layer
		_coop_saved_mask = collision_mask
	collision_layer = 0
	collision_mask = 0
	_coop_spec_index = 0
	_coop_spec_target_id = 0             # the first spectate frame snaps to the teammate
	# leave a soul where you last stood: a living teammate who reaches it pulls you back
	CoopSync.soul_drop(_coop_last_ground_pos if _coop_has_ground else global_position)
	Game.audio.play_player_damaged_sfx_lethal()
	hud.set_to_black()
	CoopSync.show_banner("Out of respawns. You are now spectating.  JUMP = switch player", 6.0)
	await get_tree().create_timer(1.2).timeout
	if is_inside_tree():
		cut_from_black()


func coop_revive_at_checkpoint() -> void:
	_coop_revive("Checkpoint reached! Rejoining the run...", null, false)


func coop_revive_by_rescue(by: String, soul_pos) -> void:
	_coop_revive("%s pulled you back." % by, soul_pos, true)


func _coop_revive(banner: String, soul_pos, rescued: bool) -> void:
	if not coop_spectating:
		return
	hud.set_to_black()
	CoopSync.show_banner(banner, 3.0)
	_coop_reviving = true
	await get_tree().create_timer(1.0).timeout
	_coop_reviving = false
	if not is_inside_tree() or not coop_spectating:
		return
	coop_spectating = false
	_coop_alone_t = 0.0
	grapple_claw_is_enabled = true
	# back onto the layers the game gave us (the old code put the player on the claw's layer,
	# which made map triggers and checkpoints blind to anyone who had been revived)
	collision_layer = _coop_saved_layer if _coop_saved_layer >= 0 else 4
	collision_mask = _coop_saved_mask if _coop_saved_mask >= 0 else 1
	var spot: Vector3 = CoopSync.rescue_point_for(self, soul_pos) if rescued else CoopSync.respawn_point_for(self)
	set_climber_state(defaultClimberState)
	velocity = Vector3.ZERO
	AirVelocity = Vector3.ZERO
	additional_velocity_next_frame = Vector3.ZERO
	teleport_to_location(spot)
	health = healthMax
	recent_damage_buffer = 0.0
	lethalDamageHandled = false
	_coop_invuln_until_ms = Time.get_ticks_msec() + RESPAWN_GRACE_MS
	cut_from_black()


func _physics_process(delta: float) -> void:
	if coop_spectating:
		global_rotation = Vector3.ZERO
		var target = CoopSync.spectate_target(_coop_spec_index)
		if target and Camera:
			var target_forward: Vector3 = -target.global_basis.z
			target_forward.y = 0.0
			if target_forward.length_squared() < 0.0001:
				target_forward = Vector3.FORWARD
			target_forward = target_forward.normalized()
			var desired: Vector3 = target.global_position - target_forward * 3.5 + Vector3.UP * 1.6
			_coop_spectate_follow(target, desired, delta)
			CoopSync.show_banner("Spectating %s   (JUMP = next player)" % target.player_name, 0.5)
		velocity = Vector3.ZERO
		AirVelocity = Vector3.ZERO
		additional_velocity_next_frame = Vector3.ZERO
		if target and CoopSync.in_session():
			_coop_alone_t = 0.0
		else:
			_coop_spectate_alone(delta)
		return
	if is_on_floor() and get_floor_normal().y > 0.8 and not (activeClimberState is ClimberState_Attached) and not _coop_respawning and health > 0.0:
		_coop_last_ground_pos = global_position
		_coop_has_ground = true
	super(delta)


func _coop_spectate_follow(target: Node3D, desired: Vector3, delta: float) -> void:
	# Review #110: a camera boom. A ray from the watched knight's head to where the camera
	# wants to be (terrain is layer 1, tubes are two-sided) shortens the boom in tunnels and
	# under overhangs, so the view never ends up inside rock.
	var eye_off: Vector3 = Camera.global_position - global_position
	if eye_off.length() > 3.0:
		eye_off = Vector3.UP * COOP_CAM_EYE
	var head: Vector3 = target.global_position + Vector3.UP * 0.6
	var want_eye: Vector3 = desired + eye_off
	var eye: Vector3 = want_eye
	var space: PhysicsDirectSpaceState3D = null
	if get_world_3d():
		space = get_world_3d().direct_space_state
	if space:
		var q := PhysicsRayQueryParameters3D.create(head, want_eye, 1)
		q.hit_back_faces = true
		var hit: Dictionary = space.intersect_ray(q)
		if not hit.is_empty():
			var hp: Vector3 = hit["position"]
			var dir: Vector3 = (want_eye - head).normalized()
			eye = head + dir * maxf(head.distance_to(hp) - COOP_CAM_PAD, 0.0)
	var tid: int = target.get_instance_id()
	var cur_eye: Vector3 = global_position + eye_off
	var snap := tid != _coop_spec_target_id or cur_eye.distance_to(eye) > 30.0
	if not snap and space:
		# the camera is behind rock from the knight's head (a bend, an overhang, the first
		# frame of spectating): jump in, never sweep through it
		var q2 := PhysicsRayQueryParameters3D.create(head, cur_eye, 1)
		q2.hit_back_faces = true
		snap = not space.intersect_ray(q2).is_empty()
	_coop_spec_target_id = tid
	if snap:
		global_position = eye - eye_off
	else:
		global_position = global_position.lerp(eye - eye_off, clampf(delta * 8.0, 0.0, 1.0))


func _coop_spectate_alone(delta: float) -> void:
	# Nobody to watch: both players died in the same fall, the last teammate left, or the
	# host left and the session ended. After a short grace (packet jitter, a teammate's revive
	# in flight) run the normal team-death restart, or the solo death once out of session.
	if _coop_reviving or _coop_respawning or in_ending_state or prevent_player_death or SceneLoader.is_transitioning():
		_coop_alone_t = 0.0
		return
	_coop_alone_t += delta
	if _coop_alone_t < SPECTATE_ALONE_S:
		var left := ceili(SPECTATE_ALONE_S - _coop_alone_t)
		if CoopSync.in_session():
			CoopSync.show_banner("Spectating. Nobody else is alive...  restarting in %d" % left, 0.5)
		else:
			CoopSync.show_banner("The session ended while you were down.  restarting in %d" % left, 0.5)
		return
	_coop_alone_t = 0.0
	coop_spectating = false
	if _coop_saved_layer >= 0:
		collision_layer = _coop_saved_layer
		collision_mask = _coop_saved_mask
	if CoopSync.in_session():
		CoopSync.show_banner("Everyone is down. Restarting the run...", 4.0)
		CoopSync.broadcast_death()      # any other spectator restarts with us
		coop_remote_death = true        # took_lethal_damage then runs the base game death
	health = 0.0
	lethalDamageHandled = false
	took_lethal_damage()


func _process(delta: float) -> void:
	if coop_spectating:
		return
	super(delta)


func _input(event: InputEvent) -> void:
	if coop_spectating:
		if event.is_action_pressed("ioa_jump"):
			_coop_spec_index += 1
		return
	super(event)


func on_bit() -> void:
	if in_ending_state and CoopSync.in_session() and not CoopSync.is_host:
		return
	super()


func ending_cut() -> void:
	player_audio_enabled = false
	hud.set_to_black()
	PlayerCamera.LookAtOverrideNode = null

	await get_tree().process_frame

	var rope_fallen = get_node("%Rope_Fallen")
	rope_fallen.visible = true

	var new_player_transform: Transform3D = get_node("%BottomEndingPlayerNode").global_transform
	var target_origin: Vector3 = new_player_transform.origin
	if CoopSync.in_session():
		target_origin += CoopSync.local_player_slot_offset()
	teleport_to_location(target_origin)
	global_rotation = Vector3.ZERO
	PlayerCamera.set_camera_rotation(new_player_transform.basis.get_rotation_quaternion().get_euler())
	enter_injured_state()

	await get_tree().create_timer(4.0).timeout
	cut_from_black()
	Game.audio.start_ending_music()

	var rope_swish = get_node("%Rope_Swish")
	rope_swish.visible = false
	rope_swish_for_ending.visible = false
	in_ending_state = true
