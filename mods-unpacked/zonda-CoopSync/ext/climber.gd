extends "res://scripts/climber.gd"

const RESPAWN_GRACE_MS := 3000

var coop_remote_death := false
var coop_spectating := false
var _coop_spec_index := 0
var _coop_invuln_until_ms := 0
var _coop_respawning := false
var _coop_has_ground := false
var _coop_last_ground_pos: Vector3


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
	collision_layer = 0
	collision_mask = 0
	_coop_spec_index = 0
	Game.audio.play_player_damaged_sfx_lethal()
	hud.set_to_black()
	CoopSync.show_banner("Out of respawns. You are now spectating.  JUMP = switch player", 6.0)
	await get_tree().create_timer(1.2).timeout
	if is_inside_tree():
		cut_from_black()


func coop_revive_at_checkpoint() -> void:
	if not coop_spectating:
		return
	hud.set_to_black()
	CoopSync.show_banner("Checkpoint reached! Rejoining the run...", 3.0)
	await get_tree().create_timer(1.0).timeout
	if not is_inside_tree():
		return
	coop_spectating = false
	grapple_claw_is_enabled = true
	collision_layer = 2
	collision_mask = 1
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
			global_position = global_position.lerp(desired, clampf(delta * 8.0, 0.0, 1.0))
			CoopSync.show_banner("Spectating %s   (JUMP = next player)" % target.player_name, 0.5)
		elif not target:
			CoopSync.show_banner("Spectating. Waiting for a living player...", 0.5)
		velocity = Vector3.ZERO
		AirVelocity = Vector3.ZERO
		additional_velocity_next_frame = Vector3.ZERO
		return
	if is_on_floor() and get_floor_normal().y > 0.8 and not (activeClimberState is ClimberState_Attached) and not _coop_respawning and health > 0.0:
		_coop_last_ground_pos = global_position
		_coop_has_ground = true
	super(delta)


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
