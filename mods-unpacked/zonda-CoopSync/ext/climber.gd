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


func _physics_process(delta: float) -> void:
	if coop_spectating:
		var target = CoopSync.spectate_target(_coop_spec_index)
		if target and Camera:
			var cam_forward: Vector3 = -Camera.global_basis.z
			var desired: Vector3 = target.global_position - cam_forward * 3.0 + Vector3.UP * 1.2
			global_position = global_position.lerp(desired, clampf(delta * 10.0, 0.0, 1.0))
			CoopSync.show_banner("Spectating %s   (JUMP = next player)" % target.player_name, 0.5)
		elif not target:
			CoopSync.show_banner("Spectating. Waiting for a living player...", 0.5)
		velocity = Vector3.ZERO
		AirVelocity = Vector3.ZERO
		additional_velocity_next_frame = Vector3.ZERO
		return
	if is_on_floor() and not _coop_respawning and health > 0.0:
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
