extends RefCounted
# ============================================================================================
# THE UNDERDARK: new creatures (ZondaCoopSync v4.9)
#
#   const Creatures := preload("res://mods-unpacked/zonda-CoopSync/maps/underdark/creatures.gd")
#
# Every creature node is top_level and works in WORLD coordinates (layout coords), so add it as
# a child of the map. Call setup(...) BEFORE add_child(...). The brain runs only where
# CoopSync.map_is_authority() is true; everyone else follows remote_state(). Stream each
# creature's state_packet() in the map's ~10 Hz authority stream and feed it back to
# remote_state() on the guests. Every attack telegraphs (a click or hiss 0.6-1.0 s before, and a
# visible wind-up). Sounds play on bus "ZondaCave" when that bus exists, else "MainBus".
#
# ---- Creatures.Brood (Node3D) ------------------------------------------------------------
#   setup({"points": [[x,y,z], ...], "count": int}, map)   points = egg positions (L["eggs"][i]["pos"])
#   hatch()                      start the hatching (10-16 crawlers over ~3 s). Call it when the idol
#                                is taken LIVE (not on a replay). Guests may call it too; they also
#                                hatch by themselves on the first stream packet that says so.
#   is_hatched() -> bool
#   clear()                      every crawler dies at once (finish, session end)
#   state_packet() -> Array      [hatched, then per crawler x, y, z, yaw, state]
#   remote_state(a: Array)
#   threat_positions() -> Array  positions of the living crawlers (for the heartbeat)
#   bite_origin(id) -> Vector3   where a bite with that id comes from
#   play_bite(id)                guests: shows/plays that crawler's nip (the host already did)
#   signal bit(who: Node3D, damage: float, id: String)   authority only; id = "brood:<i>", damage 8
#
# ---- Creatures.WallSpider (Node3D) -------------------------------------------------------
#   setup(entry of L["spiders"], map)   {"id","anchor":[x,y,z],"floor":[x,y,z],"biome"}
#   state_packet() -> Array      [state, y]
#   remote_state(a: Array)
#   threat_positions() -> Array  its body while it clicks, drops, hangs or climbs back
#   bite_origin(id) -> Vector3 / play_bite(id)
#   signal bit(who: Node3D, damage: float, id: String)   authority only; id = the spider id, damage 18
#
# ---- Creatures.WakingHusk (Node3D) -------------------------------------------------------
#   setup(L["waking_husk"], map)  {"id","trigger":[x,y,z],"r","head":[x,y,z],"yaw"}
#   attach_props(nodes: Array)   optional: the husk's prop nodes (layout props with "husk_id"),
#                                they shiver for 1.5 s before it wakes (nothing is hidden here)
#   set_woken()                  quiet end state (replay / reload after it woke): no sound, no signal
#   state_packet() -> Array      [phase]  0 asleep, 1 shivering, 2 awake
#   remote_state(a: Array)
#   threat_positions() -> Array  its head and the body beside the trigger while it shivers
#   signal wake(pos: Vector3, yaw: float)   AUTHORITY only, when the shiver ends: spawn the real
#                                           pale centipede there (the map's normal spawn path)
#   signal woke()                           EVERY machine, when the shiver ends: hide the husk props
#
# ---- Helpers (static, on the script) ------------------------------------------------------
#   Creatures.bite_local(from: Vector3, damage: float, heavy: bool)
#       applies a bite to THIS player (Game.climber): take_damage(damage) (the game halves it),
#       a tiny horizontal shove away from `from` (about 0.3-0.45 m of drift, never upward) and
#       the hurt sound. heavy = true for the spider (bite sound on top), false for a brood nip.
#   Creatures.is_spider_id(id) -> bool
#
# Models: maps/underdark/ext/mon/manifest.json {"spider": {"file","anims":{idle,walk,attack,death},
# "height_m", optional "yaw_deg" (default 180: glTF faces +Z)}, "crawler": {...}}, loaded from bytes
# with GLTFDocument (AnimationPlayer kept and driven by state). Missing or {} = the game's own
# Monster_Head_Redesign / Monster_BodySection_Redesign tinted pale and scaled down (the spider gets
# eight procedural legs). All creature meshes: no emission, no lights, no particles.
# ============================================================================================


static func bite_local(from: Vector3, damage: float, heavy: bool = false) -> void:
	Kit.bite_local(from, damage, heavy)


static func is_spider_id(id: String) -> bool:
	return not id.begins_with("brood:")


# ============================================================================ shared kit

