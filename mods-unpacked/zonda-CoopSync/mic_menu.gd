extends Node

# ============================================================================================
# ZondaCoopSync microphone picker (v4.9.1). coop_sync adds one as CoopSync.mic_menu.
#
# WHAT IT DOES
#   Puts a "MICROPHONE" dropdown in the game's pause menu (right under RESTART AT KILN) and in
#   the F2 panel's voice column. "STEAM MICROPHONE" (the default) keeps voice.gd's Steam path;
#   any other entry is a Godot input device, picked through CoopSync.voice.set_input_device().
#
# API
#   func build_picker(theme: Theme, focusable: bool) -> Control
#       A VBoxContainer: [Label "MICROPHONE" + OptionButton], a thin level meter (only shown on
#       a device: Steam gives no level) and a small hint line. theme = null inherits the parent's
#       theme (F2 panel); the pause menu passes its Resume button's theme so fonts match.
#       focusable = false sets FOCUS_NONE (F2 panel: Space/jump can never open the dropdown).
#       The device list is read when the picker is built and again every time it is shown after
#       being hidden (the F2 panel lives for the whole game), so a hot-plugged mic shows up the
#       next time the pause menu or the F2 panel opens.
#       A picker holds one CoopSync.voice.set_monitor(true) (so mic_level is live on the device
#       path, nothing is sent) only while the player is using it: its dropdown is open, it has
#       focus, or the mouse is over it, plus MON_LINGER_MS after that (MON_PICK_MS after a pick,
#       so the new mic can be tried). Merely pausing never opens the microphone (a Bluetooth
#       headset would drop to its call profile on every pause). It gives the reference back with
#       exactly one set_monitor(false) when that time is up, when it is hidden (the pause menu's
#       Settings screen covering it counts as hidden), leaves the tree or is freed.
#       The dropdown can re-pick the item it shows (allow_reselect), and a device that is the
#       voice's but is no longer in the list shows as "NAME (UNPLUGGED)", so STEAM MICROPHONE is
#       always a real change.
#
# PAUSE MENU INJECTION
#   get_tree().node_added is watched for a CanvasLayer named "PauseMenuUi" or running
#   res://scripts/pause_menu_ui.gd (hud.gd instantiates a fresh one on every pause and the menu
#   queue_free()s itself on resume). node_added fires before the menu's children are in the tree,
#   so the picker is added on the menu's own `ready` signal (after its _ready ran, its @export
#   paths are resolved and Game.node_to_select_for_controller_mode already points at Resume), or
#   deferred when the menu was already ready. Once per menu instance (a meta flag). If the game's
#   layout ever changes (no PanelContainer/VBoxContainer) it logs once and leaves the menu alone.
#
# SAFETY
#   Every voice.gd call is guarded with has_method / get(), so an older voice.gd without the
#   device API just shows STEAM MICROPHONE. An open dropdown popup is a child of the OptionButton:
#   Esc goes to the popup first (it closes the popup, not the pause menu), and if the menu is freed
#   anyway the popup is freed with it and the monitor is released by tree_exiting.
# ============================================================================================

const PAUSE_SCRIPT := "res://scripts/pause_menu_ui.gd"
const PAUSE_NAME := "PauseMenuUi"
const PAUSE_VBOX := "PanelContainer/VBoxContainer"
const PAUSE_ANCHOR := "RestartCheckpoint"
const PAUSE_AFTER := "Difficulty"
const INJECTED_META := "zonda_mic_picker"
const PICKER_NAME := "ZondaMicPicker"

const STEAM_TEXT := "STEAM MICROPHONE"
const DEFAULT_DEVICE := "Default"         # AudioServer's name for the Windows default device
const DEFAULT_TEXT := "WINDOWS DEFAULT"
const NAME_MAX := 32                      # longer device names are cut, the full name is the tooltip
const OPT_MIN_W := 160.0
const REFILL_AFTER_MS := 1000             # a picker shown this long after it was built re-reads the list
const MON_LINGER_MS := 2000               # the mic stays monitored this long after the player stops using the picker
const MON_PICK_MS := 8000                 # ...and this long after a pick, to try the new mic
const UNPLUGGED_SUFFIX := " (UNPLUGGED)"

