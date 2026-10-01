extends Node
# ============================================================================================
# THE UNDERDARK: the LightField (ZondaCoopSync v5.0, feature module "light", owner B4)
#
# One helper that answers "is this point lit, and by what?" for every light-fear creature (pale
# centipedes, wall spiders, Shades) and every feature that needs it. Players never see it.
# Only REAL light counts: player lanterns (beam and glow) and flames from map DATA (fires, bell
# lamps, torches, lit kilns, dying-light torches, the altar light, warm L.lights lamps) plus
# dynamic flames other modules add. Never: biome glows and fills, the NORMAL ambient, oil flasks,
# the idol glow, the hearth lure. Flames come from layout data plus replicated state flags
# (fire_nodes[i].lit, Kiln.lit, DyingLights state, _idol_taken), NEVER from a light node's
# visible / energy (each machine's 64-light budget switches those by its own camera), so host,
# guests and a new authority all get the same answer.
#
# The map loads it first (FEATURES order) with setup(map) before add_child; it sets
# CoopSync.light_field = self and ticks with process_priority -10 (before the creatures).
#
# API (key = the caller's id, e.g. get_instance_id(), for the ray cache; radius = target size):
#   light_at(p, key = 0, radius = 0.3) -> {"k": float, "src": "beam"|"glow"|"flame"|"",
#            "peer": sid String, "node": Node3D, "from": Vector3, "dir": Vector3 (beams)}
#   beam_at(p, key = 0, radius = 0.3) -> {"k", "peer", "node", "eye": Vector3, "dir": Vector3}
#   is_lit(p, key = 0) -> bool               light_at(p).k >= 0.2
#   player_lit(node) -> bool                 that player's own lantern is on and not dry (no ray)
#   player_dark_ms(node) -> int              ms since player_lit went false (0 while lit)
#   player_dry(node) -> bool
#   player_dry_ms(node) -> int               ms since that lantern ran dry (0 if not dry)
#   most_oil_holder() -> Node3D              the living player with the most oil (lit or not)
#   away_from_light(p) -> Vector3            flat unit vector out of the light at p (ZERO if unlit):
#                                            perpendicular out of a beam axis, radial for glow/flames
#   facing_of(node) -> Vector3               that player's flat view direction (ZERO if unknown)
#   local_lit(p) -> bool                     guests: own lantern + flames, 1 cached ray (display only)
#   oil_factor(oil) -> float                 1.0 at >= 0.15, else lerp(0.35, 1.0, oil / 0.15)
#   add_flame(pos, r, alive: Callable = Callable()) -> int   a dynamic flame; alive.call() -> bool
#   remove_flame(id)
#   static_k(p) -> float                     best STATIC flame k at p from map data: no rays, no
#                                            lanterns, no dynamic flames (Shade homes)
#   stats() -> {"rays", "rays_last", "rays_now", "rays_total", "misses", "lanterns", "flames"}
#   reset_stats()
#   census() -> String                       "fires 49, bells 2, ... ; lanterns 1"
# Tuning: beam range 22 m x oil factor, full to 0.6 of it then linear to 0; core half-angle 12
# deg (k 1) fading to 26 deg (k 0), the target's size taken off the angle; glow 6 m x oil factor,
# k = 1 - d / r, no ray inside 1.5 m; flames k = 1 - d / r. LIT at k >= 0.2. A mask-1 ray from
# the source is clear when it hits nothing or hits within 0.9 m of the point. Lantern rays are
# cached 0.25 s per (source, key), flame rays 3 s per (flame, 2 m cell). At most 28 rays per
# update (one 10 Hz tick); over budget counts as clear (player-favoured) and as a miss. Local
# lantern: Game.climber's Camera, CoopSync.lantern_on, CoopSync.lantern.oil. Remote lanterns
# (authority only): CoopSync.remote_players() with lantern_lit, eye_position(), cam pitch / yaw,
# oil_pct. A red (idol) lantern counts like any lantern.
#
# Light hint (authority, 1 Hz): a pale centipede with a target within 80 m of a player, once per
# biome per load and at most every 240 s, sends the non-persistent "lfhint_<biome>" {id: sid of
# most_oil_holder or "", by} (logs "[PALE] hint -> <id>"); every machine shows its own line.
#
# Dev test: maps/underdark/lightfear.flag ("" = phases 0-3, "0".."3" = one phase). 0 LightField,
# 1 Shades (shades.gd run_test_phase), 2 pale centipede, 3 wall spider. Ends with one line
# "[LIGHT] test done P/N PASS" (or "... FAIL: <names>").
# ============================================================================================

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const SHY_PATH := "res://mods-unpacked/zonda-CoopSync/ext/state_shy.gd"
const HUNT_PATH := "res://mods-unpacked/zonda-CoopSync/ext/state_hunting.gd"
const LIT_K := 0.2
const BEAM_RANGE := 22.0
const BEAM_FULL := 0.6
const BEAM_CORE_DEG := 12.0
const BEAM_EDGE_DEG := 26.0
const GLOW_R := 6.0
const NEAR_NO_RAY := 1.5
const OIL_LOW := 0.15
const RAY_BUDGET := 28
const UPDATE_MS := 100
const CELL := 32.0
const LANTERN_CACHE_MS := 250
const FLAME_CACHE_MS := 3000
const CLEAR_NEAR := 0.9
const HINT_R := 80.0
const HINT_GAP_MS := 240000
const MAX_FLAME_R := 32.0

var map: Node3D = null

# flames: id -> {"id", "pos", "r", "kind", "dyn", "ref", "i", "alive": Callable, "cell": Vector3i}
var _flames: Dictionary = {}
var _cells: Dictionary = {}          # Vector3i -> Array of flame ids
var _next_flame := 1

# lanterns, rebuilt at 10 Hz (the local one's pose every frame)
var _lanterns: Array = []
var _local_ln: Dictionary = {}
var _upd_ms := -100000
var _local_frame := -1

# rays
var _rays := 0                       # this update
var _rays_last := 0
var _rays_max := 0
var _ray_total := 0
var _misses := 0
var _cache: Dictionary = {}          # String -> [ms, clear]

# per player: instance id -> {"lit", "dark_ms", "dry", "dry_ms"}
var _pstate: Dictionary = {}

# the light hint
var _hint_t := 1.0
var _hint_biomes: Dictionary = {}
var _hint_next_ms := 0
var _hint_sent := 0
var _hint_seen := 0
var _routed := false                 # the map routes "lfhint_" to _on_event

# guest simulation (2.11): hiss probes stand in for the pale puppets
var _probes: Dictionary = {}
var _probe_t := 0.0
var _pale_cids: Array = []

# the dev test
var _t_on := false
var _t_phases: Array = []
var _t_pi := -1
var _t_phase := -1
var _ts := 0
var _tt := 0.0
var _t_pass := 0
var _t_total := 0
var _t_fails: Array = []
var _t_wait := 0.0
var _t_user = null
var _t_oil = null
var _t_ppd = null
var _t_d: Dictionary = {}


func _init() -> void:
	process_priority = -10
	process_physics_priority = -10


# ================================================================== module protocol

func setup(m: Node3D) -> void:
	map = m
	_build_flames()
	_collect_pale_cids()
	CoopSync.set("light_field", self)
	if map != null and map.has_method("register_events"):
		map.call("register_events", ["lfhint_"], Callable(self, "_on_event"), true)
		_routed = true
	print("[LIGHT] LightField ready: %s" % census())
	var fl = _dev_flag("lightfear.flag")
	if fl != null:
		_test_begin(str(fl).strip_edges())


func on_exit() -> void:
	_test_restore()
	if CoopSync.get("light_field") == self:
		CoopSync.set("light_field", null)


func _exit_tree() -> void:
	on_exit()


func _process(delta: float) -> void:
	if map == null or not is_instance_valid(map):
		return
	_refresh()
	_hint_tick(delta)
	_probe_tick(delta)
	if _t_on:
		_test_tick(delta)


# ================================================================== flames (map data)

func _v(a) -> Vector3:
	if a is Vector3:
		return a
	if (a is Array or a is PackedFloat32Array or a is PackedFloat64Array) and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO


func _cell_of(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / CELL), floori(p.y / CELL), floori(p.z / CELL))


func _add(kind: String, pos: Vector3, r: float, dyn: bool, ref, i: int, alive: Callable) -> int:
	var id := _next_flame
	_next_flame += 1
	var c := _cell_of(pos)
	_flames[id] = {"id": id, "pos": pos, "r": clampf(r, 0.1, MAX_FLAME_R), "kind": kind, "dyn": dyn, "ref": ref, "i": i, "alive": alive, "cell": c}
	if not _cells.has(c):
		_cells[c] = []
	(_cells[c] as Array).append(id)
	return id


