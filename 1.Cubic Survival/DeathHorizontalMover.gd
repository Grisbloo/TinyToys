extends CharacterBody3D

var speed = randi_range(50, 150)
var EdgeBox = 20
var barDirection = "Right"

@onready var Player = get_node("../Player")

func _physics_process(_delta: float) -> void:
	if barDirection == "Right":
		var MovementDirection = Vector3.RIGHT
		self.velocity = MovementDirection * speed
		move_and_slide()

		var last_collision = get_last_slide_collision()
		if last_collision:
			var collider = last_collision.get_collider()
			if collider == Player:
				Player.queue_free()

		var CurrentPosition = position.x
		if CurrentPosition >= EdgeBox:
			barDirection = "Left"

	elif barDirection == "Left":
		var MovementDirection = Vector3.LEFT
		self.velocity = MovementDirection * speed
		move_and_slide()

		var last_collision = get_last_slide_collision()
		if last_collision:
			var collider = last_collision.get_collider()
			if collider == Player:
				Player.queue_free()

		var CurrentPosition = position.x
		if CurrentPosition <= -EdgeBox:
			barDirection = "Right"
