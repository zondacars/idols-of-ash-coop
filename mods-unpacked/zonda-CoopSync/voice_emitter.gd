extends Node3D

# ============================================================================================
# ZondaCoopSync voice chat: playback side (v4.9). One per remote knight.
#
# API FOR THE INTEGRATORS
#   remote_player.gd:  var e = load("res://mods-unpacked/zonda-CoopSync/voice_emitter.gd").new()
#                      e.position = Vector3(0, 1.6, 0); add_child(e)
#                      and its voice_push(pcm) just calls e.push(pcm).
#   var peer_id := 0          whose voice this is. Optional: when 0 (or the parent has one) it
#                             is read from the parent's `peer_id` every second.
#   var talking := false      true while samples arrived in the last 300 ms
#   signal talking_changed(on: bool)
#   func push(pcm: PackedFloat32Array)   mono -1..1 at CoopSync.voice.sample_rate (the output of
#                             CoopSync.voice.decode()). Call it from the main thread for every
#                             packet; before the node is in the tree it is simply ignored.
#   static func occlusion(space, from, to, exclude: Array[RID] = []) -> float  0 clear, .5 half, 1 blocked
#
# WHAT IT DOES
#   An AudioStreamPlayer3D playing an AudioStreamGenerator at the voice sample rate.
#   Jitter buffer: playback starts once 120 ms is queued (or 150 ms after the first packet, so a
#   short word still plays); a gap drops to silence with a 4 ms fade out and rebuffers 80 ms,
#   resuming with a 4 ms fade in (no clicks). Latency cap: if queued + in-flight audio passes
#   400 ms the oldest audio is dropped down to 160 ms with a 10 ms crossfade.
#   Sound physics: inverse-distance attenuation (unit_size 4 m, max_distance 70 m), bus
#   "ZondaCave" whenever that bus exists (voices ring with the cave's reverb) else "MainBus",
#   occlusion every 0.1 s from the listening camera to this emitter (collision layer 1, max 2
#   rays): blocked = attenuation_filter_cutoff_hz slides from 20000 toward 900 Hz and -6 dB,
#   smoothed, and the same cutoff drives a low-pass on the samples themselves (the player's own
#   filter only acts with distance, so a teammate right behind a rock would otherwise stay crisp).
#   Per-peer volume and mute: CoopSync.voice.peer_gain(peer_id), checked every 0.25 s.
#   A small "((•))" mark above the parent's name tag while talking.
#   Idle for 3 s: the player stops (costs nothing); the next push restarts it.
# ============================================================================================

signal talking_changed(on: bool)

const FALLBACK_RATE := 24000
const CAVE_BUS := "ZondaCave"
const JITTER_S := 0.12
const REBUFFER_S := 0.08
const START_WAIT_MS := 150
const LEAD_S := 0.06                    # audio kept inside the generator ahead of the mixer
const MAX_LATENCY_S := 0.40
const TRIM_TO_S := 0.16
const FADE_S := 0.004
const XFADE_S := 0.01
const TALK_HOLD_MS := 300
const IDLE_STOP_MS := 3000
const OCC_CLEAR_HZ := 20000.0
const OCC_BLOCKED_HZ := 900.0
const OCC_DB := -6.0
const UNIT_SIZE := 4.0
const MAX_DIST := 70.0

var peer_id := 0
var talking := false
var stat_samples_in := 0                # samples received (diagnostics, read by the loopback test)
var stat_frames_out := 0                # frames handed to the audio generator

var _player: AudioStreamPlayer3D = null
var _gen: AudioStreamGenerator = null
var _pb: AudioStreamGeneratorPlayback = null
var _rate: int = FALLBACK_RATE
var _q := PackedFloat32Array()
var _qr := 0                            # read index into _q
var _buffering := true
var _rebuffer := false
var _fade_in := true
var _first_ms := -1
var _last_push_ms := -100000
var _cap := 0
var _gain := 1.0
var _gain_t := 0.0
var _occ := 0.0
var _occ_target := 0.0
var _occ_t := 0.0
var _lp := 0.0
var _slow_t := 0.0
var _mark: Label3D = null
var _mark_t := 0.0


func _ready() -> void:
	# keeps feeding (and the player keeps playing) while the pause menu pauses the tree: the
	# knight freezes, but teammates can still be heard. Otherwise audio queued during the pause
	# would come out as a lump afterwards.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rate = _voice_rate()
	_build_player()
	_mark = Label3D.new()
	_mark.text = "((•))"
	_mark.pixel_size = 0.005
	_mark.font_size = 40
	_mark.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	_mark.no_depth_test = true
	_mark.modulate = Color(0.91, 0.82, 0.54, 0.9)
	_mark.outline_size = 8
	_mark.outline_modulate = Color(0, 0, 0, 0.8)
	_mark.visible = false
	add_child(_mark)
	_slow_update()


