extends Node

# ============================================================================================
# ZondaCoopSync saved-run panel (v5.0, build contract 3.1). coop_sync adds one as CoopSync.save_prompt.
#
# WHAT IT SHOWS
#   Host (or solo), on a fresh start of a map with an unfinished saved run (CoopSync.map_loaded):
#       SAVED RUN: <checkpoint label>
#       <h:mm:ss> played, saved <date time>, with <names>
#       [Saved on an older version of the map: some things may be slightly off.]
#       CONTINUE   NEW RUN
#   NEW RUN asks first: "This replaces your saved run (<label>, <h:mm:ss>). Sure?"  YES / NO
#   (NO goes back). CONTINUE -> CoopSync.save_continue(key); YES -> CoopSync.save_new_run(key).
#   Guests, while their host chooses: "Waiting for <host>: continue the saved run or start new".
#   The game is paused (Game.request_pause_next_frame() every frame) while either panel shows. The
#   look is the pause menu's: res://ui/main_theme.tres, a dark panel, 20 px buttons.
#
# API
#   func show_for(key: String, summary: Dictionary)   summary = save_run.has_save(key)
#   func close()
#   func show_hold(host_name: String, secs: float)     guests; released by hide_hold() or after secs
#   func hide_hold()
#   func is_open() -> bool       the host panel or the hold shows (CoopSync.save_prompt_open)
#   func host_open() -> bool     the host panel shows
#   func hold_visible() -> bool
#   func scene_id() -> int       the scene instance the host panel was opened in
#   func auto_answer(choice)     tests: "continue" presses CONTINUE, "new" presses NEW RUN and, once
#                                the confirm has shown for 0.5 s, YES
#   var confirm_seen, closed_unix (the unix time the host panel closed), last_choice
# ============================================================================================

const THEME_PATH := "res://ui/main_theme.tres"
const LAYER := 96
const TXT := Color(1.0, 0.92, 0.75)
const TXT_DIM := Color(0.82, 0.78, 0.7)
const TXT_WARN := Color(0.95, 0.62, 0.4)
const PANEL_W := 440.0

var _layer: CanvasLayer = null
var _title: Label = null
var _info: Label = null
var _warn: Label = null
var _btn_a: Button = null        # CONTINUE / YES
var _btn_b: Button = null        # NEW RUN / NO
var _mode := ""                  # "", "choose", "confirm"
var _key := ""
var _sum: Dictionary = {}
var _scene_id := 0
var _auto := ""
var _auto_ms := 0
var confirm_seen := false
var closed_unix := 0.0
var last_choice := ""
var _hold_layer: CanvasLayer = null
var _hold_label: Label = null
var _hold_on := false
var _hold_until_ms := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_open() -> bool:
	return _mode != "" or _hold_on


func host_open() -> bool:
	return _mode != ""


func hold_visible() -> bool:
	return _hold_on


func scene_id() -> int:
	return _scene_id


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _hold_on and now > _hold_until_ms:
		hide_hold()
		print("[SAVE] hold released")
	if is_open():
		Game.request_pause_next_frame()     # paused like the pause menu while a panel shows
	if _auto != "" and _mode != "" and now >= _auto_ms:
		if _mode == "choose":
			if _auto == "continue":
				_auto = ""
				_on_a()
			else:
				_on_b()                       # to the confirm; YES follows 0.5 s later
				_auto_ms = now + 500
		elif _mode == "confirm":
			_auto = ""
			_on_a()


# ---------------------------------------------------------------- host panel

func show_for(key: String, summary: Dictionary) -> void:
	_key = key
	_sum = summary.duplicate(true)
	var cs := get_tree().current_scene
	_scene_id = cs.get_instance_id() if cs != null else 0
	confirm_seen = false
	last_choice = ""
	_build()
	_show_choose()
	print("[SAVE] panel: %s | %s%s" % [_title.text, _info.text, " | older map" if _warn.visible else ""])


func close() -> void:
	if _mode == "":
		return
	_mode = ""
	_auto = ""
	closed_unix = Time.get_unix_time_from_system()
	if is_instance_valid(_layer):
		_layer.visible = false
	print("[SAVE] panel closed (%s)" % (last_choice if last_choice != "" else "no choice"))


func auto_answer(choice: String) -> void:
	_auto = choice
	_auto_ms = Time.get_ticks_msec() + 500


func _label_text() -> String:
	var l := str(_sum.get("checkpoint_label", ""))
	return l if l != "" else "THE START"


func _hms() -> String:
	var s := maxi(0, int(_sum.get("clock_s", 0)))
	return "%d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]


