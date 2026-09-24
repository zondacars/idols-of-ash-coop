extends Node
# ============================================================================
# soundscape.gd : THE UNDERDARK cave soundscape (ZondaCoopSync v4.9, interface K3)
#
# API for the integrators:
#   const CAVE_BUS := "ZondaCave"
#       Audio bus this module creates (if missing) with an AudioEffectReverb (slot 0)
#       and an AudioEffectLowPassFilter (slot 1). It sends to "MainBus" (the bus the
#       game's volume slider controls) and falls back to "Master" if MainBus is absent.
#       Creature / ambience / voice players may set  player.bus = &"ZondaCave"
#       after checking AudioServer.get_bus_index("ZondaCave") != -1.
#   setup(map: Node3D) -> void
#       Call AFTER add_child(soundscape). Loads maps/underdark/sfx/manifest.json
#       (missing file or entries = that layer stays silent, never an error), builds
#       the bus, the rift-wind layer, the heartbeat and a pool of 3D one-shot players.
#   set_biome(b: int) -> void          (0-9; same index as the map's biome order)
#       Crossfades to that biome's ambience bed over 3 s and retunes the cave reverb.
#       Cheap to call every frame: it does nothing when b is unchanged.
#   set_open(open: bool) -> void
#       true  = player is in the open rift (huge, long, cold echo + rift wind up)
#       false = tunnel / chamber (tight, drier echo, wind down to a faint draught).
#       Cheap to call every frame.
#   set_threat(dist_m: float) -> void
#       Distance to the nearest awake threat. Heartbeat (game's own heartbeat sample)
#       starts at 18 m and gets faster and louder as it closes in. 1e9 = none.
#       Cheap to call every frame.
#   play_oneshot(kind: String, pos: Vector3) -> void
#       Plays a random manifest "oneshots"[kind] sound at a world position through the
#       cave bus, muffled if rock is between the camera and pos (one occlusion test).
#       Kinds: drip, rockfall, chain_creak, oil_pickup, spider_click, brood_skitter.
#   static occlusion(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> float
#       0 = clear line, 0.5 = grazing (only the raised ray gets through), 1 = blocked by
#       rock on collision layer 1. At most 2 rays.
#
# Also on its own: random positional drips / distant rockfalls / chain creaks around the
# listener every 8-25 s, chosen per biome from what the manifest provides.
# No particles, no per-frame raycasts. On _exit_tree the cave bus is reset to a mild,
# neutral cave so voices on other levels do not keep the last biome's echo.
# ============================================================================

const CAVE_BUS := "ZondaCave"
const SFX_DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/sfx/"
const MANIFEST_PATH := "res://mods-unpacked/zonda-CoopSync/maps/underdark/sfx/manifest.json"
const HEART_SINGLE := "res://sfx/soundsnap/131374-Human-Heartbeat-Single-Fienup-005.wav"
const WIND_FALLBACK := "res://sfx/soundsnap/249565-Heavy_Wind_Ambience_2.wav"

const BED_FADE := 3.0            # seconds for a full bed crossfade
const WIND_FADE := 2.0
const THREAT_RANGE := 18.0
const POOL_SIZE := 6

# Per-biome reverb in a tunnel/chamber:
# [room_size, damping, spread, wet, predelay_ms, lowpass_hz, hipass]
const REVERB := [
	[0.55, 0.35, 0.8, 0.20, 45.0, 12000.0, 0.10],   # 0 THE MOUTH: cold stone
	[0.50, 0.25, 0.7, 0.24, 40.0, 11000.0, 0.10],   # 1 OSSUARY: hard, bony ring
	[0.40, 0.75, 0.6, 0.16, 30.0, 7000.0, 0.00],    # 2 FUNGAL HOLLOW: soft, spongy
	[0.42, 0.62, 0.6, 0.17, 32.0, 8000.0, 0.00],    # 3 ROOTWORKS: woody, muffled
	[0.62, 0.08, 1.0, 0.32, 55.0, 13000.0, 0.25],   # 4 DROWNED GALLERIES: wet, ringing
	[0.50, 0.40, 0.8, 0.22, 40.0, 10000.0, 0.10],   # 5 SUNKEN VILLAGE
	[0.66, 0.05, 1.0, 0.30, 50.0, 16000.0, 0.30],   # 6 CRYSTAL VEINS: bright, glassy
	[0.45, 0.90, 0.5, 0.15, 30.0, 4500.0, 0.00],    # 7 THE FOUNDRY: dull, hot
	[0.52, 0.55, 0.7, 0.22, 40.0, 7500.0, 0.05],    # 8 THE NEST: organic, close
	[0.24, 0.72, 0.4, 0.10, 20.0, 8000.0, 0.00],    # 9 THE BURROWS: tight, dry
]
# How much rift wind each biome gets (the Foundry and Burrows are sheltered).
const WIND_K := [1.0, 0.85, 0.6, 0.65, 0.7, 0.7, 0.8, 0.5, 0.6, 0.3]
# Ambient one-shot mix per biome: kind -> weight (only kinds present in the manifest play).
const AMB := [
	{"rockfall": 1.0, "drip": 0.3},
	{"drip": 0.6, "rockfall": 0.8},
	{"drip": 1.0, "rockfall": 0.3},
	{"drip": 0.8, "rockfall": 0.5},
	{"drip": 1.6, "rockfall": 0.3},
	{"drip": 0.8, "chain_creak": 1.0, "rockfall": 0.3},
	{"drip": 0.6, "rockfall": 0.6},
	{"rockfall": 1.0, "chain_creak": 0.7},
	{"drip": 0.5, "rockfall": 0.6},
	{"drip": 0.4, "rockfall": 0.8},
]

