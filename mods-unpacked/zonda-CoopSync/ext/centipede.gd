extends "res://scripts/centipede.gd"

const CoopHunting := preload("res://mods-unpacked/zonda-CoopSync/ext/state_hunting.gd")
const CoopAttack := preload("res://mods-unpacked/zonda-CoopSync/ext/state_attack.gd")
const CoopWander := preload("res://mods-unpacked/zonda-CoopSync/ext/state_wander.gd")
const CoopLore := preload("res://mods-unpacked/zonda-CoopSync/ext/state_lore.gd")
const CoopShy := preload("res://mods-unpacked/zonda-CoopSync/ext/state_shy.gd")

const CoopSnapBuffer := preload("res://mods-unpacked/zonda-CoopSync/snap_buffer.gd")
const COOP_INTERP_DELAY_MS := 60
const NC_INTERP_DELAY_MS := 100       # no-clip B2: one lost packet (15-30 Hz stream) is still bracketed

var coop_puppet := false
var coop_skin := 0               # 0 = the game's centipede, 1 = pale blind crawler (Underdark)
var _coop_buf = CoopSnapBuffer.new()
var _coop_attacking := false
var _coop_dummy_attack = null
var _coop_voice_cd := 4.0             # seconds until the close-range voice may play again
var _coop_voice_prev := 1e9           # distance to this PC's knight at the last window
var _coop_voice_win := 0.0            # seconds since the distance was last sampled (a quarter-second window)
var _coop_voice_closing := false      # it came closer by at least 0.3 m over the last window (1.2 m/s)
var _coop_last_cry := -1              # the host's cry / roar counters as last seen (-1 = not yet)
var _coop_last_roar := -1
var _coop_roar_was := false           # the wander roar was playing at the last physics tick
const COOP_VOICE_RANGE := 26.0

# ---- light-fear A (v5.0): pale centipedes (coop_skin 1) fear a lantern beam on the head ----
# Whoever runs the real centipede (the host, or solo) checks at 10 Hz:
#   CoopSync.light_field.beam_at(head, get_instance_id(), 0.9) counts at k >= 0.4 (meta
#   "zonda_lit" is set while it counts; CoopHunting never starts a lunge then). Heat rises
#   2.2 x k per second while it counts, falls 1.5 per second otherwise; at 1.0 (2 s cooldown)
#   it RECOILS: a wet hiss, meta "zonda_hiss" + 1, the head rears 0.7 rad for 0.6 s, stamina
#   - 0.25, and CoopShy (ext/state_shy.gd) takes over. 3 recoils within 40 s: it slinks home
#   (meta "zonda_home", else where it started) for 12 s (meta "zonda_sulk_until", CoopWander).
# Guests: the hiss counter rides the map's 4 Hz "cr" stream; coop_note_hiss(cid, n) plays the
#   hiss and the rear on the puppet (the first value only seeds it).
# Solo: set_state swaps in CoopHunting / CoopWander for pale ones too, so all of it works solo.
const COOP_CREATURES := "res://mods-unpacked/zonda-CoopSync/maps/underdark/creatures.gd"
const COOP_FEAR_DT := 0.1
const COOP_FEAR_K := 0.4
const COOP_FEAR_RISE := 2.2
const COOP_FEAR_FALL := 1.5
const COOP_FEAR_CD := 2.0
const COOP_SULK_N := 3
const COOP_SULK_WINDOW_MS := 40000
const COOP_SULK_MS := 12000
const COOP_REAR_S := 0.6
const COOP_REAR_RAD := 0.7
const COOP_HISS_PITCH := 0.8
var _coop_fear_acc := 0.0
var _coop_heat := 0.0
var _coop_fear_cd := 0.0
var _coop_recoils: Array = []         # ms of the recoils in the last 40 s
var _coop_rear_t := 0.0               # the rear-up pose, seconds left
var _coop_rear_applied := 0.0         # the pitch added to head_offset_node this frame
var _coop_last_hiss := -1             # puppets: the host's hiss counter as last seen
var _coop_hiss_sfx: AudioStreamPlayer3D = null
static var _coop_creatures_script = null
static var _coop_creatures_tried := false

# ---- CREATURE NO-CLIP (v5.0, creature no-clip spec revision 2, section 3.A and 3.B; group NC-2) ----
# Every behaviour change below runs only while the shared helper says so (Rule K): the helper
# maps/underdark/noclip.gd is loaded at runtime (never preloaded), and NC.is_enabled() is true only
# while THE UNDERDARK is live and its guard is on. Otherwise today's code runs unchanged; only the
# fairness counters (NC.note, a no-op unless the noclip probe measures) run in both branches.
#
# Real centipedes (host and solo), every physics tick: _nc_pre() before the state's tick (seeds the
# guard; a position set from outside the tick is swept, or declared as a teleport past 3 m), then
# _nc_post(): the 3 m in-tick teleport check, the 50% advance floor while no head candidate clears
# (path states; no advance deeper into a squeeze, 7A), turn assist toward a point 6 m along the path and the pre-turn
# onto a wall ahead (rotation only), the swept move NC.move (FULL and NEAR tiers every tick), the node
# switch line check, ONE posture probe (JAW / FWD / BELLY / ROOF / CHEEK L / CHEEK R, tiered), trail
# crumbs laid from swept physics positions (update_body_visuals no longer lays them), counters and
# the unseen-only recovery. A refused path leg goes through the repair ladder _nc_stall(): skip to
# the node after next, back to the node it left, a re-path at most every 2 s, and only after 3
# re-paths with under 5 m of progress in 15 s an escalation teleport, only while nobody sees it.
# The head clearance layer (A1b, every machine) pitches and yaws head_offset_node on top of its pose
# so the 7.6 m jaw rides along a wall instead of into it; it never moves the pivot.
# 7A (owner): a centipede never pokes its head into a gap it does not fit. The pathfinder drops
# nodes under 3.85 m of headroom or 4.7 m of width (ext/centipede_3d_pathfinder.gd); both cheeks
# blocked, or a roof with no room under it, is a squeeze: a path state makes no advance deeper into
# it (jaw clear or not) and repairs by turning back (the node it left, else a re-path; never a skip
# deeper in), a lunge holds at the opening and gives up after 0.75 s (CoopHunting then waits
# 2.5 s before it lunges again, so it does not snarl in a loop at the mouth; solo swaps CoopHunting
# and CoopWander in for every skin while the guard is on, so this holds solo too).
# Puppets (guests) and shadows (the probe's loopback copies on the host): interpolate only between
# host samples (100 ms behind, never past the newest), snap once per streamed teleport counter change
# or 12 m gap, bite on the nearer of the rendered head and the newest host sample, and run the head
# layer at 30 Hz. A shadow is silent and can never damage or shove anyone.
const NC_PATH := "res://mods-unpacked/zonda-CoopSync/maps/underdark/noclip.gd"
const NC_FAR := 1
const NC_NEAR := 2
const NC_FULL := 3
const NC_TP_JUMP := 3.0
const NC_STALL_TICKS := 36            # 0.3 s of refused, non-advancing guarded ticks
const NC_REPATH_MS := 2000
const NC_ESCALATE_N := 3
const NC_ESCALATE_WINDOW_MS := 15000
const NC_ESCALATE_PROGRESS := 5.0
const NC_JAW_STALL_S := 1.0
const NC_LOW_STALL_MS := 500          # a squeeze repairs at most this often
const NC_SQUEEZE_MS := 300            # a squeeze seen this recently still counts
const NC_CHEEK_PAIR_MS := 250
const NC_SQUEEZE_GIVEUP_S := 0.75     # a lunge held at a squeeze gives up after this
const NC_SQUEEZE_WAIT_MS := 2500      # ...and CoopHunting starts no lunge for this long
const NC_HEAD_RATE := 10.0            # rad/s the head layer moves toward its candidate
const NC_RELAX_S := 0.25
const NC_GAP_SNAP := 12.0             # a guest gap over this snaps (3 lost packets at 32 m/s)
# head clearance candidates, (pitch, yaw) in degrees; pitch positive toward the body's up
const NC_CANDS := [[0, 0], [20, 0], [40, 0], [60, 0], [80, 0], [-20, 0], [-40, 0], [20, 30], [20, -30], [0, 45], [0, -45]]
# ENV fallbacks (the helper's ENV table wins, section 2.8)
const NC_ENV_FALLBACK := {"fwd": 7.6, "up": 2.2, "half_w": 2.3, "chin": 1.53, "ride": 1.6, "neck_back": 3.5, "neck_below": 1.83,
	"sec_below": 0.89, "sec_up": 1.53, "sec_half_w": 2.24, "belly_want": 1.58, "roof_want": 2.23, "cheek_want": 2.33, "gap": 3.85}
