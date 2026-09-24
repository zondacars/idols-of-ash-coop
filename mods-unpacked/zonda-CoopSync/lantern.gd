extends Node

# The hand lantern, on every level: campaign, sandbox maps, custom maps. A caged flame in
# your right hand that glows around you and throws a beam ahead, flickers and gusts.
# L switches it on or off, remembered per player. A map can set a default (the Underdark's
# LANTERN mode turns it on); the player's L choice wins until the map changes that default.
# Teammates see it in your knight's hand (CoopSync.lantern_on rides in the state packet).
#
# LAMP OIL (v4.9, K10). Off everywhere unless a map turns it on (the Underdark does):
#   var oil := 1.0            0..1 of a full lantern
#   var oil_enabled := false  a map sets it true while it runs; it switches itself off again when
#                             the scene changes, so other levels never drain
#   const OIL_SECONDS := 720.0   lit seconds in a full lantern
#   var oil_taken := {}       flask ids this player already took (oil_flask.gd), kept across a
#                             death reload, emptied by begin_oil_run(true)
#   func begin_oil_run(fresh: bool)   fresh = full tank + every flask back; false = a death
#                             reload, keeps the level. Also turns oil_enabled on.
#   func add_oil(x: float)    a flask (0.45) or a teammate's gift
#   func give_oil(peer_id: int) -> bool   0.25 of yours to a teammate within 3 m (needs 0.3)
#   func receive_oil(x: float, from_name: String)   coop_sync calls it for an "oil" message
#   func is_dry() -> bool     oil is on and the lantern is empty
# Below 15% the flame dims and gutters; at 0 it goes out and L only says "Out of oil" until the
# lantern is refilled. Hold G next to a teammate (3 m) to pour them a quarter of yours. A small
# dim gauge sits bottom-right while oil is on and the lantern is lit or empty.

const CFG := "user://zonda_lantern.cfg"
const MOD_DIR := "res://mods-unpacked/zonda-CoopSync/"
const RemoteScript := preload("res://mods-unpacked/zonda-CoopSync/remote_player.gd")

var user := -1                 # -1 follow the map default, 0 forced off, 1 forced on
var default_on := false
var _root: Node3D
var _light: OmniLight3D
var _spot: SpotLight3D
var _t := 0.0
var _flash := 0.0
var _next := 2.0
var _dot: GradientTexture2D
var _test := false
var _test_t := 0.0
# Rock right in front of the flame: at under ~2.5 m the lantern blew the wall out to flat white.
# A throttled ray scales the light down smoothly there; at normal range it is untouched.
const NEAR_DIST := 2.5
const NEAR_MIN := 0.22
var _near_k := 1.0
var _near_target := 1.0
var _near_t := 0.0

const OIL_SECONDS := 720.0
const OIL_LOW := 0.15
const OIL_GIVE := 0.25
const OIL_GIVE_MIN := 0.3
const GIVE_REACH := 3.0
const GIVE_HOLD_S := 0.6
var oil := 1.0
var oil_enabled := false:
	set(value):
		oil_enabled = value
		_oil_scene = ""                 # filled on the next frame, once the new scene is current
var oil_taken := {}
var _oil_scene := ""
var _dry_warned := false
var _low_warned := false
var _gutter := 0.0
var _gutter_next := 1.0
var _g_held := false
var _g_done := false                # one gift per press of G
var _g_t := 0.0
var _g_msg_ms := -100000
var _gauge_layer: CanvasLayer = null
var _gauge_fill: ColorRect = null
var _gauge_label: Label = null
const GAUGE_W := 64.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cf := ConfigFile.new()
	if cf.load(CFG) == OK:
		user = clampi(int(cf.get_value("lantern", "user", -1)), -1, 1)
	_test = FileAccess.file_exists(MOD_DIR + "lantern_test.flag")
	if _test:
		DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/lantern_test.flag")
	_build_gauge()


func wanted() -> bool:
	if user >= 0:
		return user == 1
	return default_on


func set_default(on: bool, keep_user: bool = false) -> void:
	default_on = on
	if not keep_user and user != -1:
		user = -1
		_save()


func toggle() -> void:
	user = 0 if wanted() else 1
	_save()
	CoopSync.show_banner("Lantern: %s   (L to toggle)" % ("ON" if user == 1 else "OFF"), 2.5)


func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("lantern", "user", user)
	cf.save(CFG)


