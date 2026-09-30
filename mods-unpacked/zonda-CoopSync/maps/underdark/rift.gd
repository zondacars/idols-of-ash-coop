extends RefCounted
# ============================================================================================
# THE UNDERDARK: the rift's geometry as data (ZondaCoopSync 5.0, owner B6)
#
#   var Rift = load("res://mods-unpacked/zonda-CoopSync/maps/underdark/rift.gd")
#   Rift.callv("use_layout", [map.L])      once per map load (idempotent within a frame)
#
# Static functions only. A port of the generator's own shapes (GEN/sdf_rift.py Rift.center and
# Rift.radius, TerraceSolid.covers and side; GEN/rift_world.py Z = 1.3, RW = 1.1), so it answers
# for FAR rock too, where the map has no collision (only chunks within 150 m of a player do).
#
#   use_layout(L)                  L["rift"]["samples"] = [[y, cx, cz, r], ...] every 10 m (wave 2)
#                                  replace the port below; L["rift"]["terraces"] (wave 2) replaces
#                                  the wave 1 table. Logs "[RIFT] terraces N (<source>)" and warns once
#                                  when a known foothold sits more than 30 m off the radius.
#   center(y) -> Vector2           (x, z) of the rift's axis at depth y
#   radius(y) -> float             the wall's mean distance from the axis at depth y
#   void_dir(p) -> Vector3         flat unit vector from p toward the axis (ZERO on the axis)
#   edge_exposed(space, p, reach = [1.5, 3.0, 4.5]) -> int
#                                  probes at p + void_dir * k + 1 m up that find NO floor within 30 m
#                                  below (layer 1). 0 = safe footing all round the void side.
#   terraces() -> Array            the giant fallen shelves: [{"name", "y_top", "bottom", "a_mid", "k",
#                                  "thick", "R"}]. L.rift.terraces, else TERRACES_W1 when layout.json's
#                                  md5 is TERRACES_W1_MD5, else [] (one warning)
#   in_terrace(p, margin = 8.0) -> bool
#                                  inside a terrace slab: y in [y_top - thick * 1.4 - margin, y_top + margin]
#                                  and side(p) = (p.x - cx) cos(a_mid) + (p.z - cz) sin(a_mid) + k R(y_top)
#                                  > -margin (cx, cz = center(p.y))
#   open_point(t) -> Vector3       the middle of the terrace's OPEN segment at y_top:
#                                  center(y_top) - dir(a_mid) * 0.6 R(y_top)
#   terrace_side(t, p) -> float    side(p) above (> 0 on the covered side, metres from the chord)
#   status() -> String             where the terraces came from ("table, md5 ok", "layout", ...)
# ============================================================================================

const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
const Z := 1.3                      # rift_world.py: depth scale
const RW := 1.1                     # rift_world.py: width scale
# rift_world.py Builder.rift radius control points, raw (y, r); used as (y * Z, r * RW)
const RADIUS_RAW := [[-30.0, 85.0], [-200.0, 112.0], [-330.0, 135.0], [-700.0, 145.0], [-790.0, 150.0],
		[-1000.0, 175.0], [-1185.0, 185.0], [-1400.0, 190.0], [-1575.0, 165.0], [-1800.0, 160.0],
		[-1965.0, 195.0], [-2200.0, 210.0], [-2365.0, 185.0], [-2600.0, 180.0], [-2765.0, 195.0],
		[-3000.0, 185.0]]
const RADIUS_LAKE := [-4170.5, 165.0]   # (LAKE_Y - 4, 150 * RW), already scaled

# Every TerraceSolid in the wave 1 generator build (W.build(sdf.SEED), R.solids), dumped offline by
# B6's probe_terraces.py (reads GEN only). bottom = y_top - thick * 1.4 (TerraceSolid.covers).
const TERRACES_W1_MD5 := "b52e68d50856d5515696627ecce4adfb"
const TERRACES_W1 := [
	{"name": "THE SHELF I", "y_top": -255.976, "bottom": -274.803, "a_mid": -1.600846, "k": 0.2, "thick": 13.4484},
	{"name": "THE SHELF II", "y_top": -568.699, "bottom": -587.109, "a_mid": 1.540747, "k": 0.2, "thick": 13.1504},
	{"name": "THE SHELF III", "y_top": -830.749, "bottom": -846.431, "a_mid": -1.301455, "k": 0.2, "thick": 11.2017},
	{"name": "THE SHELF IV", "y_top": -1318.876, "bottom": -1335.516, "a_mid": 1.840138, "k": 0.2, "thick": 11.8861},
	{"name": "THE SHELF V", "y_top": -2162.751, "bottom": -2179.529, "a_mid": 4.981731, "k": 0.2, "thick": 11.984},
	{"name": "THE SHELF VI", "y_top": -2990.571, "bottom": -3007.958, "a_mid": 1.840138, "k": 0.2, "thick": 12.4194},
	{"name": "THE SHELF VII", "y_top": -3462.947, "bottom": -3481.453, "a_mid": 4.981731, "k": 0.2, "thick": 13.2191},
	{"name": "THE SHELF VIII", "y_top": -3849.687, "bottom": -3867.732, "a_mid": 8.123323, "k": 0.2, "thick": 12.8888},
]
const FOOTHOLD_OFF_WARN := 30.0

