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
#   const OIL_SECONDS := 1800.0   lit seconds in a full lantern
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
#
# v5.0 (build contract 2.6):
#   var burn_mult := 1.0      the omen THIRST sets 2.0 (oil burns delta * burn_mult / OIL_SECONDS);
#                             the gauge then reads "OIL  64% x2". The map resets it in _exit_tree.
#   var curse_dim := 1.0      computed every frame: 1.0, or down to 0.5 while you carry a heavy idol
#                             (W = CoopSync.idol_weight * 0.4 seconds of weight, dims from W 10 to 30)
#   func curse_flare()        the idol burn's 0.6 s telegraph: a bright flare of the flame
#   func export_oil() -> Dictionary   {"oil": float, "taken": [flask id Strings]} (the SAVE)
#   func import_oil(d)        sets oil and the taken flasks EXACTLY (no floor), then calls
#                             current_scene.coop_oil_imported() when the map has it
#   const RELIGHT_MIN := 0.25 owner decision 1: a death reload (solo death or team wipe) relights the
#                             lantern to at least 25% at the checkpoint fire ("You relit your lantern at
#                             the fire."); a co-op respawn or revive does the same ("You relit your
#                             lantern."). A SAVE continue (CoopSync.continue_load) keeps the exact oil.
#   While you carry the idol (CoopSync.idol_carrier), G never pours oil: the idol module owns G.
#   The cage is tinted red for the idol holder and wears the omen trophy charm through LanternLook
#   (lantern_look.gd, loaded at runtime: a missing or broken file only drops the looks).
#   relight.flag (mod root, developer only): the A-RELIGHT test, tag [RELIGHT].

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
const NEAR_MIN := 0.32                  # 0.22 left a wall right in front of you the darkest thing on screen; 0.5 burned close planks white (09-25 test)
# how the flame lights the rock (your own lantern; teammates' lanterns stay cheap):
const OWN_ATTENUATION := 0.8            # < 1 spreads the light further: walls 5-10 m away light up, the nearest rock burns less
const OWN_SPECULAR := 1.0               # the rock's sheen catches the flame (the game default is 0.5)
const OWN_INDIRECT := 1.6               # bounce light: a lit wall warms the floor beside it (ULTRA HD's bounce lighting)
# v5.0 lighting design (R11): every surface's sheen is tuned to OWN_SPECULAR at the steady flame. A gust
# multiplies the energy by up to ~3.4 and already clips the diffuse, so the specular is divided by
# (1 + OWN_SPEC_GUST x gust): a gust brightens the rock, never flares its highlight into a white blob.
# Close to a wall (near_k < 1) the sheen fades with it. light_specular = OWN_SPECULAR x near_k / (1 + 0.6 x gust).
const OWN_SPEC_GUST := 0.6
var test_hold_f := -1.0                 # dev tests (surfaces.flag): >= 0 freezes flicker and gusts at this strength
var test_spec_k := 1.0                  # dev tests: 0 = the flame paints no sheen (the B shot)
var _near_k := 1.0
var _near_target := 1.0
var _near_t := 0.0

const OIL_SECONDS := 1800.0          # v5.1.1: 30 min lit (was 12, owner: "runs out tooooo quick")
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

# v5.0
const RELIGHT_MIN := 0.25
const LOOK_PATH := "res://mods-unpacked/zonda-CoopSync/lantern_look.gd"
var burn_mult := 1.0
var curse_dim := 1.0
var relights := 0                   # relight top-ups this launch (tests read it)
var last_relight_text := ""         # the banner of the last top-up
var last_relight_log := ""          # and its log line
var last_relight_oil := -1.0        # and the oil right after it (the lamp burns on from there)
var _look = null                    # lantern_look.gd (another builder's file): statics called via callv
var _look_fns: Dictionary = {}      # its static function names
var _look_warned := false
var _tint_state := -1               # the cage tint last applied (0 normal, 1 idol), -1 = never
var _charm_state := -1              # the omen charm tier last applied, -1 = never
var _down_id := 0                   # the climber instance the respawn watch follows
var _was_down := false              # that climber was respawning or spectating last frame
var _rl_test := false               # relight.flag


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var cf := ConfigFile.new()
	if cf.load(CFG) == OK:
		user = clampi(int(cf.get_value("lantern", "user", -1)), -1, 1)
	_test = FileAccess.file_exists(MOD_DIR + "lantern_test.flag")
	if _test:
		DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/lantern_test.flag")
	_build_gauge()
	_load_look()
	if FileAccess.file_exists(MOD_DIR + "relight.flag"):
		# developer flags are one-shot: read, then deleted, so one can never follow a player into a real run
		DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/relight.flag")
		_rl_test = true
		_relight_test.call_deferred()


