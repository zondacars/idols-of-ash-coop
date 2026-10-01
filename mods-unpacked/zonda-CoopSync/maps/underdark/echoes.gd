extends Node

# ============================================================================================
# ECHOES AND NOTES (ZondaCoopSync 5.1, feature "echoes"; the owner liked idea 1, "think like the
# Elden Ring developers").
#
# ECHOES. Where a climber dies, a dark stain stays on the rock (a stored map event, so every player
#   sees it, after a reload too). Stand in it for a second and the last six seconds of that climber
#   play back as a pale ghost: where they came from, and how it went wrong. The newest 14 per run.
#   echo_<sid>_<k>  persistent {by, pos, track: [[x,y,z,yaw] x up to 30 at 5 Hz], t}
# NOTES. Press N to chalk a note at your feet, from a fixed list (no free text): 1-9 picks one, N or
#   Esc closes. Notes are faint chalk on the floor that only shows inside your lantern's light.
#   note_<sid>_<k>  persistent {by, pos, i}      at most 12 per player per run, one every 8 s
# DEV TEST: echoes.flag -> "[ECHO] test done N/N PASS".
# ============================================================================================

const TAG := "[ECHO]"
const TRACK_HZ := 5.0
const TRACK_S := 6.0
const MAX_ECHOES := 14
const STAND_S := 1.0
const NOTE_GAP_MS := 8000
const NOTE_MAX := 12
const NOTE_SEE := 7.5
const PHRASES := ["Try the rope here", "Something waits behind you", "Shortcut ahead", "Do not trust the fire",
		"Be quiet here", "Light your lantern", "Hidden path", "Danger above", "Rest here, you earned it"]

var map: Node = null
var _track: Array = []                # my last six seconds: [x, y, z, yaw]
var _track_t := 0.0
var _alive_was := true
var _sent := 0
var _echoes: Dictionary = {}          # key -> {"node", "data", "replay": Node3D or null, "stand": float}
var _notes: Dictionary = {}           # key -> {"node": Label3D, "pos"}
var _notes_mine := 0
var _note_ms := -100000
var _picker: CanvasLayer = null
var _ghost_mat: StandardMaterial3D = null
var _stain_mat: StandardMaterial3D = null
var replays := 0                      # tests
var _test: Node = null


func setup(m: Node) -> void:
	map = m
	if map.has_method("register_events"):
		map.call("register_events", ["echo_", "note_"], _on_event, false)
	_ghost_mat = StandardMaterial3D.new()
	_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ghost_mat.albedo_color = Color(0.75, 0.8, 0.9, 0.0)
	_ghost_mat.emission_enabled = true
	_ghost_mat.emission = Color(0.55, 0.6, 0.75)
	_ghost_mat.emission_energy_multiplier = 0.5
	_ghost_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_stain_mat = StandardMaterial3D.new()
	_stain_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_stain_mat.albedo_color = Color(0.16, 0.015, 0.01, 0.85)
	_stain_mat.roughness = 0.25
	_stain_mat.metallic_specular = 0.8
	_stain_mat.emission_enabled = true
	_stain_mat.emission = Color(0.35, 0.02, 0.01)
	_stain_mat.emission_energy_multiplier = 0.15
	var flag = map.call("dev_flag", "echoes.flag") if map.has_method("dev_flag") else null
	if flag != null:
		if CoopSync.has_method("use_test_files"):
			CoopSync.call("use_test_files")
		_test = EchoTest.new()
		_test.set("ec", self)
		_test.set("map", map)
		add_child(_test)
		print("%s test on" % TAG)


func _my_sid() -> String:
	if CoopSync.has_method("my_sid"):
		return str(CoopSync.call("my_sid"))
	return str(CoopSync.my_id())


static func _v3(a) -> Vector3:
	if a is Array and (a as Array).size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


# ============================================================================ echoes

func _process(delta: float) -> void:
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var alive: bool = float(c.get("health")) > 0.0 and not bool(c.get("coop_spectating"))
	if alive:
		_track_t -= delta
		if _track_t <= 0.0:
			_track_t = 1.0 / TRACK_HZ
			var p: Vector3 = c.global_position
			var cam = c.get("Camera")
			var yaw: float = (cam as Node3D).global_rotation.y if cam is Node3D else c.global_rotation.y
			_track.append([snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01), snappedf(yaw, 0.01)])
			while _track.size() > int(TRACK_HZ * TRACK_S):
				_track.pop_front()
	elif _alive_was and not _track.is_empty():
		_died()
	_alive_was = alive
	_update_echoes(delta, c)
	_update_notes(c)


