extends Node

# ============================================================================================
# ZondaCoopSync voice chat: capture side (v4.9.1). coop_sync adds one as CoopSync.voice.
#
# API FOR THE INTEGRATORS
#   const SAMPLE_RATE := 24000       fallback rate; the live rate is `sample_rate`
#   var sample_rate: int             the rate decode() returns samples at: Steam's optimal voice
#                                    rate (getVoiceOptimalSampleRate) when it is 11025..48000,
#                                    else SAMPLE_RATE. Fixed for the session. voice_emitter.gd
#                                    reads it; nothing else needs it.
#   var push_to_talk := false        mirror of `not open_mic` (kept for older callers)
#   var open_mic := true             v4.9.1: voice is ALWAYS ON while you talk (Steam's own voice
#                                    detection gates the Steam mic, the mod's voice gate gates a
#                                    picked microphone, so silence is never sent). F7 sets it false
#                                    = your own mic muted, for this session only (never saved)
#   var talking := false             true while this player is transmitting
#   var volume := 1.0                master voice volume 0..2 (saved)
#   signal talking_changed(on: bool)
#   func poll_capture() -> PackedByteArray
#       Voice captured since the last call, ready to send; empty when not transmitting.
#       Steam microphone: compressed Steam voice. Picked microphone: one "ZVA1" packet.
#       coop_sync calls it every 40 ms while in a session. Calling it is also what tells this
#       module a session is live: the mic is only ever opened while the polls keep coming
#       (no poll for 0.5 s = mic closed, HUD mark hidden), except for monitoring (below).
#   func decode(bytes: PackedByteArray) -> PackedFloat32Array   (v5.1.3: 3x louder, soft-limited)
#       Mono samples -1..1 at `sample_rate`. Empty on bad data. Handles "ZVA1" (a friend's
#       picked microphone), the "ZVT1" test tone (only while THIS PC runs voice_test.flag) and
#       Steam voice. Steam voice starts with the talker's SteamID, whose low 4 bytes can spell a
#       magic by chance: anything that does not parse as "ZVA1", and any "ZVT1" outside the test,
#       goes to Steam's decoder.
#   func peer_gain(peer_id: int) -> float      0 when muted, else volume * that peer's volume
#   func is_muted(peer_id: int) -> bool
#   func set_muted(peer_id: int, on: bool)     saved
#   func set_peer_volume(peer_id: int, v: float)   0..2, saved
#   func set_volume(v: float)                  0..2, saved
#   func set_open_mic(on: bool)                saved, shows a banner
#
#   MICROPHONE PICKER (contract K13, v4.9.1; the UI is mic_menu.gd)
#   var input_device := ""           "" = the Steam microphone (default, Steam's own settings
#                                    pick the device). Otherwise a name from
#                                    AudioServer.get_input_device_list() ("Default" = the
#                                    Windows default device). Saved.
#   var mic_level := 0.0             0..1 display level of the mod-captured mic: the peak mapped
#                                    from -60..0 dBFS, instant attack, falls 1.5 per second.
#                                    Stays 0 on the Steam path.
#   func list_input_devices() -> PackedStringArray
#       Godot's input device list ("Default" first). EMPTY when audio input is not enabled
#       (override.cfg [audio] driver/enable_input=true) or AudioServer lacks the API.
#   func set_input_device(device_name: String) -> void
#       "" = back to Steam. An unknown name falls back to "" and prints why. Saves. Switches
#       capture right away (the next frame at the latest).
#   func uses_steam_mic() -> bool                  input_device == ""
#   func saved_device() -> String
#       The device zonda_voice.cfg holds. It differs from input_device when the saved mic was
#       missing at startup or was unplugged while in use (input_device is "" for this run then):
#       a picker can say so instead of just showing STEAM MICROPHONE.
#   func set_monitor(on: bool) -> void
#       A picker UI is visible: on the mod path the mic is opened so mic_level is live, WITHOUT
#       transmitting. Reference counted: every set_monitor(true) needs a set_monitor(false).
#
#   THE DEMON VOICE (v5.0, THE IDOL WANTS A HOST)
#   const DEMON_BUS := "ZondaDemon"
#   static func ensure_demon_bus() -> void
#       Builds the bus "ZondaDemon" once (after ZondaCave, which it sends to; MainBus when the cave
#       bus is missing). Chain: PitchShift (0.80, oversampling 4, FFT 2048), Chorus 2 voices
#       (dry 0.9, wet 0.6; 22 ms / 3 ms / 0.3 Hz / -3 dB / 3000 Hz / pan -0.25 and 37 ms / 5 ms /
#       0.2 Hz / -5 dB / 2200 Hz / pan 0.25), Distortion OVERDRIVE (pre 6, drive 0.25, keep_hf
#       4000, post -8), LowPass 5000 Hz, Amplify +2 dB. A teammate who carries the idol is heard
#       through it (remote_player.gd -> voice_emitter.set_bus_override).
#   static func set_demon_level(k: float) -> void
#       k 0..1 = the idol's weight: pitch 0.80 -> 0.68 and drive 0.25 -> 0.55. At most 4 updates a
#       second, and only when k moved by 0.02 or more (the first call always applies).
#
# THE TWO CAPTURE PATHS
#   Steam (input_device == ""): Steam's voice API (startVoiceRecording / getVoice), exactly as
#     in v4.9. The mod never opens a microphone itself.
#   Mod (input_device != ""): Godot records the picked device through an AudioStreamPlayer
#     playing an AudioStreamMicrophone on the muted bus "ZondaMic": effects AudioEffectLowPassFilter
#     (7 kHz, one biquad, Q 0.707: the anti-alias filter for 16 kHz, run natively) then
#     AudioEffectCapture (0.5 s ring), drained on every poll. (Godot 4.6 runs a bus's effects
#     before it applies the bus mute, so a muted bus still feeds the capture and nothing is heard
#     locally.)
#     The mic is open only while needed: session live and (open mic or V held), plus a 400 ms
#     tail after V is released, or while a picker monitors it. Otherwise it is stopped so
#     Windows' mic-in-use mark goes away. If Windows will not open it (held in exclusive mode by
#     another app, a driver error) a banner says so and it is retried every 2 s. A named device
#     that disappears while open (unplugged) is checked for every 1.5 s: Godot 4.6 never reopens
#     it and would replay its last few ms in a loop, so the Steam microphone takes over for
#     this run (banner), exactly like a saved device that is missing at startup.
#     Each poll: low-passed stereo frames at AudioServer.get_mix_rate() -> mono -> linear
#     resample to 16 kHz (fractional phase kept across polls) -> level meter -> gate -> IMA
#     ADPCM. The GDScript loops run at the 16 kHz output rate only (resampler, encoder).
#     Gate: V held (or its 400 ms tail) always sends. Open mic sends while the voice gate is
#     open: RMS per 20 ms against an adaptive noise floor, opens at max(0.012, floor * 3.2),
#     holds 300 ms. Monitoring alone never sends.
#     Surround output (5.1 / 7.1, virtual 7.1 headsets too): Godot 4.6 feeds a bus effect once
#     per speaker pair, so the capture player mixes to all pairs (MIX_TARGET_SURROUND, identical
#     copies) and only one 512-frame block out of every pair count is kept.
#
# "ZVA1" PACKET (one per poll, each decodes on its own: voice is unreliable, packets can be
#   lost or reordered)
#   bytes 0-3  "ZVA1"
#   bytes 4-5  sample rate, u16 little-endian (16000 from this build; decode accepts 8000..48000)
#   bytes 6-7  initial predictor, i16 little-endian
#   byte  8    initial step index 0..88 (decode clamps it)
#   byte  9    reserved, 0
#   bytes 10.. IMA ADPCM nibbles (standard step and index tables), low nibble = earlier
#              sample. Sample count = 2 * (size - 10); an odd count is padded with one extra
#              sample. At most 4000 payload bytes = MAX_PACKET_SAMPLES (decode refuses more).
#   16 kHz mono = 8,000 bytes/s of nibbles, about 8,250 bytes/s with the headers.
#   decode() turns it back into samples and resamples them (linear) to this PC's sample_rate.
#
# CONTROLS: none needed, voice is always on while you talk. F7 mutes / unmutes your own mic for
#   this session (through _unhandled_input, so typing in the lobby's text boxes never flips it).
#   There is no push to talk any more: V does nothing. The microphone itself
#   is picked in the pause menu or the F2 panel (mic_menu.gd).
# SETTINGS: user://zonda_voice.cfg  [voice] open_mic, volume, muted (Array of steam id
#   strings), peer_volume (Dictionary steam id string -> float), input_device (String, ""
#   = Steam). A saved device that is missing at startup (unplugged, or audio input off) means
#   the Steam microphone for this run; the saved name is kept until another one is picked.
# DEV TEST: if res://mods-unpacked/zonda-CoopSync/voice_test.flag exists at startup (it is
#   deleted as soon as it is read), poll_capture returns a synthetic 440 Hz tone burst
#   (0.6 s every 2 s) as "ZVT1" + raw PCM16 mono at sample_rate, no microphone or PTT needed,
#   and decode() passes it straight through, so the loopback Ghost talks back.
# MIC TEST: if res://mods-unpacked/zonda-CoopSync/mic_test.flag exists at startup (deleted as
#   soon as it is read), the mod path runs with a SYNTHETIC voice instead of a microphone (a
#   180 Hz tone with 3 harmonics under a 4 Hz envelope, 0.6 s bursts every 2 s, as if V were
#   held during the bursts), through the same resampler, gate and ADPCM encoder, so the
#   loopback Ghost receives real "ZVA1" packets. No microphone needed. At startup it also runs
#   a codec self-test (1 s of that signal at 16 kHz, encoded in 40 ms packets and decoded) and
#   prints "[CoopSync] voice codec self-test: SNR x dB, n bytes/s". voice_test.flag wins when
#   both are present.
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

