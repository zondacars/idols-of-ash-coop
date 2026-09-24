extends RefCounted

# ULTRA HD rock surfaces for THE UNDERDARK (K8). Real CC0 rock photos per biome in ULTRA HD;
# NORMAL PIXELS keeps the game's own Rock / Wall_04 textures exactly as shipped.
#
# API (for the integrators)
#   const LookUltra := preload("res://mods-unpacked/zonda-CoopSync/maps/underdark/look_ultra.gd")
#   var look := LookUltra.new()
#   look.setup(_wall_mat, _floor_mat)   # call ONCE, right after _build_materials(), BEFORE _load_cave():
#                                       # it records the shipped texture settings of every material
#                                       # (gfx.gd has not touched them yet at that point)
#   look.apply(CoopSync.gfx.is_ultra()) # once after setup, then on every gfx.mode_changed(mode)
#   look.ultra                          # read-only: the last value passed to apply()
#
#   apply(true)  gives the SAME material objects (index = biome 0-9) the biome's albedo, normal and
#                roughness (red channel) textures from tex/manifest.json with world triplanar mapping
#                at uv_scale, normal_scale 1.0, anisotropic linear filtering, and switches the game's
#                multiply detail layer off. It never touches albedo_color, so the map's
#                WALL_LIFT / FLOOR_LIFT / BRIGHT_ALB brightness (and F5) keeps working unchanged.
#                Staying under the white clip: each photo is rescaled so its mean linear brightness
#                equals the shipped texture it replaces (walls: Rock.png with its ROck_03 detail =
#                0.125, floors: Wall_04.png with its Shell detail = 0.147, measured offline), so a lit
#                wall lands exactly as bright as it did before; only the surface detail changes.
#                Bone (10) and bark (11) are never touched. A biome with no manifest entry, or whose
#                albedo file is missing, keeps the game's texture (gfx.gd may still add its normals).
#   apply(false) restores the exact recorded textures and settings of every material it dressed,
#                and the texture filter (unless the map's own pixel-filter check changed it since).
#   The first apply(true) decodes and tints the JPEGs (roughly 1 to 2 s for 10 biomes, once, about
#   35 MB of textures); every later F4 toggle only swaps cached textures, so keep the instance in a
#   member var of the map. Missing manifest = apply() does nothing, no errors.
#   gfx.gd interplay: gfx gives the game's Rock / Wall_04 their own normal maps in ULTRA HD, keyed
#   by the albedo texture's file name. A dressed material carries a runtime texture with no file
#   name, so gfx leaves it alone; on F4 back to NORMAL both gfx and this module restore the shipped
#   values, whichever runs first.
#
# tex/manifest.json: {"<biome 0-9>": {"albedo": "dir/file.jpg", "normal": "dir/file.jpg",
#   "rough": "dir/file.jpg", "uv_scale": float, "tint": [r, g, b]}}, paths relative to tex/
#   (a full "res://..." path to a game texture also works). uv_scale = texture repeats per metre
#   (0.25 = one tile every 4 m; default 0.25). tint multiplies the photo's colours (1 = unchanged)
#   before the brightness match, so it shifts hue only. Normal maps must be OpenGL convention (Y+,
#   ambientCG "NormalGL"). Images larger than 512 px are scaled down on load.

const TEX_DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/tex/"
const MANIFEST := TEX_DIR + "manifest.json"
const BIOMES := 10                    # 10 bone and 11 bark keep their look
const MAX_PX := 512
const WALL_TARGET := 0.125            # mean linear luminance of the shipped wall surface (Rock.png x ROck_03 detail at 0.27)
const FLOOR_TARGET := 0.147           # the same for floors (Wall_04.png x Shell_Colorized detail at the noise mask)
const DEFAULT_UV := 0.25
const NORMAL_SCALE := 1.0
const SHARPNESS := 3.0                # triplanar blend: tighter than the game's 1-2 so photo edges do not smear
const ULTRA_FILTER := BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
const FIELDS := ["albedo_texture", "detail_enabled", "normal_enabled", "normal_texture", "normal_scale",
		"roughness_texture", "roughness_texture_channel", "roughness", "uv1_scale", "uv1_triplanar",
		"uv1_world_triplanar", "uv1_triplanar_sharpness"]

var ultra := false
var _walls: Array = []
var _floors: Array = []
var _orig: Dictionary = {}            # material instance id -> {field: shipped value}
var _dressed: Dictionary = {}         # material instance id -> material (currently wearing a photo)
var _filter_from: Dictionary = {}     # material instance id -> texture_filter before ULTRA
var _manifest: Dictionary = {}
var _manifest_read := false
var _img_cache: Dictionary = {}       # "file|tint" -> tinted Image (no mipmaps) or null
var _tex_cache: Dictionary = {}       # key -> Texture2D or null