func _build_flames() -> void:
	var L = map.get("L") if map != null else null
	if not (L is Dictionary):
		push_warning("[LIGHT] the map has no layout: no flames")
		return
	var ld: Dictionary = L
	# the camp fires: the map's fire_nodes entries (their "lit" flag is replicated state), else
	# the layout's fires, always lit
	var fns = map.get("fire_nodes")
	if fns is Array and not (fns as Array).is_empty():
		for e in fns:
			if e is Dictionary:
				var s := float((e as Dictionary).get("s", 1.0))
				_add("fire", _v((e as Dictionary).get("pos")), clampf(6.5 * s, 1.2, 7.0), false, e, 0, Callable())
	else:
		if map.get("fire_nodes") == null:
			push_warning("[LIGHT] map.fire_nodes missing: fires from layout data, always lit")
		for f in ld.get("fires", []):
			if f is Dictionary:
				_add("fire", _v(f.get("pos")), clampf(6.5 * float(f.get("scale", 1.0)), 1.2, 7.0), false, null, 0, Callable())
	for b in ld.get("bells", []):
		if b is Dictionary:
			_add("bell", _v(b.get("pos")), 7.0, false, null, 0, Callable())
	for p in ld.get("props", []):
		if p is Dictionary and str(p.get("scene", "")).contains("Torch"):
			_add("torch", _v(p.get("pos")) + Vector3.UP * 1.0, 5.0, false, null, 0, Callable())
	var kilns = map.get("_kilns")
	for k in ld.get("kilns", []):
		if k is Dictionary:
			var node = null
			if kilns is Dictionary:
				node = (kilns as Dictionary).get(int(k.get("idx", -1)))
			_add("kiln", _v(k.get("pos")) + Vector3.UP * 1.0, 8.0, false, node, 0, Callable())
	var dying = map.get("_dying")
	for d in ld.get("dying_lights", []):
		if d is Dictionary:
			var node2 = null
			if dying is Dictionary:
				node2 = (dying as Dictionary).get(str(d.get("id", "")))
			var i := 0
			for lp in d.get("lights", []):
				_add("dying", _v(lp), 7.0, false, node2, i, Callable())
				i += 1
	var altars: Array = ld.get("altar", [])
	if not altars.is_empty() and altars[0] is Dictionary:
		_add("altar", _v(altars[0].get("pos")) + Vector3.UP * 3.5, 8.0, false, null, 0, Callable())
	for l in ld.get("lights", []):
		if not (l is Dictionary):
			continue
		var warm := false
		if (l as Dictionary).has("kind"):
			warm = str(l.get("kind", "")) == "lamp"          # wave 2 tags every light
		else:
			var c: Array = l.get("color", [0, 0, 0])
			var cr := float(c[0]) if c.size() > 0 else 0.0
			var cg := float(c[1]) if c.size() > 1 else 0.0
			var cb := float(c[2]) if c.size() > 2 else 0.0
			warm = cr >= 0.95 and cg >= 0.4 and cg <= 0.8 and cb <= 0.45 and float(l.get("range", 99.0)) <= 26.0
		if warm:
			_add("lamp", _v(l.get("pos")), 0.5 * float(l.get("range", 0.0)), false, null, 0, Callable())


func _alive(f: Dictionary) -> bool:
	var kind: String = f["kind"]
	if bool(f["dyn"]):
		var cb: Callable = f["alive"]
		if cb.is_null():
			return true
		if not cb.is_valid():
			return false
		return bool(cb.call())
	if kind == "fire":
		var e = f["ref"]
		return not (e is Dictionary) or bool((e as Dictionary).get("lit", true))
	if kind == "kiln":
		var kn = f["ref"]
		return kn != null and is_instance_valid(kn) and bool(kn.get("lit"))
	if kind == "dying":
		var dn = f["ref"]
		if dn == null or not is_instance_valid(dn):
			return false
		# the DyingLights node's own state: not begun, or this torch has not gone out yet
		return not bool(dn.get("started")) or int(f["i"]) >= int(dn.get("next"))
	if kind == "altar":
		return map != null and is_instance_valid(map) and not bool(map.get("_idol_taken"))
	return true


func _flames_near(p: Vector3, include_dyn: bool = true) -> Array:
	var out: Array = []
	var c := _cell_of(p)
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				var cc := Vector3i(c.x + dx, c.y + dy, c.z + dz)
				if not _cells.has(cc):
					continue
				for id in _cells[cc]:
					var f = _flames.get(id)
					if f == null:
						continue
					if not include_dyn and bool(f["dyn"]):
						continue
					if (f["pos"] as Vector3).distance_to(p) >= float(f["r"]):
						continue
					if _alive(f):
						out.append(f)
	return out


func _flame_k(f: Dictionary, p: Vector3) -> float:
	return maxf(0.0, 1.0 - (f["pos"] as Vector3).distance_to(p) / float(f["r"]))


func add_flame(pos: Vector3, r: float, alive: Callable = Callable()) -> int:
	return _add("dyn", pos, r, true, null, 0, alive)


func remove_flame(id: int) -> void:
	var f = _flames.get(id)
	if f == null:
		return
	_flames.erase(id)
	var c: Vector3i = f["cell"]
	if _cells.has(c):
		(_cells[c] as Array).erase(id)


func static_k(p: Vector3) -> float:
	var best := 0.0
	for f in _flames_near(p, false):
		best = maxf(best, _flame_k(f, p))
	return best


func census() -> String:
	var n := {"fire": 0, "bell": 0, "torch": 0, "lamp": 0, "kiln": 0, "dying": 0, "altar": 0, "dyn": 0}
	var kilns_lit := 0
	var dying_burning := 0
	for f in _flames.values():
		var k: String = f["kind"]
		n[k] = int(n.get(k, 0)) + 1
		if k == "kiln" and _alive(f):
			kilns_lit += 1
		elif k == "dying" and _alive(f):
			dying_burning += 1
	return "fires %d, bells %d, torches %d, lamps %d, kilns %d (%d lit), dying %d (%d burning), altar %d; lanterns %d" % [
		n["fire"], n["bell"], n["torch"], n["lamp"], n["kiln"], kilns_lit, n["dying"], dying_burning, n["altar"], _lanterns.size()]


# ================================================================== lanterns

func oil_factor(oil: float) -> float:
	# mirrors lantern.gd _oil_factor without its random dips
	if oil >= OIL_LOW:
		return 1.0
	return lerpf(0.35, 1.0, clampf(oil / OIL_LOW, 0.0, 1.0))


func _my_sid() -> String:
	if CoopSync.has_method("my_sid"):
		return str(CoopSync.call("my_sid"))
	var id := int(CoopSync.my_id())
	return str(id) if id != 0 else "local"


func _is_me(s: String) -> bool:
	if s == "":
		return false
	if CoopSync.has_method("is_me"):
		return bool(CoopSync.call("is_me", s))
	return s == _my_sid()


func _local_entry() -> Dictionary:
	var c = Game.climber
	if not is_instance_valid(c) or not (c as Node).is_inside_tree() or bool(c.get("coop_spectating")):
		return {}
	var cam = c.get("Camera")
	if not (cam is Node3D) or not (cam as Node3D).is_inside_tree():
		return {}
	var ln = CoopSync.lantern
	var oil := 1.0
	var dry := false
	if is_instance_valid(ln) and bool(ln.get("oil_enabled")):
		oil = clampf(float(ln.get("oil")), 0.0, 1.0)
		dry = oil <= 0.0
	var lit: bool = bool(CoopSync.get("lantern_on")) and not dry
	var cn := cam as Node3D
	return {"node": c, "peer": _my_sid(), "eye": cn.global_position, "dir": -cn.global_basis.z.normalized(),
			"lit": lit, "oil": oil, "dry": dry, "f": oil_factor(oil), "local": true}


func _remote_entry(rp) -> Dictionary:
	if not is_instance_valid(rp) or not (rp is Node3D) or not (rp as Node3D).is_inside_tree():
		return {}
	var lit := false
	var lv = rp.get("lantern_lit")
	if lv == null:
		var lan = rp.get("_lantern")
		lit = lan != null and is_instance_valid(lan) and (lan as Node3D).visible
	else:
		lit = bool(lv)
	var pv = rp.get("oil_pct")
	var pct: int = int(pv) if pv != null else -1
	var oil := 1.0 if pct < 0 else clampf(float(pct) / 100.0, 0.0, 1.0)
	var dry := pct == 0
	lit = lit and not dry
	var eye: Vector3 = (rp as Node3D).global_position + Vector3.UP * 0.77
	if rp.has_method("eye_position"):
		eye = rp.eye_position()
	var pitch := float(rp.get("cam_pitch")) if rp.get("cam_pitch") != null else 0.0
	var yaw := float(rp.get("cam_yaw")) if rp.get("cam_yaw") != null else 0.0
	var dir := -Basis.from_euler(Vector3(pitch, yaw, 0.0)).z
	return {"node": rp, "peer": str(rp.get("peer_id")), "eye": eye, "dir": dir.normalized(),
			"lit": lit, "oil": oil, "dry": dry, "f": oil_factor(oil), "local": false}