# ---- the mod-captured path (v4.9.1)
const ADPCM_MAGIC := "ZVA1"
const MOD_RATE := 16000                 # wire rate of a picked microphone
const ADPCM_HDR := 10
const ADPCM_MAX_PAYLOAD := 4000         # nibble bytes one packet may carry (= MAX_PACKET_SAMPLES / 2)
const MAX_PACKET_SAMPLES := 8000        # a backlog after a long hitch keeps only its newest 0.5 s
const DEV_CHECK_MS := 1500              # an open named microphone is looked for in the device list this often
const MIC_RETRY_MS := 2000              # a microphone Windows would not open is retried this often
const MIC_BUS := "ZondaMic"
const MIC_BUFFER_S := 0.5               # capture ring per speaker pair
const MIC_SETTLE_MS := 60               # audio from the first 60 ms after the mic opens is dropped
const MIX_BLOCK := 512                  # frames per AudioServer mix step (hardcoded in Godot 4.6)
const LPF_HZ := 7000.0
const GATE_WIN := 320                   # 20 ms at 16 kHz
const GATE_MIN := 0.012
const GATE_RATIO := 3.2
const GATE_HOLD_WIN := 15               # 15 windows of 20 ms = 300 ms
const LEVEL_DECAY := 1.5                # mic_level falls this much per second
const IMA_STEP := [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
	50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
	337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552,
	1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484,
	7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385,
	24623, 27086, 29794, 32767]
const IMA_INDEX := [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8]

var sample_rate: int = SAMPLE_RATE
var push_to_talk := false
var open_mic := true
var talking := false
var volume := 1.0
var muted: Dictionary = {}              # steam id (int) -> true
var peer_volume: Dictionary = {}        # steam id (int) -> 0..2
var input_device := ""                  # "" = Steam microphone, else a Godot input device name
var mic_level := 0.0                    # 0..1 display level of the mod-captured mic

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