func setup(wall_mats: Array, floor_mats: Array) -> void:
	_walls = wall_mats
	_floors = floor_mats
	for m in wall_mats + floor_mats:
		var sm := m as StandardMaterial3D
		if sm != null and not _orig.has(sm.get_instance_id()):
			_orig[sm.get_instance_id()] = _snapshot(sm)


func apply(on: bool) -> void:
	ultra = on
	if on:
		_dress_all()
	else:
		_restore_all()


# ------------------------------------------------------------------ ULTRA HD

func _dress_all() -> void:
	_read_manifest()
	if _manifest.is_empty():
		return
	var t0 := Time.get_ticks_msec()
	var done := 0
	for b in BIOMES:
		var e = _manifest.get(str(b))
		if not (e is Dictionary):
			continue
		var entry: Dictionary = e
		var hit := false
		if b < _walls.size():
			var w := _walls[b] as StandardMaterial3D
			if w != null and _dress(w, entry, WALL_TARGET):
				hit = true
		if b < _floors.size():
			var f := _floors[b] as StandardMaterial3D
			if f != null and _dress(f, entry, FLOOR_TARGET):
				hit = true
		if hit:
			done += 1
	print("[Underdark] ULTRA HD rock: %d biomes dressed in %d ms" % [done, Time.get_ticks_msec() - t0])


func _dress(m: StandardMaterial3D, entry: Dictionary, target: float) -> bool:
	var alb := _albedo(str(entry.get("albedo", "")), _tint_of(entry), target)
	if alb == null:
		return false
	var id := m.get_instance_id()
	if not _orig.has(id):
		_orig[id] = _snapshot(m)          # a material setup() never saw
	if not _filter_from.has(id):
		_filter_from[id] = m.texture_filter
	var o: Dictionary = _orig[id]
	m.albedo_texture = alb
	m.detail_enabled = false              # the game's multiply blotches would muddy the photo
	var nrm := _plain(str(entry.get("normal", "")), true)
	m.normal_enabled = nrm != null
	m.normal_texture = nrm
	m.normal_scale = NORMAL_SCALE
	var rgh := _plain(str(entry.get("rough", "")), false)
	m.roughness_texture = rgh
	m.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	m.roughness = 1.0 if rgh != null else float(o.get("roughness", 1.0))
	var s := float(entry.get("uv_scale", DEFAULT_UV))
	if s <= 0.0:
		s = DEFAULT_UV
	m.uv1_scale = Vector3(s, s, s)
	m.uv1_triplanar = true
	m.uv1_world_triplanar = true
	m.uv1_triplanar_sharpness = SHARPNESS
	m.texture_filter = ULTRA_FILTER
	_dressed[id] = m
	return true


# ------------------------------------------------------------------ NORMAL PIXELS

func _restore_all() -> void:
	for id in _dressed.keys():
		var m := _dressed[id] as StandardMaterial3D
		if m == null:
			continue
		if _orig.has(id):
			var o: Dictionary = _orig[id]
			for k in o.keys():
				m.set(k, o[k])
		# the map re-sets the filter only when the "reduced pixelization" setting changes; if it did
		# while ULTRA was on, its new choice stands
		if _filter_from.has(id) and m.texture_filter == ULTRA_FILTER:
			m.texture_filter = _filter_from[id]
	_dressed.clear()
	_filter_from.clear()


func _snapshot(m: StandardMaterial3D) -> Dictionary:
	var d := {}
	for k in FIELDS:
		d[k] = m.get(k)
	# defensive: if gfx.gd already gave this material its runtime normal map (setup called late),
	# record the shipped state instead (the game's Rock / Wall_04 have no normal or roughness map)
	var nt := m.normal_texture
	if m.normal_enabled and nt != null and nt.resource_path == "":
		d["normal_enabled"] = false
		d["normal_texture"] = null
		d["normal_scale"] = 1.0
		d["roughness_texture"] = null
		d["roughness"] = 1.0
	return d


# ------------------------------------------------------------------ textures

func _read_manifest() -> void:
	if _manifest_read:
		return
	_manifest_read = true
	if not FileAccess.file_exists(MANIFEST):
		print("[Underdark] no tex/manifest.json, ULTRA HD keeps the game's rock")
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
	if parsed is Dictionary:
		_manifest = parsed
	else:
		push_warning("[Underdark] tex/manifest.json unreadable")


func _tint_of(entry: Dictionary) -> Color:
	var t = entry.get("tint")
	if t is Array:
		var a: Array = t
		if a.size() >= 3:
			return Color(float(a[0]), float(a[1]), float(a[2]))
	return Color(1, 1, 1)


