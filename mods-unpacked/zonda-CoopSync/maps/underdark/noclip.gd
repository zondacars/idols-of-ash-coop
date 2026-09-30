extends RefCounted
# ============================================================================================
# THE UNDERDARK: the creature no-clip helper (ZondaCoopSync 5.0, group NC-1).
# Spec: docs/specs/2026-09-25-creature-noclip.md, section 2 (API 2.1 is frozen).
#
# Static functions and static vars only. Every other group reaches this file at runtime:
#   const NC_PATH := "res://mods-unpacked/zonda-CoopSync/maps/underdark/noclip.gd"
#   var NC = load(NC_PATH)            # once; null means "move as before" (Rule K)
#   if NC != null and NC.call("is_enabled"): pos = NC.call("move", space, st, pos)
#
# Rule K: is_enabled() is true only while THE UNDERDARK is live (set_map), and the guard switch is
# on (the probe's baseline mode turns it off). Counters (note) run while measuring(), guard or not.
#
# Rule N: every hit normal is flipped to face the ray's origin (the cave winding is inconsistent).
# Rays: mask 1 (all world rock), hit_back_faces = true (a ray reports every crossing of the hollow
# double-sided cave trimesh, from either side), no areas.
#
# Cost accounting: move, clearance, walk_step, place and try_recover time themselves (the "usec"
# counter, and CoopSync.perf_add). Do not wrap them in your own add_usec timing; use add_usec only
# for guard work of your own that runs outside these calls.
# walk_step counts its stats under prof["kind"] when the profile carries one (else "walker").
#
# Additive helpers (beyond the frozen 2.1 list; nobody has to use them):
#   count_as(kind) -> String   rays cast outside the calls above (posture probes, bat rays) count under
#                              kind until set back: var k = NC.count_as("stalker"); ...; NC.count_as(k)
#   extra_ok(n) -> bool        the EXTRA_CAP budget: true (and n rays booked) while this physics tick
#                              has room for n more posture / audit / bat rays; centre sweeps never ask
#   count(kind, key) -> int, total(key, skip = "probe") -> int   single counters for the probe
#   prof_ok(prof) -> bool      the 2.6 walk profile rules
# ============================================================================================

const MASK := 1
const OFF := 0              # rock not loaded near the mover: no rays at all (2.5)
const FAR := 1              # more than 150 m from every player
const NEAR := 2             # 60 to 150 m
const FULL := 3             # under 60 m
const R_FULL := 60.0
const R_NEAR := 150.0
const R_PARITY := 140.0     # a parity test is trusted only within this of an anchor eye
const TP_JUMP := 3.0        # a guarded mover that moves farther than this in one tick teleported
const RING_N := 8           # safe points kept per mover
const RING_MS := 500        # one safe point pushed every 0.5 s of guarded motion
const EXTRA_CAP := 160      # posture, audit and bat rays per physics tick; centre sweeps are NEVER deferred
const AUDIT_MS := 2000      # parity self-check of an UNVERIFIED safe point
const REC_MIN_D := 12.0     # a recovery point is at least this far from every player's capsule
const REC_STATION_D := 25.0 # ...and a station at least this far
const SEEN_DOT := 0.45      # the Stalker's view cone
const RECAST := 0.005       # parity: re-cast 5 mm past each hit
const GRAZE_DOT := 0.12     # parity: a hit this close to parallel makes the answer unknown
const SEG_SOLID_STEP := 40.0
const LOOP_ID_DEFAULT := 777

# 2.8: ONE envelope table. Fallbacks from the scene transforms and the GDRE mesh bounds; the probe's
# P0 measures them in the engine and prints the values to paste here when they differ by 0.3 m.
# centipede fwd, up, chin, belly_want: the rigid SHELL measured by P0 (Arm_ bone split, NC-1 run on
# centipede.tscn's models and transforms): shell fwd 1.54, up 1.91, below 1.36; belly_want = chin + 0.05.
# The old fwd 7.6 was Monster_Head2's IK ARMS (they plant on rock), which made the JAW / FWD probes
# about 10 m long. The 7A.1 limits do NOT follow the shell: gap 3.85 (the pathfinder's column), half_w
# 2.3 (the pathfinder's side rays are half_w + 0.05 = 2.35 m: 4.7 m wide; the shell is 1.87), roof_want
# 2.23 and cheek_want 2.33 (the head's roof and cheek squeeze). Change them only with the owner.
const ENV := {
	"centipede": {"fwd": 1.54, "up": 1.91, "half_w": 2.3, "chin": 1.36, "ride": 1.6,
		"neck_back": 3.5, "neck_below": 1.83,
		"sec_below": 0.89, "sec_up": 1.53, "sec_half_w": 2.24,
		"belly_want": 1.41, "roof_want": 2.23, "cheek_want": 2.33, "gap": 3.85},
	"stalker": {"lift": 1.23, "head_fwd": 4.83, "head_up": 1.61, "head_half_w": 1.68, "seg_below": 0.65, "seg_up": 1.11},
	"harrier": {"half_len": 2.2, "half_span": 2.0, "belly": 1.0},
	"shade": {"height": 3.1, "hunch_min": 2.5},
}

# the keys report() prints on a "[CLIP] guard <kind>" line
const GUARD_KEYS := ["sweeps", "blocks", "slides", "stall_ticks", "skips", "backs", "repaths", "escalations",
		"stuck_seen", "walk", "refused", "tps", "recovers", "held_ms", "jaw_unres_ms", "rays"]

