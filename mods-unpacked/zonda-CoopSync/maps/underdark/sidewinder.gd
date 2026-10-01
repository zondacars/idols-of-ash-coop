extends Node

# ============================================================================================
# THE SIDEWINDER (ZondaCoopSync 5.1, feature module "sidewinder"): DRY GULCH's sand-swimmer.
#
# A rattlesnake as long as the street is wide, living under the dust of the dry lake bed. You see
# a moving ripple and hear sand hiss; you never see the body until it comes up. It HUNTS BY SOUND:
#   your voice (CoopSync.noise_of: whisper 5 m, talking 12 m, shouting 30 m) and your steps on
#   the sand (walking 7 m, running 16 m). On a boardwalk only running (10 m) or talking out loud
#   carry down through the boards. Inside a building or up on a roof it cannot hear or reach you.
# THE TELL: when it has you, it coils under where you stand and its tail comes up out of the sand
#   RATTLING for 1.5 s. Then it strikes at where you are at the end of the rattle, up to 5 m from
#   the coil: get off the sand (boards, a doorway, a roof) or get 5 m away and it bites dust.
#   A hit is 30 HP and a shove. It strikes up through boardwalk planks (if it heard you on them),
#   never through stone or into a building, never onto a roof. Then it dives and goes quiet 2.5 s.
# One per town. Host-authoritative; guests get the ripple at 10 Hz ("sw" stream) and the rattle
# and the strike as events, so the tell is never lost to a dropped packet:
#   swrat_<n>  non-persistent {n, coil:[x,y,z], tail:[x,y,z], to}     the rattle starts
#   swstk_<n>  non-persistent {n, from:[x,y,z], at:[x,y,z], hit}      the strike
#   cbite_sw<n>                                                       the bite (register_bites "sw")
# DEV TEST: maps/underdark/sidewinder.flag. Tag [SIDEWINDER], "[SIDEWINDER] test done N/N PASS".
# ============================================================================================

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const TAG := "[SIDEWINDER]"

const ROAM_SPEED := 4.5
const HUNT_SPEED := 11.0
const RATTLE_S := 1.5
const STRIKE_S := 0.45
const DIVE_S := 1.2
const REST_S := 2.5
const LUNGE := 5.0
const HIT_R := 2.3
const BITE_DMG := 60.0              # the game halves it: 30 HP
const BITE_PUSH := 10.0
const FORGET_S := 6.0
const STEP_R_SAND := [0.0, 7.0, 16.0]       # still, walking, running (on the sand)
const STEP_R_PLANKS := [0.0, 0.0, 10.0]     # boards creak only when you run
const SEGS := 22
const SEG_LEN := 0.85
const SFX_RATTLE := ["sw_rattle_559759_1.ogg", "sw_rattle_559759_2.ogg", "sw_rattle_268580_1.ogg"]
const SFX_HISS := "sw_hiss_553374_1.ogg"
const SFX_SAND := "sw_sand_199395.ogg"
const SFX_BITE := ["res://sfx/MonsterIdeas/Chomp_01.wav", "res://sfx/MonsterIdeas/Chomp_02.wav"]

enum {ROAM, HUNT, RATTLE, STRIKE, DIVE, REST}
const NAMES := ["ROAM", "HUNT", "RATTLE", "STRIKE", "DIVE", "REST"]

signal bit(who: Node3D, damage: float, id: String)

var map: Node = null
var town: Node = null
var built := false
var st := ROAM
var st_t := 0.0
var pos := Vector3.ZERO               # the head, under the sand (on the bed)
var yaw := 0.0
var _goal := Vector3.ZERO
var _target: Node3D = null
var _heard_at := Vector3.ZERO
var _heard_ms := -100000
var _heard_tier := 0
var _coil := Vector3.ZERO
var _tail := Vector3.ZERO
var _strike_at := Vector3.ZERO
var _strike_from := Vector3.ZERO
var _seq := 0
var _think_t := 0.0
var _last_pos: Dictionary = {}        # player instance id -> [pos, ms]
var _speeds: Dictionary = {}          # player instance id -> m/s
var _was_auth := false
var _warned: Dictionary = {}
# guests
var _rp := Vector3.ZERO
var _rp_ms := 0
var _have_rp := false
# visuals
var _root: Node3D = null
var _mound: MeshInstance3D = null
var _dust: CPUParticles3D = null
var _segs: Array = []                 # MeshInstance3D
var _head: Node3D = null
var _tail_nodes: Array = []
var _sand_player: AudioStreamPlayer3D = null
var _fx_player: AudioStreamPlayer3D = null
var _rattle_player: AudioStreamPlayer3D = null
var _mat_scale: StandardMaterial3D = null
var _mat_sand: StandardMaterial3D = null
# tests
var log_states: Array = []            # [ms, state name]
var rattle_log: Array = []            # [ms, target name]
var strike_log: Array = []            # [ms, target name, hit, dist]


