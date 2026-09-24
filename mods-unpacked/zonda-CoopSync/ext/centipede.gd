extends "res://scripts/centipede.gd"

const CoopHunting := preload("res://mods-unpacked/zonda-CoopSync/ext/state_hunting.gd")
const CoopAttack := preload("res://mods-unpacked/zonda-CoopSync/ext/state_attack.gd")
const CoopWander := preload("res://mods-unpacked/zonda-CoopSync/ext/state_wander.gd")
const CoopLore := preload("res://mods-unpacked/zonda-CoopSync/ext/state_lore.gd")

const CoopSnapBuffer := preload("res://mods-unpacked/zonda-CoopSync/snap_buffer.gd")
const COOP_INTERP_DELAY_MS := 60

var coop_puppet := false
var coop_skin := 0               # 0 = the game's centipede, 1 = pale blind crawler (Underdark)
var _coop_buf = CoopSnapBuffer.new()
var _coop_attacking := false
var _coop_dummy_attack = null
var _coop_voice_cd := 4.0             # seconds until the close-range voice may play again
var _coop_voice_prev := 1e9           # distance to this PC's knight at the last check
var _coop_last_cry := -1              # the host's cry / roar counters as last seen (-1 = not yet)
var _coop_last_roar := -1
const COOP_VOICE_RANGE := 26.0


func _coop_close_voice(delta: float) -> void:
	_coop_voice_cd -= delta
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree() or not visible:
		return
	var d: float = global_position.distance_to(c.global_position)
	var closing: bool = d < _coop_voice_prev - 0.05
	_coop_voice_prev = d
	if _coop_voice_cd > 0.0 or d > COOP_VOICE_RANGE or not closing:
		return
	if hunting_sfx.playing or attack_sfx.playing or chomp_sfx.playing:
		return
	_coop_voice_cd = randf_range(7.0, 12.0)
	attack_sfx.play()                   # the wet snarl, not the distant hunting call (that one has distance baked in)


# The base game steps each leg (and clicks) only while (section + round(0.012 * ms)) % 15 lands
# exactly on 0 or 7, an 83 ms window. Any frame longer than that skips the window: the leg
# does not step and the click never plays. Catch up on the steps a long frame jumped over.
var _coop_step_last: Dictionary = {}


func update_body_section(delta: float, section_index: int):
	var bucket: int = section_index + roundi(0.012 * Time.get_ticks_msec())
	var prev: int = int(_coop_step_last.get(section_index, bucket))
	_coop_step_last[section_index] = bucket
	var gap: int = bucket - prev
	if gap > 1 and section_index < _body_sections.size() and _previous_head_transforms_over_distance.size() > 0:
		var miss1 := gap >= 15
		var miss2 := gap >= 15
		if not miss1:
			for v in range(prev + 1, bucket):
				var r: int = v % 15
				if r == 0:
					miss1 = true
				elif r == 7:
					miss2 = true
		if miss1 or miss2:
			var section = _body_sections[section_index]
			var had: float = global_position.distance_to(_previous_head_transforms_over_distance[0].position)
			var ht = get_interpolated_position_from_history(section_index + 1, had)
			if ht != null and ht.position.distance_squared_to(Vector3.ZERO) > 0.001:
				if miss1 and section.leg1_target_foot_position != ht.leg1_foot_position:
					section.leg1_target_foot_position = ht.leg1_foot_position
					section.play_footstep_sfx()
				if miss2 and section.leg2_target_foot_position != ht.leg2_foot_position:
					section.leg2_target_foot_position = ht.leg2_foot_position
					section.play_footstep_sfx()
	super(delta, section_index)


func on_teeth_bite() -> void:
	if not CoopSync.in_session():
		super()
		return

	# every snap of the jaws crunches, whoever it lands on (the base game does the same); it used
	# to play only when the bite hit this PC's own knight, so bites on teammates were silent
	chomp_sfx.play()
	if not is_instance_valid(Game.climber) or not Game.climber.is_inside_tree():
		return

	var dist_sq_to_climber: float = global_position.distance_squared_to(Game.climber.global_position)
	if dist_sq_to_climber < 9.0:
		last_dealt_damage_time = Time.get_ticks_msec()
		Game.climber.take_damage(75.0)
		Game.climber.additional_velocity_next_frame += global_position.direction_to(Game.climber.global_position) * 15.0
		Game.audio.play_player_was_bit()
		Game.climber.on_bit()


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


