extends "res://scripts/ending_trigger_area.gd"


func _on_body_entered(body: Node3D) -> void:
	if body == Game.climber and CoopSync.in_session():
		CoopSync.broadcast_ending()
	super(body)
