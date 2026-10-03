extends AnimatableBody3D


const DoorLoweringSpeed = 1.0
#Set the door status default to be unsolved and not opened
var isOpen = false
var isSolved = false
var endPosition = self.position.y - 7.5

func _physics_process(delta: float) -> void:
	pass
	if isSolved:
		#This is just a calculation not an actual movement
		position.y = move_toward(position.y, endPosition, DoorLoweringSpeed * delta)
		if position.y == endPosition:
			#Set open to true
			isOpen = true
		else:
			pass
