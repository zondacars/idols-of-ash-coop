extends Node

const MOD_DIR := "res://mods-unpacked/zonda-CoopSync/"
# v4.8: the tag changed from "ZondaCoopSync1" so zips older than 4.8 (which have no version
# check) can never find a 4.8 lobby. From 4.8 on, the "coop_ver" lobby data does the gating.
const LOBBY_TAG := "ZondaCoopSync2"
const LOBBY_TAG_OLD := "ZondaCoopSync1"
const MOD_VERSION := "5.1"
const MAX_MEMBERS := 4
const SYNC_HZ := 60.0
const CH_FAST := 0
const CH_EVENT := 1
const CH_VOICE := 2                  # v4.9 voice chat: unreliable, its own channel
const STALE_MS := 6000
const SEND_UNRELIABLE_NO_NAGLE := 1

const RemotePlayerScript := preload("res://mods-unpacked/zonda-CoopSync/remote_player.gd")
const LobbyUiScript := preload("res://mods-unpacked/zonda-CoopSync/lobby_ui.gd")

const EXTENSIONS := [
	["res://scripts/climber.gd", "ext/climber.gd"],
	# v5.0 no-clip (creature no-clip spec A5): column and width rules, Rule N normals, safe targets;
	# every change is gated on the no-clip helper being on (THE UNDERDARK), elsewhere the base runs
	["res://scripts/centipede_3d_pathfinder.gd", "ext/centipede_3d_pathfinder.gd"],
	["res://scripts/centipede.gd", "ext/centipede.gd"],
	["res://scripts/ending_trigger_area.gd", "ext/ending_trigger_area.gd"],
	["res://scripts/lore_point.gd", "ext/lore_point.gd"],
	["res://scenes/sandbox_map_option.gd", "ext/sandbox_map_option.gd"],
]

const MOD_MAPS := [
	["INFERNO", "res://mods-unpacked/zonda-CoopSync/maps/inferno.tscn"],
	["THE UNDERDARK", "res://mods-unpacked/zonda-CoopSync/maps/underdark/underdark.tscn"],
]

var local_name := "Player"
var is_host := false
var lobby_ui: Node = null

var _lobby_id: int = 0
var _my_steam_id: int = 0
var _host_steam_id: int = 0
var _password := ""
var _peers: Dictionary = {}
var _peer_names: Dictionary = {}
var _puppets: Array = []

var _local_player: Node = null
var _local_player_age := 0.0
var _sync_accum := 0.0
var _scan_accum := 0.0

var _level_seq := 0
var _applied_level_seq := -1
var _pending_level: Dictionary = {}
var _last_scene_instance_id := 0
var _last_scene_path := ""
var _prev_scene_path := ""
var _await_spawn_sync := false
var _last_unhook_ms: Dictionary = {}
var _welcome_queue: Array = []

var respawns_left := 1
var _maps_unlocked := false
var perf_mod_usec_frame := 0
var perf_mod_usec_avg := 0.0
var _perf_extra_usec := 0
var _banner_layer: CanvasLayer = null
var _banner_label: Label = null
var _banner_until_ms := 0

# Custom map support: events every player applies (traps, puzzles, pickups), the team's
# furthest checkpoint, and a few per-map display toggles. Survives death reloads of the
# same map, cleared on the main menu.
var map_state := {"scene": "", "checkpoint": -1, "events": {}}
# a map turns this on in its _ready, a frame before _track_scene_changes sees the new scene,
# so the flag remembers which scene set it and only a flag from another scene is cleared
var nametags_through_walls := false:
	set(value):
		nametags_through_walls = value
		_ntw_scene = _scene_now() if value else ""
var _ntw_scene := ""
const UNDERDARK_DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
# the build every player must share: mod version + game version + the Underdark layout hash
var build_id := MOD_VERSION
# the local player took the idol (a map sets this); teammates see the idol in the knight's hand
var idol_carrier := false:
	set(value):
		idol_carrier = value
		_idol_scene = _scene_now() if value else ""
var _idol_scene := ""
var _join_stage := 0                 # 1 = searching my build, 2 = looking for a lobby on another build
var _mapsync_scene := ""             # guest: mapsync asked for this scene, no reply yet
var _mapsync_next_ms := 0
var _mapsync_tries := 0
var _mev_root_id := 0                # cached arity of the current map's coop_map_event
var _mev_argc := 2
var gfx: Node = null
var lantern: Node = null         # the hand lantern, every level (lantern.gd)
var voice: Node = null           # voice chat capture + settings (voice.gd), v4.9
var mic_menu: Node = null        # the voice microphone picker (mic_menu.gd): pause menu + F2 panel, v4.9.1

# ---- v5.0 shared state (build contract 2.1). Other files reach these through get()/has_method().
var light_field = null            # the map's LightField node (maps/underdark/light.gd), or null
var hunt_pins: Dictionary = {}    # pin name -> Node3D; a centipede with meta "zonda_hunt_pin" hunts only that player
var idol_holder_sid := ""         # the idol module writes it every 0.25 s ("" = nobody)
var idol_weight := 0              # 0..98, the holder's own PC only (streamed in "idl")
var loop_ghost_weight := 0        # loopback tests: the Ghost's streamed idol weight
var omen_file := RELIC_FILE       # the file every trophy AND relic write goes to; tests point it elsewhere
var omen_tier := 0                # 0..4, the best omen trophy tier over every map ([omen] section)
# v5.1 NOISE (sound-aware creatures: the sidewinder, the stalkers, the bat colonies). How loud MY
# voice is, measured from what this PC actually sends (so F7 mute, a closed mic or push-to-talk
# let go are silence): 0 silent, 1 whisper, 2 talking, 3 shouting. Streamed in "nz"; a teammate's
# is remote_player.noise_tier. noise_of(node) reads either.
var noise_tier := 0
var noise_db := -90.0
var noise_force := -1                     # tests: -1 real; 0..3 a fixed tier for everyone; 9 = heard from anywhere
var _noise_hold := 0.0
const NOISE_DB := [-52.0, -38.0, -24.0]      # RMS dBFS at or over these: whisper, talking, shouting
const NOISE_R := [0.0, 5.0, 12.0, 30.0]     # how far a sound-aware creature hears each tier (m)
var save_run: Node = null         # saved runs: file format, writes, players table (save_run.gd)
var save_prompt: Node = null      # the CONTINUE / NEW RUN panel and the guests' hold panel (save_prompt.gd)
var test_files := false           # use_test_files() ran in this launch
var continue_load := false        # a SAVE continue is reloading the map: no relight top-up; cleared by map_loaded
var guestsim := ""                # "", "record" or "play" (guestsim.flag, developer only)
var map_loads := 0                # map_loaded calls this launch (tests wait on it)
var last_map_loaded: Dictionary = {}   # {"scene", "fresh", "ms"} of the last map_loaded call
var _my_sid_cache := ""
var _oilrep_t := 0.0              # guest: the next oil report check (every 3 s)
var _oilrep_last := -1.0          # guest: the oil level last reported (-1 = report on the next check)
var _oilrep_taken := -1
var _oilrep_due := false          # guest: report at the next frame (a checkpoint)
var _oilrep_hold_ms := 0          # guest: after the host's CONTINUE, wait for "oilset" before reporting
var _cont_guest := false          # guest: continue_load waits for the reload the host's restart "level" causes
var _cont_level_seq := -1         # guest: _applied_level_seq when the continue release arrived
var _cont_level_root := -1        # guest: the scene instance current when that restart began loading (-1 = not yet)
var _cont_until_ms := 0           # guest: continue_load never outlives this (a restart that never came)
var _hold_keepalive_t := 0.0      # host: the saved-run hold is re-sent every 4 s while the panel is open

# ---- voice chat transport (v4.9). Capture is polled every 40 ms while in a session; each
# non-empty chunk goes out unreliable on CH_VOICE as {"t": "v", "from", "q": seq, "d": bytes}.
# A talker's voice data is capped at 10,000 bytes/s = 80 kbps (plus ~100 bytes of packet header
# per chunk); chunks over the cap are dropped, never queued, so a voice can glitch but never lag
# behind. Drops are printed to the log ("voice over the 80 kbps cap"). Steam does not publish its
# voice bitrate (Opus speech is usually well under 32 kbps). A microphone picked in the pause menu
# or the F2 panel (v4.9.1) goes out as the mod's own "ZVA1" IMA ADPCM at 16 kHz instead (voice.gd):
# about 8,250 bytes/s with its headers, which is why the cap went from 8,000 to 10,000 in v4.9.1.
# The real rate is logged every 10 s of talking ("voice tx ... bytes/s"): the cap is only a
# safety net against a runaway stream.
const VOICE_POLL_S := 0.04
const VOICE_BYTES_PER_S := 10000.0
const VOICE_BURST := 6000.0
var _voice_accum := 0.0
var _voice_seq := 0
var _voice_bucket := VOICE_BURST
var _voice_dropped := 0
var _voice_tx_bytes := 0             # measured voice rate, logged every 10 s of talking
var _voice_tx_t := 0.0
var _voice_seq_in: Dictionary = {}   # peer id -> last voice seq played
# incoming "ZVA1" (decoded in GDScript) is budgeted per 1 s window: a real talker delivers about
# 1 s of audio per second (a little more after a network hitch), so 1.5 s only stops a flood
const VOICE_IN_MAX_S := 1.5
var _voice_in_ms := -100000          # start of the current budget window
var _voice_in_s: Dictionary = {}     # peer id -> seconds of "ZVA1" audio decoded in this window (0 = everyone)
var _voice_in_dropped := 0
# a peer with no knight in this scene (main menu, loading, another level) is heard flat
var _flat_voice: Dictionary = {}     # peer id -> {"p": AudioStreamPlayer, "pb": playback, "ms": last push}

# ---- developer loopback: every packet you send comes back 0.7 s later as a "Ghost" peer
const LOOP_ID := 777
const LOOP_GHOST_AT_HAND_M := 2.5    # while an idol is in play the Ghost stands this far ahead (not 3.5 m)
var _loopback := false
var _loop_queue: Array = []
var _loop_t := -1.0
var _loop_step := 0
var _loop_pending := false

# ---- v5.0 creature no-clip, test plumbing (creature no-clip spec 3.B B5, B7, B8). All of it is
# developer-only: the noclip probe (maps/underdark/noclip_probe.gd) sets these and restores them.
# B5 shadows: the host's own "c" stream, looped back, drives SHADOW puppets on the host (the guests'
# interpolation, bite distance and head clearance code), with loss, jitter and reordering. A shadow
# never damages, shoves or sounds (ext/centipede.gd), and nothing targets or streams it.
var noclip_shadows := false          # mirror the host's own "c" stream into shadow puppets
var noclip_shadow_loss := 0.0        # fraction of "c" messages the shadows drop
var noclip_shadow_jitter_ms := 0     # each kept message waits an extra random 0..jitter ms
var noclip_shadow_late := 0.0        # fraction of kept messages delayed a further 80..150 ms (they arrive after newer ones)
var _shadow_q: Array = []            # [deliver_ms, seq, msg]
var _shadow_seq := 0
var _shadow_by_cid: Dictionary = {}  # cid -> shadow puppet
var _shadow_seen_ms: Dictionary = {} # cid -> last update (ms)
const SHADOW_HIDE_MS := 2000
# B7: the loopback Ghost (often standing inside the wall you look at) is no creature's target
var noclip_no_ghost := false
# B8: jitter and loss for the guest simulation's "maps" entries (guestsim play)
var noclip_gs_loss := 0.0
var noclip_gs_jitter_ms := 0
var noclip_gs_late := 0.0
var _gs_pend: Array = []             # [deliver_ms, seq, entry]
var _gs_pend_seq := 0


func _init() -> void:
	_install_extensions()


func _install_extensions() -> void:
	for pair in EXTENSIONS:
		var ext: Script = load(MOD_DIR + pair[1])
		if ext == null:
			push_error("[CoopSync] could not load extension %s" % pair[1])
			continue
		ext.take_over_path(pair[0])
		print("[CoopSync] extended ", pair[0])


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Steam.lobby_created.connect(_on_lobby_created)
	Steam.lobby_joined.connect(_on_lobby_joined)
	Steam.lobby_match_list.connect(_on_lobby_match_list)
	Steam.lobby_chat_update.connect(_on_lobby_chat_update)
	Steam.network_messages_session_request.connect(_on_session_request)
	get_tree().node_added.connect(_on_node_added)
	get_tree().node_removed.connect(_on_node_removed)
	lobby_ui = LobbyUiScript.new()
	get_tree().root.call_deferred("add_child", lobby_ui)
	gfx = load(MOD_DIR + "gfx.gd").new()
	add_child(gfx)
	lantern = load(MOD_DIR + "lantern.gd").new()
	add_child(lantern)
	var vs = load(MOD_DIR + "voice.gd")
	if vs is Script:
		voice = vs.new()
		add_child(voice)
	else:
		push_error("[CoopSync] could not load voice.gd, voice chat is off")
	# the microphone picker (pause menu + F2 panel, v4.9.1); it drives `voice`, so only with voice
	if voice != null:
		var mm = load(MOD_DIR + "mic_menu.gd")
		if mm is Script and mm.can_instantiate():
			mic_menu = mm.new()
			add_child(mic_menu)
		else:
			push_error("[CoopSync] could not load mic_menu.gd, the microphone picker is off")
	# saved runs (v5.0): loaded like voice.gd, so a broken file only turns the feature off
	var srs = load(MOD_DIR + "save_run.gd")
	if srs is Script and srs.can_instantiate():
		save_run = srs.new()
		save_run.name = "SaveRun"
		add_child(save_run)
	else:
		push_error("[CoopSync] could not load save_run.gd, saved runs are off")
	var sps = load(MOD_DIR + "save_prompt.gd")
	if sps is Script and sps.can_instantiate():
		save_prompt = sps.new()
		save_prompt.name = "SavePrompt"
		add_child(save_prompt)
	else:
		push_error("[CoopSync] could not load save_prompt.gd, the saved-run panel is off")
	if FileAccess.file_exists(MOD_DIR + "loopback.flag"):
		DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/loopback.flag")
		_loop_pending = true                # Steam is not up yet at _ready: start on the first ticking frame
	if FileAccess.file_exists(MOD_DIR + "guestsim.flag"):
		# developer only (build contract 2.11): "record" a loopback host test, or "play" it back as a guest
		var gs := FileAccess.get_file_as_string(MOD_DIR + "guestsim.flag").strip_edges().to_lower()
		DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/guestsim.flag")
		if gs == "record" or gs == "play":
			guestsim = gs
			print("[GUESTSIM] mode %s" % gs)
	_load_relics()
	_load_omen()
	build_id = _compute_build_id()
	print("[CoopSync] build ", build_id)
	if FileAccess.file_exists(MOD_DIR + "probe.flag") and FileAccess.file_exists(MOD_DIR + "debug_probe.gd"):
		add_child(load(MOD_DIR + "debug_probe.gd").new())   # developer measuring tool, not shipped
	_build_banner()
	print("[CoopSync] ready")


func _compute_build_id() -> String:
	# "4.8 g1.41 m1a2b3c": the map hash changes by itself whenever the generator rebuilds the
	# Underdark, so two zips that differ there never end up in the same lobby.
	var s := MOD_VERSION
	var gv := str(ProjectSettings.get_setting("application/config/version", ""))
	if not gv.is_empty():
		s += " g" + gv
	var lp := MOD_DIR + "maps/underdark/layout.json"
	if FileAccess.file_exists(lp):
		var md5 := FileAccess.get_md5(lp)
		if md5.length() >= 6:
			s += " m" + md5.substr(0, 6)
	return s


func _build_banner() -> void:
	_banner_layer = CanvasLayer.new()
	_banner_layer.layer = 90
	_banner_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	_banner_label = Label.new()
	_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner_label.anchor_left = 0.0
	_banner_label.anchor_right = 1.0
	_banner_label.anchor_top = 0.0
	_banner_label.anchor_bottom = 0.0
	_banner_label.offset_top = 30.0
	_banner_label.offset_bottom = 60.0
	var ls := LabelSettings.new()
	ls.font_size = 14
	ls.outline_size = 4
	ls.outline_color = Color.BLACK
	ls.font_color = Color(1.0, 0.92, 0.75)
	_banner_label.label_settings = ls
	_banner_label.visible = false
	_banner_layer.add_child(_banner_label)
	get_tree().root.call_deferred("add_child", _banner_layer)


func show_banner(text: String, seconds: float) -> void:
	if _banner_label == null:
		return
	_banner_label.text = text
	_banner_label.visible = true
	_banner_until_ms = Time.get_ticks_msec() + int(seconds * 1000.0)


func perf_add(usec: int) -> void:
	_perf_extra_usec += usec


func _process(delta: float) -> void:
	_try_unlock_all_maps()
	# scene tracking runs without Steam too, so solo map events and checkpoints always
	# know which scene they belong to
	_track_scene_changes()
	if guestsim != "":
		_guestsim_tick(delta)
	if not Game.is_steam_enabled():
		return
	var t0 := Time.get_ticks_usec()
	_process_inner(delta)
	perf_mod_usec_frame = (Time.get_ticks_usec() - t0) + _perf_extra_usec
	_perf_extra_usec = 0
	perf_mod_usec_avg = lerpf(perf_mod_usec_avg, float(perf_mod_usec_frame), 0.05)


func perf_text() -> String:
	var fps := Engine.get_frames_per_second()
	var frame_ms := 1000.0 / maxf(fps, 1.0)
	var g: String = gfx.perf_label() if gfx else "?"
	return "FPS %d  |  frame %.1f ms  |  mod %.2f ms  |  gfx %s (F4)" % [fps, frame_ms, perf_mod_usec_avg / 1000.0, g]