static var _map = null
static var _guard := true
static var _measuring := false
static var _q: PhysicsRayQueryParameters3D = null
static var _pq: PhysicsPointQueryParameters3D = null
static var _eyes: Array = []
static var _eyes_key := Vector2i(-1, -1)
static var _counts: Dictionary = {}        # kind -> {key: int}
static var _kind := ""                     # whose rays are being counted right now
static var _concave: Dictionary = {}       # collider instance id -> bool (trimesh or not)
static var _stations: PackedVector3Array = PackedVector3Array()
static var _stations_read := false
static var _prof_bad: Dictionary = {}      # profiles already reported as broken
static var _perf := -1                      # CoopSync.perf_add exists: -1 unknown, 0 no, 1 yes
static var _warned: Dictionary = {}
static var _has_solid := false             # the map answers is_solid_at
static var _has_keep := false              # the map answers noclip_keep_solid
static var _extra_frame := -1
static var _extra_used := 0


# ============================================================================ switches

static func set_map(m) -> void:
	# underdark.gd: _ready (self) and _exit_tree (null)
	_map = m
	_has_solid = m != null and is_instance_valid(m) and (m as Object).has_method("is_solid_at")
	_has_keep = m != null and is_instance_valid(m) and (m as Object).has_method("noclip_keep_solid")
	_eyes = []
	_eyes_key = Vector2i(-1, -1)
	_concave.clear()
	_stations = PackedVector3Array()
	_stations_read = false
	_perf = -1


static func set_guard(on: bool) -> void:
	# the probe's baseline mode turns every guard off (Rule K)
	_guard = on


static func guard_on() -> bool:
	return _guard


static func is_enabled() -> bool:
	# the map is live AND the guard is on
	return _guard and is_instance_valid(_map) and (_map as Node).is_inside_tree()


static func set_measuring(on: bool) -> void:
	_measuring = on


static func measuring() -> bool:
	# fairness counters on (the probe runs), guard or not
	return _measuring


static func map_node() -> Node:
	if is_instance_valid(_map):
		return _map as Node
	return null


static func env(kind: String) -> Dictionary:
	# a copy of the kind's ENV row ("pale" and "follower" are centipedes)
	var k := kind
	if k == "pale" or k == "follower":
		k = "centipede"
	return (ENV.get(k, {}) as Dictionary).duplicate()


static func extra_ok(n: int = 1) -> bool:
	# EXTRA_CAP: posture, audit and bat rays share at most EXTRA_CAP rays per physics tick. true books
	# n rays in this tick's budget; false means "skip it this tick, try the next". Centre sweeps never ask.
	var fr := Engine.get_physics_frames()
	if fr != _extra_frame:
		_extra_frame = fr
		_extra_used = 0
	if _extra_used + n > EXTRA_CAP:
		return false
	_extra_used += n
	return true


# ============================================================================ eyes and sight (2.4)

static func eyes() -> Array:
	# [{"p": Vector3, "fwd": Vector3, "anchor": bool}], cached per physics frame (and render frame).
	# The local viewer is the current camera; it is an ANCHOR (parity may start there) only while the
	# local climber is alive, not spectating, and a ray from its capsule centre to the camera is clear.
	# Each alive remote player except the loopback Ghost: eye_position(), forward from cam_yaw/cam_pitch.
	var key := Vector2i(Engine.get_physics_frames(), Engine.get_process_frames())
	if key == _eyes_key:
		return _eyes
	_eyes_key = key
	var out: Array = []
	var space = _space()
	var cam: Camera3D = null
	if is_instance_valid(_map) and (_map as Node).is_inside_tree():
		cam = (_map as Node).get_viewport().get_camera_3d()
	else:
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and tree.root != null:
			cam = tree.root.get_camera_3d()
	if cam != null and is_instance_valid(cam) and cam.is_inside_tree():
		var cp: Vector3 = cam.global_position
		var anchor := false
		var c = _climber()
		if c != null and space != null and _local_alive(c):
			anchor = ray(space, (c as Node3D).global_position, cp).is_empty()
		out.append({"p": cp, "fwd": -cam.global_basis.z, "anchor": anchor, "local": true})
	if CoopSync.has_method("remote_players"):
		var rps = CoopSync.call("remote_players")
		if rps is Array:
			for rp in rps:
				if not is_instance_valid(rp) or not (rp is Node3D):
					continue
				if rp.get("alive") != null and not bool(rp.get("alive")):
					continue
				if _is_ghost(rp):
					continue
				var n3 := rp as Node3D
				var eye: Vector3 = n3.global_position + Vector3.UP * 0.77
				if rp.has_method("eye_position"):
					var e = rp.call("eye_position")
					if e is Vector3:
						eye = e
				var cy = rp.get("cam_yaw")
				var cpi = rp.get("cam_pitch")
				var fwd: Vector3
				if cy == null:
					fwd = -n3.global_basis.z
				elif cpi == null:
					fwd = -Basis.from_euler(Vector3(0.0, float(cy), 0.0)).z
				else:
					fwd = -Basis.from_euler(Vector3(float(cpi), float(cy), 0.0)).z
				var anc := space != null and ray(space, n3.global_position, eye).is_empty()
				out.append({"p": eye, "fwd": fwd, "anchor": anc, "local": false})
	_eyes = out
	return _eyes


static func nearest_eye(p: Vector3):
	# the nearest ANCHOR eye within R_PARITY: Vector3 or null
	var an := _anchor_eyes(p)
	if an.is_empty():
		return null
	return an[0]


