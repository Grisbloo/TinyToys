extends Node3D

@onready var camera: Camera3D = $Camera3D
@onready var samantha: CharacterBody3D = $SamanthaRoot

@onready var bed_approach_1: Marker3D = $NavigationRegion3D/Furniture/Bed/Approach
@onready var bed_approach_2: Marker3D = $NavigationRegion3D/Furniture/Bed/Approach2
@onready var bed_lying_position: Marker3D = $NavigationRegion3D/Furniture/Bed/LyingPosition

@onready var chair_approaches: Array[Marker3D] = [
	$NavigationRegion3D/Furniture/Chair/Approach,
	$NavigationRegion3D/Furniture/Chair/Approach2,
	$NavigationRegion3D/Furniture/Chair/Approach3
]

@onready var chair_seat: Marker3D = \
	$NavigationRegion3D/Furniture/Chair/SittingPosition


func _unhandled_input(event: InputEvent) -> void:

	# Click the floor to move Samantha.
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			move_samantha_to_mouse()

	# Press B to send Samantha to bed.
	if event is InputEventKey:
		if event.pressed and not event.echo:
			match event.keycode:
				KEY_B:
					send_samantha_to_bed()
				KEY_G:
					samantha.get_up()
				KEY_C:
					send_samantha_to_chair()
				KEY_V:
					samantha.stand_from_chair()


func send_samantha_to_bed() -> void:
	var distance_1 := samantha.global_position.distance_to(
		bed_approach_1.global_position
	)

	var distance_2 := samantha.global_position.distance_to(
		bed_approach_2.global_position
	)

	var chosen_approach: Marker3D

	if distance_1 <= distance_2:
		chosen_approach = bed_approach_1
	else:
		chosen_approach = bed_approach_2

	print("Chosen approach: ", chosen_approach.name)

	samantha.go_to_bed(chosen_approach, bed_lying_position)


func move_samantha_to_mouse() -> void:
	var mouse_position := get_viewport().get_mouse_position()

	var origin := camera.project_ray_origin(mouse_position)
	var direction := camera.project_ray_normal(mouse_position)

	var query := PhysicsRayQueryParameters3D.create(
		origin,
		origin + direction * 100.0
	)

	# Raycast only against collision layer 2 (floor).
	query.collision_mask = 1 << 1

	var result := get_world_3d().direct_space_state.intersect_ray(query)

	if not result.is_empty():
		samantha.move_to(result.position)

func send_samantha_to_chair() -> void:
	var best_approach: Marker3D = chair_approaches[0]
	var best_distance: float = INF

	for approach in chair_approaches:
		var distance: float = samantha.global_position.distance_to(
			approach.global_position
		)

		if distance < best_distance:
			best_distance = distance
			best_approach = approach

	print("Chosen chair approach: ", best_approach.name)

	samantha.go_to_chair(best_approach, chair_seat)