static var _nc_script = null
static var _nc_tried := false
static var _nc_on_frame := -1
static var _nc_on_val := false
static var _nc_ca := -1               # the helper has count_as(): -1 unknown, 0 no, 1 yes
var _nc = null                        # the helper's mover state (NC.state), real centipedes only
var _nc_own_us := 0                   # this tick's own guard rays (the helper's calls time themselves)
var _nc_env: Dictionary = {}
var _nc_shadow := false               # the probe's loopback shadow puppet (meta "zonda_shadow")
var _nc_prev_node = null              # the path node it left last (ladder step 2)
var _nc_nn0 = null                    # _next_node before this tick
var _nc_fwd_hit: Dictionary = {}      # {"d", "n", "ms"} of the last FWD probe hit (pre-turn)
var _nc_jaw_unres := false
var _nc_jaw_unres_t := 0.0
var _nc_repath_ms := -100000
var _nc_repaths: Array = []           # [ms, position] of recent re-paths
var _nc_low_ms := -100000
var _nc_tick := 0
var _nc_rr := 0
var _nc_speed := 0.0                  # the pivot's speed last tick (m/s)
var _nc_last_pos := Vector3.ZERO
var _nc_att_acc := 0.0
var _nc_unres_acc := 0.0
var _nc_hold_t := 0.0
# the head clearance layer
var _nc_hp := 0.0                     # the layer's pitch and yaw now (radians)
var _nc_hy := 0.0
var _nc_app_p := 0.0                  # what is applied to head_offset_node right now
var _nc_app_y := 0.0
var _nc_ti := 0                       # the candidate the layer holds
var _nc_ci := 0                       # the candidate under test while searching
var _nc_searching := false
var _nc_cycle_n := 0
var _nc_cycle_best := 0
var _nc_cycle_best_d := -1.0
var _nc_ok_t := 0.0
var _nc_relax_i := -1
var _nc_jaw_ms := 0
# 7A squeeze
var _nc_cheek_ms := [-100000, -100000]
var _nc_squeeze_ms := -100000
var _nc_sq_dir := Vector3.ZERO        # the way it was heading when the squeeze began (no advance along it)
# puppets and shadows
var _nc_tp_applied := -1              # the teleport counter the body was last reset for
var _nc_snap_b = null                 # the host sample that last caused a gap snap
var _nc_ptick := 0


func _coop_roar_watch() -> void:
	# The far wander roar is drawn by the game's own base state (any hunting or wandering centipede more than
	# 250 m from the player), so no state of ours sees it. Count each one here, and the map's 4 Hz stream tells
	# every guest's puppet to roar too. (Only the attack state counted it before, and a lunge is never 250 m off.)
	var playing: bool = is_instance_valid(roar_wander_sfx) and roar_wander_sfx.playing
	if playing and not _coop_roar_was:
		set_meta("zonda_roar", int(get_meta("zonda_roar", 0)) + 1)
	_coop_roar_was = playing


func _coop_close_voice(delta: float) -> void:
	if _nc_shadow:
		return
	_coop_voice_cd -= delta
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree() or not visible:
		return
	var d: float = global_position.distance_to(c.global_position)
	# "closing" is judged over a quarter of a second, not one frame: 0.05 m a frame is 3 m/s at 60 fps and 12 m/s at
	# 240 fps, faster than the centipede walks, so on a fast PC the snarl (v4.8, "the evil ones make their sounds when
	# close") almost never played
	_coop_voice_win += delta
	if _coop_voice_win >= 0.25:
		_coop_voice_win = 0.0
		_coop_voice_closing = d < _coop_voice_prev - 0.3
		_coop_voice_prev = d
	if _coop_voice_cd > 0.0 or d > COOP_VOICE_RANGE or not _coop_voice_closing:
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


func update_body_visuals(delta: float) -> void:
	# no-clip A1 step 7: a guarded real centipede lays its trail from swept physics positions
	# (_nc_post), so the body only follows it here; everything else lays it as the game does
	if not coop_puppet and _nc != null and nc_enabled():
		if not is_inside_tree() or get_world_3d() == null:
			return
		if _previous_head_transforms_over_distance.is_empty():
			_previous_head_transforms_over_distance.push_front(create_historical_transform_for_head())
		for i in range(_body_sections.size()):
			update_body_section(delta, i)
		return
	super(delta)


func on_teeth_bite() -> void:
	if _nc_shadow:
		# a shadow never bites: the would-bite count only (B5), against the host's own knight
		_nc_would_bite()
		return
	set_meta("zonda_snaps", int(get_meta("zonda_snaps", 0)) + 1)      # every snap of the jaws (the sound audit counts them)
	if not CoopSync.in_session():
		var c0 = Game.climber
		var hit0: bool = is_instance_valid(c0) and c0.is_inside_tree() and global_position.distance_squared_to(c0.global_position) < 9.0
		super()
		if hit0:
			_nc_count_bite(c0)
		return

	# every snap of the jaws crunches, whoever it lands on (the base game does the same); it used
	# to play only when the bite hit this PC's own knight, so bites on teammates were silent
	chomp_sfx.play()
	if not is_instance_valid(Game.climber) or not Game.climber.is_inside_tree():
		return

	var from: Vector3 = global_position
	var dist_sq_to_climber: float = global_position.distance_squared_to(Game.climber.global_position)
	if coop_puppet:
		# no-clip B2b: the rendered head is 100 ms behind the host; the newest host sample counts too
		if nc_enabled():
			var lp = _nc_latest_pos()
			if lp is Vector3:
				var d2: float = (lp as Vector3).distance_squared_to(Game.climber.global_position)
				if d2 < dist_sq_to_climber:
					dist_sq_to_climber = d2
					from = lp
		if dist_sq_to_climber < 9.0:
			nc_note(_nc_kind(), "wbite")
	if dist_sq_to_climber < 9.0:
		if _nc_shadow:
			nc_note(_nc_kind(), "shadow_dmg")     # defensive (B5): unreachable, the test requires 0
			return
		last_dealt_damage_time = Time.get_ticks_msec()
		Game.climber.take_damage(75.0)
		Game.climber.additional_velocity_next_frame += from.direction_to(Game.climber.global_position) * 15.0
		Game.audio.play_player_was_bit()
		Game.climber.on_bit()
		if not coop_puppet:
			_nc_count_bite(Game.climber)


func _ready() -> void:
	_nc_shadow = has_meta("zonda_shadow")
	add_to_group("zonda_nc")                 # the noclip probe samples every centipede (B6)
	if _nc_shadow or CoopSync.is_guest():
		coop_puppet = true
		if not _nc_shadow:
			CoopSync.register_puppet(self)   # a shadow is registered nowhere (targeting, streams, unhooks)
		smooth_random_position = math_helpers.createRandomUnitVector3D()
		for section in range(15):
			spawn_body_section()
		spawn_body_section(true)
		if Game.active_balance_settings and Game.active_balance_settings.disable_centipedes:
			queue_free()
			return
		if _nc_shadow:
			_nc_mute()
		await get_tree().process_frame
		if not _nc_shadow:
			Game.register_centipede(self)
		original_global_position = global_position
		on_bio_lum_state_updated()
		if _nc_shadow:
			print("[CLIP] shadow centipede ready")
		else:
			print("[CoopSync] puppet centipede ready")
	else:
		super()