var map: Node3D = null
var manifest: Dictionary = {}
var biome := -1
var is_open := true
var threat_dist := 1e9

var _streams: Dictionary = {}     # path -> AudioStream (null when it failed)
var _beds: Array = []             # each: {"players": Array, "vols": Array, "gain": float, "target": float}
var _wind_players: Array = []
var _wind_vols: Array = []
var _wind_gain := 0.0
var _pool: Array = []
var _pool_i := 0
var _amb_timer := 10.0
var _hearts: Array = []
var _heart_i := 0
var _heart_k := 0.0
var _heart_t := 0.0
var _rev: AudioEffectReverb = null
var _lp: AudioEffectLowPassFilter = null
var _rev_cur: Array = []
var _rev_want: Array = []
var _rev_tick := 0.0
var _ready_done := false


# ------------------------------------------------------------------ setup

func setup(m: Node3D) -> void:
	map = m
	manifest = {}
	if FileAccess.file_exists(MANIFEST_PATH):
		var txt := FileAccess.get_file_as_string(MANIFEST_PATH)
		var parsed = JSON.parse_string(txt)
		if parsed is Dictionary:
			manifest = parsed
		else:
			push_warning("soundscape: sfx manifest is not valid JSON")
	_ensure_bus()
	_rev_want = _profile(0, true)
	_rev_cur = _rev_want.duplicate()
	_apply_reverb(_rev_cur)
	# rift wind layer (stays at silence until _process fades it in)
	var winds: Array = []
	var w = manifest.get("rift_wind", [])
	if w is Array and w.size() > 0:
		winds = w
	else:
		winds = [{"file": WIND_FALLBACK, "db": -18.0}]
	for e in winds:
		if not (e is Dictionary):
			continue
		var st := _stream(str(e.get("file", "")), true)
		if st == null:
			continue
		var p := _make_loop_player(st)
		_wind_players.append(p)
		_wind_vols.append(db_to_linear(float(e.get("db", -12.0))))
	# heartbeat: two alternating players so fast beats never cut each other off
	var hb := _stream(HEART_SINGLE, false)
	if hb != null:
		for i in 2:
			var h := AudioStreamPlayer.new()
			h.stream = hb
			h.bus = _dry_bus()
			h.volume_db = -80.0
			add_child(h)
			_hearts.append(h)
	# pool of positional one-shot players
	for i in POOL_SIZE:
		var q := AudioStreamPlayer3D.new()
		q.bus = CAVE_BUS
		q.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		q.max_distance = 60.0
		q.unit_size = 5.0
		q.attenuation_filter_db = -18.0
		add_child(q)
		_pool.append(q)
	_amb_timer = randf_range(6.0, 12.0)
	_ready_done = true


static func _ensure_bus_static() -> int:
	var idx := AudioServer.get_bus_index(CAVE_BUS)
	if idx == -1:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, CAVE_BUS)
	var send := "Master"
	if AudioServer.get_bus_index("MainBus") != -1:
		send = "MainBus"
	AudioServer.set_bus_send(idx, send)
	return idx