func _build_player() -> void:
	if is_instance_valid(_player):
		_player.stop()
		_player.queue_free()
	_gen = AudioStreamGenerator.new()
	_gen.mix_rate = float(_rate)
	_gen.buffer_length = 0.5
	_player = AudioStreamPlayer3D.new()
	_player.stream = _gen
	_player.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
	_player.unit_size = UNIT_SIZE
	_player.max_distance = MAX_DIST
	_player.max_db = 6.0
	_player.attenuation_filter_cutoff_hz = OCC_CLEAR_HZ
	_player.attenuation_filter_db = -24.0
	_player.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
	_player.bus = _pick_bus()
	add_child(_player)
	_pb = null
	_cap = 0
	_reset_stream_state()


func _reset_stream_state() -> void:
	_q = PackedFloat32Array()
	_qr = 0
	_buffering = true
	_rebuffer = false
	_fade_in = true
	_first_ms = -1


static func _pick_bus() -> String:
	# voice.gd creates ZondaCave at startup, so this is the cave bus on every level. Without it,
	# MainBus: the game's volume slider only controls MainBus, "Master" would bypass it.
	if AudioServer.get_bus_index(CAVE_BUS) >= 0:
		return CAVE_BUS
	return "MainBus" if AudioServer.get_bus_index("MainBus") >= 0 else "Master"


func _voice() -> Object:
	var v = CoopSync.get("voice")
	if v is Object and is_instance_valid(v):
		return v
	return null


func _voice_rate() -> int:
	var v := _voice()
	if v != null:
		var sr = v.get("sample_rate")
		if sr != null:
			var r := int(sr)
			if r >= 8000 and r <= 48000:
				return r
	return FALLBACK_RATE


# ---------------------------------------------------------------- input from the network

func push(pcm: PackedFloat32Array) -> void:
	if pcm.is_empty() or not is_inside_tree() or not is_instance_valid(_player):
		return
	var now := Time.get_ticks_msec()
	_last_push_ms = now
	stat_samples_in += pcm.size()
	if _gain <= 0.0:
		return                              # muted: drop it, and nothing is queued for later
	var r := _voice_rate()
	if r != _rate:
		_rate = r
		_build_player()
	if _buffering and _first_ms < 0:
		_first_ms = now
	_q.append_array(pcm)
	if not _player.playing:
		_player.play()
		_pb = _player.get_stream_playback() as AudioStreamGeneratorPlayback
		_cap = 0


func _queued() -> int:
	return _q.size() - _qr


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if not is_instance_valid(_player):
		return
	var now := Time.get_ticks_msec()
	_slow_t -= delta
	if _slow_t <= 0.0:
		_slow_t = 1.0
		_slow_update()
	_gain_t -= delta
	if _gain_t <= 0.0:
		_gain_t = 0.25
		_refresh_gain()
	_occ_t -= delta
	if _occ_t <= 0.0:
		_occ_t = 0.1
		_occ_target = _measure_occlusion()
	_occ = lerpf(_occ, _occ_target, 1.0 - exp(-delta * 7.0))
	var cutoff := OCC_CLEAR_HZ * pow(OCC_BLOCKED_HZ / OCC_CLEAR_HZ, _occ)
	_player.attenuation_filter_cutoff_hz = cutoff
	_player.volume_db = (linear_to_db(_gain) if _gain > 0.0001 else -80.0) + OCC_DB * _occ

	var on := now - _last_push_ms < TALK_HOLD_MS and _gain > 0.0
	if on != talking:
		talking = on
		talking_changed.emit(on)
	if is_instance_valid(_mark):
		if _mark.visible != on:
			_mark.visible = on
		if on:
			_mark_t += delta
			_mark.modulate.a = 0.65 + 0.3 * sin(_mark_t * 9.0)

	if _player.playing:
		_feed(delta, now, cutoff)
		if _queued() == 0 and now - _last_push_ms > IDLE_STOP_MS:
			_player.stop()
			_pb = null
			_reset_stream_state()


func _slow_update() -> void:
	var bus := _pick_bus()
	if is_instance_valid(_player) and _player.bus != bus:
		_player.bus = bus
	var p := get_parent()
	if p != null:
		var pid = p.get("peer_id")
		if pid != null and int(pid) != 0:
			peer_id = int(pid)
		# the mark sits just above the parent's name tag, whatever height that is
		var tag = p.get("_label")
		if tag is Label3D and is_instance_valid(_mark):
			var t: Label3D = tag
			_mark.position = t.position - position + Vector3(0, 0.3, 0)
			_mark.no_depth_test = t.no_depth_test
		elif is_instance_valid(_mark):
			_mark.position = Vector3(0, 0.7, 0)