func set_state(state) -> void:
	if coop_puppet:
		return
	if state != null:
		var s = state.get_script()
		if CoopSync.in_session():
			if s == centipede_state_hunting:
				state = CoopHunting.new()
			elif s == centipede_state_attack:
				state = CoopAttack.new()
			elif s == centipede_state_wander_around_lore_point:
				state = CoopLore.new()
			elif s == centipede_state_wander:
				state = CoopWander.new()
		else:
			if coop_skin == 1 or nc_enabled():
				# solo pale centipede: the light-fear lunge guard and the sulk live in these two
				# (CoopSync's targeting falls back to the local knight when there is no session).
				# No-clip 7A: every skin while the guard is on, so a lunge that gave up at a squeeze
				# gets CoopHunting's 2.5 s wait (zonda_squeeze_until) instead of the game's instant re-lunge
				if s == centipede_state_hunting:
					state = CoopHunting.new()
				elif s == centipede_state_wander:
					state = CoopWander.new()
			if s == centipede_state_attack and nc_enabled():
				state = CoopAttack.new()     # no-clip A12: solo lunges get the lock, the LOS pair and the surface aim
	# no-clip: a path search in flight belongs to the state being left (its result goes to that state's object and is
	# thrown away), and until it ends every other request is dropped: end it now
	if state != null and _current_state != null and nc_enabled() and is_instance_valid(_pathfinder) and _pathfinder.has_method("nc_cancel"):
		if (state as Object).get_script() != (_current_state as Object).get_script():
			_pathfinder.call("nc_cancel")
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
	if not _nc_shadow:
		_coop_apply_cries(s)
	# no-clip B1/B2: element 8 is the host's teleport counter (0 from a host that does not send it)
	var tp: int = int(s[8]) if s.size() > 8 and (typeof(s[8]) == TYPE_INT or typeof(s[8]) == TYPE_FLOAT) else 0
	if _coop_buf.is_empty():
		global_position = p
		global_basis = Basis(q)
		_nc_tp_applied = tp
		_nc_snap_b = null
		if nc_enabled() or _nc_shadow:
			coop_reset_body()             # a new or re-shown puppet lays its body from here
	_coop_buf.push(sender_t, {"pos": p, "rot": q, "tp": tp})
	if att != _coop_attacking:
		_coop_attacking = att
		if att:
			if _coop_dummy_attack == null:
				_coop_dummy_attack = centipede_state_attack.new()
				_coop_dummy_attack.setup(self)
			_current_state = _coop_dummy_attack
			if not _nc_shadow:
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
	if _nc_shadow:
		return
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


func coop_note_hiss(cid: String, n: int) -> void:
	# the host's light-fear hiss counter from the map's "cr" stream (element 3), keyed by stable id.
	# A puppet handed a different creature starts counting afresh.
	if _nc_shadow:
		return
	if str(get_meta("zonda_hiss_cid", "")) != cid:
		set_meta("zonda_hiss_cid", cid)
		_coop_last_hiss = -1
	_coop_hiss_count(n)


func _coop_hiss_count(n: int) -> void:
	# the first value only seeds the counter; each change afterwards is one recoil on the host
	var r: Array = CoopShy.hiss_step(_coop_last_hiss, n)
	_coop_last_hiss = int(r[0])
	if bool(r[1]):
		_coop_rear_t = COOP_REAR_S
		_coop_play_hiss()


# ---------------------------------------------------------------- light-fear A (v5.0)

func _coop_light_fear(delta: float) -> void:
	# whoever runs the real centipede (host or solo), 10 Hz: a lantern beam on a pale head
	if coop_skin != 1:
		if has_meta("zonda_lit"):
			remove_meta("zonda_lit")
		return
	_coop_fear_cd = maxf(0.0, _coop_fear_cd - delta)
	_coop_fear_acc += delta
	if _coop_fear_acc < COOP_FEAR_DT:
		return
	var dt := _coop_fear_acc
	_coop_fear_acc = 0.0
	var lf = CoopSync.get("light_field")
	if lf == null or not is_instance_valid(lf) or not lf.has_method("beam_at") or not is_instance_valid(head_offset_node):
		_coop_heat = 0.0
		if has_meta("zonda_lit"):
			remove_meta("zonda_lit")
		return
	var b = lf.beam_at(head_offset_node.global_position, get_instance_id(), 0.9)
	var k := 0.0
	if b is Dictionary:
		k = float((b as Dictionary).get("k", 0.0))
	if k >= COOP_FEAR_K:
		set_meta("zonda_lit", true)
		_coop_heat = minf(1.0, _coop_heat + COOP_FEAR_RISE * k * dt)
	else:
		if has_meta("zonda_lit"):
			remove_meta("zonda_lit")
		_coop_heat = maxf(0.0, _coop_heat - COOP_FEAR_FALL * dt)
	if _coop_heat >= 1.0 and _coop_fear_cd <= 0.0 and not _coop_sulking() and b is Dictionary:
		_coop_heat = 0.0
		_coop_fear_cd = COOP_FEAR_CD
		_coop_recoil(b)


func _coop_sulking() -> bool:
	return Time.get_ticks_msec() < int(get_meta("zonda_sulk_until", 0))


func _coop_recoil(b: Dictionary) -> void:
	var now := Time.get_ticks_msec()
	var keep: Array = []
	for t in _coop_recoils:
		if now - int(t) < COOP_SULK_WINDOW_MS:
			keep.append(t)
	keep.append(now)
	_coop_recoils = keep
	set_meta("zonda_hiss", int(get_meta("zonda_hiss", 0)) + 1)
	_coop_rear_t = COOP_REAR_S
	stamina = maxf(0.0, stamina - 0.25)
	_coop_play_hiss()
	if _coop_recoils.size() >= COOP_SULK_N:
		# driven off three times: it gives up and slinks home for a while
		_coop_recoils.clear()
		set_meta("zonda_sulk_until", now + COOP_SULK_MS)
		set_state(centipede_state_wander.new())
		return
	var h = b.get("node", null)
	var holder: Node3D = h if (h is Node3D and is_instance_valid(h)) else null
	var e = b.get("eye", Vector3.ZERO)
	var d = b.get("dir", Vector3.ZERO)
	var eye: Vector3 = e if e is Vector3 else Vector3.ZERO
	var dir: Vector3 = d if d is Vector3 else Vector3.ZERO
	if eye == Vector3.ZERO and holder != null:
		eye = holder.global_position
	if _current_state != null and _current_state.get_script() == CoopShy:
		_current_state.call("restart", holder, eye, dir)    # a new hit restarts the recoil
		return
	var shy = CoopShy.new()
	shy.holder = holder
	shy.eye = eye
	shy.beam_dir = dir
	set_state(shy)


func _coop_play_hiss() -> void:
	# "pale_hiss" from the Underdark's sfx manifest (creatures.gd, loaded only when needed);
	# a missing kind stays silent
	if _nc_shadow:
		return
	if not _coop_creatures_tried:
		_coop_creatures_tried = true
		if ResourceLoader.exists(COOP_CREATURES):
			_coop_creatures_script = load(COOP_CREATURES)
		if _coop_creatures_script == null:
			push_warning("[CoopSync] creatures.gd not found: pale centipedes hiss silently")
	var C = _coop_creatures_script
	if C == null:
		return
	var os = C.call("oneshot", "pale_hiss")
	if not (os is Array) or (os as Array).size() < 2 or os[0] == null:
		return
	if not is_instance_valid(_coop_hiss_sfx):
		var parent: Node = head_offset_node if is_instance_valid(head_offset_node) else self
		_coop_hiss_sfx = C.call("make_player", parent, 0.0, 45.0)
	if is_instance_valid(_coop_hiss_sfx):
		C.call("play_stream", _coop_hiss_sfx, os[0], float(os[1]), COOP_HISS_PITCH)


func _coop_rear_undo() -> void:
	if _coop_rear_applied != 0.0 and is_instance_valid(head_offset_node):
		head_offset_node.rotate_object_local(Vector3.RIGHT, -_coop_rear_applied)
	_coop_rear_applied = 0.0


func _coop_rear_do(delta: float) -> void:
	# the recoil's rear-up: the head pitches up 0.7 rad and back over 0.6 s, on every machine
	if _coop_rear_t <= 0.0 or not is_instance_valid(head_offset_node):
		return
	_coop_rear_t = maxf(0.0, _coop_rear_t - delta)
	var k := clampf(1.0 - _coop_rear_t / COOP_REAR_S, 0.0, 1.0)
	var amt := maxf(0.0, COOP_REAR_RAD * sin(PI * pow(k, 0.6)))      # up fast (peak at 0.19 s), down slower
	head_offset_node.rotate_object_local(Vector3.RIGHT, amt)
	_coop_rear_applied = amt


func _process(delta: float) -> void:
	# two additive layers ride on top of whatever turns the head this frame: the recoil's rear-up and
	# the no-clip head clearance. Take last frame's off first, newest first (so the head's own slerp
	# never compounds them), then put this frame's on.
	_nc_head_undo()
	_coop_rear_undo()
	_coop_process_body(delta)
	_coop_rear_do(delta)
	_nc_head_do(delta)


