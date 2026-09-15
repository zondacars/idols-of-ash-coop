extends Node

const MOD_DIR := "res://mods-unpacked/zonda-CoopSync/"
const LOBBY_TAG := "ZondaCoopSync1"
const MAX_MEMBERS := 4
const SYNC_HZ := 60.0
const CH_FAST := 0
const CH_EVENT := 1
const STALE_MS := 6000
const SEND_UNRELIABLE_NO_NAGLE := 1

const RemotePlayerScript := preload("res://mods-unpacked/zonda-CoopSync/remote_player.gd")
const LobbyUiScript := preload("res://mods-unpacked/zonda-CoopSync/lobby_ui.gd")

const EXTENSIONS := [
	["res://scripts/climber.gd", "ext/climber.gd"],
	["res://scripts/centipede.gd", "ext/centipede.gd"],
	["res://treasure_pickup.gd", "ext/treasure_pickup.gd"],
	["res://scripts/ending_trigger_area.gd", "ext/ending_trigger_area.gd"],
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
var perf_mod_usec_frame := 0
var perf_mod_usec_avg := 0.0
var _perf_extra_usec := 0
var _banner_layer: CanvasLayer = null
var _banner_label: Label = null
var _banner_until_ms := 0


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
	_build_banner()
	print("[CoopSync] ready")


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
	return "FPS %d  |  frame %.1f ms  |  mod %.2f ms  |  physics %d Hz" % [fps, frame_ms, perf_mod_usec_avg / 1000.0, Engine.physics_ticks_per_second]


func _process_inner(delta: float) -> void:
	Steam.run_callbacks()
	_poll_messages()
	_track_scene_changes()
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

	_sync_accum += delta
	if _sync_accum >= 1.0 / SYNC_HZ:
		_sync_accum = 0.0
		_broadcast_state()

	if not _pending_level.is_empty() and not SceneLoader.is_transitioning():
		var lvl: Dictionary = _pending_level
		_pending_level = {}
		_apply_level(lvl)

	if is_host and _welcome_queue.size() > 0:
		var now := Time.get_ticks_msec()
		for entry in _welcome_queue.duplicate():
			if now >= entry[2]:
				_send_level_to(entry[0])
				entry[1] -= 1
				entry[2] = now + 1500
				if entry[1] <= 0:
					_welcome_queue.erase(entry)


# ---------------------------------------------------------------- public helpers

func in_session() -> bool:
	return _lobby_id != 0


func is_guest() -> bool:
	return _lobby_id != 0 and not is_host


func current_scene_path() -> String:
	return _last_scene_path


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


func respawn_point_for(c: Node3D) -> Vector3:
	var best: Node3D = null
	var best_d := INF
	for rp in _active_remote_players():
		var d: float = c.global_position.distance_squared_to(rp.global_position)
		if d < best_d:
			best_d = d
			best = rp
	if best:
		if best.has_ground:
			return best.last_ground_pos + Vector3(0.5, 0.4, 0.5)
		var floor_hit := _floor_below(c, best.global_position, 12.0)
		if floor_hit != Vector3.INF:
			return floor_hit + Vector3(0.5, 0.9, 0.5)
		return best.global_position + Vector3(0.8, 0.6, 0.8)
	if c.get("_coop_has_ground"):
		return c.get("_coop_last_ground_pos") + Vector3.UP * 0.4
	var own_floor := _floor_below(c, c.global_position, 12.0)
	if own_floor != Vector3.INF:
		return own_floor + Vector3.UP * 0.9
	return c.global_position + Vector3.UP * 0.5


func _floor_below(c: Node3D, from: Vector3, dist: float) -> Vector3:
	if not c.is_inside_tree() or c.get_world_3d() == null:
		return Vector3.INF
	var ray := PhysicsRayQueryParameters3D.create(from + Vector3.UP * 0.5, from + Vector3.DOWN * dist, 1)
	var hit: Dictionary = c.get_world_3d().direct_space_state.intersect_ray(ray)
	if hit.size() > 0:
		return hit["position"]
	return Vector3.INF


func nearest_player_node(from: Vector3) -> Node3D:
	var best: Node3D = null
	var best_d := INF
	if _local_alive():
		best = Game.climber
		best_d = from.distance_squared_to(Game.climber.global_position)
	for rp in _active_remote_players():
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
	out.append_array(_active_remote_players())
	return out


func target_player_for(c: Node3D) -> Node3D:
	if not is_instance_valid(c) or not c.is_inside_tree():
		return null
	var live_cents := 0
	for cent in Game.centipedes:
		if is_instance_valid(cent):
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


func _recompute_centipede_targets(players: Array) -> void:
	_cent_assign.clear()
	var cents: Array = []
	for cent in Game.centipedes:
		if is_instance_valid(cent) and cent.is_inside_tree():
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
	var n := target_player_for(c)
	if n == null:
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
	if not (is_instance_valid(_local_player) and _local_player.is_inside_tree()):
		_local_player = null
	_purge_puppets()
	respawns_left = 1
	_await_spawn_sync = is_guest()
	print("[CoopSync] scene -> ", _last_scene_path)
	if is_host and _lobby_id != 0:
		_broadcast_level()


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
	if SceneLoader.is_transitioning():
		_pending_level = msg
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
	_apply_game_settings(msg)
	if msg.has("map_path") and msg["map_path"] == target:
		SceneLoader.load_scene(func(): Game.load_level_based_on_difficulty(false))
	else:
		SceneLoader.load_scene(func():
			Game.on_new_loaded_level()
			Game.in_main_menu = target.contains("MainMenu")
			get_tree().change_scene_to_file(target))


func _apply_game_settings(msg: Dictionary) -> void:
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
	PlayerData.config.set_value("death", "count", int(msg.get("deaths", 0)))
	PlayerData.saveConfig()


# ---------------------------------------------------------------- lobby (host / join)

func host(player_name: String, pwd: String) -> void:
	if not Game.is_steam_enabled():
		_set_status("Steam is not running / not initialized.")
		_set_connected(false)
		return
	local_name = player_name
	_password = pwd
	is_host = true
	_my_steam_id = Steam.getSteamID()
	_host_steam_id = _my_steam_id
	Steam.createLobby(Steam.LOBBY_TYPE_PUBLIC, MAX_MEMBERS)
	print("[CoopSync] creating lobby")


func join(player_name: String, pwd: String) -> void:
	if not Game.is_steam_enabled():
		_set_status("Steam is not running / not initialized.")
		_set_connected(false)
		return
	local_name = player_name
	_password = pwd
	is_host = false
	_my_steam_id = Steam.getSteamID()
	Steam.addRequestLobbyListStringFilter("coop_game", LOBBY_TAG, Steam.LOBBY_COMPARISON_EQUAL)
	Steam.addRequestLobbyListStringFilter("coop_pwd", str(pwd.hash()), Steam.LOBBY_COMPARISON_EQUAL)
	Steam.requestLobbyList()
	print("[CoopSync] searching lobby")


func disconnect_session() -> void:
	if _lobby_id != 0:
		Steam.leaveLobby(_lobby_id)
		_lobby_id = 0
	for id in _peers.keys():
		_remove_remote_player(id)
	_peers.clear()
	_peer_names.clear()
	_welcome_queue.clear()
	_host_steam_id = 0
	is_host = false
	_applied_level_seq = -1
	print("[CoopSync] disconnected")


func _on_lobby_created(connect: int, lobby_id: int) -> void:
	if lobby_id == 0:
		is_host = false
		_set_status("Failed to create lobby (error %d)." % connect)
		_set_connected(false)
		return
	_lobby_id = lobby_id
	Steam.setLobbyData(lobby_id, "coop_game", LOBBY_TAG)
	Steam.setLobbyData(lobby_id, "coop_pwd", str(_password.hash()))
	_set_status("HOSTING. Share the password.\nYou pick the level, friends follow.\nPlayers: 1 / %d" % MAX_MEMBERS)
	print("[CoopSync] lobby created ", lobby_id)


func _on_lobby_match_list(lobbies: Array) -> void:
	if is_host:
		return
	if lobbies.is_empty():
		_set_status("No lobby found.\nCheck the password, and make sure\nthe host created the lobby first.")
		_set_connected(false)
		return
	Steam.joinLobby(lobbies[0])
	print("[CoopSync] joining lobby ", lobbies[0])


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
	_send_all({"t": "hello", "from": _my_steam_id, "n": local_name}, true)
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
		_send_to(changed_id, {"t": "hello", "from": _my_steam_id, "n": local_name}, true)
		if is_host:
			_welcome_queue.append([changed_id, 3, Time.get_ticks_msec() + 700])
		_set_status("Player joined.\nPlayers: %d / %d" % [count, MAX_MEMBERS])
	else:
		_remove_remote_player(changed_id)
		_peer_names.erase(changed_id)
		if not is_host and changed_id == _host_steam_id:
			disconnect_session()
			_set_status("Host left. Session ended.")
			_set_connected(false)
		else:
			_set_status("Player left.\nPlayers: %d / %d" % [count, MAX_MEMBERS])


func _on_session_request(remote_steam_id: int) -> void:
	Steam.acceptSessionWithUser(remote_steam_id)


# ---------------------------------------------------------------- networking

func _send_to(peer: int, msg: Dictionary, reliable: bool) -> void:
	if _lobby_id == 0 or peer == 0 or peer == _my_steam_id:
		return
	var data: PackedByteArray = var_to_bytes(msg)
	var flags: int = Steam.NETWORKING_SEND_RELIABLE if reliable else Steam.NETWORKING_SEND_UNRELIABLE
	Steam.sendMessageToUser(peer, data, flags, CH_EVENT if reliable else CH_FAST)


func _send_all(msg: Dictionary, reliable: bool) -> void:
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
	if _lobby_id == 0:
		return
	for ch in [CH_FAST, CH_EVENT]:
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
		"level":
			if from == _host_steam_id:
				_apply_level(msg)
		"death":
			on_remote_death(str(msg.get("n", "A player")))
		"pickup":
			_on_remote_pickup(str(msg.get("path", "")), msg.get("pos", Vector3.ZERO), msg.has("pos"))
		"ending":
			on_remote_ending()
		"unhook":
			_on_remote_unhook()


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
		"hp": p.health,
		"alive": not p.get("coop_spectating"),
		"gnd": p.is_on_floor(),
	}
	if p.Rope and p.Rope.is_setup and p.activeClimberState and p.activeClimberState.is_rope_active() and is_instance_valid(p.Rope._claw) and p.Rope._claw.visible:
		var pts := PackedVector3Array()
		for e in p.Rope._climbing_edges:
			pts.append(e.get_global_position())
		msg["rope"] = pts
		msg["claw"] = p.Rope._claw.global_transform
		msg["att"] = p.activeClimberState is ClimberState_Attached
	_send_all(msg, false)
	if is_host:
		_broadcast_centipedes()