# ---- mod-captured path state
var _cfg_device := ""                   # the device zonda_voice.cfg holds (kept while it is missing)
var _ptt_prev := false
var _ptt_up_ms := -100000               # when V was released (the 400 ms tail)
var _monitor_refs := 0
var _mic_capture: AudioEffectCapture = null
var _mic_player: AudioStreamPlayer = null
var _mic_open := false
var _mic_open_ms := 0
var _mic_chans := 1                     # speaker pairs feeding the capture (1 = stereo)
var _mic_retry_ms := -100000
var _mic_err := ""
var stat_mic_frames := 0                # diagnostics: frames pulled from the picked mic, and their raw peak
var stat_mic_raw_peak := 0.0
var _has_input_active := false          # AudioServer.set_input_device_active exists (4.6: yes)
var _dev_list := PackedStringArray()
var _dev_list_ms := -100000
var _dev_check_ms := -100000            # last unplug check of the open named microphone
# DSP: resampler, gate
var _dsp_rate := 0.0
var _rs_t := 0.0                        # next output position in input frames (-1 = the carried one)
var _rs_prev := 0.0                     # last mono input sample of the previous chunk
var _blk_phase := 0
var _g_acc := 0.0
var _g_cnt := 0
var _gate_floor := 0.003
var _gate_hold := 0                     # 20 ms windows left before the gate closes
var _chunk_gate := false                # the gate was open somewhere in the last pulled chunk
# ADPCM encoder
var _enc: Array = [0, 0]                # [predictor, step index] carried between packets
var _enc_cont := false                  # the last poll sent a packet: this one continues it
var _step_tab := PackedInt32Array()
var _idx_tab := PackedInt32Array()
# mic test (synthetic voice on the mod path)
var _mic_test := false
var _mt_t := 0.0
var _mt_last_ms := -1
var _mt_frac := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_step_tab = PackedInt32Array(IMA_STEP)
	_idx_tab = PackedInt32Array(IMA_INDEX)
	_has_input_active = AudioServer.has_method("set_input_device_active")
	_load()
	_test = FileAccess.file_exists(MOD_DIR + "voice_test.flag")
	if _test:
		var disk := OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/voice_test.flag"
		var err := DirAccess.remove_absolute(disk)
		print("[CoopSync] voice test tone on (flag removed: %s)" % str(err == OK))
	_mic_test = FileAccess.file_exists(MOD_DIR + "mic_test.flag")
	if _mic_test:
		var disk2 := OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/mic_test.flag"
		var err2 := DirAccess.remove_absolute(disk2)
		print("[CoopSync] mic test on: the mod microphone path sends a synthetic voice (flag removed: %s)" % str(err2 == OK))
		_codec_self_test()
	# Steam is usually not up yet at _ready: the optimal rate is read on the first frame it is
	# (_check_steam) and stays fixed after that
	_check_steam()
	ensure_cave_bus()
	print("[CoopSync] voice ready, always on (F7 mutes your mic)")
	print("[CoopSync] voice microphone: %s" % _mic_label())
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


# ---------------------------------------------------------------- the demon voice (v5.0)
# The idol's host speaks through this bus on every teammate's PC. A bus can only send to a bus
# with a lower index (AudioServer mixes from the last bus down and sends a later-index target to
# Master instead), so it is always appended after ZondaCave.

const DEMON_BUS := "ZondaDemon"
const DEMON_FX := 5
static var _demon_ms := -100000
static var _demon_k := -1.0


static func ensure_demon_bus() -> void:
	ensure_cave_bus()
	var send := CAVE_BUS if AudioServer.get_bus_index(CAVE_BUS) >= 0 else ("MainBus" if AudioServer.get_bus_index("MainBus") >= 0 else "Master")
	var idx := AudioServer.get_bus_index(DEMON_BUS)
	if idx >= 0 and AudioServer.get_bus_effect_count(idx) == DEMON_FX and idx > AudioServer.get_bus_index(send):
		if AudioServer.get_bus_send(idx) != StringName(send):
			AudioServer.set_bus_send(idx, send)
		return
	if idx >= 0:
		AudioServer.remove_bus(idx)          # wrong chain or placed before its send target: rebuild
	AudioServer.add_bus()
	idx = AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, DEMON_BUS)
	AudioServer.set_bus_send(idx, send)
	var ps := AudioEffectPitchShift.new()
	ps.pitch_scale = 0.80
	ps.oversampling = 4
	ps.fft_size = AudioEffectPitchShift.FFT_SIZE_2048
	AudioServer.add_bus_effect(idx, ps)
	var ch := AudioEffectChorus.new()
	ch.voice_count = 2
	ch.dry = 0.9
	ch.wet = 0.6
	ch.set_voice_delay_ms(0, 22.0)
	ch.set_voice_depth_ms(0, 3.0)
	ch.set_voice_rate_hz(0, 0.3)
	ch.set_voice_level_db(0, -3.0)
	ch.set_voice_cutoff_hz(0, 3000.0)
	ch.set_voice_pan(0, -0.25)
	ch.set_voice_delay_ms(1, 37.0)
	ch.set_voice_depth_ms(1, 5.0)
	ch.set_voice_rate_hz(1, 0.2)
	ch.set_voice_level_db(1, -5.0)
	ch.set_voice_cutoff_hz(1, 2200.0)
	ch.set_voice_pan(1, 0.25)
	AudioServer.add_bus_effect(idx, ch)
	var ds := AudioEffectDistortion.new()
	ds.mode = AudioEffectDistortion.MODE_OVERDRIVE
	ds.pre_gain = 6.0
	ds.drive = 0.25
	ds.keep_hf_hz = 4000.0
	ds.post_gain = -8.0
	AudioServer.add_bus_effect(idx, ds)
	var lp := AudioEffectLowPassFilter.new()
	lp.cutoff_hz = 5000.0
	AudioServer.add_bus_effect(idx, lp)
	var amp := AudioEffectAmplify.new()
	amp.volume_db = 2.0
	AudioServer.add_bus_effect(idx, amp)
	_demon_k = -1.0
	print("[CoopSync] voice: created the ZondaDemon bus (the idol's voice, sends to %s)" % send)