const HINT_STEAM := "Uses the mic set in Steam > Settings > Voice"
const HINT_DEVICE := "Always on when you talk. F7 mutes your mic."
const HINT_NO_DEVICES := "Uses the mic set in Steam > Settings > Voice. To pick another mic, copy the override.cfg from this mod's zip next to the game exe."
const HINT_UNPLUGGED := "That mic is unplugged. Plug it back in or pick another one above."
const HINT_SAVED_MISSING := "Your saved mic (%s) is not plugged in, so STEAM MICROPHONE is used."
const HINT_SAVED_BACK := "Your saved mic (%s) is plugged in again. Pick it above to use it."
const HINT_NO_VOICE := "Voice chat is unavailable."

const METER_FILL := Color(0.91, 0.82, 0.54, 1.0)     # the brand gold
const METER_BACK := Color(1.0, 1.0, 1.0, 0.12)
const METER_H := 4.0
const METER_IDLE_A := 0.35                # the meter is dimmed while the mic is not monitored

# picker root instance id -> {
#   "root": VBoxContainer, "opt": OptionButton, "meter": ProgressBar, "hint": Label,
#   "dev": String       the voice input_device the picker currently shows
#   "dev_ok": bool      that device is in the list (and is not the Steam entry)
#   "listed": bool      at least one Godot device was listed
#   "ghost": String     the device shown as "NAME (UNPLUGGED)" (the voice's, not in the list), or ""
#   "mon_on": bool      this picker holds a set_monitor(true)
#   "mon": Object       the voice node it was taken on (null if that voice had no set_monitor)
#   "mon_until": int    ticks ms until which the picker keeps monitoring (0 = not in use)
#   "menu": int         instance id of the pause menu it was put in (0 = the F2 panel)
#   "shown": bool       visible in the tree last frame
#   "built_ms": int }
var _pickers: Dictionary = {}
var _warned_layout := false
var _logged_inject := false
var _filling := false                     # _fill is running: _sync must not start another one


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().node_added.connect(_on_node_added)
	print("[CoopSync] mic menu ready (pause menu + F2 microphone picker)")
	if FileAccess.file_exists(TEST_FLAG):
		# developer flags are one-shot: read, then deleted from disk. The flag may name a device prefix.
		_test_pick = FileAccess.get_file_as_string(TEST_FLAG).strip_edges()
		DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/pausemenu.flag")
		_run_test.call_deferred()


# ---------------------------------------------------------------- developer test (pausemenu.flag)

const TEST_FLAG := "res://mods-unpacked/zonda-CoopSync/pausemenu.flag"
var _test_pick := ""