func _coop_process_body(delta: float) -> void:
	if coop_puppet:
		var nc_on := nc_enabled() or _nc_shadow
		var s := _coop_buf.sample(NC_INTERP_DELAY_MS if nc_on else COOP_INTERP_DELAY_MS)
		if not s.is_empty():
			var a: Dictionary = s["a"]
			var b: Dictionary = s["b"]
			var k: float = s["alpha"]
			var pa: Vector3 = a["pos"]
			var pb: Vector3 = b["pos"]
			if nc_on:
				# B2: between host samples only, never past the newest; one snap per teleport or gap
				var pick: Array = nc_puppet_pick(a, b, k, _nc_tp_applied, _nc_snap_b)
				var mode: int = int(pick[0])
				if mode == 1 or mode == 2:
					global_position = pb
					global_basis = Basis(b["rot"])
					coop_reset_body()
					_nc_tp_applied = int(b.get("tp", 0))
					if mode == 2:
						_nc_snap_b = b
				elif mode == 3:
					global_position = pb
					global_basis = Basis(b["rot"])
				else:
					var k1: float = float(pick[1])
					global_position = pa.lerp(pb, k1)
					global_basis = Basis((a["rot"] as Quaternion).slerp(b["rot"], clampf(k1, 0.0, 1.0)))
			elif pa.distance_squared_to(pb) > 900.0:
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
		super._process(delta)
		return

	if _current_state:
		_current_state.tick(delta)
	update_body_visuals(delta)
	var target := CoopSync.target_player_for(self)
	_coop_process_common(delta, target.global_position if target else Vector3.ZERO, target != null)


static func nc_puppet_pick(a: Dictionary, b: Dictionary, k: float, tp_applied: int, snap_b) -> Array:
	# no-clip B2, the puppet's rule for the sample pair (a, b) around the render time:
	#   [1, 1.0] snap to b and reset the body once: the host's teleport counter changed
	#   [2, 1.0] snap to b and reset once: a gap over 12 m between two host samples (lost packets)
	#   [3, 1.0] hold at b: a pair that straddles a teleport or the gap already snapped (never glide it)
	#   [0, k]   interpolate, k clamped to 1 (no extrapolation: a late packet waits, it never overshoots)
	var ta: int = int(a.get("tp", 0))
	var tb: int = int(b.get("tp", 0))
	if tb != tp_applied:
		return [1, 1.0]
	if ta != tb:
		return [3, 1.0]
	var pa: Vector3 = a["pos"]
	var pb: Vector3 = b["pos"]
	if pa.distance_to(pb) > NC_GAP_SNAP:
		if snap_b != null and is_same(b, snap_b):
			return [3, 1.0]
		return [2, 1.0]
	return [0, minf(k, 1.0)]


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
		_coop_close_voice(delta)
		_nc_puppet_tick(delta)
		_nc_count_tick(delta)
		if _nc_shadow:
			return                      # B5: a shadow makes no sound and never shoves anyone
		if not idle_sfx.playing:
			idle_sfx.play()
		_coop_local_body_knockback()
		return

	_coop_close_voice(delta)
	_coop_roar_watch()
	_coop_light_fear(delta)

	var guard := nc_enabled()
	if guard:
		_nc_pre()
	var p0 := global_position

	if not CoopSync.in_session():
		super(delta)
		if guard:
			_nc_post(p0, delta)
		_nc_count_tick(delta)
		return

	if _current_state:
		_current_state.physics_tick(delta)
	if guard:
		_nc_post(p0, delta)
	_nc_count_tick(delta)

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
	# no-clip: a section hidden by a body reset waits at the head until the trail reaches it; it must
	# not shove anyone from there (only while the guard is on; today's code otherwise)
	var skip_hidden := nc_enabled()
	for body_sec in _body_sections:
		if body_sec and is_instance_valid(body_sec.root):
			if skip_hidden and not body_sec.root.visible:
				continue
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
		if nc_enabled():
			coop_teleport(teleport_location)       # A2: a declared teleport with a fresh body
		else:
			global_position = teleport_location
		start_hunting()


# ================================================================ creature no-clip (NC-2)

static func _nc_s():
	# the shared helper, loaded once at runtime (a missing file means today's behaviour)
	if not _nc_tried:
		_nc_tried = true
		if ResourceLoader.exists(NC_PATH):
			_nc_script = load(NC_PATH)
		if _nc_script == null:
			push_warning("[CLIP] noclip.gd missing: creatures move as before")
	return _nc_script


static func nc_enabled() -> bool:
	# NC.is_enabled(), cached per physics frame (it is asked many times a tick)
	var f := Engine.get_physics_frames()
	if f != _nc_on_frame:
		_nc_on_frame = f
		var NC = _nc_s()
		_nc_on_val = NC != null and bool(NC.call("is_enabled"))
	return _nc_on_val


static func nc_note(kind: String, key: String, n: int = 1) -> void:
	# a fairness / guard counter (the helper ignores it unless the probe is measuring)
	if n == 0:
		return
	var NC = _nc_s()
	if NC != null:
		NC.call("note", kind, key, n)


func nc():
	# the helper script (or null), for the state scripts and the pathfinder extension
	return _nc_s()


func nc_on() -> bool:
	return nc_enabled()


func nc_state():
	return _nc


func nc_env_value(key: String, dflt: float) -> float:
	return float(_nc_env_get().get(key, dflt))


func _nc_env_get() -> Dictionary:
	if _nc_env.is_empty():
		var e: Dictionary = NC_ENV_FALLBACK.duplicate()
		var NC = _nc_s()
		if NC != null:
			var d = NC.call("env", "centipede")
			if d is Dictionary:
				for k in (d as Dictionary).keys():
					e[k] = d[k]
		_nc_env = e
	return _nc_env


func _nc_cid() -> String:
	# the host's stable id: the map's meta on a real one, the streamed id on a puppet or a shadow
	return str(get_meta("zonda_cid", get_meta("zonda_puppet_cid", str(get_instance_id()))))


func _nc_kind() -> String:
	if _nc_cid().begins_with("follower"):
		return "follower"
	if coop_skin == 1:
		return "pale"
	return "centipede"


func _nc_space() -> PhysicsDirectSpaceState3D:
	if not is_inside_tree() or get_world_3d() == null:
		return null
	return get_world_3d().direct_space_state


func _nc_ray(space, a: Vector3, b: Vector3) -> Dictionary:
	# one of this centipede's own guard rays (posture, head layer, ladder): timed for the cost report
	var NC = _nc_s()
	if NC == null or space == null:
		return {}
	var t0 := Time.get_ticks_usec()
	var r = NC.call("ray", space, a, b)
	_nc_own_us += Time.get_ticks_usec() - t0
	return r if r is Dictionary else {}


static func nc_count_as(kind: String) -> String:
	# the helper counts rays cast outside its own calls under this kind (returns the previous one)
	var NC = _nc_s()
	if NC == null:
		return ""
	if _nc_ca < 0:
		_nc_ca = 1 if NC.has_method("count_as") else 0
	if _nc_ca != 1:
		return ""
	return str(NC.call("count_as", kind))


func _nc_own_report(kind: String) -> void:
	# this tick's own ray time goes to the helper's usec counter (and CoopSync.perf_add through it)
	if _nc_own_us <= 0:
		return
	var NC = _nc_s()
	if NC != null:
		NC.call("add_usec", kind, _nc_own_us)
	_nc_own_us = 0


func _nc_mute() -> void:
	# a shadow is silent: every player under it (footsteps included) at -80 dB
	for a in find_children("*", "AudioStreamPlayer3D", true, false):
		(a as AudioStreamPlayer3D).volume_db = -80.0
	for a in find_children("*", "AudioStreamPlayer", true, false):
		(a as AudioStreamPlayer).volume_db = -80.0


func _nc_is_path_state() -> bool:
	var st = _current_state
	if st == null or not (st is centipede_state_follow_path):
		return false
	if st.get_script() == CoopShy:
		return int(st.get("phase")) == CoopShy.CIRCLE
	return true


func _nc_squeezed() -> bool:
	return Time.get_ticks_msec() - _nc_squeeze_ms < NC_SQUEEZE_MS