func _refresh(force: bool = false) -> void:
	var now := Time.get_ticks_msec()
	if force or now - _upd_ms >= UPDATE_MS:
		# a new update: the ray budget starts again
		_rays_max = maxi(_rays_max, _rays)
		_rays_last = _rays
		_rays = 0
		_upd_ms = now
		_lanterns.clear()
		_local_ln = _local_entry()
		if not _local_ln.is_empty():
			_lanterns.append(_local_ln)
		if CoopSync.map_is_authority():
			for rp in CoopSync.remote_players():
				var e := _remote_entry(rp)
				if not e.is_empty():
					_lanterns.append(e)
		for ln in _lanterns:
			_track(ln["node"], bool(ln["lit"]), bool(ln["dry"]))
		_local_frame = Engine.get_process_frames()
		if _cache.size() > 1500:
			var keep: Dictionary = {}
			for k in _cache.keys():
				if now - int(_cache[k][0]) < FLAME_CACHE_MS:
					keep[k] = _cache[k]
			_cache = keep
	elif _local_frame != Engine.get_process_frames():
		# the local lantern follows the camera every frame (cheap: no rays)
		_local_frame = Engine.get_process_frames()
		if not _local_ln.is_empty():
			var fresh := _local_entry()
			if fresh.is_empty():
				_lanterns.erase(_local_ln)
				_local_ln = {}
			else:
				for k in ["eye", "dir", "lit", "oil", "dry", "f"]:
					_local_ln[k] = fresh[k]


func _entry_for(node) -> Dictionary:
	_refresh()
	if node == null or not is_instance_valid(node):
		return {}
	for ln in _lanterns:
		if ln["node"] == node:
			return ln
	if node == Game.climber:
		return _local_entry()
	if node.get("peer_id") != null:
		return _remote_entry(node)      # a guest asking about a teammate: built on the fly
	return {}


func _track(node, lit: bool, dry: bool) -> void:
	if node == null or not is_instance_valid(node):
		return
	var id: int = node.get_instance_id()
	var now := Time.get_ticks_msec()
	var s = _pstate.get(id)
	if s == null:
		# first sight: dark since long ago (no grace for a lantern that was never on), dry from now
		_pstate[id] = {"lit": lit, "dark_ms": now - (0 if lit else 1000000), "dry": dry, "dry_ms": now}
		return
	if bool(s["lit"]) != lit:
		s["lit"] = lit
		if not lit:
			s["dark_ms"] = now
	if bool(s["dry"]) != dry:
		s["dry"] = dry
		if dry:
			s["dry_ms"] = now


func player_lit(node: Node3D) -> bool:
	var e := _entry_for(node)
	if e.is_empty():
		return false
	_track(node, bool(e["lit"]), bool(e["dry"]))
	return bool(e["lit"])


func player_dark_ms(node: Node3D) -> int:
	var e := _entry_for(node)
	if e.is_empty():
		return 1000000
	_track(node, bool(e["lit"]), bool(e["dry"]))
	if bool(e["lit"]):
		return 0
	var s = _pstate.get(node.get_instance_id())
	return Time.get_ticks_msec() - int(s["dark_ms"]) if s != null else 1000000


func player_dry(node: Node3D) -> bool:
	var e := _entry_for(node)
	return not e.is_empty() and bool(e["dry"])


func player_dry_ms(node: Node3D) -> int:
	var e := _entry_for(node)
	if e.is_empty() or not bool(e["dry"]):
		return 0
	_track(node, bool(e["lit"]), true)
	var s = _pstate.get(node.get_instance_id())
	return Time.get_ticks_msec() - int(s["dry_ms"]) if s != null else 0


func most_oil_holder() -> Node3D:
	var best: Node3D = null
	var bo := -1.0
	for p in CoopSync.alive_player_nodes():
		if not is_instance_valid(p):
			continue
		var e := _entry_for(p)
		var o := float(e.get("oil", 1.0)) if not e.is_empty() else 1.0
		if o > bo + 0.0001:
			bo = o
			best = p
	return best


func facing_of(node) -> Vector3:
	var e := _entry_for(node)
	if e.is_empty():
		return Vector3.ZERO
	var d: Vector3 = e["dir"]
	d.y = 0.0
	return d.normalized() if d.length() > 0.01 else Vector3.ZERO


# ================================================================== light queries

func _beam_k(ln: Dictionary, p: Vector3, radius: float) -> float:
	var eye: Vector3 = ln["eye"]
	var dir: Vector3 = ln["dir"]
	var rng := BEAM_RANGE * float(ln["f"])
	var v := p - eye
	var d := v.length()
	if rng <= 0.0 or d >= rng:
		return 0.0
	var kd := 1.0
	if d > BEAM_FULL * rng:
		kd = (rng - d) / ((1.0 - BEAM_FULL) * rng)
	if d < 0.3:
		return kd
	var ang := rad_to_deg(acos(clampf(v.dot(dir) / d, -1.0, 1.0))) - rad_to_deg(atan(maxf(radius, 0.0) / d))
	ang = maxf(ang, 0.0)
	var ka := 1.0
	if ang >= BEAM_EDGE_DEG:
		return 0.0
	if ang > BEAM_CORE_DEG:
		ka = (BEAM_EDGE_DEG - ang) / (BEAM_EDGE_DEG - BEAM_CORE_DEG)
	return clampf(ka * kd, 0.0, 1.0)


func _glow_k(ln: Dictionary, p: Vector3) -> float:
	var r := GLOW_R * float(ln["f"])
	if r <= 0.0:
		return 0.0
	return maxf(0.0, 1.0 - (p - (ln["eye"] as Vector3)).length() / r)


func _ck(p: Vector3, size: float) -> String:
	return "%d,%d,%d" % [floori(p.x / size), floori(p.y / size), floori(p.z / size)]


func _clear(from: Vector3, p: Vector3, key: String, ttl_ms: int) -> bool:
	var now := Time.get_ticks_msec()
	var c = _cache.get(key)
	if c != null and now - int(c[0]) < ttl_ms:
		return bool(c[1])
	if map == null or not is_instance_valid(map) or not map.is_inside_tree():
		return true
	if _rays >= RAY_BUDGET:
		_misses += 1
		return true                      # over budget: the player gets the benefit
	_rays += 1
	_ray_total += 1
	var hit := map.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(from, p, 1))
	var clear := hit.is_empty() or (hit["position"] as Vector3).distance_to(p) <= CLEAR_NEAR
	_cache[key] = [now, clear]
	return clear


func _cands(p: Vector3, radius: float, beams_only: bool, local_only: bool) -> Array:
	# every source with k > 0 at p, strongest first: [k, src, entry]
	var out: Array = []
	for ln in _lanterns:
		if not bool(ln["lit"]):
			continue
		if local_only and not bool(ln["local"]):
			continue
		var kb := _beam_k(ln, p, radius)
		if kb > 0.0:
			out.append([kb, "beam", ln])
		if not beams_only:
			var kg := _glow_k(ln, p)
			if kg > 0.0:
				out.append([kg, "glow", ln])
	if not beams_only:
		for f in _flames_near(p):
			var kf := _flame_k(f, p)
			if kf > 0.0:
				out.append([kf, "flame", f])
	out.sort_custom(func(a, b): return float(a[0]) > float(b[0]))
	return out


func _cand_clear(c: Array, p: Vector3, key: int) -> bool:
	var src: String = c[1]
	var e: Dictionary = c[2]
	if src == "flame":
		var fp: Vector3 = e["pos"]
		if fp.distance_to(p) <= NEAR_NO_RAY:
			return true
		return _clear(fp, p, "F%d:%s" % [int(e["id"]), _ck(p, 2.0)], FLAME_CACHE_MS)
	var eye: Vector3 = e["eye"]
	if eye.distance_to(p) <= NEAR_NO_RAY:
		return true
	var node = e["node"]
	var nid: int = node.get_instance_id() if (node != null and is_instance_valid(node)) else 0
	var kk: String = str(key) if key != 0 else "c" + _ck(p, 1.0)
	return _clear(eye, p, "L%d:%s" % [nid, kk], LANTERN_CACHE_MS)


func light_at(p: Vector3, key: int = 0, radius: float = 0.3) -> Dictionary:
	_refresh()
	for c in _cands(p, radius, false, false):
		if _cand_clear(c, p, key):
			var src: String = c[1]
			var e: Dictionary = c[2]
			if src == "flame":
				return {"k": float(c[0]), "src": "flame", "peer": "", "node": null, "from": e["pos"], "dir": Vector3.ZERO}
			return {"k": float(c[0]), "src": src, "peer": e["peer"], "node": e["node"], "from": e["eye"], "dir": e["dir"]}
	return {"k": 0.0, "src": "", "peer": "", "node": null, "from": Vector3.ZERO, "dir": Vector3.ZERO}


func beam_at(p: Vector3, key: int = 0, radius: float = 0.3) -> Dictionary:
	_refresh()
	for c in _cands(p, radius, true, false):
		if _cand_clear(c, p, key):
			var e: Dictionary = c[2]
			return {"k": float(c[0]), "peer": e["peer"], "node": e["node"], "eye": e["eye"], "dir": e["dir"]}
	return {"k": 0.0, "peer": "", "node": null, "eye": Vector3.ZERO, "dir": Vector3.ZERO}


func is_lit(p: Vector3, key: int = 0) -> bool:
	return float(light_at(p, key).get("k", 0.0)) >= LIT_K