static func seen_by_any(points: Array, max_d: float = 150.0) -> bool:
	# any viewer (anchor or not) has a point within max_d, inside its cone, with a clear line
	var es := eyes()
	if es.is_empty():
		return false
	var space = _space()
	if space == null:
		return false
	for e in es:
		var ep: Vector3 = e["p"]
		var fwd: Vector3 = e["fwd"]
		for q in points:
			if not (q is Vector3):
				continue
			var to: Vector3 = (q as Vector3) - ep
			var d := to.length()
			if d > max_d:
				continue
			if d < 0.05:
				return true
			if fwd.dot(to / d) <= SEEN_DOT:
				continue
			if ray(space, ep, q).is_empty():
				return true
	return false


# ============================================================================ rock loading

static func solid_at(p: Vector3, r: float = 6.0) -> bool:
	# map.is_solid_at(p, r) (every chunk near p has collision, and has had it for 2 physics frames);
	# true when there is no map (or the map has no such test)
	if not is_instance_valid(_map):
		return true
	if _has_solid:
		return bool(_map.is_solid_at(p, r))
	_warn_once("solid", "[CLIP] the map has no is_solid_at: rock is treated as loaded")
	return true


static func keep_solid(p: Vector3) -> void:
	# host: map.noclip_keep_solid(p) (the rock around p turns solid within one LOD sweep); else nothing
	if not is_instance_valid(_map) or not _has_keep:
		return
	if CoopSync.has_method("map_is_authority") and not bool(CoopSync.call("map_is_authority")):
		return
	(_map as Object).call("noclip_keep_solid", p)


static func tier_of(p: Vector3) -> int:
	# OFF if the rock around p is not loaded, else by the distance to the nearest eye
	if not solid_at(p, 6.0):
		return OFF
	var best := INF
	for e in eyes():
		best = minf(best, p.distance_to(e["p"]))
	if best < R_FULL:
		return FULL
	if best < R_NEAR:
		return NEAR
	return FAR


# ============================================================================ rays and sweeps

static func ray(space, a: Vector3, b: Vector3) -> Dictionary:
	# one reused query: mask 1, hit_back_faces, no areas. {} when clear; else {"position",
	# "normal" (Rule N: faces a), "d" (distance from a), "collider", "shape"}
	if space == null or a.distance_squared_to(b) < 1e-10:
		return {}
	if _q == null:
		_q = PhysicsRayQueryParameters3D.new()
		_q.collision_mask = MASK
		_q.hit_back_faces = true
		_q.hit_from_inside = false
		_q.collide_with_areas = false
		_q.collide_with_bodies = true
	_q.from = a
	_q.to = b
	if _measuring:
		_bump(_kind if _kind != "" else "other", "rays", 1)
	var h: Dictionary = space.intersect_ray(_q)
	if h.is_empty():
		return {}
	var pos: Vector3 = h["position"]
	var n: Vector3 = h["normal"]
	if n.dot(b - a) > 0.0:
		n = -n
	return {"position": pos, "normal": n, "d": a.distance_to(pos), "collider": h.get("collider"), "shape": int(h.get("shape", 0))}


static func sweep(space, a: Vector3, b: Vector3, lead: float, offs: Array = []) -> Dictionary:
	# the earliest hit over (a + o) -> (b + o + dir * lead) for o in offs ([] = the centre only).
	# {"ok": true} or {"ok": false, "position", "normal", "safe", "d"}; "safe" = the farthest point
	# from a toward b that keeps lead clear of the hit, never behind a
	var mv := b - a
	var L := mv.length()
	if L < 1e-5:
		return {"ok": true}
	var dir := mv / L
	var best: Dictionary = {}
	var best_d := INF
	if offs.is_empty():
		best = ray(space, a, b + dir * lead)
		if not best.is_empty():
			best_d = float(best["d"])
	else:
		for o in offs:
			var ov: Vector3 = o if o is Vector3 else Vector3.ZERO
			var h := ray(space, a + ov, b + ov + dir * lead)
			if not h.is_empty() and float(h["d"]) < best_d:
				best_d = float(h["d"])
				best = h
	if best.is_empty():
		return {"ok": true}
	var s := clampf(best_d - lead, 0.0, L)
	return {"ok": false, "position": best["position"], "normal": best["normal"], "safe": a + dir * s, "d": best_d}


# ============================================================================ the mover (2.2, 2.3)

static func state(kind: String, p: Vector3, opts: Dictionary = {}) -> Dictionary:
	# the Dictionary a guarded mover keeps. opts: "lead" (0.4), "offs" ([]), "anchor" (null)
	var an = opts.get("anchor", null)
	return {
		"kind": kind, "good": p, "last": p, "ring": [], "anchor": an if an is Vector3 else null,
		"lead": float(opts.get("lead", 0.4)), "offs": opts.get("offs", []) if opts.get("offs", []) is Array else [],
		"tier": FULL, "tick": 0, "tier_t": 0,
		"blocked": false, "n": Vector3.UP, "why": "", "stall_n": 0,
		"frozen": false, "stale": false, "verified": false, "need_rec": false, "tp": 0,
		"probe_i": 0, "audit_ms": 0, "ring_ms": 0, "keep_ms": 0, "rec_try_ms": -100000,
	}


static func move(space, st: Dictionary, to: Vector3, opts: Dictionary = {}) -> Vector3:
	# the swept move of a guarded mover: returns where it really is this tick (2.3).
	# opts: "slide" (true), "free_off" (false: hold while the rock is not loaded)
	if space == null or st.is_empty():
		return to
	var t0 := Time.get_ticks_usec()
	var pk := _kind
	var kind := str(st.get("kind", "other"))
	_kind = kind
	var out := _move(space, st, to, opts)
	_kind = pk
	_spent(kind, t0)
	return out