static func set_demon_level(k: float) -> void:
	k = clampf(k, 0.0, 1.0)
	var now := Time.get_ticks_msec()
	if _demon_k >= 0.0 and (now - _demon_ms < 250 or absf(k - _demon_k) < 0.02):
		return
	var idx := AudioServer.get_bus_index(DEMON_BUS)
	if idx < 0:
		return
	for i in AudioServer.get_bus_effect_count(idx):
		var e := AudioServer.get_bus_effect(idx, i)
		if e is AudioEffectPitchShift:
			(e as AudioEffectPitchShift).pitch_scale = lerpf(0.80, 0.68, k)
		elif e is AudioEffectDistortion:
			(e as AudioEffectDistortion).drive = lerpf(0.25, 0.55, k)
	_demon_ms = now
	_demon_k = k


static func demon_level() -> float:
	# the last level set_demon_level applied (-1 = never), for tests
	return _demon_k


# ---------------------------------------------------------------- settings

func _load() -> void:
	var cf := ConfigFile.new()
	if cf.load(CFG) != OK:
		return
	open_mic = true            # always on: an older saved push-to-talk choice is ignored, and F7's mute
	push_to_talk = false       # only lasts until the game closes
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
	var dev := str(cf.get_value("voice", "input_device", ""))
	_cfg_device = dev
	input_device = ""
	if dev != "":
		if list_input_devices().has(dev):
			input_device = dev
		else:
			print("[CoopSync] voice: the saved microphone \"%s\" is not available, using the Steam microphone" % dev)


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
	cf.set_value("voice", "input_device", _cfg_device)
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
	# F7 / the F2 button: false = your own mic muted for this session (not saved, so the next
	# game starts with voice on again)
	open_mic = on
	push_to_talk = false
	CoopSync.show_banner("Your mic: %s" % ("ON   (voice chat is always on, F7 mutes you)" if on else "MUTED   (F7 to unmute)"), 3.0)


# ---------------------------------------------------------------- microphone picker (K13)

static func _input_enabled() -> bool:
	return bool(ProjectSettings.get_setting("audio/driver/enable_input", false))


func list_input_devices() -> PackedStringArray:
	if not _input_enabled() or not AudioServer.has_method("get_input_device_list"):
		return PackedStringArray()
	var now := Time.get_ticks_msec()
	if now - _dev_list_ms > 1000:
		# Windows enumerates the devices on every call: a picker redrawing every frame reuses this
		_dev_list_ms = now
		var l = AudioServer.call("get_input_device_list")
		if l is PackedStringArray:
			_dev_list = l
		else:
			_dev_list = PackedStringArray()
	return _dev_list.duplicate()


func set_input_device(device_name: String) -> void:
	var dev := device_name
	if dev != "":
		_dev_list_ms = -100000              # a fresh list: the device may have just been plugged in
		if not list_input_devices().has(dev):
			var why := "it is not in the input device list"
			if not _input_enabled():
				why = "audio input is off, override.cfg needs [audio] driver/enable_input=true"
			elif not AudioServer.has_method("get_input_device_list"):
				why = "this Godot has no input device list"
			print("[CoopSync] voice: can not use the microphone \"%s\" (%s), back to the Steam microphone" % [dev, why])
			dev = ""
	_cfg_device = dev
	if dev != input_device:
		input_device = dev
		if _mic_open:
			if dev == "":
				_close_mic()                # _process starts Steam's recording on the next frame if needed
			else:
				_switch_device()
		# Steam -> a picked device: _process stops Steam's recording and opens this mic next frame
		print("[CoopSync] voice microphone: %s" % _mic_label())
	_save()


func uses_steam_mic() -> bool:
	return input_device == ""


func saved_device() -> String:
	return _cfg_device


func set_monitor(on: bool) -> void:
	# counted, not toggled: the pause menu and the F2 panel can both show a picker. The mic is
	# opened or closed by _process on the next frame, so an off+on in one frame costs nothing.
	if on:
		_monitor_refs += 1
	elif _monitor_refs > 0:
		_monitor_refs -= 1


func _mic_label() -> String:
	if _mic_test:
		return "synthetic test voice (mic_test.flag)"
	return "Steam microphone" if input_device == "" else "\"%s\" (captured by the mod)" % input_device


func _mod_path() -> bool:
	return _mic_test or input_device != ""


# ---------------------------------------------------------------- input

func _unhandled_input(event: InputEvent) -> void:
	# unhandled: a focused LineEdit (lobby name/password) eats the key first, so typing
	# never opens the mic or flips the mode
	if not (event is InputEventKey) or event.echo:
		return
	var k := event as InputEventKey
	if k.keycode == KEY_F7 and k.pressed:
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