func local_lit(p: Vector3) -> bool:
	# display prediction on a guest: this player's own lantern and the flames, one cached ray
	_refresh()
	var cs := _cands(p, 0.3, false, true)
	if cs.is_empty() or float(cs[0][0]) < LIT_K:
		return false
	var c: Array = cs[0]
	var from: Vector3 = (c[2] as Dictionary)["pos"] if str(c[1]) == "flame" else (c[2] as Dictionary)["eye"]
	if from.distance_to(p) <= NEAR_NO_RAY:
		return true
	return _clear(from, p, "LL:" + _ck(p, 1.0), LANTERN_CACHE_MS)


func away_from_light(p: Vector3) -> Vector3:
	var r := light_at(p)
	if float(r["k"]) <= 0.0:
		return Vector3.ZERO
	var from: Vector3 = r["from"]
	var v := p - from
	if str(r["src"]) == "beam":
		var d: Vector3 = r["dir"]
		v = p - (from + d * (p - from).dot(d))          # straight out of the beam's axis
		v.y = 0.0
		if v.length() < 0.01:
			v = d.cross(Vector3.UP)
	v.y = 0.0
	if v.length() < 0.01:
		v = Vector3.RIGHT
	return v.normalized()


func stats() -> Dictionary:
	return {"rays": maxi(_rays_max, _rays), "rays_last": _rays_last, "rays_now": _rays, "rays_total": _ray_total,
			"misses": _misses, "lanterns": _lanterns.size(), "flames": _flames.size()}


func reset_stats() -> void:
	_rays_max = 0
	_misses = 0


# ================================================================== the light hint

func _biome_at(p: Vector3) -> int:
	if map.has_method("biome_at"):
		return int(map.call("biome_at", p))
	if map.has_method("_biome_at"):
		return int(map.call("_biome_at", p))
	return -1


func _sid_of(n: Node3D) -> String:
	if n == null or not is_instance_valid(n):
		return ""
	if n == Game.climber:
		return _my_sid()
	var pid = n.get("peer_id")
	return str(pid) if pid != null else ""


func _name_of(n: Node3D) -> String:
	if n == null or not is_instance_valid(n):
		return ""
	if n == Game.climber:
		return str(CoopSync.local_name)
	var pn = n.get("player_name")
	return str(pn) if pn != null else "A teammate"


func _hint_tick(delta: float) -> void:
	if not CoopSync.map_is_authority():
		return
	_hint_t -= delta
	if _hint_t > 0.0:
		return
	_hint_t = 1.0
	var now := Time.get_ticks_msec()
	if now < _hint_next_ms:
		return
	var players: Array = CoopSync.alive_player_nodes()
	if players.is_empty():
		return
	for c in Game.centipedes:
		if not is_instance_valid(c) or not (c as Node).is_inside_tree():
			continue
		if bool(c.get("coop_puppet")) or int(c.get("coop_skin")) != 1 or (c as Node).process_mode == Node.PROCESS_MODE_DISABLED:
			continue
		var cp: Vector3 = (c as Node3D).global_position
		var near := false
		for p in players:
			if is_instance_valid(p) and (p as Node3D).global_position.distance_to(cp) < HINT_R:
				near = true
				break
		if not near or CoopSync.target_player_for(c) == null:
			continue
		var b := _biome_at(cp)
		if _hint_biomes.has(b):
			continue
		_hint_biomes[b] = true
		_hint_next_ms = now + HINT_GAP_MS
		var h := most_oil_holder()
		var id := _sid_of(h)
		var data := {"id": id, "by": _name_of(h)}
		_hint_sent += 1
		print("[PALE] hint -> %s" % (id if id != "" else "nobody"))
		CoopSync.map_event("lfhint_%d" % b, data, false)
		if not _routed:
			_on_event("lfhint_%d" % b, data, false)     # no route on this map build: show it here at least
		return


func _on_event(key: String, data: Dictionary, replay: bool) -> void:
	if not key.begins_with("lfhint_") or replay:
		return
	_hint_seen += 1
	var id := str(data.get("id", ""))
	var text := ""
	if CoopSync.remote_players().is_empty():
		text = "The pale centipedes hate light. Hold your beam on a head."
	elif _is_me(id):
		text = "You have the most oil. Keep your beam on the pale centipede's head, it hates the light."
	else:
		var who := str(data.get("by", ""))
		if who == "" and CoopSync.has_method("name_of"):
			who = str(CoopSync.call("name_of", id))
		if who == "":
			who = "A teammate"
		text = "%s has the most oil. Stay in their light." % who
	if map != null and map.has_method("hint_once"):
		map.call("hint_once", key, text, 7.0)
	else:
		CoopSync.show_banner(text, 7.0)


# ================================================================== guest simulation (2.11)

class HissProbe extends Node:
	# stands in for a pale puppet while a guestsim recording plays (no centipede stream is
	# recorded, so no puppets exist): the map's "cr" receiver feeds it like one
	var cid := ""
	var last := -1
	var seeded := false
	var changes := 0
	var hisses := 0
	var shy = null

	func coop_note_cries(_c: String, _cry: int, _roar: int) -> void:
		pass

	func coop_note_hiss(_c: String, n: int) -> void:
		if n < 0:
			return
		if last < 0:
			seeded = true
		elif n != last:
			changes += 1
		var r: Array = [n, last >= 0 and n != last]
		if shy != null:
			r = shy.call("hiss_step", last, n)
		if bool(r[1]):
			hisses += 1
		last = int(r[0])


func _collect_pale_cids() -> void:
	var L = map.get("L") if map != null else null
	if not (L is Dictionary):
		return
	for c in (L as Dictionary).get("centipedes", []):
		if c is Dictionary and str(c.get("skin", "")) == "pale":
			var n: int = (c.get("spawn", []) as Array).size()
			for si in n:
				_pale_cids.append("%s:%d" % [str(c.get("id", "")), si])
	_pale_cids.append("waking_husk:0")


func _probe_tick(delta: float) -> void:
	if str(CoopSync.get("guestsim")) != "play":
		return
	_probe_t -= delta
	if _probe_t > 0.0:
		return
	_probe_t = 1.0
	var by_cid = CoopSync.get("_puppet_by_cid")
	if not (by_cid is Dictionary):
		return
	var shy = load(SHY_PATH)
	for cid in _pale_cids:
		var pr = _probes.get(cid)
		if pr == null:
			pr = HissProbe.new()
			pr.cid = cid
			pr.shy = shy
			pr.name = "HissProbe_" + str(cid).replace(":", "_")
			add_child(pr)
			_probes[cid] = pr
		var cur = (by_cid as Dictionary).get(cid)
		if cur == null or not is_instance_valid(cur):
			(by_cid as Dictionary)[cid] = pr


func guestsim_report() -> Array:
	var seeded := 0
	var changes := 0
	var hisses := 0
	for pr in _probes.values():
		if not is_instance_valid(pr):
			continue
		seeded += 1 if pr.seeded else 0
		changes += int(pr.changes)
		hisses += int(pr.hisses)
	if seeded == 0 or changes == 0:
		return ["SKIP pale hiss from cr (no hiss change in the recording, %d counters seeded)" % seeded]
	if hisses == changes:
		return ["PASS pale hiss from cr (first value seeded, then %d hiss)" % hisses]
	return ["FAIL pale hiss from cr (seeded %d, changes %d, hisses %d)" % [seeded, changes, hisses]]


# ================================================================== dev test: lightfear.flag

func _dev_flag(fname: String):
	if map != null and map.has_method("dev_flag"):
		return map.call("dev_flag", fname)
	if not FileAccess.file_exists(DIR + fname):
		return null
	var txt := FileAccess.get_file_as_string(DIR + fname).strip_edges()
	DirAccess.remove_absolute(OS.get_executable_path().get_base_dir() + "/mods-unpacked/zonda-CoopSync/maps/underdark/" + fname)
	return txt


func _test_begin(content: String) -> void:
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")
	_t_phases = [0, 1, 2, 3]
	if content in ["0", "1", "2", "3"]:
		_t_phases = [int(content)]
	elif content != "" and content != "1":
		print("[LIGHT] lightfear.flag '%s' not understood: running every phase" % content)
	_t_on = true
	_t_pi = -1
	_t_phase = -1
	_ts = 0
	_tt = 0.0
	print("[LIGHT] test armed: phases %s" % str(_t_phases))


func _cl() -> Node3D:
	var c = Game.climber
	if is_instance_valid(c) and (c as Node).is_inside_tree():
		return c
	return null


func _cam() -> Node3D:
	var c := _cl()
	if c == null:
		return null
	var cam = c.get("Camera")
	return cam if cam is Node3D else null


func _look_dir(dir: Vector3) -> void:
	var c := _cl()
	if c == null or dir.length() < 0.001:
		return
	var d := dir.normalized()
	var ang := Vector3(asin(clampf(d.y, -0.999, 0.999)), atan2(-d.x, -d.z), 0.0)
	var pc = c.get("PlayerCamera")
	if pc != null:
		pc.set("CameraAngles", ang)
	var cam := _cam()
	if cam != null:
		cam.rotation = ang
	_t_d["facing"] = Vector3(d.x, 0.0, d.z).normalized() if Vector2(d.x, d.z).length() > 0.01 else _t_d.get("facing", Vector3.FORWARD)


