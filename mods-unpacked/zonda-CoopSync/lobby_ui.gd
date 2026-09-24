extends CanvasLayer

var _panel: Panel
var _name_edit: LineEdit
var _password_edit: LineEdit
var _host_btn: Button
var _join_btn: Button
var _disconnect_btn: Button
var _status_label: Label
var _roster_label: Label
var _panel_visible := false
# v4.9 voice chat column
var _voice_mode_label: Label
var _voice_mode_btn: Button
var _voice_slider: HSlider
var _voice_vol_label: Label
var _voice_rows: VBoxContainer
var _voice_rows_key := "-"
var _voice_row_labels: Dictionary = {}     # steam id (0 = you) -> [Label, name]
var _voice_row_mutes: Dictionary = {}      # steam id -> CheckBox


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_panel.visible = false


func _process(_delta: float) -> void:
	if _panel_visible:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		var txt := CoopSync.perf_text()
		if CoopSync.in_session():
			txt = "In lobby: " + CoopSync.get_roster() + "\n" + txt
		_roster_label.text = txt
		_update_voice_ui()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == Key.KEY_F2:
		_set_panel_visible(not _panel_visible)


func set_status(msg: String) -> void:
	if _status_label:
		_status_label.text = msg


func set_connected(connected: bool) -> void:
	if _host_btn:
		_host_btn.visible = not connected
		_join_btn.visible = not connected
		_disconnect_btn.visible = connected
		_name_edit.editable = not connected
		_password_edit.editable = not connected


func _build_ui() -> void:
	_panel = Panel.new()
	_panel.anchor_left = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_bottom = 0.5
	# two columns since v4.9 (connection | voice chat): the game draws its UI at 640x360
	_panel.offset_left = -316.0
	_panel.offset_top = -175.0
	_panel.offset_right = 316.0
	_panel.offset_bottom = 175.0
	var th := Theme.new()
	th.default_font_size = 12
	_panel.theme = th
	add_child(_panel)

	var cols := HBoxContainer.new()
	cols.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 8)
	cols.add_theme_constant_override("separation", 8)
	_panel.add_child(cols)

	var vbox := VBoxContainer.new()
	vbox.custom_minimum_size = Vector2(330, 0)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 2)
	cols.add_child(vbox)
	cols.add_child(VSeparator.new())
	var vcol := VBoxContainer.new()
	vcol.custom_minimum_size = Vector2(260, 0)
	vcol.add_theme_constant_override("separation", 3)
	cols.add_child(vcol)
	_build_voice_ui(vcol)

	var title := Label.new()
	title.text = "CO-OP SYNC   [F2 to toggle]"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var hint := Label.new()
	hint.text = "Host picks the level, everyone follows. 1 respawn each, then spectate."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.7)
	vbox.add_child(hint)

	vbox.add_child(HSeparator.new())

	_name_edit = _make_line_edit("Your Name", false)
	vbox.add_child(_make_row("Name", _name_edit))

	_password_edit = _make_line_edit("Session Password", true)
	vbox.add_child(_make_row("Password", _password_edit))

	vbox.add_child(HSeparator.new())

	_host_btn = Button.new()
	_host_btn.text = "Host Game"
	_host_btn.pressed.connect(_on_host_pressed)
	vbox.add_child(_host_btn)

	_join_btn = Button.new()
	_join_btn.text = "Join Game"
	_join_btn.pressed.connect(_on_join_pressed)
	vbox.add_child(_join_btn)

	vbox.add_child(HSeparator.new())

	_status_label = Label.new()
	# the build every player must share (same zip), shown so friends can compare by eye
	_status_label.text = "Not connected.\nUses Steam, no port forwarding needed.\nCoopSync build %s" % CoopSync.build_id
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_label)

	_roster_label = Label.new()
	_roster_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_roster_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_roster_label)

	_disconnect_btn = Button.new()
	_disconnect_btn.text = "Disconnect"
	_disconnect_btn.visible = false
	_disconnect_btn.pressed.connect(_on_disconnect_pressed)
	vbox.add_child(_disconnect_btn)


func _build_voice_ui(col: VBoxContainer) -> void:
	var title := Label.new()
	title.text = "VOICE CHAT"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	var hint := Label.new()
	hint.text = "Voice: push to talk (hold V) / open mic (F7)"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.modulate = Color(1, 1, 1, 0.7)
	col.add_child(hint)

	_voice_mode_label = Label.new()
	_voice_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(_voice_mode_label)

	_voice_mode_btn = Button.new()
	_voice_mode_btn.focus_mode = Control.FOCUS_NONE     # Space (jump) must never press it
	_voice_mode_btn.pressed.connect(_on_voice_mode_pressed)
	col.add_child(_voice_mode_btn)

	var vrow := HBoxContainer.new()
	var vl := Label.new()
	vl.text = "Volume"
	vrow.add_child(vl)
	_voice_slider = HSlider.new()
	_voice_slider.min_value = 0.0
	_voice_slider.max_value = 200.0
	_voice_slider.step = 5.0
	_voice_slider.focus_mode = Control.FOCUS_NONE
	_voice_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_voice_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var v = CoopSync.voice
	_voice_slider.value = float(v.volume) * 100.0 if v != null else 100.0
	_voice_slider.value_changed.connect(_on_voice_volume_changed)
	vrow.add_child(_voice_slider)
	_voice_vol_label = Label.new()
	_voice_vol_label.custom_minimum_size = Vector2(40, 0)
	_voice_vol_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_voice_vol_label.text = "%d%%" % int(_voice_slider.value)
	vrow.add_child(_voice_vol_label)
	col.add_child(vrow)

	col.add_child(HSeparator.new())
	var pl := Label.new()
	pl.text = "Players (tick Mute to silence one)"
	pl.modulate = Color(1, 1, 1, 0.7)
	col.add_child(pl)
	_voice_rows = VBoxContainer.new()
	_voice_rows.add_theme_constant_override("separation", 1)
	col.add_child(_voice_rows)


