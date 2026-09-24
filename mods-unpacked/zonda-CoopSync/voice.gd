extends Node

# ============================================================================================
# ZondaCoopSync voice chat: capture side (v4.9). coop_sync adds one as CoopSync.voice.
#
# API FOR THE INTEGRATORS
#   const SAMPLE_RATE := 24000       fallback rate; the live rate is `sample_rate`
#   var sample_rate: int             the rate decode() returns samples at: Steam's optimal voice
#                                    rate (getVoiceOptimalSampleRate) when it is 11025..48000,
#                                    else SAMPLE_RATE. Fixed for the session. voice_emitter.gd
#                                    reads it; nothing else needs it.
#   var push_to_talk := true         mirror of `not open_mic`
#   var open_mic := false            F7 toggles (Steam's own voice detection gates the mic)
#   var talking := false             true while this player is transmitting
#   var volume := 1.0                master voice volume 0..2 (saved)
#   signal talking_changed(on: bool)
#   func poll_capture() -> PackedByteArray
#       Compressed Steam voice captured since the last call; empty when not transmitting.
#       coop_sync calls it every 40 ms while in a session. Calling it is also what tells this
#       module a session is live: the mic is only ever opened while the polls keep coming
#       (no poll for 0.5 s = mic closed, HUD mark hidden).
#   func decode(bytes: PackedByteArray) -> PackedFloat32Array
#       Mono samples -1..1 at `sample_rate`. Empty on bad data. Handles the "ZVT1" test tone.
#   func peer_gain(peer_id: int) -> float      0 when muted, else volume * that peer's volume
#   func is_muted(peer_id: int) -> bool
#   func set_muted(peer_id: int, on: bool)     saved
#   func set_peer_volume(peer_id: int, v: float)   0..2, saved
#   func set_volume(v: float)                  0..2, saved
#   func set_open_mic(on: bool)                saved, shows a banner
#
# CONTROLS: hold V = push to talk, F7 = open mic on/off. Both through _unhandled_input, so
#   typing a V in the lobby's name or password box never keys the mic.
# SETTINGS: user://zonda_voice.cfg  [voice] open_mic, volume, muted (Array of steam id
#   strings), peer_volume (Dictionary steam id string -> float).
# DEV TEST: if res://mods-unpacked/zonda-CoopSync/voice_test.flag exists at startup (it is
#   deleted as soon as it is read), poll_capture returns a synthetic 440 Hz tone burst
#   (0.6 s every 2 s) as "ZVT1" + raw PCM16 mono at sample_rate, no microphone or PTT needed,
#   and decode() passes it straight through, so the loopback Ghost talks back.
#
# GodotSteam 4.18 (the build the game ships, checked against its source, tag v4.18-gde):
#   Steam.getVoice(buffer_size_override = 0) -> {"result": int, "buffer": PackedByteArray,
#       "written": int}  (buffer already trimmed to written)
#   Steam.decompressVoice(voice_data, sample_rate, buffer_size_override = 20480) ->
#       {"result": int, "size": int, "uncompressed": PackedByteArray} where "uncompressed"
#       is the FULL override-sized buffer: only the first "size" bytes are audio.
#   Both are read defensively (raw PackedByteArray returns and other key names accepted).
# ============================================================================================

signal talking_changed(on: bool)

const SAMPLE_RATE := 24000
const CFG := "user://zonda_voice.cfg"
const MOD_DIR := "res://mods-unpacked/zonda-CoopSync/"
const TEST_MAGIC := "ZVT1"
const POLL_ALIVE_MS := 500              # no poll_capture for this long = no session, mic off
const TAIL_MS := 400                    # keep draining Steam's buffer after the mic closes
const VAD_HOLD_MS := 300                # open mic: "talking" holds this long after data
const DECODE_BUF := 20480
const DECODE_BUF_MAX := 262144
# Steam's EVoiceResult values, used when the Steam singleton lacks the enum constants
const VR_OK := 0
const VR_BUFFER_TOO_SMALL := 4

var sample_rate: int = SAMPLE_RATE
var push_to_talk := true
var open_mic := false
var talking := false
var volume := 1.0
var muted: Dictionary = {}              # steam id (int) -> true
var peer_volume: Dictionary = {}        # steam id (int) -> 0..2

var _ptt_held := false
var _recording := false
var _rec_stop_ms := -1                  # when the mic closed; drain the tail until TAIL_MS
var _last_poll_ms := -100000
var _last_data_ms := -100000
var _steam_ok := false
var _steam_checked_ms := -100000
var _my_id := 0
var _rate_locked := false               # sample_rate is final (read once, the first time Steam is up)
var _getvoice_argc := -1                # how many arguments this GodotSteam's getVoice takes
var _getvoice_big := false              # Steam said BUFFER_TOO_SMALL once: always ask with a big buffer
const GETVOICE_BIG := 16384

