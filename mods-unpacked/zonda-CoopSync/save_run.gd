extends Node

# ============================================================================================
# ZondaCoopSync saved runs (v5.0, build contract 3.1). coop_sync adds one as CoopSync.save_run.
#
# WHAT IT DOES
#   A run on a mod map (THE UNDERDARK, INFERNO) survives quitting, a crash or a new session. Only
#   the host's PC (or the solo player's) keeps it, in user://zonda_saves/<map>.json, where <map> is
#   the map's scene file name: "underdark", "inferno". It is never sent to another PC: guests get
#   the state through mapsync as always, then their saved lamp oil through "oilset".
#   A fresh start of that map with an unfinished save opens the CONTINUE / NEW RUN panel
#   (save_prompt.gd, opened by CoopSync.map_loaded).
#
# FILE (JSON, written with JSON.stringify(data, "", false): no key sorting, readers never rely on order)
#   {"v": 1, "scene", "map_build" (layout fingerprint), "mod" (MOD_VERSION), "run" (this run's id),
#    "checkpoint", "checkpoint_label", "events" (CoopSync.map_state["events"]: persistent events only),
#    "clock_s" (team run time), "players": {sid: {"name", "oil", "taken": [flask ids]}},
#    "saved_at" (unix), "names", "finished"}
#   Written atomically: <map>.json.tmp, then the current file to <map>.json.bak, then the tmp renamed.
#   Reading takes the main file, else the newest good copy of .tmp and .bak. .bak and .old.json keep
#   one level each.
#
# WHEN
#   Dirty on any new persistent event, any checkpoint and any oil report (the host's own lantern is
#   checked every 3 s like a guest's, 2% steps). Written at most every 5 s while dirty, at once on a
#   checkpoint and on the "finish" event (finished: true, never prompts again), and on quit or when
#   the team leaves the map. Only while map_is_authority(), in a mod map, and when the run has
#   PROGRESS: checkpoint >= 0 or any event other than "clock" and "hfeint_*".
#   The first write of a new run over an unfinished save renames that save to <map>.old.json.
#   A run this PC joined as a guest (it only became the authority because the host left) never does
#   that: with an unfinished save of the player's own on disk it is not written at all.
#
# API (coop_sync.gd is the only direct caller; others go through CoopSync)
#   func map_key(scene: String) -> String          "" for scenes that are not mod maps
#   func has_save(map_key) -> Dictionary           summary {checkpoint, checkpoint_label, clock_s,
#                                                  saved_at, names, finished, older, src, ...} or {}
#                                                  (both copies unreadable: one banner per launch)
#   func load_into_state(map_key) -> bool          CONTINUE: CoopSync.map_state (checkpoint clamped to
#                                                  one this map has), the clock rewritten to now -
#                                                  clock_s, the host's exact oil, continue_load = true
#   func start_new_run(map_key)                    NEW RUN: <map>.json -> <map>.old.json
#   func note_dirty() / note_checkpoint() / mark_finished()
#   func on_oil_report(sid, name, oil, taken)      a guest's lamp oil (the Ghost's in loopback)
#   func players_for(map_key) -> Dictionary        this run's players table
#   func use_test_dir()                            user://zonda_saves_test/, emptied on the first call
#   func use_savetest_dir()                        user://zonda_saves_savetest/ (savetest only, kept)
#   func save_dir() -> String
#   func has_progress(state: Dictionary) -> bool
#   coop_sync hooks: on_map_loaded, on_scene_change, auto_answer, saved_player, mark_oilset_sent,
#   wants_oilset, begin_savetest (savetest.flag), fmt_hms
#
# ERRORS: an unreadable main file falls back to a copy; both unreadable: no prompt, the banner
# "The saved run could not be read." once. A failed write: "Could not save the run." once, and the
# next write tries again. A player who drops keeps their entry.
# ============================================================================================

const REAL_DIR := "user://zonda_saves/"
const TEST_DIR := "user://zonda_saves_test/"
const SAVETEST_DIR := "user://zonda_saves_savetest/"
const FORMAT_V := 1
const WRITE_GAP_MS := 5000
const OWN_OIL_CHECK_S := 3.0
const MAX_JSON_INT := 9007199254740992      # above this an int loses digits through JSON (R1)

var _dir := REAL_DIR
var _test_dir_done := false
var _dirty := false
var _last_write_ms := -100000
var _run_key := ""                  # the map key of the run this PC keeps
var _run_scene := ""                # its scene path
var _run_id := ""                   # a fresh start gets a new id; a continue keeps the file's
var _run_build := ""                # the map's layout fingerprint, taken while the map was loaded
var _owned := false                 # the file on disk belongs to this run (written, continued or NEW RUN)
var _run_mine := true               # this PC was the authority when the run started (not a guest in it)
var _guest_run_kept := false        # a run joined as a guest found this player's own unfinished save: never written
var _finished := false
var _players: Dictionary = {}       # sid -> {"name", "oil", "taken"}
var _cont_players: Dictionary = {}  # the players table of the save this PC continued (for "oilset")
var cont_scene := ""                # the scene of the last CONTINUE, while the team stays in it
var _oilset_sent: Dictionary = {}   # sid -> true: that guest got its saved oil
var _labels: Dictionary = {}        # checkpoint id -> label, cached while the map was loaded
var _write_failed := false
var _read_banner: Dictionary = {}   # map key -> true: the unreadable banner was shown this launch
var _json_warned: Dictionary = {}
var _own_t := 0.0
var _own_last := -1.0
var _own_taken := -1
var _auto := ""                     # savetest: the panel's automatic answer
var _kill_mid_write := false        # savetest kill: the process dies between the two renames
var writes := 0                     # successful writes this launch (tests)
var last_write_reason := ""
var banners: Array = []             # banners this module showed (tests)
var load_oil := -1.0                # the lamp oil when the map last announced its load (tests)
var load_relights := 0              # and the lantern's relight count then
var cont_relights := -1             # the lantern's relight count when CONTINUE restored the oil (tests)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(delta: float) -> void:
	if _dirty and Time.get_ticks_msec() - _last_write_ms >= WRITE_GAP_MS:
		_write_now("timer")
	_own_t -= delta
	if _own_t <= 0.0:
		_own_t = OWN_OIL_CHECK_S
		_own_oil_check()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# quitting (the window closed): the run as it stands right now
		if _run_key != "" and is_inside_tree() and _scene_is_run():
			_update_own_entry()
			_dirty = true
		if _dirty:
			_write_now("quit")
	elif what == NOTIFICATION_EXIT_TREE:
		if _dirty and is_inside_tree():
			_write_now("exit")


# ---------------------------------------------------------------- folders

func save_dir() -> String:
	return _dir


func use_test_dir() -> void:
	# build contract 1A.2: the test folder, emptied on the first call of the launch. Later calls do
	# nothing at all (they never switch back from the savetest folder).
	if _test_dir_done:
		return
	_test_dir_done = true
	_dir = TEST_DIR
	_empty_dir(TEST_DIR)
	print("[SAVE] test folder %s (emptied)" % TEST_DIR)


func use_savetest_dir() -> void:
	# savetest only: a folder that survives between launches (run1, then continue, ...)
	_test_dir_done = true
	_dir = SAVETEST_DIR
	print("[SAVE] savetest folder %s" % SAVETEST_DIR)


func is_test_dir() -> bool:
	return _dir == TEST_DIR


func _empty_dir(dir: String) -> void:
	if dir == REAL_DIR:
		push_error("[SAVE] refusing to empty the real save folder")
		return
	if not DirAccess.dir_exists_absolute(dir):
		return
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir + f)


func _main(key: String) -> String:
	return _dir + key + ".json"


func _old(key: String) -> String:
	return _dir + key + ".old.json"


# ---------------------------------------------------------------- map keys and progress