func _ensure_bus() -> void:
	var idx := _ensure_bus_static()
	_rev = null
	_lp = null
	for i in AudioServer.get_bus_effect_count(idx):
		var e := AudioServer.get_bus_effect(idx, i)
		if e is AudioEffectReverb and _rev == null:
			_rev = e as AudioEffectReverb
		elif e is AudioEffectLowPassFilter and _lp == null:
			_lp = e as AudioEffectLowPassFilter
	if _rev == null:
		_rev = AudioEffectReverb.new()
		AudioServer.add_bus_effect(idx, _rev)
	if _lp == null:
		_lp = AudioEffectLowPassFilter.new()
		AudioServer.add_bus_effect(idx, _lp)
	_rev.dry = 1.0
	_rev.predelay_feedback = 0.35
	_lp.resonance = 0.5
	for i in AudioServer.get_bus_effect_count(idx):
		AudioServer.set_bus_effect_enabled(idx, i, true)


func _dry_bus() -> String:
	if AudioServer.get_bus_index("MainBus") != -1:
		return "MainBus"
	return "Master"


# ------------------------------------------------------------------ public API

func set_biome(b: int) -> void:
	if b == biome or b < 0 or b >= REVERB.size():
		return
	biome = b
	_rev_want = _profile(biome, is_open)
	# fade every other bed out, bring this one in. A bed of this biome that is still fading out
	# comes back instead of a second copy: standing on a zone edge can flip the biome every frame,
	# which must never stack up players.
	var have := false
	for bed in _beds:
		if int(bed.get("biome", -1)) == b:
			bed["target"] = 1.0
			have = true
		else:
			bed["target"] = 0.0
	if have:
		return
	var beds = manifest.get("beds", {})
	if not (beds is Dictionary):
		return
	var list = beds.get(str(b), [])
	if not (list is Array) or list.is_empty():
		return
	var players: Array = []
	var vols: Array = []
	for e in list:
		if not (e is Dictionary):
			continue
		var st := _stream(str(e.get("file", "")), true)
		if st == null:
			continue
		players.append(_make_loop_player(st))
		vols.append(db_to_linear(float(e.get("db", -12.0))))
	if players.is_empty():
		return
	_beds.append({"players": players, "vols": vols, "gain": 0.0, "target": 1.0, "biome": b})


func set_open(open: bool) -> void:
	if open == is_open:
		return
	is_open = open
	_rev_want = _profile(maxi(biome, 0), is_open)


func set_threat(dist_m: float) -> void:
	threat_dist = dist_m


func play_oneshot(kind: String, pos: Vector3) -> void:
	if _pool.is_empty():
		return
	var shots = manifest.get("oneshots", {})
	if not (shots is Dictionary):
		return
	var list = shots.get(kind, [])
	if not (list is Array) or list.is_empty():
		return
	var e = list[randi() % list.size()]
	if not (e is Dictionary):
		return
	var st := _stream(str(e.get("file", "")), false)
	if st == null:
		return
	var q: AudioStreamPlayer3D = _pool[_pool_i]
	_pool_i = (_pool_i + 1) % _pool.size()
	if not q.is_inside_tree():
		return
	var far := kind == "rockfall"
	q.stop()
	q.stream = st
	q.max_distance = 110.0 if far else 55.0
	q.unit_size = 9.0 if far else 4.0
	q.pitch_scale = randf_range(0.92, 1.06)
	q.global_position = pos
	var occ := 0.0
	var lis := _listener()
	if lis.is_finite() and is_instance_valid(map) and map.is_inside_tree():
		var w3 := map.get_world_3d()
		if w3 != null:
			occ = occlusion(w3.direct_space_state, lis, pos)
	q.volume_db = float(e.get("db", -6.0)) - 6.0 * occ
	q.attenuation_filter_cutoff_hz = lerpf(20000.0, 1100.0, occ)
	q.play()


static func occlusion(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3) -> float:
	if space == null:
		return 0.0
	var d := to - from
	var ln := d.length()
	if ln < 0.6:
		return 0.0
	# stop half a metre short so the source's own floor or wall does not count
	var end := from + d * ((ln - 0.5) / ln)
	var q := PhysicsRayQueryParameters3D.create(from, end, 1)
	if space.intersect_ray(q).is_empty():
		return 0.0
	# second ray a little higher: a ledge lip or a low rock only half-blocks
	var up := Vector3(0, 0.7, 0)
	var q2 := PhysicsRayQueryParameters3D.create(from + up, end + up, 1)
	if space.intersect_ray(q2).is_empty():
		return 0.5
	return 1.0


# ------------------------------------------------------------------ internals