func _try_unlock_all_maps() -> void:
	if _maps_unlocked:
		return
	if SandboxDataManager == null or SandboxDataManager.loaded_data == null:
		return
	_maps_unlocked = true
	# review #106: the mod maps live in memory only. Entries an older build saved to
	# sandbox_data.tres are taken out once, so an uninstall never leaves dead map entries.
	var md: Array = SandboxDataManager.loaded_data.unlocked_map_data
	var stripped := 0
	for i in range(md.size() - 1, -1, -1):
		var entry = md[i]
		if entry != null and str(entry.scene_path).begins_with("res://mods-unpacked/"):
			md.remove_at(i)
			stripped += 1
	if stripped > 0:
		SandboxDataManager.save()
		print("[CoopSync] removed %d saved mod map entries from sandbox data" % stripped)
	# Unlock the maps themselves without touching campaign progress, so no
	# Steam achievements fire for difficulties that were never actually beaten.
	SandboxDataManager.safe_unlock_map_of_type("CAMPAIGN (INVERTED)", "res://scenes/FogLands_Invert.tscn", SandboxData.EDifficultyLevel.Nightmare)
	SandboxDataManager.safe_unlock_map_of_type("FIRST KILN", "res://scenes/ViperPit.tscn", SandboxData.EDifficultyLevel.Nightmare)
	SandboxDataManager.safe_unlock_map_of_type("FIRST KILN (INVERTED)", "res://scenes/first_kiln_invert.tscn", SandboxData.EDifficultyLevel.Nightmare)
	for m in MOD_MAPS:
		if FileAccess.file_exists(m[1]) and not SandboxDataManager.loaded_data.has_unlocked_map_with_path(m[1]):
			# no save() here: the entry exists only while the mod is loaded
			SandboxDataManager.loaded_data.unlocked_map_data.append(SandboxMapData.new().setup(m[0], m[1], SandboxData.EDifficultyLevel.Normal))
	print("[CoopSync] all sandbox maps unlocked")


func _process_inner(delta: float) -> void:
	Steam.run_callbacks()
	if _loop_pending:
		_loop_pending = false
		_loop_start()
	_poll_messages()
	if _banner_label and _banner_label.visible and Time.get_ticks_msec() > _banner_until_ms:
		_banner_label.visible = false

	if _local_player == null:
		_scan_accum += delta
		if _scan_accum >= 1.0:
			_scan_accum = 0.0
			_scan_for_player()
	elif is_instance_valid(_local_player):
		_local_player_age += delta

	if _lobby_id == 0:
		return

	_voice_tick(delta)
	if _loopback:
		_loop_script(delta)
	if noclip_shadows or not _shadow_q.is_empty() or not _shadow_by_cid.is_empty():
		_noclip_shadow_pump()
	_save_session_tick(delta)
	if not is_host:
		_sweep_puppets()
	_update_souls(delta)
	_sync_accum += delta
	if _sync_accum >= 1.0 / SYNC_HZ:
		_sync_accum = 0.0
		_broadcast_state()

	if not _pending_level.is_empty() and not SceneLoader.is_transitioning() and not SceneLoader.was_transitioning_recently():
		var lvl: Dictionary = _pending_level
		_pending_level = {}
		_apply_level(lvl)

	if not _mapsync_scene.is_empty():
		_retry_mapsync()

	if is_host and _welcome_queue.size() > 0:
		var now := Time.get_ticks_msec()
		for entry in _welcome_queue.duplicate():
			if now >= entry[2]:
				_send_level_to(entry[0])
				entry[1] -= 1
				entry[2] = now + 1500
				if entry[1] <= 0:
					_welcome_queue.erase(entry)


# ---------------------------------------------------------------- developer loopback

func _loop_start() -> void:
	# a developer harness never touches the player's real saved runs or trophies (build contract 1A.2)
	use_test_files()
	if not Game.is_steam_enabled():
		print("[LOOP] Steam not running, loopback off")
		return
	_loopback = true
	is_host = true
	_my_steam_id = Steam.getSteamID()
	_host_steam_id = _my_steam_id
	_lobby_id = 1                       # a session with no real peers; _send_all short-circuits
	local_name = "Me"
	_peer_names[LOOP_ID] = "Ghost"
	print("[LOOP] loopback on: a Ghost mirrors you 0.7 s behind, 3.5 m ahead of where you look")


func _loop_pump() -> void:
	var now := Time.get_ticks_msec()
	while _loop_queue.size() > 0 and int(_loop_queue[0][0]) <= now:
		var msg: Dictionary = _loop_queue.pop_front()[1]
		var t := str(msg.get("t", ""))
		if t == "c" and noclip_shadows:
			_noclip_shadow_queue(msg)       # no-clip test only: shadow puppets (still dropped below)
		# "c": echoed centipedes would spawn as real hunting centipedes on the host (review #122)
		if t in ["death", "ending", "mapev", "maps", "level", "mapsync", "mapsync_req", "checkpoint", "unhook", "c"]:
			if guestsim == "record" and (t == "maps" or t == "mapev"):
				_guestsim_record(t, msg)    # kept for the guest simulation, still never applied here
			if t == "mapev":
				_loop_ghost_mapev(msg)
			continue                    # your own world events must not come back as a second player's
		msg["from"] = LOOP_ID
		if t == "savehold":
			# the saved-run hold, as the Ghost (a guest) would see it: shown for 2 s, then released
			if bool(msg.get("on", false)) and is_instance_valid(save_prompt):
				save_prompt.show_hold(sanitize_name(str(msg.get("host", "the host"))), 2.0)
				print("[SAVE] loop hold shown")
			continue
		if t == "oilset":
			# the Ghost answers a restored oil level with its report, so both ends round-trip
			if str(msg.get("to", "")) == str(LOOP_ID) and is_instance_valid(save_run):
				var tk = msg.get("taken", [])
				save_run.on_oil_report(str(LOOP_ID), "Ghost", float(msg.get("oil", 1.0)), tk if tk is Array else [])
				print("[SAVE] loop oilset -> oilrep from the Ghost: %.2f, %d taken" % [float(msg.get("oil", 1.0)), (tk as Array).size() if tk is Array else 0])
			continue
		if t == "p":
			msg["n"] = "Ghost"
			# the Ghost carries the idol only when the idol module says it holds it (not a mirror of mine)
			if idol_holder_sid == str(LOOP_ID):
				msg["idl"] = 1 + clampi(loop_ghost_weight, 0, 98)
			else:
				msg.erase("idl")
			var ghost = _peers.get(LOOP_ID)
			var me = Game.climber
			if is_instance_valid(me) and me.get("coop_spectating") and is_instance_valid(ghost):
				# while I spectate, the Ghost stands still and stays alive (it is the teammate
				# who rescues me), instead of mirroring my spectator camera
				msg["pos"] = ghost.global_position
				msg["alive"] = true
				msg.erase("rope")
				msg.erase("att")
			else:
				var yaw: float = float(msg.get("cam", 0.0))
				var at: Vector3 = msg["pos"]
				var ahead := 3.5
				if _loop_ghost_at_hand() and is_instance_valid(me) and me.is_inside_tree():
					# an idol is being handed around (mine or the Ghost's): the pass rules measure the
					# Ghost against where I stand NOW (4.5 m flat in loopback to hand it over, 6 m on the
					# authority), and a knight the Nest keeps shoving (24 m/s body knockback) moves metres
					# in the 0.7 s the echo takes. The Ghost therefore stands 2.5 m ahead of my CURRENT
					# place and view (the remote knight still renders its usual 60 ms behind), so the
					# A-IDOL pass never misses its teammate. It is still a real remote packet stream.
					at = me.global_position
					if me.get("Camera") != null and is_instance_valid(me.Camera):
						yaw = me.Camera.global_rotation.y
					msg["cam"] = yaw
					ahead = LOOP_GHOST_AT_HAND_M
				msg["pos"] = at + Vector3(-sin(yaw), 0.0, -cos(yaw)) * ahead
			_on_player_state(LOOP_ID, msg)
		elif t == "soul":
			_spawn_soul(LOOP_ID, "Ghost", msg.get("p", Vector3.ZERO))
		elif t == "rescue":
			_on_rescue(int(msg.get("who", 0)), "Ghost", false)
		elif t == "v":
			_on_voice(LOOP_ID, msg)                 # the Ghost talks back with your own voice
		elif t == "oil":
			# oil poured for the Ghost comes straight back, so both ends of a gift can be tested
			if int(msg.get("to", 0)) == LOOP_ID and is_instance_valid(lantern) and lantern.has_method("receive_oil"):
				lantern.receive_oil(float(msg.get("x", 0.0)), "Ghost")


func _loop_ghost_at_hand() -> bool:
	# the loopback Ghost stands at arm's reach of where I am now (not where I was 0.7 s ago) while an
	# idol is in play between us: I carry it, or the idol module says the Ghost holds it
	return idol_carrier or (idol_holder_sid != "" and idol_holder_sid == str(LOOP_ID))


func _loop_ghost_mapev(msg: Dictionary) -> void:
	# a request addressed to the Ghost ("to": "777") is answered by the map's loopback shim, since the
	# Ghost has no machine of its own (build contract 2.1 edit 7)
	var d = msg.get("d")
	if not (d is Dictionary) or str((d as Dictionary).get("to", "")) != str(LOOP_ID):
		return
	var root := get_tree().current_scene
	if root and root.has_method("coop_loop_ghost"):
		root.call_deferred("coop_loop_ghost", str(msg.get("k", "")), d)