func _died() -> void:
	# my death leaves an echo where it happened (a dev test can be invincible: it calls this itself)
	_sent += 1
	var last: Array = _track[-1]
	var key := "echo_%s_%d_%d" % [_my_sid(), int(Time.get_unix_time_from_system()) % 100000, _sent]
	CoopSync.map_event(key, {"by": CoopSync.local_name, "pos": [last[0], last[1], last[2]], "track": _track.duplicate(),
			"t": Time.get_unix_time_from_system()})
	_track.clear()
	print("%s an echo stays where %s fell" % [TAG, CoopSync.local_name])


func leave_echo_now() -> void:
	# tests: as if I died here now
	if not _track.is_empty():
		_died()


func _on_event(key: String, data: Dictionary, _replay: bool) -> void:
	if key.begins_with("echo_"):
		if _echoes.has(key):
			return
		_add_echo(key, data)
		# only the newest MAX_ECHOES stay
		if _echoes.size() > MAX_ECHOES:
			var oldest := ""
			var ot := 1e30
			for k in _echoes.keys():
				var tt := float((_echoes[k]["data"] as Dictionary).get("t", 0.0))
				if tt < ot:
					ot = tt
					oldest = k
			if oldest != "":
				(_echoes[oldest]["node"] as Node).queue_free()
				_echoes.erase(oldest)
	elif key.begins_with("note_"):
		if not _notes.has(key):
			_add_note(key, data)


func _floor_at(p: Vector3) -> Vector3:
	var space = (map as Node3D).get_world_3d().direct_space_state if map is Node3D else null
	if space == null:
		return p
	var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3(0, 1.0, 0), p + Vector3(0, -6.0, 0), 1))
	return hit["position"] if not hit.is_empty() else p - Vector3(0, 0.9, 0)


func _add_echo(key: String, data: Dictionary) -> void:
	var stain := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.75
	cm.bottom_radius = 0.75
	cm.height = 0.02
	cm.radial_segments = 14
	stain.mesh = cm
	stain.material_override = _stain_mat
	stain.top_level = true
	add_child(stain)
	stain.global_position = _floor_at(_v3(data.get("pos", []))) + Vector3(0, 0.02, 0)
	stain.rotation.y = randf() * TAU
	stain.scale = Vector3(1.0, 1.0, randf_range(0.6, 1.0))
	_echoes[key] = {"node": stain, "data": data, "replay": null, "stand": 0.0, "rt": 0.0}


func _update_echoes(delta: float, c) -> void:
	var p: Vector3 = c.global_position
	for k in _echoes.keys():
		var e: Dictionary = _echoes[k]
		var st: Node3D = e["node"]
		if not is_instance_valid(st):
			continue
		if e["replay"] != null:
			_step_replay(e, delta)
			continue
		var d := Vector2(p.x - st.global_position.x, p.z - st.global_position.z).length()
		var on_it := d < 1.1 and absf(p.y - st.global_position.y) < 2.2
		if on_it:
			if float(e["stand"]) >= 0.0:
				e["stand"] = float(e["stand"]) + delta
				if float(e["stand"]) >= STAND_S:
					e["stand"] = -1.0            # played: step off it before it plays again
					_start_replay(e)
		else:
			e["stand"] = 0.0