func _profile(b: int, open: bool) -> Array:
	var r: Array = REVERB[clampi(b, 0, REVERB.size() - 1)]
	var room: float = r[0]
	var damp: float = r[1]
	var spread: float = r[2]
	var wet: float = r[3]
	var pre: float = r[4]
	var lp: float = r[5]
	var hp: float = r[6]
	if open:
		# the rift: huge, long, cold, with a late slap-back from the far wall
		room = lerpf(room, 0.97, 0.75)
		damp = damp * 0.6
		spread = 1.0
		wet = minf(wet + 0.14, 0.5)
		pre = clampf(pre * 3.0, 90.0, 260.0)
		lp = minf(lp * 1.2, 18000.0)
	else:
		# tunnel or chamber: tight and drier
		room = room * 0.75
		damp = minf(damp + 0.12, 1.0)
		wet = wet * 0.75
		pre = maxf(pre * 0.6, 20.0)
	return [room, damp, spread, wet, pre, lp, hp]


func _apply_reverb(v: Array) -> void:
	if _rev == null or _lp == null or v.size() < 7:
		return
	_rev.room_size = clampf(float(v[0]), 0.0, 1.0)
	_rev.damping = clampf(float(v[1]), 0.0, 1.0)
	_rev.spread = clampf(float(v[2]), 0.0, 1.0)
	_rev.wet = clampf(float(v[3]), 0.0, 1.0)
	_rev.predelay_msec = clampf(float(v[4]), 20.0, 500.0)
	_lp.cutoff_hz = clampf(float(v[5]), 200.0, 20500.0)
	_rev.hipass = clampf(float(v[6]), 0.0, 1.0)


func _stream(path: String, loop: bool) -> AudioStream:
	if path == "":
		return null
	var full := path
	if not path.begins_with("res://"):
		full = SFX_DIR + path
	var key := full + ("#L" if loop else "")
	if _streams.has(key):
		return _streams[key]
	var st: AudioStream = null
	if full.begins_with("res://mods-unpacked/"):
		# never imported by the editor: build the stream from the raw bytes
		if FileAccess.file_exists(full):
			var bytes := FileAccess.get_file_as_bytes(full)
			var ext := full.get_extension().to_lower()
			if bytes.size() > 0:
				if ext == "ogg":
					var ogg := AudioStreamOggVorbis.load_from_buffer(bytes)
					if ogg != null:
						ogg.loop = loop
						st = ogg
				elif ext == "mp3":
					var mp3 := AudioStreamMP3.new()
					mp3.data = bytes
					mp3.loop = loop
					st = mp3
				elif ext == "wav":
					st = AudioStreamWAV.load_from_buffer(bytes)
	elif ResourceLoader.exists(full):
		st = load(full) as AudioStream
	if st == null:
		push_warning("soundscape: could not load " + full)
	_streams[key] = st
	return st


func _make_loop_player(st: AudioStream) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = st
	p.bus = CAVE_BUS
	p.volume_db = -80.0
	# game .wav files do not loop by themselves: restart on finish
	var restart := func():
		if is_instance_valid(p) and p.is_inside_tree() and p.volume_db > -70.0:
			p.play()
	p.finished.connect(restart)
	add_child(p)
	return p


func _start_loop(p: AudioStreamPlayer) -> void:
	if p.playing or not p.is_inside_tree() or p.stream == null:
		return
	var ln := p.stream.get_length()
	var at := 0.0
	if ln > 2.0:
		at = randf() * ln * 0.8
	p.play(at)


func _set_loop_vol(p: AudioStreamPlayer, lin: float) -> void:
	if lin < 0.003:
		p.volume_db = -80.0
		if p.playing:
			p.stop()
		return
	p.volume_db = linear_to_db(lin)
	_start_loop(p)


func _listener() -> Vector3:
	var vp := get_viewport()
	if vp != null:
		var cam := vp.get_camera_3d()
		if cam != null and cam.is_inside_tree():
			return cam.global_position
	if is_instance_valid(Game.climber) and Game.climber.is_inside_tree():
		return Game.climber.global_position
	return Vector3(INF, INF, INF)