func _aim_at(p: Vector3) -> void:
	var cam := _cam()
	if cam != null:
		_look_dir(p - cam.global_position)


func _park(pos: Vector3) -> void:
	var c := _cl()
	if c == null:
		return
	if map.has_method("debug_park"):
		map.call("debug_park", pos)
	elif map.has_method("_debug_park"):
		map.call("_debug_park", c, pos)
	else:
		c.call("teleport_to_location", pos)
	c.global_rotation = Vector3.ZERO


func _shot(fname: String) -> void:
	var path := "user://" + fname
	if map.has_method("debug_shot"):
		map.call("debug_shot", path)
	elif map.has_method("_debug_shot"):
		map.call("_debug_shot", path)


func _check(tag: String, what: String, ok: bool) -> void:
	_t_total += 1
	if ok:
		_t_pass += 1
	else:
		_t_fails.append(what)
	print("[%s] %s %s" % [tag, "PASS" if ok else "FAIL", what])


func _next(step: int) -> void:
	_ts = step
	_tt = 0.0


func _lantern_on(on: bool) -> void:
	var ln = CoopSync.lantern
	if is_instance_valid(ln):
		ln.set("user", 1 if on else 0)


func _set_oil(x: float) -> void:
	var ln = CoopSync.lantern
	if is_instance_valid(ln) and bool(ln.get("oil_enabled")):
		ln.set("oil", x)


func _test_prepare() -> void:
	# invincible, lantern on, full oil, loopback script parked; all restored at the end
	var c := _cl()
	if c != null and _t_ppd == null:
		_t_ppd = bool(c.get("prevent_player_death"))
	if c != null:
		c.set("prevent_player_death", true)
	var ln = CoopSync.lantern
	if is_instance_valid(ln):
		if _t_user == null:
			_t_user = ln.get("user")
		if _t_oil == null:
			_t_oil = ln.get("oil")
	_lantern_on(true)
	_set_oil(1.0)
	if CoopSync.get("_loop_step") != null:
		CoopSync.set("_loop_step", 7)


func _test_restore() -> void:
	var c := _cl()
	if c != null and _t_ppd != null:
		c.set("prevent_player_death", bool(_t_ppd))
	_t_ppd = null
	var ln = CoopSync.lantern
	if is_instance_valid(ln):
		if _t_user != null:
			ln.set("user", int(_t_user))
		if _t_oil != null:
			ln.set("oil", float(_t_oil))
	_t_user = null
	_t_oil = null


func _test_ready() -> bool:
	if _cl() == null or _cam() == null:
		return false
	if map.has_method("load_announced") and not bool(map.call("load_announced")):
		return false
	if CoopSync.has_method("save_prompt_open") and bool(CoopSync.call("save_prompt_open")):
		return false
	return true


func _test_tick(delta: float) -> void:
	_tt += delta
	if _t_phase < 0:
		# between phases
		if _t_pi < 0:
			if not _test_ready():
				_tt = 0.0
				return
			if _tt < 3.0:
				return
		elif _tt < 1.0:
			return
		_t_pi += 1
		if _t_pi >= _t_phases.size():
			_test_end()
			return
		_t_phase = int(_t_phases[_t_pi])
		_t_d = {}
		_next(0)
		print("[LIGHT] phase %d start" % _t_phase)
		return
	match _t_phase:
		0:
			_tp0()
		1:
			_tp1()
		2:
			_tp2()
		3:
			_tp3()


func _phase_end() -> void:
	print("[LIGHT] phase %d end" % _t_phase)
	_t_phase = -1
	_tt = 0.0


func _test_end() -> void:
	_t_on = false
	_test_restore()
	if _t_fails.is_empty():
		print("[LIGHT] test done %d/%d PASS" % [_t_pass, _t_total])
	else:
		print("[LIGHT] test done %d/%d FAIL: %s" % [_t_pass, _t_total, ", ".join(PackedStringArray(_t_fails))])


func _lantern_k_at(p: Vector3) -> float:
	# the lanterns alone (no flames, no rays): the phase 0 numbers
	var best := 0.0
	for ln in _lanterns:
		if bool(ln["lit"]):
			best = maxf(best, maxf(_beam_k(ln, p, 0.0), _glow_k(ln, p)))
	return best


func _safe_far_station() -> Vector3:
	# the main-route station farthest from here that no trigger, flask or pickup sits near
	var L: Dictionary = map.get("L")
	var avoid: Array = []
	for c in L.get("checkpoints", []):
		avoid.append([_v(c["pos"]), float(c.get("r", 7.0)) + 20.0])
	for c in L.get("centipedes", []):
		if c.has("trigger"):
			avoid.append([_v(c["trigger"][0]), float(c["trigger"][1]) + 20.0])
	for d in L.get("dying_lights", []):
		avoid.append([_v(d["trigger"][0]), float(d["trigger"][1]) + 15.0])
	for key in ["oil", "kilns", "fragments", "relics", "plates", "bells", "altar", "finish", "gates"]:
		for e in L.get(key, []):
			if e is Dictionary and e.has("pos"):
				avoid.append([_v(e["pos"]), 25.0])
	var wh = L.get("waking_husk", null)
	if wh is Dictionary and wh.has("trigger"):
		avoid.append([_v(wh["trigger"]), float(wh.get("r", 6.0)) + 20.0])
	var here := _cl().global_position
	var best := Vector3.ZERO
	var bd := -1.0
	for s in L.get("stations", []):
		if not (s is Dictionary) or str(s.get("kind", "")) == "hard":
			continue
		var p := _v(s["pos"])
		var ok := true
		for a in avoid:
			if p.distance_to(a[0]) < float(a[1]):
				ok = false
				break
		if ok and p.distance_to(here) > bd:
			bd = p.distance_to(here)
			best = p
	return best


# ---------------------------------------------------------------- phase 0: the LightField

func _tp0() -> void:
	match _ts:
		0:
			_test_prepare()
			_next(1)
		1:
			if _tt < 0.4:
				return
			_refresh(true)
			if _local_ln.is_empty() or not bool(_local_ln["lit"]):
				_check("LIGHT", "local lantern lit (entry %s)" % str(not _local_ln.is_empty()), false)
				_phase_end()
				return
			var e: Vector3 = _local_ln["eye"]
			var d: Vector3 = _local_ln["dir"]
			for pr in [[5.0, 1.0], [12.0, 1.0], [20.0, 0.227], [30.0, 0.0]]:
				var k := _beam_k(_local_ln, e + d * float(pr[0]), 0.0)
				_check("LIGHT", "beam %.0f m ahead k=%.2f (want %.2f)" % [float(pr[0]), k, float(pr[1])], absf(k - float(pr[1])) <= 0.05)
			var kg := _lantern_k_at(e - d * 4.0)
			_check("LIGHT", "glow 4 m behind k=%.2f (want 0.33)" % kg, absf(kg - 1.0 / 3.0) <= 0.02)
			_lantern_on(false)
			_next(2)
		2:
			if _tt < 0.4:
				return
			_refresh(true)
			var e2: Vector3 = _cam().global_position
			var d2: Vector3 = -_cam().global_basis.z
			var koff := _lantern_k_at(e2 - d2 * 4.0)
			_check("LIGHT", "glow 4 m behind with the lantern off k=%.2f (want 0)" % koff, koff <= 0.001 and not player_lit(_cl()))
			_lantern_on(true)
			_set_oil(0.05)
			_next(3)
		3:
			if _tt < 0.4:
				return
			_refresh(true)
			if _local_ln.is_empty():
				_check("LIGHT", "local lantern at 5% oil", false)
			else:
				var e3: Vector3 = _local_ln["eye"]
				var d3: Vector3 = _local_ln["dir"]
				var gr := GLOW_R * float(_local_ln["f"])
				var k12 := _beam_k(_local_ln, e3 + d3 * 12.0, 0.0)
				var kedge := _glow_k(_local_ln, e3 - d3 * 2.72)
				_check("LIGHT", "oil 0.05: beam 12 m ahead k=%.2f (want about 0)" % k12, k12 < 0.15)
				_check("LIGHT", "oil 0.05: glow radius %.2f m (want 3.4)" % gr, absf(gr - 3.4) <= 0.05)
				_check("LIGHT", "oil 0.05: lit edge k=%.2f at 2.72 m (want 0.20)" % kedge, absf(kedge - 0.2) <= 0.02)
			_set_oil(1.0)
			reset_stats()
			_t_d["q"] = 0
			_next(4)
		4:
			# a realistic load: 10 keyed light queries around the player every frame for 1.2 s
			var cam := _cam()
			if cam != null:
				var base: Vector3 = cam.global_position
				for i in 10:
					var a := float(i) / 10.0 * TAU
					var q := base + Vector3(cos(a) * (3.0 + float(i)), -1.0, sin(a) * (3.0 + float(i)))
					light_at(q, 9001 + i, 0.3)
					_t_d["q"] = int(_t_d["q"]) + 1
			if _tt < 1.2:
				return
			var st := stats()
			print("[LIGHT] stats rays_max=%d rays_total=%d misses=%d lanterns=%d flames=%d queries=%d" % [int(st["rays"]), int(st["rays_total"]), int(st["misses"]), int(st["lanterns"]), int(st["flames"]), int(_t_d["q"])])
			_check("LIGHT", "stats rays <= %d per update (max %d) and 0 misses (%d)" % [RAY_BUDGET, int(st["rays"]), int(st["misses"])], int(st["rays"]) <= RAY_BUDGET and int(st["misses"]) == 0)
			_next(5)
		5:
			# static_k: data only, no rays, equal to 1 - d / r of the fire that dominates the point
			var before := _ray_total
			var done := 0
			var ok := true
			var detail: Array = []
			for f in _flames.values():
				if done >= 5:
					break
				if str(f["kind"]) != "fire" or not _alive(f):
					continue
				var r := float(f["r"])
				var dist := minf(1.0 + 0.75 * float(done), r * 0.9)
				var p: Vector3 = (f["pos"] as Vector3) + Vector3(dist, 0.0, 0.0)
				var want := 1.0 - dist / r
				var brute := 0.0
				for g in _flames.values():
					if not bool(g["dyn"]) and _alive(g):
						brute = maxf(brute, _flame_k(g, p))
				if brute > want + 0.001:
					continue                  # another flame dominates this point: pick another fire
				var got := static_k(p)
				detail.append("%.2f/%.2f" % [got, want])
				if absf(got - want) > 0.01:
					ok = false
				done += 1
			_check("LIGHT", "static_k (%s) with %d rays" % [", ".join(PackedStringArray(detail)), _ray_total - before], ok and done == 5 and _ray_total == before)
			_next(6)
		6:
			_refresh(true)
			_t_d["census"] = census()
			print("[LIGHT] flames: %s" % str(_t_d["census"]))
			var far := _safe_far_station()
			_t_d["far"] = far
			if far != Vector3.ZERO:
				_park(far + Vector3.UP * 1.0)
			_next(7)
		7:
			if _tt < 1.5:
				return
			_refresh(true)
			var c2 := census()
			print("[LIGHT] flames at the far end %s: %s" % [str(_t_d.get("far", Vector3.ZERO)), c2])
			_check("LIGHT", "census camera-independent", c2 == str(_t_d["census"]) and _t_d.get("far", Vector3.ZERO) != Vector3.ZERO)
			_phase_end()