class Kit:
	const DIR := "res://mods-unpacked/zonda-CoopSync/maps/underdark/"
	const CLICKS := ["res://sfx/soundsnap/creature_footsteps/243425-metal_hit_small-carpet_knife01.wav",
			"res://sfx/soundsnap/creature_footsteps/243426-metal_hit_small-carpet_knife02.wav",
			"res://sfx/soundsnap/creature_footsteps/243427-metal_hit_small-carpet_knife03.wav",
			"res://sfx/soundsnap/creature_footsteps/243428-metal_hit_small-carpet_knife04.wav",
			"res://sfx/soundsnap/creature_footsteps/243430-metal_hit_small-carpet_knife06.wav",
			"res://sfx/soundsnap/creature_footsteps/243431-metal_hit_small-carpet_knife07.wav",
			"res://sfx/soundsnap/creature_footsteps/243432-metal_hit_small-carpet_knife08.wav",
			"res://sfx/soundsnap/creature_footsteps/243434-metal_hit_small-carpet_knife10.wav"]
	const TEETH := ["res://sfx/MonsterIdeas/Teeth_01.wav", "res://sfx/MonsterIdeas/Teeth_02.wav",
			"res://sfx/MonsterIdeas/Teeth_03.wav", "res://sfx/MonsterIdeas/Teeth_04.wav"]
	const CHOMP := ["res://sfx/MonsterIdeas/Chomp_01.wav", "res://sfx/MonsterIdeas/Chomp_02.wav",
			"res://sfx/MonsterIdeas/Chomp_03.wav", "res://sfx/MonsterIdeas/Chomp_04.wav",
			"res://sfx/MonsterIdeas/Chomp_05.wav"]
	const SNARL := ["res://sfx/soundsnap/monster_attack/306010-Creature-Oxbow-Snarls-Breaths-Aggressive_1.wav",
			"res://sfx/soundsnap/monster_attack/306011-Creature-Oxbow-Snarls-Breaths-Aggressive_2.wav",
			"res://sfx/soundsnap/monster_attack/306013-Creature-Oxbow-Snarls-Breaths-Aggressive_4.wav",
			"res://sfx/soundsnap/monster_attack/306014-Creature-Oxbow-Snarls-Breaths-Aggressive_5.wav"]
	const SILK := "res://sfx/soundsnap/244895-rope_slide_through_pulley-03.wav"
	const SCRAPE := "res://sfx/soundsnap/478116-METLMvmt-Vice_Grip_Large_Aluminium_Scrap_Screw_Drag_05-SSPRK-GgtPrps.wav"
	const RATTLE := "res://sfx/MonsterIdeas/Rattle_Search_Sound.wav"
	const HEAD := "res://Art/Monster_Head_Redesign.glb"
	const SEG := "res://Art/Monster_BodySection_Redesign.glb"
	const ANIM_KEYS := {"idle": ["idle"], "walk": ["walk", "run", "crawl", "move"],
			"attack": ["attack", "bite", "punch", "hit"], "death": ["death", "die", "dead"]}

	static var _streams: Dictionary = {}
	static var _models: Dictionary = {}
	static var _sfx_man: Dictionary = {}
	static var _sfx_read := false
	static var _mon_man: Dictionary = {}
	static var _mon_read := false

	static func v(a) -> Vector3:
		if a is Vector3:
			return a
		if (a is Array or a is PackedFloat32Array or a is PackedFloat64Array) and a.size() >= 3:
			return Vector3(float(a[0]), float(a[1]), float(a[2]))
		return Vector3.ZERO

	static func bus() -> StringName:
		if AudioServer.get_bus_index("ZondaCave") >= 0:
			return &"ZondaCave"
		if AudioServer.get_bus_index("MainBus") >= 0:
			return &"MainBus"
		return &"Master"

	static func listener(n: Node) -> Vector3:
		var vp := n.get_viewport()
		if vp != null:
			var cam := vp.get_camera_3d()
			if cam != null and cam.is_inside_tree():
				return cam.global_position
		return Vector3(1e9, 1e9, 1e9)

	static func ray(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3, back: bool) -> Dictionary:
		var q := PhysicsRayQueryParameters3D.create(a, b, 1)
		q.hit_back_faces = back
		return space.intersect_ray(q)

	static func _read_json(path: String) -> Dictionary:
		if not FileAccess.file_exists(path):
			return {}
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(parsed) == TYPE_DICTIONARY:
			return parsed
		return {}

	# ------------------------------------------------------------------ sound

	static func game_stream(path: String) -> AudioStream:
		if _streams.has(path):
			return _streams[path]
		var s: AudioStream = null
		if ResourceLoader.exists(path):
			s = load(path) as AudioStream
		_streams[path] = s
		return s

	static func file_stream(file: String) -> AudioStream:
		# a manifest entry: a full res://sfx/... game path, or a file under maps/underdark/sfx/
		if file.begins_with("res://sfx/") or file.begins_with("res://Art/"):
			return game_stream(file)
		var path := file if file.begins_with("res://") else DIR + "sfx/" + file
		if _streams.has(path):
			return _streams[path]
		var s: AudioStream = null
		if FileAccess.file_exists(path):
			var bytes := FileAccess.get_file_as_bytes(path)
			var ext := path.get_extension().to_lower()
			if not bytes.is_empty():
				if ext == "ogg":
					s = AudioStreamOggVorbis.load_from_buffer(bytes)
				elif ext == "wav":
					s = AudioStreamWAV.load_from_buffer(bytes)
				elif ext == "mp3":
					var m := AudioStreamMP3.new()
					m.data = bytes
					s = m
		_streams[path] = s
		return s

	static func rand_stream(key: String, paths: Array, pitch_rand: float) -> AudioStream:
		if _streams.has(key):
			return _streams[key]
		var r := AudioStreamRandomizer.new()
		r.random_pitch = pitch_rand
		var n := 0
		for p in paths:
			var s := game_stream(str(p))
			if s != null:
				r.add_stream(-1, s)
				n += 1
		var out: AudioStream = null
		if n > 0:
			out = r
		_streams[key] = out
		return out

	static func oneshot(kind: String) -> Array:
		# [AudioStream or null, db] from the sfx manifest's "oneshots"
		var key := "oneshot:" + kind
		if _streams.has(key):
			return _streams[key]
		if not _sfx_read:
			_sfx_read = true
			_sfx_man = _read_json(DIR + "sfx/manifest.json")
		var out: Array = [null, 0.0]
		var ones = _sfx_man.get("oneshots", {})
		if typeof(ones) == TYPE_DICTIONARY:
			var list = ones.get(kind, [])
			if typeof(list) == TYPE_ARRAY:
				var r := AudioStreamRandomizer.new()
				r.random_pitch = 1.08
				var n := 0
				var db_sum := 0.0
				for e in list:
					if typeof(e) != TYPE_DICTIONARY:
						continue
					var s := file_stream(str(e.get("file", "")))
					if s == null:
						continue
					r.add_stream(-1, s)
					db_sum += float(e.get("db", 0.0))
					n += 1
				if n > 0:
					out = [r, db_sum / float(n)]
		_streams[key] = out
		return out

	static func player(parent: Node, db: float, max_dist: float) -> AudioStreamPlayer3D:
		var p := AudioStreamPlayer3D.new()
		p.volume_db = db
		p.max_distance = max_dist
		p.unit_size = 6.0
		p.bus = bus()
		parent.add_child(p)
		return p

	static func play(p: AudioStreamPlayer3D, stream: AudioStream, db: float, pitch: float) -> void:
		if p == null or stream == null or not p.is_inside_tree():
			return
		p.stream = stream
		p.volume_db = db
		p.pitch_scale = pitch
		p.bus = bus()                  # the cave bus may have been created after we were
		p.play()

	# ------------------------------------------------------------------ bites

	static func bite_local(from: Vector3, damage: float, heavy: bool) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		if c.get("coop_spectating"):
			return
		c.take_damage(damage)            # the game halves it and plays its own small hurt sound
		var away: Vector3 = c.global_position - from
		away.y = 0.0                     # a nudge, never a lift: nobody is thrown off a ledge
		if away.length() > 0.05:
			# the climber re-adds this every physics frame, decaying x0.96 (climber.gd), so the
			# total drift is about 25x the number / physics rate: 1.2 -> ~0.45 m, 0.8 -> ~0.3 m
			c.additional_velocity_next_frame += away.normalized() * (1.2 if heavy else 0.8)
		if heavy and Game.audio:
			Game.audio.play_player_was_bit()

	# ------------------------------------------------------------------ models

	static func _mon_template(kind: String) -> Array:
		# [PackedScene or null, manifest entry]
		var key := "mon:" + kind
		if _models.has(key):
			return _models[key]
		var out: Array = [null, {}]
		_models[key] = out
		if not _mon_read:
			_mon_read = true
			_mon_man = _read_json(DIR + "ext/mon/manifest.json")
		var e = _mon_man.get(kind, null)
		if typeof(e) != TYPE_DICTIONARY:
			return out
		out[1] = e
		var file := str(e.get("file", ""))
		if file == "":
			return out
		var path := file if file.begins_with("res://") else DIR + "ext/mon/" + file
		if not FileAccess.file_exists(path):
			push_warning("[Underdark] creature model missing: " + path)
			return out
		var bytes := FileAccess.get_file_as_bytes(path)
		var doc := GLTFDocument.new()
		var state := GLTFState.new()
		if bytes.is_empty() or doc.append_from_buffer(bytes, "", state) != OK:
			push_warning("[Underdark] creature model unreadable: " + path)
			return out
		var root: Node = doc.generate_scene(state)
		if root == null:
			return out
		_convert_importer_meshes(root)
		_own_all(root, root)
		var ps := PackedScene.new()
		if ps.pack(root) == OK:
			out[0] = ps
		root.free()
		return out

	static func _convert_importer_meshes(root: Node) -> void:
		# runtime glTF can hand back ImporterMeshInstance3D: swap each for a real MeshInstance3D
		# that keeps its skin and skeleton, so the AnimationPlayer still drives it
		for n in root.find_children("*", "ImporterMeshInstance3D", true, false):
			var src := n as ImporterMeshInstance3D
			var par := src.get_parent()
			if par == null:
				continue
			var mi := MeshInstance3D.new()
			mi.transform = src.transform
			if src.mesh != null:
				mi.mesh = src.mesh.get_mesh()
			mi.skin = src.skin
			mi.skeleton = src.skeleton_path
			var nm := src.name
			var idx := src.get_index()
			par.remove_child(src)
			par.add_child(mi)
			par.move_child(mi, idx)
			mi.name = nm
			for ch in src.get_children():
				src.remove_child(ch)
				mi.add_child(ch)
			src.free()

	static func _own_all(n: Node, root: Node) -> void:
		for ch in n.get_children():
			if ch != root:
				ch.owner = root
			_own_all(ch, root)

	static func local_aabb(root: Node3D) -> AABB:
		var box := AABB()
		var first := true
		for n in root.find_children("*", "MeshInstance3D", true, false):
			var m := n as MeshInstance3D
			if m.mesh == null:
				continue
			var xf := Transform3D.IDENTITY
			var node: Node = m
			while node != null and node != root:
				if node is Node3D:
					xf = (node as Node3D).transform * xf
				node = node.get_parent()
			var b: AABB = xf * m.mesh.get_aabb()
			if first:
				box = b
				first = false
			else:
				box = box.merge(b)
		return box

	static func _wrap(n: Node3D) -> Node3D:
		# a parent that holds n with its own root transform, so local_aabb() sees that transform too
		var w := Node3D.new()
		w.add_child(n)
		return w

	static func _resolve(anim: AnimationPlayer, want: String, keys: Array) -> String:
		var list := anim.get_animation_list()
		if want != "" and anim.has_animation(want):
			return want
		var cands: Array = []
		if want != "":
			cands.append(want.to_lower())
		cands.append_array(keys)
		for c in cands:
			for n in list:
				var low := String(n).to_lower()
				if low == str(c) or low.ends_with("|" + str(c)) or low.ends_with("/" + str(c)):
					return String(n)
		for c in cands:
			for n in list:
				if String(n).to_lower().contains(str(c)):
					return String(n)
		return ""

	static func _paint(n: Node, mat: Material) -> void:
		for g in n.find_children("*", "MeshInstance3D", true, false):
			(g as MeshInstance3D).material_override = mat

	static func _cheap(n: Node) -> void:
		for g in n.find_children("*", "GeometryInstance3D", true, false):
			var gi := g as GeometryInstance3D
			gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			gi.visibility_range_end = 100.0
			gi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

	static func make_rig(kind: String, def_height: float, tint: Color) -> Rig:
		var rig := Rig.new()
		var fit := Node3D.new()
		rig.root = fit
		var mat := StandardMaterial3D.new()
		mat.albedo_color = tint              # dim and matte: stays well under the post clip
		mat.roughness = 0.92
		mat.metallic_specular = 0.15
		var tm := _mon_template(kind)
		var ps: PackedScene = tm[0]
		var e: Dictionary = tm[1]
		if ps != null:
			var inst := ps.instantiate() as Node3D
			if inst != null:
				var h := float(e.get("height_m", def_height))
				if h <= 0.01:
					h = def_height
				var w := _wrap(inst)
				var box := local_aabb(w)
				var s := 1.0
				if box.size.y > 0.0001:
					s = clampf(h / box.size.y, 0.0005, 2000.0)
				var ctr := box.get_center()
				w.position = Vector3(-ctr.x, -box.position.y, -ctr.z)
				fit.scale = Vector3.ONE * s
				fit.rotation.y = deg_to_rad(float(e.get("yaw_deg", 180.0)))
				fit.add_child(w)
				_paint(inst, mat)
				var aps := inst.find_children("*", "AnimationPlayer", true, false)
				if not aps.is_empty():
					rig.anim = aps[0] as AnimationPlayer
					var wa = e.get("anims", {})
					var want: Dictionary = wa if typeof(wa) == TYPE_DICTIONARY else {}
					for st in ["idle", "walk", "attack", "death"]:
						var nm := _resolve(rig.anim, str(want.get(st, "")), ANIM_KEYS[st])
						rig.names[st] = nm
						if nm != "" and (st == "idle" or st == "walk"):
							var an := rig.anim.get_animation(nm)
							if an != null:
								an.loop_mode = Animation.LOOP_LINEAR
				_cheap(fit)
				return rig
		rig.fallback = true
		if kind == "spider":
			_fallback_spider(rig, def_height, mat)
		else:
			_fallback_crawler(rig, def_height, mat)
		_cheap(fit)
		return rig

	static func _scene(path: String) -> PackedScene:
		if ResourceLoader.exists(path):
			return load(path) as PackedScene
		return null

	static func _fallback_crawler(rig: Rig, h: float, mat: Material) -> void:
		# the game's own centipede head and two body sections, pale and knee high
		var hps := _scene(HEAD)
		var sps := _scene(SEG)
		var hold := Node3D.new()
		rig.root.add_child(hold)
		if hps == null:
			var cm := CapsuleMesh.new()
			cm.radius = h * 0.4
			cm.height = h * 2.2
			var body := MeshInstance3D.new()
			body.mesh = cm
			body.rotation.x = PI * 0.5
			body.position = Vector3(0, h * 0.45, 0)
			hold.add_child(body)
			_paint(hold, mat)
			return
		var head := _wrap(hps.instantiate() as Node3D)
		var hb := local_aabb(head)
		var s := h / maxf(hb.size.y, 0.01)
		hold.scale = Vector3.ONE * s
		var hc := hb.get_center()
		head.position = Vector3(-hc.x, -hb.position.y, -hc.z)
		hold.add_child(head)
		var z := hb.size.z * 0.45
		if sps != null:
			for i in 2:
				var sg := _wrap(sps.instantiate() as Node3D)
				var sb := local_aabb(sg)
				var k := 0.8 - 0.14 * float(i)
				var piv := Node3D.new()
				z += sb.size.z * k * 0.45
				piv.position = Vector3(0, 0, z)
				hold.add_child(piv)
				var sc := sb.get_center()
				sg.scale = Vector3.ONE * k
				sg.position = Vector3(-sc.x * k, -sb.position.y * k, -sc.z * k)
				piv.add_child(sg)
				z += sb.size.z * k * 0.4
				rig.segs.append(piv)
		_paint(hold, mat)

	static func _fallback_spider(rig: Rig, h: float, mat: Material) -> void:
		# the centipede head as the body, eight jointed legs (two capsules each)
		var hold := Node3D.new()
		rig.root.add_child(hold)
		var hps := _scene(HEAD)
		if hps != null:
			var head := _wrap(hps.instantiate() as Node3D)
			var hb := local_aabb(head)
			var s := (h * 0.55) / maxf(hb.size.y, 0.01)
			var holder := Node3D.new()
			holder.scale = Vector3.ONE * s
			holder.position = Vector3(0, h * 0.3, 0)
			var hc := hb.get_center()
			head.position = Vector3(-hc.x, -hb.position.y, -hc.z)
			holder.add_child(head)
			hold.add_child(holder)
		else:
			var sm := SphereMesh.new()
			sm.radius = h * 0.35
			sm.height = h * 0.6
			var b := MeshInstance3D.new()
			b.mesh = sm
			b.position = Vector3(0, h * 0.55, 0)
			hold.add_child(b)
		var l1 := h * 0.95
		var l2 := h * 1.15
		var cap1 := CapsuleMesh.new()
		cap1.radius = h * 0.04
		cap1.height = l1
		cap1.radial_segments = 6
		cap1.rings = 1
		var cap2 := CapsuleMesh.new()
		cap2.radius = h * 0.032
		cap2.height = l2
		cap2.radial_segments = 6
		cap2.rings = 1
		for side in [1.0, -1.0]:
			for j in 4:
				var f := float(j) / 3.0
				var spread := lerpf(0.65, -0.75, f)      # front legs reach forward (-Z), back legs back
				var hinge := Node3D.new()
				hinge.position = Vector3(side * h * 0.2, h * 0.62, lerpf(-h * 0.28, h * 0.3, f))
				hinge.rotation.y = spread if side > 0.0 else PI - spread
				hold.add_child(hinge)
				var upper := Node3D.new()
				upper.rotation.z = 0.55
				hinge.add_child(upper)
				var m1 := MeshInstance3D.new()
				m1.mesh = cap1
				m1.rotation.z = -PI * 0.5
				m1.position = Vector3(l1 * 0.5, 0, 0)
				upper.add_child(m1)
				var knee := Node3D.new()
				knee.position = Vector3(l1, 0, 0)
				knee.rotation.z = -1.85
				upper.add_child(knee)
				var m2 := MeshInstance3D.new()
				m2.mesh = cap2
				m2.rotation.z = -PI * 0.5
				m2.position = Vector3(l2 * 0.5, 0, 0)
				knee.add_child(m2)
				rig.legs.append(upper)
		_paint(hold, mat)


