extends Area3D

@onready var Player = get_node("../Player")

var pressed = false

func _on_body_entered(body: Node3D) -> void:
	if body == Player:
		pressed = true
		print("Plate 1 has been pressed")
		#if correctsequence:
			#set colour to green 
		#else:
			#set colour to red for a few seconds then back to white

#reset the puzzle signal
#pressed = false
#set colour to white