# ---------------------------------------------------------------- phase 1: the Shades (shades.gd)

func _phase1_done(passed: int, total: int) -> void:
	_t_d["p1"] = [passed, total]


func _tp1() -> void:
	match _ts:
		0:
			var sh = map.call("feature", "shades") if map.has_method("feature") else null
			if sh == null or not is_instance_valid(sh) or not sh.has_method("run_test_phase"):
				print("[LIGHT] phase 1 SKIP no shades")
				_phase_end()
				return
			sh.call("run_test_phase", Callable(self, "_phase1_done"))
			_next(1)
		1:
			if _t_d.has("p1"):
				var r: Array = _t_d["p1"]
				_t_pass += int(r[0])
				_t_total += int(r[1])
				if int(r[0]) < int(r[1]):
					_t_fails.append("shades %d/%d" % [int(r[0]), int(r[1])])
				print("[LIGHT] phase 1 shades %d/%d" % [int(r[0]), int(r[1])])
				_phase_end()
			elif _tt > 420.0:
				_check("LIGHT", "phase 1 shades finished within 420 s", false)
				_phase_end()


# ---------------------------------------------------------------- phase 2: a pale centipede

func _cen3() -> Node3D:
	for c in Game.centipedes:
		if is_instance_valid(c) and (c as Node).has_meta("zonda_cid") and str((c as Node).get_meta("zonda_cid")) == "cen3:0":
			return c
	return null


func _head(c: Node3D) -> Vector3:
	var h = c.get("head_offset_node")
	if h is Node3D and is_instance_valid(h):
		return (h as Node3D).global_position
	return c.global_position


func _tp2_watch(c: Node3D) -> void:
	# every frame of the phase: a lunge may never start while the beam holds it
	if c == null or not is_instance_valid(c):
		return
	if c.has_meta("zonda_lit") and c.get("_current_state") is centipede_state_attack:
		_t_d["lit_attack"] = int(_t_d.get("lit_attack", 0)) + 1


const PALE_PATH_LIMIT_MS := 8000    # the circle gives up at 10 s; the no-clip pathfinder refuses gaps the head does not fit


func _tp2_circle(c: Node3D) -> void:
	# the flank is judged against where the player faced when CoopShy chose it
	var shy: Dictionary = c.get_meta("zonda_shy", {})
	var me := _cl().global_position
	var now := Time.get_ticks_msec()
	if not _t_d.has("circle") and int(shy.get("circle_ms", 0)) > 0:
		_t_d["circle"] = int(shy["circle_ms"])
		var fl := _v(shy.get("flank", [0, 0, 0]))
		var src := str(shy.get("src", ""))
		var face: Vector3 = _t_d.get("facing", Vector3.FORWARD)
		print("[PALE] circle: flank %s src=%s" % [str(fl), src])
		if src != "":
			_check("PALE", "flank is behind (dot %.1f)" % (fl - me).dot(face), (fl - me).dot(face) < 0.0)
		_check("PALE", "flank on rock (src=%s)" % (src if src != "" else "none, circle skipped"), src == "rock" or src == "station")
	if _t_d.has("circle") and not _t_d.has("path_checked"):
		var pm := int(shy.get("path_ms", 0))
		var am := int(shy.get("abort_ms", 0))
		if pm > 0 or am > 0 or now - int(_t_d["circle"]) > PALE_PATH_LIMIT_MS or str(shy.get("src", "")) == "":
			_t_d["path_checked"] = true
			if str(shy.get("src", "")) != "":
				# a flank path within the limit, or (no-clip) a clean give-up: no path in 4 s and it went back to hunting
				var t0 := int(_t_d["circle"])
				var got: bool = pm > 0 and pm - t0 <= PALE_PATH_LIMIT_MS
				var gave_up: bool = pm == 0 and am > 0 and am - t0 <= PALE_PATH_LIMIT_MS
				var what := "none"
				if pm > 0:
					what = "path after %.2f s" % ((pm - t0) / 1000.0)
				elif am > 0:
					what = "no path, went back to hunting after %.2f s" % ((am - t0) / 1000.0)
				_check("PALE", "shy path within %d s, or a clean give-up (%s)" % [PALE_PATH_LIMIT_MS / 1000, what], got or gave_up)


func _tp2_cleanup() -> void:
	var c := _cen3()
	if c != null:
		Game.centipedes.erase(c)
		c.queue_free()                   # a test creature: it would hunt the spider test next