func _loop_shot(name: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img:
		if img.get_width() > 960:
			img.resize(640, 360, Image.INTERPOLATE_BILINEAR)
		img.save_png("user://%s.png" % name)


func _loop_script(delta: float) -> void:
	# a fixed sequence that exercises every co-op path once, printing what it sees
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree():
		return
	if _loop_t < 0.0:
		_loop_t = 0.0
	_loop_t += delta
	var rp = _peers.get(LOOP_ID)
	match _loop_step:
		0:
			if _loop_t > 14.0:
				var ahead: Vector3 = c.global_position + Vector3(-sin(c.Camera.global_rotation.y), 0.0, -cos(c.Camera.global_rotation.y)) * 2.2
				_spawn_soul(LOOP_ID, "Ghost", ahead)
				print("[LOOP] 14s ghost soul dropped 2.2 m ahead; standing here should pull it back in 1.5 s")
				_loop_step = 1
		1:
			if _loop_t > 19.0:
				print("[LOOP] 19s souls left: %d (0 = the proximity rescue worked)" % _souls.size())
				_loop_step = 2
		2:
			if _loop_t > 24.0:
				_loop_shot("loopback_1")
				var lan := false
				var vis := false
				if is_instance_valid(rp):
					vis = rp.visible
					lan = rp.get("_lantern") != null and rp.get("_lantern").visible
				print("[LOOP] 24s shot 1: ghost knight visible=%s lantern=%s puppets=%d peers=%d" % [str(vis), str(lan), _puppets.size(), _peers.size()])
				if is_instance_valid(rp):
					var ve = rp.get("_voice")
					if is_instance_valid(ve):
						var pl = ve.get("_player")
						var bus := "?"
						var cut := 0.0
						if is_instance_valid(pl):
							bus = str(pl.bus)
							cut = float(pl.attenuation_filter_cutoff_hz)
						print("[LOOP] 24s voice: samples in %d, frames played %d, bus %s, occlusion %.2f, cutoff %.0f Hz, talking %s" % [
							int(ve.get("stat_samples_in")), int(ve.get("stat_frames_out")), bus, float(ve.get("_occ")), cut, str(ve.get("talking"))])
					else:
						print("[LOOP] 24s voice: the Ghost has NO voice emitter")
				_loop_step = 3
		3:
			if _loop_t > 28.0 and c.has_method("coop_enter_spectator"):
				c.coop_enter_spectator()
				print("[LOOP] 28s I died with no respawns: spectating=%s, my soul dropped" % str(c.get("coop_spectating")))
				_loop_step = 4
		4:
			if _loop_t > 34.0:
				_on_rescue(_my_steam_id, "Ghost", false)
				print("[LOOP] 34s Ghost rescues me")
				_loop_step = 5
		5:
			if _loop_t > 37.0:
				print("[LOOP] 37s after rescue: spectating=%s health=%.0f souls=%d" % [str(c.get("coop_spectating")), float(c.health), _souls.size()])
				_loop_shot("loopback_2")
				_loop_step = 6
		6:
			if _loop_t > 40.0:
				print("[LOOP] done")
				_loop_step = 7


# ---------------------------------------------------------------- public helpers

func in_session() -> bool:
	return _lobby_id != 0


func is_guest() -> bool:
	return _lobby_id != 0 and not is_host


func current_scene_path() -> String:
	return _last_scene_path


# ---------------------------------------------------------------- v5.0: Steam ids are Strings (R1)
# Every Steam id inside map_event data and new net messages is a String: a 17-digit int that goes
# through JSON (the saved run) comes back as a float with lost digits.

func my_sid() -> String:
	# this player's id as a String; solo without Steam: "local"
	if _my_steam_id != 0:
		return str(_my_steam_id)
	if _my_sid_cache.is_empty() and Game.is_steam_enabled():
		var id := int(Steam.getSteamID())
		if id != 0:
			_my_sid_cache = str(id)
	return _my_sid_cache if not _my_sid_cache.is_empty() else "local"


func sid(v) -> String:
	# String as is, int as its digits; a float (a JSON-mangled id) or anything else never matches: ""
	if v is String or v is StringName:
		return str(v)
	if v is int:
		return str(v)
	return ""


func is_me(v) -> bool:
	var s := sid(v)
	return s != "" and s == my_sid()


func name_of(s: String) -> String:
	if s == my_sid():
		return local_name
	if s.is_valid_int() and _peer_names.has(int(s)):
		return str(_peer_names[int(s)])
	return "A teammate"


func host_id() -> int:
	return _host_steam_id if in_session() else _my_steam_id


func host_sid() -> String:
	if in_session() and _host_steam_id != 0:
		return str(_host_steam_id)
	return my_sid()


func session_ids() -> Array:
	# me, plus every teammate whose knight is in this scene and was updated within STALE_MS
	# (alive OR spectating)
	var out: Array = [my_sid()]
	var now := Time.get_ticks_msec()
	for id in _peers.keys():
		var rp = _peers[id]
		if is_instance_valid(rp) and str(rp.scene_path) == _last_scene_path and now - int(rp.last_update_ms) < STALE_MS:
			var s := str(id)
			if not out.has(s):
				out.append(s)
	return out


func _map_filter_spawn(p: Vector3) -> Vector3:
	# a map can move a respawn or rescue point (the False Hearth never lets anyone respawn in its maw)
	var root := get_tree().current_scene
	if root and root.has_method("coop_filter_spawn"):
		var r = root.call("coop_filter_spawn", p)
		if r is Vector3:
			return r
	return p


func _is_mod_map(scene: String) -> bool:
	for m in MOD_MAPS:
		if str(m[1]) == scene:
			return true
	return false


# ---------------------------------------------------------------- v5.0: saved runs (save_run.gd, save_prompt.gd)

func map_loaded(scene: String, fresh: bool) -> void:
	# A mod map calls this once per load, deferred from its _ready. fresh = there was no map state
	# for this scene (a new run: not a death reload, not a continue). On the authority's fresh load
	# of a map with an unfinished saved run the CONTINUE / NEW RUN panel opens here, synchronously,
	# so save_prompt_open() is already true when this returns (the map's clock waits for it).
	_end_continue_load()
	map_loads += 1
	last_map_loaded = {"scene": scene, "fresh": fresh, "ms": Time.get_ticks_msec()}
	if is_instance_valid(save_run):
		save_run.on_map_loaded(scene, fresh)
	if guestsim != "":
		_guestsim_on_map_loaded(scene)
	if not fresh or not map_is_authority() or guestsim == "play":
		return
	if not is_instance_valid(save_run) or not is_instance_valid(save_prompt):
		return
	var key: String = save_run.map_key(scene)
	if key.is_empty():
		return
	var s: Dictionary = save_run.has_save(key)
	if s.is_empty() or bool(s.get("finished", false)):
		return
	if bool(s.get("older", false)):
		# v5.1: a run saved on another build of this map (v5.0's, say) would put its checkpoints and
		# its stored events on rock that moved: it is never offered. The file stays until a new save.
		print("[SAVE] the saved run is from another build of this map (mod %s): not offered, a new run starts" % str(s.get("mod", "?")))
		show_banner("Your saved run was made on an older version of this map, so it cannot be continued. A new run starts.", 7.0)
		return
	save_prompt.show_for(key, s)
	_hold_keepalive_t = 0.0                  # the guests are held on the next frame (and every 4 s)
	var auto: String = save_run.auto_answer()
	if not auto.is_empty():
		save_prompt.auto_answer(auto)


func save_prompt_open() -> bool:
	# the host's saved-run panel or a guest's hold panel is showing (the game is paused meanwhile)
	return is_instance_valid(save_prompt) and bool(save_prompt.is_open())


func save_continue(key: String) -> void:
	# CONTINUE on the saved-run panel: restore the map state (checkpoint, events, the clock) and this
	# player's oil, tell every guest to drop its map state, then reload the level through the same
	# path as RESTART AT KILN. The guests follow the restart and get the saved state by mapsync,
	# then their saved oil by "oilset".
	if not is_instance_valid(save_run):
		return
	var scene := _scene_now()
	if not save_run.load_into_state(key):
		if is_instance_valid(save_prompt):
			save_prompt.close()
		show_banner("The saved run could not be read.", 5.0)
		_save_hold_send(false, false, "")
		return
	if is_instance_valid(save_prompt):
		save_prompt.close()
	# reliable on CH_EVENT before the level message, so every guest resets before it reloads
	_save_hold_send(false, true, str(map_state.get("scene", scene)))
	print("[SAVE] continue: reloading at checkpoint %d" % int(map_state.get("checkpoint", -1)))
	# the game's loading overlay only re-arms 0.5 s after the previous load ended: a reload asked for
	# sooner fades to black and never swaps the scene. The map has only just loaded, so wait for it.
	while SceneLoader.is_transitioning() or SceneLoader.was_transitioning_recently():
		await get_tree().process_frame
	SceneLoader.load_scene(Game.load_level_based_on_difficulty)


func save_new_run(key: String) -> void:
	# NEW RUN (confirmed): the saved run becomes <map>.old.json and this run plays on fresh
	if is_instance_valid(save_run):
		save_run.start_new_run(key)
	if is_instance_valid(save_prompt):
		save_prompt.close()
	_save_hold_send(false, false, "")


func _save_hold_send(on: bool, cont: bool, scene: String) -> void:
	_send_all({"t": "savehold", "from": _my_steam_id, "on": on, "host": local_name, "cont": cont, "s": scene}, true)


func _on_savehold(msg: Dictionary) -> void:
	# guest: the host is choosing (on), or has chosen. After CONTINUE (cont) this guest's map state
	# for the scene is emptied, so the mapsync after the reload REPLACES it instead of merging into it.
	if bool(msg.get("on", false)):
		if is_instance_valid(save_prompt):
			save_prompt.show_hold(sanitize_name(str(msg.get("host", "the host"))), 15.0)
		return
	if is_instance_valid(save_prompt):
		save_prompt.hide_hold()
	if bool(msg.get("cont", false)):
		var s := str(msg.get("s", ""))
		if not s.is_empty():
			map_state = {"scene": s, "checkpoint": -1, "events": {}}
			continue_load = true
			_oilrep_hold_ms = Time.get_ticks_msec() + 20000
			if not map_is_authority():
				# the flag belongs to the reload the host's restart "level" causes: a map instance that
				# was still loading, or a death reload, when the host pressed CONTINUE must not use it up
				# (the only "oilset" can land on that instance; the restart would then relight to 25%)
				_cont_guest = true
				_cont_level_seq = _applied_level_seq
				_cont_level_root = -1
				_cont_until_ms = Time.get_ticks_msec() + 60000
			print("[SAVE] the host continues a saved run: map state cleared for the reload")


func _end_continue_load() -> void:
	# a map load is over: a SAVE continue's reload no longer holds back the relight floor. On a guest
	# the flag lasts until the map instance loaded by the host's restart "level" (newer than the
	# continue release) comes up, or 60 s at most.
	if _cont_guest and Time.get_ticks_msec() < _cont_until_ms:
		var cs := get_tree().current_scene if is_inside_tree() else null
		if _cont_level_root < 0 or cs == null or cs.get_instance_id() == _cont_level_root:
			return
	continue_load = false
	_cont_guest = false
	_cont_level_root = -1


func _on_oilset(msg: Dictionary) -> void:
	# guest: the host's saved run restores this player's lamp oil and taken flasks, exactly
	_oilrep_hold_ms = 0
	if not is_instance_valid(lantern) or not lantern.has_method("import_oil"):
		return
	var tk = msg.get("taken", [])
	lantern.import_oil({"oil": float(msg.get("oil", 1.0)), "taken": tk if tk is Array else []})
	_oilrep_last = -1.0                     # report the restored level back, so the host's table matches
	print("[SAVE] lamp oil restored from the saved run: %d%%" % int(round(float(msg.get("oil", 1.0)) * 100.0)))


func _send_oilset(peer: int) -> void:
	# host, after a CONTINUE: each guest gets its saved oil and taken flasks once (a guest with no
	# saved entry gets a fresh full lantern), right after its mapsync answer
	if not is_instance_valid(save_run):
		return
	var s := str(peer)
	var e: Dictionary = save_run.saved_player(s)
	var oil := 1.0
	var taken: Array = []
	if e.has("oil"):
		oil = clampf(float(e["oil"]), 0.0, 1.0)
		var t = e.get("taken", [])
		if t is Array:
			taken = (t as Array).duplicate()
	save_run.mark_oilset_sent(s)
	_send_to(peer, {"t": "oilset", "from": _my_steam_id, "to": s, "oil": oil, "taken": taken}, true)
	print("[SAVE] oilset to %s: %d%%, %d flasks taken" % [name_of(s), int(round(oil * 100.0)), taken.size()])


func _save_session_tick(delta: float) -> void:
	# host: keep the guests held while the saved-run panel is open; guest: report the lamp oil
	if is_host and is_instance_valid(save_prompt) and bool(save_prompt.host_open()):
		_hold_keepalive_t -= delta
		if _hold_keepalive_t <= 0.0:
			_hold_keepalive_t = 4.0
			_save_hold_send(true, false, "")
	if _cont_guest and Time.get_ticks_msec() >= _cont_until_ms:
		_end_continue_load()                    # the host's restart never came: the relight floor is back
	if is_guest():
		_guest_oil_tick(delta)


func _guest_oil_tick(delta: float) -> void:
	# a guest reports its lamp oil to the host, who keeps the saved run: when it changed by 2% or
	# more (checked every 3 s) and at every checkpoint
	if not is_instance_valid(lantern) or not bool(lantern.get("oil_enabled")) or not _is_mod_map(_last_scene_path):
		return
	if _oilrep_hold_ms > 0:
		if Time.get_ticks_msec() < _oilrep_hold_ms:
			return                          # a CONTINUE is restoring my oil: report the restored level
		_oilrep_hold_ms = 0
	_oilrep_t -= delta
	if not _oilrep_due and _oilrep_t > 0.0:
		return
	_oilrep_t = 3.0
	var ex: Dictionary = lantern.export_oil() if lantern.has_method("export_oil") else {"oil": float(lantern.get("oil")), "taken": []}
	var oil := float(ex.get("oil", 1.0))
	var taken: Array = ex.get("taken", []) if ex.get("taken", []) is Array else []
	if not _oilrep_due and absf(oil - _oilrep_last) < 0.02 and taken.size() == _oilrep_taken:
		return
	_oilrep_due = false
	_oilrep_last = oil
	_oilrep_taken = taken.size()
	_send_to(_host_steam_id, {"t": "oilrep", "from": _my_steam_id, "n": local_name, "oil": oil, "taken": taken}, true)


func use_test_files() -> void:
	# build contract 1A.2: every developer test and harness run uses the TEST save folder
	# (user://zonda_saves_test/, emptied once per launch) and the test cosmetics file, so the player's
	# real saved runs and trophies are never touched. Idempotent: later calls do nothing at all.
	if test_files:
		return
	test_files = true
	if noise_force < 0:
		noise_force = 9                           # v5.1: tests written before the sound rules keep their old hunts
	if is_instance_valid(save_run):
		save_run.use_test_dir()
	omen_file = "user://zonda_cosmetics_test.cfg"
	if FileAccess.file_exists(omen_file):
		DirAccess.remove_absolute(omen_file)
	print("[CoopSync] test files on")


# ---------------------------------------------------------------- v5.0: omen trophies ([omen] in the cosmetics file)

func omen_tier_for(n: int) -> int:
	# omens carried to the finish -> trophy tier: 1-2 I, 3-5 II, 6-7 III, 8 IV
	if n <= 0:
		return 0
	if n <= 2:
		return 1
	if n <= 5:
		return 2
	if n <= 7:
		return 3
	return 4


func omen_best(map_key: String) -> int:
	# the most omens this player has carried out of that map (read from the file trophies go to)
	var cf := ConfigFile.new()
	if cf.load(omen_file) != OK:
		return 0
	return int(cf.get_value("omen", "%s_best" % map_key, 0))


func omen_grant(map_key: String, n: int) -> Dictionary:
	# the finish with n omens: keep the best per map in [omen] "<map>_best" of omen_file (never
	# [relics]: its size drives the gold name, rope and crown), then recompute omen_tier from that file
	var cf := ConfigFile.new()
	cf.load(omen_file)                      # a missing file is an empty one
	var k := "%s_best" % map_key
	var prev := int(cf.get_value("omen", k, 0))
	var best := maxi(prev, n)
	if n > prev:
		cf.set_value("omen", k, best)
		var err := cf.save(omen_file)
		if err != OK:
			push_warning("[CoopSync] could not save the omen trophy to %s (error %d)" % [omen_file, err])
	omen_tier = _omen_tier_in(cf)
	return {"tier": omen_tier_for(n), "best": best, "new": omen_tier_for(n) > omen_tier_for(prev)}


func _load_omen() -> void:
	# the trophy tier shown on your lantern and knight: the best over every map, read from the real file
	var cf := ConfigFile.new()
	if cf.load(RELIC_FILE) == OK:
		omen_tier = _omen_tier_in(cf)


func _omen_tier_in(cf: ConfigFile) -> int:
	var t := 0
	if cf.has_section("omen"):
		for key in cf.get_section_keys("omen"):
			if str(key).ends_with("_best"):
				t = maxi(t, omen_tier_for(int(cf.get_value("omen", key, 0))))
	return t


func register_puppet(c: Node) -> void:
	_purge_puppets()
	_puppets.append(c)


func _purge_puppets() -> void:
	_puppets = _puppets.filter(func(p): return is_instance_valid(p))


func _active_remote_players() -> Array:
	var out: Array = []
	var now := Time.get_ticks_msec()
	for id in _peers.keys():
		var rp = _peers[id]
		if is_instance_valid(rp) and rp.alive and rp.scene_path == _last_scene_path and now - rp.last_update_ms < STALE_MS:
			out.append(rp)
	return out


func _local_alive() -> bool:
	return is_instance_valid(Game.climber) and Game.climber.is_inside_tree() and not Game.climber.get("coop_spectating")


func any_teammate_alive() -> bool:
	return _active_remote_players().size() > 0


func spectate_target(index: int) -> Node3D:
	var list := _active_remote_players()
	if list.is_empty():
		return null
	return list[posmod(index, list.size())]


func local_player_slot_offset() -> Vector3:
	var ids: Array = [_my_steam_id]
	for id in _peers.keys():
		ids.append(id)
	ids.sort()
	var idx: int = ids.find(_my_steam_id)
	if idx <= 0:
		return Vector3.ZERO
	var angle: float = float(idx) * (TAU / 4.0)
	return Vector3(cos(angle), 0.0, sin(angle)) * 0.9


const _SPAWN_OFFSETS := [
	Vector3(0.0, 0.0, 0.0), Vector3(0.7, 0.0, 0.0), Vector3(-0.7, 0.0, 0.0), Vector3(0.0, 0.0, 0.7),
	Vector3(0.0, 0.0, -0.7), Vector3(1.2, 0.0, 1.2), Vector3(-1.2, 0.0, -1.2), Vector3(1.2, 0.0, -1.2),
]


func respawn_point_for(c: Node3D) -> Vector3:
	# Candidates in priority order: the nearest friend's last solid ground, then the friends
	# themselves, then our own last ground. Every candidate is physics-checked so we never
	# come back hanging in the air or inside a wall.
	var remotes := _active_remote_players()
	var here: Vector3 = c.global_position
	remotes.sort_custom(func(a, b): return here.distance_squared_to(a.global_position) < here.distance_squared_to(b.global_position))
	var candidates: Array = []
	for rp in remotes:
		if rp.has_ground:
			candidates.append(rp.last_ground_pos)
		candidates.append(rp.global_position)
	if c.get("_coop_has_ground"):
		candidates.append(c.get("_coop_last_ground_pos"))
	candidates.append(here)
	for cand in candidates:
		var spot := _settle_on_ground(c, _map_filter_spawn(cand))
		if spot != Vector3.INF:
			return spot
	# Nothing solid near anyone (everyone mid-rope): a longer probe straight down from the nearest friend.
	if remotes.size() > 0:
		var deep := _floor_below(c, remotes[0].global_position, 40.0)
		if deep != Vector3.INF:
			return deep + Vector3.UP * 0.9
		return remotes[0].global_position
	var own_floor := _floor_below(c, here, 40.0)
	if own_floor != Vector3.INF:
		return own_floor + Vector3.UP * 0.9
	return here + Vector3.UP * 0.5


func _settle_on_ground(c: Node3D, from: Vector3) -> Vector3:
	if not c.is_inside_tree() or c.get_world_3d() == null:
		return Vector3.INF
	var space := c.get_world_3d().direct_space_state
	var cap := CapsuleShape3D.new()
	cap.radius = 0.42
	cap.height = 1.5
	for off in _SPAWN_OFFSETS:
		var start: Vector3 = from + off + Vector3.UP * 1.0
		var ray := PhysicsRayQueryParameters3D.create(start, start + Vector3.DOWN * 4.0, 1)
		var hit: Dictionary = space.intersect_ray(ray)
		if hit.is_empty():
			continue
		var n: Vector3 = hit["normal"]
		if n.y < 0.75:
			continue  # too steep, we would slide straight off
		var center: Vector3 = hit["position"] + Vector3.UP * 0.9
		var q := PhysicsShapeQueryParameters3D.new()
		q.shape = cap
		q.transform = Transform3D(Basis.IDENTITY, center)
		q.collision_mask = 1
		q.exclude = [c.get_rid()]
		if space.intersect_shape(q, 1).size() > 0:
			continue  # would clip into rock
		return center
	return Vector3.INF


func _floor_below(c: Node3D, from: Vector3, dist: float) -> Vector3:
	if not c.is_inside_tree() or c.get_world_3d() == null:
		return Vector3.INF
	var ray := PhysicsRayQueryParameters3D.create(from + Vector3.UP * 0.5, from + Vector3.DOWN * dist, 1)
	var hit: Dictionary = c.get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.size() > 0 and hit["normal"].y > 0.6:
		return hit["position"]
	return Vector3.INF


func nearest_player_node(from: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	if _local_alive():
		best = Game.climber
		best_d = from.distance_squared_to(Game.climber.global_position)
	for rp in _target_remote_players():
		var d: float = from.distance_squared_to(rp.global_position)
		if d < best_d:
			best_d = d
			best = rp
	return best


var _cent_assign: Dictionary = {}


func _alive_player_nodes() -> Array:
	var out: Array = []
	if _local_alive():
		out.append(Game.climber)
	out.append_array(_target_remote_players())
	return out


func _target_remote_players() -> Array:
	# the remote players creatures may target: every active one, except the loopback Ghost while the
	# no-clip test runs (B7: it stands 3.5 m ahead of the camera, often inside the wall looked at)
	var list := _active_remote_players()
	if not noclip_no_ghost:
		return list
	return list.filter(func(p): return int(p.get("peer_id")) != LOOP_ID)


var _lure_node: Node3D = null
var _lure_until_ms := 0
var _lure_calls: Dictionary = {}     # lure node instance id -> last set_lure call (ms)
const LURE_STREAM_GAP_MS := 1000


func set_lure(node: Node3D, seconds: float) -> void:
	# A map can pull every centipede toward one spot (the bell). The bell calls this every
	# frame with its time left. A lure already running is never extended (review #66): a
	# second ring, or a second bell, can only keep or shorten it, and when it runs out, the
	# rest of a ring that arrived meanwhile does not start a new one.
	if not is_instance_valid(node):
		return
	var now := Time.get_ticks_msec()
	var nid := node.get_instance_id()
	var prev: int = int(_lure_calls.get(nid, -100000))
	_lure_calls[nid] = now
	var until: int = now + int(seconds * 1000.0)
	if lure_active():
		_lure_until_ms = mini(_lure_until_ms, until) if node == _lure_node else _lure_until_ms
		return
	if now - prev < LURE_STREAM_GAP_MS:
		return                          # the tail of a ring that was refused while a lure ran
	_lure_node = node
	_lure_until_ms = until


func lure_active() -> bool:
	return is_instance_valid(_lure_node) and Time.get_ticks_msec() < _lure_until_ms


func lure_node() -> Node3D:
	# v5.0 no-clip (A10): the bell pulling the centipedes right now, else null; CoopHunting never
	# lunges at it (a centipede idles by the bell instead of biting into its collision cylinder)
	return _lure_node if lure_active() else null


func _lure_applies(c: Node) -> bool:
	# a map marks centipedes the bell must not pull (the finale chasers once the idol is taken)
	return lure_active() and not bool(c.get_meta("zonda_no_lure", false))


func target_player_for(c: Node3D) -> Node3D:
	if not is_instance_valid(c) or not c.is_inside_tree():
		return null
	if _lure_applies(c):
		return _lure_node
	# v5.0: a pinned hunter (meta "zonda_hunt_pin", e.g. "idol") chases only the player that pin
	# names in hunt_pins, while that player is alive here; otherwise it targets as usual
	var pinned := _pin_target(c, [])
	if pinned != null:
		return pinned
	# A map can pin a centipede to a band of depth: it hunts whoever is inside the band and
	# ignores everyone else, so it stays in its biome after the team has moved on.
	if c.has_meta("zonda_territory"):
		return _territory_target(c)
	var live_cents := 0
	for cent in Game.centipedes:
		if is_instance_valid(cent) and not cent.has_meta("zonda_territory"):
			live_cents += 1
	if live_cents <= 1:
		return nearest_player_node(c.global_position)
	var players := _alive_player_nodes()
	if players.is_empty():
		return null
	var now := Time.get_ticks_msec()
	if now - _cent_assign_time > 1000:
		_recompute_centipede_targets(players)
		_cent_assign_time = now
	var cur = _cent_assign.get(c.get_instance_id())
	if cur != null and is_instance_valid(cur) and players.has(cur):
		return cur
	return nearest_player_node(c.global_position)


var _cent_assign_time := 0
var _cent_accum := 0


func _territory_target(c: Node3D) -> Node3D:
	var t: Array = c.get_meta("zonda_territory")      # [y_top, y_bottom]
	var best: Node3D = null
	var bd := 1e18
	for p in _alive_player_nodes():
		var y: float = p.global_position.y
		if y <= float(t[0]) + 15.0 and y >= float(t[1]) - 15.0:
			var d: float = c.global_position.distance_squared_to(p.global_position)
			if d < bd:
				bd = d
				best = p
	return best


func _pin_target(c: Node, players: Array) -> Node3D:
	# the player a pinned hunter must chase, or null (no pin, or its player is not alive here)
	if not c.has_meta("zonda_hunt_pin") or hunt_pins.is_empty():
		return null
	var t = hunt_pins.get(str(c.get_meta("zonda_hunt_pin")))
	if not is_instance_valid(t) or not (t is Node3D) or not (t as Node3D).is_inside_tree():
		return null
	if (t as Node3D).has_meta("zonda_pin_decoy"):
		return t                        # v5.1: the screaming idol on the ground calls the Nest to it
	var alive: Array = players if not players.is_empty() else _alive_player_nodes()
	return t if alive.has(t) else null


func _recompute_centipede_targets(players: Array) -> void:
	_cent_assign.clear()
	var cents: Array = []
	for cent in Game.centipedes:
		# a pinned hunter already has its one target, so the others still spread over the rest
		if is_instance_valid(cent) and cent.is_inside_tree() and not cent.has_meta("zonda_territory") and _pin_target(cent, players) == null:
			cents.append(cent)
	var pairs: Array = []
	for cent in cents:
		for p in players:
			pairs.append([cent.global_position.distance_squared_to(p.global_position), cent, p])
	pairs.sort_custom(func(a, b): return a[0] < b[0])
	var taken_players: Dictionary = {}
	for pair in pairs:
		var cent: Node3D = pair[1]
		var p: Node3D = pair[2]
		if _cent_assign.has(cent.get_instance_id()) or taken_players.has(p.get_instance_id()):
			continue
		_cent_assign[cent.get_instance_id()] = p
		taken_players[p.get_instance_id()] = true
	for cent in cents:
		if not _cent_assign.has(cent.get_instance_id()):
			_cent_assign[cent.get_instance_id()] = nearest_player_node(cent.global_position)


func target_player_position(c: Node3D) -> Vector3:
	var n := target_player_for(c)
	if n:
		return n.global_position
	return c.global_position


func target_player_distance(c: Node3D, default_distance: float = 999.9) -> float:
	var n := target_player_for(c)
	if n:
		return c.global_position.distance_to(n.global_position)
	return default_distance


func target_attached_claw_node(c: Node3D) -> Node3D:
	if not is_instance_valid(c) or _lure_applies(c):
		return null
	var n := target_player_for(c)
	if n == null or n.has_meta("zonda_pin_decoy"):
		return null
	if n == Game.climber:
		if Game.climber.activeClimberState is ClimberState_Attached and Game.climber.activeClimberState._time_in_state > 2.0:
			return Game.climber.Rope._claw
		return null
	if n.attached and n.attached_time > 2.0 and is_instance_valid(n.claw_node):
		return n.claw_node
	return null


func nearest_player_position(from: Vector3) -> Vector3:
	var n := nearest_player_node(from)
	if n:
		return n.global_position
	return from


func nearest_player_distance(from: Vector3, default_distance: float = 999.9) -> float:
	var n := nearest_player_node(from)
	if n:
		return from.distance_to(n.global_position)
	return default_distance


func lowest_player_y() -> float:
	var y := INF
	if _local_alive():
		y = Game.climber.global_position.y
	for rp in _active_remote_players():
		y = min(y, rp.global_position.y)
	return y


func nearest_attached_claw_node(from: Vector3) -> Node3D:
	var n := nearest_player_node(from)
	if n == null:
		return null
	if n == Game.climber:
		if Game.climber.activeClimberState is ClimberState_Attached and Game.climber.activeClimberState._time_in_state > 2.0:
			return Game.climber.Rope._claw
		return null
	if n.attached and n.attached_time > 2.0 and is_instance_valid(n.claw_node):
		return n.claw_node
	return null


func host_check_unhook(centipede: Node3D) -> void:
	if not is_host or not Game.centipede_should_go_after_claw():
		return
	var now := Time.get_ticks_msec()
	for rp in _active_remote_players():
		if rp.attached and is_instance_valid(rp.claw_node) and rp.claw_node.visible:
			if centipede.global_position.distance_squared_to(rp.claw_node.global_position) < 9.0:
				if now > int(_last_unhook_ms.get(rp.peer_id, -99999)) + 1500:
					_last_unhook_ms[rp.peer_id] = now
					_send_to(rp.peer_id, {"t": "unhook", "from": _my_steam_id}, true)


# ---------------------------------------------------------------- local player tracking

func _on_node_added(node: Node) -> void:
	if node is Climber:
		_local_player = node
		_local_player_age = 0.0


func _on_node_removed(node: Node) -> void:
	if node == _local_player:
		_local_player = null


func _scan_for_player() -> void:
	if is_instance_valid(Game.climber) and Game.climber.is_inside_tree():
		_local_player = Game.climber


# ---------------------------------------------------------------- scene / level sync

func _track_scene_changes() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var id := scene.get_instance_id()
	if id == _last_scene_instance_id:
		return
	_last_scene_instance_id = id
	_prev_scene_path = _last_scene_path
	_last_scene_path = scene.scene_file_path
	# saved runs: write the run the team just left (before a menu clears map_state below); a panel
	# still open from the scene we left is closed and the guests are released
	if is_instance_valid(save_run):
		save_run.on_scene_change(_prev_scene_path, _last_scene_path)
	if is_instance_valid(save_prompt) and bool(save_prompt.host_open()) and int(save_prompt.scene_id()) != id:
		save_prompt.close()
		_save_hold_send(false, false, "")
	if guestsim == "record" and _prev_scene_path == _gs_scene and _gs_entries.size() > 0:
		_guestsim_close("left the recorded map")   # one map instance per recording (a death reload is a new one)
	_oilrep_last = -1.0
	if _is_mod_map(_last_scene_path):
		# the map's _ready (which reads it for the lantern) ran a frame ago: a continue is over even
		# if the map never called map_loaded (on a guest: once the host's restart has loaded)
		_end_continue_load()
	if not (is_instance_valid(_local_player) and _local_player.is_inside_tree()):
		_local_player = null
	_purge_puppets()
	respawns_left = 1
	# review #43: this used to reset the flag a frame after the Underdark had set it
	if not (nametags_through_walls and _ntw_scene == _last_scene_path):
		nametags_through_walls = _last_scene_path.begins_with(UNDERDARK_DIR)
	_puppet_by_cid.clear()
	_puppet_seen_ms.clear()
	# a map sets idol_carrier while it loads (the replayed "idol" event), a frame before this
	# runs, so only a carrier flag from another scene is cleared here
	if idol_carrier and _idol_scene != _last_scene_path:
		idol_carrier = false
	if not _mapsync_scene.is_empty() and _mapsync_scene != _last_scene_path:
		_mapsync_scene = ""
	if _last_scene_path.contains("MainMenu"):
		map_state = {"scene": "", "checkpoint": -1, "events": {}}
		_restore_pending_custom()
	_await_spawn_sync = is_guest() and _is_gameplay_scene(_last_scene_path)
	print("[CoopSync] scene -> ", _last_scene_path)
	if _last_scene_path.contains("MainMenu") and not _autostarted and FileAccess.file_exists(MOD_DIR + "autostart.flag"):
		_autostart()
	if is_host and _lobby_id != 0:
		_broadcast_level()


var _autostarted := false


func _autostart() -> void:
	# developer only: start a sandbox map straight from the menu, no clicks. The flag is
	# removed as soon as it is read so it can never follow a player into a real session.
	_autostarted = true
	# every scripted run uses the test save folder and the test cosmetics file (build contract 1A.2)
	use_test_files()
	var want := FileAccess.get_file_as_string(MOD_DIR + "autostart.flag").strip_edges().to_upper()
	var disk := OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/autostart.flag"
	var err := DirAccess.remove_absolute(disk)
	print("[CoopSync] autostart flag '%s' (removed: %s)" % [want, str(err == OK)])
	if FileAccess.file_exists(MOD_DIR + "savetest.flag"):
		# developer only: the saved-run test (save_run.gd), read before the map loads; it picks its own
		# folder (user://zonda_saves_savetest/, kept between launches)
		var st := FileAccess.get_file_as_string(MOD_DIR + "savetest.flag").strip_edges().to_lower()
		DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/savetest.flag")
		if is_instance_valid(save_run):
			save_run.begin_savetest(st)
	for m in MOD_MAPS:
		if str(m[0]).to_upper() == want:
			Game.active_balance_settings = Game.get_balance_settings_for_sandbox_difficulty_level(SandboxData.EDifficultyLevel.Normal)
			Game.active_sandbox_map_data = SandboxMapData.new().setup(str(m[0]), str(m[1]), 0)
			await get_tree().create_timer(1.0).timeout
			print("[CoopSync] autostart -> ", m[1])
			SceneLoader.load_scene(func(): Game.load_level_based_on_difficulty(false))
			return
	print("[CoopSync] autostart: no map called ", want)


func _broadcast_level() -> void:
	if _last_scene_path.contains("you_died"):
		return
	if _prev_scene_path.contains("you_died"):
		return
	var restart := _last_scene_path == _prev_scene_path
	_level_seq += 1
	_send_all(_build_level_msg(restart), true)


func _send_level_to(peer: int) -> void:
	if _last_scene_path.contains("you_died"):
		return
	_send_to(peer, _build_level_msg(false), true)


func _build_level_msg(restart: bool) -> Dictionary:
	var msg := {
		"t": "level",
		"from": _my_steam_id,
		"seq": _level_seq,
		"scene": _last_scene_path,
		"restart": restart,
		"deaths": PlayerData.get_death_count(),
		"sandbox": Game.in_sandbox_mode,
		"bal": -1,
	}
	if Game.active_balance_settings:
		msg["bal"] = Game.get_sandbox_difficulty_level_for_balance_setting(Game.active_balance_settings)
	if Game.active_sandbox_map_data:
		msg["map_name"] = Game.active_sandbox_map_data.display_name
		msg["map_path"] = Game.active_sandbox_map_data.scene_path
		msg["map_diff"] = int(Game.active_sandbox_map_data.default_difficulty)
	if Game.custom_balance_settings:
		msg["custom"] = _balance_to_dict(Game.custom_balance_settings)
	return msg


func _balance_to_dict(b) -> Dictionary:
	return {
		"regen": b.centipede_stamina_regen_rate,
		"full": b.centipede_starts_at_full_stamina,
		"close": b.centipede_movement_speed_close,
		"far": b.centipede_movement_speed_far,
		"disable": b.disable_centipedes,
		"extra": b.additional_centipedes,
		"dmg": b.damage_multiplier,
		"rope": b.rope_length_multiplier,
		"claw": b.centipede_can_go_after_claw,
	}


func _dict_to_balance(d: Dictionary, b) -> void:
	b.centipede_stamina_regen_rate = d.get("regen", b.centipede_stamina_regen_rate)
	b.centipede_starts_at_full_stamina = d.get("full", b.centipede_starts_at_full_stamina)
	b.centipede_movement_speed_close = d.get("close", b.centipede_movement_speed_close)
	b.centipede_movement_speed_far = d.get("far", b.centipede_movement_speed_far)
	b.disable_centipedes = d.get("disable", b.disable_centipedes)
	b.additional_centipedes = int(d.get("extra", b.additional_centipedes))
	b.damage_multiplier = d.get("dmg", b.damage_multiplier)
	b.rope_length_multiplier = d.get("rope", b.rope_length_multiplier)
	b.centipede_can_go_after_claw = d.get("claw", b.centipede_can_go_after_claw)


func _apply_level(msg: Dictionary) -> void:
	if is_host:
		return
	if SceneLoader.is_transitioning() or SceneLoader.was_transitioning_recently():
		_pending_level = msg                   # retried once the loading overlay has re-armed (see save_continue)
		return
	var target: String = msg.get("scene", "")
	if target.is_empty() or target.contains("you_died"):
		return
	var seq: int = int(msg.get("seq", 0))
	if seq <= _applied_level_seq:
		return
	_applied_level_seq = seq
	var cur := ""
	if get_tree().current_scene:
		cur = get_tree().current_scene.scene_file_path
	if cur == target and not msg.get("restart", false):
		return
	print("[CoopSync] following host to ", target)
	if _cont_guest and _cont_level_root < 0 and seq > _cont_level_seq:
		# the host's restart after CONTINUE: the map instance this loads is the continued run
		var cs := get_tree().current_scene
		_cont_level_root = cs.get_instance_id() if cs != null else 0
	_apply_game_settings(msg)
	if msg.has("map_path") and msg["map_path"] == target:
		SceneLoader.load_scene(func(): Game.load_level_based_on_difficulty(false))
	else:
		SceneLoader.load_scene(func():
			Game.on_new_loaded_level()
			Game.in_main_menu = target.contains("MainMenu")
			get_tree().change_scene_to_file(target))


func _apply_game_settings(msg: Dictionary) -> void:
	# review #106: the host's death count and custom sliders are used in memory only. The
	# guest's own values are kept aside once per session and put back (and saved) on leaving.
	if not _own_saved:
		_own_saved = true
		_own_deaths = PlayerData.get_death_count()
		_own_custom = _balance_to_dict(Game.custom_balance_settings) if Game.custom_balance_settings else {}
		if not _own_custom_pending.is_empty():
			_own_custom = _own_custom_pending       # still holding the last host's sliders
			_own_custom_pending = {}
	var bal: int = int(msg.get("bal", -1))
	if msg.has("custom") and Game.custom_balance_settings:
		_dict_to_balance(msg["custom"], Game.custom_balance_settings)
	if bal >= 0:
		Game.active_balance_settings = Game.get_balance_settings_for_sandbox_difficulty_level(bal)
	else:
		Game.active_balance_settings = null
	if msg.has("map_path"):
		Game.active_sandbox_map_data = SandboxMapData.new().setup(msg.get("map_name", "COOP"), msg["map_path"], int(msg.get("map_diff", 0)))
	else:
		Game.active_sandbox_map_data = null
	Game.in_sandbox_mode = msg.get("sandbox", false)
	Game.active_run_time = 0.0
	Game.active_run = Game.active_balance_settings != null
	PlayerData.config.set_value("death", "count", int(msg.get("deaths", 0)))   # memory only, no saveConfig


var _own_saved := false
var _own_deaths := 0
var _own_custom: Dictionary = {}


func _restore_own_settings() -> void:
	# undoes _apply_game_settings: also overwrites any save the game made mid-session
	# (a death saves the host-based count to disk)
	if not _own_saved:
		return
	_own_saved = false
	PlayerData.config.set_value("death", "count", _own_deaths)
	PlayerData.saveConfig()
	if not _own_custom.is_empty() and Game.custom_balance_settings:
		if Game.active_balance_settings == Game.custom_balance_settings and not _scene_now().contains("MainMenu"):
			# a guest left solo mid-run keeps the run's (host's) sliders until the main menu,
			# so the difficulty never changes under them; the sandbox menu only saves from there
			_own_custom_pending = _own_custom
		else:
			_dict_to_balance(_own_custom, Game.custom_balance_settings)
	_own_custom = {}
	print("[CoopSync] own death count (%d) and custom settings restored" % _own_deaths)


var _own_custom_pending: Dictionary = {}


func _restore_pending_custom() -> void:
	if _own_custom_pending.is_empty():
		return
	if Game.custom_balance_settings:
		_dict_to_balance(_own_custom_pending, Game.custom_balance_settings)
	_own_custom_pending = {}


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_restore_own_settings()
		_restore_pending_custom()


func _exit_tree() -> void:
	_restore_own_settings()
	_restore_pending_custom()


# ---------------------------------------------------------------- lobby (host / join)

func host(player_name: String, pwd: String) -> void:
	if not Game.is_steam_enabled():
		_set_status("Steam is not running / not initialized.")
		_set_connected(false)
		return
	if _loopback:
		disconnect_session()        # the developer harness never mixes with a real lobby
	local_name = player_name
	_password = pwd
	is_host = true
	_my_steam_id = Steam.getSteamID()
	_host_steam_id = _my_steam_id
	Steam.createLobby(Steam.LOBBY_TYPE_PUBLIC, MAX_MEMBERS)
	print("[CoopSync] creating lobby (build %s)" % build_id)


func join(player_name: String, pwd: String) -> void:
	if not Game.is_steam_enabled():
		_set_status("Steam is not running / not initialized.")
		_set_connected(false)
		return
	if _loopback:
		disconnect_session()
	local_name = player_name
	_password = pwd
	is_host = false
	_my_steam_id = Steam.getSteamID()
	_join_stage = 1
	_request_lobbies(true)
	print("[CoopSync] searching lobby (build %s)" % build_id)


func _request_lobbies(same_build: bool) -> void:
	# Steam clears the filters after every request, so they are added each time.
	# Stage 1 asks for a lobby with this password on this exact build. Stage 2 (only when
	# stage 1 finds nothing) drops the build and tag filters, to tell the player the host's
	# lobby exists but runs another CoopSync build.
	Steam.addRequestLobbyListStringFilter("coop_pwd", str(_password.hash()), Steam.LOBBY_COMPARISON_EQUAL)
	if same_build:
		Steam.addRequestLobbyListStringFilter("coop_game", LOBBY_TAG, Steam.LOBBY_COMPARISON_EQUAL)
		Steam.addRequestLobbyListStringFilter("coop_ver", build_id, Steam.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListDistanceFilter(Steam.LOBBY_DISTANCE_FILTER_WORLDWIDE)   # friends abroad
	Steam.requestLobbyList()


func disconnect_session() -> void:
	var was_guest := is_guest()
	if _lobby_id != 0:
		if not _loopback:
			Steam.leaveLobby(_lobby_id)
		_lobby_id = 0
	_loopback = false
	_loop_queue.clear()
	for id in _peers.keys():
		_remove_remote_player(id)
	_peers.clear()
	_peer_names.clear()
	_welcome_queue.clear()
	_voice_seq_in.clear()
	_clear_flat_voice()
	_host_steam_id = 0
	is_host = false
	_applied_level_seq = -1
	_join_stage = 0
	_mapsync_scene = ""
	_oilrep_hold_ms = 0
	if _cont_guest:
		_cont_guest = false                 # no restart is coming from a host who left
		continue_load = false
		_cont_level_root = -1
	if is_instance_valid(save_prompt):
		save_prompt.hide_hold()             # nobody left to wait for
	_restore_own_settings()
	var had_puppets := _drop_puppets()
	if was_guest or had_puppets:
		# this machine is the authority now: a map can take over the creatures it only mirrored
		var root := get_tree().current_scene
		if root and root.has_method("coop_session_ended"):
			root.coop_session_ended()
	print("[CoopSync] disconnected")


func _drop_puppets() -> bool:
	# puppets only mirror the host; with no host left they would freeze in place and still shove
	var any := false
	for p in _puppets:
		if is_instance_valid(p):
			any = true
			Game.centipedes.erase(p)
			p.queue_free()
	_puppets.clear()
	_puppet_by_cid.clear()
	_puppet_seen_ms.clear()
	return any


func _on_lobby_created(connect: int, lobby_id: int) -> void:
	if lobby_id == 0:
		is_host = false
		_set_status("Failed to create lobby (error %d)." % connect)
		_set_connected(false)
		return
	_lobby_id = lobby_id
	Steam.setLobbyData(lobby_id, "coop_game", LOBBY_TAG)
	Steam.setLobbyData(lobby_id, "coop_pwd", str(_password.hash()))
	Steam.setLobbyData(lobby_id, "coop_ver", build_id)
	_set_status("HOSTING. Share the password.\nYou pick the level, friends follow.\nBuild %s. Players: 1 / %d" % [build_id, MAX_MEMBERS])
	print("[CoopSync] lobby created ", lobby_id)


func _on_lobby_match_list(lobbies: Array) -> void:
	if is_host or _join_stage == 0:
		return
	if _join_stage == 1:
		if lobbies.is_empty():
			# nothing on this build: look once more without the build filter, to explain why
			_join_stage = 2
			_request_lobbies(false)
			return
		_join_stage = 0
		Steam.joinLobby(lobbies[0])
		print("[CoopSync] joining lobby ", lobbies[0])
		return
	_join_stage = 0
	var other := ""
	for lid in lobbies:
		var tag: String = str(Steam.getLobbyData(int(lid), "coop_game"))
		if tag == LOBBY_TAG:
			other = str(Steam.getLobbyData(int(lid), "coop_ver"))
			if other.is_empty():
				other = "unknown"
			break
		if tag == LOBBY_TAG_OLD:
			other = "older than 4.8"
			break
	if not other.is_empty():
		_set_status("That lobby runs another CoopSync build.\nHost %s, you %s.\nEveryone needs the same zip: update, then join." % [other, build_id])
		print("[CoopSync] lobby found on another build: host %s, me %s" % [other, build_id])
	else:
		_set_status("No lobby found with that password on\nyour build (%s). Check the password and\nthat you and the host have the same zip." % build_id)
	_set_connected(false)


func _on_lobby_joined(lobby_id: int, _permissions: int, _locked: bool, response: int) -> void:
	if response != Steam.CHAT_ROOM_ENTER_RESPONSE_SUCCESS:
		_set_status("Failed to join lobby (response %d)." % response)
		_set_connected(false)
		_lobby_id = 0
		return
	_lobby_id = lobby_id
	_host_steam_id = Steam.getLobbyOwner(lobby_id)
	is_host = _host_steam_id == _my_steam_id
	var count: int = Steam.getNumLobbyMembers(lobby_id)
	for i in range(count):
		var member: int = Steam.getLobbyMemberByIndex(lobby_id, i)
		if member != _my_steam_id:
			Steam.acceptSessionWithUser(member)
	_send_all({"t": "hello", "from": _my_steam_id, "n": local_name, "b": build_id}, true)
	if is_host:
		_set_status("HOSTING.\nPlayers: %d / %d" % [count, MAX_MEMBERS])
	else:
		_set_status("CONNECTED.\nWaiting for the host to pick a level.\nPlayers: %d / %d" % [count, MAX_MEMBERS])
	_scan_for_player()
	print("[CoopSync] joined lobby %d (%d members) host=%s" % [lobby_id, count, str(is_host)])


func _on_lobby_chat_update(lobby_id: int, changed_id: int, _making_change_id: int, chat_state: int) -> void:
	if lobby_id != _lobby_id:
		return
	var count: int = Steam.getNumLobbyMembers(_lobby_id)
	if chat_state & Steam.CHAT_MEMBER_STATE_CHANGE_ENTERED:
		Steam.acceptSessionWithUser(changed_id)
		_send_to(changed_id, {"t": "hello", "from": _my_steam_id, "n": local_name, "b": build_id}, true)
		if is_host:
			_welcome_queue.append([changed_id, 3, Time.get_ticks_msec() + 700])
			if is_instance_valid(save_prompt) and bool(save_prompt.host_open()):
				# joined while the host is choosing CONTINUE or NEW RUN: held too
				_send_to(changed_id, {"t": "savehold", "from": _my_steam_id, "on": true, "host": local_name, "cont": false, "s": ""}, true)
		_set_status("Player joined.\nPlayers: %d / %d" % [count, MAX_MEMBERS])
	else:
		_remove_remote_player(changed_id)
		_remove_soul(changed_id)
		_peer_names.erase(changed_id)
		_voice_seq_in.erase(changed_id)
		_free_flat_voice(changed_id)
		if not is_host and changed_id == _host_steam_id:
			disconnect_session()
			show_banner("The host left. The co-op session ended, you are playing solo now.", 6.0)
			_set_status("Host left. Session ended.")
			_set_connected(false)
		else:
			_set_status("Player left.\nPlayers: %d / %d" % [count, MAX_MEMBERS])


func _on_session_request(remote_steam_id: int) -> void:
	Steam.acceptSessionWithUser(remote_steam_id)


# ---------------------------------------------------------------- networking

func _send_to(peer: int, msg: Dictionary, reliable: bool) -> void:
	if _loopback:
		# the harness has no real peers: a direct message goes round the Ghost like everything else
		_loop_queue.append([Time.get_ticks_msec() + 700, msg.duplicate(true)])
		return
	if _lobby_id == 0 or peer == 0 or peer == _my_steam_id:
		return
	var data: PackedByteArray = var_to_bytes(msg)
	var flags: int = Steam.NETWORKING_SEND_RELIABLE if reliable else Steam.NETWORKING_SEND_UNRELIABLE
	Steam.sendMessageToUser(peer, data, flags, CH_EVENT if reliable else CH_FAST)


func _send_all(msg: Dictionary, reliable: bool) -> void:
	if _loopback:
		_loop_queue.append([Time.get_ticks_msec() + 700, msg.duplicate(true)])
		return
	if _lobby_id == 0:
		return
	var data: PackedByteArray = var_to_bytes(msg)
	var flags: int = Steam.NETWORKING_SEND_RELIABLE if reliable else SEND_UNRELIABLE_NO_NAGLE
	var ch: int = CH_EVENT if reliable else CH_FAST
	var count: int = Steam.getNumLobbyMembers(_lobby_id)
	for i in range(count):
		var member: int = Steam.getLobbyMemberByIndex(_lobby_id, i)
		if member != _my_steam_id:
			Steam.sendMessageToUser(member, data, flags, ch)


func _poll_messages() -> void:
	if _loopback:
		_loop_pump()
		return
	if _lobby_id == 0:
		return
	for ch in [CH_FAST, CH_EVENT, CH_VOICE]:
		var msgs: Array = Steam.receiveMessagesOnChannel(ch, 64)
		for m in msgs:
			var data: PackedByteArray = m.get("payload", PackedByteArray())
			if data.size() > 0:
				_handle_message(data)


func _handle_message(data: PackedByteArray) -> void:
	var msg = bytes_to_var(data)
	if typeof(msg) != TYPE_DICTIONARY:
		return
	var from: int = int(msg.get("from", 0))
	if from == 0 or from == _my_steam_id:
		return
	match str(msg.get("t", "")):
		"p":
			_on_player_state(from, msg)
		"c":
			if from == _host_steam_id and not is_host:
				_apply_centipedes(msg)
		"hello":
			_peer_names[from] = str(msg.get("n", "Player"))
			var their_build := str(msg.get("b", "older than 4.8"))
			if their_build != build_id:
				show_banner("%s has a different CoopSync build (%s, you have %s). Everyone needs the same zip." % [sanitize_name(str(msg.get("n", "A player"))), their_build, build_id], 8.0)
		"level":
			if from == _host_steam_id:
				_apply_level(msg)
		"death":
			on_remote_death(str(msg.get("n", "A player")))
		"ending":
			on_remote_ending()
		"unhook":
			_on_remote_unhook()
		"soul":
			if str(msg.get("s", "")) == _last_scene_path:
				_spawn_soul(from, sanitize_name(str(msg.get("n", "Player"))), msg.get("p", Vector3.ZERO))
		"rescue":
			_on_rescue(int(msg.get("who", 0)), sanitize_name(str(msg.get("n", "A teammate"))), false)
		"v":
			_on_voice(from, msg)
		"oil":
			if int(msg.get("to", 0)) == _my_steam_id and is_instance_valid(lantern) and lantern.has_method("receive_oil"):
				lantern.receive_oil(float(msg.get("x", 0.0)), sanitize_name(str(msg.get("n", "A teammate"))))
		"checkpoint":
			if msg.has("cp") and _scene_ok_for_state(str(msg.get("s", ""))):
				_note_checkpoint(str(msg.get("s", "")), int(msg["cp"]))
			on_checkpoint_reached()
		"mapev":
			var evs := str(msg.get("s", ""))
			if _scene_ok_for_state(evs):
				var d = msg.get("d", {})
				var pers := bool(msg.get("p", true))
				if not pers and d is Dictionary:
					# R4: who asked, from the message's own "from" (a convenience, not a security check)
					d["_from"] = str(from)
				_apply_map_event(evs, str(msg.get("k", "")), d, pers, false)
		"maps":
			if str(msg.get("s", "")) == _last_scene_path and not SceneLoader.is_transitioning():
				var root := get_tree().current_scene
				if root and root.has_method("coop_map_stream"):
					root.coop_map_stream(msg.get("d", {}), int(msg.get("ts", 0)))
		"mapsync_req":
			var rs := str(msg.get("s", ""))
			if is_host and not rs.is_empty() and (rs == str(map_state.get("scene", "")) or rs == _scene_now()):
				var st := _map_state_for(rs)
				_send_to(from, {"t": "mapsync", "from": _my_steam_id, "s": rs,
						"cp": st["checkpoint"], "ev": st["events"]}, true)
				print("[CoopSync] mapsync sent: checkpoint %d, %d events" % [int(st["checkpoint"]), st["events"].size()])
				# after a CONTINUE, each guest's saved lamp oil follows its first mapsync answer
				if is_instance_valid(save_run) and bool(save_run.wants_oilset(rs, str(from))):
					_send_oilset(from)
		"mapsync":
			if from == _host_steam_id:
				var ev = msg.get("ev", {})
				_on_mapsync(str(msg.get("s", "")), int(msg.get("cp", -1)), ev if ev is Dictionary else {})
		"oilrep":
			# a guest's lamp oil, for the saved run the host keeps
			if map_is_authority() and is_instance_valid(save_run):
				var tk = msg.get("taken", [])
				save_run.on_oil_report(str(from), sanitize_name(str(msg.get("n", "Player"))), float(msg.get("oil", 1.0)), tk if tk is Array else [])
		"oilset":
			if from == _host_steam_id and not is_host:
				_on_oilset(msg)
		"savehold":
			if from == _host_steam_id and not is_host:
				_on_savehold(msg)


# ---------------------------------------------------------------- outgoing state

func _broadcast_state() -> void:
	if not is_instance_valid(_local_player) or not _local_player.is_inside_tree():
		return
	var p = _local_player
	var msg := {
		"t": "p",
		"ts": Time.get_ticks_msec(),
		"from": _my_steam_id,
		"n": local_name,
		"scene": _last_scene_path,
		"pos": p.global_position,
		"cam": p.Camera.global_rotation.y if p.Camera else p.global_rotation.y,
		"cp": p.Camera.global_rotation.x if p.Camera else 0.0,     # camera pitch (radians), for gaze checks
		"hp": p.health,
		"alive": not p.get("coop_spectating"),
		"cos": cosmetics,
		"lan": lantern_on,
		"gnd": p.is_on_floor() and p.get_floor_normal().y > 0.8 and not (p.activeClimberState is ClimberState_Attached),
	}
	if idol_carrier:
		# absent = not the holder, so it costs nothing for everyone else; v5.0 sends 1 + the idol's
		# weight % (0..98) instead of true (a build before 5.0 reads any value as true)
		msg["idl"] = 1 + clampi(idol_weight, 0, 98)
	if omen_tier > 0:
		msg["om"] = omen_tier           # the omen trophy tier: the charm on your lantern (absent = 0)
	if noise_tier > 0:
		msg["nz"] = noise_tier          # v5.1: how loud my voice is (absent = silent)
	if is_instance_valid(lantern) and bool(lantern.get("oil_enabled")):
		msg["ol"] = int(round(float(lantern.get("oil")) * 100.0))   # lamp oil %, for sharing (G)
	if p.Rope and p.Rope.is_setup and p.activeClimberState and p.activeClimberState.is_rope_active() and is_instance_valid(p.Rope._claw) and p.Rope._claw.visible:
		var pts := PackedVector3Array()
		for e in p.Rope._climbing_edges:
			pts.append(e.get_global_position())
		msg["rope"] = pts
		msg["claw"] = p.Rope._claw.global_transform
		msg["att"] = p.activeClimberState is ClimberState_Attached
	_send_all(msg, false)
	if is_host:
		_cent_accum += 1
		if _cent_accum >= 2:          # centipedes at half the player rate: the buffer smooths them
			_cent_accum = 0
			_broadcast_centipedes()


func _broadcast_centipedes() -> void:
	# element 5 is a stable id (review #11): guests match puppets by it, not by list order.
	# Sleepers (a map disables their processing) are left out, so guests hide them.
	# v5.0 no-clip (B1): element 8 is the teleport counter (meta "zonda_tp"); a guest's puppet snaps and
	# rebuilds its body once per change instead of gliding through the rock. Elements 6 and 7 are the
	# cry and roar slots, -1 = "not sent" (the Underdark streams those in its own "cr").
	var list: Array = []
	for c in Game.centipedes:
		if is_instance_valid(c) and c.is_inside_tree() and not bool(c.get("coop_puppet")) and c.process_mode != Node.PROCESS_MODE_DISABLED:
			var cid: String = str(c.get_meta("zonda_cid")) if c.has_meta("zonda_cid") else str(c.get_instance_id())
			list.append([c.global_position, c.global_basis.get_rotation_quaternion(), c._current_state is centipede_state_attack, c.stamina,
					int(c.get_meta("zonda_skin", 0)), cid, -1, -1, int(c.get_meta("zonda_tp", 0))])
	if list.is_empty():
		return
	_send_all({"t": "c", "ts": Time.get_ticks_msec(), "from": _my_steam_id, "s": _last_scene_path, "l": list}, false)


# ---------------------------------------------------------------- incoming state

func _on_player_state(from: int, msg: Dictionary) -> void:
	var scene: String = str(msg.get("scene", ""))
	if scene != _last_scene_path or SceneLoader.is_transitioning():
		return
	var rp = _peers.get(from)
	if not is_instance_valid(rp):
		rp = _spawn_remote_player(from, sanitize_name(str(msg.get("n", "Player"))))
		if rp == null:
			return
	rp.update_state(msg)
	if _await_spawn_sync and from == _host_steam_id and is_instance_valid(_local_player) and _local_player_age > 1.2:
		_await_spawn_sync = false
		var host_pos: Vector3 = msg.get("pos", Vector3.ZERO)
		_local_player.teleport_to_location(_safe_spawn_near(host_pos))
		print("[CoopSync] spawned next to host")


func _is_gameplay_scene(path: String) -> bool:
	if path.is_empty():
		return false
	if Game.active_sandbox_map_data and Game.active_sandbox_map_data.scene_path == path:
		return true
	return false


func _safe_spawn_near(host_pos_in: Vector3) -> Vector3:
	# Never shove a player into geometry: only use the side offset if the path there is clear.
	var host_pos := _map_filter_spawn(host_pos_in)
	var target: Vector3 = host_pos + Vector3(0.8, 0.3, 0.8)
	if not is_instance_valid(_local_player) or not _local_player.is_inside_tree():
		return target
	var space: World3D = _local_player.get_world_3d()
	if space == null:
		return target
	var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(host_pos + Vector3.UP * 0.3, target, 1)
	if space.direct_space_state.intersect_ray(ray).size() > 0:
		return host_pos
	return target


func sanitize_name(raw: String) -> String:
	# Some setups return a file path (or nothing) from Steam's persona name, which then
	# rides along as a player's display name. Reject anything that is not name-shaped.
	var n := raw.strip_edges()
	if n.is_empty():
		return "Player"
	if n.contains("\\") or n.contains("/") or n.contains(":"):
		return "Player"
	return n.substr(0, 24)


func _spawn_remote_player(peer_id: int, player_name: String):
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var rp = RemotePlayerScript.new()
	rp.name = "CoopRemote_%d" % peer_id
	rp.peer_id = peer_id
	rp.player_name = player_name
	scene.add_child(rp)
	_peers[peer_id] = rp
	print("[CoopSync] remote player spawned: ", player_name)
	return rp


func _remove_remote_player(peer_id: int) -> void:
	if _peers.has(peer_id):
		if is_instance_valid(_peers[peer_id]):
			_peers[peer_id].queue_free()
		_peers.erase(peer_id)


func _apply_centipedes(msg: Dictionary) -> void:
	if str(msg.get("s", "")) != _last_scene_path or SceneLoader.is_transitioning():
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var list: Array = msg.get("l", [])
	var now := Time.get_ticks_msec()
	var sender_t: int = int(msg.get("ts", now))
	_purge_puppets()
	for i in list.size():
		var entry: Array = list[i]
		if entry.size() < 4:
			continue
		# the host's stable id (element 5); a host without one falls back to list order
		var cid: String = str(entry[5]) if entry.size() > 5 else "idx:%d" % i
		var pup = _puppet_by_cid.get(cid)
		if not is_instance_valid(pup):
			var skin: int = int(entry[4]) if entry.size() > 4 else 0
			pup = _adopt_or_make_puppet(scene, entry[0], skin)
			if pup == null:
				break                       # centipedes are disabled on this PC
			_puppet_by_cid[cid] = pup
			pup.set_meta("zonda_puppet_cid", cid)      # the host's id (no-clip kind and test points)
			# no-clip (B3): a puppet handed to a new id starts from that creature's first sample with a
			# fresh body (no slide from the old creature's place); only while the no-clip guard is on
			if pup.has_method("coop_nc_rebind"):
				pup.call("coop_nc_rebind")
		_puppet_seen_ms[cid] = now
		if pup.process_mode == Node.PROCESS_MODE_DISABLED:
			pup.process_mode = Node.PROCESS_MODE_INHERIT
			var old_buf = pup.get("_coop_buf")
			if old_buf != null:
				old_buf.clear()             # hidden a while: start from the new state, no slide
			if pup.has_method("coop_nc_rebind"):
				pup.call("coop_nc_rebind")  # B3: and a fresh body and snap latches
		if pup.has_method("coop_apply_state"):
			pup.coop_apply_state(entry, sender_t)


# guest: host centipede id -> the puppet that mirrors it, and when the host last streamed it
var _puppet_by_cid: Dictionary = {}
var _puppet_seen_ms: Dictionary = {}
var _puppet_sweep_ms := 0
const PUPPET_HIDE_MS := 2000
const PUPPET_FREE_MS := 10000


func _adopt_or_make_puppet(scene: Node, at: Vector3, skin: int):
	# A scene's own centipedes become puppets on a guest before the host streams anything:
	# reuse the nearest one nobody owns yet (same skin), else make a new one.
	var owned := {}
	for v in _puppet_by_cid.values():
		if is_instance_valid(v):
			owned[v.get_instance_id()] = true
	var best = null
	var bd := INF
	for p in _puppets:
		if not is_instance_valid(p) or owned.has(p.get_instance_id()) or p.is_queued_for_deletion():
			continue
		if int(p.get("coop_skin")) != skin:
			continue
		var d: float = (p as Node3D).global_position.distance_squared_to(at)
		if d < bd:
			bd = d
			best = p
	if best != null:
		return best
	var nc = load("res://scenes/centipede.tscn").instantiate()
	scene.add_child(nc)                 # its _ready registers it as a puppet (ext/centipede.gd)
	if not is_instance_valid(nc) or nc.is_queued_for_deletion():
		return null
	return nc


func _hide_puppet(p: Node) -> void:
	# hidden and not processing: a hidden puppet must not shove the knight or make sound
	p.visible = false
	p.process_mode = Node.PROCESS_MODE_DISABLED


func _sweep_puppets() -> void:
	# guest: a centipede the host stopped streaming (asleep, freed, re-placed under a new id)
	# is hidden after 2 s and freed after 10 s. Puppets no id owns are hidden too.
	var now := Time.get_ticks_msec()
	if now < _puppet_sweep_ms:
		return
	_puppet_sweep_ms = now + 250
	_purge_puppets()
	var owned := {}
	for cid in _puppet_by_cid.keys():
		var pup = _puppet_by_cid[cid]
		if not is_instance_valid(pup):
			_puppet_by_cid.erase(cid)
			_puppet_seen_ms.erase(cid)
			continue
		var age: int = now - int(_puppet_seen_ms.get(cid, now))
		if age > PUPPET_FREE_MS:
			_puppet_by_cid.erase(cid)
			_puppet_seen_ms.erase(cid)
			_puppets.erase(pup)
			Game.centipedes.erase(pup)
			pup.queue_free()
			continue
		owned[pup.get_instance_id()] = true
		if age > PUPPET_HIDE_MS and pup.visible:
			_hide_puppet(pup)
	for p in _puppets:
		if not is_instance_valid(p) or owned.has(p.get_instance_id()):
			continue
		if not p.has_meta("zonda_unowned_ms"):
			p.set_meta("zonda_unowned_ms", now)
		elif p.visible and now - int(p.get_meta("zonda_unowned_ms")) > PUPPET_HIDE_MS:
			_hide_puppet(p)


# ---------------------------------------------------------------- v5.0 no-clip: shadow puppets (test only)
# The noclip probe (host run) sets noclip_shadows. Every "c" message the loopback drops is also queued
# here (with loss, jitter and late delivery) and applied to SHADOW puppets: centipede.tscn instances
# with meta "zonda_shadow", made on the host. They run exactly the guests' puppet code (interpolation,
# snap latches, bite distance, head clearance) and can never hurt, shove or sound: ext/centipede.gd
# returns before any damage, and no shadow is registered anywhere (targeting, streaming, LOD, unhooks).

func noclip_shadows_clear() -> void:
	# frees every shadow, empties the queue and switches the mirror off (the probe's cleanup)
	for cid in _shadow_by_cid.keys():
		var sh = _shadow_by_cid[cid]
		if is_instance_valid(sh):
			sh.queue_free()
	_shadow_by_cid.clear()
	_shadow_seen_ms.clear()
	_shadow_q.clear()
	noclip_shadows = false


func _noclip_shadow_queue(msg: Dictionary) -> void:
	# an unreliable channel, simulated: dropped with probability loss; the rest wait 0..jitter ms, and a
	# fraction a further 80..150 ms, so they land after newer ones (the puppet's buffer drops them, as a
	# real out-of-order packet is dropped)
	if noclip_shadow_loss > 0.0 and randf() < noclip_shadow_loss:
		return
	var wait := 0
	if noclip_shadow_jitter_ms > 0:
		wait += randi_range(0, noclip_shadow_jitter_ms)
	if noclip_shadow_late > 0.0 and randf() < noclip_shadow_late:
		wait += randi_range(80, 150)
	_shadow_seq += 1
	_shadow_q.append([Time.get_ticks_msec() + wait, _shadow_seq, msg])


func _noclip_shadow_pump() -> void:
	var now := Time.get_ticks_msec()
	if not _shadow_q.is_empty():
		var due: Array = []
		var keep: Array = []
		for q in _shadow_q:
			if int(q[0]) <= now:
				due.append(q)
			else:
				keep.append(q)
		_shadow_q = keep
		due.sort_custom(func(a, b): return int(a[0]) < int(b[0]) or (int(a[0]) == int(b[0]) and int(a[1]) < int(b[1])))
		for q in due:
			_noclip_shadow_apply(q[2])
	for cid in _shadow_by_cid.keys():
		var sh = _shadow_by_cid[cid]
		if not is_instance_valid(sh):
			_shadow_by_cid.erase(cid)
			_shadow_seen_ms.erase(cid)
			continue
		if sh.visible and now - int(_shadow_seen_ms.get(cid, now)) > SHADOW_HIDE_MS:
			_hide_puppet(sh)


func _noclip_shadow_apply(msg: Dictionary) -> void:
	if str(msg.get("s", "")) != _last_scene_path or SceneLoader.is_transitioning():
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var list = msg.get("l", [])
	if not (list is Array):
		return
	var ts := int(msg.get("ts", Time.get_ticks_msec()))
	var now := Time.get_ticks_msec()
	for i in (list as Array).size():
		var entry = list[i]
		if not (entry is Array) or (entry as Array).size() < 4:
			continue
		var cid: String = str(entry[5]) if (entry as Array).size() > 5 else "idx:%d" % i
		var sh = _shadow_by_cid.get(cid)
		if not is_instance_valid(sh):
			var ps = load("res://scenes/centipede.tscn")
			if ps == null:
				return
			sh = ps.instantiate()
			sh.set_meta("zonda_shadow", true)          # before add_child: its _ready reads it
			sh.set_meta("zonda_puppet_cid", cid)       # the host's id: its kind (follower) and test points
			sh.name = "NoclipShadow_%d" % _shadow_seq
			scene.add_child(sh)
			if not is_instance_valid(sh) or sh.is_queued_for_deletion():
				return                                 # centipedes are disabled on this PC
			_shadow_by_cid[cid] = sh
		elif sh.process_mode == Node.PROCESS_MODE_DISABLED:
			sh.process_mode = Node.PROCESS_MODE_INHERIT
			if sh.has_method("coop_nc_rebind"):
				sh.call("coop_nc_rebind")              # re-shown: a fresh buffer, body and latches
		_shadow_seen_ms[cid] = now
		if sh.has_method("coop_apply_state"):
			sh.call("coop_apply_state", entry, ts)


# ---------------------------------------------------------------- events

func broadcast_death() -> void:
	_send_all({"t": "death", "from": _my_steam_id, "n": local_name}, true)


func on_remote_death(who: String) -> void:
	print("[CoopSync] %s died with nobody left, restarting for everyone" % who)
	show_banner("%s died. Everyone is down, restarting the run..." % who, 4.0)
	var c = Game.climber
	if is_instance_valid(c) and c.is_inside_tree() and not c.lethalDamageHandled and not c.prevent_player_death and not SceneLoader.is_transitioning():
		c.coop_remote_death = true
		c.health = 0.0
		c.took_lethal_damage()


func broadcast_ending() -> void:
	_send_all({"t": "ending", "from": _my_steam_id}, true)


func on_remote_ending() -> void:
	var c = Game.climber
	if is_instance_valid(c) and c.is_inside_tree() and not c.in_ending_state and not c.ending_should_trigger_next_step_on_next_collision and not c.prevent_player_death:
		Game.trigger_ending()


# ---------------------------------------------------------------- custom maps

func _map_state_for(scene: String) -> Dictionary:
	if str(map_state.get("scene", "")) != scene:
		map_state = {"scene": scene, "checkpoint": -1, "events": {}}
	return map_state


func _note_checkpoint(scene: String, id: int) -> void:
	if scene.is_empty():
		return
	var st := _map_state_for(scene)
	if id > int(st["checkpoint"]):
		st["checkpoint"] = id
		if is_instance_valid(save_run):
			save_run.note_checkpoint()      # the saved run is written right away at a new checkpoint
		if is_guest():
			_oilrep_due = true              # and a guest reports its lamp oil


func map_checkpoint_for(scene: String) -> int:
	# Takes the path explicitly: a map's _ready runs a frame before this autoload
	# notices the scene change, so _last_scene_path can still be the previous scene.
	if str(map_state.get("scene", "")) != scene:
		return -1
	return int(map_state["checkpoint"])


func map_events_for(scene: String) -> Dictionary:
	if str(map_state.get("scene", "")) != scene:
		return {}
	return map_state["events"]


func _scene_now() -> String:
	# The scene actually loaded right now. A map's _ready and its first frames run before
	# _track_scene_changes notices the new scene, so _last_scene_path can still be the
	# previous scene (often you_died) at that moment.
	var tree := get_tree()
	if tree and tree.current_scene:
		return tree.current_scene.scene_file_path
	return _last_scene_path


func _scene_ok_for_state(scene: String) -> bool:
	# a remote checkpoint / event / mapsync may only touch map_state when it is for the map
	# this player is in, or the one map_state already holds. Anything else (a late packet
	# from a scene the team left) would wipe the current map's events.
	if scene.is_empty():
		return false
	var held := str(map_state.get("scene", ""))
	return scene == held or scene == _scene_now() or held.is_empty()


func map_event_done(key: String) -> bool:
	return str(map_state.get("scene", "")) == _scene_now() and map_state["events"].has(key)


func map_events() -> Dictionary:
	if str(map_state.get("scene", "")) != _scene_now():
		return {}
	return map_state["events"]


func map_event(key: String, data: Dictionary = {}, persist: bool = true) -> void:
	# Applies locally right away, then tells everyone else. Persistent events are
	# idempotent, so a trap or puzzle step never fires twice for the same player.
	var scene := _scene_now()
	if persist and str(map_state.get("scene", "")) == scene and map_state["events"].has(key):
		return
	_apply_map_event(scene, key, data, persist, false)
	if in_session():
		_send_all({"t": "mapev", "from": _my_steam_id, "s": scene, "k": key, "d": data, "p": persist}, true)


func _apply_map_event(scene: String, key: String, data, persist: bool, replay: bool) -> void:
	# replay = true when the event is re-applied from stored state (mapsync from the host):
	# the map then sets the end state quietly, with no banners, stings or animations
	if scene.is_empty() or key.is_empty():
		return
	if persist:
		var st := _map_state_for(scene)
		if st["events"].has(key):
			return
		st["events"][key] = data
		if is_instance_valid(save_run):
			save_run.note_dirty()           # a new persistent event: the saved run is written within 5 s
			if key == "finish":
				save_run.mark_finished()    # a finished run never prompts again
	if scene != _scene_now() or SceneLoader.is_transitioning():
		return                         # stored: the map replays it from map_events_for() on load
	var root := get_tree().current_scene
	if root and root.has_method("coop_map_event"):
		_root_map_event(root, key, data if typeof(data) == TYPE_DICTIONARY else {}, replay)


func _root_map_event(root: Node, key: String, data: Dictionary, replay: bool) -> void:
	# maps built before the quiet replay take (key, data) only; never call them with 3 args
	var rid := root.get_instance_id()
	if rid != _mev_root_id:
		_mev_root_id = rid
		_mev_argc = 2
		for m in root.get_method_list():
			if str(m.get("name", "")) == "coop_map_event":
				var args: Array = m.get("args", [])
				_mev_argc = args.size()
				break
	if _mev_argc >= 3:
		root.coop_map_event(key, data, replay)
	else:
		root.coop_map_event(key, data)


func map_stream(data: Dictionary) -> void:
	if in_session():
		_send_all({"t": "maps", "from": _my_steam_id, "s": _last_scene_path, "ts": Time.get_ticks_msec(), "d": data}, false)


func map_is_authority() -> bool:
	if guestsim == "play":
		return false                        # the guest simulation plays the guest side for the whole launch
	return not in_session() or is_host


func map_checkpoint(id: int, scene: String = "") -> void:
	# a map passes its own scene_file_path: right after a death reload this can run before
	# _last_scene_path has caught up, and the stale path would wipe the team's map state
	var sc: String = scene if not scene.is_empty() else _last_scene_path
	_note_checkpoint(sc, id)
	if in_session():
		_send_all({"t": "checkpoint", "from": _my_steam_id, "s": sc, "cp": id}, true)
		on_checkpoint_reached()
	else:
		show_banner("Checkpoint reached.", 3.0)


func map_request_sync(scene: String = "") -> void:
	var sc: String = scene if not scene.is_empty() else _last_scene_path
	_map_state_for(sc)
	if in_session() and not is_host and not sc.is_empty():
		_send_to(_host_steam_id, {"t": "mapsync_req", "from": _my_steam_id, "s": sc}, true)
		# resent a few times until the host answers (a late joiner's first request can land
		# before the host has the Steam session up)
		_mapsync_scene = sc
		_mapsync_tries = 0
		_mapsync_next_ms = Time.get_ticks_msec() + 2500


func _on_mapsync(sc: String, cp: int, ev: Dictionary) -> void:
	# guest: the host's stored map state for a scene (a separate function so tests can feed it:
	# the loopback never echoes mapsync)
	if sc == _mapsync_scene:
		_mapsync_scene = ""
	# only for the map this player is actually in (or loading into): a stale reply
	# must never wipe the state of the map they are in now
	if _scene_ok_for_state(sc):
		_note_checkpoint(sc, cp)
		for k in ev.keys():
			_apply_map_event(sc, str(k), ev[k], true, true)
		print("[CoopSync] mapsync received: checkpoint %d, %d events" % [cp, ev.size()])


func _retry_mapsync() -> void:
	if not is_guest() or _mapsync_tries >= 4 or _scene_now() != _mapsync_scene:
		_mapsync_scene = ""
		return
	var now := Time.get_ticks_msec()
	if now < _mapsync_next_ms:
		return
	_mapsync_tries += 1
	_mapsync_next_ms = now + 2500
	_send_to(_host_steam_id, {"t": "mapsync_req", "from": _my_steam_id, "s": _mapsync_scene}, true)
	print("[CoopSync] mapsync request resent (%d)" % _mapsync_tries)


func my_id() -> int:
	return _my_steam_id


func alive_player_nodes() -> Array:
	return _alive_player_nodes()


func alive_player_count() -> int:
	return _alive_player_nodes().size()


func remote_players() -> Array:
	return _active_remote_players()


func broadcast_checkpoint() -> void:
	_send_all({"t": "checkpoint", "from": _my_steam_id}, true)


func on_checkpoint_reached() -> void:
	respawns_left = 1
	_clear_souls()
	show_banner("Checkpoint reached. Respawns refreshed for the team.", 4.0)
	var c = Game.climber
	if is_instance_valid(c) and c.is_inside_tree() and c.get("coop_spectating") and c.has_method("coop_revive_at_checkpoint"):
		c.coop_revive_at_checkpoint()


# ---------------------------------------------------------------- souls: co-op rescue
# A player who runs out of respawns leaves a soul where they last stood on solid ground.
# Any living teammate who stays within arm's reach of it for a moment pulls them back into
# the run, right there, without waiting for the next checkpoint. Works on every map.

const SOUL_REACH := 3.2
const SOUL_HOLD_S := 1.5

var _souls: Dictionary = {}          # owner steam id -> Node3D
var _soul_hold := 0.0
var _soul_holding := 0
var _soul_clock := 0.0


func soul_drop(pos: Vector3) -> void:
	if not in_session():
		return
	_spawn_soul(_my_steam_id, local_name, pos)
	_send_all({"t": "soul", "from": _my_steam_id, "n": local_name, "p": pos, "s": _last_scene_path}, true)


func _spawn_soul(owner_id: int, who: String, pos: Vector3) -> void:
	_remove_soul(owner_id)
	var scene := get_tree().current_scene
	if scene == null:
		return
	var root := Node3D.new()
	root.name = "CoopSoul_%d" % owner_id
	root.set_meta("who", who)
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	tex.width = 64
	tex.height = 64
	# the game doubles brightness and clips early, so these stay dim on purpose
	for spec in [[1.7, Color(0.16, 0.24, 0.3, 0.75)], [0.6, Color(0.3, 0.38, 0.42, 0.95)]]:
		var mi := MeshInstance3D.new()
		var qm := QuadMesh.new()
		qm.size = Vector2(spec[0], spec[0])
		mi.mesh = qm
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_texture = tex
		m.albedo_color = spec[1]
		m.disable_fog = true
		m.no_depth_test = nametags_through_walls
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mi)
	var l := OmniLight3D.new()
	l.light_color = Color(0.6, 0.8, 1.0)
	l.light_energy = 0.5
	l.omni_range = 9.0
	l.shadow_enabled = false
	root.add_child(l)
	var lab := Label3D.new()
	lab.text = "%s\n(stay close to pull them back)" % who
	lab.position = Vector3(0, 1.0, 0)
	lab.pixel_size = 0.004
	lab.font_size = 40
	lab.modulate = Color(0.7, 0.85, 1.0)
	lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	lab.no_depth_test = true
	root.add_child(lab)
	scene.add_child(root)
	root.global_position = pos + Vector3(0, 1.1, 0)
	_souls[owner_id] = root


func _remove_soul(owner_id: int) -> void:
	var n = _souls.get(owner_id)
	if is_instance_valid(n):
		n.queue_free()
	_souls.erase(owner_id)


func _clear_souls() -> void:
	for k in _souls.keys():
		_remove_soul(k)


func soul_position(owner_id: int):
	var n = _souls.get(owner_id)
	if is_instance_valid(n) and n.is_inside_tree():
		return n.global_position - Vector3(0, 1.1, 0)
	return null


func rescue_point_for(c: Node3D, soul_pos) -> Vector3:
	if soul_pos is Vector3:
		var spot := _settle_on_ground(c, _map_filter_spawn(soul_pos))
		if spot != Vector3.INF:
			return spot
	return respawn_point_for(c)


func _update_souls(delta: float) -> void:
	if _souls.is_empty():
		return
	_soul_clock += delta
	for k in _souls.keys():
		var n = _souls[k]
		if not is_instance_valid(n) or not n.is_inside_tree():
			_souls.erase(k)
			continue
		if n.get_child_count() > 1:
			(n.get_child(0) as Node3D).position.y = sin(_soul_clock * 1.7) * 0.12
			(n.get_child(1) as Node3D).position.y = sin(_soul_clock * 1.7) * 0.12
	var c = Game.climber
	if not is_instance_valid(c) or not c.is_inside_tree() or c.get("coop_spectating") or c.health <= 0.0:
		_soul_hold = 0.0
		return
	var near := 0
	for k in _souls.keys():
		if k == _my_steam_id:
			continue
		var n2: Node3D = _souls[k]
		if n2.global_position.distance_to(c.global_position + Vector3(0, 0.9, 0)) < SOUL_REACH:
			near = k
			break
	if near == 0:
		_soul_hold = 0.0
		_soul_holding = 0
		return
	if near != _soul_holding:
		_soul_holding = near
		_soul_hold = 0.0
	_soul_hold += delta
	var who := str(_souls[near].get_meta("who", "your teammate"))
	show_banner("Pulling %s back...  stay close" % who, 0.4)
	if _soul_hold >= SOUL_HOLD_S:
		_soul_hold = 0.0
		_soul_holding = 0
		_send_all({"t": "rescue", "from": _my_steam_id, "who": near, "n": local_name}, true)
		_on_rescue(near, local_name, true)


func _on_rescue(who_id: int, by: String, mine: bool) -> void:
	var who := "a teammate"
	var n = _souls.get(who_id)
	if is_instance_valid(n):
		who = str(n.get_meta("who", who))
	var at = soul_position(who_id)
	_remove_soul(who_id)
	if who_id == _my_steam_id:
		var c = Game.climber
		if is_instance_valid(c) and c.is_inside_tree() and c.get("coop_spectating") and c.has_method("coop_revive_by_rescue"):
			c.coop_revive_by_rescue(by, at)
	elif mine:
		show_banner("You pulled %s back." % who, 4.0)
	else:
		show_banner("%s pulled %s back." % [by, who], 4.0)


# ---------------------------------------------------------------- relics: cosmetics earned on custom maps
# Stored per player in user://zonda_cosmetics.cfg. The count rides along in the player state so
# teammates see it: 1 = gold name tag, 2 = gold rope, 3 = a crown.

const RELIC_FILE := "user://zonda_cosmetics.cfg"
var cosmetics := 0
var lantern_on := false          # the hand lantern is lit, so teammates see it on your knight
var _relics: Dictionary = {}


func _load_relics() -> void:
	var cf := ConfigFile.new()
	if cf.load(RELIC_FILE) == OK and cf.has_section("relics"):
		for k in cf.get_section_keys("relics"):
			if bool(cf.get_value("relics", k, false)):
				_relics[str(k)] = true
	cosmetics = _relics.size()


func relic_has(id: String) -> bool:
	return _relics.has(id)


func relic_grant(id: String) -> bool:
	if _relics.has(id):
		return false
	_relics[id] = true
	cosmetics = _relics.size()
	# v5.0: written to omen_file, which tests point at a test file (the real one is only ever read)
	var cf := ConfigFile.new()
	cf.load(omen_file)
	cf.set_value("relics", id, true)
	cf.save(omen_file)
	return true


func _on_remote_unhook() -> void:
	var c = Game.climber
	if not is_instance_valid(c) or not (c.activeClimberState is ClimberState_Attached):
		return
	_purge_puppets()
	if _puppets.size() > 0 and is_instance_valid(_puppets[0]):
		c.Rope._claw.unhook_from_centipede(_puppets[0])


# ---------------------------------------------------------------- voice chat (v4.9)

func _measure_noise(bytes: PackedByteArray) -> void:
	# v5.1: the level of what I am sending (decoded like a teammate would hear it), smoothed
	if voice == null or not voice.has_method("decode"):
		return
	var pcm: PackedFloat32Array = voice.decode(bytes)
	if pcm.is_empty():
		return
	var acc := 0.0
	for x in pcm:
		acc += x * x
	var db := 10.0 * log(acc / pcm.size() + 1e-12) / log(10.0)
	noise_db = maxf(db, noise_db)                 # instant attack, the release is in _noise_decay
	_noise_hold = 0.35


func _noise_decay(delta: float) -> void:
	_noise_hold -= delta
	if _noise_hold <= 0.0:
		noise_db = maxf(-90.0, noise_db - 60.0 * delta)
	var t := 0
	for i in NOISE_DB.size():
		if noise_db >= float(NOISE_DB[i]):
			t = i + 1
	noise_tier = t


func noise_of(n) -> int:
	# 0..3 for the local climber or a teammate's knight; anything else is silent
	if n == null or not is_instance_valid(n):
		return 0
	if noise_force >= 0 and noise_force <= 3:
		return noise_force
	if noise_force == 9:
		return 2                                  # the old tests: as loud as the old triggers assumed
	if n == Game.climber:
		return noise_tier
	var v = n.get("noise_tier")
	return int(v) if v != null else 0


func noise_radius(n) -> float:
	if noise_force == 9:
		return 1e6                                # a dev test that predates the sound rules: hunted as before
	return float(NOISE_R[clampi(noise_of(n), 0, 3)])


func _voice_tick(delta: float) -> void:
	_noise_decay(delta)
	# every frame in a session: refill the bandwidth bucket, poll the mic every 40 ms
	if voice == null:
		return
	_voice_bucket = minf(VOICE_BURST, _voice_bucket + delta * VOICE_BYTES_PER_S)
	_voice_accum += delta
	if _voice_accum < VOICE_POLL_S:
		return
	_voice_accum = minf(_voice_accum - VOICE_POLL_S, VOICE_POLL_S)
	_flat_voice_sweep()
	var bytes: PackedByteArray = voice.poll_capture()
	if bytes.is_empty():
		return
	_measure_noise(bytes)
	_voice_seq += 1
	var msg := {"t": "v", "from": _my_steam_id, "q": _voice_seq, "d": bytes}
	var data: PackedByteArray = var_to_bytes(msg)
	# the developer test tone (voice_test.flag) is raw PCM, far over the cap: it is exempt, but only
	# while this PC really runs the test (a crafted "ZVT1" packet from anyone else stays capped)
	var test: bool = bool(voice.get("_test")) and bytes.size() >= 4 and bytes[0] == 90 and bytes[1] == 86 and bytes[2] == 84 and bytes[3] == 49
	if not test:
		if float(bytes.size()) > _voice_bucket:
			_voice_dropped += 1
			if _voice_dropped % 50 == 1:
				print("[CoopSync] voice over the %d kbps cap, %d chunks dropped" % [int(VOICE_BYTES_PER_S * 8.0 / 1000.0), _voice_dropped])
			return
		_voice_bucket -= float(bytes.size())
		_voice_tx_bytes += bytes.size()
		_voice_tx_t += VOICE_POLL_S
		if _voice_tx_t >= 10.0:
			print("[CoopSync] voice tx: %d bytes/s of voice data (cap %d)" % [int(float(_voice_tx_bytes) / _voice_tx_t), int(VOICE_BYTES_PER_S)])
			_voice_tx_bytes = 0
			_voice_tx_t = 0.0
	if _loopback:
		_loop_queue.append([Time.get_ticks_msec() + 700, msg])
		return
	var count: int = Steam.getNumLobbyMembers(_lobby_id)
	for i in range(count):
		var member: int = Steam.getLobbyMemberByIndex(_lobby_id, i)
		if member != _my_steam_id:
			Steam.sendMessageToUser(member, data, SEND_UNRELIABLE_NO_NAGLE, CH_VOICE)


func _on_voice(from: int, msg: Dictionary) -> void:
	if voice == null or from == 0:
		return
	if voice.is_muted(from):
		return                              # muted: not even decoded
	var q: int = int(msg.get("q", 0))
	var last: int = int(_voice_seq_in.get(from, -1))
	if q <= last and last - q < 5000:
		return                              # late or repeated chunk (unreliable can reorder)
	_voice_seq_in[from] = q
	var d = msg.get("d")
	if not (d is PackedByteArray):
		return
	var raw: PackedByteArray = d
	# raw "ZVT1" test audio is only played while this PC runs the test: voice.decode() checks that
	# itself (a Steam talker whose account id spells "ZVT1" must still be heard)
	if raw.size() > 10 and raw[0] == 90 and raw[1] == 86 and raw[2] == 65 and raw[3] == 49:
		# "ZVA1" (a picked microphone) is decoded in GDScript, not natively like Steam voice: each
		# talker gets at most VOICE_IN_MAX_S seconds of it per second, so a buggy or hostile
		# lobby member can not stall everyone's frame. The rate check keeps a Steam packet that
		# only looks like "ZVA1" (rate 1, see voice.decode) out of the count. A claimed rate over
		# the 16 kHz this build sends is charged as 16 kHz, so a high rate buys no extra decoding.
		var r: int = raw.decode_u16(4)
		if r >= 8000 and not _voice_in_budget(from, float((raw.size() - 10) * 2) / float(mini(r, 16000))):
			_voice_in_dropped += 1
			if _voice_in_dropped % 50 == 1:
				print("[CoopSync] voice in: a talker sent more than %.1f s of audio per second, %d chunks dropped" % [VOICE_IN_MAX_S, _voice_in_dropped])
			return
	var pcm: PackedFloat32Array = voice.decode(d)
	if pcm.is_empty():
		return
	# positional only from a knight that is really here: one left over from before the talker
	# changed level stays in the tree, frozen where they left and hidden, and a voice from
	# there would be far away or silent
	var rp = _peers.get(from)
	if is_instance_valid(rp) and rp.is_inside_tree() and rp.has_method("voice_push") \
			and str(rp.scene_path) == _last_scene_path and Time.get_ticks_msec() - int(rp.last_update_ms) < STALE_MS:
		rp.voice_push(pcm)                  # positional, echoing with the cave (voice_emitter.gd)
	else:
		_flat_voice_push(from, pcm)


func _voice_in_budget(from: int, secs: float) -> bool:
	# true = this much "ZVA1" audio from `from` may be decoded now (and it is counted). The window
	# is shared and cleared every second, so ids that come and go never pile up. The total for
	# everyone together is capped as well, because "from" is whatever the packet says.
	var now := Time.get_ticks_msec()
	if now - _voice_in_ms >= 1000:
		_voice_in_ms = now
		_voice_in_s.clear()
	var used: float = float(_voice_in_s.get(from, 0.0))
	var total: float = float(_voice_in_s.get(0, 0.0))
	if used + secs > VOICE_IN_MAX_S or total + secs > VOICE_IN_MAX_S * float(MAX_MEMBERS - 1):
		return false
	_voice_in_s[from] = used + secs
	_voice_in_s[0] = total + secs
	return true


func _flat_voice_push(from: int, pcm: PackedFloat32Array) -> void:
	# no knight to speak from (menus, loading, a teammate on another level): heard flat
	var gain: float = float(voice.peer_gain(from))
	if gain <= 0.0:
		return
	var e = _flat_voice.get(from)
	if e == null:
		var gen := AudioStreamGenerator.new()
		var sr = voice.get("sample_rate")
		gen.mix_rate = float(sr) if sr != null else 24000.0
		gen.buffer_length = 0.4
		var np := AudioStreamPlayer.new()
		np.stream = gen
		np.bus = &"MainBus" if AudioServer.get_bus_index("MainBus") >= 0 else &"Master"
		add_child(np)
		e = {"p": np, "pb": null, "ms": 0}
		_flat_voice[from] = e
	var pl: AudioStreamPlayer = e["p"]
	if not is_instance_valid(pl):
		_flat_voice.erase(from)
		return
	pl.volume_db = minf(linear_to_db(gain), 6.0)       # 200% x 200% would be +12 dB and clip
	var pb = e["pb"]
	if not pl.playing or pb == null:
		pl.play()
		pb = pl.get_stream_playback()
		e["pb"] = pb
		if pb != null:
			var lead := PackedVector2Array()
			lead.resize(int(float((pl.stream as AudioStreamGenerator).mix_rate) * 0.08))   # 80 ms cushion
			pb.push_buffer(lead)
	if pb == null:
		return
	var frames := PackedVector2Array()
	frames.resize(pcm.size())
	for i in pcm.size():
		frames[i] = Vector2(pcm[i], pcm[i])
	if pb.can_push_buffer(frames.size()):
		pb.push_buffer(frames)
	e["ms"] = Time.get_ticks_msec()


func _flat_voice_sweep() -> void:
	var now := Time.get_ticks_msec()
	for id in _flat_voice.keys():
		var e: Dictionary = _flat_voice[id]
		var pl = e["p"]
		if not is_instance_valid(pl):
			_flat_voice.erase(id)
			continue
		if pl.playing and now - int(e["ms"]) > 3000:
			pl.stop()
			e["pb"] = null


func _free_flat_voice(peer_id: int) -> void:
	var e = _flat_voice.get(peer_id)
	if e != null and is_instance_valid(e["p"]):
		e["p"].queue_free()
	_flat_voice.erase(peer_id)


func _clear_flat_voice() -> void:
	for id in _flat_voice.keys():
		_free_flat_voice(id)
	_flat_voice.clear()


func voice_peers() -> Array:
	# [[steam id, name], ...] of everyone else in the session (the Ghost in loopback), for the F2 panel
	var out: Array = []
	for id in _peer_names.keys():
		out.append([int(id), str(_peer_names[id])])
	return out


func peer_talking(peer_id: int) -> bool:
	var rp = _peers.get(peer_id)
	if is_instance_valid(rp) and rp.has_method("voice_talking") and rp.voice_talking():
		return true
	var e = _flat_voice.get(peer_id)
	return e != null and Time.get_ticks_msec() - int(e["ms"]) < 300


# ---------------------------------------------------------------- lamp oil sharing (v4.9)

func send_oil(to: int, amount: float) -> void:
	# lantern.gd pours `amount` for a teammate standing next to you (hold G)
	_send_to(to, {"t": "oil", "from": _my_steam_id, "to": to, "x": amount, "n": local_name}, true)


# ---------------------------------------------------------------- ui helpers

func _set_status(msg: String) -> void:
	if lobby_ui and lobby_ui.has_method("set_status"):
		lobby_ui.set_status(msg)


func _set_connected(connected: bool) -> void:
	if lobby_ui and lobby_ui.has_method("set_connected"):
		lobby_ui.set_connected(connected)


func get_roster() -> String:
	var names: Array = [local_name + (" (host)" if is_host else "")]
	for id in _peer_names.keys():
		names.append(str(_peer_names[id]) + (" (host)" if id == _host_steam_id else ""))
	return ", ".join(names)


# ---------------------------------------------------------------- guest simulation (guestsim.flag, developer only)
# The loopback never echoes "mapev", "maps" or "mapsync", so no host test runs a guest-side path.
# "record" (with loopback.flag and one feature flag): every "maps" / "mapev" the loopback drops is
# kept with its time since map_loaded, plus where I stand every 0.5 s, and written to
# user://zonda_guestsim.rec every 10 s and on scene exit. "play" (solo, autostart, no feature flag):
# map_is_authority() is false all launch, the recording is played back into the map as a guest
# receives it, and every feature module reports what it saw live (its guestsim_report()). Then the
# late-join pass: a real late joiner has a FRESH map instance (its once-gate and its modules hold
# nothing yet), so this PC drops its map state, reloads the map through SceneLoader, stands where
# the host stood last, and the recording's final state lands through _on_mapsync exactly as that
# joiner's mapsync does. 3 s later the modules report again: the "late join ..." lines come from this
# fresh map, every other line from the live pass. The run ends with "[GUESTSIM] test done P/N PASS".
#
# v5.0 acceptance fix: a recording is ONE map instance of ONE test. It closes (written, no more
# entries) when the recorded map is left (a death reload or a reload_current_scene makes a new
# instance), and 3 s after the recorded module calls guestsim_test_done("<TAG>") at its own
# "test done" line. Before, the recording ran on until the harness killed the game (5 minutes of
# idle streams, then a death reload's second map instance), and playing that back in real time
# never reached the report within the play run's time limit ("playback started", then nothing).
# Playback is also capped (guestsim_play_cap_s, 150 s): past it the remaining reliable events land at
# once, in order, the remaining stream packets collapse to the newest per key, and the host's last
# place is taken. No cap while the no-clip network knobs are set (noclip_gs_*: the noclip probe's guest
# run replays its whole host run) or when a test sets guestsim_play_cap_s <= 0.

const GUESTSIM_REC := "user://zonda_guestsim.rec"
const GUESTSIM_CAP := 60000        # about 20 minutes of an Underdark test (the noclip host run is 14)
const GS_DONE := 8
const GS_END_GRACE_MS := 3000      # record: a test's trailing packets (a dive in flight) are kept this long
const GS_WRITE_BIG := 3000         # record: past this many entries the file is rewritten every 30 s, not 10 s
const GS_PROGRESS_MS := 30000      # play: a progress line this often
var _gs_entries: Array = []
var _gs_scene := ""
var _gs_loaded_ms := -1           # record: the first map_loaded of the recorded scene (offsets count from it)
var _gs_me_t := 0.0
var _gs_write_t := 10.0
var _gs_closed := false           # record: the recording is complete (no more entries)
var _gs_end_at_ms := -1           # record: guestsim_test_done() closes it then
var _gs_end_tag := ""
var guestsim_play_cap_s := 150.0  # play: the longest real-time playback (<= 0: none; none while noclip_gs_* are set)
var _gs_play: Dictionary = {}     # play: the recording
var _gs_idx := 0
# play: 0 idle, 1 waiting 3 s, 2 playing, 3 late-join pass due (live report, then the reload),
# 4 waiting for the fresh map, 5 park due, 6 mapsync due, 7 report due, GS_DONE done
var _gs_phase := 0
var _gs_at_ms := 0
var _gs_t0 := 0
var _gs_prog_ms := 0
var _gs_live_rep: Array = []      # [feature, line] from the live pass
var _gs_late_rep: Array = []      # [feature, line] from the fresh map after the late-join mapsync
var _gs_old_root := 0             # the map instance the recording was played into
var _gs_fresh_ms := -1            # map_loaded of the fresh map (the late-join pass)
var _gs_deadline := 0             # the fresh map must be up by then


func guestsim_test_done(tag: String = "") -> void:
	# A feature test that is being recorded calls this right after printing its "[<TAG>] test done"
	# line: the recording closes GS_END_GRACE_MS later, so the playback holds that test and nothing
	# after it. Any other launch: nothing happens.
	if guestsim != "record" or _gs_closed or _gs_loaded_ms < 0 or _gs_end_at_ms >= 0:
		return
	_gs_end_at_ms = Time.get_ticks_msec() + GS_END_GRACE_MS
	_gs_end_tag = tag
	_guestsim_write()                     # at once too: a harness may stop the game at the done line
	# never the words "test done" here: acceptance.sh takes a log's LAST such line as the test's result
	print("[GUESTSIM] %s test finished: the recording closes in %d s" % [tag if tag != "" else "the recorded", GS_END_GRACE_MS / 1000])


func _guestsim_close(why: String) -> void:
	if _gs_closed or _gs_loaded_ms < 0:
		return
	var span := _guestsim_span(_gs_entries)
	_guestsim_write()
	_gs_closed = true
	print("[GUESTSIM] recording closed (%s): %d entries over %d s" % [why, _gs_entries.size(), span / 1000])


func _guestsim_on_map_loaded(scene: String) -> void:
	if guestsim == "record":
		if _gs_scene != scene and not _gs_closed:
			_gs_scene = scene
			_gs_entries.clear()
			_gs_loaded_ms = Time.get_ticks_msec()
			print("[GUESTSIM] recording %s" % scene)
	elif guestsim == "play" and _gs_phase == 4:
		if scene == _gs_scene:
			_gs_fresh_ms = Time.get_ticks_msec()     # the late-join pass: the fresh map is up
	elif guestsim == "play" and _gs_phase == 0:
		var bytes := FileAccess.get_file_as_bytes(GUESTSIM_REC)
		var d = bytes_to_var(bytes) if bytes.size() > 0 else null
		if not (d is Dictionary) or not ((d as Dictionary).get("entries") is Array):
			_gs_phase = GS_DONE
			print("[GUESTSIM] no recording at %s" % GUESTSIM_REC)
			print("[GUESTSIM] test done 0/1 FAIL: no recording")
			return
		if str((d as Dictionary).get("scene", "")) != scene:
			_gs_phase = GS_DONE
			print("[GUESTSIM] the recording is of %s, not %s" % [str((d as Dictionary).get("scene", "")), scene])
			print("[GUESTSIM] test done 0/1 FAIL: wrong map")
			return
		_gs_play = d
		_gs_scene = scene
		_gs_idx = 0
		_gs_phase = 1
		_gs_at_ms = Time.get_ticks_msec() + 3000
		print("[GUESTSIM] playing %d entries in 3 s (checkpoint %d, %d final events)" % [
			(_gs_play["entries"] as Array).size(), int(_gs_play.get("cp", -1)), (_gs_play.get("final", {}) as Dictionary).size()])


func _guestsim_record(t: String, msg: Dictionary) -> void:
	if _gs_closed or _gs_loaded_ms < 0 or _gs_entries.size() >= GUESTSIM_CAP or str(msg.get("s", "")) != _gs_scene:
		return
	var ms := Time.get_ticks_msec() - _gs_loaded_ms
	if t == "maps":
		_gs_entries.append([ms, "maps", msg.get("d", {})])
	else:
		_gs_entries.append([ms, "mapev", str(msg.get("k", "")), msg.get("d", {}), bool(msg.get("p", true))])


func _guestsim_write() -> void:
	if _gs_closed:
		return                            # complete: a later map state must never overwrite it
	var fin: Dictionary = {}
	var cp := -1
	if str(map_state.get("scene", "")) == _gs_scene:
		fin = (map_state["events"] as Dictionary).duplicate(true)
		cp = int(map_state["checkpoint"])
	var f := FileAccess.open(GUESTSIM_REC, FileAccess.WRITE)
	if f == null:
		print("[GUESTSIM] could not write %s" % GUESTSIM_REC)
		return
	f.store_buffer(var_to_bytes({"scene": _gs_scene, "entries": _gs_entries, "final": fin, "cp": cp}))
	f.close()
	print("[GUESTSIM] recorded %d entries" % _gs_entries.size())


func _guestsim_span(entries: Array) -> int:
	# the recording's length in ms (its last entry's offset)
	if entries.is_empty() or not (entries[entries.size() - 1] is Array):
		return 0
	return int(entries[entries.size() - 1][0])


func _guestsim_cap_ms() -> int:
	# the real-time playback cap in ms (0 = none): none for the noclip guest run (its knobs are set)
	if _guestsim_knobs_on() or guestsim_play_cap_s <= 0.0:
		return 0
	return int(guestsim_play_cap_s * 1000.0)


func _guestsim_knobs_on() -> bool:
	return noclip_gs_loss > 0.0 or noclip_gs_jitter_ms > 0 or noclip_gs_late > 0.0


func _guestsim_queue_maps(e: Array) -> void:
	# B8: a "maps" entry through a simulated unreliable channel (its recorded send time rides along)
	if noclip_gs_loss > 0.0 and randf() < noclip_gs_loss:
		return
	var wait := 0
	if noclip_gs_jitter_ms > 0:
		wait += randi_range(0, noclip_gs_jitter_ms)
	if noclip_gs_late > 0.0 and randf() < noclip_gs_late:
		wait += randi_range(80, 150)
	_gs_pend_seq += 1
	_gs_pend.append([Time.get_ticks_msec() + wait, _gs_pend_seq, e])


func _guestsim_deliver_pending(root: Node, all: bool) -> void:
	if _gs_pend.is_empty():
		return
	var now := Time.get_ticks_msec()
	var due: Array = []
	var keep: Array = []
	for q in _gs_pend:
		if all or int(q[0]) <= now:
			due.append(q)
		else:
			keep.append(q)
	_gs_pend = keep
	due.sort_custom(func(a, b): return int(a[0]) < int(b[0]) or (int(a[0]) == int(b[0]) and int(a[1]) < int(b[1])))
	for q in due:
		var e: Array = q[2]
		if root.has_method("coop_map_stream") and e[2] is Dictionary:
			root.coop_map_stream(e[2], _gs_t0 + int(e[0]))    # the recorded send time: a late one is older


func _guestsim_fast_forward(root: Node, entries: Array) -> int:
	# past the playback cap: every remaining reliable event lands now, in order; the remaining stream
	# packets collapse to the newest per top-level key, and "cx" per creature stream inside it (v5.0:
	# each module stream goes out in its own {"cx": {id: v}} message, so a per-key collapse would keep
	# only the last module's packet); the host's last place is taken
	var last_maps: Dictionary = {}
	var last_me = null
	var n := 0
	while _gs_idx < entries.size():
		var e = entries[_gs_idx]
		_gs_idx += 1
		n += 1
		if not (e is Array) or (e as Array).size() < 3:
			continue
		var kind := str(e[1])
		if kind == "mapev":
			_guestsim_play_one(root, e)
		elif kind == "maps" and e[2] is Dictionary:
			var md: Dictionary = e[2]
			for k in md.keys():
				var v = md[k]
				if str(k) == "cx" and v is Dictionary:
					for k2 in (v as Dictionary).keys():
						last_maps["cx." + str(k2)] = [int(e[0]), {k: {k2: (v as Dictionary)[k2]}}]
				else:
					last_maps[k] = [int(e[0]), {k: v}]
		elif kind == "me":
			last_me = e
	if root.has_method("coop_map_stream"):
		for k in last_maps.keys():
			var ts: int = (_gs_t0 + int(last_maps[k][0])) if _guestsim_knobs_on() else Time.get_ticks_msec()
			root.coop_map_stream(last_maps[k][1], ts)
	if last_me != null:
		_guestsim_play_one(root, last_me)
	return n


func _guestsim_tick(delta: float) -> void:
	if guestsim == "record":
		if _gs_closed or _gs_loaded_ms < 0 or _scene_now() != _gs_scene:
			return
		if _gs_end_at_ms >= 0 and Time.get_ticks_msec() >= _gs_end_at_ms:
			_guestsim_close("after the %s test" % (_gs_end_tag if _gs_end_tag != "" else "recorded"))
			return
		_gs_me_t -= delta
		if _gs_me_t <= 0.0:
			_gs_me_t = 0.5
			var c = Game.climber
			if is_instance_valid(c) and c.is_inside_tree() and _gs_entries.size() < GUESTSIM_CAP:
				var p: Vector3 = c.global_position
				_gs_entries.append([Time.get_ticks_msec() - _gs_loaded_ms, "me", [p.x, p.y, p.z]])
		_gs_write_t -= delta
		if _gs_write_t <= 0.0:
			# a big recording is rewritten less often (each write serializes all of it: a frame hitch)
			_gs_write_t = 10.0 if _gs_entries.size() < GS_WRITE_BIG else 30.0
			_guestsim_write()
		return
	if guestsim != "play" or _gs_phase == 0 or _gs_phase == GS_DONE:
		return
	var now := Time.get_ticks_msec()
	if _gs_phase == 4 and now >= _gs_deadline:
		_gs_phase = GS_DONE
		print("[GUESTSIM] late-join pass: the map did not reload within 60 s")
		_gs_late_rep = [["", "FAIL late join: the map did not reload"]]
		_guestsim_report()
		return
	var root := get_tree().current_scene
	if root == null or root.scene_file_path != _gs_scene or SceneLoader.is_transitioning():
		return
	match _gs_phase:
		1:
			if now >= _gs_at_ms:
				_gs_phase = 2
				_gs_t0 = now
				_gs_prog_ms = now + GS_PROGRESS_MS
				_gs_pend.clear()
				var c = Game.climber
				if is_instance_valid(c):
					c.prevent_player_death = true
				var span := _guestsim_span(_gs_play["entries"])
				var extra := ""
				var cap := _guestsim_cap_ms()
				if cap > 0 and span > cap:
					extra += ", real time capped at %d s" % (cap / 1000)
				if _guestsim_knobs_on():
					extra += ", loss %.2f jitter %d ms late %.2f" % [noclip_gs_loss, noclip_gs_jitter_ms, noclip_gs_late]
				print("[GUESTSIM] playback started: %d s recorded%s" % [span / 1000, extra])
		2:
			var entries: Array = _gs_play["entries"]
			var el := now - _gs_t0
			var knobs := _guestsim_knobs_on()
			var cap := _guestsim_cap_ms()
			if cap > 0 and el >= cap and _gs_idx < entries.size():
				_guestsim_deliver_pending(root, true)
				var ff := _guestsim_fast_forward(root, entries)
				print("[GUESTSIM] playback cap %d s reached: the last %d entries fast-forwarded" % [cap / 1000, ff])
			while _gs_idx < entries.size() and int(entries[_gs_idx][0]) <= el:
				var e: Array = entries[_gs_idx]
				if knobs and str(e[1]) == "maps":
					_guestsim_queue_maps(e)
				else:
					_guestsim_play_one(root, e)
				_gs_idx += 1
			if knobs:
				_guestsim_deliver_pending(root, false)
			if now >= _gs_prog_ms and _gs_idx < entries.size():
				_gs_prog_ms = now + GS_PROGRESS_MS
				print("[GUESTSIM] playing: %d of %d s, %d/%d entries" % [el / 1000, _guestsim_span(entries) / 1000, _gs_idx, entries.size()])
			if _gs_idx >= entries.size():
				_guestsim_deliver_pending(root, true)
				_gs_phase = 3
				_gs_at_ms = now + 3000
				print("[GUESTSIM] playback done: %d entries" % entries.size())
		3:
			if now >= _gs_at_ms:
				# the late-join pass (2.11 step 2). This map applied every event live, and its once-gate
				# (and each module's own state) would drop or short-cut a second apply, so the pass runs
				# on a FRESH map instance, as a real late joiner's does: the live report is kept, this
				# PC's map state is dropped, and the map reloads.
				_gs_live_rep = _guestsim_collect(root)
				_gs_old_root = root.get_instance_id()
				_gs_fresh_ms = -1
				_gs_deadline = now + 60000
				_gs_phase = 4
				map_state = {"scene": "", "checkpoint": -1, "events": {}}
				print("[GUESTSIM] late-join pass: %d live report lines kept, reloading the map fresh" % _gs_live_rep.size())
				SceneLoader.load_scene(func(): Game.load_level_based_on_difficulty(false))
		4:
			if _gs_fresh_ms >= 0 and root.get_instance_id() != _gs_old_root:
				_gs_phase = 5
				_gs_at_ms = now + 1500
		5:
			if now >= _gs_at_ms:
				# a late joiner spawns beside the host: stand where the host stood last
				var c = Game.climber
				if is_instance_valid(c):
					c.prevent_player_death = true
				var last := _guestsim_last_me()
				if last != Vector3.INF:
					_guestsim_play_one(root, [0, "me", [last.x, last.y, last.z]])
				_gs_phase = 6
				_gs_at_ms = now + 1500
		6:
			if now >= _gs_at_ms:
				# the recording's final state, exactly as a late joiner's mapsync lands
				var f0 = _gs_play.get("final", {})
				var fin: Dictionary = (f0 as Dictionary).duplicate(true) if f0 is Dictionary else {}
				_on_mapsync(_gs_scene, int(_gs_play.get("cp", -1)), fin)
				print("[GUESTSIM] late-join pass: a fresh map got the mapsync of %d events" % fin.size())
				_gs_phase = 7
				_gs_at_ms = now + 3000
		7:
			if now >= _gs_at_ms:
				_gs_phase = GS_DONE
				_gs_late_rep = _guestsim_collect(root)
				_guestsim_report()


func _guestsim_play_one(root: Node, e: Array) -> void:
	var kind := str(e[1])
	if kind == "maps":
		if root.has_method("coop_map_stream") and e[2] is Dictionary:
			root.coop_map_stream(e[2], Time.get_ticks_msec())
	elif kind == "mapev":
		var d = e[3]
		var pers := bool(e[4])
		if not pers and d is Dictionary and not (d as Dictionary).has("_from"):
			d["_from"] = my_sid()           # sent by the host, which was this PC when it was recorded
		_apply_map_event(_gs_scene, str(e[2]), d, pers, false)
	elif kind == "me":
		var p: Array = e[2]
		var pos := Vector3(float(p[0]), float(p[1]), float(p[2]))
		if root.has_method("debug_park"):
			root.call("debug_park", pos)
		elif is_instance_valid(Game.climber):
			Game.climber.teleport_to_location(pos)


func _guestsim_last_me() -> Vector3:
	# where the host stood last in the recording (INF when it has no "me" entry)
	var entries = _gs_play.get("entries", [])
	if not (entries is Array):
		return Vector3.INF
	for i in range((entries as Array).size() - 1, -1, -1):
		var e = entries[i]
		if e is Array and (e as Array).size() >= 3 and str(e[1]) == "me" and e[2] is Array and (e[2] as Array).size() >= 3:
			return Vector3(float(e[2][0]), float(e[2][1]), float(e[2][2]))
	return Vector3.INF


func _guestsim_collect(root: Node) -> Array:
	# every feature module's guestsim_report() lines as [feature, line], in load order, not printed:
	# "PASS ...", "FAIL ..." or "SKIP ..." (not counted)
	var out: Array = []
	var feats = root.get("_features")
	if feats is Dictionary:
		for key in (feats as Dictionary).keys():
			var f = feats[key]
			if is_instance_valid(f) and f.has_method("guestsim_report"):
				var rep = f.call("guestsim_report")
				if rep is Array:
					for ln in rep:
						out.append([str(key), str(ln)])
	elif root.has_method("coop_guestsim_done"):
		var r = root.call("coop_guestsim_done")     # a map without _features prints its own lines
		if r is Array:
			for ln in r:
				out.append(["", str(ln)])
	return out


func _guestsim_is_late_line(line: String) -> bool:
	# "PASS late join: ...", "SKIP late join (...)": the lines about the late joiner's fresh map
	var s := line.strip_edges()
	for w in ["PASS", "FAIL", "SKIP"]:
		var ws := str(w)
		if s.begins_with(ws):
			s = s.substr(ws.length()).strip_edges()
			break
	return s.begins_with("late join")


func _guestsim_report() -> void:
	# the live pass's lines, except its "late join" ones, plus the fresh map's "late join" lines
	var merged: Array = []
	for e in _gs_live_rep:
		if not _guestsim_is_late_line(str(e[1])):
			merged.append(e)
	for e in _gs_late_rep:
		if _guestsim_is_late_line(str(e[1])):
			merged.append(e)
	var lines: Array = []
	for e in merged:
		var feat := str(e[0])
		print("[GUESTSIM] %s%s" % ["" if feat.is_empty() else feat + " ", str(e[1])])
		lines.append(str(e[1]))
	var p := 0
	var n := 0
	var fails: Array = []
	for ln in lines:
		var s := str(ln).strip_edges()
		if s.begins_with("PASS"):
			p += 1
			n += 1
		elif s.begins_with("FAIL"):
			n += 1
			fails.append(s.substr(5))
	var c = Game.climber
	if is_instance_valid(c):
		c.prevent_player_death = false
	if fails.is_empty() and n > 0:
		print("[GUESTSIM] test done %d/%d PASS" % [p, n])
	elif n == 0:
		print("[GUESTSIM] test done 0/0 FAIL: no report lines")
	else:
		print("[GUESTSIM] test done %d/%d FAIL: %s" % [p, n, ", ".join(fails)])
