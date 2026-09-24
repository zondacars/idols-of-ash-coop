extends Node3D

# ---------------------------------------------------------------- OIL FLASK (K10 pickup)
# A small dim clay/metal flask of lamp oil that hovers a hand above the floor, bobs very
# slightly and throws a faint warm pool of light (one small OmniLight3D, no particles, no
# emissive specks), so it reads in LANTERN mode from ~12 m. When the LOCAL climber touches it:
# CoopSync.lantern.add_oil(0.45), the sfx manifest "oil_pickup" sound, a short banner, and the
# flask vanishes FOR THIS PLAYER ONLY. Pickups are per player: nothing is synced.
#
# API FOR THE INTEGRATORS (underdark.gd)
#   const OilFlask := preload("res://mods-unpacked/zonda-CoopSync/maps/underdark/oil_flask.gd")
#   for e in L.get("oil", []):
#       var f: Node3D = OilFlask.new()
#       var d: Dictionary = (e as Dictionary).duplicate()
#       d["model"] = _ext_instance("ext/ph/metal_jug.glb", 0.5)   # optional; null/missing = built-in clay flask
#       d["map"] = self                                        # optional; lets it honour _debug_tour
#       f.setup(d)          # call BEFORE add_child
#       add_child(f)
#   setup(data: Dictionary)
#       data["id"]    String   required, e.g. "oil_3" (the key remembered as taken)
#       data["pos"]   [x,y,z]  required, the WALKABLE floor point the flask stands over
#       data["biome"] int      optional, only kept for debugging (var biome)
#       data["model"] Node3D   optional, a ready instance from the map's ext loader (it is
#                              re-parented here and scaled to ~0.36 m tall); else a primitive flask
#       data["map"]   Node3D   optional, the map; no pickup while map._debug_tour is true
#   var id: String, var biome: int, var taken: bool (read only)
#   func is_taken() -> bool
#   const OIL_AMOUNT := 0.45
#   const TAKEN_META := "zonda_oil_taken"
#   static func taken_ids() -> Dictionary     (the per-player set, see below)
#   static func clear_taken() -> void         (forget every pickup; call on a FRESH run)
#
# TAKEN IDS: kept on the CoopSync.lantern node so a death reload (the map rebuilt) does not
# bring a flask back. If lantern.gd declares `var oil_taken := {}` that Dictionary is used;
# otherwise a Dictionary in lantern meta "zonda_oil_taken". lantern.begin_oil_run(true) should
# empty it (oil_taken.clear(), or remove_meta("zonda_oil_taken")), or the map calls
# OilFlask.clear_taken() on a fresh run. The flask re-checks the set 4x a second, so the build
# order of flasks vs begin_oil_run() does not matter (a cleared set shows the flask again).
#
# FULL LANTERN: while lantern.oil_enabled and lantern.oil >= 0.98 the flask is NOT taken (it
# would be wasted); a short "Your lantern is full" banner shows instead (at most every 6 s).
#
# DEGRADES: no lantern / no add_oil() -> nothing is taken; no sfx manifest or file -> the game's
# heal sound; no model -> primitive flask. Sound uses bus "ZondaCave" when it exists.

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const SFX_DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/sfx/"
const PLAYER_LAYER := 4
const OIL_AMOUNT := 0.45
const TAKEN_META := "zonda_oil_taken"
const HEIGHT := 0.36             # flask height in metres
const HOVER := 0.14              # gap above the floor at the bottom of the bob
const BOB := 0.025               # bob amplitude, metres: very slight
const TOUCH_R := 1.4             # pickup sphere radius around the knight's body height
const GLOW_ENERGY := 0.35
const GLOW_RANGE := 4.0
const FULL_BANNER_GAP := 6.0

static var _sfx_loaded := false
static var _sfx_list: Array = []          # [[AudioStream, db], ...] for "oil_pickup"

var id := ""
var biome := -1
var taken := false

var _pos := Vector3.ZERO
var _map: Node3D = null
var _model: Node3D = null
var _pivot: Node3D
var _light: OmniLight3D
var _area: Area3D
var _t := 0.0
var _check_t := 0.0
var _full_t := 0.0
var _flick := 1.0
var _flick_target := 1.0
var _flick_t := 0.0