func _nc_into_dir() -> Vector3:
	# the way it is heading into a squeeze: toward the next path node (a path state moves straight at
	# it), else the body's forward (a lunge)
	var st = _current_state
	if st is centipede_state_follow_path:
		var nn = st.get("_next_node")
		if nn != null:
			var d: Vector3 = nn.position - global_position
			if d.length() > 0.01:
				return d.normalized()
	var f := -global_basis.z
	return f.normalized() if f.length() > 0.001 else Vector3.ZERO


func _nc_vis_points() -> Array:
	# what a viewer would see of it: the head pivot and the pivots of sections 0, 3, 7, 11, 15
	var out: Array = [global_position]
	for i in [0, 3, 7, 11, 15]:
		if i < _body_sections.size():
			var sec = _body_sections[i]
			if sec != null and is_instance_valid(sec.root) and sec.root.visible:
				out.append(sec.root.global_position)
	return out


func _nc_seen() -> bool:
	var NC = _nc_s()
	if NC == null:
		return false
	return bool(NC.call("seen_by_any", _nc_vis_points(), 150.0))


# ---------------------------------------------------------------- A2: teleports and the body

func coop_reset_body() -> void:
	# the body after a teleport: no trail, every section hidden at the head, the leg goals with it.
	# The sections reappear one by one as the head lays a new trail (a section whose history point
	# is ZERO hides), exactly like the game's own spawn.
	_previous_head_transforms_over_distance.clear()
	_cached_ht_prev_to_loc_distance.clear()
	_coop_step_last.clear()
	for sec in _body_sections:
		if sec == null or not is_instance_valid(sec.root):
			continue
		sec.root.global_position = global_position
		sec.root.visible = false
		if is_instance_valid(sec.leg1_goal_node):
			sec.leg1_goal_node.global_position = global_position
		if is_instance_valid(sec.leg2_goal_node):
			sec.leg2_goal_node.global_position = global_position
		sec.leg1_target_foot_position = global_position
		sec.leg2_target_foot_position = global_position


func coop_teleport(p: Vector3, anchor = null) -> void:
	# host / solo only (a puppet ignores it). Callers check NC.seen_by_any first (the repair ladder,
	# the map's leash), except spawns and scripted test hooks. The streamed counter makes guests snap.
	if coop_puppet:
		return
	var p2 := p
	var NC = _nc_s()
	var space := _nc_space()
	if NC != null and space != null and nc_enabled():
		if _nc == null:
			_nc_env_get()
			_nc = NC.call("state", _nc_kind(), p, {"lead": 0.6, "anchor": anchor if anchor is Vector3 else get_meta("zonda_anchor", p)})
		var r = NC.call("place", space, _nc, p, anchor)
		if r is Vector3:
			p2 = r
	global_position = p2
	if _nc != null:
		_nc["last"] = p2
	_nc_last_pos = p2
	coop_reset_body()
	set_meta("zonda_tp", int(get_meta("zonda_tp", 0)) + 1)
	_nc_prev_node = null
	_nc_drop_path()


func _nc_drop_path() -> void:
	# a path state re-paths from where it is now (the game's follow_path calls reached_end_of_path)
	var st = _current_state
	if st is centipede_state_follow_path:
		var path = st.get("_path")
		if path is Array:
			(path as Array).clear()
		st.set("_next_node", null)
		st.set("_end_of_path_reached", false)


# ---------------------------------------------------------------- A1: the per-tick guard

func _nc_pre() -> void:
	var NC = _nc_s()
	var space := _nc_space()
	if NC == null or space == null:
		return
	if _nc == null:
		_nc_env_get()
		var anchor = get_meta("zonda_anchor", global_position)
		_nc = NC.call("state", _nc_kind(), global_position, {"lead": 0.6, "anchor": anchor})
		if not (_nc is Dictionary):
			_nc = null
			return
		var r = NC.call("place", space, _nc, global_position, anchor)
		if r is Vector3:
			global_position = r
		_nc["last"] = global_position
		_nc_last_pos = global_position
	else:
		var last = _nc.get("last", global_position)
		if last is Vector3 and global_position.distance_squared_to(last) > 1e-8:
			# something outside the tick moved the head (start_hunting's snap, the map's direct sets)
			if global_position.distance_to(last) > NC_TP_JUMP:
				coop_teleport(global_position)
			else:
				var before := global_position
				var r2 = NC.call("move", space, _nc, global_position)
				if r2 is Vector3:
					global_position = r2
					if global_position.distance_squared_to(before) > 1e-8:
						original_global_position = global_position
	_nc_nn0 = _current_state.get("_next_node") if _current_state is centipede_state_follow_path else null


func _nc_post(p0: Vector3, delta: float) -> void:
	var NC = _nc_s()
	var space := _nc_space()
	if NC == null or space == null or _nc == null:
		return
	var kind := _nc_kind()
	var prev_kind := nc_count_as(kind)
	_nc_post_inner(NC, space, kind, p0, delta)
	if _nc_ca == 1:
		nc_count_as(prev_kind)
	_nc_own_report(kind)


func _nc_post_inner(NC, space, kind: String, p0: Vector3, delta: float) -> void:
	var now := Time.get_ticks_msec()
	# 1. teleport check: nothing in a tick moves 3 m (the fastest legal speed is 32 m/s)
	if p0.distance_to(global_position) > NC_TP_JUMP:
		coop_teleport(global_position)
		_nc_speed = 0.0
		return
	var path_state := _nc_is_path_state()
	var attack_state: bool = _current_state is centipede_state_attack
	# 2. the forward floor: the only slowdown. 50% while no head candidate clears (a concave corner).
	# 7A: while squeezed (a roof with no room under it, or both cheeks) a path state makes NO advance
	# deeper into the gap, whatever the jaw says (under a flat low lip the forward jaw ray is clear);
	# turning back out of it stays free, so the repair ladder can lead it away
	if path_state and (_nc_jaw_unres or _nc_squeezed()):
		var adv := global_position - p0
		if _nc_squeezed() and _nc_sq_dir != Vector3.ZERO:
			var into := adv.dot(_nc_sq_dir)
			if into > 0.0:
				adv -= _nc_sq_dir * into
		if _nc_jaw_unres:
			adv *= 0.5
		global_position = p0 + adv
	# 7A in a lunge: at a gap narrower than the head it holds at the opening, then gives up
	if attack_state and _nc_squeezed():
		global_position = p0
		_nc_hold_t += delta
		if _nc_hold_t >= NC_SQUEEZE_GIVEUP_S:
			_nc_hold_t = 0.0
			nc_note(kind, "abort_squeeze")
			set_meta("zonda_squeeze_until", now + NC_SQUEEZE_WAIT_MS)
			set_state(centipede_state_hunting.new())
			path_state = _nc_is_path_state()
			attack_state = false
	else:
		_nc_hold_t = maxf(0.0, _nc_hold_t - delta)
	# 3. turn assist and pre-turn (rotation only; the pivot's path is untouched)
	if path_state:
		_nc_turn_assist(delta)
		_nc_pre_turn(delta)
	# 4. the swept move
	var r = NC.call("move", space, _nc, global_position)
	if r is Vector3:
		global_position = r
	if int(_nc.get("stall_n", 0)) >= NC_STALL_TICKS:
		_nc_stall("wall")
	# 5. node switch: one line check to the new node; a blocked one is repaired (skip or back), never re-pathed
	if path_state and _current_state is centipede_state_follow_path:
		var nn = _current_state.get("_next_node")
		if nn != null and nn != _nc_nn0:
			_nc_prev_node = _nc_nn0
			if not _nc_ray(space, global_position, nn.position).is_empty():
				_nc_stall("node")
	# 6. one posture probe, tiered
	_nc_posture(space, NC, int(_nc.get("tier", NC_FULL)), path_state, attack_state)
	# jaw unresolved for 1 s in a path state: the ladder (the node after next, the previous one first)
	if _nc_jaw_unres:
		_nc_jaw_unres_t += delta
		if path_state and _nc_jaw_unres_t >= NC_JAW_STALL_S:
			_nc_jaw_unres_t = 0.0
			_nc_stall("jaw")
	# 7. trail crumbs from swept positions only (a FAR-tier chord that was never swept lays none)
	var good = _nc.get("good")
	if good is Vector3 and global_position.distance_squared_to(good) < 1e-6:
		var h := _previous_head_transforms_over_distance
		if h.is_empty() or h[0].position.distance_squared_to(global_position) > historical_transform_min_dist * historical_transform_min_dist:
			h.push_front(create_historical_transform_for_head())
			if h.size() > 200:
				h.pop_back()
	# 9. recovery: an unverified seed that turned out to be in rock, only while nobody sees it
	if bool(_nc.get("need_rec", false)):
		var rp = NC.call("try_recover", space, _nc, _nc_vis_points(), {"head": float(_nc_env_get().get("gap", 3.85))})
		if rp is Vector3:
			global_position = _nc.get("good", rp)
			_nc["last"] = global_position
			coop_reset_body()
			set_meta("zonda_tp", int(get_meta("zonda_tp", 0)) + 1)
			_nc_prev_node = null
			_nc_drop_path()
	_nc["last"] = global_position
	_nc_speed = p0.distance_to(global_position) / maxf(delta, 0.0001)


