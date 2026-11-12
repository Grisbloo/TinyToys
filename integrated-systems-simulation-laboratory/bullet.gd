extends Area3D

@export var speed: float = 35.0
@export var lifetime: float = 3.0

var direction: Vector3 = Vector3.RIGHT

func _ready() -> void:
	area_entered.connect(_on_area_entered)

func _physics_process(delta: float) -> void:
	global_position += direction.normalized() * speed * delta

	lifetime -= delta

	if lifetime <= 0.0:
		queue_free()

func _on_area_entered(area: Area3D) -> void:
	var object = area.get_parent()

	if object.has_method("take_hit"):
		object.take_hit()
		queue_free()