func setup(data: Dictionary) -> void:
	id = str(data.get("id", ""))
	biome = int(data.get("biome", -1))
	var p = data.get("pos", null)
	if p is Array and (p as Array).size() >= 3:
		_pos = Vector3(float(p[0]), float(p[1]), float(p[2]))
	elif p is Vector3:
		_pos = p
	var m = data.get("model", null)
	if m is Node3D and is_instance_valid(m):
		_model = m
	var mp = data.get("map", null)
	if mp is Node3D and is_instance_valid(mp):
		_map = mp
	_t = randf() * TAU                   # flasks never bob in step with each other


func _ready() -> void:
	position = _pos
	_pivot = Node3D.new()
	add_child(_pivot)
	if is_instance_valid(_model):
		_fit_model(_model)
		_pivot.add_child(_model)
	else:
		_build_primitive(_pivot)
	# the glow: a faint warm pool on the floor, which is what reads from 12 m in the dark
	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.62, 0.26)
	_light.light_energy = GLOW_ENERGY
	_light.omni_range = GLOW_RANGE
	_light.omni_attenuation = 1.2
	_light.shadow_enabled = false
	_light.light_specular = 0.0          # no glints on wet rock: no specks
	_light.light_volumetric_fog_energy = 0.0
	_light.distance_fade_enabled = true
	_light.distance_fade_begin = 40.0
	_light.distance_fade_length = 15.0
	_light.position = Vector3(0.0, HOVER + HEIGHT * 0.9, 0.0)
	_light.set_meta("zonda_no_shadow", true)   # the F4 shadow budget must leave it alone
	add_child(_light)
	_area = Area3D.new()
	_area.collision_layer = 0
	_area.collision_mask = PLAYER_LAYER
	var cs := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = TOUCH_R
	cs.shape = sph
	_area.add_child(cs)
	_area.position = Vector3(0.0, 0.9, 0.0)
	add_child(_area)
	_area.body_entered.connect(_on_body)
	_refresh_taken()


func is_taken() -> bool:
	return taken


# ---------------------------------------------------------------- taken set (per player)

static func _lantern() -> Node:
	var l = CoopSync.get("lantern")
	if l is Node and is_instance_valid(l):
		return l
	return null


static func taken_ids() -> Dictionary:
	var l := _lantern()
	if l == null:
		return {}
	var d = l.get("oil_taken")
	if d is Dictionary:
		return d
	if not l.has_meta(TAKEN_META):
		l.set_meta(TAKEN_META, {})
	var m = l.get_meta(TAKEN_META)
	if m is Dictionary:
		return m
	var fresh := {}
	l.set_meta(TAKEN_META, fresh)
	return fresh


static func clear_taken() -> void:
	var l := _lantern()
	if l == null:
		return
	var d = l.get("oil_taken")
	if d is Dictionary:
		(d as Dictionary).clear()
	if l.has_meta(TAKEN_META):
		l.remove_meta(TAKEN_META)


func _refresh_taken() -> void:
	var t := false
	if id != "":
		t = taken_ids().has(id)
	if t != taken or visible == t:
		taken = t
		visible = not t
		if is_instance_valid(_area):
			_area.monitoring = not t


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	_check_t -= delta
	if _check_t <= 0.0:
		_check_t = 0.25
		_refresh_taken()
		if not taken:
			_poll_touch()
	_full_t = maxf(0.0, _full_t - delta)
	if taken:
		return
	_t += delta
	_pivot.position.y = HOVER + BOB * (1.0 + sin(_t * 1.6))
	_pivot.rotation.y = _t * 0.35
	_pivot.rotation.z = sin(_t * 1.1) * 0.04
	# a slow, soft breathing of the glow: never a flash
	_flick_t -= delta
	if _flick_t <= 0.0:
		_flick_t = randf_range(0.25, 0.7)
		_flick_target = randf_range(0.85, 1.05)
	_flick = lerpf(_flick, _flick_target, clampf(delta * 3.0, 0.0, 1.0))
	_light.light_energy = GLOW_ENERGY * _flick