static var _ry := PackedFloat64Array()      # the ported radius table, ascending y
static var _rr := PackedFloat64Array()
static var _sy := PackedFloat64Array()      # wave 2 samples, ascending y (empty = use the port)
static var _scx := PackedFloat64Array()
static var _scz := PackedFloat64Array()
static var _sr := PackedFloat64Array()
static var _terr: Array = []
static var _terr_src := ""
static var _terr_ready := false
static var _used_frame := -1
static var _used_n := -1


static func use_layout(L: Dictionary) -> void:
	# both the omen module and the harriers call this in the same frame: the second call is a no-op
	var stn: Array = L.get("stations", []) if L.get("stations", []) is Array else []
	var frame := Engine.get_process_frames()
	if frame == _used_frame and stn.size() == _used_n:
		return
	_used_frame = frame
	_used_n = stn.size()
	_ensure_port()
	_sy = PackedFloat64Array()
	_scx = PackedFloat64Array()
	_scz = PackedFloat64Array()
	_sr = PackedFloat64Array()
	_terr = []
	_terr_src = ""
	var rift = L.get("rift", null)
	if rift is Dictionary:
		var smp = (rift as Dictionary).get("samples", null)
		if smp is Array and (smp as Array).size() >= 2:
			var rows: Array = []
			for e in smp:
				if (e is Array or e is PackedFloat32Array or e is PackedFloat64Array) and e.size() >= 4:
					rows.append([float(e[0]), float(e[1]), float(e[2]), float(e[3])])
			rows.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
			for r in rows:
				_sy.append(float(r[0]))
				_scx.append(float(r[1]))
				_scz.append(float(r[2]))
				_sr.append(float(r[3]))
			print("[RIFT] axis and radius from layout samples (%d)" % _sy.size())
		var tl = (rift as Dictionary).get("terraces", null)
		if tl is Array and not (tl as Array).is_empty():
			for e in tl:
				if e is Dictionary:
					_terr.append(_norm_terrace(e))
			_terr_src = "layout"
	if _terr_src == "":
		_terraces_from_table(stn)
	_terr_ready = true
	print("[RIFT] terraces %d (%s)" % [_terr.size(), _terr_src])
	_check_footholds(stn)


static func status() -> String:
	if not _terr_ready:
		terraces()
	return _terr_src


static func center(y: float) -> Vector2:
	if _sy.size() >= 2:
		return Vector2(_interp(_sy, _scx, y), _interp(_sy, _scz, y))
	return Vector2(430.0 + 42.0 * sin(y / 470.0 + 1.3) + 16.0 * sin(y / 190.0 + 0.4),
			20.0 + 42.0 * cos(y / 420.0) + 16.0 * sin(y / 230.0 + 2.0))


static func radius(y: float) -> float:
	if _sy.size() >= 2:
		return _interp(_sy, _sr, y)
	_ensure_port()
	return _interp(_ry, _rr, y)


static func void_dir(p: Vector3) -> Vector3:
	var c := center(p.y)
	var d := Vector3(c.x - p.x, 0.0, c.y - p.z)
	var l := d.length()
	if l < 0.001:
		return Vector3.ZERO
	return d / l


static func edge_exposed(space: PhysicsDirectSpaceState3D, p: Vector3, reach: Array = [1.5, 3.0, 4.5]) -> int:
	if space == null:
		return 0
	var vd := void_dir(p)
	if vd == Vector3.ZERO:
		return reach.size()
	var n := 0
	for k in reach:
		var q: Vector3 = p + vd * float(k) + Vector3.UP
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(q, q + Vector3.DOWN * 31.0, 1))
		if hit.is_empty():
			n += 1
	return n


static func terraces() -> Array:
	if not _terr_ready:
		# nobody called use_layout: the table still applies when the installed layout matches
		_ensure_port()
		_terr = []
		_terraces_from_table([])
		_terr_ready = true
	return _terr


