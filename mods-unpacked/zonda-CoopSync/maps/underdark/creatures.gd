extends RefCounted
# ============================================================================================
# THE UNDERDARK: new creatures (ZondaCoopSync v4.9, light-fear and omen hooks v5.0)
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
#   setup({"points": [[x,y,z], ...], "count": int, "tag": String, "hunts_idol": bool}, map)
#                                points = egg positions (L["eggs"][i]["pos"]); count 10-16 (13);
#                                tag names the bite ids (default "brood"; the Early Brood omen
#                                uses "obrood"); hunts_idol (default true): while map.idol_prey()
#                                is a living node in the tree, it is the ONLY target (the leash
#                                still measures the nearest living player)
#   hatch()                      start the hatching (10-16 crawlers over ~3 s). Call it when the idol
#                                is taken LIVE (not on a replay). Guests may call it too; they also
#                                hatch by themselves on the first stream packet that says so.
#   is_hatched() -> bool
#   clear()                      every crawler dies at once (finish, session end)
#   state_packet() -> Array      [hatched, then per crawler x, y, z, yaw, state]
#   remote_state(a: Array)       guests: the first packet with a[0] == 1 hatches and builds them
#   threat_positions() -> Array  positions of the living crawlers (for the heartbeat)
#   bite_origin(id) -> Vector3   where a bite with that id comes from
#   play_bite(id)                guests: shows/plays that crawler's nip (the host already did)
#   lose_scent(s: float)         AUTHORITY: for s seconds they only turn toward the target (no
#                                walking, no new wind-up); a crawler winding up goes back to walking
#   scent_hiss()                 EVERY machine: the 3 living crawlers nearest the listener hiss and
#                                rear up (the wind-up pose) for 0.6 s, locally
#   const PER_TARGET_GAP_HOST := 1.1   the nip gap while it hunts a single idol holder (else 0.8)
#   var last_prey_name := ""     debug: the node it hunted at the last brain tick
#   signal bit(who: Node3D, damage: float, id: String)   authority only; id = "<tag>:<i>", damage 8
#
# ---- Creatures.WallSpider (Node3D) -------------------------------------------------------
#   setup(entry of L["spiders"], map)   {"id","anchor":[x,y,z],"floor":[x,y,z],"biome"}
#   var rest_s := 25.0           the rest after a bite or a scatter (the omen HUNGRY SILK sets 9)
#   var trigger_r := 6.0         how close (horizontally) a player below sets it clicking (SILK: 8)
#   states WAIT 0, CLICK 1 (1.0 s), DROP 2, HANG 3, CLIMB 4, REST 5, SCATTER 6
#   light-fear C: a lantern BEAM on it (LightField.beam_at, k >= 0.45) for 0.15 s while it clicks,
#   or for 0.6 s while it waits with a living player within 14 m, makes it screech and scurry
#   sideways into the rock (SCATTER, 0.9 s), then it rests HIDDEN for rest_s. Glow and fires do
#   nothing. Logs "[SPIDERLIGHT] <id> scatter (pre-emptive|click)" on the authority.
#   state_packet() -> Array      [state, y, hidden01]
#   remote_state(a: Array)       guests un-hide by themselves after rest_s (REST -> WAIT is not streamed)
#   threat_positions() -> Array  its body while it clicks, drops, hangs or climbs back ([] while hidden)
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
#   Creatures.bite_local(from: Vector3, damage: float, heavy: bool = false, push: float = -1.0)
#       applies a bite to THIS player (Game.climber): take_damage(damage) (the game halves it),
#       a small horizontal shove away from `from` (never upward) and the hurt sound. heavy = true
#       for the spider (bite sound on top), false for a brood nip. push < 0 keeps the old nudge
#       (1.2 heavy / 0.8 light, about 0.45 / 0.3 m of drift); push >= 0 is the impulse itself
#       (drift is about 0.375 m per 1.0 of push). Other builders call it with callv (1A.1).
#   Creatures.is_spider_id(id) -> bool       id begins with "sp_"
#   Creatures.oneshot(kind) -> Array         [AudioStream or null, db] from the sfx manifest
#   Creatures.make_player(parent, db, max_dist) -> AudioStreamPlayer3D   on the cave bus
#   Creatures.play_stream(p, stream, db, pitch)
#       (the last three let ext/centipede.gd play "pale_hiss" without preloading this file)
#
# Models: maps/underdark/ext/mon/manifest.json {"spider": {"file","anims":{idle,walk,attack,death},
# "height_m", optional "yaw_deg" (default 180: glTF faces +Z)}, "crawler": {...}}, loaded from bytes
# with GLTFDocument (AnimationPlayer kept and driven by state). Missing or {} = the game's own
# Monster_Head_Redesign / Monster_BodySection_Redesign tinted pale and scaled down (the spider gets
# eight procedural legs). All creature meshes: no emission, no lights, no particles.
#
# ---- v5.0 creature no-clip (docs/specs/2026-09-25-creature-noclip.md 3.D, 3.E, 3.F) ---------
# Rule K: every behaviour change below runs only while noclip.gd (NC-1, loaded at runtime through
# Kit.nc()) says is_enabled(); otherwise today's code runs unchanged. Test plumbing (the "zonda_nc"
# group, noclip_points(), the hooks and the NC.note counters) runs either way.
#   Brood: the brain ticks in _physics_process; each step is NC.walk_step (both-sided rays, proven
#     headroom, L-shaped rise/drop) with the Brood profile, so the crawlers really walk and chase
#     now (owner decision 7A.5); small, they fit wherever 1.45 m of headroom does. The body walks
#     the proven path (rise first, drop last), pitches to the floor, is born on the floor and dies
#     by shrinking (no sinking). Guests: the way between two host samples is ray-checked (the
#     L-path, or a detour when two brain steps in one packet cut a corner) and walked about 110 ms
#     behind the newest sample (no extrapolation); a gap over 2 m, the stream coming back after a
#     gap, or no clear way snaps it (declared). noclip_points(): kind "brood"/"obrood" (the tag),
#     centre = crawler + 0.3 m. Counters: winds, nips, moves (+ walk/refused per heading, from
#     walk_step or the old step).
#   WallSpider: once per machine its perch is fitted under the real rock: 9 up rays (at least 5
#     hits: cling under the lowest, tilted to the mean normal, at most 30 degrees), then the seeded
#     yaw (from the id, the same on every machine) and 30 degree steps, and only if needed a lower
#     perch (0.1 m steps, at most 4 m; it then waits on a short thread under its crack), until the
#     body and the four leg corners are in open air and the whole drop's pose swing is too. The
#     swing never turns further than the drop below the perch leaves room for. The light-fear
#     scatter slides along the ceiling (every 0.2 m checked), or up its own thread into the crack,
#     or shrinks in place. noclip_points(): kind "spider", centre 0.25 m off the ceiling,
#     extremities = the 4 leg corners; whitelisted while hidden. Hook noclip_test_scatter().
#     Counters: clicks, bites. Logs "[CLIP] fit spider <id> ..." once per spider per machine.
#   WakingHusk: joins "zonda_nc" (props whitelisted, no points). Hook noclip_test_wake() -> bool.
# ============================================================================================


static func bite_local(from: Vector3, damage: float, heavy: bool = false, push: float = -1.0) -> void:
	Kit.bite_local(from, damage, heavy, push)


static func is_spider_id(id: String) -> bool:
	# only the wall spiders ("sp_<n>"): brood, obrood, Shade and hearth ids are not spiders
	return id.begins_with("sp_")


static func oneshot(kind: String) -> Array:
	return Kit.oneshot(kind)


static func make_player(parent: Node, db: float, max_dist: float) -> AudioStreamPlayer3D:
	return Kit.player(parent, db, max_dist)