func _load_image(rel: String) -> Image:
	if rel.is_empty():
		return null
	var img: Image = null
	if rel.begins_with("res://") and not rel.begins_with(TEX_DIR) and ResourceLoader.exists(rel):
		var res = load(rel)                   # a game texture (imported, so load() works)
		if res is Texture2D:
			img = (res as Texture2D).get_image()
			if img != null and img.is_compressed() and img.decompress() != OK:
				img = null
	else:
		var path := rel if rel.begins_with("res://") else TEX_DIR + rel
		var bytes := FileAccess.get_file_as_bytes(path)
		if bytes.is_empty():
			push_warning("[Underdark] ULTRA texture missing: " + path)
			return null
		img = Image.new()
		var ext := path.get_extension().to_lower()
		var err := ERR_FILE_UNRECOGNIZED
		if ext == "png":
			err = img.load_png_from_buffer(bytes)
		elif ext == "webp":
			err = img.load_webp_from_buffer(bytes)
		else:
			err = img.load_jpg_from_buffer(bytes)
		if err != OK:
			push_warning("[Underdark] ULTRA texture unreadable: " + path)
			return null
	if img == null or img.is_empty():
		return null
	if img.has_mipmaps():
		img.clear_mipmaps()
	var w := img.get_width()
	var h := img.get_height()
	if w > MAX_PX or h > MAX_PX:
		var k := float(MAX_PX) / float(maxi(w, h))
		img.resize(maxi(1, int(w * k)), maxi(1, int(h * k)), Image.INTERPOLATE_LANCZOS)
	return img


func _tinted_base(rel: String, tint: Color) -> Image:
	var key := "%s|%.3f|%.3f|%.3f" % [rel, tint.r, tint.g, tint.b]
	if _img_cache.has(key):
		return _img_cache[key] as Image
	var img := _load_image(rel)
	if img != null:
		if img.get_format() != Image.FORMAT_RGB8:
			img.convert(Image.FORMAT_RGB8)
		if absf(tint.r - 1.0) > 0.01 or absf(tint.g - 1.0) > 0.01 or absf(tint.b - 1.0) > 0.01:
			_apply_tint(img, tint)
	_img_cache[key] = img
	return img


func _apply_tint(img: Image, t: Color) -> void:
	var lr := PackedByteArray()
	var lg := PackedByteArray()
	var lb := PackedByteArray()
	lr.resize(256)
	lg.resize(256)
	lb.resize(256)
	for v in 256:
		lr[v] = clampi(int(round(v * t.r)), 0, 255)
		lg[v] = clampi(int(round(v * t.g)), 0, 255)
		lb[v] = clampi(int(round(v * t.b)), 0, 255)
	var d := img.get_data()
	var n := d.size() - 2
	var i := 0
	while i < n:
		d[i] = lr[d[i]]
		d[i + 1] = lg[d[i + 1]]
		d[i + 2] = lb[d[i + 2]]
		i += 3
	img.set_data(img.get_width(), img.get_height(), false, Image.FORMAT_RGB8, d)


# sRGB gain that brings the image's mean linear luminance to `target` (4096 point samples)
func _gain(img: Image, target: float) -> float:
	var s := Image.new()
	s.copy_from(img)
	s.resize(64, 64, Image.INTERPOLATE_NEAREST)
	var sum := 0.0
	for y in 64:
		for x in 64:
			var c := s.get_pixel(x, y).srgb_to_linear()
			sum += c.r * 0.2126 + c.g * 0.7152 + c.b * 0.0722
	var mean := sum / 4096.0
	if mean < 0.002:
		return 1.0
	return clampf(pow(target / mean, 1.0 / 2.2), 0.3, 2.5)


func _albedo(rel: String, tint: Color, target: float) -> Texture2D:
	if rel.is_empty():
		return null
	var key := "a|%s|%.3f|%.3f|%.3f|%.3f" % [rel, tint.r, tint.g, tint.b, target]
	if _tex_cache.has(key):
		return _tex_cache[key] as Texture2D
	var tex: Texture2D = null
	var base := _tinted_base(rel, tint)
	if base != null:
		var img := Image.new()
		img.copy_from(base)
		var g := _gain(base, target)
		if absf(g - 1.0) > 0.005:
			img.adjust_bcs(g, 1.0, 1.0)
		img.generate_mipmaps()
		tex = ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex


func _plain(rel: String, is_normal: bool) -> Texture2D:
	if rel.is_empty():
		return null
	var key := ("n|" if is_normal else "r|") + rel
	if _tex_cache.has(key):
		return _tex_cache[key] as Texture2D
	var tex: Texture2D = null
	var img := _load_image(rel)
	if img != null:
		if is_normal:
			if img.get_format() != Image.FORMAT_RGB8:
				img.convert(Image.FORMAT_RGB8)
			img.generate_mipmaps(true)        # renormalise each mip
		else:
			img.convert(Image.FORMAT_L8)      # grey roughness; the shader reads the red channel
			img.generate_mipmaps()
		tex = ImageTexture.create_from_image(img)
	_tex_cache[key] = tex
	return tex