func _start_replay(e: Dictionary) -> void:
	var ps = load("res://Art/Knight.glb")
	var g := Node3D.new()
	g.top_level = true
	add_child(g)
	if ps is PackedScene:
		var k: Node3D = (ps as PackedScene).instantiate()
		for co in k.find_children("*", "CollisionObject3D", true, false):
			co.queue_free()
		for mi in k.find_children("*", "MeshInstance3D", true, false):
			(mi as MeshInstance3D).material_override = _ghost_mat
			(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		g.add_child(k)
	e["replay"] = g
	e["rt"] = 0.0
	replays += 1
	var by := str((e["data"] as Dictionary).get("by", "someone"))
	CoopSync.show_banner("The last moments of %s." % by, 3.0)
	print("%s replaying the echo of %s" % [TAG, by])


func _step_replay(e: Dictionary, delta: float) -> void:
	var g: Node3D = e["replay"]
	var tr: Array = (e["data"] as Dictionary).get("track", [])
	e["rt"] = float(e["rt"]) + delta
	var f := float(e["rt"]) * TRACK_HZ
	if tr.size() < 2 or f >= tr.size() - 1 + 6.0:
		g.queue_free()
		e["replay"] = null
		_ghost_mat.albedo_color.a = 0.0
		return
	var i := mini(int(f), tr.size() - 2)
	var k := clampf(f - i, 0.0, 1.0)
	var a: Array = tr[i]
	var b: Array = tr[i + 1]
	var pa := Vector3(float(a[0]), float(a[1]), float(a[2]))
	var pb := Vector3(float(b[0]), float(b[1]), float(b[2]))
	g.global_position = pa.lerp(pb, k) - Vector3(0, 0.8, 0)
	g.rotation.y = lerp_angle(float(a[3]), float(b[3]), k) + PI
	# fades in, holds, and at the end (they fell) sinks and fades out
	var total := float(tr.size()) / TRACK_HZ
	var tt := float(e["rt"])
	var alpha := clampf(tt / 0.6, 0.0, 1.0) * clampf((total + 1.2 - tt) / 1.2, 0.0, 1.0)
	_ghost_mat.albedo_color.a = 0.42 * alpha


# ============================================================================ notes

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var k := event as InputEventKey
	if _picker != null:
		if k.keycode == KEY_N or k.keycode == KEY_ESCAPE:
			_close_picker()
			get_viewport().set_input_as_handled()
			return
		var n := int(k.keycode) - int(KEY_1)
		if n >= 0 and n < PHRASES.size():
			_close_picker()
			write_note(n)
			get_viewport().set_input_as_handled()
		return
	if k.keycode == KEY_N:
		var c = Game.climber
		if is_instance_valid(c) and c.is_inside_tree() and float(c.get("health")) > 0.0:
			_open_picker()
			get_viewport().set_input_as_handled()


func _open_picker() -> void:
	_picker = CanvasLayer.new()
	_picker.layer = 70
	var lb := Label.new()
	var txt := "Chalk a note here (1-%d), N to close:\n" % PHRASES.size()
	for i in PHRASES.size():
		txt += "\n%d   %s" % [i + 1, PHRASES[i]]
	lb.text = txt
	var ls := LabelSettings.new()
	ls.font_size = 12
	ls.outline_size = 4
	ls.outline_color = Color.BLACK
	ls.font_color = Color(0.92, 0.88, 0.78)
	lb.label_settings = ls
	lb.position = Vector2(24, 80)
	_picker.add_child(lb)
	add_child(_picker)


func _close_picker() -> void:
	if is_instance_valid(_picker):
		_picker.queue_free()
	_picker = null


func write_note(i: int) -> bool:
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return false
	var now := Time.get_ticks_msec()
	if now - _note_ms < NOTE_GAP_MS:
		CoopSync.show_banner("The chalk is still wet. Wait a moment.", 2.0)
		return false
	if _notes_mine >= NOTE_MAX:
		CoopSync.show_banner("Your chalk is used up.", 2.0)
		return false
	_note_ms = now
	_notes_mine += 1
	var p: Vector3 = _floor_at(c.global_position)
	CoopSync.map_event("note_%s_%d_%d" % [_my_sid(), int(Time.get_unix_time_from_system()) % 100000, _notes_mine],
			{"by": CoopSync.local_name, "pos": [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)], "i": clampi(i, 0, PHRASES.size() - 1)})
	CoopSync.show_banner("You chalk it on the rock: \"%s\"." % PHRASES[clampi(i, 0, PHRASES.size() - 1)], 2.5)
	return true