static func play_stream(p: AudioStreamPlayer3D, stream: AudioStream, db: float, pitch: float) -> void:
	Kit.play(p, stream, db, pitch)


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

	# ------------------------------------------------------------------ no-clip helper (v5.0)
	# maps/underdark/noclip.gd belongs to another group (NC-1): loaded at runtime, never preloaded.
	# A missing helper means every creature here moves exactly as before (Rule K).

	const NC_PATH := "res://mods-unpacked/zonda-CoopSync/maps/underdark/noclip.gd"
	static var _nc_script = null
	static var _nc_tried := false

	static func nc():
		if not _nc_tried:
			_nc_tried = true
			if ResourceLoader.exists(NC_PATH):
				_nc_script = load(NC_PATH)
			if _nc_script == null:
				push_warning("[CLIP] noclip.gd missing: creatures move as before")
		return _nc_script

	static func nc_on() -> bool:
		var n = nc()
		return n != null and bool(n.call("is_enabled"))

	static func note(kind: String, key: String, k: int = 1) -> void:
		# fairness and guard counters (NC.note is a no-op unless the probe measures)
		var n = nc()
		if n != null:
			n.call("note", kind, key, k)

	static func nray(space, a: Vector3, b: Vector3) -> Dictionary:
		# NC.ray: both faces, Rule N normal (faces a), "d"; {} when clear or with no helper
		var n = nc()
		if n == null:
			return {}
		var h = n.call("ray", space, a, b)
		if h is Dictionary:
			return h
		return {}

	static func rig_box(rig: Rig) -> AABB:
		# the rig's bounds in its pose frame (the root's own scale and yaw included), measured once
		if rig == null or rig.root == null:
			return AABB(Vector3(-0.3, 0.0, -0.3), Vector3(0.6, 0.4, 0.6))
		if not rig.box_ok:
			rig.box_ok = true
			var b: AABB = rig.root.transform * local_aabb(rig.root)
			if b.size.length() < 0.01:
				b = AABB(Vector3(-0.3, 0.0, -0.3), Vector3(0.6, 0.4, 0.6))
			rig.box = b
		return rig.box

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

	static func bite_local(from: Vector3, damage: float, heavy: bool, push: float = -1.0) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree():
			return
		if c.get("coop_spectating"):
			return
		c.take_damage(damage)            # the game halves it and plays its own small hurt sound
		var away: Vector3 = c.global_position - from
		away.y = 0.0                     # a nudge, never a lift: nobody is thrown off a ledge
		var k: float = (1.2 if heavy else 0.8) if push < 0.0 else push
		if away.length() > 0.05 and k > 0.0:
			# the climber re-adds this every physics frame, decaying x0.96 (climber.gd), so the
			# total drift is about 25x the number / physics rate: 1.2 -> ~0.45 m, 0.8 -> ~0.3 m
			c.additional_velocity_next_frame += away.normalized() * k
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
	var box := AABB()                 # Kit.rig_box(): the bounds in the pose frame (v5.0 no-clip)
	var box_ok := false

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
	var hiss_t := 0.0               # scent_hiss: the wind-up pose shown locally, whatever the state
	var sfx_step: AudioStreamPlayer3D
	var sfx_voice: AudioStreamPlayer3D
	# v5.0 no-clip (used only while the helper is on, Rule K)
	# the proven floor path (L-steps) the body walks along: the brain's steps on the host, the
	# checked path between samples on guests
	var way: Array = []
	var floor_n := Vector3.UP        # host: the floor normal under the last step
	var pause := 0.0                 # host: every heading was refused, no planning for this long
	var tp := 0                      # snaps so far (declared teleports, for the no-clip probe)
	var g_last := Vector3.ZERO       # guests: the newest host sample (the end of the path) and its ms
	var g_ms := 0
	var u_est := 0.0                 # guests: the host's pace from the samples (m/s, smoothed)
	var hl := 0.25                   # half the body length (the rig's box), for the rear-up lift
	var cl := Vector3(0.0, 0.16, 0.0)  # the body's centre in the pose frame (it dies rolling about it)
	var _pitch := 0.0                # the floor slope along the heading, applied to the pose
	var _slope_t := 0.0

	func build() -> void:
		pose = Node3D.new()
		add_child(pose)
		rig = Kit.make_rig("crawler", 0.5, Color(0.36, 0.34, 0.29))
		pose.add_child(rig.root)
		var bx := Kit.rig_box(rig)
		hl = maxf(0.05, bx.size.z * 0.5)
		cl = bx.get_center()
		sfx_step = Kit.player(self, 0.0, 26.0)
		sfx_step.max_polyphony = 2
		sfx_voice = Kit.player(self, 0.0, 34.0)
		wob = randf() * TAU
		visible = false

	func be_born(at: Vector3, ncm: bool = false) -> void:
		if st != UNBORN:
			return
		st = WALK
		sim = at
		if ncm:
			position = at                      # born ON the floor: the 0.3 -> 1.0 scale-up is the hatch
		else:
			position = at + Vector3.DOWN * 0.35
		way.clear()
		g_last = at
		g_ms = Time.get_ticks_msec()
		u_est = 0.0
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

	func scent_hiss() -> void:
		# the idol changed hands: a hiss and a rear-up, shown on this machine only
		if not alive():
			return
		hiss_t = 0.6
		Kit.play(sfx_voice, Kit.rand_stream("snarl", Kit.SNARL, 1.15), -4.0, 1.7)

	func rx_push(p: Vector3, ms: int, snap: bool) -> void:
		# guests (no-clip on, D5): a new host sample. The way from the last sample to it is checked
		# here (the L-path at the body's centre height, or a short detour when two brain steps in one
		# packet cut a corner) and walked by _nc_follow. snap = place it at once (a jump over 2 m,
		# the stream coming back after a gap, or no clear way): declared through tp
		if snap:
			if position.distance_to(p) > 0.05:
				tp += 1
			way.clear()
			position = p
			g_last = p
			g_ms = ms
			u_est = 0.0
			return
		var seg := g_last.distance_to(p)
		if seg < 0.005:
			u_est = lerpf(u_est, 0.0, 0.35)       # standing: the pace settles
			g_ms = ms
			return
		var path := _nc_path(g_last, p)
		if path.is_empty():
			rx_push(p, ms, true)
			return
		way.append_array(path)
		var pace := seg / maxf(0.05, float(ms - g_ms) / 1000.0)
		u_est = pace if u_est <= 0.0 else lerpf(u_est, pace, 0.35)
		g_last = p
		g_ms = ms

	func _nc_path(a: Vector3, b: Vector3) -> Array:
		# the points after a, ending at b, of a way whose centre line (+0.3 m) crosses no rock: the
		# L-path (rise first, drop last), else a detour through one point beside the chord. [] = none
		# (or the rock is not loaded here: a guest never glides through unchecked rock)
		var NC = Kit.nc()
		if NC == null:
			return [b]
		if not bool(NC.call("solid_at", a, 4.0)) or not bool(NC.call("solid_at", b, 4.0)):
			return []
		var space := get_world_3d().direct_space_state
		var direct := _l_pts(a, b)
		if _pts_clear(space, a, direct):
			return direct
		var fl := Vector3(b.x - a.x, 0.0, b.z - a.z)
		var perp := Vector3(-fl.z, 0.0, fl.x).normalized() if fl.length() > 0.001 else Vector3.RIGHT
		var mid := (a + b) * 0.5
		for k in [0.35, -0.35, 0.7, -0.7, 1.05, -1.05]:
			var m := mid + perp * float(k)
			m.y = maxf(a.y, b.y)
			var pts: Array = _l_pts(a, m)
			pts.append_array(_l_pts(m, b))
			if _pts_clear(space, a, pts):
				return pts
		return []

	static func _l_pts(a: Vector3, b: Vector3) -> Array:
		var rise := b.y - a.y
		if rise > 0.15:
			return [Vector3(a.x, b.y, a.z), b]
		if rise < -0.15:
			return [Vector3(b.x, a.y, b.z), b]
		return [b]

	static func _pts_clear(space, a: Vector3, pts: Array) -> bool:
		var prev := a + Vector3.UP * 0.3
		for q in pts:
			var qq: Vector3 = (q as Vector3) + Vector3.UP * 0.3
			if not Kit.nray(space, prev, qq).is_empty():
				return false
			prev = qq
		return true

	func _walk_way(dist: float) -> void:
		# move along the queued path by dist (never a chord across a corner of it)
		var left := dist
		while left > 0.0001 and not way.is_empty():
			var w: Vector3 = way[0]
			var d := position.distance_to(w)
			if d <= left:
				position = w
				left -= d
				way.pop_front()
			else:
				position += (w - position) * (left / d)
				left = 0.0

	func _nc_walk(delta: float) -> void:
		# host: walk the brain's proven path, rise first and drop last, never a chord through a lip.
		# 1.5x its speed, so it keeps up with the 12 Hz brain
		if way.size() > 8 or (way.is_empty() and position.distance_to(sim) > 2.0):
			way.clear()
			if position.distance_to(sim) > 0.05:
				tp += 1
			position = sim                     # fell behind (a long hitch): never glide a long chord
			return
		_walk_way(speed * 1.5 * delta)

	func _nc_follow(delta: float) -> void:
		# guests: walk the checked path at the host's pace, about 110 ms behind its newest sample
		# (never past it: no extrapolation); far behind (a hitch) it is placed there instead
		if way.is_empty():
			return
		var rem := 0.0
		var prev := position
		for w in way:
			rem += prev.distance_to(w)
			prev = w
		if rem > 3.0:
			rx_push(g_last, g_ms, true)
			return
		var v := clampf(u_est + (rem - u_est * 0.11) / 0.25, 0.0, speed * 2.5)
		_walk_way(v * delta)

	func _nc_slope(auth: bool) -> float:
		# the floor's slope along the heading (nose up = positive), at most 25 degrees
		var fwd := Vector3(-sin(rotation.y), 0.0, -cos(rotation.y))
		if auth:
			if floor_n.y > 0.2:
				_slope_t = atan2(-floor_n.dot(fwd), floor_n.y)
		elif not way.is_empty():
			var d: Vector3 = (way[0] as Vector3) - position
			var h := Vector2(d.x, d.z).length()
			if h > 0.05 and absf(d.y) <= 0.15 * maxf(1.0, h / 0.6):
				_slope_t = atan2(d.y, h) * Vector3(d.x, 0.0, d.z).normalized().dot(fwd)
		else:
			_slope_t = lerpf(_slope_t, 0.0, 0.05)  # standing still: settle slowly
		return clampf(_slope_t, -0.436, 0.436)

	func visual(delta: float, ncm: bool = false, auth: bool = true) -> void:
		if st == UNBORN:
			return
		vis_t = minf(1.0, vis_t + delta * 2.2)
		hiss_t = maxf(0.0, hiss_t - delta)
		var prev := position
		if st != DEAD:
			if not ncm:
				position = position.lerp(sim, clampf(delta * 10.0, 0.0, 1.0))
			elif auth:
				_nc_walk(delta)
			else:
				_nc_follow(delta)
			rotation.y = lerp_angle(rotation.y, yaw, clampf(delta * 12.0, 0.0, 1.0))
		moving = (position - prev).length() > delta * 0.8
		wob += delta * (16.0 if moving else 3.0)
		var tilt := 0.0
		var roll := 0.0
		var fwd := 0.0
		var lift := 0.0
		if st == WIND or (hiss_t > 0.0 and alive()):
			tilt = 0.55 + sin(wob * 3.0) * 0.06          # reared up and trembling: the wind-up
			lift = 0.08
		elif st == NIP:
			tilt = -0.25
			fwd = -0.35                                  # the lunge
		elif st == DEAD:
			dead_t += delta
			roll = minf(1.0, dead_t * 2.0) * PI * 0.85
			if dead_t > 0.8 and not ncm:
				position.y -= delta * 0.5          # (no-clip on: it shrinks away instead of sinking)
			if dead_t > 1.8:
				visible = false
		elif moving:
			tilt = sin(wob) * 0.05
			lift = absf(sin(wob)) * 0.03
		var pitch := 0.0
		if ncm:
			# lie along the floor, and rear up (or nip) about the tail (or the nose), never through the floor
			_pitch = lerpf(_pitch, _nc_slope(auth), clampf(delta * 8.0, 0.0, 1.0))
			pitch = _pitch
			if st != DEAD and absf(tilt) > 0.001:
				lift = maxf(lift, hl * sin(absf(tilt)))
		pose.rotation.x = lerpf(pose.rotation.x, tilt + pitch, clampf(delta * 14.0, 0.0, 1.0))
		pose.rotation.z = roll
		var sc := lerpf(0.3, 1.0, vis_t)
		if ncm and st == DEAD:
			sc *= maxf(0.01, 1.0 - clampf((dead_t - 0.8) / 0.6, 0.0, 1.0))
		pose.scale = Vector3.ONE * sc
		if ncm and st == DEAD:
			# rolls over and shrinks about its own middle: the dead body stays on the floor
			pose.position = cl - pose.basis * cl
		else:
			pose.position = pose.position.lerp(Vector3(0, lift, fwd), clampf(delta * 14.0, 0.0, 1.0))
		if rig.fallback:
			for i in rig.segs.size():
				var sg: Node3D = rig.segs[i]
				sg.rotation.y = sin(wob - float(i + 1) * 0.9) * (0.35 if moving else 0.08)
		elif st == DEAD:
			rig.play("death", 0.1)
		elif st == WIND or st == NIP or hiss_t > 0.0:
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
	const PER_TARGET_GAP_HOST := 1.1     # the same while it hunts a single idol holder
	const MAX_WINDING := 3               # at most three rear up on the same player at once

	var map: Node3D
	var points: Array = []
	var count := 13
	var tag := "brood"                   # bite ids are "<tag>:<i>"
	var hunts_idol := true               # the idol holder (map.idol_prey()) is the only target
	var last_prey_name := ""             # debug: who it hunted at the last brain tick
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
	var _scent_t := 0.0                  # authority: lose_scent time left
	var _prey_mode := false              # authority: the last brain tick hunted the idol holder
	# v5.0 no-clip (3.D): the one floor walk (NC.walk_step) with the Brood profile. Every probe
	# starts where the headroom was proven (head 1.45 >= 1.35 + 0.1), and the full 1.15 m step up
	# has a clear probe above its lip (1.35 >= 1.15 + 0.2). "kind" = the tag, set in setup().
	const NC_STEP_UP := 1.15
	const PLAYER_HALF_H := 0.78          # a climber's capsule centre is this far above its feet
	var _prof: Dictionary = {"probes": [0.35, 1.0, 1.35], "lead": 0.35, "step_up": 1.15, "max_drop": 2.4,
			"head": 1.45, "min_ny": 0.45, "kind": "brood"}

	func _ready() -> void:
		add_to_group("zonda_nc")             # the no-clip probe samples every crawler (noclip_points)

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
		tag = str(data.get("tag", "brood"))
		if tag == "":
			tag = "brood"
		hunts_idol = bool(data.get("hunts_idol", true))
		_prof["kind"] = tag                  # walk_step counts its walk / refused under the tag

	func lose_scent(s: float) -> void:
		# authority only: the idol changed hands. For s seconds they only turn toward the holder;
		# a crawler rearing up drops back to walking with a short cooldown
		if not CoopSync.map_is_authority():
			return
		_scent_t = maxf(_scent_t, s)
		for c in crawlers:
			var cr: Crawler = c
			if cr.st == Crawler.WIND:
				cr.set_state(Crawler.WALK)
				cr.cd = 0.5

	func scent_hiss() -> void:
		# every machine: the three living crawlers nearest this listener hiss and rear, locally
		if not hatched:
			return
		var lis := Kit.listener(self)
		var ranked: Array = []
		for c in crawlers:
			var cr: Crawler = c
			if cr.alive():
				ranked.append([(cr.position - lis).length_squared(), cr])
		ranked.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
		for i in mini(3, ranked.size()):
			(ranked[i][1] as Crawler).scent_hiss()

	func _idol_prey() -> Node3D:
		# the idol holder (idol_host.gd through the map), only while alive and in the tree
		if not hunts_idol or not is_instance_valid(map) or not map.has_method("idol_prey"):
			return null
		var n = map.call("idol_prey")
		if n is Node3D and is_instance_valid(n) and (n as Node3D).is_inside_tree():
			return n
		return null

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
		set_physics_process(true)

	func clear() -> void:
		for c in crawlers:
			var cr: Crawler = c
			if cr.st == Crawler.UNBORN:
				cr.st = Crawler.DEAD
				cr.visible = false
			else:
				cr.set_state(Crawler.DEAD)

	func _physics_process(delta: float) -> void:
		# v5.0 (R15, no-clip D2): with the helper on, the authority's brain runs on the physics tick
		if not hatched or not CoopSync.map_is_authority() or not Kit.nc_on():
			return
		_brain(delta, true)

	func _brain(delta: float, ncm: bool) -> void:
		# authority: births and the 12 Hz brain (the physics tick with no-clip on, else _process)
		for c in crawlers:
			var cr: Crawler = c
			if cr.st == Crawler.UNBORN and clock >= cr.hatch_at:
				cr.be_born(_snap_floor(cr.egg), ncm)
		_brain_t += delta
		if _brain_t >= BRAIN_DT:
			var dt := _brain_t
			_brain_t = 0.0
			_think(dt, ncm)

	func _process(delta: float) -> void:
		if not hatched:
			return
		clock += delta
		var auth: bool = CoopSync.map_is_authority()
		var ncm := Kit.nc_on()
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
		if auth and not ncm:
			_brain(delta, false)             # today's code: the brain in _process
		# what this machine sees and hears
		var lis := Kit.listener(self)
		_skit_window -= delta
		if _skit_window <= 0.0:
			_skit_window = 0.1
			_skit_budget = 3
		var any_left := false
		for c in crawlers:
			var cr: Crawler = c
			cr.visual(delta, ncm, auth)
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
				set_physics_process(false)

	func _snap_floor(p: Vector3) -> Vector3:
		var space := get_world_3d().direct_space_state
		if Kit.nc_on():
			# D1: a both-sided ray from p + 1 m down 3 m, accepted only as a floor (n.y >= 0.45) with
			# 1.45 m of clear headroom; a low overhang over the egg keeps p (never snaps up into it).
			# A surface within 0.3 m above p is the floor itself (egg points sit up to 0.17 m off it).
			var ov := Kit.nray(space, p + Vector3.UP * 0.05, p + Vector3.UP * 1.0)
			if not ov.is_empty() and float(ov.get("d", 1.0)) > 0.3:
				return p
			var h := Kit.nray(space, p + Vector3.UP * 1.0, p + Vector3.DOWN * 2.0)
			if h.is_empty() or (h["normal"] as Vector3).y < 0.45:
				return p
			var fp: Vector3 = h["position"]
			if not Kit.nray(space, fp + Vector3.UP * 0.05, fp + Vector3.UP * 1.45).is_empty():
				return p
			return fp
		var hit := Kit.ray(space, p + Vector3.UP * 1.0, p + Vector3.DOWN * 3.0, false)
		if hit.is_empty():
			return p
		return hit["position"]

	func _think(dt: float, ncm: bool = false) -> void:
		var players: Array = CoopSync.alive_player_nodes()
		var space := get_world_3d().direct_space_state
		# while someone carries the idol, the holder is the only prey (the leash below still measures
		# the nearest living player, so a brood left far behind still dies)
		var prey := _idol_prey()
		_prey_mode = prey != null
		last_prey_name = str(prey.name) if prey != null else ""
		_scent_t = maxf(0.0, _scent_t - dt)
		var scentless := _scent_t > 0.0
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
			var tgt: Node3D = prey if prey != null else best
			if tgt == null:
				continue                       # nobody alive: they wait where they are
			var tp: Vector3 = tgt.global_position
			var to := tp - cr.sim
			var td: float = to.length()
			var flat := Vector3(to.x, 0.0, to.z)
			var fd := flat.length()
			if fd > 0.05:
				cr.yaw = atan2(-flat.x, -flat.z)
			var dir := Vector3.ZERO
			if fd > 0.01:
				dir = flat / fd
			# no-clip on (2.6): a crawler whose every heading was refused rests its planning 0.5 s, and
			# one whose prey stands on a ledge above its step right over it waits there, facing it
			var may_plan := true
			if ncm:
				cr.pause = maxf(0.0, cr.pause - dt)
				may_plan = cr.pause <= 0.0 and not (to.y - PLAYER_HALF_H > NC_STEP_UP and fd < 2.0)
			if cr.st == Crawler.NIP:
				cr.nip_t -= dt
				if cr.nip_t <= 0.0:
					cr.set_state(Crawler.WALK)
				continue
			if scentless:
				continue                       # lost the scent: they only turn toward the prey
			if cr.st == Crawler.WIND:
				cr.wind -= dt
				if fd > 0.9 and may_plan:
					_move(cr, dir, cr.speed * 0.3 * dt, space, ncm)
				if cr.wind <= 0.0:
					var tid := tgt.get_instance_id()
					if td < 1.9 and absf(to.y) < 1.7 and _nip_ok(tid) and _clear(space, cr.sim, tp):
						_last_nip[tid] = clock
						cr.set_state(Crawler.NIP)
						cr.nip_t = 0.3
						cr.cd = 1.8
						Kit.note(tag, "nips")
						bit.emit(tgt, NIP_DAMAGE, "%s:%d" % [tag, i])
					else:
						cr.set_state(Crawler.WALK)
						cr.cd = 0.5
				continue
			# walking: close in, rear up when in reach
			var tid2 := tgt.get_instance_id()
			if td < 1.5 and absf(to.y) < 1.6 and cr.cd <= 0.0 and int(winding.get(tid2, 0)) < MAX_WINDING:
				cr.set_state(Crawler.WIND)
				Kit.note(tag, "winds")             # the telegraph (R9): the hiss and the rear-up
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
			if fd > 1.1 and dir.length() > 0.01 and may_plan:
				_move(cr, dir, cr.speed * dt, space, ncm)

	func _nip_ok(tid: int) -> bool:
		var gap: float = PER_TARGET_GAP_HOST if _prey_mode else PER_TARGET_GAP
		return clock - float(_last_nip.get(tid, -99.0)) >= gap

	func _clear(space: PhysicsDirectSpaceState3D, a: Vector3, b: Vector3) -> bool:
		# never through rock
		return Kit.ray(space, a + Vector3.UP * 0.4, b + Vector3.UP * 0.8, true).is_empty()

	func _move(cr: Crawler, dir: Vector3, dist: float, space: PhysicsDirectSpaceState3D, ncm: bool = false) -> void:
		for a in [0.0, 0.8, -0.8, 1.6, -1.6]:
			var d := dir.rotated(Vector3.UP, float(a))
			var ok := false
			if ncm:
				ok = _nc_step(cr, d, dist * (1.0 if float(a) == 0.0 else 0.7), space)
			else:
				Kit.note(tag, "walk")          # (with the helper on, walk_step counts these itself)
				ok = _try_step(cr, d, dist * (1.0 if float(a) == 0.0 else 0.7), space)
				if not ok:
					Kit.note(tag, "refused")
			if ok:
				Kit.note(tag, "moves")
				return
		if ncm:
			cr.pause = 0.5                     # every heading refused: rest the planning (2.6)

	func _nc_step(cr: Crawler, d: Vector3, dist: float, space: PhysicsDirectSpaceState3D) -> bool:
		# D1: one step of the shared floor walk. It starts probes only in proven air, finds the floor
		# with a both-sided ray from there, proves the headroom, and returns an L-shaped path (rise
		# first, drop last) that the body then walks (Crawler._nc_walk)
		var NC = Kit.nc()
		if NC == null:
			return false
		var r = NC.call("walk_step", space, cr.sim, d, dist, _prof)
		if not (r is Dictionary) or not bool((r as Dictionary).get("ok", false)):
			return false
		var np: Vector3 = (r as Dictionary).get("pos", cr.sim)
		var via: Vector3 = (r as Dictionary).get("via", cr.sim)
		if via.distance_to(cr.sim) > 0.01 and via.distance_to(np) > 0.01:
			cr.way.append(via)
		if np.distance_to(cr.sim) > 0.001:
			cr.way.append(np)
		cr.sim = np
		cr.floor_n = (r as Dictionary).get("n", Vector3.UP)
		return true

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
		var ncm := Kit.nc_on()
		var fresh := _stale                  # the stream came back after a gap: place them before they show
		var now := Time.get_ticks_msec()
		_rx_ms = now
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
				cr.be_born(p, ncm)
			elif ncm:
				# D5: the way from the last sample is checked and walked; a jump over 2 m between two
				# samples snaps (declared), never glides
				cr.rx_push(p, now, fresh or cr.g_last.distance_to(p) > 2.0)
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
		if not id.begins_with(tag + ":"):
			return null
		var i := int(id.substr(tag.length() + 1))
		if i < 0 or i >= crawlers.size():
			return null
		return crawlers[i]

	func noclip_points() -> Array:
		# the no-clip probe (spec 5.2, D6): one entry per visible crawler, centre 0.3 m up (a
		# floor-level centre would make every chord along a bumpy floor a false crossing)
		var out: Array = []
		if not hatched or not is_inside_tree():
			return out
		var kind := tag if (tag == "brood" or tag == "obrood") else "brood"
		var view := "host" if CoopSync.map_is_authority() else "guest"
		const ST := ["walk", "wind", "nip", "dead"]
		for i in crawlers.size():
			var cr: Crawler = crawlers[i]
			if cr.st == Crawler.UNBORN or not cr.is_visible_in_tree():
				continue
			out.append({"kind": kind, "id": "%s:%d" % [tag, i], "view": view,
					"c": [cr.global_position + Vector3.UP * 0.3], "cn": ["body"], "seg": [-1], "sp": 0.0,
					"x": [], "xn": [], "xc": [], "xg": [],
					"vis": true, "wl": false, "tp": cr.tp, "st": str(ST[clampi(cr.st, 0, 3)]), "fx": {}})
		return out