func map_key(scene: String) -> String:
	# "res://.../maps/underdark/underdark.tscn" -> "underdark" (mod maps only)
	for m in CoopSync.MOD_MAPS:
		if str(m[1]) == scene:
			return scene.get_file().get_basename().to_lower().replace(" ", "")
	return ""


func has_progress(state: Dictionary) -> bool:
	# a run with nothing but its clock (written on every fresh start) or a harrier feint (which can
	# happen before any real progress) is not worth a save: two idle starts must never rotate a real
	# run away through .old.json
	if int(state.get("checkpoint", -1)) >= 0:
		return true
	var ev = state.get("events", {})
	if ev is Dictionary:
		for k in (ev as Dictionary).keys():
			var ks := str(k)
			if ks != "clock" and not ks.begins_with("hfeint_"):
				return true
	return false


func _scene_is_run() -> bool:
	var root := get_tree().current_scene
	return root != null and root.scene_file_path == _run_scene


func _build_for(scene: String) -> String:
	# the layout fingerprint: the map's own map_build_id() while it is loaded, else the md5 of the
	# layout.json next to its scene (THE UNDERDARK), else ""
	var root := get_tree().current_scene if is_inside_tree() else null
	if root != null and root.scene_file_path == scene and root.has_method("map_build_id"):
		return str(root.call("map_build_id"))
	var lp := scene.get_base_dir() + "/layout.json"
	if FileAccess.file_exists(lp):
		return FileAccess.get_md5(lp)
	return ""


# ---------------------------------------------------------------- run lifecycle (coop_sync hooks)

func on_map_loaded(scene: String, fresh: bool) -> void:
	var key := map_key(scene)
	if key.is_empty():
		return
	if fresh or _run_scene != scene:
		# a new run on this map: new id, and the file on disk is not ours until the first write
		_run_key = key
		_run_scene = scene
		_run_id = _new_run_id()
		_owned = false
		# a guest's copy of the host's run: if the host leaves, this PC becomes the authority, but the
		# run is still the host's (only the host's PC keeps the save, 3.1): it never pushes this player's
		# own unfinished saved run out to .old.json (see _write_now)
		_run_mine = CoopSync.map_is_authority()
		_guest_run_kept = false
		_finished = false
		_dirty = false
		_players.clear()
		_cont_players.clear()
		_labels.clear()
		cont_scene = ""
		_oilset_sent.clear()
	_run_build = _build_for(scene)
	_own_last = -1.0
	_own_taken = -1
	var ln = CoopSync.lantern
	if is_instance_valid(ln):
		load_oil = float(ln.get("oil"))
		load_relights = int(ln.get("relights")) if ln.get("relights") != null else 0


func on_scene_change(prev: String, now: String) -> void:
	# the team left the run's scene (death reload, menu, quit to menu): write what changed
	if prev != "" and prev == _run_scene and _dirty:
		_write_now("left the map")
	if now.contains("MainMenu"):
		cont_scene = ""
		_oilset_sent.clear()


func _new_run_id() -> String:
	return "%d_%d" % [int(Time.get_unix_time_from_system()), randi() % 1000000]


func auto_answer() -> String:
	# the panel's automatic answer: a savetest run's choice, else NEW RUN in the test folder
	if _auto != "":
		print("[SAVE] savetest: auto %s" % ("CONTINUE" if _auto == "continue" else "NEW RUN"))
		return _auto
	if _dir == TEST_DIR:
		print("[SAVE] test folder: auto NEW RUN")
		return "new"
	return ""


# ---------------------------------------------------------------- reading

func _read_one(path: String) -> Dictionary:
	# {} = no file; {"_bad": true} = a file that is not a saved run
	if not FileAccess.file_exists(path):
		return {}
	var txt := FileAccess.get_file_as_string(path)
	if txt.strip_edges().is_empty():
		return {"_bad": true}
	var json := JSON.new()                      # parse() reports a damaged file quietly (no engine ERROR line)
	if json.parse(txt) != OK:
		return {"_bad": true}
	var j = json.data
	if not (j is Dictionary) or int((j as Dictionary).get("v", 0)) < 1 or not ((j as Dictionary).get("events") is Dictionary):
		return {"_bad": true}
	return j


func _good(d: Dictionary) -> bool:
	return not d.is_empty() and not d.has("_bad")


func read_save(key: String, quiet: bool = false) -> Dictionary:
	# the saved run for a map key: the main file, else the newest good copy (.tmp, .bak), else {}
	var main := _main(key)
	var m := _read_one(main)
	if _good(m):
		m["_src"] = "main"
		return m
	var t := _read_one(main + ".tmp")
	var b := _read_one(main + ".bak")
	var pick: Dictionary = {}
	if _good(t) and (not _good(b) or float(t.get("saved_at", 0)) >= float(b.get("saved_at", 0))):
		pick = t
		pick["_src"] = "tmp"
	elif _good(b):
		pick = b
		pick["_src"] = "bak"
	if not pick.is_empty():
		if not quiet:
			print("[SAVE] %s: the main file is %s, using the .%s copy" % [key, "damaged" if m.has("_bad") else "missing", str(pick["_src"])])
		return pick
	if (m.has("_bad") or t.has("_bad") or b.has("_bad")) and not quiet and not _read_banner.has(key):
		_read_banner[key] = true
		print("[SAVE] %s: the saved run could not be read (the file and its backup are damaged)" % key)
		_banner("The saved run could not be read.", 5.0)
	return {}


func has_save(key: String) -> Dictionary:
	if key.is_empty():
		return {}
	var d := read_save(key)
	if d.is_empty():
		return {}
	var scene := str(d.get("scene", ""))
	var names: Array = []
	var nm = d.get("names", [])
	if nm is Array:
		for x in nm:
			names.append(str(x))
	var cur := _build_for(scene)
	return {
		"key": key,
		"scene": scene,
		"checkpoint": int(d.get("checkpoint", -1)),
		"checkpoint_label": str(d.get("checkpoint_label", "")),
		"clock_s": maxi(0, int(d.get("clock_s", 0))),
		"saved_at": int(d.get("saved_at", 0)),
		"names": names,
		"finished": bool(d.get("finished", false)),
		"older": cur != "" and str(d.get("map_build", "")) != cur,
		"mod": str(d.get("mod", "")),
		"events_n": (d.get("events", {}) as Dictionary).size(),
		"src": str(d.get("_src", "main")),
	}


# ---------------------------------------------------------------- CONTINUE and NEW RUN

func load_into_state(key: String) -> bool:
	# CONTINUE: the saved state becomes CoopSync.map_state, so the reload that follows replays it as a
	# death reload does. The clock's t0 is rewritten so hours offline never count, and this player's
	# lantern gets its exact saved oil and taken flasks (no relight floor: continue_load).
	var d := read_save(key)
	if d.is_empty() or bool(d.get("finished", false)):
		return false
	var scene := str(d.get("scene", ""))
	var cur := CoopSync._scene_now()
	if map_key(cur) == key:
		scene = cur
	if scene.is_empty():
		return false
	var ev: Dictionary = (d.get("events", {}) as Dictionary).duplicate(true)
	var clock_s := maxi(0, int(d.get("clock_s", 0)))
	var now := Time.get_unix_time_from_system()
	if ev.get("clock") is Dictionary:
		(ev["clock"] as Dictionary)["t0"] = now - float(clock_s)
	elif clock_s > 0:
		ev["clock"] = {"t0": now - float(clock_s)}
	var saved_cp := int(d.get("checkpoint", -1))
	var cp := _clamp_checkpoint(saved_cp)
	CoopSync.map_state = {"scene": scene, "checkpoint": cp, "events": ev}
	_players = _clean_players(d.get("players", {}))
	_cont_players = _players.duplicate(true)
	_oilset_sent.clear()
	cont_scene = scene
	_run_key = key
	_run_scene = scene
	_run_id = str(d.get("run", "")) if str(d.get("run", "")) != "" else _new_run_id()
	_owned = true
	_run_mine = true
	_guest_run_kept = false
	_finished = false
	_dirty = false
	if cp == saved_cp and str(d.get("checkpoint_label", "")) != "":
		_labels[cp] = str(d.get("checkpoint_label", ""))
	var me := saved_player(CoopSync.my_sid())
	if me.is_empty():
		me = _player_by_name(CoopSync.local_name)
	var ln = CoopSync.lantern
	if me.has("oil") and is_instance_valid(ln) and ln.has_method("import_oil"):
		ln.import_oil({"oil": float(me["oil"]), "taken": me.get("taken", [])})
		_own_last = float(me["oil"])
	if is_instance_valid(ln):
		cont_relights = int(ln.get("relights")) if ln.get("relights") != null else 0
	CoopSync.continue_load = true
	print("[SAVE] continue %s: checkpoint %d%s (%s), %d events, clock %s, %d players" % [
		key, cp, "" if cp == saved_cp else " (saved %d, not in this map)" % saved_cp, str(d.get("checkpoint_label", "")),
		ev.size(), fmt_hms(clock_s), _players.size()])
	return true