func _process(delta: float) -> void:
	if not _ready_done:
		return
	# --- beds: crossfade
	var i := _beds.size() - 1
	while i >= 0:
		var bed: Dictionary = _beds[i]
		var g: float = bed["gain"]
		var t: float = bed["target"]
		g = move_toward(g, t, delta / BED_FADE)
		bed["gain"] = g
		var players: Array = bed["players"]
		var vols: Array = bed["vols"]
		# equal-power curve so the crossfade does not dip in the middle
		var eg := sin(g * PI * 0.5)
		for j in players.size():
			var p: AudioStreamPlayer = players[j]
			if is_instance_valid(p):
				_set_loop_vol(p, float(vols[j]) * eg)
		if g <= 0.0 and t <= 0.0:
			for p in players:
				if is_instance_valid(p):
					p.queue_free()
			_beds.remove_at(i)
		i -= 1
	# --- rift wind
	var wk: float = WIND_K[clampi(biome, 0, WIND_K.size() - 1)]
	var wt := wk if is_open else wk * 0.12
	_wind_gain = move_toward(_wind_gain, wt, delta / WIND_FADE)
	for j in _wind_players.size():
		var wp: AudioStreamPlayer = _wind_players[j]
		if is_instance_valid(wp):
			_set_loop_vol(wp, float(_wind_vols[j]) * _wind_gain)
	# --- reverb glides toward the wanted profile (10 Hz, stops when settled)
	_rev_tick -= delta
	if _rev_tick <= 0.0 and _rev_want.size() == 7 and _rev_cur.size() == 7:
		_rev_tick = 0.1
		var moved := false
		for k in 7:
			var a: float = _rev_cur[k]
			var b: float = _rev_want[k]
			if absf(a - b) > 0.0005 * maxf(1.0, absf(b)):
				_rev_cur[k] = lerpf(a, b, 0.2)
				moved = true
		if moved:
			_apply_reverb(_rev_cur)
	# --- heartbeat
	var want := 0.0
	if threat_dist < THREAT_RANGE:
		want = clampf(1.0 - threat_dist / THREAT_RANGE, 0.0, 1.0)
	_heart_k = move_toward(_heart_k, want, delta * (0.9 if want > _heart_k else 0.35))
	if _heart_k > 0.02 and not _hearts.is_empty():
		_heart_t -= delta
		if _heart_t <= 0.0:
			var kk := pow(_heart_k, 0.8)
			_heart_t = lerpf(1.25, 0.36, kk)
			var h: AudioStreamPlayer = _hearts[_heart_i]
			_heart_i = (_heart_i + 1) % _hearts.size()
			if h.is_inside_tree():
				h.volume_db = lerpf(-26.0, -4.0, kk)
				h.pitch_scale = 0.95 + 0.1 * kk
				h.play()
	else:
		_heart_t = minf(_heart_t, 0.25)
	# --- ambient one-shots around the listener
	_amb_timer -= delta
	if _amb_timer <= 0.0:
		_amb_timer = randf_range(8.0, 25.0)
		_ambient_oneshot()


func _ambient_oneshot() -> void:
	if biome < 0:
		return
	var lis := _listener()
	if not lis.is_finite():
		return
	var shots = manifest.get("oneshots", {})
	if not (shots is Dictionary):
		return
	var mix: Dictionary = AMB[clampi(biome, 0, AMB.size() - 1)]
	var kinds: Array = []
	var weights: Array = []
	var total := 0.0
	for k in mix:
		var l = shots.get(k, [])
		if l is Array and not l.is_empty():
			kinds.append(k)
			weights.append(float(mix[k]))
			total += float(mix[k])
	if kinds.is_empty() or total <= 0.0:
		return
	var r := randf() * total
	var kind: String = kinds[kinds.size() - 1]
	for j in kinds.size():
		r -= float(weights[j])
		if r <= 0.0:
			kind = kinds[j]
			break
	var ang := randf() * TAU
	var dist := randf_range(6.0, 22.0)
	var dy := randf_range(2.0, 12.0)
	if kind == "rockfall":
		dist = randf_range(25.0, 60.0)
		dy = randf_range(-20.0, 20.0)
	elif kind == "chain_creak":
		dist = randf_range(10.0, 35.0)
		dy = randf_range(-4.0, 10.0)
	var pos := lis + Vector3(cos(ang) * dist, dy, sin(ang) * dist)
	play_oneshot(kind, pos)


func _exit_tree() -> void:
	# leave a mild, neutral cave on the bus for voices on other levels
	if _rev != null:
		_rev.room_size = 0.45
		_rev.damping = 0.5
		_rev.spread = 0.8
		_rev.wet = 0.12
		_rev.predelay_msec = 30.0
		_rev.hipass = 0.1
	if _lp != null:
		_lp.cutoff_hz = 20000.0
