extends CharacterBody3D

var speed = 25


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	# For this specific game z axis is flipped
	if Input.is_action_pressed("move up"):
		var inputdirection = Vector3.BACK
		self.velocity = inputdirection * speed
		self.move_and_slide()
	
	# For this specific game z axis is flipped
	if Input.is_action_pressed("move down"):
		var inputdirection = Vector3.FORWARD
		self.velocity = inputdirection * speed
		self.move_and_slide()
	
	# Consequently left and right are backwards
	if Input.is_action_pressed("move left"):
		var inputdirection = Vector3.RIGHT
		self.velocity = inputdirection * speed
		self.move_and_slide()
		
	if Input.is_action_pressed("move right"):
		var inputdirection = Vector3.LEFT
		self.velocity = inputdirection * speed
		self.move_and_slide()