func _poll_touch() -> void:
	# body_entered misses a knight who is already standing in the sphere (e.g. the lantern was
	# full when he arrived and has burned down since, or the flask reappeared around him)
	var c = Game.climber
	if not is_instance_valid(c) or not (c as Node).is_inside_tree():
		return
	if not (c is Node3D) or (c as Node3D).global_position.distance_to(global_position) > TOUCH_R + 3.0:
		return
	if is_instance_valid(_area) and _area.monitoring and _area.overlaps_body(c):
		_try_take(c)


func _on_body(body: Node3D) -> void:
	var c = Game.climber
	if not is_instance_valid(c) or body != c:
		return
	_try_take(c)


func _try_take(c) -> void:
	if taken or id == "":
		return
	if not (c as Node).is_inside_tree():
		return
	if c.get("prevent_player_death") == true:
		return                          # the developer tour teleports through: never hand out oil
	if is_instance_valid(_map) and _map.get("_debug_tour") == true:
		return
	var hp = c.get("health")
	if (hp is float or hp is int) and float(hp) <= 0.0:
		return
	var l = _lantern()    # untyped: add_oil() lives on lantern.gd, not on Node
	if l == null or not l.has_method("add_oil"):
		return
	if l.get("oil_enabled") == true:
		var cur = l.get("oil")
		if (cur is float or cur is int) and float(cur) >= 0.98:
			if _full_t <= 0.0:
				_full_t = FULL_BANNER_GAP
				CoopSync.show_banner("Your lantern is full. The flask can wait.", 2.5)
			return
	taken = true
	taken_ids()[id] = true
	l.add_oil(OIL_AMOUNT)
	_play_pickup()
	var pct := ""
	var now = l.get("oil")
	if now is float or now is int:
		pct = "   (%d%%)" % int(round(clampf(float(now), 0.0, 1.0) * 100.0))
	CoopSync.show_banner("Lamp oil. Your lantern drinks it in." + pct, 2.5)
	visible = false
	if is_instance_valid(_area):
		_area.set_deferred("monitoring", false)


# ---------------------------------------------------------------- sound

static func _load_sfx() -> void:
	if _sfx_loaded:
		return
	_sfx_loaded = true
	var raw := FileAccess.get_file_as_string(SFX_DIR + "manifest.json")
	if raw == "":
		return
	var j = JSON.parse_string(raw)
	if not (j is Dictionary):
		return
	var os = (j as Dictionary).get("oneshots", {})
	if not (os is Dictionary):
		return
	var arr = (os as Dictionary).get("oil_pickup", [])
	if not (arr is Array):
		return
	for e in arr:
		if not (e is Dictionary):
			continue
		var f := str((e as Dictionary).get("file", ""))
		var db := float((e as Dictionary).get("db", 0.0))
		var st := _stream(f)
		if st != null:
			_sfx_list.append([st, db])


static func _stream(f: String) -> AudioStream:
	if f == "":
		return null
	if f.begins_with("res://sfx/") or f.begins_with("res://Art/") or (f.begins_with("res://") and not f.begins_with("res://mods-unpacked/")):
		var r = load(f)                  # a game file: imported, load() works
		if r is AudioStream:
			return r
		return null
	var path := f if f.begins_with("res://") else SFX_DIR + f
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var ext := path.get_extension().to_lower()
	if ext == "ogg":
		var o = AudioStreamOggVorbis.load_from_buffer(bytes)
		if o is AudioStream:
			return o
	elif ext == "wav":
		var w = AudioStreamWAV.load_from_buffer(bytes)
		if w is AudioStream:
			return w
	elif ext == "mp3":
		var m := AudioStreamMP3.new()
		m.data = bytes
		return m
	return null