func _add_note(key: String, data: Dictionary) -> void:
	var lb := Label3D.new()
	lb.text = PHRASES[clampi(int(data.get("i", 0)), 0, PHRASES.size() - 1)]
	lb.font_size = 48
	lb.pixel_size = 0.006
	lb.modulate = Color(0.85, 0.82, 0.72, 0.0)
	lb.outline_size = 0
	lb.shaded = false
	lb.double_sided = true
	lb.top_level = true
	add_child(lb)
	lb.global_position = _v3(data.get("pos", [])) + Vector3(0, 0.04, 0)
	lb.rotation = Vector3(-PI * 0.5, randf() * TAU, 0.0)
	_notes[key] = {"node": lb, "pos": lb.global_position}


func _update_notes(c) -> void:
	if _notes.is_empty():
		return
	# chalk shows only in lantern light: mine lit and the note inside its reach
	var lit := bool(CoopSync.get("lantern_on"))
	var p: Vector3 = c.global_position
	for k in _notes.keys():
		var lb: Label3D = _notes[k]["node"]
		if not is_instance_valid(lb):
			continue
		var d := p.distance_to(_notes[k]["pos"])
		var want := 0.0
		if lit and d < NOTE_SEE:
			want = clampf((NOTE_SEE - d) / 2.0, 0.0, 1.0) * 0.8
		lb.modulate.a = lerpf(lb.modulate.a, want, 0.15)


func note_visible(key: String) -> bool:
	return _notes.has(key) and is_instance_valid(_notes[key]["node"]) and (_notes[key]["node"] as Label3D).modulate.a > 0.3


# ============================================================================ dev test

class EchoTest extends Node:
	var ec = null
	var map = null
	var t := 0.0
	var phase := 0
	var mark := 0.0
	var n_pass := 0
	var n_total := 0
	var fails: Array = []
	var start := Vector3.ZERO

	func ok(key: String, cond: bool, text: String) -> void:
		n_total += 1
		if cond:
			n_pass += 1
			print("%s PASS %s" % [TAG, text])
		else:
			fails.append(key)
			print("%s FAIL %s" % [TAG, text])

	func _process(delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree() or phase < 0:
			return
		t += delta
		c.prevent_player_death = true
		match phase:
			0:
				if t < 8.0:
					return
				# walk a little (fake), then "die": the echo is written and appears as a stain
				start = c.global_position
				for i in 12:
					ec._track.append([start.x + i * 0.4, start.y, start.z, 0.0])
				ec.leave_echo_now()
				mark = t
				phase = 1
			1:
				if t - mark < 1.0:
					return
				var store: Dictionary = CoopSync.map_events_for(str(map.get("scene_file_path")))
				var n := 0
				for k in store.keys():
					if str(k).begins_with("echo_"):
						n += 1
				ok("stored", n >= 1 and ec._echoes.size() >= 1, "the echo is stored and its stain is on the rock (%d)" % ec._echoes.size())
				# stand in it
				var st: Node3D = ec._echoes.values()[0]["node"]
				map.call("debug_park", st.global_position + Vector3(0, 1.0, 0))
				mark = t
				phase = 2
			2:
				if ec.replays >= 1:
					ok("replay", t - mark >= 0.9, "standing in it played the echo back after %.1f s" % (t - mark))
					mark = t
					phase = 3
				elif t - mark > 5.0:
					ok("replay", false, "no replay 5 s after standing in the stain")
					_finish()
			3:
				# a note, then lantern on and off
				var ok_w: bool = ec.write_note(2)
				ok("note written", ok_w, "a note chalked")
				var ok_w2: bool = ec.write_note(3)
				ok("note gap", not ok_w2, "a second note at once is refused (wet chalk)")
				if is_instance_valid(CoopSync.lantern) and CoopSync.lantern.get("user") != null:
					CoopSync.lantern.set("user", 1)
				CoopSync.set("lantern_on", true)
				mark = t
				phase = 4
			4:
				if t - mark < 1.5:
					return
				var key := ""
				for k in ec._notes.keys():
					key = k
				ok("note lit", key != "" and ec.note_visible(key), "the note shows in lantern light")
				CoopSync.set("lantern_on", false)
				if is_instance_valid(CoopSync.lantern) and CoopSync.lantern.get("user") != null:
					CoopSync.lantern.set("user", 0)
				mark = t
				phase = 5
			5:
				if t - mark < 1.5:
					return
				var key2 := ""
				for k in ec._notes.keys():
					key2 = k
				ok("note dark", key2 != "" and not ec.note_visible(key2), "with the lantern out it cannot be seen")
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