func _tp2() -> void:
	var c := _cen3()
	_tp2_watch(c)
	match _ts:
		0:
			_test_prepare()
			_hint_biomes.clear()
			_hint_next_ms = 0
			_hint_sent = 0
			var L: Dictionary = map.get("L")
			var ce: Dictionary = {}
			for e in L.get("centipedes", []):
				if str(e.get("id", "")) == "cen3":
					ce = e
			if ce.is_empty():
				_check("PALE", "layout has cen3", false)
				_phase_end()
				return
			var sp := _v(ce["spawn"][0])
			_t_d["spawn"] = sp
			# the nearest main-route station 18-40 m from its den: we wait there for it to come
			var best := Vector3.ZERO
			var bd := 1e9
			for s in L.get("stations", []):
				if str(s.get("kind", "")) == "hard":
					continue
				var p := _v(s["pos"])
				var d := p.distance_to(sp)
				if d >= 18.0 and d <= 40.0 and d < bd:
					bd = d
					best = p
			if best == Vector3.ZERO:
				_check("PALE", "a station 18-40 m from cen3", false)
				_phase_end()
				return
			_park(best + Vector3.UP * 1.0)
			_look_dir(best - sp)
			print("[PALE] parked %.1f m from cen3's den at %s" % [bd, str(best)])
			_next(1)
		1:
			_look_dir(_cl().global_position - (_t_d["spawn"] as Vector3))
			if _tt < 1.2:
				return
			CoopSync.map_event("cent_cen3", {"id": "cen3"}, false)
			print("[PALE] woke cen3")
			_next(2)
		2:
			_look_dir(_cl().global_position - (_t_d["spawn"] as Vector3))
			if c != null:
				_t_d["hiss0"] = int(c.get_meta("zonda_hiss", 0))
				print("[PALE] cen3 is up (skin %d)" % int(c.get("coop_skin")))
				_next(3)
			elif _tt > 6.0:
				_check("PALE", "cen3 spawned", false)
				_phase_end()
		3:
			if c == null:
				_check("PALE", "cen3 alive", false)
				_phase_end()
				return
			_look_dir(_cl().global_position - _head(c))
			var hunting := load(HUNT_PATH)
			var cs = c.get("_current_state")
			if cs != null and cs.get_script() == hunting:
				if not CoopSync.in_session():
					_check("PALE", "solo state CoopHunting", true)
				_next(4)
			elif _tt > 12.0:
				var nm := "null"
				if cs != null:
					nm = str(cs.get_script().resource_path)
				if not CoopSync.in_session():
					_check("PALE", "solo state CoopHunting (state %s)" % nm, false)
				_next(4)
		4:
			if c == null:
				_check("PALE", "cen3 alive", false)
				_phase_end()
				return
			_look_dir(_cl().global_position - _head(c))        # face away while it closes in
			var d := _cam().global_position.distance_to(_head(c))
			if d <= 16.5:
				_t_d["aim0"] = Time.get_ticks_msec()
				print("[PALE] cen3 at %.1f m: beam on its head" % d)
				_next(5)
			elif _tt > 30.0:
				_check("PALE", "cen3 came within 16 m (closest %.1f m)" % d, false)
				_tp2_cleanup()
				_phase_end()
		5:
			if c == null:
				_check("PALE", "cen3 alive", false)
				_phase_end()
				return
			var now := Time.get_ticks_msec()
			if not _t_d.has("recoil"):
				_aim_at(_head(c))
				if int(c.get_meta("zonda_hiss", 0)) > int(_t_d["hiss0"]):
					_t_d["recoil"] = now
					_t_d["hiss1"] = int(c.get_meta("zonda_hiss", 0))
					print("[PALE] recoil after %.2f s" % ((now - int(_t_d["aim0"])) / 1000.0))
			else:
				_aim_at(_head(c))
				if not _t_d.has("shot") and now - int(_t_d["recoil"]) >= 300:
					_t_d["shot"] = true
					_shot("underdark_pale_recoil.png")
			_tp2_circle(c)
			if _tt >= 3.0:
				var ok_r: bool = _t_d.has("recoil") and int(_t_d["recoil"]) - int(_t_d["aim0"]) <= 1200
				_check("PALE", "recoil within 1.2 s (%s)" % (("%.2f s" % ((int(_t_d["recoil"]) - int(_t_d["aim0"])) / 1000.0)) if _t_d.has("recoil") else "none"), ok_r)
				_check("PALE", "hiss count +1 at the recoil (%d -> %d)" % [int(_t_d["hiss0"]), int(_t_d.get("hiss1", _t_d["hiss0"]))], int(_t_d.get("hiss1", -1)) == int(_t_d["hiss0"]) + 1)
				# turn round: the beam leaves it, it is in the dark behind us now
				var f: Vector3 = _t_d.get("facing", Vector3.FORWARD)
				_t_d["turn_face"] = -f
				_t_d["turn_ms"] = now
				_look_dir(-f)
				print("[PALE] turned 180 deg")
				_next(6)
		6:
			if c == null:
				_check("PALE", "cen3 alive after the turn", false)
				_tp2_end()
				return
			var now2 := Time.get_ticks_msec()
			var tf: Vector3 = _t_d["turn_face"]
			_look_dir(tf)
			var me := _cl().global_position
			if _t_d.has("recoil") and not _t_d.has("away_checked") and now2 - int(_t_d["recoil"]) >= 4000:
				_t_d["away_checked"] = true
				var dd := me.distance_to(c.global_position)
				_check("PALE", "at least 8 m away 4 s after the recoil (%.1f m)" % dd, dd >= 8.0)
			_tp2_circle(c)
			if not _t_d.has("came"):
				var dh := me.distance_to(_head(c))
				if dh >= 13.0:
					_t_d["was_far"] = true           # it has to come BACK: away first, then within 12 m
				if dh < 12.0 and _t_d.has("was_far"):
					_t_d["came"] = true
					var dot := (_head(c) - me).dot(tf)
					var secs := (now2 - int(_t_d["turn_ms"])) / 1000.0
					_check("PALE", "came back within 12 m from the dark side in %.1f s (dot %.1f)" % [secs, dot], dot < 0.0 and secs <= 15.0)
			var all_done: bool = _t_d.has("came") and _t_d.has("away_checked") and _t_d.has("path_checked")
			if all_done or _tt >= 15.0:
				_tp2_end()


func _tp2_end() -> void:
	if not _t_d.has("away_checked"):
		_check("PALE", "at least 8 m away 4 s after the recoil (not measured)", false)
	if not _t_d.has("circle"):
		_check("PALE", "circle reached (flank chosen)", false)
	elif not _t_d.has("path_checked"):
		_check("PALE", "shy path within %d s, or a clean give-up (not measured)" % (PALE_PATH_LIMIT_MS / 1000), false)
	if not _t_d.has("came"):
		_check("PALE", "came back within 12 m from the dark side within 15 s", false)
	_check("PALE", "never attacked while lit (%d frames)" % int(_t_d.get("lit_attack", 0)), int(_t_d.get("lit_attack", 0)) == 0)
	_check("PALE", "hint sent once (%d)" % _hint_sent, _hint_sent == 1)
	_tp2_cleanup()
	_phase_end()


# ---------------------------------------------------------------- phase 3: a wall spider

var _t_sp = null                       # LIGHT-3: the spider under test (the first one with a clear 8-12 m view)
var _t_bites := 0                      # LIGHT-3: its bite signal, counted (health heals back within seconds, so a
var _t_drop := 0.0                     # before/after compare misses a bite: every frame-to-frame health drop is added up too)
var _t_hp_prev := 0.0


func _on_t_bit(_who: Node3D, _damage: float, _id: String) -> void:
	_t_bites += 1


func _sp1():
	if _t_sp != null and is_instance_valid(_t_sp):
		return _t_sp
	return null


func _tp3_pick() -> void:
	# a spider whose body the beam can reach from a floor 8-12 m away: the no-clip fit lowers some bodies under
	# their crack, where no floor far off sees them (and nothing there could scare them either), so every spider
	# in turn gets the chance; the first one with such a floor is the one all of phase 3 uses
	match _ts:
		0:
			_test_prepare()
			_t_sp = null
			var cand: Array = []
			var sps = map.get("_spiders")
			if sps is Array:
				for s in sps:
					if is_instance_valid(s):
						cand.append(s)
			if cand.is_empty():
				_check("SPIDERLIGHT", "the map has wall spiders", false)
				_phase_end()
				return
			_t_d["cand"] = cand
			_t_d["ci"] = 0
			_next(10)
		10:
			var cand10: Array = _t_d["cand"]
			var sp10 = cand10[int(_t_d["ci"])]
			var a: Vector3 = sp10.get("anchor")
			var fl: Vector3 = sp10.get("floor_pt")
			var L: Dictionary = map.get("L")
			var best := Vector3.ZERO
			var bd := 1e9
			for s in L.get("stations", []):
				if str(s.get("kind", "")) == "hard":
					continue
				var p := _v(s["pos"])
				var hd := Vector2(p.x - a.x, p.z - a.z).length()
				if hd >= 16.0 and hd <= 35.0 and absf(p.y - fl.y) < 4.0 and hd < bd:
					bd = hd
					best = p
			if best == Vector3.ZERO:
				best = Vector3(a.x, fl.y, a.z) + Vector3(20.0, 0.0, 0.0)
			_t_d["far"] = best
			_park(best + Vector3.UP * 1.0)
			_look_away_from(a)
			_next(11)
		11:
			var cand11: Array = _t_d["cand"]
			var ci := int(_t_d["ci"])
			var sp11 = cand11[ci]
			var body11 := _sp_body(sp11)
			_look_away_from(body11)
			if _tt < 1.4:
				return
			# the click and bite phases stand under it: its floor point has to lie under the anchor (the bite reaches 1.6 m
			# from the anchor, so a floor point a metre or more off to the side could never be bitten from)
			var a11: Vector3 = sp11.get("anchor")
			var f11: Vector3 = sp11.get("floor_pt")
			var off11 := Vector2(a11.x - f11.x, a11.z - f11.z).length()
			# v5.1: and nothing solid between that floor and its body (a slab under the perch: it never clicks there)
			var under_ok := bool(sp11.call("_sees", f11 + Vector3.UP * 0.4)) if sp11.has_method("_sees") else true
			var spot := _spider_spot(sp11) if off11 <= 0.8 and under_ok else Vector3.ZERO
			if off11 > 0.8:
				print("[SPIDERLIGHT] %s: its floor point is %.1f m off to the side of its anchor, skipped" % [str(sp11.get("id")), off11])
			elif not under_ok:
				print("[SPIDERLIGHT] %s: rock between its floor point and its body, skipped" % str(sp11.get("id")))
			if spot != Vector3.ZERO:
				_t_sp = sp11
				_t_d["rest0"] = float(sp11.get("rest_s"))
				sp11.set("rest_s", 25.0)
				sp11.set("trigger_r", 6.0)
				_t_d["spot"] = spot
				_park(spot)
				_look_away_from(body11)
				print("[SPIDERLIGHT] %s: waiting %.1f m (horizontal) from it (spider %d of %d had a clear view)" % [str(sp11.get("id")), Vector2(spot.x - body11.x, spot.z - body11.z).length(), ci + 1, cand11.size()])
				_next(2)
				return
			print("[SPIDERLIGHT] %s: no floor 8-12 m away sees its body" % str(sp11.get("id")))
			ci += 1
			if ci < cand11.size():
				_t_d["ci"] = ci
				_next(10)
			else:
				_check("SPIDERLIGHT", "a floor 8-12 m from a wall spider with a clear view (looked at %d)" % cand11.size(), false)
				_tp3_end()


