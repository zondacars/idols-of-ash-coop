extends "res://treasure_pickup.gd"

var _coop_consumed := false


func on_picked_up() -> void:
	if _coop_consumed:
		return
	_coop_consumed = true
	print("[CoopSync] local pickup %s at %s" % [String(get_path()), str(global_position)])
	if CoopSync.in_session():
		CoopSync.broadcast_pickup(String(get_path()), global_position)
	super()


func coop_remote_consume() -> void:
	if _coop_consumed:
		return
	_coop_consumed = true
	queue_free()