# ---------------------------------------------------------------- LanternLook (lantern_look.gd, B3)

func _load_look() -> void:
	# another builder's new file: loaded at runtime, never preloaded, so a missing or broken file
	# can only drop the looks (build contract 1A.1)
	if not FileAccess.file_exists(LOOK_PATH):
		push_warning("[CoopSync] lantern_look.gd is missing: no idol tint or omen charm on the lantern")
		return
	var s = load(LOOK_PATH)
	if not (s is Script) or not (s as Script).can_instantiate():
		push_warning("[CoopSync] lantern_look.gd did not load: no idol tint or omen charm on the lantern")
		return
	_look = s
	for m in (s as Script).get_script_method_list():
		_look_fns[str(m.get("name", ""))] = true


func _look_call(fn: String, args: Array) -> void:
	if _look == null:
		return
	if not _look_fns.has(fn):
		if not _look_warned:
			_look_warned = true
			push_warning("[CoopSync] lantern_look.gd has no %s(): the lantern keeps its plain look" % fn)
		return
	_look.callv(fn, args)


func _energy_k() -> float:
	# LanternLook's red idol tint asks for a little more light through meta "zonda_energy_k"
	if is_instance_valid(_light) and _light.has_meta("zonda_energy_k"):
		return float(_light.get_meta("zonda_energy_k"))
	if is_instance_valid(_root) and _root.has_meta("zonda_energy_k"):
		return float(_root.get_meta("zonda_energy_k"))
	return 1.0


func curse_flare() -> void:
	# the idol burn's telegraph (0.6 s before the tick): the flame flares
	_flash = maxf(_flash, 1.0)


func _update_curse() -> void:
	if bool(CoopSync.idol_carrier):
		var w: float = float(CoopSync.idol_weight) * 0.4
		curse_dim = lerpf(1.0, 0.5, clampf((w - 10.0) / 20.0, 0.0, 1.0))
	else:
		curse_dim = 1.0


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
	if not fresh and not bool(CoopSync.continue_load):
		# owner decision 1: a death reload (solo death, or a team wipe) relights the lantern at the
		# checkpoint fire to at least 25%. A SAVE continue keeps the exact saved oil instead.
		var before := oil
		oil = maxf(oil, RELIGHT_MIN)
		if oil > before:
			_relit("You relit your lantern at the fire.", "[OIL] relit at the fire %.2f -> %.2f" % [before, oil])
	_dry_warned = oil <= 0.0
	_low_warned = oil < OIL_LOW


func _relit(banner: String, line: String) -> void:
	_dry_warned = false
	relights += 1
	last_relight_text = banner
	last_relight_log = line
	last_relight_oil = oil
	CoopSync.show_banner(banner, 4.0)
	print(line)


func _watch_respawn(c: Node3D) -> void:
	# owner decision 1 for co-op: a respawn or a revive (the climber was respawning or spectating and
	# comes back with health) also tops the lantern up to 25%. ext/climber.gd is frozen: read with get().
	var down: bool = bool(c.get("_coop_respawning")) or bool(c.get("coop_spectating"))
	var cid := c.get_instance_id()
	if cid != _down_id:
		_down_id = cid
		_was_down = down
		return
	if _was_down and not down and oil_enabled and float(c.get("health")) > 0.0:
		var before := oil
		oil = maxf(oil, RELIGHT_MIN)
		if oil > before:
			_low_warned = oil < OIL_LOW
			_relit("You relit your lantern.", "[OIL] relit on respawn %.2f -> %.2f" % [before, oil])
	_was_down = down


