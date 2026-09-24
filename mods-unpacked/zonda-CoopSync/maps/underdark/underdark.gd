extends Node3D

# THE UNDERDARK. The cave itself is a pre-built glTF (underdark.glb, generated offline
# from a fixed seed so every player has the identical world). This script loads it,
# builds collision, places every prop, light, trap, puzzle and creature from layout.json,
# and runs them. Anything that changes the world goes through CoopSync.map_event so all
# players see the same thing, and re-applies after a death reload.

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const PYRELIGHT := "res://Art/Pyrelight.tscn"
const EMBER := "res://Treasure_Pickup.tscn"
const CENTIPEDE := "res://scenes/centipede.tscn"
const TEXT_AREA_SCRIPT := "res://scripts/ending_text_display_area.gd"
const SFX_RUMBLE := "res://sfx/soundsnap/304185-Chair-Rumble-Contact-Resonant-Distorted-Crisp-High.wav"
const SFX_GRAVEL := "res://sfx/soundsnap/41281-FOLEY_FOOTSTEPS_BOOTS_SLIDE_GRAVEL_SCATTER_01.wav"
const SFX_METAL := ["res://sfx/soundsnap/273280-Builder-Game-Item-Pickaxe-Hit-Stone-Metal-1.wav", "res://sfx/soundsnap/273281-Builder-Game-Item-Pickaxe-Hit-Stone-Metal-2.wav"]
const SFX_WIND := "res://sfx/soundsnap/249565-Heavy_Wind_Ambience_2.wav"
const PLAYER_LAYER := 4
const CLAW_LAYER := 2
# v4.9 modules (each one degrades quietly when its assets are missing)
const Soundscape := preload("res://mods-unpacked/zonda-CoopSync/maps/underdark/soundscape.gd")
const Creatures := preload("res://mods-unpacked/zonda-CoopSync/maps/underdark/creatures.gd")
const LookUltra := preload("res://mods-unpacked/zonda-CoopSync/maps/underdark/look_ultra.gd")
const HeatHaze := preload("res://mods-unpacked/zonda-CoopSync/maps/underdark/heat_haze.gd")
const OilFlask := preload("res://mods-unpacked/zonda-CoopSync/maps/underdark/oil_flask.gd")

# per-biome look: [wall albedo, floor albedo, ambient, fog color, fog density, bg energy]
const LOOKS := [
	[Color(0.78, 0.7, 0.58), Color(0.72, 0.62, 0.5), Color(0.5, 0.45, 0.38), Color(0.085, 0.078, 0.064), 0.82, 0.3],
	[Color(0.85, 0.82, 0.72), Color(0.8, 0.76, 0.66), Color(0.36, 0.34, 0.3), Color(0.066, 0.068, 0.062), 0.84, 0.1],
	[Color(0.45, 0.62, 0.42), Color(0.35, 0.55, 0.32), Color(0.18, 0.4, 0.25), Color(0.028, 0.085, 0.055), 0.84, 0.1],
	[Color(0.55, 0.42, 0.3), Color(0.45, 0.34, 0.25), Color(0.41, 0.29, 0.18), Color(0.082, 0.056, 0.03), 0.84, 0.1],
	[Color(0.45, 0.55, 0.58), Color(0.38, 0.48, 0.5), Color(0.24, 0.32, 0.36), Color(0.045, 0.072, 0.088), 0.86, 0.1],
	[Color(0.6, 0.58, 0.62), Color(0.5, 0.48, 0.52), Color(0.32, 0.29, 0.37), Color(0.06, 0.05, 0.088), 0.84, 0.1],
	[Color(0.62, 0.76, 0.95), Color(0.55, 0.7, 0.9), Color(0.27, 0.4, 0.58), Color(0.038, 0.075, 0.13), 0.82, 0.1],
	[Color(0.6, 0.35, 0.25), Color(0.5, 0.28, 0.2), Color(0.5, 0.18, 0.08), Color(0.125, 0.044, 0.012), 0.8, 0.2],
	[Color(0.5, 0.22, 0.24), Color(0.42, 0.18, 0.2), Color(0.42, 0.08, 0.08), Color(0.09, 0.012, 0.012), 0.8, 0.18],
	[Color(0.62, 0.55, 0.45), Color(0.55, 0.48, 0.4), Color(0.14, 0.11, 0.08), Color(0.01, 0.01, 0.01), 0.9, 0.0],
	# 10 and 11 are surfaces, not places: bone (the Ribs) and bark (the great roots)
	[Color(1.9, 1.8, 1.5), Color(1.9, 1.8, 1.5), Color(0.36, 0.34, 0.3), Color(0.066, 0.068, 0.062), 0.84, 0.1],
	[Color(0.4, 0.27, 0.16), Color(0.46, 0.31, 0.18), Color(0.36, 0.25, 0.16), Color(0.082, 0.056, 0.03), 0.84, 0.1],
]

var L: Dictionary = {}
var _env: Environment
var _cur_biome := -1
var _blend := 0.0
var _look_now: Array = []
var _weather: Weather
var _tour_f6 := false
var _particles_on := true
var _rope_gold_t := 0.0
var _dimmed: Dictionary = {}
var _ext_tmpl: Dictionary = {}         # ext/<pack>/<file>.glb -> template Node3D (never in the tree)
var _ext_placed := 0
var _dress_mat: Array = []
var _sky: DirectionalLight3D
var _glow: DirectionalLight3D
var _look_from: Array = []
var _look_to: Array = []
var _chunks: Array = []          # [MeshInstance3D, center, radius]
var _lod_accum := 0.0
var _lod_index := 0
var _clock := 0.0
var _finished := false
var _gates: Dictionary = {}
var _kilns: Dictionary = {}       # idx -> node
var _plates: Array = []
var _fragments: Dictionary = {}
var _frag_count := 0
var _stalkers: Array = []
var _crumbles: Dictionary = {}
var _droppers: Dictionary = {}
var _dying: Dictionary = {}
var _spawned_cents: Dictionary = {}
var _follower: Node3D
var _follow_best := 1e9
var _follow_stall := 0.0
var _cent_tick := 0.0
var _territorial: Array = []          # [node, y_top, y_bottom, home]
var _hud: CanvasLayer
var _hud_depth: Label
var _run_start_ms := 0
var _debug_tour := false
var _debug_finale := false
var _debug_reload := false
var _rl_t := 0.0
var _rl_done := false
const RELOAD_MARK := "user://zonda_reload_test.txt"
var _debug_bright := false
var _bt_t := 0.0
var _bt_i := -1
var _dbg_fin_t := -4.0
var _dbg_fin_started := false
var _dbg_fin_shots := 0
var _tour_i := -1
var _tour_t := 0.0
var _tour_shots: Array = []
var _tour_shot_done := false
var _wall_mat: Array = []
var _floor_mat: Array = []
var _mat_bar: StandardMaterial3D
var _mat_crystal: StandardMaterial3D
var _mat_ruin: StandardMaterial3D
var _crystal_n := 0
var _lava_kill_y := -1e9
var _lava_box: Array = []       # [center, d, s, half_w, half_l]
var _bars: Array = []
var _bells: Dictionary = {}
var _platforms: Dictionary = {}
var _fall_speed := 0.0
var _lethal_fall := 38.0
var _bruise_from := 19.0
var _bruise_per := 4.5
var _bruise_told := false
# The game pins ambient energy to 0.18 every frame (world_environment.gd), so the only way to
# lift the dark is through the ambient COLOUR. And its colour-correction ramp clips to white at
# about 0.28 raw and crushes below 0.06, so everything here lives between those two numbers.
const AMB_GAIN := 1.9
# light that falls down the rift from far above, per biome. It is what lets you see a balcony
# 300 m away. Off inside the side caves.
const SKYGLOW := [0.25, 0.25, 0.25, 0.28, 0.3, 0.2, 0.25, 0.15, 0.0, 0.0]
# The game's colour ramp crushes anything darker than about 0.12 after its 2x brightness, and its
# sand and rock textures are dark to begin with, so floors in the ambient-only biomes rendered
# black (measured: 76 to 95% of floor pixels under 4% brightness). Lift the albedo, not the lights.
# v4.8: Sunken Village (5), the Nest (8) and the root bark (11) read black in NORMAL, so they get
# the same lift as their neighbours. LANTERN still scales all of it by BRIGHT_ALB.
const WALL_LIFT := [1.15, 1.18, 1.27, 1.75, 1.42, 1.3, 1.15, 1.3, 1.65, 1.0, 1.0, 1.3]
const FLOOR_LIFT := [1.36, 1.42, 1.57, 2.2, 1.78, 1.6, 1.39, 1.6, 2.0, 1.0, 1.0, 1.6]
# how bright the void (the background past the rock) is against each biome's fog tint. Below 1 the
# pit reads darker than the fogged rock in front of it, so it looks bottomless. The Mouth (open to
# the surface) and the Burrows (already black) keep the old look.
const VOID_DIM := [1.0, 0.35, 0.35, 0.35, 0.35, 0.35, 0.35, 0.35, 0.35, 1.0, 0.35, 0.35]
const VIEW_RANGE := 425.0        # the campaign shows 150-300 m of void; the rift needs the same
const SOLID_RANGE := 150.0
const BRIGHT := [0.08, 1.0]                        # ambient and the glow down the rift: LANTERN (near black) or NORMAL
const BRIGHT_ALB := [0.55, 1.0]                     # how much of the rock brightness lift stays
const BRIGHT_LANTERN := [true, false]               # the lantern's default in each mode (L overrides)
const BRIGHT_NAMES := ["LANTERN (dark)", "NORMAL"]
const BRIGHT_FILE := "user://zonda_underdark.cfg"
var _bright_i := 0
const LIGHT_BUDGET := 64         # how many of our own omni lights may be on at once
const LIGHT_FAR := 175.0         # and none of them past this, however few are on
# render layer 20 = the idol in your own hand: your own lantern (lantern.gd) skips it, or a
# light 1 m away blows it out to white
const HELD_LAYER := 1 << 19
var _mat_lava: ShaderMaterial
var _lights: Array = []
var _managed_lights: Array = []
var _light_tick := 0.0
var _nest_lights: Array = []
var _music: MusicDirector
var _idol_taken := false
var _idol_node: Node3D
var _altar_light: OmniLight3D
var _altar_pos: Vector3
var _replaying := false          # true while a stored event is re-applied: state only, no drama
var _cp_healed: Dictionary = {}   # checkpoint id -> true once THIS player got its heal
var _stalk_accum := 0.0
var _idol_by := ""
var _idol_mine := false           # the local player carries the idol
var _held_idol: Node3D
var _held_failed := false
var _held_t := 0.0
var _clock_t0 := 0.0              # the team run clock: unix start time from the "clock" map event
var _clock_asked := false
var _finish_sent := false
var _fin_tick := 0.0
var _fin_wait_t := 0.0
var _death_noted := false
var _end_card: CanvasLayer
var _applied: Dictionary = {}          # persistent event keys already applied here: a second apply is a no-op
var _real_spawned: Dictionary = {}     # centipede ids this machine spawned real creatures for
var _grace: Array = []                 # [node, wake_ms, centre]: spawned asleep so it never lands on a player
var _creature_centres: Array = []      # host: awake creature positions, kept solid by _update_lod
var _burrow_zones: Array = []          # the Burrows (biome 9 zones)
var _burrow_parked := false            # host: the Follower waits outside while someone is in the Burrows
var _burrow_top := -1e9                # a little above the Burrows' highest chamber
var _mat_crystal_prop: StandardMaterial3D
var _pix_mode := -1                    # last applied "reduced pixelization" choice (-1 = not yet)
var _pix_t := 0.0
# ---- v4.9
var _ss: Node = null                   # soundscape.gd: beds, cave reverb, heartbeat
var _ss_open_t := 0.0
var _ss_open_votes := 0
var _ss_threat_t := 0.0
var _look_ultra = LookUltra.new()      # ULTRA HD rock photos (member, so its texture cache lives with the map)
var _ultra_on := false
var _haze: CanvasLayer = null
var _haze_k := 0.0
var _haze_t := 0.0
var _haze_want := 0.0
var _foundry_fires: Array = []         # Vector3: the Foundry's fires, for the heat shimmer
var _brood: Node3D = null              # Creatures.Brood (the Nest's eggs, after the idol)
var _spiders: Array = []               # Creatures.WallSpider
var _husk: Node3D = null               # Creatures.WakingHusk
var _husk_props: Array = []            # the husk's prop nodes (layout props with "husk_id")
var _husk_bodies: Array = []           # and their collision boxes
var _husk_hidden := false
var _cx_accum := 0.0
var _oil_fresh := true                 # this load starts a new run (full lantern), not a death reload
var _flasks: Array = []
var _debug_spider := false
var _sp_t := 0.0
var _sp_phase := 0
var _sp_states: Dictionary = {}
var _sp_husk_phase := -1
var _debug_oil := false
var _oil_t := 0.0
var _oil_phase := 0
var _oil_log_t := 0.0
var _oil_before := 0.0
var _oil_target: Node3D = null
var _oil_phase_t := 0.0


func _ready() -> void:
	var t0 := Time.get_ticks_msec()
	var f := FileAccess.open(DIR + "layout.json", FileAccess.READ)
	if f == null:
		push_error("[Underdark] layout.json missing")
		return
	L = JSON.parse_string(f.get_as_text())
	_lethal_fall = float(L.get("rules", {}).get("lethal_fall_speed", 38.0))
	_bruise_from = float(L.get("rules", {}).get("bruise_from", 19.0))
	_bruise_per = float(L.get("rules", {}).get("bruise_per", 4.5))
	_load_brightness()
	_debug_tour = FileAccess.file_exists(DIR + "tour.flag")
	_debug_finale = FileAccess.file_exists(DIR + "finale.flag")
	_debug_reload = FileAccess.file_exists(DIR + "reload.flag")
	_debug_bright = FileAccess.file_exists(DIR + "bright.flag")
	_debug_spider = FileAccess.file_exists(DIR + "spider.flag")
	_debug_oil = FileAccess.file_exists(DIR + "oil.flag")
	# a death reload keeps the team's map state for this scene (and so does a team checkpoint):
	# then the lantern keeps its oil level. Anything else is a new run with a full lantern.
	# (read before map_request_sync below, which creates this scene's state on a fresh start)
	_oil_fresh = str(CoopSync.map_state.get("scene", "")) != scene_file_path and CoopSync.map_checkpoint_for(scene_file_path) < 0
	# the cave soundscape first: it creates the "ZondaCave" reverb bus every creature, trap and
	# ambience sound below is routed through
	_ss = Soundscape.new()
	_ss.name = "Soundscape"
	add_child(_ss)
	_ss.setup(self)
	if _debug_tour:
		# tour.flag may hold label prefixes ("along,husk") to shoot only those stops
		var flt := FileAccess.get_file_as_string(DIR + "tour.flag").strip_edges()
		_tour_f6 = flt.contains("+f6")          # developer: press F6 at stop 3 (off) and stop 5 (on)
		if flt != "" and flt != "1":
			var keep: Array = []
			var pref := flt.split(",")
			var idx := 0
			for s0 in L.get("tour", []):
				for pf in pref:
					if str(s0.get("label", "")).begins_with(pf.strip_edges()):
						s0["orig"] = idx
						keep.append(s0)
						break
				idx += 1
			L["tour"] = keep
	# developer flags are one-shot, like autostart.flag: read, then deleted, so a stray flag can never
	# leave a real run invincible. reload.flag stays: its test spans three map loads and removes itself.
	for fl in ["tour.flag", "finale.flag", "bright.flag", "spider.flag", "oil.flag"]:
		if FileAccess.file_exists(DIR + fl):
			DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/maps/underdark/" + fl)
	for z in L.get("zones", []):
		if int(z.get("biome", -1)) == 9:
			_burrow_zones.append(z)
			_burrow_top = maxf(_burrow_top, float(z["top"]) + 10.0)
	_build_materials()
	# ULTRA HD rock photos: record the shipped texture settings now, before gfx.gd ever sees these
	# materials (it only meets them once the cave meshes enter the tree in _load_cave)
	_look_ultra.setup(_wall_mat, _floor_mat)
	_sync_ultra(true)
	var gfx = CoopSync.gfx
	if is_instance_valid(gfx) and gfx.has_signal("mode_changed") and not gfx.is_connected("mode_changed", _on_gfx_mode):
		gfx.connect("mode_changed", _on_gfx_mode)
	_setup_environment()
	_load_cave()
	_place_start()
	_place_barriers()
	_place_props()
	_place_dress()
	_place_lights()
	_place_fires()
	_place_embers()
	_place_crystals()
	_place_texts()
	_place_checkpoints()
	_place_crumbles()
	_place_vents()
	_place_droppers()
	_place_spikes()
	_place_ice()
	_place_gates()
	_place_kilns()
	_place_plates()
	_place_fragments()
	_place_bells()
	_place_relics()
	_place_lanterns()
	_place_mist()
	_weather = Weather.new()
	_weather.build(_soft_dot())
	add_child(_weather)
	_weather.enabled = _particles_on           # F6, saved (read by _load_brightness above)
	print("[Underdark] particles %s (saved setting, F6)" % ("on" if _particles_on else "off"))
	if _debug_bright:
		_weather.enabled = false               # the brightness test measures light, not motes
	elif _debug_tour:
		_weather.enabled = true
		_weather.force_full()
	_place_platforms()
	_place_spars()
	_place_falls()
	_place_ghosts()
	_place_bats()
	_place_bars()
	_place_lava()
	_place_ambience()
	_place_dying_lights()
	_place_altar()
	_place_eggs()
	_place_v49_creatures()
	_place_oil()
	_haze = HeatHaze.new()
	add_child(_haze)
	for fr in L.get("fires", []):
		var fp := _v(fr["pos"])
		if _biome_at(fp) == 7:
			_foundry_fires.append(fp)
	_build_hud()
	call_deferred("_announce_light")
	_music = MusicDirector.new()
	add_child(_music)
	_run_start_ms = Time.get_ticks_msec()
	# creatures after a frame so Game.centipedes is clean for this scene
	call_deferred("_place_creatures")
	_collect_lights()
	CoopSync.nametags_through_walls = true
	# pass our own path: this runs a frame before the autoload notices the scene change
	CoopSync.map_request_sync(scene_file_path)
	var ms := _run_state()
	if not ms.is_empty() and not ms.has("relics0"):
		ms["relics0"] = CoopSync.cosmetics        # for the end card: relics found during this run
	call_deferred("_reapply_events")
	print("[Underdark] built in %d ms: %d chunks, %d props, %d external models" % [Time.get_ticks_msec() - t0, _chunks.size(), L.get("props", []).size(), _ext_placed])


func _exit_tree() -> void:
	# the Underdark's lantern default stays in the Underdark (the player's own L choice is kept)
	if is_instance_valid(CoopSync.lantern):
		CoopSync.lantern.set_default(false, true)
		# oil only burns in the Underdark: other levels never drain it
		if "oil_enabled" in CoopSync.lantern:
			CoopSync.lantern.set("oil_enabled", false)
	var gfx = CoopSync.gfx
	if is_instance_valid(gfx) and gfx.has_signal("mode_changed") and gfx.is_connected("mode_changed", _on_gfx_mode):
		gfx.disconnect("mode_changed", _on_gfx_mode)
	CoopSync.idol_carrier = false
	# the external-model templates and dim variants are never in the tree: free them by hand
	for v in _ext_tmpl.values():
		if v != null and is_instance_valid(v):
			(v as Node).free()
	_ext_tmpl.clear()


func _run_state() -> Dictionary:
	# this run's shared map state in CoopSync (survives a death reload), or {} if it is not ours yet
	var ms: Dictionary = CoopSync.map_state
	if str(ms.get("scene", "")) != scene_file_path:
		return {}
	return ms


# ------------------------------------------------------------------ world

func _build_materials() -> void:
	var rock: StandardMaterial3D = load("res://Art/Textures/Rock_01.tres")
	var wall4: StandardMaterial3D = load("res://Art/Textures/Wall_04.tres")
	for i in LOOKS.size():
		var w: StandardMaterial3D = rock.duplicate()
		w.vertex_color_use_as_albedo = true
		w.cull_mode = BaseMaterial3D.CULL_DISABLED
		w.uv1_scale = Vector3(0.11, 0.11, 0.11)
		_wall_mat.append(w)
		var fl: StandardMaterial3D = wall4.duplicate()
		fl.vertex_color_use_as_albedo = true
		fl.cull_mode = BaseMaterial3D.CULL_DISABLED
		fl.metallic = 0.0                       # the game's sand is half metal, which reads as black with no sky to reflect
		fl.uv1_scale = Vector3(0.09, 0.09, 0.09)
		_floor_mat.append(fl)
		var dm: StandardMaterial3D = w.duplicate()
		dm.vertex_color_use_as_albedo = false
		dm.cull_mode = BaseMaterial3D.CULL_BACK
		_dress_mat.append(dm)
	_apply_material_brightness()
	_mat_bar = StandardMaterial3D.new()
	_mat_bar.albedo_color = Color(0.32, 0.12, 0.08)
	_mat_bar.metallic = 0.2
	_mat_bar.roughness = 0.6
	_mat_crystal = StandardMaterial3D.new()
	# the game's environment doubles brightness and color-corrects, so anything emissive
	# and blue turns pure white. Dark albedo, no emission, let the room lights do it.
	_mat_crystal.albedo_color = Color(0.1, 0.22, 0.42)
	_mat_crystal.roughness = 0.9
	_mat_crystal.emission_enabled = false
	# the crystal props read dead grey: their own copy gets a faint cold glow, kept at about a third
	# of the clip (linear blue ~0.03). Icicles and fragments keep the plain material.
	_mat_crystal_prop = _mat_crystal.duplicate()
	_mat_crystal_prop.albedo_color = Color(0.14, 0.27, 0.48)
	_mat_crystal_prop.emission_enabled = true
	_mat_crystal_prop.emission = Color(0.1, 0.22, 0.42)
	_mat_crystal_prop.emission_energy_multiplier = 0.2
	_mat_ruin = wall4.duplicate()
	_mat_ruin.albedo_color = Color(0.42, 0.4, 0.44)
	_mat_ruin.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat_ruin.uv1_scale = Vector3(0.2, 0.2, 0.2)
	_apply_pixel_filter()
	_mat_lava = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, cull_disabled;