func start_new_run(key: String) -> void:
	# NEW RUN (confirmed): the saved run is kept as <map>.old.json, this run starts clean
	_rotate_old(key)
	var sc := CoopSync._scene_now()
	_run_key = key
	if map_key(sc) == key:
		_run_scene = sc
	_run_id = _new_run_id()
	_owned = true
	_run_mine = true
	_guest_run_kept = false
	_finished = false
	_dirty = false
	_players.clear()
	_cont_players.clear()
	cont_scene = ""
	_oilset_sent.clear()
	print("[SAVE] new run on %s: the saved run is kept as %s.old.json" % [key, key])


func _rotate_old(key: String) -> void:
	var main := _main(key)
	var d := read_save(key, true)
	var src := ""
	if not d.is_empty():
		src = main + ({"main": "", "tmp": ".tmp", "bak": ".bak"}.get(str(d.get("_src", "main")), "") as String)
	elif FileAccess.file_exists(main):
		src = main
	if src != "":
		if FileAccess.file_exists(_old(key)):
			DirAccess.remove_absolute(_old(key))
		var err := DirAccess.rename_absolute(src, _old(key))
		if err != OK:
			print("[SAVE] could not keep %s as .old.json (error %d)" % [src, err])
	for suffix in ["", ".tmp", ".bak"]:
		if FileAccess.file_exists(main + suffix):
			DirAccess.remove_absolute(main + suffix)


func _clamp_checkpoint(cp: int) -> int:
	# a checkpoint id this map has, else the nearest lower one, else -1 (the map changed)
	if cp < 0:
		return -1
	var ids := _checkpoint_ids()
	if ids.is_empty():
		return cp
	var best := -1
	for i in ids:
		if i <= cp and i > best:
			best = i
	return best


func _checkpoint_ids() -> Array:
	var out: Array = []
	var root := get_tree().current_scene
	if root == null:
		return out
	if root.has_method("checkpoint_ids"):
		var r = root.call("checkpoint_ids")
		if r is Array:
			for i in r:
				out.append(int(i))
			return out
	var lay = root.get("L")
	if lay is Dictionary:
		for c in (lay as Dictionary).get("checkpoints", []):
			if c is Dictionary:
				out.append(int((c as Dictionary).get("id", -1)))
	return out


func _clean_players(p) -> Dictionary:
	var out: Dictionary = {}
	if not (p is Dictionary):
		return out
	for k in (p as Dictionary).keys():
		var e = p[k]
		if not (e is Dictionary):
			continue
		var c: Dictionary = {"name": str((e as Dictionary).get("name", "Player"))}
		if (e as Dictionary).has("oil"):
			c["oil"] = clampf(float(e["oil"]), 0.0, 1.0)
			var taken: Array = []
			var t = (e as Dictionary).get("taken", [])
			if t is Array:
				for x in t:
					taken.append(str(x))
			c["taken"] = taken
		out[str(k)] = c
	return out


func saved_player(sid: String) -> Dictionary:
	# a player's entry in the save this PC continued ({} = none)
	var e = _cont_players.get(sid)
	return (e as Dictionary).duplicate(true) if e is Dictionary else {}


func _player_by_name(n: String) -> Dictionary:
	# solo fallback (a run saved without Steam ids): the one entry with this name
	var found: Dictionary = {}
	for k in _cont_players.keys():
		var e = _cont_players[k]
		if e is Dictionary and str((e as Dictionary).get("name", "")) == n:
			if not found.is_empty():
				return {}
			found = (e as Dictionary).duplicate(true)
	return found


func mark_oilset_sent(sid: String) -> void:
	_oilset_sent[sid] = true


func wants_oilset(scene: String, sid: String) -> bool:
	return cont_scene != "" and scene == cont_scene and not _oilset_sent.has(sid)


# ---------------------------------------------------------------- dirty, oil reports, finish

func note_dirty() -> void:
	_dirty = true


func note_checkpoint() -> void:
	_dirty = true
	_write_now("checkpoint")


func mark_finished() -> void:
	_finished = true
	_dirty = true
	_write_now("finish")


func on_oil_report(sid: String, pname: String, oil: float, taken: Array) -> void:
	var tk: Array = []
	for x in taken:
		tk.append(str(x))
	_players[sid] = {"name": pname, "oil": clampf(oil, 0.0, 1.0), "taken": tk}
	_dirty = true


func players_for(key: String) -> Dictionary:
	return _players.duplicate(true) if key == _run_key else {}


func _update_own_entry() -> void:
	# the host's own lamp oil comes straight from its lantern (only while the map burns oil: on the
	# way out of the map the last known level is kept)
	var me := CoopSync.my_sid()
	var e: Dictionary = (_players.get(me) as Dictionary).duplicate() if _players.get(me) is Dictionary else {}
	e["name"] = CoopSync.local_name
	var ln = CoopSync.lantern
	if is_instance_valid(ln) and bool(ln.get("oil_enabled")) and ln.has_method("export_oil") and _scene_is_run():
		var x: Dictionary = ln.export_oil()
		e["oil"] = clampf(float(x.get("oil", 1.0)), 0.0, 1.0)
		var taken: Array = []
		var t = x.get("taken", [])
		if t is Array:
			for k in t:
				taken.append(str(k))
		e["taken"] = taken
	_players[me] = e


func _own_oil_check() -> void:
	if _run_key.is_empty() or not CoopSync.map_is_authority() or not _scene_is_run():
		return
	var ln = CoopSync.lantern
	if not is_instance_valid(ln) or not bool(ln.get("oil_enabled")):
		return
	var oil := float(ln.get("oil"))
	var taken_n: int = (ln.get("oil_taken") as Dictionary).size() if ln.get("oil_taken") is Dictionary else 0
	if absf(oil - _own_last) < 0.02 and taken_n == _own_taken:
		return
	_own_last = oil
	_own_taken = taken_n
	_update_own_entry()
	_dirty = true


# ---------------------------------------------------------------- writing