func _nc_count_tick(delta: float) -> void:
	# 8. counters (A13), in both Rule K branches: the probe compares a guarded run with a baseline
	if not coop_puppet:
		if _current_state is centipede_state_attack:
			_nc_att_acc += delta * 1000.0
			var n := int(_nc_att_acc)
			if n > 0:
				_nc_att_acc -= float(n)
				nc_note(_nc_kind(), "att_ms", n)
		if _nc_jaw_unres and _nc != null:
			_nc_unres_acc += delta * 1000.0
			var m := int(_nc_unres_acc)
			if m > 0:
				_nc_unres_acc -= float(m)
				nc_note(_nc_kind(), "jaw_unres_ms", m)
		return
	if _nc_shadow and _coop_attacking:
		_nc_att_acc += delta * 1000.0
		var n2 := int(_nc_att_acc)
		if n2 > 0:
			_nc_att_acc -= float(n2)
			nc_note(_nc_kind(), "shadow_att_ms", n2)


func _nc_count_bite(c) -> void:
	# a bite that dealt damage (host and solo): "bites", and "bites_clean" when the line from the head
	# to the capsule centre is clear (a bite through rock in today's build is not danger lost)
	var kind := _nc_kind()
	nc_note(kind, "bites")
	var space := _nc_space()
	if space != null and is_instance_valid(c) and _nc_s() != null and _nc_ray(space, global_position, c.global_position).is_empty():
		nc_note(kind, "bites_clean")


func _nc_latest_pos():
	var l = _coop_buf.latest()
	if l is Dictionary and (l as Dictionary).get("pos") is Vector3:
		return l["pos"]
	return null


func _nc_would_bite() -> void:
	# B2b / B5: the distance a guest's puppet would bite at (the nearer of the rendered head and the
	# newest host sample) against this PC's own knight; counted, nothing else
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var d2: float = global_position.distance_squared_to(c.global_position)
	var lp = _nc_latest_pos()
	if lp is Vector3:
		d2 = minf(d2, (lp as Vector3).distance_squared_to(c.global_position))
	if d2 < 9.0:
		nc_note(_nc_kind(), "wbite")


func _nc_lookahead(st, dist: float) -> Vector3:
	# the point dist metres along the path from the head (through _next_node, then _path[0], ...)
	var prev := global_position
	var left := dist
	var pts: Array = []
	var nn = st.get("_next_node")
	if nn != null:
		pts.append(nn.position)
	var path = st.get("_path")
	if path is Array:
		for i in mini((path as Array).size(), 8):
			var n = path[i]
			if n != null:
				pts.append(n.position)
	for p in pts:
		var seg: float = prev.distance_to(p)
		if seg >= left and seg > 0.0001:
			return prev + (p - prev) * (left / seg)
		left -= seg
		prev = p
	return prev


func _nc_turn_assist(delta: float) -> void:
	# an extra slerp toward the path 6 m ahead (0.4 on top of the game's 0.2): the pathfinder's zig-zags
	# are smoothed instead of slowed for
	var st = _current_state
	var nn = st.get("_next_node")
	if nn == null:
		return
	var la := _nc_lookahead(st, 6.0)
	var dir := la - global_position
	var up: Vector3 = nn.normal
	if dir.length() < 0.05 or up.length() < 0.5:
		return
	if absf(dir.normalized().dot(up.normalized())) > 0.9816:
		return                          # within 11 degrees of the surface normal
	var spd := 0.0
	if st.has_method("get_path_follow_speed"):
		spd = float(st.call("get_path_follow_speed"))
	var w := clampf(spd * delta * 0.4, 0.0, 1.0)
	if w <= 0.0:
		return
	var want := Basis.looking_at(dir.normalized(), up.normalized()).get_rotation_quaternion()
	global_rotation = global_basis.get_rotation_quaternion().slerp(want, w).get_euler()


func _nc_pre_turn(delta: float) -> void:
	# a wall ahead (the FWD probe, under 0.2 s old): the body starts to rear onto it before it gets there
	if _nc_fwd_hit.is_empty() or Time.get_ticks_msec() - int(_nc_fwd_hit.get("ms", 0)) > 200:
		return
	var n: Vector3 = _nc_fwd_hit["n"]
	var d: float = float(_nc_fwd_hit["d"])
	var jaw_len: float = float(_nc_env_get()["fwd"]) + minf(3.0, 0.15 * _nc_speed)
	var fwd := -global_basis.z.normalized()
	var tgt := fwd - n * fwd.dot(n)
	if tgt.length() < 0.1:
		var up := global_basis.y.normalized()
		tgt = up - n * up.dot(n)        # straight at the wall: climb it along the body's up
	if tgt.length() < 0.05 or absf(tgt.normalized().dot(n)) > 0.98:
		return
	var w := clampf(6.0 * (1.0 - d / maxf(jaw_len, 0.1)) * delta, 0.0, 1.0)
	if w <= 0.0:
		return
	var want := Basis.looking_at(tgt.normalized(), n).get_rotation_quaternion()
	global_rotation = global_basis.get_rotation_quaternion().slerp(want, w).get_euler()


func _nc_posture(space, NC, tier: int, path_state: bool, attack_state: bool) -> void:
	# one probe per tick: JAW on even ticks, then FWD, BELLY, ROOF, CHEEK L, CHEEK R in turn (FULL);
	# one of the six every 4th tick (NEAR); none past 150 m (FAR) or where rock is not loaded (OFF)
	_nc_tick += 1
	var slot := -1
	if tier >= NC_FULL:
		if _nc_tick % 2 == 0:
			slot = 0
		else:
			slot = 1 + (_nc_rr % 5)
			_nc_rr += 1
	elif tier == NC_NEAR:
		if _nc_tick % 4 == 0:
			slot = _nc_rr % 6
			_nc_rr += 1
	else:
		# FAR / OFF: no head probes, so no stale "unresolved" may keep slowing it down
		if _nc_jaw_unres:
			_nc_jaw_unres = false
			_nc_jaw_unres_t = 0.0
	if slot < 0:
		return
	var env := _nc_env_get()
	var pos := global_position
	var up := global_basis.y.normalized()
	var right := global_basis.x.normalized()
	var fwd := -global_basis.z.normalized()
	var now := Time.get_ticks_msec()
	match slot:
		0:
			_nc_jaw_probe(space, NC)
		1:
			var jaw_len: float = float(env["fwd"]) + minf(3.0, 0.15 * _nc_speed)
			var h := _nc_ray(space, pos, pos + fwd * jaw_len)
			if not h.is_empty():
				_nc_fwd_hit = {"d": float(h.get("d", 0.0)), "n": h.get("normal", -fwd), "ms": now}
		2:
			# BELLY: lift the head just enough that the chin clears a bump or a convex lip
			var r = NC.call("clearance", space, _nc, pos, -up, float(env["belly_want"]))
			if r is Vector3:
				global_position = r
		3:
			var roof_want: float = float(env["roof_want"])
			var h3 := _nc_ray(space, pos, pos + up * (roof_want + 0.1))
			if not h3.is_empty() and float(h3.get("d", 0.0)) < roof_want:
				var push: float = roof_want - float(h3.get("d", 0.0))
				if _nc_ray(space, pos, pos - up * (float(env["belly_want"]) + push)).is_empty():
					# pushed down through clearance (a swept push from good, never into other rock)
					var r3 = NC.call("clearance", space, _nc, pos, up, roof_want)
					if r3 is Vector3:
						global_position = r3
				else:
					_nc_squeeze(path_state, attack_state, "roof")      # no room under the rock: a squeeze
		4, 5:
			var side: Vector3 = -right if slot == 4 else right
			var want: float = float(env["cheek_want"])
			var h4 := _nc_ray(space, pos, pos + side * want)
			if not h4.is_empty():
				_nc_cheek_ms[slot - 4] = now
				var r4 = NC.call("clearance", space, _nc, pos, side, want)
				if r4 is Vector3:
					global_position = r4
				if absi(int(_nc_cheek_ms[0]) - int(_nc_cheek_ms[1])) <= NC_CHEEK_PAIR_MS:
					_nc_squeeze(path_state, attack_state, "cheeks")    # a gap narrower than the head