func export_oil() -> Dictionary:
	# the SAVE's per-player entry: the oil level and the flasks this player already took
	var taken: Array = []
	for k in oil_taken.keys():
		taken.append(str(k))
	return {"oil": oil, "taken": taken}


func import_oil(d: Dictionary) -> void:
	# a SAVE continue: oil and taken flasks come back EXACTLY (no relight floor)
	oil = clampf(float(d.get("oil", oil)), 0.0, 1.0)
	oil_taken.clear()
	var t = d.get("taken", [])
	if t is Array:
		for k in t:
			oil_taken[str(k)] = true
	_dry_warned = oil <= 0.0
	_low_warned = oil < OIL_LOW
	print("[OIL] imported %.3f, %d flasks taken" % [oil, oil_taken.size()])
	var root := get_tree().current_scene if is_inside_tree() else null
	if root != null and root.has_method("coop_oil_imported"):
		root.call("coop_oil_imported")


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
	if CoopSync.idol_carrier:
		# while you carry the idol, G passes it (idol_host.gd) and never pours oil
		_g_done = true
		_g_t = 0.0
		return
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
	oil = maxf(0.0, oil - delta * burn_mult / OIL_SECONDS)
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
	var rebuilt := false
	if not is_instance_valid(_root) or _root.get_parent() != cam:
		if is_instance_valid(_root):
			_root.queue_free()
		var pair: Array = RemoteScript.build_cage_lantern(_dot_tex(), 6.0, 20.0, true)
		_root = pair[0]
		_light = pair[1]
		_spot = pair[2] if pair.size() > 2 else null
		# the Underdark's carried idol sits on render layer 20 a metre from this flame: skip it
		_light.light_cull_mask = ~(1 << 19)
		_light.omni_attenuation = OWN_ATTENUATION
		_light.light_specular = OWN_SPECULAR
		_light.light_indirect_energy = OWN_INDIRECT
		if is_instance_valid(_spot):
			_spot.light_cull_mask = ~(1 << 19)
			_spot.light_specular = OWN_SPECULAR
			_spot.light_indirect_energy = OWN_INDIRECT
		_root.position = Vector3(0.52, -0.33, -0.62)     # lower right of the view, out of the way
		cam.add_child(_root)
		rebuilt = true
	# the idol holder's red cage and the omen trophy charm (LanternLook), on a rebuild or a change
	var tint := 1 if bool(CoopSync.idol_carrier) else 0
	if rebuilt or tint != _tint_state:
		_tint_state = tint
		_look_call("tint_cage_lantern", [_root, _light, _spot, tint == 1])
	var tier := int(CoopSync.omen_tier)
	if rebuilt or tier != _charm_state:
		_charm_state = tier
		_look_call("set_charm", [_root, tier])
	_update_curse()
	_watch_respawn(c)
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
	if test_hold_f >= 0.0:
		_flash = 0.0                                   # dev test: no gusts while a shot is framed
	_near_t -= delta
	if _near_t <= 0.0:
		_near_t = 0.1
		_near_target = _near_factor(cam)
	_near_k = lerpf(_near_k, _near_target, clampf(delta * 6.0, 0.0, 1.0))
	var f := (0.8 + 0.12 * sin(_t * 8.3) + 0.06 * sin(_t * 21.0)) * (1.0 + _flash) * _near_k * _oil_factor(delta) * curse_dim * _energy_k()
	if test_hold_f >= 0.0:
		f = test_hold_f * _near_k                      # dev test: a steady flame at this strength
	_light.light_energy = 5.0 * f
	_light.omni_range = 18.0 + 6.0 * _flash
	var sp := OWN_SPECULAR * _near_k / (1.0 + OWN_SPEC_GUST * _flash) * test_spec_k
	_light.light_specular = sp
	if is_instance_valid(_spot):
		_spot.light_energy = 7.0 * f
		_spot.spot_range = 34.0 + 8.0 * _flash
		_spot.light_specular = sp
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
	if burn_mult > 1.01:
		# the omen THIRST: the lantern drinks faster ("OIL  64% x2")
		txt += " x" + (str(int(round(burn_mult))) if absf(burn_mult - round(burn_mult)) < 0.01 else "%.2f" % burn_mult)
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