var _test := false
var _test_t := 0.0
var _test_phase := 0.0
var _test_last_ms := -1

var _hud: CanvasLayer = null
var _hud_label: Label = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load()
	_test = FileAccess.file_exists(MOD_DIR + "voice_test.flag")
	if _test:
		var disk := OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/voice_test.flag"
		var err := DirAccess.remove_absolute(disk)
		print("[CoopSync] voice test tone on (flag removed: %s)" % str(err == OK))
	# Steam is usually not up yet at _ready: the optimal rate is read on the first frame it is
	# (_check_steam) and stays fixed after that
	_check_steam()
	ensure_cave_bus()
	print("[CoopSync] voice ready, %s" % ("open mic" if open_mic else "push to talk (V)"))
	_build_hud()


# A mild, neutral cave reverb for voices on every level, created once if no map made it yet.
# The Underdark's soundscape.gd finds this same bus (by name, effects by type) and retunes it per
# biome; when it leaves it puts these neutral values back. Sends to MainBus, so the game's
# volume slider covers voices.
const CAVE_BUS := "ZondaCave"


static func ensure_cave_bus() -> void:
	if AudioServer.get_bus_index(CAVE_BUS) >= 0:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, CAVE_BUS)
	AudioServer.set_bus_send(idx, "MainBus" if AudioServer.get_bus_index("MainBus") >= 0 else "Master")
	var rev := AudioEffectReverb.new()
	rev.room_size = 0.45
	rev.damping = 0.5
	rev.spread = 0.8
	rev.wet = 0.12
	rev.dry = 1.0
	rev.predelay_msec = 30.0
	rev.predelay_feedback = 0.35
	rev.hipass = 0.1
	AudioServer.add_bus_effect(idx, rev)
	var lp := AudioEffectLowPassFilter.new()
	lp.cutoff_hz = 20000.0
	lp.resonance = 0.5
	AudioServer.add_bus_effect(idx, lp)
	print("[CoopSync] voice: created the ZondaCave bus (mild cave echo, sends to %s)" % AudioServer.get_bus_send(idx))


# ---------------------------------------------------------------- settings

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG) != OK:
		return
	open_mic = bool(cf.get_value("voice", "open_mic", false))
	push_to_talk = not open_mic
	volume = clampf(float(cf.get_value("voice", "volume", 1.0)), 0.0, 2.0)
	muted.clear()
	var m = cf.get_value("voice", "muted", [])
	if m is Array:
		for s in m:
			var id := str(s).to_int()
			if id != 0:
				muted[id] = true
	peer_volume.clear()
	var pv = cf.get_value("voice", "peer_volume", {})
	if pv is Dictionary:
		for k in pv.keys():
			var id := str(k).to_int()
			if id != 0:
				peer_volume[id] = clampf(float(pv[k]), 0.0, 2.0)


func _save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("voice", "open_mic", open_mic)
	cf.set_value("voice", "volume", volume)
	var m: Array = []
	for id in muted.keys():
		m.append(str(id))
	cf.set_value("voice", "muted", m)
	var pv := {}
	for id in peer_volume.keys():
		pv[str(id)] = float(peer_volume[id])
	cf.set_value("voice", "peer_volume", pv)
	cf.save(CFG)


func peer_gain(peer_id: int) -> float:
	if muted.has(peer_id):
		return 0.0
	var pv: float = float(peer_volume.get(peer_id, 1.0))
	return clampf(volume * pv, 0.0, 4.0)


func is_muted(peer_id: int) -> bool:
	return muted.has(peer_id)


func set_muted(peer_id: int, on: bool) -> void:
	if on:
		muted[peer_id] = true
	else:
		muted.erase(peer_id)
	_save()


func set_peer_volume(peer_id: int, v: float) -> void:
	peer_volume[peer_id] = clampf(v, 0.0, 2.0)
	_save()


func set_volume(v: float) -> void:
	volume = clampf(v, 0.0, 2.0)
	_save()


func set_open_mic(on: bool) -> void:
	open_mic = on
	push_to_talk = not on
	_save()
	CoopSync.show_banner("Voice: %s" % ("OPEN MIC   (F7 for push to talk)" if on else "PUSH TO TALK, hold V   (F7 for open mic)"), 3.0)


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	# unhandled: a focused LineEdit (lobby name/password) eats the key first, so typing
	# never opens the mic or flips the mode
	if not (event is InputEventKey) or event.echo:
		return
	var k := event as InputEventKey
	if k.keycode == KEY_V:
		if k.pressed and not _ptt_held:
			_ptt_held = true
		elif not k.pressed:
			_ptt_held = false
	elif k.keycode == KEY_F7 and k.pressed:
		set_open_mic(not open_mic)
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- capture