static func _move(space, st: Dictionary, to: Vector3, opts: Dictionary) -> Vector3:
	var now := Time.get_ticks_msec()
	var kind := str(st["kind"])
	st["tick"] = int(st["tick"]) + 1
	# 1. the budget tier, every 0.25 s
	if now >= int(st["tier_t"]):
		st["tier"] = tier_of(to)
		st["tier_t"] = now + 250
	var tier := int(st["tier"])
	# 2. the rock is not loaded here
	if tier == OFF:
		if bool(opts.get("free_off", false)):
			st["stale"] = true
			st["verified"] = false
			st["frozen"] = false
			st["why"] = "unloaded"
			st["last"] = to
			return to
		st["frozen"] = true
		st["blocked"] = true
		st["why"] = "unloaded"
		if now >= int(st.get("keep_ms", 0)):
			st["keep_ms"] = now + 500
			keep_solid(st["good"])
		_bump(kind, "held_off_ticks")
		st["last"] = st["good"]
		return st["good"]
	# 3. leaving OFF after flying unguarded: re-seed here with parity, never sweep from the stale good
	if bool(st["stale"]):
		st["stale"] = false
		st["frozen"] = false
		_bump(kind, "reseeds")
		return _place(space, st, to, null, false)
	st["frozen"] = false
	# 4. a self-audit found good in rock: held until the caller's try_recover succeeds
	if bool(st["need_rec"]):
		st["last"] = st["good"]
		return st["good"]
	# 5. FAR: a 30 Hz chord (the next due sweep covers good -> current)
	if tier == FAR and int(st["tick"]) % 4 != 0:
		st["last"] = to
		return to
	# 6, 7. the sweep, with a slide along the wall in FULL and NEAR
	var res := _sweep_to(space, st, to, bool(opts.get("slide", true)), true)
	# 8. the self-audit, only while good is unverified
	_audit(space, st, now)
	return res


static func _sweep_to(space, st: Dictionary, to: Vector3, slide: bool, main: bool) -> Vector3:
	# sweep good -> to; good only ever becomes the end of a sweep that crossed no rock surface
	var kind := str(st["kind"])
	var good: Vector3 = st["good"]
	if good.distance_to(to) < 0.001:
		st["last"] = to
		return to
	_bump(kind, "sweeps" if main else "pushes")
	var r := sweep(space, good, to, float(st["lead"]), st["offs"])
	if bool(r["ok"]):
		st["good"] = to
		_ring_push(st)
		if main:
			st["blocked"] = false
			st["stall_n"] = 0
			st["why"] = ""
		st["last"] = to
		return to
	var safe: Vector3 = r["safe"]
	var n: Vector3 = r["normal"]
	var res := safe
	var tier := int(st["tier"])
	if slide and (tier == FULL or tier == NEAR):
		var rem := to - safe
		rem -= n * rem.dot(n)
		var rl := rem.length()
		if rl > 0.01 and ray(space, safe, safe + rem + rem / rl * float(st["lead"])).is_empty():
			res = safe + rem
			_bump(kind, "slides")
	st["good"] = res
	_ring_push(st)
	st["last"] = res
	if main:
		st["blocked"] = true
		st["why"] = "wall"
		st["n"] = n
		_bump(kind, "blocks")
		# a slide that makes progress never counts toward a stall
		if res.distance_to(good) < 0.2 * to.distance_to(good):
			st["stall_n"] = int(st["stall_n"]) + 1
			_bump(kind, "stall_ticks")
		else:
			st["stall_n"] = 0
	return res


static func _ring_push(st: Dictionary) -> void:
	# only proven points (a verified chain) go into the ring, one every RING_MS
	if not bool(st["verified"]):
		return
	var now := Time.get_ticks_msec()
	if now < int(st["ring_ms"]):
		return
	st["ring_ms"] = now + RING_MS
	var ring: Array = st["ring"]
	ring.push_front(st["good"])
	while ring.size() > RING_N:
		ring.pop_back()


static func _audit(space, st: Dictionary, now: int) -> void:
	# parity self-check of an UNVERIFIED good (a seed that could not run parity), FULL or NEAR only.
	# A verified chain is never audited: its air is proven by induction.
	if bool(st["verified"]) or bool(st["need_rec"]):
		return
	var tier := int(st["tier"])
	if tier != FULL and tier != NEAR:
		return
	if now < int(st["audit_ms"]):
		return
	if not extra_ok(12):
		return                                  # the tick's extra budget is spent: next tick
	st["audit_ms"] = now + AUDIT_MS
	var kind := str(st["kind"])
	_bump(kind, "audits")
	var r := inside2(space, st["good"])
	if r == 0:
		st["verified"] = true
	elif r == 1:
		st["need_rec"] = true
		st["why"] = "inside"
		_bump(kind, "audit_inside")


static func clearance(space, st: Dictionary, p: Vector3, dir: Vector3, want: float) -> Vector3:
	# ONE ray p -> p + dir * want; a hit at d < want pushes p back by want - d along -dir, as a swept
	# move from st.good (it can never push into other rock). Returns the corrected p.
	if space == null or st.is_empty() or dir.length_squared() < 1e-8 or want <= 0.0:
		return p
	var t0 := Time.get_ticks_usec()
	var pk := _kind
	var kind := str(st.get("kind", "other"))
	_kind = kind
	var dn := dir.normalized()
	var out := p
	var h := ray(space, p, p + dn * want)
	if not h.is_empty() and float(h["d"]) < want:
		out = _sweep_to(space, st, p - dn * (want - float(h["d"])), false, false)
	_kind = pk
	_spent(kind, t0)
	return out