# ---------------------------------------------------------------- relight.flag (developer only, A-RELIGHT)
# Autostart THE UNDERDARK with relight.flag in the mod folder. Tag [RELIGHT].
#   1. park on checkpoint 2 (THE FAR WALL), empty the lantern and die: after the death reload the
#      lantern is relit at the fire ("[OIL] relit at the fire 0.00 -> 0.25", the banner, and the oil the
#      relight left, last_relight_oil, >= 0.25: the lit lamp burns on after it)
#   2. park about 12 m from the nearest ossuary_low Shade home (map.feature("shades").homes()) on a
#      real floor with a line of sight to it (_rl_spot_near), lantern on, facing away, for 20 s: no
#      Shade strike (shades.gd _struck; the health check only when that cannot be read)
# The death reload spans a scene change: this node lives on (CoopSync child), and the user://
# marker zonda_relight_test.txt records the phase. prevent_player_death is restored at the end.

const RL_MARK := "user://zonda_relight_test.txt"
var _rl_pass := 0
var _rl_total := 0
var _rl_fails: Array = []


func _rl_check(ok: bool, what: String) -> void:
	_rl_total += 1
	if ok:
		_rl_pass += 1
	else:
		_rl_fails.append(what)
	print("[RELIGHT] %s %s" % ["PASS" if ok else "FAIL", what])


func _rl_wait(secs: float) -> void:
	await get_tree().create_timer(secs, true).timeout


func _rl_map() -> Node:
	# the Underdark once it has announced its load (CoopSync.map_loaded), else null
	var root := get_tree().current_scene
	if root == null or not str(root.scene_file_path).ends_with("underdark.tscn"):
		return null
	if root.has_method("load_announced") and not bool(root.call("load_announced")):
		return null
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return null
	return root


func _rl_park(root: Node, pos: Vector3) -> void:
	var c = Game.climber
	if root.has_method("debug_park"):
		root.call("debug_park", pos)
	else:
		c.set_climber_state(c.defaultClimberState)
		c.velocity = Vector3.ZERO
		c.teleport_to_location(pos)


func _rl_mark(phase: String) -> void:
	var f := FileAccess.open(RL_MARK, FileAccess.WRITE)
	if f != null:
		f.store_string(phase)
		f.close()