func _session_live() -> bool:
	return Time.get_ticks_msec() - _last_poll_ms < POLL_ALIVE_MS


func _check_steam() -> void:
	var now := Time.get_ticks_msec()
	if now - _steam_checked_ms < 2000:
		return
	_steam_checked_ms = now
	var ok := false
	if Engine.has_singleton("Steam") or ClassDB.class_exists("Steam"):
		var enabled := true
		if Game.has_method("is_steam_enabled"):
			enabled = bool(Game.is_steam_enabled())
		if enabled:
			_my_id = int(Steam.getSteamID())
			ok = _my_id != 0
	if not ok and _recording:
		_recording = false
	_steam_ok = ok
	if ok and not _rate_locked:
		_rate_locked = true
		if Steam.has_method("getVoiceOptimalSampleRate"):
			var r := int(Steam.getVoiceOptimalSampleRate())
			if r >= 11025 and r <= 48000:
				sample_rate = r
		print("[CoopSync] voice: Steam up, playback at %d Hz" % sample_rate)


func _process(_delta: float) -> void:
	_check_steam()
	var now := Time.get_ticks_msec()
	# a missed key-up (focus moved to a text box, window lost focus) must not leave the mic open
	if _ptt_held and not Input.is_physical_key_pressed(KEY_V) and not Input.is_key_pressed(KEY_V):
		_ptt_held = false
	if _ptt_held and not DisplayServer.window_is_focused():
		_ptt_held = false
	var live := _session_live()
	var want := live and _steam_ok and (open_mic or _ptt_held)
	if want and not _recording:
		Steam.startVoiceRecording()
		_recording = true
		_rec_stop_ms = -1
	elif not want and _recording:
		Steam.stopVoiceRecording()
		_recording = false
		_rec_stop_ms = now
	var on := false
	if live:
		if _test and _test_burst_on():
			on = true
		elif _ptt_held and _recording:
			on = true
		elif open_mic and _recording and now - _last_data_ms < VAD_HOLD_MS:
			on = true
	if on != talking:
		talking = on
		if _steam_ok and Steam.has_method("setInGameVoiceSpeaking"):
			Steam.setInGameVoiceSpeaking(_my_id, on)
		talking_changed.emit(on)
	if is_instance_valid(_hud_label) and _hud_label.visible != talking:
		_hud_label.visible = talking


func poll_capture() -> PackedByteArray:
	var now := Time.get_ticks_msec()
	_last_poll_ms = now
	if _test:
		return _test_capture(now)
	if not _steam_ok:
		return PackedByteArray()
	var draining := _rec_stop_ms >= 0 and now - _rec_stop_ms < TAIL_MS
	if not _recording and not draining:
		return PackedByteArray()
	var out := PackedByteArray()
	# up to 4 reads: Steam hands out what it has per call; stop on NO_DATA / not recording
	for _i in 4:
		var got = _get_voice()
		var buf := PackedByteArray()
		var res := VR_OK
		if got is Dictionary:
			res = int(got.get("result", VR_OK))
			var b = got.get("buffer", got.get("voice_data", PackedByteArray()))
			if b is PackedByteArray:
				buf = b
			var w := int(got.get("written", got.get("size", buf.size())))
			if w >= 0 and w < buf.size():
				buf = buf.slice(0, w)
		elif got is PackedByteArray:
			buf = got
		if res == VR_BUFFER_TOO_SMALL and not _getvoice_big and _getvoice_argc >= 1:
			# Steam keeps data it could not hand out, so a too-small default buffer would stall
			# the mic for good: from now on ask with a big buffer (after a hitch, say)
			_getvoice_big = true
			print("[CoopSync] voice: getVoice buffer too small, using %d bytes" % GETVOICE_BIG)
			continue
		if res != VR_OK or buf.is_empty():
			break
		out.append_array(buf)
		if out.size() > 8192:
			break
	if not out.is_empty():
		_last_data_ms = now
		if _ptt_held or open_mic or draining:
			return out
	return PackedByteArray()