func _write_now(reason: String) -> bool:
	if _run_key.is_empty() or not CoopSync.map_is_authority() or _guest_run_kept:
		_dirty = false
		return false
	if CoopSync.save_prompt_open():
		return false                            # after the panel closes
	var st: Dictionary = CoopSync.map_state
	if str(st.get("scene", "")) != _run_scene or not has_progress(st):
		_dirty = false
		return false
	_last_write_ms = Time.get_ticks_msec()
	if not _owned:
		# the first write of a new run: an unfinished save of another run is kept as .old.json
		var prev := read_save(_run_key, true)
		if not prev.is_empty() and not bool(prev.get("finished", false)) and str(prev.get("run", "")) != _run_id:
			if not _run_mine:
				# a run this PC joined as a guest (it became the authority when the host left): the
				# player's own unfinished run stays untouched, and this one is not saved at all
				_guest_run_kept = true
				_dirty = false
				print("[SAVE] %s: this run was joined as a guest; your own unfinished saved run is kept and this one is not saved" % _run_key)
				return false
			_rotate_old(_run_key)
			print("[SAVE] %s: a new run replaces an unfinished saved run, kept as %s.old.json" % [_run_key, _run_key])
		_owned = true
	var data := _build_data()
	if not _write_file(_run_key, data):
		return false                            # stays dirty: tried again in 5 s
	_dirty = false
	writes += 1
	var first := last_write_reason == ""
	last_write_reason = reason
	if first or reason != "timer":
		print("[SAVE] saved %s (%s): checkpoint %d (%s), %d events, %s played" % [
			_run_key, reason, int(data["checkpoint"]), str(data["checkpoint_label"]), (data["events"] as Dictionary).size(), fmt_hms(int(data["clock_s"]))])
	return true


func flush_now(reason: String = "test") -> bool:
	# write at once if the run can be written (tests)
	_dirty = true
	return _write_now(reason)


func _build_data() -> Dictionary:
	var st: Dictionary = CoopSync.map_state
	var ev: Dictionary = st.get("events", {})
	_json_check(ev)
	_update_own_entry()
	var cp := int(st.get("checkpoint", -1))
	return {
		"v": FORMAT_V,
		"scene": _run_scene,
		"map_build": _run_build,
		"mod": CoopSync.MOD_VERSION,
		"run": _run_id,
		"checkpoint": cp,
		"checkpoint_label": _label_for(cp),
		"events": ev,
		"clock_s": _clock_secs(ev),
		"players": _players,
		"saved_at": int(Time.get_unix_time_from_system()),
		"names": _names(),
		"finished": _finished,
	}


func _label_for(cp: int) -> String:
	var root := get_tree().current_scene
	if root != null and root.scene_file_path == _run_scene:
		var l := ""
		if root.has_method("checkpoint_label"):
			l = str(root.call("checkpoint_label", cp))
		if l.is_empty() and cp >= 0:
			var lay = root.get("L")
			if lay is Dictionary:
				for c in (lay as Dictionary).get("checkpoints", []):
					if c is Dictionary and int((c as Dictionary).get("id", -1)) == cp:
						l = str((c as Dictionary).get("label", ""))
		if not l.is_empty():
			_labels[cp] = l
	if _labels.has(cp):
		return str(_labels[cp])
	return "THE START" if cp < 0 else "CHECKPOINT %d" % (cp + 1)


func _clock_secs(ev: Dictionary) -> int:
	# Underdark: from the "clock" event; a map without one: its run_secs() while loaded, else 0
	var ck = ev.get("clock")
	if ck is Dictionary and float((ck as Dictionary).get("t0", 0.0)) > 0.0:
		return maxi(0, int(Time.get_unix_time_from_system() - float(ck["t0"])))
	var root := get_tree().current_scene
	if root != null and root.scene_file_path == _run_scene and root.has_method("run_secs"):
		return maxi(0, int(root.call("run_secs")))
	return 0


func _names() -> Array:
	var out: Array = [CoopSync.local_name]
	for k in _players.keys():
		var e = _players[k]
		var n := str((e as Dictionary).get("name", "")) if e is Dictionary else ""
		if n != "" and not out.has(n):
			out.append(n)
	var pn = CoopSync.get("_peer_names")
	if pn is Dictionary:
		for v in (pn as Dictionary).values():
			if not out.has(str(v)):
				out.append(str(v))
	return out


func _json_check(ev: Dictionary) -> void:
	# R2: persistent event data must survive JSON. One warning per event key per launch.
	for k in ev.keys():
		var ks := str(k)
		if _json_warned.has(ks):
			continue
		var bad := _json_bad(ev[k])
		if bad != "":
			_json_warned[ks] = true
			push_warning("[SAVE] event %s holds %s: it will not load back the same (JSON-safe data only, R1/R2)" % [ks, bad])


func _json_bad(v) -> String:
	match typeof(v):
		TYPE_NIL, TYPE_BOOL, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME:
			return ""
		TYPE_INT:
			return "an int too large for JSON (a Steam id? use a String)" if absi(int(v)) > MAX_JSON_INT else ""
		TYPE_ARRAY:
			for x in v:
				var b := _json_bad(x)
				if b != "":
					return b
			return ""
		TYPE_DICTIONARY:
			for kk in (v as Dictionary).keys():
				if typeof(kk) != TYPE_STRING and typeof(kk) != TYPE_STRING_NAME:
					return "a non-String key"
				var b := _json_bad(v[kk])
				if b != "":
					return b
			return ""
	return "a %s" % type_string(typeof(v))


func _write_file(key: String, data: Dictionary) -> bool:
	# atomic: <key>.json.tmp, the current file to .bak, then the tmp renamed over the real name
	if not DirAccess.dir_exists_absolute(_dir):
		var e0 := DirAccess.make_dir_recursive_absolute(_dir)
		if e0 != OK:
			return _fail("cannot create %s (error %d)" % [_dir, e0])
	var main := _main(key)
	var f := FileAccess.open(main + ".tmp", FileAccess.WRITE)
	if f == null:
		return _fail("cannot open %s.tmp (error %d)" % [main, FileAccess.get_open_error()])
	f.store_string(JSON.stringify(data, "", false))
	f.flush()
	var werr := f.get_error()
	f.close()
	if werr != OK and werr != ERR_FILE_EOF:
		return _fail("writing %s.tmp failed (error %d)" % [main, werr])
	if FileAccess.file_exists(main):
		if FileAccess.file_exists(main + ".bak"):
			DirAccess.remove_absolute(main + ".bak")
		var e1 := DirAccess.rename_absolute(main, main + ".bak")
		if e1 != OK:
			return _fail("cannot move %s to .bak (error %d)" % [main, e1])
	if _kill_mid_write:
		# savetest kill: die in the worst window (main file moved away, tmp not renamed yet)
		printerr("[SAVETEST] kill: the game is killed mid-write now")
		OS.kill(OS.get_process_id())
	var e2 := DirAccess.rename_absolute(main + ".tmp", main)
	if e2 != OK:
		return _fail("cannot rename %s.tmp (error %d)" % [main, e2])
	return true


func _fail(msg: String) -> bool:
	print("[SAVE] write failed: %s" % msg)
	if not _write_failed:
		_write_failed = true
		_banner("Could not save the run.", 5.0)
	return false


func _banner(text: String, secs: float) -> void:
	banners.append(text)
	print("[SAVE] banner: %s" % text)
	CoopSync.show_banner(text, secs)


func fmt_hms(secs: int) -> String:
	secs = maxi(0, secs)
	return "%d:%02d:%02d" % [secs / 3600, (secs / 60) % 60, secs % 60]


# ---------------------------------------------------------------- savetest.flag (developer only, A-SAVE)
# The content picks the run; each run is its own launch (autostart), in this order:
#   run1      the savetest folder is emptied; no save without progress; 3 checkpoints, a kiln, a
#             fragment, a flask, the omen/idol/feint test events, oil 0.05; the file is logged; quit
#   continue  auto CONTINUE: checkpoint, events, kiln, fragment, clock, oil EXACT, taken, the
#             idol id, the omen lit set, the idol holder and passes 9
#   new       auto NEW RUN: the confirm, <map>.old.json, the clock starts after the panel
#   loop      (with loopback.flag) the hold panel on the Ghost's side, the oilset -> oilrep round
#             trip, the continue handshake by direct calls
#   corrupt   a damaged file with a good .bak, then both damaged (one banner)
#   inferno   (AUTOSTART=INFERNO) save at REST PLATFORM 2, then a fresh start and CONTINUE
#   kill      crash windows simulated, then the game kills itself mid-write
#   real      the kill leftover is readable; the real folder is touched only through
#             zz_savetest.json and every other file there is byte-identical after; the savetest
#             folder is deleted
# Every run but real uses user://zonda_saves_savetest/ (kept between launches). Tag [SAVETEST].

