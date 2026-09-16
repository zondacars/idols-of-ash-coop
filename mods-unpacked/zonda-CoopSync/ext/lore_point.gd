extends "res://scripts/lore_point.gd"


func action() -> void:
	super()
	if CoopSync.in_session():
		CoopSync.broadcast_checkpoint()
		CoopSync.on_checkpoint_reached()
