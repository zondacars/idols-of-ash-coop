extends "res://scripts/Actionable.gd"
# One skull on the Omen Altar (THE UNDERDARK, v5.0). The altar builds an Area3D (layer 1, a 0.5 m
# sphere, monitorable) and gives it this script: the climber's ActionableFinder then shows the
# game's own E prompt with displayed_action_text, which the altar keeps up to date. Pressing E
# calls action(), which hands the skull's omen id to the altar. It never starts Dialogic.

var altar = null          # the omen module's Altar node (omen.gd)
var omen_id := ""


func _init() -> void:
	auto_trigger = false


func action() -> void:
	if altar != null and is_instance_valid(altar) and altar.has_method("on_press"):
		altar.call("on_press", omen_id)