class Rig extends RefCounted:
	var root: Node3D                  # put this under the creature's pose node
	var anim: AnimationPlayer = null
	var names: Dictionary = {}        # idle/walk/attack/death -> animation name ("" = none)
	var cur := ""
	var segs: Array = []              # fallback crawler: body-section pivots (procedural sway)
	var legs: Array = []              # fallback spider: upper-leg pivots (procedural gait)
	var fallback := false

	func play(state: String, blend: float = 0.18) -> void:
		if anim == null:
			return
		var n := str(names.get(state, ""))
		if n == "" and state != "idle":
			n = str(names.get("idle", ""))
		if n == "" or n == cur:
			return
		cur = n
		anim.play(n, blend)

	func set_speed(k: float) -> void:
		if anim != null:
			anim.speed_scale = k

	func set_active(on: bool) -> void:
		if anim != null and anim.active != on:
			anim.active = on


# ============================================================================ the brood

class Crawler extends Node3D:
	# one hatchling: the Brood thinks for it, this only shows it and makes its noises
	const UNBORN := -1
	const WALK := 0
	const WIND := 1
	const NIP := 2
	const DEAD := 3

	var rig: Rig
	var pose: Node3D
	var sim := Vector3.ZERO          # where the brain (or the stream) says it is
	var yaw := 0.0
	var st := UNBORN
	var egg := Vector3.ZERO
	var hatch_at := 0.0
	var speed := 7.4
	var age := 0.0
	var cd := 0.0
	var wind := 0.0
	var nip_t := 0.0
	var dead_t := 0.0
	var vis_t := 0.0
	var step_t := 0.0
	var wob := 0.0
	var moving := false
	var sfx_step: AudioStreamPlayer3D
	var sfx_voice: AudioStreamPlayer3D

	func build() -> void:
		pose = Node3D.new()
		add_child(pose)
		rig = Kit.make_rig("crawler", 0.5, Color(0.36, 0.34, 0.29))
		pose.add_child(rig.root)
		sfx_step = Kit.player(self, 0.0, 26.0)
		sfx_step.max_polyphony = 2
		sfx_voice = Kit.player(self, 0.0, 34.0)
		wob = randf() * TAU
		visible = false

	func be_born(at: Vector3) -> void:
		if st != UNBORN:
			return
		st = WALK
		sim = at
		position = at + Vector3.DOWN * 0.35
		rotation.y = yaw
		vis_t = 0.0
		visible = true
		# the egg splits: a wet crunch and a scatter of claws
		Kit.play(sfx_voice, Kit.rand_stream("teeth", Kit.TEETH, 1.2), -4.0, 1.35)
		_step_sound(0.0)

	func alive() -> bool:
		return st == WALK or st == WIND or st == NIP

	func set_state(s: int) -> void:
		if s == st or st == UNBORN:
			return
		if st == DEAD:
			return                      # nothing comes back
		st = s
		if s == WIND:
			# the telegraph: a thin hiss and a rattle of claws, 0.6-0.9 s before the nip
			Kit.play(sfx_voice, Kit.rand_stream("snarl", Kit.SNARL, 1.15), -3.0, 1.9)
			_step_sound(2.0)
		elif s == NIP:
			Kit.play(sfx_voice, Kit.rand_stream("chomp", Kit.CHOMP, 1.2), 0.0, 1.45)
		elif s == DEAD:
			dead_t = 0.0
			Kit.play(sfx_voice, Kit.rand_stream("snarl", Kit.SNARL, 1.15), -9.0, 2.3)

	func _step_sound(extra_db: float) -> void:
		var os := Kit.oneshot("brood_skitter")
		var s: AudioStream = os[0]
		if s != null:
			Kit.play(sfx_step, s, float(os[1]) - 2.0 + extra_db, randf_range(0.95, 1.2))
		else:
			Kit.play(sfx_step, Kit.rand_stream("clicks", Kit.CLICKS, 1.25), -5.0 + extra_db, randf_range(1.5, 1.9))

	func skitter() -> void:
		_step_sound(0.0)

	func visual(delta: float) -> void:
		if st == UNBORN:
			return
		vis_t = minf(1.0, vis_t + delta * 2.2)
		var prev := position
		if st != DEAD:
			position = position.lerp(sim, clampf(delta * 10.0, 0.0, 1.0))
			rotation.y = lerp_angle(rotation.y, yaw, clampf(delta * 12.0, 0.0, 1.0))
		moving = (position - prev).length() > delta * 0.8
		wob += delta * (16.0 if moving else 3.0)
		var tilt := 0.0
		var roll := 0.0
		var fwd := 0.0
		var lift := 0.0
		if st == WIND:
			tilt = 0.55 + sin(wob * 3.0) * 0.06          # reared up and trembling: the wind-up
			lift = 0.08
		elif st == NIP:
			tilt = -0.25
			fwd = -0.35                                  # the lunge
		elif st == DEAD:
			dead_t += delta
			roll = minf(1.0, dead_t * 2.0) * PI * 0.85
			if dead_t > 0.8:
				position.y -= delta * 0.5
			if dead_t > 1.8:
				visible = false
		elif moving:
			tilt = sin(wob) * 0.05
			lift = absf(sin(wob)) * 0.03
		pose.rotation.x = lerpf(pose.rotation.x, tilt, clampf(delta * 14.0, 0.0, 1.0))
		pose.rotation.z = roll
		pose.position = pose.position.lerp(Vector3(0, lift, fwd), clampf(delta * 14.0, 0.0, 1.0))
		pose.scale = Vector3.ONE * lerpf(0.3, 1.0, vis_t)
		if rig.fallback:
			for i in rig.segs.size():
				var sg: Node3D = rig.segs[i]
				sg.rotation.y = sin(wob - float(i + 1) * 0.9) * (0.35 if moving else 0.08)
		elif st == DEAD:
			rig.play("death", 0.1)
		elif st == WIND or st == NIP:
			rig.play("attack", 0.1)
		elif moving:
			rig.play("walk")
			rig.set_speed(clampf(speed / 5.0, 0.8, 2.2))
		else:
			rig.play("idle")
			rig.set_speed(1.0)