func _unhandled_input(event: InputEvent) -> void:
	# unhandled, so typing an L (or a G) in the lobby's name box never reaches the lantern
	if not (event is InputEventKey) or event.echo:
		return
	var k := event as InputEventKey
	if k.keycode == KEY_L and k.pressed:
		var c = Game.climber
		if is_instance_valid(c) and c.is_inside_tree():
			if is_dry():
				CoopSync.show_banner("Out of oil. Find a flask, or ask a teammate to share (they hold G).", 3.0)
			else:
				toggle()
			get_viewport().set_input_as_handled()
	elif k.keycode == KEY_G:
		if k.pressed:
			if oil_enabled and not _g_held:
				_g_held = true
				_g_done = false
				_g_t = 0.0
		else:
			_g_held = false


# ---------------------------------------------------------------- lamp oil

func is_dry() -> bool:
	return oil_enabled and oil <= 0.0


func begin_oil_run(fresh: bool) -> void:
	oil_enabled = true
	if fresh:
		oil = 1.0
		oil_taken.clear()
		if has_meta("zonda_oil_taken"):
			remove_meta("zonda_oil_taken")
	oil = clampf(oil, 0.0, 1.0)
	_dry_warned = oil <= 0.0
	_low_warned = oil < OIL_LOW


func add_oil(x: float) -> void:
	if x <= 0.0:
		return
	var was_dry := is_dry()
	oil = clampf(oil + x, 0.0, 1.0)
	if oil > 0.0:
		_dry_warned = false
	if oil >= OIL_LOW:
		_low_warned = false
	if was_dry and wanted():
		_flash = 1.2                        # the flame catches again with a small flare


func receive_oil(x: float, from_name: String) -> void:
	var amount := clampf(x, 0.0, 0.5)
	add_oil(amount)
	CoopSync.show_banner("%s poured you some lamp oil (+%d%%). Oil %d%%." % [from_name, int(round(amount * 100.0)), int(round(oil * 100.0))], 3.5)


func give_oil(peer_id: int) -> bool:
	# 0.25 of yours to a living teammate within 3 m, when you have at least 0.3
	if not oil_enabled or oil < OIL_GIVE_MIN:
		return false
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree() or c.get("coop_spectating"):
		return false
	var rp = null
	for r in CoopSync.remote_players():
		if int(r.peer_id) == peer_id:
			rp = r
	if rp == null or _reach_dist(c, rp) > _give_reach():
		return false
	oil = maxf(0.0, oil - OIL_GIVE)
	CoopSync.send_oil(peer_id, OIL_GIVE)
	CoopSync.show_banner("You poured %s some lamp oil (-%d%%). Oil %d%%." % [str(rp.player_name), int(OIL_GIVE * 100.0), int(round(oil * 100.0))], 3.5)
	return true


func _nearest_teammate(c: Node3D):
	var best = null
	var bd := _give_reach()
	for r in CoopSync.remote_players():
		var d: float = _reach_dist(c, r)
		if d <= bd:
			bd = d
			best = r
	return best


func _reach_dist(c: Node3D, r: Node3D) -> float:
	# side by side: the flat distance counts. The two nodes' origins sit at different heights on
	# the body (a remote knight's is 0.78 m above its feet), so up to 2 m of height is ignored
	var d: Vector3 = r.global_position - c.global_position
	if absf(d.y) > 2.0:
		return INF
	return Vector2(d.x, d.z).length()


func _give_reach() -> float:
	# the loopback Ghost always stands 3.5 m ahead of your view, so the harness gets 4.5 m
	return 4.5 if bool(CoopSync.get("_loopback")) else GIVE_REACH


func _give_banner(text: String) -> void:
	var now := Time.get_ticks_msec()
	if now - _g_msg_ms > 1500:
		_g_msg_ms = now
		CoopSync.show_banner(text, 2.0)


func _update_give(delta: float, c: Node3D) -> void:
	if _g_held:
		var down := Input.is_physical_key_pressed(KEY_G) or Input.is_key_pressed(KEY_G)
		if not down or not DisplayServer.window_is_focused():
			_g_held = false                 # a missed key-up (focus moved away) never keeps it held
	if not _g_held or _g_done:
		_g_t = 0.0
		return
	if c.get("coop_spectating"):
		_g_done = true
		return
	var rp = _nearest_teammate(c)
	if rp == null:
		_g_done = true
		_give_banner("Stand next to a teammate (3 m) and hold G to share your oil.")
		return
	if oil < OIL_GIVE_MIN:
		_g_done = true
		_give_banner("You need at least %d%% oil to share." % int(OIL_GIVE_MIN * 100.0))
		return
	var their: int = int(rp.get("oil_pct")) if rp.get("oil_pct") != null else -1
	if their >= 90:
		_g_done = true
		_give_banner("%s's lantern is already full." % str(rp.player_name))
		return
	_g_t += delta
	CoopSync.show_banner("Pouring oil for %s...  keep holding G" % str(rp.player_name), 0.3)
	if _g_t >= GIVE_HOLD_S:
		_g_done = true
		give_oil(int(rp.peer_id))