func _saved_when() -> String:
	var at := int(_sum.get("saved_at", 0))
	if at <= 0:
		return "at an unknown time"
	var bias := int(Time.get_time_zone_from_system().get("bias", 0))      # minutes from UTC
	var d := Time.get_datetime_dict_from_unix_time(at + bias * 60)
	return "%04d-%02d-%02d %02d:%02d" % [int(d["year"]), int(d["month"]), int(d["day"]), int(d["hour"]), int(d["minute"])]


func _show_choose() -> void:
	_mode = "choose"
	_title.text = "SAVED RUN: %s" % _label_text()
	var names: Array = _sum.get("names", []) if _sum.get("names", []) is Array else []
	var info := "%s played, saved %s" % [_hms(), _saved_when()]
	if not names.is_empty():
		info += ", with %s" % ", ".join(PackedStringArray(names))
	_info.text = info
	_info.visible = true
	_warn.text = "Saved on an older version of the map: some things may be slightly off."
	_warn.visible = bool(_sum.get("older", false))
	_btn_a.text = "CONTINUE"
	_btn_b.text = "NEW RUN"
	_layer.visible = true
	_focus(_btn_a)


func _show_confirm() -> void:
	_mode = "confirm"
	confirm_seen = true
	_title.text = "This replaces your saved run (%s, %s). Sure?" % [_label_text(), _hms()]
	_info.visible = false
	_warn.visible = false
	_btn_a.text = "YES"
	_btn_b.text = "NO"
	_focus(_btn_b)
	print("[SAVE] confirm shown")


func _focus(b: Button) -> void:
	Game.node_to_select_for_controller_mode = b
	if b.is_inside_tree():
		b.grab_focus.call_deferred()


func _on_a() -> void:
	if _mode == "choose":
		last_choice = "continue"
		CoopSync.save_continue(_key)
	elif _mode == "confirm":
		last_choice = "new"
		CoopSync.save_new_run(_key)


func _on_b() -> void:
	if _mode == "choose":
		_show_confirm()
	elif _mode == "confirm":
		_show_choose()


func _theme() -> Theme:
	var th = load(THEME_PATH) if ResourceLoader.exists(THEME_PATH) else null
	return th if th is Theme else null


func _panel_box() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.81)
	sb.content_margin_left = 36.0
	sb.content_margin_right = 36.0
	sb.content_margin_top = 20.0
	sb.content_margin_bottom = 20.0
	return sb


func _label(size: int, color: Color) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(PANEL_W, 0.0)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


func _button() -> Button:
	var b := Button.new()
	b.add_theme_font_size_override("font_size", 20)
	b.custom_minimum_size = Vector2(150.0, 0.0)
	return b


func _build() -> void:
	if is_instance_valid(_layer):
		return
	_layer = CanvasLayer.new()
	_layer.name = "ZondaSavePrompt"
	_layer.layer = LAYER
	_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	var cc := CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	_layer.add_child(cc)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_box())
	var th := _theme()
	if th != null:
		panel.theme = th
	cc.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 10)
	panel.add_child(vb)
	_title = _label(18, TXT)
	vb.add_child(_title)
	_info = _label(12, TXT_DIM)
	vb.add_child(_info)
	_warn = _label(11, TXT_WARN)
	vb.add_child(_warn)
	var hb := HBoxContainer.new()
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.add_theme_constant_override("separation", 24)
	vb.add_child(hb)
	_btn_a = _button()
	_btn_b = _button()
	hb.add_child(_btn_a)
	hb.add_child(_btn_b)
	_btn_a.pressed.connect(_on_a)
	_btn_b.pressed.connect(_on_b)
	_layer.visible = false
	get_tree().root.add_child.call_deferred(_layer)


# ---------------------------------------------------------------- guests: the hold

func show_hold(host_name: String, secs: float = 15.0) -> void:
	if not is_instance_valid(_hold_layer):
		_hold_layer = CanvasLayer.new()
		_hold_layer.name = "ZondaSaveHold"
		_hold_layer.layer = LAYER
		_hold_layer.process_mode = Node.PROCESS_MODE_ALWAYS
		var cc := CenterContainer.new()
		cc.set_anchors_preset(Control.PRESET_FULL_RECT)
		cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hold_layer.add_child(cc)
		var panel := PanelContainer.new()
		panel.add_theme_stylebox_override("panel", _panel_box())
		var th := _theme()
		if th != null:
			panel.theme = th
		cc.add_child(panel)
		_hold_label = _label(14, TXT)
		panel.add_child(_hold_label)
		_hold_layer.visible = false
		get_tree().root.add_child.call_deferred(_hold_layer)
	_hold_label.text = "Waiting for %s: continue the saved run or start new" % host_name
	_hold_layer.visible = true
	_hold_on = true
	_hold_until_ms = Time.get_ticks_msec() + int(secs * 1000.0)


func hide_hold() -> void:
	_hold_on = false
	if is_instance_valid(_hold_layer):
		_hold_layer.visible = false