func setup(m: Node) -> void:
	map = m
	_was_auth = CoopSync.map_is_authority()
	var L = m.get("L")
	var T = (L as Dictionary).get("town") if L is Dictionary else null
	if not (T is Dictionary):
		print("[Underdark] sidewinder: no town")
		return
	var sw = (T as Dictionary).get("sidewinder", {})
	pos = _v3(sw.get("home", (T as Dictionary).get("center", [0, 0, 0])) if sw is Dictionary else (T as Dictionary).get("center", [0, 0, 0]))
	_goal = pos
	_build_visuals()
	built = true
	if map.has_method("register_events"):
		map.call("register_events", ["swrat_", "swstk_"], _on_event, true)
	if map.has_method("register_stream"):
		map.call("register_stream", "sw", _send, _recv)
	if map.has_method("register_bites"):
		map.call("register_bites", "sw", self)
	if map.has_method("register_threats"):
		map.call("register_threats", self)
	print("[Underdark] sidewinder: 1 under the bed of DRY GULCH")
	_setup_test()


func _town():
	if is_instance_valid(town):
		return town
	if map != null and map.has_method("feature"):
		var t = map.call("feature", "town")
		if t != null and t.has_method("surface_at") and bool(t.call("ready_town")):
			town = t
	return town


func _warn(key: String, text: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning("%s %s" % [TAG, text])


static func _v3(a) -> Vector3:
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	if a is Vector3:
		return a
	return Vector3.ZERO


static func _arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]


# ============================================================================ visuals

func _sfx(file: String, loop: bool) -> AudioStream:
	if file.begins_with("res://") and not file.begins_with("res://mods-unpacked"):
		return load(file) as AudioStream
	var ss = map.get("_ss") if map != null else null
	if is_instance_valid(ss) and ss.has_method("_stream"):
		var st0 = ss.call("_stream", file, loop)
		if st0 is AudioStream:
			return st0
	var full := DIR + "sfx/" + file
	if not FileAccess.file_exists(full):
		_warn("sfx " + file, "missing sound " + full)
		return null
	var ogg := AudioStreamOggVorbis.load_from_buffer(FileAccess.get_file_as_bytes(full))
	if ogg != null:
		ogg.loop = loop
	return ogg


func _bus() -> StringName:
	return &"ZondaCave" if AudioServer.get_bus_index("ZondaCave") >= 0 else &"MainBus"


