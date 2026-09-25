extends CharacterBody3D

var speed = 25

func _process(_delta: float) -> void: 
	if Input.is_action_pressed("move_up"):
		var inputdirection = Vector3.FORWARD
		self.velocity = inputdirection * speed
		self.move_and_slide()

	if Input.is_action_pressed("move_down"):
		var inputdirection = Vector3.BACK
		self.velocity = inputdirection * speed
		self.move_and_slide()

	if Input.is_action_pressed("move_left"):
		var inputdirection = Vector3.LEFT
		self.velocity = inputdirection * speed
		self.move_and_slide()
		
	if Input.is_action_pressed("move_right"):
		var inputdirection = Vector3.RIGHT
		self.velocity = inputdirection * speed
		self.move_and_slide()