const ST_MARKER := "user://zonda_savetest.txt"
const ST_RUNS := ["run1", "continue", "new", "loop", "corrupt", "inferno", "kill", "real"]
var _st_run := ""
var _st_pass := 0
var _st_total := 0
var _st_fails: Array = []
var _st_seen_loads := 0


func begin_savetest(run: String) -> void:
	_st_run = run
	print("[SAVETEST] run %s" % run)
	if not ST_RUNS.has(run):
		print("[SAVETEST] test done 0/1 FAIL: unknown run '%s'" % run)
		return
	if run != "real":
		use_savetest_dir()
	if run == "run1":
		_empty_dir(SAVETEST_DIR)
		DirAccess.remove_absolute(ST_MARKER)
	if run == "loop":
		CoopSync.set("_loop_step", 7)           # R12: the loopback's own soul and spectate script stays out of it
	_auto = "continue" if run == "continue" or run == "inferno" else "new"
	_savetest.call_deferred()


func _st_check(ok: bool, what: String) -> void:
	_st_total += 1
	if ok:
		_st_pass += 1
	else:
		_st_fails.append(what.get_slice(" (", 0))
	print("[SAVETEST] %s %s" % ["PASS" if ok else "FAIL", what])


func _st_wait(secs: float) -> void:
	await get_tree().create_timer(secs, true).timeout


func _st_wait_map(want_fresh: int = -1, timeout: float = 150.0) -> bool:
	# a map_loaded newer than the last one seen (fresh or not when asked), its climber in the tree and
	# the panel closed
	var t := 0.0
	while t < timeout:
		var lm: Dictionary = CoopSync.last_map_loaded
		var root := get_tree().current_scene
		if CoopSync.map_loads > _st_seen_loads and (want_fresh < 0 or bool(lm.get("fresh", false)) == (want_fresh == 1)) \
				and root != null and root.scene_file_path == str(lm.get("scene", "")) and is_instance_valid(Game.climber) \
				and Game.climber.is_inside_tree() and not CoopSync.save_prompt_open() and not SceneLoader.is_transitioning():
			_st_seen_loads = CoopSync.map_loads
			return true
		await _st_wait(0.25)
		t += 0.25
	_st_check(false, "map loaded within %d s" % int(timeout))
	return false


func _st_park(root: Node, pos: Vector3) -> void:
	var c = Game.climber
	if root.has_method("debug_park"):
		root.call("debug_park", pos)
	else:
		c.set_climber_state(c.defaultClimberState)
		c.velocity = Vector3.ZERO
		c.teleport_to_location(pos)


func _st_files(key: String) -> Array:
	var out: Array = []
	for suffix in [".json", ".json.tmp", ".json.bak", ".old.json"]:
		if FileAccess.file_exists(_dir + key + suffix):
			out.append(key + suffix)
	return out


func _st_done() -> void:
	var c = Game.climber
	if is_instance_valid(c):
		c.prevent_player_death = false
	if _st_fails.is_empty():
		print("[SAVETEST] test done %d/%d PASS" % [_st_pass, _st_total])
	else:
		print("[SAVETEST] test done %d/%d FAIL: %s" % [_st_pass, _st_total, ", ".join(_st_fails)])


func _savetest() -> void:
	match _st_run:
		"run1":
			await _st_run1()
		"continue":
			await _st_continue()
		"new":
			await _st_new()
		"loop":
			await _st_loop()
		"corrupt":
			await _st_corrupt()
		"inferno":
			await _st_inferno()
		"kill":
			await _st_kill()
		"real":
			await _st_real()
	if _st_run == "kill":
		return                                      # killed itself (see _st_kill)
	_st_done()
	if _st_run == "run1":
		await _st_wait(1.0)
		get_tree().quit()


func _st_layout_pos(e) -> Vector3:
	var p = (e as Dictionary).get("pos", []) if e is Dictionary else []
	if p is Array and (p as Array).size() >= 3:
		return Vector3(float(p[0]), float(p[1]), float(p[2]))
	return Vector3.INF


func _st_run1() -> void:
	if not await _st_wait_map(1):
		return
	var root := get_tree().current_scene
	var scene := root.scene_file_path
	var key := map_key(scene)
	var c = Game.climber
	c.prevent_player_death = true
	# 1. a fresh start with only its clock must write nothing
	for _i in 40:
		if CoopSync.map_event_done("clock"):
			break
		await _st_wait(0.25)
	print("[SAVETEST] clock stored: %s, events %s" % [str(CoopSync.map_event_done("clock")), str(CoopSync.map_events_for(scene).keys())])
	flush_now("test")
	await _st_wait(6.0)
	_st_check(_st_files(key).is_empty() and has_progress(CoopSync.map_state) == false, "no save without progress (files %s)" % str(_st_files(key)))
	# 2. the omen test events FIRST (R1/R2 shapes): the omen module seals the altar by itself as soon
	# as checkpoint 0 is reached, and the first stored omen_seal wins, so written after the checkpoints
	# the test's own seal would be dropped and the continue check would compare [] with []
	var me := CoopSync.my_sid()
	var omens := ["hearth", "thirst", "brood", "follower", "bells", "bones", "shrines", "silk"]
	var lit: Array = []
	for seq in range(1, 12):
		var act := "light"
		var oid := ""
		if seq <= 8:
			oid = omens[seq - 1]
			lit.append(oid)
		elif seq == 9:
			oid = "silk"
			act = "snuff"
			lit.erase("silk")
		elif seq == 10:
			oid = "silk"
			lit.append("silk")
		else:
			oid = "bells"
			act = "snuff"
			lit.erase("bells")
		CoopSync.map_event("omenset_%d" % seq, {"seq": seq, "lit": lit.duplicate(), "act": act, "id": oid, "by": CoopSync.local_name, "req": me})
	CoopSync.map_event("omen_seal", {"lit": lit.duplicate(), "who": [me], "by": CoopSync.local_name, "seq": 12})
	var seal_now = CoopSync.map_events_for(scene).get("omen_seal")
	var seal_lit: Array = (seal_now as Dictionary).get("lit", []) if seal_now is Dictionary else []
	var want_lit := lit.duplicate()
	var got_lit := seal_lit.duplicate()
	want_lit.sort()
	got_lit.sort()
	_st_check(not want_lit.is_empty() and got_lit == want_lit, "the stored omen_seal is the test's (lit %s, test %s)" % [str(seal_lit), str(lit)])
	# 3. three checkpoints (each one writes at once)
	var lay = root.get("L")
	if not (lay is Dictionary):
		_st_check(false, "the map layout")
		return
	for id in [0, 1, 2]:
		var p := Vector3.INF
		for k in (lay as Dictionary).get("checkpoints", []):
			if int(k.get("id", -1)) == id:
				p = _st_layout_pos(k)
		if p == Vector3.INF:
			continue
		_st_park(root, p + Vector3(0.5, 0.2, 0.5))
		await _st_wait(1.5)
		CoopSync.map_checkpoint(id, scene)
		await _st_wait(0.5)
	_st_check(CoopSync.map_checkpoint_for(scene) == 2 and FileAccess.file_exists(_main(key)), "3 checkpoints, saved at once (checkpoint %d, writes %d)" % [CoopSync.map_checkpoint_for(scene), writes])
	# 4. a kiln, a fragment and a flask
	var kilns: Array = (lay as Dictionary).get("kilns", [])
	var frags: Array = (lay as Dictionary).get("fragments", [])
	var oils: Array = (lay as Dictionary).get("oil", [])
	var kiln_key := "kiln_%d" % int(kilns[0].get("idx", 0)) if not kilns.is_empty() else ""
	var frag_id := str(frags[0].get("id", "")) if not frags.is_empty() else ""
	var flask := str(oils[0].get("id", "")) if not oils.is_empty() else ""
	if kiln_key != "":
		CoopSync.map_event(kiln_key, {})
	if frag_id != "":
		CoopSync.map_event("frag_" + frag_id, {"by": CoopSync.local_name})
	var ln = CoopSync.lantern
	if flask != "" and is_instance_valid(ln):
		(ln.get("oil_taken") as Dictionary)[flask] = true
	# 5. the persistent test events of the other features (R1/R2 shapes; the omens went in at 2)
	CoopSync.map_event("idol", {"by": CoopSync.local_name, "id": me})
	await _st_wait(1.5)
	_st_check(CoopSync.map_event_done("idolpass_1"), "the idol module wrote its confirm idolpass_1")
	var prev := me
	for n in range(2, 12):
		var holder := me if n % 2 == 1 else "777"
		var orphan := n == 5
		CoopSync.map_event("idolpass_%d" % n, {"n": n, "id": holder, "by": "Me" if holder == me else "Ghost",
				"giver": prev, "giver_by": "Me" if prev == me else "Ghost", "orphan": orphan, "confirm": false})
		prev = holder
	CoopSync.map_event("hfeint_mouth", {})
	# 6. the lamp oil (below the 25% relight floor: a continue must keep it exactly)
	if is_instance_valid(ln):
		ln.set("oil", 0.05)
	await _st_wait(0.5)
	_st_check(flush_now("test"), "written")
	var d := read_save(key, true)
	var pe = (d.get("players", {}) as Dictionary).get(me, {}) if not d.is_empty() else {}
	var ev: Dictionary = d.get("events", {}) if not d.is_empty() else {}
	print("[SAVETEST] file %s: checkpoint %d (%s), %d events, clock %d s, players %s, names %s" % [
		_main(key), int(d.get("checkpoint", -9)), str(d.get("checkpoint_label", "")), ev.size(), int(d.get("clock_s", -1)),
		JSON.stringify(d.get("players", {})), str(d.get("names", []))])
	print("[SAVETEST] events: %s" % str(ev.keys()))
	_st_check(int(d.get("checkpoint", -9)) == 2 and ev.has("omen_seal") and ev.has("idolpass_11") and ev.has("hfeint_mouth"), "the file holds the run")
	_st_check(pe is Dictionary and absf(float((pe as Dictionary).get("oil", -1.0)) - 0.05) < 0.0001 and ((pe as Dictionary).get("taken", []) as Array).has(flask), "my oil 0.05 and the taken flask are saved")
	_st_check(str(d.get("scene", "")) == scene and str(d.get("mod", "")) == CoopSync.MOD_VERSION and float(d.get("v", 0)) == 1.0, "format v1, scene, mod")
	var f := FileAccess.open(ST_MARKER, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"kiln": kiln_key, "frag": frag_id, "flask": flask, "lit": lit}))
		f.close()


