extends "res://scripts/centipede_3d_pathfinder.gd"

# ZondaCoopSync v5.0, creature no-clip (spec revision 2, 3.A A5; group NC-2). Registered in
# coop_sync.gd EXTENSIONS. EVERY change is gated on the no-clip helper being on (THE UNDERDARK live,
# helper loaded, guard on); everywhere else the game's pathfinder runs unchanged (Rule K).
# - Rule N: a hit normal is flipped to face the ray's origin (the cave's winding is inconsistent, so
#   a normal can point INTO the rock and the node would be placed 1.6 m inside it).
# - Column and width rules (owner decision 7A: big creatures never follow into gaps they do not fit):
#   a new neighbour node is kept only when its column is clear for ENV.gap (3.85 m: ride 1.6 + head
#   2.2 + 0.05) along its normal, and two side rays of ENV.half_w + 0.05 (2.35 m) across the travel
#   direction, in the node's surface plane, are clear (the head is 4.6 m wide). +3 rays per node.
# - create_path_node_from_loc: the node sits along THIS hit's normal (the base used the previous hit's),
#   12 m rays, hits under 0.1 m ignored, the node must see loc (else the next of the 3 closest, else
#   loc itself), and never Vector3.ZERO.
# - Targets that sit ON the rock are pulled into air: a claw target moves 1.5 m toward its player, a
#   wander-family target (the game's wander, CoopWander, CoopLore) 2 m back toward the head.
# - Accepted path requests count "repaths" (both Rule K branches; the helper counts only while the
#   noclip probe measures).
# The helper is reached through the centipede (ext/centipede.gd nc(), nc_on(), nc_env_value()).

const NC_SIDE_PAD := 0.05
# A failing search must not freeze a centipede. The game raises its node limit with every miss (2000 up to 16000
# nodes, 3 up to 5 a frame: measured, a centipede stood still for the whole 35 s of a test with a search in flight)
# and drops every other request meanwhile. That is harmless in the game's dense graph, where every target is
# reachable, but with the head-fit rules some targets are not (a player pressed against a wall, a ledge too narrow),
# so those searches always run their whole limit. Guarded searches get a fixed limit, a faster rate and a wall-clock
# cap: a search that cannot reach its target ends in about two seconds with the closest node found so far.
const NC_SEARCH_NODES := 2500
const NC_SEARCH_RATE := 10
const NC_SEARCH_MS := 2200


func _nc_on() -> bool:
	return is_instance_valid(_centipede) and _centipede.has_method("nc_on") and bool(_centipede.call("nc_on"))


func _nc_helper():
	if is_instance_valid(_centipede) and _centipede.has_method("nc"):
		return _centipede.call("nc")
	return null


func _nc_kind() -> String:
	if is_instance_valid(_centipede) and _centipede.has_method("_nc_kind"):
		return str(_centipede.call("_nc_kind"))
	return "centipede"


func _nc_env(key: String, dflt: float) -> float:
	if is_instance_valid(_centipede) and _centipede.has_method("nc_env_value"):
		return float(_centipede.call("nc_env_value", key, dflt))
	return dflt


func _nc_note(key: String) -> void:
	var NC = _nc_helper()
	if NC != null:
		NC.call("note", _nc_kind(), key, 1)


var _nc_us := 0                          # time spent in this pathfinder's own no-clip rays (cost report)
var _nc_cancel := false                  # the search in flight belongs to a state that has been left: end it now


func nc_cancel() -> void:
	# called by the centipede's set_state when the state changes (ext/centipede.gd)
	if path_finding_in_progress:
		_nc_cancel = true


func _nc_clear(space, a: Vector3, b: Vector3) -> bool:
	var NC = _nc_helper()
	if NC == null:
		return true
	var t0 := Time.get_ticks_usec()
	var r = NC.call("ray", space, a, b)
	_nc_us += Time.get_ticks_usec() - t0
	return not (r is Dictionary) or (r as Dictionary).is_empty()


func _nc_begin() -> String:
	# the helper counts the rays below under this centipede's kind; returns the previous kind
	var NC = _nc_helper()
	if NC == null or not NC.has_method("count_as"):
		return ""
	return str(NC.call("count_as", _nc_kind()))


func _nc_end(prev: String) -> void:
	var NC = _nc_helper()
	if NC == null:
		return
	if NC.has_method("count_as"):
		NC.call("count_as", prev)
	if _nc_us > 0:
		NC.call("add_usec", _nc_kind(), _nc_us)
		_nc_us = 0


func create_path_node_from_ray_results(results: Dictionary) -> path_node:
	if not _nc_on():
		return super(results)
	# Rule N with the shared ray_params (every caller sets from / to right before the call): no new ray
	var node = path_node.new()
	var n: Vector3 = results["normal"]
	if n.dot(ray_params.to - ray_params.from) > 0.0:
		n = -n
	node.normal = n
	node.position = results["position"] + n * follow_path_height
	return node