# ============================================================================ parity (2.4)

static func inside(space, p: Vector3, anchor: Vector3, cap: int = 8, anchor_is_eye: bool = true) -> int:
	# 1 rock, 0 air, -1 unknown. Parity of the cave-trimesh crossings along anchor -> p (the anchor is
	# air). Convex solids (boxes, cylinders) are answered by a point query instead.
	if space == null:
		return -1
	if not solid_at(p, 6.0) or not solid_at(anchor, 6.0):
		return -1
	var seg := p - anchor
	var L := seg.length()
	if L > R_PARITY:
		return -1
	if L < 0.001:
		return 1 if _in_convex(space, p) else 0
	var dir := seg / L
	if not anchor_is_eye:
		# a data anchor: a chunk that is not solid in between would hide its surfaces
		var k := SEG_SOLID_STEP
		while k < L:
			if not solid_at(anchor + dir * k, SEG_SOLID_STEP * 0.5 + 0.5):
				return -1
			k += SEG_SOLID_STEP
	var from := anchor
	var count := 0
	var prev_pos := Vector3.INF
	var prev_n := Vector3.ZERO
	var iters := 0
	while true:
		iters += 1
		if iters > cap * 3 + 6:
			return -1
		var h := ray(space, from, p)
		if h.is_empty():
			break
		var hp: Vector3 = h["position"]
		var n: Vector3 = h["normal"]
		if _is_concave(h):
			if absf(n.dot(dir)) < GRAZE_DOT:
				return -1                       # nearly parallel along bumpy rock: parity flips here
			var same := prev_pos != Vector3.INF and hp.distance_to(prev_pos) < 0.01 and n.dot(prev_n) > 0.99
			if not same:
				count += 1
				if count > cap:
					return -1
			prev_pos = hp
			prev_n = n
		from = hp + dir * RECAST
		if (p - from).dot(dir) <= 0.0:
			break
	if _in_convex(space, p):
		return 1
	return 1 if count % 2 == 1 else 0


static func inside2(space, p: Vector3, cap: int = 8) -> int:
	# two independent anchors must agree: the nearest anchor eye within R_PARITY, and the second
	# nearest one, else the first shifted 0.5 m sideways (used only if the ray to it is clear)
	if space == null:
		return -1
	var an := _anchor_eyes(p)
	if an.is_empty():
		return -1
	var A: Vector3 = an[0]
	var B = null
	if an.size() > 1 and (an[1] as Vector3).distance_to(A) > 0.05:
		B = an[1]
	else:
		var d := p - A
		var side := Vector3(-d.z, 0.0, d.x)
		if side.length() < 0.001:
			side = Vector3.RIGHT
		side = side.normalized() * 0.5
		for sgn in [1.0, -1.0]:
			var a2: Vector3 = A + side * float(sgn)
			if ray(space, A, a2).is_empty():
				B = a2
				break
	if B == null:
		return -1
	var r1 := inside(space, p, A, cap, true)
	if r1 == -1:
		return -1
	var r2 := inside(space, p, B, cap, true)
	if r1 == r2:
		return r1
	return -1


static func _anchor_eyes(p: Vector3) -> Array:
	# anchor eye positions within R_PARITY of p, nearest first
	var tmp: Array = []
	for e in eyes():
		if not bool(e.get("anchor", false)):
			continue
		var ep: Vector3 = e["p"]
		var d := ep.distance_to(p)
		if d <= R_PARITY:
			tmp.append([d, ep])
	tmp.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var out: Array = []
	for t in tmp:
		out.append(t[1])
	return out


static func _is_concave(h: Dictionary) -> bool:
	# a cave trimesh (every crossing reported, parity counts it) or a convex solid (entries only)
	var col = h.get("collider")
	if col == null or not is_instance_valid(col) or not (col is CollisionObject3D):
		return true
	var id: int = (col as Object).get_instance_id()
	if _concave.has(id):
		return bool(_concave[id])
	var res := false
	var co := col as CollisionObject3D
	for oid in co.get_shape_owners():
		for k in co.shape_owner_get_shape_count(oid):
			var sh := co.shape_owner_get_shape(oid, k)
			if sh is ConcavePolygonShape3D or sh is HeightMapShape3D:
				res = true
	_concave[id] = res
	return res


static func _in_convex(space, p: Vector3) -> bool:
	# p is inside a convex layer-1 solid (a prop box, a bell cylinder, a platform)
	if space == null:
		return false
	if _pq == null:
		_pq = PhysicsPointQueryParameters3D.new()
		_pq.collision_mask = MASK
		_pq.collide_with_areas = false
		_pq.collide_with_bodies = true
	_pq.position = p
	if _measuring:
		_bump(_kind if _kind != "" else "other", "rays", 1)
	var hits: Array = space.intersect_point(_pq, 4)
	for h in hits:
		if not _is_concave(h):
			return true
	return false


# ============================================================================ placement and recovery

static func place(space, st: Dictionary, p: Vector3, anchor = null) -> Vector3:
	# a teleport or a seed: parity decides whether p is air. The caller guarantees it is not seen
	# (every teleport site checks seen_by_any first, except spawns and scripted test hooks).
	if st.is_empty():
		return p
	var t0 := Time.get_ticks_usec()
	var pk := _kind
	var kind := str(st.get("kind", "other"))
	_kind = kind
	var out := _place(space, st, p, anchor, true)
	_kind = pk
	_spent(kind, t0)
	return out