func _process(delta: float) -> void:
	_check_steam()
	var now := Time.get_ticks_msec()
	# a missed key-up (focus moved to a text box, window lost focus) must not leave the mic open
	if _ptt_held and not Input.is_physical_key_pressed(KEY_V) and not Input.is_key_pressed(KEY_V):
		_ptt_held = false
	if _ptt_held and not DisplayServer.window_is_focused():
		_ptt_held = false
	if _ptt_prev and not _ptt_held:
		_ptt_up_ms = now                    # the mod path keeps sending for TAIL_MS after V is released
	_ptt_prev = _ptt_held
	var live := _session_live()
	var mod := _mod_path()
	# Steam path (unchanged from v4.9; never on while a picked microphone is in use)
	var want := live and _steam_ok and not mod and (open_mic or _ptt_held)
	if want and not _recording:
		Steam.startVoiceRecording()
		_recording = true
		_rec_stop_ms = -1
	elif not want and _recording:
		Steam.stopVoiceRecording()
		_recording = false
		_rec_stop_ms = now
	# mod path: open or close the picked microphone, keep the meter live outside a session
	_sync_mod_mic(now, live, mod)
	if mod and not live and (_mic_open or (_mic_test and _monitor_refs > 0)):
		_mod_pull(now)                      # nobody polls outside a session: monitoring only, never sent
		_enc_cont = false
	if mod:
		mic_level = maxf(0.0, mic_level - LEVEL_DECAY * delta)
	else:
		mic_level = 0.0
	var on := false
	if live:
		if _test and _test_burst_on():
			on = true
		elif mod:
			on = (_ptt_now() and (_mic_open or _mic_test)) or (open_mic and _gate_hold > 0)
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
	if _mod_path():
		return _mod_capture(now)
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


# ---------------------------------------------------------------- mod-captured path

func _ptt_now() -> bool:
	if _mic_test:
		return fmod(_mt_t, 2.0) < 0.6       # the synthetic voice "holds V" during its bursts
	return _ptt_held


func _ptt_tail(now: int) -> bool:
	if _mic_test:
		var ph := fmod(_mt_t, 2.0)
		return ph >= 0.6 and ph < 0.6 + float(TAIL_MS) / 1000.0
	# _ptt_prev: CoopSync (the parent) polls BEFORE this node's _process in a frame, so on the
	# frame V is released _ptt_up_ms still holds the previous release; the chunk captured while
	# V was down must go out anyway
	return _ptt_prev or now - _ptt_up_ms < TAIL_MS


func _sync_mod_mic(now: int, live: bool, mod: bool) -> void:
	var want := false
	if mod and not _mic_test:
		want = (live and (open_mic or _ptt_held or now - _ptt_up_ms < TAIL_MS)) or _monitor_refs > 0
	if want and not _mic_open:
		if now >= _mic_retry_ms and not _open_mic(now):
			_mic_retry_ms = now + MIC_RETRY_MS
	elif not want and _mic_open:
		_close_mic()
	elif _mic_open and _has_input_active:
		# a stopped microphone playback turns Godot's input off when it is freed, a few ms after
		# stop(): if the mic was reopened before that, this turns it back on (no-op otherwise).
		# Godot marks its input on BEFORE it asks Windows and keeps that mark when Windows says
		# no, which would make every later call a no-op: a refusal is undone and retried in 2 s.
		var e := int(AudioServer.call("set_input_device_active", true))
		if e != OK:
			AudioServer.call("set_input_device_active", false)
			_close_mic()
			_mic_fail("Windows would not open \"%s\", error %d" % [input_device, e])     # same text as _open_mic: one log line, one banner
			_mic_retry_ms = now + MIC_RETRY_MS
			return
	if _mic_open and not _mic_test and input_device != "" and input_device != "Default" \
			and now - _dev_check_ms >= DEV_CHECK_MS:
		_dev_check_ms = now
		_check_device_present()


func _check_device_present() -> void:
	# Godot 4.6 never reopens an unplugged named input device while it is open: the capture then
	# replays its last few ms round and round (a buzz the open mic gate takes for speech), even
	# after the device is plugged back in. "Default" is exempt: Godot follows Windows' default.
	_dev_list_ms = -100000                  # a fresh list, not the 1 s cache
	var l := list_input_devices()
	if l.is_empty() or l.has(input_device):
		return                              # empty = the list itself failed: no verdict
	print("[CoopSync] voice: the microphone \"%s\" is gone (unplugged?), using the Steam microphone for this run" % input_device)
	_close_mic()
	input_device = ""                       # _cfg_device keeps the pick, like a device missing at startup
	CoopSync.show_banner("Microphone unplugged, using STEAM MICROPHONE", 3.0)


func _mic_fail(why: String) -> void:
	if why != _mic_err:
		_mic_err = why
		print("[CoopSync] voice: can not open the microphone (%s)" % why)
		CoopSync.show_banner("Voice: can not open the picked microphone, retrying. Pick another in the pause menu.", 4.0)


func _open_mic(now: int) -> bool:
	if not _input_enabled():
		_mic_fail("audio input is off, override.cfg needs [audio] driver/enable_input=true")
		return false
	if not _ensure_mic_nodes():
		_mic_fail("the ZondaMic capture bus could not be set up")
		return false
	_apply_device()
	if _has_input_active:
		# ask Windows first: Godot marks its input on before input_start() and keeps the mark when
		# that fails (device held in exclusive mode by another app, WASAPI init error), leaving a
		# silent playback that looks open and a flag no later call can reset. A refusal is undone
		# so the 2 s retry really retries; on success play() finds the input already on.
		var e := int(AudioServer.call("set_input_device_active", true))
		if e != OK:
			AudioServer.call("set_input_device_active", false)
			_mic_fail("Windows would not open \"%s\", error %d" % [input_device, e])
			return false
	_mic_chans = _channel_count()
	_mic_capture.clear_buffer()
	_mic_player.play()
	_mic_open = true
	_mic_open_ms = now
	_mic_err = ""
	_blk_phase = 0
	_dsp_reset()
	_gate_hold = 0
	_enc_cont = false
	return true


func _close_mic() -> void:
	if is_instance_valid(_mic_player) and _mic_player.playing:
		_mic_player.stop()
	if _mic_open and _has_input_active:
		AudioServer.call("set_input_device_active", false)   # Windows' mic-in-use mark goes away now
	_mic_open = false
	_gate_hold = 0
	_g_acc = 0.0
	_g_cnt = 0
	_enc_cont = false


func _switch_device() -> void:
	# another picked device while the mic is open: Godot's audio thread swaps devices live
	_apply_device()
	if _mic_capture != null:
		_mic_capture.clear_buffer()
	_mic_open_ms = Time.get_ticks_msec()     # drop what is still in flight from the old device
	_enc_cont = false