class Brood extends Node3D:
	# When the idol is taken the Nest's eggs split and knee-high crawlers pour out, chasing the
	# nearest living player toward the exit. They nip (small damage, a tiny nudge), never climb
	# after you and never walk off an edge. The authority thinks at 12 Hz and streams them.
	signal bit(who: Node3D, damage: float, id: String)

	const NIP_DAMAGE := 8.0
	const LIFE := 70.0
	const LEASH := 90.0
	const BRAIN_DT := 1.0 / 12.0
	const HATCH_SPAN := 3.0
	const PER_TARGET_GAP := 0.8          # one nip per player per 0.8 s, however many are on them
	const MAX_WINDING := 3               # at most three rear up on the same player at once

	var map: Node3D
	var points: Array = []
	var count := 13
	var crawlers: Array = []
	var hatched := false
	var clock := 0.0
	var _brain_t := 0.0
	var _last_nip: Dictionary = {}
	var _skit_window := 0.0
	var _skit_budget := 0
	var _done_t := 0.0
	var _rx_ms := 0                      # guests: when the host's last brood packet arrived
	var _stale := false                  # guests: the host stopped streaming, the brood is hidden

	func setup(data: Dictionary, m: Node3D) -> void:
		map = m
		top_level = true
		points.clear()
		for p in data.get("points", []):
			var q = p
			if typeof(q) == TYPE_DICTIONARY:
				q = q.get("pos", null)
			if q is Vector3 or (q is Array and q.size() >= 3):
				points.append(Kit.v(q))
		count = clampi(int(data.get("count", 13)), 10, 16)

	func is_hatched() -> bool:
		return hatched

	func hatch() -> void:
		if hatched or points.is_empty() or not is_inside_tree():
			return
		hatched = true
		clock = 0.0
		_rx_ms = Time.get_ticks_msec()
		# the same layout on every machine: eggs spread evenly over the clusters
		var rng := RandomNumberGenerator.new()
		rng.seed = 7331
		for i in count:
			var c := Crawler.new()
			var pi := int(float(i) * float(points.size()) / float(count)) % points.size()
			var egg: Vector3 = points[pi]
			var a := rng.randf() * TAU
			var r := rng.randf_range(0.2, 0.8)
			c.egg = egg + Vector3(cos(a) * r, 0.0, sin(a) * r)
			c.hatch_at = HATCH_SPAN * float(i) / float(count)
			c.speed = rng.randf_range(6.6, 8.2)          # a running knight (10 m/s) outpaces them
			c.yaw = rng.randf() * TAU
			add_child(c)
			c.build()
			crawlers.append(c)
		set_process(true)

	func clear() -> void:
		for c in crawlers:
			var cr: Crawler = c
			if cr.st == Crawler.UNBORN:
				cr.st = Crawler.DEAD
				cr.visible = false
			else:
				cr.set_state(Crawler.DEAD)

	func _process(delta: float) -> void:
		if not hatched:
			return
		clock += delta
		var auth: bool = CoopSync.map_is_authority()
		if not auth:
			# a guest only shows what the host streams. When that stops (the host reloaded after a
			# death and its brood is gone, or the host left) nothing may stand frozen on this
			# screen: the brood hides until packets come again
			var stale: bool = Time.get_ticks_msec() - _rx_ms > 3000
			if stale != _stale:
				_stale = stale
				visible = not stale
		elif _stale:
			_stale = false
			visible = true
		if auth:
			for c in crawlers:
				var cr: Crawler = c
				if cr.st == Crawler.UNBORN and clock >= cr.hatch_at:
					cr.be_born(_snap_floor(cr.egg))
			_brain_t += delta
			if _brain_t >= BRAIN_DT:
				var dt := _brain_t
				_brain_t = 0.0
				_think(dt)
		# what this machine sees and hears
		var lis := Kit.listener(self)
		_skit_window -= delta
		if _skit_window <= 0.0:
			_skit_window = 0.1
			_skit_budget = 3
		var any_left := false
		for c in crawlers:
			var cr: Crawler = c
			cr.visual(delta)
			if cr.alive() or (cr.st == Crawler.DEAD and cr.visible) or cr.st == Crawler.UNBORN:
				any_left = true
			if cr.alive() and cr.moving:
				cr.step_t -= delta
				if cr.step_t <= 0.0 and _skit_budget > 0 and (cr.position - lis).length() < 24.0:
					cr.step_t = randf_range(0.16, 0.3)
					_skit_budget -= 1
					cr.skitter()
		if not any_left:
			_done_t += delta
			if _done_t > 2.0:
				set_process(false)

	func _snap_floor(p: Vector3) -> Vector3:
		var hit := Kit.ray(get_world_3d().direct_space_state, p + Vector3.UP * 1.0, p + Vector3.DOWN * 3.0, false)
		if hit.is_empty():
			return p
		return hit["position"]

	func _think(dt: float) -> void:
		var players: Array = CoopSync.alive_player_nodes()
		var space := get_world_3d().direct_space_state
		var winding: Dictionary = {}
		for c in crawlers:
			var cr: Crawler = c
			if cr.st == Crawler.WIND:
				var k := cr.get_meta("tgt", 0) as int
				winding[k] = int(winding.get(k, 0)) + 1
		for i in crawlers.size():
			var cr: Crawler = crawlers[i]
			if not cr.alive():
				continue
			cr.age += dt
			cr.cd = maxf(0.0, cr.cd - dt)
			var best: Node3D = null
			var bd := 1e9
			for p in players:
				if not is_instance_valid(p) or not (p as Node3D).is_inside_tree():
					continue
				var d: float = ((p as Node3D).global_position - cr.sim).length()
				if d < bd:
					bd = d
					best = p
			if cr.age > LIFE or (best != null and bd > LEASH):
				cr.set_state(Crawler.DEAD)
				continue
			if best == null:
				continue                       # nobody alive: they wait where they are
			var tp: Vector3 = best.global_position
			var to := tp - cr.sim
			var flat := Vector3(to.x, 0.0, to.z)
			var fd := flat.length()
			if fd > 0.05:
				cr.yaw = atan2(-flat.x, -flat.z)
			var dir := Vector3.ZERO
			if fd > 0.01:
				dir = flat / fd
			if cr.st == Crawler.NIP:
				cr.nip_t -= dt
				if cr.nip_t <= 0.0:
					cr.set_state(Crawler.WALK)
				continue
			if cr.st == Crawler.WIND:
				cr.wind -= dt
				if fd > 0.9:
					_move(cr, dir, cr.speed * 0.3 * dt, space)
				if cr.wind <= 0.0:
					var tid := best.get_instance_id()
					if bd < 1.9 and absf(to.y) < 1.7 and _nip_ok(tid) and _clear(space, cr.sim, tp):
						_last_nip[tid] = clock
						cr.set_state(Crawler.NIP)
						cr.nip_t = 0.3
						cr.cd = 1.8
						bit.emit(best, NIP_DAMAGE, "brood:%d" % i)
					else:
						cr.set_state(Crawler.WALK)
						cr.cd = 0.5
				continue
			# walking: close in, rear up when in reach
			var tid2 := best.get_instance_id()
			if bd < 1.5 and absf(to.y) < 1.6 and cr.cd <= 0.0 and int(winding.get(tid2, 0)) < MAX_WINDING:
				cr.set_state(Crawler.WIND)
				cr.wind = randf_range(0.6, 0.9)
				cr.set_meta("tgt", tid2)
				winding[tid2] = int(winding.get(tid2, 0)) + 1
				continue
			# keep a little apart from each other
			var push := Vector3.ZERO
			for o in crawlers:
				var oc: Crawler = o
				if oc == cr or not oc.alive():
					continue
				var dv := cr.sim - oc.sim
				dv.y = 0.0
				var dl := dv.length()
				if dl < 1.0 and dl > 0.001:
					push += dv / dl * (1.0 - dl)
			if push.length() > 0.001:
				dir = (dir + push * 0.8).normalized()
			if fd > 1.1 and dir.length() > 0.01:
				_move(cr, dir, cr.speed * dt, space)

	func _nip_ok(tid: int) -> bool:
		return clock - float(_last_nip.get(tid, -99.0)) >= PER_TARGET_GAP

	func _clear(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
		# never through rock
		return Kit.ray(space, a + Vector3.UP * 0.4, b + Vector3.UP * 0.8, true).is_empty()

	func _move(cr: Crawler, dir: Vector3, dist: float, space: PhysicsDirectSpaceState3D) -> void:
		for a in [0.0, 0.8, -0.8, 1.6, -1.6]:
			var d := dir.rotated(Vector3.UP, float(a))
			if _try_step(cr, d, dist * (1.0 if float(a) == 0.0 else 0.7), space):
				return

	func _try_step(cr: Crawler, d: Vector3, dist: float, space: PhysicsDirectSpaceState3D) -> bool:
		var from := cr.sim
		var want := from + d * dist
		var probe := want + d * 0.35
		var knee := Vector3.UP * 0.35
		if not Kit.ray(space, from + knee, probe + knee, true).is_empty():
			var hi := Vector3.UP * 1.0          # a step up, never a wall
			if not Kit.ray(space, from + hi, probe + hi, true).is_empty():
				return false
		var hit := Kit.ray(space, want + Vector3.UP * 1.1, want + Vector3.DOWN * 2.4, false)
		if hit.is_empty():
			return false                        # the edge: no floor within 2.4 m below
		var n: Vector3 = hit["normal"]
		if n.y < 0.45:
			return false                        # too steep to scurry up
		var fy: float = hit["position"].y
		if fy > from.y + 1.15:
			return false
		cr.sim = Vector3(want.x, fy, want.z)
		return true

	func state_packet() -> Array:
		var a: Array = [1 if hatched else 0]
		if not hatched:
			return a
		for c in crawlers:
			var cr: Crawler = c
			a.append(snappedf(cr.sim.x, 0.01))
			a.append(snappedf(cr.sim.y, 0.01))
			a.append(snappedf(cr.sim.z, 0.01))
			a.append(snappedf(cr.yaw, 0.01))
			a.append(cr.st)
		return a

	func remote_state(a: Array) -> void:
		if a.is_empty() or int(a[0]) != 1:
			return
		if not hatched:
			hatch()
			if not hatched:
				return
		_rx_ms = Time.get_ticks_msec()
		var n := mini(floori((a.size() - 1) / 5.0), crawlers.size())
		for i in n:
			var cr: Crawler = crawlers[i]
			var b := 1 + i * 5
			var s := int(a[b + 4])
			if s == Crawler.UNBORN:
				continue
			var p := Vector3(float(a[b]), float(a[b + 1]), float(a[b + 2]))
			cr.yaw = float(a[b + 3])
			if cr.st == Crawler.UNBORN:
				cr.be_born(p)
			cr.sim = p
			cr.set_state(s)

	func threat_positions() -> Array:
		var out: Array = []
		if _stale:
			return out
		for c in crawlers:
			var cr: Crawler = c
			if cr.alive():
				out.append(cr.position)
		return out

	func bite_origin(id: String) -> Vector3:
		var cr := _by_id(id)
		if cr != null:
			return cr.sim
		return global_position

	func play_bite(id: String) -> void:
		var cr := _by_id(id)
		if cr != null and cr.alive():
			cr.set_state(Crawler.NIP)

	func _by_id(id: String) -> Crawler:
		if not id.begins_with("brood:"):
			return null
		var i := int(id.substr(6))
		if i < 0 or i >= crawlers.size():
			return null
		return crawlers[i]


# ============================================================================ wall spiders

class WallSpider extends Node3D:
	# Clings under the rock over a walkway. When someone passes beneath it clicks for 0.8 s,
	# drops on a silk thread to head height, snaps once, and reels itself back up. 25 s rest.
	signal bit(who: Node3D, damage: float, id: String)

	const WAIT := 0
	const CLICK := 1
	const DROP := 2
	const HANG := 3
	const CLIMB := 4
	const REST := 5
	const DAMAGE := 18.0
	const CLICK_S := 0.8
	const HANG_S := 0.6
	const REST_S := 25.0
	const TRIGGER_R := 6.0
	const REACH := 1.6
	const CLIMB_SPEED := 4.0

	var map: Node3D
	var id := "sp"
	var anchor := Vector3.ZERO
	var floor_pt := Vector3.ZERO
	var biome := -1
	var st := WAIT
	var st_t := 0.0
	var cling_y := 0.0
	var low_y := 0.0
	var y := 0.0
	var rp_y := 0.0
	var drop_dur := 0.5
	var body: Node3D
	var pose: Node3D
	var rig: Rig
	var thread: MeshInstance3D
	var sfx_click: AudioStreamPlayer3D
	var sfx_voice: AudioStreamPlayer3D
	var sfx_silk: AudioStreamPlayer3D
	var _scan_t := 0.0
	var _click_t := 0.0
	var _lod_t := 0.0
	var _near := true
	var _k := 0.0
	var _t := 0.0
	var _q_cling := Quaternion(Vector3(0, 0, 1), PI)          # belly up under the rock
	var _q_hang := Quaternion(Vector3(1, 0, 0), -PI * 0.5)    # head down on the thread

	func setup(e: Dictionary, m: Node3D) -> void:
		map = m
		top_level = true
		id = str(e.get("id", "sp"))
		anchor = Kit.v(e.get("anchor", [0, 0, 0]))
		floor_pt = Kit.v(e.get("floor", [anchor.x, anchor.y - 8.0, anchor.z]))
		biome = int(e.get("biome", -1))
		cling_y = anchor.y - 0.05
		low_y = minf(floor_pt.y + 1.75, cling_y - 1.0)
		y = cling_y
		rp_y = cling_y

	func _ready() -> void:
		body = Node3D.new()
		body.position = Vector3(anchor.x, y, anchor.z)
		body.rotation.y = randf() * TAU
		add_child(body)
		pose = Node3D.new()
		pose.basis = Basis(_q_cling)
		body.add_child(pose)
		rig = Kit.make_rig("spider", 0.55, Color(0.2, 0.19, 0.16))
		pose.add_child(rig.root)
		var cm := CylinderMesh.new()
		cm.top_radius = 0.02
		cm.bottom_radius = 0.02
		cm.height = 1.0
		cm.radial_segments = 4
		cm.rings = 1
		var tm := StandardMaterial3D.new()
		tm.albedo_color = Color(0.32, 0.32, 0.3)
		tm.roughness = 1.0
		tm.metallic_specular = 0.0
		thread = MeshInstance3D.new()
		thread.mesh = cm
		thread.material_override = tm
		thread.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		thread.visible = false
		add_child(thread)
		sfx_click = Kit.player(body, 0.0, 30.0)
		sfx_click.max_polyphony = 3
		sfx_voice = Kit.player(body, 0.0, 36.0)
		sfx_silk = Kit.player(body, 0.0, 30.0)
		_scan_t = randf() * 0.1
		_t = randf() * 10.0

	func _enter(s: int) -> void:
		st = s
		st_t = 0.0
		if s == CLICK:
			# the warning: a dry chatter from above, 0.8 s before it drops
			var os := Kit.oneshot("spider_click")
			var cs: AudioStream = os[0]
			if cs != null:
				Kit.play(sfx_voice, cs, float(os[1]), 1.0)
			_click_t = 0.0
		elif s == DROP:
			drop_dur = clampf((cling_y - low_y) / 16.0, 0.35, 0.8)
			Kit.play(sfx_silk, Kit.game_stream(Kit.SILK), -2.0, 1.7)
		elif s == HANG:
			Kit.play(sfx_voice, Kit.rand_stream("snarl", Kit.SNARL, 1.1), 0.0, 1.45)
			Kit.play(sfx_click, Kit.rand_stream("chomp", Kit.CHOMP, 1.15), 2.0, 1.2)
		elif s == CLIMB:
			Kit.play(sfx_silk, Kit.game_stream(Kit.SILK), -6.0, 1.15)

	func _process(delta: float) -> void:
		_t += delta
		st_t += delta
		if CoopSync.map_is_authority():
			_think(delta)
			rp_y = y
		else:
			y = lerpf(y, rp_y, clampf(delta * 12.0, 0.0, 1.0))
		_lod_t -= delta
		if _lod_t <= 0.0:
			_lod_t = 0.5
			_near = (Kit.listener(self) - anchor).length() < 110.0
			rig.set_active(_near)
		if not _near and (st == WAIT or st == REST):
			return
		_visual(delta)

	func _think(delta: float) -> void:
		if st == WAIT:
			_scan_t -= delta
			if _scan_t > 0.0:
				return
			_scan_t = 0.1
			for p in CoopSync.alive_player_nodes():
				if not is_instance_valid(p) or not (p as Node3D).is_inside_tree():
					continue
				var pp: Vector3 = (p as Node3D).global_position
				var hd := Vector2(pp.x - anchor.x, pp.z - anchor.z).length()
				if hd < TRIGGER_R and pp.y < anchor.y and pp.y > floor_pt.y - 4.0:
					_enter(CLICK)
					return
		elif st == CLICK:
			if st_t >= CLICK_S:
				_enter(DROP)
		elif st == DROP:
			var k := clampf(st_t / drop_dur, 0.0, 1.0)
			y = lerpf(cling_y, low_y, k * k)
			if k >= 1.0:
				y = low_y
				_enter(HANG)
				_try_bite()
		elif st == HANG:
			if st_t >= HANG_S:
				_enter(CLIMB)
		elif st == CLIMB:
			y = minf(cling_y, y + CLIMB_SPEED * delta)
			if y >= cling_y:
				_enter(REST)
		elif st == REST:
			if st_t >= REST_S:
				_enter(WAIT)

	func _try_bite() -> void:
		# one snap at the bottom of the drop, only at someone still under it
		var at := Vector3(anchor.x, low_y, anchor.z)
		for p in CoopSync.alive_player_nodes():
			if not is_instance_valid(p) or not (p as Node3D).is_inside_tree():
				continue
			var d: Vector3 = (p as Node3D).global_position - at
			if Vector2(d.x, d.z).length() < REACH and d.y > -2.6 and d.y < 0.9:
				bit.emit(p, DAMAGE, id)
				return

	func _visual(delta: float) -> void:
		body.position = Vector3(anchor.x, y, anchor.z)
		var want_k := 1.0 if (st == DROP or st == HANG or st == CLIMB) else 0.0
		_k = lerpf(_k, want_k, clampf(delta * 9.0, 0.0, 1.0))
		pose.basis = Basis(_q_cling.slerp(_q_hang, _k))
		# the visible wind-up: it shivers and flexes against the rock while it clicks
		if st == CLICK:
			pose.position = Vector3(randf_range(-0.03, 0.03), randf_range(-0.05, 0.02), randf_range(-0.03, 0.03))
			_click_t -= delta
			if _click_t <= 0.0:
				_click_t = randf_range(0.08, 0.14)
				Kit.play(sfx_click, Kit.rand_stream("clicks", Kit.CLICKS, 1.2), 1.0, randf_range(1.6, 2.1))
		else:
			pose.position = Vector3.ZERO
		var gap := anchor.y - y
		thread.visible = gap > 0.3
		if thread.visible:
			thread.position = Vector3(anchor.x, (anchor.y + y) * 0.5, anchor.z)
			thread.scale = Vector3(1.0, maxf(gap, 0.01), 1.0)
		if rig.fallback:
			var base := 0.55
			var amp := 0.04
			var freq := 2.0
			if st == CLICK:
				base = 0.8
				amp = 0.12
				freq = 22.0
			elif st == DROP or st == HANG:
				base = 1.1                           # legs flung wide, then snapping shut
				amp = 0.08
				freq = 9.0
			elif st == CLIMB:
				amp = 0.22
				freq = 9.0
			for i in rig.legs.size():
				var lg: Node3D = rig.legs[i]
				var ph := float(i) * 1.7 + (PI if i % 2 == 0 else 0.0)
				lg.rotation.z = lerpf(lg.rotation.z, base + sin(_t * freq + ph) * amp, clampf(delta * 12.0, 0.0, 1.0))
		else:
			if st == HANG or st == DROP:
				rig.play("attack", 0.1)
				rig.set_speed(1.0)
			elif st == CLIMB:
				rig.play("walk")
				rig.set_speed(1.4)
			elif st == CLICK:
				rig.play("idle", 0.1)
				rig.set_speed(2.8)
			else:
				rig.play("idle")
				rig.set_speed(1.0)

	func state_packet() -> Array:
		return [st, snappedf(y, 0.01)]

	func remote_state(a: Array) -> void:
		if a.size() < 2:
			return
		var s := int(a[0])
		rp_y = float(a[1])
		if s != st:
			_enter(s)

	func threat_positions() -> Array:
		if st == WAIT or st == REST:
			return []
		return [Vector3(anchor.x, y, anchor.z)]

	func bite_origin(_id: String) -> Vector3:
		return Vector3(anchor.x, y, anchor.z)

	func play_bite(_id: String) -> void:
		if st != HANG:
			Kit.play(sfx_click, Kit.rand_stream("chomp", Kit.CHOMP, 1.15), 2.0, 1.2)


# ============================================================================ the waking husk

class WakingHusk extends Node3D:
	# One of the dead centipedes on a great shelf is not dead. Walk its length and it shivers,
	# bone scraping on stone, for a second and a half. Then the map swaps it for a live one.
	signal wake(pos: Vector3, yaw: float)
	signal woke()

	const SHIVER_S := 1.5

	var map: Node3D
	var id := "wh1"
	var trigger := Vector3.ZERO
	var r := 6.0
	var head := Vector3.ZERO
	var yaw := 0.0
	var phase := 0
	var t := 0.0
	var props: Array = []
	var props_xf: Array = []
	var sfx_a: AudioStreamPlayer3D
	var sfx_b: AudioStreamPlayer3D
	var _scan_t := 0.0
	var _jit_t := 0.0

	func setup(d: Dictionary, m: Node3D) -> void:
		map = m
		top_level = true
		id = str(d.get("id", "wh1"))
		trigger = Kit.v(d.get("trigger", [0, 0, 0]))
		r = float(d.get("r", 6.0))
		head = Kit.v(d.get("head", d.get("trigger", [0, 0, 0])))
		yaw = float(d.get("yaw", 0.0))

	func _ready() -> void:
		# the trigger lies near the tail, about 50 m down the body from the head: the bone scrape
		# (the warning) comes from the body close to the player, the rattle and the snarl from the
		# head, where the live one gets up. Both carry past the husk's full length.
		sfx_a = Kit.player(self, 0.0, 70.0)
		sfx_a.position = trigger.lerp(head, 0.2)
		sfx_b = Kit.player(self, 0.0, 70.0)
		sfx_b.position = head

	func attach_props(nodes: Array) -> void:
		props.clear()
		for n in nodes:
			if n is Node3D:
				props.append(n)

	func set_woken() -> void:
		_restore()
		phase = 2
		set_process(false)

	func _process(delta: float) -> void:
		if phase == 0:
			if not CoopSync.map_is_authority():
				return
			_scan_t -= delta
			if _scan_t > 0.0:
				return
			_scan_t = 0.2
			for p in CoopSync.alive_player_nodes():
				if is_instance_valid(p) and (p as Node3D).is_inside_tree() and ((p as Node3D).global_position - trigger).length() < r:
					_begin()
					return
		elif phase == 1:
			t += delta
			_jit_t -= delta
			if _jit_t <= 0.0:
				_jit_t = 1.0 / 30.0
				var k := clampf(t / SHIVER_S, 0.0, 1.0)
				var amp := 0.015 + 0.05 * k
				for i in props.size():
					var n = props[i]
					if not is_instance_valid(n) or i >= props_xf.size():
						continue
					var xf: Transform3D = props_xf[i]
					n.transform = xf
					n.position = xf.origin + Vector3(randf_range(-amp, amp), randf_range(-amp, amp) * 0.5, randf_range(-amp, amp))
					n.rotate_y(randf_range(-0.02, 0.02) * (1.0 + k))
			if t >= SHIVER_S and CoopSync.map_is_authority():
				_finish()

	func _begin() -> void:
		if phase != 0:
			return
		phase = 1
		t = 0.0
		props_xf.clear()
		for n in props:
			props_xf.append((n as Node3D).transform if is_instance_valid(n) else Transform3D.IDENTITY)
		Kit.play(sfx_a, Kit.game_stream(Kit.SCRAPE), 3.0, 0.7)
		Kit.play(sfx_b, Kit.game_stream(Kit.RATTLE), 1.0, 0.85)

	func _restore() -> void:
		for i in mini(props.size(), props_xf.size()):
			var n = props[i]
			if is_instance_valid(n):
				(n as Node3D).transform = props_xf[i]

	func _finish() -> void:
		if phase == 2:
			return
		_restore()
		phase = 2
		Kit.play(sfx_b, Kit.rand_stream("snarl", Kit.SNARL, 1.0), 5.0, 0.8)
		woke.emit()
		if CoopSync.map_is_authority():
			wake.emit(head, yaw)
		set_process(false)

	func state_packet() -> Array:
		return [phase]

	func remote_state(a: Array) -> void:
		if a.is_empty():
			return
		var p := int(a[0])
		if p == 1 and phase == 0:
			_begin()
		elif p == 2 and phase == 1:
			_finish()
		elif p == 2 and phase == 0:
			set_woken()               # joined late: it is already up, quietly
			woke.emit()

	func threat_positions() -> Array:
		# while it shivers the whole body is the threat: its head, and the stretch of body beside
		# the trigger (the player is there, 50 m from the head), so the heartbeat starts at once
		if phase == 1:
			return [head, trigger.lerp(head, 0.2)]
		return []