func _get_voice():
	# Steam.getVoice() as this GodotSteam declares it: 4.18 has getVoice(buffer_size_override = 0),
	# newer builds getVoice(buffer_size = 1024). The argument is only passed when it exists.
	if _getvoice_argc < 0:
		_getvoice_argc = 0
		for m in ClassDB.class_get_method_list("Steam", true):
			if str(m.get("name", "")) == "getVoice":
				var a = m.get("args", [])
				_getvoice_argc = a.size() if a is Array else 0
				break
	if _getvoice_big and _getvoice_argc >= 1:
		return Steam.call("getVoice", GETVOICE_BIG)      # call(): no parse-time argument check
	return Steam.getVoice()


# ---------------------------------------------------------------- decode

func decode(bytes: PackedByteArray) -> PackedFloat32Array:
	if bytes.size() < 4:
		return PackedFloat32Array()
	if bytes[0] == 90 and bytes[1] == 86 and bytes[2] == 84 and bytes[3] == 49:     # "ZVT1"
		return _pcm16_to_float(bytes, 4, bytes.size() - 4)
	if not _steam_ok or not Steam.has_method("decompressVoice"):
		return PackedFloat32Array()
	var cap := DECODE_BUF
	while cap <= DECODE_BUF_MAX:
		var got = Steam.decompressVoice(bytes, sample_rate, cap)
		if got is PackedByteArray:
			var raw: PackedByteArray = got
			return _pcm16_to_float(raw, 0, raw.size())
		if not (got is Dictionary):
			return PackedFloat32Array()
		var res := int(got.get("result", VR_OK))
		var size := int(got.get("size", got.get("written", -1)))
		if res == VR_BUFFER_TOO_SMALL:
			cap = maxi(cap * 4, size + 1024)
			continue
		if res != VR_OK:
			return PackedFloat32Array()
		var pcm = got.get("uncompressed", got.get("buffer", got.get("output_buffer", PackedByteArray())))
		if not (pcm is PackedByteArray):
			return PackedFloat32Array()
		var pba: PackedByteArray = pcm
		if size < 0 or size > pba.size():
			size = pba.size()
		return _pcm16_to_float(pba, 0, size)
	return PackedFloat32Array()


static func _pcm16_to_float(b: PackedByteArray, start: int, length: int) -> PackedFloat32Array:
	var n := length / 2
	var out := PackedFloat32Array()
	if n <= 0:
		return out
	out.resize(n)
	var o := start
	for i in n:
		out[i] = float(b.decode_s16(o)) / 32768.0
		o += 2
	return out


# ---------------------------------------------------------------- developer test tone

func _test_burst_on() -> bool:
	return fmod(_test_t, 2.0) < 0.6


func _test_capture(now: int) -> PackedByteArray:
	if _test_last_ms < 0:
		_test_last_ms = now
		return PackedByteArray()
	var dt := clampf(float(now - _test_last_ms) / 1000.0, 0.0, 0.2)
	_test_last_ms = now
	var t0 := _test_t
	_test_t += dt
	var n := int(round(dt * float(sample_rate)))
	if n <= 0:
		return PackedByteArray()
	var out := PackedByteArray()
	out.resize(4 + n * 2)
	out[0] = 90
	out[1] = 86
	out[2] = 84
	out[3] = 49
	var any := false
	var step := TAU * 440.0 / float(sample_rate)
	for i in n:
		var t := t0 + float(i) / float(sample_rate)
		var ph := fmod(t, 2.0)
		var s := 0.0
		if ph < 0.6:
			# 20 ms fades at both ends of the burst so the tone itself has no clicks
			var env := minf(1.0, minf(ph / 0.02, (0.6 - ph) / 0.02))
			s = sin(_test_phase) * 0.35 * env
			any = true
		_test_phase = fmod(_test_phase + step, TAU)
		out.encode_s16(4 + i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	if not any:
		return PackedByteArray()
	_last_data_ms = now
	return out


# ---------------------------------------------------------------- HUD

func _build_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.layer = 91
	_hud.process_mode = Node.PROCESS_MODE_ALWAYS
	_hud_label = Label.new()
	_hud_label.text = "(( speaking ))"
	_hud_label.anchor_left = 0.0
	_hud_label.anchor_right = 0.0
	_hud_label.anchor_top = 1.0
	_hud_label.anchor_bottom = 1.0
	_hud_label.offset_left = 14.0
	_hud_label.offset_right = 200.0
	_hud_label.offset_top = -34.0
	_hud_label.offset_bottom = -12.0
	_hud_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var ls := LabelSettings.new()
	ls.font_size = 12
	ls.outline_size = 4
	ls.outline_color = Color.BLACK
	ls.font_color = Color(0.91, 0.82, 0.54, 0.85)       # the brand gold, a little dimmed
	_hud_label.label_settings = ls
	_hud_label.visible = false
	_hud.add_child(_hud_label)
	add_child(_hud)