func _st_marker() -> Dictionary:
	if not FileAccess.file_exists(ST_MARKER):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(ST_MARKER)) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


func _st_continue() -> void:
	var key := "underdark"
	var saved := read_save(key, true)
	if saved.is_empty():
		_st_check(false, "a saved run from run1 in %s" % _dir)
		return
	var mk := _st_marker()
	# the fresh load opens the panel and answers CONTINUE; the reload is the continued run
	if not await _st_wait_map(0):
		return
	var root := get_tree().current_scene
	var scene := root.scene_file_path
	var c = Game.climber
	c.prevent_player_death = true
	var me := CoopSync.my_sid()
	var sp: Dictionary = (saved.get("players", {}) as Dictionary).get(me, {})
	var soil := float(sp.get("oil", -1.0))
	var tops := load_relights - cont_relights
	print("[SAVETEST] continued: oil at load %.4f, saved %.4f, relight top-ups during the continue %d" % [load_oil, soil, tops])
	# the lantern burns while the map finishes loading (a fraction of a second is 0.0005 of the oil), so the
	# check is "the saved amount, not a refill": within 0.003 (about 3 s of burn) and no relight top-up
	_st_check(cont_relights >= 0 and absf(load_oil - soil) < 0.003 and tops == 0, "oil exact (saved %.4f, loaded %.4f, no relight banner)" % [soil, load_oil])
	_st_check(CoopSync.map_checkpoint_for(scene) == int(saved.get("checkpoint", -9)), "checkpoint %d (saved %d)" % [CoopSync.map_checkpoint_for(scene), int(saved.get("checkpoint", -9))])
	var live: Dictionary = CoopSync.map_events_for(scene)
	var sev: Dictionary = saved.get("events", {})
	var missing: Array = []
	for k in sev.keys():
		if not live.has(k):
			missing.append(str(k))
	_st_check(missing.is_empty(), "events restored n=%d of %d (missing %s)" % [live.size(), sev.size(), str(missing)])
	var kiln_ok := false
	var kilns = root.get("_kilns")
	if kilns is Dictionary and str(mk.get("kiln", "")) != "":
		var kn = (kilns as Dictionary).get(int(str(mk["kiln"]).substr(5)))
		kiln_ok = kn != null and bool(kn.get("lit"))
	_st_check(kiln_ok, "kiln lit (%s)" % str(mk.get("kiln", "?")))
	var frag_ok := false
	var frs = root.get("_fragments")
	if frs is Dictionary and str(mk.get("frag", "")) != "":
		var fr = (frs as Dictionary).get(str(mk["frag"]))
		frag_ok = fr != null and bool(fr.get("collected"))
	_st_check(frag_ok, "fragment collected (%s)" % str(mk.get("frag", "?")))
	var rs := -1
	if root.has_method("run_secs"):
		rs = int(root.call("run_secs"))
	elif root.get("_clock_t0") != null and float(root.get("_clock_t0")) > 0.0:
		rs = int(Time.get_unix_time_from_system() - float(root.get("_clock_t0")))
	var cs := int(saved.get("clock_s", 0))
	_st_check(rs >= cs and rs - cs <= 60, "clock %d s (saved %d s, not wall time)" % [rs, cs])
	var taken: Array = []
	var ot = CoopSync.lantern.get("oil_taken") if is_instance_valid(CoopSync.lantern) else null
	if ot is Dictionary:
		taken = (ot as Dictionary).keys()
	var st_taken: Array = sp.get("taken", [])
	var same := taken.size() == st_taken.size()
	for x in st_taken:
		if not taken.has(str(x)):
			same = false
	_st_check(same and taken.has(str(mk.get("flask", ""))), "taken flasks %s (saved %s)" % [str(taken), str(st_taken)])
	var idol = live.get("idol")
	_st_check(idol is Dictionary and (idol as Dictionary).get("id") is String, "idol id is a String (%s)" % str(idol))
	# after the omen and idol modules' replay
	await _st_wait(2.0)
	var omen = root.call("feature", "omen") if root.has_method("feature") else null
	var seal = sev.get("omen_seal", {})
	var want: Array = (seal as Dictionary).get("lit", []) if seal is Dictionary else []
	var got: Array = []
	if omen != null and is_instance_valid(omen) and omen.has_method("lit_ids"):
		var li = omen.call("lit_ids")
		if li is Array:
			got = li
	var a := want.duplicate()
	var b := got.duplicate()
	a.sort()
	b.sort()
	# the stored seal must be run1's own (7 lit), or [] == [] would pass on an empty altar
	var intended: Array = mk.get("lit", []) if mk.get("lit", []) is Array else []
	var i2 := intended.duplicate()
	i2.sort()
	_st_check(omen != null and a == b and not a.is_empty() and (intended.is_empty() or a == i2), "lit set equals omen_seal.lit (%s, want %s, run1 wrote %s)" % [str(got), str(want), str(intended)])
	var idm = root.call("feature", "idol") if root.has_method("feature") else null
	var ip11 = sev.get("idolpass_11", {})
	var want_holder := str((ip11 as Dictionary).get("id", "")) if ip11 is Dictionary else ""
	var holder := str(idm.call("holder_sid")) if idm != null and is_instance_valid(idm) and idm.has_method("holder_sid") else "?"
	_st_check(holder == want_holder, "holder %s equals idolpass_11.id %s" % [holder, want_holder])
	var want_passes := 0
	for k in sev.keys():
		var e = sev[k]
		if str(k).begins_with("idolpass_") and e is Dictionary and not bool((e as Dictionary).get("confirm", false)) and not bool((e as Dictionary).get("orphan", false)):
			want_passes += 1
	var passes := int(idm.call("passes")) if idm != null and is_instance_valid(idm) and idm.has_method("passes") else -1
	_st_check(passes == want_passes and want_passes == 9, "passes %d (stored real passes %d)" % [passes, want_passes])