uniform float t = 0.0;
varying vec3 wp;
void vertex() { wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
float h(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float n(vec2 p) { vec2 i = floor(p); vec2 f = fract(p); f = f * f * (3.0 - 2.0 * f);
	return mix(mix(h(i), h(i + vec2(1, 0)), f.x), mix(h(i + vec2(0, 1)), h(i + vec2(1, 1)), f.x), f.y); }
void fragment() {
	vec2 p = wp.xz * 0.045 + vec2(t * 0.02, t * 0.013);
	float v = n(p) * 0.6 + n(p * 2.3 + t * 0.05) * 0.3 + n(p * 5.1) * 0.1;
	// linear values. The game doubles brightness in display space and clips to white there,
	// so linear 0.064 is already white. These land on deep red and orange.
	vec3 dark = vec3(0.008, 0.0008, 0.0); vec3 hot = vec3(0.062, 0.0095, 0.0006);
	float k = smoothstep(0.4, 0.78, v);
	ALBEDO = mix(dark, hot, k);
	EMISSION = vec3(0.0);
}
"""
	_mat_lava.shader = sh


func _apply_pixel_filter() -> void:
	# The game's "reduced pixelization" option only reaches its own shared Rock/Wall materials; ours
	# are copies, so the filter is set here, and re-checked once a second (a mid-run settings change).
	# Both choices use mipmaps: up close the texels stay as hard as before, but far floors stop
	# shimmering into bright specks while the camera moves.
	var reduced: bool = bool(GameSettings.config.get_value("video", "reduced_pixelization", false))
	var want: int = 1 if reduced else 0
	if want == _pix_mode:
		return
	_pix_mode = want
	var tf: BaseMaterial3D.TextureFilter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	if reduced:
		tf = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	for i in _wall_mat.size():
		if _ultra_on and i < 10:
			continue                       # wearing the ULTRA HD photos: they keep their smooth filter
		(_wall_mat[i] as BaseMaterial3D).texture_filter = tf
	for i in _floor_mat.size():
		if _ultra_on and i < 10:
			continue
		(_floor_mat[i] as BaseMaterial3D).texture_filter = tf
	for m in _dress_mat:
		(m as BaseMaterial3D).texture_filter = tf
	if _mat_ruin != null:
		_mat_ruin.texture_filter = tf


func _gfx_is_ultra() -> bool:
	var gfx = CoopSync.gfx
	if not is_instance_valid(gfx):
		return false
	if gfx.has_method("is_ultra"):
		return bool(gfx.call("is_ultra"))
	return int(gfx.get("mode")) == 3          # an older gfx.gd without is_ultra(): mode 3 is ULTRA HD


func _on_gfx_mode(_m: int) -> void:
	_sync_ultra()


func _sync_ultra(force: bool = false) -> void:
	# F4: ULTRA HD dresses biomes 0-9 in real rock photos, NORMAL PIXELS puts the game's own
	# textures back exactly. Also polled once a second (_process), so it follows F4 even without
	# gfx's mode_changed signal. Only a real change reaches look_ultra.
	var want := _gfx_is_ultra()
	if want == _ultra_on and not force:
		return
	_ultra_on = want
	_look_ultra.apply(want)
	if not want:
		_pix_mode = -1
		_apply_pixel_filter()          # the photos' smooth filter goes; the setting's own choice returns


func _load_cave() -> void:
	var bytes := FileAccess.get_file_as_bytes(DIR + "underdark.glb")
	if bytes.is_empty():
		push_error("[Underdark] underdark.glb missing or empty")
		return
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_buffer(bytes, "", state)
	if err != OK:
		push_error("[Underdark] could not read cave mesh: %s" % err)
		return
	var root: Node = doc.generate_scene(state)
	if root == null:
		push_error("[Underdark] cave scene empty")
		return
	var count := 0
	var found: Array = []
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		found.append(mi)
	# the runtime importer can hand back ImporterMeshInstance3D instead; convert those
	for imi in root.find_children("*", "ImporterMeshInstance3D", true, false):
		var im: ImporterMesh = imi.mesh
		if im == null:
			continue
		var conv := MeshInstance3D.new()
		conv.mesh = im.get_mesh()
		found.append(conv)
	for mi in found:
		var m: MeshInstance3D = mi
		var mesh: Mesh = m.mesh
		if mesh == null:
			continue
		if m.get_parent():
			m.get_parent().remove_child(m)
		add_child(m)
		m.transform = Transform3D.IDENTITY
		for si in mesh.get_surface_count():
			var mat: Material = mesh.surface_get_material(si)
			var nm: String = mat.resource_name if mat else ""
			var b := 0
			var is_floor := false
			if nm.begins_with("B"):
				var parts := nm.substr(1).split("_")
				b = clampi(int(parts[0]), 0, LOOKS.size() - 1)
				is_floor = parts.size() > 1 and parts[1] == "F"
			m.set_surface_override_material(si, _floor_mat[b] if is_floor else _wall_mat[b])
		var tri: ConcavePolygonShape3D = mesh.create_trimesh_shape()
		if tri != null and _has_real_triangle(tri.get_faces()):
			var body := StaticBody3D.new()
			body.collision_layer = 1
			body.physics_material_override = load("res://physics_materials/stone.tres")
			var shape := CollisionShape3D.new()
			tri.backface_collision = true
			shape.shape = tri
			body.add_child(shape)
			m.add_child(body)
		var aabb := mesh.get_aabb()
		var c := aabb.get_center()
		_chunks.append([m, c, aabb.size.length() * 0.5])
		m.visibility_range_end = 0.0
		count += 1
	root.queue_free()
	print("[Underdark] cave chunks: %d" % count)


func _has_real_triangle(f: PackedVector3Array) -> bool:
	# a sliver chunk can come out of marching cubes with only zero-area triangles
	var i := 0
	while i + 2 < f.size():
		if (f[i + 1] - f[i]).cross(f[i + 2] - f[i]).length_squared() > 1e-10:
			return true
		i += 3
	return false


func _place_start() -> void:
	var st: Dictionary = L["start"]
	var c = get_node_or_null("Climber")
	if c:
		var p: Array = st["pos"]
		c.position = Vector3(p[0], p[1], p[2])
		c.rotation.y = float(st["yaw"])


func _place_barriers() -> void:
	# invisible walls around the surface bowl so nobody walks off the edge of the world
	for b in L.get("barriers", []):
		var body := StaticBody3D.new()
		body.collision_layer = 1
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		var s: Array = b["size"]
		box.size = Vector3(s[0], s[1], s[2])
		cs.shape = box
		body.add_child(cs)
		body.position = _v(b["pos"])
		body.rotation.y = float(b["yaw"])
		add_child(body)


func _place_props() -> void:
	var cache: Dictionary = {}
	for p in L.get("props", []):
		var path: String = p["scene"]
		var n: Node3D
		if path.begins_with("ext/"):
			n = _ext_instance(path, float(p.get("dim", 0.45)))
			if n == null:
				continue
			_ext_placed += 1
		else:
			if not cache.has(path):
				cache[path] = load(path)
			var ps: PackedScene = cache[path]
			if ps == null:
				continue
			n = ps.instantiate()
		n.position = _v(p["pos"])
		var r: Array = p["rot"]
		n.rotation = Vector3(r[0], r[1], r[2])
		n.scale = Vector3.ONE * float(p["scale"])
		add_child(n)
		var husk_part: bool = p.get("husk_id") != null
		if husk_part:
			_husk_props.append(n)          # the waking husk: hidden when it gets up (see _hide_husk_props)
		if p.get("box") != null:
			var bx: Array = p["box"]
			var body := StaticBody3D.new()
			body.collision_layer = 1
			var cs := CollisionShape3D.new()
			var shape := BoxShape3D.new()
			shape.size = Vector3(bx[0] * 2.0, bx[1] * 2.0, bx[2] * 2.0)
			cs.shape = shape
			body.add_child(cs)
			body.rotation = n.rotation
			var bc = p.get("box_c")
			if bc is Array and (bc as Array).size() >= 3:
				# the model's real box centre (off-pivot models), in its own unrotated frame, already scaled
				cs.position = Vector3.ZERO
				body.position = n.position + Basis.from_euler(n.rotation) * Vector3(float(bc[0]), float(bc[1]), float(bc[2]))
			else:
				cs.position = Vector3(0, bx[1], 0)
				body.position = n.position
			add_child(body)
			if husk_part:
				_husk_bodies.append(body)
		if str(p.get("col", "")) == "hull":
			_ext_hull(n, path, float(p["scale"]))
		if bool(p.get("pale", false)):
			_paint_pale(n)
		var ruin: bool = path.contains("Village_") or path.contains("Ghost_Tower") or path.contains("Building_") or path.contains("Roof_") or path.contains("Door.glb") or path.contains("Tower_0")
		if path.begins_with("ext/"):
			pass                          # already dimmed to its own factor
		elif path.contains("Plant_"):
			_dim_materials(n, 0.3)
		elif path.contains("Corpse_0"):
			_dim_materials(n, 0.5)
		elif path.contains("Stone_0") or path.contains("Rock_0"):
			_dim_materials(n, 0.55)         # pale kit stones clip to white in the game's post
		elif path.contains("Woman") or path.contains("Player_Corpse") or path.contains("Rope") or path.contains("WaterWheel") or path.contains("StoneSphere"):
			_dim_materials(n, 0.4)
		for mi in n.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).visibility_range_end = float(p.get("vis", 300.0))
			(mi as GeometryInstance3D).visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			if ruin:
				(mi as GeometryInstance3D).material_override = _mat_ruin


# ------------------------------------------------------------------ external models
# The kits under maps/underdark/ext/ were never imported by the editor, so load() cannot see
# them. GLTFDocument reads the .glb at runtime; each file becomes one template whose mesh
# instances are copied (with their transforms) per placement.

func _ext_template(rel: String) -> Node3D:
	if _ext_tmpl.has(rel):
		return _ext_tmpl[rel]
	_ext_tmpl[rel] = null
	var bytes := FileAccess.get_file_as_bytes(DIR + rel)
	if bytes.is_empty():
		push_warning("[Underdark] ext model missing: " + rel)
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_buffer(bytes, "", state) != OK:
		push_warning("[Underdark] ext model unreadable: " + rel)
		return null
	var root: Node = doc.generate_scene(state)
	if root == null:
		return null
	var tmpl := Node3D.new()
	var found: Array = []
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		found.append([mi, (mi as MeshInstance3D).mesh])
	for imi in root.find_children("*", "ImporterMeshInstance3D", true, false):
		var im: ImporterMesh = imi.mesh
		if im != null:
			found.append([imi, im.get_mesh()])
	for pair in found:
		var src: Node3D = pair[0]
		var mesh: Mesh = pair[1]
		if mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var node: Node = src
		while node != null and node != root:
			if node is Node3D:
				xf = (node as Node3D).transform * xf
			node = node.get_parent()
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.transform = xf
		# every surface gets its own material copy so the dim never touches the shared resource
		for si in mesh.get_surface_count():
			var m: Material = mesh.surface_get_material(si)
			if m is StandardMaterial3D:
				mi.set_surface_override_material(si, (m as StandardMaterial3D).duplicate())
		tmpl.add_child(mi)
	root.free()
	_ext_tmpl[rel] = tmpl
	return tmpl


func _ext_instance(rel: String, dim: float) -> Node3D:
	var key := "%s|%.2f" % [rel, dim]
	if _ext_tmpl.has(key):
		return null if _ext_tmpl[key] == null else (_ext_tmpl[key] as Node3D).duplicate()
	var t := _ext_template(rel)
	if t == null:
		_ext_tmpl[key] = null
		return null
	var n: Node3D = t.duplicate()
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		for si in m.mesh.get_surface_count():
			var src: Material = m.get_active_material(si)
			if src is StandardMaterial3D:
				var d: StandardMaterial3D = src.duplicate()
				d.albedo_color = Color(d.albedo_color.r * dim, d.albedo_color.g * dim, d.albedo_color.b * dim, d.albedo_color.a)
				d.emission_enabled = false
				# matte like the game's own rock: the photoscans' packed roughness maps and default
				# specular threw cyan speckles at 640x360 (metallic is left alone: brass stays brass)
				d.metallic_specular = 0.0
				d.roughness_texture = null
				d.roughness = 1.0
				m.set_surface_override_material(si, d)
	_ext_tmpl[key] = n
	return n.duplicate()


func _ext_hull(n: Node3D, rel: String, sc: float) -> void:
	# a convex hull per mesh, so boulders can be stood on and hooked like rock
	var t := _ext_template(rel)
	if t == null:
		return
	if not t.has_meta("hulls"):
		var hulls: Array = []
		for c in t.get_children():
			if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
				var shp: ConvexPolygonShape3D = (c as MeshInstance3D).mesh.create_convex_shape(true, true)
				if shp != null and shp.points.size() >= 4:
					hulls.append([shp.points, (c as Node3D).transform])
		t.set_meta("hulls", hulls)
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.physics_material_override = load("res://physics_materials/stone.tres")
	for h in t.get_meta("hulls"):
		var pts: PackedVector3Array = h[0]
		var xf: Transform3D = h[1]
		var out := PackedVector3Array()
		out.resize(pts.size())
		for i in pts.size():
			out[i] = (xf * pts[i]) * sc
		var shape := ConvexPolygonShape3D.new()
		shape.points = out
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)
	body.position = n.position
	body.rotation = n.rotation
	add_child(body)


func _place_bats() -> void:
	for b in L.get("bats", []):
		var s := BatSwarm.new()
		s.setup(b)
		add_child(s)


var _pale_mat: StandardMaterial3D


func _paint_pale(n: Node) -> void:
	# a husk of the pale kind: bone white, no glow
	if _pale_mat == null:
		_pale_mat = StandardMaterial3D.new()
		_pale_mat.albedo_color = Color(0.58, 0.55, 0.47)
		_pale_mat.metallic = 0.05
		_pale_mat.roughness = 0.85
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		for si in m.mesh.get_surface_count():
			m.set_surface_override_material(si, _pale_mat)


func _place_eggs() -> void:
	for e in L.get("eggs", []):
		var eg := EggCluster.new()
		eg.setup(e)
		add_child(eg)


# ------------------------------------------------------------------ v4.9 creatures (creatures.gd)
# Wall spiders over the Crystal Veins and Rootworks walkways, one husk on a Crystal Veins shelf that
# is not dead, and the brood asleep in the Nest's eggs. The authority runs their brains and streams
# them ("cx", 10 Hz); a bite goes to the bitten player like the Stalker's (cbite_ map event).

func _place_v49_creatures() -> void:
	for e in L.get("spiders", []):
		if not (e is Dictionary):
			continue
		var sp = Creatures.WallSpider.new()
		sp.setup(e, self)
		add_child(sp)
		sp.connect("bit", _on_creature_bit)
		_spiders.append(sp)
	var wh = L.get("waking_husk", null)
	if wh is Dictionary and (wh as Dictionary).has("trigger"):
		var hk = Creatures.WakingHusk.new()
		hk.setup(wh, self)
		add_child(hk)
		hk.attach_props(_husk_props)
		hk.connect("wake", _on_husk_wake)
		hk.connect("woke", _on_husk_woke)
		if _debug_tour:
			hk.set_process(false)            # the screenshot tour passes it: the husk must stay in the shots
		_husk = hk
	var eggs: Array = _brood_eggs()
	if not eggs.is_empty():
		var br = Creatures.Brood.new()
		br.setup({"points": eggs, "count": 13}, self)
		add_child(br)
		br.connect("bit", _on_creature_bit)
		_brood = br
	print("[Underdark] v4.9 creatures: %d wall spiders, husk=%s, brood=%s (%d egg clusters), %d husk props" % [_spiders.size(), str(_husk != null), str(_brood != null), eggs.size(), _husk_props.size()])


func _brood_eggs() -> Array:
	# The brood pours from the clusters around the altar, where the idol is taken. Most of the
	# Nest's clusters lie 90-170 m across the cavern: hatched there they would be past the brood's
	# 90 m leash (dead at birth) and behind a team already running the other way. Clusters within
	# 45 m of the altar; if the layout has fewer than two, the four nearest.
	var all: Array = L.get("eggs", [])
	if all.is_empty() or L.get("altar", []).is_empty():
		return all
	var ranked: Array = []
	for e in all:
		if e is Dictionary and (e as Dictionary).has("pos"):
			ranked.append([_v(e["pos"]).distance_to(_altar_pos), e])
	ranked.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var out: Array = []
	for r in ranked:
		if float(r[0]) < 45.0:
			out.append(r[1])
	if out.size() < 2:
		out.clear()
		for i in mini(4, ranked.size()):
			out.append(ranked[i][1])
	return out


func _bite_source(id: String):
	# the creature a bite id belongs to: "brood:<i>" or a spider id (null if unknown here)
	if id.begins_with("brood:"):
		return _brood if is_instance_valid(_brood) else null
	for sp in _spiders:
		if is_instance_valid(sp) and str(sp.get("id")) == id:
			return sp
	return null


func _on_creature_bit(who: Node3D, damage: float, id: String) -> void:
	# authority only (the creatures emit it there). The local player takes it at once; a teammate
	# gets a non-persistent map event and takes it on their own machine (like stalkbite_)
	if not is_instance_valid(who):
		return
	var src = _bite_source(id)
	if src == null:
		return
	if _debug_spider and Creatures.is_spider_id(id):
		print("[SPIDER] bite %s -> %s, %.0f damage" % [id, str(who.name), damage])
	if who == Game.climber:
		Creatures.bite_local(src.bite_origin(id), damage, Creatures.is_spider_id(id))
	else:
		var pid = who.get("peer_id")
		if pid != null:
			CoopSync.map_event("cbite_" + id, {"who": int(pid), "dmg": damage}, false)


func _on_husk_wake(pos: Vector3, yaw: float) -> void:
	# authority: the husk finished its shiver. Stored, so a reload or a late joiner finds the husk
	# gone and its centipede loose; the event itself spawns the centipede (_husk_event)
	var hid := "wh1"
	if is_instance_valid(_husk):
		hid = str(_husk.get("id"))
	CoopSync.map_event("husk_" + hid, {"pos": [pos.x, pos.y, pos.z], "yaw": yaw})


func _on_husk_woke() -> void:
	# every machine: the dead husk is gone, the live one stands where its head was
	_hide_husk_props()
	if _debug_spider:
		print("[HUSK] wake")
		_debug_shot("user://underdark_husk.png")


func _hide_husk_props() -> void:
	if _husk_hidden:
		return
	_husk_hidden = true
	for n in _husk_props:
		if is_instance_valid(n):
			(n as Node3D).visible = false
	for b in _husk_bodies:
		if is_instance_valid(b):
			(b as StaticBody3D).collision_layer = 0


func _husk_event(data: Dictionary, replay: bool) -> void:
	if is_instance_valid(_husk):
		var ph := int(_husk.get("phase"))
		if replay:
			if ph != 2:
				_husk.set_woken()            # quietly: no shiver, no snarl
		elif ph != 2 and not CoopSync.map_is_authority():
			_husk.remote_state([2])          # the event beat the stream here: finish the shiver now
	_hide_husk_props()
	if not CoopSync.map_is_authority():
		return                               # guests get its puppet from the host's centipede stream
	var wh = L.get("waking_husk", {})
	var pos := Vector3.ZERO
	var dp = data.get("pos", null)
	if dp is Array and (dp as Array).size() >= 3:
		pos = _v(dp)
	elif wh is Dictionary and (wh as Dictionary).has("head"):
		pos = _v(wh["head"])
	else:
		return
	var yaw := float(data.get("yaw", 0.0))
	_spawn_husk_centipede(pos, yaw, _reload_cp_pos() if replay else null, 60.0)


func _spawn_husk_centipede(pos: Vector3, yaw: float, grace_centre, grace_r: float) -> void:
	# the real pale centipede that was the husk, through the same path as the layout's groups:
	# a stable cid for the guests' puppets, the pale skin, and a home biome it never leaves.
	# grace_centre (Vector3 or null): spawned within grace_r of it, it starts asleep (_update_grace)
	if _real_spawned.has("waking_husk"):
		return
	var ps: PackedScene = load(CENTIPEDE)
	if ps == null:
		return
	_real_spawned["waking_husk"] = true
	var n: Node3D = ps.instantiate()
	n.position = pos
	n.rotation.y = yaw
	n.set_meta("zonda_cid", "waking_husk:0")
	var b := _biome_at(pos)
	var top := 1e9
	var bottom := -1e9
	for st in L.get("strata", []):
		if int(st["biome"]) == b:
			top = float(st["top"]) - 8.0          # the same band the layout gives this biome's centipedes
			bottom = float(st["bottom"]) - 8.0
	if top < 1e8:
		n.set_meta("zonda_territory", [top, bottom])
		_territorial.append([n, top, bottom, pos])
	add_child(n)
	if n.has_method("coop_apply_skin"):
		n.coop_apply_skin(1)
	if grace_centre is Vector3 and pos.distance_to(grace_centre) < grace_r:
		n.process_mode = Node.PROCESS_MODE_DISABLED
		n.visible = false
		_grace.append([n, Time.get_ticks_msec() + 10000, pos])
	print("[Underdark] the waking husk's centipede is loose at %s" % str(pos))
	if _debug_spider:
		print("[HUSK] centipede spawned at %s" % str(pos))


func _stream_creatures(delta: float) -> void:
	# host -> guests, 10 Hz: the brood (while it lives), every wall spider and the husk
	if not CoopSync.map_is_authority() or not CoopSync.in_session():
		return
	_cx_accum += delta
	if _cx_accum < 0.1:
		return
	_cx_accum = 0.0
	var cx := {}
	if is_instance_valid(_brood) and _brood.is_hatched() and float(_brood.get("clock")) < 80.0:
		cx["b"] = _brood.state_packet()
	if not _spiders.is_empty():
		# a spider waiting on its perch sends [] (guests ignore it): the packet stays small, under
		# one unreliable fragment even with the whole brood in it. REST is still sent, so a guest
		# always sees it back up on the rock, and REST and WAIT look the same there.
		var sp: Array = []
		var any_sp := false
		for s in _spiders:
			if is_instance_valid(s) and int(s.get("st")) != 0:
				sp.append(s.state_packet())
				any_sp = true
			else:
				sp.append([])
		if any_sp:
			cx["sp"] = sp
	if is_instance_valid(_husk):
		cx["wh"] = _husk.state_packet()
	if not cx.is_empty():
		CoopSync.map_stream({"cx": cx})


func _nearest_threat(p: Vector3) -> float:
	# the nearest awake hostile, for the heartbeat: centipedes (real or puppet), the Stalkers,
	# the brood, a spider off its perch, the husk while it shivers
	var best := 1e9
	for cent in Game.centipedes:
		if not is_instance_valid(cent):
			continue
		var cn := cent as Node3D
		if cn == null or not cn.is_inside_tree() or not cn.visible or cn.process_mode == Node.PROCESS_MODE_DISABLED:
			continue
		best = minf(best, cn.global_position.distance_to(p))
	for s in _stalkers:
		if is_instance_valid(s) and is_instance_valid(s.body):
			best = minf(best, (s.body as Node3D).global_position.distance_to(p))
	var lists: Array = []
	if is_instance_valid(_brood):
		lists.append(_brood.threat_positions())
	for sp in _spiders:
		if is_instance_valid(sp):
			lists.append(sp.threat_positions())
	if is_instance_valid(_husk):
		lists.append(_husk.threat_positions())
	for l in lists:
		for q in l:
			if q is Vector3:
				best = minf(best, (q as Vector3).distance_to(p))
	return best


func _enclosed(p: Vector3) -> bool:
	# a chamber or tunnel (tight, dry echo) rather than the open rift (huge, long echo): inside a
	# layout zone, or rock close overhead AND on at least three sides
	if _in_zone(p):
		return true
	var space := get_world_3d().direct_space_state
	var head := p + Vector3.UP * 1.6
	if space.intersect_ray(PhysicsRayQueryParameters3D.create(head, head + Vector3.UP * 16.0, 1)).is_empty():
		return false
	var walls := 0
	for d in [Vector3.RIGHT, Vector3.LEFT, Vector3.FORWARD, Vector3.BACK]:
		if not space.intersect_ray(PhysicsRayQueryParameters3D.create(head, head + (d as Vector3) * 14.0, 1)).is_empty():
			walls += 1
	return walls >= 3


func _update_soundscape(delta: float) -> void:
	if _ss == null:
		return
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var p: Vector3 = c.global_position
	if _cur_biome >= 0:
		_ss.set_biome(_cur_biome)
	_ss_open_t -= delta
	if _ss_open_t <= 0.0:
		_ss_open_t = 0.5
		var open := not _enclosed(p)
		if open == bool(_ss.get("is_open")):
			_ss_open_votes = 0
		else:
			_ss_open_votes += 1
			if _ss_open_votes >= 2:           # two checks in a row: a balcony's overhang does not flip it
				_ss_open_votes = 0
				_ss.set_open(open)
	_ss_threat_t -= delta
	if _ss_threat_t <= 0.0:
		_ss_threat_t = 0.2
		var d := 1e9
		if c.health > 0.0 and not c.get("coop_spectating"):
			d = _nearest_threat(p)
		_ss.set_threat(d)


func _update_haze(delta: float) -> void:
	# the Foundry's heat shimmer: full just above the lava lake, gone 60 m higher, a little near its
	# fires, nothing outside THE FOUNDRY. Eased over about a second, so it never pops.
	if _haze == null:
		return
	_haze_t -= delta
	if _haze_t <= 0.0:
		_haze_t = 0.25
		_haze_want = 0.0
		var c = Game.climber
		if is_instance_valid(c) and c.is_inside_tree() and _cur_biome == 7:
			var p: Vector3 = c.global_position
			if not _lava_box.is_empty():
				var q: Vector3 = p - _lava_box[0]
				if q.y > -4.0 and absf(q.dot(_lava_box[1])) < float(_lava_box[3]) + 30.0 and absf(q.dot(_lava_box[2])) < float(_lava_box[4]) + 30.0:
					_haze_want = clampf(1.0 - (q.y - 12.0) / 60.0, 0.0, 1.0)
			for fp in _foundry_fires:
				var fd: float = (fp as Vector3).distance_to(p)
				if fd < 10.0:
					_haze_want = maxf(_haze_want, 0.45 * clampf(1.0 - (fd - 2.0) / 8.0, 0.0, 1.0))
	_haze_k = move_toward(_haze_k, _haze_want, delta)
	_haze.set_strength(_haze_k)


# ------------------------------------------------------------------ v4.9 lantern oil (K10)

func _place_oil() -> void:
	# The lantern burns oil here (lantern.gd owns the tank, the gauge and the sharing). A new run
	# starts full; a death reload keeps the level, and the flasks this player already took stay gone.
	var ln = CoopSync.lantern
	if not is_instance_valid(ln):
		return
	if _oil_fresh:
		OilFlask.clear_taken()
	if "oil_enabled" in ln:
		ln.set("oil_enabled", true)
	if ln.has_method("begin_oil_run"):
		ln.call("begin_oil_run", _oil_fresh)
	if not ln.has_method("add_oil"):
		push_warning("[Underdark] lantern.gd has no oil yet: no flasks placed")
		return
	var taken: Dictionary = OilFlask.taken_ids()
	for e in L.get("oil", []):
		if not (e is Dictionary):
			continue
		var fid := str(e.get("id", ""))
		if fid == "" or taken.has(fid):
			continue
		var d: Dictionary = (e as Dictionary).duplicate()
		d["model"] = _ext_instance("ext/ph/metal_jug.glb", 0.5)  # null is fine: a clay flask then
		d["map"] = self
		var f: Node3D = OilFlask.new()
		f.setup(d)
		add_child(f)
		_flasks.append(f)
	print("[Underdark] oil: %s run, %d flasks placed (%d already taken)" % ["fresh" if _oil_fresh else "reloaded", _flasks.size(), taken.size()])


func _dim_materials(n: Node, k: float) -> void:
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var m := mi as MeshInstance3D
		if m.mesh == null:
			continue
		for si in m.mesh.get_surface_count():
			var src: Material = m.get_active_material(si)
			if not (src is StandardMaterial3D):
				continue
			if not _dimmed.has(src):
				var d: StandardMaterial3D = src.duplicate()
				d.albedo_color = Color(d.albedo_color.r * k, d.albedo_color.g * k, d.albedo_color.b * k, d.albedo_color.a)
				d.emission_enabled = false
				_dimmed[src] = d
			m.set_surface_override_material(si, _dimmed[src])


func _place_dress() -> void:
	# Kit rocks half-buried in the generated walls and floors. Each piece is measured
	# at runtime so the embed depth is right whatever its real bounds are.
	var cache: Dictionary = {}
	var placed := 0
	for d in L.get("dress", []):
		var path: String = d["scene"]
		var ext: bool = path.begins_with("ext/")
		var n: Node3D
		if ext:
			n = _ext_instance(path, 0.5)
			if n == null:
				continue
		else:
			if not cache.has(path):
				cache[path] = load(path)
			var ps: PackedScene = cache[path]
			if ps == null:
				continue
			n = ps.instantiate()
		var sc := float(d["scale"])
		var ab := _merged_aabb(n)
		if ab.size == Vector3.ZERO:
			n.queue_free()
			continue
		var hit := _v(d["hit"])
		var nrm := _v(d["n"])
		var embed := float(d.get("embed", 0.45))
		n.rotation = Vector3(float(d.get("tilt", 0.0)), float(d.get("yaw", 0.0)), float(d.get("roll", 0.0)))
		n.scale = Vector3.ONE * sc
		# Several kit rocks have their pivot at one end, so the mesh centre must be pushed
		# back through the same rotation, or the piece ends up floating out in the room.
		var basis := Basis.from_euler(n.rotation)
		var centre_off: Vector3 = basis * (ab.get_center() * sc)
		var half: Vector3 = ab.size * 0.5 * sc
		var reach: float = absf(basis.x.dot(nrm)) * half.x + absf(basis.y.dot(nrm)) * half.y + absf(basis.z.dot(nrm)) * half.z
		n.position = hit + nrm * (reach * (1.0 - 2.0 * embed)) - centre_off
		add_child(n)
		# same stone as the wall it grows out of, or it reads as a slab pasted on
		var db := clampi(_biome_at(hit), 0, _dress_mat.size() - 1)
		# the Burrows wall roots are heavy photoscans inside dark bending tubes: short draw
		# distance and no shadow pass (FPS pack)
		var root_dress: bool = path == "ext/ph/single_root.glb"
		for mi in n.find_children("*", "GeometryInstance3D", true, false):
			if not ext:
				(mi as GeometryInstance3D).material_override = _dress_mat[db]
			(mi as GeometryInstance3D).visibility_range_end = 45.0 if root_dress else 240.0
			(mi as GeometryInstance3D).visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			if root_dress:
				(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		placed += 1
	print("[Underdark] dressing pieces: %d" % placed)


func _merged_aabb(root: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi in root.find_children("*", "MeshInstance3D", true, false):
		var m: MeshInstance3D = mi
		if m.mesh == null:
			continue
		var xf := Transform3D.IDENTITY
		var node: Node = m
		while node != null and node != root:
			if node is Node3D:
				xf = (node as Node3D).transform * xf
			node = node.get_parent()
		var ab: AABB = xf * m.mesh.get_aabb()
		if first:
			out = ab
			first = false
		else:
			out = out.merge(ab)
	return out


func _place_lights() -> void:
	for l in L.get("lights", []):
		_add_light(_v(l["pos"]), _c(l["color"]), float(l["energy"]), float(l["range"]), true)


func _add_light(pos: Vector3, color: Color, energy: float, rng: float, fill: bool = false) -> OmniLight3D:
	var o := OmniLight3D.new()
	o.light_color = color
	o.light_energy = energy
	o.omni_range = rng
	o.shadow_enabled = false
	o.position = pos
	o.distance_fade_enabled = true
	# fully faded by LIGHT_FAR, where the budget switches it off anyway: no pop at 175 m
	var fade_len: float = 55.0 if rng >= 60.0 else 40.0
	o.distance_fade_begin = LIGHT_FAR - fade_len
	o.distance_fade_length = fade_len
	o.light_volumetric_fog_energy = 0.0     # the fog pass costs per light; the haze reads without them
	if fill:
		# plain fill light: the F4 shadow budget (gfx.gd) must never give it shadows, or NORMAL
		# PIXELS goes about 20% darker than the shipped look
		o.set_meta("zonda_no_shadow", true)
	add_child(o)
	_lights.append(o)
	return o


func _place_fires() -> void:
	for f in L.get("fires", []):
		_add_fire(_v(f["pos"]), float(f["scale"]), bool(f.get("beacon", false)))


var _dot_tex: GradientTexture2D


func _soft_dot() -> GradientTexture2D:
	if _dot_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		_dot_tex = GradientTexture2D.new()
		_dot_tex.gradient = g
		_dot_tex.fill = GradientTexture2D.FILL_RADIAL
		_dot_tex.fill_from = Vector2(0.5, 0.5)
		_dot_tex.fill_to = Vector2(0.5, 0.0)
		_dot_tex.width = 64
		_dot_tex.height = 64
	return _dot_tex


func _add_fire(pos: Vector3, s: float, beacon: bool = false) -> Node3D:
	# The game's "Pyrelight" is the tall pillar the campaign puts over its kiln shrines,
	# so it only belongs at checkpoints. Everything else gets an actual flame.
	if beacon:
		var ps: PackedScene = load(PYRELIGHT)
		if ps == null:
			return null
		var n: Node3D = ps.instantiate()
		n.position = pos
		n.scale = Vector3(s, s, s)
		add_child(n)
		return n
	var flame := CPUParticles3D.new()
	flame.amount = 12
	flame.lifetime = 0.9
	flame.explosiveness = 0.0
	flame.randomness = 0.6
	flame.local_coords = false
	flame.direction = Vector3.UP
	flame.spread = 14.0
	flame.gravity = Vector3(0, 1.4, 0)
	flame.initial_velocity_min = 0.7 * s
	flame.initial_velocity_max = 1.6 * s
	flame.scale_amount_min = 0.5 * s
	flame.scale_amount_max = 1.1 * s
	flame.damping_min = 0.6
	flame.damping_max = 1.4
	var grad := Gradient.new()
	# kept dim on purpose: the game doubles brightness in post, bright fire turns white
	grad.set_color(0, Color(0.55, 0.3, 0.08, 0.5))
	grad.set_color(1, Color(0.25, 0.04, 0.0, 0.0))
	grad.add_point(0.4, Color(0.5, 0.16, 0.02, 0.4))
	flame.color_ramp = grad
	var quad := QuadMesh.new()
	quad.size = Vector2(0.55, 0.7)
	var fm := StandardMaterial3D.new()
	fm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	fm.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	fm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	fm.albedo_texture = _soft_dot()
	fm.vertex_color_use_as_albedo = true
	fm.disable_receive_shadows = true
	quad.material = fm
	flame.mesh = quad
	flame.position = pos + Vector3(0, 0.25 * s, 0)
	flame.visibility_range_end = 140.0
	add_child(flame)
	var fl := Flicker.new()
	fl.setup(_add_light(pos + Vector3(0, 0.9 * s, 0), Color(1.0, 0.6, 0.25), 1.1 * s, 13.0 * s))
	add_child(fl)
	return flame


func _place_embers() -> void:
	var ps: PackedScene = load(EMBER)
	if ps == null:
		return
	for e in L.get("embers", []):
		var n: Node3D = ps.instantiate()
		n.position = _v(e["pos"])
		add_child(n)


func _place_crystals() -> void:
	for c in L.get("crystals", []):
		var mi := MeshInstance3D.new()
		var prism := PrismMesh.new()
		prism.size = Vector3(0.6, 1.6, 0.6)
		mi.mesh = prism
		mi.material_override = _mat_crystal_prop
		var s := float(c["s"])
		mi.position = _v(c["pos"]) + Vector3(0, 0.8 * s, 0)
		mi.scale = Vector3.ONE * s
		mi.rotation = Vector3(float(c["tilt"]), float(c["yaw"]), 0.0)
		mi.visibility_range_end = 220.0
		add_child(mi)
		_crystal_n += 1
		if _crystal_n % 4 == 0:
			_add_light(_v(c["pos"]) + Vector3(0, 2.5 * s, 0), Color(0.45, 0.75, 1.0), 0.6, 14.0 + 3.0 * s, true)


func _place_texts() -> void:
	for t in L.get("texts", []):
		var a := _area(_v(t["pos"]), float(t["r"]), PLAYER_LAYER)
		a.set_script(load(TEXT_AREA_SCRIPT))
		a.set("displayed_text", t["text"])
		add_child(a)


# ------------------------------------------------------------------ checkpoints and respawn

func _place_checkpoints() -> void:
	for c in L.get("checkpoints", []):
		var a := _area(_v(c["pos"]), float(c["r"]), PLAYER_LAYER)
		var id := int(c["id"])
		a.body_entered.connect(func(body: Node3D): _on_checkpoint(id, body))
		add_child(a)
	# a death reloads the map: put the player at the team's furthest checkpoint
	var cp := CoopSync.map_checkpoint_for(scene_file_path)
	if cp >= 0:
		# the respawn already restores health: no free +60 on reload, here or at any checkpoint
		# the team already passed
		for c0 in L.get("checkpoints", []):
			if int(c0["id"]) <= cp:
				_cp_healed[int(c0["id"])] = true
		for c in L.get("checkpoints", []):
			if int(c["id"]) == cp:
				var climber = get_node_or_null("Climber")
				if climber:
					climber.position = _v(c["pos"]) + Vector3(0.5, 0.2, 0.5)
					# the same short grace a co-op respawn gets (counted from the end of the build)
					call_deferred("_reload_grace")
				break


func _reload_grace() -> void:
	var climber = get_node_or_null("Climber")
	if climber != null and "_coop_invuln_until_ms" in climber:
		climber.set("_coop_invuln_until_ms", Time.get_ticks_msec() + 3000)


func _on_checkpoint(id: int, body: Node3D) -> void:
	if body != Game.climber:
		return
	var label := ""
	for c in L["checkpoints"]:
		if int(c["id"]) == id:
			label = str(c["label"])
	# every player gets the heal once per checkpoint on their own first arrival, not only the
	# one who moves the team's checkpoint forward
	var healed_now := false
	if not _cp_healed.has(id):
		_cp_healed[id] = true
		healed_now = true
		Game.audio.play_player_healed()
		if is_instance_valid(Game.climber):
			Game.climber.heal(60.0)
	if id <= CoopSync.map_checkpoint_for(scene_file_path):
		if healed_now:
			CoopSync.show_banner("Checkpoint: %s" % label, 3.0)
		return
	CoopSync.map_checkpoint(id, scene_file_path)
	CoopSync.show_banner("Checkpoint: %s" % label, 4.0)


# ------------------------------------------------------------------ traps

func _place_crumbles() -> void:
	var ps: PackedScene = load("res://Art/Sand_Shelf_Base.glb")
	if ps == null:
		return
	for c in L.get("crumbles", []):
		var n: Node3D = ps.instantiate()
		n.position = _v(c["pos"])
		n.rotation.y = float(c["yaw"])
		n.scale = Vector3.ONE * float(c["scale"])
		add_child(n)
		var trap := Crumble.new()
		trap.setup(str(c["id"]), n, 4.7 * float(c["scale"]) + 1.4)
		add_child(trap)
		_crumbles[str(c["id"])] = trap


func _place_vents() -> void:
	for v in L.get("vents", []):
		var pos := _v(v["pos"])
		var fire := _add_fire(pos, 0.35)
		var light := _add_light(pos + Vector3(0, 1.5, 0), Color(1.0, 0.55, 0.2), 0.7, 14.0)
		var vent := FireVent.new()
		vent.setup(fire, light, pos, float(v["period"]), float(v["phase"]))
		add_child(vent)


func _place_droppers() -> void:
	for d in L.get("droppers", []):
		var kind := str(d["kind"])
		var icicle: bool = kind == "icicle"
		var tower: bool = kind == "tower"
		var ps: PackedScene = load("res://Art/Ghost_Tower_02.glb" if tower else ("res://Art/Spikes_01.glb" if icicle else "res://Art/Stone_09.glb"))
		if ps == null:
			continue
		var rock: Node3D = ps.instantiate()
		for body in rock.find_children("*", "StaticBody3D", true, false):
			body.queue_free()
		rock.position = _v(d["hang"])
		if tower:
			rock.scale = Vector3.ONE * 0.45
			rock.rotation = Vector3(PI, randf() * TAU, 0)
			for mi in rock.find_children("*", "GeometryInstance3D", true, false):
				(mi as GeometryInstance3D).material_override = _mat_ruin
		elif icicle:
			rock.scale = Vector3.ONE * 0.16
			rock.rotation = Vector3(PI, randf() * TAU, 0)
			for mi in rock.find_children("*", "MeshInstance3D", true, false):
				(mi as MeshInstance3D).material_override = _mat_crystal
		else:
			rock.scale = Vector3.ONE * 0.5
			rock.rotation = Vector3(randf_range(-0.3, 0.3), randf() * TAU, randf_range(-0.3, 0.3))
		add_child(rock)
		var trap := Dropper.new()
		var trip: Array = d["trip"]
		trap.setup(str(d["id"]), rock, _v(trip[0]), float(trip[1]), 7.0 if tower else (2.4 if icicle else 3.6), float(d["floor"]))
		if tower:
			trap.damage = 90.0
			trap.fall_time = 1.6
			trap.reset_after = 9999.0
		add_child(trap)
		_droppers[str(d["id"])] = trap


func _place_spikes() -> void:
	for s in L.get("spikes", []):
		var a := _area(_v(s["pos"]), float(s["r"]), PLAYER_LAYER)
		add_child(a)
		var trap := SpikeBed.new()
		trap.setup(a, _v(s["push"]))
		add_child(trap)


func _place_ice() -> void:
	for i in L.get("ice", []):
		var a := _area(_v(i["pos"]), float(i["r"]), PLAYER_LAYER)
		add_child(a)
		var sl := IceShelf.new()
		sl.setup(a, _v(i["dir"]))
		add_child(sl)


# ------------------------------------------------------------------ puzzles

func _place_gates() -> void:
	for g in L.get("gates", []):
		var gate := Gate.new()
		gate.setup(g, _mat_bar)
		add_child(gate)
		_gates[str(g["id"])] = gate


func _place_kilns() -> void:
	var ps: PackedScene = load("res://Art/Ancient_Kiln.glb")
	for k in L.get("kilns", []):
		var pos := _v(k["pos"])
		var n: Node3D = null
		if ps:
			n = ps.instantiate()
			n.position = pos
			n.scale = Vector3.ONE * 0.8
			add_child(n)
		var kiln := Kiln.new()
		kiln.setup(str(k["gate"]), int(k["idx"]), pos)
		add_child(kiln)
		_kilns[int(k["idx"])] = kiln


func _place_plates() -> void:
	for p in L.get("plates", []):
		var plate := Plate.new()
		plate.setup(str(p["gate"]), int(p["idx"]), _v(p["pos"]), _mat_bar)
		add_child(plate)
		_plates.append(plate)


func _place_fragments() -> void:
	for f in L.get("fragments", []):
		var frag := Fragment.new()
		frag.setup(str(f["id"]), _v(f["pos"]), _mat_crystal)
		add_child(frag)
		_fragments[str(f["id"])] = frag


# ------------------------------------------------------------------ relics of the short way

func _place_relics() -> void:
	# One at the bottom of each secret ladder. Taking it is permanent and per player:
	# 1 = your name burns gold for your team, 2 = your rope turns gold, 3 = a crown.
	for r in L.get("relics", []):
		var id := str(r["id"])
		var pos := _v(r["pos"])
		var root := Node3D.new()
		root.position = pos
		for spec in [[1.5, Color(0.36, 0.26, 0.06, 0.8)], [0.5, Color(0.5, 0.4, 0.14, 0.95)]]:
			var mi := MeshInstance3D.new()
			var qm := QuadMesh.new()
			qm.size = Vector2(spec[0], spec[0])
			mi.mesh = qm
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_texture = _soft_dot()
			m.albedo_color = spec[1]
			m.disable_fog = true
			mi.material_override = m
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			root.add_child(mi)
		var l := _add_light(pos, Color(1.0, 0.78, 0.3), 0.7, 12.0)
		if CoopSync.relic_has(id):
			root.scale = Vector3.ONE * 0.45          # you already carry this one
			l.light_energy = 0.25
		add_child(root)
		var a := _area(pos, 2.4, PLAYER_LAYER)
		a.body_entered.connect(func(body: Node3D): _on_relic(id, body, root, l))
		add_child(a)
	_apply_rope_gold()


func _on_relic(id: String, body: Node3D, root: Node3D, l: OmniLight3D) -> void:
	if body != Game.climber or _debug_tour or Game.climber.prevent_player_death:
		return          # the developer tour teleports through here: it must never hand out relics
	if not CoopSync.relic_grant(id):
		return
	root.scale = Vector3.ONE * 0.45
	l.light_energy = 0.25
	var n: int = CoopSync.cosmetics
	var what := "Your name burns gold for your team."
	if n == 2:
		what = "Your rope is gold now."
	elif n >= 3:
		what = "All three. Your team will see the crown."
	CoopSync.show_banner("A relic of the short way  (%d of 3).  %s" % [n, what], 7.0)
	Game.audio.play_dark_transition()
	_apply_rope_gold()


func _apply_rope_gold() -> void:
	if CoopSync.cosmetics < 2:
		return
	var c = Game.climber
	if not is_instance_valid(c):
		return
	for n in c.find_children("*", "", true, false):
		var mats = n.get("grapplePointLineMaterial")
		if mats is Array:
			for m in mats:
				if m is StandardMaterial3D:
					(m as StandardMaterial3D).albedo_color = Color(0.55, 0.4, 0.12)


func _place_altar() -> void:
	for a in L.get("altar", []):
		var pos := _v(a["pos"])
		var plinth := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 1.6
		cyl.bottom_radius = 2.1
		cyl.height = 1.4
		plinth.mesh = cyl
		plinth.material_override = _wall_mat[8]
		plinth.position = pos + Vector3(0, 0.7, 0)
		add_child(plinth)
		var body := StaticBody3D.new()
		body.collision_layer = 1
		var cs := CollisionShape3D.new()
		var sh := CylinderShape3D.new()
		sh.radius = 1.9
		sh.height = 1.4
		cs.shape = sh
		body.add_child(cs)
		body.position = plinth.position
		add_child(body)
		var idol: PackedScene = load("res://Art/Praxthos.glb")
		if idol:
			_idol_node = idol.instantiate()
			_idol_node.position = pos + Vector3(0, 1.4, 0)
			_idol_node.scale = Vector3.ONE * 1.3
			add_child(_idol_node)
		_altar_pos = pos
		_altar_light = _add_light(pos + Vector3(0, 3.5, 0), Color(1.0, 0.85, 0.5), 2.0, 26.0)
		var grab := _area(pos + Vector3(0, 2.2, 0), 3.2, PLAYER_LAYER)
		grab.body_entered.connect(_on_idol_touch)
		add_child(grab)
	for f in L.get("finish", []):
		var fin := _area(_v(f["pos"]), float(f["r"]), PLAYER_LAYER)
		fin.body_entered.connect(_on_finish)
		add_child(fin)


func _on_idol_touch(body: Node3D) -> void:
	if body != Game.climber or _idol_taken:
		return
	CoopSync.map_event("idol", {"by": CoopSync.local_name, "id": CoopSync.my_id()})


func _is_me(data: Dictionary) -> bool:
	# who an event names: by Steam id when both sides have one, else by name (solo)
	var who := int(data.get("id", 0))
	if who != 0 and CoopSync.my_id() != 0:
		return who == CoopSync.my_id()
	return str(data.get("by", "")) == CoopSync.local_name


func _finale(by: String, replay: bool = false) -> void:
	if _idol_taken:
		return
	_idol_taken = true
	_idol_by = by
	if is_instance_valid(_follower):
		_follower.set_meta("zonda_no_lure", true)     # once the idol is taken the bell cannot hold it
	if is_instance_valid(_idol_node):
		_idol_node.visible = false
	_nest_lights.clear()
	for l in _lights:
		if is_instance_valid(l) and (l.position - _altar_pos).length() < 110.0:
			_nest_lights.append([l, l.light_energy, l.light_color])
	if replay:
		# a reload or a late join after the idol was taken: the end state at once, no blackout,
		# no banner, no waiting
		for e in _nest_lights:
			e[0].light_color = Color(1.0, 0.12, 0.08)
			e[0].light_energy = e[1] * 0.7
		if is_instance_valid(_altar_light):
			_altar_light.light_color = Color(1.0, 0.15, 0.1)
		if _music:
			_music.finale()
		for c in L.get("centipedes", []):
			if str(c.get("on", "")) == "idol":
				_release_centipedes(str(c["id"]), true)
		if _gates.has("gate_exit"):
			_gates["gate_exit"].latched = true
			_gates["gate_exit"].open(true)
		_follower_join_finale(true)
		return
	Game.audio.play_dark_transition()
	# every light in the Nest dies for two seconds, then comes back red and pulsing
	for e in _nest_lights:
		var tw := create_tween()
		tw.tween_property(e[0], "light_energy", 0.0, 0.4)
	CoopSync.show_banner("%s took the idol. THE NEST WAKES. RUN." % by, 6.0)
	if _music:
		_music.finale()
	await get_tree().create_timer(2.0).timeout
	if not is_inside_tree():
		return
	for e in _nest_lights:
		e[0].light_color = Color(1.0, 0.12, 0.08)
		var tw := create_tween()
		tw.tween_property(e[0], "light_energy", e[1] * 0.7, 1.0)
	if is_instance_valid(_altar_light):
		_altar_light.light_color = Color(1.0, 0.15, 0.1)
	# the lights come back red and the eggs split: the brood pours out over ~3 s and chases the
	# team to the exit (the authority hatches and streams them; a guest's call only prepares them)
	if is_instance_valid(_brood):
		_brood.hatch()
		print("[Underdark] the brood hatches")
	for c in L.get("centipedes", []):
		if str(c.get("on", "")) == "idol":
			_release_centipedes(str(c["id"]), true)     # quiet: "RUN." keeps the screen
	if _gates.has("gate_exit"):
		_gates["gate_exit"].latched = true
		_gates["gate_exit"].open()
	# a few seconds later the thing that followed you all the way down comes through the tunnel
	# (after the 6 s RUN banner has had its full time)
	await get_tree().create_timer(4.2).timeout
	if is_inside_tree():
		_follower_join_finale()


# ------------------------------------------------------------------ the crucible

func _place_lanterns() -> void:
	# points of light hung along the rift, so the eye can measure the dark
	var sphere := QuadMesh.new()
	sphere.size = Vector2(1.0, 1.0)
	var mats: Dictionary = {}
	for ln in L.get("lanterns", []):
		var col := _c(ln["color"])
		var key := col.to_html()
		if not mats.has(key):
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.albedo_texture = _soft_dot()
			m.albedo_color = Color(col.r * 0.14, col.g * 0.14, col.b * 0.14, 0.85)
			m.disable_fog = true
			mats[key] = m
		var mi := MeshInstance3D.new()
		mi.mesh = sphere
		mi.material_override = mats[key]
		mi.position = _v(ln["pos"])
		mi.scale = Vector3.ONE * float(ln["s"])
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = 330.0
		add_child(mi)


func _collect_lights() -> void:
	# after the game has gathered the level's lights (it does that a frame or two in), take
	# ours back off its list so its very permissive rule stops switching them on behind us
	await get_tree().create_timer(1.5).timeout
	if not is_inside_tree():
		return
	_managed_lights.clear()
	for n in find_children("*", "OmniLight3D", true, false):
		var l: OmniLight3D = n
		if l.has_meta("zonda_keep"):
			continue
		l.set_meta("zonda_managed", true)
		l.light_volumetric_fog_energy = 0.0
		# every managed light is fully faded by LIGHT_FAR, so the 175 m cut never pops
		var fl: float = 55.0 if l.omni_range >= 60.0 else 40.0
		l.distance_fade_enabled = true
		l.distance_fade_begin = LIGHT_FAR - fl
		l.distance_fade_length = fl
		_managed_lights.append(l)
	var we = IOAWorldEnvironment.current
	if we != null:
		var keep: Array[OmniLight3D] = []
		for l2 in we._all_omnilights_in_level:
			if is_instance_valid(l2) and not l2.has_meta("zonda_managed"):
				keep.append(l2)
		we._all_omnilights_in_level = keep
	print("[Underdark] light budget: %d of ours managed, %d left to the game" % [_managed_lights.size(), we._all_omnilights_in_level.size() if we else -1])


func _update_light_budget(delta: float) -> void:
	if _managed_lights.is_empty():
		return
	_light_tick -= delta
	if _light_tick > 0.0:
		return
	_light_tick = 0.3
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var eye := cam.global_position
	var alive: Array = []
	var ranked: Array = []
	for l in _managed_lights:
		if not is_instance_valid(l):
			continue
		alive.append(l)
		var d: float = eye.distance_to(l.global_position)
		if d > LIGHT_FAR:
			if l.visible:
				l.visible = false
			continue
		ranked.append([d, l])
	_managed_lights = alive
	ranked.sort_custom(func(a, b): return a[0] < b[0])
	for i in ranked.size():
		var want: bool = i < LIGHT_BUDGET
		var lt: OmniLight3D = ranked[i][1]
		if lt.visible != want:
			lt.visible = want


func _place_mist() -> void:
	# Clouds that sit in the world: spore banks on the Fungal balconies, mist over the Drowned
	# footholds, cold haze in the Crystal Veins. They need the game's volumetric fog (on by
	# default in its video settings); with it off they simply are not there.
	var mist_i := -1
	for m in L.get("mist", []):
		mist_i += 1
		if mist_i % 2 == 1:
			continue
		var fv := FogVolume.new()
		fv.shape = RenderingServer.FOG_VOLUME_SHAPE_ELLIPSOID
		var sz: Array = m["size"]
		fv.size = Vector3(float(sz[0]), float(sz[1]), float(sz[2]))
		var fm := FogMaterial.new()
		fm.density = float(m["density"])
		var col := _c(m["color"])
		fm.albedo = col
		fm.emission = Color(col.r * 0.06, col.g * 0.06, col.b * 0.06)
		fm.edge_fade = 0.6
		fv.material = fm
		fv.position = _v(m["pos"])
		add_child(fv)


func _place_platforms() -> void:
	var wood: StandardMaterial3D = load("res://Art/Textures/Wood_01.tres")
	for d in L.get("platforms", []):
		var pf := HangingPlatform.new()
		pf.setup(d, _mat_bar if str(d["kind"]) == "iron" else wood, _mat_bar)
		add_child(pf)
		_platforms[str(d["id"])] = pf


func _place_spars() -> void:
	for d in L.get("spars", []):
		var sp := CrystalSpar.new()
		sp.dot_tex = _soft_dot()
		sp.setup(_v(d["a"]), _v(d["b"]), float(d["r"]))
		add_child(sp)


func _place_falls() -> void:
	for d in L.get("falls", []):
		var wf := Waterfall.new()
		wf.setup(_v(d["pos"]), float(d["height"]), _v(d["push"]))
		add_child(wf)


func _place_ghosts() -> void:
	var ps: PackedScene = load("res://Art/Knight.glb")
	if ps == null:
		return
	var gm := StandardMaterial3D.new()
	gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.albedo_color = Color(0.06, 0.085, 0.1, 0.3)
	gm.cull_mode = BaseMaterial3D.CULL_BACK
	for g in L.get("ghosts", []):
		var gh := Ghost.new()
		gh.setup(ps, gm, _v(g["pos"]), float(g["yaw"]))
		add_child(gh)


func _place_bells() -> void:
	for b in L.get("bells", []):
		var bell := Bell.new()
		bell.setup(b, _mat_bar)
		add_child(bell)
		_bells[str(b["id"])] = bell


func _place_bars() -> void:
	for b in L.get("bars", []):
		var bar := MonkeyBar.new()
		bar.dot_tex = _soft_dot()
		bar.setup(b, _mat_bar)
		add_child(bar)
		_bars.append(bar)


func _place_lava() -> void:
	for lv in L.get("lava", []):
		var c := _v(lv["center"])
		var yaw := float(lv["yaw"])
		var d := Vector3(cos(yaw), 0, sin(yaw))
		var s := Vector3(-sin(yaw), 0, cos(yaw))
		var hw := float(lv["half_w"])
		var hl := float(lv["half_l"])
		var mi := MeshInstance3D.new()
		var stl := SurfaceTool.new()
		stl.begin(Mesh.PRIMITIVE_TRIANGLES)
		var rr := maxf(hw, hl) * 1.25
		for i in 48:
			var a0 := TAU * float(i) / 48.0
			var a1 := TAU * float(i + 1) / 48.0
			stl.set_normal(Vector3.UP)
			stl.add_vertex(Vector3.ZERO)
			stl.set_normal(Vector3.UP)
			stl.add_vertex(Vector3(cos(a1) * rr, 0, sin(a1) * rr))
			stl.set_normal(Vector3.UP)
			stl.add_vertex(Vector3(cos(a0) * rr, 0, sin(a0) * rr))
		mi.mesh = stl.commit()
		mi.material_override = _mat_lava
		mi.position = c
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		_add_light(c + Vector3(0, 6, 0), Color(1.0, 0.45, 0.1), 3.0, 70.0)
		_add_light(c + d * hw * 0.6 + Vector3(0, 6, 0), Color(1.0, 0.45, 0.1), 2.0, 50.0)
		_add_light(c - d * hw * 0.6 + Vector3(0, 6, 0), Color(1.0, 0.45, 0.1), 2.0, 50.0)
		_lava_box = [c, d, s, hw, hl]
		_lava_kill_y = c.y + 3.0


func _check_lava() -> void:
	if _lava_box.is_empty():
		return
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree() or c.get("coop_spectating"):
		return
	var p: Vector3 = c.global_position
	if p.y > _lava_kill_y:
		return
	var q: Vector3 = p - _lava_box[0]
	if absf(q.dot(_lava_box[1])) < _lava_box[3] and absf(q.dot(_lava_box[2])) < _lava_box[4]:
		if c.health > 0.0 and not c.lethalDamageHandled:
			c.take_damage(400.0)


# ------------------------------------------------------------------ creatures and scares

func _place_creatures() -> void:
	for s in L.get("stalkers", []):
		var st := Stalker.new()
		st.setup(s)
		add_child(st)
		_stalkers.append(st)
	for c in L.get("centipedes", []):
		if c.has("on"):
			continue
		var trig: Array = c["trigger"]
		var a := _area(_v(trig[0]), float(trig[1]), PLAYER_LAYER)
		var id := str(c["id"])
		a.body_entered.connect(func(body: Node3D): _on_centipede_trigger(id, body))
		add_child(a)


func _on_centipede_trigger(id: String, body: Node3D) -> void:
	if body != Game.climber:
		return
	if CoopSync.map_event_done("cent_" + id):
		# already woken this run, but a death reload above its trigger left it asleep (see
		# _cent_below_reload): wake it again now, behind the team, exactly like the first pass.
		# Not stored, so it reaches the host whoever walks in first.
		if not _spawned_cents.has(id):
			CoopSync.map_event("cent_" + id, {"id": id}, false)
		return
	CoopSync.map_event("cent_" + id, {"id": id})


func _cent_entry(id: String) -> Dictionary:
	for c in L.get("centipedes", []):
		if str(c["id"]) == id:
			return c
	return {}


func _reload_cp_pos():
	# where a death reload put the team (null on a fresh start)
	var cp := CoopSync.map_checkpoint_for(scene_file_path)
	if cp < 0:
		return null
	for c in L.get("checkpoints", []):
		if int(c["id"]) == cp:
			return _v(c["pos"])
	return null


func _cent_below_reload(id: String) -> bool:
	# a woken group whose trigger lies deeper than the checkpoint the team reloads at: the team
	# has to pass that trigger again, so the group sleeps until then instead of waiting at the spawn
	var cp = _reload_cp_pos()
	if cp == null:
		return false
	var c := _cent_entry(id)
	if not c.has("trigger"):
		return false
	var trig: Array = c["trigger"]
	return float(trig[0][1]) < (cp as Vector3).y


func _release_centipedes(id: String, quiet: bool = false) -> void:
	if _spawned_cents.has(id):
		return
	if _replaying:
		quiet = true
	_spawned_cents[id] = true
	if not quiet:
		_release_warning(id)            # every player hears it, live only (never on a replay)
	# Guests get puppets from the host's centipede stream, so only the authority spawns.
	if not CoopSync.map_is_authority():
		return
	var centre = _reload_cp_pos() if _replaying else null
	_spawn_zone(id, centre, 60.0)


func _release_warning(id: String) -> void:
	# only players near the trigger: a teammate 300 m away is not told "something lives here"
	var c := _cent_entry(id)
	var me = Game.climber
	if c.has("trigger") and is_instance_valid(me) and me.is_inside_tree():
		var trig: Array = c["trigger"]
		if (me as Node3D).global_position.distance_to(_v(trig[0])) > 150.0:
			return
	if id == "follower":
		CoopSync.show_banner("Something followed you in. It will not stop.", 4.0)
	else:
		CoopSync.show_banner("Something lives here.", 3.0)
	Game.audio.play_dark_transition()


func _spawn_zone(id: String, grace_centre, grace_r: float) -> void:
	# the authority's real creatures for one centipede group, at their layout spawn points.
	# grace_centre (a Vector3 or null): a spawn within grace_r of it starts asleep (see _update_grace)
	var ps: PackedScene = load(CENTIPEDE)
	if ps == null:
		return
	var c := _cent_entry(id)
	if c.is_empty():
		return
	_real_spawned[id] = true
	var idol_group: bool = str(c.get("on", "")) == "idol"
	var spawns: Array = c["spawn"]
	for si in spawns.size():
		var sp := _v(spawns[si])
		var n: Node3D = ps.instantiate()
		n.position = sp
		n.set_meta("zonda_cid", "%s:%d" % [id, si])        # stable id for the guests' puppets
		if c.has("territory"):
			# it belongs to this biome and stays here after you leave
			var t: Array = c["territory"]
			n.set_meta("zonda_territory", [float(t[0]), float(t[1])])
			_territorial.append([n, float(t[0]), float(t[1]), sp])
		elif idol_group:
			n.set_meta("zonda_no_lure", true)                 # the bell cannot hold the Nest's chasers
			if _replaying:
				# a reload after the idol was taken: they sleep at the altar until the team comes back
				# within reach, instead of hunting a respawn 300 m away
				_territorial.append([n, 1e9, -1e9, sp])
		add_child(n)
		if c.has("skin") and n.has_method("coop_apply_skin"):
			n.coop_apply_skin(1 if str(c["skin"]) == "pale" else 0)
		if bool(c.get("follower", false)):
			_follower = n
			n.set_meta("zonda_cid", "follower:0")
		if grace_centre is Vector3 and sp.distance_to(grace_centre) < grace_r:
			n.process_mode = Node.PROCESS_MODE_DISABLED
			n.visible = false
			_grace.append([n, Time.get_ticks_msec() + 10000, sp])


func _update_grace() -> void:
	# a creature spawned asleep wakes once every living player is 25 m from its spawn, or after 10 s
	if _grace.is_empty():
		return
	var players: Array = CoopSync.alive_player_nodes()
	var now := Time.get_ticks_msec()
	var keep: Array = []
	for g in _grace:
		var n = g[0]
		if not is_instance_valid(n):
			continue
		var clear := true
		for p in players:
			if (p as Node3D).global_position.distance_to(g[2]) < 25.0:
				clear = false
				break
		if clear or now >= int(g[1]):
			if n == _follower and _burrow_parked:
				continue                 # parked outside the Burrows: it wakes with the unpark instead
			n.process_mode = Node.PROCESS_MODE_INHERIT
			n.visible = true
		else:
			keep.append(g)
	_grace = keep


func _in_grace(n: Node) -> bool:
	for g in _grace:
		if g[0] == n:
			return true
	return false


func coop_session_ended() -> void:
	# the host left and this player goes on alone: this machine is the authority now. The guest
	# only ever had puppets (CoopSync just freed them), so every group the team woke gets real
	# creatures again, fresh at their own spawn points; a spawn too close to the player starts
	# asleep. The stalkers and the plates switch to local rule on their own (map_is_authority).
	if not CoopSync.map_is_authority():
		return
	var me = Game.climber
	var here = null
	if is_instance_valid(me) and me.is_inside_tree():
		here = (me as Node3D).global_position
	for id in _spawned_cents.keys():
		var sid := str(id)
		if _real_spawned.has(sid):
			continue
		if sid == "follower" and _idol_taken:
			continue                     # it joins the finale below instead
		_spawn_zone(sid, here, 25.0)
	if _idol_taken and not _real_spawned.has("follower_finale"):
		_follower_join_finale(true)
	# the waking husk's centipede, if it got up while the host ran it
	var wh = L.get("waking_husk", null)
	if wh is Dictionary and (wh as Dictionary).has("head") and _applied.has("husk_" + str(wh.get("id", "wh1"))):
		_spawn_husk_centipede(_v(wh["head"]), float(wh.get("yaw", 0.0)), here, 25.0)
	for s in _stalkers:
		s.rp_pos = s.body.position
	print("[Underdark] session ended: now the authority, %d creature groups respawned" % _real_spawned.size())


# One centipede follows the team for the whole descent. It cannot squeeze through the Burrows
# or path around the Lid, so when it falls far behind (or is walled off) the host puts it back
# on the rift wall above and behind the team, out of sight. It never appears ahead of you.
func _update_centipedes(delta: float) -> void:
	if not CoopSync.map_is_authority():
		return
	_cent_tick -= delta
	if _cent_tick > 0.0:
		return
	_cent_tick = 2.0
	_update_creature_centres()
	_update_grace()
	var players: Array = CoopSync.alive_player_nodes()
	if players.is_empty():
		return
	var in_burrows := false
	for p in players:
		if _in_burrows((p as Node3D).global_position, false):
			in_burrows = true
			break
	if _spawned_cents.has("follower") and not _idol_taken:
		var need := false
		# It cannot squeeze into the Burrows: while anyone is inside, it waits outside, asleep and
		# hidden. Once everyone is out it comes back behind and above the team.
		if in_burrows and not _burrow_parked and is_instance_valid(_follower):
			_burrow_parked = true
			_follower.process_mode = Node.PROCESS_MODE_DISABLED
			_follower.visible = false
		elif _burrow_parked and not in_burrows:
			_burrow_parked = false
			if is_instance_valid(_follower):
				_follower.process_mode = Node.PROCESS_MODE_INHERIT
				_follower.visible = true
			need = true
		if not _burrow_parked and not in_burrows:
			if not is_instance_valid(_follower) or not _follower.is_inside_tree():
				need = true
			elif not _in_grace(_follower):
				var d := 1e9
				for p in players:
					d = minf(d, (p as Node3D).global_position.distance_to(_follower.global_position))
				if d < _follow_best - 6.0:
					_follow_best = d
					_follow_stall = 0.0
				else:
					_follow_stall += 2.0
				if d > 240.0 or (_follow_stall >= 36.0 and d > 55.0):
					need = true
				elif _in_burrows(_follower.global_position, true):
					need = true                  # it got into a tube after all: put it back outside
			if need:
				var spot = _follower_spot(players)
				if spot != null:
					_replace_follower(spot)
	# the ones that live in a biome: idle when nobody is in it, and never wander out of it
	for e in _territorial:
		var n2 = e[0]
		if not is_instance_valid(n2) or not n2.is_inside_tree():
			continue
		if _in_grace(n2):
			continue
		var bottom: float = float(e[2])
		if n2.has_meta("zonda_territory"):
			# nothing that lives out in the rift follows anyone into the Burrows: while someone is
			# inside, its hunting band stops above the Burrow Mouth (and the leash below uses it)
			if in_burrows and bottom < _burrow_top and float(e[1]) > _burrow_top:
				bottom = _burrow_top
			n2.set_meta("zonda_territory", [float(e[1]), bottom])
		var near_any := 1e9
		for p in players:
			near_any = minf(near_any, (p as Node3D).global_position.distance_to(n2.global_position))
		var awake: bool = near_any < 190.0
		if awake == (n2.process_mode == Node.PROCESS_MODE_DISABLED):
			n2.process_mode = Node.PROCESS_MODE_INHERIT if awake else Node.PROCESS_MODE_DISABLED
			n2.visible = awake
		if not awake:
			var isf = n2.get("idle_sfx")
			if is_instance_valid(isf) and isf.playing:
				isf.stop()
			continue
		if _in_burrows(n2.global_position, true):
			# it crawled into a Burrows tube: back to its den
			n2.global_position = e[3]
			n2.set_state(centipede_state_wander.new())
			continue
		var target = CoopSync.target_player_for(n2)
		if target == null and (n2._current_state is centipede_state_hunting or n2._current_state is centipede_state_attack):
			n2.set_state(centipede_state_wander.new())
		var y: float = n2.global_position.y
		if target == null and (y > float(e[1]) + 40.0 or y < bottom - 40.0):
			var near := 1e9
			for p in players:
				near = minf(near, (p as Node3D).global_position.distance_to(n2.global_position))
			if near > 120.0:
				n2.global_position = e[3]
				n2.set_state(centipede_state_wander.new())


func _follower_join_finale(quiet: bool = false) -> void:
	if not quiet:
		CoopSync.show_banner("It was behind you the whole way.", 5.0)
	if not CoopSync.map_is_authority():
		return
	var fin = L.get("follower_finale", null)
	if fin == null:
		return
	_replace_follower(_v(fin["spawn"]), "follower_finale:0")
	var n: Node3D = _follower
	n.set_meta("zonda_no_lure", true)        # the bell cannot hold it in the finale
	_spawned_cents["follower"] = true
	_real_spawned["follower_finale"] = true
	_burrow_parked = false
	if _replaying:
		# a reload after the idol was taken: it sleeps in its tunnel until the team comes back near
		_territorial.append([n, 1e9, -1e9, n.position])
	print("[Underdark] the follower joined the finale at %s" % str(n.position))


func _replace_follower(spot: Vector3, cid: String = "follower:0") -> void:
	# a fresh Follower at spot. It keeps the old one's slot in Game.centipedes, so no other
	# centipede shifts in the host's stream when it is swapped.
	var idx := -1
	if is_instance_valid(_follower):
		idx = Game.centipedes.find(_follower)
		Game.centipedes.erase(_follower)
		_follower.queue_free()
	var ps: PackedScene = load(CENTIPEDE)
	var n: Node3D = ps.instantiate()
	n.position = spot
	n.set_meta("zonda_cid", cid)
	if _idol_taken:
		n.set_meta("zonda_no_lure", true)
	add_child(n)
	_follower = n
	_follow_best = 1e9
	_follow_stall = 0.0
	if idx >= 0:
		_keep_slot(n, idx)


func _keep_slot(n: Node3D, idx: int) -> void:
	# the centipede registers itself a frame after it enters the tree; move it into the slot then
	for _i in 12:
		await get_tree().process_frame
		if not is_instance_valid(n) or not is_inside_tree():
			return
		var at: int = Game.centipedes.find(n)
		if at >= 0:
			if at != idx:
				Game.centipedes.remove_at(at)
				Game.centipedes.insert(mini(idx, Game.centipedes.size()), n)
			return


func _in_burrows(p: Vector3, tubes_only: bool) -> bool:
	# inside the Burrows: any biome 9 zone, or (tubes_only) close to the spine of a tube, not the
	# two chambers at either end
	for z in _burrow_zones:
		var nm := str(z.get("name", ""))
		if tubes_only and (nm == "Burrow Mouth" or nm == "Breathing Room"):
			continue
		var c := _v(z["center"])
		var r: float = 7.0 if tubes_only else float(z["radius"])
		var lo: float = float(z["floor"]) - (4.0 if tubes_only else 8.0)
		var hi: float = float(z["top"]) + (6.0 if tubes_only else 8.0)
		if p.y > lo and p.y < hi and Vector2(p.x - c.x, p.z - c.z).length() < r:
			return true
	return false


func _update_creature_centres() -> void:
	# host: where the awake creatures are, so the rock around them stays solid even past the
	# players' 150 m collision range (their feet, paths and rays need real rock)
	_creature_centres.clear()
	for cent in Game.centipedes:
		if is_instance_valid(cent) and cent.is_inside_tree() and not bool(cent.get("coop_puppet")) and cent.process_mode != Node.PROCESS_MODE_DISABLED:
			_creature_centres.append((cent as Node3D).global_position)
	for s in _stalkers:
		if is_instance_valid(s.body):
			_creature_centres.append(s.body.global_position)


func _update_reload_test(delta: float) -> void:
	# developer test (maps/underdark/reload.flag), three map loads:
	#   phase 0: take checkpoint 5 and the kiln gate, then die
	#   phase 1 and 2: log the team checkpoint, the stored events, where we stand and the gate,
	#   then die again (phase 1) or finish and remove the flag (phase 2)
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree() or _rl_done:
		return
	_rl_t += delta
	var phase := 0
	if FileAccess.file_exists(RELOAD_MARK):
		phase = int(FileAccess.get_file_as_string(RELOAD_MARK).strip_edges())
	if phase == 0 and _rl_t > 6.0:
		_rl_done = true
		var cp: Dictionary = {}
		for k in L["checkpoints"]:
			if int(k["id"]) == 5:
				cp = k
		c.teleport_to_location(_v(cp["pos"]) + Vector3(0, 1.0, 0))
		await get_tree().create_timer(1.5).timeout
		CoopSync.map_checkpoint(5, scene_file_path)
		CoopSync.map_event("gate_kilns", {})
		print("[RELOAD] phase 0: checkpoint now %d, events %s" % [CoopSync.map_checkpoint_for(scene_file_path), str(CoopSync.map_events_for(scene_file_path).keys())])
		var f := FileAccess.open(RELOAD_MARK, FileAccess.WRITE)
		f.store_string("1")
		f.close()
		await get_tree().create_timer(2.0).timeout
		c.health = 0.0
		c.took_lethal_damage()
	elif phase >= 1 and _rl_t > 7.0:
		_rl_done = true
		var cp_pos := Vector3.ZERO
		for k in L["checkpoints"]:
			if int(k["id"]) == CoopSync.map_checkpoint_for(scene_file_path):
				cp_pos = _v(k["pos"])
		var gate_open := false
		if _gates.has("gate_kilns"):
			gate_open = bool(_gates["gate_kilns"].is_open)
		print("[RELOAD] phase %d after death: checkpoint %d, events %s, standing %.0f m from that checkpoint, kiln gate open=%s" % [
			phase, CoopSync.map_checkpoint_for(scene_file_path), str(CoopSync.map_events_for(scene_file_path).keys()),
			c.global_position.distance_to(cp_pos), str(gate_open)])
		var img := get_viewport().get_texture().get_image()
		if img:
			if img.get_width() > 960:
				img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
			img.save_png("user://reload_test_%d.png" % phase)
		if phase == 1:
			var f := FileAccess.open(RELOAD_MARK, FileAccess.WRITE)
			f.store_string("2")
			f.close()
			await get_tree().create_timer(1.0).timeout
			c.health = 0.0
			c.took_lethal_damage()
		else:
			DirAccess.remove_absolute(RELOAD_MARK)
			DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/maps/underdark/reload.flag")
			print("[RELOAD] done")


func _update_debug_finale(delta: float) -> void:
	# developer test (maps/underdark/finale.flag): stands at the altar, takes the idol, and
	# reports where the Follower comes from and how fast it closes.
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	_dbg_fin_t += delta
	if not _dbg_fin_started:
		if _dbg_fin_t > 0.0:
			_dbg_fin_started = true
			c.prevent_player_death = true
			c.health = c.healthMax
			c.velocity = Vector3.ZERO
			c.teleport_to_location(_altar_pos + Vector3(-9.0, 1.6, 0.0))
			c.PlayerCamera.set_camera_rotation(Vector3(0.0, deg_to_rad(-90.0), 0.0))
			CoopSync.map_event("idol", {"by": CoopSync.local_name, "id": CoopSync.my_id()})
		return
	if _dbg_fin_t > 34.0 and _dbg_fin_t - delta <= 34.0:
		for f in L.get("finish", []):
			c.teleport_to_location(_v(f["pos"]) + Vector3(0, 1.0, 0))
			print("[Underdark] finale test: at the exit")
			break
	if int(_dbg_fin_t * 2.0) != int((_dbg_fin_t - delta) * 2.0) and int(_dbg_fin_t) % 2 == 0:
		var fd := -1.0
		var st := "none"
		if is_instance_valid(_follower):
			fd = _follower.global_position.distance_to(c.global_position)
			st = str(_follower._current_state.get_script().get_global_name()) if _follower._current_state else "?"
		print("[Underdark] finale t=%.0f follower_dist=%.0f state=%s player=%s" % [_dbg_fin_t, fd, st, str(c.global_position)])
		if is_instance_valid(_brood):
			var bl: Array = _brood.threat_positions()
			var bd := 1e9
			for q in bl:
				bd = minf(bd, (q as Vector3).distance_to(c.global_position))
			print("[Underdark] finale t=%.0f brood hatched=%s alive=%d nearest=%.0f m" % [_dbg_fin_t, str(_brood.is_hatched()), bl.size(), bd if bl.size() > 0 else -1.0])
	for at in [8.0, 14.0, 22.0, 32.0, 38.0]:
		if _dbg_fin_t >= at and _dbg_fin_shots < int(at) and (_dbg_fin_t - delta) < at:
			_dbg_fin_shots = int(at)
			var img := get_viewport().get_texture().get_image()
			if img:
				if img.get_width() > 960:
					img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
				img.save_png("user://underdark_finale_%02d.png" % int(at))
	if _dbg_fin_t > 40.0:
		_debug_finale = false
		c.prevent_player_death = false          # a test never leaves the player invincible
		print("[Underdark] finale test done")


func _debug_shot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img:
		if img.get_width() > 960:
			img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
		img.save_png(path)


func _debug_park(c, pos: Vector3) -> void:
	# a test teleport: rope off, standing still, full health
	c.set_climber_state(c.defaultClimberState)
	c.velocity = Vector3.ZERO
	c.health = c.healthMax
	c.teleport_to_location(pos)


func _update_spider_test(delta: float) -> void:
	# developer test (maps/underdark/spider.flag, deleted once read): after 5 s the player stands
	# under the first wall spider and every spider's click / drop / bite is logged ([SPIDER]); 20 s
	# later the player stands on the waking husk's trigger and its wake is logged ([HUSK]).
	# Invincible during the test only.
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	_sp_t += delta
	const NAMES := ["wait", "click", "drop", "hang (bite window)", "climb", "rest"]
	for sp in _spiders:
		if not is_instance_valid(sp):
			continue
		var sid := str(sp.get("id"))
		var sst := int(sp.get("st"))
		if int(_sp_states.get(sid, 0)) != sst:
			_sp_states[sid] = sst
			var ap: Vector3 = sp.get("anchor")
			print("[SPIDER] %s %s  t=%.1f s, %.1f m from you" % [sid, NAMES[clampi(sst, 0, NAMES.size() - 1)], _sp_t, ap.distance_to(c.global_position)])
			if sst == 3:
				_debug_shot("user://underdark_spider.png")
	if is_instance_valid(_husk):
		var ph := int(_husk.get("phase"))
		if ph != _sp_husk_phase:
			if _sp_husk_phase >= 0:
				print("[HUSK] phase %d (%s)  t=%.1f s" % [ph, ["asleep", "shivering", "awake"][clampi(ph, 0, 2)], _sp_t])
			_sp_husk_phase = ph
	if _sp_phase == 0 and _sp_t > 5.0:
		_sp_phase = 1
		var sps: Array = L.get("spiders", [])
		if sps.is_empty():
			print("[SPIDER] layout.json has no spiders")
			return
		c.prevent_player_death = true
		var e: Dictionary = sps[0]
		_debug_park(c, _v(e["floor"]) + Vector3(0, 1.0, 0))
		print("[SPIDER] test: standing under %s (anchor %s, floor %s)" % [str(e.get("id", "?")), str(e["anchor"]), str(e["floor"])])
	elif _sp_phase == 1 and _sp_t > 25.0:
		_sp_phase = 2
		var wh = L.get("waking_husk", null)
		if not (wh is Dictionary):
			print("[HUSK] layout.json has no waking_husk")
			return
		c.prevent_player_death = true
		_debug_park(c, _v(wh["trigger"]) + Vector3(0, 1.0, 0))
		print("[HUSK] test: standing on the trigger %s (head %s, %d husk props)" % [str(wh["trigger"]), str(wh["head"]), _husk_props.size()])
	elif _sp_phase == 2 and _sp_t > 45.0:
		_sp_phase = 3
		_debug_spider = false
		c.prevent_player_death = false          # a test never leaves the player invincible
		print("[SPIDER] test done")


func _update_oil_test(delta: float) -> void:
	# developer test (maps/underdark/oil.flag, deleted once read): logs the oil every 5 s, drains a
	# full tank in 8 s, sits dark for 4 s, then stands on the nearest flask and logs the pickup.
	var c = Game.climber
	var ln = CoopSync.lantern
	if not is_instance_valid(c) or not c.is_inside_tree() or not is_instance_valid(ln):
		return
	if not ("oil" in ln):
		print("[OIL] lantern.gd has no oil (K10 missing): test stopped")
		_debug_oil = false
		return
	_oil_t += delta
	_oil_phase_t += delta
	var oil := float(ln.get("oil"))
	_oil_log_t -= delta
	if _oil_log_t <= 0.0:
		_oil_log_t = 5.0
		print("[OIL] t=%.0f oil=%.3f enabled=%s lantern wanted=%s fresh_run=%s flasks=%d" % [_oil_t, oil, str(ln.get("oil_enabled")), str(ln.wanted()), str(_oil_fresh), _flasks.size()])
	if _oil_phase == 0:
		if _oil_t > 3.0:
			_oil_phase = 1
			_oil_phase_t = 0.0
			c.prevent_player_death = true
			print("[OIL] fast drain: a full tank in 8 s")
	elif _oil_phase == 1:
		ln.set("oil", maxf(0.0, oil - delta / 8.0))
		if float(ln.get("oil")) <= 0.0:
			_oil_phase = 2
			_oil_phase_t = 0.0
			print("[OIL] dry at t=%.1f: lantern wanted=%s (it should be out, L says Out of oil)" % [_oil_t, str(ln.wanted())])
	elif _oil_phase == 2:
		if _oil_phase_t < 4.0:
			return
		_oil_phase = 3
		_oil_phase_t = 0.0
		var best: Node3D = null
		var bd := 1e9
		for f in _flasks:
			if not is_instance_valid(f) or f.is_taken():
				continue
			var d: float = (f as Node3D).global_position.distance_to(c.global_position)
			if d < bd:
				bd = d
				best = f
		if best == null:
			print("[OIL] no flask left to test the pickup")
			_oil_phase = 4
			_oil_phase_t = 0.0
			return
		_oil_target = best
		_oil_before = float(ln.get("oil"))
		# the flask never hands oil to an invincible (touring) knight, so the guard comes off
		# here; the flasks stand on checked floor and the park is a 1 m step down
		c.prevent_player_death = false
		_debug_park(c, best.global_position + Vector3(0, 1.0, 0))
		print("[OIL] standing on flask %s (%.0f m away) at %s" % [str(best.get("id")), bd, str(best.global_position)])
	elif _oil_phase == 3:
		var got: bool = is_instance_valid(_oil_target) and _oil_target.is_taken()
		if got or oil > _oil_before + 0.01:
			print("[OIL] pickup: %s taken=%s, oil %.3f -> %.3f" % [str(_oil_target.get("id")) if is_instance_valid(_oil_target) else "?", str(got), _oil_before, oil])
			_oil_phase = 4
			_oil_phase_t = 0.0
		elif _oil_phase_t > 8.0:
			print("[OIL] NO pickup after 8 s on the flask (oil %.3f)" % oil)
			_oil_phase = 4
			_oil_phase_t = 0.0
	elif _oil_phase == 4 and _oil_phase_t > 3.0:
		_debug_oil = false
		c.prevent_player_death = false          # a test never leaves the player invincible
		print("[OIL] test done")


func _follower_spot(players: Array):
	var top_y := -1e9
	for p in players:
		top_y = maxf(top_y, (p as Node3D).global_position.y)
	var best = null
	var best_score := 1e9
	var mouth := Vector3(0, 1e9, 0)
	for z in _burrow_zones:
		if str(z.get("name", "")) == "Burrow Mouth":
			mouth = _v(z["center"])
	for st in L.get("stations", []):
		var pos := _v(st["pos"])
		if pos.y < top_y + 25.0:
			continue
		if pos.distance_to(mouth) < 60.0:
			continue                          # never put it back at the Burrows' door
		var dmin := 1e9
		for p in players:
			dmin = minf(dmin, (p as Node3D).global_position.distance_to(pos))
		if dmin < 70.0 or dmin > 150.0:
			continue
		var score := absf(dmin - 100.0)
		if score < best_score:
			best_score = score
			best = pos + Vector3(0, 3.0, 0)
	return best


func _place_ambience() -> void:
	for a in L.get("ambience", []):
		var amb := Ambience.new()
		amb.setup(a)
		add_child(amb)


func _place_dying_lights() -> void:
	for d in L.get("dying_lights", []):
		var dl := DyingLights.new()
		dl.setup(d)
		add_child(dl)
		_dying[str(d["id"])] = dl


# ------------------------------------------------------------------ events (synced)

func coop_map_event(key: String, data: Dictionary, replay: bool = false) -> void:
	# replay = true when a stored event is re-applied (death reload, late join): the resulting
	# state is applied, but no banners, stings, blackouts, door slides or sounds
	# Every stored event applies once per map load. One that arrives live in the map's first
	# frame is also in the stored events _reapply_events replays a frame later: the second apply
	# changes nothing and plays nothing. The repeatable kinds (never stored) are not gated, and
	# cent_ has its own guard (_spawned_cents) because a reload may deliberately skip it.
	var once := not (key.begins_with("crumble_") or key.begins_with("drop_") or key.begins_with("bell_") or key.begins_with("stalkbite_") or key.begins_with("cbite_") or key.begins_with("cent_"))
	if once and _applied.has(key):
		return
	if key.begins_with("cent_") and replay and _cent_below_reload(str(data.get("id", key.substr(5)))):
		return                             # it wakes again when the team passes its trigger
	if once:
		_applied[key] = true
	var was := _replaying
	_replaying = replay
	_apply_event(key, data, replay)
	_replaying = was


func _apply_event(key: String, data: Dictionary, replay: bool) -> void:
	if key.begins_with("cent_"):
		_release_centipedes(str(data.get("id", key.substr(5))), replay)
	elif key.begins_with("crumble_"):
		var id := key.substr(8)
		if _crumbles.has(id):
			_crumbles[id].remote_collapse()
	elif key.begins_with("drop_"):
		var id := key.substr(5)
		if _droppers.has(id):
			_droppers[id].remote_drop()
	elif key.begins_with("kiln_"):
		var idx := int(key.substr(5))
		if _kilns.has(idx):
			_kilns[idx].light_up(replay)
		_check_kiln_gate()
	elif key.begins_with("frag_"):
		var id := key.substr(5)
		var by := str(data.get("by", ""))
		if _fragments.has(id):
			_fragments[id].collect(by, replay)
		_frag_count = 0
		for fid in _fragments.keys():
			if _fragments[fid].collected:
				_frag_count += 1
		if not replay:
			if by != "":
				CoopSync.show_banner("%s found an idol fragment  (%d / 3)" % [by, _frag_count], 4.0)
			else:
				CoopSync.show_banner("Idol fragment %d / 3" % _frag_count, 4.0)
		_check_idol_gate()
	elif key.begins_with("gate_"):
		if _gates.has(key):
			# a stored gate event only exists for a gate that latched open; keep it latched after
			# a reload too, or the plate logic would shut the plate door again
			_gates[key].latched = true
			_gates[key].open(replay)
	elif key.begins_with("dying_"):
		var id := key.substr(6)
		if _dying.has(id):
			_dying[id].begin(replay)
	elif key.begins_with("stalkbite_"):
		var sid := key.substr(10)
		for s in _stalkers:
			if s.id == sid:
				if not CoopSync.map_is_authority():
					s.body.position = s.rp_pos   # the bite comes from where it really is, never from afar
					s.bite_sounds()          # the host already heard it when it bit
				if int(data.get("who", -1)) == CoopSync.my_id():
					s.bite_local()
	elif key.begins_with("cbite_"):
		# a v4.9 creature bit someone (sent by the authority, never stored)
		var bid := key.substr(6)
		var src = _bite_source(bid)
		if src != null:
			if not CoopSync.map_is_authority():
				src.play_bite(bid)           # the host already showed it when it bit
			var w = data.get("who", -1)
			if w != null and CoopSync.my_id() != 0 and int(w) == CoopSync.my_id():
				if _debug_spider and Creatures.is_spider_id(bid):
					print("[SPIDER] bitten by %s" % bid)
				Creatures.bite_local(src.bite_origin(bid), float(data.get("dmg", 8.0)), Creatures.is_spider_id(bid))
	elif key.begins_with("husk_"):
		_husk_event(data, replay)
	elif key.begins_with("pfdrop_"):
		var pid := key.substr(7)
		if _platforms.has(pid):
			_platforms[pid].drop_now(replay)
	elif key.begins_with("bell_"):
		var bid := key.substr(5)
		if _bells.has(bid):
			_bells[bid].toll()
	elif key == "idol":
		if _is_me(data) and not _idol_taken:
			_idol_mine = true             # this player carries it out (shown in their hand)
		_finale(str(data.get("by", "")), replay)
	elif key.begins_with("barsink_"):
		var bi := int(key.substr(8))
		for b in _bars:
			if b.idx == bi:
				b.sink_now(replay)
	elif key == "clock":
		# the team run clock: set once by the authority when the map first starts
		_clock_t0 = float(data.get("t0", 0.0))
	elif key == "finish":
		if not replay:                    # a reload never re-runs the ending
			_finish(str(data.get("by", "")), data)


func _reapply_events() -> void:
	var ev := CoopSync.map_events_for(scene_file_path)
	for k in ev.keys():
		var d = ev[k]
		coop_map_event(str(k), d if typeof(d) == TYPE_DICTIONARY else {}, true)


func coop_map_stream(d: Dictionary, _ts: int) -> void:
	# host -> guests: stalker positions and plate state
	if d.has("st"):
		var arr: Array = d["st"]
		for i in mini(arr.size(), _stalkers.size()):
			_stalkers[i].remote_state(arr[i])
	if d.has("pl"):
		var pl: Array = d["pl"]
		for i in mini(pl.size(), _plates.size()):
			_plates[i].remote_pressed(bool(pl[i]))
	if d.has("cr") and not CoopSync.map_is_authority():
		# the host's cry counters: the puppet mirroring that id plays the cry (see _stream_cries)
		var by_cid = CoopSync.get("_puppet_by_cid")
		if by_cid is Dictionary:
			for e in d["cr"]:
				if not (e is Array) or (e as Array).size() < 3:
					continue
				var pup = (by_cid as Dictionary).get(str(e[0]))
				if is_instance_valid(pup) and pup.has_method("coop_note_cries"):
					pup.coop_note_cries(str(e[0]), int(e[1]), int(e[2]))
	if d.has("cx") and not CoopSync.map_is_authority():
		# v4.9 creatures (see _stream_creatures)
		var cx = d["cx"]
		if cx is Dictionary:
			if cx.has("b") and cx["b"] is Array and is_instance_valid(_brood):
				_brood.remote_state(cx["b"])
			if cx.has("sp") and cx["sp"] is Array:
				var spa: Array = cx["sp"]
				for i in mini(spa.size(), _spiders.size()):
					if spa[i] is Array and is_instance_valid(_spiders[i]):
						_spiders[i].remote_state(spa[i])
			if cx.has("wh") and cx["wh"] is Array and is_instance_valid(_husk):
				_husk.remote_state(cx["wh"])
	if d.has("open"):
		for gid in d["open"]:
			if _gates.has(str(gid)) and not _gates[str(gid)].is_open:
				_gates[str(gid)].open()
	if d.has("closed"):
		for gid in d["closed"]:
			if _gates.has(str(gid)) and _gates[str(gid)].is_open and not _gates[str(gid)].latched:
				_gates[str(gid)].close()


func _check_kiln_gate() -> void:
	var lit := 0
	for k in _kilns.values():
		if k.lit:
			lit += 1
	if lit >= 4 and _gates.has("gate_kilns") and not _gates["gate_kilns"].is_open:
		_gates["gate_kilns"].latched = true
		if _replaying:
			_gates["gate_kilns"].open(true)       # the stored gate event exists already
			return
		CoopSync.map_event("gate_kilns", {})
		CoopSync.show_banner("The kilns roar. Stone grinds somewhere ahead.", 5.0)


func _check_idol_gate() -> void:
	if _frag_count >= 3 and _gates.has("gate_idol") and not _gates["gate_idol"].is_open:
		_gates["gate_idol"].latched = true
		if _replaying:
			_gates["gate_idol"].open(true)
			return
		CoopSync.map_event("gate_idol", {})
		CoopSync.show_banner("The idol is whole. The Foundry door opens.", 5.0)


func _update_plates(delta: float) -> void:
	# Host decides, with one test for every player, and guests only show the plate state the host
	# streams ("pl"), so a plate never flickers or clanks twice on a guest's screen.
	# Plates needed = living players; solo gets a 16 s window.
	if _plates.is_empty() or not _gates.has("gate_plates"):
		return
	if not CoopSync.map_is_authority():
		return
	var gate: Gate = _gates["gate_plates"]
	if gate.latched:
		return
	var states: Array = []
	var pressed := 0
	for p in _plates:
		var on: bool = p.host_check(delta)
		states.append(on)
		if on:
			pressed += 1
	var need: int = maxi(1, CoopSync.alive_player_count())
	var want_open: bool = pressed >= need
	if need == 1 and pressed >= 1:
		gate.solo_timer = 16.0
	if gate.solo_timer > 0.0:
		gate.solo_timer -= delta
		want_open = true
	if want_open and not gate.is_open:
		gate.open()
		if need > 1:
			gate.latched = true
			CoopSync.map_event("gate_plates", {})
		else:
			CoopSync.show_banner("The door opens... for a moment. Run.", 3.0)
	elif not want_open and gate.is_open and not gate.latched:
		gate.close()
	_stream_accum += delta
	if _stream_accum > 0.1:
		_stream_accum = 0.0
		var open_ids: Array = []
		var closed_ids: Array = []
		for gid in _gates.keys():
			if _gates[gid].is_open:
				open_ids.append(gid)
			elif gid == "gate_plates":
				closed_ids.append(gid)
		CoopSync.map_stream({"pl": states, "open": open_ids, "closed": closed_ids})


var _stream_accum := 0.0


func _stream_stalkers(delta: float) -> void:
	# The stalkers have their own 10 Hz stream on the authority, so nothing about the plates
	# (latched door, no plates) can freeze them on the guests' screens.
	if _stalkers.is_empty() or not CoopSync.map_is_authority() or not CoopSync.in_session():
		return
	_stalk_accum += delta
	if _stalk_accum < 0.1:
		return
	_stalk_accum = 0.0
	var st: Array = []
	for s in _stalkers:
		st.append(s.state_packet())
	CoopSync.map_stream({"st": st})


var _cry_accum := 0.0


func _stream_cries(delta: float) -> void:
	# host -> guests, 4 Hz: every map centipede's hunting-cry and roar counters by stable id, so a
	# guest's puppet cries where it really is (review #41). The centipede stream itself does not
	# carry them; counters make a lost packet harmless.
	if not CoopSync.map_is_authority() or not CoopSync.in_session():
		return
	_cry_accum += delta
	if _cry_accum < 0.25:
		return
	_cry_accum = 0.0
	var cr: Array = []
	for cent in Game.centipedes:
		# every map centipede, 0 counts included: a guest has to have seen the 0 before the first
		# cry, or that first cry only seeds its counter and stays silent
		if not is_instance_valid(cent) or not cent.has_meta("zonda_cid"):
			continue
		cr.append([str(cent.get_meta("zonda_cid")), int(cent.get_meta("zonda_cry", 0)), int(cent.get_meta("zonda_roar", 0))])
	if not cr.is_empty():
		CoopSync.map_stream({"cr": cr})


func _on_finish(body: Node3D) -> void:
	if body != Game.climber or _finished:
		return
	if not _idol_taken:
		CoopSync.show_banner("The way out is sealed. The idol on the altar is the key.", 4.0)
	# with the idol taken, _update_finish decides: the whole living team has to be at the exit


func _at_finish(p: Vector3) -> bool:
	for f in L.get("finish", []):
		if p.distance_to(_v(f["pos"])) < float(f["r"]) + 1.0:
			return true
	return false


func _update_finish(delta: float) -> void:
	# The run ends when every ALIVE player (local and living teammates) stands in the exit.
	# Dead or spectating players never block it. Solo: you alone, exactly as before.
	if not _idol_taken or _finished or _finish_sent:
		return
	_fin_tick -= delta
	if _fin_tick > 0.0:
		return
	_fin_tick = 0.25
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree() or c.get("coop_spectating"):
		return
	if not _at_finish(c.global_position):
		_fin_wait_t = 0.0
		return
	var alive: Array = CoopSync.alive_player_nodes()
	var inside := 0
	for p in alive:
		if is_instance_valid(p) and _at_finish((p as Node3D).global_position):
			inside += 1
	if inside >= alive.size():
		_finish_sent = true
		CoopSync.map_event("finish", {"by": CoopSync.local_name, "secs": _run_secs()})
		return
	_fin_wait_t -= 0.25
	if _fin_wait_t <= 0.0:
		_fin_wait_t = 1.0
		CoopSync.show_banner("Waiting at the exit: %d/%d" % [inside, alive.size()], 1.4)


func _run_secs() -> int:
	# the team clock (same start for everyone, survives death reloads); local time if it never came
	if _clock_t0 > 0.0:
		return maxi(0, int(Time.get_unix_time_from_system() - _clock_t0))
	return (Time.get_ticks_msec() - _run_start_ms) / 1000


func _fmt_time(secs: int) -> String:
	if secs >= 3600:
		return "%d:%02d:%02d" % [secs / 3600, (secs / 60) % 60, secs % 60]
	return "%02d:%02d" % [secs / 60, secs % 60]


func _ensure_clock() -> void:
	# the authority starts the team clock once, as a stored map event, the first time the map runs
	if _clock_t0 > 0.0 or _clock_asked or not CoopSync.map_is_authority():
		return
	if CoopSync.current_scene_path() != scene_file_path:
		return                        # the autoload has not caught up with this scene yet
	_clock_asked = true
	CoopSync.map_event("clock", {"t0": Time.get_unix_time_from_system()})


func _note_death() -> void:
	# counts this player's own deaths for the end card (kept in the run's map state)
	var c = Game.climber
	if not is_instance_valid(c):
		return
	var dead: bool = c.lethalDamageHandled == true
	if dead and not _death_noted:
		_death_noted = true
		var ms := _run_state()
		if not ms.is_empty():
			ms["deaths"] = int(ms.get("deaths", 0)) + 1
	elif not dead:
		_death_noted = false


func _finish(by: String, data: Dictionary = {}) -> void:
	if _finished:
		return
	_finished = true
	if is_instance_valid(_brood):
		_brood.clear()                   # out in the light the brood is done
	Game.audio.play_player_healed()
	var secs: int = int(data.get("secs", _run_secs()))
	var carrier: String = _idol_by if _idol_by != "" else by
	CoopSync.show_banner("%s carried the idol out. THE UNDERDARK is cleared in %s." % [carrier, _fmt_time(secs)], 10.0)
	_show_end_card(secs, carrier)
	await get_tree().create_timer(10.0).timeout
	if not is_inside_tree():
		return
	# the run is over: the idol leaves your hand with the end card
	_idol_mine = false
	CoopSync.idol_carrier = false
	if is_instance_valid(_held_idol):
		_held_idol.queue_free()
	if is_instance_valid(_end_card):
		_end_card.queue_free()
	if CoopSync.in_session() and not CoopSync.is_host:
		return
	SceneLoader.load_scene(func():
		Game.on_new_loaded_level()
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn"))


func _show_end_card(secs: int, carrier: String) -> void:
	# a centred card for the last 10 s of the run: team time, who carried the idol, what was found
	if is_instance_valid(_end_card):
		_end_card.queue_free()
	var ms := _run_state()
	var relics_run: int = maxi(0, CoopSync.cosmetics - int(ms.get("relics0", CoopSync.cosmetics)))
	var deaths: int = int(ms.get("deaths", 0))
	_end_card = CanvasLayer.new()
	_end_card.layer = 70
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_end_card.add_child(cc)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.02, 0.02, 0.025, 0.86)
	sb.border_color = Color(0.91, 0.82, 0.54, 0.9)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(12.0)
	panel.add_theme_stylebox_override("panel", sb)
	cc.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	panel.add_child(box)
	var rows: Array = [
		["THE UNDERDARK IS CLEARED", 16, Color(0.91, 0.82, 0.54)],
		["Team time   %s" % _fmt_time(secs), 12, Color(0.92, 0.88, 0.8)],
		["Idol carried by   %s" % (carrier if carrier != "" else "?"), 11, Color(0.92, 0.88, 0.8)],
		["Idol fragments   %d / 3" % _frag_count, 11, Color(0.92, 0.88, 0.8)],
		["Relics found this run   %d" % relics_run, 11, Color(0.92, 0.88, 0.8)],
		["Your deaths   %d" % deaths, 11, Color(0.92, 0.88, 0.8)],
	]
	for r in rows:
		var lb := Label.new()
		lb.text = str(r[0])
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var ls := LabelSettings.new()
		ls.font_size = int(r[1])
		ls.font_color = r[2]
		ls.outline_size = 3
		ls.outline_color = Color.BLACK
		lb.label_settings = ls
		box.add_child(lb)
	add_child(_end_card)


# ------------------------------------------------------------------ the idol in your hand

func _update_held_idol(delta: float) -> void:
	if not _idol_mine or _held_failed:
		return
	if not CoopSync.idol_carrier:
		CoopSync.idol_carrier = true          # re-assert after the autoload's scene-change reset
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var cam = c.get("Camera")
	if not (cam is Node3D):
		return
	if not is_instance_valid(_held_idol) or _held_idol.get_parent() != cam:
		if is_instance_valid(_held_idol):
			_held_idol.queue_free()
		_held_idol = _make_held_idol()
		if _held_idol == null:
			_held_failed = true
			return
		cam.add_child(_held_idol)
	_held_idol.visible = not c.get("coop_spectating")
	_held_t += delta
	# lower left of the view, the mirror of the lantern, with a slow sway
	_held_idol.position = Vector3(-0.5, -0.36 + sin(_held_t * 5.2) * 0.005, -0.65)
	_held_idol.rotation = Vector3(0.0, 0.5 + sin(_held_t * 0.9) * 0.08, sin(_held_t * 2.1) * 0.04)


func _make_held_idol() -> Node3D:
	var ps: PackedScene = load("res://Art/Praxthos.glb")
	if ps == null:
		return null
	var model: Node3D = ps.instantiate()
	for co in model.find_children("*", "CollisionObject3D", true, false):
		co.queue_free()
	_dim_materials(model, 0.5)
	# Praxthos uses the game's ghost material, which is invisible closer than 8 m and fades near
	# other geometry: the copy in your hand gets its own material with both fades off
	for mi in model.find_children("*", "MeshInstance3D", true, false):
		var m3 := mi as MeshInstance3D
		if m3.mesh == null:
			continue
		for si in m3.mesh.get_surface_count():
			var src: Material = m3.get_active_material(si)
			if src is BaseMaterial3D:
				var d: BaseMaterial3D = src.duplicate()
				d.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_DISABLED
				d.proximity_fade_enabled = false
				m3.set_surface_override_material(si, d)
	for gi in model.find_children("*", "GeometryInstance3D", true, false):
		(gi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		(gi as GeometryInstance3D).layers = HELD_LAYER
	# small in the hand whatever the model's real size: about 22 cm tall, centred on the grip
	var ab := _merged_aabb(model)
	var h: float = maxf(ab.size.y, maxf(ab.size.x, ab.size.z))
	var k: float = 0.22 / h if h > 0.001 else 0.2
	model.scale = Vector3.ONE * k
	model.position = -ab.get_center() * k
	var holder := Node3D.new()
	holder.name = "ZondaHeldIdol"
	holder.add_child(model)
	return holder


# ------------------------------------------------------------------ per frame

func _physics_process(_delta: float) -> void:
	# On Normal the game caps fall damage at 62 HP, so jumping down was always the fast way.
	# Here LANDING a fall of 40 m or more (38 m/s) kills, and even a one-balcony jump costs a
	# third of your health. The rope itself is untouched: a catch forgives the fall.
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree() or c.get("coop_spectating"):
		_fall_speed = 0.0
		return
	if c.is_on_floor():
		if _fall_speed > _lethal_fall and c.health > 0.0 and not c.lethalDamageHandled and not c.prevent_player_death:
			CoopSync.show_banner("The fall killed you. In the Underdark, trust the rope.", 4.0)
			c.take_damage(1000.0)
		elif _fall_speed > _bruise_from and c.health > 0.0 and not c.lethalDamageHandled and not c.prevent_player_death:
			# take_damage halves what it is given
			c.take_damage((_fall_speed - _bruise_from) * _bruise_per * 2.0)
			if not _bruise_told:
				_bruise_told = true
				CoopSync.show_banner("That landing cost you. Let the rope out instead of jumping.", 4.0)
		_fall_speed = 0.0
	elif c.activeClimberState is ClimberState_Attached:
		# The rope is left exactly as the game made it: a catch forgives the fall, at any speed.
		_fall_speed = minf(_fall_speed, maxf(0.0, -c.velocity.y))
	else:
		_fall_speed = maxf(_fall_speed * 0.98, -c.velocity.y)


func _process(delta: float) -> void:
	_clock += delta
	_mat_lava.set_shader_parameter("t", _clock)
	if _idol_taken and _nest_lights.size() > 0:
		var k := 0.55 + 0.45 * absf(sin(_clock * 2.6))
		for e in _nest_lights:
			if is_instance_valid(e[0]):
				e[0].light_energy = e[1] * 0.7 * k
	_update_lod(delta)
	_update_light_budget(delta)
	_update_environment(delta)
	_update_plates(delta)
	_stream_stalkers(delta)
	_stream_cries(delta)
	_stream_creatures(delta)
	_update_soundscape(delta)
	_update_haze(delta)
	_update_centipedes(delta)
	_ensure_clock()
	_update_finish(delta)
	_update_held_idol(delta)
	_note_death()
	_pix_t -= delta
	if _pix_t <= 0.0:
		_pix_t = 1.0
		_apply_pixel_filter()          # the settings menu can change it mid-run
		_sync_ultra()                  # F4, even if gfx.gd has no mode_changed signal
	_rope_gold_t -= delta
	if _rope_gold_t <= 0.0:
		_rope_gold_t = 3.0
		_apply_rope_gold()          # the game rebuilds its rope materials now and then
	_update_hud()
	_check_lava()
	if _debug_tour:
		_update_tour(delta)
	if _debug_finale:
		_update_debug_finale(delta)
	if _debug_reload:
		_update_reload_test(delta)
	if _debug_bright:
		_update_bright_test(delta)
	if _debug_spider:
		_update_spider_test(delta)
	if _debug_oil:
		_update_oil_test(delta)


func _update_lod(delta: float) -> void:
	# Only chunks near the local player (or any teammate) are visible / collidable.
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var centers: Array = [c.global_position]
	for rp in CoopSync.remote_players():
		centers.append(rp.global_position)
	var n := _chunks.size()
	if n == 0:
		return
	var per_frame := maxi(8, n / 6)
	for k in per_frame:
		_lod_index = (_lod_index + 1) % n
		var entry: Array = _chunks[_lod_index]
		var mi: MeshInstance3D = entry[0]
		var best := 1e9
		for p in centers:
			best = minf(best, (p - entry[1]).length() - entry[2])
		var want: bool = best < VIEW_RANGE
		if mi.visible != want:
			mi.visible = want
		if mi.get_child_count() == 0:
			continue                       # a sliver chunk with no real triangles has no collision
		var body := mi.get_child(0) as StaticBody3D
		if body == null:
			continue
		var solid: int = 1 if best < SOLID_RANGE else 0
		if solid == 0:
			# host: rock within 60 m of an awake creature stays solid wherever the players are
			for q in _creature_centres:
				if ((q as Vector3) - (entry[1] as Vector3)).length() - float(entry[2]) < 60.0:
					solid = 1
					break
		if body.collision_layer != solid:
			body.collision_layer = solid


func _setup_environment() -> void:
	var we := get_node_or_null("WorldEnvironment")
	if we == null or we.environment == null:
		return
	_env = we.environment.duplicate()
	we.environment = _env
	_env.fog_depth_begin = 14.0
	_env.fog_depth_end = 400.0
	_look_from = _look_of(0)
	_look_to = _look_of(0)
	_apply_look(_look_of(0))
	_make_sky_lights()


func _make_sky_lights() -> void:
	# added late on purpose: the game collects the level's directional lights one frame after
	# load and switches them off 250 m down. These two are not in its list.
	await get_tree().create_timer(1.0).timeout
	_sky = DirectionalLight3D.new()
	_sky.set_meta("zonda_no_shadow", true)
	_sky.shadow_enabled = false
	_sky.light_energy = 0.0
	_sky.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	_sky.rotation = Vector3(deg_to_rad(-62.0), deg_to_rad(35.0), 0.0)
	add_child(_sky)
	_glow = DirectionalLight3D.new()                      # the lava lake, from underneath
	_glow.set_meta("zonda_no_shadow", true)
	_glow.shadow_enabled = false
	_glow.light_energy = 0.0
	_glow.light_color = Color(1.0, 0.34, 0.07)
	_glow.sky_mode = DirectionalLight3D.SKY_MODE_LIGHT_ONLY
	_glow.rotation = Vector3(deg_to_rad(76.0), deg_to_rad(-25.0), 0.0)
	add_child(_glow)


func _in_zone(p: Vector3) -> bool:
	for z in L.get("zones", []):
		var c := _v(z["center"])
		if p.y > float(z["floor"]) - 8.0 and p.y < float(z["top"]) + 8.0:
			if (Vector3(p.x, 0, p.z) - Vector3(c.x, 0, c.z)).length() < float(z["radius"]):
				return true
	return false


func _update_sky_lights(delta: float, p: Vector3) -> void:
	if _sky == null or _glow == null or _look_now.is_empty():
		return
	var inside := _in_zone(p)
	var want: float = 0.0 if inside else float(SKYGLOW[clampi(_cur_biome, 0, SKYGLOW.size() - 1)]) * _bright()
	_sky.light_energy = lerpf(_sky.light_energy, want, minf(1.0, delta * (8.0 if _debug_tour else 0.7)))
	var a: Color = _look_now[2]
	var m := maxf(0.001, maxf(a.r, maxf(a.g, a.b)))
	_sky.light_color = Color(a.r / m, a.g / m, a.b / m).lerp(Color.WHITE, 0.35)
	var lake := float(L["lava"][0]["center"][1]) if L.get("lava", []).size() > 0 else -1e9
	var heat := 0.0 if inside else clampf(1.0 - (p.y - lake) / 430.0, 0.0, 1.0)
	_glow.light_energy = lerpf(_glow.light_energy, 0.42 * heat * heat, minf(1.0, delta * (8.0 if _debug_tour else 0.7)))


func _bright() -> float:
	return float(BRIGHT[clampi(_bright_i, 0, BRIGHT.size() - 1)])


func _load_brightness() -> void:
	var cf := ConfigFile.new()
	if cf.load(BRIGHT_FILE) == OK:
		_particles_on = bool(cf.get_value("look", "particles", true))
		if cf.has_section_key("look", "mode2"):
			_bright_i = clampi(int(cf.get_value("look", "mode2", 0)), 0, BRIGHT.size() - 1)
		else:
			# a setting saved before the two-mode switch (0 LANTERN, 1 DARK, 2 NORMAL, 3 BRIGHT)
			var b := int(cf.get_value("look", "bright", 0))
			_bright_i = 1 if b >= 2 else 0


func _announce_light() -> void:
	CoopSync.lantern.set_default(BRIGHT_LANTERN[clampi(_bright_i, 0, BRIGHT_LANTERN.size() - 1)], true)
	await get_tree().create_timer(2.5).timeout
	if is_inside_tree():
		CoopSync.show_banner("Underdark light: %s   (F5 to change, L toggles the lantern, F6 particles)" % BRIGHT_NAMES[_bright_i], 4.0)


func _apply_material_brightness() -> void:
	var f := float(BRIGHT_ALB[clampi(_bright_i, 0, BRIGHT_ALB.size() - 1)])
	for i in mini(LOOKS.size(), _wall_mat.size()):
		var wl: float = WALL_LIFT[i] * f
		(_wall_mat[i] as StandardMaterial3D).albedo_color = Color(LOOKS[i][0].r * wl, LOOKS[i][0].g * wl, LOOKS[i][0].b * wl)
		var fll: float = FLOOR_LIFT[i] * f
		(_floor_mat[i] as StandardMaterial3D).albedo_color = Color(LOOKS[i][1].r * fll, LOOKS[i][1].g * fll, LOOKS[i][1].b * fll)
	for i in _dress_mat.size():
		var dl: float = 0.62 * (0.7 + 0.3 * f)
		(_dress_mat[i] as StandardMaterial3D).albedo_color = Color(LOOKS[i][0].r * dl, LOOKS[i][0].g * dl, LOOKS[i][0].b * dl)


func _set_bright(i: int, save: bool = true) -> void:
	_bright_i = clampi(i, 0, BRIGHT.size() - 1)
	if save:
		var cf := ConfigFile.new()
		cf.load(BRIGHT_FILE)
		cf.set_value("look", "mode2", _bright_i)      # 0 LANTERN, 1 NORMAL (the old "bright" key used 4 slots)
		cf.save(BRIGHT_FILE)
	_apply_material_brightness()
	if not _look_now.is_empty():
		_apply_look(_look_now)
	CoopSync.lantern.set_default(BRIGHT_LANTERN[_bright_i])    # a new light mode brings its own lantern default
	CoopSync.show_banner("Underdark light: %s   (F5 light, L lantern, F4 graphics, F6 particles)" % BRIGHT_NAMES[_bright_i], 3.0)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F5:
		_set_bright((_bright_i + 1) % BRIGHT.size())
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F6:
		_set_particles(not (_weather != null and _weather.enabled))
		get_viewport().set_input_as_handled()


func _set_particles(on: bool) -> void:
	# F6: the drifting dust, spores, ash and embers, on (in spells that come and go) or off. Per player.
	if _weather == null:
		return
	_weather.set_enabled(on)
	var cf := ConfigFile.new()
	cf.load(BRIGHT_FILE)
	cf.set_value("look", "particles", on)
	cf.save(BRIGHT_FILE)
	CoopSync.show_banner("Particles: %s   (F6)" % ("ON, they come and go" if on else "OFF"), 2.5)
	print("[Underdark] particles ", "on" if on else "off")


func _update_bright_test(delta: float) -> void:
	# developer only (maps/underdark/bright.flag): stand on a balcony, step through every F5
	# mode three seconds apart, and save user://underdark_bright_N.png for each
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	_bt_t += delta
	if _bt_i < 0:
		if _bt_t < 2.5:
			return
		var st: Array = L.get("stations", [])
		if st.is_empty():
			_debug_bright = false
			return
		var k := mini(30, st.size() - 2)
		var p := _v(st[k]["pos"]) + Vector3(0, 1.0, 0)
		var q := _v(st[k + 1]["pos"])
		c.prevent_player_death = true
		c.set_climber_state(c.defaultClimberState)
		c.velocity = Vector3.ZERO
		c.teleport_to_location(p)
		var dir := (q - p).normalized()
		c.PlayerCamera.set_camera_rotation(Vector3(asin(clampf(dir.y, -1.0, 1.0)), atan2(-dir.x, -dir.z), 0.0))
		c.global_rotation = Vector3.ZERO
		_bt_i = 0
		_bt_t = 0.0
		_set_bright(0, false)
		return
	if _bt_t < 3.0:
		return
	var img := get_viewport().get_texture().get_image()
	if img:
		if img.get_width() > 960:
			img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
		img.save_png("user://underdark_bright_%d.png" % _bt_i)
	print("[Underdark] bright test shot %d %s lantern=%s" % [_bt_i, BRIGHT_NAMES[_bt_i], str(CoopSync.lantern.wanted())])
	_bt_i += 1
	_bt_t = 0.0
	if _bt_i >= BRIGHT.size():
		_debug_bright = false
		c.prevent_player_death = false          # a test never leaves the player invincible
		print("[Underdark] bright test done")
		return
	_set_bright(_bt_i, false)


func _apply_look(k: Array) -> void:
	_look_now = k.duplicate()
	var amb: Color = k[2]
	var g := AMB_GAIN * _bright()
	_env.ambient_light_color = Color(amb.r * g, amb.g * g, amb.b * g)
	# the fog keeps each biome's tint (the rock fades into it as before), but the void behind the
	# rock is split off and dimmed by VOID_DIM, so the pit reads darker than the rock: bottomless
	var vd: float = float(k[6]) if k.size() > 6 else 1.0
	_env.fog_light_color = k[3]
	_env.fog_density = k[4]
	_env.fog_sky_affect = vd
	_env.background_color = k[3] * vd
	_env.background_energy_multiplier = k[5]
	_env.volumetric_fog_albedo = k[3].lightened(0.5)
	_env.volumetric_fog_emission = k[3] * 0.4
	_env.volumetric_fog_emission_energy = 0.4


func _biome_at(p: Vector3) -> int:
	for z in L.get("zones", []):
		var c := _v(z["center"])
		if p.y > float(z["floor"]) - 8.0 and p.y < float(z["top"]) + 8.0:
			if (Vector3(p.x, 0, p.z) - Vector3(c.x, 0, c.z)).length() < float(z["radius"]):
				return int(z["biome"])
	for st in L.get("strata", []):
		if p.y <= float(st["top"]) and p.y > float(st["bottom"]):
			return int(st["biome"])
	return 0 if p.y > -40.0 else 8


func _update_environment(delta: float) -> void:
	if _env == null:
		return
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var b := _biome_at(c.global_position)
	if b < 0:
		return
	_update_sky_lights(delta, c.global_position)
	if _weather:
		_weather.follow(c, b)
	if b != _cur_biome:
		_cur_biome = b
		_look_from = _current_look()
		_look_to = _look_of(b)
		_blend = 0.0
		if _music:
			_music.set_biome(b)
	if _blend < 1.0:
		_blend = minf(1.0, _blend + delta * (6.0 if _debug_tour else 0.25))
		var mixed: Array = []
		for i in _look_to.size():
			if _look_to[i] is Color:
				mixed.append((_look_from[i] as Color).lerp(_look_to[i], _blend))
			else:
				mixed.append(lerpf(_look_from[i], _look_to[i], _blend))
		_apply_look(mixed)


func _current_look() -> Array:
	if not _look_now.is_empty():
		return _look_now.duplicate()
	return _look_of(0)


func _look_of(b: int) -> Array:
	# a biome's look plus its void dim as a 7th entry, so the biome blend eases the void too
	var a: Array = LOOKS[b].duplicate()
	a.append(float(VOID_DIM[clampi(b, 0, VOID_DIM.size() - 1)]))
	return a


# ------------------------------------------------------------------ hud

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = 60
	_hud_depth = Label.new()
	_hud_depth.anchor_left = 1.0
	_hud_depth.anchor_right = 1.0
	_hud_depth.offset_left = -380.0
	_hud_depth.grow_horizontal = Control.GROW_DIRECTION_BEGIN      # a long line grows left, never off screen
	_hud_depth.offset_right = -10.0
	_hud_depth.offset_top = 8.0
	_hud_depth.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var ls := LabelSettings.new()
	ls.font_size = 11
	ls.outline_size = 3
	ls.outline_color = Color.BLACK
	ls.font_color = Color(0.9, 0.85, 0.75)
	_hud_depth.label_settings = ls
	_hud.add_child(_hud_depth)
	add_child(_hud)


func _update_hud() -> void:
	var c = Game.climber
	if _hud_depth == null or not is_instance_valid(c) or not c.is_inside_tree():
		return
	var secs := _run_secs()
	var b := _cur_biome
	var bname: String = str(L["biomes"][b]) if b >= 0 else ""
	var relics := ""
	if CoopSync.cosmetics > 0:
		relics = "   relics %d/3" % CoopSync.cosmetics
	# from Fungal Hollow down, the team's idol fragments (synced map events, so everyone agrees)
	var idol := ""
	if b >= 2 or _frag_count > 0:
		idol = "   idol %d/3" % _frag_count
	_hud_depth.text = "%s   %d m   %s%s%s" % [bname, int(-c.global_position.y), _fmt_time(secs), idol, relics]


# ------------------------------------------------------------------ debug tour (screenshots)

func _update_tour(delta: float) -> void:
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	var stops: Array = L.get("tour", [])
	if stops.is_empty():
		return
	_tour_t -= delta
	if _tour_i >= 0 and _tour_i < stops.size() and stops[_tour_i].get("air", false):
		c.velocity = Vector3.ZERO
		c.AirVelocity = Vector3.ZERO
		c.global_position = _v(stops[_tour_i]["pos"])
	if _tour_t < 0.9 and not _tour_shot_done and _tour_i >= 0:
		_tour_shot_done = true
		var img := get_viewport().get_texture().get_image()
		if img:
			if img.get_width() > 960:
				img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
			img.save_png("user://underdark_tour_%02d.png" % int(stops[_tour_i].get("orig", _tour_i)))
		print("[Underdark] tour fps %d at stop %d y=%.1f floor=%s" % [Engine.get_frames_per_second(), int(stops[_tour_i].get("orig", _tour_i)), c.global_position.y, str(c.is_on_floor())])
	if _tour_t > 0.0:
		return
	_tour_i += 1
	_tour_shot_done = false
	if _tour_i >= stops.size():
		_debug_tour = false
		c.prevent_player_death = false          # a test never leaves the player invincible
		print("[Underdark] tour done")
		return
	_tour_t = 2.2
	var s: Dictionary = stops[_tour_i]
	var pos := _v(s["pos"])
	var look := _v(s["look"])
	c.prevent_player_death = true
	c.health = c.healthMax
	c.set_climber_state(c.defaultClimberState)
	c.velocity = Vector3.ZERO
	c.AirVelocity = Vector3.ZERO
	c.teleport_to_location(pos)
	var dir := (look - pos).normalized()
	var yaw := atan2(-dir.x, -dir.z)
	var pitch := asin(clampf(dir.y, -1.0, 1.0))
	c.PlayerCamera.set_camera_rotation(Vector3(pitch, yaw, 0.0))
	c.global_rotation = Vector3.ZERO
	print("[Underdark] tour %d/%d %s at %s" % [_tour_i + 1, stops.size(), s.get("label", ""), pos])
	if _tour_f6 and (_tour_i == 2 or _tour_i == 4):
		var ev := InputEventKey.new()
		ev.keycode = KEY_F6
		ev.physical_keycode = KEY_F6
		ev.pressed = true
		Input.parse_input_event(ev)
	if _tour_f6 and _weather != null:
		print("[Underdark] tour specks: enabled=%s level=%.2f biome=%d" % [str(_weather.enabled), _weather.level, _weather.cur])


# ------------------------------------------------------------------ helpers

func _v(a) -> Vector3:
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _c(a) -> Color:
	return Color(float(a[0]), float(a[1]), float(a[2]))


func _area(pos: Vector3, radius: float, mask: int) -> Area3D:
	var a := Area3D.new()
	a.collision_layer = 0
	a.collision_mask = mask
	var shape := CollisionShape3D.new()
	var sph := SphereShape3D.new()
	sph.radius = radius
	shape.shape = sph
	a.add_child(shape)
	a.position = pos
	return a


class Weather extends Node3D:
	# Motes in a box around the local camera, one emitter per kind, switched by biome. v4.9: back
	# on, gentle, and in SPELLS: about a minute of drifting dust / spores / ash, then clear air for
	# one to two minutes, fading in and out, so the air is never busy all the time. F6 turns them off
	# (and on) per player, saved by the map. Gentle means: about two thirds of the old count, dimmer,
	# no mote small enough to become a one-pixel sparkle, none further than 18 m (the far motes were
	# the ones that shimmered into specks), and every mote fades out within 3 m of the eye (a lit mote at arm's length read as a white orb).
	# Dust, ash, drips and the crystal glints are LIT: they show in lamp and lantern light and stay
	# dark in the dark. Spores, embers and the Nest's motes glow on their own.
	var kinds: Dictionary = {}
	var mats: Dictionary = {}           # kind -> its material (the fade rides on its albedo alpha)
	var dot: Texture2D
	var cur := -2
	var enabled := true                 # F6
	var level := 0.0                    # 0..1 strength of the air right now
	var _spell := false
	var _spell_t := 0.0
	var _fade_in := FADE_IN
	var _shown := -1.0
	var _rng := RandomNumberGenerator.new()
	const BY_BIOME := {
		0: ["dust"], 1: ["bone_ash"], 2: ["spores", "spores_big"], 3: ["dust", "drips_light"],
		4: ["drips", "mist_motes"], 5: ["dust_violet"], 6: ["glitter"], 7: ["ash", "sparks"],
		8: ["red_motes"], 9: [],
	}
	const PARTICLES_ON := true
	const SPELL_ON := Vector2(40.0, 80.0)      # seconds a spell lasts
	const SPELL_OFF := Vector2(50.0, 120.0)    # seconds of clear air between spells
	const FADE_IN := 8.0
	const FADE_OUT := 8.0
	const FADE_F6 := 0.6                       # F6 off: gone at once
	const FADE_F6_ON := 2.0                    # F6 on: a spell starts straight away

	func build(dot_tex: Texture2D) -> void:
		dot = dot_tex
		_rng.randomize()
		_spell = false
		_spell_t = _rng.randf_range(8.0, 30.0)    # the first spell comes soon after you arrive
		if not PARTICLES_ON:
			return
		#      name            n   life  box                  gravity                 v0    v1   size  colour                           streak y_off spread lit
		_add("dust",          140, 8.0, Vector3(18, 9, 18), Vector3(0.05, -0.08, 0.0), 0.05, 0.3, 0.16, Color(0.6, 0.55, 0.44, 0.5), false, 0.0, 180.0, true)
		_add("dust_violet",   140, 8.0, Vector3(18, 9, 18), Vector3(-0.04, -0.1, 0.03), 0.05, 0.3, 0.16, Color(0.52, 0.45, 0.66, 0.5), false, 0.0, 180.0, true)
		_add("bone_ash",      170, 7.0, Vector3(18, 9, 18), Vector3(0.0, -0.55, 0.0), 0.1, 0.5, 0.15, Color(0.6, 0.58, 0.54, 0.5), false, 4.0, 60.0, true)
		_add("spores",        200, 9.0, Vector3(18, 9, 18), Vector3(0.0, 0.22, 0.0), 0.05, 0.35, 0.15, Color(0.1, 0.34, 0.2, 0.55), false, -3.0, 180.0, false)
		_add("spores_big",     18, 12.0, Vector3(18, 9, 18), Vector3(0.0, 0.1, 0.0), 0.02, 0.15, 0.55, Color(0.05, 0.2, 0.11, 0.25), false, -2.0, 180.0, false)
		_add("drips_light",    33, 1.7, Vector3(18, 0.5, 18), Vector3(0.0, -14.0, 0.0), 2.0, 5.0, 1.0, Color(0.6, 0.72, 0.8, 0.4), true, 12.0, 4.0, true)
		_add("drips",         100, 1.7, Vector3(18, 0.5, 18), Vector3(0.0, -14.0, 0.0), 2.0, 6.0, 1.0, Color(0.6, 0.75, 0.85, 0.45), true, 12.0, 5.0, true)
		_add("mist_motes",     20, 10.0, Vector3(18, 6, 18), Vector3(0.1, 0.02, 0.0), 0.05, 0.25, 1.6, Color(0.4, 0.5, 0.55, 0.09), false, -2.0, 180.0, true)
		_add("glitter",       150, 6.0, Vector3(18, 9, 18), Vector3(0.0, -0.3, 0.0), 0.05, 0.3, 0.12, Color(0.45, 0.6, 0.78, 0.5), false, 3.0, 180.0, true)
		_add("ash",           180, 7.0, Vector3(18, 9, 18), Vector3(0.1, -0.5, 0.0), 0.1, 0.5, 0.16, Color(0.45, 0.4, 0.37, 0.6), false, 5.0, 70.0, true)
		_add("sparks",        110, 3.5, Vector3(18, 6, 18), Vector3(0.0, 1.7, 0.0), 0.5, 2.2, 0.1, Color(0.5, 0.16, 0.03, 0.65), false, -8.0, 40.0, false)
		_add("red_motes",      90, 8.0, Vector3(18, 9, 18), Vector3(0.0, 0.05, 0.0), 0.05, 0.3, 0.12, Color(0.34, 0.04, 0.04, 0.5), false, 0.0, 180.0, false)

	func _add(kind: String, n: int, life: float, ext: Vector3, grav: Vector3, v0: float, v1: float, size: float, col: Color, streak: bool, y_off: float, spread: float, lit: bool) -> void:
		var p := CPUParticles3D.new()
		p.amount = n
		p.lifetime = life
		p.randomness = 1.0
		p.local_coords = false
		p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		p.emission_box_extents = ext
		p.direction = Vector3.UP if grav.y > 0.0 else Vector3.DOWN
		p.spread = spread
		p.gravity = grav
		p.initial_velocity_min = v0
		p.initial_velocity_max = v1
		p.scale_amount_min = 0.7
		p.scale_amount_max = 1.3
		p.color = col
		var fm := StandardMaterial3D.new()
		fm.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL if lit else BaseMaterial3D.SHADING_MODE_UNSHADED
		fm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		fm.vertex_color_use_as_albedo = true
		fm.disable_receive_shadows = true
		fm.albedo_color = Color(1, 1, 1, 0)
		fm.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
		fm.distance_fade_min_distance = 1.0       # nothing blots the view: gone within 1 m, full from 3 m
		fm.distance_fade_max_distance = 3.0
		if lit:
			fm.roughness = 1.0
			fm.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		if streak:
			var bm := BoxMesh.new()
			bm.size = Vector3(0.025, 0.55, 0.025)
			bm.material = fm
			p.mesh = bm
			p.particle_flag_align_y = true
		else:
			fm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
			fm.albedo_texture = dot
			var qm := QuadMesh.new()
			qm.size = Vector2(size, size)
			qm.material = fm
			p.mesh = qm
		p.position = Vector3(0, y_off, 0)
		p.emitting = false
		p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(p)
		kinds[kind] = p
		mats[kind] = fm

	func set_enabled(on: bool) -> void:
		# F6. Switching on starts a spell straight away, so you see what you switched on.
		enabled = on
		if on:
			_spell = true
			_spell_t = _rng.randf_range(SPELL_ON.x, SPELL_ON.y)
			_fade_in = FADE_F6_ON

	func force_full() -> void:
		# developer tour: a spell at full strength that never ends, so every shot shows the air
		_spell = true
		_spell_t = 1e9
		level = 1.0
		_apply()

	func _process(delta: float) -> void:
		_spell_t -= delta
		if _spell_t <= 0.0:
			_spell = not _spell
			_fade_in = FADE_IN
			if _spell:
				_spell_t = _rng.randf_range(SPELL_ON.x, SPELL_ON.y)
			else:
				_spell_t = _rng.randf_range(SPELL_OFF.x, SPELL_OFF.y)
		var target := 1.0 if (enabled and _spell) else 0.0
		var t := _fade_in
		if not enabled:
			t = FADE_F6
		elif target < level:
			t = FADE_OUT
		level = move_toward(level, target, delta / t)
		if absf(level - _shown) > 0.01 or (level == 0.0 and _shown != 0.0) or (level == 1.0 and _shown != 1.0):
			_apply()

	func _apply() -> void:
		_shown = level
		var on: Array = BY_BIOME.get(cur, [])
		for k in kinds.keys():
			var fm: StandardMaterial3D = mats[k]
			fm.albedo_color = Color(1, 1, 1, level)
			var want: bool = level > 0.0 and on.has(k)
			var p: CPUParticles3D = kinds[k]
			if p.emitting != want:
				p.emitting = want

	func follow(c: Node3D, biome: int) -> void:
		var cam = c.get("Camera")
		global_position = (cam as Node3D).global_position if is_instance_valid(cam) else c.global_position
		if biome == cur:
			return
		cur = biome
		_apply()


class U:
	const CLICKS := ["res://sfx/soundsnap/creature_footsteps/243425-metal_hit_small-carpet_knife01.wav",
			"res://sfx/soundsnap/creature_footsteps/243426-metal_hit_small-carpet_knife02.wav",
			"res://sfx/soundsnap/creature_footsteps/243427-metal_hit_small-carpet_knife03.wav",
			"res://sfx/soundsnap/creature_footsteps/243428-metal_hit_small-carpet_knife04.wav",
			"res://sfx/soundsnap/creature_footsteps/243430-metal_hit_small-carpet_knife06.wav",
			"res://sfx/soundsnap/creature_footsteps/243431-metal_hit_small-carpet_knife07.wav",
			"res://sfx/soundsnap/creature_footsteps/243432-metal_hit_small-carpet_knife08.wav",
			"res://sfx/soundsnap/creature_footsteps/243434-metal_hit_small-carpet_knife10.wav"]
	const TEETH := ["res://sfx/MonsterIdeas/Teeth_01.wav", "res://sfx/MonsterIdeas/Teeth_02.wav",
			"res://sfx/MonsterIdeas/Teeth_03.wav", "res://sfx/MonsterIdeas/Teeth_04.wav"]

	static func sfx(path: String, db: float, pos: Vector3, parent: Node, max_dist: float = 40.0) -> AudioStreamPlayer3D:
		var p := AudioStreamPlayer3D.new()
		p.stream = load(path)
		p.volume_db = db
		p.max_distance = max_dist
		p.bus = cave_bus()
		p.position = pos
		parent.add_child(p)
		return p

	static func cave_bus() -> StringName:
		# v4.9: creature, trap and ambience sounds ring through the soundscape's cave reverb
		# ("ZondaCave" sends to MainBus, so the game's volume slider still governs them)
		if AudioServer.get_bus_index("ZondaCave") >= 0:
			return &"ZondaCave"
		return &"MainBus"


# ================================================================== trap classes

class Crumble extends Node3D:
	# Rumbles and shakes for a full second, then drops. Synced: whoever triggers it
	# tells everyone, and the fall happens on every screen.
	var id := ""
	var piece: Node3D
	var area: Area3D
	var origin: Vector3
	var stand_time := 0.0
	var state := 0
	var shake_t := 0.0
	var sfx_rumble: AudioStreamPlayer3D
	var sfx_gravel: AudioStreamPlayer3D
	var reach := 4.0

	func setup(i: String, p: Node3D, r: float) -> void:
		id = i
		piece = p
		reach = r
		origin = p.position
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 4
		var shape := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = r
		shape.shape = sph
		area.add_child(shape)
		area.position = origin + Vector3(0, 1.2, 0)

	func _ready() -> void:
		add_child(area)
		sfx_rumble = U.sfx(SFX_RUMBLE, -4.0, origin, self, 45.0)
		sfx_gravel = U.sfx(SFX_GRAVEL, -2.0, origin, self, 45.0)

	func _process(delta: float) -> void:
		if not is_instance_valid(piece):
			return
		if state == 0:
			var c = Game.climber
			if is_instance_valid(c) and area.overlaps_body(c):
				stand_time += delta
				if stand_time > 0.9:
					CoopSync.map_event("crumble_" + id, {}, false)
			else:
				stand_time = maxf(0.0, stand_time - delta * 2.0)
		elif state == 1:
			shake_t += delta
			var k := 0.06 + 0.16 * shake_t
			piece.position = origin + Vector3(sin(shake_t * 60.0) * k, -shake_t * 0.12, cos(shake_t * 52.0) * k)
			if shake_t > 1.05:
				_fall()

	func remote_collapse() -> void:
		if state != 0:
			return
		state = 1
		shake_t = 0.0
		sfx_rumble.play()
		sfx_gravel.play()

	func _fall() -> void:
		state = 2
		var c = Game.climber
		if is_instance_valid(c) and c.activeClimberState is ClimberState_Attached and is_instance_valid(c.Rope._claw):
			if c.Rope._claw.global_position.distance_to(piece.global_position) < reach + 1.5:
				c.set_climber_state(c.defaultClimberState)
				Game.audio.play_rope_snap_sfx()
		Game.audio.play_metal_hit(piece.global_position)
		var tw := create_tween()
		tw.tween_property(piece, "position:y", origin.y - 80.0, 1.7).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(_hide)
		await get_tree().create_timer(30.0).timeout
		if not is_instance_valid(piece):
			return
		piece.position = origin
		piece.visible = true
		_collision(true)
		stand_time = 0.0
		state = 0

	func _hide() -> void:
		if is_instance_valid(piece):
			piece.visible = false
			_collision(false)

	func _collision(on: bool) -> void:
		for body in piece.find_children("*", "StaticBody3D", true, false):
			body.collision_layer = 1 if on else 0


class FireVent extends Node3D:
	var fire: Node3D
	var light: OmniLight3D
	var area: Area3D
	var period := 7.0
	var phase := 0.0
	var clock := 0.0
	var tick := 0.0
	var was_active := false

	func setup(f: Node3D, l: OmniLight3D, pos: Vector3, p: float, ph: float) -> void:
		fire = f
		light = l
		period = p
		phase = ph
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 4
		var shape := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 3.2
		shape.shape = sph
		area.add_child(shape)
		area.position = pos + Vector3(0, 1.4, 0)

	func _ready() -> void:
		add_child(area)

	func _process(delta: float) -> void:
		clock += delta
		var t: float = fmod(clock + phase, period)
		var active: bool = t < 2.2
		if is_instance_valid(fire):
			var target := 1.15 if active else 0.35
			var sc: float = lerpf(fire.scale.x, target, clampf(delta * 8.0, 0.0, 1.0))
			fire.scale = Vector3(sc, sc, sc)
		if is_instance_valid(light):
			light.light_energy = lerpf(light.light_energy, 0.7 + (2.6 if active else 0.0), clampf(delta * 8.0, 0.0, 1.0))
		if not active:
			was_active = false
			tick = 0.0
			return
		var c = Game.climber
		if not is_instance_valid(c):
			return
		if area.overlaps_body(c):
			tick -= delta
			if tick <= 0.0:
				tick = 0.7
				c.take_damage(12.0)
				if not was_active:
					c.additional_velocity_next_frame += Vector3.UP * 7.0
			was_active = true


class Dropper extends Node3D:
	var id := ""
	var rock: Node3D
	var trip: Area3D
	var hurt: Area3D
	var rest: Vector3
	var floor_y := 0.0
	var falling := false
	var armed := true
	var hit_done := false
	var damage := 60.0
	var fall_time := 1.1
	var reset_after := 28.0

	func setup(i: String, r: Node3D, trip_pos: Vector3, trip_r: float, hurt_r: float, fy: float) -> void:
		id = i
		rock = r
		rest = r.position
		floor_y = fy
		trip = Area3D.new()
		trip.collision_layer = 0
		trip.collision_mask = 4
		var ts := CollisionShape3D.new()
		var tsph := SphereShape3D.new()
		tsph.radius = trip_r
		ts.shape = tsph
		trip.add_child(ts)
		trip.position = trip_pos
		hurt = Area3D.new()
		hurt.collision_layer = 0
		hurt.collision_mask = 4
		var hs := CollisionShape3D.new()
		var hsph := SphereShape3D.new()
		hsph.radius = hurt_r
		hs.shape = hsph
		hurt.add_child(hs)

	func _ready() -> void:
		add_child(trip)
		add_child(hurt)
		trip.body_entered.connect(_on_trip)

	func _on_trip(body: Node3D) -> void:
		if not armed or body != Game.climber:
			return
		CoopSync.map_event("drop_" + id, {}, false)

	func remote_drop() -> void:
		if not armed:
			return
		armed = false
		falling = true
		hit_done = false
		Game.audio.play_metal_hit(rock.global_position)
		var tw := create_tween()
		tw.tween_property(rock, "position:y", floor_y - 1.0, fall_time).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(func(): falling = false)
		await get_tree().create_timer(reset_after).timeout
		if not is_instance_valid(rock):
			return
		rock.position = rest
		armed = true

	func _process(_delta: float) -> void:
		if not falling or hit_done or not is_instance_valid(rock) or not is_instance_valid(Game.climber):
			return
		hurt.global_position = rock.global_position
		if hurt.overlaps_body(Game.climber):
			hit_done = true
			var c = Game.climber
			c.take_damage(damage)
			var away: Vector3 = c.global_position - rock.global_position
			away.y = 0.0
			away = away.normalized() if away.length_squared() > 0.001 else Vector3.RIGHT
			c.additional_velocity_next_frame += away * 14.0 + Vector3.DOWN * 6.0
			Game.audio.play_player_was_bit()


class SpikeBed extends Node3D:
	var hurt: Area3D
	var shove: Vector3
	var cooldown := 0.0

	func setup(h: Area3D, push: Vector3) -> void:
		hurt = h
		shove = push

	func _process(delta: float) -> void:
		cooldown = maxf(0.0, cooldown - delta)
		if cooldown > 0.0 or not is_instance_valid(hurt) or not is_instance_valid(Game.climber):
			return
		if hurt.overlaps_body(Game.climber):
			cooldown = 1.4
			var c = Game.climber
			c.take_damage(40.0)
			c.additional_velocity_next_frame += shove * 15.0 + Vector3.UP * 5.0
			# no rope cut: the rope behaves exactly as in the base game


class IceShelf extends Node3D:
	var area: Area3D
	var slide: Vector3

	func setup(a: Area3D, dir: Vector3) -> void:
		area = a
		slide = dir

	func _physics_process(_delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		if c.is_on_floor() and area.overlaps_body(c):
			c.additional_velocity_next_frame += slide * 0.05


# ================================================================== puzzle classes

class Gate extends Node3D:
	var id := ""
	var is_open := false
	var latched := false
	var solo_timer := 0.0
	var door: MeshInstance3D
	var body: StaticBody3D
	var closed_y := 0.0
	var open_y := 0.0
	var sfx: AudioStreamPlayer3D
	var tw: Tween

	func setup(g: Dictionary, mat: Material) -> void:
		id = str(g["id"])
		var pos := Vector3(g["pos"][0], g["pos"][1], g["pos"][2])
		var w := float(g["w"])
		var h := float(g["h"])
		closed_y = pos.y
		open_y = pos.y + h - 0.6
		door = MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(w, h, 1.6)
		door.mesh = bm
		var m: StandardMaterial3D = load("res://Art/Textures/Wall_04.tres").duplicate()
		m.albedo_color = Color(0.35, 0.3, 0.28)
		door.material_override = m
		body = StaticBody3D.new()
		body.collision_layer = 1
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = bm.size
		cs.shape = bs
		body.add_child(cs)
		door.add_child(body)
		door.position = pos
		door.rotation.y = float(g["yaw"])
		# frame the door with two iron pillars so it reads as a puzzle door
		for side in [-1.0, 1.0]:
			var pil := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.5
			cm.bottom_radius = 0.6
			cm.height = h + 2.0
			pil.mesh = cm
			pil.material_override = mat
			pil.position = Vector3(side * (w * 0.5 + 0.7), 0.0, 0.0)
			add_child(pil)
		position = Vector3.ZERO
		add_child(door)
		for p in get_children():
			if p != door:
				p.position = door.position + door.basis * p.position
				p.rotation.y = door.rotation.y

	func _ready() -> void:
		sfx = U.sfx(SFX_METAL[0], 0.0, door.position, self, 60.0)

	func open(instant: bool = false) -> void:
		if is_open:
			return
		is_open = true
		if instant:
			# replayed after a reload or a late join: already open, no slide and no sound
			if tw:
				tw.kill()
			door.position.y = open_y
			return
		_slide(open_y)

	func close() -> void:
		if not is_open:
			return
		is_open = false
		_slide(closed_y)

	func _slide(target_y: float) -> void:
		if tw:
			tw.kill()
		sfx.play()
		tw = create_tween()
		tw.tween_property(door, "position:y", target_y, 2.2).set_trans(Tween.TRANS_SINE)


class Kiln extends Node3D:
	var gate := ""
	var idx := 0
	var lit := false
	var pos: Vector3
	var fire: Node3D
	var light: OmniLight3D
	var area: Area3D

	func setup(g: String, i: int, p: Vector3) -> void:
		gate = g
		idx = i
		pos = p

	func _ready() -> void:
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 4
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 3.0
		cs.shape = sph
		area.add_child(cs)
		area.position = pos + Vector3(0, 1.5, 0)
		add_child(area)
		light = OmniLight3D.new()
		light.light_color = Color(1.0, 0.5, 0.15)
		light.light_energy = 0.15
		light.omni_range = 18.0
		light.shadow_enabled = false
		light.position = pos + Vector3(0, 3.0, 0)
		add_child(light)
		var ps: PackedScene = load(PYRELIGHT)
		if ps:
			fire = ps.instantiate()
			fire.position = pos + Vector3(0, 1.0, 0)
			fire.scale = Vector3(0.12, 0.12, 0.12)
			add_child(fire)

	func _process(_delta: float) -> void:
		if lit:
			return
		var c = Game.climber
		if is_instance_valid(c) and area.overlaps_body(c):
			CoopSync.map_event("kiln_%d" % idx, {})

	func light_up(instant: bool = false) -> void:
		if lit:
			return
		lit = true
		if instant:
			# replayed: lit already, quietly
			if is_instance_valid(fire):
				fire.scale = Vector3(0.9, 0.9, 0.9)
			if is_instance_valid(light):
				light.light_energy = 1.8
			return
		if is_instance_valid(fire):
			var tw := create_tween()
			tw.tween_property(fire, "scale", Vector3(0.9, 0.9, 0.9), 1.2)
		if is_instance_valid(light):
			var tw2 := create_tween()
			tw2.tween_property(light, "light_energy", 1.8, 1.2)
		Game.audio.play_player_healed()
		CoopSync.show_banner("Kiln lit.", 2.0)


class Plate extends Node3D:
	var gate := ""
	var idx := 0
	var pos: Vector3
	var mesh: MeshInstance3D
	var pressed := false
	var off_t := 0.0
	var up_ms := 0

	func setup(g: String, i: int, p: Vector3, mat: Material) -> void:
		gate = g
		idx = i
		pos = p
		mesh = MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 2.2
		cm.bottom_radius = 2.4
		cm.height = 0.35
		mesh.mesh = cm
		mesh.material_override = mat
		mesh.position = pos + Vector3(0, 0.17, 0)

	func _ready() -> void:
		add_child(mesh)
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.7, 0.3)
		l.light_energy = 0.5
		l.omni_range = 8.0
		l.shadow_enabled = false
		l.position = pos + Vector3(0, 1.2, 0)
		add_child(l)

	func _on_plate(p: Vector3) -> bool:
		# one test for everyone, the host's own knight included: over the plate, standing on it
		var q := p - pos
		return Vector2(q.x, q.z).length() < 2.6 and q.y > -0.5 and q.y < 2.8

	func host_check(delta: float) -> bool:
		# the host only: a plate is down if any living player is on it. It must read empty for
		# 0.25 s before it rises, so a late teammate packet never bounces it.
		var on := false
		var c = Game.climber
		if is_instance_valid(c) and c.is_inside_tree() and not c.get("coop_spectating") and _on_plate(c.global_position):
			on = true
		if not on:
			for rp in CoopSync.remote_players():
				if _on_plate(rp.global_position):
					on = true
					break
		if on:
			off_t = 0.0
		elif pressed:
			off_t += delta
			if off_t < 0.25:
				on = true
		_set_pressed(on)
		return on

	func remote_pressed(on: bool) -> void:
		_set_pressed(on)

	func _set_pressed(on: bool) -> void:
		if on == pressed:
			return
		pressed = on
		mesh.position.y = pos.y + (0.05 if on else 0.17)
		if on:
			# one clank per real press: a plate that was up for under 0.3 s stays quiet
			if Time.get_ticks_msec() - up_ms > 300:
				Game.audio.play_metal_hit(pos)
		else:
			up_ms = Time.get_ticks_msec()


class Fragment extends Node3D:
	var id := ""
	var pos: Vector3
	var collected := false
	var mesh: MeshInstance3D
	var area: Area3D
	var light: OmniLight3D

	func setup(i: String, p: Vector3, mat: Material) -> void:
		id = i
		pos = p
		mesh = MeshInstance3D.new()
		var pm := PrismMesh.new()
		pm.size = Vector3(0.7, 1.1, 0.7)
		mesh.mesh = pm
		var m: StandardMaterial3D = mat.duplicate()
		m.albedo_color = Color(0.7, 0.5, 0.15)
		m.emission_enabled = true
		m.emission = Color(1.0, 0.7, 0.2)
		m.emission_energy_multiplier = 0.25
		mesh.material_override = m
		mesh.position = p

	func _ready() -> void:
		add_child(mesh)
		light = OmniLight3D.new()
		light.light_color = Color(1.0, 0.8, 0.35)
		light.light_energy = 1.4
		light.omni_range = 16.0
		light.shadow_enabled = false
		light.position = pos + Vector3(0, 0.6, 0)
		add_child(light)
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 4
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 2.4
		cs.shape = sph
		area.add_child(cs)
		area.position = pos
		add_child(area)

	func _process(delta: float) -> void:
		if collected:
			return
		mesh.rotation.y += delta * 1.6
		mesh.position.y = pos.y + sin(Time.get_ticks_msec() * 0.003) * 0.25
		var c = Game.climber
		if is_instance_valid(c) and area.overlaps_body(c):
			CoopSync.map_event("frag_" + id, {"by": CoopSync.local_name})

	func collect(_by: String, quiet: bool = false) -> void:
		if collected:
			return
		collected = true
		mesh.visible = false
		if is_instance_valid(light):
			light.queue_free()            # gone for good: the light budget would switch a hidden one back on
		if not quiet:
			Game.audio.play_player_healed()


# ================================================================== the crucible

class MonkeyBar extends Node3D:
	# A thin rod of hot iron hanging from chains. Grapple only: the game's hook test is a ray
	# on layer 1, which the player also collides with, so the collision is a steep invisible
	# ridge around the rod (58 degree faces: the hook bites, feet slide off) and anyone who
	# still manages to perch on it is pushed off.
	# Some are rigged: hang from one too long and it rumbles, then sinks 3.5 m.
	var bar: MeshInstance3D
	var idx := 0
	var sink := false
	var sunk := false
	var sinking := false
	var hang_t := 0.0
	var top_y := 0.0
	var chains: Array = []
	var light: OmniLight3D
	var sfx_rumble: AudioStreamPlayer3D
	var half_len := 6.0
	var dot_tex: Texture2D

	func _ready() -> void:
		if sink:
			sfx_rumble = U.sfx(SFX_RUMBLE, 0.0, bar.position, self, 60.0)

	func _process(delta: float) -> void:
		if not sink or sunk:
			return
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		var on_it := false
		var top := bar.position + Vector3(0, 0.4, 0)
		if c.activeClimberState is ClimberState_Attached and is_instance_valid(c.Rope._claw):
			on_it = (c.Rope._claw.global_position - top).length() < 3.0
		if not on_it and c.is_on_floor() and (c.global_position - top).length() < 3.2:
			on_it = true
		if on_it:
			hang_t += delta
			if hang_t > 1.2:
				CoopSync.map_event("barsink_%d" % idx, {})
		else:
			hang_t = maxf(0.0, hang_t - delta)

	func sink_now(instant: bool = false) -> void:
		if sunk:
			return
		sunk = true
		if instant:
			# replayed: already down, no rumble and no shake
			bar.position.y -= 3.5
			if light:
				light.position.y -= 3.5
			for ch in chains:
				var cmi: CylinderMesh = ch.mesh
				cmi.height += 3.5
				ch.position.y -= 1.75
			return
		sinking = true
		if sfx_rumble:
			sfx_rumble.play()
		var start := bar.position
		var tw := create_tween()
		# shake for 0.8 s, then drop 3.5 m over 1.4 s
		for i in 10:
			tw.tween_property(bar, "position", start + Vector3(randf_range(-0.12, 0.12), -0.05 * i, randf_range(-0.12, 0.12)), 0.08)
		tw.tween_property(bar, "position:y", start.y - 3.5, 1.4).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.tween_callback(func(): sinking = false)
		if light:
			var tl := create_tween()
			tl.tween_property(light, "position:y", light.position.y - 3.5, 2.2)
		for ch in chains:
			var cm: CylinderMesh = ch.mesh
			var tc := create_tween()
			tc.tween_property(cm, "height", cm.height + 3.5, 2.2)
			tc.parallel().tween_property(ch, "position:y", ch.position.y - 1.75, 2.2)

	func _physics_process(_delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		# nobody stands on a rod
		if c.is_on_floor():
			var lp: Vector3 = bar.global_transform.affine_inverse() * c.global_position
			if absf(lp.x) < 1.3 and absf(lp.z) < half_len + 0.6 and lp.y > -1.4 and lp.y < 1.8:
				var side: Vector3 = bar.global_basis.x * (1.0 if lp.x >= 0.0 else -1.0)
				c.additional_velocity_next_frame += side * 6.0 + Vector3.DOWN * 2.0
		# the hook rides the bar down instead of hanging in mid-air where the bar was
		if not sinking:
			return
		if not (c.activeClimberState is ClimberState_Attached) or not is_instance_valid(c.Rope._claw):
			return
		var claw: RigidBody3D = c.Rope._claw
		var top := bar.position + Vector3(0, 0.6, 0)
		var flat: Vector3 = claw.global_position
		flat.y = top.y
		if (flat - top).length() < 3.2 and claw.global_position.y > top.y:
			claw.global_position.y = top.y
			PhysicsServer3D.body_set_state(claw.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D.IDENTITY.translated(claw.global_position))

	func setup(b: Dictionary, mat: Material) -> void:
		idx = int(b["idx"])
		sink = bool(b.get("sink", false))
		var pos := Vector3(b["pos"][0], b["pos"][1], b["pos"][2])
		var length := float(b["length"])
		var width := float(b["width"])
		var thick := float(b["thick"])
		half_len = length * 0.5
		bar = MeshInstance3D.new()
		bar.position = pos
		bar.rotation.y = float(b["yaw"])
		var rod := MeshInstance3D.new()
		var rm := CylinderMesh.new()
		rm.top_radius = maxf(0.08, width * 0.5)
		rm.bottom_radius = rm.top_radius
		rm.height = length
		rm.radial_segments = 8
		rm.rings = 1
		rod.mesh = rm
		var hot := StandardMaterial3D.new()                   # iron that has hung over a lava lake for a long time
		hot.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		# just under the post clip (about linear 0.06 red, the lava's own hot value): deep red-orange
		# iron, not white. Rigged rods look exactly the same: their tell is the rumble and shake
		# when you hang on them, never a colour you can read from afar.
		hot.albedo_color = Color(0.27, 0.09, 0.02)
		rod.material_override = hot
		rod.rotation.x = PI * 0.5
		rod.position = Vector3(0, -0.3, 0)
		bar.add_child(rod)
		var body := StaticBody3D.new()
		body.collision_layer = 1
		body.physics_material_override = load("res://physics_materials/stone.tres")
		var cs := CollisionShape3D.new()
		var ridge := ConvexPolygonShape3D.new()
		var hl := length * 0.5
		ridge.points = PackedVector3Array([
			Vector3(0, 0, -hl), Vector3(0.55, -0.88, -hl), Vector3(-0.55, -0.88, -hl),
			Vector3(0, 0, hl), Vector3(0.55, -0.88, hl), Vector3(-0.55, -0.88, hl)])
		cs.shape = ridge
		body.add_child(cs)
		bar.add_child(body)
		add_child(bar)
		for e in [-1.0, 1.0]:                                  # a glow at each end so you can find it from a rope away
			var dot := MeshInstance3D.new()
			var qm := QuadMesh.new()
			qm.size = Vector2(1.6, 1.6)
			dot.mesh = qm
			var gm := StandardMaterial3D.new()
			gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			gm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			gm.albedo_texture = dot_tex
			gm.albedo_color = Color(0.4, 0.13, 0.03, 0.9)
			gm.disable_fog = true
			dot.material_override = gm
			dot.position = Vector3(0, -0.3, e * (hl - 0.8))
			bar.add_child(dot)
		# chains up to the ceiling
		var tops: Array = b["chain_top"]
		for i in 2:
			var side := -1.0 if i == 0 else 1.0
			var local := Vector3(0, 0, side * (length * 0.5 - 0.8))
			var world := bar.position + bar.basis * local
			var top_y := float(tops[i])
			var ch := MeshInstance3D.new()
			var cm := CylinderMesh.new()
			cm.top_radius = 0.09
			cm.bottom_radius = 0.09
			cm.height = maxf(0.5, top_y - world.y)
			ch.mesh = cm
			ch.material_override = mat
			ch.position = Vector3(world.x, (world.y + top_y) * 0.5, world.z)
			add_child(ch)
			chains.append(ch)
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.55, 0.2)
		l.light_energy = 0.5
		l.omni_range = 10.0
		l.shadow_enabled = false
		l.position = pos + Vector3(0, 1.5, 0)
		add_child(l)
		light = l


# ================================================================== creatures

class Stalker extends Node3D:
	# A centipede-shaped thing that only moves while nobody on the team can see it.
	# Host runs it and streams its position; guests just show it. It hunts the nearest
	# living player inside its zone, bites, and retreats to the dark.
	var id := ""
	var home: Vector3
	var zone: Array = []
	var speed := 26.0
	var body: Node3D
	var segs: Array = []
	var trail: Array = []
	var target_pos: Vector3
	var bite_cd := 0.0
	var hidden_t := 0.0
	var sfx_breath: AudioStreamPlayer3D
	var sfx_snarl: AudioStreamPlayer3D
	var sfx_chomp: AudioStreamPlayer3D
	var sfx_step: AudioStreamPlayer3D
	var _step_t := 0.0
	var _last_body := Vector3.ZERO
	var _snarl_near := false
	var visible_to_someone := false
	var rp_pos: Vector3
	var rp_yaw := 0.0
	var retreat := 0.0

	func setup(s: Dictionary) -> void:
		id = str(s["id"])
		home = Vector3(s["home"][0], s["home"][1], s["home"][2])
		zone = s["zone"]
		speed = float(s.get("speed", 26.0))
		target_pos = home

	func _ready() -> void:
		body = Node3D.new()
		var head_ps: PackedScene = load("res://Art/Monster_Head_Redesign.glb")
		var seg_ps: PackedScene = load("res://Art/Monster_BodySection_Redesign.glb")
		if head_ps:
			var h: Node3D = head_ps.instantiate()
			h.scale = Vector3.ONE * 1.4
			body.add_child(h)
		for i in 9:
			if seg_ps:
				var sg: Node3D = seg_ps.instantiate()
				sg.scale = Vector3.ONE * 1.3
				add_child(sg)
				segs.append(sg)
				sg.position = home
		body.position = home
		add_child(body)
		for i in 60:
			trail.append(home)
		sfx_breath = U.sfx("res://sfx/soundsnap/monster_idle/306004-Creature-Oxbow-Breaths-Wet-Fast.wav", 2.0, Vector3.ZERO, body, 45.0)
		sfx_snarl = U.sfx("res://sfx/soundsnap/monster_attack/306011-Creature-Oxbow-Snarls-Breaths-Aggressive_2.wav", 4.0, Vector3.ZERO, body, 60.0)
		var teeth := AudioStreamRandomizer.new()
		for t in U.TEETH:
			teeth.add_stream(-1, load(t))
		sfx_chomp = U.sfx(U.TEETH[0], 8.0, Vector3(0, 0.8, 0), body, 45.0)
		sfx_chomp.stream = teeth
		var claws := AudioStreamRandomizer.new()
		claws.random_pitch = 1.2
		for t in U.CLICKS:
			claws.add_stream(-1, load(t))
		sfx_step = U.sfx(U.CLICKS[0], 3.0, Vector3.ZERO, body, 32.0)
		sfx_step.stream = claws
		sfx_step.max_polyphony = 3
		_last_body = home
		var l := OmniLight3D.new()
		l.light_color = Color(0.6, 0.1, 0.1)
		l.light_energy = 0.35
		l.omni_range = 9.0
		l.shadow_enabled = false
		body.add_child(l)
		rp_pos = home

	func _in_zone(p: Vector3) -> bool:
		for z in zone:
			var c := Vector3(z[0][0], z[0][1], z[0][2])
			if (p - c).length() < float(z[1]) + 6.0:
				return true
		return false

	func _seen_by(p: Vector3, cam: Camera3D) -> bool:
		if cam == null:
			return false
		return _seen_from(cam.global_position, -cam.global_basis.z, p)

	func _seen_from(eye: Vector3, fwd: Vector3, p: Vector3) -> bool:
		# test its knees, its back and its head: any one of them in the clear counts as seen
		var space := get_world_3d().direct_space_state
		for off in [0.7, 1.7, 2.6]:
			var q: Vector3 = p + Vector3.UP * off
			var to := q - eye
			var d := to.length()
			if d > 120.0:
				continue
			if fwd.dot(to / maxf(d, 0.01)) < 0.45:
				continue
			if space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, q, 1)).is_empty():
				return true
		return false

	func _seen_by_teammate(rp: Node3D) -> bool:
		# a teammate's real view: camera yaw and pitch from their state packet, from their eyes.
		# An older build sends no pitch: then the old yaw-only test from the knight's body.
		var cy = rp.get("cam_yaw")
		var cp = rp.get("cam_pitch")
		if cy == null or cp == null:
			var fwd0: Vector3 = -rp.global_basis.z
			var to0: Vector3 = (body.position + Vector3.UP * 1.7) - rp.global_position
			var d0: float = to0.length()
			if d0 < 100.0 and fwd0.dot(to0 / maxf(d0, 0.01)) > 0.5:
				var ray := PhysicsRayQueryParameters3D.create(rp.global_position + Vector3.UP * 1.5, body.position + Vector3.UP * 1.7, 1)
				return get_world_3d().direct_space_state.intersect_ray(ray).is_empty()
			return false
		var fwd: Vector3 = -Basis.from_euler(Vector3(float(cp), float(cy), 0.0)).z
		var eye: Vector3 = rp.global_position + Vector3.UP * 1.55
		if rp.has_method("eye_position"):
			eye = rp.call("eye_position")
		return _seen_from(eye, fwd, body.position)


	func _floor_under(p: Vector3) -> float:
		var space := get_world_3d().direct_space_state
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 8.0, p + Vector3.DOWN * 45.0, 1))
		if hit.is_empty():
			return -1e9
		return float(hit["position"].y)

	func _process(delta: float) -> void:
		bite_cd = maxf(0.0, bite_cd - delta)
		if CoopSync.map_is_authority():
			_think(delta)
		else:
			# while this guest is watching it, it holds still on this screen (the host stops it
			# too, a packet later); small corrections happen only while nobody here looks
			var hold := false
			var c = Game.climber
			if is_instance_valid(c) and c.is_inside_tree() and c.Camera and not c.get("coop_spectating"):
				if (rp_pos - body.position).length() < 12.0:
					hold = _seen_by(body.position, c.Camera)
			if not hold:
				body.position = body.position.lerp(rp_pos, clampf(delta * 10.0, 0.0, 1.0))
				body.rotation.y = lerp_angle(body.rotation.y, rp_yaw, clampf(delta * 8.0, 0.0, 1.0))
		_update_segments(delta)
		_local_sounds(delta)

	func _local_sounds(delta: float) -> void:
		# what THIS player hears, host or guest: wet breathing inside 40 m, claws clicking on the
		# rock while it moves inside 32 m, and a snarl the moment it gets within reach
		var moved: float = (body.position - _last_body).length()
		_last_body = body.position
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		var d: float = (c.global_position - body.position).length()
		if d < 40.0 and not sfx_breath.playing:
			sfx_breath.play()
		_step_t -= delta
		if d < 32.0 and moved > 0.02 and _step_t <= 0.0:
			_step_t = randf_range(0.11, 0.2)
			sfx_step.play()
		var near: bool = d < 4.0
		if near and not _snarl_near and not sfx_snarl.playing:
			sfx_snarl.play()
		_snarl_near = near

	func bite_sounds() -> void:
		sfx_snarl.play()
		sfx_chomp.play()

	func _think(delta: float) -> void:
		var players := CoopSync.alive_player_nodes()
		var nearest: Node3D = null
		var nd := 1e9
		for p in players:
			if not _in_zone(p.global_position):
				continue
			var d: float = (p.global_position - body.position).length()
			if d < nd:
				nd = d
				nearest = p
		# seen by the local camera (not a dead host's spectator camera), or by a living teammate's
		# real view (their camera yaw and pitch, from their eyes)
		var seen := false
		var c = Game.climber
		if is_instance_valid(c) and c.Camera and not c.get("coop_spectating"):
			seen = _seen_by(body.position, c.Camera)
		if not seen:
			for rp in CoopSync.remote_players():
				if _seen_by_teammate(rp):
					seen = true
					break
		visible_to_someone = seen
		# the bell: while it rings the stalker slinks back to its dark
		if CoopSync.lure_active():
			retreat = maxf(retreat, 1.0)
		if retreat > 0.0:
			retreat -= delta
			target_pos = home
		elif nearest:
			target_pos = nearest.global_position + Vector3.UP * 0.8
			if not sfx_breath.playing and nd < 40.0:
				sfx_breath.play()
		else:
			target_pos = home
		if not seen or retreat > 0.0:
			hidden_t += delta
			var step := speed * delta
			var to := target_pos - body.position
			to.y = 0.0                                   # it walks the rock, it does not fly
			var flat := to.length()
			var want := body.position
			if flat > step:
				want += to / flat * step
			elif flat > 0.01:
				want += to
			var space := get_world_3d().direct_space_state
			if flat > 0.01:
				var chest := Vector3.UP * 1.4
				if space.intersect_ray(PhysicsRayQueryParameters3D.create(body.position + chest, want + chest, 1)).is_empty():
					body.position = want
				else:
					var up_over := want + Vector3.UP * 2.2   # a ledge in the way: try stepping onto it
					if space.intersect_ray(PhysicsRayQueryParameters3D.create(body.position + chest, up_over + chest, 1)).is_empty():
						body.position = up_over
			var fy := _floor_under(body.position)
			if fy < -1e8:
				body.position = home                     # over the void: back to its den
			else:
				body.position.y = lerpf(body.position.y, fy + 0.5, clampf(delta * 6.0, 0.0, 1.0))
			if flat > 0.5:
				body.rotation.y = atan2(-to.x, -to.z)
		if nearest and nd < 2.6 and bite_cd <= 0.0 and retreat <= 0.0:
			bite_cd = 3.0
			retreat = 4.0
			bite_sounds()
			if nearest == Game.climber:
				bite_local()
			else:
				CoopSync.map_event("stalkbite_" + id, {"who": nearest.get("peer_id")}, false)

	func bite_local() -> void:
		var c = Game.climber
		if not is_instance_valid(c):
			return
		c.take_damage(45.0)
		var away: Vector3 = (c.global_position - body.position)
		away.y = 0.3
		c.additional_velocity_next_frame += away.normalized() * 16.0
		# the rope stays on, exactly like the base centipede bite: only the damage and the shove
		Game.audio.play_player_was_bit()

	func _update_segments(delta: float) -> void:
		trail.push_front(body.position)
		trail.pop_back()
		for i in segs.size():
			var k := mini(trail.size() - 1, (i + 1) * 3)
			var sg: Node3D = segs[i]
			sg.position = sg.position.lerp(trail[k], clampf(delta * 14.0, 0.0, 1.0))
			var ahead: Vector3 = trail[maxi(0, k - 3)]
			var dir := ahead - sg.position
			if dir.length() > 0.2:
				sg.rotation.y = atan2(-dir.x, -dir.z)

	func state_packet() -> Array:
		return [body.position.x, body.position.y, body.position.z, body.rotation.y]

	func remote_state(a: Array) -> void:
		rp_pos = Vector3(a[0], a[1], a[2])
		rp_yaw = float(a[3])


class Ambience extends Node3D:
	var sounds: Array = []
	var lo := 8.0
	var hi := 20.0
	var t := 0.0
	var player: AudioStreamPlayer3D
	var pos: Vector3

	func setup(a: Dictionary) -> void:
		pos = Vector3(a["pos"][0], a["pos"][1], a["pos"][2])
		sounds = a["sounds"]
		lo = float(a["min"])
		hi = float(a["max"])
		player = AudioStreamPlayer3D.new()
		player.volume_db = float(a.get("db", 0.0))
		player.max_distance = float(a.get("range", 30.0))
		player.bus = U.cave_bus()
		player.position = pos
		t = randf_range(lo, hi)

	func _ready() -> void:
		add_child(player)

	func _process(delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or (c.global_position - pos).length() > player.max_distance + 20.0:
			return
		t -= delta
		if t <= 0.0:
			t = randf_range(lo, hi)
			player.stream = load(sounds[randi() % sounds.size()])
			player.position = pos + Vector3(randf_range(-6, 6), randf_range(-2, 3), randf_range(-6, 6))
			player.play()


class DyingLights extends Node3D:
	# Torches along a tunnel that go out one by one as the player passes, and the
	# gravel sound of something following in the dark.
	var id := ""
	var trigger: Area3D
	var lights: Array = []
	var fires: Array = []
	var started := false
	var next := 0
	var t := 0.0

	func setup(d: Dictionary) -> void:
		id = str(d["id"])
		var tr: Array = d["trigger"]
		trigger = Area3D.new()
		trigger.collision_layer = 0
		trigger.collision_mask = 4
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = float(tr[1])
		cs.shape = sph
		trigger.add_child(cs)
		trigger.position = Vector3(tr[0][0], tr[0][1] + 1.0, tr[0][2])
		var ps: PackedScene = load(PYRELIGHT)
		for lp in d["lights"]:
			var p := Vector3(lp[0], lp[1], lp[2])
			var l := OmniLight3D.new()
			l.light_color = Color(1.0, 0.6, 0.3)
			l.light_energy = 1.1
			l.omni_range = 16.0
			l.shadow_enabled = false
			l.position = p + Vector3(0, 1.6, 0)
			add_child(l)
			lights.append(l)
			if ps:
				var f: Node3D = ps.instantiate()
				f.position = p
				f.scale = Vector3(0.3, 0.3, 0.3)
				add_child(f)
				fires.append(f)

	func _ready() -> void:
		add_child(trigger)
		trigger.body_entered.connect(func(b: Node3D):
			if b == Game.climber and not started:
				CoopSync.map_event("dying_" + id, {}))

	func begin(instant: bool = false) -> void:
		if started:
			return
		started = true
		if instant:
			# replayed: every light already out, no sound, no banner
			for l in lights:
				if is_instance_valid(l):
					l.light_energy = 0.0
			for f in fires:
				if is_instance_valid(f):
					f.visible = false
			next = lights.size()
			return
		t = 2.5
		Game.audio.play_dark_transition2()

	func _process(delta: float) -> void:
		if not started or next >= lights.size():
			return
		t -= delta
		if t > 0.0:
			return
		t = randf_range(2.0, 4.0)
		var l: OmniLight3D = lights[next]
		var tw := create_tween()
		tw.tween_property(l, "light_energy", 0.0, 0.6)
		if next < fires.size():
			fires[next].visible = false
		Game.audio.play_sfx_gravel_footstep()
		next += 1
		if next == lights.size():
			CoopSync.show_banner("The last light is out.", 3.0)


# ================================================================== music

class MusicDirector extends Node:
	# The game's own ambience only runs in the campaign scene, so a custom map is silent
	# without this. Three layers (drone, music, accent) cross-fade per biome, and the
	# finale pushes the Wasteland theme up. Streams restart themselves to loop.
	const WIND := "res://sfx/soundsnap/ambience/528557-WINDTonl-Ash_Meadows_At_Dawn_01-JATH-WDV-LOM_Mikro_Usi.wav"
	const A22 := "res://sfx/soundsnap/ambience/276358-22.wav"
	const A23 := "res://sfx/soundsnap/ambience/276359-23.wav"
	const D004 := "res://sfx/soundsnap/ambience/221904-Dark-SciFi-Drone-Mixed-004.wav"
	const D087 := "res://sfx/soundsnap/ambience/221989-Dark-SciFi-Drone-Mixed-087.wav"
	const DOOM := "res://sfx/soundsnap/ambience/1238574.audio-DSGNDron-SMorph-Doom_Drones_2_-Horror_Winds_Far_Whistle_01.wav"
	const ASHES := "res://sfx/Edited/Ashes_Text.wav"
	const WLONG := "res://sfx/music/Wasteland_LONG_LOOP_53BPM.wav"
	const WSHORT := "res://sfx/music/Wasteland_SHORT_LOOP_STRING53BPM.wav"
	# per biome: [drone, music, accent], each [path, linear volume] or null.
	# Volumes follow the campaign's own mix (drones ~0.05, wind ~1.5, theme 0.2).
	const SETS := [
		[[WIND, 1.4], null, null],
		[[A22, 0.05], null, [ASHES, 0.05]],
		[[A23, 0.05], [ASHES, 0.12], null],
		[[D004, 0.06], null, null],
		[[D087, 0.06], [WIND, 0.35], null],
		[[A22, 0.05], [ASHES, 0.14], null],
		[[A23, 0.05], [WSHORT, 0.09], null],
		[[DOOM, 0.07], null, null],
		[[DOOM, 0.08], [WLONG, 0.09], null],
		[[D004, 0.035], null, null],
	]
	var players: Array = []
	var target_path: Array = ["", "", ""]
	var target_vol: Array = [0.0, 0.0, 0.0]
	var current_path: Array = ["", "", ""]
	var boost := 1.0

	func _ready() -> void:
		process_mode = Node.PROCESS_MODE_ALWAYS
		for i in 3:
			var p := AudioStreamPlayer.new()
			p.bus = &"MainBus"
			p.volume_db = -80.0
			p.finished.connect(func(): if p.stream: p.play())
			add_child(p)
			players.append(p)

	func set_biome(b: int) -> void:
		if b < 0 or b >= SETS.size():
			return
		var set_: Array = SETS[b]
		for i in 3:
			if set_[i] == null:
				target_path[i] = ""
				target_vol[i] = 0.0
			else:
				target_path[i] = set_[i][0]
				target_vol[i] = float(set_[i][1])

	func finale() -> void:
		target_path[1] = WLONG
		target_vol[1] = 0.26
		target_vol[0] = 0.11
		boost = 1.0

	func _process(delta: float) -> void:
		for i in 3:
			var p: AudioStreamPlayer = players[i]
			var want_path: String = target_path[i]
			var want_vol: float = target_vol[i] * boost
			if current_path[i] != want_path:
				# fade out what is playing, then swap
				want_vol = 0.0
				if p.volume_linear < 0.006 or current_path[i] == "":
					current_path[i] = want_path
					p.stop()
					if want_path != "":
						p.stream = load(want_path)
					continue
			var nv: float = lerpf(p.volume_linear, maxf(want_vol, 0.001), clampf(delta * 0.6, 0.0, 1.0))
			p.volume_db = linear_to_db(nv)
			if nv >= 0.005 and not p.playing and p.stream:
				p.play()
			if nv < 0.005 and p.playing:
				p.stop()


class Flicker extends Node:
	var light: OmniLight3D
	var base := 1.0
	var t := 0.0

	func setup(l: OmniLight3D) -> void:
		light = l
		base = l.light_energy
		t = randf() * 10.0

	func _process(delta: float) -> void:
		if not is_instance_valid(light):
			return
		t += delta
		light.light_energy = base * (0.82 + 0.18 * sin(t * 9.1) + 0.1 * sin(t * 23.7))


class Bell extends Node3D:
	# An old miners' bell hung from the roof. Hit it with your hook and every centipede
	# in the map comes to the sound for 20 seconds instead of coming for you.
	var id := ""
	var bell: Node3D
	var pos: Vector3
	var sfx: AudioStreamPlayer3D
	var area: Area3D
	var cool := 0.0
	var swing := 0.0
	var lure_left := 0.0

	func setup(b: Dictionary, mat: Material) -> void:
		id = str(b["id"])
		pos = Vector3(b["pos"][0], b["pos"][1], b["pos"][2])
		var sc := float(b["scale"])
		var ps: PackedScene = load("res://Art/Ancient_Kiln.glb")
		bell = Node3D.new()
		if ps:
			var k: Node3D = ps.instantiate()
			for body in k.find_children("*", "StaticBody3D", true, false):
				body.queue_free()
			k.rotation = Vector3(PI, 0, 0)     # the kiln dome upside down reads as a bell
			k.scale = Vector3.ONE * sc * 0.42
			for mi in k.find_children("*", "GeometryInstance3D", true, false):
				(mi as GeometryInstance3D).material_override = mat
			bell.add_child(k)
		# clapper
		var cl := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = 0.35 * sc
		sm.height = 0.7 * sc
		cl.mesh = sm
		cl.material_override = mat
		cl.position = Vector3(0, -1.5 * sc, 0)
		bell.add_child(cl)
		bell.position = pos
		add_child(bell)
		# chain up to the roof
		var ch := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.12
		cm.bottom_radius = 0.12
		cm.height = maxf(0.5, float(b["ceiling"]) - pos.y)
		ch.mesh = cm
		ch.material_override = mat
		ch.position = Vector3(pos.x, (pos.y + float(b["ceiling"])) * 0.5, pos.z)
		add_child(ch)
		# hookable: the claw needs something solid with an upward face to land on
		var body2 := StaticBody3D.new()
		body2.collision_layer = 1
		var cs := CollisionShape3D.new()
		var cyl := CylinderShape3D.new()
		cyl.radius = 1.5 * sc
		cyl.height = 2.0 * sc
		cs.shape = cyl
		body2.add_child(cs)
		body2.position = pos
		add_child(body2)

	func _ready() -> void:
		sfx = U.sfx(SFX_METAL[1], 6.0, pos, self, 400.0)
		area = Area3D.new()
		area.collision_layer = 0
		area.collision_mask = 2 | 4     # the claw and players
		var cs := CollisionShape3D.new()
		var sph := SphereShape3D.new()
		sph.radius = 3.4
		cs.shape = sph
		area.add_child(cs)
		area.position = pos
		add_child(area)

	func _process(delta: float) -> void:
		cool = maxf(0.0, cool - delta)
		if swing > 0.0:
			swing -= delta
			var k: float = swing / 2.5
			bell.rotation.z = sin(swing * 11.0) * 0.32 * k
			bell.rotation.x = cos(swing * 9.0) * 0.22 * k
		if lure_left > 0.0:
			lure_left -= delta
			if CoopSync.map_is_authority():
				CoopSync.set_lure(bell, lure_left)
		if cool > 0.0:
			return
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		var hit := false
		if is_instance_valid(c.Rope._claw) and c.Rope._claw.visible:
			hit = (c.Rope._claw.global_position - pos).length() < 3.2
		if not hit and c.velocity.length() > 7.0 and (c.global_position - pos).length() < 3.4:
			hit = true
		if hit:
			cool = 6.0
			CoopSync.map_event("bell_" + id, {}, false)

	func toll() -> void:
		swing = 2.5
		# a second ring while the lure still runs only rings: it never stretches the lure
		if lure_left <= 0.0:
			lure_left = 20.0
		cool = 6.0
		sfx.play()
		Game.audio.play_dark_transition2()
		var map := get_parent()
		if map != null and bool(map.get("_idol_taken")):
			CoopSync.show_banner("The bell rings. What hunts the idol does not turn.", 5.0)
		else:
			CoopSync.show_banner("The bell rings. Everything hunting turns toward it.", 5.0)


class EggCluster extends Node3D:
	# A clutch of eggs against the Nest wall. They glow from inside and pulse, each cluster
	# on its own rhythm, faster when the local player is close. Nothing hatches. Yet.
	var mat: StandardMaterial3D
	var t := 0.0
	var rate := 1.0
	var near := false

	func setup(d: Dictionary) -> void:
		position = Vector3(d["pos"][0], d["pos"][1], d["pos"][2])
		var n := int(d.get("n", 6))
		var s := float(d.get("s", 0.8))
		t = randf() * 6.0
		rate = randf_range(0.7, 1.3)
		mat = StandardMaterial3D.new()
		mat.albedo_color = Color(0.05, 0.06, 0.035)
		mat.roughness = 0.8                       # glossy eggs caught the red lamps and clipped white
		mat.emission_enabled = true
		mat.emission = Color(0.12, 0.3, 0.06)
		mat.emission_energy_multiplier = 0.03
		var sm := SphereMesh.new()
		sm.radius = 0.5
		sm.height = 1.0
		sm.radial_segments = 10
		sm.rings = 6
		for i in n:
			var egg := MeshInstance3D.new()
			egg.mesh = sm
			egg.material_override = mat
			var r := randf_range(0.2, 0.34) * s
			var a := randf() * TAU
			var rr := randf_range(0.0, 0.55) * s
			egg.position = Vector3(cos(a) * rr, r * 0.9 + randf_range(0.0, 0.25) * s, sin(a) * rr)
			egg.scale = Vector3(r, r * randf_range(1.15, 1.4), r)
			egg.rotation = Vector3(randf_range(-0.3, 0.3), randf() * TAU, randf_range(-0.3, 0.3))
			egg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			egg.visibility_range_end = 110.0
			egg.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			add_child(egg)

	func _process(delta: float) -> void:
		if Engine.get_process_frames() % 15 == 0:
			var c = Game.climber
			near = is_instance_valid(c) and c.is_inside_tree() and (c.global_position - global_position).length() < 90.0
		if not near:
			return
		t += delta * rate
		var k: float = 0.5 + 0.5 * sin(t * 1.7)
		k = k * k
		mat.emission_energy_multiplier = 0.03 + 0.12 * k        # peak stays under the post clip


class BatSwarm extends Node3D:
	# A colony roosting under an overhang. When the local player comes near it bursts out,
	# wheels once around the balcony and is gone up the rift. Each player sees their own.
	var bats: Array = []
	var vel: Array = []
	var live := false
	var t := 0.0
	var trig := 15.0
	var n_bats := 14
	var mesh: ArrayMesh
	var mat: StandardMaterial3D

	func setup(d: Dictionary) -> void:
		position = Vector3(d["pos"][0], d["pos"][1], d["pos"][2])
		trig = float(d.get("r", 15.0))
		n_bats = int(d.get("n", 14))
		mat = StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(0.012, 0.01, 0.012)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.add_vertex(Vector3(0, 0, 0.08))
		st.add_vertex(Vector3(-0.3, 0.05, -0.1))
		st.add_vertex(Vector3(-0.1, 0, -0.08))
		st.add_vertex(Vector3(0, 0, 0.08))
		st.add_vertex(Vector3(0.1, 0, -0.08))
		st.add_vertex(Vector3(0.3, 0.05, -0.1))
		mesh = st.commit()

	func _process(delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		if not live:
			if Engine.get_process_frames() % 10 != 0:
				return
			if (c.global_position - global_position).length() < trig:
				_burst()
			return
		t += delta
		for i in bats.size():
			var b: MeshInstance3D = bats[i]
			var v: Vector3 = vel[i]
			var to_home: Vector3 = global_position - b.global_position
			to_home.y = 0.0
			var wheel := Vector3(-to_home.z, 0.0, to_home.x).normalized() * 6.5
			var up := Vector3(0, clampf(t - 2.2, 0.0, 1.0) * 8.0, 0)
			var want: Vector3 = wheel + to_home.normalized() * 1.5 + up + Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * 5.0
			v = v.lerp(want, delta * 3.0)
			vel[i] = v
			b.global_position += v * delta
			var flat := Vector3(v.x, 0.0, v.z)
			if flat.length() > 0.2:
				b.look_at(b.global_position + flat.normalized() * 2.0, Vector3.UP)
			b.scale = Vector3(1.0 + 0.55 * sin(t * 27.0 + i * 1.7), 1.0, 1.0)
		if t > 7.5:
			queue_free()

	func _burst() -> void:
		live = true
		for i in n_bats:
			var b := MeshInstance3D.new()
			b.mesh = mesh
			b.material_override = mat
			b.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			b.position = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * 2.0
			add_child(b)
			bats.append(b)
			vel.append(Vector3(randf() - 0.5, randf() * 0.4, randf() - 0.5) * 9.0)
		# the colony leaving the rock: a scatter of grit and a dry chittering of claws
		var grit := U.sfx("res://sfx/soundsnap/41281-FOLEY_FOOTSTEPS_BOOTS_SLIDE_GRAVEL_SCATTER_01.wav", -2.0, Vector3.ZERO, self, 30.0)
		grit.pitch_scale = 1.35
		grit.play()
		for k in 5:
			var cl := U.sfx(U.CLICKS[randi() % U.CLICKS.size()], -6.0, Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5) * 3.0, self, 28.0)
			cl.pitch_scale = randf_range(1.6, 2.2)
			get_tree().create_timer(0.08 + k * randf_range(0.07, 0.16)).timeout.connect(cl.play)


class Ghost extends Node3D:
	# One of the climbers who came before. Stands where the way continues, watching it.
	# Fades when the local player comes close; each player sees their own.
	const WHISPERS := ["res://sfx/soundsnap/1022742.audio-HUMAN_VOCAL_Female_4_Breath_Medium_01.wav",
			"res://sfx/soundsnap/463323-HUMAN_BREATH_Female-Deep_Opened_Mouth_Normal_Speed_Breath-B.wav"]
	var body: Node3D
	var mat: StandardMaterial3D
	var fading := false
	var t := 0.0
	var base_a := 0.3

	func setup(ps: PackedScene, base: StandardMaterial3D, pos: Vector3, yaw: float) -> void:
		body = ps.instantiate()
		mat = base.duplicate()
		base_a = base.albedo_color.a
		for mi in body.find_children("*", "GeometryInstance3D", true, false):
			(mi as GeometryInstance3D).material_override = mat
			(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			(mi as GeometryInstance3D).visibility_range_end = 70.0
		position = pos
		rotation.y = yaw
		add_child(body)
		t = randf() * 6.0

	func _process(delta: float) -> void:
		t += delta
		if fading:
			mat.albedo_color.a = maxf(0.0, mat.albedo_color.a - delta * 0.3)
			body.position.y += delta * 0.25
			if mat.albedo_color.a <= 0.0:
				queue_free()
			return
		body.position.y = sin(t * 0.8) * 0.04
		var c = Game.climber
		if is_instance_valid(c) and c.is_inside_tree():
			# thinner the closer you get: seen from afar it is a figure, from close up almost nothing
			var dd: float = (c.global_position - global_position).length()
			mat.albedo_color.a = base_a * clampf((dd - 2.5) / 12.0, 0.1, 1.0)
		if is_instance_valid(c) and c.is_inside_tree() and (c.global_position - global_position).length() < 10.0:
			fading = true
			var p := U.sfx(WHISPERS[randi() % WHISPERS.size()], -8.0, Vector3(0, 1.5, 0), self, 22.0)
			p.play()


# ================================================================== the rift's furniture

class HangingPlatform extends Node3D:
	# A deck hung on chains over the void (village floors, foundry gantries, rests on the
	# Crucible). Some are rigged: stand on one too long and its chains let go, for everyone.
	var id := ""
	var deck: MeshInstance3D
	var body: StaticBody3D
	var rigged := false
	var gone := false
	var stand := 0.0
	var top: Vector3
	var half: Vector3
	var sfx: AudioStreamPlayer3D
	var chains: Array = []

	func setup(d: Dictionary, mat: Material, chain_mat: Material) -> void:
		id = str(d["id"])
		rigged = bool(d.get("drop", false))
		top = Vector3(d["pos"][0], d["pos"][1], d["pos"][2])
		var sz := Vector3(d["size"][0], d["size"][1], d["size"][2])
		half = sz * 0.5
		deck = MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = sz
		deck.mesh = bm
		deck.material_override = mat
		deck.position = top - Vector3(0, sz.y * 0.5, 0)
		deck.rotation.y = float(d.get("yaw", 0.0))
		body = StaticBody3D.new()
		body.collision_layer = 1
		body.physics_material_override = load("res://physics_materials/stone.tres")
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = sz
		cs.shape = bs
		body.add_child(cs)
		deck.add_child(body)
		add_child(deck)
		var clen := float(d.get("chain", 0.0))
		if clen > 0.0:
			for cx in [-1.0, 1.0]:
				for cz in [-1.0, 1.0]:
					var ch := MeshInstance3D.new()
					var cm := CylinderMesh.new()
					cm.top_radius = 0.08
					cm.bottom_radius = 0.08
					cm.height = clen
					cm.radial_segments = 5
					ch.mesh = cm
					ch.material_override = chain_mat
					ch.position = Vector3(cx * (half.x - 0.4), clen * 0.5 + sz.y * 0.5, cz * (half.z - 0.4))
					deck.add_child(ch)
					chains.append(ch)

	func _ready() -> void:
		if rigged:
			sfx = U.sfx(SFX_RUMBLE, 2.0, top, self, 55.0)

	func _process(delta: float) -> void:
		if not rigged or gone:
			return
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		var q: Vector3 = c.global_position - top
		if c.is_on_floor() and absf(q.x) < half.x + 0.5 and absf(q.z) < half.z + 0.5 and q.y > -0.5 and q.y < 2.5:
			stand += delta
			if stand > 1.4:
				CoopSync.map_event("pfdrop_" + id, {})
		else:
			stand = maxf(0.0, stand - delta)

	func drop_now(instant: bool = false) -> void:
		if gone:
			return
		gone = true
		if instant:
			# replayed: the deck already fell
			body.collision_layer = 0
			deck.visible = false
			for ch in chains:
				ch.visible = false
			return
		if sfx:
			sfx.play()
		Game.audio.play_rope_snap_sfx()
		var start := deck.position
		var tw := create_tween()
		for i in 10:
			tw.tween_property(deck, "position", start + Vector3(randf_range(-0.15, 0.15), -0.04 * i, randf_range(-0.15, 0.15)), 0.09)
		tw.tween_property(deck, "position:y", start.y - 260.0, 4.0).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
		tw.parallel().tween_property(deck, "rotation:z", 0.9, 4.0)
		tw.tween_callback(func(): body.collision_layer = 0; deck.visible = false)
		for ch in chains:
			ch.visible = false
		var c = Game.climber
		if is_instance_valid(c) and c.activeClimberState is ClimberState_Attached and is_instance_valid(c.Rope._claw):
			if (c.Rope._claw.global_position - top).length() < half.length() + 2.0:
				c.set_climber_state(c.defaultClimberState)


class CrystalSpar extends Node3D:
	# A crystal grown clean across the rift: a six-sided prism with a flat top face, slick
	# as glass. Step on and you slide where it goes.
	var a: Vector3
	var b: Vector3
	var r := 7.0
	var down: Vector3
	var t_axis: Vector3
	var length := 0.0
	var dot_tex: Texture2D

	static func _h(i: int, k: int) -> float:
		# deterministic 0..1 noise: every player must grow the same crystal
		return fposmod(sin(float(i) * 12.9898 + float(k) * 78.233) * 43758.5453, 1.0)

	func _tri(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, outward: Vector3, col: Color) -> void:
		var nrm := (p1 - p0).cross(p2 - p0).normalized()
		if nrm.dot(outward) < 0.0:
			nrm = -nrm
		for q in [p0, p1, p2]:
			st.set_color(col)
			st.set_normal(nrm)
			st.add_vertex(q)

	func setup(pa: Vector3, pb: Vector3, radius: float) -> void:
		a = pa
		b = pb
		r = radius
		length = (b - a).length()
		t_axis = (b - a) / length
		var u := Vector3.UP.cross(t_axis).normalized()
		var v := t_axis.cross(u).normalized()       # the deck normal, mostly up
		down = t_axis if t_axis.y < 0.0 else -t_axis
		var half_h := r * 0.866
		var n := maxi(10, int(length / 7.0))
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		# rings along the crystal. The two vertices of the flat top face stay exactly where they were
		# (the collision box is that face); every other vertex wanders, so the sides are irregular,
		# faceted and pinched toward the tips.
		var rings: Array = []
		for i in n + 1:
			var f := float(i) / float(n)
			var centre := a + t_axis * length * f
			var e := minf(f, 1.0 - f) * length
			var taper := clampf(0.42 + e / 9.0, 0.42, 1.0)
			var ring: Array = []
			for k in 6:
				var ang := deg_to_rad(60.0 * k)
				var off := u * cos(ang) * r + v * sin(ang) * r
				if k != 1 and k != 2:
					off *= (1.0 + 0.2 * (_h(i, k) - 0.5) * 2.0) * taper
				ring.append(centre + off - v * half_h)
			rings.append(ring)
		for i in n:
			var band := 0.7 + 0.6 * _h(i / 2, 7)
			for k in 6:
				var k1 := (k + 1) % 6
				var mid := deg_to_rad(60.0 * k + 30.0)
				var outward := u * cos(mid) + v * sin(mid)
				var col := Color(0.12, 0.24, 0.42) * (band * (0.8 + 0.4 * _h(i, k + 20)))
				if k == 1:
					col = Color(0.2, 0.3, 0.42) * (0.85 + 0.3 * _h(i, 30))      # the worn deck
				col.a = 1.0
				var p00: Vector3 = rings[i][k]
				var p01: Vector3 = rings[i][k1]
				var p10: Vector3 = rings[i + 1][k]
				var p11: Vector3 = rings[i + 1][k1]
				_tri(st, p00, p01, p11, outward, col)
				_tri(st, p00, p11, p10, outward, col)
		for end_i in [0, n]:                          # close the ends
			var c0: Vector3 = a if end_i == 0 else b
			c0 -= v * half_h
			for k in 6:
				_tri(st, c0, rings[end_i][k], rings[end_i][(k + 1) % 6], (-t_axis if end_i == 0 else t_axis), Color(0.1, 0.2, 0.36))
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		# under the post clip (linear ~0.064 is white): the per-face vertex colours set the tone, the
		# glow is a faint cold rim (blue ~0.03 linear), and a rougher glass keeps specular hot spots
		# from flattening the faces to white
		m.albedo_color = Color(1.0, 1.0, 1.0)
		m.roughness = 0.6
		m.emission_enabled = true
		m.emission = Color(0.1, 0.21, 0.42)
		m.emission_energy_multiplier = 0.22
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		var mi := MeshInstance3D.new()
		mi.mesh = st.commit()
		mi.material_override = m
		mi.visibility_range_end = 420.0
		add_child(mi)
		# crystals grown out of the sides and hanging from the underside. Never on the deck.
		var sp := SurfaceTool.new()
		sp.begin(Mesh.PRIMITIVE_TRIANGLES)
		var tips: Array = []
		var count := int(length / 5.0)
		for s in count:
			var f2 := (float(s) + 0.5) / float(count) + (_h(s, 91) - 0.5) * 0.06
			var base_t := a + t_axis * length * clampf(f2, 0.03, 0.97)
			for c in 2 + int(_h(s, 92) * 2.0):
				var th := deg_to_rad(150.0 + _h(s * 7 + c, 93) * 240.0)
				var outdir := u * cos(th) + v * sin(th)
				var under := clampf(-sin(th), 0.0, 1.0)
				var ln := lerpf(2.2, 5.5, _h(s, c + 94)) + under * lerpf(2.0, 8.5, _h(s + 3, c + 95))
				var rb := ln * lerpf(0.13, 0.22, _h(s, c + 96))
				var dir := (outdir + t_axis * (_h(s, c + 97) - 0.5) * 0.9 + Vector3.DOWN * 0.35 * under).normalized()
				var base := base_t - v * half_h + outdir * r * 0.9
				var q1 := dir.cross(t_axis).normalized()
				if q1.length_squared() < 0.01:
					q1 = dir.cross(u).normalized()
				var q2 := dir.cross(q1).normalized()
				var apex := base + dir * ln
				var col2 := Color(0.16, 0.3, 0.5) * (0.8 + 0.4 * _h(s, c + 98))
				col2.a = 1.0
				for k in 6:
					var pa0 := base + (q1 * cos(TAU * k / 6.0) + q2 * sin(TAU * k / 6.0)) * rb
					var pa1 := base + (q1 * cos(TAU * (k + 1) / 6.0) + q2 * sin(TAU * (k + 1) / 6.0)) * rb
					_tri(sp, pa0, pa1, apex, (pa0 + pa1) * 0.5 - base, col2)
				if (s + c) % 4 == 0:
					tips.append(apex)
		var mi2 := MeshInstance3D.new()
		mi2.mesh = sp.commit()
		mi2.material_override = m
		mi2.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi2.visibility_range_end = 300.0
		add_child(mi2)
		# a faint glint at some of the tips, so the crystal reads from across the rift
		if dot_tex != null:
			var gm := StandardMaterial3D.new()
			gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			gm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
			gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			gm.albedo_texture = dot_tex
			gm.albedo_color = Color(0.07, 0.13, 0.26, 0.85)        # centre just under the clip (blue ~0.055 linear)
			gm.disable_fog = true
			var qm := QuadMesh.new()
			qm.size = Vector2(1.6, 1.6)
			for tp in tips:
				var g := MeshInstance3D.new()
				g.mesh = qm
				g.material_override = gm
				g.position = tp
				g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				g.visibility_range_end = 260.0
				add_child(g)
		# collision: a box whose top is the prism's top face (the deck line a-b)
		var body := StaticBody3D.new()
		body.collision_layer = 1
		var cs := CollisionShape3D.new()
		var bs := BoxShape3D.new()
		bs.size = Vector3(r, half_h * 2.0, length)
		cs.shape = bs
		body.add_child(cs)
		body.transform = Transform3D(Basis(u, v, t_axis), (a + b) * 0.5 - v * half_h)
		add_child(body)

	func _physics_process(_delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree() or not c.is_on_floor():
			return
		var q: Vector3 = c.global_position - a
		var along := q.dot(t_axis)
		if along < 6.0 or along > length - 14.0:
			return
		var off := q - t_axis * along
		if off.length() < r * 0.9 + 1.2:
			c.additional_velocity_next_frame += down * 0.085     # glass: you go where it goes


class Waterfall extends Node3D:
	# Water pouring out of the wall into nothing. It shoves you toward the edge.
	var top: Vector3
	var height := 30.0
	var push: Vector3

	func setup(p: Vector3, h: float, shove: Vector3) -> void:
		top = p
		height = h
		push = shove

	func _ready() -> void:
		var ps := CPUParticles3D.new()
		ps.amount = 90
		ps.lifetime = 2.2
		ps.local_coords = false
		ps.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
		ps.emission_box_extents = Vector3(2.2, 0.3, 2.2)
		ps.direction = Vector3.DOWN
		ps.spread = 6.0
		ps.gravity = Vector3(0, -14.0, 0)
		ps.initial_velocity_min = 3.0
		ps.initial_velocity_max = 6.0
		ps.scale_amount_min = 0.7
		ps.scale_amount_max = 1.5
		var quad := QuadMesh.new()
		quad.size = Vector2(0.9, 3.2)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color = Color(0.09, 0.12, 0.13, 0.22)
		m.albedo_texture = get_parent()._soft_dot()
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		quad.material = m
		ps.mesh = quad
		ps.position = top
		ps.visibility_range_end = 200.0
		add_child(ps)
		var snd := U.sfx(SFX_WIND, -6.0, top - Vector3(0, height * 0.8, 0), self, 50.0)
		snd.finished.connect(func(): snd.play())
		snd.play()

	func _physics_process(_delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		var q: Vector3 = c.global_position - top
		if q.y < 2.0 and q.y > -height and Vector2(q.x, q.z).length() < 3.6:
			c.additional_velocity_next_frame += push * 0.012