func _run_test() -> void:
	# Waits for a level, opens the game's own pause menu, shoots it, picks the Windows default mic
	# through the real dropdown, reads the level meter, puts the player's own choice back, closes
	# the menu, then opens and shoots the F2 panel. Everything goes to the log as [MicTest].
	var t0 := Time.get_ticks_msec()
	while true:
		await get_tree().create_timer(1.0, true).timeout
		var c = Game.get("climber")
		if is_instance_valid(c) and c.is_inside_tree() and Time.get_ticks_msec() - t0 > 12000:
			break
		if Time.get_ticks_msec() - t0 > 120000:
			print("[MicTest] no level loaded")
			return
	await get_tree().create_timer(3.0, true).timeout
	var hud: Node = null
	for n in get_tree().current_scene.find_children("*", "", true, false):
		if n.has_method("toggle_pause_menu"):
			hud = n
			break
	if hud == null:
		print("[MicTest] no HUD with toggle_pause_menu")
		return
	hud.toggle_pause_menu()
	await get_tree().create_timer(1.5, true).timeout
	var menu = hud.get("pause_menu")
	if not is_instance_valid(menu):
		print("[MicTest] the pause menu did not open")
		return
	var picker: Node = menu.find_child(PICKER_NAME, true, false)
	print("[MicTest] pause menu open, picker injected: %s" % str(picker != null))
	if picker == null:
		return
	var opts := picker.find_children("*", "OptionButton", true, false)
	if opts.is_empty():
		print("[MicTest] no dropdown in the picker")
		return
	var opt: OptionButton = opts[0]
	var items := []
	for i in opt.item_count:
		items.append("%s=%s" % [opt.get_item_text(i), str(opt.get_item_metadata(i))])
	print("[MicTest] items: %s | selected %d" % [", ".join(items), opt.selected])
	_test_log_labels(picker, "before")
	_test_shot("mic_pause_0")
	var v = _voice()
	var prev := str(v.get("input_device")) if v != null else ""
	var pick := _index_of(opt, DEFAULT_DEVICE)
	if _test_pick.length() > 1:
		for i in opt.item_count:
			if str(opt.get_item_metadata(i)).begins_with(_test_pick):
				pick = i
				break
	if pick < 0 and opt.item_count > 1:
		pick = 1
	if pick < 0:
		print("[MicTest] no device to pick (audio input off?)")
	else:
		opt.grab_focus()
		opt.select(pick)
		opt.item_selected.emit(pick)
		await get_tree().create_timer(2.5, true).timeout
		var peak := 0.0
		for _k in 20:
			await get_tree().create_timer(0.05, true).timeout
			peak = maxf(peak, float(v.get("mic_level")))
		print("[MicTest] picked '%s': input_device='%s' mic_open=%s monitor_refs=%s AudioServer.input_device='%s' mic_level peak %.2f err='%s' frames %s raw peak %s" % [
			opt.get_item_text(pick), str(v.get("input_device")), str(v.get("_mic_open")), str(v.get("_monitor_refs")),
			str(AudioServer.get("input_device")), peak, str(v.get("_mic_err")), str(v.get("stat_mic_frames")), str(v.get("stat_mic_raw_peak"))])
		_test_log_labels(picker, "device")
		_test_shot("mic_pause_1")
		var back := _index_of(opt, prev)
		if back < 0:
			back = 0
		opt.select(back)
		opt.item_selected.emit(back)
		await get_tree().create_timer(1.0, true).timeout
		print("[MicTest] restored: input_device='%s' (was '%s')" % [str(v.get("input_device")), prev])
	hud.toggle_pause_menu()
	await get_tree().create_timer(3.0, true).timeout
	print("[MicTest] pause menu closed: monitor_refs=%s mic_open=%s" % [str(v.get("_monitor_refs")) if v != null else "?", str(v.get("_mic_open")) if v != null else "?"])
	var ev := InputEventKey.new()
	ev.keycode = KEY_F2
	ev.physical_keycode = KEY_F2
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().create_timer(1.5, true).timeout
	_test_shot("mic_f2")
	var ev2 := InputEventKey.new()
	ev2.keycode = KEY_F2
	ev2.physical_keycode = KEY_F2
	ev2.pressed = true
	Input.parse_input_event(ev2)
	await get_tree().create_timer(1.5, true).timeout
	print("[MicTest] done: monitor_refs=%s mic_open=%s" % [str(v.get("_monitor_refs")) if v != null else "?", str(v.get("_mic_open")) if v != null else "?"])


func _test_log_labels(root: Node, tag: String) -> void:
	var t := []
	for l in root.find_children("*", "Label", true, false):
		if (l as Label).is_visible_in_tree() and (l as Label).text != "":
			t.append((l as Label).text)
	print("[MicTest] %s labels: %s" % [tag, " | ".join(t)])


func _test_shot(fname: String) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		return
	if img.get_width() > 1280:
		img.resize(1280, 720, Image.INTERPOLATE_BILINEAR)
	img.save_png("user://%s.png" % fname)