func _update_voice_ui() -> void:
	var v = CoopSync.voice
	if v == null:
		_voice_mode_label.text = "Voice chat is unavailable."
		_voice_mode_btn.visible = false
		return
	var om := bool(v.open_mic)
	_voice_mode_label.text = "Now: OPEN MIC (Steam cuts silence)" if om else "Now: PUSH TO TALK, hold V"
	var bt := "Switch to push to talk" if om else "Switch to open mic"
	if _voice_mode_btn.text != bt:
		_voice_mode_btn.text = bt
	var want := float(v.volume) * 100.0
	if absf(_voice_slider.value - want) > 0.5 and not _voice_slider.has_focus():
		_voice_slider.set_value_no_signal(want)
		_voice_vol_label.text = "%d%%" % int(round(want))
	# rows: you first, then everyone else; rebuilt only when the roster changes
	var peers: Array = CoopSync.voice_peers() if CoopSync.in_session() else []
	var key := "S" if CoopSync.in_session() else "N"
	for pr in peers:
		key += "%d:%s|" % [int(pr[0]), str(pr[1])]
	if key != _voice_rows_key:
		_voice_rows_key = key
		_rebuild_voice_rows(peers)
	for id in _voice_row_labels.keys():
		var entry: Array = _voice_row_labels[id]
		var lab: Label = entry[0]
		var talk: bool = bool(v.talking) if int(id) == 0 else CoopSync.peer_talking(int(id))
		var txt: String = str(entry[1]) + ("   ((speaking))" if talk else "")
		if lab.text != txt:
			lab.text = txt
	for id in _voice_row_mutes.keys():
		var cb: CheckBox = _voice_row_mutes[id]
		var m := bool(v.is_muted(int(id)))
		if cb.button_pressed != m:
			cb.set_pressed_no_signal(m)


func _rebuild_voice_rows(peers: Array) -> void:
	for c in _voice_rows.get_children():
		c.queue_free()
	_voice_row_labels.clear()
	_voice_row_mutes.clear()
	if not CoopSync.in_session():
		var none := Label.new()
		none.text = "Host or join a lobby to talk."
		none.modulate = Color(1, 1, 1, 0.6)
		_voice_rows.add_child(none)
		return
	var me := Label.new()
	me.clip_text = true
	_voice_rows.add_child(me)
	_voice_row_labels[0] = [me, "You"]
	if peers.is_empty():
		var alone := Label.new()
		alone.text = "Nobody else here yet."
		alone.modulate = Color(1, 1, 1, 0.6)
		_voice_rows.add_child(alone)
	for pr in peers:
		var id: int = int(pr[0])
		var row := HBoxContainer.new()
		var lab := Label.new()
		lab.clip_text = true
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lab)
		var cb := CheckBox.new()
		cb.text = "Mute"
		cb.focus_mode = Control.FOCUS_NONE
		cb.toggled.connect(_on_mute_toggled.bind(id))
		row.add_child(cb)
		_voice_rows.add_child(row)
		_voice_row_labels[id] = [lab, CoopSync.sanitize_name(str(pr[1]))]
		_voice_row_mutes[id] = cb


func _on_voice_mode_pressed() -> void:
	var v = CoopSync.voice
	if v != null:
		v.set_open_mic(not bool(v.open_mic))


func _on_voice_volume_changed(value: float) -> void:
	_voice_vol_label.text = "%d%%" % int(round(value))
	var v = CoopSync.voice
	if v != null:
		v.set_volume(value / 100.0)


func _on_mute_toggled(on: bool, peer_id: int) -> void:
	var v = CoopSync.voice
	if v != null:
		v.set_muted(peer_id, on)


func _make_line_edit(placeholder: String, secret: bool) -> LineEdit:
	var edit := LineEdit.new()
	edit.placeholder_text = placeholder
	edit.secret = secret
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return edit


func _make_row(label_text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(72, 0)
	row.add_child(lbl)
	row.add_child(control)
	return row


func _set_panel_visible(v: bool) -> void:
	_panel_visible = v
	_panel.visible = v


func _read_inputs() -> Array:
	var player_name := CoopSync.sanitize_name(_name_edit.text)
	if player_name == "Player":
		player_name = CoopSync.sanitize_name(Game.steam_name)
	return [player_name, _password_edit.text.strip_edges()]


func _on_host_pressed() -> void:
	var inputs := _read_inputs()
	if inputs[1].is_empty():
		set_status("Enter a password so friends can find your lobby.")
		return
	set_status("Creating Steam lobby...")
	set_connected(true)
	CoopSync.host(inputs[0], inputs[1])


func _on_join_pressed() -> void:
	var inputs := _read_inputs()
	if inputs[1].is_empty():
		set_status("Enter the host's password.")
		return
	set_status("Searching for lobby (worldwide)...")
	set_connected(true)
	CoopSync.join(inputs[0], inputs[1])


func _on_disconnect_pressed() -> void:
	CoopSync.disconnect_session()
	set_status("Disconnected.")
	set_connected(false)