func _build_visuals() -> void:
	_root = Node3D.new()
	_root.name = "Sidewinder"
	_root.top_level = true
	add_child(_root)
	_mat_scale = StandardMaterial3D.new()
	_mat_scale.albedo_color = Color(0.2, 0.16, 0.1)
	_mat_scale.roughness = 0.55
	_mat_scale.metallic_specular = 0.6
	_mat_sand = StandardMaterial3D.new()
	_mat_sand.albedo_color = Color(0.42, 0.36, 0.26)
	_mat_sand.roughness = 1.0
	# the ripple: a low mound that moves through the dust, and the dust it throws up
	_mound = MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	_mound.mesh = sm
	_mound.material_override = _mat_sand
	_mound.scale = Vector3(1.1, 0.22, 2.4)
	_root.add_child(_mound)
	_dust = CPUParticles3D.new()
	_dust.amount = 40
	_dust.lifetime = 1.4
	_dust.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	_dust.emission_sphere_radius = 1.0
	_dust.direction = Vector3.UP
	_dust.spread = 50.0
	_dust.initial_velocity_min = 0.4
	_dust.initial_velocity_max = 1.4
	_dust.gravity = Vector3(0, -0.6, 0)
	_dust.scale_amount_min = 0.15
	_dust.scale_amount_max = 0.45
	var dq := QuadMesh.new()
	dq.size = Vector2(0.6, 0.6)
	var dm := StandardMaterial3D.new()
	dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dm.albedo_color = Color(0.5, 0.44, 0.33, 0.35)
	dm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var dot = map.call("soft_dot") if map != null and map.has_method("soft_dot") else null
	if dot is Texture2D:
		dm.albedo_texture = dot
	dq.material = dm
	_dust.mesh = dq
	_root.add_child(_dust)
	# the body: segments that taper to the tail, the head with its fangs and slit eyes
	for i in SEGS:
		var mi := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		var k := float(i) / (SEGS - 1)
		var r := lerpf(0.42, 0.14, k * k)
		cap.radius = r
		cap.height = maxf(SEG_LEN * 1.35, r * 2.0 + 0.01)
		mi.mesh = cap
		mi.material_override = _mat_scale
		mi.visible = false
		_root.add_child(mi)
		_segs.append(mi)
	_head = Node3D.new()
	_root.add_child(_head)
	var hm := MeshInstance3D.new()
	var hs := SphereMesh.new()
	hs.radius = 0.5
	hs.height = 0.7
	hm.mesh = hs
	hm.scale = Vector3(1.15, 0.8, 1.7)
	hm.material_override = _mat_scale
	_head.add_child(hm)
	var eye := StandardMaterial3D.new()
	eye.albedo_color = Color(0.9, 0.75, 0.2)
	eye.emission_enabled = true
	eye.emission = Color(0.95, 0.7, 0.15)
	eye.emission_energy_multiplier = 0.9
	for sx in [-1.0, 1.0]:
		var e := MeshInstance3D.new()
		var em := BoxMesh.new()
		em.size = Vector3(0.05, 0.12, 0.08)
		e.mesh = em
		e.material_override = eye
		e.position = Vector3(sx * 0.38, 0.14, -0.38)
		_head.add_child(e)
		var f := MeshInstance3D.new()
		var fm := CylinderMesh.new()
		fm.top_radius = 0.0
		fm.bottom_radius = 0.05
		fm.height = 0.42
		f.mesh = fm
		var fang := StandardMaterial3D.new()
		fang.albedo_color = Color(0.85, 0.82, 0.72)
		f.material_override = fang
		f.position = Vector3(sx * 0.16, -0.28, -0.62)
		_head.add_child(f)
	_head.visible = false
	for i in 4:
		var tm := MeshInstance3D.new()
		var ts := SphereMesh.new()
		ts.radius = 0.16 - i * 0.02
		ts.height = 0.26 - i * 0.03
		tm.mesh = ts
		var rmat := StandardMaterial3D.new()
		rmat.albedo_color = Color(0.5, 0.42, 0.3)
		tm.material_override = rmat
		tm.visible = false
		_root.add_child(tm)
		_tail_nodes.append(tm)
	_sand_player = AudioStreamPlayer3D.new()
	_sand_player.stream = _sfx(SFX_SAND, true)
	_sand_player.volume_db = -6.0
	_sand_player.unit_size = 5.0
	_sand_player.max_distance = 45.0
	_sand_player.bus = _bus()
	_root.add_child(_sand_player)
	_fx_player = AudioStreamPlayer3D.new()
	_fx_player.unit_size = 10.0
	_fx_player.max_distance = 70.0
	_fx_player.bus = _bus()
	_root.add_child(_fx_player)
	_rattle_player = AudioStreamPlayer3D.new()
	_rattle_player.volume_db = 6.0
	_rattle_player.unit_size = 14.0
	_rattle_player.max_distance = 60.0
	_rattle_player.bus = _bus()
	_root.add_child(_rattle_player)


func _bed(p: Vector3) -> float:
	var t = _town()
	return float(t.call("bed_y", p)) if t != null else p.y


# ============================================================================ hearing (authority)

func _players() -> Array:
	var out: Array = []
	if CoopSync.has_method("alive_player_nodes"):
		for p in CoopSync.call("alive_player_nodes"):
			if is_instance_valid(p) and (p as Node3D).is_inside_tree():
				out.append(p)
	return out