func _st_new() -> void:
	var key := "underdark"
	var had := FileAccess.file_exists(_main(key))
	_st_check(had, "a saved run to replace")
	var sp = CoopSync.save_prompt
	if not await _st_wait_map(1):
		return
	_st_check(is_instance_valid(sp) and bool(sp.get("confirm_seen")), "confirm shown")
	_st_check(FileAccess.file_exists(_old(key)) and not FileAccess.file_exists(_main(key)), "moved to .old.json (files %s)" % str(_st_files(key)))
	var closed := float(sp.get("closed_unix")) if is_instance_valid(sp) else 0.0
	var t0 := 0.0
	for _i in 60:
		var ck = CoopSync.map_events().get("clock")
		if ck is Dictionary:
			t0 = float((ck as Dictionary).get("t0", 0.0))
			break
		await _st_wait(0.25)
	_st_check(t0 > 0.0 and t0 >= closed - 0.05, "clock after panel (t0 %.2f, panel closed %.2f)" % [t0, closed])
	var scene := get_tree().current_scene.scene_file_path
	_st_check(CoopSync.map_checkpoint_for(scene) == -1 and not has_progress(CoopSync.map_state), "the map starts fresh (checkpoint %d, events %s)" % [CoopSync.map_checkpoint_for(scene), str(CoopSync.map_events_for(scene).keys())])


func _st_loop() -> void:
	if not await _st_wait_map(-1):
		return
	CoopSync.set("_loop_step", 7)
	_st_check(bool(CoopSync.get("_loopback")), "loopback on (loopback.flag)")
	var sp = CoopSync.save_prompt
	var root := get_tree().current_scene
	var scene := root.scene_file_path
	await _st_wait(1.0)
	# 1. the hold, as the Ghost sees it
	CoopSync._save_hold_send(true, false, "")
	var shown := false
	for _i in 12:
		await _st_wait(0.125)
		if is_instance_valid(sp) and bool(sp.call("hold_visible")):
			shown = true
			break
	_st_check(shown, "hold shown on the guest side")
	await _st_wait(2.5)
	_st_check(is_instance_valid(sp) and not bool(sp.call("hold_visible")), "hold released after 2 s")
	# 2. oilset -> oilrep round trip with the Ghost
	_cont_players[str(CoopSync.LOOP_ID)] = {"name": "Ghost", "oil": 0.37, "taken": ["oil_3"]}
	_oilset_sent.erase(str(CoopSync.LOOP_ID))
	_players.erase(str(CoopSync.LOOP_ID))
	CoopSync._send_oilset(CoopSync.LOOP_ID)
	var got := {}
	for _i in 20:
		await _st_wait(0.1)
		var e = _players.get(str(CoopSync.LOOP_ID))
		if e is Dictionary:
			got = e
			break
	_st_check(absf(float(got.get("oil", -1.0)) - 0.37) < 0.0001 and (got.get("taken", []) as Array) == ["oil_3"], "oilrep round trip (%s)" % JSON.stringify(got))
	_cont_players.erase(str(CoopSync.LOOP_ID))
	# 3. the continue handshake, by direct calls (the loopback drops mapsync)
	var orig: Dictionary = (CoopSync.map_state["events"] as Dictionary).duplicate(true)
	var orig_cp := int(CoopSync.map_state["checkpoint"])
	var saved := orig.duplicate(true)
	var t0 := Time.get_unix_time_from_system() - 1234.0
	saved["clock"] = {"t0": t0}
	saved["kiln_990"] = {}
	CoopSync._on_savehold({"on": false, "cont": true, "s": scene})
	_st_check((CoopSync.map_state["events"] as Dictionary).is_empty() and bool(CoopSync.continue_load), "guest state reset on the continue release")
	CoopSync._on_mapsync(scene, orig_cp, saved)
	var ck = (CoopSync.map_state["events"] as Dictionary).get("clock")
	_st_check(ck is Dictionary and absf(float((ck as Dictionary).get("t0", 0.0)) - t0) < 0.01 and (CoopSync.map_state["events"] as Dictionary).has("kiln_990"), "guest state replaced (clock t0 %.2f, want %.2f)" % [float((ck as Dictionary).get("t0", 0.0)) if ck is Dictionary else 0.0, t0])
	CoopSync.continue_load = false
	CoopSync.map_state["events"] = orig
	CoopSync.map_state["checkpoint"] = orig_cp


func _st_good_data(scene: String, cp: int, label: String) -> Dictionary:
	return {"v": FORMAT_V, "scene": scene, "map_build": _build_for(scene), "mod": CoopSync.MOD_VERSION, "run": "savetest",
		"checkpoint": cp, "checkpoint_label": label, "events": {"clock": {"t0": Time.get_unix_time_from_system() - 99.0}, "kiln_1": {}},
		"clock_s": 99, "players": {}, "saved_at": int(Time.get_unix_time_from_system()), "names": ["Me"], "finished": false}