func _play_pickup() -> void:
	_load_sfx()
	if _sfx_list.is_empty():
		var ga = Game.get("audio")
		if ga != null and is_instance_valid(ga) and ga.has_method("play_player_healed"):
			ga.play_player_healed()
		return
	var pick: Array = _sfx_list[randi() % _sfx_list.size()]
	var p := AudioStreamPlayer.new()      # your own hands: not positional
	p.stream = pick[0]
	p.volume_db = float(pick[1])
	if AudioServer.get_bus_index("ZondaCave") >= 0:
		p.bus = "ZondaCave"
	# parented to the map's tree root, so it finishes although this flask hides
	var host: Node = get_tree().current_scene if get_tree().current_scene != null else get_tree().root
	host.add_child(p)
	p.finished.connect(p.queue_free)
	p.play()


# ---------------------------------------------------------------- looks

func _fit_model(n: Node3D) -> void:
	if n.get_parent() != null:
		n.get_parent().remove_child(n)
	var lo := Vector3(INF, INF, INF)
	var hi := Vector3(-INF, -INF, -INF)
	var any := false
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var node: Node = m
		while node != null and node != n:
			if node is Node3D:
				xf = (node as Node3D).transform * xf
			node = node.get_parent()
		var ab: AABB = xf * m.mesh.get_aabb()
		lo = lo.min(ab.position)
		hi = hi.max(ab.end)
		any = true
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# matte and dark: the pool of light sells it, never a highlight speck
		for si in m.mesh.get_surface_count():
			var src: Material = m.get_active_material(si)
			if src is StandardMaterial3D:
				var d: StandardMaterial3D = (src as StandardMaterial3D).duplicate()
				d.emission_enabled = false
				d.metallic_specular = 0.0
				d.roughness = maxf(d.roughness, 0.8)
				d.albedo_color = Color(minf(d.albedo_color.r, 0.06), minf(d.albedo_color.g, 0.05), minf(d.albedo_color.b, 0.04), d.albedo_color.a)
				m.set_surface_override_material(si, d)
	if not any:
		return
	var h: float = hi.y - lo.y
	var s: float = HEIGHT / h if h > 0.01 else 1.0
	n.scale = Vector3.ONE * s
	# stand its base on the pivot and centre it on the bob axis
	var c := (lo + hi) * 0.5
	n.position = Vector3(-c.x * s, -lo.y * s, -c.z * s)


func _build_primitive(parent: Node3D) -> void:
	# a squat clay oil flask: round belly, short neck, a dark cork, a thin strap
	var clay := StandardMaterial3D.new()
	clay.albedo_color = Color(0.055, 0.034, 0.02)
	clay.roughness = 1.0
	clay.metallic_specular = 0.0
	# the oil inside warms the clay a touch: far below the white clip, no speck
	clay.emission_enabled = true
	clay.emission = Color(0.03, 0.014, 0.004)
	clay.emission_energy_multiplier = 0.6
	var dark := StandardMaterial3D.new()
	dark.albedo_color = Color(0.022, 0.016, 0.012)
	dark.roughness = 1.0
	dark.metallic_specular = 0.0
	var belly := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.12
	sm.height = 0.22
	sm.radial_segments = 12
	sm.rings = 6
	belly.mesh = sm
	belly.material_override = clay
	belly.position = Vector3(0.0, 0.11, 0.0)
	var neck := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.032
	cm.bottom_radius = 0.045
	cm.height = 0.1
	cm.radial_segments = 8
	neck.mesh = cm
	neck.material_override = clay
	neck.position = Vector3(0.0, 0.255, 0.0)
	var cork := MeshInstance3D.new()
	var km := CylinderMesh.new()
	km.top_radius = 0.026
	km.bottom_radius = 0.03
	km.height = 0.05
	km.radial_segments = 8
	cork.mesh = km
	cork.material_override = dark
	cork.position = Vector3(0.0, 0.33, 0.0)
	var strap := MeshInstance3D.new()
	var tm := TorusMesh.new()
	tm.inner_radius = 0.118
	tm.outer_radius = 0.132
	tm.rings = 12
	tm.ring_segments = 4
	strap.mesh = tm
	strap.material_override = dark
	strap.position = Vector3(0.0, 0.12, 0.0)
	for mi in [belly, neck, cork, strap]:
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		parent.add_child(mi)