func _exit_tree() -> void:
	for id in _pickers:
		_hold(_pickers[id], false)


# ---------------------------------------------------------------- pause menu injection

func _on_node_added(node: Node) -> void:
	# every node the game adds comes through here: the cheap type test goes first
	if not (node is CanvasLayer):
		return
	if not _is_pause_menu(node):
		return
	if node.has_meta(INJECTED_META):
		return
	var id := node.get_instance_id()
	if node.is_node_ready():
		_inject.call_deferred(id)
		return
	var cb := _inject.bind(id)
	if not node.ready.is_connected(cb):
		node.ready.connect(cb, Object.CONNECT_ONE_SHOT)


func _is_pause_menu(node: Node) -> bool:
	if String(node.name) == PAUSE_NAME:
		return true
	var s = node.get_script()
	if s is Script:
		return (s as Script).resource_path == PAUSE_SCRIPT
	return false


func _inject(id: int) -> void:
	var menu := instance_from_id(id) as Node
	if menu == null or not is_instance_valid(menu) or not menu.is_inside_tree():
		return
	if menu.has_meta(INJECTED_META):
		return
	menu.set_meta(INJECTED_META, true)
	var vbox := menu.get_node_or_null(PAUSE_VBOX) as VBoxContainer
	if vbox == null:
		_warn_layout("no %s in %s" % [PAUSE_VBOX, String(menu.name)])
		return
	var th: Theme = null
	var resume := vbox.get_node_or_null("Resume") as Control
	if resume != null:
		th = resume.theme
	if th == null:
		for c in vbox.get_children():
			if c is Control and (c as Control).theme != null:
				th = (c as Control).theme
				break
	var at := -1
	var anchor := vbox.get_node_or_null(PAUSE_ANCHOR)
	if anchor != null:
		at = anchor.get_index() + 1
	else:
		var after := vbox.get_node_or_null(PAUSE_AFTER)
		if after != null:
			at = after.get_index()
		var where: String = ("above " + PAUSE_AFTER) if after != null else "at the bottom"
		_warn_layout("no %s button, the picker goes %s" % [PAUSE_ANCHOR, where])
	var picker := build_picker(th, true)
	picker.name = PICKER_NAME
	var pe: Dictionary = _pickers.get(picker.get_instance_id(), {})
	if not pe.is_empty():
		pe["menu"] = id                     # its Settings screen covers the picker (see _covered)
	vbox.add_child(picker)
	if at >= 0 and at < vbox.get_child_count():
		vbox.move_child(picker, at)
	if not _logged_inject:
		_logged_inject = true
		print("[CoopSync] mic menu: microphone picker added to the pause menu")


func _warn_layout(why: String) -> void:
	if _warned_layout:
		return
	_warned_layout = true
	print("[CoopSync] mic menu: the pause menu layout is not the one this mod knows (%s)" % why)


# ---------------------------------------------------------------- the picker