func _nc_squeeze(path_state: bool, attack_state: bool, why: String) -> void:
	# 7A: the head does not fit here. A path state stops advancing into the gap (_nc_post step 2) and
	# repairs (at most every 0.5 s): back to the node it left, else a re-path, never a skip deeper in;
	# a lunge holds at the opening (_nc_post) and gives up
	var now := Time.get_ticks_msec()
	if not _nc_squeezed() or _nc_sq_dir == Vector3.ZERO:
		_nc_sq_dir = _nc_into_dir()       # a fresh squeeze: the way in (kept while it lasts, so backing out is free)
	_nc_squeeze_ms = now
	nc_note(_nc_kind(), "squeeze_" + why)
	if path_state and now - _nc_low_ms >= NC_LOW_STALL_MS:
		_nc_low_ms = now
		_nc_stall("low")


func _nc_jaw_probe(space, NC) -> void:
	# A1b: one ray from the pivot along the candidate under test, jaw_len = ENV.fwd + a speed lead
	if space == null or NC == null or not is_instance_valid(head_offset_node):
		return
	var now := Time.get_ticks_msec()
	var dt: float = clampf(float(now - _nc_jaw_ms) / 1000.0, 0.0, 0.25) if _nc_jaw_ms > 0 else 0.0
	_nc_jaw_ms = now
	var fwd_len: float = float(_nc_env_get()["fwd"]) + minf(3.0, 0.15 * _nc_speed)
	var base := _nc_head_base()
	var n := NC_CANDS.size()
	var mode := 0
	var test_i := _nc_ti
	if _nc_searching:
		mode = 1
		test_i = _nc_ci
	elif _nc_relax_i >= 0:
		mode = 2
		test_i = _nc_relax_i
	var dir := _nc_cand_dir(base, test_i)
	var origin := global_position
	var hit := _nc_ray(space, origin, origin + dir * fwd_len)
	var clear := hit.is_empty()
	var d: float = fwd_len if clear else float(hit.get("d", 0.0))
	var r: Array = nc_jaw_step(mode, test_i, clear, d, dt, _nc_ti, _nc_ci, _nc_cycle_n, _nc_cycle_best, _nc_cycle_best_d, _nc_ok_t, n)
	_nc_ti = int(r[0])
	_nc_ci = int(r[1])
	_nc_searching = bool(r[2])
	_nc_cycle_n = int(r[3])
	_nc_cycle_best = int(r[4])
	_nc_cycle_best_d = float(r[5])
	_nc_ok_t = float(r[6])
	_nc_relax_i = int(r[7])
	var unres: int = int(r[8])
	if unres == 1:
		if not _nc_jaw_unres:
			_nc_jaw_unres_t = 0.0
		_nc_jaw_unres = true
	elif unres == 0:
		_nc_jaw_unres = false
		_nc_jaw_unres_t = 0.0


static func nc_jaw_step(mode: int, test_i: int, clear: bool, d: float, dt: float, ti: int, ci: int, cycle_n: int,
		best: int, best_d: float, ok_t: float, n: int) -> Array:
	# the head layer's search, as a pure step (unit-tested headless). mode 0 = the held candidate,
	# 1 = searching, 2 = relaxing toward neutral. Returns
	# [ti, ci, searching, cycle_n, best, best_d, ok_t, relax_i, unres] with unres 1 = no candidate cleared
	# a full cycle, 0 = one cleared, -1 = unchanged.
	var searching := mode == 1
	var relax_i := -1
	var unres := -1
	if mode == 0:
		if clear:
			ok_t += dt
			unres = 0
			if ok_t >= NC_RELAX_S and ti != 0:
				relax_i = 0
		else:
			ok_t = 0.0
			searching = true
			cycle_n = 1
			best = ti
			best_d = d
			ci = (ti + 1) % n
	elif mode == 1:
		if clear:
			ti = test_i
			searching = false
			ok_t = 0.0
			cycle_n = 0
			best_d = -1.0
			unres = 0
		else:
			if d > best_d:
				best_d = d
				best = test_i
			cycle_n += 1
			if cycle_n >= n:
				unres = 1
				ti = best
				cycle_n = 0
				best_d = -1.0
			ci = (test_i + 1) % n
	else:
		if clear:
			ti = test_i
			ok_t = 0.0
			unres = 0
		elif test_i == 0 and ti > 1:
			relax_i = ti - 1
		else:
			ok_t = 0.0
	return [ti, ci, searching, cycle_n, best, best_d, ok_t, relax_i, unres]


func _nc_head_base() -> Basis:
	# head_offset_node's pose with this layer's rotation taken off (the look and the rear-up stay)
	var b := head_offset_node.global_basis
	if _nc_app_y != 0.0:
		b = b * Basis(Vector3.UP, -_nc_app_y)
	if _nc_app_p != 0.0:
		b = b * Basis(Vector3.RIGHT, -_nc_app_p)
	return b


static func _nc_cand_dir(base: Basis, i: int) -> Vector3:
	var c: Array = NC_CANDS[i]
	var b2: Basis = base * Basis(Vector3.RIGHT, deg_to_rad(float(c[0]))) * Basis(Vector3.UP, deg_to_rad(float(c[1])))
	return (-b2.z).normalized()


func _nc_head_undo() -> void:
	if not is_instance_valid(head_offset_node):
		return
	if _nc_app_y != 0.0:
		head_offset_node.rotate_object_local(Vector3.UP, -_nc_app_y)
	if _nc_app_p != 0.0:
		head_offset_node.rotate_object_local(Vector3.RIGHT, -_nc_app_p)
	_nc_app_p = 0.0
	_nc_app_y = 0.0


func _nc_head_do(delta: float) -> void:
	# the layer moves toward the held candidate at 10 rad/s (back to neutral once the guard is off)
	if not is_instance_valid(head_offset_node):
		return
	var tp := 0.0
	var ty := 0.0
	if nc_enabled() or _nc_shadow:
		var c: Array = NC_CANDS[clampi(_nc_ti, 0, NC_CANDS.size() - 1)]
		tp = deg_to_rad(float(c[0]))
		ty = deg_to_rad(float(c[1]))
	var step := NC_HEAD_RATE * delta
	_nc_hp = move_toward(_nc_hp, tp, step)
	_nc_hy = move_toward(_nc_hy, ty, step)
	if _nc_hp == 0.0 and _nc_hy == 0.0:
		return
	head_offset_node.rotate_object_local(Vector3.RIGHT, _nc_hp)
	head_offset_node.rotate_object_local(Vector3.UP, _nc_hy)
	_nc_app_p = _nc_hp
	_nc_app_y = _nc_hy


func _nc_puppet_tick(delta: float) -> void:
	# puppets and shadows: the head layer only, at 30 Hz, near the local player and on loaded rock
	_nc_ptick += 1
	if _nc_ptick % 4 != 0:
		return
	var moved: float = global_position.distance_to(_nc_last_pos)
	_nc_last_pos = global_position
	if not nc_enabled() and not _nc_shadow:
		return
	var NC = _nc_s()
	var c = Game.climber
	if NC == null or not is_instance_valid(c) or not c.is_inside_tree() or not visible:
		return
	if global_position.distance_to(c.global_position) > 60.0:
		return
	if not bool(NC.call("solid_at", global_position, 8.0)):
		return
	_nc_speed = moved / maxf(delta * 4.0, 0.0001)
	var kind := _nc_kind()
	var prev_kind := nc_count_as(kind)
	_nc_jaw_probe(_nc_space(), NC)
	if _nc_ca == 1:
		nc_count_as(prev_kind)
	_nc_own_report(kind)


func coop_nc_rebind() -> void:
	# B3: a puppet re-shown or handed to a new id starts clean (buffer, snap latches, body)
	if not coop_puppet or not (nc_enabled() or _nc_shadow):
		return
	_coop_buf.clear()
	_nc_tp_applied = -1
	_nc_snap_b = null
	coop_reset_body()