static func _place(space, st: Dictionary, p: Vector3, anchor, bump: bool) -> Vector3:
	var kind := str(st["kind"])
	var an = anchor if anchor is Vector3 else st.get("anchor", null)
	var r := -1
	if space != null:
		r = inside2(space, p)
		if r == -1 and an is Vector3:
			r = inside(space, p, an, 8, false)
	var res := p
	var ver := false
	if r == 0:
		ver = true
	elif r == 1:
		st["ring"] = []
		st["good"] = p
		var c = recover(space, st)
		if c is Vector3:
			res = c
			ver = true
		else:
			print("[CLIP] place in rock, no recovery point: %s at %s" % [kind, _fmt(p)])
	st["ring"] = []
	st["good"] = res
	st["last"] = res
	st["verified"] = ver
	st["need_rec"] = false
	st["blocked"] = false
	st["stall_n"] = 0
	st["stale"] = false
	st["frozen"] = false
	st["ring_ms"] = 0
	st["audit_ms"] = Time.get_ticks_msec() + AUDIT_MS
	if bump or res.distance_to(p) > 0.01:
		st["tp"] = int(st["tp"]) + 1
		st["why"] = "tp"
		_bump(kind, "tps")
	return res


static func recover(space, st: Dictionary, opts: Dictionary = {}):
	# a proven air point to put a stuck mover, or null. Candidates in order: ring points newest first
	# (skipping those within opts.min_back of good), the anchor, then the nearest layout stations
	# within 60 m of good (station + 1 m, with a floor within 3 m below and opts.head (3.8) clear
	# above). Every candidate keeps REC_MIN_D (stations REC_STATION_D) from every alive player and
	# is not seen.
	if space == null or st.is_empty():
		return null
	var min_back := float(opts.get("min_back", 0.0))
	var head := float(opts.get("head", 3.8))
	var good: Vector3 = st["good"]
	var players := _player_centres()
	for q in st["ring"]:
		if not (q is Vector3):
			continue
		if min_back > 0.0 and (q as Vector3).distance_to(good) < min_back:
			continue
		if _rec_ok(q, players, REC_MIN_D):
			return q
	var an = st.get("anchor", null)
	if an is Vector3 and (min_back <= 0.0 or (an as Vector3).distance_to(good) >= min_back) and _rec_ok(an, players, REC_MIN_D):
		return an
	for s in _stations_near(good, 60.0, 4):
		var c: Vector3 = (s as Vector3) + Vector3.UP * 1.0
		if min_back > 0.0 and c.distance_to(good) < min_back:
			continue
		if not solid_at(c, 4.0):
			continue
		if ray(space, c, c + Vector3.DOWN * 3.0).is_empty():
			continue
		if not ray(space, c, c + Vector3.UP * head).is_empty():
			continue
		if _rec_ok(c, players, REC_STATION_D):
			return c
	return null


static func try_recover(space, st: Dictionary, vis: Array, opts: Dictionary = {}):
	# null at once when the mover is seen (vis: its own visible points) or within 0.5 s of the last
	# try; else recover() and, on a point, the bookkeeping. The caller then resets its body.
	if st.is_empty():
		return null
	var now := Time.get_ticks_msec()
	var last := int(st.get("rec_try_ms", -100000))
	if now - last < 500:
		return null
	st["rec_try_ms"] = now
	var t0 := Time.get_ticks_usec()
	var pk := _kind
	var kind := str(st.get("kind", "other"))
	_kind = kind
	var held := mini(now - last, 1000) if last > -100000 else 0
	var out = null
	if seen_by_any(vis):
		_bump(kind, "held_ms", held)
		_bump(kind, "recover_held_seen")
	else:
		var c = recover(space, st, opts)
		if c is Vector3:
			st["good"] = c
			st["last"] = c
			st["ring"] = []
			st["tp"] = int(st["tp"]) + 1
			st["why"] = "recover"
			st["need_rec"] = false
			st["verified"] = true
			st["blocked"] = false
			st["stall_n"] = 0
			st["frozen"] = false
			st["stale"] = false
			_bump(kind, "recovers")
			_bump(kind, "tps")
			out = c
		else:
			_bump(kind, "held_ms", held)
	_kind = pk
	_spent(kind, t0)
	return out


static func _rec_ok(c: Vector3, players: Array, dmin: float) -> bool:
	for pc in players:
		if c.distance_to(pc) < dmin:
			return false
	return not seen_by_any([c, c + Vector3.UP * 1.5])


static func _player_centres() -> Array:
	var out: Array = []
	var list = CoopSync.call("alive_player_nodes") if CoopSync.has_method("alive_player_nodes") else null
	if list is Array:
		for n in list:
			if is_instance_valid(n) and n is Node3D:
				out.append((n as Node3D).global_position)
	else:
		var c = _climber()
		if c != null:
			out.append((c as Node3D).global_position)
	# the loopback Ghost stands where the host looks: keep recoveries off it too
	var peers = CoopSync.get("_peers")
	if peers is Dictionary:
		var g = (peers as Dictionary).get(_loop_id())
		if is_instance_valid(g) and g is Node3D:
			out.append((g as Node3D).global_position)
	return out


static func _stations_near(p: Vector3, r: float, n: int) -> Array:
	# the nearest layout stations within r of p, nearest first (at most n)
	if not _stations_read:
		_stations_read = true
		var L = (_map as Object).get("L") if is_instance_valid(_map) else null
		if L is Dictionary:
			for s in (L as Dictionary).get("stations", []):
				if s is Dictionary and (s as Dictionary).has("pos"):
					var a = s["pos"]
					if a is Array and a.size() >= 3:
						_stations.append(Vector3(float(a[0]), float(a[1]), float(a[2])))
	var tmp: Array = []
	for s in _stations:
		var d := s.distance_to(p)
		if d <= r:
			tmp.append([d, s])
	tmp.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	var out: Array = []
	for i in mini(n, tmp.size()):
		out.append(tmp[i][1])
	return out