func _speed_of(p: Node3D, now: int) -> float:
	var id := p.get_instance_id()
	var q := p.global_position
	var e = _last_pos.get(id)
	_last_pos[id] = [q, now]
	if e == null:
		return 0.0
	var dt := float(now - int(e[1])) / 1000.0
	if dt <= 0.01:
		return float(_speeds.get(id, 0.0))
	var v := Vector2(q.x - (e[0] as Vector3).x, q.z - (e[0] as Vector3).z).length() / dt
	var sm := lerpf(float(_speeds.get(id, 0.0)), v, 0.5)
	_speeds[id] = sm
	return sm


func hear_radius(p: Node3D, surf: String, speed: float) -> float:
	# public (tests): how far away this player can be heard right now
	if surf == "inside" or surf == "roof" or surf == "off":
		return 0.0
	var voice := 0.0
	if CoopSync.has_method("noise_radius"):
		voice = float(CoopSync.call("noise_radius", p))
	var gait := 0 if speed < 1.2 else (1 if speed < 5.2 else 2)
	if surf == "planks":
		var tier := int(CoopSync.call("noise_of", p)) if CoopSync.has_method("noise_of") else 0
		return maxf(float(STEP_R_PLANKS[gait]), voice if tier >= 2 else 0.0)
	return maxf(float(STEP_R_SAND[gait]), voice)


func _listen(now: int) -> void:
	var t = _town()
	if t == null:
		return
	var best: Node3D = null
	var best_score := -1e9
	for p in _players():
		var pn := p as Node3D
		var q := pn.global_position
		var surf := str(t.call("surface_at", q))
		var sp := _speed_of(pn, now)
		var r := hear_radius(pn, surf, sp)
		if r <= 0.0:
			continue
		var d := Vector2(q.x - pos.x, q.z - pos.z).length()
		if d > r:
			continue
		var score := r - d
		if score > best_score:
			best_score = score
			best = pn
	if best != null:
		_target = best
		_heard_at = best.global_position
		_heard_ms = now


# ============================================================================ the brain (authority)

func _go(n: int) -> void:
	st = n
	st_t = 0.0
	log_states.append([Time.get_ticks_msec(), NAMES[n]])


func _physics_process(delta: float) -> void:
	if not built:
		return
	var auth: bool = CoopSync.map_is_authority()
	if auth != _was_auth:
		_was_auth = auth
		if auth:
			_go(ROAM)
	if auth:
		_brain(delta)
	else:
		_guest(delta)
	_visual(delta)


func _brain(delta: float) -> void:
	var now := Time.get_ticks_msec()
	st_t += delta
	_think_t -= delta
	if _think_t <= 0.0:
		_think_t = 0.2
		if st == ROAM or st == HUNT or st == REST:
			_listen(now)
	var t = _town()
	match st:
		ROAM:
			if _target != null and now - _heard_ms < 1000:
				_go(HUNT)
				return
			if pos.distance_to(_goal) < 3.0 or st_t > 20.0:
				_goal = _pick_roam()
				st_t = 0.0
			_swim(_goal, ROAM_SPEED, delta)
		HUNT:
			if not is_instance_valid(_target) or now - _heard_ms > int(FORGET_S * 1000.0):
				_target = null
				_go(ROAM)
				return
			var tp := _target.global_position
			var surf := str(t.call("surface_at", tp)) if t != null else "off"
			var to := _heard_at
			_swim(to, HUNT_SPEED, delta)
			var d := Vector2(tp.x - pos.x, tp.z - pos.z).length()
			var can := surf == "sand" or (surf == "planks" and now - _heard_ms < 600)
			if can and d < 4.0:
				_rattle()
		RATTLE:
			if st_t >= RATTLE_S:
				_strike()
		STRIKE:
			if st_t >= STRIKE_S:
				_go(DIVE)
		DIVE:
			if st_t >= DIVE_S:
				_go(REST)
		REST:
			if st_t >= REST_S:
				_go(HUNT if (_target != null and now - _heard_ms < 2000) else ROAM)


func _pick_roam() -> Vector3:
	var t = _town()
	if t == null:
		return pos
	var c: Vector3 = t.get("_c")
	var u: Vector3 = t.get("_u")
	var v: Vector3 = t.get("_v")
	var R: float = float(t.get("_radius"))
	for i in 12:
		var s := randf_range(-R * 0.75, R * 0.75)
		var w := randf_range(-R * 0.6, R * 0.6)
		if randf() < 0.5:
			w = randf_range(-8.0, 8.0)                    # the main street often
		var q := c + u * s + v * w
		q.y = _bed(q)
		if Vector2(q.x - c.x, q.z - c.z).length() < R - 18.0 and str(t.call("surface_at", q + Vector3(0, 0.5, 0))) == "sand":
			return q
	return pos


