extends Node

# ============================================================================================
# HEARING (ZondaCoopSync 5.1, feature "hearing"): the dev test for the sound rules (the owner's
# pick: the sidewinder, the stalkers and the bat colonies hunt by sound; the sidewinder has its
# own test). Inert in play. hearing.flag -> "[HEAR] test done N/N PASS".
#   bats: the burst radius is 40% of the colony's trigger when quiet, the trigger when talking and
#         2.5 times it when shouting
#   the stalker: a silent, still player 20 m away in its zone is not hunted; shouting is; when the
#         player goes quiet it searches where it last heard them, then goes home
# ============================================================================================

const TAG := "[HEAR]"
var map: Node = null


func setup(m: Node) -> void:
	map = m
	var flag = map.call("dev_flag", "hearing.flag") if map.has_method("dev_flag") else null
	if flag == null:
		return
	if CoopSync.has_method("use_test_files"):
		CoopSync.call("use_test_files")
	CoopSync.set("noise_force", 0)
	var t := HearTest.new()
	t.map = map
	add_child(t)
	print("%s test on" % TAG)


class HearTest extends Node:
	var map = null
	var t := 0.0
	var phase := 0
	var mark := 0.0
	var n_pass := 0
	var n_total := 0
	var fails: Array = []
	var st = null
	var spot := Vector3.ZERO
	var mark2 := 0.0

	func ok(key: String, cond: bool, text: String) -> void:
		n_total += 1
		if cond:
			n_pass += 1
			print("%s PASS %s" % [TAG, text])
		else:
			fails.append(key)
			print("%s FAIL %s" % [TAG, text])

	func _process(delta: float) -> void:
		var c = Game.climber
		if not is_instance_valid(c) or not c.is_inside_tree() or phase < 0:
			return
		t += delta
		c.prevent_player_death = true
		match phase:
			0:
				if t < 3.0:
					return
				var bat = null
				for n in get_tree().get_nodes_in_group("zonda_nc"):
					if n.has_method("burst_radius"):
						bat = n
						break
				if bat == null:
					ok("bats", false, "no bat colony found")
				else:
					var trig: float = float(bat.get("trig"))
					CoopSync.set("noise_force", 0)
					var q: float = bat.burst_radius(c)
					CoopSync.set("noise_force", 2)
					var tk: float = bat.burst_radius(c)
					CoopSync.set("noise_force", 3)
					var sh: float = bat.burst_radius(c)
					ok("bats", absf(q - trig * 0.4) < 0.01 and absf(tk - trig) < 0.01 and absf(sh - trig * 2.5) < 0.01,
							"bat colony bursts at %.1f m quiet, %.1f talking, %.1f shouting (trigger %.1f)" % [q, tk, sh, trig])
				var sts = map.get("_stalkers")
				if not (sts is Array) or (sts as Array).is_empty():
					ok("stalker", false, "no stalker")
					_finish()
					return
				st = sts[0]
				# a spot in its zone 20 m from where it rests
				var home: Vector3 = st.get("home")
				spot = home
				var space = c.get_world_3d().direct_space_state
				for a in 16:
					var q2: Vector3 = home + Vector3(sin(a * TAU / 16.0), 0.0, cos(a * TAU / 16.0)) * 20.0
					var hit: Dictionary = space.intersect_ray(PhysicsRayQueryParameters3D.create(q2 + Vector3(0, 4, 0), q2 + Vector3(0, -8, 0), 1))
					if not hit.is_empty() and st.call("_in_zone", hit["position"]):
						spot = (hit["position"] as Vector3) + Vector3(0, 1.0, 0)
						break
				CoopSync.set("noise_force", 0)
				map.call("debug_park", spot)
				mark = t
				phase = 1
			1:
				if t - mark < 4.0:
					return
				var tp: Vector3 = st.get("target_pos")
				ok("silent", tp.distance_to(st.get("home")) < 2.0, "silent and still 20 m away: it stays home (target %.1f m from its home)" % tp.distance_to(st.get("home")))
				CoopSync.set("noise_force", 3)
				mark = t
				phase = 2
			2:
				# shouting: it hears me at once (it is fast: it may already have bitten and be slinking off)
				if t - mark < 1.0:
					return
				var hm := int(st.get("_heard_ms"))
				ok("shout", Time.get_ticks_msec() - hm < 1500, "shouting 20 m away: it heard me and came (last heard %d ms ago, retreat %.1f)" % [Time.get_ticks_msec() - hm, float(st.get("retreat"))])
				CoopSync.set("noise_force", 0)
				mark = t
				phase = 3
			3:
				# quiet: after its retreat it creeps to where it last heard me
				if float(st.get("retreat")) > 0.0 and t - mark < 6.0:
					mark2 = t
					return
				if t - mark2 < 0.6:
					return
				var tp3: Vector3 = st.get("target_pos")
				var ha: Vector3 = st.get("_heard_at")
				ok("search", tp3.distance_to(ha + Vector3.UP * 0.8) < 1.0, "gone quiet: it searches where it heard me (target %.1f m from there)" % tp3.distance_to(ha + Vector3.UP * 0.8))
				mark = t
				phase = 4
			4:
				if t - mark < 9.0:
					return
				var tp4: Vector3 = st.get("target_pos")
				ok("home", tp4.distance_to(st.get("home")) < 2.0, "quiet for 10 s: it goes home")
				_finish()

	func _finish() -> void:
		phase = -1
		CoopSync.set("noise_force", 9)
		var c = Game.climber
		if is_instance_valid(c):
			c.prevent_player_death = false
		if fails.is_empty():
			print("%s test done %d/%d PASS" % [TAG, n_pass, n_total])
		else:
			print("%s test done %d/%d FAIL: %s" % [TAG, n_pass, n_total, ", ".join(PackedStringArray(fails))])