func _broadcast_centipedes() -> void:
	var list: Array = []
	for c in Game.centipedes:
		if is_instance_valid(c) and c.is_inside_tree():
			list.append([c.global_position, c.global_basis.get_rotation_quaternion(), c._current_state is centipede_state_attack, c.stamina])
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
		rp = _spawn_remote_player(from, str(msg.get("n", "Player")))
		if rp == null:
			return
	rp.update_state(msg)
	if _await_spawn_sync and from == _host_steam_id and is_instance_valid(_local_player) and _local_player_age > 1.2:
		_await_spawn_sync = false
		var pos: Vector3 = msg.get("pos", Vector3.ZERO)
		_local_player.teleport_to_location(pos + Vector3(0.8, 0.3, 0.8))
		print("[CoopSync] spawned next to host")


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
	var sender_t: int = int(msg.get("ts", Time.get_ticks_msec()))
	_purge_puppets()
	for i in list.size():
		if i >= _puppets.size():
			var nc = load("res://scenes/centipede.tscn").instantiate()
			scene.add_child(nc)
			if not is_instance_valid(nc) or nc.is_queued_for_deletion():
				break
		if i < _puppets.size() and is_instance_valid(_puppets[i]) and _puppets[i].has_method("coop_apply_state"):
			_puppets[i].coop_apply_state(list[i], sender_t)
	for j in range(list.size(), _puppets.size()):
		if is_instance_valid(_puppets[j]):
			_puppets[j].visible = false


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