func _swim(to: Vector3, speed: float, delta: float) -> void:
	var t = _town()
	var d := Vector3(to.x - pos.x, 0.0, to.z - pos.z)
	var ln := d.length()
	if ln < 0.05:
		return
	var step := minf(ln, speed * delta)
	var dir := d / ln
	yaw = lerp_angle(yaw, atan2(-dir.x, -dir.z), clampf(delta * 6.0, 0.0, 1.0))
	var nxt := pos + dir * step
	# it never leaves the bed: stay inside the town radius
	if t != null:
		var c: Vector3 = t.get("_c")
		var R: float = float(t.get("_radius"))
		var off := Vector2(nxt.x - c.x, nxt.z - c.z)
		if off.length() > R - 14.0:
			off = off.normalized() * (R - 14.0)
			nxt = Vector3(c.x + off.x, nxt.y, c.z + off.y)
	nxt.y = _bed(nxt)
	pos = nxt


func _rattle() -> void:
	var tp := _target.global_position
	_coil = Vector3(pos.x, _bed(pos), pos.z)
	var back := Vector3(sin(yaw), 0.0, cos(yaw))       # behind the head
	_tail = _coil + back * 4.5
	_tail.y = _bed(_tail)
	_seq += 1
	var nm := _name(_target)
	rattle_log.append([Time.get_ticks_msec(), nm])
	print("%s rattles at %s (%.1f m)" % [TAG, nm, Vector2(tp.x - pos.x, tp.z - pos.z).length()])
	_go(RATTLE)
	CoopSync.map_event("swrat_%d" % _seq, {"n": _seq, "coil": _arr(_coil), "tail": _arr(_tail), "to": nm}, false)


func _strike() -> void:
	var t = _town()
	_strike_from = _coil
	var hit_node: Node3D = null
	var aim := _coil
	var dist := 99.0
	if is_instance_valid(_target):
		var tp := _target.global_position
		var flat := Vector3(tp.x - _coil.x, 0.0, tp.z - _coil.z)
		var reach := flat.limit_length(LUNGE)
		aim = _coil + reach
		aim.y = _bed(aim)
		var surf := str(t.call("surface_at", tp)) if t != null else "off"
		dist = Vector2(tp.x - aim.x, tp.z - aim.z).length()
		var dy := tp.y - aim.y
		if (surf == "sand" or surf == "planks") and dist <= HIT_R and dy < 3.2:
			hit_node = _target
	_strike_at = aim
	var nm := _name(_target) if is_instance_valid(_target) else ""
	strike_log.append([Time.get_ticks_msec(), nm, hit_node != null, dist])
	print("%s strikes at %s: %s (%.1f m from the bite)" % [TAG, nm, "HIT" if hit_node != null else "miss", dist])
	_go(STRIKE)
	CoopSync.map_event("swstk_%d" % _seq, {"n": _seq, "from": _arr(_strike_from), "at": _arr(_strike_at), "hit": hit_node != null}, false)
	if hit_node != null:
		bit.emit(hit_node, BITE_DMG, "sw%d" % _seq)
	pos = aim
	_target = _target if hit_node == null else null


func _name(n) -> String:
	if not is_instance_valid(n):
		return ""
	if n == Game.climber:
		return CoopSync.local_name
	return str(n.get("player_name"))


# ============================================================================ sync

func _send():
	return [st, snappedf(pos.x, 0.01), snappedf(pos.y, 0.01), snappedf(pos.z, 0.01), snappedf(yaw, 0.01)]


func _recv(v) -> void:
	if CoopSync.map_is_authority() or not (v is Array) or (v as Array).size() < 5:
		return
	_rp = Vector3(float(v[1]), float(v[2]), float(v[3]))
	yaw = float(v[4])
	_rp_ms = Time.get_ticks_msec()
	if not _have_rp:
		pos = _rp
		_have_rp = true
	var n := int(v[0])
	if (n == ROAM or n == HUNT) and (st == REST or st == DIVE) and st_t > 0.5:
		_go(n)
	elif n == ROAM or n == HUNT:
		if st != RATTLE and st != STRIKE and st != DIVE:
			st = n