func build_picker(theme: Theme, focusable: bool) -> Control:
	_prune()
	var root := VBoxContainer.new()
	root.name = PICKER_NAME
	root.add_theme_constant_override("separation", 3)
	if theme != null:
		root.theme = theme

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var lab := Label.new()
	lab.text = "MICROPHONE"
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)
	var opt := OptionButton.new()
	opt.fit_to_longest_item = false          # long device names must not widen the menu
	opt.clip_text = true
	opt.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	opt.custom_minimum_size = Vector2(OPT_MIN_W, 0)
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	opt.focus_mode = Control.FOCUS_ALL if focusable else Control.FOCUS_NONE
	opt.allow_reselect = true                # picking the item already shown still applies (and saves) it
	row.add_child(opt)
	root.add_child(row)

	var meter := ProgressBar.new()
	meter.min_value = 0.0
	meter.max_value = 1.0
	meter.step = 0.0
	meter.show_percentage = false
	meter.custom_minimum_size = Vector2(0, METER_H)
	meter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meter.focus_mode = Control.FOCUS_NONE
	var back := StyleBoxFlat.new()
	back.bg_color = METER_BACK
	var fill := StyleBoxFlat.new()
	fill.bg_color = METER_FILL
	meter.add_theme_stylebox_override("background", back)
	meter.add_theme_stylebox_override("fill", fill)
	meter.visible = false
	root.add_child(meter)

	var hint := Label.new()
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.7)
	root.add_child(hint)

	var id := root.get_instance_id()
	var entry := {
		"root": root, "opt": opt, "meter": meter, "hint": hint,
		"dev": "", "dev_ok": false, "listed": false, "ghost": "",
		"mon_on": false, "mon": null, "mon_until": 0, "menu": 0, "shown": false,
		"built_ms": Time.get_ticks_msec(),
	}
	_pickers[id] = entry
	_fill(entry)
	opt.item_selected.connect(_on_item_selected.bind(id))
	root.tree_exiting.connect(_on_picker_exiting.bind(id))
	return root


# (Re)reads the device list into the dropdown and selects the current device.
func _fill(entry: Dictionary) -> void:
	if not _valid(entry):
		return
	var opt: OptionButton = entry["opt"]
	var v = _voice()
	opt.clear()
	opt.add_item(STEAM_TEXT)
	opt.set_item_metadata(0, "")
	opt.set_item_tooltip(0, "The microphone chosen in Steam's own voice settings")
	var names := PackedStringArray()
	if v != null and v.has_method("list_input_devices"):
		var got = v.list_input_devices()
		if got is PackedStringArray:
			names = got
		elif got is Array:
			for n in got:
				names.append(str(n))
	for n in names:
		if n.strip_edges().is_empty():
			continue
		var idx := opt.item_count
		if n == DEFAULT_DEVICE:
			opt.add_item(DEFAULT_TEXT)
			opt.set_item_tooltip(idx, "Whatever Windows uses as its default microphone")
		else:
			opt.add_item(_short(n))
			opt.set_item_tooltip(idx, n)
		opt.set_item_metadata(idx, n)
	entry["listed"] = opt.item_count > 1
	entry["ghost"] = ""
	# the voice still records a device that is not in the list (unplugged mid-game): show it as
	# UNPLUGGED instead of claiming STEAM MICROPHONE, so picking STEAM is a real change
	var dev := _current_device(v)
	if dev != "" and _index_of(opt, dev) < 0:
		var gi := opt.item_count
		opt.add_item(_display_name(dev) + UNPLUGGED_SUFFIX)
		opt.set_item_metadata(gi, dev)
		opt.set_item_tooltip(gi, dev + " is not plugged in")
		entry["ghost"] = dev
	opt.disabled = v == null
	_filling = true
	_sync(entry, v, true)
	_filling = false


# Shows the voice's current device on this picker (when it changed, or always with force).
func _sync(entry: Dictionary, v, force: bool) -> void:
	if not _valid(entry):
		return
	var dev := _current_device(v)
	if not force and dev == str(entry["dev"]):
		return
	var opt: OptionButton = entry["opt"]
	var ghost := str(entry.get("ghost", ""))
	if ghost != "" and ghost != dev:
		# the voice moved off the unplugged device: its UNPLUGGED entry goes
		var gi := _index_of(opt, ghost)
		if gi > 0:
			opt.remove_item(gi)
		entry["ghost"] = ""
		ghost = ""
	var idx := _index_of(opt, dev)
	if idx < 0 and not _filling:
		# this picker's list is older than the device (plugged in after the list was read, e.g.
		# picked in the other picker) or the device is gone: re-read it (_fill adds the UNPLUGGED
		# entry for a device that is really gone, then calls _sync again)
		_fill(entry)
		return
	entry["dev"] = dev
	var missing := idx < 0 or (dev != "" and dev == ghost)
	if idx < 0:
		idx = 0
	if opt.selected != idx:
		opt.select(idx)
	opt.tooltip_text = opt.get_item_tooltip(idx)
	entry["dev_ok"] = dev != "" and not missing
	var hint: Label = entry["hint"]
	var txt := HINT_DEVICE
	if v == null:
		txt = HINT_NO_VOICE
	elif missing:
		txt = HINT_UNPLUGGED
	elif dev == "":
		var saved := _saved_device(v)
		if not bool(entry["listed"]):
			txt = HINT_NO_DEVICES
		elif saved != "":
			# the saved mic was missing at startup: voice.gd uses Steam for this run but keeps the
			# name (picking any entry, STEAM MICROPHONE too, replaces it)
			var hint_fmt: String = HINT_SAVED_MISSING if _index_of(opt, saved) < 0 else HINT_SAVED_BACK
			txt = hint_fmt % _display_name(saved)
		else:
			txt = HINT_STEAM
	if hint.text != txt:
		hint.text = txt
	if not bool(entry["dev_ok"]):
		var meter: ProgressBar = entry["meter"]
		meter.visible = false