func _sp_body(sp) -> Vector3:
	var a: Vector3 = sp.get("anchor")
	return Vector3(a.x, float(sp.get("y")), a.z)


func _look_away_from(p: Vector3) -> void:
	var me := _cl().global_position
	var d := me - p
	d.y = 0.0
	if d.length() < 0.1:
		d = Vector3.FORWARD
	_look_dir(d)


func _spider_spot(sp) -> Vector3:
	# 8-12 m out from the anchor, horizontally, on rock near its floor, away from checkpoints and flasks
	var a: Vector3 = sp.get("anchor")
	var fl: Vector3 = sp.get("floor_pt")
	var L: Dictionary = map.get("L")
	var space := map.get_world_3d().direct_space_state
	var toward := Vector3.ZERO
	if _t_d.has("far"):
		toward = (_t_d["far"] as Vector3) - a
		toward.y = 0.0
	for dist in [10.0, 9.0, 11.0, 8.5, 11.5, 12.0, 8.0]:
		for i in 16:
			var ang := float(i) / 16.0 * TAU
			var dir := Vector3(cos(ang), 0.0, sin(ang))
			if toward.length() > 0.1 and i == 0:
				dir = toward.normalized()
			var p := Vector3(a.x, fl.y, a.z) + dir * float(dist)
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(p + Vector3.UP * 3.0, p + Vector3.DOWN * 4.0, 1))
			if hit.is_empty() or (hit["normal"] as Vector3).y < 0.7:
				continue
			var g: Vector3 = hit["position"]
			var ok := true
			for c in L.get("checkpoints", []):
				if g.distance_to(_v(c["pos"])) < float(c.get("r", 7.0)) + 1.0:
					ok = false
			for o in L.get("oil", []):
				if g.distance_to(_v(o["pos"])) < 2.5:
					ok = false
			var hd := Vector2(g.x - a.x, g.z - a.z).length()
			if ok and hd >= 8.0 and hd <= 12.0 and _spider_los(space, g, sp):
				return g + Vector3.UP * 1.0
	return Vector3.ZERO


func _spider_los(space, g: Vector3, sp) -> bool:
	# the beam has to reach the spider: from the player's eye at that spot the body, which the no-clip fit
	# lowers under its crack, must be in view. Rock in between hides it from the light (nothing to scare).
	var body := _sp_body(sp)
	var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(g + Vector3.UP * 1.8, body, 1))
	return hit.is_empty() or (hit["position"] as Vector3).distance_to(body) <= 0.6


func _tp3() -> void:
	if _ts == 0 or _ts >= 10:
		_tp3_pick()
		return
	var sp = _sp1()
	if sp == null:
		_check("SPIDERLIGHT", "the spider under test exists", false)
		_phase_end()
		return
	var st := int(sp.get("st"))
	var body := _sp_body(sp)
	match _ts:
		2:
			_look_away_from(body)
			if _tt < 1.0:
				return
			if st != 0:
				if _tt > 40.0:
					_check("SPIDERLIGHT", "sp_1 waiting before the pre-emptive test (state %d)" % st, false)
					_tp3_end()
				return
			_t_d["aim"] = Time.get_ticks_msec()
			_t_d["clicked"] = false
			_next(3)
		3:
			if st == 1:
				_t_d["clicked"] = true
			if st == 6:
				var dt := (Time.get_ticks_msec() - int(_t_d["aim"])) / 1000.0
				_check("SPIDERLIGHT", "pre-emptive scatter within 0.8 s from 8-12 m (%.2f s, why=%s, click first=%s)" % [dt, str(sp.get("last_scatter_why")), str(_t_d["clicked"])],
						dt <= 0.8 and str(sp.get("last_scatter_why")) == "pre-emptive" and not bool(_t_d["clicked"]))
				_t_d["scat"] = Time.get_ticks_msec()
				_look_away_from(body)
				_next(4)
				return
			_aim_at(body)
			if _tt > 3.0:
				_check("SPIDERLIGHT", "pre-emptive scatter within 0.8 s from 8-12 m (none, state %d)" % st, false)
				_look_away_from(body)
				_next(5)
		4:
			_look_away_from(body)
			var now := Time.get_ticks_msec()
			if not _t_d.has("shot1") and now - int(_t_d["scat"]) >= 400:
				_t_d["shot1"] = true
				_shot("underdark_spider_scatter.png")
			if st == 5 and bool(sp.get("hidden")) and not _t_d.has("rest_ms"):
				_t_d["rest_ms"] = now
			if st == 0 and _t_d.has("rest_ms"):
				var secs := (now - int(_t_d["rest_ms"])) / 1000.0
				_check("SPIDERLIGHT", "hidden for 25 s, then WAIT (%.1f s)" % secs, absf(secs - 25.0) <= 0.6)
				_next(5)
			elif _tt > 40.0:
				_check("SPIDERLIGHT", "hidden for 25 s, then WAIT (state %d)" % st, false)
				_next(5)
		5:
			# the CLICK case: under it, looking away; 0.3 s into the click, the beam goes on it
			if st != 0:
				if _tt > 30.0:
					_check("SPIDERLIGHT", "sp_1 waiting before the click test (state %d)" % st, false)
					_tp3_end()
				return
			sp.set("rest_s", 3.0)                # the rest was measured above: shorter from here
			var fl2: Vector3 = sp.get("floor_pt")
			_park(fl2 + Vector3.UP * 1.0)
			_look_dir(Vector3(1.0, 0.0, 0.0))
			_t_d["hp"] = float(_cl().get("health"))
			_t_d["seen"] = []
			_next(6)
		6:
			_look_dir(Vector3(1.0, 0.0, 0.0))
			if not (st in _t_d["seen"]):
				(_t_d["seen"] as Array).append(st)
			if st == 1:
				_t_d["click_ms"] = Time.get_ticks_msec()
				_next(7)
			elif _tt > 2.0:
				_check("SPIDERLIGHT", "a click under sp_1 (states %s)" % str(_t_d["seen"]), false)
				_next(8)
		7:
			if not (st in _t_d["seen"]):
				(_t_d["seen"] as Array).append(st)
			var since := Time.get_ticks_msec() - int(_t_d["click_ms"])
			if st == 6 or st == 5 or _tt > 2.5:
				var seen: Array = _t_d["seen"]
				var hp := float(_cl().get("health"))
				_check("SPIDERLIGHT", "CLICK + beam: scatter, no bite (states %s, hp %.0f -> %.0f)" % [str(seen), float(_t_d["hp"]), hp],
						seen.has(6) and not seen.has(2) and not seen.has(3) and hp >= float(_t_d["hp"]) - 0.01)
				_look_dir(Vector3(1.0, 0.0, 0.0))
				_next(8)
				return
			if since >= 300:
				_aim_at(body)
			else:
				_look_dir(Vector3(1.0, 0.0, 0.0))
		8:
			# aim away through a whole click: the normal drop and bite
			_look_dir(Vector3(1.0, 0.0, 0.0))
			if st == 0 or st == 1:
				_t_d["hp2"] = float(_cl().get("health"))
				_t_d["seen2"] = []
				_t_bites = 0
				_t_drop = 0.0
				_t_hp_prev = float(_cl().get("health"))
				if sp.has_signal("bit") and not sp.is_connected("bit", _on_t_bit):
					sp.connect("bit", _on_t_bit)
				_next(9)
			elif _tt > 12.0:
				_check("SPIDERLIGHT", "sp_1 back before the bite test (state %d)" % st, false)
				_tp3_end()
		9:
			_look_dir(Vector3(1.0, 0.0, 0.0))
			if not (st in _t_d["seen2"]):
				(_t_d["seen2"] as Array).append(st)
			var seen2: Array = _t_d["seen2"]
			var hp2 := float(_cl().get("health"))
			if hp2 < _t_hp_prev:
				_t_drop += _t_hp_prev - hp2
			_t_hp_prev = hp2
			if seen2.has(4) or _tt > 6.0:
				if sp.has_signal("bit") and sp.is_connected("bit", _on_t_bit):
					sp.disconnect("bit", _on_t_bit)
				_check("SPIDERLIGHT", "aimed away: the normal drop and bite (states %s, %d bites, %.0f health lost)" % [str(seen2), _t_bites, _t_drop],
						seen2.has(2) and seen2.has(3) and not seen2.has(6) and _t_bites >= 1 and _t_drop >= 1.0)
				_tp3_end()


func _tp3_end() -> void:
	var sp = _sp1()
	if sp != null:
		sp.set("rest_s", float(_t_d.get("rest0", 25.0)))
	_phase_end()