# ============================================================================ the floor walk (2.6)

static func walk_step(space, from: Vector3, dir: Vector3, dist: float, prof: Dictionary) -> Dictionary:
	# prof: {"probes": [h0, h1, ...] ascending, "lead", "step_up", "max_drop", "head" (minimum
	#        headroom), "min_ny" (0.5), optional "room_max", "tall", "room_from", "kind"}
	# returns {"ok", "pos" (floor point), "via" (== from when none), "n" (floor normal, Rule N),
	#          "room" (headroom at pos), "low_t" (a hunch height to cross at, or INF),
	#          "why": "" | "prof" | "unloaded" | "wall" | "edge" | "steep" | "rise" | "drop" | "low"}
	# from is a floor point whose headroom (at least head) was proven when it was accepted.
	var t0 := Time.get_ticks_usec()
	var pk := _kind
	var kind := str(prof.get("kind", "walker"))
	_kind = kind
	var r := _walk(space, from, dir, dist, prof)
	_kind = pk
	_bump(kind, "walk")
	if not bool(r["ok"]):
		_bump(kind, "refused")
	_spent(kind, t0)
	return r


static func _ws(ok: bool, why: String, pos: Vector3, via: Vector3, n: Vector3, room: float, low_t: float) -> Dictionary:
	return {"ok": ok, "why": why, "pos": pos, "via": via, "n": n, "room": room, "low_t": low_t}


static func prof_ok(prof: Dictionary) -> bool:
	# the 2.6 profile rules: every probe starts where the headroom was proven, and the full step-up
	# height has a clear probe above its lip
	var probes = prof.get("probes", [])
	if not (probes is Array) or (probes as Array).is_empty():
		return false
	var mx := -INF
	var prev := -INF
	for h in probes:
		var hf := float(h)
		if hf < prev:
			return false
		prev = hf
		mx = maxf(mx, hf)
	var head := float(prof.get("head", 0.0))
	var step_up := float(prof.get("step_up", 0.0))
	return head >= mx + 0.1 - 1e-6 and mx >= step_up + 0.2 - 1e-6


static func _walk(space, from: Vector3, dir: Vector3, dist: float, prof: Dictionary) -> Dictionary:
	var up := Vector3.UP
	if not prof_ok(prof):
		var key := str(prof.get("probes", [])) + "|" + str(prof.get("head", 0)) + "|" + str(prof.get("step_up", 0))
		if not _prof_bad.has(key):
			_prof_bad[key] = true
			push_error("[CLIP] walk_step profile breaks the 2.6 rules (head >= max probe + 0.1, max probe >= step_up + 0.2): %s" % str(prof))
		return _ws(false, "prof", from, from, up, 0.0, INF)
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length() < 1e-5 or dist <= 1e-4:
		return _ws(true, "", from, from, up, float(prof.get("head", 0.0)), INF)
	var dn := flat.normalized()
	var want := from + dn * dist
	var probes: Array = prof["probes"]
	var lead := float(prof.get("lead", 0.3))
	var step_up := float(prof.get("step_up", 0.0))
	var max_drop := float(prof.get("max_drop", 0.0))
	var head := float(prof.get("head", 0.0))
	var min_ny := float(prof.get("min_ny", 0.5))
	# 1. missing rock is never read as a void
	if not solid_at(want, 4.0) or not solid_at(from, 4.0):
		return _ws(false, "unloaded", from, from, up, 0.0, INF)
	# 2. body probes at the old level
	var top := -1.0
	for h in probes:
		var hf := float(h)
		var hit := ray(space, from + up * hf, want + up * hf + dn * lead)
		if hit.is_empty():
			top = hf
		elif hf > step_up:
			return _ws(false, "wall", from, from, up, 0.0, INF)
	if top < 0.0:
		return _ws(false, "wall", from, from, up, 0.0, INF)
	# 3. the floor, from a point proven in air (never the underside of an overhang)
	var fl := ray(space, want + up * top, want + Vector3.DOWN * (max_drop + 0.3))
	if fl.is_empty():
		return _ws(false, "edge", from, from, up, 0.0, INF)
	var n: Vector3 = fl["normal"]
	if n.y < min_ny:
		return _ws(false, "steep", from, from, n, 0.0, INF)
	var np: Vector3 = fl["position"]
	var rise := np.y - from.y
	if rise > step_up:
		return _ws(false, "rise", from, from, n, 0.0, INF)
	if rise < -max_drop:
		return _ws(false, "drop", from, from, n, 0.0, INF)
	# 4. headroom at the new floor point
	var room_max := maxf(float(prof.get("room_max", head)), head)
	var room := room_max
	var hr := ray(space, np + up * 0.1, np + up * room_max)
	if not hr.is_empty():
		room = float(hr["d"]) + 0.1
		if room < head:
			return _ws(false, "low", from, from, n, room, INF)
	# 5. the tall probe (Shades): a hit does not refuse the step, it asks for a hunch
	var low_t := INF
	if prof.has("tall"):
		var h_t := minf(float(prof["tall"]), float(prof.get("room_from", prof["tall"])) - 0.1)
		if h_t > 0.0 and not ray(space, from + up * h_t, want + up * h_t + dn * lead).is_empty():
			low_t = h_t - 0.05
	# 6. the L-shaped path, never diagonal through a lip
	var via := from
	if rise > 0.15:
		via = Vector3(from.x, np.y, from.z)
		if not ray(space, from + up * head, via + up * head).is_empty():
			return _ws(false, "low", from, from, n, room, INF)
		var h0 := float(probes[0])
		if not ray(space, via + up * h0, np + up * h0 + dn * lead).is_empty():
			return _ws(false, "wall", from, from, n, room, INF)
	elif rise < -0.15:
		via = Vector3(np.x, from.y, np.z)
	return _ws(true, "", np, via, n, room, low_t)