static func in_terrace(p: Vector3, margin: float = 8.0) -> bool:
	for t in terraces():
		var yt: float = t["y_top"]
		if p.y >= yt + margin or p.y <= float(t["bottom"]) - margin:
			continue
		if terrace_side(t, p) > -margin:
			return true
	return false


static func terrace_side(t: Dictionary, p: Vector3) -> float:
	var c := center(p.y)
	var a: float = t["a_mid"]
	return (p.x - c.x) * cos(a) + (p.z - c.y) * sin(a) + float(t["k"]) * float(t["R"])


static func open_point(t: Dictionary) -> Vector3:
	var yt: float = t["y_top"]
	var c := center(yt)
	var a: float = t["a_mid"]
	var r: float = float(t["R"]) * 0.6
	return Vector3(c.x - cos(a) * r, yt, c.y - sin(a) * r)


# ------------------------------------------------------------------ internals

static func _ensure_port() -> void:
	if not _ry.is_empty():
		return
	var rows: Array = []
	for e in RADIUS_RAW:
		rows.append([float(e[0]) * Z, float(e[1]) * RW])
	rows.append([float(RADIUS_LAKE[0]), float(RADIUS_LAKE[1])])
	rows.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
	for r in rows:
		_ry.append(float(r[0]))
		_rr.append(float(r[1]))


static func _interp(xs: PackedFloat64Array, ys: PackedFloat64Array, x: float) -> float:
	# numpy.interp: linear inside, clamped to the end values outside
	var n := xs.size()
	if n == 0:
		return 0.0
	if x <= xs[0]:
		return ys[0]
	if x >= xs[n - 1]:
		return ys[n - 1]
	var i := xs.bsearch(x)
	if i <= 0:
		return ys[0]
	var x0 := xs[i - 1]
	var x1 := xs[i]
	var k := 0.0 if x1 - x0 < 1e-9 else (x - x0) / (x1 - x0)
	return lerpf(ys[i - 1], ys[i], k)


static func _norm_terrace(e: Dictionary) -> Dictionary:
	var yt := float(e.get("y_top", 0.0))
	var th := float(e.get("thick", 12.0))
	var t := {"name": str(e.get("name", "")), "y_top": yt, "bottom": float(e.get("bottom", yt - th * 1.4)),
			"a_mid": float(e.get("a_mid", 0.0)), "k": float(e.get("k", 0.2)), "thick": th}
	t["R"] = float(e["R"]) if e.has("R") else radius(yt)
	return t


static func _terraces_from_table(stn: Array) -> void:
	var md5 := FileAccess.get_md5(DIR + "layout.json")
	if md5 != TERRACES_W1_MD5:
		_terr = []
		_terr_src = "none: layout.json md5 %s is not the wave 1 table's and the layout has no rift.terraces" % md5
		push_warning("[RIFT] no terrace data: layout.json md5 %s does not match TERRACES_W1_MD5 and L.rift.terraces is absent. Harriers fly without the slab rule." % md5)
		return
	for e in TERRACES_W1:
		_terr.append(_norm_terrace(e))
	_terr_src = "table, md5 ok"
	if stn.is_empty():
		return
	var bad: Array = []
	for t in _terr:
		var n := 0
		for s in stn:
			if s is Dictionary and str(s.get("kind", "")) == "terrace":
				var sp = s.get("pos", [])
				if sp is Array and (sp as Array).size() >= 3 and absf(float(sp[1]) - float(t["y_top"])) <= 0.5:
					n += 1
		if n < 2:
			bad.append(str(t["name"]))
	if not bad.is_empty():
		_terr_src += ", station check FAILED: " + ", ".join(bad)
		push_warning("[RIFT] terrace table entries without two terrace stations at their y_top: " + ", ".join(bad))


static func _check_footholds(stn: Array) -> void:
	var n := 0
	var off := 0
	var worst := 0.0
	var worst_at := Vector3.ZERO
	for s in stn:
		if not (s is Dictionary):
			continue
		var kind := str(s.get("kind", ""))
		if kind != "foothold" and kind != "shelf":
			continue
		var sp = s.get("pos", [])
		if not (sp is Array) or (sp as Array).size() < 3:
			continue
		var p := Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
		var c := center(p.y)
		var d := absf(Vector2(p.x - c.x, p.z - c.y).length() - radius(p.y))
		n += 1
		if d > FOOTHOLD_OFF_WARN:
			off += 1
		if d > worst:
			worst = d
			worst_at = p
	if off > 0:
		push_warning("[RIFT] %d of %d footholds sit more than %.0f m off the ported radius (worst %.1f m at %s): the port may not match this layout" % [off, n, FOOTHOLD_OFF_WARN, worst, str(worst_at)])
	print("[RIFT] footholds checked %d, worst %.1f m off the radius" % [n, worst])