# ============================================================================ wall spiders

class WallSpider extends Node3D:
	# Clings under the rock over a walkway. When someone passes beneath it clicks for 1.0 s,
	# drops on a silk thread to head height, snaps once, and reels itself back up, then rests.
	# Light-fear C (v5.0): hold a lantern BEAM on it while it clicks (0.15 s), or while it waits
	# with someone within 14 m (0.6 s), and it screeches, scurries sideways and squeezes into the
	# rock instead of dropping. It stays hidden for rest_s, then skitters back. Glow and fires do
	# nothing: you have to aim.
	signal bit(who: Node3D, damage: float, id: String)

	const WAIT := 0
	const CLICK := 1
	const DROP := 2
	const HANG := 3
	const CLIMB := 4
	const REST := 5
	const SCATTER := 6
	const DAMAGE := 18.0
	const CLICK_S := 1.0
	const HANG_S := 0.6
	const REACH := 1.6
	const CLIMB_SPEED := 4.0
	# light-fear C
	const SCATTER_S := 0.9
	const SCATTER_SIDE := 2.2
	const SCATTER_UP := 0.4
	const SCATTER_SCALE := 0.2
	const LIGHT_K := 0.45              # beam_at(body, key, 0.5) at this k or more counts
	const LIGHT_CLICK_S := 0.15        # beam time that turns a CLICK into a SCATTER
	const LIGHT_WAIT_S := 0.6          # beam time that scares it off while it waits
	const LIGHT_WAIT_R := 14.0         # ...only with a living player this close (horizontally)
	const LIGHT_TICK := 0.1            # 10 Hz (R15): CLICK needs 2 lit samples, WAIT 6

	var rest_s := 25.0                 # the omen HUNGRY SILK sets 9.0 (every read uses this var)
	var trigger_r := 6.0               # ...and 8.0 here
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
	var hidden := false                # squeezed into the rock after a scatter (REST only)
	var last_scatter_why := ""         # "pre-emptive" or "click" (authority)
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
	var _lit_t := 0.0
	var _light_acc := 0.0
	var _scatter_dir := Vector3.RIGHT
	var _unhide_ms := -100000
	var _q_cling := Quaternion(Vector3(0, 0, 1), PI)          # belly up under the rock
	var _q_hang := Quaternion(Vector3(1, 0, 0), -PI * 0.5)    # head down on the thread
	# v5.0 no-clip (3.E; used only while the helper is on, Rule K)
	const ST_NAMES := ["wait", "click", "drop", "hang", "climb", "rest", "scatter"]
	const SWING := PI * 7.0 / 6.0     # the drop's pose turn (180 degrees) plus the ceiling tilt (30)
	const LOWER_STEPS := 40           # the perch may come down 40 x 0.1 m to keep the legs out of the rock
	const DROP_TRIES := 30            # perches whose whole drop is checked (about 150 rays each), once
	var _ncm := false
	var _fit_done := false
	var _yaw_seed := 0.0              # E2: from the id, the same on every machine
	var _scatter_a0 := 0.0            # E3: the first scatter heading tried (also from the id)
	var _rig_box := AABB()            # the rig's bounds in the pose frame
	var _up_ext := 0.0                # how far the rig reaches above the body origin in the cling pose
	var _rig_r := 1.2                 # the farthest rig corner from the body origin
	var _thread_top := 0.0            # the silk hangs from here (the anchor, or the fitted ceiling)
	var _q_tilt := Quaternion.IDENTITY  # the cling pose tilted to the ceiling, in the body frame
	var _sc_d: Array = []             # E3: distances along _scatter_dir...
	var _sc_dy: Array = []            # ...and how far the body top rises (+) or dips (-) there
	var _sc_rise := 0.0               # no heading passed: it flees this far up its own thread instead
	var _tp := 0                      # declared pose jumps (fit, un-hide) for the no-clip probe
	var _test_scatter := false        # noclip_test_scatter() waiting for the spider to be back up

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
		_thread_top = anchor.y
		# the side it scurries to: from the id, so every machine shows the same escape
		var a := float(posmod(hash(id), 3600)) / 3600.0 * TAU
		_scatter_dir = Vector3(cos(a), 0.0, sin(a))
		# E2/E3: a proper generator seeded from the id (hash(id) alone differs by ~1 between
		# "sp_1".."sp_9", which sent 9 of 11 spiders the same way)
		var rng := RandomNumberGenerator.new()
		rng.seed = hash(id + "#zonda#spider#pose")
		_yaw_seed = rng.randf() * TAU
		_scatter_a0 = rng.randf() * TAU

	func _ready() -> void:
		add_to_group("zonda_nc")             # the no-clip probe samples it (noclip_points)
		body = Node3D.new()
		body.position = Vector3(anchor.x, y, anchor.z)
		body.rotation.y = _yaw_seed if Kit.nc_on() else randf() * TAU
		add_child(body)
		pose = Node3D.new()
		pose.basis = Basis(_q_cling)
		body.add_child(pose)
		rig = Kit.make_rig("spider", 0.55, Color(0.2, 0.19, 0.16))
		pose.add_child(rig.root)
		_rig_box = Kit.rig_box(rig)
		var cb: AABB = Transform3D(Basis(_q_cling), Vector3.ZERO) * _rig_box
		_up_ext = maxf(0.0, cb.end.y)
		_rig_r = 0.3
		for i in 8:
			_rig_r = maxf(_rig_r, _rig_box.get_endpoint(i).length())
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
		body.visible = not hidden

	func _enter(s: int) -> void:
		# REST keeps the hidden flag its caller set (after a scatter); every other state shows it
		var was_hidden := hidden
		st = s
		st_t = 0.0
		_lit_t = 0.0
		_light_acc = 0.0
		if s != REST:
			hidden = false
		if body != null:
			body.visible = not hidden
		if s == CLICK:
			if CoopSync.map_is_authority():
				Kit.note("spider", "clicks")       # the telegraph (R9), counted once, where it is decided
			# the warning: a dry chatter from above, 1.0 s before it drops
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
		elif s == SCATTER:
			# the screech: claws, a thin hiss and the silk whipping up
			var os2 := Kit.oneshot("brood_skitter")
			var sk: AudioStream = os2[0]
			if sk != null:
				Kit.play(sfx_click, sk, float(os2[1]), 1.3)
			else:
				Kit.play(sfx_click, Kit.rand_stream("clicks", Kit.CLICKS, 1.25), 0.0, 2.0)
			var hs := Kit.oneshot("pale_hiss")
			var hst: AudioStream = hs[0]
			if hst != null:
				Kit.play(sfx_voice, hst, float(hs[1]), 1.7)
			Kit.play(sfx_silk, Kit.game_stream(Kit.SILK), -4.0, 2.0)
		elif s == WAIT and was_hidden:
			# back out of the crack: a quiet skitter
			_tp += 1                             # it reappears at its perch (declared for the probe)
			if _ncm and body != null and pose != null:
				_visual(0.0)                     # back on the perch at full size, even while far
			_unhide_ms = Time.get_ticks_msec()
			var os3 := Kit.oneshot("brood_skitter")
			var qs: AudioStream = os3[0]
			if qs != null:
				Kit.play(sfx_click, qs, float(os3[1]) - 10.0, 1.15)
			else:
				Kit.play(sfx_click, Kit.rand_stream("clicks", Kit.CLICKS, 1.25), -12.0, 1.8)

	func _process(delta: float) -> void:
		_t += delta
		st_t += delta
		_ncm = Kit.nc_on()
		if CoopSync.map_is_authority():
			_think(delta)
			rp_y = y
		else:
			y = lerpf(y, rp_y, clampf(delta * 12.0, 0.0, 1.0))
			if st == REST and hidden and st_t >= rest_s:
				_enter(WAIT)                # REST -> WAIT is not streamed: un-hide by ourselves
		_lod_t -= delta
		if _lod_t <= 0.0:
			_lod_t = 0.5
			_near = (Kit.listener(self) - anchor).length() < 110.0
			rig.set_active(_near)
			# E1: fit the cling pose once on this machine, when the spider matters here (the host
			# also fits it for a teammate far from the host, whose drop it runs and streams)
			if _ncm and not _fit_done and (_near or _player_near(110.0)):
				_nc_fit()
		if not _near and (st == WAIT or st == REST):
			return
		_visual(delta)

	func _player_near(r: float) -> bool:
		if not CoopSync.map_is_authority():
			return false
		for p in CoopSync.alive_player_nodes():
			if is_instance_valid(p) and (p as Node3D).is_inside_tree() and ((p as Node3D).global_position - anchor).length() < r:
				return true
		return false

	func _think(delta: float) -> void:
		if _test_scatter and (st == WAIT or st == CLICK or (st == REST and not hidden)):
			_test_scatter = false
			_scatter("test")                   # noclip_test_scatter(), once it is back on its perch
			return
		if st == WAIT:
			_scan_t -= delta
			if _scan_t > 0.0:
				return
			var near_light := false
			for p in CoopSync.alive_player_nodes():
				if not is_instance_valid(p) or not (p as Node3D).is_inside_tree():
					continue
				var pp: Vector3 = (p as Node3D).global_position
				var hd := Vector2(pp.x - anchor.x, pp.z - anchor.z).length()
				if hd < trigger_r and pp.y < anchor.y and pp.y > floor_pt.y - 4.0 and _sees(pp):
					_enter(CLICK)
					return
				if hd < LIGHT_WAIT_R and absf(pp.y - anchor.y) < 20.0:
					near_light = true
			# someone close with a lantern: a beam held on it scares it off before it clicks
			var step: float = LIGHT_TICK
			_scan_t = step
			if near_light and _beam_k() >= LIGHT_K:
				_lit_t += step
				if _lit_t >= LIGHT_WAIT_S - 0.001:
					_scatter("pre-emptive")
			else:
				_lit_t = 0.0
		elif st == CLICK:
			_light_acc += delta
			if _light_acc >= LIGHT_TICK:
				var ldt := _light_acc
				_light_acc = 0.0
				if _beam_k() >= LIGHT_K:
					_lit_t += ldt
					if _lit_t >= LIGHT_CLICK_S - 0.001:
						_scatter("click")
						return
				else:
					_lit_t = 0.0
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
				hidden = false
				_enter(REST)
		elif st == SCATTER:
			if st_t >= SCATTER_S:
				hidden = true
				_enter(REST)
		elif st == REST:
			if st_t >= rest_s:
				_enter(WAIT)

	func _beam_k() -> float:
		# the strongest lantern BEAM on the body (the LightField, maps/underdark/light.gd)
		var lf = CoopSync.get("light_field")
		if lf == null or not is_instance_valid(lf) or not lf.has_method("beam_at"):
			return 0.0
		var b = lf.beam_at(Vector3(anchor.x, y, anchor.z), get_instance_id(), 0.5)
		if b is Dictionary:
			return float((b as Dictionary).get("k", 0.0))
		return 0.0

	func _scatter(why: String) -> void:
		last_scatter_why = why
		print("[SPIDERLIGHT] %s scatter (%s)" % [id, why])
		_enter(SCATTER)

	func _sees(pp: Vector3) -> bool:
		# v5.1: rock between its perch and someone under it (a shelf, a slab: sp_2 of the v5.1 layout hangs
		# over one) means no click and no bite through it
		if not is_inside_tree():
			return false
		# cast from the player up to the perch (a perch tucked into the crack starts inside rock, where a
		# ray sees nothing): rock within 1 m of the perch is its own crack, anything further is in the way
		var perch := Vector3(anchor.x, cling_y - 0.3, anchor.z)
		var q := PhysicsRayQueryParameters3D.create(pp + Vector3(0.0, 0.4, 0.0), perch, 1)   # just under the eye (the origin is about 1 m up)
		var h := get_world_3d().direct_space_state.intersect_ray(q)
		return h.is_empty() or (h["position"] as Vector3).distance_to(perch) <= 1.0

	func _try_bite() -> void:
		# one snap at the bottom of the drop, only at someone still under it
		var at := Vector3(anchor.x, low_y, anchor.z)
		for p in CoopSync.alive_player_nodes():
			if not is_instance_valid(p) or not (p as Node3D).is_inside_tree():
				continue
			var d: Vector3 = (p as Node3D).global_position - at
			if Vector2(d.x, d.z).length() < REACH and d.y > -2.6 and d.y < 0.9 and _sees((p as Node3D).global_position):
				Kit.note("spider", "bites")
				bit.emit(p, DAMAGE, id)
				return

	func _visual(delta: float) -> void:
		var off := Vector3.ZERO
		var sc := 1.0
		if st == SCATTER:
			var sk := clampf(st_t / SCATTER_S, 0.0, 1.0)
			var e := 1.0 - (1.0 - sk) * (1.0 - sk)        # a fast start, slowing into the crack
			if _ncm:
				off = _nc_scatter_off(e)                   # E3: along the ceiling, not into it
			else:
				off = _scatter_dir * SCATTER_SIDE * e + Vector3.UP * SCATTER_UP * sk
			sc = lerpf(1.0, SCATTER_SCALE, sk)
		elif st == REST and hidden:
			if _ncm:
				off = _nc_scatter_off(1.0)
			else:
				off = _scatter_dir * SCATTER_SIDE + Vector3.UP * SCATTER_UP
			sc = SCATTER_SCALE
		if body.visible == hidden:
			body.visible = not hidden
		body.position = Vector3(anchor.x, y, anchor.z) + off
		var want_k := 1.0 if (st == DROP or st == HANG or st == CLIMB) else 0.0
		_k = lerpf(_k, want_k, clampf(delta * 9.0, 0.0, 1.0))
		if _ncm:
			# the turn from belly-up to head-down swings the legs through a half circle: it may only
			# turn as far as the drop below the perch leaves room, so no leg ever swings up into the
			# rock (on the way down, and back up on the climb)
			_k = minf(_k, _nc_k_cap(cling_y - y))
		var q := _q_cling.slerp(_q_hang, _k)
		if _ncm and _fit_done:
			q = _q_tilt.slerp(Quaternion.IDENTITY, _k) * q
		pose.basis = Basis(q).scaled(Vector3.ONE * sc)
		# the visible wind-up: it shivers and flexes against the rock while it clicks
		if st == CLICK:
			pose.position = Vector3(randf_range(-0.03, 0.03), randf_range(-0.05, 0.02), randf_range(-0.03, 0.03))
			_click_t -= delta
			if _click_t <= 0.0:
				_click_t = randf_range(0.08, 0.14)
				Kit.play(sfx_click, Kit.rand_stream("clicks", Kit.CLICKS, 1.2), 1.0, randf_range(1.6, 2.1))
		else:
			pose.position = Vector3.ZERO
		var ty := y + (off.y if _ncm and _sc_rise > 0.0 else 0.0)   # climbing its own thread: the silk ends at the body
		var gap := _thread_top - ty
		thread.visible = gap - (_up_ext if _fit_done else 0.0) > 0.3 and not (hidden and _ncm)
		if thread.visible:
			thread.position = Vector3(anchor.x, (_thread_top + ty) * 0.5, anchor.z)
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
			elif st == SCATTER:
				base = 0.7                           # a frantic scurry
				amp = 0.25
				freq = 16.0
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
			elif st == SCATTER:
				rig.play("walk", 0.05)
				rig.set_speed(2.4)
			elif st == CLICK:
				rig.play("idle", 0.1)
				rig.set_speed(2.8)
			else:
				rig.play("idle")
				rig.set_speed(1.0)

	func state_packet() -> Array:
		return [st, snappedf(y, 0.01), 1 if hidden else 0]

	func remote_state(a: Array) -> void:
		if a.size() < 2:
			return
		var s := int(a[0])
		rp_y = float(a[1])
		if _fit_done:
			# this machine fitted the perch itself (the same rays as the host): on the perch it sits
			# at its own fit, and it never climbs above it
			if s == WAIT or s == CLICK or s == REST or s == SCATTER:
				rp_y = cling_y
			else:
				rp_y = minf(rp_y, cling_y)
		var hid: bool = a.size() > 2 and int(a[2]) == 1
		if s == REST and st == WAIT and Time.get_ticks_msec() - _unhide_ms < 3000:
			return                           # it came back out here already: a late REST must not re-hide it
		if s != st:
			if s == REST:
				hidden = hid
			_enter(s)
		elif s == REST and hidden != hid:
			hidden = hid
			if body != null:
				body.visible = not hidden

	func threat_positions() -> Array:
		if st == WAIT or st == REST or st == SCATTER or hidden:
			return []
		return [Vector3(anchor.x, y, anchor.z)]

	func bite_origin(_id: String) -> Vector3:
		return Vector3(anchor.x, y, anchor.z)

	func play_bite(_id: String) -> void:
		if st != HANG:
			Kit.play(sfx_click, Kit.rand_stream("chomp", Kit.CHOMP, 1.15), 2.0, 1.2)

	# ---------------------------------------------------------------- v5.0 no-clip (3.E)

	func _nc_k_cap(d: float) -> float:
		# how far the belly-up -> head-down turn may go with the body d metres below its perch: a rig
		# point turned by angle a moves at most 2 r sin(a / 2), so it stays under the perch height
		var r2 := 2.0 * _rig_r
		if d >= r2:
			return 1.0
		if d <= 0.0:
			return 0.0
		return clampf(asin(d / r2) * 2.0 / SWING, 0.0, 1.0)

	func _nc_scatter_off(e: float) -> Vector3:
		# E3: the escape (e 0..1) along the chosen heading, the body top following the sampled
		# ceiling; a spider waiting on a thread under its crack flees up the thread instead; none
		# of those checked clear (or no fit): it shrinks in place
		if not _fit_done:
			return Vector3.ZERO
		if _sc_rise > 0.0:
			return Vector3.UP * _sc_rise * clampf(e, 0.0, 1.0)
		if _scatter_dir == Vector3.ZERO or _sc_d.size() < 2:
			return Vector3.ZERO
		var d := SCATTER_SIDE * clampf(e, 0.0, 1.0)
		var dy := 0.0
		for k in range(1, _sc_d.size()):
			var d0 := float(_sc_d[k - 1])
			var d1 := float(_sc_d[k])
			if d <= d1 or k == _sc_d.size() - 1:
				dy = lerpf(float(_sc_dy[k - 1]), float(_sc_dy[k]), clampf((d - d0) / maxf(d1 - d0, 0.001), 0.0, 1.0))
				break
		return _scatter_dir * d + Vector3.UP * dy

	func _nc_fit() -> void:
		# E1 + E2 + E3, once per machine: fit the cling pose under the real ceiling, pick the yaw that
		# keeps the four leg corners out of the rock, and choose the scatter heading along the ceiling
		var NC = Kit.nc()
		if NC == null or body == null or not is_inside_tree():
			return
		if not bool(NC.call("solid_at", anchor, 4.0)):
			return                               # its rock is not loaded here yet: the next LOD tick
		_fit_done = true
		var t0 := Time.get_ticks_usec()
		var space := get_world_3d().direct_space_state
		# E1: 9 rays up (the anchor and a 0.8 m ring) from 0.6 m under the anchor to 0.8 m over it
		var hy: Array = []
		var nsum := Vector3.ZERO
		for i in 9:
			var o := Vector3.ZERO
			if i > 0:
				var a := float(i - 1) / 8.0 * TAU
				o = Vector3(cos(a), 0.0, sin(a)) * 0.8
			var from := Vector3(anchor.x + o.x, anchor.y - 0.6, anchor.z + o.z)
			var h := Kit.nray(space, from, from + Vector3.UP * 1.4)
			if not h.is_empty():
				hy.append(float((h["position"] as Vector3).y))
				nsum += h["normal"] as Vector3       # Rule N: faces the ray's origin, into the air
		var tilt_w := Quaternion.IDENTITY
		var tilt_deg := 0.0
		var cy := cling_y
		if hy.size() >= 5:
			var lo := float(hy.min())
			_thread_top = lo
			cy = lo - _up_ext - 0.05
			if nsum.length() > 0.5:
				# its back (DOWN in the cling pose) tilts toward the ceiling's mean normal, at most 30 deg
				var nd := nsum.normalized()
				var ang := minf(Vector3.DOWN.angle_to(nd), deg_to_rad(30.0))
				var ax := Vector3.DOWN.cross(nd)
				if ang > 0.01 and ax.length() > 0.0001:
					tilt_w = Quaternion(ax.normalized(), ang)
					tilt_deg = rad_to_deg(ang)
		# E2 and the leg corners: the seeded yaw, then 30 degree steps; only when no yaw keeps all
		# four corners clear, the perch comes down 0.1 m at a time. Most perches sit in steep
		# crevices (the rock 1 to 2 m lower on one side within 0.8 m, checked against the mesh: 8 of
		# the 11 need 1.1 to 2.1 m), so it may come down up to 4 m: it then waits on a short thread
		# under its crack, in open air. A perch also has to leave room for the drop: the pose turning
		# head-down on the way down (and back up on the climb) is checked too, for a limited number
		# of candidates (ray budget); past that the first perch whose rest pose is clear is kept
		var yaw := _yaw_seed
		var lowered := -1.0
		var fb_yaw := _yaw_seed
		var fb_low := -1.0
		var tries := 0
		var swing_ok := false
		for k in LOWER_STEPS + 1:
			for j in 12:
				var yw := _yaw_seed + float(j) * TAU / 12.0
				var cyk := cy - 0.1 * float(k)
				if not _nc_corners_clear(space, yw, cyk, tilt_w):
					continue
				if fb_low < 0.0:
					fb_yaw = yw
					fb_low = 0.1 * float(k)
				tries += 1
				if _nc_drop_clear(space, yw, cyk, tilt_w):
					yaw = yw
					lowered = 0.1 * float(k)
					swing_ok = true
					break
				if tries >= DROP_TRIES:
					break
			if lowered >= 0.0 or tries >= DROP_TRIES:
				break
		if lowered < 0.0 and fb_low >= 0.0:
			yaw = fb_yaw
			lowered = fb_low
		if lowered > 0.0:
			cy -= lowered
		cling_y = cy
		low_y = minf(floor_pt.y + 1.75, cling_y - 1.0)
		_q_tilt = Quaternion(Vector3.UP, -yaw) * tilt_w * Quaternion(Vector3.UP, yaw)
		body.rotation = Vector3(0.0, yaw, 0.0)
		if st == WAIT or st == CLICK or st == REST or st == SCATTER:
			y = cling_y
			rp_y = cling_y
		_tp += 1
		_nc_pick_scatter(space)
		_visual(0.0)                         # the new pose at once (it is not redrawn while far)
		var us := Time.get_ticks_usec() - t0
		NC.call("add_usec", "spider", us)      # the one-time fit shows in the guard line and perf.flag
		print("[CLIP] fit spider %s ceiling_hits=%d/9 cling=%+.2f m tilt=%.0f deg yaw=%.0f deg corners=%s drop=%.1f m scatter=%s usec=%d" % [
				id, hy.size(), cling_y - (anchor.y - 0.05), tilt_deg, rad_to_deg(fposmod(yaw, TAU)),
				("clear" if lowered == 0.0 else ("lowered %.1f m" % lowered if lowered > 0.0 else "blocked")) + ("" if swing_ok else " swing_unchecked"),
				cling_y - low_y,
				("%.0f deg" % rad_to_deg(fposmod(atan2(_scatter_dir.z, _scatter_dir.x), TAU)) if _scatter_dir != Vector3.ZERO else ("up the thread %.1f m" % _sc_rise if _sc_rise > 0.0 else "in place")), us])

	func _nc_corners_clear(space, yw: float, cy: float, tilt_w: Quaternion) -> bool:
		# the four leg corners (the rig's feet side, pressed to the rock in the cling pose) and the
		# body centre must be in open air, with 6 cm to spare toward the ceiling and 5% outward (the
		# click's shiver moves it up to 3 cm)
		var b := Basis(tilt_w) * Basis(Vector3.UP, yw) * Basis(_q_cling)
		var o := Vector3(anchor.x, cy, anchor.z)
		var c := o + b * (Vector3.UP * 0.25)
		var col := Vector3(anchor.x, cy - 1.0, anchor.z)   # the drop column below (clear at every spider)
		if not Kit.nray(space, col, c).is_empty():
			return false
		for i in 4:
			var w := o + b * (_nc_corner(i) * Vector3(1.05, 1.0, 1.05)) + Vector3.UP * 0.06
			if not Kit.nray(space, c, w).is_empty():
				return false
		return true

	func _nc_pose_basis(yw: float, tilt_w: Quaternion, k: float) -> Basis:
		# the pose in the world at turn k (0 = cling, 1 = hanging), as _visual draws it
		var qy := Quaternion(Vector3.UP, yw)
		var ql := qy.inverse() * tilt_w * qy
		return Basis(qy * ql.slerp(Quaternion.IDENTITY, k) * _q_cling.slerp(_q_hang, k))

	func _nc_drop_clear(space, yw: float, cy: float, tilt_w: Quaternion) -> bool:
		# the drop from a perch at cy, pose turned as far as _nc_k_cap lets it (the turn is never
		# further than that): every 0.1 m while it may still be turning, then hanging, down to the
		# bite height. The centre's path and the four centre-to-corner lines stay in open air
		var low := minf(floor_pt.y + 1.75, cy - 1.0)
		var span := cy - low
		var r2 := 2.0 * _rig_r
		var steps: Array = []
		var d := 0.1
		while d < minf(span, r2):
			steps.append([d, _nc_k_cap(d)])
			d += 0.1
		d = minf(span, r2)
		while d <= span + 0.001:
			steps.append([d, _nc_k_cap(d)])
			d += 0.5
		var prev_c := Vector3(anchor.x, cy, anchor.z) + _nc_pose_basis(yw, tilt_w, 0.0) * (Vector3.UP * 0.25)
		for s in steps:
			var o := Vector3(anchor.x, cy - float(s[0]), anchor.z)
			var b := _nc_pose_basis(yw, tilt_w, float(s[1]))
			var c := o + b * (Vector3.UP * 0.25)
			if not Kit.nray(space, prev_c, c).is_empty():
				return false
			for i in 4:
				if not Kit.nray(space, c, o + b * _nc_corner(i) + Vector3.UP * 0.03).is_empty():
					return false
			prev_c = c
		return true

	func _nc_pick_scatter(space) -> void:
		# E3: 12 headings, 30 degrees apart, from the seeded one. A heading passes when a side ray at
		# mid-body is clear for 2.6 m and the ceiling 1.2 m and 2.4 m along it lies between 0.3 m
		# under and 0.45 m over the body top. The body top then rides 5 cm under the lowest ceiling
		# found under its whole (shrinking) footprint, never above its rest height, and the escape is
		# checked every 0.2 m the way the probe sees it: the centre's path and the four leg corners.
		# None passes: up its own thread (when it waits on one), else it shrinks in place.
		_scatter_dir = Vector3.ZERO
		_sc_d = []
		_sc_dy = []
		_sc_rise = 0.0
		var top0 := cling_y + _up_ext
		var b0 := Basis(Vector3.UP, body.rotation.y) * Basis(_q_tilt) * Basis(_q_cling)
		var o0 := Vector3(anchor.x, cling_y, anchor.z)
		for i in 12:
			var ang := _scatter_a0 + float(i) * TAU / 12.0
			var dir := Vector3(cos(ang), 0.0, sin(ang))
			var p0 := Vector3(anchor.x, cling_y - 0.25, anchor.z)
			if not Kit.nray(space, p0, p0 + dir * 2.6).is_empty():
				continue
			# the ceiling every 0.4 m: under the centre line and under the four corners
			var ds: Array = [0.0]
			var tops: Array = [top0]
			var ok := true
			for k in range(1, 7):
				var dd := 0.4 * float(k)
				var sc := _nc_scale_at(dd)
				var lowest := INF
				for j in 5:
					var q := o0 + dir * dd
					if j > 0:
						q += b0 * (_nc_corner(j - 1) * sc)
					var h := Kit.nray(space, Vector3(q.x, top0 - 0.3, q.z), Vector3(q.x, top0 + 0.45, q.z))
					if not h.is_empty():
						lowest = minf(lowest, float((h["position"] as Vector3).y))
					elif j == 0 and (k == 3 or k == 6):
						ok = false                   # 1.2 m and 2.4 m out: no ceiling in reach there
						break
				if not ok:
					break
				ds.append(dd)
				tops.append(minf(top0, lowest - 0.05))
			if not ok:
				continue
			var dys: Array = [0.0]
			for k in range(1, ds.size()):
				var m := minf(float(tops[k]), float(tops[k - 1]))
				if k + 1 < ds.size():
					m = minf(m, float(tops[k + 1]))
				dys.append(m - top0)
			_sc_d = ds
			_sc_dy = dys
			_scatter_dir = dir
			# the escape as drawn, every 0.2 m: the centre's path and the centre-to-corner lines clear
			var prev_c := o0 + b0 * (Vector3.UP * 0.25)
			for s in range(1, 12):
				var e := float(s) / 11.0
				var sc2 := _nc_scale_at(SCATTER_SIDE * e)
				var o := o0 + _nc_scatter_off(e)
				var c := o + b0 * (Vector3.UP * 0.25 * sc2)
				if not Kit.nray(space, prev_c, c).is_empty():
					ok = false
					break
				for j in 4:
					if not Kit.nray(space, c, o + b0 * (_nc_corner(j) * sc2) + Vector3.UP * 0.03).is_empty():
						ok = false
						break
				if not ok:
					break
				prev_c = c
			if ok:
				return
			_scatter_dir = Vector3.ZERO
			_sc_d = []
			_sc_dy = []
		# waiting on a thread under its crack (the perch was lowered): up the thread, shrinking, to
		# just under the rock, or part of the way; checked the same way
		var full := _thread_top - top0 - 0.05
		if full < 0.3:
			return
		for part in [1.0, 0.75, 0.5]:
			_sc_rise = full * float(part)
			var ok2 := true
			var prev_c := o0 + b0 * (Vector3.UP * 0.25)
			for s in range(1, 12):
				var e := float(s) / 11.0
				var sc2 := _nc_scale_at(SCATTER_SIDE * e)
				var o := o0 + _nc_scatter_off(e)
				var c := o + b0 * (Vector3.UP * 0.25 * sc2)
				if not Kit.nray(space, prev_c, c).is_empty():
					ok2 = false
					break
				for j in 4:
					if not Kit.nray(space, c, o + b0 * (_nc_corner(j) * sc2) + Vector3.UP * 0.03).is_empty():
						ok2 = false
						break
				if not ok2:
					break
				prev_c = c
			if ok2:
				return
		_sc_rise = 0.0

	func _nc_corner(j: int) -> Vector3:
		# the rig's four feet-side corners (pressed to the rock in the cling pose), in the pose frame
		return Vector3(_rig_box.position.x if j % 2 == 0 else _rig_box.end.x, _rig_box.position.y,
				_rig_box.position.z if j < 2 else _rig_box.end.z)

	func _nc_scale_at(d: float) -> float:
		# the body's scale when the scatter has carried it d metres (e = d / SCATTER_SIDE)
		var e := clampf(d / SCATTER_SIDE, 0.0, 1.0)
		var sk := 1.0 - sqrt(maxf(0.0, 1.0 - e))
		return lerpf(1.0, SCATTER_SCALE, sk)

	func noclip_test_scatter() -> void:
		# the no-clip probe (P6): the light-fear escape on demand. Authority only; from a drop it
		# waits until the spider is back on its perch
		if not CoopSync.map_is_authority():
			return
		if st == SCATTER or (st == REST and hidden):
			return
		_test_scatter = true

	func noclip_points() -> Array:
		# the no-clip probe (spec 5.2, E4): centre 0.25 m off its ceiling (along the pose's own up,
		# so it follows the drop and the shrink), extremities = the 4 leg corners pressed to the rock
		if body == null or pose == null or not is_inside_tree():
			return []
		var xf := pose.global_transform
		var xs: Array = []
		for i in 4:
			xs.append(xf * _nc_corner(i))
		return [{"kind": "spider", "id": id, "view": "host" if CoopSync.map_is_authority() else "guest",
				"c": [xf * (Vector3.UP * 0.25)], "cn": ["body"], "seg": [-1], "sp": 0.0,
				"x": xs, "xn": ["leg", "leg", "leg", "leg"], "xc": [0, 0, 0, 0], "xg": [false, false, false, false],
				"vis": body.is_visible_in_tree(), "wl": hidden, "tp": _tp,
				"st": str(ST_NAMES[clampi(st, 0, ST_NAMES.size() - 1)]), "fx": {}}]


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
		add_to_group("zonda_nc")             # no-clip probe (3.F): props whitelisted, no points
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

	func noclip_points() -> Array:
		# the no-clip probe (spec 5.2, 3.F): the husk's props are intended contact (whitelisted) and
		# its jitter is under 7 cm; the live centipede it becomes reports itself (3.A)
		return [{"kind": "husk", "id": id, "view": "host" if CoopSync.map_is_authority() else "guest",
				"c": [], "cn": [], "seg": [], "sp": 0.0, "x": [], "xn": [], "xc": [], "xg": [],
				"vis": is_visible_in_tree(), "wl": true, "tp": 0,
				"st": str(["asleep", "shivering", "awake"][clampi(phase, 0, 2)]), "fx": {}}]

	func noclip_test_wake() -> bool:
		# test hook (authority): start the shiver as if someone stood on the trigger; the map's
		# normal wake path then spawns the live pale centipede. false when it is not asleep here
		if not CoopSync.map_is_authority() or phase != 0 or not is_processing():
			return false
		_begin()
		return true