func _st_put(path: String, txt: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(txt)
		f.close()


func _st_corrupt() -> void:
	if not await _st_wait_map(-1):
		return
	var scene := get_tree().current_scene.scene_file_path
	var key := "underdark"
	for n in _st_files(key):
		DirAccess.remove_absolute(_dir + n)
	DirAccess.make_dir_recursive_absolute(_dir)
	_st_put(_main(key), "{\"v\": 1, \"events\": {broken")
	_st_put(_main(key) + ".bak", JSON.stringify(_st_good_data(scene, 1, "OSSUARY"), "", false))
	var s := has_save(key)
	_st_check(str(s.get("src", "")) == "bak" and int(s.get("checkpoint", -9)) == 1, "a damaged file falls back to its .bak (src %s)" % str(s.get("src", "")))
	_st_put(_main(key) + ".bak", "not json at all")
	var before := banners.size()
	var s2 := has_save(key)
	var s3 := has_save(key)
	var shown := banners.size() - before
	_st_check(s2.is_empty() and s3.is_empty() and shown == 1 and banners[banners.size() - 1] == "The saved run could not be read.", "both damaged: no saved run, one banner (%d)" % shown)
	for n in _st_files(key):
		DirAccess.remove_absolute(_dir + n)


func _st_inferno() -> void:
	var key := "inferno"
	for n in _st_files(key):
		DirAccess.remove_absolute(_dir + n)
	if not await _st_wait_map(1):
		return
	var root := get_tree().current_scene
	var scene := root.scene_file_path
	_st_check(map_key(scene) == key, "INFERNO loaded (%s)" % scene)
	var c = Game.climber
	c.prevent_player_death = true
	await _st_wait(2.0)
	_st_check(_st_files(key).is_empty(), "no save before progress")
	for id in [0, 1]:
		var p = root.call("checkpoint_pos", id) if root.has_method("checkpoint_pos") else null
		if p is Vector3:
			c.set_climber_state(c.defaultClimberState)
			c.velocity = Vector3.ZERO
			c.teleport_to_location(p)
			await _st_wait(1.5)
			if CoopSync.map_checkpoint_for(scene) < id:
				CoopSync.map_checkpoint(id, scene)
			await _st_wait(0.5)
	var d := read_save(key, true)
	_st_check(int(d.get("checkpoint", -9)) == 1 and str(d.get("checkpoint_label", "")) == "REST PLATFORM 2", "saved at REST PLATFORM 2 (checkpoint %d, %s)" % [int(d.get("checkpoint", -9)), str(d.get("checkpoint_label", ""))])
	await _st_wait(3.0)
	flush_now("test")
	d = read_save(key, true)
	var saved_clock := int(d.get("clock_s", -1))
	# a fresh start of INFERNO: the panel answers CONTINUE
	CoopSync.map_state = {"scene": "", "checkpoint": -1, "events": {}}
	SceneLoader.load_scene(Game.load_level_based_on_difficulty)
	if not await _st_wait_map(0):
		return
	await _st_wait(2.0)
	root = get_tree().current_scene
	c = Game.climber
	c.prevent_player_death = true
	var cp1 = root.call("checkpoint_pos", 1) if root.has_method("checkpoint_pos") else null
	var dist: float = c.global_position.distance_to(cp1) if cp1 is Vector3 else 999.0
	if cp1 is Vector3:
		# where the continue put the climber against the platform's spawn (a fall shows as a y gap)
		var gp: Vector3 = c.global_position
		print("[SAVETEST] inferno: climber at (%.1f, %.1f, %.1f), REST PLATFORM 2 spawn (%.1f, %.1f, %.1f), on floor %s" % [
				gp.x, gp.y, gp.z, (cp1 as Vector3).x, (cp1 as Vector3).y, (cp1 as Vector3).z, str(c.is_on_floor())])
	_st_check(CoopSync.map_checkpoint_for(scene) == 1 and dist < 12.0, "INFERNO continued at REST PLATFORM 2 (checkpoint %d, %.1f m from it)" % [CoopSync.map_checkpoint_for(scene), dist])
	var rs := int(root.call("run_secs")) if root.has_method("run_secs") else -1
	_st_check(rs >= saved_clock and rs - saved_clock <= 60, "INFERNO clock %d s (saved %d s)" % [rs, saved_clock])
	for n in _st_files(key):
		DirAccess.remove_absolute(_dir + n)


func _st_kill() -> void:
	if not await _st_wait_map(-1):
		return
	var scene := get_tree().current_scene.scene_file_path
	var key := "underdark"
	var main := _main(key)
	for n in _st_files(key):
		DirAccess.remove_absolute(_dir + n)
	# the crash windows, simulated
	var a := _st_good_data(scene, 1, "OSSUARY")
	var b := _st_good_data(scene, 2, "THE FAR WALL")
	_write_file(key, a)
	_write_file(key, b)
	var full := JSON.stringify(_st_good_data(scene, 3, "THE BURROWS"), "", false)
	_st_put(main + ".tmp", full.substr(0, full.length() / 2))
	_st_check(int(read_save(key, true).get("checkpoint", -9)) == 2, "killed while writing the tmp: the main file is read")
	DirAccess.remove_absolute(main + ".bak")
	DirAccess.rename_absolute(main, main + ".bak")
	_st_put(main + ".tmp", full)
	var r := read_save(key, true)
	_st_check(int(r.get("checkpoint", -9)) == 3 and str(r.get("_src", "")) == "tmp", "killed between the renames: the complete tmp is read (src %s)" % str(r.get("_src", "")))
	_st_put(main + ".tmp", full.substr(0, 40))
	r = read_save(key, true)
	_st_check(int(r.get("checkpoint", -9)) == 2 and str(r.get("_src", "")) == "bak", "and with a partial tmp: the .bak (src %s)" % str(r.get("_src", "")))
	for n in _st_files(key):
		DirAccess.remove_absolute(_dir + n)
	# a real write loop, then the game kills itself in the middle of a write; the real run checks the
	# file it left behind
	var loops := 0
	var t := 0.0
	while t < 1.5:
		var d := _st_good_data(scene, 4 + loops % 5, "LOOP")
		(d["events"] as Dictionary)["n"] = {"loops": loops}
		_write_file(key, d)
		loops += 1
		await get_tree().process_frame
		t += get_process_delta_time()
	var mk := FileAccess.open(ST_MARKER, FileAccess.WRITE)
	if mk != null:
		mk.store_string(JSON.stringify({"kill": true, "loops": loops}))
		mk.close()
	_st_check(loops > 10, "write loop ran (%d writes)" % loops)
	# printerr flushes the log before the process dies
	if _st_fails.is_empty():
		printerr("[SAVETEST] test done %d/%d PASS" % [_st_pass, _st_total])
	else:
		printerr("[SAVETEST] test done %d/%d FAIL: %s" % [_st_pass, _st_total, ", ".join(_st_fails)])
	_kill_mid_write = true
	_write_file(key, _st_good_data(scene, 9, "KILLED"))
	_kill_mid_write = false                         # never reached


func _st_real() -> void:
	if not await _st_wait_map(-1):
		return
	var scene := get_tree().current_scene.scene_file_path
	# 1. the file the kill run left behind
	var keep_dir := _dir
	_dir = SAVETEST_DIR
	var left := _st_files("underdark")
	if left.is_empty():
		print("[SAVETEST] SKIP kill leftover: no file in %s (run kill first)" % SAVETEST_DIR)
	else:
		var r := read_save("underdark", true)
		_st_check(not r.is_empty(), "kill leftover readable (src %s, files %s)" % [str(r.get("_src", "none")), str(left)])
	_dir = keep_dir
	# 2. the real folder: only zz_savetest.json, every other file byte-identical
	var existed := DirAccess.dir_exists_absolute(REAL_DIR)
	var sums: Dictionary = {}
	if existed:
		for f in DirAccess.get_files_at(REAL_DIR):
			sums[f] = FileAccess.get_md5(REAL_DIR + f)
	print("[SAVETEST] real folder: %s, %d files" % ["present" if existed else "absent", sums.size()])
	_dir = REAL_DIR
	var key := "zz_savetest"
	var w1 := _write_file(key, _st_good_data(scene, 1, "OSSUARY"))
	var w2 := _write_file(key, _st_good_data(scene, 2, "THE FAR WALL"))
	var back := read_save(key, true)
	_st_check(w1 and w2 and int(back.get("checkpoint", -9)) == 2 and str(back.get("_src", "")) == "main" and FileAccess.file_exists(_main(key) + ".bak"), "real folder write and read back (zz_savetest.json)")
	for suffix in [".json", ".json.tmp", ".json.bak", ".old.json"]:
		if FileAccess.file_exists(REAL_DIR + key + suffix):
			DirAccess.remove_absolute(REAL_DIR + key + suffix)
	_dir = keep_dir
	var same := true
	var now_files: Array = Array(DirAccess.get_files_at(REAL_DIR)) if DirAccess.dir_exists_absolute(REAL_DIR) else []
	if now_files.size() != sums.size():
		same = false
	for f in sums.keys():
		if not FileAccess.file_exists(REAL_DIR + f) or FileAccess.get_md5(REAL_DIR + f) != str(sums[f]):
			same = false
	if not existed and DirAccess.dir_exists_absolute(REAL_DIR) and DirAccess.get_files_at(REAL_DIR).is_empty():
		DirAccess.remove_absolute(REAL_DIR.trim_suffix("/"))
	_st_check(same, "real folder untouched (%d files)" % sums.size())
	# 3. the savetest folder goes
	if DirAccess.dir_exists_absolute(SAVETEST_DIR):
		for f in DirAccess.get_files_at(SAVETEST_DIR):
			DirAccess.remove_absolute(SAVETEST_DIR + f)
		DirAccess.remove_absolute(SAVETEST_DIR.trim_suffix("/"))
	DirAccess.remove_absolute(ST_MARKER)
	_st_check(not DirAccess.dir_exists_absolute(SAVETEST_DIR), "savetest folder deleted")