func _update_oil(delta: float, c: Node3D, lit: bool) -> void:
	if not oil_enabled:
		return
	var scene := get_tree().current_scene
	var sp: String = scene.scene_file_path if scene else ""
	if _oil_scene.is_empty():
		_oil_scene = sp
	elif sp != _oil_scene:
		oil_enabled = false                 # another level: the map that wanted oil is gone
		_g_held = false
		return
	_update_give(delta, c)
	if not lit or get_tree().paused or SceneLoader.is_transitioning() or c.get("coop_spectating"):
		return
	if c.get("prevent_player_death"):
		return                              # the developer tour never burns oil
	oil = maxf(0.0, oil - delta / OIL_SECONDS)
	if oil < OIL_LOW and not _low_warned:
		_low_warned = true
		CoopSync.show_banner("Your lantern is running low on oil.", 3.0)
	if oil <= 0.0 and not _dry_warned:
		_dry_warned = true
		CoopSync.show_banner("Your lantern has run dry. Find a flask of oil, or ask a teammate to share (G).", 5.0)


func _oil_factor(delta: float) -> float:
	# 1 above 15%; below it the flame shrinks toward a quarter and gutters (sudden dips)
	if not oil_enabled or oil >= OIL_LOW:
		_gutter = 0.0
		return 1.0
	var k := clampf(oil / OIL_LOW, 0.0, 1.0)
	_gutter_next -= delta
	if _gutter_next <= 0.0:
		_gutter = 1.0
		_gutter_next = randf_range(0.25, 0.6) + 1.4 * k
	_gutter = maxf(0.0, _gutter - delta * 5.0)
	return lerpf(0.25, 1.0, k) * (1.0 - 0.65 * _gutter * (1.0 - 0.5 * k))


func _dot_tex() -> GradientTexture2D:
	if _dot == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		_dot = GradientTexture2D.new()
		_dot.gradient = g
		_dot.fill = GradientTexture2D.FILL_RADIAL
		_dot.fill_from = Vector2(0.5, 0.5)
		_dot.fill_to = Vector2(0.5, 0.0)
		_dot.width = 64
		_dot.height = 64
	return _dot


func _process(delta: float) -> void:
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		CoopSync.lantern_on = false
		_g_held = false
		_update_gauge(false)
		return
	var cam = c.get("Camera")                      # the Camera3D itself: view space
	if not (cam is Node3D):
		_update_gauge(false)
		return
	if not is_instance_valid(_root) or _root.get_parent() != cam:
		if is_instance_valid(_root):
			_root.queue_free()
		var pair: Array = RemoteScript.build_cage_lantern(_dot_tex(), 6.0, 20.0, true)
		_root = pair[0]
		_light = pair[1]
		_spot = pair[2]
		# the Underdark's carried idol sits on render layer 20 a metre from this flame: skip it
		_light.light_cull_mask = ~(1 << 19)
		if is_instance_valid(_spot):
			_spot.light_cull_mask = ~(1 << 19)
		_root.position = Vector3(0.52, -0.33, -0.62)     # lower right of the view, out of the way
		cam.add_child(_root)
	var on := wanted() and not is_dry()
	_update_oil(delta, c, on)
	on = wanted() and not is_dry()                  # it may have just run dry (or left oil) this frame
	if _root.visible != on:
		_root.visible = on
	CoopSync.lantern_on = on
	_update_gauge(oil_enabled and (on or is_dry()) and not c.get("coop_spectating"))
	if _test:
		_update_test(delta)
	if not on:
		return
	_t += delta
	_next -= delta
	if _next <= 0.0:
		_flash = randf_range(0.9, 1.8)                 # a gust: bright for a moment, then settles
		_next = randf_range(1.2, 4.0)
	_flash = maxf(0.0, _flash - delta * 3.0)
	_near_t -= delta
	if _near_t <= 0.0:
		_near_t = 0.1
		_near_target = _near_factor(cam)
	_near_k = lerpf(_near_k, _near_target, clampf(delta * 6.0, 0.0, 1.0))
	var f := (0.8 + 0.12 * sin(_t * 8.3) + 0.06 * sin(_t * 21.0)) * (1.0 + _flash) * _near_k * _oil_factor(delta)
	_light.light_energy = 5.0 * f
	_light.omni_range = 18.0 + 6.0 * _flash
	if is_instance_valid(_spot):
		_spot.light_energy = 7.0 * f
		_spot.spot_range = 34.0 + 8.0 * _flash
	var moving: float = clampf(Vector2(c.velocity.x, c.velocity.z).length() / 5.0, 0.0, 1.0)
	_root.position = Vector3(0.52, -0.33 + sin(_t * 6.0) * 0.006 * (0.3 + moving), -0.62)
	_root.rotation.z = sin(_t * 2.4) * 0.05 * (0.4 + moving)