func _relight_test() -> void:
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")
	print("[RELIGHT] test armed: waiting for THE UNDERDARK")
	_rl_mark("1")
	var root: Node = null
	for _i in 240:
		root = _rl_map()
		if root != null:
			break
		await _rl_wait(0.5)
	if root == null:
		_rl_check(false, "map loaded")
		_rl_finish()
		return
	await _rl_wait(4.0)
	root = _rl_map()
	if root == null:
		_rl_check(false, "map still loaded after 4 s")
		_rl_finish()
		return
	var scene: String = str(root.scene_file_path)
	var lay = root.get("L")
	var cp_pos := Vector3.INF
	if lay is Dictionary:
		for k in (lay as Dictionary).get("checkpoints", []):
			if int(k.get("id", -1)) == 2:
				var p: Array = k["pos"]
				cp_pos = Vector3(float(p[0]), float(p[1]), float(p[2]))
	if cp_pos == Vector3.INF:
		_rl_check(false, "checkpoint 2 in the layout")
		_rl_finish()
		return
	# phase 1: checkpoint 2, dry lantern, death
	var c = Game.climber
	c.prevent_player_death = true
	_rl_park(root, cp_pos + Vector3(0.5, 0.2, 0.5))
	await _rl_wait(1.5)
	CoopSync.map_checkpoint(2, scene)
	await _rl_wait(1.0)
	_rl_check(CoopSync.map_checkpoint_for(scene) >= 2, "checkpoint 2 reached (team checkpoint %d)" % CoopSync.map_checkpoint_for(scene))
	_rl_mark("2")
	oil = 0.0
	_dry_warned = true
	var before_relights := relights
	var old_id: int = c.get_instance_id()
	print("[RELIGHT] oil set to 0.00, dying at checkpoint 2")
	c.prevent_player_death = false
	c.health = 0.0
	c.took_lethal_damage()
	# the death reload: a new climber in a new Underdark
	var back := false
	for _i in 120:
		await _rl_wait(0.5)
		var r2 := _rl_map()
		if r2 != null and is_instance_valid(Game.climber) and Game.climber.get_instance_id() != old_id:
			back = true
			Game.climber.prevent_player_death = true
			break
	if not back:
		_rl_check(false, "death reload came back")
		_rl_finish()
		return
	await _rl_wait(2.0)
	root = _rl_map()
	c = Game.climber
	if root == null or not is_instance_valid(c):
		_rl_check(false, "map after the reload")
		_rl_finish()
		return
	c.prevent_player_death = true
	print("[RELIGHT] after the reload: oil %.2f (%.3f at the relight), relights %d, log '%s'" % [oil, last_relight_oil, relights - before_relights, last_relight_log])
	print("[RELIGHT] banner: %s" % last_relight_text)
	_rl_check(relights == before_relights + 1 and last_relight_log.begins_with("[OIL] relit at the fire 0.00 -> 0.25"), "relit at the fire 0.00 -> 0.25")
	_rl_check(last_relight_text == "You relit your lantern at the fire.", "banner text")
	# the level the relight left (the lit lamp has burned on for the 2 s since)
	_rl_check(relights == before_relights + 1 and last_relight_oil >= RELIGHT_MIN - 0.0001, "oil >= 0.25 (%.3f at the relight, %.3f now)" % [last_relight_oil, oil])
	# phase 2: a Shade band, lantern on, facing away
	var shades = root.call("feature", "shades") if root.has_method("feature") else null
	var sh_id := ""
	var home := Vector3.INF
	var best := INF
	for e in _rl_homes(shades):
		if str(e.get("band", "")) != "ossuary_low":
			continue
		var hp = e.get("pos")
		if hp is Vector3 and (hp as Vector3).distance_to(c.global_position) < best:
			best = (hp as Vector3).distance_to(c.global_position)
			home = hp
			sh_id = str(e.get("id", ""))
	if home == Vector3.INF:
		print("[RELIGHT] SKIP no strike in 20 s: no ossuary_low Shade home (shades.gd missing or no homes())")
		_rl_finish()
		return
	var saved_user := user
	user = 1                                  # lantern on for the test only (never saved)
	# the rock near the home only turns solid near a player (150 m) and the home drops onto its rock
	# once a player is close: stand at the nearest other station first, then read the home again
	_rl_park(root, _rl_pre_spot(root, home))
	await _rl_wait(2.0)
	for e in _rl_homes(shades):
		if str(e.get("id", "")) == sh_id and e.get("pos") is Vector3:
			home = e["pos"]
	var spot := _rl_spot_near(root, home, 12.0)
	if spot == Vector3.INF:
		_rl_check(false, "no strike in 20 s (no floor spot 6 to 22 m from the Shade home %s with a line of sight to it)" % str(home))
		user = saved_user
		_rl_finish()
		return
	_rl_park(root, spot + Vector3(0.0, 0.3, 0.0))
	var away: Vector3 = spot - home
	away.y = 0.0
	if away.length() > 0.01:
		away = away.normalized()
		c.rotation.y = atan2(-away.x, -away.z)
	# on the floor before anything is counted: a fall or a bump is not a strike
	for _i in 16:
		await _rl_wait(0.25)
		if not is_instance_valid(c) or not c.is_inside_tree() or c.is_on_floor():
			break
	await _rl_wait(0.5)
	if not is_instance_valid(c) or not c.is_inside_tree():
		_rl_check(false, "no strike in 20 s (the climber is gone)")
		user = saved_user
		_rl_finish()
		return
	var hp0: float = float(c.health)
	var low := hp0
	var struck0 = _rl_struck(shades)          # player key -> ms of that Shade strike (shades.gd), or null
	var strikes := 0
	print("[RELIGHT] parked %.1f m from the Shade %s home %s (on floor %s, drop %.1f m), lantern on (oil %.2f), facing away" % [
		spot.distance_to(home), sh_id, str(home), str(c.is_on_floor()), maxf(0.0, spot.y - (c.global_position as Vector3).y), oil])
	for _i in 80:
		await _rl_wait(0.25)
		if not is_instance_valid(c) or not c.is_inside_tree():
			break
		low = minf(low, float(c.health))
		var st = _rl_struck(shades)
		if struck0 is Dictionary and st is Dictionary:
			for k in (st as Dictionary).keys():
				if not (struck0 as Dictionary).has(k) or (struck0 as Dictionary)[k] != st[k]:
					strikes += 1
					print("[RELIGHT] a Shade struck %s" % str(k))
			struck0 = st
	if struck0 is Dictionary:
		# only a Shade's strike counts (a fall, a spider or a drip is not the lantern's business here)
		_rl_check(strikes == 0, "no strike in 20 s (%d Shade strikes; health %.0f -> lowest %.0f)" % [strikes, hp0, low])
	else:
		_rl_check(low >= hp0 - 0.01, "no strike in 20 s (health %.0f -> lowest %.0f; shades.gd has no _struck)" % [hp0, low])
	user = saved_user
	_rl_finish()