func _apply_device() -> void:
	# AudioServer.input_device ("Default" = the Windows default; Godot itself falls back to
	# "Default" for a name that vanished since it was picked)
	if input_device != "" and AudioServer.has_method("set_input_device"):
		AudioServer.call("set_input_device", input_device)


static func _channel_count() -> int:
	# speaker pairs the AudioServer mixes (and feeds a bus effect with): stereo 1, 3.1 2, 5.1 3, 7.1 4
	return clampi(int(AudioServer.get_speaker_mode()) + 1, 1, 4)


func _ensure_mic_nodes() -> bool:
	var idx := AudioServer.get_bus_index(MIC_BUS)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, MIC_BUS)
		AudioServer.set_bus_send(idx, "Master")
		print("[CoopSync] voice: created the ZondaMic bus (muted, microphone capture only)")
	AudioServer.set_bus_mute(idx, true)
	var found := false
	var has_lp := false
	for i in AudioServer.get_bus_effect_count(idx):
		var fx = AudioServer.get_bus_effect(idx, i)
		if fx is AudioEffectLowPassFilter:
			has_lp = true
		if fx is AudioEffectCapture:
			_mic_capture = fx
			found = true
			break
	if not has_lp:
		# anti-alias for the 16 kHz resampler, ahead of the capture: exactly one RBJ biquad
		# (FILTER_6DB = 1 stage) with a Butterworth Q, in C++ instead of a 48 kHz GDScript loop
		var lp := AudioEffectLowPassFilter.new()
		lp.cutoff_hz = LPF_HZ
		lp.resonance = 0.7071
		lp.db = AudioEffectFilter.FILTER_6DB
		AudioServer.add_bus_effect(idx, lp, 0)
	if not found:
		var cap := AudioEffectCapture.new()
		cap.buffer_length = MIC_BUFFER_S * float(_channel_count())
		AudioServer.add_bus_effect(idx, cap)
		_mic_capture = cap
	if not is_instance_valid(_mic_player):
		_mic_player = AudioStreamPlayer.new()
		_mic_player.name = "ZondaMic"
		_mic_player.process_mode = Node.PROCESS_MODE_ALWAYS     # keeps recording in the pause menu
		_mic_player.stream = AudioStreamMicrophone.new()
		# every speaker pair gets the same copy (see _one_copy); stereo output ignores this
		_mic_player.mix_target = AudioStreamPlayer.MIX_TARGET_SURROUND
		add_child(_mic_player)
	_mic_player.bus = MIC_BUS
	return _mic_capture != null


func _mod_capture(now: int) -> PackedByteArray:
	var s := _mod_pull(now)
	if s.is_empty():
		return PackedByteArray()
	var send := _ptt_now() or _ptt_tail(now) or (open_mic and _chunk_gate)
	if not send:
		_enc_cont = false
		return PackedByteArray()
	if s.size() > MAX_PACKET_SAMPLES:
		s = s.slice(s.size() - MAX_PACKET_SAMPLES)
		_enc_cont = false
	var pkt := _adpcm_encode(s, MOD_RATE, _enc, _enc_cont)
	_enc_cont = true
	return pkt


func _mod_pull(now: int) -> PackedFloat32Array:
	# new mono samples at MOD_RATE since the last pull; updates mic_level and the gate
	_chunk_gate = false
	var rate := AudioServer.get_mix_rate()
	var fr := PackedVector2Array()
	if _mic_test:
		fr = _mic_test_frames(now, rate)
	elif _mic_open and _mic_capture != null:
		var avail := _mic_capture.get_frames_available()
		if now - _mic_open_ms < MIC_SETTLE_MS:
			if avail > 0:
				_mic_capture.clear_buffer()
			return PackedFloat32Array()
		if _mic_chans > 1:
			avail -= avail % MIX_BLOCK
		if avail <= 0:
			return PackedFloat32Array()
		fr = _mic_capture.get_buffer(avail)
		stat_mic_frames += fr.size()
		var j := 0
		while j < fr.size():                   # every 16th frame is plenty for a diagnostic peak
			var a := maxf(absf(fr[j].x), absf(fr[j].y))
			if a > stat_mic_raw_peak:
				stat_mic_raw_peak = a
			j += 16
		if _mic_chans > 1:
			fr = _one_copy(fr)
	return _dsp_run(fr, rate)


func _one_copy(fr: PackedVector2Array) -> PackedVector2Array:
	# surround: each mix step reaches the capture once per speaker pair, as identical 512-frame
	# blocks (MIX_TARGET_SURROUND), so keeping one block out of every _mic_chans is the mic once
	var out := PackedVector2Array()
	var n := fr.size()
	var b := 0
	while b + MIX_BLOCK <= n:
		if _blk_phase == 0:
			out.append_array(fr.slice(b, b + MIX_BLOCK))
		_blk_phase = (_blk_phase + 1) % _mic_chans
		b += MIX_BLOCK
	return out


func _dsp_reset() -> void:
	_rs_t = 0.0
	_rs_prev = 0.0
	_g_acc = 0.0
	_g_cnt = 0