func coop_apply_skin(k: int) -> void:
	coop_skin = k
	set_meta("zonda_skin", k)
	call_deferred("_coop_paint_skin")


func _coop_paint_skin() -> void:
	if not is_inside_tree():
		return
	if coop_skin == 0:
		_coop_unpaint_skin()
		return
	set_meta("zonda_painted", true)
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.7, 0.66, 0.56)       # bone. Never saw the sun.
	m.metallic = 0.05
	m.roughness = 0.85
	for mi in find_children("*", "MeshInstance3D", true, false):
		var mesh_i := mi as MeshInstance3D
		if mesh_i.mesh == null:
			continue
		for si in mesh_i.mesh.get_surface_count():
			mesh_i.set_surface_override_material(si, m)
	if not has_meta("zonda_pale_voice"):
		set_meta("zonda_pale_voice", true)
		for a in [idle_sfx, attack_sfx, hunting_sfx, chomp_sfx, roar_wander_sfx]:
			if a is AudioStreamPlayer3D:
				(a as AudioStreamPlayer3D).pitch_scale = 0.72


func _coop_unpaint_skin() -> void:
	# back from the pale crawler to the game's own skin (a puppet can be handed a different creature)
	if not has_meta("zonda_painted"):
		return
	remove_meta("zonda_painted")
	for mi in find_children("*", "MeshInstance3D", true, false):
		var mesh_i := mi as MeshInstance3D
		if mesh_i.mesh == null:
			continue
		for si in mesh_i.mesh.get_surface_count():
			mesh_i.set_surface_override_material(si, null)
	super.on_bio_lum_state_updated()          # the game puts its own monster material back
	if has_meta("zonda_pale_voice"):
		remove_meta("zonda_pale_voice")
		for a in [idle_sfx, attack_sfx, hunting_sfx, chomp_sfx, roar_wander_sfx]:
			if a is AudioStreamPlayer3D:
				(a as AudioStreamPlayer3D).pitch_scale = 1.0


func on_bio_lum_state_updated() -> void:
	super()
	if coop_skin != 0:
		_coop_paint_skin()


func coop_apply_state(s: Array, sender_t: int) -> void:
	visible = true
	if s.size() > 4 and int(s[4]) != coop_skin:
		coop_apply_skin(int(s[4]))
	var p: Vector3 = s[0]
	var q: Quaternion = s[1]
	var att: bool = s[2]
	stamina = s[3]
	_coop_apply_cries(s)
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


func _coop_apply_cries(s: Array) -> void:
	# The host's hunting-cry and roar counters ride after the stable id (a String) in the entry:
	# the first number past index 4 is the cry count, the next the roar count. A change plays the
	# sound here, at the puppet's real place. The first packet only seeds them (no cry on join).
	var nums: Array = []
	for i in range(5, s.size()):
		var v = s[i]
		if typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT:
			nums.append(int(v))
	var cry: int = int(nums[0]) if nums.size() > 0 else -1
	var roar: int = int(nums[1]) if nums.size() > 1 else -1
	_coop_cry_counts(cry, roar)


func coop_note_cries(cid: String, cry: int, roar: int) -> void:
	# the same counters from a map's own stream (the Underdark's "cr", keyed by stable id). A puppet
	# handed a different creature starts counting afresh, so it never cries for the old one.
	if str(get_meta("zonda_cry_cid", "")) != cid:
		set_meta("zonda_cry_cid", cid)
		_coop_last_cry = -1
		_coop_last_roar = -1
	_coop_cry_counts(cry, roar)


func _coop_cry_counts(cry: int, roar: int) -> void:
	# -1 = not sent. A change plays the sound; the first value seen only seeds the counter.
	if cry >= 0:
		if _coop_last_cry >= 0 and cry != _coop_last_cry and is_instance_valid(hunting_sfx) and not hunting_sfx.playing:
			hunting_sfx.play()
		_coop_last_cry = cry
	if roar >= 0:
		if _coop_last_roar >= 0 and roar != _coop_last_roar and is_instance_valid(roar_wander_sfx) and not roar_wander_sfx.playing:
			roar_wander_sfx.play()
		_coop_last_roar = roar


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

	_coop_close_voice(delta)
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
