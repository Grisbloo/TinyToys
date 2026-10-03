extends Node3D

@onready var Door = $Door
@onready var LivesLabel = $CanvasLayer/Label

var sequence = [1,2,3,4,5,6,7]
var currentstep = 0
var lives = 3
signal correct(plateNumber)
signal incorrect(plateNumber)

func _ready():
	sequence.shuffle()
	#print(sequence)
	LivesLabel.text = "Lives: " + str(lives)

func _on_pressure_plate_pressed(plateNumber):
	if currentstep >= sequence.size():
		return
	if plateNumber == sequence[currentstep]:
		correct.emit(plateNumber)
		currentstep += 1
		if currentstep == sequence.size():
			Door.isSolved = true
	else:
		incorrect.emit(plateNumber)
		lives -= 1
		currentstep = 0
		LivesLabel.text = "Lives: " + str(lives)
		
		if lives == 0:
			currentstep = 0
			sequence.shuffle()
			lives = 3
			for plate in get_children():
				if plate is Area3D:
					plate.reset_plate()
			LivesLabel.text = "Lives: " + str(lives)