func _refresh_gain() -> void:
	var g := 1.0
	var v := _voice()
	if v != null and v.has_method("peer_gain"):
		g = float(v.call("peer_gain", peer_id))
	g = clampf(g, 0.0, 4.0)
	if g <= 0.0 and _gain > 0.0:
		_reset_stream_state()               # just muted: forget what was queued
	_gain = g


# ---------------------------------------------------------------- jitter buffer

func _feed(delta: float, now: int, cutoff: float) -> void:
	if _pb == null:
		_pb = _player.get_stream_playback() as AudioStreamGeneratorPlayback
		if _pb == null:
			return
	var avail := _pb.get_frames_available()
	_cap = maxi(_cap, avail)
	var filled := maxi(0, _cap - avail)
	var rate := float(_rate)
	var queued := _queued()
	# latency cap: never let the voice fall more than 400 ms behind
	if queued > 0 and float(queued + filled) > MAX_LATENCY_S * rate:
		_trim(maxi(int(TRIM_TO_S * rate) - filled, int(XFADE_S * rate) + 1))
		queued = _queued()
	if _buffering:
		if queued <= 0:
			return
		var need := int((REBUFFER_S if _rebuffer else JITTER_S) * rate)
		if queued < need and (_first_ms < 0 or now - _first_ms < START_WAIT_MS):
			return
		_buffering = false
		_fade_in = true
	var lead := int(maxf(LEAD_S, delta * 2.5) * rate)
	var want := mini(lead - filled, avail)
	if want <= 0:
		return
	var n := mini(want, queued)
	if n <= 0:
		return
	var chunk := _q.slice(_qr, _qr + n)
	_qr += n
	if _qr > 8192 and _qr * 2 > _q.size():
		_q = _q.slice(_qr)
		_qr = 0
	var underrun := _queued() == 0
	var fade := maxi(1, int(FADE_S * rate))
	# occlusion low-pass on the samples (one pole), bypassed while the line is clear
	var filt := _occ > 0.02
	var a := 1.0 - exp(-TAU * cutoff / rate)
	var frames := PackedVector2Array()
	frames.resize(n)
	var y := _lp
	for i in n:
		var s: float = chunk[i]
		if filt:
			y += a * (s - y)
			s = y
		else:
			y = s
		if _fade_in and i < fade:
			s *= float(i + 1) / float(fade + 1)
		if underrun and i >= n - fade:
			s *= float(n - i) / float(fade + 1)
		s = clampf(s, -1.0, 1.0)
		frames[i] = Vector2(s, s)
	_lp = y
	_fade_in = false
	if _pb.can_push_buffer(n):
		_pb.push_buffer(frames)
		stat_frames_out += n
	if underrun:
		# out of audio: we faded to zero, now wait for a little more before resuming
		_buffering = true
		_rebuffer = true
		_first_ms = -1
		_lp = 0.0


func _trim(keep: int) -> void:
	var queued := _queued()
	var drop := queued - keep
	if drop <= 0:
		return
	var x := mini(int(XFADE_S * float(_rate)), keep)
	var a := _qr
	var b := _qr + drop
	for i in x:
		var t := float(i + 1) / float(x + 1)
		_q[b + i] = _q[a + i] * (1.0 - t) + _q[b + i] * t
	_qr = b


# ---------------------------------------------------------------- occlusion

func _measure_occlusion() -> float:
	if not is_inside_tree():
		return 0.0
	var vp := get_viewport()
	if vp == null:
		return 0.0
	var cam := vp.get_camera_3d()
	if cam == null or not cam.is_inside_tree():
		return 0.0
	var from := cam.global_position
	var to := global_position
	if from.distance_squared_to(to) > MAX_DIST * MAX_DIST:
		return _occ_target                  # out of earshot anyway: skip the rays
	var w := get_world_3d()
	if w == null or w.direct_space_state == null:
		return 0.0
	var ex: Array[RID] = []
	var c = Game.climber
	if is_instance_valid(c) and c.is_inside_tree() and c is CollisionObject3D:
		ex.append((c as CollisionObject3D).get_rid())
	return occlusion(w.direct_space_state, from, to, ex)


static func occlusion(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, exclude: Array[RID] = []) -> float:
	# 0 = clear line, 1 = rock (collision layer 1) in the way; at most 2 rays. A second ray
	# 0.6 m higher tells a low lip or a ledge edge (half muffled) from a solid wall.
	if space == null:
		return 0.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 1)
	if not exclude.is_empty():
		q.exclude = exclude
	if space.intersect_ray(q).is_empty():
		return 0.0
	var up := Vector3.UP * 0.6
	var q2 := PhysicsRayQueryParameters3D.create(from + up, to + up, 1)
	if not exclude.is_empty():
		q2.exclude = exclude
	if space.intersect_ray(q2).is_empty():
		return 0.5
	return 1.0