func _on_item_selected(index: int, id: int) -> void:
	var entry: Dictionary = _pickers.get(id, {})
	if entry.is_empty() or not _valid(entry):
		return
	var opt: OptionButton = entry["opt"]
	if index < 0 or index >= opt.item_count:
		return
	var want := str(opt.get_item_metadata(index))
	var shown := opt.get_item_text(index)
	entry["mon_until"] = Time.get_ticks_msec() + MON_PICK_MS    # keep the meter live to try the new mic
	var v = _voice()
	if v == null or not v.has_method("set_input_device"):
		if want != "":
			_banner("This voice chat build cannot switch microphones")
		_sync(entry, v, true)
		return
	v.set_input_device(want)
	var got := _current_device(v)
	if got == want:
		_banner("Microphone: %s" % shown)
	else:
		_banner("Microphone not found, using %s" % _display_name(got))
	# every open picker (pause menu and F2 panel together) shows the same choice
	for pid in _pickers:
		_sync(_pickers[pid], v, true)


func _on_picker_exiting(id: int) -> void:
	var entry: Dictionary = _pickers.get(id, {})
	if entry.is_empty():
		return
	_hold(entry, false)
	entry["shown"] = false


# ---------------------------------------------------------------- per frame

func _process(_delta: float) -> void:
	if _pickers.is_empty():
		return
	var now := Time.get_ticks_msec()
	var v = null
	var have_v := false
	var level := 0.0
	var have_level := false
	var dead: Array = []
	for id in _pickers:
		var e: Dictionary = _pickers[id]
		if not _valid(e):
			_hold(e, false)
			dead.append(id)
			continue
		var root: Control = e["root"]
		var on := root.is_inside_tree() and root.is_visible_in_tree() and not _covered(e)
		if not on:
			if bool(e["shown"]):
				e["shown"] = false
			e["mon_until"] = 0
			_hold(e, false)
			continue
		if not bool(e["shown"]):
			e["shown"] = true
			# shown again (the F2 panel reopened, back from Settings): re-read the list so
			# hot-plugged mics show up
			if now - int(e["built_ms"]) > REFILL_AFTER_MS:
				_fill(e)
		# the mic is opened for the meter only while the player uses the picker, never just
		# because the menu is on screen
		if _in_use(e):
			e["mon_until"] = maxi(int(e["mon_until"]), now + MON_LINGER_MS)
		var mon := now < int(e["mon_until"])
		_hold(e, mon)
		if not have_v:
			have_v = true
			v = _voice()
			if v != null:
				var lv = v.get("mic_level")
				if lv != null:
					level = clampf(float(lv), 0.0, 1.0)
					have_level = true
		_sync(e, v, false)
		var meter: ProgressBar = e["meter"]
		var want_meter := bool(e["dev_ok"]) and have_level
		if meter.visible != want_meter:
			meter.visible = want_meter
		if want_meter and absf(meter.value - level) > 0.004:
			meter.value = level
		var ma: float = 1.0 if mon else METER_IDLE_A
		if meter.modulate.a != ma:
			meter.modulate = Color(1, 1, 1, ma)
	for id in dead:
		_pickers.erase(id)