func broadcast_pickup(path: String, pos: Vector3) -> void:
	_send_all({"t": "pickup", "from": _my_steam_id, "path": path, "pos": pos}, true)


func _on_remote_pickup(path: String, pos: Vector3, has_pos: bool) -> void:
	if path.is_empty():
		return
	var node := get_node_or_null(NodePath(path))
	if node and node.has_method("coop_remote_consume"):
		print("[CoopSync] remote pickup consumed by path: ", path)
		node.coop_remote_consume()
		return
	if not has_pos:
		print("[CoopSync] remote pickup NOT found by path (no pos): ", path)
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var best: Node3D = null
	var best_d := 2.25
	for ember in _find_embers(scene):
		var d: float = ember.global_position.distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = ember
	if best:
		print("[CoopSync] remote pickup consumed by position: ", String(best.get_path()))
		if best.has_method("coop_remote_consume"):
			best.coop_remote_consume()
		else:
			best.queue_free()
	else:
		print("[CoopSync] remote pickup NOT found: ", path, " ", str(pos))


func _find_embers(root: Node) -> Array:
	var out: Array = []
	if root is Node3D and root.scene_file_path == "res://Treasure_Pickup.tscn":
		out.append(root)
	for c in root.get_children():
		out.append_array(_find_embers(c))
	return out


func broadcast_ending() -> void:
	_send_all({"t": "ending", "from": _my_steam_id}, true)


func on_remote_ending() -> void:
	var c = Game.climber
	if is_instance_valid(c) and c.is_inside_tree() and not c.in_ending_state and not c.ending_should_trigger_next_step_on_next_collision and not c.prevent_player_death:
		Game.trigger_ending()


func _on_remote_unhook() -> void:
	var c = Game.climber
	if not is_instance_valid(c) or not (c.activeClimberState is ClimberState_Attached):
		return
	_purge_puppets()
	if _puppets.size() > 0 and is_instance_valid(_puppets[0]):
		c.Rope._claw.unhook_from_centipede(_puppets[0])


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