func _rl_homes(shades) -> Array:
	# shades.gd homes() through call (another builder's file): [{"id", "band", "pos"}]
	var out: Array = []
	if shades != null and is_instance_valid(shades) and shades.has_method("homes"):
		var h = shades.call("homes")
		if h is Array:
			for e in h:
				if e is Dictionary:
					out.append(e)
	return out


func _rl_struck(shades):
	# a copy of shades.gd's _struck (player key -> ms of the last Shade strike), null when unreadable
	if shades == null or not is_instance_valid(shades):
		return null
	var s = shades.get("_struck")
	return (s as Dictionary).duplicate() if s is Dictionary else null


func _rl_stations(root: Node) -> Array:
	var out: Array = []
	var lay = root.get("L")
	if lay is Dictionary:
		for s in (lay as Dictionary).get("stations", []):
			var sp = s.get("pos", []) if s is Dictionary else []
			if sp is Array and (sp as Array).size() >= 3:
				out.append(Vector3(float(sp[0]), float(sp[1]), float(sp[2])))
	return out


func _rl_pre_spot(root: Node, home: Vector3) -> Vector3:
	# the nearest other main-route station within 60 m of the home (a stand point), else the home
	var best := home
	var best_d := 60.0
	for v in _rl_stations(root):
		var d := (v as Vector3).distance_to(home)
		if d > 1.0 and d < best_d:
			best_d = d
			best = v
	return best + Vector3(0.0, 1.0, 0.0)


