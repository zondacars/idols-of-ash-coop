extends "res://scripts/centipede.gd"

const CoopHunting := preload("res://mods-unpacked/zonda-CoopSync/ext/state_hunting.gd")
const CoopAttack := preload("res://mods-unpacked/zonda-CoopSync/ext/state_attack.gd")
const CoopWander := preload("res://mods-unpacked/zonda-CoopSync/ext/state_wander.gd")
const CoopLore := preload("res://mods-unpacked/zonda-CoopSync/ext/state_lore.gd")

const CoopSnapBuffer := preload("res://mods-unpacked/zonda-CoopSync/snap_buffer.gd")
const COOP_INTERP_DELAY_MS := 60

var coop_puppet := false
var _coop_buf = CoopSnapBuffer.new()
var _coop_attacking := false
var _coop_dummy_attack = null


func _ready() -> void:
	if CoopSync.is_guest():
		coop_puppet = true
		CoopSync.register_puppet(self)
		smooth_random_position = math_helpers.createRandomUnitVector3D()
		for section in range(15):
			spawn_body_section()
		spawn_body_section(true)
		if Game.active_balance_settings and Game.active_balance_settings.disable_centipedes:
			queue_free()
			return
		await get_tree().process_frame
		Game.register_centipede(self)
		original_global_position = global_position
		on_bio_lum_state_updated()
		print("[CoopSync] puppet centipede ready")
	else:
		super()


func set_state(state) -> void:
	if coop_puppet:
		return
	if CoopSync.in_session() and state != null:
		var s = state.get_script()
		if s == centipede_state_hunting:
			state = CoopHunting.new()
		elif s == centipede_state_attack:
			state = CoopAttack.new()
		elif s == centipede_state_wander_around_lore_point:
			state = CoopLore.new()
		elif s == centipede_state_wander:
			state = CoopWander.new()
	super(state)


func coop_apply_state(s: Array, sender_t: int) -> void:
	visible = true
	var p: Vector3 = s[0]
	var q: Quaternion = s[1]
	var att: bool = s[2]
	stamina = s[3]
	if _coop_buf.is_empty():
		global_position = p
		global_basis = Basis(q)
	_coop_buf.push(sender_t, {"pos": p, "rot": q})
	if att != _coop_attacking:
		_coop_attacking = att
		if att:
			if _coop_dummy_attack == null:
				_coop_dummy_attack = centipede_state_attack.new()
				_coop_dummy_attack.setup(self)
			_current_state = _coop_dummy_attack
			attack_sfx.play()
		else:
			_current_state = null


func _process(delta: float) -> void:
	if coop_puppet:
		var s := _coop_buf.sample(COOP_INTERP_DELAY_MS)
		if not s.is_empty():
			var a: Dictionary = s["a"]
			var b: Dictionary = s["b"]
			var k: float = s["alpha"]
			var pa: Vector3 = a["pos"]
			var pb: Vector3 = b["pos"]
			if pa.distance_squared_to(pb) > 900.0:
				global_position = pb
				global_basis = Basis(b["rot"])
			else:
				global_position = pa.lerp(pb, k)
				global_basis = Basis((a["rot"] as Quaternion).slerp(b["rot"], clampf(k, 0.0, 1.0)))
		update_body_visuals(delta)
		var look := Vector3.ZERO
		var has_look := false
		if Game.climber:
			look = Game.climber.global_position
			has_look = true
		_coop_process_common(delta, look, has_look)
		return

	if not CoopSync.in_session():
		super(delta)
		return

	if _current_state:
		_current_state.tick(delta)
	update_body_visuals(delta)
	var target := CoopSync.target_player_for(self)
	_coop_process_common(delta, target.global_position if target else Vector3.ZERO, target != null)