# ---------------------------------------------------------------- the repair ladder

func _nc_stall(why: String) -> void:
	# why: "wall" (0.3 s of refused ticks), "node" (the line to a new node is blocked), "jaw" (no head
	# candidate for 1 s), "low" (a squeeze: roof with no room under it, or both cheeks)
	if _nc != null:
		_nc["stall_n"] = 0
	var st = _current_state
	if st == null:
		return
	var kind := _nc_kind()
	if st is centipede_state_attack:
		# a lunge never repairs: a stuck one (refused and not advancing for 0.3 s) ends
		if why == "wall":
			nc_note(kind, "abort_stall")
			set_state(centipede_state_hunting.new())
		return
	if st.has_method("coop_blocked") and not _nc_is_path_state():
		st.call("coop_blocked", why)          # CoopShy RECOIL / BACKOFF
		return
	if not (st is centipede_state_follow_path):
		return
	var space := _nc_space()
	if space == null:
		return
	var path = st.get("_path")
	var nn = st.get("_next_node")
	# the rays are cast lazily, in ladder order: skip first, then back (a squeeze never skips: 7A)
	var skip_ok: bool = why != "low" and path is Array and (path as Array).size() > 0 and path[0] != null and _nc_ray(space, global_position, path[0].position).is_empty()
	var back_ok := false
	if not skip_ok:
		back_ok = _nc_prev_node != null and _nc_prev_node != nn and _nc_ray(space, global_position, _nc_prev_node.position).is_empty()
	var now := Time.get_ticks_msec()
	match nc_ladder_pick(why, skip_ok, back_ok, now, _nc_repath_ms):
		"skip":
			# 1. the node after next, when the line to it is clear
			st.set("_next_node", (path as Array).pop_front())
			nc_note(kind, "skips")
		"back":
			# 2. the node it left (its leg to the next node was checked by the pathfinder)
			if nn != null and path is Array:
				(path as Array).push_front(nn)
			st.set("_next_node", _nc_prev_node)
			_nc_prev_node = null
			nc_note(kind, "backs")
		"repath":
			# 3. a re-path, at most once per 2 s (otherwise it keeps sliding and waits)
			_nc_repath_ms = now
			_nc_drop_path()
			var keep: Array = []
			for e in _nc_repaths:
				if now - int(e[0]) < NC_ESCALATE_WINDOW_MS:
					keep.append(e)
			keep.append([now, global_position])
			_nc_repaths = keep
			# 4. escalate: 3 re-paths in 15 s with under 5 m of progress; a recovery only while unseen
			if nc_should_escalate(_nc_repaths, global_position):
				if _nc_seen():
					nc_note(kind, "stuck_seen")
					return
				var NC = _nc_s()
				var p = NC.call("recover", space, _nc, {"min_back": 10.0}) if NC != null and _nc != null else null
				if p is Vector3:
					nc_note(kind, "escalations")
					_nc_repaths.clear()
					coop_teleport(p)


static func nc_ladder_pick(why: String, skip_ok: bool, back_ok: bool, now: int, last_repath_ms: int) -> String:
	# the repair ladder's order (issue 5): "skip", else "back", else (not for a node switch) a
	# "repath" at most every 2 s, else "wait" (keep sliding); a node switch never re-paths ("none").
	# A squeeze ("low", 7A) never skips: the node after next lies deeper in the gap it does not fit,
	# so it goes back, else re-paths
	if skip_ok and why != "low":
		return "skip"
	if back_ok:
		return "back"
	if why == "node":
		return "none"
	if now - last_repath_ms < NC_REPATH_MS:
		return "wait"
	return "repath"


static func nc_should_escalate(repaths: Array, pos: Vector3) -> bool:
	# 3 re-paths within the 15 s window, and the head under 5 m from where the first of them started
	if repaths.size() < NC_ESCALATE_N:
		return false
	var first = repaths[0]
	if not (first is Array) or (first as Array).size() < 2 or not (first[1] is Vector3):
		return false
	return pos.distance_to(first[1]) < NC_ESCALATE_PROGRESS


# ---------------------------------------------------------------- B6: test points and hooks

func noclip_points() -> Array:
	# section 5.2: one entry for this centipede (the probe counts crossings, embeds, rods and pops)
	if not is_inside_tree() or not is_instance_valid(head_offset_node):
		return []
	var env := _nc_env_get()
	var up := global_basis.y.normalized()
	var right := global_basis.x.normalized()
	var back := global_basis.z.normalized()
	var jaw_dir := (-head_offset_node.global_basis.z).normalized()
	var piv := global_position
	var c: Array = [piv]
	var cn: Array = ["head"]
	var seg: Array = [-1]
	for i in [0, 3, 7, 11, 15]:
		if i < _body_sections.size():
			var sec = _body_sections[i]
			if sec != null and is_instance_valid(sec.root) and sec.root.is_visible_in_tree():
				c.append(sec.root.global_position)
				cn.append("body#%d" % i)
				seg.append(i)
	var x: Array = [piv + jaw_dir * float(env["fwd"]), piv + up * float(env["up"]), piv - right * float(env["half_w"]),
			piv + right * float(env["half_w"]), piv - up * float(env["chin"])]
	var xn: Array = ["jaw", "top", "cheek", "cheek", "chin"]
	var xc: Array = [0, 0, 0, 0, 0]
	var xg: Array = [false, false, false, false, false]
	for ci in range(1, c.size()):
		var sec2 = _body_sections[int(seg[ci])]
		x.append(sec2.root.global_position - sec2.root.global_basis.y.normalized() * float(env["sec_below"]))
		xn.append("belly#%d" % int(seg[ci]))
		xc.append(ci)
		xg.append(false)
	# GRAZE-only: the root neck's bottom and the knees of sections 0, 7 and 15
	x.append(piv + back * float(env["neck_back"]) - up * float(env["neck_below"]))
	xn.append("neck")
	xc.append(0)
	xg.append(true)
	for ki in [0, 7, 15]:
		if ki >= _body_sections.size():
			continue
		var s3 = _body_sections[ki]
		if s3 == null or not is_instance_valid(s3.root) or not s3.root.is_visible_in_tree():
			continue
		for leg in [s3.leg1, s3.leg2]:
			if not is_instance_valid(leg):
				continue
			var skel := leg.get_node_or_null("Armature/Skeleton3D") as Skeleton3D
			if skel == null or skel.get_bone_count() < 2:
				continue
			x.append(skel.global_transform * skel.get_bone_global_pose(1).origin)
			xn.append("leg")
			xc.append(maxi(0, seg.find(ki)))
			xg.append(true)
	var view := "shadow" if _nc_shadow else ("guest" if coop_puppet else "host")
	var st := "idle"
	var fx := {}
	if coop_puppet:
		if _coop_attacking:
			st = "attack"
	else:
		var cs = _current_state
		if cs is centipede_state_attack:
			st = "attack"
		elif cs != null and cs.get_script() == CoopShy:
			st = "shy"
		elif cs is centipede_state_follow_path:
			st = "path"
		var nn = cs.get("_next_node") if cs is centipede_state_follow_path else null
		var want_v := 0.0
		if nn != null and cs.has_method("get_path_follow_speed"):
			want_v = float(cs.call("get_path_follow_speed"))
		fx = {"tgt_d": CoopSync.target_player_distance(self, 999.9), "want_v": want_v, "has_next": nn != null,
				"pathing": _pathfinder != null and bool(_pathfinder.path_finding_in_progress)}
	return [{"kind": _nc_kind(), "id": _nc_cid(), "view": view,
			"c": c, "cn": cn, "seg": seg, "sp": 3.0, "x": x, "xn": xn, "xc": xc, "xg": xg,
			"vis": is_visible_in_tree(), "wl": false,
			"tp": _nc_tp_applied if coop_puppet else int(get_meta("zonda_tp", 0)), "st": st, "fx": fx}]


func coop_test_recoil(holder: Node3D) -> void:
	# the probe's forced recoil (a pale one caught in the holder's beam, as light-fear would)
	if coop_puppet or not is_instance_valid(holder):
		return
	var eye: Vector3 = holder.global_position + Vector3.UP * 0.77
	_coop_recoil({"node": holder, "eye": eye, "dir": eye.direction_to(global_position)})