func _near_factor(cam: Node3D) -> float:
	# 1.0 unless rock is closer than NEAR_DIST straight ahead of the eye or of the flame itself
	var w: World3D = cam.get_world_3d()
	if w == null:
		return 1.0
	var space: PhysicsDirectSpaceState3D = w.direct_space_state
	if space == null:
		return 1.0
	var fwd: Vector3 = -cam.global_basis.z
	var best: float = NEAR_DIST
	for src in [cam.global_position, _root.global_position]:
		var o: Vector3 = src
		var q := PhysicsRayQueryParameters3D.create(o, o + fwd * NEAR_DIST, 1)
		var hit: Dictionary = space.intersect_ray(q)
		if not hit.is_empty():
			best = minf(best, o.distance_to(hit["position"]))
	return lerpf(NEAR_MIN, 1.0, smoothstep(0.4, NEAR_DIST, best))


# ---------------------------------------------------------------- oil gauge (bottom-right)

func _build_gauge() -> void:
	_gauge_layer = CanvasLayer.new()
	_gauge_layer.layer = 91
	_gauge_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var box := Control.new()
	box.anchor_left = 1.0
	box.anchor_right = 1.0
	box.anchor_top = 1.0
	box.anchor_bottom = 1.0
	box.offset_left = -GAUGE_W - 14.0
	box.offset_right = -14.0
	box.offset_top = -30.0
	box.offset_bottom = -12.0
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gauge_layer.add_child(box)
	_gauge_label = Label.new()
	_gauge_label.text = "OIL"
	_gauge_label.position = Vector2(0.0, -2.0)
	_gauge_label.size = Vector2(GAUGE_W, 12.0)
	_gauge_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ls := LabelSettings.new()
	ls.font_size = 9
	ls.outline_size = 3
	ls.outline_color = Color.BLACK
	ls.font_color = Color(0.72, 0.62, 0.42, 0.75)
	_gauge_label.label_settings = ls
	box.add_child(_gauge_label)
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.5)
	bg.position = Vector2(0.0, 12.0)
	bg.size = Vector2(GAUGE_W, 5.0)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(bg)
	_gauge_fill = ColorRect.new()
	_gauge_fill.color = Color(0.5, 0.36, 0.14, 0.85)
	_gauge_fill.position = Vector2(1.0, 13.0)
	_gauge_fill.size = Vector2(GAUGE_W - 2.0, 3.0)
	_gauge_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(_gauge_fill)
	_gauge_layer.visible = false
	add_child(_gauge_layer)


func _update_gauge(show: bool) -> void:
	if not is_instance_valid(_gauge_layer):
		return
	if _gauge_layer.visible != show:
		_gauge_layer.visible = show
	if not show:
		return
	var k := clampf(oil, 0.0, 1.0)
	_gauge_fill.size = Vector2(maxf(0.0, (GAUGE_W - 2.0) * k), 3.0)
	_gauge_fill.color = Color(0.5, 0.16, 0.08, 0.85) if k < OIL_LOW else Color(0.5, 0.36, 0.14, 0.85)
	var txt := "OIL  EMPTY" if k <= 0.0 else "OIL  %d%%" % int(ceil(k * 100.0))
	if _gauge_label.text != txt:
		_gauge_label.text = txt


func _update_test(delta: float) -> void:
	# developer only (lantern_test.flag in the mod folder): on whatever level loads, force the
	# lantern on after 6 s, save user://lantern_test.png at 9 s, then put the setting back
	_test_t += delta
	if _test_t > 6.0 and user != 1:
		set_default(true, false)
	if _test_t > 9.0:
		var img := get_viewport().get_texture().get_image()
		if img:
			if img.get_width() > 960:
				img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
			img.save_png("user://lantern_test.png")
		print("[CoopSync] lantern test shot on ", CoopSync._last_scene_path, " lantern on=", str(wanted()))
		user = -1
		_save()
		_test = false