static func l_step(cur: Vector3, via: Vector3, goal: Vector3, step: float) -> Vector3:
	# move cur toward via until within 1 cm, then toward goal, by at most step in total
	if step <= 0.0:
		return cur
	var out := cur
	var left := step
	var dv := out.distance_to(via)
	if dv > 0.01:
		if dv <= left:
			out = via
			left -= dv
		else:
			return out + (via - out) / dv * left
	var dg := out.distance_to(goal)
	if dg <= left:
		return goal
	if dg < 1e-6:
		return out
	return out + (goal - out) / dg * left


# ============================================================================ counters (2.9)

static func note(kind: String, key: String, n: int = 1) -> void:
	# fairness and guard counters (a no-op unless measuring)
	_bump(kind, key, n)


static func counters() -> Dictionary:
	# {kind: {key: int}}, a copy
	return _counts.duplicate(true)


static func add_usec(kind: String, usec: int) -> void:
	# guard work a caller measured itself (not the helper calls above, which time themselves)
	if usec <= 0:
		return
	_bump(kind, "usec", usec)
	_perf_add(usec)


static func count(kind: String, key: String) -> int:
	# one counter (0 when absent): cheaper than counters() for a per-frame check
	var d = _counts.get(kind)
	if d == null:
		return 0
	return int((d as Dictionary).get(key, 0))


static func total(key: String, skip: String = "probe") -> int:
	# a counter summed over every kind except skip (the probe's own rays are not guard cost)
	var n := 0
	for k in _counts.keys():
		if str(k) == skip:
			continue
		n += int((_counts[k] as Dictionary).get(key, 0))
	return n


static func count_as(kind: String) -> String:
	# rays cast outside move / clearance / walk_step / place / try_recover (a posture probe, a bat
	# ray, the probe's own sampling) count under this kind until it is set back; returns the previous
	# kind so the caller can restore it: var k = NC.count_as("stalker"); ...; NC.count_as(k)
	var prev := _kind
	_kind = kind
	return prev


static func report() -> Array:
	# "[CLIP] guard <kind> ..." lines, one per kind that ran any guard work (the probe's own rays
	# are not guard work)
	var out: Array = []
	var kinds: Array = _counts.keys()
	kinds.sort()
	for k in kinds:
		if str(k) == "probe":
			continue
		var d: Dictionary = _counts[k]
		var any := false
		for key in GUARD_KEYS:
			if int(d.get(key, 0)) != 0:
				any = true
				break
		if not any and int(d.get("usec", 0)) == 0:
			continue
		var parts: Array = []
		for key in GUARD_KEYS:
			parts.append("%s=%d" % [key, int(d.get(key, 0))])
		var calls := maxi(1, int(d.get("calls", 0)))
		parts.append("usec_avg=%.1f" % (float(d.get("usec", 0)) / float(calls)))
		out.append("[CLIP] guard %s %s" % [str(k), " ".join(PackedStringArray(parts))])
	return out


static func reset_stats() -> void:
	_counts.clear()


static func _bump(kind: String, key: String, n: int = 1) -> void:
	if not _measuring:
		return
	var d = _counts.get(kind)
	if d == null:
		d = {}
		_counts[kind] = d
	d[key] = int(d.get(key, 0)) + n


static func _spent(kind: String, t0: int) -> void:
	var us := Time.get_ticks_usec() - t0
	if _measuring:
		_bump(kind, "usec", us)
		_bump(kind, "calls", 1)
	_perf_add(us)


static func _perf_add(us: int) -> void:
	if _perf < 0:
		_perf = 1 if CoopSync.has_method("perf_add") else 0
	if _perf == 1:
		CoopSync.call("perf_add", us)


# ============================================================================ small helpers

static func _space():
	if is_instance_valid(_map) and _map is Node3D and (_map as Node3D).is_inside_tree():
		return (_map as Node3D).get_world_3d().direct_space_state
	var c = _climber()
	if c != null:
		return (c as Node3D).get_world_3d().direct_space_state
	return null


static func _climber():
	var c = Game.get("climber")
	if is_instance_valid(c) and c is Node3D and (c as Node3D).is_inside_tree():
		return c
	return null


static func _local_alive(c) -> bool:
	if c.get("coop_spectating") != null and bool(c.get("coop_spectating")):
		return false
	var hp = c.get("health")
	if hp != null and float(hp) <= 0.0:
		return false
	return true


static func _loop_id() -> int:
	var v = CoopSync.get("LOOP_ID")
	return int(v) if v != null else LOOP_ID_DEFAULT


static func _is_ghost(rp) -> bool:
	var lid := _loop_id()
	var pid = rp.get("peer_id")
	if pid != null and int(pid) == lid:
		return true
	var peers = CoopSync.get("_peers")
	if peers is Dictionary and (peers as Dictionary).get(lid) == rp:
		return true
	return false


static func _warn_once(key: String, text: String) -> void:
	if _warned.has(key):
		return
	_warned[key] = true
	push_warning(text)


static func _fmt(p: Vector3) -> String:
	return "(%.1f, %.1f, %.1f)" % [p.x, p.y, p.z]