func _dsp_run(fr: PackedVector2Array, rate: float) -> PackedFloat32Array:
	# stereo -> mono -> linear resample to MOD_RATE, the level meter and the gate, in one loop at
	# the output rate. The 7 kHz anti-alias low-pass already ran on the ZondaMic bus (the mic
	# test's synthetic voice has nothing above 1 kHz to fold back).
	var out := PackedFloat32Array()
	var n := fr.size()
	if n == 0 or rate < 1000.0:
		return out
	if absf(rate - _dsp_rate) > 0.5:
		_dsp_rate = rate
		_dsp_reset()
	var step := rate / float(MOD_RATE)
	var t := _rs_t                          # frame -1 is the last one of the previous chunk
	var prev := _rs_prev
	var last := n - 1
	out.resize(int((float(n) - t) / step) + 4)
	var k := 0
	var peak := 0.0
	var acc := _g_acc
	var cnt := _g_cnt
	var gate_any := _gate_hold > 0
	while t < float(last):
		var ii := floori(t)
		var a: float = prev
		if ii >= 0:
			var va: Vector2 = fr[ii]
			a = (va.x + va.y) * 0.5
		var vb: Vector2 = fr[ii + 1]
		var o: float = a + ((vb.x + vb.y) * 0.5 - a) * (t - float(ii))
		if k >= out.size():
			out.resize(k + 64)
		out[k] = o
		k += 1
		if o > peak:
			peak = o
		elif -o > peak:
			peak = -o
		acc += o * o
		cnt += 1
		if cnt >= GATE_WIN:
			_gate_eval(sqrt(acc / float(cnt)))
			acc = 0.0
			cnt = 0
			if _gate_hold > 0:
				gate_any = true
		t += step
	out.resize(k)
	var vl: Vector2 = fr[last]
	_rs_prev = (vl.x + vl.y) * 0.5
	_rs_t = t - float(n)
	_g_acc = acc
	_g_cnt = cnt
	_chunk_gate = gate_any
	if peak > 0.001:
		var lvl := clampf((linear_to_db(peak) + 60.0) / 60.0, 0.0, 1.0)
		if lvl > mic_level:
			mic_level = lvl
	return out


func _gate_eval(rms: float) -> void:
	# open mic voice gate, one call per 20 ms window: an adaptive noise floor that falls fast,
	# rises slowly while quiet and only creeps up during speech (a new steady noise such as a fan
	# is learned in about 15 s, a sentence barely moves it)
	var thr := maxf(GATE_MIN, _gate_floor * GATE_RATIO)
	if rms >= thr:
		_gate_hold = GATE_HOLD_WIN
		_gate_floor += (rms - _gate_floor) * 0.0003
	else:
		if _gate_hold > 0:
			_gate_hold -= 1
		var rate := 0.3 if rms < _gate_floor else 0.02
		_gate_floor += (rms - _gate_floor) * rate
	_gate_floor = clampf(_gate_floor, 0.0003, 0.1)


# ---------------------------------------------------------------- IMA ADPCM ("ZVA1")

func _adpcm_encode(s: PackedFloat32Array, rate: int, st: Array, cont: bool) -> PackedByteArray:
	# one self-contained packet; st = [predictor, step index] is carried to the next packet so a
	# stream of packets decodes without a seam, while the header lets any packet decode alone
	var out := PackedByteArray()
	var n := s.size()
	if n == 0:
		return out
	var cnt := n + (n & 1)                  # odd: one extra sample (the last one again)
	out.resize(ADPCM_HDR + (cnt >> 1))
	out[0] = 90                             # "ZVA1"
	out[1] = 86
	out[2] = 65
	out[3] = 49
	out.encode_u16(4, clampi(rate, 0, 65535))
	var pred: int = clampi(int(st[0]), -32768, 32767)
	var idx: int = clampi(int(st[1]), 0, 88)
	if not cont:
		pred = clampi(int(clampf(s[0], -1.0, 1.0) * 32767.0), -32768, 32767)
	out.encode_s16(6, pred)
	out[8] = idx
	out[9] = 0
	var steps := _step_tab
	var itab := _idx_tab
	var o := ADPCM_HDR
	var lo := 0
	var last := n - 1
	for i in cnt:
		var smp := int(clampf(s[mini(i, last)], -1.0, 1.0) * 32767.0)
		var step: int = steps[idx]
		var diff := smp - pred
		var nib := 0
		if diff < 0:
			nib = 8
			diff = -diff
		var vp := step >> 3
		if diff >= step:
			nib |= 4
			diff -= step
			vp += step
		var half := step >> 1
		if diff >= half:
			nib |= 2
			diff -= half
			vp += half
		var quarter := step >> 2
		if diff >= quarter:
			nib |= 1
			vp += quarter
		if (nib & 8) != 0:
			pred -= vp
		else:
			pred += vp
		if pred > 32767:
			pred = 32767
		elif pred < -32768:
			pred = -32768
		idx += itab[nib]
		if idx < 0:
			idx = 0
		elif idx > 88:
			idx = 88
		if (i & 1) == 0:
			lo = nib
		else:
			out[o] = lo | (nib << 4)
			o += 1
	st[0] = pred
	st[1] = idx
	return out


func _adpcm_decode_raw(b: PackedByteArray) -> PackedFloat32Array:
	# samples at the packet's own rate; empty when the packet is malformed
	var none := PackedFloat32Array()
	var size := b.size()
	if size <= ADPCM_HDR or size - ADPCM_HDR > ADPCM_MAX_PAYLOAD:
		return none
	var rate := b.decode_u16(4)
	if rate < 8000 or rate > 48000:
		return none
	var pred := b.decode_s16(6)
	var idx := clampi(b[8], 0, 88)
	var out := PackedFloat32Array()
	out.resize((size - ADPCM_HDR) * 2)
	var steps := _step_tab
	var itab := _idx_tab
	var k := 0
	for o in range(ADPCM_HDR, size):
		var bv := b[o]
		for h in 2:
			var nib := (bv >> 4) if h == 1 else (bv & 15)
			var step: int = steps[idx]
			var vp := step >> 3
			if (nib & 4) != 0:
				vp += step
			if (nib & 2) != 0:
				vp += step >> 1
			if (nib & 1) != 0:
				vp += step >> 2
			if (nib & 8) != 0:
				pred -= vp
			else:
				pred += vp
			if pred > 32767:
				pred = 32767
			elif pred < -32768:
				pred = -32768
			idx += itab[nib]
			if idx < 0:
				idx = 0
			elif idx > 88:
				idx = 88
			out[k] = float(pred) / 32768.0
			k += 1
	return out