func create_new_neighbor_path_nodes_from_node(node: path_node) -> Array[path_node]:
	if not _nc_on() or not is_instance_valid(_centipede) or _centipede.get_world_3d() == null:
		return super(node)
	var space := _centipede.get_world_3d().direct_space_state
	var gap := _nc_env("gap", 3.85)
	var half := _nc_env("half_w", 2.3) + NC_SIDE_PAD
	var new_nodes: Array[path_node] = []
	var prev := _nc_begin()
	for d in range(6):
		var angle = (d / 6.0) * TAU * (5.0 / 6.0)
		var new_node: path_node = try_find_new_node_from_node(node, node.get_dir_from_angle(angle))
		if new_node:
			var new_node_hash: int = path_node.get_spatial_hash_for_position(new_node.position)
			if not existing_node_hashes.has(new_node_hash) and has_line_of_sight(node.position, new_node.position):
				if is_valid_path_node_position(node.position) and _nc_fits(space, node, new_node, gap, half):
					existing_node_hashes.set(new_node_hash, true)
					new_nodes.append(new_node)
	_nc_end(prev)
	return new_nodes


func _nc_fits(space, parent: path_node, nn: path_node, gap: float, half: float) -> bool:
	# the column (headroom along the node's normal) and the width (both sides across the travel)
	var n := nn.normal.normalized()
	if n.length() < 0.5:
		return true
	var hit := nn.position - n * follow_path_height
	if not _nc_clear(space, hit + n * 0.05, hit + n * gap):
		_nc_note("col_drops")
		return false
	var dir := nn.position - parent.position
	dir -= n * dir.dot(n)
	if dir.length() < 0.01:
		return true
	var side := n.cross(dir.normalized()).normalized()
	if not _nc_clear(space, nn.position, nn.position + side * half) or not _nc_clear(space, nn.position, nn.position - side * half):
		_nc_note("width_drops")
		return false
	return true


func create_path_node_from_loc(loc: Vector3) -> path_node:
	if not _nc_on():
		return await super(loc)
	var new_path_node: path_node = path_node.new()
	new_path_node.normal = Vector3.UP
	new_path_node.position = loc            # no hit at all: the node is loc itself, never Vector3.ZERO
	var cands: Array = []                   # the 3 closest: [dist, node position, normal]
	if is_instance_valid(_centipede) and _centipede.get_world_3d():
		for t in range(30):
			if t % 6 == 0:
				await get_tree().physics_frame
			if not is_instance_valid(_centipede) or not _centipede.is_inside_tree() or _centipede.get_world_3d() == null:
				break
			var to: Vector3 = loc + math_helpers.createRandomUnitVector3D() * 12.0
			var ray: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(loc, to, 1)
			var results: Dictionary = _centipede.get_world_3d().direct_space_state.intersect_ray(ray)
			if results.is_empty():
				continue
			var hp: Vector3 = results["position"]
			var dist: float = hp.distance_to(loc)
			if dist < 0.1:
				continue
			var n: Vector3 = results["normal"]
			if n.dot(to - loc) > 0.0:
				n = -n                      # Rule N: toward loc
			var node_position: Vector3 = hp + n * follow_path_height
			if not is_valid_path_node_position(node_position):
				continue
			cands.append([dist, node_position, n])
			cands.sort_custom(func(a, b): return float(a[0]) < float(b[0]))
			if cands.size() > 3:
				cands.resize(3)
	if is_instance_valid(_centipede) and _centipede.is_inside_tree() and _centipede.get_world_3d() != null:
		var space := _centipede.get_world_3d().direct_space_state
		var prev := _nc_begin()
		for c in cands:
			if _nc_clear(space, loc, c[1]):
				new_path_node.position = c[1]
				new_path_node.normal = c[2]
				break
		_nc_end(prev)
	return new_path_node