func _guest(delta: float) -> void:
	st_t += delta
	if _have_rp and (st == ROAM or st == HUNT or st == REST):
		pos = pos.lerp(_rp, clampf(delta * 8.0, 0.0, 1.0))
	if st == STRIKE and st_t >= STRIKE_S:
		_go(DIVE)
	elif st == DIVE and st_t >= DIVE_S:
		_go(REST)


func _on_event(key: String, data: Dictionary, replay: bool) -> void:
	if replay:
		return
	if key.begins_with("swrat_"):
		_coil = _v3(data.get("coil", []))
		_tail = _v3(data.get("tail", []))
		if not CoopSync.map_is_authority():
			_go(RATTLE)
		_play_rattle()
	elif key.begins_with("swstk_"):
		_strike_from = _v3(data.get("from", []))
		_strike_at = _v3(data.get("at", []))
		if not CoopSync.map_is_authority():
			_go(STRIKE)
			pos = _strike_at
		_play_fx(SFX_HISS, 4.0, 0.9)
		if bool(data.get("hit", false)):
			_play_fx(SFX_BITE[randi() % SFX_BITE.size()], 4.0, 0.7)


func _play_rattle() -> void:
	if not is_instance_valid(_rattle_player) or not _rattle_player.is_inside_tree():
		return
	_rattle_player.stream = _sfx(SFX_RATTLE[randi() % SFX_RATTLE.size()], false)
	_rattle_player.global_position = _tail + Vector3(0, 0.6, 0)
	_rattle_player.play()


func _play_fx(file: String, db: float, pitch: float) -> void:
	if not is_instance_valid(_fx_player) or not _fx_player.is_inside_tree():
		return
	_fx_player.stream = _sfx(file, false)
	_fx_player.volume_db = db
	_fx_player.pitch_scale = pitch
	_fx_player.global_position = _strike_at + Vector3(0, 1.0, 0)
	_fx_player.play()


# the map's bite plumbing
func bite_origin(_id: String) -> Vector3:
	return _strike_at


func play_bite(_id: String) -> void:
	pass


func bite_opts(_id: String) -> Dictionary:
	return {"heavy": true, "push": BITE_PUSH}


func threat_positions() -> Array:
	if not built or st == ROAM:
		return []
	return [pos]


# ============================================================================ the look

func _visual(delta: float) -> void:
	if not is_instance_valid(_root):
		return
	var lis := Vector3.ZERO
	var c = Game.climber
	if is_instance_valid(c) and c.is_inside_tree():
		lis = c.global_position
	var near := lis.distance_to(pos) < 140.0
	_root.visible = near
	if not near:
		if _sand_player.playing:
			_sand_player.stop()
		return
	var under := st == ROAM or st == HUNT or st == REST
	# the mound and its dust follow the head while it swims
	_mound.visible = under or st == RATTLE
	_mound.global_position = pos + Vector3(0, -0.05, 0)
	_mound.rotation = Vector3(0, yaw, 0)
	var moving := st == ROAM or st == HUNT
	_dust.emitting = moving or st == STRIKE
	_dust.global_position = pos
	if moving and not _sand_player.playing and _sand_player.stream != null:
		_sand_player.play()
	elif not moving and _sand_player.playing:
		_sand_player.stop()
	_sand_player.global_position = pos
	_sand_player.pitch_scale = 1.15 if st == HUNT else 0.85
	# the tail rattles up out of the sand
	var rattling := st == RATTLE
	for i in _tail_nodes.size():
		var tn: MeshInstance3D = _tail_nodes[i]
		tn.visible = rattling
		if rattling:
			var shake := sin(float(Time.get_ticks_msec()) * 0.09 + i) * 0.06
			tn.global_position = _tail + Vector3(shake, 0.2 + i * 0.24 * clampf(st_t * 3.0, 0.0, 1.0), -shake)
	# the strike: the body comes up out of the coil in an arc to the bite, then sinks back
	var body_k := 0.0
	if st == STRIKE:
		body_k = clampf(st_t / 0.18, 0.0, 1.0)
	elif st == DIVE:
		body_k = clampf(1.0 - st_t / DIVE_S, 0.0, 1.0)
	var show_body := body_k > 0.01
	_head.visible = show_body
	for i in _segs.size():
		(_segs[i] as MeshInstance3D).visible = show_body
	if not show_body:
		return
	var a := _strike_from
	var b := _strike_at
	var apex := (a + b) * 0.5 + Vector3(0, 2.6 * body_k, 0)
	var sink := (1.0 - body_k) * 2.5
	var prev := Vector3.ZERO
	for i in _segs.size():
		var k := 1.0 - float(i) / (_segs.size() - 1)          # 1 at the head, 0 at the coil
		var tt := k * body_k
		var p := _bez(a, apex, b, tt) - Vector3(0, sink * (1.0 - k), 0)
		var seg := _segs[i] as MeshInstance3D
		seg.global_position = p
		if i > 0:
			var dirv := prev - p
			if dirv.length() > 0.001:
				seg.look_at(p + dirv, Vector3.UP if absf(dirv.normalized().y) < 0.95 else Vector3.RIGHT)
				seg.rotate_object_local(Vector3.RIGHT, PI * 0.5)
		prev = p
	var hp := _bez(a, apex, b, body_k)
	var hd := _bez(a, apex, b, minf(body_k + 0.02, 1.0)) - _bez(a, apex, b, maxf(body_k - 0.02, 0.0))
	_head.global_position = hp
	if hd.length() > 0.001:
		_head.look_at(hp + hd, Vector3.UP if absf(hd.normalized().y) < 0.95 else Vector3.RIGHT)