static func _resample_linear(src: PackedFloat32Array, from_rate: int, to_rate: int) -> PackedFloat32Array:
	var n := src.size()
	if from_rate == to_rate or n < 2 or from_rate <= 0 or to_rate <= 0:
		return src
	var m := int(round(float(n) * float(to_rate) / float(from_rate)))
	var out := PackedFloat32Array()
	if m < 1:
		return out
	out.resize(m)
	var step := float(n) / float(m)
	var t := 0.0
	var last := n - 1
	for j in m:
		var i := floori(t)
		if i >= last:
			out[j] = src[last]
		else:
			var a := src[i]
			out[j] = a + (src[i + 1] - a) * (t - float(i))
		t += step
	return out


# ---------------------------------------------------------------- decode

# v5.1.3: teammates' voices came through far too quiet (a headset mic picked in the MICROPHONE
# box is recorded raw, with no automatic gain), so every received voice is played 3x louder
# (+9.5 dB) with a soft limiter above 0.7, so loud talkers round off instead of crackling.
const VOICE_BOOST := 3.0
const BOOST_KNEE := 0.7


func decode(bytes: PackedByteArray) -> PackedFloat32Array:
	var pcm := _decode_raw(bytes)
	if pcm.is_empty() or (_test and bytes.size() >= 4 and bytes[0] == 90 and bytes[1] == 86 and bytes[2] == 84 and bytes[3] == 49):
		return pcm                          # the developer test tone stays at its own level
	var room := 1.0 - BOOST_KNEE
	for i in pcm.size():
		var y: float = pcm[i] * VOICE_BOOST
		var a := absf(y)
		if a > BOOST_KNEE:
			y = signf(y) * (BOOST_KNEE + room * tanh((a - BOOST_KNEE) / room))
		pcm[i] = y
	return pcm


func _decode_raw(bytes: PackedByteArray) -> PackedFloat32Array:
	if bytes.size() < 4:
		return PackedFloat32Array()
	# Steam voice starts with the talker's SteamID64, little-endian: its first 4 bytes are the
	# account id and can spell a magic by chance (account 826,365,530 is "ZVA1", 827,610,714 is
	# "ZVT1"). So "ZVT1" is played as raw test audio only while this PC runs the test (the
	# loopback Ghost echoing our own tone); otherwise it goes to Steam's decoder like any other
	# data that is not ours (a friend's test tone is not Steam voice and should come back as an
	# error), which decodes that one account's voice. A "ZVA1" that does not parse (a Steam
	# packet's bytes 4-5 read as rate 1) goes on to Steam's decoder too.
	if _test and bytes[0] == 90 and bytes[1] == 86 and bytes[2] == 84 and bytes[3] == 49:     # "ZVT1"
		return _pcm16_to_float(bytes, 4, bytes.size() - 4)
	if bytes[0] == 90 and bytes[1] == 86 and bytes[2] == 65 and bytes[3] == 49:     # "ZVA1"
		var adp := _adpcm_decode_raw(bytes)
		if not adp.is_empty():
			return _resample_linear(adp, bytes.decode_u16(4), sample_rate)
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


# ---------------------------------------------------------------- developer mic test (synthetic voice)

static func _synth(t: float) -> float:
	# 180 Hz with 3 harmonics under a 4 Hz envelope, 0.6 s bursts every 2 s (20 ms fades).
	# Every part repeats exactly every 2 s, so the caller may wrap t there.
	var ph := fmod(t, 2.0)
	if ph >= 0.6:
		return 0.0
	var fade := minf(1.0, minf(ph / 0.02, (0.6 - ph) / 0.02))
	var env := 0.55 + 0.45 * sin(TAU * 4.0 * t)
	var w := TAU * 180.0 * t
	return 0.3 / 2.08 * fade * env * (sin(w) + 0.5 * sin(2.0 * w) + 0.33 * sin(3.0 * w) + 0.25 * sin(4.0 * w))


func _mic_test_frames(now: int, rate: float) -> PackedVector2Array:
	# what the capture bus would hold: stereo frames at the mix rate since the last pull
	var fr := PackedVector2Array()
	if _mt_last_ms < 0:
		_mt_last_ms = now
		return fr
	var dt := clampf(float(now - _mt_last_ms) / 1000.0, 0.0, 0.2)
	_mt_last_ms = now
	var want := dt * rate + _mt_frac
	var n := int(want)
	_mt_frac = want - float(n)
	if n <= 0:
		return fr
	fr.resize(n)
	var t := _mt_t
	var inv := 1.0 / rate
	for i in n:
		var s := _synth(t + float(i) * inv)
		fr[i] = Vector2(s, s)
	_mt_t = fmod(t + float(n) * inv, 2.0)
	return fr


func _codec_self_test() -> void:
	# 1 s of the synthetic voice at 16 kHz, encoded in 40 ms packets exactly like the live path,
	# each packet decoded on its own
	var n := MOD_RATE
	var src := PackedFloat32Array()
	src.resize(n)
	for i in n:
		src[i] = _synth(float(i) / float(MOD_RATE))
	var st: Array = [0, 0]
	var cont := false
	var total := 0
	var dec := PackedFloat32Array()
	var chunk := 640
	var p := 0
	while p < n:
		var part := src.slice(p, mini(p + chunk, n))
		var pkt := _adpcm_encode(part, MOD_RATE, st, cont)
		cont = true
		total += pkt.size()
		dec.append_array(_adpcm_decode_raw(pkt))
		p += chunk
	var sig := 0.0
	var err := 0.0
	var m := mini(n, dec.size())
	for i in m:
		var d := src[i] - dec[i]
		sig += src[i] * src[i]
		err += d * d
	var snr := 10.0 * log(sig / maxf(err, 1e-12)) / log(10.0)
	print("[CoopSync] voice codec self-test: SNR %.1f dB, %d bytes/s" % [snr, total])


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