func find_new_path_to_node_single_path(start_node: path_node, end_node: path_node, out: pathfinder_output):
	if not _nc_on():
		await super(start_node, end_node, out)
		return
	# the game's search (a copy) with three changes: it ends as soon as _nc_cancel is set, and its limit, rate and
	# time cap are the NC_SEARCH_* constants instead of the game's miss-driven ones (see above)
	var has_found_goal := false
	existing_node_hashes.clear()
	clear_node_data(start_node)
	clear_node_data(end_node)
	var open_list: Array[path_node]
	open_list.append(null)
	open_list.append(start_node)
	var closest_node_to_goal: path_node = null
	var closest_node_to_goal_heuristic: float = 999999.9
	var current_node: path_node = null
	var nodes_searched: int = 0
	var node_search_limit: int = NC_SEARCH_NODES
	var node_search_rate: int = NC_SEARCH_RATE
	var t_search := Time.get_ticks_msec()
	while (open_list.size() > 1 and not has_found_goal and nodes_searched < node_search_limit and is_inside_tree() and not _nc_cancel \
			and Time.get_ticks_msec() - t_search < NC_SEARCH_MS):
		nodes_searched_this_frame += 1
		if nodes_searched_this_frame > node_search_rate:
			nodes_searched_this_frame = 0
			await get_tree().physics_frame
		if _nc_cancel:
			break
		current_node = open_list[1]
		current_node.category = path_node_category.Closed
		open_list[1] = open_list[open_list.size() - 1]
		open_list.remove_at(open_list.size() - 1)
		nodes_searched += 1
		var v := 1
		var u: int
		while (true):
			u = v
			if (2 * u + 1 <= open_list.size() - 1):
				if (open_list[u].f_cost >= open_list[2 * u].f_cost):
					v = 2 * u
				if (open_list[v].f_cost >= open_list[2 * u + 1].f_cost):
					v = 2 * u + 1
			elif (2 * u <= open_list.size() - 1):
				if (open_list[u].f_cost >= open_list[2 * u].f_cost):
					v = 2 * u
			if (u != v):
				var tmp := open_list[u]
				open_list[u] = open_list[v]
				open_list[v] = tmp
			else:
				break
		if (current_node.position.distance_squared_to(end_node.position) <= 4.0 and has_line_of_sight(current_node.position, end_node.position)):
			has_found_goal = true
			break
		var current_node_neighbors := create_new_neighbor_path_nodes_from_node(current_node)
		for neighbor in current_node_neighbors:
			if neighbor.category == path_node_category.Closed:
				continue
			var neighbor_to_current_heuristic := heuristic(neighbor, current_node)
			var neighbor_to_goal_heuristic := heuristic(neighbor, end_node)
			if neighbor.category == path_node_category.Default:
				if not open_list.has(neighbor):
					open_list.append(neighbor)
				neighbor.category = path_node_category.Open
				neighbor.search_parent = current_node
				neighbor.g_cost = current_node.g_cost + neighbor_to_goal_heuristic * h_weight
				neighbor.h_cost = neighbor_to_goal_heuristic * h_weight
				neighbor.f_cost = neighbor.g_cost + neighbor.h_cost * h_weight
				sort_open_list(open_list)
			elif neighbor.g_cost > current_node.g_cost + neighbor_to_current_heuristic:
				neighbor.g_cost = current_node.g_cost + neighbor_to_current_heuristic * h_weight
				neighbor.f_cost = neighbor.g_cost + neighbor.h_cost * h_weight
				neighbor.search_parent = current_node
				sort_open_list(open_list)
			if not closest_node_to_goal or neighbor_to_goal_heuristic < closest_node_to_goal_heuristic:
				closest_node_to_goal = neighbor
				closest_node_to_goal_heuristic = neighbor_to_goal_heuristic
	out.reached_target = has_found_goal
	out.closest_node_to_end_found = closest_node_to_goal
	if has_found_goal:
		prep_solution(current_node, out)
	else:
		prep_solution(closest_node_to_goal, out)


func find_new_path_to_node(target_node: Node3D, state: centipede_state_follow_path):
	if _nc_on() and is_instance_valid(target_node) and is_instance_valid(_centipede) and _centipede.is_inside_tree():
		var is_claw: bool = target_node.has_method("unhook_from_centipede") or target_node == CoopSync.target_attached_claw_node(_centipede)
		if is_claw:
			# the claw sits ON the rock: aim 1.5 m out from it, toward its player
			var claw := target_node.global_position
			var pp := CoopSync.target_player_position(_centipede)
			var t := claw
			if pp.distance_to(claw) > 0.01:
				t = claw + (pp - claw).normalized() * 1.5
			return await find_new_path_to_position(t, state)
	return await super(target_node, state)


func find_new_path_to_position(target_position: Vector3, state: centipede_state_follow_path):
	var accepted := not path_finding_in_progress
	if accepted:
		_nc_note("repaths")
	var t := target_position
	if accepted and _nc_on() and state is centipede_state_wander and is_instance_valid(_centipede):
		# the wander rays return the raw hit on the rock face: the goal moves 2 m back into air
		var head := _centipede.global_position
		if t.distance_to(head) > 6.0:
			t = t + (head - t).normalized() * 2.0
	if accepted:
		_nc_cancel = false
	var t_req := Time.get_ticks_msec()
	await super(t, state)
	if accepted:
		# how long the search kept this centipede waiting (the no-clip probe compares it with the game's own)
		var lat := Time.get_ticks_msec() - t_req
		_nc_note("path_n")
		var NC = _nc_helper()
		if NC != null:
			NC.call("note", _nc_kind(), "path_ms", lat)
			if lat > 3000:
				NC.call("note", _nc_kind(), "path_slow", 1)