func _rl_ray(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> Dictionary:
	# both-sided: the cave collision is double-sided with an inconsistent winding (underdark.gd
	# backface_collision), so a back-culled ray falls through real floors. Never the climber itself.
	var q := PhysicsRayQueryParameters3D.create(a, b, 1)
	q.hit_back_faces = true
	var c = Game.climber
	if is_instance_valid(c) and c is CollisionObject3D:
		var ex: Array[RID] = []
		ex.append((c as CollisionObject3D).get_rid())
		q.exclude = ex
	return space.intersect_ray(q)


func _rl_floor(space: PhysicsDirectSpaceState3D, p: Vector3) -> Vector3:
	# the floor at p: the first surface a ray from 2 m above p to 2 m below it meets, flat enough to
	# stand on, with 1.9 m of head room. INF when there is none within 2 m (mid-air, or a wall).
	var hit := _rl_ray(space, p + Vector3.UP * 2.0, p + Vector3.DOWN * 2.0)
	if hit.is_empty():
		return Vector3.INF
	var n: Vector3 = hit["normal"]
	if absf(n.y) < 0.7:
		return Vector3.INF
	var fl: Vector3 = hit["position"]
	if not _rl_ray(space, fl + Vector3.UP * 0.1, fl + Vector3.UP * 1.9).is_empty():
		return Vector3.INF
	return fl


func _rl_spot_near(root: Node, home: Vector3, dist: float) -> Vector3:
	# a floor spot about `dist` m from the home: the main-route stations near it and a ring of points
	# around it at a few heights, each snapped to a real floor (_rl_floor) and kept only with a clear
	# line of sight to the home (so it stands in the home's own cave, never inside rock). 9 to 16 m
	# first, then 6 to 22 m; near a checkpoint or more than 2.5 m above or below the home scores worse
	# (a Shade never shrieks at a player 3 m above or below it). INF when there is none.
	if not (root is Node3D) or (root as Node3D).get_world_3d() == null:
		return Vector3.INF
	var space: PhysicsDirectSpaceState3D = (root as Node3D).get_world_3d().direct_space_state
	if space == null:
		return Vector3.INF
	var cps: Array = []
	var lay = root.get("L")
	if lay is Dictionary:
		for k in (lay as Dictionary).get("checkpoints", []):
			var p = k.get("pos", []) if k is Dictionary else []
			if p is Array and (p as Array).size() >= 3:
				cps.append(Vector3(float(p[0]), float(p[1]), float(p[2])))
	var cands: Array = []
	for v in _rl_stations(root):
		var d0 := (v as Vector3).distance_to(home)
		if d0 > 4.0 and d0 < 24.0:
			cands.append(v)
	for i in 16:
		var a := TAU * float(i) / 16.0
		var dir := Vector3(cos(a), 0.0, sin(a))
		for r in [dist, dist - 2.0, dist + 2.0, dist - 3.0, dist + 4.0, dist - 5.0, dist + 7.0]:
			for dy in [0.0, 1.5, -1.5, 3.0, -3.0]:
				cands.append(home + dir * float(r) + Vector3(0.0, float(dy), 0.0))
	var floors: Array = []
	for v in cands:
		var f := _rl_floor(space, v)
		if f != Vector3.INF:
			floors.append(f)
	var eye := home + Vector3.UP * 1.2
	for win in [[9.0, 16.0], [6.0, 22.0]]:
		var best := Vector3.INF
		var best_err := INF
		for f2 in floors:
			var fl: Vector3 = f2
			var d := fl.distance_to(home)
			if d < float(win[0]) or d > float(win[1]):
				continue
			var err := absf(d - dist)
			if absf(fl.y - home.y) > 2.5:
				err += 8.0
			for cp in cps:
				if fl.distance_to(cp) < 20.0:
					err += 10.0
					break
			if err >= best_err:
				continue
			if not _rl_ray(space, eye, fl + Vector3.UP * 1.2).is_empty():
				continue                          # no line of sight: another cave, or inside rock
			best_err = err
			best = fl
		if best != Vector3.INF:
			return best
	return Vector3.INF


func _rl_finish() -> void:
	var c = Game.climber
	if is_instance_valid(c):
		c.prevent_player_death = false
	DirAccess.remove_absolute(RL_MARK)
	_rl_test = false
	if _rl_fails.is_empty():
		print("[RELIGHT] test done %d/%d PASS" % [_rl_pass, _rl_total])
	else:
		print("[RELIGHT] test done %d/%d FAIL: %s" % [_rl_pass, _rl_total, ", ".join(_rl_fails)])
