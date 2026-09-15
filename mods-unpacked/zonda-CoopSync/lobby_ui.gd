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
	_panel.offset_left = -215.0
	_panel.offset_top = -172.0
	_panel.offset_right = 215.0
	_panel.offset_bottom = 172.0
	add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 8)
	vbox.add_theme_constant_override("separation", 2)
	_panel.add_child(vbox)

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
	_status_label.text = "Not connected.\nUses Steam, no port forwarding needed."
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
	var player_name := _name_edit.text.strip_edges()
	if player_name.is_empty():
		player_name = Game.steam_name if Game.steam_name != "" else "Player"
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
	set_status("Searching for lobby...")
	set_connected(true)
	CoopSync.join(inputs[0], inputs[1])


func _on_disconnect_pressed() -> void:
	CoopSync.disconnect_session()
	set_status("Disconnected.")
	set_connected(false)