func _coop_process_common(delta: float, look_pos: Vector3, has_look: bool) -> void:
	var head_offset_target_rotation: Quaternion = global_basis.get_rotation_quaternion()
	if has_look and head_offset_node.global_position.direction_to(look_pos).dot(-global_basis.z) > 0.0:
		head_offset_target_rotation = math_helpers.create_look_at_position_quaternion(head_offset_node.global_position, look_pos, global_basis.y)
	head_offset_node.global_rotation = Quaternion.from_euler(head_offset_node.global_rotation).slerp(head_offset_target_rotation, 4.0 * delta).get_euler()
	smooth_random_position = smooth_random_position.lerp(math_helpers.createRandomUnitVector3D(), delta * 0.01)
	if bio_lum_monster_enabled != GameSettings.config.get_value("game", "bio_lum_monster_enabled", false):
		on_bio_lum_state_updated()


func _physics_process(delta: float) -> void:
	if not is_inside_tree():
		return

	if coop_puppet:
		if not idle_sfx.playing:
			idle_sfx.play()
		_coop_local_body_knockback()
		return

	if not CoopSync.in_session():
		super(delta)
		return

	if _current_state:
		_current_state.physics_tick(delta)

	if not idle_sfx.playing:
		idle_sfx.play()

	nearest_lore_point_location_in_range_of_player = Vector3.ZERO

	var target := CoopSync.target_player_for(self)
	if target:
		var tp: Vector3 = target.global_position
		var lore_point_min_dist: float = lore_point_player_range * lore_point_player_range
		for lp_loc in Game.lore_point_locations:
			var dist_sq: float = lp_loc.distance_squared_to(tp)
			if dist_sq < lore_point_min_dist:
				lore_point_min_dist = dist_sq
				nearest_lore_point_location_in_range_of_player = lp_loc

		if global_position.distance_squared_to(tp) > 500.0 * 500.0:
			try_to_teleport_to_get_closer_to_player()

		if Game.climber and Game.centipede_should_go_after_claw() and Game.climber.activeClimberState is ClimberState_Attached:
			if global_position.distance_squared_to(Game.climber.Rope._claw.global_position) < 3.0 * 3.0:
				Game.climber.Rope._claw.unhook_from_centipede(self)
		CoopSync.host_check_unhook(self)

		_coop_local_body_knockback()


func _coop_local_body_knockback() -> void:
	if not Game.climber:
		return
	for body_sec in _body_sections:
		if body_sec and is_instance_valid(body_sec.root):
			if Game.climber.global_position.distance_squared_to(body_sec.root.global_position) < 9.0:
				var direction_to_player: Vector3 = body_sec.root.global_position.direction_to(Game.climber.global_position)
				direction_to_player.y *= 0.1
				Game.climber.additional_velocity_next_frame = direction_to_player.normalized() * 24.0


func try_to_teleport_to_get_closer_to_player() -> void:
	if coop_puppet:
		return
	if not CoopSync.in_session():
		super()
		return
	var p := CoopSync.target_player_position(self)
	if Game.in_foglands_scene:
		if p.y < global_position.y:
			if p.y < -1850.0 + 854.536:
				try_to_teleport_to_location(Vector3(-23.254, -1775.561 + 854.536, -73.225))
			elif p.y < -1650.0 + 854.536:
				try_to_teleport_to_location(Vector3(123.0, -1486.0 + 854.536, -83.0))
			elif p.y < -1250.0 + 854.536:
				try_to_teleport_to_location(Vector3(-1.8, -1263.0 + 854.536, -45.0))
			elif p.y < -1050.0 + 854.536:
				try_to_teleport_to_location(Vector3(0.0, -900.0 + 854.536, 0.0))


func try_to_teleport_to_location(teleport_location: Vector3) -> void:
	if coop_puppet:
		return
	var ref: Vector3 = Game.climber.global_position
	if CoopSync.in_session():
		ref = CoopSync.target_player_position(self)
	if teleport_location.distance_squared_to(ref) > 160.0 * 160.0:
		global_position = teleport_location
		start_hunting()
