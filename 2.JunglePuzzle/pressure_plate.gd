extends Area3D

@export var plateNumber = 1

@onready var Player = get_node("../Player")
@onready var plateMesh = $MeshInstance3D

var pressed = false

signal plate_pressed(plateNumber)

func _on_body_entered(body: Node3D) -> void:
	if body == Player and !pressed:
		pressed = true
		#print("Plate ", plateNumber, " has been pressed")
		plate_pressed.emit(plateNumber)

func _on_puzzle_correct(correctPlateNumber):
	#print("Correct signal recieved by plate ", self.plateNumber)
	if correctPlateNumber == self.plateNumber:
		#turn off "collision"
		set_deferred("monitoring", false)
		plateMesh.material_override.albedo_color = Color.GREEN

func _on_puzzle_incorrect(wrongPlateNumber):
	pressed = false
	if wrongPlateNumber == self.plateNumber:
		plateMesh.material_override.albedo_color = Color.RED
		set_deferred("monitoring", false)
		$Timer.start()
	else:
		plateMesh.material_override.albedo_color = Color.WHITE
		set_deferred("monitoring", true)
		
func _on_timer_timeout():
	plateMesh.material_override.albedo_color = Color.WHITE
	set_deferred("monitoring", true)
	
func reset_plate():
	plateMesh.material_override.albedo_color = Color.WHITE
	pressed = false
	set_deferred("monitoring", true)