static func _bez(a: Vector3, m: Vector3, b: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return a * u * u + m * 2.0 * u * t + b * t * t


func on_session_ended() -> void:
	_was_auth = CoopSync.map_is_authority()


# ============================================================================ dev test

func _setup_test() -> void:
	var flag = null
	if map != null and map.has_method("dev_flag"):
		flag = map.call("dev_flag", "sidewinder.flag")
	if flag == null:
		return
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")
	CoopSync.set("noise_force", -1)            # this test is about hearing: the real rules
	var t := SwTest.new()
	t.name = "SwTest"
	t.sw = self
	t.map = map
	print("%s test on" % TAG)
	add_child(t)


class SwTest extends Node:
	# 1 still on the sand far away: never heard. 2 running on the sand near it: heard, a rattle,
	# then (staying put) a hit. 3 rattle, then run onto a boardwalk... onto the roof: a miss.
	# 4 standing still inside a building next to it: never heard.
	var sw = null
	var map = null
	var t := 0.0
	var phase := 0
	var mark := -1.0
	var n_pass := 0
	var n_total := 0
	var fails: Array = []
	var r0 := 0
	var s0 := 0
	var run_dir := Vector3.ZERO

	func ok(key: String, cond: bool, text: String) -> void:
		n_total += 1
		if cond:
			n_pass += 1
			print("%s PASS %s" % [TAG, text])
		else:
			fails.append(key)
			print("%s FAIL %s" % [TAG, text])

	func town():
		return sw._town()

	func park(p: Vector3) -> void:
		if map.has_method("debug_park"):
			map.call("debug_park", p)

	func _process(delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree() or phase < 0:
			return
		t += delta
		c.prevent_player_death = true
		var tw = town()
		if tw == null:
			if t > 8.0:
				ok("town", false, "no town module")
				_finish()
			return
		var u: Vector3 = tw.get("_u")
		var v: Vector3 = tw.get("_v")
		match phase:
			0:
				if t < 3.0:
					return
				# far from it, standing still on the sand: it must not hear me
				var far: Vector3 = sw.pos + v * 60.0
				far.y = tw.call("bed_y", far) + 1.0
				park(far)
				mark = t
				r0 = sw.rattle_log.size()
				phase = 1
			1:
				if t - mark < 6.0:
					return
				ok("still", sw.rattle_log.size() == r0 and sw.st == 0, "standing still 60 m away: never heard (state %s)" % sw.NAMES[sw.st])
				# running on the sand 10 m from it: heard, it comes, it rattles
				run_dir = u
				var near: Vector3 = sw.pos + v * 10.0
				near.y = tw.call("bed_y", near) + 1.0
				park(near)
				mark = t
				r0 = sw.rattle_log.size()
				s0 = sw.strike_log.size()
				phase = 2
			2:
				# fake a run: move the player 1.2 m every 0.2 s (6 m/s) back and forth on the spot
				var q: Vector3 = c.global_position + run_dir * 6.0 * delta
				if fmod(t - mark, 2.0) < delta:
					run_dir = -run_dir
				q.y = tw.call("bed_y", q) + 1.0
				c.global_position = q
				if sw.rattle_log.size() > r0:
					ok("heard", true, "running on the sand 10 m off: heard, it rattled after %.1f s" % (t - mark))
					mark = t
					phase = 3
				elif t - mark > 12.0:
					ok("heard", false, "running on the sand 10 m off: no rattle in 12 s (state %s)" % sw.NAMES[sw.st])
					_finish()
			3:
				# stand still right there: the strike must land (the tell came 1.5 s before)
				if sw.strike_log.size() > s0:
					var e: Array = sw.strike_log[-1]
					var gap: float = float(int(e[0]) - int(sw.rattle_log[-1][0])) / 1000.0
					ok("tell", absf(gap - sw.RATTLE_S) < 0.2, "the rattle came %.2f s before the strike (want 1.5)" % gap)
					ok("hit", bool(e[2]), "standing on the sand through the rattle: bitten (%.1f m)" % float(e[3]))
					mark = t
					s0 = sw.strike_log.size()
					r0 = sw.rattle_log.size()
					phase = 4
				elif t - mark > 4.0:
					ok("hit", false, "no strike 4 s after the rattle")
					_finish()
			4:
				# again: this time on the rattle, get onto a roof: it must miss
				if t - mark < 1.0:
					return
				var q2: Vector3 = c.global_position + run_dir * 6.0 * delta
				if fmod(t - mark, 2.0) < delta:
					run_dir = -run_dir
				q2.y = tw.call("bed_y", q2) + 1.0
				c.global_position = q2
				if sw.rattle_log.size() > r0:
					var roof := Vector3.ZERO
					var best := 1e9
					for b in tw.T.get("buildings", []):
						var bp: Vector3 = tw._v3(b["pos"])
						var dd: float = bp.distance_to(c.global_position)
						if dd < best:
							best = dd
							roof = bp + Vector3(0, tw._walk_h + float(b.get("h", 4.2)) + 1.2, 0)
					park(roof)
					mark = t
					phase = 5
				elif t - mark > 14.0:
					ok("roof", false, "no second rattle in 14 s")
					_finish()
			5:
				if sw.strike_log.size() > s0:
					var e2: Array = sw.strike_log[-1]
					var surf: String = tw.call("surface_at", c.global_position)
					ok("roof", not bool(e2[2]), "up on a roof (%s) through the rattle: it missed" % surf)
					mark = t
					phase = 6
				elif t - mark > 4.0:
					ok("roof", true, "up on a roof: it never struck")
					mark = t
					phase = 6
			6:
				# inside a building, talking out loud is not heard (the voice tier is faked)
				var bld: Dictionary = {}
				for b in tw.T.get("buildings", []):
					if bool(b.get("open", false)) and str(b.get("kind", "")) != "church":
						bld = b
						break
				if bld.is_empty():
					_finish()
					return
				var bp2: Vector3 = tw._v3(bld["pos"])
				var inside := Vector3(bp2.x, tw.call("bed_y", bp2) + tw._walk_h + 1.0, bp2.z)
				park(inside)
				var r_in: float = sw.hear_radius(c, str(tw.call("surface_at", inside)), 6.0)
				ok("inside", r_in == 0.0, "inside %s, running: hear radius %.1f (want 0)" % [str(bld.get("kind", "")), r_in])
				var r_sand: float = sw.hear_radius(c, "sand", 6.0)
				ok("radii", r_sand >= 15.9, "running on sand is heard from %.1f m" % r_sand)
				_finish()

	func _finish() -> void:
		phase = -1
		var c = Game.climber
		if is_instance_valid(c):
			c.prevent_player_death = false
		if fails.is_empty():
			print("%s test done %d/%d PASS" % [TAG, n_pass, n_total])
		else:
			print("%s test done %d/%d FAIL: %s" % [TAG, n_pass, n_total, ", ".join(PackedStringArray(fails))])