# The player is using this picker: its dropdown is open, it has focus (keyboard or controller),
# or the mouse is over it. Hover only counts in the pause menu while the mouse is visible: in
# controller mode the hidden cursor can rest anywhere. (The F2 panel always shows the mouse.)
func _in_use(e: Dictionary) -> bool:
	var opt: OptionButton = e["opt"]
	if opt.has_focus():
		return true
	var pop := opt.get_popup()
	if pop != null and pop.visible:
		return true
	if int(e.get("menu", 0)) != 0 and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
		return false
	var root: Control = e["root"]
	return root.get_global_rect().has_point(root.get_global_mouse_position())


# The pause menu this picker sits in has its Settings screen open on top of it: the picker is
# covered (pause_menu_ui.gd adds settings_menu as a child without hiding its own panel).
func _covered(e: Dictionary) -> bool:
	var mid := int(e.get("menu", 0))
	if mid == 0:
		return false
	var menu = instance_from_id(mid)
	if menu == null or not is_instance_valid(menu):
		return false
	return menu.get("settings_menu") != null


# Takes (on) or gives back (off) this picker's one monitor reference. Idempotent.
func _hold(entry: Dictionary, on: bool) -> void:
	if on == bool(entry.get("mon_on", false)):
		return
	if on:
		entry["mon_on"] = true
		entry["mon"] = null
		var v = _voice()
		if v != null and v.has_method("set_monitor"):
			entry["mon"] = v
			v.set_monitor(true)
	else:
		entry["mon_on"] = false
		var held = entry.get("mon")
		entry["mon"] = null
		if is_instance_valid(held) and held.has_method("set_monitor"):
			held.set_monitor(false)


# ---------------------------------------------------------------- helpers

func _prune() -> void:
	var dead: Array = []
	for id in _pickers:
		if not is_instance_valid(_pickers[id].get("root")):
			_hold(_pickers[id], false)
			dead.append(id)
	for id in dead:
		_pickers.erase(id)


func _valid(entry: Dictionary) -> bool:
	return is_instance_valid(entry.get("root")) and is_instance_valid(entry.get("opt")) \
		and is_instance_valid(entry.get("meter")) and is_instance_valid(entry.get("hint"))


func _coop():
	return get_node_or_null("/root/CoopSync")


func _voice():
	var cs = _coop()
	if cs == null:
		return null
	var v = cs.get("voice")
	if is_instance_valid(v):
		return v
	return null


func _current_device(v) -> String:
	if v == null:
		return ""
	var d = v.get("input_device")
	if d == null:
		return ""
	return str(d)


# The device zonda_voice.cfg holds (voice.saved_device(); an older voice.gd only had _cfg_device).
# It only differs from input_device when the saved mic was missing at startup (input_device is "").
func _saved_device(v) -> String:
	if v == null:
		return ""
	if v.has_method("saved_device"):
		return str(v.saved_device())
	var d = v.get("_cfg_device")
	if d == null:
		return ""
	return str(d)


func _index_of(opt: OptionButton, dev: String) -> int:
	for i in opt.item_count:
		if str(opt.get_item_metadata(i)) == dev:
			return i
	return -1


func _short(n: String) -> String:
	if n.length() <= NAME_MAX:
		return n
	return n.substr(0, NAME_MAX - 3).strip_edges() + "..."


func _display_name(dev: String) -> String:
	if dev == "":
		return STEAM_TEXT
	if dev == DEFAULT_DEVICE:
		return DEFAULT_TEXT
	return _short(dev)


func _banner(text: String) -> void:
	var cs = _coop()
	if cs != null and cs.has_method("show_banner"):
		cs.show_banner(text, 2.5)
